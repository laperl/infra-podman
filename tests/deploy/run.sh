#!/usr/bin/env bash
# Tests for deploy.sh with fake ansible-navigator and podman and throwaway SSH keys.
# Needs git and ssh-keygen. Never touches the real ~/.config, ~/.ssh or any server.
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- isolated HOME, keys and trust anchor --------------------------------------------
export HOME=$work/home
unset XDG_CONFIG_HOME XDG_STATE_HOME SSH_AUTH_SOCK
mkdir -p "$HOME/.config/infra-podman"
ssh-keygen -q -t ed25519 -N '' -C trusted -f "$work/trusted"
ssh-keygen -q -t ed25519 -N '' -C attacker -f "$work/attacker"
echo "operator@example.invalid namespaces=\"git\" $(cat "$work/trusted.pub")" \
  >"$HOME/.config/infra-podman/allowed_signers"
log=$HOME/.local/state/infra-podman/deploy.log

# --- fakes ------------------------------------------------------------------------------
calls=$work/calls
cat >"$work/fake-navigator" <<'EOF'
#!/usr/bin/env bash
printf 'navigator %s\n' "$*" >>"$FAKE_CALLS"
exit "${FAKE_RC:-0}"
EOF
cat >"$work/fake-podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$FAKE_CALLS"
printf 'stdin %s\n' "$(cat)" >>"$FAKE_CALLS"
EOF
chmod +x "$work/fake-navigator" "$work/fake-podman"
export INFRA_NAVIGATOR_BIN=$work/fake-navigator INFRA_PODMAN_BIN=$work/fake-podman FAKE_CALLS=$calls
# Where deploy.sh leaves the copy of the data repository; absent until a test creates it.
export INFRA_DATA_COPY_DIR=$work/data-copy

# --- a throwaway copy of the repository, without inventory (SPEC 4.13) ---------------
repo=$work/repo
mkdir -p "$repo/docs"
cp -r "$src/deploy.sh" "$src/ansible-navigator.yml" "$src/playbooks" "$repo/"
cp "$src/docs/allowed_signers" "$repo/docs/"
printf '.gitignore\n' >"$repo/.gitignore"
g() { git -C "$repo" -c user.name=op -c user.email=operator@example.invalid \
  -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen "$@"; }
g init -q
g add -A
g commit -q -m initial

# --- a throwaway data repository, built from inventory.example (SPEC 4.13) -------------
data=$work/data/infra-podman
mkdir -p "$data"
cp -r "$src/inventory.example" "$data/inventory"
d() { git -C "$data" -c user.name=op -c user.email=operator@example.invalid \
  -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen "$@"; }
d init -q
d add -A
d commit -q -m "initial data, unsigned"
conf=$HOME/.config/infra-podman/deploy.conf
echo "data_repo = $data" >"$conf"

# --- helpers ----------------------------------------------------------------------------
failures=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

expect() { # expect <ok|refused> <description> <deploy.sh args...>
  local want=$1 what=$2 rc=0
  shift 2
  : >"$calls"
  "$repo/deploy.sh" "$@" </dev/null >"$work/out" 2>&1 || rc=$?
  # SHOW_OUT=1 tests/deploy/run.sh prints every deploy.sh message.
  [[ -n ${SHOW_OUT:-} ]] && sed "s/^/    | /" "$work/out"
  local last
  last=$(tail -1 "$log" 2>/dev/null | cut -f8)
  if [[ $want == ok && $rc -eq 0 && $last == ok ]]; then
    pass "$what"
  elif [[ $want == refused && $rc -ne 0 && ! -s $calls && $last == refused ]]; then
    pass "$what"
  else
    fail "$what (rc=$rc, log=$last)"
    sed 's/^/    /' "$work/out"
  fi
}

called_with() { # called_with <description> <grep -E pattern>
  if grep -Eq -- "$2" "$calls"; then pass "$1"; else fail "$1"; sed 's/^/    /' "$calls"; fi
}

