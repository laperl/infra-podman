#!/usr/bin/env bash
# Run ansible-playbook for the lifecycle workflow and, on failure, repeat the failing
# tasks as GitHub annotations, so the result is readable from the checks API.
# Never used with real secrets: lifecycle only handles values generated in CI.
set -uo pipefail
log=$(mktemp)
ansible-playbook "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [[ $status -ne 0 ]]; then
  grep -E -B1 -A3 '^(fatal|failed):|ERROR!|\[ERROR\]' "$log" | head -40 \
    | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}' \
    | sed -e 's/^/::error title=ansible-playbook failed::/' -e 's/$/\n/'
fi
rm -f "$log"
exit "$status"
