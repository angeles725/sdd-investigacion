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
      lines)
        # kit issue #1304: `lines` replies with the text in $3 ONLY to a `gh issue list` whose
        # --search text contains $4 (empty = every call), so a test can prove WHICH signature
        # (new vs legacy) a query carried. Any other list call sees an empty result.
        printf '  *" issue list "*"%s"*) printf "%%s\\n" "%s"; exit 0 ;;\n' "${4:-}" "${3:-}"
        printf '  *" issue list "*) exit 0 ;;\n'
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

# mk_open_retro <path>: a pending retro with ONE open row; creates parent dirs; echoes the path.
mk_open_retro() {
  mkdir -p "$(dirname "$1")"
  {
    printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
    printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
    printf '| 1 | a delta | CLAUDE.md | B1 | fix | HIGH |\n'
  } > "$1"
  printf '%s' "$1"
}
# mk_targets <box> <name> <path-token> [<name2> <path-token2>]: rewrite the box's TARGETS.md.
mk_targets() {
  local box="$1"
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | %s | `%s` |\n' "$2" "$3"
    [ -z "${4:-}" ] || printf '| 2 | %s | `%s` |\n' "$4" "$5"
  } > "$box/research-sdd/TARGETS.md"
}
# cache_for <file> <name> <retro-basename> [<row>]: a cache holding exactly one signature line.
cache_for() { printf 'Source retro: %s/retros/%s · %s\n' "$2" "$3" "${4:-1}" > "$1"; }
echo "== reconcile-issues.test.sh =="

# ---------------------------------------------------------------------------
# 1 — ABSENT-INPUT: retro file not found → absent-input message, exit 1
box="$(mkbox case-absent)"
mk_gh_stub "$box" nomatch
run "$box" "$box/rh/target-foo/retros/does-not-exist.md"
if [ "$RC" = 1 ] && grep -qi 'absent-input' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -qi 'empty-input' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -qi 'no-match' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -qi 'tracked:' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -qi 'untracked:' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -qi 'orphaned:' <<<"$OUT"; then
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
if [ "$RC7" != 0 ] && grep -qi 'degraded' <<<"$OUT7"; then
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
grep -qE 'fleet-summary:.*untracked=2' <<<"$OUT" && fleet_ok=1
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
if [ "$RC" != 0 ] && grep -qi 'degraded:' <<<"$OUT"; then
  ok "10 gh-fail-degraded: gh query failure → non-zero + degraded message" "(exit $RC)"
else
  no "10 gh-fail-degraded: gh query failure → non-zero + degraded message" \
    "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 10b — OUT-OF-SCOPE MARKER (kit issue #1099; exit code revised by #1125 item 3): a marker
# positioned after a SECOND heading is outside the shared #945 scope. Before #1099 this was
# silently conflated with "no marker at all" (status "") and every row was reported untracked —
# a classification bug, not just a missed report. #1099 makes this fail CLOSED instead: refuse
# to classify, report loudly under the typed 'out-of-scope-marker:' reason. #1125 item 3: this
# is a CORPUS finding (the retro's own marker is mispositioned), not an operational failure of
# reconcile-issues.sh — per CLAUDE.md §8 a finding is WARN-only and exits 0, the same rule every
# other typed state here already follows (empty-input, unclassifiable, …). Before #1125 this
# `return 1`ed into the SAME degraded= bucket as a real gh-query failure, so under --all a single
# mispositioned marker anywhere in the fleet made the whole run exit 1 — indistinguishable from
# the instrument itself being broken.
box="$(mkbox case-oos)"
mk_gh_stub "$box" nomatch
retro_oos="$box/rh/target-foo/retros/r-oos.md"
{
  printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| 1 | old delta | METHODOLOGY.md | B1 | new | HIGH |\n'
} > "$retro_oos"
run "$box" "$retro_oos"
if [ "$RC" = 0 ] && grep -qi '^out-of-scope-marker:' <<<"$OUT" \
  && ! grep -qi 'untracked:\|tracked:\|orphaned:' <<<"$OUT"; then
  ok "10b out-of-scope-marker: marker after a SECOND heading → refuses to classify, exit 0 (finding, not failure — #1099/#1125)" "(exit $RC)"
else
  no "10b out-of-scope-marker: marker after a SECOND heading → refuses to classify, exit 0 (finding, not failure — #1099/#1125)" \
    "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 10d — OUT-OF-SCOPE MARKER under --all (kit issue #1125 item 3): the out-of-scope-marker
# finding must be counted separately as out-of-scope= in the fleet-summary line, and must NOT
# push _fleet_degraded above zero — proving the finding stays visible without gating the exit
# code of the whole fleet run.
box="$(mkbox case-oos-all)"
mk_gh_stub "$box" nomatch
retro_oos_all="$box/rh/target-foo/retros/r-oos.md"
{
  printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| 1 | old delta | METHODOLOGY.md | B1 | new | HIGH |\n'
} > "$retro_oos_all"
run "$box" "--all"
if [ "$RC" = 0 ] && grep -qE 'fleet-summary:.*degraded=0.*out-of-scope=1' <<<"$OUT"; then
  ok "10d --all: out-of-scope-marker counted separately, degraded stays 0, exit 0" "(exit $RC)"
else
  no "10d --all: out-of-scope-marker counted separately, degraded stays 0, exit 0" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 10c — REGRESSION GUARD: genuinely no marker at all must stay the ordinary pending/open case
# (untracked:), NOT be misclassified as out-of-scope-marker.
box="$(mkbox case-oos-absent)"
mk_gh_stub "$box" nomatch
retro_absent="$(mk_retro "$box" target-foo r-no-marker.md "-" \
  "| 1 | add session cost | CLAUDE.md §5 | B10 | new | HIGH |")"
run "$box" "$retro_absent"
if [ "$RC" = 0 ] && grep -qi 'untracked:' <<<"$OUT" \
  && ! grep -qi '^out-of-scope-marker:' <<<"$OUT"; then
  ok "10c genuinely markerless retro → still untracked, NOT out-of-scope-marker" "(exit $RC)"
else
  no "10c genuinely markerless retro → still untracked, NOT out-of-scope-marker" "exit=$RC out=[$OUT]"
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
_untracked_11=$(grep -c 'untracked: row' <<<"$OUT" 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_11" = "1" ] \
   && grep -qi 'untracked:.*row 3' <<<"$OUT"; then
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
_untracked_12=$(grep -c 'untracked: row' <<<"$OUT" 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_12" = "1" ] \
   && grep -qi 'untracked:.*row 3' <<<"$OUT"; then
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
_untracked_13=$(grep -c 'untracked: row' <<<"$OUT" 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_13" = "1" ] \
   && grep -qi 'untracked:.*D3' <<<"$OUT"; then
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
_untracked_14=$(grep -c 'untracked: row' <<<"$OUT" 2>/dev/null || true)
if [ "$RC" = 0 ] && [ "$_untracked_14" = "1" ] \
   && grep -qi 'untracked:.*row 6' <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q 'untracked:' <<<"$OUT" \
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
if [ "$RC" = 0 ] && grep -q '^tracked:' <<<"$OUT" \
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
_meta_untracked="$(grep -c '^untracked:' <<<"$OUT" 2>/dev/null || echo 0)"
_meta_tracked="$(grep -c '^tracked:' <<<"$OUT" 2>/dev/null || echo 0)"
# row 1 must be untracked (no literal-dot match); row 2 must be tracked (exact match).
if [ "$RC" = 0 ] && [ "${_meta_untracked:-0}" = "1" ] && [ "${_meta_tracked:-0}" = "1" ]; then
  ok "17 T-CACHE-METACHAR: metachar prefix → row 1 untracked (no false match), row 2 tracked (exact match)" \
     "(untracked=${_meta_untracked} tracked=${_meta_tracked})"
else
  no "17 T-CACHE-METACHAR: expected 1 untracked + 1 tracked" \
     "exit=$RC untracked=${_meta_untracked} tracked=${_meta_tracked} out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# kit issue #1090 — PARTIAL is a status TOKEN, never free text; dismissed always wins.
# ---------------------------------------------------------------------------

# 18 — REAL #1090 REPRO MARKER (verbatim): a dismissed marker whose free-text explanation
# mentions 'partial' in lowercase prose must yield ZERO open (untracked) rows, never all 7.
box18="$(mkbox case-1090-repro)"
mk_gh_stub "$box18" nomatch
retro18="$(mk_retro "$box18" target-foo r-1090-repro.md \
  "<!-- review-status: dismissed 2026-09-20 · scoped to build-n4-module kit — deltas owned + implemented there (D1-D5 orient-guard, P3/P4/P5; P1 partial) -->" \
  "$(printf '| 1 | delta one | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | delta two | METHODOLOGY.md | B2 | new | HIGH |')")"
run "$box18" "$retro18"
if [ "$RC" = 0 ] && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "18 #1090 real repro marker: dismissed + prose 'partial' → zero untracked rows" "(exit $RC)"
else
  no "18 #1090 real repro marker: dismissed + prose 'partial' → zero untracked rows" "exit=$RC out=[$OUT]"
fi

# 19 — PROSE 'partial' POSITION (first/middle/last) on a DISMISSED marker never trips
# PARTIAL handling.
_pos19=0
for pos in first middle last; do
  _pos19=$((_pos19+1))
  case "$pos" in
    first)  _prose19="partial rollback only — see the linked ticket for the rest" ;;
    middle) _prose19="deltas partial in scope, the remainder tracked elsewhere" ;;
    last)   _prose19="deltas owned and implemented elsewhere (partial)" ;;
  esac
  box19="$(mkbox "case-1090-prose-$pos")"
  mk_gh_stub "$box19" nomatch
  retro19="$(mk_retro "$box19" target-foo r-1090-prose.md \
    "<!-- review-status: dismissed 2026-09-20 · kit deadbeef — ${_prose19} -->" \
    "| 1 | delta one | METHODOLOGY.md | B1 | new | HIGH |")"
  run "$box19" "$retro19"
  if [ "$RC" = 0 ] && ! grep -q '^untracked:' <<<"$OUT"; then
    ok "19.$_pos19 #1090 dismissed + prose 'partial' at $pos → zero untracked rows" "(exit $RC)"
  else
    no "19.$_pos19 #1090 dismissed + prose 'partial' at $pos → zero untracked rows" "exit=$RC out=[$OUT]"
  fi
