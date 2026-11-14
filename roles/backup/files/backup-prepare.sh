#!/usr/bin/env bash
# ExecStartPre of <env>-backup.service, on the host, as the service user (SPEC 4.11).
# Fills the staging directory with what the restic container backs up, as
# <app>/<type>/<name>/, following backup.conf and then every backup.d/*.conf, the items
# each application declares (roles/backup/tasks/app_items.yml):
#   pg     <app> <container>    pg_dump of every database, one by one, as the read-only
#                               role backup through the socket (docs/POSTGRES.md), and the
#                               roles without passwords (they live in KeePassXC)
#   file   <app> <name> <path>  a copy of that file
#   volume <app> <name> <volume>
#                               the whole volume as a tar, with `podman volume export`:
#                               it keeps owners and modes, and works with the container
#                               stopped. To restore: podman volume import
#   exec   <app> <name> <container> <command...>
#                               what that command prints, run inside the running
#                               container: the application's own tool to take its data
#                               out, or a tar of some of its directories
# The reason of the run is daily, or what the file next-reason says (tasks/run_now.yml
# writes pre-upgrade there before an image change); restic tags the snapshots with it.
# On failure the reason goes to prepare-error, for backup-status.sh and the notifier.
set -euo pipefail

state=$HOME/.local/state/infra-podman/backup
staging=$state/staging
conf=$HOME/.config/infra-podman/backup/backup.conf
conf_dir=$HOME/.config/infra-podman/backup/backup.d
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

reason=daily
if [[ -f $state/next-reason ]]; then
  reason=$(head -n 1 "$state/next-reason")
  rm -f "$state/next-reason"
fi
[[ $reason =~ ^[a-z][a-z-]{0,30}$ ]] || fail "motivo de copia no válido en next-reason: $reason"
printf '%s\n' "$reason" >"$staging/.reason"
echo "backup-prepare: reason $reason"

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

export_volume() { # export_volume <app> <name> <volume>
  local dir=$staging/$1/volume/$2
  mkdir -p "$dir"
  echo "backup-prepare: $1: volume $3"
  podman volume export "$3" >"$dir/$2.tar" || fail "no se ha podido exportar el volumen $3."
}

exec_command() { # exec_command <app> <name> <container> <command...>
  local app=$1 name=$2 container=$3 running dir
  shift 3
  [[ $# -gt 0 ]] || fail "la copia $name de $app no dice qué orden ejecutar en $container."
  running=$(podman container inspect --format '{{.State.Running}}' "$container" 2>/dev/null) || running=false
  [[ $running == true ]] || fail "$container no está en marcha: no se puede ejecutar su copia $name."
  dir=$staging/$app/exec/$name
  mkdir -p "$dir"
  echo "backup-prepare: $app: exec $name"
  podman exec "$container" "$@" </dev/null >"$dir/$name.out" \
    || fail "la orden de la copia $name de $container ha fallado: $*"
}

read_items() { # read_items <file>
  local kind app a b words
  while read -r kind app a b; do
    case $kind in
      '' | '#'*) continue ;;
      pg) dump_instance "$app" "$a" ;;
      file) copy_file "$app" "$a" "$b" ;;
      volume) export_volume "$app" "$a" "$b" ;;
      exec)
        read -r -a words <<<"$b"
        exec_command "$app" "$a" "${words[@]}"
        ;;
      *) fail "línea desconocida en $1: $kind" ;;
    esac
  done <"$1"
}

read_items "$conf"
if [[ -d $conf_dir ]]; then
  for items in "$conf_dir"/*.conf; do
    [[ -e $items ]] || continue
    read_items "$items"
  done
fi

[[ -n $(find "$staging" -mindepth 1 -maxdepth 1 -not -name .reason) ]] || fail "no hay nada que copiar en $conf ni en $conf_dir."
echo "backup-prepare: ready"
