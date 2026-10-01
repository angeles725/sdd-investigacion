#!/usr/bin/env bash
# lint-block.sh — mechanical block linter (kit issue #1206, slice 1).
#
# Enforces the GENERIC block-writing rules that prose alone already failed to hold (see
# lint_block.py for the rule definitions: R0 waiver hygiene, R3 ephemeral evidence in Self-verify,
# R6 cross-block comparison without a raw artifact). Per-target rule packs (JVM, multi-version,
# child-gap hygiene, ...) are slice 2 and plug into the RULES registry in lint_block.py.
#
# Usage:
#   lint-block.sh <block.md>...             FAIL mode: exit 1 if any finding remains. Use on NEW blocks.
#   lint-block.sh --audit <path>...         report-only: <path> is a block file or a corpus directory
#                                           (canonical block files found recursively). Exit 0 with
#                                           counts whatever the findings. Use on LEGACY corpora.
#
# Waiver (per paragraph / table row, any line of it):
#   <!-- lint-waive: R3 reason=why this evidence is acceptable -->
#   A waiver with no `reason=` text is an R0 finding and does NOT waive.
#
# Read-only: never writes into a target (METHODOLOGY §13/§18 propose-never-apply). Never edits blocks.
#
# Typed states (CLAUDE.md §7 — a bare "0" must say which zero it is):
#   ABSENT-INPUT  a given path does not exist                    -> exit 2 (reported, rest still linted)
#   EMPTY-INPUT   an empty file, or a directory with no block files -> reported, not a finding
#   UNCLASSIFIED  --audit: N non-canonical .md files under a corpus were not linted (count + first 3)
#   NO-MATCH      files read and inspected, no rule fired          -> exit 0
#   DEGRADED      python3 or the helper is unavailable / a listing failed -> exit 2, NOTHING linted
#                 is never reported as clean
# Every run ends with a `SUMMARY` line carrying the coverage counters (how many Self-verify
# sections, [CERT-hw]/[CERT-live] items and R6 trigger clauses were actually inspected).
#
# Exit: 0 clean (or --audit) · 1 findings in FAIL mode · 2 usage / absent / unreadable / degraded.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELF_DIR/lint_block.py"
_bflib="$SELF_DIR/lib/block-files.sh"

usage() {
  echo "usage: lint-block.sh <block.md>...        (FAIL mode)" >&2
  echo "       lint-block.sh --audit <file|dir>...  (report-only; dirs are searched for block files)" >&2
}

audit=0
paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --audit) audit=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done; break ;;
    -*) echo "lint-block: unknown option: $1" >&2; usage; exit 2 ;;
    *) paths+=("$1") ;;
  esac
  shift
done
if [ "${#paths[@]}" -eq 0 ]; then usage; exit 2; fi

# --- probe: could the instrument run at all? (§7 third question) ---------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "lint-block: DEGRADED: python3 not found — nothing was linted (this is NOT a clean result)" >&2
  exit 2
fi
if [ ! -f "$HELPER" ]; then
  echo "lint-block: DEGRADED: helper $HELPER missing — nothing was linted (this is NOT a clean result)" >&2
  exit 2
fi
# shellcheck source=lib/block-files.sh
. "$_bflib" 2>/dev/null
if ! declare -F block_file_filter >/dev/null 2>&1; then
  echo "lint-block: DEGRADED: lib/block-files.sh failed to define block_file_filter — nothing was linted (this is NOT a clean result)" >&2
  exit 2
fi

tmp="$(mktemp -d)" || { echo "lint-block: DEGRADED: cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
list="$tmp/files"
: > "$list"
rc_ops=0

for p in "${paths[@]}"; do
  if [ -d "$p" ]; then
    if [ "$audit" -ne 1 ]; then
      echo "lint-block: $p is a directory; FAIL mode takes block files (use --audit for a corpus)" >&2
      rc_ops=2
      continue
    fi
    # Prune by BASENAME below the root (never by absolute-path substring: a corpus that itself
    # lives under a `.claude/` ancestor, e.g. a harness worktree, must not be skipped wholesale).
    find "$p" -mindepth 1 \( -name node_modules -o -name .git -o -name .claude \) -prune \
      -o -type f -name '*.md' -print \
      2>"$tmp/find.err" | LC_ALL=C sort > "$tmp/all"
    ps=("${PIPESTATUS[@]}")
    block_file_filter < "$tmp/all" > "$tmp/found"; fst=$?
    block_file_filter -v < "$tmp/all" > "$tmp/unclass"; ust=$?
    if [ "${ps[0]}" -ne 0 ] || [ "${ps[1]}" -ne 0 ] || [ "$fst" -ge 2 ] || [ "$ust" -ge 2 ]; then
      echo "lint-block: DEGRADED: listing of $p failed (find=${ps[0]} sort=${ps[1]} filter=$fst/$ust); result below is partial" >&2
      rc_ops=2
    fi
    if [ -s "$tmp/found" ]; then
      cat "$tmp/found" >> "$list"
    elif [ "$fst" -lt 2 ]; then
      echo "EMPTY-INPUT: $p has no canonical block files"
    fi
    # Non-canonical .md files are NOT linted; say how many and which (first 3), never drop silently.
    if [ -s "$tmp/unclass" ]; then
      n_un="$(wc -l < "$tmp/unclass" | tr -d ' ')"
      first_un="$(head -n 3 "$tmp/unclass" | tr '\n' ' ')"
      echo "UNCLASSIFIED: $n_un non-canonical .md file(s) under $p were NOT linted (first: ${first_un% })"
    fi
  elif [ -f "$p" ]; then
    printf '%s\n' "$p" >> "$list"
  else
    echo "ABSENT-INPUT: $p does not exist" >&2
    rc_ops=2
  fi
done

if [ ! -s "$list" ]; then
  # Nothing to lint: say so explicitly — never a bare confident zero.
  if [ "$rc_ops" -ne 0 ]; then
    echo "lint-block: nothing was linted (see ABSENT-INPUT / DEGRADED above)" >&2
    exit 2
  fi
  echo "SUMMARY files=0 findings=0 — EMPTY-INPUT: no block files in the given paths; nothing was linted"
  exit 0
fi

mode_args=()
[ "$audit" -eq 1 ] && mode_args=(--audit)
python3 "$HELPER" "${mode_args[@]}" --files-from - < "$list"
rc=$?
if [ "$rc_ops" -ne 0 ] && [ "$rc" -lt 2 ]; then rc=2; fi
exit "$rc"
