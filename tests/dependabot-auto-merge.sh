#!/usr/bin/env bash
# Drive dependabot-auto-merge.yml's wait-and-verify step against synthetic check snapshots.
#
# WHY this exists: the step is shell inside YAML, so nothing type-checks it and nothing runs it until
# a real dependabot PR does — at which point a mistake either refuses every green PR or, worse,
# merges an unverified one. Both failure modes are invisible to review.
#
# It has already earned its place. The first version of the polling fix named its array `GROUPS`,
# which bash maintains itself as the current user's supplementary group IDs; the assignment was
# silently ignored, the loop iterated numeric GIDs, and every PR was refused. The YAML parsed, the
# shell raised nothing, and reading it showed a correct-looking array. Only running it showed GIDs.
#
# Usage: bash tests/dependabot-auto-merge.sh
set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/dependabot-auto-merge.yml"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Extract the `run:` block of the wait step, de-indented.
python3 - "$W" "$SCRATCH/step.sh" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i,l in enumerate(src) if l.strip() == "set -euo pipefail")
end   = next(i for i,l in enumerate(src) if 'echo "Required real verification checks passed."' in l)
body = "\n".join(l[10:] if l.startswith(" "*10) else l for l in src[start:end+1])
pathlib.Path(sys.argv[2]).write_text(body + "\n")
PY

# Stub `gh`: echoes whichever snapshot the case selected.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
cat "$SNAPSHOT"
GH
chmod +x "$SCRATCH/bin/gh"
# WHY the wait budget is 1s here: cases that must REFUSE do so by exhausting it, and a
# production-length wait would make this suite take 90 minutes to prove that.
export PATH="$SCRATCH/bin:$PATH" PR_URL=stub AUTO_MERGE_WAIT_SECONDS=1 AUTO_MERGE_POLL_SECONDS=1

rc_all=0
run_case() {
  local label="$1" json="$2" want="$3"
  printf '%s' "$json" > "$SCRATCH/snap.json"
  export SNAPSHOT="$SCRATCH/snap.json"
  out=$(bash "$SCRATCH/step.sh" 2>&1); rc=$?
  local got; [ $rc -eq 0 ] && got=ACCEPT || got=REFUSE
  if [ "$got" = "$want" ]; then printf '  pass  %-52s -> %s\n' "$label" "$got"
  else printf '  FAIL  %-52s -> %s (wanted %s)\n%s\n' "$label" "$got" "$want" "$(printf '%s' "$out" | head -4)"; rc_all=1; fi
}

ALL='[{"name":"gate / gate","bucket":"pass"},{"name":"cargo deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv-scanner","bucket":"pass"}]'
NOGATE='[{"name":"cargo deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv-scanner","bucket":"pass"}]'
PENDGATE='[{"name":"gate / gate","bucket":"pending"},{"name":"cargo deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv-scanner","bucket":"pass"}]'
FAILGATE='[{"name":"gate / gate","bucket":"fail"},{"name":"cargo deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv-scanner","bucket":"pass"}]'
ALTSPELL='[{"name":"Gate Attestation","bucket":"pass"},{"name":"cargo-deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv scanner","bucket":"pass"}]'
TWOGATE='[{"name":"gate / gate","bucket":"pass"},{"name":"other / gate-gate","bucket":"fail"},{"name":"cargo deny","bucket":"pass"},{"name":"cargo audit","bucket":"pass"},{"name":"osv-scanner","bucket":"pass"}]'

echo "== the bug this fixes =="
run_case "gate absent (the reported #46 failure)"        "$NOGATE"   REFUSE
run_case "gate still pending when fast checks passed"    "$PENDGATE" REFUSE
echo "== it must still accept a genuinely green PR =="
run_case "every group present and passing"               "$ALL"      ACCEPT
run_case "alternate spellings across repos"              "$ALTSPELL" ACCEPT
echo "== and still refuse the things it always refused =="
run_case "gate reported and failed"                      "$FAILGATE" REFUSE
run_case "two checks match one token, one of them fails"  "$TWOGATE"  REFUSE

echo "== the case the fix exists for: a gate that arrives late =="
mkdir -p "$SCRATCH/seq"
printf '%s' "$NOGATE"   > "$SCRATCH/seq/0.json"
printf '%s' "$PENDGATE" > "$SCRATCH/seq/1.json"
printf '%s' "$ALL"      > "$SCRATCH/seq/2.json"
echo 0 > "$SCRATCH/seq/n"
cat > "$SCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
n=$(cat "$SEQDIR/n" 2>/dev/null || echo 0)
f="$SEQDIR/$n.json"
[ -f "$f" ] || f=$(ls "$SEQDIR"/[0-9]*.json | sort -V | tail -1)
echo $((n+1)) > "$SEQDIR/n"
cat "$f"
GH
chmod +x "$SCRATCH/bin/gh"
if SEQDIR="$SCRATCH/seq" AUTO_MERGE_WAIT_SECONDS=30 AUTO_MERGE_POLL_SECONDS=1 \
     bash "$SCRATCH/step.sh" >/dev/null 2>&1; then
  printf '  pass  %-52s -> ACCEPT\n' "absent, then pending, then green"
else
  printf '  FAIL  %-52s -> REFUSE (wanted ACCEPT)\n' "absent, then pending, then green"
  rc_all=1
fi

echo
[ "$rc_all" -eq 0 ] && echo "all cases pass" || echo "FAILURES above"
exit "$rc_all"
