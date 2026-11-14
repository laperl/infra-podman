#!/usr/bin/env bash
# Runs the commands of docs/OPERATIONS.md exactly as written, in DEV terms, on the
# backup-copy job of lifecycle: the runner plays the laptop and the main server, as the DEV VM
# does. Each block is the fenced bash after a "<!-- test: <name> -->" line.
# Usage: check-operations.sh <step>
#   deployed        1    containers, timers and unit files
#   status          2    both status files say result=ok; the list of snapshots
#   run-now         3    a backup and a copy, both result=ok
#   healthy         4    the laptop and the main server look healthy
#   firefly         1, 4 Firefly III, its instance casa: deployed and healthy (firefly job)
#   restore-local   5.1  a broken database restored under another name, checked, swapped
#   restore-server    5.2  a database restored from the main server's volume, with only the restic key
#   data-repo       5.3  the data repository from the local copy
#   lost-laptop     5.4  the data repository from the main server's volume, cloned as on a new laptop
# prod- names become dev- and the placeholders (<…>) the values of the runner; a block
# left with a placeholder this script does not know fails, so the manual cannot drift.
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
doc=$here/../../docs/OPERATIONS.md
images=$here/../../playbooks/group_vars/all/images.yml
db=lifecycle_app
work=${RUNNER_TEMP:?}/operations
mkdir -p "$work"
chmod 755 "$work"
# fd 3 is the real stdout: errors must reach the annotations (the job log is not readable).
exec 3>&1
step=${1:-}
fail() { echo "::error title=check-operations $step::$*" >&3; exit 1; }

# The fenced block after "<!-- test: name -->", without the indentation of its list item.
block() {
  awk -v want="<!-- test: $1 -->" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    !found && line == want { found = 1; next }
    found && !inside && line ~ /^```/ { inside = 1; match($0, /^[ \t]*/); indent = RLENGTH; next }
    inside && line ~ /^```/ { exit }
    inside { print substr($0, indent + 1) }
  ' "$doc"
}

# DEV names and the values of the runner. The laptop is the inventory host localhost.
substitute() {
  local restic_image
  restic_image=$(sed -n 's/^restic_image: *"\([^"]*\)".*/\1/p' "$images")
  sed -E \
    -e 's/\bprod-/dev-/g' \
    -e "s|<base>|$db|g" \
    -e 's|<superusuario>|ci_admin|g' \
    -e 's|<instancia>|casa|g' \
    -e 's|<puerto>|18100|g' \
    -e "s|<imagen_de_restic>|$restic_image|g" \
    -e 's|<instalación>/dev-laptop|ci-site/dev-localhost|g' \
    -e "s|~/infra-podman-datos-restaurados|$work/data-restored|g" \
    -e "s|~/infra-podman-data|$work/data-lost|g"
}

# run <block> [stdin file]: prints the output; fails with its last lines. The blocks of
# one task run in the same terminal in the manual: db and superuser stay set.
run() {
  local name=$1 input=${2:-/dev/null} script body out rc=0 left
  body=$(block "$name")
  [[ -n $body ]] || fail "docs/OPERATIONS.md has no block '$name'"
  script=$work/$name.sh
  {
    echo 'set -Eeuo pipefail'
    # svc, as docs/SETUP.md (step 12) has it in the operator's ~/.bashrc.
    # shellcheck disable=SC2016  # written to the script, expanded there
    echo 'svc() { (cd / && sudo -u svc_runner env HOME="$(getent passwd svc_runner | cut -d: -f6)" XDG_RUNTIME_DIR="/run/user/$(id -u svc_runner)" "$@"); }'
    # In the manual, servidor is another machine; here it is the same one.
    # shellcheck disable=SC2016
    echo 'ssh() { if [[ $1 == -n ]]; then shift; exec </dev/null; fi; [[ $1 == servidor ]] || return 99; shift; "$@"; }'
    # shellcheck disable=SC2016
    echo 'scp() { [[ $1 == -q && $2 == servidor:* ]] || return 99; cp "${2#servidor:}" "$3"; }'
    echo "db=$db"
    echo "superuser=ci_admin"
    echo "$body" | substitute
  } >"$script"
  if left=$(grep -noE '<[a-záéíóúñ_]+>' "$script"); then
    fail "unknown placeholder in the block '$name': $left"
  fi
  out=$work/$name.out
  (cd "$work" && bash "$script" <"$input") >"$out" 2>&1 || rc=$?
  cat "$out"
  [[ $rc == 0 ]] || fail "the block '$name' failed ($rc): $(tail -5 "$out" | tr '\n' ' ')"
}

