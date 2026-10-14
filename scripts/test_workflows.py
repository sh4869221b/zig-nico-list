"""Structural invariants for the checked-in, deliberately simple CI YAML."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github/workflows"


class WorkflowWiringTests(unittest.TestCase):
    def read(self, name):
        return (WORKFLOWS / name).read_text(encoding="utf-8")

    def test_normal_triggers_and_gate_never_use_workflow_path_filters(self):
        text = self.read("ci.yml")
        self.assertEqual(text.count("branches: [main]"), 2)
        self.assertIn("types: [opened, synchronize, reopened, edited]", text)
        self.assertIn("  workflow_dispatch:", text)
        self.assertNotRegex(text, r"(?m)^\s+(?:paths|paths-ignore|tags|schedule):")
        self.assertIn("    name: CI\n    if: always()\n    needs: [changes, quality, native]", text)
        self.assertIn("fetch-depth: 0", text)

    def test_aggregate_gate_rejects_failures_cancellations_and_unexpected_skips(self):
        text = self.read("ci.yml")
        code = text.split("      - name: Require every selected check to succeed", 1)[1].split("        run: |\n", 1)[1]
        code = "\n".join(line[10:] for line in code.splitlines())
        from unittest.mock import patch
        good = {"PLAN_RESULT": "success", "QUALITY_REQUIRED": "true", "QUALITY_RESULT": "success",
                "NATIVE_REQUIRED": "false", "NATIVE_RESULT": "skipped"}
        with patch.dict("os.environ", good, clear=True):
            exec(code, {})
        for key, value in (("PLAN_RESULT", "failure"), ("PLAN_RESULT", "cancelled"),
                           ("QUALITY_RESULT", "failure"), ("QUALITY_RESULT", "cancelled"),
                           ("QUALITY_RESULT", "skipped"), ("NATIVE_RESULT", "failure"),
                           ("NATIVE_REQUIRED", ""), ("NATIVE_REQUIRED", "true")):
            with self.subTest(key=key, value=value), patch.dict("os.environ", {**good, key: value}, clear=True):
                with self.assertRaises(SystemExit):
                    exec(code, {})

    def test_release_forces_all_checks_before_existing_draft_gate(self):
        text = self.read("release.yml")
        self.assertIn("tags: ['v[0-9]*']", text)
        self.assertNotIn("pull_request", text)
        self.assertIn("needs: [quality, native]", text)
        for flag in ("format", "scripts", "docs", "unit", "build", "package"):
            self.assertIn(f"      {flag}: true", text)
        self.assertIn("if: github.repository == 'sh4869221b/zig-nico-list'", text)

    def test_reusable_workflows_have_no_independent_events(self):
        for name in ("checks.yml", "native.yml"):
            text = self.read(name)
            self.assertIn("  workflow_call:", text)
            self.assertNotRegex(text, r"(?m)^  (push|pull_request|workflow_dispatch|schedule):")
        native = self.read("native.yml")
        self.assertIn("if: inputs.unit", native)
        self.assertIn("if: inputs.build", native)
        self.assertNotIn("zig fmt", native)
        self.assertNotIn("unittest discover", native)
        self.assertIn("python scripts/build_cached.py", native)
        self.assertIn("python tests/integration.py", native)

    def test_cold_is_manual_only_and_not_a_normal_dependency(self):
        cold = self.read("reproducibility.yml")
        self.assertIn("  workflow_dispatch:", cold)
        self.assertNotRegex(cold, r"(?m)^  (push|pull_request|workflow_call|schedule):")
        self.assertIn("python scripts/check_build.py", cold)
        for name in ("ci.yml", "native.yml", "release.yml"):
            self.assertNotIn("reproducibility.yml", self.read(name))
            self.assertNotIn("python scripts/check_build.py", self.read(name))

    def test_permissions_cache_writes_and_concurrency_remain_bounded(self):
        for file in WORKFLOWS.glob("*.yml"):
            text = file.read_text(encoding="utf-8")
            self.assertNotIn("pull_request_target", re.sub(r"(?m)^\s*#.*$", "", text))
            self.assertNotIn("secrets: inherit", text)
            self.assertNotRegex(text, r"(?m)^\s+schedule:")
            self.assertIn("permissions:\n  contents: read", text)
            self.assertEqual(text.count("contents: write"), 1 if file.name == "release.yml" else 0)
            self.assertEqual(text.count("uses: actions/checkout@"), text.count("persist-credentials: false"))
        native = self.read("native.yml")
        self.assertEqual(native.count("uses: actions/cache/save@"), 3)
        self.assertEqual(native.count("if: github.event_name == 'push' && github.ref == 'refs/heads/main'"), 3)
        for name in ("checks.yml", "reproducibility.yml"):
            self.assertNotIn("actions/cache/save@", self.read(name))
        self.assertIn("group: test-", self.read("ci.yml"))
        self.assertIn("group: release-", self.read("release.yml"))
        self.assertIn("group: cold-reproducibility-", self.read("reproducibility.yml"))
