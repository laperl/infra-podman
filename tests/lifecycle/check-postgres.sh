#!/usr/bin/env bash
# What the operator would check by hand on dev-pg-main. Usage: check-postgres.sh <step>
#   running   healthy, no published ports, labels, starts at boot, secret not exposed
#   standard  the instance follows docs/POSTGRES.md: fixed parameters, hardening, backup
#             role, no schema public, pg_hba.conf (R34-R36)
#   write     create a marker row
#   read      the marker row is still there
#   destroyed container and unit gone, volume and its unit kept (SPEC 4.2)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
name=dev-pg-main
su=ci_admin  # fictitious superuser of tests/lifecycle/inventory.yml
home=$(getent passwd svc_runner | cut -d: -f6)
units=$home/.config/containers/systemd
fail() { echo "::error title=check-postgres::$*"; exit 1; }
sql() { # sql <query> [database] [role]: through the socket inside the container
  "$as" podman exec "$name" psql -X -U "${3:-$su}" -d "${2:-postgres}" -v ON_ERROR_STOP=1 -tAq -c "$1"
}
refused() { # refused <what> <query> <database> <role>: the statement must fail
  if sql "$2" "$3" "$4" >/dev/null 2>&1; then fail "$1 was allowed"; fi
}
tcp_rejected() { # tcp_rejected <role>: pg_hba.conf rejects it over TCP, before any password
  local out
  if out=$("$as" podman exec "$name" psql -X -w -h 127.0.0.1 -U "$1" -d postgres -c 'SELECT 1' 2>&1); then
    fail "$1 logged in over TCP"
  fi
  grep -q 'pg_hba.conf rejects connection' <<<"$out" || fail "$1 over TCP failed for another reason: $out"
}