done

# 20 — STRUCTURED PARTIAL TOKEN (case-sensitivity regression): the canonical applied+PARTIAL
# format must still classify tracked/untracked correctly after switching to the shared helper.
box20="$(mkbox case-structured-partial)"
mk_gh_stub "$box20" nomatch
retro20="$(mk_retro "$box20" target-foo r-structured-partial.md \
  "<!-- review-status: applied 2026-06-01 · kit deadbeef · PARTIAL — shipped: 1; deferred: 2 -->" \
  "$(printf '| 1 | shipped delta | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | deferred delta | CLAUDE.md | B2 | new | MEDIUM |')")"
run "$box20" "$retro20"
if [ "$RC" = 0 ] && grep -q 'untracked: row 2' <<<"$OUT" \
   && ! grep -q 'untracked: row 1' <<<"$OUT"; then
  ok "20 structured PARTIAL token: only deferred row 2 untracked, shipped row 1 skipped" "(exit $RC)"
else
  no "20 structured PARTIAL token: only deferred row 2 untracked, shipped row 1 skipped" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# kit issue #945: H1-scoped marker — the real-corpus niagara-research *-closure.md shape (H1 line
# 1, blank line 2, marker line 3). Before #945, reconcile-issues.sh's own leading-block-only scan
# (no H1 tolerance) never saw this marker, so a fully DISMISSED retro written in this shape was
# reported as if it carried no marker at all — every delta row wrongly surfaced as 'untracked'.
# ---------------------------------------------------------------------------
box21="$(mkbox case-h1-scope)"
mk_gh_stub "$box21" nomatch
retro21="$box21/rh/target-foo/retros/r-h1-scope.md"
mkdir -p "$(dirname "$retro21")"
{
  printf '# §18 Retro — focus: apis — 2026-08-25\n\n'
  printf '<!-- review-status: dismissed 2026-09-24 · kit c10f9d9 -->\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| 1 | already handled elsewhere | METHODOLOGY.md | B1 | new | LOW |\n'
} > "$retro21"
run "$box21" "$retro21"
if [ "$RC" = 0 ] && ! grep -q '^untracked:' <<<"$OUT" \
   && grep -qi 'no-match' <<<"$OUT"; then
  ok "21 H1 + blank + marker (dismissed): row NOT reported untracked (#945 real-corpus shape)" "(exit $RC)"
else
  no "21 H1 + blank + marker (dismissed): row NOT reported untracked (#945 real-corpus shape)" \
    "exit=$RC out=[$OUT]"
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
# --issues-cache makes this hermetic w.r.t. gh (kit issue #1024 round 5, CI fix): CI has no `gh`
# login, so an unauthenticated `gh auth status` would exit "degraded" here regardless of the -P
# fix under test — an empty cache file means zero open issues, never touching gh at all.
cache_sym="$box_sym/empty-issues-cache"; : > "$cache_sym"
OUT_SYM="$(PATH="$box_sym/bin:$PATH" "$BASH_BIN" \
  "$box_sym/research-sdd/profile/general/toolbelt/reconcile-issues.sh" --all --issues-cache "$cache_sym" 2>&1)"; RC_SYM=$?
