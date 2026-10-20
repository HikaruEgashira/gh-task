#!/usr/bin/env python3
"""Install a pinned Zig release without relying on a Node.js action runtime."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Callable

INDEX_URL = "https://ziglang.org/download/index.json"
ARCHITECTURES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
}
SYSTEMS = {
    "linux": "linux",
    "darwin": "macos",
}


def platform_key(machine: str | None = None, system: str | None = None) -> str:
    machine = (machine or platform.machine()).lower()
    system = (system or platform.system()).lower()
    try:
        return f"{ARCHITECTURES[machine]}-{SYSTEMS[system]}"
    except KeyError as error:
        raise ValueError(f"unsupported platform: {machine}-{system}") from error


def load_package(version: str, platform_name: str, opener: Callable[..., object]) -> dict:
    with opener(INDEX_URL, timeout=60) as response:
        index = json.load(response)
    release = index.get(version)
    if not isinstance(release, dict):
        raise ValueError(f"Zig {version} is not available")
    package = release.get(platform_name)
    if not isinstance(package, dict):
        raise ValueError(f"Zig {version} has no build for {platform_name}")
    return package


def download(url: str, destination: Path, opener: Callable[..., object]) -> None:
    with opener(url, timeout=300) as response, destination.open("wb") as handle:
        while chunk := response.read(1024 * 1024):
            handle.write(chunk)


def verify_checksum(path: Path, expected: str) -> None:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != expected:
        raise ValueError(f"Zig download checksum mismatch: {actual} != {expected}")


def install(
    version: str,
    platform_name: str,
    work_dir: Path,
    opener: Callable[..., object] = urllib.request.urlopen,
) -> Path:
    package = load_package(version, platform_name, opener)
    work_dir.mkdir(parents=True, exist_ok=True)
    install_dir = Path(tempfile.mkdtemp(prefix="zig-", dir=work_dir))
    try:
        with tempfile.TemporaryDirectory(prefix="zig-download-", dir=work_dir) as temporary:
            archive = Path(temporary) / "zig.tar.xz"
            download(package["tarball"], archive, opener)
            verify_checksum(archive, package["shasum"])
            with tarfile.open(archive, "r:xz") as bundle:
                if hasattr(tarfile, "data_filter"):
                    bundle.extractall(install_dir, filter="data")
                else:
                    bundle.extractall(install_dir)
        roots = [path for path in install_dir.iterdir() if (path / "zig").is_file()]
        if len(roots) != 1:
            raise ValueError("Zig archive did not contain a single toolchain")
        return roots[0]
    except Exception:
        shutil.rmtree(install_dir, ignore_errors=True)
        raise


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: install.py VERSION", file=sys.stderr)
        return 2
    try:
        toolchain = install(
            argv[1],
            platform_key(),
            Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())),
        )
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    github_path = os.environ.get("GITHUB_PATH")
    if github_path:
        with open(github_path, "a", encoding="utf-8") as handle:
            handle.write(f"{toolchain}\n")
    else:
        print(toolchain)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
