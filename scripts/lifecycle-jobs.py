#!/usr/bin/env python3
"""Which lifecycle jobs a pull request runs (R61), from tests/lifecycle/jobs.yml.

Usage:
  scripts/lifecycle-jobs.py --base <commit>   the jobs for what changed since <commit>
  scripts/lifecycle-jobs.py --all             every job
Prints a JSON list of job names, in the order of the map. The rules are in the map itself.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "tests/lifecycle/jobs.yml"
IMAGES = "playbooks/group_vars/all/images.yml"
IMAGE_LINE = re.compile(r"^([a-z][a-z0-9_]*_image):")


def load_map(path: Path = MAP) -> dict:
    return yaml.safe_load(path.read_text())


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def image_jobs(changed_lines: list[str], jobmap: dict) -> set[str] | None:
    """Jobs for the changed lines of images.yml; None means every job."""
    jobs: set[str] = set()
    for line in changed_lines:
        text = line.strip()
        if not text or text.startswith("#") or text == "---":
            continue
        m = IMAGE_LINE.match(text)
        if not m or m.group(1) not in jobmap["images"]:
            return None
        jobs.update(jobmap["images"][m.group(1)])
    return jobs


def select(files: list[str], image_lines: list[str], jobmap: dict) -> list[str]:
    """The jobs for these changed files (and changed lines of images.yml), in map order."""
    every = list(jobmap["jobs"])
    chosen: set[str] = set()
    for f in files:
        if not matches(f, jobmap["watched"]):
            continue
        if matches(f, jobmap["all"]):
            return every
        if f == IMAGES:
            got = image_jobs(image_lines, jobmap)
            if got is None:
                return every
            chosen |= got
            continue
        hit = [r for r in jobmap["rules"] if matches(f, r["paths"])]
        if not hit:
            return every
        for r in hit:
            chosen.update(r["jobs"])
    return [j for j in every if j in chosen]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def changed_since(base: str) -> tuple[list[str], list[str]]:
    files = [f for f in git("diff", "--name-only", f"{base}...HEAD").splitlines() if f]
    image_lines = [
        line[1:]
        for line in git("diff", "-U0", f"{base}...HEAD", "--", IMAGES).splitlines()
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
    ]
    return files, image_lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--base", help="commit the pull request starts from")
    group.add_argument("--all", action="store_true", help="every job")
    args = parser.parse_args(argv)
    jobmap = load_map()
    if args.all:
        jobs = list(jobmap["jobs"])
    else:
        files, image_lines = changed_since(args.base)
        jobs = select(files, image_lines, jobmap)
        for f in files:
            print(f"changed: {f}", file=sys.stderr)
    print(json.dumps(jobs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
