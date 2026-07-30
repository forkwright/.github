#!/usr/bin/env python3
"""Guard: a pull_request-only value must not reach `git` unguarded.

WHY: `github.event.pull_request.*`, `github.head_ref` and `github.base_ref` are
populated for `pull_request` events only. On a `push` they interpolate to the
empty string. Passing an empty string where git expects a revision aborts the
command with `fatal: ambiguous argument ''`, which takes the step, the job and
the required check with it -- so a workflow that is fine on every PR fails on
every push to the default branch.

That failure has shipped from this repo twice. The `docs-only` and
`ai-attribution` steps of `hybrid-gate.yml` both died this way until #25 derived
their diff ranges from the event that actually fired; #25 left the neighbouring
`check-trailer` step passing `$PR_HEAD_SHA` straight to `git log`.

WARNING: this guard only sees values that reach a `git` command line in the same
step. An empty value consumed by `grep`, `case` or an echo is harmless and is
deliberately not reported -- reporting it would make this check fire on ~18 sites
fleet-wide, none of them defects, and a check that cannot pass teaches its
readers to skim past it.

A site is compliant when the expression carries a `||` fallback, or the step's
`run:` script tests the variable for emptiness before using it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# WHY: the contexts GitHub populates for pull_request events and leaves empty on
# a push. The `pull_request.` prefix covers head.sha, user.login, title, body.
PR_ONLY_CONTEXT = re.compile(
    r"github\.event\.pull_request\.|github\.head_ref|github\.base_ref"
)

ENV_KEY = re.compile(r"^(?P<indent>\s+)env:\s*$")
MAPPING_ENTRY = re.compile(
    r"^(?P<indent>\s+)(?P<name>[A-Za-z_][A-Za-z0-9_]*):\s*(?P<value>\S.*?)\s*$"
)
EXPRESSION = re.compile(r"\$\{\{(?P<expr>.+?)\}\}")
STEP_START = re.compile(r"^(?P<indent>\s*)-\s")
GIT_COMMAND = re.compile(r"(?:^|[|;&(`]|\$\()\s*git\s")


class Finding:
    """One pull_request-only value reaching `git` with no guard."""

    def __init__(self, path: Path, line: int, name: str, git_line: str) -> None:
        self.path = path
        self.line = line
        self.name = name
        self.git_line = git_line

    def __str__(self) -> str:
        return (
            f"{self.path}:{self.line}: `{self.name}` interpolates a "
            "pull_request-only context with no `||` fallback, and reaches git "
            f"with no emptiness test: `{self.git_line}`. On a push event this "
            "aborts with `fatal: ambiguous argument ''`."
        )


def env_vars(lines: list[str], start: int, end: int) -> dict[str, str]:
    """Map env var name to expression text for every `env:` entry in a span."""
    found: dict[str, str] = {}
    env_indent: int | None = None
    for line in lines[start:end]:
        key = ENV_KEY.match(line)
        if key:
            env_indent = len(key.group("indent"))
            continue
        if env_indent is None:
            continue
        entry = MAPPING_ENTRY.match(line)
        if entry is None:
            if line.strip() and not line.lstrip().startswith("#"):
                env_indent = None
            continue
        if len(entry.group("indent")) <= env_indent:
            env_indent = None
            continue
        expression = EXPRESSION.search(entry.group("value"))
        if expression is not None:
            found[entry.group("name")] = expression.group("expr")
    return found


def step_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Return the [start, end) span of every YAML sequence item."""
    starts = [
        (index, len(match.group("indent")))
        for index, line in enumerate(lines)
        if (match := STEP_START.match(line))
    ]
    spans: list[tuple[int, int]] = []
    for position, (index, indent) in enumerate(starts):
        end = len(lines)
        for next_index, next_indent in starts[position + 1 :]:
            if next_indent <= indent:
                end = next_index
                break
        spans.append((index, end))
    return spans


def guards_emptiness(body: str, name: str) -> bool:
    """True when `body` tests `$name` for being set or empty before use."""
    guard = re.compile(
        r"""\[\[?\s+-[nz]\s+"?\$\{?""" + re.escape(name) + r"""\}?"?\s+\]\]?"""
    )
    return bool(guard.search(body))


def check_file(path: Path) -> tuple[list[Finding], int]:
    """Return the findings in `path` and how many PR-only values it examined."""
    lines = path.read_text(encoding="utf-8").splitlines()
    findings: list[Finding] = []
    examined = 0
    for start, end in step_spans(lines):
        body = "\n".join(lines[start:end])
        for name, expression in env_vars(lines, start, end).items():
            if not PR_ONLY_CONTEXT.search(expression):
                continue
            examined += 1
            if "||" in expression or guards_emptiness(body, name):
                continue
            reference = re.compile(r"\$\{?" + re.escape(name) + r"\}?\b")
            for offset, line in enumerate(lines[start:end]):
                if GIT_COMMAND.search(line) and reference.search(line):
                    findings.append(
                        Finding(path, start + offset + 1, name, line.strip())
                    )
                    break
    return findings, examined


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(".github/workflows")
    paths = sorted(root.glob("*.yml"))
    if not paths:
        print(f"ERROR: no workflow files under {root}", file=sys.stderr)
        return 1

    findings: list[Finding] = []
    examined = 0
    for path in paths:
        path_findings, path_examined = check_file(path)
        findings.extend(path_findings)
        examined += path_examined

    # WHY: a guard that examined nothing reports the same green as a guard that
    # examined everything. Refuse to pass vacuously.
    if examined == 0:
        print(
            "ERROR: no pull_request-only interpolation was examined, so this "
            "guard no longer measures anything. Either the workflows stopped "
            "using those contexts, or the parser stopped matching them.",
            file=sys.stderr,
        )
        return 1

    for finding in findings:
        print(f"ERROR: {finding}", file=sys.stderr)
    if findings:
        print(
            f"\n{len(findings)} unguarded site(s). Add a `|| <fallback>` to the "
            "expression (github.sha is the push-event equivalent of a PR tip), "
            "or test the variable for emptiness before the git call.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: {examined} pull_request-only value(s) examined, none reaches git unguarded."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
