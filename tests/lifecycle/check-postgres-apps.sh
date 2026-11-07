#!/usr/bin/env bash
# Application databases on dev-pg-main (docs/POSTGRES.md, sections 2 and 3), as declared in
# tests/lifecycle/apps-vars.yml. Usage: check-postgres-apps.sh <step>
#   networks   one internal, isolated network per consumer, no ports, pg_hba.conf per user
#   catalog    groups, users, database, schema and settings as the model says
#   access     R35 and R36 over TCP, from throwaway containers on each network
#   isolation  no way out: not to the internet, the host, or another consumer's network
#   password   <user>: the password of that user is the one in its secret
#   none       back without consumers: Network=none, the data kept
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
name=dev-pg-main
su=ci_admin  # fictitious superuser of tests/lifecycle/inventory.yml
demo_net=dev-demo-pg-main-net
ai_net=dev-ai-pg-main-net
fail() { local m="$*"; echo "::error title=check-postgres-apps::${m//$'\n'/ | }"; exit 1; }
sql() { # sql <query> [database]: as the superuser, through the socket
  "$as" podman exec "$name" psql -X -U "$su" -d "${2:-postgres}" -v ON_ERROR_STOP=1 -tAq -c "$1" </dev/null
}
image() { "$as" podman inspect "$name" --format '{{.ImageName}}'; }
client() { # client <network> <user> <query>: psql over TCP from a container on that network
  "$as" podman --log-level=error run --rm --network "$1" --secret "dev-pg-main-$2-password,type=env,target=PGPASSWORD" \
    --entrypoint psql "$(image)" -X -h "$name" -U "$2" -d demo -v ON_ERROR_STOP=1 -tAq -c "$3" </dev/null
}
allowed() { # allowed <what> <network> <user> <query>: its output in $out
  out=$(client "$2" "$3" "$4" 2>&1) || fail "$1 was refused: $out"
}
refused() { # refused <what> <network> <user> <query> <expected message>
  local out
  if out=$(client "$2" "$3" "$4" 2>&1); then fail "$1 was allowed"; fi
  grep -q "$5" <<<"$out" || fail "$1 failed for another reason: $out"
}
on_net() { # on_net <network> <bash command>: run it in a throwaway container on that network
  "$as" podman --log-level=error run --rm --network "$1" --entrypoint bash "$(image)" -c "$2" </dev/null
}