if [ "$RC_SYM" -eq 0 ] && ! grep -qi 'absent-input.*TARGETS\.md' <<<"$OUT_SYM"; then
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
    if ! grep -qi '^tracked:' <<<"$out_t1" \
       && grep -qi 'untracked:' <<<"$out_t1"; then
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
    if ! grep -qi 'untracked:' <<<"$out_t2"; then
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
    if ! grep -qi 'orphaned:' <<<"$out_t3"; then
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
  # kit issue #949: the hash-strip now lives in the SHARED lib/retro-status.sh helper
  # (retro_marker_shipped_ids), sourced by both reconcile-issues.sh and stage-retro-issues.sh —
  # mutate the box's COPY of the LIB (not reconcile-issues.sh itself) to prove the integration:
  # reconcile-issues.sh really does flow through the shared helper for real shipped-id behavior.
  echo "-- teeth T6: neuter hash-strip sub in the shared lib (integration through reconcile-issues.sh) --"
  # Kit issue #1093 item 5 rewrote retro_marker_shipped_ids in pure bash (no awk 3-arg match());
  # the hash-strip is now the line 't="${t#\#}"', anchored by RETRO_MARKER_SHIPPED_IDS_HASH_STRIP.
  anchor_t6='RETRO_MARKER_SHIPPED_IDS_HASH_STRIP'
  if grep -qF "$anchor_t6" "$RETRO_STATUS_LIB"; then
    box_t6="$(mkbox teeth-hash-strip)"
    mk_gh_stub "$box_t6" nomatch
    _hash_m_t6='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #1 (§11 desc), #2 (§5 desc) -->'
    mk_retro3 "$box_t6" target-foo r-t6.md "$_hash_m_t6" > /dev/null
    mutant_lib_t6="$box_t6/research-sdd/toolbelt/lib/retro-status.sh"
    # Delete the ONE line carrying the hash-strip (line-based deletion avoids sed delimiter
    # collisions with the literal '#' character inside the bash parameter expansion itself).
    sed '/t="\${t#\\#}"/d' "$RETRO_STATUS_LIB" > "$mutant_lib_t6"
    bash -n "$mutant_lib_t6" 2>/dev/null || { no "T6 teeth: mutant lib failed bash -n" ""; }
    out_t6="$(PATH="$box_t6/bin:$PATH" \
      "$BASH_BIN" "$box_t6/research-sdd/toolbelt/reconcile-issues.sh" \
      "$box_t6/rh/target-foo/retros/r-t6.md" 2>&1)"; rc_t6=$?
    _ut6=$(grep -c 'untracked: row' <<<"$out_t6" 2>/dev/null || true)
    # Fix: untracked=1 (only row 3). Mutant: untracked=3 (all rows, # not stripped).
    if [ "$_ut6" -gt 1 ]; then
      ok "T6 teeth: hash-strip neutered (shared lib) → untracked>1 (case 11 has teeth)" \
         "(untracked=$_ut6)"
    else
      no "T6 teeth: hash-strip neutered (shared lib) → should see untracked>1" \
         "case 11 may be THEATER: rc=$rc_t6 untracked=$_ut6 out=[$out_t6]"
    fi
  else
    no "T6 teeth: locate hash-strip anchor in shared lib" "anchor '$anchor_t6' not found in $RETRO_STATUS_LIB"
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
      _tmc_tracked="$(grep -c '^tracked:' <<<"$out_tmc" 2>/dev/null)"
      _tmc_untracked="$(grep -c '^untracked:' <<<"$out_tmc" 2>/dev/null)"
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
  # --issues-cache: same hermeticity requirement as the SYMLINK-TOOLBELT base check above (kit
  # issue #1024 round 5, CI fix) — an unauthenticated gh on CI must never turn this tooth's
  # expected "absent-input" symptom into an unrelated "degraded: gh is not authenticated" one.
  cache_tsym="$box_tsym/empty-issues-cache"; : > "$cache_tsym"
  out_tsym="$(PATH="$box_tsym/bin:$PATH" "$BASH_BIN" \
    "$box_tsym/research-sdd/profile/general/toolbelt/reconcile-issues.sh" --all --issues-cache "$cache_tsym" 2>&1)"; rc_tsym=$?
  if [ "$rc_tsym" -ne 0 ] && grep -qi 'absent-input.*TARGETS\.md' <<<"$out_tsym"; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant re-breaks through a symlinked toolbelt/ → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant still resolved TARGETS.md — -P fix check is THEATER" \
       "(rc=$rc_tsym out=[$out_tsym])"
  fi

  # TOOTH T7 (kit issue #1090): neuter the 'dismissed always wins' guard so a dismissed
  # marker falls through to the is_partial check like 'applied' does — a dismissed marker
  # whose structured segment DOES carry PARTIAL must then wrongly report untracked rows.
  echo "-- teeth T7: neuter 'dismissed always wins' guard; dismissed+PARTIAL must reopen rows (case 18/19 have teeth) --"
  anchor_t7='    dismissed)
      _has_open_rows=0 ;;'
  if [[ "$(cat "$SUT")" == *"$anchor_t7"* ]]; then
    box_t7="$(mkbox teeth-dismissed-wins)"
    mk_gh_stub "$box_t7" nomatch
    mk_retro "$box_t7" target-foo r-t7.md \
      "<!-- review-status: dismissed 2026-09-20 · kit deadbeef · PARTIAL — shipped: 99 -->" \
      "| 1 | should stay closed unless guard removed | CLAUDE.md | B1 | new | HIGH |" > /dev/null
    mutant_t7="$box_t7/research-sdd/toolbelt/reconcile-issues.sh"
    reverted_t7='    dismissed)
      [ "$is_partial" -eq 0 ] && _has_open_rows=0 ;;'
    sut_content_ri="$(cat "$SUT")"
    printf '%s\n' "${sut_content_ri/"$anchor_t7"/"$reverted_t7"}" > "$mutant_t7"
    bash -n "$mutant_t7" 2>/dev/null || { no "T7 teeth: mutant_t7 failed bash -n" ""; }
    out_t7="$(PATH="$box_t7/bin:$PATH" \
      "$BASH_BIN" "$mutant_t7" "$box_t7/rh/target-foo/retros/r-t7.md" 2>&1)"; rc_t7=$?
    if grep -q '^untracked:' <<<"$out_t7"; then
      ok "T7 teeth: dismissed-wins guard neutered → dismissed+PARTIAL reports untracked (case 18/19 have teeth)" "()"
    else
      no "T7 teeth: dismissed-wins guard neutered → should report untracked" \
        "no untracked — case 18/19 is THEATER: rc=$rc_t7 out=[$out_t7]"
    fi
  else
    no "T7 teeth: locate 'dismissed always wins' guard anchor" "anchor not found — SUT drifted?"
  fi

  # ── kit issue #1129 findings 2/3: mutation controls for the found=1-no-rows branch and for
  # each grammar rule this PR series added, none of which had a --prove-teeth control before. ──

  # Tooth H1: drop the retro_grammar_has_honesty guard from the found=1-no-rows branch. Case 25
  # (honest empty) must then flip from empty-input to unclassifiable.
  echo "-- teeth H1: drop the honesty check; case 25 (honest empty) must flip to unclassifiable --"
  anchor_h1='    if retro_grammar_has_honesty "$retro_path"; then
      echo "empty-input: delta section found but contains no data rows (honest §18 zero) in $retro_path" >&2
      return 0
    fi'
  sut_content_h1="$(cat "$SUT")"
  if [[ "$sut_content_h1" == *"$anchor_h1"* ]]; then
    box_h1="$(mkbox teeth-h1)"
    mk_gh_stub "$box_h1" nomatch
    retro_h1="$box_h1/rh/target-foo/retros/r-h1.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
      printf 'no new deltas; the kit already covers this run.\n'
    } > "$retro_h1"
    mutant_h1="$box_h1/research-sdd/toolbelt/reconcile-issues.sh"
    printf '%s\n' "${sut_content_h1/"$anchor_h1"/}" > "$mutant_h1"
    "$BASH_BIN" -n "$mutant_h1" 2>/dev/null || no "teeth H1: mutant syntax check" "bash -n failed"
    out_h1="$(PATH="$box_h1/bin:$PATH" "$BASH_BIN" "$mutant_h1" "$retro_h1" 2>&1)"
    if grep -qi '^unclassifiable:' <<<"$out_h1"; then
      ok "teeth H1: honesty check removed → case 25 flips to unclassifiable (has teeth)" "()"
    else
      no "teeth H1: honesty check removed → should flip to unclassifiable" "case 25 is THEATER: out=[$out_h1]"
    fi
  else
    no "teeth H1: locate the honesty-check guard anchor" "anchor not found — SUT drifted?"
  fi

  # Tooth H2: the surviving unclassifiable echo itself — silence it, case 26 must go quiet.
  echo "-- teeth H2: silence the unclassifiable echo; case 26 must go quiet (no unclassifiable line) --"
  anchor_h2='echo "unclassifiable: delta section found but contains neither row-table rows nor '"'"'### D<N> —'"'"' entries in $retro_path — needs manual review" >&2'
  if [[ "$sut_content_h1" == *"$anchor_h2"* ]]; then
    box_h2="$(mkbox teeth-h2)"
    mk_gh_stub "$box_h2" nomatch
    retro_h2="$box_h2/rh/target-foo/retros/r-h2.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
      printf '### ABSORB → prose, no table, no honesty\n\nprose here\n'
    } > "$retro_h2"
    mutant_h2="$box_h2/research-sdd/toolbelt/reconcile-issues.sh"
    printf '%s\n' "${sut_content_h1/"$anchor_h2"/:}" > "$mutant_h2"
    "$BASH_BIN" -n "$mutant_h2" 2>/dev/null || no "teeth H2: mutant syntax check" "bash -n failed"
    out_h2="$(PATH="$box_h2/bin:$PATH" "$BASH_BIN" "$mutant_h2" "$retro_h2" 2>&1)"
    if ! grep -qi 'unclassifiable' <<<"$out_h2"; then
      ok "teeth H2: unclassifiable echo silenced → case 26's typed message gone (has teeth)" "()"
    else
      no "teeth H2: unclassifiable echo silenced → message should be gone" "case 26 is THEATER: out=[$out_h2]"
    fi
  else
    no "teeth H2: locate the unclassifiable echo anchor" "anchor not found — SUT drifted?"
  fi

  # Tooth GR1 (kit issue #1129 Q5): the Spanish canonical alias, sourced from the shared grammar
  # lib as loaded by THIS consumer — remove it from the copy reconcile-issues.sh sources and
  # prove case 22 (Spanish alias with real table rows) stops being audited.
  echo "-- teeth GR1: remove the Spanish canonical alias from the sourced grammar lib; case 22 must stop auditing --"
  rg_lib_content="$(cat "$RETRO_GRAMMAR_LIB")"
  anchor_gr1='  if (low ~ /^## propuesta de deltas al kit([[:space:]]|$)/) return 1'
  if [[ "$rg_lib_content" == *"$anchor_gr1"* ]]; then
    box_gr1="$(mkbox teeth-gr1)"
    mk_gh_stub "$box_gr1" nomatch
    retro_gr1="$box_gr1/rh/target-foo/retros/r-gr1.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
      printf '| 1 | delta uno | CLAUDE.md | B1 | new | HIGH |\n'
    } > "$retro_gr1"
    printf '%s\n' "${rg_lib_content/"$anchor_gr1"/}" > "$box_gr1/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr1/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR1: mutant lib syntax check" "bash -n failed"
    out_gr1="$(PATH="$box_gr1/bin:$PATH" "$BASH_BIN" "$box_gr1/research-sdd/toolbelt/reconcile-issues.sh" "$retro_gr1" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr1"; then
      ok "teeth GR1: Spanish alias removed from lib → case 22 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR1: Spanish alias removed from lib → should revert to empty-input" "case 22 is THEATER: out=[$out_gr1]"
    fi
  else
    no "teeth GR1: locate the Spanish canonical alias in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # Tooth GR2 (kit issue #1129 Q5): revert Rule 2's hyphen widening back to space-only. Case 23
  # (hyphenated kit-delta) must then revert from unclassifiable to empty-input.
  echo "-- teeth GR2: revert Rule 2's hyphen widening; case 23 must revert to empty-input --"
  anchor_gr2='if (!is_unrec && low ~ /[ -]kit[ -]delt/ && low !~ /not[ -]+kit[ -]+delt/) is_unrec=1'
  if [[ "$rg_lib_content" == *"$anchor_gr2"* ]]; then
    box_gr2="$(mkbox teeth-gr2)"
    mk_gh_stub "$box_gr2" nomatch
    retro_gr2="$box_gr2/rh/target-foo/retros/r-gr2.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n'
      printf '## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n'
    } > "$retro_gr2"
    reverted_gr2='if (!is_unrec && low ~ / kit delt/ && low !~ /not +kit +delt/) is_unrec=1'
    printf '%s\n' "${rg_lib_content/"$anchor_gr2"/"$reverted_gr2"}" > "$box_gr2/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr2/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR2: mutant lib syntax check" "bash -n failed"
    out_gr2="$(PATH="$box_gr2/bin:$PATH" "$BASH_BIN" "$box_gr2/research-sdd/toolbelt/reconcile-issues.sh" "$retro_gr2" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr2"; then
      ok "teeth GR2: Rule 2 hyphen widening reverted → case 23 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR2: Rule 2 hyphen widening reverted → should revert to empty-input" "case 23 is THEATER: out=[$out_gr2]"
    fi
  else
    no "teeth GR2: locate Rule 2's hyphen-widened pattern in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # Tooth GR3 (kit issue #1129 Q5): disable Rule 4 (standalone H3 "Proposals" outside section).
  # Case 24 must then revert from unclassifiable to empty-input.
  echo "-- teeth GR3: disable Rule 4 (standalone H3 Proposals); case 24 must revert to empty-input --"
  anchor_gr3='      !in_sec && /^###[^#]/ {
        if (!unrec_found && low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) {
          unrec_found=1; unrec_heading=$0
        }
        next
      }'
  if [[ "$rg_lib_content" == *"$anchor_gr3"* ]]; then
    box_gr3="$(mkbox teeth-gr3)"
    mk_gh_stub "$box_gr3" nomatch
    retro_gr3="$box_gr3/rh/target-foo/retros/r-gr3.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## A. THE DEFECT\n\n'
      printf '### Proposals (propose-never-apply) — make it automatic\n\nsome prose, no table rows here\n'
    } > "$retro_gr3"
    printf '%s\n' "${rg_lib_content/"$anchor_gr3"/}" > "$box_gr3/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr3/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR3: mutant lib syntax check" "bash -n failed"
    out_gr3="$(PATH="$box_gr3/bin:$PATH" "$BASH_BIN" "$box_gr3/research-sdd/toolbelt/reconcile-issues.sh" "$retro_gr3" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr3"; then
      ok "teeth GR3: Rule 4 disabled → case 24 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR3: Rule 4 disabled → should revert to empty-input" "case 24 is THEATER: out=[$out_gr3]"
    fi
  else
    no "teeth GR3: locate Rule 4 (standalone H3 Proposals) in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # TOOTH T-OOS (kit issue #1125 item 4 — the other three consumers, sweep-retros.sh,
  # stage-retro-issues.sh, and retro-gate.sh, already have one; reconcile-issues.sh did not).
  # Neuter the out-of-scope-marker guard. Case 10b's fixture (marker after a second heading)
  # must then be silently read as if no marker existed at all — its row reported untracked
  # instead of the classification being refused — reproducing the exact #1048-#1089 fail-open
  # shape #1099 fixes.
  echo "-- teeth T-OOS: neuter the out-of-scope-marker guard; case 10b must fail open again --"
  anchor_toos='if [ -z "$_marker_line" ] && retro_marker_out_of_scope "$retro_path"; then'
  sut_content_toos="$(cat "$SUT")"
  if [[ "$sut_content_toos" == *"$anchor_toos"* ]]; then
    box_toos="$(mkbox teeth-oos)"
    mk_gh_stub "$box_toos" nomatch
    retro_toos="$box_toos/rh/target-foo/retros/r-oos.md"
    {
      printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n\n## Proposed kit deltas\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
      printf '|---|---|---|---|---|---|\n'
      printf '| 1 | old delta | METHODOLOGY.md | B1 | new | HIGH |\n'
    } > "$retro_toos"
    mutant_toos="$box_toos/research-sdd/toolbelt/reconcile-issues.sh"
    printf '%s\n' "${sut_content_toos/"$anchor_toos"/if false; then}" > "$mutant_toos"
    "$BASH_BIN" -n "$mutant_toos" 2>/dev/null || no "T-OOS teeth: mutant syntax check" "bash -n failed"
    out_toos="$(PATH="$box_toos/bin:$PATH" "$BASH_BIN" "$mutant_toos" "$retro_toos" 2>&1)"; rc_toos=$?
    if grep -q '^untracked:' <<<"$out_toos"; then
      ok "T-OOS teeth: guard neutered → row untracked again, fails open (case 10b has teeth)" "()"
    else
      no "T-OOS teeth: guard neutered → row should be untracked (fail open)" \
        "mutant did not emit untracked — case 10b is THEATER: rc=$rc_toos out=[$out_toos]"
    fi
  else
    no "T-OOS teeth: locate out-of-scope-marker guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # ---- kit issue #1287 teeth -------------------------------------------------------------------
  # tooth_swap <box> <anchor> <replacement>: overwrite the box's reconcile-issues.sh with the
  # mutant; refuses a vacuous (anchor missing / byte-identical) or syntactically broken mutant.
  tooth_swap() {
    local box="$1" anchor="$2" repl="$3"
    local file="$box/research-sdd/toolbelt/reconcile-issues.sh" content
    content="$(cat "$file")"
    if [[ "$content" != *"$anchor"* ]]; then
      no "tooth_swap: locate anchor" "anchor not found in SUT — drifted? anchor=[$anchor]"; return 1
    fi
    printf '%s\n' "${content/"$anchor"/"$repl"}" > "$file"
    if cmp -s "$file" "$SUT"; then no "tooth_swap: mutant" "identical to the SUT — vacuous"; return 1; fi
    if ! "$BASH_BIN" -n "$file" 2>/dev/null; then no "tooth_swap: mutant passes bash -n" "syntax error — crash-based theater"; return 1; fi
    return 0
  }

  # T1287a: single mode ignores the helper → falls back to basename → case 27 flips to untracked.
  echo "-- teeth T1287a: single mode uses the basename, not the registered name --"
  box_ta="$(mkbox teeth-sig-name)"; mk_gh_stub "$box_ta" nomatch
  mk_targets "$box_ta" reg-name "$box_ta/rh/target-foo"
  retro_ta="$(mk_open_retro "$box_ta/rh/target-foo/retros/r.md")"; cache_for "$ROOT/cache-ta.txt" reg-name r.md
  if tooth_swap "$box_ta" '_tgt_name="$(target_name_for_retro "$TARGETS_MD" "$retro")"' '_tgt_name=""'; then
    run "$box_ta" --issues-cache "$ROOT/cache-ta.txt" "$retro_ta"
    if grep -q '^untracked:' <<<"$OUT"; then ok "T1287a teeth: basename signature → untracked (case 27 has teeth)" "()"
    else no "T1287a teeth: basename signature must flip case 27" "case 27 is THEATER: out=[$OUT]"; fi
  fi

  # T1287b: --all stops scanning corpus/retros → case 29 loses the retro (retros=0).
  echo "-- teeth T1287b: --all drops <target>/corpus/retros --"
  box_tb="$(mkbox teeth-all-corpus)"; mk_gh_stub "$box_tb" nomatch
  mk_targets "$box_tb" reg-name "$box_tb/rh/target-foo"; rm -rf "$box_tb/rh/target-foo/retros"
  mk_open_retro "$box_tb/rh/target-foo/corpus/retros/r.md" >/dev/null; cache_for "$ROOT/cache-tb.txt" reg-name r.md
  if tooth_swap "$box_tb" 'for _retros_dir in "$_tgt_path/retros" "$_tgt_path/corpus/retros"; do' 'for _retros_dir in "$_tgt_path/retros"; do'; then
    run "$box_tb" --all --issues-cache "$ROOT/cache-tb.txt"
    if grep -q 'retros=0' <<<"$OUT"; then ok "T1287b teeth: corpus/retros dropped → retros=0 (case 29 has teeth)" "()"
    else no "T1287b teeth: corpus/retros dropped must flip case 29" "case 29 is THEATER: out=[$OUT]"; fi
  fi

  # T1287c: --all labels every retro with the target's basename, not the per-retro helper name.
  echo "-- teeth T1287c: --all uses the basename instead of the per-retro registered name --"
  box_tc="$(mkbox teeth-all-name)"; mk_gh_stub "$box_tc" nomatch
  mk_targets "$box_tc" reg-name "$box_tc/rh/target-foo"
  mk_open_retro "$box_tc/rh/target-foo/retros/r.md" >/dev/null; cache_for "$ROOT/cache-tc.txt" reg-name r.md
  if tooth_swap "$box_tc" '_rf_name="$(target_name_for_retro "$TARGETS_MD" "$_rfile")"' '_rf_name="$_tgt_nm"'; then
    run "$box_tc" --all --issues-cache "$ROOT/cache-tc.txt"
    if grep -q 'untracked=1' <<<"$OUT"; then ok "T1287c teeth: basename in --all → untracked=1 (case 30 has teeth)" "()"
    else no "T1287c teeth: basename in --all must flip case 30" "case 30 is THEATER: out=[$OUT]"; fi
  fi

  # T1287d: swallow the operational failure → WARN + guess again (case 34).
  echo "-- teeth T1287d: neuter the TARGETS.md operational-failure exit --"
  box_td="$(mkbox teeth-opfail)"; mk_gh_stub "$box_td" nomatch
  retro_td="$(mk_open_retro "$box_td/rh/target-foo/retros/r.md")"; : > "$ROOT/cache-td.txt"
  rm -f "$box_td/research-sdd/TARGETS.md"
  if tooth_swap "$box_td" 'if [ "$_tnr_rc" -eq 1 ]; then' 'if false; then'; then
    run "$box_td" --issues-cache "$ROOT/cache-td.txt" "$retro_td"
    if grep -q '^untracked:' <<<"$OUT"; then ok "T1287d teeth: failure exit neutered → verdict on a guessed name (case 34 has teeth)" "()"
    else no "T1287d teeth: failure exit neutered must flip case 34" "case 34 is THEATER: out=[$OUT]"; fi
  fi

  # T1287e: structural-name guard removed → nested unregistered retro audited under 'corpus' (case 35).
  echo "-- teeth T1287e: neuter the structural-name guard --"
  box_te="$(mkbox teeth-structural)"; mk_gh_stub "$box_te" nomatch
  mk_targets "$box_te" other "$box_te/rh/other"; mkdir -p "$box_te/rh/other"
  retro_te="$(mk_open_retro "$box_te/rh/target-foo/corpus/retros/r.md")"; : > "$ROOT/cache-te.txt"
  if tooth_swap "$box_te" '      corpus|retros)' '      __never_matches__)'; then
    run "$box_te" --issues-cache "$ROOT/cache-te.txt" "$retro_te"
    if grep -q '^untracked:' <<<"$OUT"; then ok "T1287e teeth: guard neutered → audited under 'corpus' (case 35 has teeth)" "()"
    else no "T1287e teeth: guard neutered must flip case 35" "case 35 is THEATER: out=[$OUT]"; fi
  fi

  # T1287f: the empty-dir WARN ignores sibling layouts (always WARN) → case 36 flips.
  echo "-- teeth T1287f: empty-dir WARN regardless of the sibling layout --"
  box_tf="$(mkbox teeth-empty-flat)"; mk_gh_stub "$box_tf" nomatch
  mk_targets "$box_tf" reg-name "$box_tf/rh/target-foo"
  mk_open_retro "$box_tf/rh/target-foo/corpus/retros/r.md" >/dev/null; cache_for "$ROOT/cache-tf.txt" reg-name r.md
  if tooth_swap "$box_tf" 'if [ "$_tgt_found" -eq 0 ] && [ -n "$_empty_dirs" ]; then' 'if [ -n "$_empty_dirs" ]; then'; then
    run "$box_tf" --all --issues-cache "$ROOT/cache-tf.txt"
    if grep -q 'no retro files' <<<"$OUT"; then ok "T1287f teeth: unconditional WARN → misleading 'no retro files' (case 36 has teeth)" "()"
    else no "T1287f teeth: unconditional WARN must flip case 36" "case 36 is THEATER: out=[$OUT]"; fi
  fi

  # ---- kit issue #1304 teeth (reconcile side: exact prefix filter + legacy-signature symmetry) ----
  LEG_BASE="Source retro: target-foo/retros"
  rbox() {  # <name> <gh-mode> [text] [pattern] → a box with reg-name registered over target-foo
    local b
    b="$(mkbox "$1")"
    mk_targets "$b" reg-name "$b/rh/target-foo"
    mk_gh_stub "$b" "$2" "${3:-}" "${4:-}"
    mk_open_retro "$b/rh/target-foo/${5:-retros}/r.md" >/dev/null
    printf '%s' "$b"
  }
  echo "-- teeth T1304-R1: legacy prefix never computed --"
  box_r1="$(rbox teeth-r1 nomatch)"; printf '%s/r.md · 1\n' "$LEG_BASE" > "$ROOT/cache-r1.txt"
  if tooth_swap "$box_r1" '*) _legacy_prefix="${_legacy_nm}/retros/${retro_basename}" ;;' '*) _legacy_prefix="" ;;'; then
    run "$box_r1" --issues-cache "$ROOT/cache-r1.txt" "$box_r1/rh/target-foo/retros/r.md"
    if grep -q '^untracked: row 1' <<<"$OUT"; then ok "T1304-R1 teeth: no legacy prefix → open legacy issue reads untracked (case 38 has teeth)" "()"
    else no "T1304-R1 teeth: legacy prefix removed must flip case 38" "case 38 is THEATER: out=[$OUT]"; fi
  fi
  echo "-- teeth T1304-R2: gh path queries only the registered-name signature --"
  box_r2="$(rbox teeth-r2 lines "$LEG_BASE/r.md · 1" "Source retro: target-foo/retros/r.md")"
  if tooth_swap "$box_r2" 'for _qpfx in "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"}; do' 'for _qpfx in "$_sig_prefix"; do'; then
    run "$box_r2" "$box_r2/rh/target-foo/retros/r.md"
    if grep -q '^untracked: row 1' <<<"$OUT"; then ok "T1304-R2 teeth: legacy query dropped → untracked (case 38b has teeth)" "()"
    else no "T1304-R2 teeth: legacy query dropped must flip case 38b" "case 38b is THEATER: out=[$OUT]"; fi
  fi
  echo "-- teeth T1304-R3: row-id extraction no longer filtered to this retro's signature --"
  box_r3="$(rbox teeth-r3 lines "Source retro: niagara-reg-name/retros/r.md · 1")"
  if tooth_swap "$box_r3" '| grep -F "Source retro: ${_pfx} · " \' '| grep -F "Source retro: " \'; then
    run "$box_r3" "$box_r3/rh/target-foo/retros/r.md"
    if grep -q '^tracked: row 1' <<<"$OUT"; then ok "T1304-R3 teeth: unfiltered extraction → another target's issue reads tracked (case 37 has teeth)" "()"
    else no "T1304-R3 teeth: unfiltered extraction must flip case 37" "case 37 is THEATER: out=[$OUT]"; fi
  fi
  echo "-- teeth T1304-R4: extraction loop reads only the registered-name signature --"
  box_r4="$(rbox teeth-r4 nomatch)"; printf '%s/r.md · 1\n' "$LEG_BASE" > "$ROOT/cache-r4.txt"
  if tooth_swap "$box_r4" 'for _pfx in "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"}; do' 'for _pfx in "$_sig_prefix"; do'; then
    run "$box_r4" --issues-cache "$ROOT/cache-r4.txt" "$box_r4/rh/target-foo/retros/r.md"
    if grep -q '^untracked: row 1' <<<"$OUT"; then ok "T1304-R4 teeth: legacy extraction dropped → untracked (cases 38/38f have teeth)" "()"
    else no "T1304-R4 teeth: legacy extraction dropped must flip case 38" "case 38 is THEATER: out=[$OUT]"; fi
  fi
  echo "-- teeth T1304-R5: structural legacy name no longer skipped --"
  box_r5="$(rbox teeth-r5 nomatch "" "" corpus/retros)"
  if tooth_swap "$box_r5" "corpus|retros|''|\"\$target_nm\") ;;" "''|\"\$target_nm\") ;;"; then
    run "$box_r5" "$box_r5/rh/target-foo/corpus/retros/r.md"
    if grep -qF 'Source retro: corpus/retros' "$box_r5/bin/gh.log" 2>/dev/null; then ok "T1304-R5 teeth: structural skip removed → pointless corpus/retros query (case 38d has teeth)" "()"
    else no "T1304-R5 teeth: structural skip removed must flip case 38d" "case 38d is THEATER: log=[$(cat "$box_r5/bin/gh.log" 2>/dev/null)]"; fi
  fi
  echo "-- teeth T1304-R6: equal-name skip removed (extra list call for the common case) --"
  box_r6="$(mkbox teeth-r6)"; mk_targets "$box_r6" target-foo "$box_r6/rh/target-foo"; mk_gh_stub "$box_r6" nomatch
  mk_open_retro "$box_r6/rh/target-foo/retros/r.md" >/dev/null
  if tooth_swap "$box_r6" "corpus|retros|''|\"\$target_nm\") ;;" "corpus|retros|'') ;;"; then
    run "$box_r6" "$box_r6/rh/target-foo/retros/r.md"
    if [ "$(grep -c 'issue list' "$box_r6/bin/gh.log")" = 2 ]; then ok "T1304-R6 teeth: equal-name skip removed → second list call (case 38c has teeth)" "()"
    else no "T1304-R6 teeth: equal-name skip removed must flip case 38c" "case 38c is THEATER: lists=$(grep -c 'issue list' "$box_r6/bin/gh.log")"; fi
  fi

  # ---- kit issue #1332 item 2 teeth (entry form) — mutant built with tests/lib/mutant.sh ----
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  ENTRY_FIX="$HERE/fixtures/retro-entry-form-applied-3.md"
  echo "-- teeth T1332-R1: entry-form fallback removed (cases 39a/39b/39c must flip) --"
  box_e1="$(mkbox teeth-entry)"; mk_gh_stub "$box_e1" nomatch
  if mutant_sed "$SUT" "$box_e1/research-sdd/toolbelt/reconcile-issues.sh" \
       -e 's/^    _all_row_ids="\$(retro_grammar_entry_ids "\$retro_path")"/    :/'; then
    cp "$ENTRY_FIX" "$box_e1/rh/target-foo/retros/r.md"
    run "$box_e1" --issues-cache /dev/null "$box_e1/rh/target-foo/retros/r.md"
    if grep -q '^unclassifiable:' <<<"$OUT"; then ok "T1332-R1 teeth: no entry fallback → unclassifiable again (39a has teeth)" "()"
    else no "T1332-R1 teeth: removed fallback must flip 39a" "39a is THEATER: out=[$OUT]"; fi
  else no "T1332-R1: build mutant" "mutant_sed refused"; fi
  echo "-- teeth T1332-R2: entry IDs ignored when classifying (every entry untracked despite a cache hit) --"
  box_e2="$(mkbox teeth-entry-ids)"; mk_gh_stub "$box_e2" nomatch
  if mutant_sed "$SUT" "$box_e2/research-sdd/toolbelt/reconcile-issues.sh" \
       -e 's/if printf .%s\\n. "\$_issue_row_ids" | grep -qxF "\$_rid"; then/if false; then/'; then
    sed 's/^<!-- review-status: applied.*-->$/<!-- review-status: pending -->/' "$ENTRY_FIX" > "$box_e2/rh/target-foo/retros/r.md"
    cache_for "$ROOT/cache-e2.txt" target-foo r.md D2
    run "$box_e2" --issues-cache "$ROOT/cache-e2.txt" "$box_e2/rh/target-foo/retros/r.md"
    if ! grep -q '^tracked: row D2 ' <<<"$OUT"; then ok "T1332-R2 teeth: tracked check disabled → D2 no longer tracked (39b has teeth)" "()"
    else no "T1332-R2 teeth: disabled tracked check must flip 39b" "39b is THEATER: out=[$OUT]"; fi
  else no "T1332-R2: build mutant" "mutant_sed refused"; fi

  echo "-- teeth T1332-R3: entry-gap WARN removed (case 39e must flip) --"
  box_e3="$(mkbox teeth-entry-warn)"; mk_gh_stub "$box_e3" nomatch
  if mutant_sed "$SUT" "$box_e3/research-sdd/toolbelt/reconcile-issues.sh" \
       -e 's/^    \[ -z "\$_all_row_ids" \] || retro_grammar_entry_warn "\$retro_path" >&2/    :/'; then
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### **D1** — bold id\n\n### D2 — plain id\n' > "$box_e3/rh/target-foo/retros/r.md"
    run "$box_e3" --issues-cache /dev/null "$box_e3/rh/target-foo/retros/r.md"
    if ! grep -q '^WARN: .*1 of 2' <<<"$OUT"; then ok "T1332-R3 teeth: WARN removed → silent (39e has teeth)" "()"
    else no "T1332-R3 teeth: removed WARN must flip 39e" "39e is THEATER: out=[$OUT]"; fi
  else no "T1332-R3: build mutant" "mutant_sed refused"; fi

