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
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | %s | `%s` |\n' "$tgt" "$box/rh/$tgt"
  } > "$box/research-sdd/TARGETS.md"
  printf '%s' "$box"
}

# mkbox_all <name>: sandbox with 2 targets (alpha-target, beta-target)
mkbox_all() {
  local name="$1"
  local box="$ROOT/$name"
  mkdir -p "$box/research-sdd/toolbelt/lib" \
    "$box/rh/alpha-target/retros" \
    "$box/rh/beta-target/retros" \
    "$box/bin"
  cp "$SUT"               "$box/research-sdd/toolbelt/reconcile-issues.sh"
  cp "$RETRO_STATUS_LIB"  "$box/research-sdd/toolbelt/lib/retro-status.sh"
  cp "$RETRO_GRAMMAR_LIB" "$box/research-sdd/toolbelt/lib/retro-grammar.sh"
  cp "$TARGET_PATHS_LIB"  "$box/research-sdd/toolbelt/lib/target-paths.sh"
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | alpha-target | `%s` |\n' "$box/rh/alpha-target"
    printf '| 2 | beta-target | `%s` |\n'  "$box/rh/beta-target"
  } > "$box/research-sdd/TARGETS.md"
  printf '%s' "$box"
}

# mk_gh_stub <box> [mode]
#   mode=noauth       : gh auth status fails
#   mode=tracked-row1 : issue list echoes a Source retro line for row 1 of r-tracked.md
#   mode=orphaned-row1: issue list echoes a Source retro line for row 1 of r-orphaned.md
#                       (a shipped row, so the script reports orphaned)
#   mode=fail-query   : gh issue list exits non-zero (simulates real gh rejecting bad invocation)
#   mode=nomatch (default): issue list returns empty (all untracked)
mk_gh_stub() {
  local box="$1" mode="${2:-nomatch}"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box"
    printf 'case " $* " in\n'
    if [ "$mode" = "noauth" ]; then
      printf '  *" auth status "*) exit 1 ;;\n'
    else
      printf '  *" auth status "*) exit 0 ;;\n'
    fi
    case "$mode" in
      tracked-row1)
        printf '  *" issue list "*) printf "Source retro: target-foo/retros/r-tracked.md · 1\\n"; exit 0 ;;\n'
        ;;
      orphaned-row1)
        printf '  *" issue list "*) printf "Source retro: target-foo/retros/r-orphaned.md · 1\\n"; exit 0 ;;\n'
        ;;
      fail-query)
        printf '  *" issue list "*) printf "gh: error: use --json when using --jq\\n" >&2; exit 1 ;;\n'
        ;;
      noauth|nomatch)
        printf '  *" issue list "*) exit 0 ;;\n'
        ;;
    esac
    printf '  *) exit 0 ;;\n'
    printf 'esac\n'
  } > "$box/bin/gh"
  chmod +x "$box/bin/gh"
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
mk_gh_stub "$box" nomatch
run "$box" "$box/rh/target-foo/retros/does-not-exist.md"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qi 'absent-input'; then
  ok "1 absent-input: missing retro → exit 1 + absent-input message" "(exit $RC)"
else
  no "1 absent-input: missing retro → exit 1 + absent-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 2 — EMPTY-INPUT: no delta section → empty-input message, exit 0
box="$(mkbox case-empty)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-empty.md "<!-- review-status: pending -->" "-")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'empty-input'; then
  ok "2 empty-input: no delta section → exit 0 + empty-input message" "(exit $RC)"
else
  no "2 empty-input: no delta section → exit 0 + empty-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 3 — NO-MATCH: applied retro, stub returns nothing → no-match, exit 0
box="$(mkbox case-nomatch)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-nomatch.md \
  "<!-- review-status: applied 2026-01-01 · kit abc1234 -->" \
  "| 1 | old delta | METHODOLOGY.md | B1 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'no-match'; then
  ok "3 no-match: applied retro + no issues → exit 0 + no-match message" "(exit $RC)"
else
  no "3 no-match: applied retro + no issues → exit 0 + no-match message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 4 — TRACKED: open row, stub returns matching issue → tracked: in output
box="$(mkbox case-tracked)"
mk_gh_stub "$box" "tracked-row1"
retro="$(mk_retro "$box" target-foo r-tracked.md \
  "<!-- review-status: pending -->" \
  "| 1 | add session cost | CLAUDE.md §5 | B10 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'tracked:'; then
  ok "4 tracked: open row with matching issue → tracked: in output" "(exit $RC)"
else
  no "4 tracked: open row with matching issue → tracked: in output" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 5 — UNTRACKED: open row, stub returns nothing → untracked: in output
box="$(mkbox case-untracked)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-untracked.md \
  "<!-- review-status: pending -->" \
  "| 1 | add session cost | CLAUDE.md §5 | B10 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'untracked:'; then
  ok "5 untracked: open row with no issue → untracked: in output" "(exit $RC)"
else
  no "5 untracked: open row with no issue → untracked: in output" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 6 — ORPHANED: applied retro, stub returns issue for shipped row → orphaned:
