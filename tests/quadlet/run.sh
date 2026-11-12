#!/usr/bin/env bash
# Quadlet validation suite used by the lint workflow.
#   - fixtures/valid           must pass
#   - fixtures/invalid/<case>  must fail, with the message in <case>/expected.txt
#   - every unit each role declares (<role>_quadlet_units) must pass, rendered under its real name
#   - those rendered units must be identical to the copy kept in tests/quadlet/golden
# Requires ansible-playbook, python3 and the Podman generator in PATH/default location.
#
# The golden copy is what the roles install with the values of ci_vars.yml. It makes every
# change to a unit visible in the pull request, and proves that a refactor changes none.
# After changing a template or a default on purpose, refresh it and commit the result:
#   tests/quadlet/run.sh --update-golden
set -euo pipefail

update_golden=false
case ${1:-} in
  '') ;;
  --update-golden) update_golden=true ;;
  *) echo "usage: $0 [--update-golden]" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
here="$repo/tests/quadlet"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

render() { # render <fixtures|roles> <src-dir> <dest-dir>
  local mode=quadlet_src_dir
  [[ $1 == roles ]] && mode=quadlet_roles_dir
  ansible-playbook "$repo/scripts/render-quadlets.yml" \
    -e "$mode=$2" -e "quadlet_dest_dir=$3" -e "@$here/ci_vars.yml" \
    -e "@$repo/playbooks/group_vars/all/images.yml" >"$work/render.log" 2>&1 \
    || { cat "$work/render.log"; return 1; }
}

failures=0

echo "== valid fixtures"
render fixtures "$here/fixtures/valid" "$work/valid"
"$repo/scripts/validate-quadlets.sh" "$work/valid" || failures=$((failures + 1))

for case_dir in "$here"/fixtures/invalid/*/; do
  case_name=$(basename "$case_dir")
  expected=$(<"$case_dir/expected.txt")
  echo "== invalid fixture: $case_name"
  render fixtures "$case_dir" "$work/invalid-$case_name"
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
render roles "$repo/roles" "$work/roles"
ls "$work/roles"
"$repo/scripts/validate-quadlets.sh" "$work/roles" || failures=$((failures + 1))

echo "== role templates against the golden copy"
if $update_golden; then
  rm -rf "$here/golden"
  cp -r "$work/roles" "$here/golden"
  echo "tests/quadlet/golden refreshed: review it with git diff and commit it"
elif diff -ru "$here/golden" "$work/roles"; then
  echo "ok: identical to tests/quadlet/golden"
else
  echo "FAIL: the rendered units differ from tests/quadlet/golden (diff above)."
  echo "If the change is intended, run: tests/quadlet/run.sh --update-golden"
  failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All Quadlet checks passed"