fi  # --prove-teeth

# ---------------------------------------------------------------------------
# 22 — SPANISH CANONICAL ALIAS (kit issue #1111): "## PROPUESTA de deltas al kit" is a real
#      fleet form (Pancaddia corpus retro) — accepted as canonical, row parsed and audited.
box="$(mkbox case-spanish-alias)"
mk_gh_stub "$box" nomatch
retro="$box/rh/target-foo/retros/r-spanish.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf '| 1 | delta uno | CLAUDE.md | B1 | new | HIGH |\n'
} > "$retro"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -q '^untracked:' <<<"$OUT" && ! grep -qi 'empty-input\|unclassifiable' <<<"$OUT"; then
  ok "22 Spanish canonical alias 'PROPUESTA de deltas al kit' → row audited, not empty/unclassifiable" "(exit $RC)"
else
  no "22 Spanish canonical alias → expected row audited (untracked)" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 23 — UNCLASSIFIABLE, not empty-input (kit issue #1111): a hyphenated "kit-delta" mid-heading
#      (real fleet form, niagara-research retro) with no table rows must be typed
#      unclassifiable, never a confident empty-input.
box="$(mkbox case-hyphen-kitdelta)"
mk_gh_stub "$box" nomatch
retro="$box/rh/target-foo/retros/r-hyphen.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n'
  printf '## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n'
} > "$retro"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi 'unclassifiable' <<<"$OUT" && ! grep -qF 'empty-input' <<<"$OUT"; then
  ok "23 hyphenated 'kit-delta' mid-heading → unclassifiable, never empty-input" "(exit $RC)"
