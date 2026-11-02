#!/usr/bin/env python3
"""Enforce the repository policy (docs/SPEC.md, sections 3, 4.3 and 8) on rendered Quadlet units.

The Podman 4.9 generator does not catch everything we forbid: it accepts
``Notify=healthy`` silently and ignores ``.pod`` files without an error.
This check covers those gaps. It only uses the standard library.

Usage: quadlet_policy.py FILE [FILE ...]
Exit code 0 when every file complies, 1 otherwise.
"""

from __future__ import annotations

import re
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

    for number, line in logical_lines(path.read_text(encoding="utf-8")):
        where = f"{path}:{number}"
        for pattern, message in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                errors.append(f"{where}: {message}")
        if line.startswith("[") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key == "Notify" and value.lower() == "healthy":
            errors.append(f"{where}: Notify=healthy needs Podman >= 5.0 (SPEC 4.3)")
        if key == "Image" and not DIGEST_RE.search(value):
            errors.append(f"{where}: image '{value}' must be pinned by digest @sha256:<64 hex> (D6)")
    return errors


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
