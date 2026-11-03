#!/usr/bin/env bash
# deploy.sh - the operator's single entry point (docs/SPEC.md, section 4.10).
#
#   deploy.sh plan    <playbook> [--env dev|prod] [--limit PATTERN]
#   deploy.sh apply   <playbook> [--env dev|prod] [--limit PATTERN]
#   deploy.sh secrets            [--env dev|prod] [--limit PATTERN] [--rotate NAME]
#
# --env defaults to prod. In prod the checkout must be clean and HEAD must carry a tag
# signed by a key listed in ~/.config/infra-podman/allowed_signers, a file that lives
# OUTSIDE the repository (R4 in docs/DECISIONS.md).
# plan/apply run through ansible-navigator and always ask for the sudo password at the
# terminal (R24); press Enter if a playbook needs none. secrets runs the same image with podman and
# hands the KeePassXC master password and the sudo password over stdin, never through
# ansible-navigator (R11, R29).
# Every run appends one line to ~/.local/state/infra-podman/deploy.log.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/infra-podman
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/infra-podman
ALLOWED_SIGNERS=$CONFIG_DIR/allowed_signers
DEPLOY_CONF=$CONFIG_DIR/deploy.conf
LOG_FILE=$STATE_DIR/deploy.log
# Overridable only so tests can use fakes.
NAVIGATOR=${INFRA_NAVIGATOR_BIN:-ansible-navigator}
PODMAN=${INFRA_PODMAN_BIN:-podman}

action="" target="" env_name="prod" limit="" rotate="" ref="-"

usage() {
  sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

log_line() { # log_line <result>
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$env_name" "${action:--}" \
    "${target:--}" "$ref" "${limit:-all}" "$1" >>"$LOG_FILE"
}

refuse() { # refuse <message>: stop before running anything, and log it
  echo "deploy.sh: $*" >&2
  [[ -n $action ]] && log_line "refused"
  exit 1
}

parse_args() {
  [[ $# -ge 1 ]] || usage
  action=$1
  shift
  case $action in
    plan | apply)
      [[ $# -ge 1 && $1 != --* ]] || usage
      target=$1
      shift
      ;;
    secrets) target=secrets ;;
    -h | --help) usage ;;
    *) action="" && usage ;;
  esac
  while [[ $# -gt 0 ]]; do
    case $1 in
      --env | --limit | --rotate) [[ $# -ge 2 ]] || usage ;;&
      --env) env_name=$2 ;;
      --limit) limit=$2 ;;
      --rotate) [[ $action == secrets ]] || usage; rotate=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ $env_name =~ ^(dev|prod)$ ]] || refuse "--env debe ser dev o prod"
  [[ -z $limit || $limit =~ ^[A-Za-z0-9_.,:-]+$ ]] || refuse "--limit no válido: $limit"
  [[ -z $rotate || $rotate =~ ^[a-z0-9_-]+$ ]] || refuse "nombre de secreto no válido en --rotate: $rotate"
  if [[ $action != secrets ]]; then
    [[ $target =~ ^[a-z0-9_-]+$ && -f $REPO_DIR/playbooks/$target.yml ]] \
      || refuse "playbook desconocido '$target' (se espera playbooks/<nombre>.yml)"
  fi
  [[ -f $REPO_DIR/inventory/$env_name/hosts.yml ]] || refuse "falta inventory/$env_name/hosts.yml"
}

describe_checkout() {
  local branch sha dirty=""
  sha=$(git rev-parse --short HEAD)
  branch=$(git symbolic-ref --quiet --short HEAD || echo detached)
  [[ -z $(git status --porcelain) ]] || dirty="+dirty"
  ref="$branch@$sha$dirty"
}