else
  no "23 hyphenated 'kit-delta' mid-heading → expected unclassifiable, never empty-input" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 24 — UNCLASSIFIABLE, not empty-input (kit issue #1111): a standalone H3 "### Proposals"
#      heading outside any canonical section (real fleet form, niagara-research retro) with
#      no table rows must be typed unclassifiable, never a confident empty-input.
box="$(mkbox case-h3-proposals)"
mk_gh_stub "$box" nomatch
retro="$box/rh/target-foo/retros/r-h3proposals.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## A. THE DEFECT\n\n'
  printf '### Proposals (propose-never-apply) — make it automatic\n\nsome prose, no table rows here\n'
} > "$retro"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi 'unclassifiable' <<<"$OUT" && ! grep -qF 'empty-input' <<<"$OUT"; then
  ok "24 standalone H3 '### Proposals' outside section → unclassifiable, never empty-input" "(exit $RC)"
else
  no "24 standalone H3 '### Proposals' outside section → expected unclassifiable, never empty-input" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 25 — HONEST EMPTY, not unclassifiable (kit issue #1129 finding 2): a canonical section with an
#      empty table (header + separator, no data rows) PLUS a valid §18 honesty line is a correct
#      declared zero, not "not in row-table form — needs manual review". Real fleet
#      counterexample: niagara-research/retros/2026-09-17-tools-search-innovation.md.
box="$(mkbox case-honest-empty)"
mk_gh_stub "$box" nomatch
retro="$box/rh/target-foo/retros/r-honest-empty.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file · %%/section) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf 'no new deltas; the kit already covers this run.\n'
} > "$retro"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi '^empty-input:' <<<"$OUT" \
  && ! grep -qi 'unclassifiable' <<<"$OUT"; then
  ok "25 honest empty (§18 honesty line, no rows) → empty-input, not unclassifiable" "(exit $RC)"
