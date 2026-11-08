#!/usr/bin/env bash
# Firefly III on the runner (docs/services/firefly.md), as deployed by the firefly job with
# tests/lifecycle/firefly-vars.yml. Usage: check-firefly.sh <step>
#   running    healthy, published only on 127.0.0.1:18001, /health and the login page answer
#   standard   hardening, limits, one network, secrets as files, the time zone
#   schema     its tables in the schema firefly, owned by firefly_owner, nothing in public
#   reader     firefly_ro (firefly_reader) reads Firefly's tables and cannot change them
#   isolation  no way out: not to the internet, the host, or the network of demo
#   cron       the scheduled tasks run inside the container, from their service
#   launcher   the operator's .desktop file is valid and opens 127.0.0.1:18001
#   wait       with PostgreSQL unhealthy it does not start, within its timeout (SPEC 4.3)
#   marker     write | read: a file in the attachments volume and the migrations row count
#   destroyed  container, timer and launcher gone; the volume kept (SPEC 4.2)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
name=dev-firefly
pg=dev-pg-main
su=ci_admin  # fictitious superuser of tests/lifecycle/inventory.yml
net=dev-firefly-pg-main-net
demo_net=dev-demo-pg-main-net
ai_net=dev-ai-pg-main-net
port=18001
launcher=$HOME/.local/share/applications/infra-podman-$name.desktop
state=${RUNNER_TEMP:-/tmp}/firefly-marker
fail() { local m="$*"; echo "::error title=check-firefly::${m//$'\n'/ | }"; exit 1; }
sql() { # sql <query> [database]: as the superuser, through the socket
  "$as" podman exec "$pg" psql -X -U "$su" -d "${2:-firefly}" -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
}
inspect() { "$as" podman inspect "$name" --format "$1"; }
in_ff() { "$as" podman exec "$name" bash -c "$1" </dev/null; }
pg_image() { "$as" podman inspect "$pg" --format '{{.ImageName}}'; }
healthy() { # healthy <seconds>
  local i
  for ((i = 0; i < $1; i += 5)); do
    "$as" podman healthcheck run "$name" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

case ${1:-} in
  running)
    [[ $("$as" systemctl --user is-active "$name.service") == active ]] || fail "$name.service is not active"
    "$as" podman healthcheck run "$name" >/dev/null || fail "$name is not healthy"
    ports=$("$as" podman port "$name")
    [[ $ports == "8080/tcp -> 127.0.0.1:$port" ]] || fail "published ports: '$ports', expected only 127.0.0.1:$port"
    body=$(curl -fsS "http://127.0.0.1:$port/health") || fail "/health does not answer on 127.0.0.1:$port"
    [[ $body == OK ]] || fail "/health says '$body'"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/login")
    [[ $code == 200 ]] || fail "the login page answers $code"
    host_ip=$(hostname -I | awk '{print $1}')
    if timeout 5 bash -c "</dev/tcp/$host_ip/$port" 2>/dev/null; then fail "port $port answers on $host_ip"; fi
    ;;
  standard)
    [[ $(inspect '{{.Config.User}}') == www-data ]] || fail "not running as www-data: $(inspect '{{.Config.User}}')"
    caps=$(inspect '{{.EffectiveCaps}}')
    [[ $caps == "[]" ]] || fail "capabilities left: $caps"
    inspect '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' || fail "no-new-privileges is not set"
    [[ $(inspect '{{.HostConfig.Memory}}') == 536870912 ]] || fail "memory limit: $(inspect '{{.HostConfig.Memory}}')"
    [[ $(inspect '{{.HostConfig.NanoCpus}}') == 1000000000 ]] || fail "CPU limit: $(inspect '{{.HostConfig.NanoCpus}}')"
    [[ $(inspect '{{.HostConfig.PidsLimit}}') == 200 ]] || fail "pids limit: $(inspect '{{.HostConfig.PidsLimit}}')"
    # shellcheck disable=SC2016  # a Go template, not a shell expansion
    nets=$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
    [[ $nets == "$net " ]] || fail "networks: '$nets', expected only $net"
    inspect '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' | grep -q "$name-upload:/var/www/html/storage/upload" \
      || fail "the attachments volume is not mounted"
    env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
    if grep -Eq '^(APP_KEY|DB_PASSWORD)=' <<<"$env"; then fail "a secret is in the environment, not in a file"; fi
    grep -qx 'DB_PASSWORD_FILE=/run/secrets/db-password' <<<"$env" || fail "DB_PASSWORD_FILE is not set"
    [[ $(in_ff 'stat -c %U:%a /run/secrets/db-password') == www-data:400 ]] || fail "the secret file is not www-data, 0400"
    grep -qx 'TZ=Europe/Madrid' <<<"$env" || fail "TZ is not the one of the inventory (Europe/Madrid)"
    # What the measurement of the limits starts from (R46): shown, never a failure.
    echo "::notice title=Firefly resources::$("$as" podman stats --no-stream --format '{{.MemUsage}} mem, {{.PIDs}} processes' "$name")"
    ;;
  schema)
    n=$(sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'firefly'")
    [[ $n -gt 20 ]] || fail "only $n tables in the schema firefly"
    others=$(sql "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('firefly', 'pg_catalog', 'information_schema')")
    [[ $others == 0 ]] || fail "$others tables outside the schema firefly"
    owners=$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'firefly'")
    [[ $owners == firefly_owner ]] || fail "tables owned by '$owners', expected firefly_owner (R35)"
    [[ $(sql "SELECT to_regclass('firefly.users') IS NOT NULL") == t ]] || fail "no table firefly.users"
    ;;
  reader)
    client() { # client <query>: as firefly_ro over TCP, from the network of ai
      "$as" podman --log-level=error run --rm --network "$ai_net" \
        --secret dev-pg-main-firefly_ro-password,type=env,target=PGPASSWORD --entrypoint psql "$(pg_image)" \
        -X -h "$pg" -U firefly_ro -d firefly -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
    }
    out=$(client "SELECT count(*) FROM users" 2>&1) || fail "firefly_ro cannot read users: $out"
    if out=$(client "DELETE FROM migrations" 2>&1); then fail "firefly_ro deleted rows"; fi
    grep -q 'permission denied' <<<"$out" || fail "the delete failed for another reason: $out"
    if out=$(client "CREATE TABLE lifecycle_t (n int)" 2>&1); then fail "firefly_ro created a table"; fi
    grep -q 'permission denied' <<<"$out" || fail "the create failed for another reason: $out"
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
    # The network of demo: PostgreSQL's address there, and another container in it.
    "$as" podman run -d --rm --name lifecycle-demo-probe --network "$demo_net" --entrypoint sleep "$(pg_image)" 120 >/dev/null
    pg_demo_ip=$("$as" podman inspect "$pg" --format "{{(index .NetworkSettings.Networks \"$demo_net\").IPAddress}}")
    probe_ip=$("$as" podman inspect lifecycle-demo-probe --format "{{(index .NetworkSettings.Networks \"$demo_net\").IPAddress}}")
    if in_ff "timeout 5 bash -c '</dev/tcp/$pg_demo_ip/5432'" 2>/dev/null; then
      fail "Firefly reached PostgreSQL through the network of demo ($pg_demo_ip)"
    fi
    if in_ff "timeout 5 bash -c '</dev/tcp/$probe_ip/5432'; getent hosts lifecycle-demo-probe" >/dev/null 2>&1; then
      fail "Firefly reached or resolved a container of the network of demo"
    fi
    "$as" podman stop -t 0 lifecycle-demo-probe >/dev/null
    ;;
  cron)
    [[ $("$as" systemctl --user is-active "$name-cron.timer") == active ]] || fail "$name-cron.timer is not active"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    "$as" systemctl --user start "$name-cron.service" || fail "the scheduled tasks failed: $(sudo journalctl _SYSTEMD_USER_UNIT="$name-cron.service" --since "$since" --no-pager | tail -5)"
    [[ $("$as" systemctl --user show -p Result --value "$name-cron.service") == success ]] || fail "the scheduled tasks did not end well"
    ;;
  launcher)
    [[ -f $launcher ]] || fail "no launcher at $launcher"
    desktop-file-validate "$launcher" || fail "the launcher is not a valid .desktop file"
    grep -qx "Exec=xdg-open http://127.0.0.1:$port" "$launcher" || fail "the launcher does not open 127.0.0.1:$port"
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
    # systemctl says: Job for dev-firefly.service failed because a timeout was exceeded.
    grep -q 'timeout' <<<"$out" || fail "Firefly failed to start for another reason: $out"
    ((took >= 55 && took <= 100)) || fail "Firefly gave up after $took s, expected its TimeoutStartSec (60 s)"
    # Restart=on-failure: once PostgreSQL is healthy again, it starts by itself.
    healthy 240 || fail "Firefly did not start by itself once PostgreSQL was healthy again"
    echo "::notice title=Wait for PostgreSQL (SPEC 4.3)::gave up after $took s with PostgreSQL paused; started by itself after"
    ;;
  marker)
    case ${2:-} in
      write)
        in_ff 'echo lifecycle > /var/www/html/storage/upload/lifecycle-marker'
        sql "SELECT count(*) FROM migrations" > "$state"
        ;;
      read)
        [[ $(in_ff 'cat /var/www/html/storage/upload/lifecycle-marker') == lifecycle ]] || fail "the attachments volume lost its file"
        [[ $(sql "SELECT count(*) FROM migrations") == "$(cat "$state")" ]] || fail "the database changed"
        ;;
      *) fail "usage: marker write|read" ;;
    esac
    ;;
  destroyed)
    if "$as" podman container exists "$name"; then fail "the container still exists"; fi
    "$as" podman volume exists "$name-upload" || fail "the attachments volume was removed"
    home=$(getent passwd svc_runner | cut -d: -f6)
    if sudo test -e "$home/.config/systemd/user/$name-cron.timer"; then fail "the timer is still installed"; fi
    if [[ -e $launcher ]]; then fail "the launcher is still installed"; fi
    ;;
  *)
    echo "usage: $0 running|standard|schema|reader|isolation|cron|launcher|wait|marker|destroyed" >&2
    exit 2
    ;;
esac
echo "ok: $1"
