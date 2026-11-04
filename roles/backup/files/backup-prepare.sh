#!/usr/bin/env bash
# ExecStartPre of <env>-backup.service, on the host, as the service user (SPEC 4.11).
# Fills the staging directory with what the restic container backs up, as
# <app>/<type>/<name>/, following backup.conf:
#   pg   <app> <container>    pg_dump of every database, one by one, as the read-only
#                             role backup through the socket (docs/POSTGRES.md), and the
#                             roles without passwords (they live in KeePassXC)
#   file <app> <name> <path>  a copy of that file
# On failure the reason goes to prepare-error, for backup-status.sh and the notifier.
set -euo pipefail

state=$HOME/.local/state/infra-podman/backup
staging=$state/staging
conf=$HOME/.config/infra-podman/backup/backup.conf
error_file=$state/prepare-error

mkdir -p "$state"
rm -f "$error_file"
fail() {
  echo "backup-prepare: ERROR: $*" >&2
  printf '%s\n' "$*" >"$error_file"
  exit 1
}

[[ -r $conf ]] || fail "falta $conf. Vuelve a aplicar el playbook backup."
rm -rf "$staging"
mkdir "$staging"
chmod 700 "$staging"
umask 077

dump_instance() { # dump_instance <app> <container>
  local app=$1 container=$2 running dbs db dir
  running=$(podman container inspect --format '{{.State.Running}}' "$container" 2>/dev/null) || running=false
  [[ $running == true ]] || fail "$container no está en marcha: no se pueden volcar sus bases."
  dbs=$(podman exec "$container" psql -X -At -U backup -d postgres \
    -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1" </dev/null) \
    || fail "el rol backup no puede leer la lista de bases de $container."
  for db in $dbs; do
    dir=$staging/$app/pgdump/$db
    mkdir -p "$dir"
    echo "backup-prepare: $app: pg_dump $db"
    podman exec "$container" pg_dump -U backup -d "$db" --format=custom </dev/null >"$dir/$db.dump" \
      || fail "pg_dump de la base $db de $container ha fallado."
  done
  # _roles cannot collide with a database: application names start with a letter.
  dir=$staging/$app/pgdump/_roles
  mkdir -p "$dir"
  echo "backup-prepare: $app: roles"
  podman exec "$container" pg_dumpall -U backup --globals-only --no-role-passwords </dev/null >"$dir/roles.sql" \
    || fail "no se han podido volcar los roles de $container."
}

copy_file() { # copy_file <app> <name> <path>
  [[ -r $3 ]] || fail "no existe o no se puede leer $3. En el portátil, lo deja ahí deploy.sh tras cada ejecución correcta."
  mkdir -p "$staging/$1/files/$2"
  echo "backup-prepare: $1: $2"
  cp "$3" "$staging/$1/files/$2/"
}

while read -r kind app a b; do
  case $kind in
    '' | '#'*) continue ;;
    pg) dump_instance "$app" "$a" ;;
    file) copy_file "$app" "$a" "$b" ;;
    *) fail "línea desconocida en $conf: $kind" ;;
  esac
done <"$conf"

[[ -n $(ls -A "$staging") ]] || fail "no hay nada que copiar en $conf."
echo "backup-prepare: ready"
