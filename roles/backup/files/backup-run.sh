#!/bin/sh
# Runs INSIDE the restic container (<env>-backup), with no network (SPEC 4.11).
# Every item prepared by backup-prepare.sh is /backup/<app>/<type>/<name>: one restic
# snapshot each, tagged site= (the installation, R42), env=, app=, type= and reason=
# (daily, or pre-upgrade before a PostgreSQL image change). Then retention (R28) and a
# quick check.
# restic reads the password from a file (RESTIC_PASSWORD_FILE) and never prints it.
set -eu
: "${BACKUP_SITE:?}" "${BACKUP_ENV:?}" "${BACKUP_HOST:?}" "${BACKUP_KEEP_DAILY:?}" "${BACKUP_KEEP_MONTHLY:?}" "${BACKUP_KEEP_YEARLY:?}"

log() { echo "backup: $*"; }

restic version
if ! restic cat config >/dev/null 2>&1; then
  # Never initialise over something that exists: a wrong password must fail loudly.
  if [ -n "$(ls -A "$RESTIC_REPOSITORY" 2>/dev/null)" ]; then
    log "ERROR: the repository exists but cannot be opened (wrong password?)"
    exit 1
  fi
  log "creating the repository"
  restic init
fi

reason=daily
[ -r /backup/.reason ] && reason=$(head -n 1 /backup/.reason)
log "reason: $reason"

count=0
for dir in /backup/*/*/*; do
  [ -d "$dir" ] || continue
  rel=${dir#/backup/}
  app=${rel%%/*}
  rest=${rel#*/}
  type=${rest%%/*}
  name=${rest#*/}
  log "$app/$type/$name"
  restic backup --host "$BACKUP_HOST" --tag "site=$BACKUP_SITE" --tag "env=$BACKUP_ENV" --tag "app=$app" --tag "type=$type" --tag "reason=$reason" "$dir"
  count=$((count + 1))
done
if [ "$count" -eq 0 ]; then
  log "ERROR: nothing to back up"
  exit 1
fi
log "$count item(s) saved"

# Grouped by tags too: a daily run never removes the backup made before an image change.
log "retention: $BACKUP_KEEP_DAILY daily, $BACKUP_KEEP_MONTHLY monthly, $BACKUP_KEEP_YEARLY yearly"
restic forget --host "$BACKUP_HOST" --group-by host,paths,tags --keep-daily "$BACKUP_KEEP_DAILY" \
  --keep-monthly "$BACKUP_KEEP_MONTHLY" --keep-yearly "$BACKUP_KEEP_YEARLY" --prune
restic check
restic stats --mode raw-data
log "done"
