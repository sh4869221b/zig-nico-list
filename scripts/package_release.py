#!/usr/bin/env python3
"""Create a normalized archive twice, compare it, and record its SHA-256."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TAG_PATTERN = r"v[0-9][0-9A-Za-z._+-]*"


def archive_bytes(prefix, files, windows):
    result = io.BytesIO()
    if windows:
        # Stored entries avoid platform-specific compressor differences.
        with zipfile.ZipFile(result, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, (data, mode) in sorted(files.items()):
                info = zipfile.ZipInfo(f"{prefix}/{name}", (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100000 | mode) << 16
                archive.writestr(info, data)
    else:
        with gzip.GzipFile(fileobj=result, mode="wb", filename="", mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, (data, mode) in sorted(files.items()):
                    info = tarfile.TarInfo(f"{prefix}/{name}")
                    info.size = len(data)
                    info.mode = mode
                    info.mtime = info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    archive.addfile(info, io.BytesIO(data))
    return result.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default=os.environ.get("RELEASE_TAG") or os.environ.get("GITHUB_REF_NAME"))
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if not args.tag or not re.fullmatch(TAG_PATTERN, args.tag):
        raise SystemExit("Expected a version tag such as v0.01")
    info_path = ROOT / "zig-out" / "build-info.json"
    info = json.loads(info_path.read_text(encoding="utf-8"))
    if not re.fullmatch(r"[0-9a-f]{40}", info.get("source_commit") or ""):
        raise SystemExit("A committed source tree is required for a release package")
    expected_commit = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA")
    if expected_commit and info["source_commit"] != expected_commit:
        raise SystemExit("Build information belongs to a different commit")
    if info["target"] not in {"linux-x86_64", "windows-x86_64"}:
        raise SystemExit("Unexpected native target")
    binary_path = ROOT / "zig-out" / "bin" / info["binary"]
    binary = binary_path.read_bytes()
    digest = hashlib.sha256(binary).hexdigest()
    if digest != info["binary_sha256"] or digest != info["repeat_binary_sha256"]:
        raise SystemExit("Binary changed after the repeat-build check")
    version = subprocess.check_output([str(binary_path), "--version"], text=True).strip()
    if version != f"zig-nico-list version {args.tag}":
        raise SystemExit(f"Binary version does not match release tag: {version!r}")
    files = {info["binary"]: (binary, 0o755), "BUILD-INFO.json": (info_path.read_bytes(), 0o644)}
    for name in ("LICENSE", "LICENSE-ZIG.txt", "README.md"):
        data = (ROOT / name).read_bytes()
        if not data:
            raise SystemExit(f"Required package file is empty: {name}")
        files[name] = (data, 0o644)
    prefix = f"zig-nico-list-{args.tag}-{info['target']}"
    windows = info["target"].startswith("windows")
    data = archive_bytes(prefix, files, windows)
    if data != archive_bytes(prefix, files, windows):
        raise SystemExit("Repeated archive generation was not byte-identical")
    filename = prefix + (".zip" if windows else ".tar.gz")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / filename).write_bytes(data)
    manifest = {"tag": args.tag, "archive": filename, "sha256": hashlib.sha256(data).hexdigest(), **info}
    (args.output / "artifact-info.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"{manifest['sha256']}  {filename}")


if __name__ == "__main__":
    main()
