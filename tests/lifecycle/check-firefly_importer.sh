#!/usr/bin/env bash
# The Firefly III Data Importer on the runner (docs/services/firefly_importer.md), the instance
# ci as deployed by the firefly_importer job (tests/lifecycle/firefly_importer-vars.yml):
# 127.0.0.1:18115, importing into Firefly casa (127.0.0.1:18100).
# Usage: check-firefly_importer.sh <step>
#   running    healthy, published only on 127.0.0.1:18115, /health answers OK
#   standard   its user (www-data, 33), hardening, not read-only, limits, its one network, no
#              named volume (the anonymous one of the image is noted), and the environment the
#              role writes (its Firefly, OAuth, logs)
#   firefly    from the importer, Firefly casa answers by the network of the pair
#   pair       Firefly casa is on the network of the pair too (after apply firefly)
#   oauth      end to end up to the login: with the client ID of the inventory and no session
#              the importer asks for OAuth, and sends the browser to Firefly's address on
#              127.0.0.1 with that client, its own callback and PKCE (S256); Firefly answers
#              there and asks for its login
#   isolation  no way out: not to the internet, not to the host
#   launcher   the operator's .desktop file is valid and opens 127.0.0.1:18115
#   report     playbooks/check.yml shows it running and healthy, only on 127.0.0.1 (the log of
#              that playbook, the second word)
#   destroyed  container and launcher gone, and its anonymous volume (it has nothing to keep)
#   restart    a restart makes a new container and its old anonymous volume goes: what you
#              uploaded does not survive it
#   no-pair    the importer no longer declared and apply firefly done: Firefly casa has left
#              the network of the pair, and the network is gone
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
step=${1:-}
instance=ci
port=18115
name=dev-ffimport-$instance
ff=dev-ff-casa
ff_port=18100
client_id=7                 # fictitious, tests/lifecycle/firefly_importer-vars.yml
net=dev-ffimport-$instance-ff-casa-net
launcher=$HOME/.local/share/applications/infra-podman-$name.desktop
fail() { local m="$*"; echo "::error title=check-firefly_importer $step::${m//$'\n'/ | }"; exit 1; }
inspect() { "$as" podman inspect "$name" --format "$1"; }
in_imp() { "$as" podman exec "$name" sh -c "$1" </dev/null; }
# The anonymous volumes seen by 'standard' are gone.
anon_gone() {
  local v
  while read -r v; do
    [[ -z $v ]] && continue
    if "$as" podman volume exists "$v"; then fail "its anonymous volume $v is still there"; fi
  done < "${RUNNER_TEMP:?}/ffimport-anon"
}
# shellcheck disable=SC2016  # a Go template, not a shell expansion
networks_of() { "$as" podman inspect "$1" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'; }

case $step in
  running)
    [[ $("$as" systemctl --user is-active "$name.service") == active ]] || fail "$name.service is not active"
    "$as" podman healthcheck run "$name" >/dev/null || fail "$name is not healthy"
    ports=$("$as" podman port "$name")
    [[ $ports == "8080/tcp -> 127.0.0.1:$port" ]] || fail "published ports: '$ports', expected only 127.0.0.1:$port"
    body=$(curl -fsS "http://127.0.0.1:$port/health") || fail "/health does not answer on 127.0.0.1:$port"
    [[ $body == OK ]] || fail "/health says '$body'"
    host_ip=$(hostname -I | awk '{print $1}')
    if timeout 5 bash -c "</dev/tcp/$host_ip/$port" 2>/dev/null; then fail "port $port answers on $host_ip"; fi
    ;;
  standard)
    [[ $(in_imp 'id -u') == 33 ]] || fail "the process is not UID 33 (www-data) inside: $(in_imp 'id -u')"
    caps=$(inspect '{{.EffectiveCaps}}')
    [[ $caps == "[]" ]] || fail "capabilities left: $caps"
    inspect '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' || fail "no-new-privileges is not set"
    [[ $(inspect '{{.HostConfig.Memory}}') == 536870912 ]] || fail "memory limit: $(inspect '{{.HostConfig.Memory}}')"
    [[ $(inspect '{{.HostConfig.NanoCpus}}') == 1000000000 ]] || fail "CPU limit: $(inspect '{{.HostConfig.NanoCpus}}')"
    [[ $(inspect '{{.HostConfig.PidsLimit}}') == 200 ]] || fail "pids limit: $(inspect '{{.HostConfig.PidsLimit}}')"
    nets=$(networks_of "$name")
    [[ $nets == "$net " ]] || fail "networks: '$nets', expected only $net"
    # No named volume. The image declares an anonymous one (VOLUME in its Dockerfile): Podman
    # makes it on each start and, with --rm (Quadlet), removes it with the container. Its
    # names are kept to check that in 'destroyed' and 'restart'.
    vols=$(inspect '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}={{.Destination}} {{end}}{{end}}')
    for v in $vols; do
      [[ ${v%%=*} =~ ^[0-9a-f]{64}$ ]] || fail "it has a named volume: $v"
      echo "::notice title=Data Importer anonymous volume::${v#*=}"
    done
    tr ' ' '\n' <<<"$vols" | sed 's/=.*//' | grep . > "${RUNNER_TEMP:?}/ffimport-anon" || true
    env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
    for want in "FIREFLY_III_URL=http://$ff:8080" "VANITY_URL=http://127.0.0.1:$ff_port" \
                "FIREFLY_III_CLIENT_ID=$client_id" FALLBACK_LOCALE=es_ES LOG_CHANNEL=stdout LOG_LEVEL=notice \
                LOG_RETURN_JSON=false APP_DEBUG=false CAN_POST_AUTOIMPORT=false CAN_POST_FILES=false; do
      grep -qxF "$want" <<<"$env" || fail "the environment does not say $want"
    done
    if grep -Eq '^FIREFLY_III_ACCESS_TOKEN=.+' <<<"$env"; then fail "a personal access token is set"; fi
    # What the measurement of the limits starts from (R46): shown, never a failure.
    echo "::notice title=Data Importer resources::$("$as" podman stats --no-stream --format '{{.MemUsage}} mem, {{.PIDs}} processes' "$name")"
    ;;
  firefly)
    code=$(in_imp "curl -s -o /dev/null -w '%{http_code}' -m 10 http://$ff:8080/health") || true
    [[ $code == 200 ]] || fail "from the importer, $ff:8080/health answers '$code', expected 200"
    ;;
  pair)
    nets=$(networks_of "$ff")
    [[ " $nets" == *" $net "* ]] || fail "$ff is not on $net: '$nets'"
    ;;
  oauth)
    # Without a session, with the client ID of the inventory: it needs OAuth.
    got=$(curl -fsS "http://127.0.0.1:$port/token/validate") || fail "/token/validate does not answer"
    grep -q '"NEEDS_OAUTH"' <<<"$got" || fail "/token/validate says '$got', expected NEEDS_OAUTH"
    # /token sends the browser to Firefly's address on 127.0.0.1, with this client, its own
    # callback and PKCE.
    loc=$(curl -sS -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:$port/token") || fail "/token does not answer"
    [[ $loc == "http://127.0.0.1:$ff_port/oauth/authorize?"* ]] || fail "/token sends the browser to '$loc'"
    for want in "client_id=$client_id" "redirect_uri=http%3A%2F%2F127.0.0.1%3A$port%2Fcallback" \
                response_type=code code_challenge= code_challenge_method=S256; do
      [[ $loc == *"$want"* ]] || fail "the address of Firefly lacks $want: $loc"
    done
    # Firefly answers at that address and asks for its login first.
    got=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$loc") || fail "Firefly does not answer at $loc"
    [[ $got =~ ^302\ http://127\.0\.0\.1:$ff_port/login ]] || fail "Firefly answered '$got', expected a redirect to its login"
    ;;
  isolation)
    # Controls from the runner, so a failure below means isolation and not a broken runner.
    timeout 5 bash -c '</dev/tcp/1.1.1.1/443' || fail "control: the runner cannot reach 1.1.1.1:443"
    getent hosts example.com >/dev/null || fail "control: the runner cannot resolve example.com"
    host_ip=$(hostname -I | awk '{print $1}')
    python3 -m http.server 18998 --bind 0.0.0.0 >/dev/null 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null || true' EXIT
    sleep 1
    timeout 5 bash -c "</dev/tcp/$host_ip/18998" || fail "control: the runner cannot reach its own port 18998"
    in_imp "curl -s -o /dev/null -m 10 http://$ff:8080/health" || fail "control: the importer cannot reach $ff"
    if in_imp 'curl -s -o /dev/null -m 5 https://1.1.1.1' 2>/dev/null; then fail "the importer reached 1.1.1.1:443"; fi
    if in_imp 'getent hosts example.com' >/dev/null 2>&1; then fail "the importer resolved example.com"; fi
    if in_imp "curl -s -o /dev/null -m 5 http://$host_ip:18998" 2>/dev/null; then fail "the importer reached the host ($host_ip:18998)"; fi
    ;;
  launcher)
    [[ -f $launcher ]] || fail "no launcher at $launcher"
    desktop-file-validate "$launcher" || fail "the launcher is not a valid .desktop file"
    grep -qxF "Exec=xdg-open http://127.0.0.1:$port" "$launcher" || fail "the launcher does not open 127.0.0.1:$port: $(grep '^Exec=' "$launcher")"
    grep -qx "Name=Firefly Importer ($instance)" "$launcher" || fail "the launcher is not named after its instance"
    ;;
  report)
    log=${2:?the log of playbooks/check.yml}
    grep -q "$name: en marcha, sano. Entrada: 127.0.0.1:$port->8080. Redes: $net\." "$log" \
      || fail "the report does not show $name running, healthy, only on 127.0.0.1:$port and on $net: $(grep "$name" "$log" | head -3)"
    if grep -A 50 '^ *SOBRA' "$log" | grep -q "ffimport-$instance"; then fail "the report lists something of ffimport-$instance as left over"; fi
    ;;
  destroyed)
    if "$as" podman container exists "$name"; then fail "the container still exists"; fi
    if [[ -e $launcher ]]; then fail "the launcher is still installed"; fi
    anon_gone
    ;;
  restart)
    # What you upload goes when it restarts: a new container, and the old anonymous volume gone.
    old=$(inspect '{{.Id}}')
    "$as" systemctl --user restart "$name.service"
    for _ in $(seq 1 60); do "$as" podman healthcheck run "$name" >/dev/null 2>&1 && break; sleep 2; done
    "$as" podman healthcheck run "$name" >/dev/null || fail "$name is not healthy after a restart"
    [[ $(inspect '{{.Id}}') != "$old" ]] || fail "the restart kept the same container"
    anon_gone
    ;;
  no-pair)
    nets=$(networks_of "$ff")
    [[ " $nets" != *" $net "* ]] || fail "$ff is still on $net"
    if "$as" podman network exists "$net"; then fail "the network $net is still there"; fi
    ;;
  *) echo "usage: $0 running|standard|firefly|pair|oauth|isolation|launcher|report <log>|restart|destroyed|no-pair" >&2; exit 2 ;;
esac
echo "ok: $step"
