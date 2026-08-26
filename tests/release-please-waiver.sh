#!/usr/bin/env bash
# Drive the release-please branch-shape waivers in gate-attestation.yml and
# hybrid-gate.yml against a spoofed-author fixture.
#
# WHY this exists: issue #18 found that a branch named
# `release-please--branches--x` alone bypassed the Gate-Passed trailer check
# and the AI-attribution check, because `github.head_ref` is chosen by
# whoever opens the PR. The fix (#42) paired the branch shape with a
# `user.type == 'Bot'` check nobody but GitHub can set. Nothing exercised
# that fix: actionlint checks the workflow's shape, not what the expression
# or the shell decides for a given author. This is that adversarial fixture —
# a human/fork PR using the release-please branch prefix must NOT be waived.
#
# Both extractions read the live workflow text rather than a hand-copied
# duplicate of the condition, so a future edit to the real logic is what this
# test evaluates, not a description of it that can drift out of sync.
#
# Usage: bash tests/release-please-waiver.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GA="$ROOT/.github/workflows/gate-attestation.yml"
HG="$ROOT/.github/workflows/hybrid-gate.yml"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

rc_all=0

echo "== gate-attestation.yml: 'Pass trusted automation PRs' if-expression =="

# Extract the expression text and evaluate it with python, translating the
# small subset of GH Actions expression syntax this line uses.
python3 - "$GA" "$SCRATCH/ga_cases.txt" <<'PY'
import re, sys, pathlib

src = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"name: Pass trusted automation PRs\n\s*if: \$\{\{(.*)\}\}", src)
if not m:
    print("FAIL: could not find the 'Pass trusted automation PRs' if-expression", file=sys.stderr)
    sys.exit(1)
expr = m.group(1).strip()

def translate(expr, login, head_ref, user_type):
    py = expr
    py = re.sub(r"startsWith\(([^,]+),\s*'([^']*)'\)", r"\1.startswith('\2')", py)
    py = py.replace("github.event.pull_request.user.login", repr(login))
    py = py.replace("github.event.pull_request.user.type", repr(user_type))
    py = py.replace("github.head_ref", repr(head_ref))
    py = py.replace("&&", " and ").replace("||", " or ")
    return eval(py)

cases = [
    # (label, login, head_ref, user_type, want_waived)
    ("dependabot login",                         "dependabot[bot]", "dependabot/npm/x",                       "Bot", True),
    ("release-please[bot] login",                 "release-please[bot]", "some-branch",                         "Bot", True),
    ("release-please branch + Bot author",         "release-please[bot]", "release-please--branches--main",     "Bot", True),
    ("release-please branch + PAT-owned Bot",      "some-app[bot]", "release-please--branches--main",           "Bot", True),
    ("SPOOFED: release-please branch, User author", "attacker", "release-please--branches--main",                "User", False),
    ("SPOOFED: release-please branch, no type",     "attacker", "release-please--branches--main",                "",     False),
    ("ordinary PR",                                "someone",    "feature/x",                                    "User", False),
]

lines = []
ok = True
for label, login, head_ref, user_type, want in cases:
    got = translate(expr, login, head_ref, user_type)
    status = "pass" if got == want else "FAIL"
    if got != want:
        ok = False
    lines.append(f"  {status}  {label:<48} -> waived={got} (wanted {want})")

pathlib.Path(sys.argv[2]).write_text("\n".join(lines) + "\n")
sys.exit(0 if ok else 1)
PY
ga_rc=$?
cat "$SCRATCH/ga_cases.txt"
[ "$ga_rc" -eq 0 ] || rc_all=1

echo
echo "== hybrid-gate.yml: 'Verify no AI attribution' run block =="

# Extract the run: block of the ai-attribution step, de-indented.
python3 - "$HG" "$SCRATCH/step.sh" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i, l in enumerate(src) if l.strip() == 'case "$PR_HEAD_REF" in')
end = next(i for i, l in enumerate(src) if i > start and l.strip() == 'exit 1' and src[i - 1].strip().startswith("echo \"Remove AI attribution"))
end += 1  # the closing `fi` for the final `if [ "$violation" -ne 0 ]` block
body = []
for l in src[start:end + 1]:
    body.append(l[10:] if l.startswith(" " * 10) else l)
pathlib.Path(sys.argv[2]).write_text("\n".join(body) + "\n")
PY

run_case() {
  local label="$1" head_ref="$2" author="$3" author_type="$4" title="$5" want_rc="$6"
  PR_HEAD_REF="$head_ref" PR_AUTHOR="$author" PR_AUTHOR_TYPE="$author_type" \
  PR_TITLE="$title" PR_BODY="" BASE_REF="" EVENT_BEFORE="" \
  bash "$SCRATCH/step.sh" >"$SCRATCH/out" 2>&1
  local got_rc=$?
  if [ "$got_rc" -eq "$want_rc" ]; then
    printf '  pass  %-58s -> exit %s\n' "$label" "$got_rc"
  else
    printf '  FAIL  %-58s -> exit %s (wanted %s)\n' "$label" "$got_rc" "$want_rc"
    sed 's/^/        /' "$SCRATCH/out"
    rc_all=1
  fi
}

# WHY the marker sits at the START of the title: the AI-attribution pattern
# is line-anchored (^) so it does not misfire on a title merely discussing
# the policy mid-sentence — a marker embedded elsewhere in the string is a
# property of that regex, not of the release-please waiver under test here.
run_case "release-please branch, Bot author, clean title"        "release-please--branches--main" "release-please[bot]" "Bot"  "chore: release 1.2.3" 0
run_case "SPOOFED branch, User author, clean title"                "release-please--branches--main" "attacker" "User" "chore: release 1.2.3" 0
run_case "SPOOFED branch, User author, AI marker in title"         "release-please--branches--main" "attacker" "User" "🤖 Generated with Claude" 1
run_case "ordinary PR, clean title"                                 "feature/x" "someone" "User" "feat: add x" 0
run_case "ordinary PR, AI marker in title"                          "feature/x" "someone" "User" "co-authored-by: claude" 1

echo
[ "$rc_all" -eq 0 ] && echo "all cases pass" || echo "FAILURES above"
exit "$rc_all"
