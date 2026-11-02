# -*- coding: utf-8 -*-
# Lookup plugin that reads secrets from a KeePassXC database through keepassxc-cli.
# It is the only piece of the repository that knows how secrets are read (SPEC 4.5):
# replacing its implementation must not require changes in playbooks or roles.

from __future__ import annotations

DOCUMENTATION = r"""
name: kdbx
short_description: Read secrets from a KeePassXC database with keepassxc-cli
description:
  - Runs C(keepassxc-cli show -q -s -a <attribute> <database> <group>/<name>) once per term.
  - The master password is read from the environment variable named by O(password_env)
    and handed to keepassxc-cli on standard input, never as an argument.
  - Every call decrypts the database again. Use it only where a secret is created or rotated,
    behind a C(when:) that is false when the secret already exists.
  - Always use it in tasks with C(no_log: true).
options:
  _terms:
    description: Secret names. Each one is looked up as C(<group>/<name>).
    required: true
  database:
    description: Path to the C(.kdbx) file.
    type: path
    env:
      - name: KDBX_DATABASE
    required: true
  group:
    description: Group that contains the infrastructure entries (SPEC 4.5).
    type: str
    default: Infra_Podman
  attribute:
    description: Entry attribute to read.
    type: str
    default: password
  password_env:
    description: Name of the environment variable that holds the master password.
    type: str
    default: KDBX_PASSWORD
  cli:
    description: keepassxc-cli executable.
    type: str
    default: keepassxc-cli
  timeout:
    description: Seconds to wait for each keepassxc-cli call.
    type: int
    default: 120
"""

EXAMPLES = r"""
- name: Create the Postgres password secret only if it does not exist
  containers.podman.podman_secret:
    name: postgres_password
    data: "{{ lookup('kdbx', 'postgres_password') }}"
  no_log: true
  when: "'postgres_password' not in existing_secrets"
"""

RETURN = r"""
_raw:
  description: One value per term, without the trailing newline printed by keepassxc-cli.
  type: list
  elements: str
"""

import os
import subprocess

from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)

        database = self.get_option("database")
        group = self.get_option("group").strip("/")
        attribute = self.get_option("attribute")
        password_env = self.get_option("password_env")
        cli = self.get_option("cli")
        timeout = self.get_option("timeout")

        password = os.environ.get(password_env)
        if not password:
            raise AnsibleError(
                f"kdbx: environment variable {password_env} is not set. "
                "Run this through 'deploy.sh secrets', which asks for the master password."
            )
        if not os.path.isfile(database):
            raise AnsibleError(f"kdbx: database not found: {database}")

        return [self._read(cli, database, f"{group}/{name}" if group else name,
                           attribute, password, timeout)
                for name in terms]

    @staticmethod
    def _read(cli, database, entry, attribute, password, timeout):
        # The password travels only through stdin; argv is visible in the process list.
        command = [cli, "show", "-q", "-s", "-a", attribute, database, entry]
        try:
            result = subprocess.run(
                command,
                input=password + "\n",
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise AnsibleError(f"kdbx: '{cli}' not found in PATH") from exc
        except subprocess.TimeoutExpired as exc:
            raise AnsibleError(f"kdbx: keepassxc-cli timed out reading '{entry}'") from exc

        if result.returncode != 0:
            # Never echo stdout (it may hold the secret) nor anything containing the password.
            detail = result.stderr.strip().replace(password, "***") or "wrong master password?"
            raise AnsibleError(
                f"kdbx: cannot read '{entry}' (exit code {result.returncode}): {detail}"
            )

        value = result.stdout
        if value.endswith("\n"):
            value = value[:-1]
        if value == "":
            raise AnsibleError(f"kdbx: attribute '{attribute}' of '{entry}' is empty")
        return value
