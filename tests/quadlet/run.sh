#!/usr/bin/env bash
# Quadlet validation suite used by the lint workflow.
#   - fixtures/valid           must pass
#   - fixtures/invalid/<case>  must fail, with the message in <case>/expected.txt
#   - every template under roles/ must pass
# Requires ansible-playbook, python3 and the Podman generator in PATH/default location.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
here="$repo/tests/quadlet"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

render() { # render <src-dir> <dest-dir>
  ansible-playbook "$repo/scripts/render-quadlets.yml" \
    -e "quadlet_src_dir=$1" -e "quadlet_dest_dir=$2" -e "@$here/ci_vars.yml" >"$work/render.log" 2>&1 \
    || { cat "$work/render.log"; return 1; }
}

failures=0

echo "== valid fixtures"
render "$here/fixtures/valid" "$work/valid"
"$repo/scripts/validate-quadlets.sh" "$work/valid" || failures=$((failures + 1))

for case_dir in "$here"/fixtures/invalid/*/; do
  case_name=$(basename "$case_dir")
  expected=$(<"$case_dir/expected.txt")
  echo "== invalid fixture: $case_name"
  render "$case_dir" "$work/invalid-$case_name"
  if output=$("$repo/scripts/validate-quadlets.sh" "$work/invalid-$case_name" 2>&1); then
    echo "FAIL: '$case_name' was accepted"
    failures=$((failures + 1))
  elif [[ $output != *"$expected"* ]]; then
    echo "FAIL: '$case_name' was rejected for the wrong reason. Expected: $expected"
    echo "$output"
    failures=$((failures + 1))
  else
    echo "ok: rejected ($expected)"
  fi
done

echo "== role templates"
render "$repo/roles" "$work/roles"
"$repo/scripts/validate-quadlets.sh" "$work/roles" || failures=$((failures + 1))

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All Quadlet checks passed"