box="$(mkbox case-orphaned)"
mk_gh_stub "$box" "orphaned-row1"
retro="$(mk_retro "$box" target-foo r-orphaned.md \
  "<!-- review-status: applied 2026-06-01 · kit deadbeef -->" \
  "| 1 | old shipped delta | METHODOLOGY.md | B1 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'orphaned:'; then
  ok "6 orphaned: shipped row still has open issue → orphaned: in output" "(exit $RC)"
else
  no "6 orphaned: shipped row still has open issue → orphaned: in output" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 7 — DEGRADED: no gh on PATH → non-zero + degraded message
box="$(mkbox case-degraded)"
mk_hermetic_bin "$box"  # essentials only, NO gh
_deg_retro="$(mk_retro "$box" target-foo r-deg.md \
  "<!-- review-status: pending -->" \
  "| 1 | d | CLAUDE.md | B1 | new | HIGH |")"
OUT7="$(PATH="$box/bin" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/reconcile-issues.sh" \
  "$_deg_retro" 2>&1)"; RC7=$?
if [ "$RC7" != 0 ] && printf '%s' "$OUT7" | grep -qi 'degraded'; then
  ok "7 degraded: missing gh → non-zero + degraded message" "(exit $RC7)"
else
  no "7 degraded: missing gh → non-zero + degraded message" "exit=$RC7 out=[$OUT7]"
fi

# ---------------------------------------------------------------------------
# 8 — ALL MODE: 2 fixture targets, each with 1 pending retro → fleet-summary
box="$(mkbox_all case-all)"
mk_gh_stub "$box" nomatch  # all untracked
mk_retro "$box" alpha-target r-alpha.md \
  "<!-- review-status: pending -->" \
  "| 1 | alpha delta | CLAUDE.md §5 | B1 | new | HIGH |" > /dev/null
mk_retro "$box" beta-target r-beta.md \
  "<!-- review-status: pending -->" \
  "| 1 | beta delta | CLAUDE.md §7 | B2 | new | LOW |" > /dev/null
run "$box" --all
fleet_ok=0
printf '%s\n' "$OUT" | grep -qE 'fleet-summary:.*untracked=2' && fleet_ok=1
if [ "$RC" = 0 ] && [ "$fleet_ok" = 1 ]; then
  ok "8 --all: 2 targets, 2 untracked → fleet-summary with untracked=2" "(exit $RC)"
else
  no "8 --all: 2 targets, 2 untracked → fleet-summary with untracked=2" \
    "exit=$RC fleet_ok=$fleet_ok out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9 — JSON-FLAG: gh issue list must be called with --json body (R2-001/R3/R4)
# Pre-fix code uses --template without --json; the stub logs all args so we
# can assert --json body is present in the recorded call.
box="$(mkbox case-json-flag)"
mk_gh_stub "$box" nomatch   # logs args to gh.log; exits 0 on issue list
retro="$(mk_retro "$box" target-foo r-jsonflag.md \
  "<!-- review-status: pending -->" \
  "| 1 | add session cost | CLAUDE.md §5 | B10 | new | HIGH |")"
run "$box" "$retro"
_gh_log_9="$box/bin/gh.log"
_log_contents_9="$(cat "$_gh_log_9" 2>/dev/null)"
if [ -f "$_gh_log_9" ] && grep -qF ' --json body' "$_gh_log_9"; then
  ok "9 json-flag: gh issue list called with --json body" "(exit $RC)"
else
  no "9 json-flag: gh issue list called with --json body" \
    "exit=$RC log=[$_log_contents_9]"
fi

# ---------------------------------------------------------------------------
# 10 — GH-FAIL-DEGRADED: gh query non-zero → non-zero exit + typed degraded:
# Pre-fix code emits WARN, continues with empty bodies, exits 0 with untracked:.
# Post-fix must emit degraded: and exit non-zero (§7 typed-degraded contract).
box="$(mkbox case-ghfail)"
mk_gh_stub "$box" "fail-query"
retro="$(mk_retro "$box" target-foo r-ghfail.md \
  "<!-- review-status: pending -->" \
  "| 1 | add session cost | CLAUDE.md §5 | B10 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -qi 'degraded:'; then
  ok "10 gh-fail-degraded: gh query failure → non-zero + degraded message" "(exit $RC)"
else
  no "10 gh-fail-degraded: gh query failure → non-zero + degraded message" \
    "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# mk_retro3 <box> <target> <filename> <marker>
#   Creates a retro with 3 delta rows (ids 1, 2, 3) for partial-shipped tests.
mk_retro3() {
  local box="$1" tgt="$2" fname="$3" marker="$4"
  local f="$box/rh/$tgt/retros/$fname"
  {
    printf '%s\n' "$marker"
    printf '# retro\n\n## Proposed kit deltas\n\n'
    printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
    printf '|---|---|---|---|---|---|\n'
    printf '| 1 | delta one   | METHODOLOGY.md | B1 | new | HIGH |\n'
    printf '| 2 | delta two   | METHODOLOGY.md | B2 | new | HIGH |\n'
    printf '| 3 | delta three | METHODOLOGY.md | B3 | new | HIGH |\n'
  } > "$f"
  printf '%s' "$f"
}

