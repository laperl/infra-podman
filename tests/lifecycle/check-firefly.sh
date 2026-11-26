#!/usr/bin/env bash
# Firefly III on the runner (docs/services/firefly.md), two instances (R48) as deployed by
# the firefly job: casa on 127.0.0.1:17100 and canary on 127.0.0.1:17101, each with its own
# database (tests/lifecycle/firefly-vars.yml). Usage: check-firefly.sh <step> [instance]
# (default casa):
#   running    healthy, published only on 127.0.0.1:<its port>, /health and the login page answer
#   standard   hardening, limits, its one network, secrets as files, its settings
#   schema     its tables in the schema of its database, owned by its _owner group
#   reader     ff_ro (ff_casa_reader), from the network of canary, whose pg_hba names ff_casa,
#              reads casa's tables and cannot change them, nor enter ff_canary
#   isolation  no way out: not to the internet, the host, or the other instance and its network
#   egress <instance> <allowed ip> <forbidden ip>
#              with networking.egress: [<allowed ip>], it reaches that address and nothing
#              else: not the other address of the runner, not the internet (R59)
#   told <instance> <apply log> <check log>
#              the apply and the check playbook say whether this machine really limits
#              that way out (it needs netavark 1.7.0 or newer)
#   pair       with casa connecting to canary (firefly-pair.yml): their own internal,
#              isolated network with only the two, reachable by name both ways (docs/NETWORK.md)
#   no-pair    that line removed: the network and its unit are gone, and so is the path
#   user       the first user, through the registration page, as the operator does it
#   cron       the scheduled tasks run inside the container, from their service
#   launcher   the operator's .desktop file is valid and opens 127.0.0.1:<its port>
#   wait       with PostgreSQL unhealthy it does not start, within its timeout (SPEC 4.3)
#   marker     write | read (the third word): a file in its volume and its migrations count
#   destroyed  container, timer and launcher gone; volume and database kept (SPEC 4.2)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
step=${1:-}
instance=${2:-casa}
case $instance in
  casa) port=17100 other=canary ;;
  canary) port=17101 other=casa ;;
  *) echo "unknown instance $instance" >&2; exit 2 ;;
