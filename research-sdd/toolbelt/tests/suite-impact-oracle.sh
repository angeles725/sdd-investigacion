#!/usr/bin/env bash
# suite-impact-oracle.sh — a REAL oracle for suite-impact.sh (kit issue #2201). Acceptance evidence, not a gate.
#
# The replay oracle (suite-impact-replay.sh) only checks that a changed suite selects itself, which is tautological.
# This one asks the real question: if this production file were BROKEN, which suites would notice, and did the
# impact map select them?
#
#   1. archive the whole repo at --ref into a temp dir and commit it there (the live tree is never written);
#   2. inject a breaking mutation into --file: `exit 97` after the shebang (.sh), `raise SystemExit(97)` (.py),
#      `process.exit(97);` (.mjs/.js); commit it as a second commit;
#   3. ask suite-impact.sh what it selects for that commit; an ESCALATED run selects everything, so there is nothing
#      to check and the oracle says so;
#   4. run every suite the map did NOT select, plain, inside the temp copy (each bounded by a timeout, --jobs in
#      parallel); a suite that fails with the mutation is a CANDIDATE miss;
#   5. restore the original file and re-run each candidate: still failing = a pre-existing failure (reported, not
#      a miss); passing = a REAL MISS (the mutation broke it and the map did not select it).
#   A suite that hits the timeout is INCONCLUSIVE: listed, never counted as a pass or a miss.
#
# Usage: suite-impact-oracle.sh --file <repo-relative production path> [--repo DIR] [--ref REF] [--jobs N]
#                               [--timeout SECONDS] [--manifest-dir DIR] [--keep]
#   --ref      default HEAD        --jobs  default 4        --timeout  default 600 (per suite)
#   --keep     keep the temp copy and print `kept: <dir>` (for inspection)
# Env: SUITE_IMPACT_SUT  the instrument (default: suite-impact.sh next to this script)
# Output (one line): ORACLE file=<f> selected=<n> unselected=<n> failed-under-mutation=<n> baseline-failing=<n>
#                    timed-out=<n> misses=[<suite>...]       (or: ORACLE file=<f> escalated: <reason>)
# Exit: 0 no real miss (or escalated) · 1 at least one real miss · 2 degraded/usage (`degraded: suite-impact-oracle: ...`).
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
INSTRUMENT="${SUITE_IMPACT_SUT:-$HERE/suite-impact.sh}"
degraded() { echo "degraded: suite-impact-oracle: $*" >&2; exit 2; }
usage() { echo "usage: suite-impact-oracle.sh --file <repo-relative production path> [--repo DIR] [--ref REF] [--jobs N] [--timeout SECONDS] [--manifest-dir DIR] [--keep]" >&2; exit 2; }

