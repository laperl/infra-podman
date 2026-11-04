#!/usr/bin/env bash
# Tests for the status file and the operator's notifier (roles/backup/files), with a fake
# notify-send and a fake clock. The backup itself is tested in the lifecycle workflow.
# The checks are strings evaluated later by check(): single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/backup/files
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home INFRA_BACKUP_STATUS_DIR=$work/status INFRA_NOTIFY_BIN=$work/notify-send
mkdir -p "$HOME/.local/state/infra-podman/backup/staging" "$INFRA_BACKUP_STATUS_DIR"
state=$HOME/.local/state/infra-podman/backup
status=$INFRA_BACKUP_STATUS_DIR/dev-backup.status
cat >"$INFRA_NOTIFY_BIN" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${INFRA_BACKUP_STATUS_DIR%/*}/notified"
FAKE
chmod +x "$INFRA_NOTIFY_BIN"
notified=$work/notified

failures=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
field() { sed -n "s/^$1=//p" "$status"; }
notify() { : >"$notified"; INFRA_NOW=$1 "$src/backup-notify.sh" >/dev/null; }

# --- backup-status.sh -----------------------------------------------------------------
echo secret-dump >"$state/staging/x.dump"
SERVICE_RESULT=success "$src/backup-status.sh" dev-backup >/dev/null
check "a good run is recorded as ok" '[[ $(field result) == ok && -n $(field last_ok_epoch) ]]'
check "the staging directory (plain dumps) is deleted" '[[ ! -e $state/staging ]]'
check "the status file is readable by the operator" '[[ $(stat -c %a "$status") == 644 ]]'
good=$(field last_ok_epoch)

echo "pg_dump de la base x ha fallado." >"$state/prepare-error"
SERVICE_RESULT=exit-code EXIT_STATUS=1 "$src/backup-status.sh" dev-backup >/dev/null
check "a failed run is recorded as failed" '[[ $(field result) == failed ]]'
check "the failure keeps the last good backup" '[[ $(field last_ok_epoch) == "$good" ]]'
check "the message gives the reason and where the logs are" \
  '[[ $(field message) == *"pg_dump de la base x ha fallado."*"journalctl _SYSTEMD_USER_UNIT=dev-backup.service"* ]]'
rm "$state/prepare-error"
SERVICE_RESULT=exit-code EXIT_STATUS=1 "$src/backup-status.sh" dev-backup >/dev/null
check "without a prepare error, the message blames restic" '[[ $(field message) == *"restic ha terminado con error"* ]]'

# --- backup-notify.sh -------------------------------------------------------------------
notify "$((good + 3600))"
check "a failed backup notifies, with its message" 'grep -q "dev-backup: La copia de .* ha fallado" "$notified"'
SERVICE_RESULT=success "$src/backup-status.sh" dev-backup >/dev/null
good=$(field last_ok_epoch)
notify "$((good + 35 * 3600))"
check "a recent good backup does not notify" '[[ ! -s $notified ]]'
notify "$((good + 37 * 3600))"
check "a good backup older than 36 h notifies" 'grep -q "hace más de 36 h" "$notified"'
check "the notification is critical and from infra-podman" 'grep -q -- "--app-name=infra-podman --urgency=critical Backup" "$notified"'

rm "$status"
notify "$(($(date +%s) + 3600))"
check "no backup yet, just installed: no notification" '[[ ! -s $notified ]]'
notify "$(($(date +%s) + 40 * 3600))"
check "no backup 40 h after installing: notifies" 'grep -q "Todavía no se ha hecho ninguna copia" "$notified"'
rm -rf "$INFRA_BACKUP_STATUS_DIR"
mkdir -p "$INFRA_BACKUP_STATUS_DIR" && rmdir "$INFRA_BACKUP_STATUS_DIR"
: >"$notified"
INFRA_BACKUP_STATUS_DIR=$work/status "$src/backup-notify.sh" >/dev/null || true
check "a missing status directory notifies" 'grep -q "el backup no está instalado" "$notified"'

if [[ $failures -gt 0 ]]; then
  echo "$failures backup test(s) failed"
  exit 1
fi
echo "All backup status and notifier tests passed"
