#!/usr/bin/env bash
# Which secrets deploy.sh secrets installs on each machine (playbooks/secrets.yml): the
# group of a secret may be one inventory group or a list of them (R44). Runs the real
# selection tasks of the playbook against a fake inventory, without KeePassXC or Podman.
set -euo pipefail
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/inventory.yml" <<'INV'
all:
  vars:
    infra_secrets:
      - name: only-checked
      - name: one-group
        group: postgres_hosts
        readers: [pg-main]
      - name: two-groups
        group: [backup_clients, backup_servers]
        readers: [backup, backup-server]
  children:
    postgres_hosts: {hosts: {laptop: {}}}
    backup_clients: {hosts: {laptop: {}, vm: {}}}
    backup_servers: {hosts: {server: {}, vm: {}}}
    servers: {hosts: {laptop: {}, vm: {}, server: {}, other: {}}}
INV

# The two selection tasks, copied from the playbook as they are, plus one that prints.
python3 - "$src/playbooks/secrets.yml" "$work/select.yml" <<'PY'
import sys, yaml
plays = yaml.safe_load(open(sys.argv[1]))
play = next(p for p in plays if p["hosts"] == "servers")
tasks = [t for t in play["tasks"] if t["name"] in ("Start with no secrets for this machine", "Choose the secrets of this machine")]
assert len(tasks) == 2, "the selection tasks of secrets.yml changed: update this test"
tasks.append({"name": "Print", "ansible.builtin.debug": {"msg": "SELECTED {{ inventory_hostname }}={{ secrets_here | map(attribute='name') | join(',') }}"}})
yaml.safe_dump([{"hosts": "servers", "gather_facts": False, "connection": "local", "tasks": tasks}], open(sys.argv[2], "w"))
PY

out=$(ansible-playbook -i "$work/inventory.yml" "$work/select.yml" 2>&1) || { echo "::error::selection playbook failed: $out"; exit 1; }
failures=0
want() {
  if grep -q "SELECTED $1=$2\"" <<<"$out"; then echo "ok: $1 gets '$2'"; else echo "::error::$1 should get '$2'"; failures=$((failures + 1)); fi
}
want laptop "one-group,two-groups"
want vm "two-groups"
want server "two-groups"
want other ""

# The declaration: each name once, and who reads each installed secret (readers:).
python3 - "$src/playbooks/secrets.yml" "$work/declared.yml" <<'PY'
import sys, yaml
plays = yaml.safe_load(open(sys.argv[1]))
play = next(p for p in plays if p["hosts"] == "control")
tasks = [t for t in play["tasks"] if t["name"] == "Check the declaration of the secrets"]
assert len(tasks) == 1, "the declaration check of secrets.yml changed: update this test"
yaml.safe_dump([{"hosts": "localhost", "gather_facts": False, "connection": "local", "vars": {"infra_env": "dev"}, "tasks": tasks}], open(sys.argv[2], "w"))
PY
declared() {  # declared <accepted|refused> <description> <infra_secrets as JSON>
  if ansible-playbook -i localhost, "$work/declared.yml" -e "{\"infra_secrets\": $3}" >/dev/null 2>&1; then got=accepted; else got=refused; fi
  if [[ $got == "$1" ]]; then echo "ok: $2 is $1"; else echo "::error::$2 should be $1"; failures=$((failures + 1)); fi
}
declared accepted "a secret with readers and one only checked" '[{"name": "a", "group": "g", "readers": ["pg-main"]}, {"name": "only-checked"}]'
declared accepted "a secret that two read, in one line" '[{"name": "a", "group": ["g", "h"], "readers": ["pg-main", "ff-casa"]}]'
declared refused "the same name twice" '[{"name": "a", "group": "g", "readers": ["x"]}, {"name": "a", "group": "h", "readers": ["y"]}]'
declared refused "a secret with a group and no readers" '[{"name": "a", "group": "g"}]'
declared refused "readers that is not a list" '[{"name": "a", "group": "g", "readers": "pg-main"}]'
declared refused "an empty list of readers" '[{"name": "a", "group": "g", "readers": []}]'

[[ $failures -eq 0 ]] || exit 1
echo "All secrets selection tests passed"
