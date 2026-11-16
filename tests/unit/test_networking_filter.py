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


if __name__ == "__main__":
    unittest.main()