esac
name=dev-ff-$instance
db=ff_$instance
pg=dev-pg-main
su=ci_admin  # fictitious superuser of tests/lifecycle/inventory.yml
net=dev-ff-$instance-pg-main-net
other_name=dev-ff-$other
other_net=dev-ff-$other-pg-main-net
launcher=$HOME/.local/share/applications/infra-podman-$name.desktop
state=${RUNNER_TEMP:-/tmp}/firefly-marker-$instance
fail() { local m="$*"; echo "::error title=check-firefly $step $instance::${m//$'\n'/ | }"; exit 1; }
sql() { # sql <query> [database]: as the superuser, through the socket
  "$as" podman exec "$pg" psql -X -U "$su" -d "${2:-$db}" -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
}
inspect() { "$as" podman inspect "$name" --format "$1"; }
in_ff() { "$as" podman exec "$name" bash -c "$1" </dev/null; }
pg_image() { "$as" podman inspect "$pg" --format '{{.ImageName}}'; }
ip_in() { # ip_in <container> <network>
  "$as" podman inspect "$1" --format "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}"
}
healthy() { # healthy <seconds>
  local i
  for ((i = 0; i < $1; i += 5)); do
    "$as" podman healthcheck run "$name" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# Whether this machine limits a way out with routes: netavark 1.7.0 or newer. An older
# one, like Ubuntu 24.04's 1.4.0, ignores them, and the platform has to say so.
limits() {
  local stack
  stack=$("$as" podman info --format '{{.Host.NetworkBackendInfo.Version}}')
  [[ $stack == "netavark "* && $(printf '%s\n' 1.7.0 "${stack#netavark }" | sort -V | head -n 1) == 1.7.0 ]]
}
# told <apply log> <check log>: the apply and the check playbook say the truth about it.
told() {
  if limits; then
    ! grep -q 'WARNING: .* limits the way out' "$1" || fail "the apply warns that this machine does not limit, and it does"
    ! grep -q 'ESTA MÁQUINA NO LIMITA' "$2" || fail "the check report says this machine does not limit, and it does"
    grep -q 'salida SOLO a' "$2" || fail "the check report does not show the limited network"
  else
    grep -q 'WARNING: .* limits the way out' "$1" || fail "this machine does not limit the way out and the apply did not warn"
    grep -q 'ESTA MÁQUINA NO LIMITA' "$2" || fail "this machine does not limit the way out and the check report does not say so"
    grep -q 'no limita la salida en esta máquina' "$2" || fail "the check report does not count it as a problem"
  fi
}
case $step in
  running)
    [[ $("$as" systemctl --user is-active "$name.service") == active ]] || fail "$name.service is not active"
    "$as" podman healthcheck run "$name" >/dev/null || fail "$name is not healthy"
    ports=$("$as" podman port "$name")
    [[ $ports == "8080/tcp -> 127.0.0.1:$port" ]] || fail "published ports: '$ports', expected only 127.0.0.1:$port"
    body=$(curl -fsS "http://127.0.0.1:$port/health") || fail "/health does not answer on 127.0.0.1:$port"
    [[ $body == OK ]] || fail "/health says '$body'"
    # Without users yet Firefly sends /login on to /register: follow it, it must stay here.
    got=$(curl -sL -o /dev/null -w '%{http_code} %{url_effective}' "http://127.0.0.1:$port/login")
    [[ $got =~ ^200\ http://127\.0\.0\.1:$port/ ]] || fail "the login page answers '$got'"
    host_ip=$(hostname -I | awk '{print $1}')
    if timeout 5 bash -c "</dev/tcp/$host_ip/$port" 2>/dev/null; then fail "port $port answers on $host_ip"; fi
    ;;
  standard)
    [[ $(inspect '{{.Config.User}}') == www-data ]] || fail "not running as www-data: $(inspect '{{.Config.User}}')"
    caps=$(inspect '{{.EffectiveCaps}}')
    [[ $caps == "[]" ]] || fail "capabilities left: $caps"
    inspect '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' || fail "no-new-privileges is not set"
    # canary sets memory: 768m in the inventory; casa keeps the default, 512m.
    memory=536870912
    [[ $instance == canary ]] && memory=805306368
    [[ $(inspect '{{.HostConfig.Memory}}') == "$memory" ]] || fail "memory limit: $(inspect '{{.HostConfig.Memory}}')"
    [[ $(inspect '{{.HostConfig.NanoCpus}}') == 1000000000 ]] || fail "CPU limit: $(inspect '{{.HostConfig.NanoCpus}}')"
    [[ $(inspect '{{.HostConfig.PidsLimit}}') == 200 ]] || fail "pids limit: $(inspect '{{.HostConfig.PidsLimit}}')"
    # shellcheck disable=SC2016  # a Go template, not a shell expansion
    nets=$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
    [[ $nets == "$net " ]] || fail "networks: '$nets', expected only $net"
    inspect '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' | grep -q "$name-uploads:/var/www/html/storage/upload" \
      || fail "the attachments volume is not mounted"
    env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
    if grep -Eq '^(APP_KEY|DB_PASSWORD)=' <<<"$env"; then fail "a secret is in the environment, not in a file"; fi
    grep -qx 'DB_PASSWORD_FILE=/run/secrets/db-password' <<<"$env" || fail "DB_PASSWORD_FILE is not set"
    [[ $(in_ff 'stat -c %U:%a /run/secrets/db-password') == www-data:400 ]] || fail "the secret file is not www-data, 0400"
    tz=UTC
    [[ $instance == casa ]] && tz=Europe/Madrid
    grep -qx "TZ=$tz" <<<"$env" || fail "TZ is not the one of the inventory ($tz)"
    for v in DB_DATABASE DB_USERNAME PGSQL_SCHEMA; do
      grep -qx "$v=$db" <<<"$env" || fail "$v is not its own ($db)"
    done
    # What the measurement of the limits starts from (R46): shown, never a failure.
    echo "::notice title=Firefly $instance resources::$("$as" podman stats --no-stream --format '{{.MemUsage}} mem, {{.PIDs}} processes' "$name")"
    ;;
  schema)
    # One database per instance, with one schema of the same name (docs/POSTGRES.md, 2).
    n=$(sql "SELECT count(*) FROM pg_tables WHERE schemaname = '$db'")
    [[ $n -gt 20 ]] || fail "only $n tables in the schema $db"
    others=$(sql "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('$db', 'pg_catalog', 'information_schema')")
    [[ $others == 0 ]] || fail "$others tables outside the schema $db"
    owners=$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = '$db'")
    [[ $owners == "${db}_owner" ]] || fail "tables owned by '$owners', expected ${db}_owner (R35)"
    [[ $(sql "SELECT to_regclass('$db.users') IS NOT NULL") == t ]] || fail "no table $db.users"
    ;;
  reader)
    # The network of canary admits the users of ff_casa (its pg_hba names it, inventory.yml).
    canary_net=dev-ff-canary-pg-main-net
    client() { # client <query>: as ff_ro over TCP, from the network of canary
      "$as" podman --log-level=error run --rm --network "$canary_net" \
        --secret dev-ff-ro-db-password,type=env,target=PGPASSWORD --entrypoint psql "$(pg_image)" \
        -X -h "$pg" -U ff_ro -d ff_casa -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
    }
    out=$(client "SELECT count(*) FROM users" 2>&1) || fail "ff_ro cannot read users: $out"
    if out=$(client "DELETE FROM migrations" 2>&1); then fail "ff_ro deleted rows"; fi
    grep -q 'permission denied' <<<"$out" || fail "the delete failed for another reason: $out"
    if out=$(client "CREATE TABLE lifecycle_t (n int)" 2>&1); then fail "ff_ro created a table"; fi
    grep -q 'permission denied' <<<"$out" || fail "the create failed for another reason: $out"
    # Nor into the database of the other instance: ff_ro is no user of ff_canary, so no
    # line of pg_hba.conf admits it there, from any network (R48, docs/NETWORK.md).
    if out=$("$as" podman --log-level=error run --rm --network "$canary_net" \
         --secret dev-ff-ro-db-password,type=env,target=PGPASSWORD --entrypoint psql "$(pg_image)" \
         -X -h "$pg" -U ff_ro -d ff_canary -tAq -c "SELECT 1" </dev/null 2>&1); then
      fail "ff_ro connected to the database of canary"
    fi
    ;;
  isolation)
    # Controls from the runner, so a failure below means isolation and not a broken runner.
    timeout 5 bash -c '</dev/tcp/1.1.1.1/443' || fail "control: the runner cannot reach 1.1.1.1:443"
    getent hosts example.com >/dev/null || fail "control: the runner cannot resolve example.com"
    host_ip=$(hostname -I | awk '{print $1}')
    python3 -m http.server 18999 --bind 0.0.0.0 >/dev/null 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null || true' EXIT
    sleep 1
    timeout 5 bash -c "</dev/tcp/$host_ip/18999" || fail "control: the runner cannot reach its own port 18999"
    # Control inside: Firefly does reach its PostgreSQL.
    in_ff "timeout 5 bash -c '</dev/tcp/$pg/5432'" || fail "control: Firefly cannot reach $pg:5432"
    if in_ff 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' 2>/dev/null; then fail "Firefly reached 1.1.1.1:443"; fi
    if in_ff 'getent hosts example.com' >/dev/null 2>&1; then fail "Firefly resolved example.com"; fi
    if in_ff 'curl -s -m 5 -o /dev/null https://example.com' 2>/dev/null; then fail "Firefly fetched https://example.com"; fi
    if in_ff "timeout 5 bash -c '</dev/tcp/$host_ip/18999'" 2>/dev/null; then fail "Firefly reached the host ($host_ip:18999)"; fi
    # The other instance (R48): another network, another subnet, nothing reachable.
    [[ $("$as" podman network inspect "$net" --format '{{range .Subnets}}{{.Subnet}}{{end}}') != \
       $("$as" podman network inspect "$other_net" --format '{{range .Subnets}}{{.Subnet}}{{end}}') ]] \
      || fail "$net and $other_net share their subnet"
    other_ip=$(ip_in "$other_name" "$other_net")
    pg_other_ip=$(ip_in "$pg" "$other_net")
    if in_ff "timeout 5 bash -c '</dev/tcp/$other_ip/8080'" 2>/dev/null; then fail "Firefly reached $other_name ($other_ip:8080)"; fi
    if in_ff "getent hosts $other_name" >/dev/null 2>&1; then fail "Firefly resolved $other_name"; fi
    if in_ff "timeout 5 bash -c '</dev/tcp/$pg_other_ip/5432'" 2>/dev/null; then
      fail "Firefly reached PostgreSQL through the network of $other ($pg_other_ip)"
    fi
    ;;
  egress)
    allowed=${3:?} forbidden=${4:?} egress_net=$name-egress-net
    python3 -m http.server 18999 --bind 0.0.0.0 >/dev/null 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null || true' EXIT
    sleep 1
    # Controls from the runner: both addresses answer, so a refusal below is the network.
    timeout 5 bash -c "</dev/tcp/$allowed/18999" || fail "control: the runner cannot reach $allowed:18999"
    timeout 5 bash -c "</dev/tcp/$forbidden/18999" || fail "control: the runner cannot reach $forbidden:18999"
    timeout 5 bash -c '</dev/tcp/1.1.1.1/443' || fail "control: the runner cannot reach 1.1.1.1:443"
    # The network as Podman has it, and the container on it besides its PostgreSQL one.
    info=$("$as" podman network inspect "$egress_net")
    [[ $(jq -r '.[0].options.no_default_route' <<< "$info") == true ]] || fail "$egress_net has a default route"
    [[ $(jq -r '[.[0].routes[].destination] | join(" ")' <<< "$info") == "$allowed/32" ]] || fail "routes of $egress_net: $(jq -c '.[0].routes' <<< "$info")"
    [[ $(jq -r '.[0].dns_enabled' <<< "$info") == false ]] || fail "$egress_net has DNS"
    nets=$("$as" podman inspect --format '{{json .NetworkSettings.Networks}}' "$name" | jq -r 'keys | sort | join(" ")')
    [[ $nets == "$egress_net $net" ]] || fail "networks of $name: $nets (expected $egress_net and $net)"
    in_ff "timeout 5 bash -c '</dev/tcp/$pg/5432'" || fail "Firefly no longer reaches $pg:5432"
    in_ff "timeout 5 bash -c '</dev/tcp/$allowed/18999'" || fail "Firefly cannot reach the allowed address $allowed:18999"
    if limits; then
      if in_ff "timeout 5 bash -c '</dev/tcp/$forbidden/18999'" 2>/dev/null; then fail "Firefly reached $forbidden:18999, and only $allowed is allowed"; fi
      if in_ff 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' 2>/dev/null; then fail "Firefly reached 1.1.1.1:443, and only $allowed is allowed"; fi
    else
      echo "::notice title=check-firefly egress::this machine does not limit the way out (netavark older than 1.7.0): that $forbidden is out of reach cannot be tried here"
    fi
    if in_ff 'getent hosts example.com' >/dev/null 2>&1; then fail "Firefly resolved example.com"; fi
    ;;
  told) told "${3:?}" "${4:?}" ;;
  pair)
    # <instance> connects to the other one (tests/lifecycle/firefly-pair.yml): their own
    # network, internal, isolated, without outside DNS, with only those two (docs/NETWORK.md).
    pnet=dev-ff-$instance-ff-$other-net
    info=$("$as" podman network inspect "$pnet") || fail "no network $pnet"
    [[ $(jq -r '.[0].internal' <<< "$info") == true ]] || fail "$pnet is not internal"
    [[ $(jq -r '.[0].options.isolate' <<< "$info") == true ]] || fail "$pnet is not isolated"
    [[ $(jq -c '.[0].network_dns_servers' <<< "$info") == '["127.0.0.1"]' ]] || fail "$pnet sends DNS out: $(jq -c '.[0].network_dns_servers' <<< "$info")"
    on=$("$as" podman ps --filter network="$pnet" --format '{{.Names}}' | sort | xargs)
    [[ $on == "$name $other_name" || $on == "$other_name $name" ]] || fail "containers on $pnet: '$on' (expected $name and $other_name)"
    # By name, and both ways: a network has no direction (docs/NETWORK.md, section 10).
    in_ff "timeout 5 bash -c '</dev/tcp/$other_name/8080'" || fail "$name does not reach $other_name:8080"
    "$as" podman exec "$other_name" bash -c "timeout 5 bash -c '</dev/tcp/$name/8080'" </dev/null \
      || fail "$other_name does not reach $name:8080"
    # Still nothing outside: a pair network is internal.
    if in_ff 'getent hosts example.com' >/dev/null 2>&1; then fail "$name resolved example.com"; fi
    ;;
  no-pair)
    pnet=dev-ff-$instance-ff-$other-net
    ! "$as" podman network exists "$pnet" || fail "the network $pnet is still there"
    svc_home=$(getent passwd svc_runner | cut -d: -f6)
    ! "$as" test -e "$svc_home/.config/containers/systemd/$pnet.network" || fail "$pnet.network is still installed"
    if in_ff "timeout 5 bash -c '</dev/tcp/$other_name/8080'" 2>/dev/null; then fail "$name still reaches $other_name"; fi
    ;;
  user)
    # A fictitious user, with a random password that goes to the list of secrets the job
    # looks for in its output. Without internet: the password check against
    # api.pwnedpasswords.com is the optional box, left unticked.
    jar=$(mktemp)
    password=$(openssl rand -hex 24)
    echo "::add-mask::$password"
    echo "$password" >> "${RUNNER_TEMP:?}/pw"
    page=$(mktemp)
    code=$(curl -sS -c "$jar" -o "$page" -w '%{http_code}' "http://127.0.0.1:$port/register") || code="curl failed"
    [[ $code == 200 ]] || fail "the registration page answers $code: $(head -c 300 "$page")"
    token=$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' "$page")
    token=${token%%$'\n'*}
    rm -f "$page"
    [[ -n $token ]] || fail "the registration page has no form token"
    code=$(curl -s -b "$jar" -c "$jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/register" \
      --data-urlencode "_token=$token" --data-urlencode "email=lifecycle@example.com" \
      --data-urlencode "password=$password" --data-urlencode "password_confirmation=$password") || code="curl failed"
    rm -f "$jar"
    [[ $code == 302 ]] || fail "the registration answered $code"
    owners=$(sql "SELECT count(*) FROM $db.role_user ru JOIN $db.roles r ON r.id = ru.role_id WHERE r.name = 'owner'")
    [[ $owners == 1 ]] || fail "the first user is not the owner ($owners owners)"
    ;;
  cron)
    [[ $("$as" systemctl --user is-active "$name-cron.timer") == active ]] || fail "$name-cron.timer is not active"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    # The journal of the unit also holds the healthchecks of its ExecStartPre: left out.
    "$as" systemctl --user start "$name-cron.service" || fail "the scheduled tasks failed: $(sudo journalctl \
      _SYSTEMD_USER_UNIT="$name-cron.service" --since "$since" --no-pager -o cat | grep -v 'health_status' | tail -15)"
    [[ $("$as" systemctl --user show -p Result --value "$name-cron.service") == success ]] || fail "the scheduled tasks did not end well"
    ;;
  launcher)
    [[ -f $launcher ]] || fail "no launcher at $launcher"
    desktop-file-validate "$launcher" || fail "the launcher is not a valid .desktop file"
    # casa: the default browser; canary: the launcher_command of the inventory.
    exec_line="Exec=xdg-open http://127.0.0.1:$port"
    [[ $instance == canary ]] && exec_line="Exec=flatpak run org.mozilla.firefox --new-window http://127.0.0.1:$port"
    grep -qxF "$exec_line" "$launcher" || fail "the launcher does not say '$exec_line': $(grep '^Exec=' "$launcher")"
    grep -qx "Name=Firefly III ($instance)" "$launcher" || fail "the launcher is not named after its instance"
    ;;
  wait)
    # PostgreSQL paused: its healthcheck fails, so Firefly must wait and give up at
    # TimeoutStartSec (60 s in the lifecycle inventory).
    "$as" podman pause "$pg" >/dev/null
    start=$(date +%s)
    if out=$("$as" systemctl --user restart "$name.service" 2>&1); then
      "$as" podman unpause "$pg" >/dev/null
      fail "Firefly started with PostgreSQL unhealthy"
    fi
    took=$(($(date +%s) - start))
    "$as" podman unpause "$pg" >/dev/null
    # systemctl says: Job for dev-ff-casa.service failed because a timeout was exceeded.
    grep -q 'timeout' <<<"$out" || fail "Firefly failed to start for another reason: $out"
    ((took >= 55 && took <= 100)) || fail "Firefly gave up after $took s, expected its TimeoutStartSec (60 s)"
    # Restart=on-failure: once PostgreSQL is healthy again, it starts by itself.
    healthy 240 || fail "Firefly did not start by itself once PostgreSQL was healthy again"
    echo "::notice title=Wait for PostgreSQL (SPEC 4.3)::gave up after $took s with PostgreSQL paused; started by itself after"
    ;;
  marker)
    case ${3:-} in
      write)
        in_ff 'echo lifecycle > /var/www/html/storage/upload/lifecycle-marker'
        sql "SELECT count(*) FROM $db.migrations" > "$state"
        ;;
      read)
        [[ $(in_ff 'cat /var/www/html/storage/upload/lifecycle-marker') == lifecycle ]] || fail "the attachments volume lost its file"
        [[ $(sql "SELECT count(*) FROM $db.migrations") == "$(cat "$state")" ]] || fail "the database changed"
        ;;
      *) fail "usage: marker <instance> write|read" ;;
    esac
    ;;
  destroyed)
    if "$as" podman container exists "$name"; then fail "the container still exists"; fi
    "$as" podman volume exists "$name-uploads" || fail "the attachments volume was removed"
    home=$(getent passwd svc_runner | cut -d: -f6)
    if sudo test -e "$home/.config/systemd/user/$name-cron.timer"; then fail "the timer is still installed"; fi
    if [[ -e $launcher ]]; then fail "the launcher is still installed"; fi
    [[ $(sql "SELECT count(*) FROM $db.migrations") -gt 0 ]] || fail "its database lost its data"
    ;;
  *)
    echo "usage: $0 running|standard|schema|reader|isolation|user|cron|launcher|wait|marker|destroyed [casa|canary]" >&2
    exit 2
    ;;
esac
echo "ok: $step $instance"
