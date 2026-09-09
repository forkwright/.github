#!/usr/bin/env python3
"""Validate hybrid-gate's mutually exclusive system-package installation paths.

WHY: actionlint validates workflow syntax but cannot prove the default runner
APT path and the explicitly opted-in isolated Ubuntu installer remain exact
complements. This reads effective YAML rather than source substrings, so
comments and unrelated text cannot satisfy the contract.
"""

from __future__ import annotations

import copy
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import yaml

DEFAULT_CONDITION = "inputs.system_packages != '' && !inputs.system_packages_ubuntu_only"
OPT_IN_CONDITION = "inputs.system_packages != '' && inputs.system_packages_ubuntu_only"
DEFAULT_APT_BODY = (
    "sudo apt-get update\n"
    "sudo apt-get install --yes --no-install-recommends ${{ inputs.system_packages }}\n"
)
INSTALLER_PATTERN = re.compile(
    r"forkwright/\.github/\.github/actions/install-ubuntu-packages@[0-9a-f]{40}\Z"
)


def workflow_call(document: dict[str, Any]) -> dict[str, Any]:
    """Return the reusable-workflow declaration despite PyYAML's `on` quirk."""
    on = document.get(True, document.get("on"))
    if not isinstance(on, dict):
        return {}
    call = on.get("workflow_call")
    return call if isinstance(call, dict) else {}


def named_step(document: dict[str, Any], name: str) -> dict[str, Any] | None:
    jobs = document.get("jobs")
    if not isinstance(jobs, dict):
        return None
    full_gate = jobs.get("full-gate-build")
    if not isinstance(full_gate, dict):
        return None
    steps = full_gate.get("steps")
    if not isinstance(steps, list):
        return None
    matches = [step for step in steps if isinstance(step, dict) and step.get("name") == name]
    return matches[0] if len(matches) == 1 else None


def validate(document: dict[str, Any]) -> list[str]:
    """Return every violated opt-in contract rather than stopping at one."""
    failures: list[str] = []
    inputs = workflow_call(document).get("inputs")
    input_spec = inputs.get("system_packages_ubuntu_only") if isinstance(inputs, dict) else None
    expected_spec = {"type": "boolean", "required": False, "default": False}
    if not isinstance(input_spec, dict):
        failures.append("missing system_packages_ubuntu_only workflow_call input")
    else:
        for field, expected in expected_spec.items():
            if input_spec.get(field) != expected:
                failures.append(
                    f"system_packages_ubuntu_only.{field} is {input_spec.get(field)!r}, "
                    f"expected {expected!r}"
                )

    default_step = named_step(document, "Install system dependencies")
    if default_step is None:
        failures.append("missing unique default system-package step")
    else:
        if default_step.get("if") != DEFAULT_CONDITION:
            failures.append("default system-package condition is not the exact non-opt-in condition")
        if default_step.get("run") != DEFAULT_APT_BODY:
            failures.append("default system-package APT body changed")
        if "uses" in default_step:
            failures.append("default system-package step must run the existing APT body, not an action")
        if "with" in default_step:
            failures.append("default system-package run step must not declare action inputs")

    opt_in_step = named_step(document, "Install Ubuntu-only system dependencies")
    if opt_in_step is None:
        failures.append("missing unique Ubuntu-only system-package step")
    else:
        if opt_in_step.get("if") != OPT_IN_CONDITION:
            failures.append("Ubuntu-only system-package condition is not the exact opt-in condition")
        uses = opt_in_step.get("uses")
        if not isinstance(uses, str) or not INSTALLER_PATTERN.fullmatch(uses):
            failures.append("Ubuntu-only system-package action is not pinned to a full immutable installer SHA")
        if opt_in_step.get("with") != {"packages": "${{ inputs.system_packages }}"}:
            failures.append("Ubuntu-only system-package action does not forward only system_packages")
        if "run" in opt_in_step:
            failures.append("Ubuntu-only system-package step must use the installer action, not a run body")

    return failures


def assert_negative_cases(document: dict[str, Any]) -> list[str]:
    """Ensure representative bad edits cannot accidentally satisfy validation."""
    failures: list[str] = []
    mutations: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        (
            "default true",
            lambda item: workflow_call(item)["inputs"]["system_packages_ubuntu_only"].update(
                default=True
            ),
        ),
        (
            "identical conditions",
            lambda item: named_step(item, "Install Ubuntu-only system dependencies").update(
                **{"if": DEFAULT_CONDITION}
            ),
        ),
        (
            "extra default command",
            lambda item: named_step(item, "Install system dependencies").update(
                run=f"{DEFAULT_APT_BODY}echo unexpected\n"
            ),
        ),
        (
            "mutable installer ref",
            lambda item: named_step(item, "Install Ubuntu-only system dependencies").update(
                uses="forkwright/.github/.github/actions/install-ubuntu-packages@main"
            ),
        ),
        (
            "wrong package input",
            lambda item: named_step(item, "Install Ubuntu-only system dependencies").update(
                **{"with": {"packages": "sl"}}
            ),
        ),
    ]
    for label, mutate in mutations:
        mutated = copy.deepcopy(document)
        mutate(mutated)
        if not validate(mutated):
            failures.append(f"negative mutation passed validation: {label}")
    return failures


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) == 2 else ".github/workflows/hybrid-gate.yml")
    try:
        document = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as error:
        print(f"FAIL: cannot load {path}: {error}", file=sys.stderr)
        return 1
    if not isinstance(document, dict):
        print(f"FAIL: {path} is not a YAML mapping", file=sys.stderr)
        return 1

    failures = validate(document)
    failures.extend(assert_negative_cases(document))
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
