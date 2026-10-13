#!/usr/bin/env python3
"""Verify both native artifacts, then create (never publish) a GitHub draft."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from package_release import TAG_PATTERN


def gh(*arguments):
    return subprocess.check_output(["gh", *arguments], text=True).strip()


def resolve_tag(repository, tag):
    # Matching refs returns an empty list when absent; all API failures still fail.
    result = gh("api", f"repos/{repository}/git/matching-refs/tags/{tag}", "--paginate",
                "--jq", f'.[] | select(.ref == "refs/tags/{tag}")')
    if not result:
        return None
    obj = json.loads(result)["object"]
    for _ in range(10):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            break
        obj = json.loads(gh("api", f"repos/{repository}/git/tags/{obj['sha']}"))["object"]
    raise SystemExit("Release tag does not resolve to a commit")


def ensure_tag(repository, tag, commit, allow_create):
    actual = resolve_tag(repository, tag)
    if actual is None and allow_create:
        gh("api", "--method", "POST", f"repos/{repository}/git/refs",
           "-f", f"ref=refs/tags/{tag}", "-f", f"sha={commit}")
        actual = resolve_tag(repository, tag)
    if actual != commit:
        raise SystemExit("Remote tag is missing or points to a different commit; it will not be rewritten")


def collect_artifacts(directory, tag, commit):
    artifacts, sums = [], []
    for target, extension in (("linux-x86_64", ".tar.gz"), ("windows-x86_64", ".zip")):
        folder = directory / target
        info = json.loads((folder / "artifact-info.json").read_text(encoding="utf-8"))
        expected = f"zig-nico-list-{tag}-{target}{extension}"
        if {p.name for p in folder.iterdir()} != {expected, "artifact-info.json"}:
            raise SystemExit(f"Missing or unexpected release files for {target}")
        for key, value in {"tag": tag, "source_commit": commit, "target": target, "archive": expected, "zig_version": "0.17.0"}.items():
            if info.get(key) != value:
                raise SystemExit(f"Unexpected {key} in {target} build information")
        if not re.fullmatch(r"[0-9a-f]{64}", info.get("binary_sha256", "")) or info["binary_sha256"] != info.get("repeat_binary_sha256"):
            raise SystemExit(f"Repeat-build verification missing for {target}")
        artifact = folder / expected
        with artifact.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != info.get("sha256"):
            raise SystemExit(f"Archive checksum mismatch for {target}")
        artifacts.append(str(artifact))
        sums.append(f"{digest}  {expected}\n")
    return artifacts, sums


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    tag, commit = os.environ["RELEASE_TAG"], os.environ["RELEASE_COMMIT"]
    event = os.environ["GITHUB_EVENT_NAME"]
    if repository != "sh4869221b/zig-nico-list" or event not in {"push", "workflow_dispatch"}:
        raise SystemExit("Draft releases require a version tag push or manual dispatch in this repository")
    if event == "push" and (os.environ["GITHUB_REF_TYPE"] != "tag" or os.environ["GITHUB_REF_NAME"] != tag):
        raise SystemExit("Push-triggered releases must use the pushed tag")
    if not re.fullmatch(TAG_PATTERN, tag) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("Unexpected release tag or commit")
    if commit != os.environ["GITHUB_SHA"] or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != commit:
        raise SystemExit("Release checkout does not match the tested commit")
    artifacts, sums = collect_artifacts(Path("release-input"), tag, commit)
    # This function is reached only after both native jobs and artifact checks pass.
    ensure_tag(repository, tag, commit, allow_create=event == "workflow_dispatch")
    with tempfile.TemporaryDirectory(prefix="release-metadata-") as temporary:
        checksums = Path(temporary) / "SHA256SUMS"
        checksums.write_text("".join(sorted(sums)), encoding="utf-8", newline="\n")
        notes = Path(temporary) / "notes.md"
        notes.write_text(
            f"Source commit: `{commit}`\n\n"
            "Native x86_64 Linux and Windows binaries built with the pinned Zig 0.17.0 toolchain, "
            "ReleaseFast optimization, and baseline CPU features. Both native jobs passed Zig unit "
            "tests and the Python integration suite for this exact tag commit.\n\n"
            "Each job compared two builds using separate empty local and global caches and checked "
            "byte-identical archives generated twice. This verifies repeatability within each CI job; "
            "independent-machine reproducibility has not been established.\n\n"
            "Archives include README.md, LICENSE, LICENSE-ZIG.txt, and BUILD-INFO.json. "
            "Download SHA256SUMS with the archives and verify the SHA-256 checksums before use.\n",
            encoding="utf-8", newline="\n",
        )
        # --verify-tag prevents implicit tag creation; --draft is never removed.
        print(gh("release", "create", tag, *artifacts, str(checksums), "--repo", repository,
                 "--draft", "--verify-tag", "--target", commit, "--title", tag, "--notes-file", str(notes)))
    result = json.loads(gh("release", "view", tag, "--repo", repository, "--json", "isDraft,tagName,assets,url"))
    expected_assets = {Path(name).name for name in artifacts} | {"SHA256SUMS"}
    if result["isDraft"] is not True or result["tagName"] != tag or {a["name"] for a in result["assets"]} != expected_assets:
        raise SystemExit("Draft verification failed; inspect the release manually")
    print(f"Verified complete draft (manual publication required): {result['url']}")


if __name__ == "__main__":
    main()
