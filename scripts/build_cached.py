#!/usr/bin/env python3
"""Build with compiler caches, but always install and identify a fresh output."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from build_metadata import (BUILD_OPTIONS, SCHEMA_VERSION, TARGET_BINARIES, VERIFICATION,
                            VERSION, native_target, source_identity, verify_output)

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        info, _ = verify_output(ROOT)
        print(f"Verified current build: {info['binary_sha256']}  {info['binary']}")
        return
    identity = source_identity(ROOT)
    target = native_target()
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != VERSION:
        raise SystemExit(f"Expected Zig {VERSION}, got {version}")
    executable = TARGET_BINARIES[target]
    destination = ROOT / "zig-out"
    # No old installed executable/receipt may survive a failed build.
    if destination.exists():
        shutil.rmtree(destination)
    local = ROOT / ".zig-cache/release-fast"
    global_cache = ROOT / ".zig-global-cache/release-fast"
    environment = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(local), ZIG_GLOBAL_CACHE_DIR=str(global_cache))
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="zig-cached-output-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        prefix = Path(temporary) / "out"
        subprocess.run([args.zig, "build", *BUILD_OPTIONS, "--cache-dir", str(local),
                        "--prefix", str(prefix), "--summary", "all"], cwd=ROOT, env=environment, check=True)
        output = prefix / "bin" / executable
        data = output.read_bytes()
        if not data:
            raise SystemExit("Build did not generate a nonempty executable")
        binary_version = subprocess.check_output([str(output), "--version"], text=True).strip()
        if identity != source_identity(ROOT):
            raise SystemExit("Source changed while building")
        (destination / "bin").mkdir(parents=True)
        shutil.copy2(output, destination / "bin" / executable)
    info = {"schema_version": SCHEMA_VERSION, "source_commit": identity[0],
            "source_tree": identity[1], "source_sha256": identity[2],
            "zig_version": version, "target": target, "build_options": BUILD_OPTIONS,
            "binary": executable, "binary_version": binary_version,
            "binary_sha256": hashlib.sha256(data).hexdigest(), "verification": VERIFICATION}
    (destination / "build-info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n",
                                                encoding="utf-8", newline="\n")
    verify_output(ROOT)
    print(f"Cached native build: {info['binary_sha256']}  {executable}; {time.monotonic() - started:.3f}s")


if __name__ == "__main__":
    main()
