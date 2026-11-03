#!/usr/bin/env bash
# What the operator would check by hand on dev-pg-main. Usage: check-postgres.sh <step>
#   running   healthy, no published ports, labels, starts at boot, secret not exposed
#   write     create a marker row (and the pgvector extension)
#   read      the marker row is still there
#   destroyed container and unit gone, volume and its unit kept (SPEC 4.2)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
name=dev-pg-main
home=$(getent passwd svc_runner | cut -d: -f6)
units=$home/.config/containers/systemd
fail() { echo "::error title=check-postgres::$*"; exit 1; }
sql() { "$as" podman exec "$name" psql -U postgres -tAq -c "$1"; }

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
  write)
    sql "CREATE EXTENSION IF NOT EXISTS vector; CREATE TABLE IF NOT EXISTS lifecycle_marker (v text); INSERT INTO lifecycle_marker VALUES ('kept');"
    ;;
  read)
    [[ $(sql "SELECT v FROM lifecycle_marker") == kept ]] || fail "the data did not survive"
    ;;
  destroyed)
    ! "$as" podman container exists "$name" || fail "the container still exists"
    ! "$as" test -e "$units/$name.container" || fail "$name.container is still installed"
    "$as" podman volume exists "$name-data" || fail "the volume was removed (SPEC 4.2: never without purge)"
    "$as" test -e "$units/$name-data.volume" || fail "$name-data.volume was removed"
    ;;
  *) echo "usage: $0 running|write|read|destroyed" >&2; exit 2 ;;
esac
echo "ok: $1"