case $1 in
  networks)
    # shellcheck disable=SC2016  # a Go template, not shell
    got=$("$as" podman inspect "$name" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
    [[ $(tr ' ' '\n' <<<"$got" | grep . | sort | tr '\n' ' ') == "$ai_net $demo_net " ]] \
      || fail "$name is on these networks: '$got' (expected $ai_net and $demo_net)"
    [[ -z $("$as" podman port "$name") ]] || fail "$name publishes ports (SPEC 4.4)"
    home=$(getent passwd svc_runner | cut -d: -f6)
    for net in "$demo_net" "$ai_net"; do
      [[ $("$as" podman network inspect "$net" --format '{{.Internal}} {{index .Options "isolate"}}') == 'true true' ]] \
        || fail "$net is not internal with isolate=true (D9)"
      for label in infra.env=dev infra.app=pg-main infra.component=net infra.managed-by=infra-podman; do
        # Captured first: with pipefail, grep -q closing early can fail podman with SIGPIPE.
        nets=$("$as" podman network ls --filter "label=$label" --format '{{.Name}}')
        grep -qx "$net" <<<"$nets" || fail "$net: missing label $label"
      done
    done
    demo_subnet=$("$as" podman network inspect "$demo_net" --format '{{range .Subnets}}{{.Subnet}}{{end}}')
    ai_subnet=$("$as" podman network inspect "$ai_net" --format '{{range .Subnets}}{{.Subnet}}{{end}}')
    [[ $demo_subnet != "$ai_subnet" ]] || fail "both networks got the same subnet"
    hba=$("$as" cat "$home/.config/infra-podman/$name/pg_hba.conf")
    for line in "\"demo\"  \"demo_app\"  $demo_subnet  scram-sha-256" "\"demo\"  \"demo_rw\"  $demo_subnet  scram-sha-256" \
                "\"demo\"  \"demo_ro\"  $demo_subnet  scram-sha-256" "\"demo\"  \"demo_ai\"  $ai_subnet  scram-sha-256"; do
      grep -qF "host    $line" <<<"$hba" || fail "pg_hba.conf has no line '$line'"
    done
    [[ $(sql "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL") == 0 ]] || fail "pg_hba.conf has errors"
    echo "::notice title=Consumer networks::$demo_net $demo_subnet, $ai_net $ai_subnet (chosen by Podman)"
    ;;
  catalog)
    for g in owner writer reader; do
      [[ $(sql "SELECT rolcanlogin FROM pg_roles WHERE rolname = 'demo_$g'") == f ]] || fail "demo_$g missing or with LOGIN"
    done
    for pair in demo_app:demo_owner demo_rw:demo_writer demo_ro:demo_reader demo_ai:demo_reader; do
      user=${pair%%:*} group=${pair#*:}
      [[ $(sql "SELECT string_agg(g.rolname, ',') FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = '$user'") == "$group" ]] \
        || fail "$user is not a member of $group only"
      [[ $(sql "SELECT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls
                AND rolpassword LIKE 'SCRAM-SHA-256\$%' FROM pg_authid WHERE rolname = '$user'") == t ]] \
        || fail "$user: not a plain LOGIN role with a SCRAM password"
    done
    [[ $(sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'demo'") == demo_owner ]] || fail "demo is not owned by demo_owner"
    [[ $(sql "SELECT has_database_privilege('public', 'demo', 'CONNECT')") == f ]] || fail "PUBLIC may connect to demo"
    [[ $(sql "SELECT has_database_privilege('backup', 'demo', 'CONNECT')") == t ]] || fail "backup may not connect to demo"
    [[ $(sql "SELECT count(*) FROM pg_namespace WHERE nspname = 'public'" demo) == 0 ]] || fail "schema public in demo"
    [[ $(sql "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'demo'" demo) == demo_owner ]] || fail "schema demo not owned by demo_owner"
    [[ $(sql "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'" demo) == demo ]] \
      || fail "vector is not in the schema demo"
    [[ $(sql "SELECT array_to_string(setconfig, ',') FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
              WHERE r.rolname = 'demo_app'") == 'search_path=demo,role=demo_owner' ]] || fail "demo_app does not work as demo_owner in demo"
    ;;
  access)
    # R35: the user of _owner creates as _owner, without the application doing anything.
    allowed "SET role of demo_app" "$demo_net" demo_app "SELECT session_user || ' as ' || current_user"
    [[ $out == 'demo_app as demo_owner' ]] || fail "demo_app does not become demo_owner on connecting (got: $out)"
    allowed "CREATE TABLE by demo_app" "$demo_net" demo_app \
      "CREATE TABLE IF NOT EXISTS probe (id serial PRIMARY KEY, v text, e vector(2));
       CREATE OR REPLACE FUNCTION probe_write() RETURNS void LANGUAGE sql SECURITY DEFINER
         AS \$\$ INSERT INTO probe (v) VALUES ('by function') \$\$;
       TRUNCATE probe; INSERT INTO probe (v, e) VALUES ('by owner', '[1,2]')"
    [[ $(sql "SELECT tableowner FROM pg_tables WHERE schemaname = 'demo' AND tablename = 'probe'" demo) == demo_owner ]] \
      || fail "the table created by demo_app is not owned by demo_owner (R35)"
    # _writer: data yes, structure no.
    allowed "INSERT by demo_rw" "$demo_net" demo_rw "INSERT INTO probe (v) VALUES ('by writer')"
    allowed "UPDATE by demo_rw" "$demo_net" demo_rw "UPDATE probe SET v = 'updated' WHERE v = 'by writer'"
    allowed "DELETE by demo_rw" "$demo_net" demo_rw "DELETE FROM probe WHERE v = 'updated'"
    allowed "a function, by demo_rw" "$demo_net" demo_rw "SELECT probe_write()"
    refused "CREATE TABLE by demo_rw" "$demo_net" demo_rw "CREATE TABLE nope (v text)" 'permission denied'
    refused "TRUNCATE by demo_rw" "$demo_net" demo_rw "TRUNCATE probe" 'permission denied'
    # _reader: reads, and nothing else at all (R36).
    for reader in demo_ro:"$demo_net" demo_ai:"$ai_net"; do
      user=${reader%%:*} net=${reader#*:}
      allowed "SELECT by $user" "$net" "$user" "SELECT count(*) FROM probe"
      [[ $out -ge 2 ]] || fail "$user reads $out rows, expected at least 2"
      allowed "vector search by $user" "$net" "$user" "SELECT e <-> '[2,3]' FROM probe WHERE e IS NOT NULL"
      refused "INSERT by $user" "$net" "$user" "INSERT INTO probe (v) VALUES ('r')" 'permission denied'
      refused "UPDATE by $user" "$net" "$user" "UPDATE probe SET v = 'r'" 'permission denied'
      refused "DELETE by $user" "$net" "$user" "DELETE FROM probe" 'permission denied'
      refused "TRUNCATE by $user" "$net" "$user" "TRUNCATE probe" 'permission denied'
      refused "nextval by $user" "$net" "$user" "SELECT nextval('probe_id_seq')" 'permission denied'
      refused "a SECURITY DEFINER function, by $user" "$net" "$user" "SELECT probe_write()" 'permission denied'
      refused "CREATE TABLE by $user" "$net" "$user" "CREATE TABLE nope (v text)" 'permission denied'
    done
    # pg_hba.conf: each user only from its consumer's network, only to its database.
    refused "demo_app from the network of ai" "$ai_net" demo_app "SELECT 1" 'pg_hba.conf'
    refused "demo_ai from the network of demo" "$demo_net" demo_ai "SELECT 1" 'pg_hba.conf'
    if out=$("$as" podman --log-level=error run --rm --network "$demo_net" --secret dev-pg-main-demo_app-password,type=env,target=PGPASSWORD \
               --entrypoint psql "$(image)" -X -h "$name" -U demo_app -d postgres -c 'SELECT 1' </dev/null 2>&1); then
      fail "demo_app connected to the database postgres"
    fi
    grep -q 'pg_hba.conf' <<<"$out" || fail "demo_app to postgres failed for another reason: $out"
    ;;
  isolation)
    # Controls: from the runner itself the internet and a local port do answer, so a
    # failure below means isolation and not a broken runner.
    timeout 5 bash -c '</dev/tcp/1.1.1.1/443' || fail "control: the runner cannot reach 1.1.1.1:443"
    getent hosts example.com >/dev/null || fail "control: the runner cannot resolve example.com"
    host_ip=$(hostname -I | awk '{print $1}')
    python3 -m http.server 18999 --bind 0.0.0.0 >/dev/null 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null || true' EXIT
    sleep 1
    timeout 5 bash -c "</dev/tcp/$host_ip/18999" || fail "control: the runner cannot reach its own port 18999"
    # A container of the ai network, and the address of PostgreSQL in that network.
    "$as" podman run -d --rm --name lifecycle-ai-probe --network "$ai_net" --entrypoint sleep "$(image)" 120 >/dev/null
    pg_ai_ip=$("$as" podman inspect "$name" --format "{{(index .NetworkSettings.Networks \"$ai_net\").IPAddress}}")
    probe_ip=$("$as" podman inspect lifecycle-ai-probe --format "{{(index .NetworkSettings.Networks \"$ai_net\").IPAddress}}")
    for where in "from the network of demo:on_net $demo_net" "from PostgreSQL:pg"; do
      label=${where%%:*} how=${where#*:}
      run() { if [[ $how == pg ]]; then "$as" podman exec "$name" bash -c "$1" </dev/null; else on_net "${how#on_net }" "$1"; fi; }
      if run 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' 2>/dev/null; then fail "$label: reached 1.1.1.1:443"; fi
      if run 'getent hosts example.com' >/dev/null 2>&1; then fail "$label: resolved example.com"; fi
      if run "timeout 5 bash -c '</dev/tcp/$host_ip/18999'" 2>/dev/null; then fail "$label: reached the host ($host_ip:18999)"; fi
    done
    if on_net "$demo_net" "timeout 5 bash -c '</dev/tcp/$pg_ai_ip/5432'" 2>/dev/null; then
      fail "from the network of demo: reached PostgreSQL through the network of ai ($pg_ai_ip)"
    fi
    if on_net "$demo_net" "timeout 5 bash -c '</dev/tcp/$probe_ip/5432'; getent hosts lifecycle-ai-probe" >/dev/null 2>&1; then
      fail "from the network of demo: reached or resolved a container of the network of ai"
    fi
    "$as" podman stop -t 0 lifecycle-ai-probe >/dev/null
    ;;
  password)
    allowed "login of $2 with its secret" "$demo_net" "$2" "SELECT 1"
    ;;
  none)
    [[ $("$as" podman inspect "$name" --format '{{.HostConfig.NetworkMode}}') == none ]] || fail "$name is not back on Network=none"
    [[ $(sql "SELECT count(*) FROM probe" demo) -ge 2 ]] || fail "the data of demo was not kept"
    home=$(getent passwd svc_runner | cut -d: -f6)
    if "$as" grep -q 'demo_' "$home/.config/infra-podman/$name/pg_hba.conf"; then fail "pg_hba.conf still admits the users"; fi
    ;;
  *) echo "usage: $0 networks|catalog|access|isolation|password <user>|none" >&2; exit 2 ;;
esac
echo "ok: $1"
