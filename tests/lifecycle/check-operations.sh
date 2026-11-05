#!/usr/bin/env bash
# Runs the commands of docs/OPERATIONS.md exactly as written, in DEV terms, on the
# backup-copy job of lifecycle: the runner plays the laptop and the backup server, as the
# DEV VM does. Each block is the fenced bash after a "<!-- test: <name> -->" line; it runs
# after the "antes de empezar" block of its side (0.1 laptop or 0.2 GX10).
# Usage: check-operations.sh <step>
#   view           1.1   both lists of snapshots
#   in-sync        1.2   says the server has every local snapshot
#   copy-now       1.3   a backup and a copy, both result=ok
#   drill          1.4   the monthly drill says BIEN twice
#   restore-local  2.1   a broken database restored under another name, then swapped
#   restore-volume 2.2   a database restored from the server's volume, without the server
#   data-repo      2.3   the data repository cloned from the local copy
#   lost-laptop    2.4   the data repository from the server, with only the passwords
# Placeholders (<…>) and env=prod are replaced with the values of the runner; a block
# with a placeholder this script does not know fails, so the manual cannot drift.
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
fail() { echo "::error title=check-operations $step::$*" >&3; exit 1; }
step=${1:-}

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

# The values of the runner for each placeholder line (name=<…>) and for env=prod.
substitute() {
  local restic_image
  restic_image=$(sed -n 's/^restic_image: *"\([^"]*\)".*/\1/p' "$images")
  sed -E \
    -e 's/^env=prod\b/env=dev/' \
    -e "s|^db=<[^>]*>|db=$db|" -e "s|^db=postgres\b|db=$db|" \
    -e "s|^img=<[^>]*>|img=$restic_image|" \
    -e "s|^repo=<[^>]*>/<[^>]*>-<[^>]*>|repo=ci-site/dev-localhost|" \
    -e "s|^url=http://<[^>]*>\.<[^>]*>\.ts\.net:18000|url=http://127.0.0.1:18000|" \
    -e "s|^dest=~/[^ ]*|dest=$work/data-restored|"
}

# run <side> <block> [stdin file]: prints the output; fails with its last lines.
run() {
  local side=$1 name=$2 input=${3:-/dev/null} script body out rc=0
  body=$(block "$name")
  [[ -n $body ]] || fail "docs/OPERATIONS.md has no block '$name'"
  script=$work/$name.sh
  {
    echo 'set -Eeuo pipefail'
    # In the manual, "ssh gx10 <command>" runs on the GX10; here it is the same machine.
    # shellcheck disable=SC2016  # written to the script, expanded there
    echo 'ssh() { [[ $1 == gx10 ]] || return 99; shift; "$@"; }'
    [[ $side == none ]] || block "$side"
    # A later block in the manual runs in the same terminal as the one that set db.
    echo "db=$db"
    echo "$body"
  } | substitute >"$script"
  if left=$(grep -nE '^[a-z_]+=.*<[^>]+>' "$script"); then
    fail "unknown placeholder in the block '$name': $left"
  fi
  out=$work/$name.out
  (cd "$work" && bash "$script" <"$input") >"$out" 2>&1 || rc=$?
  cat "$out"
  [[ $rc == 0 ]] || fail "the block '$name' failed ($rc): $(tail -5 "$out" | tr '\n' ' ')"
}

sql() { "$here/as-svc.sh" podman exec dev-pg-main psql -X -U ci_admin -d "${2:-postgres}" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
rows() { sql "SELECT count(*) FROM app.t" "$1"; }
expect() { # expect <block> <text>: the output of the last run of <block> contains <text>
  grep -qF -- "$2" "$work/$1.out" || fail "the block '$1' does not say '$2': $(tail -5 "$work/$1.out" | tr '\n' ' ')"
}
keyfile() { # the restic key, and before it the server password if asked, one per line
  : >"$work/keys"
  chmod 600 "$work/keys"
  for f in "$@"; do cat "$RUNNER_TEMP/$f" >>"$work/keys"; done
  echo "$work/keys"
}

case $step in
  view)
    run laptop view
    [[ $(grep -c 'pgdump/lifecycle_app' "$work/view.out") -ge 2 ]] || fail "lifecycle_app is not in both lists"
    ;;
  in-sync)
    run laptop in-sync
    expect in-sync "BIEN: el GX10 tiene todas las copias"
    ;;
  copy-now)
    run laptop copy-now
    [[ $(grep -c 'result=ok' "$work/copy-now.out") == 2 ]] || fail "not result=ok twice"
    ;;
  drill)
    run laptop drill
    expect drill "BIEN: el GX10 tiene todas las copias"
    expect drill "BIEN: la base restaurada desde el GX10 es igual (1 tablas)"
    [[ $(sql "SELECT count(*) FROM pg_database WHERE datname = '${db}_simulacro'") == 0 ]] || fail "the drill database was left behind"
    ;;
  restore-local)
    # Break the database after the last backup, restore it under another name, swap.
    sql "DELETE FROM app.t WHERE n <= 10" "$db"
    run laptop restore-local
    expect restore-local "app.t|1000"
    [[ $(rows "$db") == 990 ]] || fail "the restore touched the database in use"
    run laptop swap
    [[ $(rows "$db") == 1000 ]] || fail "after the swap, $db does not hold the restored data"
    old=$(sql "SELECT datname FROM pg_database WHERE datname LIKE '${db}_antigua_%'")
    [[ -n $old && $(rows "$old") == 990 ]] || fail "the broken database was not kept as ${db}_antigua_*"
    [[ $(sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'") == ci_admin ]] \
      || fail "the restored database lost its owner"
    sql "DROP DATABASE \"$old\""
    echo "::notice title=Restore (2.1)::broken database restored under another name (1000 rows), swapped, the broken one kept as $old"
    ;;
  restore-volume)
    run gx10 volume-view "$(keyfile rpw)"
    grep -q 'pgdump/lifecycle_app' "$work/volume-view.out" || fail "the server's volume does not list lifecycle_app"
    run gx10 volume-dump "$(keyfile rpw)"
    [[ $(stat -c %a /dev/shm/infra-restore.dump) == 600 ]] || fail "the plain dump in /dev/shm is readable by others"
    run laptop volume-restore
    expect volume-restore "app.t|1000"
    [[ ! -e /dev/shm/infra-restore.dump ]] || fail "the plain dump was left in /dev/shm"
    sql "DROP DATABASE \"${db}_restaurada\""
    echo "::notice title=Restore (2.2)::a database restored from the server's volume with only the restic key"
    ;;
  data-repo)
    run laptop data-repo
    expect data-repo "lifecycle data"
    rm -rf "$work/data-restored"
    ;;
  lost-laptop)
    run none lost-laptop "$(keyfile spw rpw)"
    expect lost-laptop "lifecycle data"
    [[ -z $(git -C "$work/data-restored" remote) ]] || fail "the restored data repository still has a remote"
    rm -rf "$work/data-restored"
    echo "::notice title=Lost laptop (2.4)::data repository recovered from the server with only the two passwords"
    ;;
  *) echo "usage: $0 view|in-sync|copy-now|drill|restore-local|restore-volume|data-repo|lost-laptop" >&2; exit 2 ;;
esac
rm -f "$work/keys"
echo "ok: $step"
