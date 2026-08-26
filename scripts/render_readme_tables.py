#!/usr/bin/env python3
"""Derive README.md's pinned-action, reusable-input, and fleet-rollout tables
from the tree and (best-effort) the live org, and print them for splicing in.

WHY this exists: those three tables were hand-typed and drifted from the
workflows they describe -- a nonexistent gate-attestation `runner` input, four
of six pins on a stale version, and a rollout list that named 12 repos while
more than twice that many had already converted with no entry at all (#19).
A doc a human retypes on every change is a second copy of the workflow files
themselves, free to diverge invisibly; this reads the workflows instead.

WHY the fleet-rollout table is best-effort: it goes through GitHub code
search, which needs network + `gh` auth and does not claim completeness (a
repo whose search index entry is stale reports as unconverted). Treat its
absence as "unknown", never as "not converted" -- an empty or failed query
prints a warning and omits the table rather than rendering a false negative.

Usage: python3 scripts/render_readme_tables.py
Prints each table to stdout under a heading matching its README section;
splice the output in by hand. This is a derivation tool, not a writer -- it
never touches README.md itself, so a change here cannot silently rewrite docs
nobody reviewed.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = ROOT / ".github" / "workflows"

# WHY True, not "on": PyYAML's safe_load resolves the bare scalar key `on:`
# to the boolean True per the YAML 1.1 core schema -- this is a parser
# quirk, not a typo. Reading doc["on"] finds nothing and reports "no
# workflow_call inputs" for every file, which is silently wrong rather than
# an error.
_ON_KEY = True


def load_on_block(path: Path) -> dict:
    doc = yaml.safe_load(path.read_text())
    on = doc.get(_ON_KEY, doc.get("on"))
    return on if isinstance(on, dict) else {}


def pinned_actions() -> dict[str, tuple[str, str]]:
    """Third-party action -> (version comment, sha), asserting fleet-wide
    consistency. Excludes this repo's own reusable workflows calling each
    other (e.g. hybrid-gate.yml -> docs-only.yml) -- that is internal
    wiring, pinned for the same reproducibility reason, but it is not a
    dependency a fleet consumer needs to know about.
    """
    pattern = re.compile(r"uses:\s*([\w./-]+)@([0-9a-f]{40})\s*#\s*(\S+)")
    seen: dict[str, tuple[str, str]] = {}
    conflicts: list[tuple[str, tuple[str, str], tuple[str, str], Path]] = []
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        for line in path.read_text().splitlines():
            m = pattern.search(line)
            if not m:
                continue
            action, sha, version = m.groups()
            if action.startswith("forkwright/.github/"):
                continue
            pin = (version, sha)
            if action in seen and seen[action] != pin:
                conflicts.append((action, seen[action], pin, path))
            seen[action] = pin
    for action, old, new, path in conflicts:
        print(
            f"WARNING: {action} pinned inconsistently ({old} vs {new} in {path})",
            file=sys.stderr,
        )
    return seen


def reusable_workflows() -> dict[str, dict]:
    """filename -> workflow_call block, for every file that declares one.

    A file with no `workflow_call` key (actionlint.yml, which triggers on
    `pull_request` and lints THIS repo's own workflows) is not a fleet
    reusable and is excluded here by construction, not by a maintained list.
    """
    out: dict[str, dict] = {}
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        on = load_on_block(path)
        if "workflow_call" in on:
            out[path.name] = on["workflow_call"] or {}
    return out


def render_pin_table(pins: dict[str, tuple[str, str]]) -> str:
    lines = ["| Action | Version | SHA |", "|--------|---------|-----|"]
    for action in sorted(pins):
        version, sha = pins[action]
        lines.append(f"| {action} | {version} | `{sha}` |")
    return "\n".join(lines)


def render_inputs_table(reusables: dict[str, dict]) -> str:
    lines = ["| Workflow | Input | Default | Notes |", "|----------|-------|---------|-------|"]
    for name in sorted(reusables):
        call = reusables[name]
        wf = name.removesuffix(".yml")
        inputs = call.get("inputs") or {}
        if not inputs:
            lines.append(f"| {wf} | *(none)* | | |")
            continue
        for iname in sorted(inputs):
            spec = inputs[iname] or {}
            default = spec.get("default", "")
            # WHY lower(): YAML's true/false round-trip through PyYAML as
            # Python's True/False -- a reader of this table expects the YAML
            # spelling, not the Python one.
            if isinstance(default, bool):
                default = str(default).lower()
            desc = (spec.get("description") or "").strip().split("\n")[0]
            lines.append(f"| {wf} | `{iname}` | `{default}` | {desc} |")
    return "\n".join(lines)


def fleet_consumers() -> dict[str, set[str]] | None:
    """workflow filename -> consuming repo full_names, via GitHub code search.

    Returns None (not {}) on any query failure, so the caller can tell
    "queried and found nothing" apart from "could not query" -- the two read
    identically as an empty table otherwise, and the second must never
    render as a rollout claim.
    """
    try:
        result = subprocess.run(
            [
                "gh", "api", "-X", "GET", "search/code", "--paginate",
                # WHY one token, not two: `--raw-field` (`-F`) takes a single
                # `key=value` argument. Passing "q" and the value as separate
                # argv elements is silently accepted by no gh subcommand --
                # it surfaces as "accepts 1 arg(s), received 2" pointing at
                # the *search endpoint*, which reads as a query-syntax
                # problem rather than an argv-shape one.
                "--raw-field",
                '''q="forkwright/.github/.github/workflows" org:forkwright''',
                "--jq", r'.items[] | "\(.repository.full_name)\t\(.path)"',
            ],
            capture_output=True, text=True, check=True, timeout=60,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as exc:
        print(f"WARNING: fleet rollout query failed ({exc}); omitting rollout table", file=sys.stderr)
        return None

    consumers: dict[str, set[str]] = {}
    for line in result.stdout.splitlines():
        if "\t" not in line:
            continue
        repo, path = line.split("\t", 1)
        if repo == "forkwright/.github":
            continue
        # WHY this filter: kanon's ci-substrate carries the SAME reusable
        # pin string inside its own `.j2` templates (the source these
        # workflows get generated FROM for other repos) and in prose docs
        # describing the pattern. Neither is kanon's OWN repo consuming a
        # reusable -- only a hit under its actual `.github/workflows/`
        # means the repo calls it.
        if not path.startswith(".github/workflows/"):
            continue
        consumers.setdefault(Path(path).name, set()).add(repo)
    return consumers


def render_rollout_table(consumers: dict[str, set[str]], reusables: dict[str, dict]) -> str:
    all_repos = sorted({repo for repos in consumers.values() for repo in repos})
    lines = ["| Repo | Reusables consumed |", "|------|---------------------|"]
    for repo in all_repos:
        used = sorted(
            name.removesuffix(".yml") for name in reusables if repo in consumers.get(name, set())
        )
        if not used:
            continue
        lines.append(f"| {repo} | {', '.join(used)} |")
    return "\n".join(lines)


def main() -> int:
    pins = pinned_actions()
    reusables = reusable_workflows()

    print("## Pinned action versions\n")
    print(render_pin_table(pins))

    print("\n## Workflow inputs\n")
    print(render_inputs_table(reusables))

    consumers = fleet_consumers()
    print("\n## Fleet rollout (code-search snapshot; re-run to refresh)\n")
    if consumers is None:
        print("(query failed -- see stderr; leaving the README section untouched)")
    elif not consumers:
        print("(query returned no consumers -- see stderr before trusting this as ground truth)")
    else:
        print(render_rollout_table(consumers, reusables))

    return 0


if __name__ == "__main__":
    sys.exit(main())
