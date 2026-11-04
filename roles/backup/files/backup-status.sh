#!/usr/bin/env bash
# ExecStopPost of <env>-backup.service, on the host, as the service user. Runs after
# every attempt, good or bad (systemd sets SERVICE_RESULT and EXIT_STATUS).
#   - Deletes the staging directory: the plain dumps never stay on disk.
#   - Writes <unit>.status in the shared status directory, for the operator's notifier.
#     It only holds dates and a message, never data or secrets.
# Usage: backup-status.sh <unit name without .service>
set -uo pipefail

unit=${1:?usage: backup-status.sh <unit>}
state=$HOME/.local/state/infra-podman/backup
status_dir=${INFRA_BACKUP_STATUS_DIR:-/var/lib/infra-podman/backup-status}
file=$status_dir/$unit.status

rm -rf "$state/staging"

now=$(date +%s)
iso=$(date -Is)
last_ok="" last_ok_epoch=""
if [[ -f $file ]]; then
  last_ok=$(sed -n 's/^last_ok=//p' "$file")
  last_ok_epoch=$(sed -n 's/^last_ok_epoch=//p' "$file")
fi

if [[ ${SERVICE_RESULT:-} == success ]]; then
  result=ok
  last_ok=$iso
  last_ok_epoch=$now
  message="Copia correcta."
else
  result=failed
  if [[ -s $state/prepare-error ]]; then
    reason=$(head -1 "$state/prepare-error")
  else
    reason="restic ha terminado con error (${SERVICE_RESULT:-?}, ${EXIT_STATUS:-?})."
  fi
  message="La copia de $iso ha fallado: $reason Logs: sudo journalctl _SYSTEMD_USER_UNIT=$unit.service -n 100"
fi

tmp=$(mktemp "$status_dir/.$unit.XXXXXX") || { echo "backup-status: cannot write in $status_dir" >&2; exit 1; }
printf 'result=%s\nfinished=%s\nfinished_epoch=%s\nlast_ok=%s\nlast_ok_epoch=%s\nmessage=%s\n' \
  "$result" "$iso" "$now" "$last_ok" "$last_ok_epoch" "$message" >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$file"
echo "backup-status: $result. $message"
