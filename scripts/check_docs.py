#!/usr/bin/env python3
"""Offline document sanity checks, including the files required by packaging."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ("README.md", "LICENSE", "LICENSE-ZIG.txt")


def check_documents(root=ROOT):
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode("utf-8").split("\0")
    documents = {path for path in files if path.endswith(".md")} | set(REQUIRED)
    for name in sorted(documents):
        text = (root / name).read_text(encoding="utf-8")
        if "\0" in text:
            raise SystemExit(f"NUL byte in document: {name}")
        if name in REQUIRED and not text.strip():
            raise SystemExit(f"Required package document is empty: {name}")
    return len(documents)


if __name__ == "__main__":
    print(f"Checked {check_documents()} UTF-8 documents and all required package documents")
