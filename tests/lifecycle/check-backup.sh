#!/usr/bin/env bash
# What the operator would check by hand on dev-backup. Usage: check-backup.sh <step>
#   installed  timer enabled, nothing run by the apply, no network, never at boot
#   ok         last run good: tagged snapshots, restores of a database and of the data
#              repository, roles saved, no plain dump left on disk
#   failed     last run failed and the status explains why
#   retention  R28 on fake-dated snapshots, with the values of the installed unit
#   count      prints the number of pgdump snapshots of pg-main
#   destroyed  timer and container unit gone, repository kept (SPEC 4.2)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
unit=dev-backup
home=$(getent passwd svc_runner | cut -d: -f6)
status=/var/lib/infra-podman/backup-status/$unit.status
image=$(sed -n 's/^restic_image: *"\([^"]*\)".*/\1/p' "$here/../../playbooks/group_vars/all/images.yml")
fail() { echo "::error title=check-backup::$*"; exit 1; }
field() { sed -n "s/^$1=//p" "$status"; }
restic_cli() { # restic_cli <args...>: restic on the real repository, with the real secret
  "$as" podman run --rm --network=none -v dev-backup-repo:/repo \
    --secret dev-backup-restic-password,type=mount,target=/run/secrets/restic-password \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
    ${OUT:+-v "$OUT:/out"} "$image" --no-cache "$@"
}

