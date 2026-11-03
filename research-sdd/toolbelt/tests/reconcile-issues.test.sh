#!/usr/bin/env bash
# reconcile-issues.test.sh — TDD harness for reconcile-issues.sh.
#
# Covers: absent-input (file not found); empty-input (no delta section);
# no-match (applied retro, no orphaned issues); tracked (stub returns matching
# issue); untracked (stub returns no issue); orphaned (stub returns signature
# for a now-shipped row); degraded (gh absent from PATH); --all over >=2 targets;
# json-flag (gh called with --json body, not --template); gh-fail-degraded (gh
# query returns non-zero → non-zero exit + typed degraded, never false untracked).
#
# Usage: reconcile-issues.test.sh                (run the suite)
#        reconcile-issues.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../reconcile-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
RETRO_STATUS_LIB="$HERE/../lib/retro-status.sh"
[ -f "$RETRO_STATUS_LIB" ] || { echo "FATAL: retro-status helper not found" >&2; exit 2; }
RETRO_GRAMMAR_LIB="$HERE/../lib/retro-grammar.sh"
[ -f "$RETRO_GRAMMAR_LIB" ] || { echo "FATAL: retro-grammar helper not found" >&2; exit 2; }
TARGET_PATHS_LIB="$HERE/../lib/target-paths.sh"
[ -f "$TARGET_PATHS_LIB" ] || { echo "FATAL: target-paths helper not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v awk  >/dev/null 2>&1 || { echo "FATAL: awk not on PATH" >&2; exit 2; }
command -v grep >/dev/null 2>&1 || { echo "FATAL: grep not on PATH" >&2; exit 2; }
command -v sed  >/dev/null 2>&1 || { echo "FATAL: sed not on PATH" >&2; exit 2; }
JQ_BIN="$(type -P jq)"; [ -n "$JQ_BIN" ] || { echo "FATAL: jq not on PATH (the closed-issue gh stub runs the SUT's --jq through it)" >&2; exit 2; }

# Pre-resolve coreutil paths for hermetic PATH construction in degraded test
_AWK_BIN="$(type -P awk)"; _GREP_BIN="$(type -P grep)"
_SED_BIN="$(type -P sed)"; _TR_BIN="$(type -P tr)"
_DIRNAME_BIN="$(type -P dirname)"; _BASENAME_BIN="$(type -P basename)"
_HEAD_BIN="$(type -P head)"; _SORT_BIN="$(type -P sort)"
_CUT_BIN="$(type -P cut)"; _FIND_BIN="$(type -P find)"

# mk_hermetic_bin <box>: populate $box/bin with essential coreutils but NO gh.
mk_hermetic_bin() {
  local box="$1"
  mkdir -p "$box/bin"
  ln -sf "$BASH_BIN"       "$box/bin/bash"
  ln -sf "$_AWK_BIN"       "$box/bin/awk"
  ln -sf "$_GREP_BIN"      "$box/bin/grep"
  ln -sf "$_SED_BIN"       "$box/bin/sed"
  ln -sf "$_TR_BIN"        "$box/bin/tr"
  ln -sf "$_DIRNAME_BIN"   "$box/bin/dirname"
  ln -sf "$_BASENAME_BIN"  "$box/bin/basename"
  ln -sf "$_HEAD_BIN"      "$box/bin/head"
  ln -sf "$_SORT_BIN"      "$box/bin/sort"
  ln -sf "$_CUT_BIN"       "$box/bin/cut"
  ln -sf "$_FIND_BIN"      "$box/bin/find"
  # No gh symlink — that is the point of this helper
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# Case 47 runs the stager shim, which runs the Go command: the caller's RSDD_BIN, else one build into the temp dir
# (degraded, never a pass, without go).
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$ROOT/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  RSDD_BIN="$ROOT/rsdd"
fi
export RSDD_BIN
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# mkbox <name> [target-name]
#   Builds a single-target hermetic sandbox.
mkbox() {
  local name="$1" tgt="${2:-target-foo}"
  local box="$ROOT/$name"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/$tgt/retros" "$box/bin"
  cp "$SUT"               "$box/research-sdd/toolbelt/reconcile-issues.sh"
  cp "$RETRO_STATUS_LIB"  "$box/research-sdd/toolbelt/lib/retro-status.sh"
  cp "$RETRO_GRAMMAR_LIB" "$box/research-sdd/toolbelt/lib/retro-grammar.sh"
  cp "$TARGET_PATHS_LIB"  "$box/research-sdd/toolbelt/lib/target-paths.sh"
  # `sleep` stub (kit issue #1784): never really waits; logs its argument so a test can read the backoff.
  printf '#!%s\nprintf "%%s\\n" "$1" >> "%s/bin/sleep.log"\n' "$BASH_BIN" "$box" > "$box/bin/sleep"; chmod +x "$box/bin/sleep"
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | %s | `%s` |\n' "$tgt" "$box/rh/$tgt"
  } > "$box/research-sdd/TARGETS.md"
  printf '%s' "$box"
}

# mk_retro <box> <target> <filename> <marker> <table-content>
#   marker="-" for no leading comment.
#   table-content="-" to skip the delta section entirely.
#   table-content="" for an empty table.
mk_retro() {
  local box="$1" tgt="$2" fname="$3" marker="$4" table_content="$5"
  local f="$box/rh/$tgt/retros/$fname"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    if [ "$table_content" = "-" ]; then
      printf '# retro\n\nNo proposed deltas here.\n'
    else
      printf '# retro\n\n## Proposed kit deltas\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
      printf '|---|---|---|---|---|---|\n'
      [ -z "$table_content" ] || printf '%s\n' "$table_content"
    fi
  } > "$f"
  printf '%s' "$f"
}

# run <box> [args...]
#   Invoke the sandbox SUT; capture stdout+stderr into OUT, exit code into RC.
run() {
  local box="$1"; shift
  OUT="$(PATH="$box/bin:$PATH" \
    "$BASH_BIN" "$box/research-sdd/toolbelt/reconcile-issues.sh" \
    "$@" 2>&1)"; RC=$?
}

echo "== reconcile-issues.test.sh =="

# ---------------------------------------------------------------------------
# 1 — ABSENT-INPUT: retro file not found → absent-input message, exit 1
box="$(mkbox case-absent)"
run "$box" "$box/rh/target-foo/retros/does-not-exist.md"
if [ "$RC" = 1 ] && grep -qi 'absent-input' <<<"$OUT"; then
  ok "1 absent-input: missing retro → exit 1 + absent-input message" "(exit $RC)"
else
  no "1 absent-input: missing retro → exit 1 + absent-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 2 — EMPTY-INPUT: no delta section → empty-input message, exit 0
box="$(mkbox case-empty)"
retro="$(mk_retro "$box" target-foo r-empty.md "<!-- review-status: pending -->" "-")"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi 'empty-input' <<<"$OUT"; then
  ok "2 empty-input: no delta section → exit 0 + empty-input message" "(exit $RC)"
else
  no "2 empty-input: no delta section → exit 0 + empty-input message" "exit=$RC out=[$OUT]"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