# ---------------------------------------------------------------------------
# 11 — HASH-SHIPPED: marker uses #N (desc) format; rows 1,2 shipped, row 3 open
# Bug: parser fails to strip leading '#', so shipped_ids has '#1','#2' not '1','2';
# rows 1 and 2 are falsely treated as open and reported as untracked.
# Fix: only row 3 should be reported as untracked.
box="$(mkbox case-hash-shipped)"
mk_gh_stub "$box" nomatch
_hash_marker='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #1 (§11 consumer-absence), #2 (§5 slot-vs-derived) -->'
mk_retro3 "$box" target-foo r-hash-shipped.md "$_hash_marker" > /dev/null
run "$box" "$box/rh/target-foo/retros/r-hash-shipped.md"
_untracked_11=$(printf '%s\n' "$OUT" | grep -c 'untracked: row' 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_11" = "1" ] \
   && printf '%s\n' "$OUT" | grep -qi 'untracked:.*row 3'; then
  ok "11 hash-shipped: #N(desc) → rows 1,2 shipped; only row 3 untracked" \
     "(exit $RC untracked=$_untracked_11)"
else
  no "11 hash-shipped: #N(desc) → rows 1,2 shipped; only row 3 untracked" \
     "exit=$RC untracked=$_untracked_11 out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 12 — BARE-SHIPPED: bare 'shipped: 1, 2' format still marks rows 1,2 shipped
box="$(mkbox case-bare-shipped)"
mk_gh_stub "$box" nomatch
_bare_marker='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: 1, 2 -->'
mk_retro3 "$box" target-foo r-bare-shipped.md "$_bare_marker" > /dev/null
run "$box" "$box/rh/target-foo/retros/r-bare-shipped.md"
_untracked_12=$(printf '%s\n' "$OUT" | grep -c 'untracked: row' 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_12" = "1" ] \
   && printf '%s\n' "$OUT" | grep -qi 'untracked:.*row 3'; then
  ok "12 bare-shipped: '1, 2' format → rows 1,2 shipped; only row 3 untracked" \
     "(exit $RC untracked=$_untracked_12)"
else
  no "12 bare-shipped: '1, 2' format → rows 1,2 shipped; only row 3 untracked" \
     "exit=$RC untracked=$_untracked_12 out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 13 — PREFIX-SHIPPED: 'shipped: D1, D2' format (prefixed ids) still works
box="$(mkbox case-prefix-shipped)"
mk_gh_stub "$box" nomatch
{
  printf '%s\n' '<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: D1, D2 -->'
  printf '# retro\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| D1 | delta one   | METHODOLOGY.md | B1 | new | HIGH |\n'
  printf '| D2 | delta two   | METHODOLOGY.md | B2 | new | HIGH |\n'
  printf '| D3 | delta three | METHODOLOGY.md | B3 | new | HIGH |\n'
} > "$box/rh/target-foo/retros/r-prefix-shipped.md"
run "$box" "$box/rh/target-foo/retros/r-prefix-shipped.md"
_untracked_13=$(printf '%s\n' "$OUT" | grep -c 'untracked: row' 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_13" = "1" ] \
   && printf '%s\n' "$OUT" | grep -qi 'untracked:.*D3'; then
  ok "13 prefix-shipped: 'D1, D2' format → D1,D2 shipped; only D3 untracked" \
     "(exit $RC untracked=$_untracked_13)"
else
  no "13 prefix-shipped: 'D1, D2' format → D1,D2 shipped; only D3 untracked" \
     "exit=$RC untracked=$_untracked_13 out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 14 — SINGLE-HASH: single 'shipped: #5 (some trailing text)' → row 5 shipped
box="$(mkbox case-single-hash)"
mk_gh_stub "$box" nomatch
{
  printf '%s\n' '<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #5 (some trailing text) -->'
  printf '# retro\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| 5 | delta five | METHODOLOGY.md | B5 | new | HIGH |\n'
  printf '| 6 | delta six  | METHODOLOGY.md | B6 | new | HIGH |\n'
} > "$box/rh/target-foo/retros/r-single-hash.md"
run "$box" "$box/rh/target-foo/retros/r-single-hash.md"
_untracked_14=$(printf '%s\n' "$OUT" | grep -c 'untracked: row' 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_14" = "1" ] \
   && printf '%s\n' "$OUT" | grep -qi 'untracked:.*row 6'; then
  ok "14 single-hash: '#5 (desc)' format → row 5 shipped; only row 6 untracked" \
     "(exit $RC untracked=$_untracked_14)"
else
  no "14 single-hash: '#5 (desc)' format → row 5 shipped; only row 6 untracked" \
     "exit=$RC untracked=$_untracked_14 out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 15 — CACHE-UNTRACKED: --issues-cache given; cache has no matching signature → untracked, exit 0
# Assert: gh is NOT invoked (the fail-if-called stub exits 1 if reached; gh.log stays empty).
box15="$(mkbox case-cache-untracked)"
{
  printf '#!%s\n' "$BASH_BIN"
  printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box15"
  printf 'exit 1\n'
} > "$box15/bin/gh"
chmod +x "$box15/bin/gh"
# Cache file: contains an issue body with a DIFFERENT retro's signature (not this retro)
_cache15="$ROOT/cache15.txt"
printf 'Source retro: other-target/retros/other.md · 1\n' > "$_cache15"
retro15="$(mk_retro "$box15" target-foo r-cache-untracked.md \
  "<!-- review-status: pending -->" \
  "| 1 | test delta | CLAUDE.md | B1 | new | HIGH |")"
run "$box15" --issues-cache "$_cache15" "$retro15"
_gh_calls_15="$(wc -l < "$box15/bin/gh.log" 2>/dev/null | tr -d ' ')"
_gh_calls_15="${_gh_calls_15:-0}"  # missing log → 0 calls (gh was never invoked)
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'untracked:' \
   && [ "$_gh_calls_15" = "0" ]; then
  ok "15 cache-untracked: cache with no matching sig → untracked, exit 0, no gh call" \
     "(exit $RC gh_calls=${_gh_calls_15})"
else
  no "15 cache-untracked: expected untracked exit 0 no-gh" \
     "exit=$RC out=[$OUT] gh_calls=${_gh_calls_15}"
fi

# ---------------------------------------------------------------------------
# 16 — CACHE-TRACKED: --issues-cache given; cache has exact matching signature → tracked, exit 0
# Assert: gh is NOT invoked (same fail-if-called stub pattern).
box16="$(mkbox case-cache-tracked)"
{
  printf '#!%s\n' "$BASH_BIN"
  printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box16"
  printf 'exit 1\n'
} > "$box16/bin/gh"
chmod +x "$box16/bin/gh"
# Cache file: issue body WITH the exact signature for this retro and row 1
# sig_prefix = target-foo/retros/r-cache-tracked.md
_cache16="$ROOT/cache16.txt"
printf 'Source retro: target-foo/retros/r-cache-tracked.md · 1\n' > "$_cache16"
retro16="$(mk_retro "$box16" target-foo r-cache-tracked.md \
  "<!-- review-status: pending -->" \
  "| 1 | test delta | CLAUDE.md | B1 | new | HIGH |")"
run "$box16" --issues-cache "$_cache16" "$retro16"
_gh_calls_16="$(wc -l < "$box16/bin/gh.log" 2>/dev/null | tr -d ' ')"
_gh_calls_16="${_gh_calls_16:-0}"  # missing log → 0 calls (gh was never invoked)
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^tracked:' \
   && [ "$_gh_calls_16" = "0" ]; then
  ok "16 cache-tracked: cache with matching sig → tracked, exit 0, no gh call" \
     "(exit $RC gh_calls=${_gh_calls_16})"
else
  no "16 cache-tracked: expected tracked exit 0 no-gh" \
     "exit=$RC out=[$OUT] gh_calls=${_gh_calls_16}"
fi

# ---------------------------------------------------------------------------
# 17 — T-CACHE-METACHAR: metachar in sig_prefix (dot in target name) must not cause false match.
# target name "target-v2.foo" has a literal dot; cache contains "target-v2Xfoo/retros/r.md · 1"
# (X matches '.' in an extended regex but NOT as a fixed string).
# With fixed-string grep: row 1 is UNTRACKED (no literal match); row 2 IS tracked (exact match).
# A regex-based grep would false-match row 1 as tracked.
box17="$(mkbox T-CACHE-METACHAR target-v2.foo)"
{
  printf '#!%s\n' "$BASH_BIN"
  printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box17"
  printf 'exit 1\n'
} > "$box17/bin/gh"
chmod +x "$box17/bin/gh"
_cache17="$ROOT/cache17.txt"
# False-match body: dot replaced by 'X' — regex '.' matches X, fixed string does not.
printf 'Source retro: target-v2Xfoo/retros/r-meta.md · 1\n' > "$_cache17"
# True-match body: exact literal dot — fixed string must match this.
printf 'Source retro: target-v2.foo/retros/r-meta.md · 2\n' >> "$_cache17"
retro17="$(mk_retro "$box17" "target-v2.foo" "r-meta.md" \
  "<!-- review-status: pending -->" \
  "| 1 | delta-a | CLAUDE.md | B1 | new | HIGH |
| 2 | delta-b | CLAUDE.md | B2 | new | HIGH |")"
run "$box17" --issues-cache "$_cache17" "$retro17"
_meta_untracked="$(printf '%s\n' "$OUT" | grep -c '^untracked:' 2>/dev/null || echo 0)"
_meta_tracked="$(printf '%s\n' "$OUT" | grep -c '^tracked:' 2>/dev/null || echo 0)"
# row 1 must be untracked (no literal-dot match); row 2 must be tracked (exact match).
if [ "$RC" = 0 ] && [ "${_meta_untracked:-0}" = "1" ] && [ "${_meta_tracked:-0}" = "1" ]; then
  ok "17 T-CACHE-METACHAR: metachar prefix → row 1 untracked (no false match), row 2 tracked (exact match)" \
     "(untracked=${_meta_untracked} tracked=${_meta_tracked})"
else
  no "17 T-CACHE-METACHAR: expected 1 untracked + 1 tracked" \
     "exit=$RC untracked=${_meta_untracked} tracked=${_meta_tracked} out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# kit issue #1024 round 3, MEDIUM: symlinked toolbelt (render dir)
# ---------------------------------------------------------------------------
# KIT_ROOT used to be derived via `cd "$_SCRIPT_DIR/../.."` WITHOUT -P. bash's default (-L,
# logical) $PWD tracking resolves ".." against the STRING it cd'd into, not the physical
# filesystem — so when the FIRST cd lands on a symlinked toolbelt/ (as installed for a non-claude
# profile's render dir, kit issue #993 WU2 + #1024 F1), the symlink component is never "spent":
# the SECOND ".." cancels it out lexically and lands one level short of the real kit root, inside
# .../research-sdd/profile/ instead of .../research-sdd/. Reproduced against the pre-fix SUT:
# `TARGETS_MD` then pointed at .../profile/research-sdd/TARGETS.md, which does not exist.
box_sym="$(mkbox symlink-toolbelt)"
mkdir -p "$box_sym/research-sdd/profile/general"
ln -s "$box_sym/research-sdd/toolbelt" "$box_sym/research-sdd/profile/general/toolbelt"
OUT_SYM="$(PATH="$box_sym/bin:$PATH" "$BASH_BIN" \
  "$box_sym/research-sdd/profile/general/toolbelt/reconcile-issues.sh" --all 2>&1)"; RC_SYM=$?
if [ "$RC_SYM" -eq 0 ] && ! printf '%s' "$OUT_SYM" | grep -qi 'absent-input.*TARGETS\.md'; then
  ok "SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/, still resolves the real TARGETS.md" \
     "(rc=$RC_SYM)"
else
  no "SYMLINK-TOOLBELT: TARGETS.md not found through a symlinked toolbelt/" "(rc=$RC_SYM out=[$OUT_SYM])"
fi

# ---------------------------------------------------------------------------
# TEETH (negative controls for --prove-teeth)
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  # Mutation strategy: use sed to replace the line AFTER each anchor comment.
  # All sed mutations are applied to a fresh copy of the SUT so mutations
  # do not interfere with each other.

  # TOOTH T1: Neuter the tracked detection condition.
  # The anchor comment line immediately precedes the if-condition that decides
  # whether a row-id is tracked.  Replacing the following line with
  # `      if false; then` makes every open row report as untracked instead.
  echo "-- teeth T1: neuter tracked detection condition --"
  anchor_t1='RECONCILE_ISSUES_TRACKED_CHECK:'
  if grep -q "$anchor_t1" "$SUT"; then
    box_t1="$(mkbox teeth-tracked)"
    mk_gh_stub "$box_t1" "tracked-row1"
    retro_t1="$(mk_retro "$box_t1" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | tracked delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t1="$box_t1/research-sdd/toolbelt/reconcile-issues.sh"
    # Replace the line after the anchor with `if false; then`
    sed "/${anchor_t1}/{ n; s/.*/      if false; then/ }" "$SUT" > "$mutant_t1"
    out_t1="$(PATH="$box_t1/bin:$PATH" \
      "$BASH_BIN" "$mutant_t1" "$retro_t1" 2>&1)"; rc_t1=$?
    if ! printf '%s\n' "$out_t1" | grep -qi '^tracked:' \
       && printf '%s\n' "$out_t1" | grep -qi 'untracked:'; then
      ok "T1 teeth: tracked condition neutered → row shows as untracked (case 4 has teeth)" "()"
    else
      no "T1 teeth: tracked condition neutered → row should show as untracked" \
        "case 4 may be THEATER: rc=$rc_t1 out=[$out_t1]"
    fi
  else
    no "T1 teeth: locate tracked check anchor" "anchor '$anchor_t1' not found in SUT"
  fi

  # TOOTH T2: Neuter the untracked emit.
  # The anchor comment line immediately precedes the printf that emits 'untracked:'.
  # Replacing that line with a no-op means case 5 sees no 'untracked:' output.
  echo "-- teeth T2: neuter untracked emit --"
  anchor_t2='RECONCILE_ISSUES_UNTRACKED_EMIT:'
  if grep -q "$anchor_t2" "$SUT"; then
    box_t2="$(mkbox teeth-untracked)"
    mk_gh_stub "$box_t2" nomatch
    retro_t2="$(mk_retro "$box_t2" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | untracked delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t2="$box_t2/research-sdd/toolbelt/reconcile-issues.sh"
    # Replace the printf 'untracked:...' line with a no-op
    sed "/${anchor_t2}/{ n; s/.*/        : # teeth-t2-untracked-emit-removed/ }" \
      "$SUT" > "$mutant_t2"
    out_t2="$(PATH="$box_t2/bin:$PATH" \
      "$BASH_BIN" "$mutant_t2" "$retro_t2" 2>&1)"; rc_t2=$?
    if ! printf '%s\n' "$out_t2" | grep -qi 'untracked:'; then
      ok "T2 teeth: untracked emit neutered → no untracked: output (case 5 has teeth)" "()"
    else
      no "T2 teeth: untracked emit neutered → should not see untracked:" \
        "case 5 may be THEATER: rc=$rc_t2 out=[$out_t2]"
    fi
  else
    no "T2 teeth: locate untracked emit anchor" "anchor '$anchor_t2' not found in SUT"
  fi

  # TOOTH T3: Neuter the orphaned detection condition.
  # The anchor comment precedes the if-condition that checks whether an issue
  # row-id is absent from the open delta set.  `if false; then` disables it.
  echo "-- teeth T3: neuter orphaned detection condition --"
  anchor_t3='RECONCILE_ISSUES_ORPHANED_CHECK:'
  if grep -q "$anchor_t3" "$SUT"; then
    box_t3="$(mkbox teeth-orphaned)"
    mk_gh_stub "$box_t3" "orphaned-row1"
    retro_t3="$(mk_retro "$box_t3" target-foo r-orphaned.md \
      "<!-- review-status: applied 2026-06-01 · kit deadbeef -->" \
      "| 1 | old delta | METHODOLOGY.md | B1 | new | HIGH |")"
    mutant_t3="$box_t3/research-sdd/toolbelt/reconcile-issues.sh"
    sed "/${anchor_t3}/{ n; s/.*/      if false; then/ }" "$SUT" > "$mutant_t3"
    out_t3="$(PATH="$box_t3/bin:$PATH" \
      "$BASH_BIN" "$mutant_t3" "$retro_t3" 2>&1)"; rc_t3=$?
    if ! printf '%s\n' "$out_t3" | grep -qi 'orphaned:'; then
      ok "T3 teeth: orphaned condition neutered → no orphaned: output (case 6 has teeth)" "()"
    else
      no "T3 teeth: orphaned condition neutered → should not see orphaned:" \
        "case 6 may be THEATER: rc=$rc_t3 out=[$out_t3]"
    fi
  else
    no "T3 teeth: locate orphaned check anchor" "anchor '$anchor_t3' not found in SUT"
  fi

  # TOOTH T4: Neuter the --json body flag (simulate pre-fix invocation).
  # Replace --json body with --json number so the logged call no longer contains
  # the exact ' --json body' string that case 9 asserts.
  echo "-- teeth T4: neuter --json body flag --"
  if grep -qF ' --json body' "$SUT"; then
    box_t4="$(mkbox teeth-json-flag)"
    mk_gh_stub "$box_t4" nomatch
    retro_t4="$(mk_retro "$box_t4" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | test delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t4="$box_t4/research-sdd/toolbelt/reconcile-issues.sh"
    sed 's/--json body/--json number/' "$SUT" > "$mutant_t4"
    PATH="$box_t4/bin:$PATH" \
      "$BASH_BIN" "$mutant_t4" "$retro_t4" >/dev/null 2>&1
    _log_t4="$box_t4/bin/gh.log"
    if ! grep -qF ' --json body' "$_log_t4" 2>/dev/null; then
      ok "T4 teeth: --json body neutered → log no longer has --json body (case 9 has teeth)" "()"
    else
      no "T4 teeth: --json body neutered → log should not have --json body" \
        "case 9 may be THEATER: log=[$( cat "$_log_t4" 2>/dev/null )]"
    fi
  else
    no "T4 teeth: locate --json body in SUT" "'--json body' not found in SUT"
  fi

  # TOOTH T5: Neuter the degraded return on gh query failure.
  # Anchor RECONCILE_ISSUES_GH_DEGRADED_RETURN: immediately precedes return 1.
  # Replacing return 1 with a no-op means case 10 sees exit 0 instead of non-zero.
  echo "-- teeth T5: neuter degraded return --"
  anchor_t5='RECONCILE_ISSUES_GH_DEGRADED_RETURN:'
  if grep -q "$anchor_t5" "$SUT"; then
    box_t5="$(mkbox teeth-ghfail)"
    mk_gh_stub "$box_t5" "fail-query"
    retro_t5="$(mk_retro "$box_t5" target-foo r-ghfail.md \
      "<!-- review-status: pending -->" \
      "| 1 | test delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t5="$box_t5/research-sdd/toolbelt/reconcile-issues.sh"
    sed "/${anchor_t5}/{ n; s/.*/    : # teeth-t5-degraded-return-removed/ }" \
      "$SUT" > "$mutant_t5"
    out_t5="$(PATH="$box_t5/bin:$PATH" \
      "$BASH_BIN" "$mutant_t5" "$retro_t5" 2>&1)"; rc_t5=$?
    # Test 10 passes on (RC!=0 AND degraded: present). Tooth passes if mutant exits 0.
    if [ "$rc_t5" -eq 0 ]; then
      ok "T5 teeth: degraded return neutered → exit 0 (case 10 has teeth)" "()"
    else
      no "T5 teeth: degraded return neutered → should exit 0" \
        "case 10 may be THEATER: rc=$rc_t5 out=[$out_t5]"
    fi
  else
    no "T5 teeth: locate degraded return anchor" "anchor '$anchor_t5' not found in SUT"
  fi

  # TOOTH T6: Neuter the RECONCILE_ISSUES_HASH_STRIP # strip.
  # Replace `sub(/^#/, "", t)` with a no-op so #N ids are no longer stripped;
  # case 11's hash marker then produces untracked=3 (all rows open) instead of 1.
  echo "-- teeth T6: neuter hash-strip sub --"
  anchor_t6='RECONCILE_ISSUES_HASH_STRIP:'
  if grep -q "$anchor_t6" "$SUT"; then
    box_t6="$(mkbox teeth-hash-strip)"
    mk_gh_stub "$box_t6" nomatch
    _hash_m_t6='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #1 (§11 desc), #2 (§5 desc) -->'
    mk_retro3 "$box_t6" target-foo r-t6.md "$_hash_m_t6" > /dev/null
    mutant_t6="$box_t6/research-sdd/toolbelt/reconcile-issues.sh"
    # Comment out the sub(/^#/…) line that follows the anchor
    sed "/${anchor_t6}/{ n; s/.*sub.*#.*/              # teeth-t6-hash-strip-removed/ }" \
      "$SUT" > "$mutant_t6"
    out_t6="$(PATH="$box_t6/bin:$PATH" \
      "$BASH_BIN" "$mutant_t6" "$box_t6/rh/target-foo/retros/r-t6.md" 2>&1)"; rc_t6=$?
    _ut6=$(printf '%s\n' "$out_t6" | grep -c 'untracked: row' 2>/dev/null || true)
    # Fix: untracked=1 (only row 3). Mutant: untracked=3 (all rows, # not stripped).
    if [ "$_ut6" -gt 1 ]; then
      ok "T6 teeth: hash-strip neutered → untracked>1 (case 11 has teeth)" \
         "(untracked=$_ut6)"
    else
      no "T6 teeth: hash-strip neutered → should see untracked>1" \
         "case 11 may be THEATER: rc=$rc_t6 untracked=$_ut6 out=[$out_t6]"
    fi
  else
    no "T6 teeth: locate hash-strip anchor" "anchor '$anchor_t6' not found in SUT"
  fi

  # TOOTH T-CACHE-NO-GH: neuter the CACHE_BRANCH condition → --issues-cache ignored; gh called instead.
  # A recording gh that SUCCEEDS (logs calls + exits 0, returns no bodies → untracked) is used so
  # the mutant can run to completion; then assert the gh log is NON-empty (gh was called).
  echo "-- teeth T-CACHE-NO-GH: neuter cache branch → gh called despite --issues-cache --"
  anchor_tcng='RECONCILE_ISSUES_CACHE_BRANCH:'
  if grep -q "$anchor_tcng" "$SUT"; then
    box_tcng="$(mkbox teeth-cache-no-gh)"
    # Recording gh that succeeds: logs every call, returns empty issue list (untracked)
    {
      printf '#!%s\n' "$BASH_BIN"
      printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box_tcng"
      printf 'case " $* " in\n'
      printf '  *" auth status "*) exit 0 ;;\n'
      printf '  *" issue list "*) exit 0 ;;\n'
      printf '  *) exit 0 ;;\n'
      printf 'esac\n'
    } > "$box_tcng/bin/gh"
    chmod +x "$box_tcng/bin/gh"
    _cache_tcng="$ROOT/cache-tcng.txt"
    printf 'Source retro: target-foo/retros/r-tcng.md · 1\n' > "$_cache_tcng"
    retro_tcng="$(mk_retro "$box_tcng" target-foo r-tcng.md \
      "<!-- review-status: pending -->" \
      "| 1 | test delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_tcng="$box_tcng/research-sdd/toolbelt/reconcile-issues.sh"
    # Mutant: replace the line AFTER the anchor with `if false; then` (disables cache branch)
    sed "/${anchor_tcng}/{ n; s/.*/  if false; then  # MUTANT-CACHE-BRANCH-DISABLED/ }" \
      "$SUT" > "$mutant_tcng"
    PATH="$box_tcng/bin:$PATH" \
      "$BASH_BIN" "$mutant_tcng" --issues-cache "$_cache_tcng" "$retro_tcng" >/dev/null 2>&1 || true
    _gh_calls_tcng="$(grep -c 'issue list' "$box_tcng/bin/gh.log" 2>/dev/null || echo 0)"
    if [ "${_gh_calls_tcng:-0}" -gt 0 ]; then
      ok "T-CACHE-NO-GH teeth: cache branch neutered → gh issue list WAS called (cache-path has teeth)" \
         "(gh_calls=${_gh_calls_tcng})"
    else
      no "T-CACHE-NO-GH teeth: cache branch neutered → gh should have been called" \
         "cases 15/16 may be THEATER: gh_calls=${_gh_calls_tcng}"
    fi
  else
    no "T-CACHE-NO-GH teeth: locate cache branch anchor" "anchor '$anchor_tcng' not found in SUT"
  fi

  # TOOTH T-CACHE-METACHAR: revert fixed-string grep to extended-regex → dot metachar false match.
  # Mutant: changes "grep -F" to "grep -E" in the sigprefix filter line.
  # With -E, '.' in "target-v2.foo" matches 'X' in "target-v2Xfoo" → row 1 false-matched as tracked.
  # T-CACHE-METACHAR expects row 1 untracked; mutant makes both rows tracked → assertion fails → RED.
  echo "-- teeth T-CACHE-METACHAR: grep -F → grep -E causes false metachar match → both rows tracked --"
  anchor_tmc='RECONCILE_ISSUES_CACHE_SIGPREFIX_MATCH:'
  if grep -q "$anchor_tmc" "$SUT" && grep -q 'grep -F "Source retro:' "$SUT"; then
    box_tmc="$(mkbox teeth-cache-metachar target-v2.foo)"
    {
      printf '#!%s\n' "$BASH_BIN"
      printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box_tmc"
      printf 'exit 1\n'
    } > "$box_tmc/bin/gh"
    chmod +x "$box_tmc/bin/gh"
    _cache_tmc="$ROOT/cache-tmc.txt"
    printf 'Source retro: target-v2Xfoo/retros/r-tmc.md · 1\n' > "$_cache_tmc"
    printf 'Source retro: target-v2.foo/retros/r-tmc.md · 2\n' >> "$_cache_tmc"
    retro_tmc="$(mk_retro "$box_tmc" "target-v2.foo" "r-tmc.md" \
      "<!-- review-status: pending -->" \
      "| 1 | delta-a | CLAUDE.md | B1 | new | HIGH |
| 2 | delta-b | CLAUDE.md | B2 | new | HIGH |")"
    mutant_tmc="$box_tmc/research-sdd/toolbelt/reconcile-issues.sh"
    # Mutant: replace 'grep -F "Source retro:' with 'grep -E "Source retro:' directly.
    # The rest of the pipeline (sed + grep-oE) is unchanged; only the filter step loses fixed-string.
    sed 's/grep -F "Source retro:/grep -E "Source retro:/' "$SUT" > "$mutant_tmc"
    if grep -q 'grep -E "Source retro:' "$mutant_tmc" && \
       ! grep -q 'grep -F "Source retro:' "$mutant_tmc"; then
      out_tmc="$(PATH="$box_tmc/bin:$PATH" \
        "$BASH_BIN" "$mutant_tmc" --issues-cache "$_cache_tmc" "$retro_tmc" 2>&1)" || true
      _tmc_tracked="$(printf '%s\n' "$out_tmc" | grep -c '^tracked:' 2>/dev/null)"
      _tmc_untracked="$(printf '%s\n' "$out_tmc" | grep -c '^untracked:' 2>/dev/null)"
      # With -E mutant: row 1 is false-matched as tracked (dot matches X) → tracked≥2, untracked=0.
      # T-CACHE-METACHAR assertion "row 1 untracked" would fail → RED.
      if [ "${_tmc_tracked:-0}" -ge 2 ] && [ "${_tmc_untracked:-0}" -eq 0 ]; then
        ok "T-CACHE-METACHAR teeth: -E mutant false-matches row 1 → both rows tracked → T-CACHE-METACHAR has teeth" \
           "(tracked=${_tmc_tracked} untracked=${_tmc_untracked})"
      else
        no "T-CACHE-METACHAR teeth: -E mutant result unexpected (tracked=${_tmc_tracked} untracked=${_tmc_untracked}) — THEATER or fixture broken"
      fi
    else
      no "T-CACHE-METACHAR teeth: sed mutant did not swap grep -F to grep -E — tooth invalid"
    fi
  else
    no "T-CACHE-METACHAR teeth: anchor or grep -F sentinel not found in SUT"
  fi

  # TOOTH SYMLINK-TOOLBELT: revert -P/pwd -P to plain cd/pwd (kit issue #1024 round 3, MEDIUM).
  echo "-- teeth SYMLINK-TOOLBELT: revert -P to plain cd/pwd --"
  box_tsym="$(mkbox teeth-symlink-toolbelt)"
  mutant_tsym="$box_tsym/research-sdd/toolbelt/reconcile-issues.sh"
  sed -e 's/cd -P "\$(dirname "\$0")" \&\& pwd -P/cd "$(dirname "$0")" \&\& pwd/' \
      -e 's/cd -P "\$_SCRIPT_DIR\/\.\.\/\.\." \&\& pwd -P/cd "$_SCRIPT_DIR\/..\/.." \&\& pwd/' \
      "$SUT" > "$mutant_tsym"
  if diff -q "$SUT" "$mutant_tsym" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: mutant = SUT — -P pattern not found"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: mutant differs (-P reverted to plain cd/pwd)"
  fi
  mkdir -p "$box_tsym/research-sdd/profile/general"
  ln -s "$box_tsym/research-sdd/toolbelt" "$box_tsym/research-sdd/profile/general/toolbelt"
  out_tsym="$(PATH="$box_tsym/bin:$PATH" "$BASH_BIN" \
    "$box_tsym/research-sdd/profile/general/toolbelt/reconcile-issues.sh" --all 2>&1)"; rc_tsym=$?
  if [ "$rc_tsym" -ne 0 ] && printf '%s' "$out_tsym" | grep -qi 'absent-input.*TARGETS\.md'; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant re-breaks through a symlinked toolbelt/ → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant still resolved TARGETS.md — -P fix check is THEATER" \
       "(rc=$rc_tsym out=[$out_tsym])"
  fi

fi  # --prove-teeth

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
