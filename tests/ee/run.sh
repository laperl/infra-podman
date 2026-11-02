#!/usr/bin/env bash
# Integration tests for the Ansible execution environment (SPEC 7.1, phase 0).
# Runs INSIDE the image (see .github/workflows/ee-image.yml), from the repo root.
# All values are random and thrown away: no real secret is ever involved.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== Versions"
ansible --version | head -1
python3 --version
keepassxc-cli --version
ansible-galaxy collection list containers.podman ansible.posix 2>/dev/null | grep -E '^(containers|ansible)\.' || echo "(collections not installed here)"
command -v ssh >/dev/null && ssh -V

random() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }
master=$(random)
value=$(random)
db="$work/test.kdbx"

echo "== keepassxc-cli accepts the master password on stdin, without a terminal"
printf '%s\n%s\n' "$master" "$master" | keepassxc-cli db-create -q -p "$db"
printf '%s\n' "$master" | keepassxc-cli mkdir -q "$db" Infra_Podman
printf '%s\n%s\n' "$master" "$value" | keepassxc-cli add -q -p "$db" Infra_Podman/test_dummy
read_back=$(printf '%s\n' "$master" | keepassxc-cli show -q -s -a password "$db" Infra_Podman/test_dummy)
[[ $read_back == "$value" ]] || { echo "FAIL: read back a different value"; exit 1; }
echo "ok"

echo "== Lookup: reads the secret; a skipped task does not evaluate it"
KDBX_DATABASE=$db KDBX_PASSWORD=$master KDBX_TEST_EXPECTED=$value \
  ansible-playbook tests/ee/lookup.yml

echo "== Lookup: wrong master password fails without showing it"
if out=$(KDBX_DATABASE=$db KDBX_PASSWORD=wrong-$master KDBX_TEST_EXPECTED=$value \
  ansible-playbook tests/ee/lookup.yml 2>&1); then
  echo "FAIL: wrong password accepted"; exit 1
fi
if grep -qF -e "$master" -e "$value" <<<"$out"; then
  echo "FAIL: password or secret leaked in the output"; exit 1
fi
echo "ok"

echo "== playbooks/secrets.yml with the password on stdin, exactly as deploy.sh secrets runs it"
printf '%s\n' "$master" | KDBX_DATABASE=$db \
  bash -c 'IFS= read -r KDBX_PASSWORD; export KDBX_PASSWORD; exec ansible-playbook "$@"' secrets \
  playbooks/secrets.yml -i inventory/dev/hosts.yml -e secrets_rotate=test_dummy
if printf '%s\n' "$master" | KDBX_DATABASE=$db \
  bash -c 'IFS= read -r KDBX_PASSWORD; export KDBX_PASSWORD; exec ansible-playbook "$@"' secrets \
  playbooks/secrets.yml -i inventory/dev/hosts.yml -e secrets_rotate=undeclared >/dev/null 2>&1; then
  echo "FAIL: rotating an undeclared secret was accepted"; exit 1
fi
echo "ok"

echo "== Known trap: a lookup in loop: is evaluated even with when: false"
if out=$(KDBX_PASSWORD=$master ansible-playbook tests/ee/lookup_loop_trap.yml 2>&1); then
  echo "FAIL: expected the loop trap play to fail"; exit 1
fi
grep -q "database not found" <<<"$out" || { echo "FAIL: failed for another reason:"; echo "$out"; exit 1; }
echo "ok (documented in docs/SPEC.md, section 4.5)"

echo "All execution environment tests passed"