# --- the example inventory never forwards the SSH agent (R17) ---------------------------
for e in dev prod; do
  if grep -q '^ansible_ssh_common_args: "-o ForwardAgent=no"$' "$src/inventory.example/$e/group_vars/all.yml"; then
    pass "example inventory $e disables SSH agent forwarding"
  else
    fail "example inventory $e disables SSH agent forwarding"
  fi
done
if [[ -e $src/inventory ]]; then
  fail "the code repository has no inventory/ (it lives in the data repository, SPEC 4.13)"
else
  pass "the code repository has no inventory/ (it lives in the data repository, SPEC 4.13)"
fi

# --- the data repository is required and must be its own repository -------------------
: >"$conf"
expect refused "dev needs data_repo in deploy.conf" plan check --env dev
echo "data_repo = $work/nowhere" >"$conf"
expect refused "a missing data repository is refused" plan check --env dev
mkdir -p "$work/plain"
echo "data_repo = $work/plain" >"$conf"
expect refused "a folder that is not a git repository is refused" plan check --env dev
echo "data_repo = $data/inventory" >"$conf"
expect refused "a subfolder of a git repository is refused" plan check --env dev
mkdir -p "$repo/data-inside"
git -C "$repo/data-inside" init -q
echo "data_repo = $repo/data-inside" >"$conf"
expect refused "a data repository inside the code repository is refused" plan check --env dev
rm -rf "$repo/data-inside"
mkdir -p "$work/empty"
git -C "$work/empty" init -q
echo "data_repo = $work/empty" >"$conf"
expect refused "a data repository without commits is refused" plan check --env dev
echo "data_repo = $data" >"$conf"
mv "$data/inventory/dev" "$work/dev-aside"
expect refused "a data repository without inventory/dev/hosts.yml is refused" plan check --env dev
mv "$work/dev-aside" "$data/inventory/dev"

# --- DEV: no tag needed ---------------------------------------------------------------
expect ok "dev plan runs without a tag" plan check --env dev
called_with "dev plan uses the dev inventory of the data repository, --check, --diff and asks for the sudo password" \
  "^navigator run playbooks/check.yml -i $data/inventory/dev/hosts.yml -- --check --diff --ask-become-pass\$"
if tail -1 "$log" | cut -f6 | grep -q '^data@[0-9a-f]*$'; then pass "the log records the data commit"; else fail "the log records the data commit"; fi
expect ok "dev apply runs without --check" apply check --env dev --limit example-vm
called_with "dev apply passes --diff, --ask-become-pass and --limit, not --check" \
  "^navigator run playbooks/check.yml -i $data/inventory/dev/hosts.yml -- --diff --ask-become-pass --limit example-vm\$"
touch "$data/scratch"
expect ok "dev accepts unsigned and uncommitted data" plan check --env dev
if tail -1 "$log" | cut -f6 | grep -q '+dirty$'; then pass "the log marks dirty data"; else fail "the log marks dirty data"; fi
rm "$data/scratch"

if grep -q -- '"--network=host"' "$src/ansible-navigator.yml"; then
  pass "the Ansible container uses the host network, to reach the laptop on 127.0.0.1 (R23)"
else
  fail "the Ansible container uses the host network, to reach the laptop on 127.0.0.1 (R23)"
fi

# --- the copy of the data repository for the backup (SPEC 4.11) -----------------------
expect ok "without the copy directory nothing is copied, and nothing fails" plan check --env dev
if [[ ! -e $INFRA_DATA_COPY_DIR ]]; then pass "deploy.sh does not create the copy directory"; else fail "deploy.sh does not create the copy directory"; fi
mkdir -p "$INFRA_DATA_COPY_DIR"
expect ok "with the copy directory, a successful run leaves the copy" plan check --env dev
bundle=$INFRA_DATA_COPY_DIR/infra-podman-data.bundle
if git bundle verify "$bundle" >/dev/null 2>&1 && git clone -q "$bundle" "$work/restored" 2>/dev/null \
  && [[ $(git -C "$work/restored" rev-parse HEAD) == $(git -C "$data" rev-parse HEAD) ]]; then
  pass "the copy is a bundle of the data repository that git can clone"