FILE=""; REPO_ARG="."; REF="HEAD"; JOBS=4; TIMEOUT=600; KEEP=0; MANIFESTS="$HERE"
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || usage; FILE="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO_ARG="$2"; shift 2 ;;
    --ref) [ $# -ge 2 ] || usage; REF="$2"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || usage; JOBS="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
    --manifest-dir) [ $# -ge 2 ] || usage; MANIFESTS="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "suite-impact-oracle: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$FILE" ] || usage
case "$JOBS" in ''|*[!0-9]*|0) echo "suite-impact-oracle: --jobs must be a positive integer" >&2; usage ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) echo "suite-impact-oracle: --timeout must be a positive integer" >&2; usage ;; esac
case "$FILE" in /*|*..*) echo "suite-impact-oracle: --file must be a repo-relative path without '..'" >&2; usage ;; esac
case "$FILE" in
  *.sh) MUT_KIND="sh" ;; *.py) MUT_KIND=py ;; *.mjs|*.js) MUT_KIND=js ;;
  *) echo "suite-impact-oracle: unsupported file type (want .sh .py .mjs .js): $FILE" >&2; usage ;;
esac
[ -f "$INSTRUMENT" ] || degraded "instrument absent: $INSTRUMENT"
for t in git tar timeout xargs mktemp awk cmp comm find sed tr; do command -v "$t" >/dev/null 2>&1 || degraded "$t not found on PATH"; done
REPO="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || degraded "not a git repository: $REPO_ARG"
git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1 || degraded "bad ref: $REF"
git -C "$REPO" cat-file -e "$REF:$FILE" 2>/dev/null || degraded "$FILE does not exist at $REF"

WORK="$(mktemp -d)" || degraded "cannot create a temp dir"
cleanup() { if [ "$KEEP" = 1 ]; then echo "kept: $WORK"; else rm -rf -- "$WORK"; fi; }
trap cleanup EXIT
TREE="$WORK/tree"; mkdir -p "$TREE" "$WORK/logs" "$WORK/tmp"
git -C "$REPO" archive "$REF" | tar -x -C "$TREE" || degraded "cannot export $REF"

# hermetic git identity inside the copy
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=oracle GIT_AUTHOR_EMAIL=oracle@invalid GIT_COMMITTER_NAME=oracle GIT_COMMITTER_EMAIL=oracle@invalid
( cd "$TREE" && git init -q -b main . && git add -A && git commit -q -m base ) || degraded "cannot commit the temp copy"

# ---- the mutation -------------------------------------------------------------------------------------------
case "$MUT_KIND" in
  sh) BREAK='exit 97' ;;
  py) BREAK='raise SystemExit(97)' ;;
  js) BREAK='process.exit(97);' ;;
esac
awk -v b="$BREAK" 'NR==1 && /^#!/ { print; print b; next } NR==1 { print b } { print }' "$TREE/$FILE" > "$WORK/mutant" || degraded "cannot build the mutant"
cmp -s "$TREE/$FILE" "$WORK/mutant" && degraded "mutation did not change $FILE"
cp "$TREE/$FILE" "$WORK/original"
cat "$WORK/mutant" > "$TREE/$FILE"
( cd "$TREE" && git add -A && git commit -q -m mutation ) || degraded "cannot commit the mutation"

# ---- what does the map select? ----------------------------------------------------------------------------
bash "$INSTRUMENT" --repo "$TREE" --base HEAD~1 --head HEAD --format report --manifest-dir "$MANIFESTS" --tolerate-stale-manifest > "$WORK/report" 2> "$WORK/report.err" \
  || degraded "suite-impact.sh failed: $(head -n1 "$WORK/report.err")"
if grep -q '^Escalated to FULL: ' "$WORK/report"; then
  echo "ORACLE file=$FILE escalated: $(grep -m1 '^Escalated to FULL: ' "$WORK/report" | sed 's/^Escalated to FULL: //') (selection is every suite; nothing to check)"
  exit 0
fi
sed -n '/^Selected:$/,$p' "$WORK/report" | tail -n +2 | LC_ALL=C sort > "$WORK/selected"
[ -s "$WORK/selected" ] || degraded "the instrument selected no suite (could not look)"

# ---- every suite in the copy ------------------------------------------------------------------------------
( cd "$TREE" && find research-sdd/toolbelt/tests research-sdd/install/tests -maxdepth 1 -type f \( -name '*.test.sh' -o -name '*.test.mjs' \) | LC_ALL=C sort ) > "$WORK/all"
[ -s "$WORK/all" ] || degraded "no suites found in the copy (could not look)"
LC_ALL=C comm -23 "$WORK/all" "$WORK/selected" > "$WORK/unselected"
NSEL="$(grep -c . "$WORK/selected")"; NUNSEL="$(grep -c . "$WORK/unselected")"

# run_suite SUITE -> prints "<rc> <suite>"; log under logs/. rc 124 = timeout.
run_one() {
  local s="$1" name d rc
  name="$(printf '%s' "$s" | tr '/' '_')"
  d="$(mktemp -d -p "$WORK/tmp")"
  case "$s" in
    *.mjs) ( cd "$TREE" && TMPDIR="$d" timeout "$TIMEOUT" node "$s" ) > "$WORK/logs/$name.$2" 2>&1 ;;
    *) ( cd "$TREE" && TMPDIR="$d" timeout "$TIMEOUT" bash "$s" ) > "$WORK/logs/$name.$2" 2>&1 ;;
  esac
  rc=$?
  printf '%s %s\n' "$rc" "$s"
}
export -f run_one
export TREE WORK TIMEOUT

xargs -P "$JOBS" -I{} bash -c 'run_one "$1" mut' _ {} < "$WORK/unselected" > "$WORK/results" \
  || degraded "xargs reported a failure while running the unselected suites"
[ "$(grep -c . "$WORK/results")" = "$NUNSEL" ] || degraded "ran $(grep -c . "$WORK/results") of $NUNSEL unselected suites (could not look)"

awk '$1 == 124 { print $2 }' "$WORK/results" | LC_ALL=C sort > "$WORK/timedout"
awk '$1 != 0 && $1 != 124 { print $2 }' "$WORK/results" | LC_ALL=C sort > "$WORK/candidates"

# ---- baseline: restore the original and re-run each candidate ---------------------------------------------
cat "$WORK/original" > "$TREE/$FILE"
: > "$WORK/misses"; : > "$WORK/baseline"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  r="$(run_one "$s" base)"; rc="${r%% *}"
  if [ "$rc" = 0 ]; then printf '%s\n' "$s" >> "$WORK/misses"; else printf '%s\n' "$s" >> "$WORK/baseline"; fi
done < "$WORK/candidates"

short() { sed 's|^research-sdd/[a-z]*/tests/||; s|^research-sdd/install/tests/|install:|' | tr '\n' ' ' | sed 's/ $//'; }
printf 'ORACLE file=%s selected=%s unselected=%s failed-under-mutation=%s baseline-failing=%s timed-out=%s misses=[%s]\n' \
  "$FILE" "$NSEL" "$NUNSEL" "$(grep -c . "$WORK/candidates")" "$(grep -c . "$WORK/baseline")" "$(grep -c . "$WORK/timedout")" "$(short < "$WORK/misses")"
[ -s "$WORK/timedout" ] && echo "ORACLE inconclusive (timeout ${TIMEOUT}s): $(short < "$WORK/timedout")"
[ -s "$WORK/baseline" ] && echo "ORACLE pre-existing failures (fail without the mutation too): $(short < "$WORK/baseline")"
[ -s "$WORK/misses" ] && exit 1
exit 0
