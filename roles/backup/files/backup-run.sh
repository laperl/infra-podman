#!/bin/sh
# Runs INSIDE the restic container (<env>-backup), with no network (SPEC 4.11).
# Every item prepared by backup-prepare.sh is /backup/<app>/<type>/<name>: one restic
# snapshot each, tagged env=, app= and type=. Then retention (R28) and a quick check.
# restic reads the password from a file (RESTIC_PASSWORD_FILE) and never prints it.
set -eu
: "${BACKUP_ENV:?}" "${BACKUP_HOST:?}" "${BACKUP_KEEP_DAILY:?}" "${BACKUP_KEEP_MONTHLY:?}" "${BACKUP_KEEP_YEARLY:?}"

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

count=0
for dir in /backup/*/*/*; do
  [ -d "$dir" ] || continue
  rel=${dir#/backup/}
  app=${rel%%/*}
  rest=${rel#*/}
  type=${rest%%/*}
  name=${rest#*/}
  log "$app/$type/$name"
  restic backup --host "$BACKUP_HOST" --tag "env=$BACKUP_ENV" --tag "app=$app" --tag "type=$type" "$dir"
  count=$((count + 1))
done
if [ "$count" -eq 0 ]; then
  log "ERROR: nothing to back up"
  exit 1
fi
log "$count item(s) saved"

log "retention: $BACKUP_KEEP_DAILY daily, $BACKUP_KEEP_MONTHLY monthly, $BACKUP_KEEP_YEARLY yearly"
restic forget --host "$BACKUP_HOST" --keep-daily "$BACKUP_KEEP_DAILY" \
  --keep-monthly "$BACKUP_KEEP_MONTHLY" --keep-yearly "$BACKUP_KEEP_YEARLY" --prune
restic check
restic stats --mode raw-data
log "done"
