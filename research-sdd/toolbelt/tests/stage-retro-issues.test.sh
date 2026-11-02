#!/usr/bin/env bash
# stage-retro-issues.test.sh — TDD harness for stage-retro-issues.sh.
#
# Covers: dry-run output for pending retro; partial marker (deferred rows only);
# empty-input (no delta section); no-match (all shipped/applied); wrong-kit row;
# no-priority row (label omitted); --apply dedup (stub returns existing match);
# --apply creates issue (stub records the call); absent-input (file not found);
# degraded on missing gh under --apply.
#
# Usage: stage-retro-issues.test.sh                (run the suite)
#        stage-retro-issues.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
RETRO_STATUS_LIB="$HERE/../lib/retro-status.sh"
[ -f "$RETRO_STATUS_LIB" ] || { echo "FATAL: retro-status helper not found" >&2; exit 2; }
RETRO_GRAMMAR_LIB="$HERE/../lib/retro-grammar.sh"
[ -f "$RETRO_GRAMMAR_LIB" ] || { echo "FATAL: retro-grammar helper not found" >&2; exit 2; }
TARGET_PATHS_LIB="$HERE/../lib/target-paths.sh"
[ -f "$TARGET_PATHS_LIB" ] || { echo "FATAL: target-paths helper not found" >&2; exit 2; }
SCRUB_LIB="$HERE/../lib/scrub-issue-text.sh"
[ -f "$SCRUB_LIB" ] || { echo "FATAL: scrub-issue-text helper not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v awk  >/dev/null 2>&1 || { echo "FATAL: awk not on PATH" >&2; exit 2; }
command -v grep >/dev/null 2>&1 || { echo "FATAL: grep not on PATH" >&2; exit 2; }

# Pre-resolve coreutil paths for hermetic PATH construction in degraded test
_AWK_BIN="$(type -P awk)"; _GREP_BIN="$(type -P grep)"
_SED_BIN="$(type -P sed)"; _TR_BIN="$(type -P tr)"
_DIRNAME_BIN="$(type -P dirname)"; _BASENAME_BIN="$(type -P basename)"
_HEAD_BIN="$(type -P head)"; _SORT_BIN="$(type -P sort)"
_CUT_BIN="$(type -P cut)"; _PRINTF_BIN="$(type -P printf 2>/dev/null)" || _PRINTF_BIN=""

# mk_hermetic_bin <box>: populate $box/bin with symlinks to essential coreutils
# but WITHOUT gh — used for the degraded test case.
mk_hermetic_bin() {
  local box="$1"
  mkdir -p "$box/bin"
  ln -sf "$BASH_BIN"     "$box/bin/bash"
  ln -sf "$_AWK_BIN"     "$box/bin/awk"
  ln -sf "$_GREP_BIN"    "$box/bin/grep"
  ln -sf "$_SED_BIN"     "$box/bin/sed"
  ln -sf "$_TR_BIN"      "$box/bin/tr"
  ln -sf "$_DIRNAME_BIN" "$box/bin/dirname"
  ln -sf "$_BASENAME_BIN" "$box/bin/basename"
  ln -sf "$_HEAD_BIN"    "$box/bin/head"
  ln -sf "$_SORT_BIN"    "$box/bin/sort"
  ln -sf "$_CUT_BIN"     "$box/bin/cut"
  # No gh symlink — that is the point of this helper
}

# mk_no_git_bin <box>: populate $box/nogit-bin with symlinks to essential
# coreutils AND $box/bin/gh (if it exists) but WITHOUT git — used for the
# "git missing" degraded-message tests (kit issue #1045). Unlike
# mk_hermetic_bin, gh IS included here so the --apply gh-probe passes and the
# test actually exercises the git-missing branch of kit-issue-repo resolution,
# not the earlier gh-missing probe.
mk_no_git_bin() {
  local box="$1"
  mkdir -p "$box/nogit-bin"
  ln -sf "$BASH_BIN"      "$box/nogit-bin/bash"
  ln -sf "$_AWK_BIN"      "$box/nogit-bin/awk"
  ln -sf "$_GREP_BIN"     "$box/nogit-bin/grep"
  ln -sf "$_SED_BIN"      "$box/nogit-bin/sed"
  ln -sf "$_TR_BIN"       "$box/nogit-bin/tr"
  ln -sf "$_DIRNAME_BIN"  "$box/nogit-bin/dirname"
  ln -sf "$_BASENAME_BIN" "$box/nogit-bin/basename"
  ln -sf "$_HEAD_BIN"     "$box/nogit-bin/head"
  ln -sf "$_SORT_BIN"     "$box/nogit-bin/sort"
  ln -sf "$_CUT_BIN"      "$box/nogit-bin/cut"
  [ -x "$box/bin/gh" ] && ln -sf "$box/bin/gh" "$box/nogit-bin/gh"
  # No git symlink — that is the point of this helper
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
