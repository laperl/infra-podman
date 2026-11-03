#!/usr/bin/env bash
# After playbooks/base.yml: what the operator would check by hand on a machine.
set -euo pipefail
user=${1:-svc_runner}
uid=$(id -u "$user")

fail() { echo "FAIL: $*"; exit 1; }

[[ -f /var/lib/systemd/linger/$user ]] || fail "linger is not enabled for $user"
grep -q "^$user:" /etc/subuid || fail "no subuid range for $user"
grep -q "^$user:" /etc/subgid || fail "no subgid range for $user"
[[ $(stat -c %a "$(getent passwd "$user" | cut -d: -f6)") == 700 ]] || fail "home of $user is not 0700"
[[ $(getent passwd "$user" | cut -d: -f7) == /usr/sbin/nologin ]] || fail "$user has a login shell"
if sudo -n -l -U "$user" 2>/dev/null | grep -q 'may run'; then fail "$user can use sudo"; fi

as_user() { sudo -u "$user" env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
as_user systemctl --user is-active default.target >/dev/null || fail "the user manager of $user is not running"
[[ $(as_user podman info --format '{{.Host.Security.Rootless}}') == true ]] || fail "podman is not rootless for $user"
echo "::notice title=Podman for ${user}::$(as_user podman --version), cgroups $(as_user podman info --format '{{.Host.CgroupsVersion}}'), network $(as_user podman info --format '{{.Host.NetworkBackend}}')"
echo "ok: $user has linger, sub-IDs, a running user manager and rootless Podman"
