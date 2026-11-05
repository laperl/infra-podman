#!/usr/bin/env bash
# Runs in the OPERATOR's session, every hour (infra-podman-backup-notify.timer). Reads
# the status the backups leave in /var/lib/infra-podman/backup-status and shows a desktop
# notification when a backup failed or the last good one is too old. Changes nothing.
set -uo pipefail

# Overridable only so tests can use fakes.
status_dir=${INFRA_BACKUP_STATUS_DIR:-/var/lib/infra-podman/backup-status}
max_age_hours=${INFRA_BACKUP_MAX_AGE_HOURS:-36}
now=${INFRA_NOW:-$(date +%s)}
notify=${INFRA_NOTIFY_BIN:-notify-send}

alert() {
  echo "backup-notify: AVISO: $1"
  "$notify" --app-name=infra-podman --urgency=critical "Backup" "$1" \
    || echo "backup-notify: notify-send failed" >&2
}

if [[ ! -d $status_dir ]]; then
  alert "No existe $status_dir: el backup no está instalado. Aplica el playbook backup."
  exit 0
fi

shopt -s nullglob
files=("$status_dir"/*.status)
if [[ ${#files[@]} -eq 0 ]]; then
  age=$(((now - $(stat -c %Y "$status_dir")) / 3600))
  if [[ $age -ge $max_age_hours ]]; then
    alert "Todavía no se ha hecho ninguna copia (instalado hace $age h). Comprueba el temporizador: svc systemctl --user list-timers"
  else
    echo "backup-notify: no backup yet, installed $age h ago"
  fi
  exit 0
fi

# Each status file may set its own limit (max_age_hours=; the copy to the server: 7 days)
# and an extra warning (warning=; the server nearly full). result=unreachable (the server
# did not answer) is not an alarm by itself: only when the last good copy gets too old.
for file in "${files[@]}"; do
  unit=$(basename "$file" .status)
  result=$(sed -n 's/^result=//p' "$file")
  message=$(sed -n 's/^message=//p' "$file")
  last_ok=$(sed -n 's/^last_ok=//p' "$file")
  last_ok_epoch=$(sed -n 's/^last_ok_epoch=//p' "$file")
  since_epoch=$(sed -n 's/^since_epoch=//p' "$file")
  warning=$(sed -n 's/^warning=//p' "$file")
  limit=$(sed -n 's/^max_age_hours=//p' "$file")
  limit=${limit:-$max_age_hours}
  # Never a good copy yet: count from when the status was first written, if known.
  reference=${last_ok_epoch:-$since_epoch}
  if [[ $result != ok && $result != unreachable ]]; then
    alert "$unit: $message"
  elif [[ -z $reference ]] || [[ $(((now - reference) / 3600)) -ge $limit ]]; then
    if [[ $result == unreachable ]]; then
      alert "$unit: la última copia correcta es de ${last_ok:-nunca}, hace más de $limit h. $message"
    else
      alert "$unit: la última copia correcta es de ${last_ok:-nunca}, hace más de $limit h. Comprueba el temporizador: svc systemctl --user list-timers"
    fi
  else
    echo "backup-notify: $unit $result, last good copy ${last_ok:-none yet}"
  fi
  if [[ -n $warning ]]; then
    alert "$unit: $warning"
  fi
done
