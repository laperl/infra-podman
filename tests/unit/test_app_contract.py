"""Every application role says what kind of application it is (R56).

An application role is one deployed by instances (<role>_instances in its defaults).
Its <role>_contract must be complete and agree with its Quadlet templates and with the
table of docs/services/README.md, section 9. PostgreSQL is the platform's provider, not
an application.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
PLATFORM = {"postgres"}
PROVIDERS = {"postgres"}


def application_roles() -> list[str]:
    roles = []
    for defaults in sorted((REPO / "roles").glob("*/defaults/main.yml")):
        role = defaults.parent.parent.name
        if role not in PLATFORM and f"{role}_instances" in yaml.safe_load(defaults.read_text()):
            roles.append(role)
    return roles


def network_lines(role: str) -> list[str]:
    lines = []
    for template in sorted((REPO / "roles" / role / "templates").glob("*.container.j2")):
        lines += re.findall(r"^Network=(.*)$", template.read_text(), flags=re.M)
    return lines


class AppContract(unittest.TestCase):
    def test_there_is_at_least_one_application(self) -> None:
        self.assertIn("firefly", application_roles())

    def test_every_application_declares_a_complete_contract(self) -> None:
        for role in application_roles():
            with self.subTest(role=role):
                defaults = yaml.safe_load((REPO / "roles" / role / "defaults/main.yml").read_text())
                contract = defaults.get(f"{role}_contract")
                self.assertIsInstance(contract, dict, f"{role}_contract is missing in its defaults")
                self.assertEqual(set(contract), {"database", "providers", "egress"})
                self.assertIn(contract["database"], ("none", "postgres"))
                self.assertIsInstance(contract["providers"], list)
                self.assertLessEqual(set(contract["providers"]), PROVIDERS)
                self.assertIsInstance(contract["egress"], bool)
                if contract["database"] == "postgres":
                    self.assertIn("postgres", contract["providers"], "its own database needs the provider postgres")

    def test_the_units_agree_with_the_contract(self) -> None:
        for role in application_roles():
            with self.subTest(role=role):
                contract = yaml.safe_load((REPO / "roles" / role / "defaults/main.yml").read_text())[f"{role}_contract"]
                lines = network_lines(role)
                self.assertTrue(lines, "a container without Network= gets Podman's default network, with a way out")
                if contract["providers"]:
                    self.assertTrue([line for line in lines if line.endswith(".network")],
                                    "an application with providers joins a network with each")
                if not contract["egress"]:
                    for line in lines:
                        self.assertTrue(line == "none" or line.endswith(".network"),
                                        f"Network={line} is not none or a .network unit")
                    for network in sorted((REPO / "roles" / role / "templates").glob("*.network.j2")):
                        self.assertIn("Internal=true", network.read_text(),
                                      f"{network.name}: without egress every network is internal")

    def test_every_application_is_in_the_table_of_the_common_page(self) -> None:
        page = (REPO / "docs/services/README.md").read_text()
        for role in application_roles():
            with self.subTest(role=role):
                self.assertTrue(re.search(rf"(?m)^\| .*`{role}`.*\|", page),
                                f"{role} has no row in the table of docs/services/README.md, section 9")


    def test_every_application_is_in_the_list_of_applications(self) -> None:
        shorts = yaml.safe_load((REPO / "playbooks/group_vars/all/apps.yml").read_text())["infra_apps"]
        for role in application_roles():
            with self.subTest(role=role):
                defaults = yaml.safe_load((REPO / "roles" / role / "defaults/main.yml").read_text())
                self.assertEqual(shorts.get(role), defaults[f"{role}_short"],
                                 f"{role} is missing in infra_apps (playbooks/group_vars/all/apps.yml): its instances would be "
                                 "reported as undeclared and nothing could connect to them")


if __name__ == "__main__":
    unittest.main()
