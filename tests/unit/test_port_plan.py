"""The port plan (plugins/filter/networking.py, playbooks/group_vars/all/ports.yml, R63)."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("networking_filter", ROOT / "plugins/filter/networking.py")
networking_filter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(networking_filter)
PLAN = yaml.safe_load((ROOT / "playbooks/group_vars/all/ports.yml").read_text())
APPS = yaml.safe_load((ROOT / "playbooks/group_vars/all/apps.yml").read_text())["infra_apps"]
BLOCKS = PLAN["infra_port_blocks"]
SIZE = PLAN["infra_port_block_size"]


def problems(publish, short, env="dev"):
    return networking_filter.port_problems(publish, short, PLAN["infra_port_bases"][env], BLOCKS, SIZE)


class PortProblems(unittest.TestCase):
    def test_inside_the_block(self) -> None:
        self.assertEqual(problems(["127.0.0.1:17100:8080", "127.0.0.1:17109:8080"], "ff"), [])
        self.assertEqual(problems(["127.0.0.1:18120:8080"], "ffimport", "prod"), [])
        self.assertEqual(problems(["127.0.0.1:17010:8428", "127.0.0.1:17011:9428"], "obs"), [])
        self.assertEqual(problems(["127.0.0.1:18000:8000"], "backup", "prod"), [])

    def test_outside_the_block(self) -> None:
        for publish, short, env, part in (
            (["127.0.0.1:18100:8080"], "ff", "dev", "17100 to 17109"),
            (["127.0.0.1:17100:8080"], "ff", "prod", "18100 to 18109"),
            (["127.0.0.1:18115:8080"], "ffimport", "prod", "18120 to 18129"),
            (["127.0.0.1:17110:8080"], "ff", "dev", "17100 to 17109"),
            (["127.0.0.1:18000:8000"], "backup", "dev", "17000 to 17009"),
            (["17100:8080"], "ff", "dev", "is not <address>"),
            (["127.0.0.1:17100:8080"], "nope", "dev", "no port block"),
        ):
            found = problems(publish, short, env)
            self.assertTrue(found and part in found[0], (publish, short, env, found))


class PortClashes(unittest.TestCase):
    def test_one_port_twice(self) -> None:
        variables = {
            "firefly_instances": [
                {"name": "casa", "networking": {"inbound": {"publish": ["127.0.0.1:17100:8080"]}}},
                {"name": "canary", "networking": {"inbound": {"publish": ["127.0.0.1:17100:8080"]}}},
            ],
            "pgadmin_instances": [{"name": "main", "networking": {"inbound": {"publish": ["127.0.0.1:17110:8080"]}}}],
        }
        self.assertEqual(networking_filter.port_clashes(APPS, variables),
                         ["port 17100 is published by ff-canary and ff-casa"])

    def test_none(self) -> None:
        self.assertEqual(networking_filter.port_clashes(APPS, {"firefly_instances": None}), [])


class ThePlan(unittest.TestCase):
    def test_every_application_has_a_block(self) -> None:
        missing = sorted(set(APPS.values()) - {"pg"} - set(BLOCKS))
        self.assertEqual(missing, [], "add their block to playbooks/group_vars/all/ports.yml")

    def test_blocks_do_not_overlap_and_apps_start_at_100(self) -> None:
        starts = sorted(BLOCKS.values())
        self.assertTrue(all(b - a >= SIZE for a, b in zip(starts, starts[1:])), starts)
        infra = {"backup", "obs"}
        self.assertTrue(all(BLOCKS[s] < 100 for s in infra))
        self.assertTrue(all(v >= 100 for s, v in BLOCKS.items() if s not in infra))
        self.assertTrue(all(v + SIZE <= 1000 for v in BLOCKS.values()))


if __name__ == "__main__":
    unittest.main()
