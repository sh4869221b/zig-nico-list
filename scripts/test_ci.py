"""Offline cache integrity and cold-build isolation regression checks."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_build
from install_zig import VERSION, verified_archive


class ToolchainCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payload = b"official archive fixture"
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.archive = self.root / f"zig-x86_64-linux-{VERSION}.tar.xz"

    def test_verified_hit_does_not_download(self):
        self.archive.write_bytes(self.payload)
        with patch("install_zig.urllib.request.urlopen") as download:
            self.assertEqual(verified_archive(self.root, "linux", ".tar.xz", self.digest), self.archive)
        download.assert_not_called()

    def test_corrupt_hit_fails_before_use(self):
        self.archive.write_bytes(b"corrupt")
        with patch("install_zig.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                verified_archive(self.root, "linux", ".tar.xz", self.digest)
        download.assert_not_called()

    def test_miss_publishes_only_verified_complete_archive(self):
        with patch("install_zig.urllib.request.urlopen", return_value=io.BytesIO(self.payload)):
            verified_archive(self.root, "linux", ".tar.xz", self.digest)
        self.assertEqual(self.archive.read_bytes(), self.payload)
        self.assertEqual(list(self.root.iterdir()), [self.archive])

    def test_bad_download_is_not_cached(self):
        with patch("install_zig.urllib.request.urlopen", return_value=io.BytesIO(b"bad")):
            with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                verified_archive(self.root, "linux", ".tar.xz", self.digest)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_interrupted_download_is_not_cached(self):
        with patch("install_zig.urllib.request.urlopen", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                verified_archive(self.root, "linux", ".tar.xz", self.digest)
        self.assertEqual(list(self.root.iterdir()), [])


class ColdBuildTests(unittest.TestCase):
    def test_repeat_builds_cannot_use_warm_unit_cache_or_stale_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "zig-out/bin").mkdir(parents=True)
            (root / "zig-out/bin/zig-nico-list").write_bytes(b"stale output")
            commit = "a" * 40
            builds = []

            def run(args, **kwargs):
                if args[:2] == ["git", "rev-parse"]:
                    return subprocess.CompletedProcess(args, 0, stdout=commit + "\n")
                self.assertEqual(args[:4], ["zig", "build", "-Doptimize=fast", "-Dcpu=baseline"])
                env = kwargs["env"]
                local = Path(args[args.index("--cache-dir") + 1])
                global_cache = Path(env["ZIG_GLOBAL_CACHE_DIR"])
                self.assertEqual(env["ZIG_LOCAL_CACHE_DIR"], str(local))
                self.assertFalse(local.exists())
                self.assertFalse(global_cache.exists())
                self.assertNotEqual(str(local), "warm-local")
                self.assertNotEqual(str(global_cache), "warm-global")
                builds.append((local, global_cache))
                output = Path(args[args.index("--prefix") + 1]) / "bin"
                output.mkdir(parents=True)
                (output / "zig-nico-list").write_bytes(b"fresh identical executable")
                return subprocess.CompletedProcess(args, 0)

            with patch.object(check_build, "ROOT", root), \
                 patch("check_build.platform.system", return_value="Linux"), \
                 patch("check_build.platform.machine", return_value="x86_64"), \
                 patch("check_build.subprocess.check_output", return_value="0.17.0\n"), \
                 patch("check_build.subprocess.run", side_effect=run), \
                 patch("sys.argv", ["check_build.py"]), \
                 patch.dict(os.environ, {"RELEASE_COMMIT": commit, "RUNNER_TEMP": temporary,
                                         "ZIG_LOCAL_CACHE_DIR": "warm-local",
                                         "ZIG_GLOBAL_CACHE_DIR": "warm-global"}):
                check_build.main()
            self.assertEqual(len(builds), 2)
            self.assertEqual(len({path for build in builds for path in build}), 4)
            self.assertEqual((root / "zig-out/bin/zig-nico-list").read_bytes(), b"fresh identical executable")
            info = json.loads((root / "zig-out/build-info.json").read_text())
            self.assertEqual(info["source_commit"], commit)
            self.assertEqual(info["binary_sha256"], info["repeat_binary_sha256"])

    def test_unit_run_cannot_reuse_a_previous_success(self):
        source = (Path(__file__).resolve().parent.parent / "build.zig").read_text()
        self.assertIn("run_tests.has_side_effects = true;", source)
        self.assertIn('b.step("test", "Run unit tests").dependOn(&run_tests.step);', source)


if __name__ == "__main__":
    unittest.main()
