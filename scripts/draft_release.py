#!/usr/bin/env python3
"""Verify both native artifacts, then create (never publish) a GitHub draft."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import zipfile

from package_release import TAG_PATTERN
from build_metadata import source_identity, validate_info

ROOT = Path(__file__).resolve().parent.parent


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


def collect_artifacts(directory, tag, commit, *, identity=None):
    identity = identity or source_identity(ROOT)
    if identity[0] != commit:
        raise SystemExit("Release checkout belongs to a different commit")
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
        validate_info(info, identity, target)
        if info["binary_version"] != f"zig-nico-list version {tag}":
            raise SystemExit(f"Executable version does not match {tag}")
        artifact = folder / expected
        with artifact.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != info.get("sha256"):
            raise SystemExit(f"Archive checksum mismatch for {target}")
        prefix = expected.removesuffix(extension)
        expected_names = {f"{prefix}/{name}" for name in
                          (info["binary"], "BUILD-INFO.json", "README.md", "LICENSE", "LICENSE-ZIG.txt")}
        if extension == ".zip":
            with zipfile.ZipFile(artifact) as bundle:
                if set(bundle.namelist()) != expected_names or len(bundle.namelist()) != len(expected_names):
                    raise SystemExit("Unexpected release archive payload")
                embedded_info = bundle.read(f"{prefix}/BUILD-INFO.json")
                binary = bundle.read(f"{prefix}/{info['binary']}")
        else:
            with tarfile.open(artifact, "r:gz") as bundle:
                members = bundle.getmembers()
                if ({m.name for m in members} != expected_names or len(members) != len(expected_names)
                        or not all(m.isfile() for m in members)):
                    raise SystemExit("Unexpected release archive payload")
                embedded_info = bundle.extractfile(f"{prefix}/BUILD-INFO.json").read()
                binary = bundle.extractfile(f"{prefix}/{info['binary']}").read()
        expected_info = {key: value for key, value in info.items() if key not in {"tag", "archive", "sha256"}}
        if json.loads(embedded_info) != expected_info:
            raise SystemExit("Embedded build information differs from artifact manifest")
        if not binary or hashlib.sha256(binary).hexdigest() != info["binary_sha256"]:
            raise SystemExit("Archived executable checksum differs from build information")
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
    # This function is reached only after all native jobs and artifact checks pass.
    ensure_tag(repository, tag, commit, allow_create=event == "workflow_dispatch")
    with tempfile.TemporaryDirectory(prefix="release-metadata-") as temporary:
        checksums = Path(temporary) / "SHA256SUMS"
        checksums.write_text("".join(sorted(sums)), encoding="utf-8", newline="\n")
        notes = Path(temporary) / "notes.md"
        notes.write_text(
            f"Source commit: `{commit}`\n\n"
            "Native x86_64 Linux and Windows binaries built with the pinned Zig 0.17.0 toolchain, "
            "ReleaseFast optimization, and baseline CPU features. All native unit and integration "
            "jobs passed for this exact tag commit.\n\n"
            "Normal builds reuse compiler caches but always install a fresh executable and verify "
            "its commit, source tree, build inputs, settings, version, and SHA-256. Archives generated "
            "twice are byte-identical, and their embedded metadata and executable hashes are checked. "
            "Cold two-build reproducibility is a separate manual workflow and is NOT established "
            "by this release run; independent-machine reproducibility is not claimed.\n\n"
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