verify_signed_checkout() {
  # The trust anchor must live outside the repository: a key added to a file in the repo
  # would let anyone with write access sign their own tag (R4).
  [[ -f $ALLOWED_SIGNERS ]] \
    || refuse "falta $ALLOWED_SIGNERS (ver docs/SIGNING.md)"
  local anchor
  anchor=$(realpath "$ALLOWED_SIGNERS")
  [[ $anchor != "$REPO_DIR"/* ]] \
    || refuse "$ALLOWED_SIGNERS no puede apuntar a un fichero del repo"

  [[ -z $(git status --porcelain) ]] \
    || refuse "hay cambios sin commit o ficheros sin seguimiento; en prod solo se despliega un tag firmado y limpio"

  local tag
  for tag in $(git tag --points-at HEAD); do
    # Force ssh-keygen: never trust a signing program configured elsewhere.
    if git -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$anchor" \
      verify-tag "$tag" >/dev/null 2>&1; then
      ref="tag:$tag@$(git rev-parse --short HEAD)"
      echo "deploy.sh: tag firmado verificado: $tag"
      return 0
    fi
  done
  refuse "HEAD no tiene ningún tag firmado por una clave de confianza (git tag -s, ver docs/WORKFLOW.md)"
}

confirm_prod_apply() {
  # Applying to production needs a person at a terminal (D14: no AI runs apply).
  [[ -t 0 ]] || refuse "apply --env prod necesita un terminal interactivo"
  local answer
  read -r -p "Vas a aplicar '$target' en PRODUCCIÓN desde $ref. Escribe 'prod' para continuar: " answer
  [[ $answer == prod ]] || refuse "cancelado por el operador"
}

run_navigator() {
  local args=(run "playbooks/$target.yml" -i "inventory/$env_name/hosts.yml" --)
  [[ $action == plan ]] && args+=(--check)
  # The sudo password is typed at the terminal and read by ansible-playbook inside the
  # container: in stdout mode ansible-runner hands it the terminal (--interactive/--tty).
  # It never travels as an argument, an environment variable or a file (R11, R24).
  args+=(--diff --ask-become-pass)
  [[ -n $limit ]] && args+=(--limit "$limit")
  "$NAVIGATOR" "${args[@]}"
}

conf_get() { # conf_get <key>: value from deploy.conf (key=value lines; never sourced)
  [[ -f $DEPLOY_CONF ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$DEPLOY_CONF" | tail -1
}

run_secrets() {
  local kdbx image password
  kdbx=$(conf_get "kdbx_$env_name")
  kdbx=${kdbx/#\~/$HOME}
  [[ -n $kdbx && -f $kdbx ]] \
    || refuse "define kdbx_$env_name=<ruta al .kdbx> en $DEPLOY_CONF (ver docs/SETUP.md)"
  image=$(sed -n 's/^ *image: *\([^ ]*\).*/\1/p' ansible-navigator.yml)
  [[ $image == *@sha256:* ]] || refuse "ansible-navigator.yml no fija la imagen por digest"
  [[ -n ${SSH_AUTH_SOCK:-} && -S $SSH_AUTH_SOCK ]] \
    || refuse "no hay agente SSH (SSH_AUTH_SOCK); desbloquea KeePassXC"

  local mounts=(
    -v "$REPO_DIR:/work:ro" -w /work
    -v "$kdbx:/kdbx/database.kdbx:ro" -e KDBX_DATABASE=/kdbx/database.kdbx
    -v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock
  )
  [[ -d $HOME/.ssh ]] && mounts+=(-v "$HOME/.ssh:/root/.ssh:ro")
  local playbook_args=(playbooks/secrets.yml -i "inventory/$env_name/hosts.yml")
  [[ -n $limit ]] && playbook_args+=(--limit "$limit")
  [[ -n $rotate ]] && playbook_args+=(-e "secrets_rotate=$rotate")

  local become_password
  IFS= read -rs -p "Contraseña maestra de $(basename "$kdbx"): " password
  echo >&2
  [[ -n $password ]] || refuse "contraseña vacía"
  # Installing the secrets on a machine needs sudo there, to become the service user.
  # The sudo passwords of the laptop and the GX10 differ: use --limit (R24).
  IFS= read -rs -p "Contraseña de sudo de ${limit:-las máquinas} (Intro si no hace falta): " become_password
  echo >&2
  # printf is a bash builtin: the passwords never appear in the process list, and they
  # reach the container through stdin only, never as arguments or files (R11, R29).
  # label=disable: the agent socket and ~/.ssh cannot be relabelled for the container.
  # --network=host: the laptop is reached over SSH on 127.0.0.1 (R23).
  local status=0
  printf '%s\n%s\n' "$password" "$become_password" | "$PODMAN" run --rm -i --user root \
    --security-opt label=disable --network=host "${mounts[@]}" "$image" \
    bash -c 'IFS= read -r KDBX_PASSWORD; IFS= read -r INFRA_BECOME_PASSWORD; export KDBX_PASSWORD INFRA_BECOME_PASSWORD; exec ansible-playbook --become-password-file scripts/become-password.sh "$@"' \
    secrets "${playbook_args[@]}" || status=$?
  unset password become_password
  return "$status"
}

main() {
  parse_args "$@"
  cd "$REPO_DIR"
  describe_checkout
  if [[ $env_name == prod ]]; then
    verify_signed_checkout
  else
    echo "deploy.sh: DEV desde $ref (sin tag firmado)"
  fi
  [[ $action == apply && $env_name == prod ]] && confirm_prod_apply

  local status=0
  case $action in
    plan | apply) run_navigator || status=$? ;;
    secrets) run_secrets || status=$? ;;
  esac
  if [[ $status -eq 0 ]]; then log_line "ok"; else log_line "failed($status)"; fi
  return "$status"
}

main "$@"
