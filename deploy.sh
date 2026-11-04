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
# The inventory lives in the operator's data repository, outside this one (SPEC 4.13,
# R38): its path is data_repo in ~/.config/infra-podman/deploy.conf. In prod that
# repository must be clean and its last commit signed by a key of the same allowed_signers.
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
data_dir="" data_ref="-"

usage() {
  sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

log_line() { # log_line <result>
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # date, env, action, playbook, code tag or branch, data commit, hosts, result (SPEC 4.10)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$env_name" "${action:--}" \
    "${target:--}" "$ref" "$data_ref" "${limit:-all}" "$1" >>"$LOG_FILE"
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
}

describe_checkout() {
  local branch sha dirty=""
  sha=$(git rev-parse --short HEAD)
  branch=$(git symbolic-ref --quiet --short HEAD || echo detached)
  [[ -z $(git status --porcelain) ]] || dirty="+dirty"
  ref="$branch@$sha$dirty"
}

trust_anchor() { # prints the real path of allowed_signers, or refuses
  # The trust anchor must live outside both repositories: a key added to a file in a repo
  # would let anyone with write access sign their own tag or commit (R4).
  [[ -f $ALLOWED_SIGNERS ]] \
    || refuse "falta $ALLOWED_SIGNERS (ver docs/SIGNING.md)"
  local anchor
  anchor=$(realpath "$ALLOWED_SIGNERS")
  [[ $anchor != "$REPO_DIR"/* ]] \
    || refuse "$ALLOWED_SIGNERS no puede apuntar a un fichero del repo"
  [[ -z $data_dir || $anchor != "$data_dir"/* ]] \
    || refuse "$ALLOWED_SIGNERS no puede apuntar a un fichero del repo de datos"
  printf '%s\n' "$anchor"
}

verify_signed_checkout() {
  local anchor
  anchor=$(trust_anchor) || exit 1

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
  local nearest
  nearest=$(git describe --tags --abbrev=0 2>/dev/null || echo ninguno)
  refuse "HEAD ($(git rev-parse --short HEAD)) no tiene ningún tag firmado por una clave de confianza." \
    "El último tag ($nearest) está en $(git rev-parse --short "$nearest^{commit}" 2>/dev/null || echo '-')." \
    "¿Creaste el tag antes de git pull? Ver docs/WORKFLOW.md, paso 5"
}

resolve_data_repo() {
  # The operator's data repository (SPEC 4.13): one git repository per project, at the
  # path given by data_repo in deploy.conf. Read in dev and prod alike.
  local conf top
  conf=$(conf_get data_repo)
  conf=${conf/#\~/$HOME}
  [[ -n $conf ]] \
    || refuse "define data_repo = <ruta del repo de datos> en $DEPLOY_CONF (ver docs/SETUP.md, paso 14)"
  [[ -d $conf ]] \
    || refuse "no existe el repo de datos $conf. ¿Está montado el volumen cifrado?"
  data_dir=$(cd "$conf" && pwd -P)
  top=$(git -C "$data_dir" rev-parse --show-toplevel 2>/dev/null) \
    || refuse "$data_dir no es un repo git (ver docs/SETUP.md, paso 14)"
  [[ $(cd "$top" && pwd -P) == "$data_dir" ]] \
    || refuse "data_repo tiene que ser la raíz de su propio repo git, no una carpeta de $top"
  [[ $data_dir != "$REPO_DIR" && $data_dir != "$REPO_DIR"/* && $REPO_DIR != "$data_dir"/* ]] \
    || refuse "el repo de datos y el de código tienen que estar separados, uno no puede contener al otro"
  local sha dirty=""
  sha=$(git -C "$data_dir" rev-parse --short HEAD 2>/dev/null) \
    || refuse "el repo de datos $data_dir no tiene ningún commit"
  [[ -z $(git -C "$data_dir" status --porcelain) ]] || dirty="+dirty"
  data_ref="data@$sha$dirty"
  [[ -f $data_dir/inventory/$env_name/hosts.yml ]] \
    || refuse "falta inventory/$env_name/hosts.yml en el repo de datos $data_dir"
}

verify_signed_data() {
  # Prod deploys only data the operator approved: no pending changes, and the last commit
  # signed by a trusted key (SPEC 4.10, R38). Same anchor and same forced program as tags.
  local anchor
  anchor=$(trust_anchor) || exit 1
  [[ -z $(git -C "$data_dir" status --porcelain) ]] \
    || refuse "el repo de datos tiene cambios sin commit o ficheros sin seguimiento ($data_dir)." \
      "Haz un commit firmado (docs/WORKFLOW.md, «Cambiar datos») o descártalos"
  git -C "$data_dir" -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$anchor" \
    verify-commit HEAD >/dev/null 2>&1 \
    || refuse "el último commit del repo de datos ($data_ref) no está firmado por una clave de confianza." \
      "Comprueba con: git -C $data_dir verify-commit HEAD (docs/SIGNING.md)"
  echo "deploy.sh: commit firmado del repo de datos verificado: $data_ref"
}

confirm_prod_apply() {
  # Applying to production needs a person at a terminal (D14: no AI runs apply).
  [[ -t 0 ]] || refuse "apply --env prod necesita un terminal interactivo"
  local answer
  read -r -p "Vas a aplicar '$target' en PRODUCCIÓN desde $ref. Escribe 'prod' para continuar: " answer
  [[ $answer == prod ]] || refuse "cancelado por el operador"
}

run_navigator() {
  # ansible-runner mounts the folder of the inventory file into the container, at the
  # same path (ansible-runner 2.4.3, _handle_ansible_cmd_options_bind_mounts): group_vars
  # and host_vars next to hosts.yml come with it.
  local args=(run "playbooks/$target.yml" -i "$data_dir/inventory/$env_name/hosts.yml" --)
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
    # The inventory of this environment, from the data repository, read-only (SPEC 4.13).
    -v "$data_dir/inventory/$env_name:/inventory:ro"
    # The agent socket at the SAME path as on the laptop, as ansible-navigator does
    # (ansible-runner's automounts): an IdentityAgent in ~/.ssh/config keeps working.
    -v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
  )
  [[ -d $HOME/.ssh ]] && mounts+=(-v "$HOME/.ssh:/root/.ssh:ro")
  [[ -f /etc/ssh/ssh_known_hosts ]] && mounts+=(-v /etc/ssh/ssh_known_hosts:/etc/ssh/ssh_known_hosts:ro)
  local playbook_args=(playbooks/secrets.yml -i /inventory/hosts.yml)
  # The first play of secrets.yml runs on localhost (the Ansible container): it checks
  # infra_site and --rotate and reads the check-only secrets. A --limit without localhost
  # would skip it silently, so it is always added.
  [[ -n $limit ]] && playbook_args+=(--limit "$limit,localhost")
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
  resolve_data_repo
  if [[ $env_name == prod ]]; then
    verify_signed_checkout
    verify_signed_data
  else
    echo "deploy.sh: DEV desde $ref (sin tag firmado), datos de $data_dir ($data_ref)"
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
