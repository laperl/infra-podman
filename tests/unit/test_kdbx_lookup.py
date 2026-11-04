"""Unit tests for plugins/lookup/kdbx.py with a fake keepassxc-cli (stdlib only).

Run from the repository root:  python3 -m unittest discover -s tests/unit -v
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

from ansible.errors import AnsibleError
from ansible.plugins.loader import lookup_loader

REPO = Path(__file__).resolve().parents[2]
lookup_loader.add_directory(str(REPO / "plugins" / "lookup"))

FAKE_PASSWORD = "fake-master-password"  # fictitious, test only
FAKE_SECRET = "NotARealSecret-123"  # fictitious, test only

FAKE_CLI = textwrap.dedent(
    f"""\
    #!{sys.executable}
    # Fake keepassxc-cli: records argv and stdin, then behaves like 'ls' (titles of
    # FAKE_CLI_LS, comma separated) or 'show -a password'.
    import json, os, sys
    stdin = sys.stdin.read()
    with open(os.environ["FAKE_CLI_LOG"], "a") as log:
        log.write(json.dumps({{"argv": sys.argv[1:], "stdin": stdin}}) + "\\n")
    if sys.argv[1] == "ls":
        if os.environ.get("FAKE_CLI_MODE") == "nogroup":
            sys.stderr.write("Cannot find group " + sys.argv[-1] + ".\\n")
            sys.exit(1)
        listing = os.environ.get("FAKE_CLI_LS", "a,b,postgres_password,Sub/")
        sys.stdout.write("\\n".join(listing.split(",")) + "\\n")
        sys.exit(0)
    mode = os.environ.get("FAKE_CLI_MODE", "ok")
    if mode == "fail":
        sys.stdout.write("{FAKE_SECRET}\\n")
        sys.stderr.write("Error: got " + stdin.strip() + "\\n")
        sys.exit(1)
    if mode == "empty":
        sys.stdout.write("\\n")
        sys.exit(0)
    sys.stdout.write("{FAKE_SECRET}-" + sys.argv[-1].split("/")[-1] + "\\n")
    """
)


class KdbxLookupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        self.cli = tmp / "keepassxc-cli"
        self.cli.write_text(FAKE_CLI)
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IXUSR)
        self.database = tmp / "test.kdbx"
        self.database.write_bytes(b"not a real database")
        self.log = tmp / "calls.jsonl"
        self.env = mock.patch.dict(
            os.environ, {"KDBX_PASSWORD": FAKE_PASSWORD, "FAKE_CLI_LOG": str(self.log)}
        )
        self.env.start()
        self.lookup = lookup_loader.get("kdbx", loader=None, templar=None)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def run_lookup(self, *terms, variables=None, **options):
        options.setdefault("database", str(self.database))
        options.setdefault("cli", str(self.cli))
        if variables is None:
            variables = {"infra_site": "test-site"}
        return self.lookup.run(list(terms), variables=variables, **options)

    def calls(self, command=None):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [c for c in calls if command is None or c["argv"][0] == command]

    def test_password_goes_through_stdin_never_argv(self):
        self.run_lookup("postgres_password")
        for call in self.calls():
            self.assertEqual(call["stdin"], FAKE_PASSWORD + "\n")
            self.assertNotIn(FAKE_PASSWORD, " ".join(call["argv"]))

    def test_command_line_matches_spec(self):
        self.run_lookup("postgres_password")
        self.assertEqual(
            [c["argv"] for c in self.calls()],
            [["ls", "-q", str(self.database), "test-site"],
             ["show", "-q", "-s", "-a", "password", str(self.database),
              "test-site/postgres_password"]],
        )

    def test_group_is_the_installation_name(self):
        self.run_lookup("a", variables={"infra_site": "laperl"})
        self.assertEqual(self.calls("show")[0]["argv"][-1], "laperl/a")

    def test_missing_installation_name_fails_without_calling_cli(self):
        for variables in ({}, {"infra_site": ""}, {"infra_site": "Infra_Podman"},
                          {"infra_site": "a/b"}, {"infra_site": "-x"}):
            with self.subTest(variables=variables):
                with self.assertRaisesRegex(AnsibleError, "name of the installation"):
                    self.run_lookup("a", variables=variables)
        self.assertFalse(self.log.exists())

    def test_missing_group_explains_the_rename(self):
        with mock.patch.dict(os.environ, {"FAKE_CLI_MODE": "nogroup"}):
            with self.assertRaisesRegex(AnsibleError, "group named exactly 'test-site'"):
                self.run_lookup("a")
        self.assertEqual(self.calls("show"), [])

    def test_missing_entry_fails_before_reading(self):
        with self.assertRaisesRegex(AnsibleError, "no entry 'zzz' in the group 'test-site'"):
            self.run_lookup("zzz")
        self.assertEqual(self.calls("show"), [])

    def test_duplicate_title_fails_before_reading(self):
        with mock.patch.dict(os.environ, {"FAKE_CLI_LS": "a,b,a"}):
            with self.assertRaisesRegex(AnsibleError, "2 entries titled 'a'"):
                self.run_lookup("a")
        self.assertEqual(self.calls("show"), [])

    def test_a_subgroup_is_not_an_entry(self):
        with self.assertRaisesRegex(AnsibleError, "no entry 'Sub'"):
            self.run_lookup("Sub")

    def test_returns_value_without_trailing_newline(self):
        self.assertEqual(self.run_lookup("a"), [f"{FAKE_SECRET}-a"])

    def test_one_read_per_term(self):
        self.assertEqual(self.run_lookup("a", "b"), [f"{FAKE_SECRET}-a", f"{FAKE_SECRET}-b"])
        self.assertEqual(len(self.calls("show")), 2)

    def test_explicit_group_and_attribute(self):
        self.run_lookup("b", group="other-site", attribute="username")
        (call,) = self.calls("show")
        self.assertEqual(call["argv"][4], "username")
        self.assertEqual(call["argv"][-1], "other-site/b")

    def test_database_from_environment(self):
        with mock.patch.dict(os.environ, {"KDBX_DATABASE": str(self.database)}):
            self.lookup.run(["a"], variables={"infra_site": "test-site"}, cli=str(self.cli))
        self.assertEqual(self.calls("show")[0]["argv"][5], str(self.database))

    def test_missing_password_fails_without_calling_cli(self):
        del os.environ["KDBX_PASSWORD"]
        with self.assertRaisesRegex(AnsibleError, "KDBX_PASSWORD is not set"):
            self.run_lookup("a")
        self.assertFalse(self.log.exists())

    def test_missing_database_fails(self):
        with self.assertRaisesRegex(AnsibleError, "database not found"):
            self.run_lookup("a", database="/nonexistent/test.kdbx")

    def test_failure_does_not_leak_secret_or_password(self):
        with mock.patch.dict(os.environ, {"FAKE_CLI_MODE": "fail"}):
            with self.assertRaises(AnsibleError) as ctx:
                self.run_lookup("a")
        message = str(ctx.exception)
        self.assertIn("exit code 1", message)
        self.assertNotIn(FAKE_SECRET, message)
        self.assertNotIn(FAKE_PASSWORD, message)

    def test_empty_value_fails(self):
        with mock.patch.dict(os.environ, {"FAKE_CLI_MODE": "empty"}):
            with self.assertRaisesRegex(AnsibleError, "is empty"):
                self.run_lookup("a")

    def test_missing_cli_fails_cleanly(self):
        with self.assertRaisesRegex(AnsibleError, "not found in PATH"):
            self.run_lookup("a", cli="/nonexistent/keepassxc-cli")


if __name__ == "__main__":
    unittest.main()