case $1 in
  installed)
    "$as" systemctl --user is-enabled "$unit.timer" >/dev/null || fail "$unit.timer is not enabled"
    "$as" systemctl --user is-active "$unit.timer" >/dev/null || fail "$unit.timer is not active"
    [[ ! -e $status ]] || fail "a backup ran during the apply (only the timer may start it)"
    gen=$("$as" systemctl --user cat "$unit.service")
    grep -q -- '--network=none' <<<"$gen" || fail "the backup container has a network"
    grep -q -- '--cap-drop=all' <<<"$gen" || fail "the backup container keeps capabilities"
    grep -q -- '--read-only' <<<"$gen" || fail "the backup container root is writable"
    ! "$as" test -e "/run/user/$(id -u svc_runner)/systemd/generator/default.target.wants/$unit.service" \
      || fail "$unit.service would start at boot"
    echo "::notice title=Backup timer::$("$as" systemctl --user list-timers "$unit.timer" --no-pager | sed -n 2p)"
    ;;
  ok)
    [[ $(field result) == ok ]] || fail "status: $(cat "$status" 2>/dev/null)"
    [[ $(stat -c %a "$status") == 644 ]] || fail "status file not readable by the operator"
    ! "$as" test -e "$home/.local/state/infra-podman/backup/staging" || fail "the plain dumps were left on disk"
    snaps=$(restic_cli snapshots --json)
    for want in "app=pg-main type=pgdump /backup/pg-main/pgdump/lifecycle_app" \
      "app=pg-main type=pgdump /backup/pg-main/pgdump/postgres" \
      "app=pg-main type=pgdump /backup/pg-main/pgdump/_roles" \
      "app=infra-podman type=files /backup/infra-podman/files/data-repo"; do
      read -r app type path <<<"$want"
      jq -e --arg a "$app" --arg t "$type" --arg p "$path" \
        'any(.[]; (.tags | index("env=dev") and index($a) and index($t)) and .paths == [$p])' <<<"$snaps" >/dev/null \
        || fail "no snapshot $want with env=dev"
    done
    echo "::notice title=Backup snapshots::$(jq -r '[.[] | .paths[0]] | unique | join(", ")' <<<"$snaps")"

    OUT=$("$as" mktemp -d)
    export OUT
    restic_cli restore latest --path /backup/pg-main/pgdump/lifecycle_app --target /out >/dev/null
    restic_cli restore latest --path /backup/pg-main/pgdump/_roles --target /out >/dev/null
    restic_cli restore latest --path /backup/infra-podman/files/data-repo --target /out >/dev/null
    sql() { "$as" podman exec -i dev-pg-main psql -X -U ci_admin -v ON_ERROR_STOP=1 -tAq "$@"; }
    sql -d postgres -c "DROP DATABASE IF EXISTS lifecycle_restored" -c "CREATE DATABASE lifecycle_restored"
    "$as" cat "$OUT/backup/pg-main/pgdump/lifecycle_app/lifecycle_app.dump" \
      | "$as" podman exec -i dev-pg-main pg_restore -U ci_admin -d lifecycle_restored --exit-on-error
    want=$(sql -d lifecycle_app -c "SELECT count(*) || ':' || sum(n) FROM app.t")
    got=$(sql -d lifecycle_restored -c "SELECT count(*) || ':' || sum(n) FROM app.t")
    [[ $got == "$want" ]] || fail "restored database differs: $got instead of $want"
    sql -d postgres -c "DROP DATABASE lifecycle_restored"
    "$as" grep -q 'CREATE ROLE backup' "$OUT/backup/pg-main/pgdump/_roles/roles.sql" || fail "roles not saved"
    ! "$as" grep -q 'SCRAM-SHA-256' "$OUT/backup/pg-main/pgdump/_roles/roles.sql" || fail "role passwords were saved"
    "$as" git clone -q "$OUT/backup/infra-podman/files/data-repo/infra-podman-data.bundle" "$OUT/clone" \
      || fail "the data repository copy cannot be cloned"
    [[ $("$as" git -C "$OUT/clone" log -1 --format=%s) == "lifecycle data" ]] || fail "wrong data repository restored"
    "$as" rm -rf "$OUT"
    echo "::notice title=Restore::database rows $got, roles and data repository restored"
    ;;
  failed)
    [[ $(field result) == failed ]] || fail "status: $(cat "$status" 2>/dev/null)"
    [[ $(field message) == *"$2"* ]] || fail "status message does not say '$2': $(field message)"
    [[ -n $(field last_ok_epoch) ]] || fail "the last good backup was forgotten"
    echo "::notice title=Failure message::$(field message)"
    ;;
  retention)
    gen=$("$as" systemctl --user cat "$unit.service")
    d=$(grep -o 'BACKUP_KEEP_DAILY=[0-9]*' <<<"$gen" | cut -d= -f2)
    m=$(grep -o 'BACKUP_KEEP_MONTHLY=[0-9]*' <<<"$gen" | cut -d= -f2)
    y=$(grep -o 'BACKUP_KEEP_YEARLY=[0-9]*' <<<"$gen" | cut -d= -f2)
    [[ $d/$m/$y == 7/12/5 ]] || fail "the unit keeps $d/$m/$y, R28 says 7/12/5"
    # Fake dates: 10 daily, the 15th of 21 months, and 6 earlier years. Throwaway repository
    # and password, not the real ones.
    dates="2019-01-10 2020-01-10 2021-01-10 2022-01-10 2023-01-10 2024-01-10"
    for ym in 2025-0{1..9} 2025-1{0..2} 2026-0{1..9}; do dates="$dates $ym-15"; done
    for dd in 25 26 27 28 29 30 31; do dates="$dates 2026-10-$dd"; done
    dates="$dates 2026-11-01 2026-11-02 2026-11-03"
    kept=$("$as" podman run --rm --network=none --entrypoint /bin/sh -e RESTIC_PASSWORD=retention-test \
      -e RESTIC_REPOSITORY=/tmp/r "$image" -c "
        set -e; restic init -q; echo x > /tmp/f
        for t in $dates; do restic backup -q --host h --time \"\$t 12:00:00\" /tmp/f; done
        restic forget -q --host h --keep-daily $d --keep-monthly $m --keep-yearly $y
        restic snapshots --json" | jq -r '.[].time[0:10]' | sort | tr '\n' ' ')
    expected="2022-01-10 2023-01-10 2024-01-10 2025-12-15 2026-01-15 2026-02-15 2026-03-15 2026-04-15 "
    expected+="2026-05-15 2026-06-15 2026-07-15 2026-08-15 2026-09-15 2026-10-28 2026-10-29 2026-10-30 "
    expected+="2026-10-31 2026-11-01 2026-11-02 2026-11-03 "
    [[ $kept == "$expected" ]] || fail "retention kept: $kept"
    echo "::notice title=Retention R28::37 snapshots, 20 kept: $kept"
    ;;
  count)
    restic_cli snapshots --json --tag app=pg-main,type=pgdump | jq length
    ;;
  destroyed)
    ! "$as" systemctl --user is-enabled "$unit.timer" >/dev/null 2>&1 || fail "the timer is still enabled"
    ! "$as" test -e "$home/.config/systemd/user/$unit.timer" || fail "the timer file is still there"
    ! "$as" test -e "$home/.config/containers/systemd/$unit.container" || fail "$unit.container is still installed"
    "$as" podman volume exists dev-backup-repo || fail "the repository volume was removed (SPEC 4.2)"
    [[ $(restic_cli snapshots --json | jq length) -gt 0 ]] || fail "the snapshots are gone"
    ;;
  *) echo "usage: $0 installed|ok|failed <text>|retention|count|destroyed" >&2; exit 2 ;;
esac
[[ $1 == count ]] || echo "ok: $1"
