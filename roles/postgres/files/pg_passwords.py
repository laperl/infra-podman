#!/usr/bin/env python3
"""Set the password of each application user from its Podman secret (docs/POSTGRES.md, 4).

Run by the postgres role as the service user, on the server:
    pg_passwords.py --container dev-pg-main --superuser ci_admin \
        --users '[{"role": "app1", "secret": "dev-app1-db-password"}]' [--check]

- The secret is read with `podman secret inspect --showsecret` and never leaves this process:
  not in arguments, not in the output.
- PostgreSQL never sees the password in clear text: this script computes the SCRAM-SHA-256
  verifier and sends that. PostgreSQL stores an already encrypted password as it is
  (CREATE ROLE, PASSWORD), and a statement in clear text could end up in its log.
- Idempotent: if the stored verifier already matches the secret, nothing is sent.
- Prints JSON: {"changed": [roles]} (with --check: what would change).

Passwords must be printable ASCII. For those, SASLprep (RFC 4013), which PostgreSQL applies
before hashing, changes nothing; for others this script would compute another verifier.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys

SALT_BYTES = 16  # what PostgreSQL uses for its own verifiers


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def scram_keys(password: str, salt: bytes, iterations: int) -> tuple[bytes, bytes]:
    """StoredKey and ServerKey of RFC 5802, with SHA-256 (RFC 7677)."""
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("ascii"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    return stored_key, server_key


def build_verifier(password: str, iterations: int, salt: bytes | None = None) -> str:
    """SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>, as in pg_authid."""
    salt = os.urandom(SALT_BYTES) if salt is None else salt
    stored_key, server_key = scram_keys(password, salt, iterations)
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def verifier_matches(password: str, verifier: str) -> bool:
    """True if the stored verifier was built from this password."""
    try:
        method, rest = verifier.split("$", 1)
        params, keys = rest.split("$", 1)
        iterations, salt = params.split(":", 1)
        stored_key, server_key = keys.split(":", 1)
        if method != "SCRAM-SHA-256":
            return False
        want_stored, want_server = scram_keys(password, base64.b64decode(salt), int(iterations))
    except (ValueError, TypeError):
        return False
    return (hmac.compare_digest(want_stored, base64.b64decode(stored_key))
            and hmac.compare_digest(want_server, base64.b64decode(server_key)))


def check_password(role: str, password: str) -> None:
    if not password:
        raise ValueError(f"the secret of {role} is empty")
    if any(not 0x20 <= ord(c) <= 0x7E for c in password):
        raise ValueError(f"the password of {role} has characters other than printable ASCII; "
                         "generate it again in KeePassXC with letters, digits and symbols only")


def run(argv: list[str], stdin: str | None = None) -> str:
    result = subprocess.run(argv, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                            capture_output=True, text=True, check=False, cwd="/")
    if result.returncode != 0:
        # Never echo stdin: it may hold a verifier.
        raise RuntimeError(f"{' '.join(argv[:4])} failed: {result.stderr.strip()}")
    return result.stdout


def read_secret(name: str) -> str:
    result = subprocess.run(["podman", "secret", "inspect", "--showsecret", name],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, cwd="/")
    if result.returncode != 0:
        raise LookupError(name)
    return json.loads(result.stdout)[0]["SecretData"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--container", required=True)
    parser.add_argument("--superuser", required=True)
    parser.add_argument("--users", required=True, help="JSON list of {role, secret}")
    parser.add_argument("--check", action="store_true", help="only say what would change")
    args = parser.parse_args()
    users = json.loads(args.users)

    psql = ["podman", "exec", "-i", args.container, "psql", "-X", "-q", "-t", "-A",
            "-v", "ON_ERROR_STOP=1", "-U", args.superuser, "-d", "postgres"]
    roles = ", ".join(f"'{u['role']}'" for u in users)
    stored = {}
    for line in run(psql + ["-c", f"SELECT rolname, coalesce(rolpassword, '') FROM pg_authid "
                                  f"WHERE rolname IN ({roles})"]).splitlines():
        role, _, verifier = line.partition("|")
        stored[role] = verifier
    iterations = int(run(psql + ["-c", "SHOW scram_iterations"]).strip())

    changed, missing, statements = [], [], []
    for user in users:
        role, secret = user["role"], user["secret"]
        try:
            password = read_secret(secret)
        except LookupError:
            missing.append(secret)
            continue
        check_password(role, password)
        if role in stored and verifier_matches(password, stored[role]):
            continue
        if role not in stored and not args.check:
            raise RuntimeError(f"the role {role} does not exist")
        changed.append(role)
        statements.append(f"ALTER ROLE \"{role}\" PASSWORD '{build_verifier(password, iterations)}';")

    if missing:
        print(json.dumps({"missing": missing}))
        return 3
    if statements and not args.check:
        run(psql + ["-f", "-"], stdin="\n".join(statements) + "\n")
    print(json.dumps({"changed": changed}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError) as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
