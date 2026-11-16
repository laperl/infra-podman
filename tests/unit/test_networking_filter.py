"""networking.egress values (plugins/filter/networking.py, R59)."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2] / "plugins/filter/networking.py"
spec = importlib.util.spec_from_file_location("networking_filter", PLUGIN)
networking_filter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(networking_filter)
problems = networking_filter.egress_problems


class EgressProblems(unittest.TestCase):
    def test_what_is_fine(self) -> None:
        for value in (False, True, ["100.64.0.7"], ["192.168.1.0/24", "100.64.0.7/32"], ["10.0.0.0/16", "10.91.0.0/16"]):
            self.assertEqual(problems(value), [], value)

    def test_what_is_not(self) -> None:
        for value, part in (
            ("internet", "true, false or a list"),
            ([], "true, false or a list"),
            (None, "true, false or a list"),
            (["backup.example.ts.net"], "a name is not possible"),
            (["fd7a::1"], "is not IPv4"),
            (["0.0.0.0/0"], "write egress: true"),
            (["10.90.3.4"], "overlaps 10.90.0.0/16"),
            (["10.0.0.0/8"], "overlaps 10.90.0.0/16"),
        ):
            found = problems(value)
            self.assertEqual(len(found), 1, value)
            self.assertIn(part, found[0])

    def test_every_bad_item_is_named(self) -> None:
        self.assertEqual(len(problems(["100.64.0.7", "nope", "10.90.0.1"])), 2)


MACHINE = {
    "postgres_instances": [{"name": "laptop"}, {"name": "test"}],
    "firefly_instances": [
        {"name": "casa", "networking": {"connects_to": ["pg-laptop"]}},
        {"name": "canary", "networking": {"connects_to": ["pg-laptop", "pg-test"]}},
        {"name": "solo"},
    ],
}
APPS = {"postgres": "pg", "firefly": "ff"}


class ConnectsTo(unittest.TestCase):
    def test_instances_and_clients(self) -> None:
        self.assertEqual(networking_filter.instance_ids(APPS, MACHINE),
                         ["ff-canary", "ff-casa", "ff-solo", "pg-laptop", "pg-test"])
        self.assertEqual(networking_filter.clients_of("pg-laptop", APPS, MACHINE), ["ff-canary", "ff-casa"])
        self.assertEqual(networking_filter.clients_of("pg-test", APPS, MACHINE), ["ff-canary"])
        self.assertEqual(networking_filter.clients_of("ff-casa", APPS, MACHINE), [])
        self.assertEqual(networking_filter.clients_of("pg-laptop", APPS, {}), [])

    def check(self, value, me="ff-casa", machine=None) -> list[str]:
        return networking_filter.connects_to_problems(value, me, APPS, machine or MACHINE)

    def test_what_is_fine(self) -> None:
        self.assertEqual(self.check(["pg-laptop"]), [])
        self.assertEqual(self.check(["pg-laptop", "pg-test"], "ff-canary"), [])
        self.assertEqual(self.check([], "ff-solo"), [])

    def test_what_is_not(self) -> None:
        for value, part in (
            ("pg-laptop", "is a list of instances"),
            ([{"name": "pg-laptop"}], "is a list of instances"),
            (["pg-laptop", "pg-laptop"], "more than once"),
            (["ff-casa"], "cannot connect to itself"),
            (["pg-nope"], "is not an instance of this machine (there are: ff-canary, ff-casa, ff-solo, pg-laptop, pg-test)"),
        ):
            found = self.check(value)
            self.assertEqual(len(found), 1, value)
            self.assertIn(part, found[0])

    def test_a_pair_is_written_once(self) -> None:
        machine = {"postgres_instances": [{"name": "laptop", "networking": {"connects_to": ["ff-casa"]}}],
                   "firefly_instances": [{"name": "casa", "networking": {"connects_to": ["pg-laptop"]}}]}
        found = self.check(["pg-laptop"], "ff-casa", machine)
        self.assertEqual(found, ["pg-laptop already says it connects to ff-casa: one line per pair is enough, remove one of the two"])


if __name__ == "__main__":
    unittest.main()
