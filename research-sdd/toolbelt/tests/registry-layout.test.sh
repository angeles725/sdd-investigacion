#!/usr/bin/env bash
# registry-layout.test.sh — the per-tool registry layout of kit issue #2225.
#
# Two PRs that each add a new tool used to append at the same anchor of reason-codes.v1.md /
# tool-registry.md and conflicted in every pair. The convention now is: one file per tool in
# reason-codes.d/<tool>.md (run-level notes) and tool-registry.d/<tool>.md (maint rows). This suite
# proves the readers still see everything (anti-silent-zero, CLAUDE.md §7):
#   - reason-codes.d/ or tool-registry.d/ absent                       -> DEGRADED rc 2 (absent-input)
#   - either directory without a single *.md                           -> DEGRADED rc 2 (empty-input)
#   - a .d file that is empty, or whose first line is not `### <stem>` -> FINDING rc 1
#   - a note stem that existed at the split (PINNED_NOTES) is gone     -> FINDING rc 1
#   - a non-.md file inside either .d directory                        -> FINDING rc 1
#   - maint/ absent, or with no tool script                            -> DEGRADED rc 2 (a zero-script pass proves nothing)
#   - a maint/ entry script with neither a `### <stem>` heading in
#     tool-registry.d/*.md nor a table row starting with
#     `| \`maint/<name>` in tool-registry.md                            -> FINDING rc 1
# On success the checker prints `INFO  maint scripts checked: N`.
# The degraded/input TABLES stay in reason-codes.v1.md and are verified by reason-codes.test.sh.
#
# Usage: registry-layout.test.sh [--prove-teeth]
#        registry-layout.test.sh --check TOOLBELT_DIR   (internal: the checker alone, exit 0/1/2)
# Exit: 0 all pass · 1 any failure · 2 harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)

# Notes that existed when the layout was introduced; a removed one is a dropped section, not a no-op.
PINNED_NOTES=(kit-merge-train kit-pr-pipeline kit-rdd kit-size-check kit-writer-check reconcile-issues run-all-cache suite-impact)