sql() { "$here/as-svc.sh" podman exec dev-pg-main psql -X -U ci_admin -d "${2:-postgres}" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
rows() { sql "SELECT count(*) FROM app.t" "$1"; }
expect() { # expect <block> <extended regex>: the output of the last run of <block> matches
  grep -qE -- "$2" "$work/$1.out" || fail "the block '$1' does not say '$2': $(tail -5 "$work/$1.out" | tr '\n' ' ')"
}
count_is() { # count_is <block> <line> <n>: exactly n lines of the output are <line>
  local n
  n=$(grep -cxF -- "$2" "$work/$1.out" || true)
  [[ $n == "$3" ]] || fail "the block '$1' says '$2' $n times, expected $3"
}
keyfile() { # the restic key, as the operator pastes it
  install -m 600 "$RUNNER_TEMP/rpw" "$work/key"
  echo "$work/key"
}

case $step in
  deployed)
    run deployed
    expect deployed 'dev-pg-main'
    expect deployed 'dev-backup\.timer'
    expect deployed 'dev-backup-copy\.timer'
    expect deployed 'dev-backup\.container'
    ;;
  status)
    run status
    count_is status 'result=ok' 2
    run snapshots
    expect snapshots 'pgdump/lifecycle_app'
    expect snapshots 'files/data-repo'
    ;;
  run-now)
    run run-now
    count_is run-now 'result=ok' 2
    ;;
  healthy)
    run healthy
    count_is healthy 'active' 3
    expect healthy '^sano$'
    count_is healthy 'result=ok' 2
    if grep -q -- '->' "$work/healthy.out"; then fail "podman port shows a published port"; fi
    run healthy-server
    expect healthy-server '^active$'
    expect healthy-server '^401$'
    ;;
  firefly)
    run deployed-firefly
    expect deployed-firefly 'dev-ff-casa-cron\.timer'
    run healthy-firefly
    count_is healthy-firefly 'active' 2
    expect healthy-firefly '^sano$'
    count_is healthy-firefly '8080/tcp -> 127.0.0.1:18100' 1
    expect healthy-firefly '^OK$'
    ;;
  restore-local)
    # Break the database after the last backup; restore it under another name; swap.
    sql "DELETE FROM app.t WHERE n <= 10" "$db"
    run restore-local
    [[ $(rows "${db}_restaurada") == 1000 ]] || fail "the restored database does not hold the 1000 rows"
    [[ $(rows "$db") == 990 ]] || fail "the restore touched the database in use"
    run check-restored
    expect check-restored 'app +\| t +\|'
    run swap
    [[ $(rows "$db") == 1000 ]] || fail "after the swap, $db does not hold the restored data"
    [[ $(rows "${db}_antigua") == 990 ]] || fail "the broken database was not kept as ${db}_antigua"
    sql "DROP DATABASE ${db}_antigua"
    echo "::notice title=Restore (5.1)::broken database restored under another name (1000 rows) and swapped; the broken one kept as ${db}_antigua"
    ;;
  restore-server)
    run server-dump "$(keyfile)"
    [[ -s /dev/shm/restaurar.dump ]] || fail "the dump from the main server's volume is empty"
    [[ $(stat -c %a /dev/shm/restaurar.dump) == 600 ]] || fail "the plain dump in /dev/shm is readable by others"
    run server-restore
    [[ ! -e /dev/shm/restaurar.dump ]] || fail "the plain dump was left in /dev/shm"
    [[ $(rows "${db}_restaurada") == 1000 ]] || fail "the database restored from the main server does not hold the 1000 rows"
    sql "DROP DATABASE ${db}_restaurada"
    echo "::notice title=Restore (5.2)::a database restored from the main server's volume, without its server, with only the restic key"
    ;;
  data-repo)
    run data-repo
    expect data-repo 'lifecycle data'
    [[ ! -e /dev/shm/datos.bundle ]] || fail "the bundle was left in /dev/shm"
    rm -rf "$work/data-restored"
    ;;
  lost-laptop)
    run lost-server "$(keyfile)"
    [[ $(stat -c %a /dev/shm/restaurar.bundle) == 600 ]] || fail "the bundle in /dev/shm is readable by others"
    run lost-laptop
    expect lost-laptop 'lifecycle data'
    [[ -z $(git -C "$work/data-lost" remote) ]] || fail "the restored data repository still has a remote"
    [[ ! -e /dev/shm/restaurar.bundle && ! -e /dev/shm/datos.bundle ]] || fail "a bundle was left in /dev/shm"
    rm -rf "$work/data-lost"
    echo "::notice title=Lost laptop (5.4)::data repository recovered from the main server's volume with only the restic key"
    ;;
  *) echo "usage: $0 deployed|status|run-now|healthy|restore-local|restore-server|data-repo|lost-laptop" >&2; exit 2 ;;
esac
rm -f "$work/key"
echo "ok: $step"
