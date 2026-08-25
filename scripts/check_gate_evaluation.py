#!/usr/bin/env python3
"""Execute hybrid-gate's `gate` verdict script against a fixed event matrix.

WHY this exists as a script rather than a review checklist: the verdict is a
shell ladder of early exits, and which arm fires depends on `github.event_name`
— a value actionlint type-checks but never evaluates. The failure it guards is
silent by construction: the gate reports success, so nothing downstream has a
red result to point at. Only running the ladder distinguishes the two shapes.

WHY it runs the text out of the workflow instead of a copy: a copy drifts, and
a drifted copy passing is worse than no check at all.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

# (trailer_found, docs_only, build_result, attribution_result, event_name),
# expected exit status, description.
#
# WHY the pull_request rows are here even though none of them exercise the
# event guard: they are what makes a regression legible. Tightening the push
# path is only correct if the pre-merge path is untouched, and these rows fail
# if a future edit tightens both.
CASES: list[tuple[tuple[str, str, str, str, str], int, str]] = [
    (("true", "false", "skipped", "success", "pull_request"), 0,
     "pull_request, tip stamped: passes without a build"),
    (("false", "false", "success", "success", "pull_request"), 0,
     "pull_request, no trailer, build green: passes"),
    (("false", "false", "failure", "success", "pull_request"), 1,
     "pull_request, no trailer, build red: fails"),
    (("false", "true", "skipped", "success", "pull_request"), 0,
     "pull_request, docs-only: exempt"),
    (("true", "false", "skipped", "failure", "pull_request"), 1,
     "pull_request, attribution red: fails even when stamped"),
    (("true", "false", "success", "success", "push"), 0,
     "push, tip stamped, build green: passes"),
    (("true", "false", "failure", "success", "push"), 1,
     "push, tip stamped, build RED: must fail"),
    (("true", "false", "skipped", "success", "push"), 1,
     "push, tip stamped, build SKIPPED: must fail"),
    (("false", "false", "failure", "success", "push"), 1,
     "push, no trailer, build red: fails"),
    (("false", "true", "skipped", "success", "push"), 0,
     "push, docs-only: exempt"),
]

KEYS = ("TRAILER_FOUND", "DOCS_ONLY", "BUILD_RESULT", "ATTRIBUTION_RESULT",
        "EVENT_NAME")


def verdict_script(workflow: Path) -> str:
    doc = yaml.safe_load(workflow.read_text())
    steps = doc["jobs"]["gate"]["steps"]
    for step in steps:
        if step.get("name") == "Evaluate gate result":
            return step["run"]
    raise SystemExit(
        f"{workflow}: no 'Evaluate gate result' step in the gate job. "
        "The step was renamed or removed; update this check to match."
    )


def main() -> int:
    workflow = Path(sys.argv[1] if len(sys.argv) > 1
                    else ".github/workflows/hybrid-gate.yml")
    script = verdict_script(workflow)

    failures = 0
    for values, expected, description in CASES:
        env = dict(zip(KEYS, values))
        env["PATH"] = "/usr/bin:/bin"
        result = subprocess.run(["bash", "-c", script], env=env,
                                capture_output=True, text=True, check=False)
        if result.returncode == expected:
            print(f"ok    {description}")
            continue
        failures += 1
        print(f"FAIL  {description}")
        print(f"        expected exit {expected}, got {result.returncode}")
        print(f"        env: {env}")
        for line in (result.stdout + result.stderr).splitlines():
            print(f"        | {line}")

    print(f"\n{len(CASES) - failures}/{len(CASES)} cases behaved as specified.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