# layout_check TB — prints FINDING:/DEGRADED: lines; rc 0 clean · 1 findings · 2 degraded.
layout_check() {
  local tb="$1" d f stem first rc=0 n
  for d in reason-codes.d tool-registry.d; do
    if [ ! -d "$tb/$d" ]; then printf 'DEGRADED: absent-input: %s is not a directory\n' "$d"; return 2; fi
    n="$(find "$tb/$d" -maxdepth 1 -type f -name '*.md' | wc -l)" || { printf 'DEGRADED: find failed on %s\n' "$d"; return 2; }
    if [ "$n" -eq 0 ]; then printf 'DEGRADED: empty-input: %s holds no *.md file\n' "$d"; return 2; fi
    for f in "$tb/$d"/*; do
      case "$f" in *.md) ;; *) printf 'FINDING: non-.md file in %s: %s\n' "$d" "$(basename "$f")"; rc=1; continue ;; esac
      stem="$(basename "$f" .md)"
      first="$(head -n 1 "$f")"
      if [ ! -s "$f" ]; then printf 'FINDING: empty file: %s/%s.md\n' "$d" "$stem"; rc=1; continue; fi
      if [ "$first" != "### $stem" ] && [ "${first#"### $stem "}" = "$first" ]; then
        printf 'FINDING: %s/%s.md must start with "### %s" (found: %s)\n' "$d" "$stem" "$stem" "$first"; rc=1
      fi
    done
  done
  for stem in "${PINNED_NOTES[@]}"; do
    [ -f "$tb/reason-codes.d/$stem.md" ] || { printf 'FINDING: dropped note section: reason-codes.d/%s.md\n' "$stem"; rc=1; }
  done
  if [ ! -f "$tb/tool-registry.md" ]; then printf 'DEGRADED: absent-input: tool-registry.md\n'; return 2; fi
  if [ ! -d "$tb/maint" ]; then printf 'DEGRADED: absent-input: maint is not a directory\n'; return 2; fi
  n=0
  for f in "$tb"/maint/*; do
    [ -f "$f" ] || continue
    stem="$(basename "$f")"
    case "$stem" in *-common.sh) continue ;; esac   # sourced helper, not a tool entry point
    n=$((n + 1))
    if grep -qE -- "^### ${stem%.*}( |\$)" "$tb"/tool-registry.d/*.md \
      || grep -qF -- "| \`maint/$stem" "$tb/tool-registry.md"; then :; else
      printf 'FINDING: maint/%s has no "### %s" heading in tool-registry.d/ and no table row in tool-registry.md\n' "$stem" "${stem%.*}"; rc=1
    fi
  done
  if [ "$n" -eq 0 ]; then printf 'DEGRADED: empty-input: maint/ holds no tool script\n'; return 2; fi
  printf 'INFO  maint scripts checked: %s\n' "$n"
  return "$rc"
}

if [ "${1:-}" = "--check" ]; then layout_check "${2:?toolbelt dir}"; exit $?; fi

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed || exit 2
pass=0; fail=0
tmp=''
trap 'rm -rf "$tmp"' EXIT
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== registry-layout.test.sh =="

# expect NAME WANT_RC TB [GREP] — layout_check TB must exit WANT_RC and (when given) print GREP.
expect() {
  local name="$1" want="$2" dir="$3" pat="${4:-}" out rc
  out="$(layout_check "$dir")"; rc=$?
  if [ "$rc" -ne "$want" ]; then no "$name (rc $rc, wanted $want)"; printf '%s\n' "$out" | sed 's/^/        /'; return; fi
  if [ -n "$pat" ] && ! grep -qE -- "$pat" <<<"$out"; then no "$name (output lacks /$pat/)"; printf '%s\n' "$out" | sed 's/^/        /'; return; fi
  ok "$name"
  case "$name" in real*) grep -E -- '^INFO ' <<<"$out" | sed 's/^/        /' ;; esac
}

# --- 1. the real toolbelt ---
expect "real layout: every note section present, every maint tool has its own entry" 0 "$TB" 'maint scripts checked: [1-9]'

# --- 2. fixtures: a clean tree and one defect each ---
tmp="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
mkfix() {   # mkfix NAME — a clean mini toolbelt under $tmp/NAME
  local r="$tmp/$1" s
  mkdir -p "$r/reason-codes.d" "$r/tool-registry.d" "$r/maint"
  for s in "${PINNED_NOTES[@]}"; do printf '### %s\n\nnote body' "$s" > "$r/reason-codes.d/$s.md"; done  # no trailing newline: last-line edge
  printf '# registry\n| `maint/a.sh` | in the main file |' > "$r/tool-registry.md"
  printf '### b\n\n| `maint/b.sh` | in a .d file |' > "$r/tool-registry.d/b.md"
  : > "$r/maint/a.sh"; : > "$r/maint/b.sh"; : > "$r/maint/x-common.sh"
}
mkfix good;    expect "fixture: clean tree is clean (tool listed in main file, in .d file; helper exempt)" 0 "$tmp/good"
mkfix nodir;   rm -r "$tmp/nodir/reason-codes.d"
expect "fixture: reason-codes.d absent -> DEGRADED rc 2" 2 "$tmp/nodir" 'absent-input: reason-codes.d'
mkfix nodir2;  rm -r "$tmp/nodir2/tool-registry.d"
expect "fixture: tool-registry.d absent -> DEGRADED rc 2" 2 "$tmp/nodir2" 'absent-input: tool-registry.d'
mkfix emptyd;  rm "$tmp/emptyd/tool-registry.d/b.md"
expect "fixture: tool-registry.d with no *.md -> DEGRADED rc 2" 2 "$tmp/emptyd" 'empty-input: tool-registry.d'
mkfix emptyf;  : > "$tmp/emptyf/reason-codes.d/kit-rdd.md"
expect "fixture: empty note file fails" 1 "$tmp/emptyf" 'empty file: reason-codes.d/kit-rdd.md'
mkfix badhead; printf '## kit-rdd\nbody' > "$tmp/badhead/reason-codes.d/kit-rdd.md"
expect "fixture: heading not '### <stem>' fails" 1 "$tmp/badhead" 'must start with "### kit-rdd"'
mkfix lasthd;  printf '### b\n' > "$tmp/lasthd/tool-registry.d/b.md"; printf 'z' > "$tmp/lasthd/tool-registry.d/zz.md"
expect "fixture: LAST file (alphabetical) with a bad heading fails" 1 "$tmp/lasthd" 'tool-registry.d/zz.md must start'
mkfix dropped; rm "$tmp/dropped/reason-codes.d/suite-impact.md"
expect "fixture: a pinned note section removed fails" 1 "$tmp/dropped" 'dropped note section: reason-codes.d/suite-impact.md'
mkfix unlist;  : > "$tmp/unlist/maint/c.py"
expect "fixture: a maint tool listed nowhere fails" 1 "$tmp/unlist" 'maint/c.py has no "### c" heading'
mkfix mention; : > "$tmp/mention/maint/c.py"; printf 'see maint/c.py in prose' >> "$tmp/mention/tool-registry.md"
expect "fixture: a bare mention in prose is not an entry (substring is not enough)" 1 "$tmp/mention" 'maint/c.py has no'
mkfix nomaint; rm -r "$tmp/nomaint/maint"
expect "fixture: maint/ absent -> DEGRADED rc 2" 2 "$tmp/nomaint" 'absent-input: maint'
mkfix emaint;  rm "$tmp/emaint/maint/a.sh" "$tmp/emaint/maint/b.sh"
expect "fixture: maint/ with only a helper (zero tool scripts) -> DEGRADED rc 2" 2 "$tmp/emaint" 'empty-input: maint'
mkfix nonmd;   : > "$tmp/nonmd/reason-codes.d/notes.txt"
expect "fixture: a non-.md file in a .d directory fails" 1 "$tmp/nonmd" 'non-.md file in reason-codes.d: notes.txt'
mkfix firsthd; printf '## aa\nbody' > "$tmp/firsthd/reason-codes.d/aa.md"
expect "fixture: FIRST file (alphabetical) with a bad heading fails" 1 "$tmp/firsthd" 'reason-codes.d/aa.md must start'
mkfix single;  rm "$tmp/single/tool-registry.d/b.md"; printf '### b\n| `maint/b.sh` |' > "$tmp/single/tool-registry.d/b.md"
expect "fixture: single-file .d directory is clean" 0 "$tmp/single"

# --- 3. teeth: mutate a COPY of the real toolbelt pieces; each must turn the checker red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: dropping one section of the real layout must be caught --"
  cp_real() {   # cp_real NAME — a copy of the files the checker reads, under $tmp/NAME
    local r="$tmp/$1"
    mkdir -p "$r/maint" && cp -r "$TB/reason-codes.d" "$TB/tool-registry.d" "$TB/tool-registry.md" "$r/" \
      && cp -r "$TB"/maint/. "$r/maint/" || return 1
  }
  expect_red() { expect "teeth: $1" 1 "$2" "$3"; }
  if cp_real t_tr && rm "$tmp/t_tr/tool-registry.d/kit-writer-check.md"; then
    expect_red "dropping tool-registry.d/kit-writer-check.md leaves maint/kit-writer-check.sh without an entry" "$tmp/t_tr" 'kit-writer-check.sh has no'
  else no "teeth: could not build the tool-registry.d mutant"; fi
  if cp_real t_rc && rm "$tmp/t_rc/reason-codes.d/kit-merge-train.md"; then
    expect_red "dropping reason-codes.d/kit-merge-train.md is a dropped note section" "$tmp/t_rc" 'dropped note section: reason-codes.d/kit-merge-train.md'
  else no "teeth: could not build the reason-codes.d mutant"; fi
  if cp_real t_mt && rm -r "$tmp/t_mt/maint"; then
    expect "teeth: removing maint/ from the real layout is DEGRADED, not a pass" 2 "$tmp/t_mt" 'absent-input: maint'
  else no "teeth: could not build the maint-absent mutant"; fi
  if cp_real t_hd && MUTANT_SYNTAX=none mutant_sed "$TB/reason-codes.d/kit-rdd.md" "$tmp/t_hd/reason-codes.d/kit-rdd.md" '1s/^### /## /'; then
    expect_red "breaking one heading is caught" "$tmp/t_hd" 'must start with "### kit-rdd"'
  else no "teeth: could not build the heading mutant (refused by lib/mutant.sh)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
