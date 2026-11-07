"""Unit tests for roles/postgres/files/pg_passwords.py (stdlib only).

Run from the repository root:  python3 -m unittest discover -s tests/unit -v

The end-to-end path (podman secret, psql, login over TCP) is tested in the lifecycle
workflow (tests/lifecycle/check-postgres-apps.sh).
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("pg_passwords", REPO / "roles/postgres/files/pg_passwords.py")
pg_passwords = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pg_passwords)

# Built by PostgreSQL 16 itself (ALTER ROLE … PASSWORD 'pencil'), for a fictitious password.
PG_VERIFIER = ("SCRAM-SHA-256$4096:R6rnaWpzXu9ex5RHV2yrIw==$"
               "CdpD21qm2gabUgmRerp2maeu0hgDOEpP+H33ELecGvI=:V65M9k+Fl4C8MMCkmQIWZlIv9nby40tgf3jctJ/H0QY=")


class VerifierTests(unittest.TestCase):
    def test_matches_a_verifier_built_by_postgresql(self):
        self.assertTrue(pg_passwords.verifier_matches("pencil", PG_VERIFIER))

    def test_rejects_another_password(self):
        self.assertFalse(pg_passwords.verifier_matches("pencil2", PG_VERIFIER))

    def test_builds_what_postgresql_builds_with_the_same_salt(self):
        salt = pg_passwords.base64.b64decode("R6rnaWpzXu9ex5RHV2yrIw==")
        self.assertEqual(pg_passwords.build_verifier("pencil", 4096, salt), PG_VERIFIER)

    def test_a_new_verifier_has_a_random_salt_and_matches(self):
        first = pg_passwords.build_verifier("pencil", 4096)
        second = pg_passwords.build_verifier("pencil", 4096)
        self.assertNotEqual(first, second)
        self.assertTrue(pg_passwords.verifier_matches("pencil", first))

    def test_empty_or_other_formats_never_match(self):
        for stored in ["", "md5" + "0" * 32, "SCRAM-SHA-256$x", "garbage"]:
            self.assertFalse(pg_passwords.verifier_matches("pencil", stored), stored)


class PasswordCheckTests(unittest.TestCase):
    def test_printable_ascii_is_accepted(self):
        pg_passwords.check_password("app", "Abc-123_!$'\" ~")

    def test_empty_is_refused(self):
        with self.assertRaises(ValueError):
            pg_passwords.check_password("app", "")

    def test_other_characters_are_refused(self):
        for password in ["ñandú", "tab\there", "line\n"]:
            with self.assertRaises(ValueError):
                pg_passwords.check_password("app", password)


if __name__ == "__main__":
    unittest.main()
