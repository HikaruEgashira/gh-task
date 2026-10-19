from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = REPO_ROOT / "scripts" / "validate_workflows.py"


def run_validator(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(VALIDATOR), "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


class WorkflowPinTests(unittest.TestCase):
    def test_repository_workflows_are_pinned(self) -> None:
        result = run_validator(REPO_ROOT)
        self.assertEqual(
            result.returncode,
            0,
            msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

    def test_rejects_movable_action_refs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / ".github" / "workflows" / "ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                textwrap.dedent(
                    """\
                    name: CI
                    on: pull_request
                    jobs:
                      test:
                        runs-on: ubuntu-latest
                        steps:
                          - uses: actions/checkout@v4
                    """
                ),
                encoding="utf-8",
            )

            result = run_validator(root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("full 40-character commit SHA", result.stderr)

    def test_accepts_sha_pinned_actions_and_local_actions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / ".github" / "workflows" / "ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                textwrap.dedent(
                    """\
                    name: CI
                    on: pull_request
                    jobs:
                      test:
                        runs-on: ubuntu-latest
                        steps:
                          - uses: actions/checkout@1111111111111111111111111111111111111111 # v4
                          - uses: ./.github/actions/local
                    """
                ),
                encoding="utf-8",
            )

            result = run_validator(root)

        self.assertEqual(
            result.returncode,
            0,
            msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
