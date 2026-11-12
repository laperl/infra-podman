#!/usr/bin/env python3
"""Enforce the repository policy (docs/SPEC.md, sections 3, 4.3, 4.4, 4.12, 4.14 and 8) on rendered Quadlet units.

The Podman 4.9 generator does not catch everything we forbid: it accepts
``Notify=healthy`` silently and ignores ``.pod`` files without an error.
This check covers those gaps. It only uses the standard library.

Usage: quadlet_policy.py FILE [FILE ...]
Exit code 0 when every file complies, 1 otherwise.
"""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path

# D4: only native per-service templates of these kinds.
ALLOWED_SUFFIXES = {".container", ".network", ".volume"}

# D6: images pinned by digest (an optional tag before the digest is tolerated).
DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")

# Section 8 / 4.3: patterns forbidden anywhere in a unit, comments excluded.
FORBIDDEN_PATTERNS = [
    (re.compile(r"\b(slirp4netns|pasta)\b", re.IGNORECASE),
     "slirp4netns/pasta options are forbidden (SPEC 4.3)"),
    (re.compile(r"\b(podman|docker)\.sock\b", re.IGNORECASE),
     "mounting the Podman or Docker socket is forbidden (SPEC 8)"),
]


# SPEC 4.12: explicit names, prefixed with the environment, and the infra.* labels.
NAME_KEYS = {".container": "ContainerName", ".network": "NetworkName", ".volume": "VolumeName"}
ENVIRONMENTS = ("prod", "dev")
SLUG = r"[a-z0-9]+(?:-[a-z0-9]+)*"
NAME_PATTERNS = {
    # <env>-<app>[-<piece>]
    ".container": re.compile(rf"^(?:{'|'.join(ENVIRONMENTS)})-{SLUG}$"),
    # <env>-<consumer>-<provider>-net
    ".network": re.compile(rf"^(?:{'|'.join(ENVIRONMENTS)})-[a-z0-9]+(?:-[a-z0-9]+)+-net$"),
    # <env>-<app>-<content>
    ".volume": re.compile(rf"^(?:{'|'.join(ENVIRONMENTS)})-[a-z0-9]+(?:-[a-z0-9]+)+$"),
}
NAME_HINTS = {
    ".container": "<env>-<app>[-<piece>]",
    ".network": "<env>-<consumer>-<provider>-net",
    ".volume": "<env>-<app>-<content>",
}
REQUIRED_LABELS = ("infra.env", "infra.app", "infra.component", "infra.managed-by")
MANAGED_BY = "infra-podman"

# R25, SPEC 4.4: a container publishes only on the loopback address, and on a host port
# chosen in the inventory. Without the address Podman listens on every interface; without
# the host port it picks a different one on each start.
PUBLISH_RE = re.compile(r"^127\.0\.0\.1:\d{1,5}:\d{1,5}(?:/(?:tcp|udp))?$")

# R46, SPEC 4.14: every container limits memory, CPU and number of processes. Podman 4.9
# has no Quadlet key for the first two, so they are flags in PodmanArgs=, written
# --flag=value (docs/COMPATIBILITY.md).
REQUIRED_PODMAN_ARGS = ("--memory", "--cpus")


def labels_from(value: str) -> dict[str, str]:
    """Parse one Label= value: one or more key=value pairs, optionally quoted."""
    labels = {}
    for item in shlex.split(value):
        key, _, val = item.partition("=")
        labels[key] = val
    return labels