else
  no "25 honest empty (§18 honesty line, no rows) → expected empty-input, not unclassifiable" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 26 — UNCLASSIFIABLE (found=1, no rows, NOT an honest zero) — kit issue #1129 finding 3: the
#      found=1-no-rows relabel itself had no positive test. A canonical section whose body is
#      ordinary prose (no §18 honesty phrase, no table rows) must still be unclassifiable.
box="$(mkbox case-no-rows-not-honest)"
mk_gh_stub "$box" nomatch
retro="$box/rh/target-foo/retros/r-not-honest.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
  printf '### ABSORB → some ordinary sub-heading with prose, no table, no honesty phrase\n\nprose here\n'
} > "$retro"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi '^unclassifiable:' <<<"$OUT" \
  && ! grep -qi '^empty-input:' <<<"$OUT"; then
  ok "26 canonical section, no rows, NOT honest → unclassifiable" "(exit $RC)"
else
  no "26 canonical section, no rows, NOT honest → expected unclassifiable" "exit=$RC out=[$OUT]"
fi


# ---------------------------------------------------------------------------
# kit issue #1287 item 1: stage-retro-issues.sh stamps `Source retro: <TARGETS name>/retros/<file>`
# (name from the nearest registered ancestor — lib/target-paths.sh target_name_for_retro), so
# reconcile (single AND --all) must search the SAME signature and --all must also reach
# <target>/corpus/retros. Before the fix a target whose registered name differs from its path
# basename reported every newly seeded issue as `untracked` forever (inviting manual duplicates).
# Assertions use here-strings, not `printf | grep -q` (SIGPIPE-prone under pipefail, #1162).

# 27 — SINGLE, flat layout, registered name != basename: the name-based signature is TRACKED
#      (RED pre-fix: reconcile searched `target-foo/retros/...` and reported untracked).
box27="$(mkbox case-sig-name-flat)"
mk_gh_stub "$box27" nomatch
mk_targets "$box27" reg-name "$box27/rh/target-foo"
retro27="$(mk_open_retro "$box27/rh/target-foo/retros/r27.md")"
cache_for "$ROOT/cache27.txt" reg-name r27.md
run "$box27" --issues-cache "$ROOT/cache27.txt" "$retro27"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "27 single flat: registered name != basename → tracked by the name signature" "(exit $RC)"
else
  no "27 single flat: registered name != basename → expected tracked" "exit=$RC out=[$OUT]"
fi

# 28 — SINGLE, nested corpus layout (<target>/corpus/retros), name != basename → tracked.
box28="$(mkbox case-sig-name-nested)"
mk_gh_stub "$box28" nomatch
mk_targets "$box28" reg-name "$box28/rh/target-foo"
retro28="$(mk_open_retro "$box28/rh/target-foo/corpus/retros/r28.md")"
cache_for "$ROOT/cache28.txt" reg-name r28.md
run "$box28" --issues-cache "$ROOT/cache28.txt" "$retro28"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && ! grep -qi 'not found in' <<<"$OUT"; then
  ok "28 single nested corpus/retros → tracked by the name signature, no basename WARN" "(exit $RC)"
else
  no "28 single nested corpus/retros → expected tracked" "exit=$RC out=[$OUT]"
fi

# 29 — --all reaches <target>/corpus/retros (RED pre-fix: retros=0, empty-input) and uses the name.
box29="$(mkbox case-all-corpus)"
mk_gh_stub "$box29" nomatch
mk_targets "$box29" reg-name "$box29/rh/target-foo"
rm -rf "$box29/rh/target-foo/retros"
mk_open_retro "$box29/rh/target-foo/corpus/retros/r29.md" >/dev/null
cache_for "$ROOT/cache29.txt" reg-name r29.md
run "$box29" --all --issues-cache "$ROOT/cache29.txt"
if [ "$RC" = 0 ] && grep -q 'fleet-summary: tracked=1 untracked=0 .*retros=1' <<<"$OUT"; then
  ok "29 --all finds <target>/corpus/retros and tracks it by the registered name" "(exit $RC)"
else
  no "29 --all finds <target>/corpus/retros and tracks it by the registered name" "exit=$RC out=[$OUT]"
fi

# 30 — --all, flat layout, name != basename → tracked by the name; flat + corpus together → both.
box30="$(mkbox case-all-flat-and-corpus)"
mk_gh_stub "$box30" nomatch
mk_targets "$box30" reg-name "$box30/rh/target-foo"
mk_open_retro "$box30/rh/target-foo/retros/r30a.md" >/dev/null
mk_open_retro "$box30/rh/target-foo/corpus/retros/r30b.md" >/dev/null
{ printf 'Source retro: reg-name/retros/r30a.md · 1\n'; printf 'Source retro: reg-name/retros/r30b.md · 1\n'; } > "$ROOT/cache30.txt"
run "$box30" --all --issues-cache "$ROOT/cache30.txt"
if [ "$RC" = 0 ] && grep -q 'fleet-summary: tracked=2 untracked=0 .*retros=2' <<<"$OUT"; then
  ok "30 --all flat + corpus/retros of one target → both audited under the name" "(exit $RC)"
else
  no "30 --all flat + corpus/retros of one target → expected tracked=2 retros=2" "exit=$RC out=[$OUT]"
fi

# 31 — --all, TWO targets, one retros dir each at a different depth: first / last positions both
#      resolve (list edges), and a target with NEITHER retros nor corpus/retros still WARNs (the
#      anti-silent-zero message survives) without hiding the others.
box31="$(mkbox_all case-all-edges)"
mk_gh_stub "$box31" nomatch
rm -rf "$box31/rh/beta-target/retros"
mk_open_retro "$box31/rh/alpha-target/retros/r31a.md" >/dev/null
mk_open_retro "$box31/rh/beta-target/corpus/retros/r31b.md" >/dev/null
{ printf 'Source retro: alpha-target/retros/r31a.md · 1\n'; printf 'Source retro: beta-target/retros/r31b.md · 1\n'; } > "$ROOT/cache31.txt"
run "$box31" --all --issues-cache "$ROOT/cache31.txt"; out31a="$OUT"; rc31a=$RC
rm -rf "$box31/rh/beta-target/corpus"
run "$box31" --all --issues-cache "$ROOT/cache31.txt"; out31b="$OUT"; rc31b=$RC
if [ "$rc31a" = 0 ] && grep -q 'fleet-summary: tracked=2 untracked=0 .*retros=2' <<<"$out31a" \
  && [ "$rc31b" = 0 ] && grep -q 'fleet-summary: tracked=1 untracked=0 .*retros=1' <<<"$out31b" \
  && grep -q "WARN: no retros/ directory for target 'beta-target'" <<<"$out31b"; then
  ok "31 --all two targets (flat / corpus): both resolve; retro-less target still WARNs" "(rc=$rc31a/$rc31b)"
