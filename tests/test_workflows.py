from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = REPO_ROOT / "scripts" / "validate_workflows.py"
SETUP_ZIG = REPO_ROOT / ".github" / "actions" / "setup-zig"

SPEC = importlib.util.spec_from_file_location(
    "setup_zig_install", SETUP_ZIG / "install.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load setup-zig installer")
SETUP_ZIG_INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP_ZIG_INSTALL)


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


class ZigSetupTests(unittest.TestCase):
    def test_workflows_install_zig_without_a_node_action(self) -> None:
        for name in ("ci.yml", "release.yml"):
            workflow = REPO_ROOT / ".github" / "workflows" / name
            text = workflow.read_text(encoding="utf-8")
            self.assertIn("uses: ./.github/actions/setup-zig", text)
            self.assertNotIn("mlugg/setup-zig", text)

    def test_setup_action_is_composite(self) -> None:
        text = (SETUP_ZIG / "action.yml").read_text(encoding="utf-8")
        self.assertIn("using: composite", text)
        self.assertNotIn("node20", text)

    def test_platform_key_maps_supported_platforms(self) -> None:
        self.assertEqual(
            SETUP_ZIG_INSTALL.platform_key("x86_64", "Linux"), "x86_64-linux"
        )
        self.assertEqual(
            SETUP_ZIG_INSTALL.platform_key("arm64", "Darwin"), "aarch64-macos"
        )
        with self.assertRaises(ValueError):
            SETUP_ZIG_INSTALL.platform_key("riscv64", "Linux")

    def test_install_downloads_and_verifies_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "zig.tar.xz"
            with tarfile.open(archive, "w:xz") as bundle:
                executable = b"#!/bin/sh\nexit 0\n"
                info = tarfile.TarInfo("zig-test/zig")
                info.size = len(executable)
                info.mode = 0o755
                bundle.addfile(info, io.BytesIO(executable))

            payload = archive.read_bytes()
            checksum = hashlib.sha256(payload).hexdigest()
            index = json.dumps(
                {
                    "0.15.2": {
                        "x86_64-linux": {
                            "tarball": "https://example.invalid/zig.tar.xz",
                            "shasum": checksum,
                        }
                    }
                }
            ).encode()

            def opener(url: str, timeout: int) -> io.BytesIO:
                return io.BytesIO(index if url == SETUP_ZIG_INSTALL.INDEX_URL else payload)

            toolchain = SETUP_ZIG_INSTALL.install(
                "0.15.2", "x86_64-linux", root, opener=opener
            )

            self.assertEqual(toolchain.name, "zig-test")
            self.assertTrue((toolchain / "zig").is_file())
            self.assertTrue(os.access(toolchain / "zig", os.X_OK))

    def test_install_rejects_a_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "zig.tar.xz"
            with tarfile.open(archive, "w:xz") as bundle:
                executable = b"#!/bin/sh\nexit 0\n"
                info = tarfile.TarInfo("zig-test/zig")
                info.size = len(executable)
                bundle.addfile(info, io.BytesIO(executable))

            index = json.dumps(
                {
                    "0.15.2": {
                        "x86_64-linux": {
                            "tarball": "https://example.invalid/zig.tar.xz",
                            "shasum": "0" * 64,
                        }
                    }
                }
            ).encode()

            def opener(url: str, timeout: int) -> io.BytesIO:
                return io.BytesIO(
                    index if url == SETUP_ZIG_INSTALL.INDEX_URL else archive.read_bytes()
                )

            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                SETUP_ZIG_INSTALL.install(
                    "0.15.2", "x86_64-linux", root, opener=opener
                )


if __name__ == "__main__":
    unittest.main()
