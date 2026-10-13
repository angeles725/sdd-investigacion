#!/usr/bin/env bash
# suite-impact-replay.sh — adoption evidence for suite-impact.sh (kit issue #2201). REPORT ONLY, not a gate.
#
# For the last N first-parent commits of a ref (default origin/main) it runs `suite-impact.sh` on
# `<sha>^..<sha>` and applies a cheap oracle: every suite file the commit itself added or modified
# (research-sdd/toolbelt/tests/*.test.sh|mjs, research-sdd/install/tests/*.test.sh) must be in the selection,
# or the run must have escalated to FULL. A commit that fails the oracle lists the missing suites.
#
# What the oracle does NOT prove: it checks that a changed suite is selected, not that the selection catches a
# regression the commit introduced in production code. It is the floor, a cheap smoke test of the map.
#
# Output, one line per commit:   <sha7> <selected>/<total> escalated=<yes|no> missing=[<suite>...]
#   a commit the map could not analyse prints:   <sha7> degraded rc=<rc>: <reason>
# then a totals block: commits, analysed, degraded, escalated + rate, oracle misses, mean selected size over the
# non-escalated runs and over all runs.
#
# Usage: suite-impact-replay.sh <N> [--ref REF] [--repo DIR] [--strict]
#   --strict   exit 1 when any commit missed the oracle or was degraded (default: always exit 0 after reporting)
# Env: SUITE_IMPACT_SUT  the instrument to run (default: suite-impact.sh next to this script)
# The manifests used are the ones next to this script: older commits do not carry them, and a manifest line
# naming a suite that did not exist yet is tolerated (--tolerate-stale-manifest).
# Exit: 0 reported · 1 --strict finding · 2 usage / operational failure.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${SUITE_IMPACT_SUT:-$HERE/suite-impact.sh}"

N=""; REF="origin/main"; REPO_ARG="."; STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) [ $# -ge 2 ] || { echo "usage: --ref needs a value" >&2; exit 2; }; REF="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || { echo "usage: --repo needs a value" >&2; exit 2; }; REPO_ARG="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -*) echo "suite-impact-replay: unknown argument: $1" >&2; exit 2 ;;
    *) if [ -z "$N" ]; then N="$1"; shift; else echo "suite-impact-replay: too many arguments" >&2; exit 2; fi ;;
  esac
done
case "$N" in ''|*[!0-9]*|0) echo "usage: suite-impact-replay.sh <N> [--ref REF] [--repo DIR] [--strict]  (N a positive integer)" >&2; exit 2 ;; esac
[ -f "$SUT" ] || { echo "degraded: suite-impact-replay: instrument absent: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "degraded: suite-impact-replay: git not found on PATH" >&2; exit 2; }
REPO="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || { echo "degraded: suite-impact-replay: not a git repository: $REPO_ARG" >&2; exit 2; }
git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1 || { echo "degraded: suite-impact-replay: bad ref: $REF" >&2; exit 2; }

TMP="$(mktemp -d)" || { echo "degraded: suite-impact-replay: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" rev-list --first-parent -n "$N" "$REF" > "$TMP/shas" || { echo "degraded: suite-impact-replay: rev-list failed" >&2; exit 2; }
[ -s "$TMP/shas" ] || { echo "degraded: suite-impact-replay: no commits on $REF" >&2; exit 2; }

commits=0; analysed=0; degr=0; esc=0; miss=0; sum_all=0; sum_ne=0; n_ne=0; skipped=0
while IFS= read -r sha; do
  commits=$((commits+1))
  short="${sha:0:7}"
  if ! git -C "$REPO" rev-parse --verify -q "$sha^" >/dev/null 2>&1; then
    echo "$short root-commit (no parent): skipped"; skipped=$((skipped+1)); continue
  fi
  bash "$SUT" --base "$sha^" --head "$sha" --repo "$REPO" --format report --manifest-dir "$HERE" --tolerate-stale-manifest > "$TMP/out" 2> "$TMP/err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$short degraded rc=$rc: $(head -n1 "$TMP/err")"; degr=$((degr+1)); continue
  fi
  analysed=$((analysed+1))
  line="$(grep -m1 '^Impacted: ' "$TMP/out")"
  sel="${line#Impacted: }"; sel="${sel%% of *}"
  tot="${line#*" of "}"; tot="${tot%% *}"
  case "$sel$tot" in ''|*[!0-9]*) echo "$short degraded rc=0: unparseable Impacted line: $line"; degr=$((degr+1)); analysed=$((analysed-1)); continue ;; esac
  if grep -q '^Escalated to FULL: ' "$TMP/out"; then escalated=yes; esc=$((esc+1)); else escalated=no; fi
  sed -n '/^Selected:$/,$p' "$TMP/out" | tail -n +2 > "$TMP/selected"
  missing=""
  # the diff goes to a file first so its failure is seen (a pipe would turn it into an empty "no suite changed")
  if ! git -C "$REPO" diff --name-status -M "$sha^" "$sha" > "$TMP/diff" 2>/dev/null; then
    echo "$short degraded rc=0: git diff failed"; degr=$((degr+1)); analysed=$((analysed-1)); continue
  fi
  : > "$TMP/changed_suites"
  while IFS=$'\t' read -r st a b; do
    f="${b:-$a}"
    case "$st" in D*) continue ;; esac
    case "$f" in
      research-sdd/toolbelt/tests/*.test.sh|research-sdd/toolbelt/tests/*.test.mjs|research-sdd/install/tests/*.test.sh|research-sdd/install/tests/*.test.mjs)
        rest="${f#research-sdd/*/tests/}"; case "$rest" in */*) continue ;; esac
        printf '%s\n' "$f" >> "$TMP/changed_suites" ;;
    esac
  done < "$TMP/diff"
  if [ "$escalated" = no ]; then
    while IFS= read -r f; do grep -qxF -- "$f" "$TMP/selected" || missing="$missing $f"; done < "$TMP/changed_suites"
  fi
  missing="${missing# }"
  [ -z "$missing" ] || miss=$((miss+1))
  sum_all=$((sum_all+sel))
  if [ "$escalated" = no ]; then sum_ne=$((sum_ne+sel)); n_ne=$((n_ne+1)); fi
  printf '%s %s/%s escalated=%s missing=[%s]\n' "$short" "$sel" "$tot" "$escalated" "$missing"
done < "$TMP/shas"

mean_all="n/a"; mean_ne="n/a"
[ "$analysed" -gt 0 ] && mean_all="$(awk -v s="$sum_all" -v n="$analysed" 'BEGIN{printf "%.1f", s/n}')"
[ "$n_ne" -gt 0 ] && mean_ne="$(awk -v s="$sum_ne" -v n="$n_ne" 'BEGIN{printf "%.1f", s/n}')"
rate="n/a"; [ "$analysed" -gt 0 ] && rate="$(awk -v e="$esc" -v n="$analysed" 'BEGIN{printf "%.0f%%", 100*e/n}')"
echo "Totals: commits=$commits analysed=$analysed degraded=$degr skipped=$skipped escalated=$esc ($rate) oracle-misses=$miss mean-selected(all)=$mean_all mean-selected(non-escalated)=$mean_ne"
if [ "$analysed" -eq 0 ]; then echo "degraded: suite-impact-replay: no commit could be analysed (nothing was measured)" >&2; exit 2; fi
if [ "$STRICT" = 1 ] && { [ "$miss" -gt 0 ] || [ "$degr" -gt 0 ]; }; then exit 1; fi
exit 0
