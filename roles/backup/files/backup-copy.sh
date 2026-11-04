#!/bin/sh
# Runs INSIDE the copy container (<env>-backup-copy), every hour (SPEC 4.11, R44).
# Copies to the backup server the snapshots of the local repository (/repo, read-only)
# that it does not have yet. The server is append-only: nothing there is ever deleted.
#   exit 0   copied (or nothing new)
#   exit 75  the server did not answer: not a failure, the next hour tries again
#   exit 1   failed; the reason, in Spanish, goes to the result file
# The result file (/state/result) tells backup-copy-status.sh, on the host, what to
# write for the operator's notifier: message=, warning=, usage=. Never a password.
# Both passwords come from files; restic never prints them.
set -u
: "${BACKUP_SITE:?}" "${BACKUP_REMOTE_URL:?}" "${BACKUP_REMOTE_PATH:?}" "${BACKUP_REMOTE_MAX_BYTES:?}" "${BACKUP_REMOTE_WARN_PERCENT:?}"
# Overridable only so tests can use fakes.
result=${BACKUP_RESULT_FILE:-/state/result}
server_password_file=${BACKUP_SERVER_PASSWORD_FILE:-/run/secrets/server-password}
local_repo=${BACKUP_LOCAL_REPO:-/repo}
log=$(mktemp)
: >"$result"

say() { echo "backup-copy: $*"; }
note() { printf '%s=%s\n' "$1" "$2" >>"$result"; }
fail() {
  say "ERROR: $1"
  note message "$1"
  exit 1
}
gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }
max_gb=$(gb "$BACKUP_REMOTE_MAX_BYTES")

# restic, with its output in the journal and kept in $log to explain a failure.
run() {
  "$@" >"$log" 2>&1
  rc=$?
  cat "$log"
  return "$rc"
}

# Why restic failed, in Spanish, from what it printed.
explain() {
  if grep -qE '[(](413|507)[)]|Insufficient Storage|Too Large' "$log"; then
    echo "el servidor de copias está lleno: ha llegado a su tope de $max_gb GB y no acepta nada más. No se ha copiado nada nuevo; tus copias locales siguen bien. Sube backup_server_max_size_gb en el repo de datos (SETUP.md, paso 18)."
  elif grep -qE '[(]401[)]|Unauthorized' "$log"; then
    echo "el servidor de copias no acepta el usuario o la contraseña. Comprueba que el secreto backup-server-password es el mismo en las dos máquinas (SETUP.md, paso 18)."
  elif grep -qE '[(]403[)]|Forbidden' "$log"; then
    echo "el servidor de copias no deja escribir en $BACKUP_REMOTE_PATH. El usuario es $BACKUP_SITE y solo puede escribir en su carpeta (SETUP.md, paso 18)."
  else
    echo "$1 ha terminado con error: $(grep -i -m1 -E 'fatal|error' "$log" | cut -c1-200)"
  fi
}

# 1. Does the server answer? Any HTTP answer (401 without a password) means yes.
if ! wget -S -T 10 -O /dev/null "$BACKUP_REMOTE_URL/" 2>&1 | grep -q 'HTTP/'; then
  say "the server $BACKUP_REMOTE_URL does not answer; trying again in an hour"
  note message "El servidor de copias ($BACKUP_REMOTE_URL) no responde. Se volverá a intentar cada hora."
  exit 75
fi

RESTIC_REST_USERNAME=$BACKUP_SITE
RESTIC_REST_PASSWORD=$(cat "$server_password_file") || fail "no se puede leer la contraseña del servidor de copias."
RESTIC_REPOSITORY="rest:$BACKUP_REMOTE_URL/$BACKUP_REMOTE_PATH/"
export RESTIC_REST_USERNAME RESTIC_REST_PASSWORD RESTIC_REPOSITORY
say "server $BACKUP_REMOTE_URL, repository $BACKUP_REMOTE_PATH"

# 2. The repository on the server: open it, or create it the first time with the same
#    chunker parameters as the local one, so that the copy deduplicates. Exit codes of
#    restic: 10 the repository does not exist, 12 wrong password.
run restic cat config >/dev/null
case $? in
  0) ;;
  10)
    say "creating the repository on the server"
    run restic init --from-repo "$local_repo" --from-password-file "$RESTIC_PASSWORD_FILE" --copy-chunker-params \
      || fail "no se ha podido crear el repositorio en el servidor: $(explain 'restic init')"
    ;;
  12) fail "la clave de restic no abre el repositorio del servidor. Tiene que ser la misma que la del repositorio local (backup-restic-password)." ;;
  *) fail "no se puede abrir el repositorio del servidor: $(explain 'restic cat config')" ;;
esac

# 3. The copy. --no-lock: the local repository is mounted read-only. If the daily backup
#    is pruning at the same time, this run fails and the next hour copies.
run restic copy --from-repo "$local_repo" --from-password-file "$RESTIC_PASSWORD_FILE" --no-lock \
  || fail "$(explain 'restic copy')"

# 4. How full is it? Only this repository counts; one server per installation (R44).
run restic stats --mode raw-data --json >/dev/null || fail "no se puede medir el repositorio del servidor: $(explain 'restic stats')"
used=$(sed -n 's/.*"total_size":\([0-9]*\).*/\1/p' "$log" | head -n 1)
[ -n "$used" ] || fail "no se puede medir el repositorio del servidor: restic stats no da el tamaño."
percent=$((used * 100 / BACKUP_REMOTE_MAX_BYTES))
note usage "$(gb "$used") GB de $max_gb GB ($percent %)"
say "server usage: $(gb "$used") GB of $max_gb GB ($percent %)"
if [ "$percent" -ge "$BACKUP_REMOTE_WARN_PERCENT" ]; then
  note warning "el servidor de copias está al $percent % de su tope ($(gb "$used") de $max_gb GB). Cuando se llene dejará de aceptar copias. Sube backup_server_max_size_gb en el repo de datos (SETUP.md, paso 18)."
fi
note message "Copia en el servidor correcta."
say "done"
