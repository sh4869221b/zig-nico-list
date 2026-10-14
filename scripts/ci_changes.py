#!/usr/bin/env python3
"""Select CI jobs from complete Git diffs; unknown inputs conservatively run all."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CHECKS = ("unit", "build", "format", "scripts", "docs")
PR_ACTIONS = {"opened", "synchronize", "reopened", "edited"}


def full_plan():
    return dict.fromkeys(CHECKS, True)


def event_mode(name, event):
    """Mirror ci.yml triggers for offline positive/negative trigger tests."""
    if name == "workflow_dispatch":
        return "full"
    if name == "push" and event.get("ref") == "refs/heads/main" and not event.get("deleted", False):
        return "diff"
    if (name == "pull_request" and event.get("action") in PR_ACTIONS
            and event.get("pull_request", {}).get("base", {}).get("ref") == "main"):
        return "diff"
    return "none"


def classify(paths):
    selected = dict.fromkeys(CHECKS, False)
    for path in paths:
        if (path.startswith(".github/") or path in {".gitattributes", ".gitignore", "scripts/ci_changes.py"}
                or path in {"scripts/test_ci_changes.py", "scripts/test_workflows.py"}):
            return full_plan()
        if path in {"build.zig", "build.zig.zon"} or path.startswith("src/"):
            for check in ("unit", "build", "format"):
                selected[check] = True
            if path.startswith("build.zig"):
                selected["scripts"] = True
        elif path.startswith("tests/"):
            selected["build"] = selected["scripts"] = True
            if path.endswith(".zig"):
                selected["unit"] = selected["format"] = True
        elif path.endswith(".md") or path.startswith("docs/") or path in {"LICENSE", "LICENSE-ZIG.txt"}:
            selected["docs"] = True
        elif path == "scripts/install_zig.py":
            for check in ("unit", "build", "format", "scripts"):
                selected[check] = True
        elif path in {"scripts/build_cached.py", "scripts/build_metadata.py", "scripts/package_release.py",
                      "scripts/draft_release.py"}:
            selected["build"] = selected["scripts"] = True
        elif path == "scripts/check_docs.py":
            selected["docs"] = selected["scripts"] = True
        elif path == "scripts/check_build.py" or (path.startswith("scripts/test_") and path.endswith(".py")):
            selected["scripts"] = True
        else:
            # New dependencies/configuration must never silently miss native CI.
            return full_plan()
    return selected


def changed_paths(name, event, root=ROOT):
    if name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
    else:
        base, head = event["before"], event["after"]
    if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) and sha != "0" * 40
               for sha in (base, head)):
        raise ValueError("Missing or invalid diff endpoints")
    if name == "pull_request":
        base = subprocess.check_output(["git", "merge-base", base, head], cwd=root, text=True).strip()
    # --no-renames exposes BOTH old and new paths. -z handles spaces/newlines.
    data = subprocess.check_output(["git", "diff", "--name-only", "-z", "--no-renames", base, head, "--"], cwd=root)
    return [path.decode("utf-8") for path in data.split(b"\0") if path]


def plan_event(name, event, root=ROOT):
    mode = event_mode(name, event)
    if mode == "none":
        return dict.fromkeys(CHECKS, False)
    if mode == "full":
        return full_plan()
    try:
        return classify(changed_paths(name, event, root))
    except (KeyError, ValueError, UnicodeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Diff unavailable ({type(error).__name__}); running all checks", file=sys.stderr)
        return full_plan()


def main():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        event = json.load(stream)
    plan = plan_event(os.environ["GITHUB_EVENT_NAME"], event)
    print(json.dumps(plan, sort_keys=True))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for check, enabled in plan.items():
            output.write(f"{check}={str(enabled).lower()}\n")
        output.write(f"native={str(plan['unit'] or plan['build']).lower()}\n")
        output.write(f"quality={str(plan['format'] or plan['scripts'] or plan['docs']).lower()}\n")


if __name__ == "__main__":
    main()
