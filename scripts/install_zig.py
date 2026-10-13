#!/usr/bin/env python3
"""Install the SHA-256-pinned official Zig distribution for this native host."""

import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

VERSION = "0.17.0"
DISTRIBUTIONS = {
    "Linux": ("linux", ".tar.xz", "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"),
    "Windows": ("windows", ".zip", "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"),
}


def main():
    if platform.machine().lower() not in {"x86_64", "amd64"}:
        raise SystemExit("Only native x86_64 Linux and Windows are supported")
    target, extension, expected = DISTRIBUTIONS[platform.system()]
    root = Path(tempfile.mkdtemp(prefix="zig-pinned-", dir=os.environ.get("RUNNER_TEMP")))
    name = f"zig-x86_64-{target}-{VERSION}"
    archive = root / (name + extension)
    url = f"https://ziglang.org/download/{VERSION}/{archive.name}"
    print(f"Downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=180) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise SystemExit(f"Zig archive checksum mismatch: expected {expected}, got {actual}")
    if extension == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(root)
    else:
        with tarfile.open(archive, "r:xz") as bundle:
            bundle.extractall(root, filter="data")
    directory = root / name
    executable = directory / ("zig.exe" if target == "windows" else "zig")
    version = subprocess.check_output([str(executable), "version"], text=True).strip()
    if version != VERSION:
        raise SystemExit(f"Unexpected Zig version: {version}")
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
        output.write(str(directory) + "\n")
    print(f"Verified Zig {version}: {actual}")


if __name__ == "__main__":
    main()
