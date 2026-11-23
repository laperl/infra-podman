"""The lifecycle job map (tests/lifecycle/jobs.yml, R61) stays complete and correct.

It checks that the map and .github/workflows/lifecycle.yml name the same jobs, and that each
job's rules cover what that job really uses: the playbooks and files its steps name, the roles
of those playbooks, the roles those roles include, and the images of those roles. Then a few
concrete cases of scripts/lifecycle-jobs.py.
"""
from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/lifecycle.yml"
SPEC = importlib.util.spec_from_file_location("lifecycle_jobs", ROOT / "scripts/lifecycle-jobs.py")
lj = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lj)

JOBMAP = lj.load_map()
NOT_TESTS = {"changes", "lifecycle-ok"}
# Files a job's steps name that are not inputs of the test itself.
REFERENCE = re.compile(r"(playbooks/[a-z_-]+\.yml|tests/lifecycle/[A-Za-z0-9_.-]+|scripts/[a-z_.-]+|docs/[A-Z_]+\.md)")
ROLE_REF = re.compile(r"^\s*(?:-\s+)?(?:role|name):\s*([a-z_]+)\s*$", re.M)


def workflow_jobs() -> dict:
    return {k: v for k, v in yaml.safe_load(WORKFLOW.read_text())["jobs"].items() if k not in NOT_TESTS}


def files_named(job: dict) -> set[str]:
    found = set(REFERENCE.findall(yaml.safe_dump(job, width=10_000)))
    return {f for f in found if (ROOT / f).is_file()}


def roles_of_playbook(path: Path) -> set[str]:
    data = yaml.safe_load(path.read_text()) or []
    roles: set[str] = set()
    for play in data:
        for r in play.get("roles", []) or []:
            roles.add(r if isinstance(r, str) else r.get("role") or r.get("name"))
        for t in play.get("tasks", []) or []:
            inc = t.get("ansible.builtin.include_role") or t.get("include_role")
            if isinstance(inc, dict):
                roles.add(inc["name"])
    return {r for r in roles if (ROOT / "roles" / r).is_dir()}


def roles_included(role: str) -> set[str]:
    found: set[str] = set()
    for f in (ROOT / "roles" / role / "tasks").glob("*.yml"):
        text = f.read_text()
        for block in re.findall(r"include_role:\n((?:\s{6,}.*\n)+)", text):
            found.update(m for m in ROLE_REF.findall(block) if (ROOT / "roles" / m).is_dir())
    return found - {role}


def closure(roles: set[str]) -> set[str]:
    todo, seen = list(roles), set()
    while todo:
        r = todo.pop()
        if r in seen:
            continue
        seen.add(r)
        todo.extend(roles_included(r))
    return seen


def jobs_matching(path: str) -> set[str]:
    if lj.matches(path, JOBMAP["all"]):
        return set(JOBMAP["jobs"])
    return {j for r in JOBMAP["rules"] if lj.matches(path, r["paths"]) for j in r["jobs"]}


