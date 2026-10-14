"""Shared strict identity checks for normal cached builds and release inputs."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

from install_zig import VERSION

BUILD_OPTIONS = ["-Doptimize=fast", "-Dcpu=baseline"]
VERIFICATION = "cached-native-build-v1"
SCHEMA_VERSION = 2
TARGET_BINARIES = {"linux-x86_64": "zig-nico-list", "windows-x86_64": "zig-nico-list.exe"}


def source_identity(root):
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip()
    if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (commit, tree)):
        raise SystemExit("A committed source tree is required")
    expected = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA")
    if expected and commit != expected:
        raise SystemExit("Checkout differs from this workflow's exact commit")
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--"], cwd=root, check=True)
    # Reject extra compilation inputs, too. Output/cache directories are ignored.
    extra = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--",
                                     "build.zig", "build.zig.zon", "src"], cwd=root, text=True)
    if extra.strip():
        raise SystemExit("Untracked build inputs are not allowed")
    files = [root / "build.zig", *sorted((root / "src").rglob("*.zig"))]
    if (root / "build.zig.zon").exists():
        files.append(root / "build.zig.zon")
    inputs = [(path.relative_to(root).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest())
              for path in sorted(files)]
    digest = hashlib.sha256(json.dumps(inputs, separators=(",", ":")).encode()).hexdigest()
    return commit, tree, digest


def native_target():
    system = platform.system()
    if system not in {"Linux", "Windows"} or platform.machine().lower() not in {"amd64", "x86_64"}:
        raise SystemExit("This build must run natively on x86_64 Linux or Windows")
    return f"{system.lower()}-x86_64"


def validate_info(info, identity, target):
    commit, tree, source_digest = identity
    expected = {"schema_version": SCHEMA_VERSION, "source_commit": commit,
                "source_tree": tree, "source_sha256": source_digest,
                "zig_version": VERSION, "target": target,
                "build_options": BUILD_OPTIONS, "binary": TARGET_BINARIES[target],
                "verification": VERIFICATION}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f"Unexpected {key} in build information")
    if not re.fullmatch(r"[0-9a-f]{64}", info.get("binary_sha256", "")):
        raise SystemExit("Missing executable SHA-256")
    if not re.fullmatch(r"zig-nico-list version v[0-9][0-9A-Za-z._+-]*", info.get("binary_version", "")):
        raise SystemExit("Unexpected executable version")
    if "repeat_binary_sha256" in info:
        raise SystemExit("Cached builds must not claim cold repeat-build verification")


def verify_output(root):
    info = json.loads((root / "zig-out/build-info.json").read_text(encoding="utf-8"))
    validate_info(info, source_identity(root), native_target())
    binary_path = root / "zig-out/bin" / info["binary"]
    binary = binary_path.read_bytes()
    if not binary or hashlib.sha256(binary).hexdigest() != info["binary_sha256"]:
        raise SystemExit("Executable changed after this build")
    version = subprocess.check_output([str(binary_path), "--version"], text=True).strip()
    if version != info["binary_version"]:
        raise SystemExit("Executable version changed after this build")
    return info, binary
