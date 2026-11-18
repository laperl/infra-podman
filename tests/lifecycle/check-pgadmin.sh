#!/usr/bin/env bash
# pgAdmin 4 on the runner (docs/services/pgadmin.md), the instance ci as deployed by the
# pgadmin job (tests/lifecycle/pgadmin-vars.yml): 127.0.0.1:18102, administering pg-main.
# Usage: check-pgadmin.sh <step>
#   running    healthy, published only on 127.0.0.1:18102, /misc/ping and the login page answer
#   standard   its user, hardening, read-only root, limits, its one network, the secret as a file
#   config     config_distro.py in its volume with the settings of the role (written on the
#              first start, with the root read-only), and nothing of it in the image
#   login      end to end: the e-mail of the inventory and the password of its secret open a
#              session, a wrong password does not
#   superuser  from pgAdmin, with the tools of its image, the superuser enters pg-main over TCP;
#              pg_hba.conf has one line for it, with the subnet of this pair, and rejects it
#              from anywhere else (R37)
#   no-superuser  pgAdmin no longer declared: that line and the network of the pair are gone
#   isolation  no way out: not to the internet, not to the host
#   launcher   the operator's .desktop file is valid and opens 127.0.0.1:18102
#   report     playbooks/check.yml shows it running and healthy, only on 127.0.0.1 (the log of
#              that playbook, the second word)
#   destroyed  container and launcher gone; volume kept (SPEC 4.2)
# The passwords are read from files of the runner, never written here: $RUNNER_TEMP/pgadmin-pw
# (its user) and $RUNNER_TEMP/pg-su-pw (the superuser of pg-main).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
step=${1:-}
instance=ci
port=18102
name=dev-pgadmin-$instance
volume=$name-data
pg=dev-pg-main
su=ci_admin                 # fictitious superuser of tests/lifecycle/pgadmin-vars.yml
email=admin@example.com     # fictitious e-mail of tests/lifecycle/pgadmin-vars.yml
net=dev-pgadmin-$instance-pg-main-net
launcher=$HOME/.local/share/applications/infra-podman-$name.desktop
fail() { local m="$*"; echo "::error title=check-pgadmin $step::${m//$'\n'/ | }"; exit 1; }
inspect() { "$as" podman inspect "$name" --format "$1"; }
# The image has no bash: sh, and its own python3 for what sh cannot do.
in_pa() { "$as" podman exec "$name" sh -c "$1" </dev/null; }
reach() { # reach <host> <port>: from pgAdmin, a TCP connection within 5 seconds
  in_pa "python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)' $1 $2" >/dev/null 2>&1
}
sql() { # sql <query>: as the superuser, through the socket of pg-main
  "$as" podman exec "$pg" psql -X -U "$su" -d postgres -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
}
# The lines of pg_hba.conf that let the superuser in with a password.
su_rules() { sql "SELECT address || '/' || netmask FROM pg_hba_file_rules WHERE '$su' = ANY(user_name) AND auth_method = 'scram-sha-256'"; }
subnet() { "$as" podman network inspect "$net" --format '{{range .Subnets}}{{.Subnet}}{{end}}'; }

