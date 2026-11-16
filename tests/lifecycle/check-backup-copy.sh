#!/usr/bin/env bash
# What the operator would check by hand on the copy to the backup server (R44), with
# server and client on the same runner, as in DEV. Usage: check-backup-copy.sh <step>
#   server         running, only on 127.0.0.1, append-only, private repos, size limit,
#                  password required and only its hash stored
#   installed      copy timer on, nothing run by the apply, hardened container
#   ok             last copy good; the server holds every snapshot of the local
#                  repository, readable straight from its volume with only the restic key
#   append-only    a client cannot delete anything on the server
#   unreachable    last run could not reach the server: not a failure, last good kept
#   failed <text>  last run failed and the status says <text>
#   count          prints the number of snapshots on the server
#   egress <allowed ip> <forbidden ip> <port>
#                  the copy container's network lets it reach the first address and not
#                  the second (R59), tried with a real container on that network
#   no-egress      that network and its unit are gone
#   destroyed      server unit gone, copies kept (SPEC 4.2)
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
server=dev-backup-server
copy=dev-backup-copy
port=18000
site=ci-site
path=$site/dev-localhost
home=$(getent passwd svc_runner | cut -d: -f6)
status=/var/lib/infra-podman/backup-status/$copy.status
images=$here/../../playbooks/group_vars/all/images.yml
restic_image=$(sed -n 's/^restic_image: *"\([^"]*\)".*/\1/p' "$images")
# fd 3 is the real stdout: a failure inside a command whose output is discarded must
# still reach the annotations.
exec 3>&1
fail() { echo "::error title=check-backup-copy::$*" >&3; exit 1; }
errlog=$(mktemp)
exec 2> >(tee "$errlog" >&2)
trap 'fail "line $LINENO: $BASH_COMMAND: $(tail -5 "$errlog" | tr "\n" " ")"' ERR
field() { sed -n "s/^$1=//p" "$status"; }
spw=$(cat "$RUNNER_TEMP/spw")
http() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# The emergency path (docs/SETUP.md, step 18): the copies straight from the server's
# volume, without the server and without its password. Only the restic key.
restic_direct() {
  "$as" podman run --rm --network=none -v "$server-data:/data:ro" \
    --secret dev-backup-restic-password,type=mount,target=/run/secrets/restic-password \
    -e RESTIC_REPOSITORY="/data/$path" -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
    ${OUT:+-v "$OUT:/out"} "$restic_image" --no-cache --no-lock "$@"
}
restic_local() {
  "$as" podman run --rm --network=none -v dev-backup-repo:/repo \
    --secret dev-backup-restic-password,type=mount,target=/run/secrets/restic-password \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
    "$restic_image" --no-cache "$@"
}

