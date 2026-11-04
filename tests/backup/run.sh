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

# --- backup-copy.sh (copy to the backup server, R44) -----------------------------------
# Fake wget and restic: the real ones run in the lifecycle workflow.
bin=$work/bin
mkdir -p "$bin"
calls=$work/calls
cat >"$bin/wget" <<'FAKE'
#!/usr/bin/env bash
[[ ${FAKE_SERVER:-up} == up ]] || { echo "wget: can't connect to remote host: Connection refused" >&2; exit 1; }
echo "  HTTP/1.1 401 Unauthorized" >&2
echo "wget: server returned error: HTTP/1.1 401 Unauthorized" >&2
exit 1
FAKE
cat >"$bin/restic" <<'FAKE'
#!/usr/bin/env bash
printf '%s user=%s repo=%s\n' "$*" "$RESTIC_REST_USERNAME" "$RESTIC_REPOSITORY" >>"$FAKE_CALLS"
case $1:${FAKE_RESTIC:-ok} in
  cat:new) echo "Fatal: repository does not exist: unable to open config file" >&2; exit 10 ;;
  cat:wrong-key) echo "Fatal: wrong password or no key found" >&2; exit 12 ;;
  cat:unauthorized) echo "Fatal: unable to open config file: unexpected HTTP response (401): 401 Unauthorized" >&2; exit 1 ;;
  copy:full) echo "Fatal: Save(<data/5f1c2a>) returned error: unexpected HTTP response (413): 413 Request Entity Too Large" >&2; exit 1 ;;
  stats:*) echo "{\"total_size\":${FAKE_USED:-1073741824},\"total_file_count\":3}" ;;
esac
exit 0
FAKE
chmod +x "$bin/wget" "$bin/restic"
echo server-secret >"$work/server-password"
copy_result=$work/copy-result
copy() { # copy <expected exit code> [VAR=value...]: one run of backup-copy.sh with fakes
  local want=$1 got=0
  shift
  : >"$calls"
  env PATH="$bin:$PATH" FAKE_CALLS="$calls" BACKUP_RESULT_FILE="$copy_result" BACKUP_SERVER_PASSWORD_FILE="$work/server-password" \
    BACKUP_LOCAL_REPO=/repo RESTIC_PASSWORD_FILE=/run/secrets/restic-password BACKUP_SITE=ci-site \
    BACKUP_REMOTE_URL=http://server.invalid:18000 BACKUP_REMOTE_PATH=ci-site/dev/ci \
    BACKUP_REMOTE_MAX_BYTES=10737418240 BACKUP_REMOTE_WARN_PERCENT=80 "$@" sh "$src/backup-copy.sh" >"$work/copy.log" 2>&1 || got=$?
  [[ $got == "$want" ]] || { echo "  backup-copy.sh exited $got, expected $want:"; sed 's/^/    /' "$work/copy.log"; }
  [[ $got == "$want" ]]
}
said() { sed -n "s/^$1=//p" "$copy_result"; }

check "an existing repository: copies, from the read-only local one" \
  'copy 0 && grep -q "^copy --from-repo /repo --from-password-file /run/secrets/restic-password --no-lock" "$calls" && ! grep -q "^init" "$calls"'
check "it goes to <site>/<env>/<machine>, as the installation's user" \
  'grep -q "user=ci-site repo=rest:http://server.invalid:18000/ci-site/dev/ci/" "$calls"'
check "it reports the usage and no warning below 80 %" '[[ $(said usage) == "1.0 GB de 10.0 GB (10 %)" && -z $(said warning) ]]'
check "the server password never reaches the output" '! grep -q server-secret "$work/copy.log" "$copy_result" "$calls"'
check "a new server: the repository is created with the local chunker parameters" \
  'copy 0 FAKE_RESTIC=new && grep -q "^init --from-repo /repo --from-password-file /run/secrets/restic-password --copy-chunker-params" "$calls" && grep -q "^copy " "$calls"'
check "at 85 % of the limit: a warning" \
  'copy 0 FAKE_USED=9126805504 && [[ $(said warning) == *"está al 85 % de su tope"* ]]'
check "server down: exit 75 and nothing else tried" \
  'copy 75 FAKE_SERVER=down && [[ ! -s $calls ]] && [[ $(said message) == *"no responde"* ]]'
check "server full: fails and says so in Spanish" \
  'copy 1 FAKE_RESTIC=full && [[ $(said message) == *"está lleno"*"backup_server_max_size_gb"* ]]'
