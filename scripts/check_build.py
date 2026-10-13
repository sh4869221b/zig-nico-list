#!/usr/bin/env python3
"""Compare two native ReleaseFast builds with separate, initially empty caches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    args = parser.parse_args()
    system = platform.system()
    if system not in {"Linux", "Windows"} or platform.machine().lower() not in {"amd64", "x86_64"}:
        raise SystemExit("This check must run natively on x86_64 Linux or Windows")
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise SystemExit(f"Expected Zig 0.17.0, got {version}")
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True)
    commit = commit.stdout.strip() if commit.returncode == 0 else None
    expected_commit = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA")
    if expected_commit and commit != expected_commit:
        raise SystemExit("The checkout does not match this workflow's exact commit")
    executable = "zig-nico-list" + (".exe" if system == "Windows" else "")
    with tempfile.TemporaryDirectory(prefix="zig-repeat-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        base = Path(temporary)
        binaries = []
        for label in ("first", "second"):
            folder = base / label
            environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(folder / "global"), ZIG_LOCAL_CACHE_DIR=str(folder / "local"))
            subprocess.run([
                args.zig, "build", "-Doptimize=fast", "-Dcpu=baseline",
                "--cache-dir", str(folder / "local"),
                "--prefix", str(folder / "out"),
            ], cwd=ROOT, env=environment, check=True)
            binaries.append(folder / "out" / "bin" / executable)
        first, second = (binary.read_bytes() for binary in binaries)
        if not first or first != second:
            raise SystemExit("Independent-cache ReleaseFast builds are not byte-identical")
        destination = ROOT / "zig-out" / "bin" / executable
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binaries[0], destination)
    digest = hashlib.sha256(first).hexdigest()
    info = {
        "source_commit": commit,
        "zig_version": version,
        "target": f"{system.lower()}-x86_64",
        "build_options": ["-Doptimize=fast", "-Dcpu=baseline"],
        "binary": executable,
        "binary_sha256": digest,
        "repeat_binary_sha256": hashlib.sha256(second).hexdigest(),
        "verification": "Two native builds in this job, with separate empty local and global caches",
    }
    (ROOT / "zig-out" / "build-info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"Byte-identical repeat builds: {digest}  {executable}", flush=True)


if __name__ == "__main__":
    main()
