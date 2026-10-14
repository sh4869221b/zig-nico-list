"""Offline regression checks for CI event/path routing and document validation."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_docs
import ci_changes


CHECKS = ("unit", "build", "format", "scripts", "docs")
BASE = "a" * 40
HEAD = "b" * 40


def selected(*enabled):
    return {check: check in enabled for check in CHECKS}


def push_event(base=BASE, head=HEAD, ref="refs/heads/main", **extra):
    return {"ref": ref, "before": base, "after": head, **extra}


def pull_request_event(base=BASE, head=HEAD, action="synchronize", target="main"):
    return {
        "action": action,
        "pull_request": {
            "base": {"ref": target, "sha": base},
            "head": {"sha": head},
        },
    }


class EventRoutingTests(unittest.TestCase):
    def test_main_branch_push_uses_diff(self):
        for extra in ({}, {"deleted": False}, {"created": True}):
            with self.subTest(extra=extra):
                event = push_event(**extra)
                self.assertEqual(ci_changes.event_mode("push", event), "diff")
                with patch.object(ci_changes, "changed_paths", return_value=["README.md"]) as diff:
                    self.assertEqual(ci_changes.plan_event("push", event), selected("docs"))
                diff.assert_called_once()

    def test_feature_branch_and_tag_pushes_do_not_run_checks(self):
        for ref in ("refs/heads/feature", "refs/heads/main-fix", "refs/tags/v0.01", "main", ""):
            with self.subTest(ref=ref), patch.object(ci_changes, "changed_paths") as diff:
                event = push_event(ref=ref)
                self.assertEqual(ci_changes.event_mode("push", event), "none")
                self.assertEqual(ci_changes.plan_event("push", event), selected())
                diff.assert_not_called()

    def test_deleted_main_branch_does_not_run_checks(self):
        with patch.object(ci_changes, "changed_paths") as diff:
            self.assertEqual(ci_changes.plan_event("push", push_event(deleted=True)), selected())
        diff.assert_not_called()

    def test_supported_pull_request_actions_targeting_main_use_diff(self):
        for action in ("opened", "synchronize", "reopened", "edited"):
            with self.subTest(action=action):
                event = pull_request_event(action=action)
                self.assertEqual(ci_changes.event_mode("pull_request", event), "diff")
                with patch.object(ci_changes, "changed_paths", return_value=["README.md"]) as diff:
                    self.assertEqual(ci_changes.plan_event("pull_request", event), selected("docs"))
                diff.assert_called_once()

    def test_other_pull_request_targets_and_actions_do_not_run_checks(self):
        events = [pull_request_event(target=target) for target in ("develop", "feature", "Main", "")]
        events += [pull_request_event(action=action) for action in
                   ("closed", "labeled", "unlabeled", "assigned", "ready_for_review", "")]
        events += [{}, {"action": "opened"}, {"action": "opened", "pull_request": {}}]
        for event in events:
            with self.subTest(event=event), patch.object(ci_changes, "changed_paths") as diff:
                self.assertEqual(ci_changes.event_mode("pull_request", event), "none")
                self.assertEqual(ci_changes.plan_event("pull_request", event), selected())
                diff.assert_not_called()

    def test_manual_dispatch_always_runs_every_check_without_diff(self):
        for event in ({}, {"ref": "refs/heads/feature"}, {"ref": "refs/tags/v0.01"}):
            with self.subTest(event=event), patch.object(ci_changes, "changed_paths") as diff:
                self.assertEqual(ci_changes.event_mode("workflow_dispatch", event), "full")
                self.assertEqual(ci_changes.plan_event("workflow_dispatch", event), selected(*CHECKS))
                diff.assert_not_called()

    def test_unconfigured_events_do_not_run_checks(self):
        for name in ("schedule", "release", "pull_request_target", "workflow_run", "unknown"):
            with self.subTest(name=name), patch.object(ci_changes, "changed_paths") as diff:
                self.assertEqual(ci_changes.plan_event(name, pull_request_event()), selected())
                diff.assert_not_called()


class PathClassificationTests(unittest.TestCase):
    def assert_paths_select(self, paths, *checks):
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(ci_changes.classify([path]), selected(*checks))

    def test_docs_only_paths(self):
        self.assert_paths_select(
            ("README.md", "AGENTS.md", "scripts/README.md", "docs/DESIGN.md",
             "docs/diagram.svg", "LICENSE", "LICENSE-ZIG.txt"), "docs")

    def test_source_paths(self):
        self.assert_paths_select(("src/main.zig", "src/nested/parser.zig", "src/data.json", "src/embedded.md"),
                                 "unit", "build", "format")

    def test_build_definitions(self):
        self.assert_paths_select(("build.zig", "build.zig.zon"), "unit", "build", "format", "scripts")

    def test_integration_only_paths(self):
        self.assert_paths_select(("tests/integration.py", "tests/fixtures/response.json", "tests/fixtures/input.md"),
                                 "build", "scripts")

    def test_zig_test_paths(self):
        self.assert_paths_select(("tests/helpers.zig",), "unit", "build", "format", "scripts")

    def test_python_only_check_helpers(self):
        self.assert_paths_select(("scripts/check_build.py", "scripts/test_ci.py", "scripts/test_release.py",
                                  "scripts/test_cached_build.py", "scripts/test_future.py"), "scripts")

    def test_packaging_and_build_helpers(self):
        self.assert_paths_select(("scripts/build_cached.py", "scripts/build_metadata.py",
                                  "scripts/package_release.py", "scripts/draft_release.py"), "build", "scripts")

    def test_toolchain_changes(self):
        self.assert_paths_select(("scripts/install_zig.py",), "unit", "build", "format", "scripts")

    def test_document_checker(self):
        self.assert_paths_select(("scripts/check_docs.py",), "scripts", "docs")

    def test_ci_and_repository_configuration_run_every_check(self):
        self.assert_paths_select((".github/workflows/ci.yml", ".github/workflows/release.yml",
                                  ".github/actions/setup/action.yml", ".github/README.md", ".gitattributes",
                                  ".gitignore", "scripts/ci_changes.py", "scripts/test_ci_changes.py",
                                  "scripts/test_workflows.py"), *CHECKS)

    def test_unknown_paths_run_every_check(self):
        self.assert_paths_select(("new-file.txt", "Makefile", "pyproject.toml", ".zig-version",
                                  "scripts/new_helper.py", "scripts/test_helper.sh", "vendor/library.zig"), *CHECKS)

    def test_combined_changes_union_the_required_checks(self):
        cases = [
            (["README.md", "docs/DESIGN.md"], ("docs",)),
            (["README.md", "src/main.zig"], ("unit", "build", "format", "docs")),
            (["README.md", "tests/integration.py"], ("build", "scripts", "docs")),
            (["src/main.zig", "scripts/test_release.py"], ("unit", "build", "format", "scripts")),
            (["docs/DESIGN.md", "build.zig"], CHECKS),
            (["README.md", "new-dependency.lock"], CHECKS),
            (["new-dependency.lock", "README.md"], CHECKS),
        ]
        for paths, checks in cases:
            with self.subTest(paths=paths):
                self.assertEqual(ci_changes.classify(paths), selected(*checks))
                self.assertEqual(ci_changes.classify(reversed(paths)), selected(*checks))

    def test_empty_diff_runs_no_checks(self):
        self.assertEqual(ci_changes.classify([]), selected())

    def test_plans_do_not_share_mutable_state(self):
        plan = ci_changes.full_plan()
        plan["build"] = False
        self.assertEqual(ci_changes.full_plan(), selected(*CHECKS))
        ci_changes.classify(["README.md"])["docs"] = False
        self.assertEqual(ci_changes.classify(["README.md"]), selected("docs"))


class TemporaryGitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "CI Test")
        self.git("config", "user.email", "ci-test@example.invalid")
        self.git("config", "core.autocrlf", "false")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def write(self, path, contents="fixture\n"):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")

    def commit(self, message="fixture"):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")


class GitDiffTests(TemporaryGitTests):
    def test_push_uses_the_complete_before_after_range(self):
        self.write("README.md", "base\n")
        base = self.commit()
        self.write("src/main.zig")
        self.commit("first pushed commit changes source")
        self.write("README.md", "last pushed commit only changes docs\n")
        head = self.commit("second pushed commit changes docs")
        event = push_event(base, head)
        self.assertCountEqual(ci_changes.changed_paths("push", event, self.root), ["src/main.zig", "README.md"])
        self.assertEqual(ci_changes.plan_event("push", event, self.root), selected("unit", "build", "format", "docs"))

    def test_pull_request_uses_merge_base_and_excludes_base_branch_only_changes(self):
        self.write("README.md", "common ancestor\n")
        self.commit()
        self.git("checkout", "--quiet", "-b", "feature")
        self.write("README.md", "feature documentation\n")
        feature = self.commit()
        self.git("checkout", "--quiet", "main")
        self.write("src/main.zig", "main-only source edit\n")
        main = self.commit()
        pr = pull_request_event(main, feature)
        self.assertEqual(ci_changes.changed_paths("pull_request", pr, self.root), ["README.md"])
        self.assertEqual(ci_changes.plan_event("pull_request", pr, self.root), selected("docs"))
        # The same endpoints on a push intentionally use two-dot/before-after semantics.
        self.assertCountEqual(ci_changes.changed_paths("push", push_event(main, feature), self.root),
                              ["README.md", "src/main.zig"])

    def test_rename_keeps_both_old_and_new_path_classifications(self):
        self.write("src/old.zig")
        base = self.commit()
        (self.root / "docs").mkdir()
        self.git("mv", "src/old.zig", "docs/new.md")
        head = self.commit()
        event = push_event(base, head)
        self.assertCountEqual(ci_changes.changed_paths("push", event, self.root), ["src/old.zig", "docs/new.md"])
        self.assertEqual(ci_changes.plan_event("push", event, self.root), selected("unit", "build", "format", "docs"))

    def test_rename_from_unknown_path_remains_conservative(self):
        self.write("unclassified.conf")
        base = self.commit()
        self.git("mv", "unclassified.conf", "README.md")
        head = self.commit()
        event = push_event(base, head)
        self.assertCountEqual(ci_changes.changed_paths("push", event, self.root), ["unclassified.conf", "README.md"])
        self.assertEqual(ci_changes.plan_event("push", event, self.root), selected(*CHECKS))

    def test_deletions_keep_original_path_classification(self):
        for path, checks in (("build.zig", ("unit", "build", "format", "scripts")),
                             ("LICENSE", ("docs",)), ("unknown.conf", CHECKS)):
            with self.subTest(path=path):
                self.write(path)
                base = self.commit()
                (self.root / path).unlink()
                head = self.commit()
                event = push_event(base, head)
                self.assertEqual(ci_changes.changed_paths("push", event, self.root), [path])
                self.assertEqual(ci_changes.plan_event("push", event, self.root), selected(*checks))

    def test_more_than_3000_changed_files_are_not_truncated(self):
        base = self.commit()
        documents = [f"docs/page-{index:04d}.md" for index in range(3050)]
        for path in documents:
            self.write(path)
        docs_head = self.commit()
        self.assertCountEqual(ci_changes.changed_paths("push", push_event(base, docs_head), self.root), documents)
        self.assertEqual(ci_changes.plan_event("push", push_event(base, docs_head), self.root), selected("docs"))
        # This sorts after all 3,050 docs and must still enable the native checks.
        self.write("src/z-last.zig")
        head = self.commit()
        event = push_event(base, head)
        self.assertCountEqual(ci_changes.changed_paths("push", event, self.root), documents + ["src/z-last.zig"])
        self.assertEqual(ci_changes.plan_event("push", event, self.root), selected("unit", "build", "format", "docs"))

    def test_spaces_and_unicode_in_tracked_paths(self):
        base = self.commit()
        paths = ["docs/a guide.md", "docs/日本語.md"]
        for path in paths:
            self.write(path)
        head = self.commit()
        self.assertCountEqual(ci_changes.changed_paths("push", push_event(base, head), self.root), paths)

    def test_unchanged_commits_produce_an_empty_plan(self):
        commit = self.commit()
        self.assertEqual(ci_changes.plan_event("push", push_event(commit, commit), self.root), selected())


class DiffFailureTests(unittest.TestCase):
    def assert_falls_back(self, name, event, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ci_changes.plan_event(name, event, **kwargs), selected(*CHECKS))

    def test_missing_push_endpoints_run_every_check_without_git(self):
        for missing in ("before", "after"):
            event = push_event()
            del event[missing]
            with self.subTest(missing=missing), patch.object(ci_changes.subprocess, "check_output") as git:
                self.assert_falls_back("push", event)
                git.assert_not_called()

    def test_missing_pull_request_endpoints_run_every_check_without_git(self):
        for side in ("base", "head"):
            event = pull_request_event()
            del event["pull_request"][side]["sha"]
            with self.subTest(side=side), patch.object(ci_changes.subprocess, "check_output") as git:
                self.assert_falls_back("pull_request", event)
                git.assert_not_called()

    def test_zero_empty_and_invalid_endpoints_run_every_check_without_git(self):
        for invalid in ("0" * 40, "", "a" * 39, "a" * 41, "g" * 40, "-" * 40):
            for side in ("base", "head"):
                endpoints = {"base": BASE, "head": HEAD, side: invalid}
                for name, event in (("push", push_event(**endpoints)),
                                    ("pull_request", pull_request_event(**endpoints))):
                    with self.subTest(name=name, invalid=invalid, side=side), \
                         patch.object(ci_changes.subprocess, "check_output") as git:
                        self.assert_falls_back(name, event)
                        git.assert_not_called()

    def test_null_or_non_string_endpoints_run_every_check_without_git(self):
        for invalid in (None, 123, [], {}):
            for side in ("base", "head"):
                endpoints = {"base": BASE, "head": HEAD, side: invalid}
                for name, event in (("push", push_event(**endpoints)),
                                    ("pull_request", pull_request_event(**endpoints))):
                    with self.subTest(name=name, invalid=invalid, side=side), \
                         patch.object(ci_changes.subprocess, "check_output") as git:
                        self.assert_falls_back(name, event)
                        git.assert_not_called()

    def test_unavailable_git_or_missing_objects_run_every_check(self):
        failures = (OSError("git unavailable"), FileNotFoundError("missing checkout"),
                    subprocess.CalledProcessError(128, ["git", "diff"]))
        for error in failures:
            for name, event in (("push", push_event()), ("pull_request", pull_request_event())):
                with self.subTest(error=error, name=name), \
                     patch.object(ci_changes.subprocess, "check_output", side_effect=error):
                    self.assert_falls_back(name, event)

    def test_pull_request_diff_failure_after_successful_merge_base_runs_every_check(self):
        with patch.object(ci_changes.subprocess, "check_output", side_effect=[
                "c" * 40 + "\n", subprocess.CalledProcessError(128, ["git", "diff"])]) as git:
            self.assert_falls_back("pull_request", pull_request_event())
        self.assertEqual(git.call_count, 2)

    def test_non_utf8_diff_paths_run_every_check(self):
        with patch.object(ci_changes.subprocess, "check_output", return_value=b"docs/invalid-\xff.md\0"):
            self.assert_falls_back("push", push_event())

    def test_diff_uses_nul_delimiters_and_disables_rename_detection(self):
        root = Path("fixture-root")
        with patch.object(ci_changes.subprocess, "check_output", return_value=b"docs/line\nbreak.md\0README.md\0") as git:
            self.assertEqual(ci_changes.changed_paths("push", push_event(), root), ["docs/line\nbreak.md", "README.md"])
        git.assert_called_once_with(
            ["git", "diff", "--name-only", "-z", "--no-renames", BASE, HEAD, "--"], cwd=root)


class PlanOutputTests(unittest.TestCase):
    def test_main_appends_lowercase_job_outputs_and_aggregate_flags(self):
        cases = (([], False, False), (["README.md"], False, True),
                 (["src/main.zig"], True, True), (["scripts/test_ci.py"], False, True))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event_file = root / "event.json"
            output_file = root / "outputs.txt"
            event_file.write_text(json.dumps(push_event()), encoding="utf-8")
            for paths, native, quality in cases:
                with self.subTest(paths=paths):
                    output_file.write_text("existing=value\n", encoding="utf-8")
                    with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event_file),
                                                 "GITHUB_EVENT_NAME": "push", "GITHUB_OUTPUT": str(output_file)}), \
                         patch.object(ci_changes, "changed_paths", return_value=paths), \
                         contextlib.redirect_stdout(io.StringIO()) as stdout:
                        ci_changes.main()
                    expected = ci_changes.classify(paths)
                    self.assertEqual(json.loads(stdout.getvalue()), expected)
                    outputs = dict(line.split("=", 1) for line in output_file.read_text(encoding="utf-8").splitlines())
                    self.assertEqual(outputs, {"existing": "value", **{key: str(value).lower() for key, value in expected.items()},
                                               "native": str(native).lower(), "quality": str(quality).lower()})

    def test_main_fallback_preserves_machine_readable_stdout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event_file = root / "event.json"
            output_file = root / "outputs.txt"
            event_file.write_text(json.dumps({"ref": "refs/heads/main"}), encoding="utf-8")
            with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event_file),
                                         "GITHUB_EVENT_NAME": "push", "GITHUB_OUTPUT": str(output_file)}), \
                 contextlib.redirect_stdout(io.StringIO()) as stdout, \
                 contextlib.redirect_stderr(io.StringIO()) as stderr:
                ci_changes.main()
            self.assertEqual(json.loads(stdout.getvalue()), selected(*CHECKS))
            self.assertIn("Diff unavailable", stderr.getvalue())
            outputs = dict(line.split("=", 1) for line in output_file.read_text(encoding="utf-8").splitlines())
            self.assertEqual(outputs, {check: "true" for check in (*CHECKS, "native", "quality")})


class DocumentCheckTests(TemporaryGitTests):
    def setUp(self):
        super().setUp()
        for name in check_docs.REQUIRED:
            self.write(name, f"Package document: {name}\n")
        self.git("add", "--all")

    def test_valid_required_and_ordinary_utf8_documents(self):
        for name in ("docs/guide.md", "docs/日本語.md", "scripts/README.md"):
            self.write(name, "Ordinary UTF-8 text: 日本語 café\n")
        self.git("add", "--all")
        self.assertEqual(check_docs.check_documents(self.root), 6)

    def test_required_documents_are_checked_even_when_not_tracked(self):
        self.git("rm", "--cached", "--quiet", "README.md", "LICENSE", "LICENSE-ZIG.txt")
        self.assertEqual(check_docs.check_documents(self.root), 3)
        (self.root / "LICENSE").unlink()
        with self.assertRaises(FileNotFoundError):
            check_docs.check_documents(self.root)

    def test_missing_required_documents_fail(self):
        for name in check_docs.REQUIRED:
            with self.subTest(name=name):
                target = self.root / name
                contents = target.read_bytes()
                target.unlink()
                try:
                    with self.assertRaises(FileNotFoundError):
                        check_docs.check_documents(self.root)
                finally:
                    target.write_bytes(contents)

    def test_empty_or_whitespace_only_required_documents_fail(self):
        for name in check_docs.REQUIRED:
            for contents in ("", " \n\t\r\n"):
                with self.subTest(name=name, contents=contents):
                    self.write(name, contents)
                    try:
                        with self.assertRaisesRegex(SystemExit, "Required package document is empty"):
                            check_docs.check_documents(self.root)
                    finally:
                        self.write(name)

    def test_nul_bytes_in_required_or_ordinary_documents_fail(self):
        for name in (*check_docs.REQUIRED, "docs/ordinary.md"):
            with self.subTest(name=name):
                self.write(name, "text\0text\n")
                self.git("add", "--all")
                try:
                    with self.assertRaisesRegex(SystemExit, "NUL byte in document"):
                        check_docs.check_documents(self.root)
                finally:
                    self.write(name)

    def test_invalid_utf8_in_required_or_ordinary_documents_fails(self):
        for name in (*check_docs.REQUIRED, "docs/ordinary.md"):
            with self.subTest(name=name):
                self.write(name)
                (self.root / name).write_bytes(b"invalid utf-8: \xff\xfe\n")
                self.git("add", "--all")
                try:
                    with self.assertRaises(UnicodeDecodeError):
                        check_docs.check_documents(self.root)
                finally:
                    self.write(name)

    def test_empty_ordinary_document_is_allowed(self):
        self.write("docs/empty.md", "")
        self.git("add", "--all")
        self.assertEqual(check_docs.check_documents(self.root), 4)

    def test_missing_tracked_ordinary_document_fails(self):
        self.write("docs/missing.md")
        self.git("add", "--all")
        (self.root / "docs/missing.md").unlink()
        with self.assertRaises(FileNotFoundError):
            check_docs.check_documents(self.root)

    def test_untracked_ordinary_documents_and_non_documents_are_ignored(self):
        self.write("docs/untracked.md", "invalid\0document")
        self.write("src/fixture.bin")
        (self.root / "src/fixture.bin").write_bytes(b"\xff\0")
        self.git("add", "src/fixture.bin")
        self.assertEqual(check_docs.check_documents(self.root), 3)

    def test_git_failure_is_not_reported_as_document_success(self):
        with patch.object(check_docs.subprocess, "check_output", side_effect=subprocess.CalledProcessError(128, "git")):
            with self.assertRaises(subprocess.CalledProcessError):
                check_docs.check_documents(self.root)


if __name__ == "__main__":
    unittest.main()