else
  fail "the copy is a bundle of the data repository that git can clone"
fi
if [[ $(stat -c %a "$bundle") == 640 ]]; then pass "the copy is readable by owner and group only"; else fail "the copy is readable by owner and group only ($(stat -c %a "$bundle"))"; fi
rm -rf "$work/restored" "$bundle"
FAKE_RC=3 "$repo/deploy.sh" plan check --env dev </dev/null >/dev/null 2>&1 || true
if [[ ! -e $bundle ]]; then pass "a failed run leaves no copy"; else fail "a failed run leaves no copy"; fi

# --- input validation -------------------------------------------------------------------
expect refused "unknown environment is refused" plan check --env staging
expect refused "unknown playbook is refused" plan nope --env dev
expect refused "path traversal in playbook name is refused" plan ../deploy --env dev
expect refused "invalid --limit is refused" plan check --env dev --limit 'a;b'

# --- PROD: signed tag required (default env) ------------------------------------------
expect refused "prod is the default and needs a tag" plan check
g tag -a v0.0.1 -m unsigned
expect refused "an unsigned annotated tag is refused" plan check
g -c user.signingkey="$work/attacker" tag -s v0.0.2 -m untrusted
expect refused "a tag signed by an untrusted key is refused" plan check

# R4: the attacker adds their key to the repo copy of allowed_signers and signs a tag.
echo "operator@example.invalid namespaces=\"git\" $(cat "$work/attacker.pub")" >>"$repo/docs/allowed_signers"
g commit -q -am "add attacker key to the repo copy"
g -c user.signingkey="$work/attacker" tag -s v0.0.3 -m attack
expect refused "R4: a key added to the repo's allowed_signers is not trusted" plan check

g reset -q --hard HEAD~1
g -c user.signingkey="$work/trusted" tag -s v0.1.0 -m good

# --- PROD: the data repository must be clean and its last commit signed (SPEC 4.10) ---
expect refused "prod refuses an unsigned data commit, even with a signed tag" plan check
echo "# untrusted" >>"$data/inventory/prod/hosts.yml"
d -c user.signingkey="$work/attacker" commit -q -S -am "data signed by an untrusted key"
expect refused "prod refuses a data commit signed by an untrusted key" plan check
d reset -q --hard HEAD~1
d -c user.signingkey="$work/trusted" commit -q -S --allow-empty -m "data signed by the operator"
expect ok "a signed tag and a signed data commit are accepted" plan check
called_with "prod plan uses the prod inventory of the data repository" \
  "^navigator run playbooks/check.yml -i $data/inventory/prod/hosts.yml -- --check --diff --ask-become-pass\$"
if tail -1 "$log" | cut -f5 | grep -q '^tag:v0.1.0@'; then pass "the log records the verified tag"; else fail "the log records the verified tag"; fi
if tail -1 "$log" | cut -f6 | grep -qx "data@$(git -C "$data" rev-parse --short HEAD)"; then
  pass "the log records the verified data commit"
else
  fail "the log records the verified data commit"
fi

echo "# pending" >>"$data/inventory/prod/hosts.yml"
expect refused "prod refuses uncommitted changes in the data repository" plan check
d checkout -q -- inventory/prod/hosts.yml
touch "$data/untracked-file"
expect refused "prod refuses untracked files in the data repository" plan check
rm "$data/untracked-file"

touch "$repo/untracked-file"
expect refused "prod refuses a dirty checkout even with a signed tag" plan check
rm "$repo/untracked-file"