case $1 in
  running)
    "$as" podman healthcheck run "$name" || fail "$name is not healthy"
    [[ -z $("$as" podman port "$name") ]] || fail "$name publishes ports (SPEC 4.4)"
    ! ss -tlnH | grep -q ':5432 ' || fail "something listens on 5432 on the host"
    [[ $("$as" podman inspect "$name" --format '{{.HostConfig.NetworkMode}}') == none ]] || fail "$name is not on Network=none"
    for label in infra.env=dev infra.app=pg-main infra.component=db infra.managed-by=infra-podman; do
      "$as" podman ps --filter "label=$label" --format '{{.Names}}' | grep -qx "$name" || fail "missing label $label"
    done
    "$as" podman volume ls --filter label=infra.component=data --format '{{.Name}}' | grep -qx "$name-data" \
      || fail "volume $name-data missing or unlabelled"
    "$as" test -e "/run/user/$(id -u svc_runner)/systemd/generator/default.target.wants/$name.service" \
      || fail "$name.service is not wanted by default.target: it would not start at boot"
    if "$as" podman inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q '^POSTGRES_PASSWORD='; then
      fail "the password is in the container configuration; it must only be a file (SPEC 4.5)"
    fi
    echo "::notice title=PostgreSQL::$(sql 'SHOW server_version'), pgvector $(sql "SELECT default_version FROM pg_available_extensions WHERE name = 'vector'")"
    ;;
  standard)
    # R34: fixed at creation. provider|locale|collate|ctype|encoding|checksums|timezone|log_timezone
    got=$(sql "SELECT concat_ws('|', datlocprovider, datlocale, datcollate, datctype, pg_encoding_to_char(encoding),
      current_setting('data_checksums'), current_setting('TimeZone'), current_setting('log_timezone'))
      FROM pg_database WHERE datname = 'postgres'")
    [[ $got == 'b|C.UTF-8|C.UTF-8|C.UTF-8|UTF8|on|UTC|UTC' ]] || fail "instance parameters: $got"
    [[ $(sql "SELECT rolsuper FROM pg_roles WHERE rolname = current_user") == t ]] || fail "$su is not the superuser"
    [[ $(sql "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres'") == 0 ]] || fail "a role postgres exists"
    [[ $(sql "SHOW hba_file") == /etc/postgresql/pg_hba.conf ]] || fail "pg_hba.conf is not the generated one"
    [[ $(sql "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL") == 0 ]] || fail "pg_hba.conf has errors"
    echo "::notice title=PostgreSQL instance::$got"

    # Hardening: read-only root, the five capabilities only, no new privileges.
    [[ $("$as" podman inspect "$name" --format '{{.HostConfig.ReadonlyRootfs}}') == true ]] || fail "root filesystem is writable"
    if "$as" podman exec "$name" touch /usr/lifecycle-probe 2>/dev/null; then fail "could write to /usr"; fi
    # CHOWN(0) DAC_OVERRIDE(1) FOWNER(3) SETGID(6) SETUID(7) = 0xcb
    "$as" podman exec "$name" grep -q '^CapBnd:[[:space:]]*00000000000000cb$' /proc/1/status \
      || fail "capability bounding set: $("$as" podman exec "$name" grep CapBnd /proc/1/status)"
    "$as" podman exec "$name" grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/1/status || fail "NoNewPrivs is not set"

    # Database postgres and template1: only the superuser and backup connect, no schema public.
    [[ $(sql "SELECT has_database_privilege('public', 'postgres', 'CONNECT')") == f ]] || fail "PUBLIC may connect to postgres"
    for db in postgres template1; do
      [[ $(sql "SELECT count(*) FROM pg_namespace WHERE nspname = 'public'" "$db") == 0 ]] || fail "schema public in $db"
    done
    [[ $(sql "SELECT count(*) FROM pg_extension WHERE extname = 'vector'") == 0 ]] || fail "vector installed in postgres"

    # backup: logs in through the socket, reads everything, writes nothing (docs/POSTGRES.md).
    [[ $(sql "SELECT rolcanlogin AND NOT rolsuper AND rolpassword IS NULL FROM pg_authid WHERE rolname = 'backup'") == t ]] \
      || fail "backup is not a LOGIN role without password"
    sql "CREATE SCHEMA IF NOT EXISTS lifecycle_probe; CREATE TABLE IF NOT EXISTS lifecycle_probe.t (v text);
      TRUNCATE lifecycle_probe.t; INSERT INTO lifecycle_probe.t VALUES ('x');"
    [[ $(sql "SELECT v FROM lifecycle_probe.t" postgres backup) == x ]] || fail "backup cannot read"
    refused "INSERT by backup" "INSERT INTO lifecycle_probe.t VALUES ('y')" postgres backup
    refused "UPDATE by backup" "UPDATE lifecycle_probe.t SET v = 'y'" postgres backup
    refused "DELETE by backup" "DELETE FROM lifecycle_probe.t" postgres backup
    refused "CREATE TABLE by backup" "CREATE TABLE lifecycle_probe.u (v text)" postgres backup
    refused "CREATE DATABASE by backup" "CREATE DATABASE lifecycle_nope" postgres backup
    sql "DROP SCHEMA lifecycle_probe CASCADE"

    # A new database is born without public, and vector works in its own schema (phase 2).
    sql "DROP DATABASE IF EXISTS lifecycle_app"
    sql "CREATE DATABASE lifecycle_app"
    [[ $(sql "SELECT count(*) FROM pg_namespace WHERE nspname = 'public'" lifecycle_app) == 0 ]] \
      || fail "a new database has the schema public"
    sql "CREATE SCHEMA app; CREATE EXTENSION vector SCHEMA app; SELECT '[1,2]'::app.vector;" lifecycle_app >/dev/null
    sql "DROP DATABASE lifecycle_app"

    # pg_hba.conf: over TCP the superuser, backup and anyone else are rejected.
    tcp_rejected "$su"
    tcp_rejected backup
    tcp_rejected nobody
    ;;
  write)
    sql "CREATE SCHEMA IF NOT EXISTS lifecycle; CREATE TABLE IF NOT EXISTS lifecycle.marker (v text);
      INSERT INTO lifecycle.marker VALUES ('kept');"
    ;;
  read)
    [[ $(sql "SELECT v FROM lifecycle.marker") == kept ]] || fail "the data did not survive"
    ;;
  destroyed)
    ! "$as" podman container exists "$name" || fail "the container still exists"
    ! "$as" test -e "$units/$name.container" || fail "$name.container is still installed"
    "$as" podman volume exists "$name-data" || fail "the volume was removed (SPEC 4.2: never without purge)"
    "$as" test -e "$units/$name-data.volume" || fail "$name-data.volume was removed"
    ;;
  *) echo "usage: $0 running|standard|write|read|destroyed" >&2; exit 2 ;;
esac
echo "ok: $1"
