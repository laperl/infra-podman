#!/usr/bin/env bash
# Run a command as the service user with the environment Podman and systemctl --user need.
# Usage: as-svc.sh <command...>   (user: $SVC_USER, default svc_runner)
set -euo pipefail
user=${SVC_USER:-svc_runner}
home=$(getent passwd "$user" | cut -d: -f6)
cd /   # the service user cannot enter the runner's workspace
exec sudo -u "$user" env HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
  XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" "$@"
