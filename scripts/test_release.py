"""Fast, offline checks for normalized release packaging."""

import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from draft_release import collect_artifacts, ensure_tag, resolve_tag
from install_zig import DISTRIBUTIONS, VERSION
from package_release import TAG_PATTERN, archive_bytes


class PackagingTests(unittest.TestCase):
    files = {"README.md": (b"documentation\n", 0o644), "zig-nico-list": (b"binary\x00\xff", 0o755)}

    def test_tag_validation(self):
        for tag in ("v0.01", "v1.2.3", "v1.2.3-rc.1"):
            self.assertIsNotNone(re.fullmatch(TAG_PATTERN, tag))
        for tag in ("v", "../v1", "v1/a", "v1\n", "v1;exit", "v1$(id)"):
            self.assertIsNone(re.fullmatch(TAG_PATTERN, tag))

    def test_pinned_toolchains(self):
        self.assertEqual(VERSION, "0.17.0")
        self.assertEqual(set(DISTRIBUTIONS), {"Linux", "Windows"})
        for _, _, digest in DISTRIBUTIONS.values():
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_repeatable_archives_and_order(self):
        for windows in (False, True):
            first = archive_bytes("release", self.files, windows)
            second = archive_bytes("release", dict(reversed(list(self.files.items()))), windows)
            self.assertEqual(first, second)

    def test_tar_metadata_and_payload(self):
        data = archive_bytes("release", self.files, False)
        self.assertEqual(data[4:8], b"\0\0\0\0")  # gzip timestamp
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(data))) as archive:
            self.assertEqual(archive.getnames(), ["release/README.md", "release/zig-nico-list"])
            for info in archive:
                name = info.name.split("/")[-1]
                self.assertEqual((info.uid, info.gid, info.mtime, info.uname, info.gname), (0, 0, 0, "", ""))
                self.assertEqual(info.mode, self.files[name][1])
                self.assertEqual(archive.extractfile(info).read(), self.files[name][0])

    def test_zip_metadata_and_payload(self):
        with zipfile.ZipFile(io.BytesIO(archive_bytes("release", self.files, True))) as archive:
            self.assertEqual(archive.namelist(), ["release/README.md", "release/zig-nico-list"])
            for info in archive.infolist():
                name = info.filename.split("/")[-1]
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(info.compress_type, zipfile.ZIP_STORED)
                self.assertEqual((info.external_attr >> 16) & 0o777, self.files[name][1])
                self.assertEqual(archive.read(info), self.files[name][0])


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.commit = "a" * 40
        for target, extension in (("linux-x86_64", ".tar.gz"), ("windows-x86_64", ".zip")):
            folder = self.directory / target
            folder.mkdir()
            name = f"zig-nico-list-v0.01-{target}{extension}"
            (folder / name).write_bytes(b"test artifact")
            info = {"tag": "v0.01", "source_commit": self.commit, "target": target,
                    "archive": name, "zig_version": "0.17.0", "binary_sha256": "b" * 64,
                    "repeat_binary_sha256": "b" * 64, "sha256": hashlib.sha256(b"test artifact").hexdigest()}
            (folder / "artifact-info.json").write_text(json.dumps(info), encoding="utf-8")

    def test_requires_both_exact_artifacts(self):
        artifacts, sums = collect_artifacts(self.directory, "v0.01", self.commit)
        self.assertEqual(len(artifacts), 2)
        self.assertEqual(len(sums), 2)
        (self.directory / "windows-x86_64" / "unexpected.txt").touch()
        with self.assertRaises(SystemExit):
            collect_artifacts(self.directory, "v0.01", self.commit)

    def test_rejects_different_commit(self):
        with self.assertRaises(SystemExit):
            collect_artifacts(self.directory, "v0.01", "c" * 40)

    def test_rejects_modified_archive(self):
        (self.directory / "linux-x86_64" / "zig-nico-list-v0.01-linux-x86_64.tar.gz").write_bytes(b"changed")
        with self.assertRaises(SystemExit):
            collect_artifacts(self.directory, "v0.01", self.commit)

    def test_rejects_failed_repeat_build(self):
        path = self.directory / "windows-x86_64" / "artifact-info.json"
        info = json.loads(path.read_text(encoding="utf-8"))
        info["repeat_binary_sha256"] = "c" * 64
        path.write_text(json.dumps(info), encoding="utf-8")
        with self.assertRaises(SystemExit):
            collect_artifacts(self.directory, "v0.01", self.commit)


class TagGateTests(unittest.TestCase):
    repository = "sh4869221b/zig-nico-list"
    commit = "a" * 40

    def ref(self, kind="commit", commit=None):
        return json.dumps({"object": {"type": kind, "sha": commit or self.commit}})

    @patch("draft_release.gh")
    def test_existing_tag_is_not_modified(self, api):
        api.return_value = self.ref()
        ensure_tag(self.repository, "v0.01", self.commit, allow_create=True)
        self.assertEqual(api.call_count, 1)

    @patch("draft_release.gh")
    def test_missing_dispatch_tag_is_created_then_verified(self, api):
        api.side_effect = ["", self.ref(), self.ref()]
        ensure_tag(self.repository, "v0.01", self.commit, allow_create=True)
        self.assertEqual(api.call_count, 3)
        self.assertEqual(api.call_args_list[1].args, ("api", "--method", "POST", f"repos/{self.repository}/git/refs",
                                                    "-f", "ref=refs/tags/v0.01", "-f", f"sha={self.commit}"))

    @patch("draft_release.gh")
    def test_missing_push_tag_is_not_created(self, api):
        api.return_value = ""
        with self.assertRaises(SystemExit):
            ensure_tag(self.repository, "v0.01", self.commit, allow_create=False)
        self.assertEqual(api.call_count, 1)

    @patch("draft_release.gh")
    def test_mismatched_tag_is_not_rewritten(self, api):
        api.return_value = self.ref(commit="b" * 40)
        with self.assertRaises(SystemExit):
            ensure_tag(self.repository, "v0.01", self.commit, allow_create=True)
        self.assertEqual(api.call_count, 1)

    @patch("draft_release.gh")
    def test_annotated_tag_is_peeled(self, api):
        api.side_effect = [self.ref(kind="tag", commit="b" * 40), self.ref()]
        self.assertEqual(resolve_tag(self.repository, "v0.01"), self.commit)
        self.assertEqual(api.call_count, 2)

    @patch("draft_release.gh")
    def test_api_error_is_not_mistaken_for_missing_tag(self, api):
        api.side_effect = subprocess.CalledProcessError(1, "gh")
        with self.assertRaises(subprocess.CalledProcessError):
            ensure_tag(self.repository, "v0.01", self.commit, allow_create=True)
        self.assertEqual(api.call_count, 1)


if __name__ == "__main__":
    unittest.main()
