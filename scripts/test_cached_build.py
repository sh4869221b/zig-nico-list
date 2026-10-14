"""Offline regression checks for reusable caches and current-build identity."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import call, patch

import build_cached
import build_metadata


IDENTITY = ("a" * 40, "b" * 40, "c" * 64)
TARGET = "linux-x86_64"
BINARY = "zig-nico-list"
BINARY_VERSION = "zig-nico-list version v0.01"
PAYLOAD = b"fresh executable fixture"


def build_info(identity=IDENTITY, target=TARGET, payload=PAYLOAD):
    return {
        "schema_version": build_metadata.SCHEMA_VERSION,
        "source_commit": identity[0],
        "source_tree": identity[1],
        "source_sha256": identity[2],
        "zig_version": build_metadata.VERSION,
        "target": target,
        "build_options": list(build_metadata.BUILD_OPTIONS),
        "binary": build_metadata.TARGET_BINARIES[target],
        "binary_version": BINARY_VERSION,
        "binary_sha256": hashlib.sha256(payload).hexdigest(),
        "verification": build_metadata.VERIFICATION,
    }


class TemporaryRootTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def installed_output(self, info=None, payload=PAYLOAD):
        info = build_info(payload=payload) if info is None else info
        destination = self.root / "zig-out"
        (destination / "bin").mkdir(parents=True, exist_ok=True)
        (destination / "bin" / info["binary"]).write_bytes(payload)
        (destination / "build-info.json").write_text(json.dumps(info), encoding="utf-8")
        return destination


class CachedBuildTests(TemporaryRootTests):
    def setUp(self):
        super().setUp()
        self.addCleanup(patch.stopall)
        patch.object(build_cached, "ROOT", self.root).start()
        self.identity = patch("build_cached.source_identity", return_value=IDENTITY).start()
        patch("build_metadata.source_identity", return_value=IDENTITY).start()
        patch("build_cached.native_target", return_value=TARGET).start()
        patch("build_metadata.native_target", return_value=TARGET).start()
        patch("sys.argv", ["build_cached.py", "--zig", "fixture-zig"]).start()
        patch("sys.stdout", new_callable=io.StringIO).start()
        patch.dict(os.environ, {"RUNNER_TEMP": str(self.root),
                                "ZIG_LOCAL_CACHE_DIR": "unrelated-local-cache",
                                "ZIG_GLOBAL_CACHE_DIR": "unrelated-global-cache"}).start()
        self.command_output = patch("build_cached.subprocess.check_output", side_effect=self.output).start()
        self.run = patch("build_cached.subprocess.run", side_effect=self.build).start()
        self.prefixes = []

    def output(self, args, **kwargs):
        self.assertTrue(kwargs["text"])
        if args == ["fixture-zig", "version"]:
            return build_metadata.VERSION + "\n"
        self.assertEqual(args[1:], ["--version"])
        self.assertEqual(Path(args[0]).read_bytes(), PAYLOAD)
        return BINARY_VERSION + "\n"

    def build(self, args, **kwargs):
        self.assertEqual(args[:4], ["fixture-zig", "build", "-Doptimize=fast", "-Dcpu=baseline"])
        self.assertEqual(args[-2:], ["--summary", "all"])
        self.assertEqual(kwargs["cwd"], self.root)
        self.assertTrue(kwargs["check"])
        local = self.root / ".zig-cache/release-fast"
        global_cache = self.root / ".zig-global-cache/release-fast"
        self.assertEqual(args[args.index("--cache-dir") + 1], str(local))
        self.assertEqual(kwargs["env"]["ZIG_LOCAL_CACHE_DIR"], str(local))
        self.assertEqual(kwargs["env"]["ZIG_GLOBAL_CACHE_DIR"], str(global_cache))
        prefix = Path(args[args.index("--prefix") + 1])
        self.assertEqual(prefix.name, "out")
        self.assertNotEqual(prefix, self.root / "zig-out")
        self.assertEqual(prefix.parent.parent, self.root)
        self.assertFalse(prefix.exists())
        self.assertFalse((self.root / "zig-out").exists())
        self.prefixes.append(prefix)
        (prefix / "bin").mkdir(parents=True)
        (prefix / "bin" / BINARY).write_bytes(PAYLOAD)
        return subprocess.CompletedProcess(args, 0)

    def test_reuses_compiler_caches_but_installs_fresh_output_each_time(self):
        self.installed_output(payload=b"stale executable")
        (self.root / "zig-out/stale-file").write_bytes(b"stale receipt")
        cache_files = []
        for directory in (".zig-cache/release-fast", ".zig-global-cache/release-fast"):
            cache = self.root / directory
            cache.mkdir(parents=True)
            marker = cache / "existing-cache-entry"
            marker.write_bytes(b"reusable compiler state")
            cache_files.append(marker)

        build_cached.main()
        build_cached.main()

        self.assertEqual(self.run.call_count, 2)
        self.assertEqual(len(set(self.prefixes)), 2)
        self.assertTrue(all(not prefix.parent.exists() for prefix in self.prefixes))
        self.assertTrue(all(path.read_bytes() == b"reusable compiler state" for path in cache_files))
        self.assertEqual((self.root / "zig-out/bin" / BINARY).read_bytes(), PAYLOAD)
        self.assertFalse((self.root / "zig-out/stale-file").exists())
        info = json.loads((self.root / "zig-out/build-info.json").read_text(encoding="utf-8"))
        self.assertEqual(info, build_info())
        self.assertNotIn("repeat_binary_sha256", info)
        self.assertEqual(self.identity.call_count, 4)

    def test_failed_build_cannot_leave_previous_install_or_receipt(self):
        self.installed_output(payload=b"previous successful executable")
        self.run.side_effect = subprocess.CalledProcessError(1, "fixture-zig")
        with self.assertRaises(subprocess.CalledProcessError):
            build_cached.main()
        self.assertFalse((self.root / "zig-out").exists())
        self.assertEqual(list(self.root.glob("zig-cached-output-*")), [])

    def test_success_without_output_cannot_reuse_previous_install(self):
        self.installed_output(payload=b"previous successful executable")
        self.run.side_effect = None
        with self.assertRaises(FileNotFoundError):
            build_cached.main()
        self.assertFalse((self.root / "zig-out").exists())
        self.assertEqual(list(self.root.glob("zig-cached-output-*")), [])

    def test_empty_output_is_rejected_without_installing_it(self):
        self.installed_output(payload=b"previous successful executable")

        def empty_build(args, **kwargs):
            self.build(args, **kwargs)
            (self.prefixes[-1] / "bin" / BINARY).write_bytes(b"")

        self.run.side_effect = empty_build
        with self.assertRaisesRegex(SystemExit, "nonempty executable"):
            build_cached.main()
        self.assertFalse((self.root / "zig-out").exists())

    def test_wrong_zig_version_is_rejected_before_build(self):
        self.command_output.side_effect = None
        self.command_output.return_value = "0.16.0\n"
        with self.assertRaisesRegex(SystemExit, "Expected Zig"):
            build_cached.main()
        self.run.assert_not_called()

    def test_source_change_during_build_is_rejected(self):
        self.installed_output(payload=b"previous successful executable")
        self.identity.side_effect = [IDENTITY, (IDENTITY[0], IDENTITY[1], "d" * 64)]
        with self.assertRaisesRegex(SystemExit, "Source changed while building"):
            build_cached.main()
        self.assertFalse((self.root / "zig-out").exists())

    def test_verify_only_checks_current_output_without_building(self):
        self.installed_output()
        with patch("sys.argv", ["build_cached.py", "--verify-only"]):
            build_cached.main()
        self.run.assert_not_called()
        self.identity.assert_not_called()
        self.command_output.assert_called_once_with(
            [str(self.root / "zig-out/bin" / BINARY), "--version"], text=True)

    def test_verify_only_rejects_modified_output(self):
        self.installed_output(payload=b"changed executable", info=build_info())
        with patch("sys.argv", ["build_cached.py", "--verify-only"]):
            with self.assertRaisesRegex(SystemExit, "Executable changed"):
                build_cached.main()
        self.run.assert_not_called()
        self.command_output.assert_not_called()


class BuildInformationTests(unittest.TestCase):
    def test_current_native_metadata_is_valid_on_both_platforms(self):
        for target in build_metadata.TARGET_BINARIES:
            with self.subTest(target=target):
                build_metadata.validate_info(build_info(target=target), IDENTITY, target)

    def test_rejects_incorrect_identity_settings_or_verification(self):
        changes = {
            "schema_version": 1,
            "source_commit": "d" * 40,
            "source_tree": "d" * 40,
            "source_sha256": "d" * 64,
            "zig_version": "0.16.0",
            "target": "windows-x86_64",
            "build_options": ["-Doptimize=safe", "-Dcpu=baseline"],
            "binary": "zig-nico-list.exe",
            "verification": "cold-repeat-build",
        }
        for key, value in changes.items():
            with self.subTest(field=key):
                info = build_info()
                info[key] = value
                with self.assertRaisesRegex(SystemExit, "Unexpected " + key):
                    build_metadata.validate_info(info, IDENTITY, TARGET)

    def test_rejects_missing_required_metadata(self):
        for key in build_info():
            with self.subTest(field=key):
                info = build_info()
                del info[key]
                with self.assertRaises(SystemExit):
                    build_metadata.validate_info(info, IDENTITY, TARGET)

    def test_rejects_invalid_executable_digests(self):
        for digest in ("", "a" * 63, "a" * 65, "A" * 64, "g" * 64):
            with self.subTest(digest=digest):
                info = build_info()
                info["binary_sha256"] = digest
                with self.assertRaisesRegex(SystemExit, "SHA-256"):
                    build_metadata.validate_info(info, IDENTITY, TARGET)

    def test_rejects_invalid_executable_versions(self):
        for version in ("", "0.01", "zig-nico-list version v", "other-tool version v0.01"):
            with self.subTest(version=version):
                info = build_info()
                info["binary_version"] = version
                with self.assertRaisesRegex(SystemExit, "Unexpected executable version"):
                    build_metadata.validate_info(info, IDENTITY, TARGET)

    def test_cached_metadata_cannot_claim_repeat_build_verification(self):
        info = build_info()
        info["repeat_binary_sha256"] = info["binary_sha256"]
        with self.assertRaisesRegex(SystemExit, "must not claim cold repeat-build"):
            build_metadata.validate_info(info, IDENTITY, TARGET)


class VerifyOutputTests(TemporaryRootTests):
    def setUp(self):
        super().setUp()
        self.addCleanup(patch.stopall)
        self.identity = patch("build_metadata.source_identity", return_value=IDENTITY).start()
        self.target = patch("build_metadata.native_target", return_value=TARGET).start()
        self.version = patch("build_metadata.subprocess.check_output", return_value=BINARY_VERSION + "\n").start()

    def test_returns_checked_metadata_and_executable(self):
        self.installed_output()
        self.assertEqual(build_metadata.verify_output(self.root), (build_info(), PAYLOAD))
        self.identity.assert_called_once_with(self.root)
        self.target.assert_called_once_with()
        self.version.assert_called_once_with(
            [str(self.root / "zig-out/bin" / BINARY), "--version"], text=True)

    def test_rejects_previous_commit_tree_or_source_before_running_binary(self):
        self.installed_output()
        for index in range(3):
            with self.subTest(identity_component=index):
                identity = list(IDENTITY)
                identity[index] = "d" * len(identity[index])
                self.identity.return_value = tuple(identity)
                with self.assertRaisesRegex(SystemExit, "Unexpected source_"):
                    build_metadata.verify_output(self.root)
        self.version.assert_not_called()

    def test_rejects_output_for_other_native_target(self):
        self.installed_output()
        self.target.return_value = "windows-x86_64"
        with self.assertRaisesRegex(SystemExit, "Unexpected target"):
            build_metadata.verify_output(self.root)
        self.version.assert_not_called()

    def test_rejects_modified_or_empty_executable_before_execution(self):
        for payload in (b"tampered executable", b""):
            with self.subTest(payload=payload):
                self.installed_output(info=build_info(), payload=payload)
                with self.assertRaisesRegex(SystemExit, "Executable changed"):
                    build_metadata.verify_output(self.root)
        self.version.assert_not_called()

    def test_empty_executable_is_rejected_even_with_matching_digest(self):
        self.installed_output(payload=b"")
        with self.assertRaisesRegex(SystemExit, "Executable changed"):
            build_metadata.verify_output(self.root)
        self.version.assert_not_called()

    def test_rejects_changed_reported_executable_version(self):
        self.installed_output()
        self.version.return_value = "zig-nico-list version v9.99\n"
        with self.assertRaisesRegex(SystemExit, "Executable version changed"):
            build_metadata.verify_output(self.root)

    def test_missing_receipt_or_executable_cannot_verify(self):
        with self.assertRaises(FileNotFoundError):
            build_metadata.verify_output(self.root)
        self.installed_output()
        (self.root / "zig-out/bin" / BINARY).unlink()
        with self.assertRaises(FileNotFoundError):
            build_metadata.verify_output(self.root)
        self.version.assert_not_called()


class SourceIdentityTests(TemporaryRootTests):
    def setUp(self):
        super().setUp()
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"RELEASE_COMMIT": "", "GITHUB_SHA": ""}).start()
        (self.root / "src/nested").mkdir(parents=True)
        (self.root / "build.zig").write_bytes(b"build source\n")
        (self.root / "src/main.zig").write_bytes(b"main source\n")
        (self.root / "src/nested/module.zig").write_bytes(b"nested source\n")
        self.untracked = ""
        self.git = patch("build_metadata.subprocess.check_output", side_effect=self.git_output).start()
        self.diff = patch("build_metadata.subprocess.run").start()

    def git_output(self, args, **kwargs):
        self.assertEqual(kwargs, {"cwd": self.root, "text": True})
        if args == ["git", "rev-parse", "HEAD"]:
            return IDENTITY[0] + "\n"
        if args == ["git", "rev-parse", "HEAD^{tree}"]:
            return IDENTITY[1] + "\n"
        self.assertEqual(args, ["git", "ls-files", "--others", "--exclude-standard", "--",
                                "build.zig", "build.zig.zon", "src"])
        return self.untracked

    def test_records_commit_tree_and_deterministic_build_input_digest(self):
        (self.root / "build.zig.zon").write_bytes(b"dependency configuration\n")
        inputs = [(name, hashlib.sha256((self.root / name).read_bytes()).hexdigest())
                  for name in ("build.zig", "build.zig.zon", "src/main.zig", "src/nested/module.zig")]
        expected = hashlib.sha256(json.dumps(inputs, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(build_metadata.source_identity(self.root), (*IDENTITY[:2], expected))
        self.assertEqual(build_metadata.source_identity(self.root), (*IDENTITY[:2], expected))
        self.diff.assert_has_calls([call(["git", "diff", "--exit-code", "HEAD", "--"],
                                         cwd=self.root, check=True)] * 2)

    def test_digest_changes_for_each_build_input_but_not_cache_or_output(self):
        original = build_metadata.source_identity(self.root)
        for name in ("build.zig", "src/main.zig", "src/nested/module.zig"):
            with self.subTest(source=name):
                path = self.root / name
                original_bytes = path.read_bytes()
                path.write_bytes(original_bytes + b"changed\n")
                self.assertNotEqual(build_metadata.source_identity(self.root)[2], original[2])
                path.write_bytes(original_bytes)
        (self.root / "build.zig.zon").write_bytes(b"new dependency input\n")
        self.assertNotEqual(build_metadata.source_identity(self.root)[2], original[2])
        (self.root / "build.zig.zon").unlink()
        for directory in (".zig-cache", ".zig-global-cache", "zig-out"):
            (self.root / directory).mkdir()
            (self.root / directory / "ignored.zig").write_bytes(b"cached or generated content")
        self.assertEqual(build_metadata.source_identity(self.root), original)

    def test_rejects_checkout_different_from_workflow_commit(self):
        for variable in ("RELEASE_COMMIT", "GITHUB_SHA"):
            with self.subTest(variable=variable), patch.dict(os.environ, {variable: "d" * 40}):
                with self.assertRaisesRegex(SystemExit, "exact commit"):
                    build_metadata.source_identity(self.root)
        self.diff.assert_not_called()

    def test_accepts_matching_workflow_commit(self):
        for variable in ("RELEASE_COMMIT", "GITHUB_SHA"):
            with self.subTest(variable=variable), patch.dict(os.environ, {variable: IDENTITY[0]}):
                self.assertEqual(build_metadata.source_identity(self.root)[:2], IDENTITY[:2])

    def test_rejects_uncommitted_source_changes(self):
        self.diff.side_effect = subprocess.CalledProcessError(1, "git diff")
        with self.assertRaises(subprocess.CalledProcessError):
            build_metadata.source_identity(self.root)

    def test_rejects_untracked_build_inputs(self):
        self.untracked = "src/extra.zig\n"
        with self.assertRaisesRegex(SystemExit, "Untracked build inputs"):
            build_metadata.source_identity(self.root)

    def test_rejects_invalid_commit_or_tree_identity(self):
        for values in (("not-a-commit", IDENTITY[1]), (IDENTITY[0], "not-a-tree")):
            with self.subTest(values=values):
                self.git.side_effect = values
                with self.assertRaisesRegex(SystemExit, "committed source tree"):
                    build_metadata.source_identity(self.root)
        self.diff.assert_not_called()


class NativeTargetTests(unittest.TestCase):
    def test_accepts_native_linux_and_windows_x86_64_aliases(self):
        for system in ("Linux", "Windows"):
            for machine in ("x86_64", "AMD64", "amd64"):
                with self.subTest(system=system, machine=machine), \
                     patch("build_metadata.platform.system", return_value=system), \
                     patch("build_metadata.platform.machine", return_value=machine):
                    self.assertEqual(build_metadata.native_target(), system.lower() + "-x86_64")

    def test_rejects_non_native_supported_release_targets(self):
        for system, machine in (("Darwin", "x86_64"), ("Linux", "aarch64"),
                                ("Windows", "ARM64"), ("Linux", "i686")):
            with self.subTest(system=system, machine=machine), \
                 patch("build_metadata.platform.system", return_value=system), \
                 patch("build_metadata.platform.machine", return_value=machine):
                with self.assertRaisesRegex(SystemExit, "natively on x86_64 Linux or Windows"):
                    build_metadata.native_target()


if __name__ == "__main__":
    unittest.main()