case $step in
  running)
    [[ $("$as" systemctl --user is-active "$name.service") == active ]] || fail "$name.service is not active"
    "$as" podman healthcheck run "$name" >/dev/null || fail "$name is not healthy"
    ports=$("$as" podman port "$name")
    [[ $ports == "8080/tcp -> 127.0.0.1:$port" ]] || fail "published ports: '$ports', expected only 127.0.0.1:$port"
    body=$(curl -fsS "http://127.0.0.1:$port/misc/ping") || fail "/misc/ping does not answer on 127.0.0.1:$port"
    [[ $body == PING ]] || fail "/misc/ping says '$body'"
    got=$(curl -sL -o /dev/null -w '%{http_code} %{url_effective}' "http://127.0.0.1:$port/")
    [[ $got =~ ^200\ http://127\.0\.0\.1:$port/login ]] || fail "the start page does not lead to the login page: '$got'"
    host_ip=$(hostname -I | awk '{print $1}')
    if timeout 5 bash -c "</dev/tcp/$host_ip/$port" 2>/dev/null; then fail "port $port answers on $host_ip"; fi
    ;;
  standard)
    [[ $(inspect '{{.Config.User}}') =~ ^(pgadmin|5050)(:.*)?$ ]] || fail "not running as pgadmin: $(inspect '{{.Config.User}}')"
    [[ $(in_pa 'id -u') == 5050 ]] || fail "the process is not UID 5050 inside: $(in_pa 'id -u')"
    caps=$(inspect '{{.EffectiveCaps}}')
    [[ $caps == "[]" ]] || fail "capabilities left: $caps"
    inspect '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' || fail "no-new-privileges is not set"
    [[ $(inspect '{{.HostConfig.ReadonlyRootfs}}') == true ]] || fail "the root is not read-only"
    if in_pa 'touch /pgadmin4/probe' 2>/dev/null; then fail "it can write in /pgadmin4"; fi
    [[ $(inspect '{{.HostConfig.Memory}}') == 536870912 ]] || fail "memory limit: $(inspect '{{.HostConfig.Memory}}')"
    [[ $(inspect '{{.HostConfig.NanoCpus}}') == 1000000000 ]] || fail "CPU limit: $(inspect '{{.HostConfig.NanoCpus}}')"
    [[ $(inspect '{{.HostConfig.PidsLimit}}') == 256 ]] || fail "pids limit: $(inspect '{{.HostConfig.PidsLimit}}')"
    # shellcheck disable=SC2016  # a Go template, not a shell expansion
    nets=$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
    [[ $nets == "$net " ]] || fail "networks: '$nets', expected only $net"
    inspect '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' | grep -q "$volume:/var/lib/pgadmin" \
      || fail "its volume is not mounted on /var/lib/pgadmin"
    env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
    if grep -q '^PGADMIN_DEFAULT_PASSWORD=' <<<"$env"; then fail "the password is in the environment, not in a file"; fi
    grep -qx 'PGADMIN_DEFAULT_PASSWORD_FILE=/run/secrets/login-password' <<<"$env" || fail "PGADMIN_DEFAULT_PASSWORD_FILE is not set"
    grep -qx "PGADMIN_DEFAULT_EMAIL=$email" <<<"$env" || fail "the e-mail is not the one of the inventory"
    [[ $(in_pa 'stat -c %u:%a /run/secrets/login-password') == 5050:400 ]] || fail "the secret file is not 5050, 0400"
    [[ $(in_pa 'stat -c %u /var/lib/pgadmin') == 5050 ]] || fail "its volume is not owned by 5050 inside"
    # What the measurement of the limits starts from (R46): shown, never a failure.
    echo "::notice title=pgAdmin resources::$("$as" podman stats --no-stream --format '{{.MemUsage}} mem, {{.PIDs}} processes' "$name")"
    ;;
  config)
    file=/var/lib/pgadmin/config_distro.py
    content=$(in_pa "cat $file") || fail "no $file: with the root read-only the settings went nowhere"
    for setting in 'ALLOW_SAVE_PASSWORD = False' 'SHOW_GRAVATAR_IMAGE = False' \
                   'UPGRADE_CHECK_ENABLED = False' 'ENHANCED_COOKIE_PROTECTION = True' 'CONSOLE_LOG_LEVEL = 30'; do
      grep -qxF "$setting" <<<"$content" || fail "$file does not say '$setting': $(tr '\n' ';' <<<"$content")"
    done
    in_pa 'test -s /var/lib/pgadmin/pgadmin4.db' || fail "its own database is not in its volume"
    ;;
  login)
    pw_file=${RUNNER_TEMP:?}/pgadmin-pw
    python3 "$here/pgadmin-login.py" "http://127.0.0.1:$port" "$email" "$pw_file" \
      || fail "the e-mail and the password of its secret do not open a session"
    printf 'wrong-%s' "$RANDOM" > "$RUNNER_TEMP/pgadmin-bad"
    if python3 "$here/pgadmin-login.py" "http://127.0.0.1:$port" "$email" "$RUNNER_TEMP/pgadmin-bad" 2>/dev/null; then
      fail "a wrong password opened a session"
    fi
    rm -f "$RUNNER_TEMP/pgadmin-bad"
    ;;
  superuser)
    sn=$(subnet)
    [[ -n $sn ]] || fail "the network $net has no subnet"
    rules=$(su_rules)
    [[ $rules == "${sn%/*}/$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).netmask)' "$sn")" ]] \
      || fail "the superuser's lines with a password: '$rules', expected only $sn"
    # With the psql of its image, newest version first, the password through the environment.
    psql=$(in_pa 'ls -d /usr/local/pgsql-*/bin/psql | sort -V | tail -n 1') || fail "no psql in the image"
    out=$("$as" podman exec -e PGPASSWORD="$(cat "${RUNNER_TEMP:?}/pg-su-pw")" "$name" \
      "$psql" -X -w -h "$pg" -U "$su" -d postgres -tAc 'SELECT current_user, inet_server_addr() IS NOT NULL' 2>&1 </dev/null) \
      || fail "the superuser cannot enter $pg from pgAdmin: $out"
    [[ $out == "$su|t" ]] || fail "unexpected answer: $out"
    # From anywhere else, rejected by pg_hba.conf before any password (127.0.0.1 inside pg-main).
    if out=$("$as" podman exec "$pg" psql -X -w -h 127.0.0.1 -U "$su" -d postgres -c 'SELECT 1' 2>&1 </dev/null); then
      fail "the superuser logged in over TCP from outside the network of pgAdmin"
    fi
    grep -q 'pg_hba.conf rejects connection' <<<"$out" || fail "rejected for another reason: $out"
    ;;
  no-superuser)
    rules=$(su_rules)
    [[ -z $rules ]] || fail "pg_hba.conf still lets the superuser in from: $rules"
    if "$as" podman network exists "$net"; then fail "the network $net is still there"; fi
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
    reach "$pg" 5432 || fail "control: pgAdmin cannot reach $pg:5432"
    if reach 1.1.1.1 443; then fail "pgAdmin reached 1.1.1.1:443"; fi
    if in_pa "python3 -c 'import socket; socket.gethostbyname(\"example.com\")'" >/dev/null 2>&1; then
      fail "pgAdmin resolved example.com"
    fi
    if reach "$host_ip" 18998; then fail "pgAdmin reached the host ($host_ip:18998)"; fi
    ;;
  launcher)
    [[ -f $launcher ]] || fail "no launcher at $launcher"
    desktop-file-validate "$launcher" || fail "the launcher is not a valid .desktop file"
    grep -qxF "Exec=xdg-open http://127.0.0.1:$port" "$launcher" || fail "the launcher does not open 127.0.0.1:$port: $(grep '^Exec=' "$launcher")"
    grep -qx "Name=pgAdmin 4 ($instance)" "$launcher" || fail "the launcher is not named after its instance"
    ;;
  report)
    log=${2:?the log of playbooks/check.yml}
    grep -q "$name: en marcha, sano. Entrada: 127.0.0.1:$port->8080. Redes: $net\." "$log" \
      || fail "the report does not show $name running, healthy, only on 127.0.0.1:$port and on $net: $(grep "$name" "$log" | head -3)"
    if grep -A 50 '^ *SOBRA' "$log" | grep -q "pgadmin-$instance"; then fail "the report lists something of pgadmin-$instance as left over"; fi
    if grep -q "falta el secreto dev-pgadmin" "$log"; then fail "the report says its secret is missing"; fi
    ;;
  destroyed)
    if "$as" podman container exists "$name"; then fail "the container still exists"; fi
    "$as" podman volume exists "$volume" || fail "its volume was removed"
    if [[ -e $launcher ]]; then fail "the launcher is still installed"; fi
    ;;
  *) echo "usage: $0 running|standard|config|login|superuser|no-superuser|isolation|launcher|report <log>|destroyed" >&2; exit 2 ;;
esac
echo "ok: $step"
