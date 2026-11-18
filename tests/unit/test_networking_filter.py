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


class Pairs(unittest.TestCase):
    machine = {
        "postgres_instances": [{"name": "main", "databases": [{"name": "ff_casa"}, {"name": "ff_canary"}]}],
        "firefly_instances": [
            {"name": "casa", "networking": {"connects_to": ["pg-main", "ff-canary"]},
             "pg_hba": [{"instance": "pg-main", "database": "ff_casa"}]},
            {"name": "canary", "networking": {"connects_to": ["pg-main"]},
             "pg_hba": [{"instance": "pg-main", "database": "ff_canary"}, {"instance": "pg-main", "database": "ff_casa"}]},
            {"name": "solo", "networking": {"connects_to": ["pg-main"]}},
        ],
    }

    def test_each_side_sees_the_same_pairs(self) -> None:
        pairs = networking_filter.pairs_of
        self.assertEqual(pairs("ff-casa", APPS, self.machine), [["ff-casa", "ff-canary"], ["ff-casa", "pg-main"]])
        self.assertEqual(pairs("ff-canary", APPS, self.machine), [["ff-canary", "pg-main"], ["ff-casa", "ff-canary"]])
        self.assertEqual(pairs("pg-main", APPS, self.machine),
                         [["ff-canary", "pg-main"], ["ff-casa", "pg-main"], ["ff-solo", "pg-main"]])
        self.assertEqual(pairs("ff-nobody", APPS, self.machine), [])

    def test_one_name_per_pair(self) -> None:
        self.assertEqual(networking_filter.pair_network(["ff-casa", "pg-main"], "prod"), "prod-ff-casa-pg-main-net")
        self.assertEqual(networking_filter.pair_units([["ff-casa", "ff-canary"]], "dev"),
                         [{"template": "pair.network.j2", "common": True,
                           "name": "dev-ff-casa-ff-canary-net.network", "app": "ff-canary"}])
        # Injective: an identifier has exactly one hyphen, so a name has one reading.
        names = {networking_filter.pair_network(pair, "dev")
                 for me in networking_filter.instance_ids(APPS, self.machine)
                 for pair in networking_filter.pairs_of(me, APPS, self.machine)}
        self.assertEqual(len(names), 4)

    def test_what_postgres_reads(self) -> None:
        self.assertEqual(networking_filter.hba_of("pg-main", APPS, self.machine),
                         [{"client": "ff-canary", "database": "ff_canary"}, {"client": "ff-canary", "database": "ff_casa"},
                          {"client": "ff-casa", "database": "ff_casa"}])
        # Only from instances that connect: pg_hba without connects_to gives nothing.
        machine = {"postgres_instances": [{"name": "main"}],
                   "firefly_instances": [{"name": "x", "pg_hba": [{"instance": "pg-main", "database": "ff_x"}]}]}
        self.assertEqual(networking_filter.hba_of("pg-main", APPS, machine), [])

    def test_postgres_does_not_start_connections(self) -> None:
        machine = {"postgres_instances": [{"name": "main"}, {"name": "b"}], "firefly_instances": [{"name": "casa"}]}
        for value in (["ff-casa"], ["pg-b"]):
            found = networking_filter.connects_to_problems(value, "pg-main", APPS, machine)
            self.assertIn("does not start connections", found[0], value)


class PgHba(unittest.TestCase):
    machine = Pairs.machine

    def check(self, value, me="ff-casa", connects_to=("pg-main",)) -> list[str]:
        return networking_filter.pg_hba_problems(value, me, list(connects_to), APPS, self.machine)

    def test_what_is_fine(self) -> None:
        self.assertEqual(self.check([{"instance": "pg-main", "database": "ff_casa"}]), [])
        self.assertEqual(self.check([{"instance": "pg-main", "database": "ff_casa"},
                                     {"instance": "pg-main", "database": "ff_canary"}]), [])
        # Between two applications there is no pg_hba.
        self.assertEqual(self.check([], connects_to=["ff-canary"]), [])
        self.assertEqual(self.check(None, connects_to=[]), [])

    def test_what_is_not(self) -> None:
        for value, connects_to, part in (
            ("pg-main", ["pg-main"], "is a list like"),
            ([{"instance": "pg-main"}], ["pg-main"], "is a list like"),
            ([{"instance": "pg-main", "database": "ff_casa", "users": ["x"]}], ["pg-main"], "only instance and database"),
            ([], ["pg-main"], "pg-main is in connects_to and nothing in pg_hba"),
            ([{"instance": "pg-main", "database": "ff_casa"}], [], "not in networking.connects_to"),
            ([{"instance": "ff-canary", "database": "ff_casa"}], ["ff-canary"], "not a PostgreSQL instance of this machine"),
            ([{"instance": "pg-nope", "database": "ff_casa"}], ["pg-main"], "pg-nope is not a PostgreSQL instance"),
            ([{"instance": "pg-main", "database": "Bad-Name"}], ["pg-main"], "is not a database name"),
            # H3: also next to a good one, the database must be declared in that instance.
            ([{"instance": "pg-main", "database": "ff_casa"}, {"instance": "pg-main", "database": "ff_nope"}],
             ["pg-main"], "ff_nope is not a database of pg-main (there are: ff_casa, ff_canary)"),
        ):
            found = self.check(value, connects_to=connects_to)
            self.assertTrue(found, value)
            self.assertIn(part, " | ".join(found), value)
        found = self.check([{"instance": "pg-main", "database": "ff_casa"}] * 2)
        self.assertIn("written more than once", found[0])
        found = networking_filter.pg_hba_problems([{"instance": "pg-main", "database": "x"}], "pg-main", [], APPS, self.machine)
        self.assertIn("written by the application", found[0])


class AdminsOf(unittest.TestCase):
    """Who may use the superuser of a PostgreSQL instance over TCP (R37)."""

    APPS = {"postgres": "pg", "firefly": "ff", "pgadmin": "pgadmin"}
    MACHINE = {
        "postgres_instances": [{"name": "laptop"}, {"name": "test"}],
        "firefly_instances": [{"name": "casa", "networking": {"connects_to": ["pg-laptop"]}}],
        "pgadmin_instances": [{"name": "laptop", "networking": {"connects_to": ["pg-laptop", "pg-test"]}},
                              {"name": "spare"}],
    }

    def admins(self, target, admins=("pgadmin",)):
        return networking_filter.admins_of(target, self.APPS, self.MACHINE, list(admins))

    def test_only_the_admin_application_that_connects(self) -> None:
        self.assertEqual(self.admins("pg-laptop"), ["pgadmin-laptop"])
        self.assertEqual(self.admins("pg-test"), ["pgadmin-laptop"])

    def test_nobody_without_the_list(self) -> None:
        self.assertEqual(self.admins("pg-laptop", ()), [])

    def test_an_application_outside_the_list_never_gets_it(self) -> None:
        self.assertNotIn("ff-casa", self.admins("pg-laptop"))


if __name__ == "__main__":
    unittest.main()