class TestLifecycleJobMap(unittest.TestCase):
    def test_same_jobs_as_the_workflow(self):
        self.assertEqual(sorted(JOBMAP["jobs"]), sorted(workflow_jobs()),
                         "tests/lifecycle/jobs.yml 'jobs' and the jobs of lifecycle.yml differ")

    def test_watched_are_the_workflow_triggers(self):
        on = yaml.safe_load(WORKFLOW.read_text())["on"]
        want = [p.replace("**", "*") for p in on["pull_request"]["paths"]]
        self.assertEqual(JOBMAP["watched"], want, "jobs.yml 'watched' and the paths of lifecycle.yml differ")
        self.assertEqual(on["push"]["paths"], on["pull_request"]["paths"])

    def test_every_rule_names_known_jobs(self):
        known = set(JOBMAP["jobs"])
        for r in JOBMAP["rules"]:
            self.assertLessEqual(set(r["jobs"]), known, r["name"])
        for img, jobs in JOBMAP["images"].items():
            self.assertLessEqual(set(jobs), known, img)

    def test_each_job_runs_only_if_picked(self):
        for name, job in workflow_jobs().items():
            self.assertEqual(job.get("needs"), "changes", name)
            self.assertEqual(job.get("if"), f"contains(fromJSON(needs.changes.outputs.jobs), '{name}')", name)

    def test_summary_waits_for_every_job(self):
        ok = yaml.safe_load(WORKFLOW.read_text())["jobs"]["lifecycle-ok"]
        self.assertEqual(sorted(ok["needs"]), sorted(["changes", *workflow_jobs()]))

    def test_files_each_job_names_are_covered(self):
        for name, job in workflow_jobs().items():
            for f in files_named(job):
                self.assertIn(name, jobs_matching(f), f"job {name} uses {f}: add it to a rule of jobs.yml")

    def test_roles_each_job_uses_are_covered(self):
        for name, job in workflow_jobs().items():
            playbooks = {f for f in files_named(job) if f.startswith("playbooks/")}
            roles = closure(set().union(*(roles_of_playbook(ROOT / p) for p in playbooks)))
            for role in roles:
                self.assertIn(name, jobs_matching(f"roles/{role}/tasks/main.yml"),
                              f"job {name} uses role {role}: add roles/{role}/* to a rule of jobs.yml")

    def test_images_each_job_uses_are_covered(self):
        images = re.findall(r"^([a-z][a-z0-9_]*_image):", (ROOT / lj.IMAGES).read_text(), re.M)
        self.assertEqual(sorted(images), sorted(JOBMAP["images"]), "images.yml and the map's 'images' differ")
        for name, job in workflow_jobs().items():
            playbooks = {f for f in files_named(job) if f.startswith("playbooks/")}
            roles = closure(set().union(*(roles_of_playbook(ROOT / p) for p in playbooks)))
            for role in roles:
                text = " ".join(p.read_text() for d in ("defaults", "tasks") for p in (ROOT / "roles" / role / d).glob("*.yml"))
                for img in images:
                    if re.search(rf"\b{img}\b", text):
                        self.assertIn(name, JOBMAP["images"][img], f"job {name} uses {img} through role {role}")


class TestSelect(unittest.TestCase):
    def pick(self, files, image_lines=()):
        return lj.select(list(files), list(image_lines), JOBMAP)

    def test_one_application(self):
        self.assertEqual(self.pick(["roles/pgadmin/tasks/main.yml"]), ["pgadmin"])
        self.assertEqual(self.pick(["roles/firefly_importer/defaults/main.yml"]), ["firefly_importer"])

    def test_firefly_also_runs_its_importer(self):
        self.assertEqual(self.pick(["roles/firefly/templates/firefly.container.j2"]), ["firefly", "firefly_importer"])

    def test_postgres_runs_all_but_base(self):
        self.assertEqual(self.pick(["roles/postgres/tasks/main.yml"]),
                         ["postgres", "firefly", "pgadmin", "firefly_importer", "backup", "backup-copy"])

    def test_common_runs_all(self):
        self.assertEqual(self.pick(["roles/quadlet_deploy/tasks/main.yml"]), [j for j in JOBMAP["jobs"] if j != "base"])
        self.assertEqual(self.pick(["plugins/filter/networking.py"]), JOBMAP["jobs"])

    def test_documentation_is_ignored(self):
        self.assertEqual(self.pick(["docs/ROADMAP.md"]), [])
        self.assertEqual(self.pick(["roles/pgadmin/tasks/main.yml", "docs/ROADMAP.md", "README.md"]), ["pgadmin"])

    def test_unknown_file_runs_all(self):
        self.assertEqual(self.pick(["roles/new_thing/tasks/main.yml"]), JOBMAP["jobs"])

    def test_image_update_runs_its_jobs(self):
        line = 'pgadmin_image: "docker.io/dpage/pgadmin4@sha256:' + "0" * 64 + '"  # track: 9.9'
        self.assertEqual(self.pick([lj.IMAGES], ["# a comment", line]), ["pgadmin"])
        self.assertEqual(self.pick([lj.IMAGES], ['postgres_image: "x"']),
                         ["postgres", "firefly", "pgadmin", "firefly_importer", "backup", "backup-copy"])

    def test_image_comment_only_runs_nothing(self):
        self.assertEqual(self.pick([lj.IMAGES], ["# Digest computed on another day"]), [])

    def test_other_line_in_images_runs_all(self):
        self.assertEqual(self.pick([lj.IMAGES], ["something_else: 1"]), JOBMAP["jobs"])


if __name__ == "__main__":
    unittest.main()