anchor=$HOME/.config/infra-podman/allowed_signers
mv "$anchor" "$anchor.real"
ln -s "$repo/docs/allowed_signers" "$anchor"
expect refused "allowed_signers pointing into the repo is refused" plan check
rm "$anchor"
cp "$anchor.real" "$data/allowed_signers"
d add allowed_signers
d -c user.signingkey="$work/trusted" commit -q -S -m "a copy of the trust anchor"
ln -s "$data/allowed_signers" "$anchor"
expect refused "allowed_signers pointing into the data repository is refused" plan check
rm "$anchor"
d reset -q --hard HEAD~1
expect refused "a missing allowed_signers is refused" plan check
mv "$anchor.real" "$anchor"

expect refused "apply in prod needs an interactive terminal" apply check

# --- failures are logged ----------------------------------------------------------------
if FAKE_RC=3 "$repo/deploy.sh" plan check --env dev </dev/null >/dev/null 2>&1; then
  fail "navigator failure is propagated"
else
  pass "navigator failure is propagated"
fi
if tail -1 "$log" | cut -f8 | grep -qx 'failed(3)'; then pass "the failure is logged"; else fail "the failure is logged"; fi

# --- secrets: password over stdin only ---------------------------------------------------
fake_password="fake-master-password-$RANDOM"  # fictitious, test only
touch "$work/dev.kdbx"
echo "kdbx_dev = $work/dev.kdbx" >>"$conf"
expect refused "secrets needs an SSH agent" secrets --env dev
export SSH_AUTH_SOCK=$work/agent.sock
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SSH_AUTH_SOCK"

: >"$calls"
fake_become="fake-sudo-password-$RANDOM"  # fictitious, test only
if printf '%s\n%s\n' "$fake_password" "$fake_become" | "$repo/deploy.sh" secrets --env dev --limit example-vm --rotate test_dummy >"$work/out" 2>&1; then
  pass "dev secrets runs"
else
  fail "dev secrets runs"; sed 's/^/    /' "$work/out"
fi
called_with "the master password reaches the container on stdin" "^stdin ${fake_password}\$"
called_with "the sudo password follows it on stdin" "^${fake_become}\$"
if grep '^podman ' "$calls" | grep -qF -e "$fake_password" -e "$fake_become"; then fail "the passwords are not in podman's arguments"; else pass "the passwords are not in podman's arguments"; fi
if grep -qF -e "$fake_password" -e "$fake_become" "$log" "$work/out"; then fail "the passwords are not in the log or output"; else pass "the passwords are not in the log or output"; fi
called_with "secrets uses the pinned image, the host network, the dev inventory, --limit and --rotate" \
  '^podman run --rm -i --user root --security-opt label=disable --network=host .* ghcr\.io/[^ ]+@sha256:[0-9a-f]{64} bash -c .* secrets playbooks/secrets.yml -i /inventory/hosts.yml --limit example-vm,localhost -e secrets_rotate=test_dummy$'
called_with "secrets mounts the inventory of the data repository read-only" "-v $data/inventory/dev:/inventory:ro "
called_with "secrets mounts the database read-only" "-v $work/dev.kdbx:/kdbx/database.kdbx:ro"
called_with "secrets mounts the SSH agent at the same path, like ansible-navigator" "-v $SSH_AUTH_SOCK:$SSH_AUTH_SOCK -e SSH_AUTH_SOCK=$SSH_AUTH_SOCK "
if grep '^podman ' "$calls" | grep -q 'ansible-navigator'; then fail "secrets does not use ansible-navigator"; else pass "secrets does not use ansible-navigator"; fi

expect refused "secrets refuses an invalid --rotate name" secrets --env dev --rotate 'x;rm'
echo "data_repo = $data" >"$conf"
expect refused "secrets refuses when the .kdbx is not configured" secrets --env dev
g tag -d v0.1.0 >/dev/null
expect refused "secrets in prod also needs a signed tag" secrets

if [[ $failures -gt 0 ]]; then
  echo "$failures deploy.sh test(s) failed"
  exit 1
fi
echo "All deploy.sh tests passed"