def check_names_and_labels(path: Path, keys: dict[str, str], labels: dict[str, str]) -> list[str]:
    errors: list[str] = []
    name_key = NAME_KEYS[path.suffix]
    name = keys.get(name_key)
    if not name:
        errors.append(f"{path}: {name_key}= is required; without it Podman prefixes 'systemd-' (SPEC 4.12)")
    else:
        if not NAME_PATTERNS[path.suffix].match(name):
            errors.append(f"{path}: {name_key}={name} must look like {NAME_HINTS[path.suffix]}, "
                          f"lower case, starting with {' or '.join(ENVIRONMENTS)} (SPEC 4.12)")
        if path.stem != name:
            errors.append(f"{path}: the file must be named after the object: {name}{path.suffix} (SPEC 4.12)")
    missing = [label for label in REQUIRED_LABELS if not labels.get(label)]
    if missing:
        errors.append(f"{path}: missing label(s) {', '.join(missing)} (SPEC 4.12)")
    env = labels.get("infra.env")
    if env and env not in ENVIRONMENTS:
        errors.append(f"{path}: infra.env={env} must be one of {', '.join(ENVIRONMENTS)} (SPEC 4.12)")
    if env and name and not name.startswith(f"{env}-"):
        errors.append(f"{path}: {name_key}={name} does not start with its infra.env '{env}-' (SPEC 4.12)")
    managed_by = labels.get("infra.managed-by")
    if managed_by and managed_by != MANAGED_BY:
        errors.append(f"{path}: infra.managed-by must be {MANAGED_BY} (SPEC 4.12)")
    return errors


def check_exposure_and_limits(path: Path, values: dict[str, list[str]]) -> list[str]:
    """Check the keys of a .container that may be written several times.

    values maps each key to every value it has in the unit, in order.
    """
    errors: list[str] = []
    for port in values.get("PublishPort", []):
        if not PUBLISH_RE.match(port):
            errors.append(f"{path}: PublishPort={port} must be "
                          f"127.0.0.1:<host port>:<container port> (R25, SPEC 4.4)")
    args: list[str] = []
    for value in values.get("PodmanArgs", []):
        try:
            args += shlex.split(value)
        except ValueError as error:
            errors.append(f"{path}: cannot parse PodmanArgs={value}: {error}")
    missing = [f"{flag}=<value> in PodmanArgs=" for flag in REQUIRED_PODMAN_ARGS
               if not any(arg.startswith(f"{flag}=") and len(arg) > len(flag) + 1 for arg in args)]
    if not any(values.get("PidsLimit", [])):
        missing.append("PidsLimit=<number>")
    if missing:
        errors.append(f"{path}: missing resource limit(s): {', '.join(missing)} (R46, SPEC 4.14)")
    return errors


def logical_lines(text: str):
    """Yield (line_number, line) joining backslash continuations, skipping comments."""
    buffer, start = "", 0
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not buffer and (not line or line[0] in "#;"):
            continue
        if not buffer:
            start = number
        if line.endswith("\\"):
            buffer += line[:-1] + " "
            continue
        yield start, buffer + line
        buffer = ""
    if buffer:
        yield start, buffer


def check_file(path: Path) -> list[str]:
    errors: list[str] = []
    if path.suffix not in ALLOWED_SUFFIXES:
        return [f"{path}: unit type '{path.suffix}' is not allowed "
                f"(only {', '.join(sorted(ALLOWED_SUFFIXES))}; .pod needs Podman >= 5.0)"]

    keys: dict[str, str] = {}
    # Every value of each key: PublishPort=, PodmanArgs= and others can be repeated.
    values: dict[str, list[str]] = {}
    labels: dict[str, str] = {}
    for number, line in logical_lines(path.read_text(encoding="utf-8")):
        where = f"{path}:{number}"
        for pattern, message in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                errors.append(f"{where}: {message}")
        if line.startswith("[") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        keys[key] = value
        values.setdefault(key, []).append(value)
        if key == "Label":
            try:
                labels.update(labels_from(value))
            except ValueError as error:
                errors.append(f"{where}: cannot parse Label={value}: {error}")
        if key == "Notify" and value.lower() == "healthy":
            errors.append(f"{where}: Notify=healthy needs Podman >= 5.0 (SPEC 4.3)")
        if key == "Image" and not DIGEST_RE.search(value):
            errors.append(f"{where}: image '{value}' must be pinned by digest @sha256:<64 hex> (D6)")
    if path.suffix == ".container":
        errors += check_exposure_and_limits(path, values)
    return errors + check_names_and_labels(path, keys, labels)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    errors = [error for name in argv for error in check_file(Path(name))]
    for error in errors:
        print(f"POLICY: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
