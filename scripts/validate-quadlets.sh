#!/usr/bin/env bash
# Validate a directory of rendered Quadlet units:
#   1. repository policy (scripts/quadlet_policy.py)
#   2. the Podman Quadlet generator in dry-run mode, as documented in quadlet(5) for Podman 4.9
# Exit code 0 when both pass, 1 otherwise.
set -euo pipefail

usage() { echo "usage: $0 <rendered-units-dir>" >&2; exit 2; }
[[ $# -eq 1 && -d $1 ]] || usage

unit_dir=$(cd "$1" && pwd)
generator=${QUADLET_GENERATOR:-/usr/lib/systemd/system-generators/podman-system-generator}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

shopt -s nullglob
units=("$unit_dir"/*)
if [[ ${#units[@]} -eq 0 ]]; then
  # The generator itself fails with "No files parsed" on an empty directory.
  echo "No Quadlet units in $unit_dir: nothing to validate"
  exit 0
fi

status=0
python3 "$script_dir/quadlet_policy.py" "${units[@]}" || status=1

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ! QUADLET_UNIT_DIRS="$unit_dir" "$generator" --user --dryrun >/dev/null 2>"$log"; then
  echo "GENERATOR: $generator rejected the units:"
  sed 's/^/  /' "$log"
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "OK: ${#units[@]} unit(s) in $unit_dir"
fi
exit "$status"
