#!/usr/bin/env bash
# Drive docs-only.yml's classification step against synthetic changesets.
#
# WHY this exists: the step is shell inside YAML, and its verdict decides whether a full build runs at
# all. A mistake in the permissive direction reports success having built nothing — the failure mode
# thumos#775 explicitly refused to risk by re-implementing the check locally. Nothing else exercises
# it: actionlint checks the workflow's shape, not what the shell decides.
#
# Usage: bash tests/docs-only.sh
set -uo pipefail

W="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/docs-only.yml"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

python3 - "$W" "$SCRATCH/step.sh" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i, l in enumerate(src) if l.strip().startswith('if [ "$DOCS_ONLY_EXEMPTION"'))
body = []
for l in src[start:]:
    body.append(l[10:] if l.startswith(" " * 10) else l)
pathlib.Path(sys.argv[2]).write_text("\n".join(body) + "\n")
PY

# Stub git: `rev-parse` succeeds so range selection is exercised; `diff --name-only` serves the case.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
  diff) cat "$CHANGED_FILE" ;;
  rev-parse) exit 0 ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$SCRATCH/bin/git"
export PATH="$SCRATCH/bin:$PATH"

rc_all=0
run_case() {
  local label="$1" files="$2" want="$3" exemption="${4:-true}"
  printf '%s' "$files" > "$SCRATCH/changed"
  CHANGED_FILE="$SCRATCH/changed" \
  DOCS_ONLY_EXEMPTION="$exemption" BASE_REF=main EVENT_BEFORE="" \
  GITHUB_OUTPUT="$SCRATCH/out" bash "$SCRATCH/step.sh" >/dev/null 2>&1
  local got
  got=$(sed -n 's/^docs_only=//p' "$SCRATCH/out" | tail -1)
  if [ "$got" = "$want" ]; then
    printf '  pass  %-50s -> %s\n' "$label" "$got"
  else
    printf '  FAIL  %-50s -> %s (wanted %s)\n' "$label" "$got" "$want"
    rc_all=1
  fi
  : > "$SCRATCH/out"
}

echo "== docs-only changesets =="
run_case "a single markdown file"            $'README.md\n'                      true
run_case "nested markdown (case * spans /)"  $'docs/design/a.md\nAGENTS.md\n'    true
run_case "the docs tree"                     $'docs/index.html\n'                true
run_case "llms.txt"                          $'llms.txt\n'                       true

echo "== anything else must build =="
run_case "one rust file among docs"          $'README.md\nsrc/main.rs\n'         false
run_case "a workflow change"                 $'.github/workflows/ci.yml\n'       false
run_case "a lockfile"                        $'Cargo.lock\n'                     false

echo "== the conservative branches =="
# WHY an empty diff must be false: it should not happen on a PR, and guessing docs-only on a
# changeset the tool could not read is the permissive direction.
run_case "empty changeset"                   ''                                  false
# WHY exemption=false must not merely skip: a caller wires this dependency unconditionally, so the
# opt-out has to produce an explicit false rather than an absent output that reads as empty.
run_case "repo opted out of the exemption"   $'README.md\n'                      false false

echo
[ "$rc_all" -eq 0 ] && echo "all cases pass" || echo "FAILURES above"
exit "$rc_all"