case $1 in
  server)
    "$as" systemctl --user is-active "$server.service" >/dev/null || fail "$server is not running"
    ports=$("$as" podman port "$server")
    [[ $ports == "8000/tcp -> 127.0.0.1:$port" ]] || fail "published ports: $ports (only 127.0.0.1:$port expected)"
    # No way out (R58): only its own internal network.
    nets=$("$as" podman inspect --format '{{json .NetworkSettings.Networks}}' "$server" | jq -r 'keys | join(" ")')
    [[ $nets == "$server-net" ]] || fail "networks of the server: $nets (only $server-net expected)"
    [[ $("$as" podman network inspect --format '{{.Internal}}' "$server-net") == true ]] || fail "$server-net is not internal"
    gen=$("$as" systemctl --user cat "$server.service")
    for want in --append-only --private-repos '--max-size 32212254720' --read-only --cap-drop=all; do
      grep -q -- "$want" <<<"$gen" || fail "the server unit lacks $want"
    done
    [[ $(http "http://127.0.0.1:$port/") == 401 ]] || fail "the server answers without a password"
    [[ $(http -u "$site:wrong" "http://127.0.0.1:$port/$path/config") == 401 ]] || fail "the server accepts a wrong password"
    code=$(http -u "$site:$spw" "http://127.0.0.1:$port/$path/config")
    [[ $code == 404 ]] || fail "with the right password, its own repository gives $code instead of 404 (not created yet)"
    code=$(http -u "$site:$spw" "http://127.0.0.1:$port/other-site/dev-x/config")
    [[ $code == 401 || $code == 403 ]] || fail "the user reaches another installation's folder ($code)"
    hash=$("$as" cat "$home/.config/infra-podman/$server/htpasswd")
    [[ $hash == "$site:\$2"* ]] || fail "the password file is not a bcrypt hash for $site"
    ! grep -qF "$spw" <<<"$hash" || fail "the password is stored in clear"
    [[ $("$as" stat -c %a "$home/.config/infra-podman/$server/htpasswd") == 600 ]] || fail "the hash is readable by others"
    echo "::notice title=Backup server::$ports; 401 without or with a wrong password; another installation refused ($code)"
    ;;
  installed)
    "$as" systemctl --user is-enabled "$copy.timer" >/dev/null || fail "$copy.timer is not enabled"
    "$as" systemctl --user is-active "$copy.timer" >/dev/null || fail "$copy.timer is not active"
    [[ ! -e $status ]] || fail "a copy ran during the apply (only the timer may start it)"
    gen=$("$as" systemctl --user cat "$copy.service")
    grep -q -- 'dev-backup-repo:/repo:ro' <<<"$gen" || fail "the local repository is not mounted read-only"
    for want in --read-only --cap-drop=all 'label.disable' "--network=container:$server"; do
      grep -q -- "$want" <<<"$gen" || fail "the copy unit lacks $want"
    done
    ! grep -q -- 'dev-pg-' <<<"$gen" || fail "the copy container can see PostgreSQL"
    ! "$as" test -e "/run/user/$(id -u svc_runner)/systemd/generator/default.target.wants/$copy.service" \
      || fail "$copy.service would start at boot"
    echo "::notice title=Copy timer::$("$as" systemctl --user list-timers "$copy.timer" --no-pager | sed -n 2p)"
    ;;
  ok)
    [[ $(field result) == ok ]] || fail "status: $(cat "$status" 2>/dev/null)"
    [[ -n $(field usage) ]] || fail "no usage in the status"
    local_snaps=$(restic_local snapshots --json)
    remote_snaps=$(restic_direct snapshots --json)
    # Every local snapshot is on the server. The server may hold more: the local
    # retention removes old ones there, the append-only server never does (R26).
    missing=$(jq -n --argjson l "$local_snaps" --argjson r "$remote_snaps" \
      '[$l[] | {time, paths, tags}] - [$r[] | {time, paths, tags}] | length')
    [[ $missing == 0 ]] || fail "$missing local snapshot(s) are not on the server (local $(jq length <<<"$local_snaps"), server $(jq length <<<"$remote_snaps"))"
    OUT=$("$as" mktemp -d)
    export OUT
    restic_direct restore latest --path /backup/pg-main/pgdump/lifecycle_app --target /out --exclude-xattr '*' >/dev/null
    "$as" cat "$OUT/backup/pg-main/pgdump/lifecycle_app/lifecycle_app.dump" \
      | "$as" podman exec -i dev-pg-main pg_restore --list >/dev/null || fail "the dump restored from the server is not valid"
    "$as" rm -rf "$OUT"
    echo "::notice title=Copy::$(jq length <<<"$remote_snaps") snapshots on the server, every local one included; $(field usage); a dump restored from its volume"
    ;;
  append-only)
    id=$(restic_direct snapshots --json | jq -r '.[0].id')
    if "$as" podman run --rm --network="container:$server" \
      --secret dev-backup-restic-password,type=mount,target=/run/secrets/restic-password \
      -e RESTIC_REPOSITORY="rest:http://127.0.0.1:8000/$path/" -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
      -e RESTIC_REST_USERNAME="$site" -e RESTIC_REST_PASSWORD="$spw" \
      "$restic_image" --no-cache forget "$id" >/dev/null 2>&1; then
      fail "a client deleted a snapshot on the server"
    fi
    restic_direct snapshots --json | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null || fail "the snapshot is gone"
    echo "::notice title=Append-only::deleting a snapshot through the server is refused"
    ;;
  unreachable)
    [[ $(field result) == unreachable ]] || fail "status: $(cat "$status" 2>/dev/null)"
    [[ -n $(field last_ok_epoch) ]] || fail "the last good copy was forgotten"
    [[ $(field message) == *"no responde"* ]] || fail "message: $(field message)"
    ;;
  failed)
    [[ $(field result) == failed ]] || fail "status: $(cat "$status" 2>/dev/null)"
    [[ $(field message) == *"$2"* ]] || fail "status message does not say '$2': $(field message)"
    echo "::notice title=Copy failure message::$(field message)"
    ;;
  count)
    restic_direct snapshots --json | jq length
    ;;
  egress)
    allowed=$2 forbidden=$3 eport=$4 net=$copy-egress-net
    # The network as Podman has it, not as its unit says.
    info=$("$as" podman network inspect "$net")
    [[ $(jq -r '.[0].options.no_default_route' <<< "$info") == true ]] || fail "$net has a default route: $info"
    [[ $(jq -r '[.[0].routes[].destination] | join(" ")' <<< "$info") == "$allowed/32" ]] || fail "routes of $net: $(jq -c '.[0].routes' <<< "$info") (only $allowed/32 expected)"
    [[ $(jq -r '.[0].dns_enabled' <<< "$info") == false ]] || fail "$net has DNS"
    grep -qx "Network=$net.network" "$home/.config/containers/systemd/$copy.container" || fail "$copy is not on $net"
    # A real container, with the image of the copy container. $1: its network, or
    # "default" for Podman's own, which has a way out to everything.
    reach() {
      local network=()
      [[ $1 == default ]] || network=(--network "$1")
      "$as" podman run --rm "${network[@]}" --entrypoint /bin/sh "$restic_image" \
        -c "wget -q -T 5 -O /dev/null http://$2:$eport/" > /dev/null 2>&1
    }
    # Without the limit both answer: otherwise the next two lines would prove nothing.
    reach default "$allowed" || fail "control: $allowed:$eport does not answer even from Podman's default network"
    reach default "$forbidden" || fail "control: $forbidden:$eport does not answer even from Podman's default network"
    reach "$net" "$allowed" || fail "from $net the allowed address $allowed:$eport does not answer"
    ! reach "$net" "$forbidden" || fail "from $net the address $forbidden:$eport answers, and only $allowed is allowed (R59)"
    ;;
  no-egress)
    net=$copy-egress-net
    ! "$as" podman network exists "$net" || fail "the network $net is still there"
    ! "$as" test -e "$home/.config/containers/systemd/$net.network" || fail "$net.network is still installed"
    ! grep -q "$net" "$home/.config/containers/systemd/$copy.container" || fail "$copy still uses $net"
    ;;
  destroyed)
    ! "$as" test -e "$home/.config/containers/systemd/$server.container" || fail "$server.container is still installed"
    "$as" podman volume exists "$server-data" || fail "the copies were removed (SPEC 4.2)"
    [[ $(restic_direct snapshots --json | jq length) -gt 0 ]] || fail "the copies are gone"
    ;;
  *) echo "usage: $0 server|installed|ok|append-only|unreachable|failed <text>|count|egress <ip> <ip> <port>|no-egress|destroyed" >&2; exit 2 ;;
esac
[[ $1 == count ]] || echo "ok: $1"
