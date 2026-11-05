#!/usr/bin/env bash
# ExecStopPost of <env>-backup-copy.service, on the host, as the service user (R44).
# Runs after every attempt (systemd sets SERVICE_RESULT and EXIT_STATUS) and writes
# <unit>.status in the shared status directory, for the operator's notifier:
#   result=ok           copied
#   result=unreachable  the server did not answer (exit 75): no alarm until the last
#                       good copy is older than max_age_hours
#   result=failed       with the reason that backup-copy.sh left in its result file
# Only dates, sizes and a message: never data or secrets. Usage:
#   backup-copy-status.sh <unit name without .service> <max age in hours>
set -uo pipefail

unit=${1:?usage: backup-copy-status.sh <unit> <max age hours>}
max_age_hours=${2:?usage: backup-copy-status.sh <unit> <max age hours>}
state=$HOME/.local/state/infra-podman/backup-copy
result_file=$state/result
status_dir=${INFRA_BACKUP_STATUS_DIR:-/var/lib/infra-podman/backup-status}
file=$status_dir/$unit.status

now=$(date +%s)
iso=$(date -Is)
from() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }

last_ok="" last_ok_epoch="" since_epoch=$now usage=""
if [[ -f $file ]]; then
  last_ok=$(from last_ok "$file")
  last_ok_epoch=$(from last_ok_epoch "$file")
  since_epoch=$(from since_epoch "$file")
  usage=$(from usage "$file")
  since_epoch=${since_epoch:-$now}
fi
said=$(from message "$result_file")
warning=$(from warning "$result_file")
new_usage=$(from usage "$result_file")
usage=${new_usage:-$usage}
rm -f "$result_file"

logs="Logs: sudo journalctl _SYSTEMD_USER_UNIT=$unit.service -n 100"
if [[ ${SERVICE_RESULT:-} == success && ${EXIT_STATUS:-0} == 75 ]]; then
  result=unreachable
  message="${said:-El servidor de copias no responde.} Última copia correcta en el servidor: ${last_ok:-ninguna todavía}."
elif [[ ${SERVICE_RESULT:-} == success ]]; then
  result=ok
  last_ok=$iso
  last_ok_epoch=$now
  message=${said:-Copia en el servidor correcta.}
else
  result=failed
  message="La copia al servidor de $iso ha fallado: ${said:-restic ha terminado con error (${SERVICE_RESULT:-?}, ${EXIT_STATUS:-?}).} $logs"
fi

mkdir -p "$state"
tmp=$(mktemp "$status_dir/.$unit.XXXXXX") || { echo "backup-copy-status: cannot write in $status_dir" >&2; exit 1; }
printf '%s\n' "result=$result" "finished=$iso" "finished_epoch=$now" "last_ok=$last_ok" "last_ok_epoch=$last_ok_epoch" \
  "since_epoch=$since_epoch" "max_age_hours=$max_age_hours" "usage=$usage" "warning=$warning" "message=$message" >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$file"
echo "backup-copy-status: $result. $message${warning:+ AVISO: $warning}"