else
  no "31 --all two targets (flat / corpus)" "with-both=[$out31a] without-beta=[$out31b]"
fi

# 32 — SINGLE with NESTED REGISTERED targets: the NEAREST ancestor's name is the signature.
box32="$(mkbox case-sig-nested-registered)"
mk_gh_stub "$box32" nomatch
mk_targets "$box32" outer-name "$box32/rh/target-foo" inner-name "$box32/rh/target-foo/inner-t"
retro32="$(mk_open_retro "$box32/rh/target-foo/inner-t/retros/r32.md")"
cache_for "$ROOT/cache32.txt" inner-name r32.md
run "$box32" --issues-cache "$ROOT/cache32.txt" "$retro32"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT"; then
  ok "32 single, nested registered targets → nearest (inner) name is the signature" "(exit $RC)"
else
  no "32 single, nested registered targets → expected tracked via inner-name" "exit=$RC out=[$OUT]"
fi

# 33 — SINGLE with a raw `$RESEARCH_HOME/...` row token (the form every real row uses).
box33="$(mkbox case-sig-raw-rh)"
mk_gh_stub "$box33" nomatch
mk_targets "$box33" rh-name '$RESEARCH_HOME/rh/target-foo'
retro33="$(mk_open_retro "$box33/rh/target-foo/corpus/retros/r33.md")"
cache_for "$ROOT/cache33.txt" rh-name r33.md
RESEARCH_HOME="$box33" run "$box33" --issues-cache "$ROOT/cache33.txt" "$retro33"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT"; then
  ok "33 single, raw \$RESEARCH_HOME row token → registered name is the signature" "(exit $RC)"
else
  no "33 single, raw \$RESEARCH_HOME row token → expected tracked via rh-name" "exit=$RC out=[$OUT]"
fi

# 34 — OPERATIONAL failures (kit issue #1287 item 3): TARGETS.md absent / zero rows → exit 1 with a
#      typed message in SINGLE mode (was a WARN + basename guess that then reported untracked).
box34="$(mkbox case-targets-absent)"
mk_gh_stub "$box34" nomatch
retro34="$(mk_open_retro "$box34/rh/target-foo/retros/r34.md")"
: > "$ROOT/cache34.txt"
rm -f "$box34/research-sdd/TARGETS.md"
run "$box34" --issues-cache "$ROOT/cache34.txt" "$retro34"; out34a="$OUT"; rc34a=$RC
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n' > "$box34/research-sdd/TARGETS.md"
run "$box34" --issues-cache "$ROOT/cache34.txt" "$retro34"; out34b="$OUT"; rc34b=$RC
if [ "$rc34a" = 1 ] && grep -qi 'cannot read' <<<"$out34a" && ! grep -q '^untracked:' <<<"$out34a" \
  && [ "$rc34b" = 1 ] && grep -qi 'no registered target' <<<"$out34b" && ! grep -q '^untracked:' <<<"$out34b"; then
  ok "34 single: TARGETS.md absent / zero-row → exit 1, typed message, no verdict" "(rc=$rc34a/$rc34b)"
else
  no "34 single: TARGETS.md absent / zero-row → expected exit 1 + typed message" "absent=[$out34a] empty=[$out34b]"
fi

# 35 — UNREGISTERED: flat keeps the WARN + basename fallback; nested (structural basename) is refused.
box35="$(mkbox case-unregistered)"
mk_gh_stub "$box35" nomatch
mk_targets "$box35" other "$box35/rh/other"
mkdir -p "$box35/rh/other"
: > "$ROOT/cache35.txt"
retro35f="$(mk_open_retro "$box35/rh/target-foo/retros/r35f.md")"
retro35n="$(mk_open_retro "$box35/rh/target-foo/corpus/retros/r35n.md")"
run "$box35" --issues-cache "$ROOT/cache35.txt" "$retro35f"; out35f="$OUT"; rc35f=$RC
run "$box35" --issues-cache "$ROOT/cache35.txt" "$retro35n"; out35n="$OUT"; rc35n=$RC
if [ "$rc35f" = 0 ] && grep -qi "using basename 'target-foo'" <<<"$out35f" \
  && [ "$rc35n" = 1 ] && grep -qi 'cannot resolve target' <<<"$out35n" && ! grep -q '^untracked:' <<<"$out35n"; then
  ok "35 single: flat unregistered → WARN + basename; nested unregistered → exit 1" "(rc=$rc35f/$rc35n)"
else
  no "35 single: unregistered handling" "flat=[$out35f] nested=[$out35n]"
fi

# 36 — --all, an EMPTY flat retros/ next to a populated corpus/retros: no "no retro files" WARN (it
#      would claim the opposite of what was audited); an empty flat retros/ with NOTHING else still
#      WARNs (anti-silent-zero preserved).
box36="$(mkbox case-all-empty-flat)"
mk_gh_stub "$box36" nomatch
mk_targets "$box36" reg-name "$box36/rh/target-foo"
mk_open_retro "$box36/rh/target-foo/corpus/retros/r36.md" >/dev/null
cache_for "$ROOT/cache36.txt" reg-name r36.md
run "$box36" --all --issues-cache "$ROOT/cache36.txt"; out36a="$OUT"; rc36a=$RC
rm -rf "$box36/rh/target-foo/corpus"
run "$box36" --all --issues-cache "$ROOT/cache36.txt"; out36b="$OUT"; rc36b=$RC
if [ "$rc36a" = 0 ] && ! grep -q 'no retro files' <<<"$out36a" && grep -q 'retros=1' <<<"$out36a" \
  && [ "$rc36b" = 0 ] && grep -q "WARN: no retro files (\*.md) found in '.*/target-foo/retros'" <<<"$out36b"; then
  ok "36 --all: empty flat retros/ is quiet when corpus/retros has files, WARNs when nothing exists" "(rc=$rc36a/$rc36b)"
else
  no "36 --all: empty-flat WARN handling" "with-corpus=[$out36a] nothing=[$out36b]"
fi

# ---------------------------------------------------------------------------
# kit issue #1304 items 1+2 (reconcile side). The gh query is a fuzzy WORD search, so (1) its
# bodies may belong to ANOTHER target's issue — reading them with `Source retro: .+ · <id>` marked
# rows this retro does not have as tracked — and (2) the seeder also dedups the LEGACY
# `<path basename>/retros/<file>` signature, so reconcile must look for it too or an open
# legacy-signed issue reads as `untracked`.
LEG_BASE="Source retro: target-foo/retros"

# 37 — gh path: a hit that is ANOTHER target's issue (same file, same row id) is not this retro's.
box37="$(mkbox case-gh-fuzzy-other)"
mk_targets "$box37" reg-name "$box37/rh/target-foo"
mk_gh_stub "$box37" lines "Source retro: niagara-reg-name/retros/r37.md · 1"
retro37="$(mk_open_retro "$box37/rh/target-foo/retros/r37.md")"
run "$box37" "$retro37"
if [ "$RC" = 0 ] && grep -q '^untracked: row 1' <<<"$OUT" && ! grep -q '^tracked:' <<<"$OUT" && ! grep -q '^orphaned:' <<<"$OUT"; then
  ok "37 gh path: another target's issue for the same row is NOT tracked (and not orphaned)" "(exit $RC)"
else
  no "37 gh path: another target's issue must not count" "exit=$RC out=[$OUT]"
fi

# 37b — control: the same query returning THIS retro's signature IS tracked.
box37b="$(mkbox case-gh-exact)"
mk_targets "$box37b" reg-name "$box37b/rh/target-foo"
mk_gh_stub "$box37b" lines "Source retro: reg-name/retros/r37b.md · 1"
retro37b="$(mk_open_retro "$box37b/rh/target-foo/retros/r37b.md")"
run "$box37b" "$retro37b"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "37b gh path control: this retro's own signature → tracked" "(exit $RC)"
else
  no "37b gh path control: expected tracked" "exit=$RC out=[$OUT]"
fi

# 38 — cache path: an OPEN legacy-signed issue (registered name != basename) is tracked.
#      RED pre-fix: only the registered-name signature was read, so row 1 was `untracked`.
box38="$(mkbox case-legacy-cache)"
mk_targets "$box38" reg-name "$box38/rh/target-foo"
mk_gh_stub "$box38" nomatch
retro38="$(mk_open_retro "$box38/rh/target-foo/retros/r38.md")"
printf '%s/r38.md · 1\n' "$LEG_BASE" > "$ROOT/cache38.txt"
run "$box38" --issues-cache "$ROOT/cache38.txt" "$retro38"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "38 cache path: open legacy-signature issue → tracked" "(exit $RC)"
else
  no "38 cache path: open legacy-signature issue → expected tracked" "exit=$RC out=[$OUT]"
fi

