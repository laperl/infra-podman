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
  - The group is the name of the installation, the inventory variable C(infra_site)
    (for example C(laperl)). There is no default; without it, nothing is read.
  - Before reading, lists the group (C(keepassxc-cli ls)) and fails if the entry is missing
    or if two entries share its title, so the value read is never ambiguous.
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
    description:
      - Group that contains the entries of this installation (SPEC 4.5).
      - When not given, the inventory variable C(infra_site). Lower case letters, digits
        and hyphens, starting with a letter.
    type: str
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
    data: "{{ lookup('kdbx', 'postgres_password') }}"  # group: infra_site, e.g. laperl
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
import re
import subprocess

from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase


# Name of the installation (infra_site), also its group in KeePassXC.
SITE_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)

        database = self.get_option("database")
        group = str(self.get_option("group") or (variables or {}).get("infra_site") or "")
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
        if not SITE_RE.match(group):
            raise AnsibleError(
                "kdbx: the name of the installation is missing or not valid "
                f"(infra_site: {group!r}). Declare it in group_vars/all.yml of the data "
                "repository, for example 'infra_site: laperl': lower case letters, digits "
                "and hyphens. It is also the name of the group in KeePassXC (SPEC 4.5)."
            )
        if not os.path.isfile(database):
            raise AnsibleError(f"kdbx: database not found: {database}")

        titles = self._list(cli, database, group, password, timeout)
        values = []
        for name in terms:
            found = titles.count(name)
            if found == 0:
                raise AnsibleError(
                    f"kdbx: there is no entry '{name}' in the group '{group}' of "
                    f"{os.path.basename(database)}. Create it in KeePassXC with exactly that title."
                )
            if found > 1:
                raise AnsibleError(
                    f"kdbx: the group '{group}' of {os.path.basename(database)} has {found} "
                    f"entries titled '{name}'. Keep only one: otherwise it is not clear which "
                    "value would be used."
                )
            values.append(self._read(cli, database, f"{group}/{name}", attribute, password, timeout))
        return values

    @staticmethod
    def _run(cli, args, password, timeout, what):
        # The password travels only through stdin; argv is visible in the process list.
        try:
            return subprocess.run(
                [cli, *args],
                input=password + "\n",
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise AnsibleError(f"kdbx: '{cli}' not found in PATH") from exc
        except subprocess.TimeoutExpired as exc:
            raise AnsibleError(f"kdbx: keepassxc-cli timed out {what}") from exc

    @classmethod
    def _list(cls, cli, database, group, password, timeout):
        """Titles of the entries directly in the group (subgroups end with '/')."""
        result = cls._run(cli, ["ls", "-q", database, group], password, timeout,
                          f"listing '{group}'")
        if result.returncode != 0:
            detail = result.stderr.strip().replace(password, "***") or "wrong master password?"
            raise AnsibleError(
                f"kdbx: cannot list the group '{group}' of {os.path.basename(database)}: {detail}. "
                f"The entries of this installation go in a group named exactly '{group}' "
                "(infra_site). If you renamed the installation, rename the group in KeePassXC too."
            )
        return [line for line in result.stdout.splitlines() if line and not line.endswith("/")]

    @classmethod
    def _read(cls, cli, database, entry, attribute, password, timeout):
        result = cls._run(cli, ["show", "-q", "-s", "-a", attribute, database, entry],
                          password, timeout, f"reading '{entry}'")

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
