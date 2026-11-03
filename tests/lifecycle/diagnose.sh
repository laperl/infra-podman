#!/usr/bin/env bash
# After a failed lifecycle step: publish what systemd and Quadlet see, as annotations
# (the job log is not readable from the checks API). No secrets involved.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
home=$(getent passwd svc_runner | cut -d: -f6)
uid=$(id -u svc_runner)
note() { # note <title> <command...>
  local out
  out=$("${@:2}" 2>&1 | tail -25 | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::warning title=$1::${out:-<empty>}"
}
note "units dir" ls -la "$home/.config/containers/systemd"
note "generator dir" ls -la "/run/user/$uid/systemd/generator"
note "generator dryrun" "$as" env QUADLET_UNIT_DIRS="$home/.config/containers/systemd" \
  /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
note "user units" "$as" systemctl --user list-units --all --no-pager 'dev-*'
note "user manager" systemctl status "user@$uid.service" --no-pager
note "user journal" sudo journalctl _UID="$uid" --no-pager -n 25
note "manager journal" sudo journalctl -u "user@$uid.service" --no-pager -n 25