check "wrong server password: fails and says which secret" \
  'copy 1 FAKE_RESTIC=unauthorized && [[ $(said message) == *"backup-server-password"* ]] && ! grep -q "^init" "$calls"'
check "wrong restic key: fails and never creates a repository" \
  'copy 1 FAKE_RESTIC=wrong-key && [[ $(said message) == *"backup-restic-password"* ]] && ! grep -q "^init" "$calls"'

# --- backup-copy-status.sh and the notifier for the copy ---------------------------------
cstatus=$INFRA_BACKUP_STATUS_DIR/dev-backup-copy.status
cfield() { sed -n "s/^$1=//p" "$cstatus"; }
cstate=$HOME/.local/state/infra-podman/backup-copy
mkdir -p "$cstate"
mkdir -p "$INFRA_BACKUP_STATUS_DIR"
rm -f "$INFRA_BACKUP_STATUS_DIR"/*.status
copy_status() { printf '%s\n' "$@" >"$cstate/result"; "$src/backup-copy-status.sh" dev-backup-copy 168 >/dev/null; }

SERVICE_RESULT=success EXIT_STATUS=75 copy_status "message=El servidor de copias (x) no responde."
check "server down on the first run: unreachable, no good copy yet" \
  '[[ $(cfield result) == unreachable && -z $(cfield last_ok_epoch) && -n $(cfield since_epoch) && $(cfield max_age_hours) == 168 ]]'
since=$(cfield since_epoch)
notify "$((since + 3600))"
check "unreachable for an hour: no notification" '[[ ! -s $notified ]]'
notify "$((since + 169 * 3600))"
check "no good copy 7 days after the first try: notifies, saying the server does not answer" \
  'grep -q "dev-backup-copy: la última copia correcta es de nunca, hace más de 168 h. El servidor de copias (x) no responde" "$notified"'

SERVICE_RESULT=success EXIT_STATUS=0 copy_status "usage=1.0 GB de 30.0 GB (3 %)" "message=Copia en el servidor correcta."
check "a good copy is recorded, with its usage" '[[ $(cfield result) == ok && -n $(cfield last_ok_epoch) && $(cfield usage) == "1.0 GB de 30.0 GB (3 %)" ]]'
check "the result file is consumed" '[[ ! -e $cstate/result ]]'
good=$(cfield last_ok_epoch)
SERVICE_RESULT=success EXIT_STATUS=75 copy_status "message=El servidor de copias (x) no responde."
check "unreachable after a good copy keeps it and the usage" \
  '[[ $(cfield result) == unreachable && $(cfield last_ok_epoch) == "$good" && $(cfield usage) == "1.0 GB de 30.0 GB (3 %)" ]]'
notify "$((good + 100 * 3600))"
check "unreachable, last good copy 100 h ago: no notification (limit 7 days)" '[[ ! -s $notified ]]'
notify "$((good + 170 * 3600))"
check "unreachable, last good copy over 7 days ago: notifies" 'grep -q "dev-backup-copy: la última copia correcta es de .*, hace más de 168 h" "$notified"'

SERVICE_RESULT=exit-code EXIT_STATUS=1 copy_status "message=el servidor de copias está lleno: ha llegado a su tope."
check "a failed copy is recorded with its reason and the logs" \
  '[[ $(cfield result) == failed && $(cfield message) == *"está lleno"*"journalctl _SYSTEMD_USER_UNIT=dev-backup-copy.service"* && $(cfield last_ok_epoch) == "$good" ]]'
notify "$((good + 3600))"
check "a failed copy notifies at once" 'grep -q "dev-backup-copy: La copia al servidor de .* ha fallado: el servidor de copias está lleno" "$notified"'

SERVICE_RESULT=success EXIT_STATUS=0 copy_status "usage=25.5 GB de 30.0 GB (85 %)" "warning=el servidor de copias está al 85 % de su tope." "message=Copia en el servidor correcta."
notify "$(($(cfield last_ok_epoch) + 3600))"
check "a good copy with the server nearly full notifies the warning" 'grep -q "dev-backup-copy: el servidor de copias está al 85 % de su tope." "$notified"'
SERVICE_RESULT=success EXIT_STATUS=0 copy_status "usage=1.0 GB de 30.0 GB (3 %)" "message=Copia en el servidor correcta."
notify "$(($(cfield last_ok_epoch) + 3600))"
check "the warning goes away with the next good copy" '[[ ! -s $notified ]]'

if [[ $failures -gt 0 ]]; then
  echo "$failures backup test(s) failed"
  exit 1
fi
echo "All backup status and notifier tests passed"