# 38b — gh path: the legacy signature is QUERIED (two list calls, one per signature) and found.
box38b="$(mkbox case-legacy-gh)"
mk_targets "$box38b" reg-name "$box38b/rh/target-foo"
mk_gh_stub "$box38b" lines "$LEG_BASE/r38b.md · 1" "Source retro: target-foo/retros/r38b.md"
retro38b="$(mk_open_retro "$box38b/rh/target-foo/retros/r38b.md")"
run "$box38b" "$retro38b"
lists38b="$(grep -c 'issue list' "$box38b/bin/gh.log")"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && [ "$lists38b" = 2 ] \
  && grep -qF 'Source retro: reg-name/retros/r38b.md' "$box38b/bin/gh.log"; then
  ok "38b gh path: legacy signature queried (2 list calls) and an open legacy issue → tracked" "(exit $RC lists=$lists38b)"
else
  no "38b gh path: expected both signatures queried and tracked" "exit=$RC lists=$lists38b out=[$OUT]"
fi

# 38c — name == basename: exactly ONE list call (no legacy lookup for the common case).
box38c="$(mkbox case-legacy-same)"
mk_targets "$box38c" target-foo "$box38c/rh/target-foo"
mk_gh_stub "$box38c" nomatch
retro38c="$(mk_open_retro "$box38c/rh/target-foo/retros/r38c.md")"
run "$box38c" "$retro38c"
lists38c="$(grep -c 'issue list' "$box38c/bin/gh.log")"
if [ "$RC" = 0 ] && [ "$lists38c" = 1 ]; then ok "38c name == basename → exactly one list call" "(lists=$lists38c)"
else no "38c name == basename → expected one list call" "exit=$RC lists=$lists38c out=[$OUT]"; fi

# 38d — nested <target>/corpus/retros: the legacy name would be `corpus` (structural) → no legacy
#       lookup, one list call, and a cache line signed `corpus/retros/...` is never read.
box38d="$(mkbox case-legacy-structural)"
mk_targets "$box38d" reg-name "$box38d/rh/target-foo"
mk_gh_stub "$box38d" nomatch
retro38d="$(mk_open_retro "$box38d/rh/target-foo/corpus/retros/r38d.md")"
run "$box38d" "$retro38d"
lists38d="$(grep -c 'issue list' "$box38d/bin/gh.log")"
if [ "$RC" = 0 ] && [ "$lists38d" = 1 ] && ! grep -qF 'Source retro: corpus/retros' "$box38d/bin/gh.log"; then
  ok "38d nested corpus/retros → structural legacy name skipped (one list call)" "(lists=$lists38d)"
else
  no "38d nested corpus/retros → expected no legacy lookup" "exit=$RC lists=$lists38d log=[$(cat "$box38d/bin/gh.log")]"
fi

# 38e — orphan symmetry: an open legacy-signed issue for a row that is no longer open is orphaned.
box38e="$(mkbox case-legacy-orphan)"
mk_targets "$box38e" reg-name "$box38e/rh/target-foo"
mk_gh_stub "$box38e" nomatch
retro38e="$(mk_open_retro "$box38e/rh/target-foo/retros/r38e.md")"
printf '%s/r38e.md · 7\n' "$LEG_BASE" > "$ROOT/cache38e.txt"
run "$box38e" --issues-cache "$ROOT/cache38e.txt" "$retro38e"
if [ "$RC" = 0 ] && grep -q '^orphaned: issue for row 7' <<<"$OUT" && grep -q '^untracked: row 1' <<<"$OUT"; then
  ok "38e cache path: legacy-signed issue for a no-longer-open row → orphaned; row 1 still untracked" "(exit $RC)"
else
  no "38e cache path: expected orphaned row 7 + untracked row 1" "exit=$RC out=[$OUT]"
fi

# 38f — LIST EDGE: BOTH signatures present in one cache, different rows → both rows are seen.
box38f="$(mkbox case-legacy-both)"
mk_targets "$box38f" reg-name "$box38f/rh/target-foo"
mk_gh_stub "$box38f" nomatch
retro38f="$box38f/rh/target-foo/retros/r38f.md"
mkdir -p "$(dirname "$retro38f")"
{
  printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf '| 1 | first | CLAUDE.md | B1 | fix | HIGH |\n| 2 | second | CLAUDE.md | B2 | fix | HIGH |\n'
} > "$retro38f"
printf 'Source retro: reg-name/retros/r38f.md · 1\n%s/r38f.md · 2\n' "$LEG_BASE" > "$ROOT/cache38f.txt"
run "$box38f" --issues-cache "$ROOT/cache38f.txt" "$retro38f"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && grep -q '^tracked: row 2' <<<"$OUT" && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "38f cache path: new-signature row 1 + legacy-signature row 2 → both tracked" "(exit $RC)"
else
  no "38f cache path: expected rows 1 and 2 tracked" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 39 — ENTRY FORM (kit issue #1332 item 2): the doctrine-valid `### D<N> —` entries under the
#      canonical heading are COUNTABLE (sweep-retros form 2). reconcile used to read only table
#      rows, so an applied retro in this form was reported `unclassifiable` while the seeder said
#      `no-match: retro is 'applied'` — two instruments, two answers for one input.
ENTRY_FIX="$HERE/fixtures/retro-entry-form-applied-3.md"
[ -f "$ENTRY_FIX" ] || { echo "FATAL: fixture missing: $ENTRY_FIX" >&2; exit 2; }
box39a="$(mkbox case-entry-applied)"; mk_gh_stub "$box39a" nomatch
cp "$ENTRY_FIX" "$box39a/rh/target-foo/retros/r39a.md"
run "$box39a" --issues-cache /dev/null "$box39a/rh/target-foo/retros/r39a.md"
if [ "$RC" = 0 ] && ! grep -q 'unclassifiable' <<<"$OUT" && grep -q '^no-match: no open deltas' <<<"$OUT" && ! grep -q '^untracked:' <<<"$OUT"; then
  ok "39a applied retro in ### D<N> entry form → no-match (not unclassifiable, not untracked)" "(exit $RC)"
else
  no "39a applied entry-form retro" "exit=$RC out=[$OUT]"
fi

# 39b — PENDING entry-form retro: every entry is an open row; a cache holding D2 only → D2 tracked,
#       D1 and D3 untracked (first / middle / last positions all enumerated).
box39b="$(mkbox case-entry-pending)"; mk_gh_stub "$box39b" nomatch
sed 's/^<!-- review-status: applied.*-->$/<!-- review-status: pending -->/' "$ENTRY_FIX" > "$box39b/rh/target-foo/retros/r39b.md"
cache_for "$ROOT/cache39b.txt" target-foo r39b.md D2
run "$box39b" --issues-cache "$ROOT/cache39b.txt" "$box39b/rh/target-foo/retros/r39b.md"
if [ "$RC" = 0 ] && grep -q '^untracked: row D1 ' <<<"$OUT" && grep -q '^tracked: row D2 ' <<<"$OUT" \
   && grep -q '^untracked: row D3 ' <<<"$OUT" && ! grep -q 'unclassifiable' <<<"$OUT"; then
  ok "39b pending entry-form retro: D1 untracked / D2 tracked / D3 untracked (list edges)" "(exit $RC)"
else
  no "39b pending entry-form retro" "exit=$RC out=[$OUT]"
fi

# 39c — ORPHAN: an open issue for D9 (no such entry in the retro) is orphaned in entry form too.
printf 'Source retro: target-foo/retros/r39b.md · D9\n' > "$ROOT/cache39c.txt"
run "$box39b" --issues-cache "$ROOT/cache39c.txt" "$box39b/rh/target-foo/retros/r39b.md"
if [ "$RC" = 0 ] && grep -q '^orphaned: issue for row D9' <<<"$OUT"; then
  ok "39c entry-form retro: issue for an absent entry D9 → orphaned" "(exit $RC)"
else
  no "39c entry-form orphan" "exit=$RC out=[$OUT]"
fi

# 39d — a canonical section with NEITHER table rows NOR entries still reports unclassifiable
#       (the entry fallback must not turn the typed finding into a silent pass).
box39d="$(mkbox case-entry-none)"; mk_gh_stub "$box39d" nomatch
printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\nSome prose about a delta, no table, no entries.\n' > "$box39d/rh/target-foo/retros/r39d.md"
run "$box39d" --issues-cache /dev/null "$box39d/rh/target-foo/retros/r39d.md"
if [ "$RC" = 0 ] && grep -q "^unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries" <<<"$OUT"; then
  ok "39d canonical section, no rows, no entries → still unclassifiable" "(exit $RC)"
else
  no "39d no rows/no entries must stay unclassifiable" "exit=$RC out=[$OUT]"
fi


# 39e (kit issue #1332 N6) — an entry whose heading token is not a usable ID (`### **D1** —`) is a
#      latent false negative: WARN that fewer IDs than form-2 entries were found.
box39e="$(mkbox case-entry-gap)"; mk_gh_stub "$box39e" nomatch
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### **D1** — bold id\n\n### D2 — plain id\n' > "$box39e/rh/target-foo/retros/r39e.md"
run "$box39e" --issues-cache /dev/null "$box39e/rh/target-foo/retros/r39e.md"
if [ "$RC" = 0 ] && grep -q '^WARN: .*1 of 2' <<<"$OUT" && grep -q '^untracked: row D2 ' <<<"$OUT"; then
  ok "39e entry with an unusable ID token → WARN '1 of 2', usable entry still reported" "(exit $RC)"
else
  no "39e entry ID gap WARN" "exit=$RC out=[$OUT]"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
