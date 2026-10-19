#!/usr/bin/env python3
"""Validate that GitHub Actions workflows use immutable action references.

Third-party actions must be pinned to a full 40-character commit SHA instead of
a movable branch or tag. This makes dependency bumps (such as Dependabot's)
reviewable and reproducible, and prevents a changed tag from silently altering
what CI executes.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

USES_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*(?P<target>[^\s#]+)\s*(?:#.*)?$",
    re.MULTILINE,
)
SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


def workflow_files(root: Path) -> list[Path]:
    return sorted(root.glob(".github/workflows/*.yml")) + sorted(
        root.glob(".github/workflows/*.yaml")
    )


def validate_workflow(path: Path, root: Path) -> list[str]:
    problems: list[str] = []
    relative = path.relative_to(root)
    text = path.read_text(encoding="utf-8")

    for match in USES_RE.finditer(text):
        target = match.group("target").strip("\"'")
        line_number = text.count("\n", 0, match.start()) + 1

        # Local composite actions are part of this repository, and Docker
        # references do not use the owner/repository@ref syntax.
        if target.startswith("./") or target.startswith("docker://"):
            continue

        if "@" not in target:
            problems.append(
                f"{relative}:{line_number}: action reference is not pinned: {target}"
            )
            continue

        action, ref = target.rsplit("@", 1)
        if not SHA_RE.fullmatch(ref):
            problems.append(
                f"{relative}:{line_number}: {action} must be pinned to a full "
                f"40-character commit SHA, found {ref!r}"
            )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="repository root to validate (default: current directory)",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    paths = workflow_files(root)
    if not paths:
        print(f"error: no workflow files found under {root / '.github/workflows'}")
        return 1

    problems: list[str] = []
    for path in paths:
        file_problems = validate_workflow(path, root)
        if file_problems:
            problems.extend(file_problems)
        else:
            print(f"ok: {path.relative_to(root)}")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
