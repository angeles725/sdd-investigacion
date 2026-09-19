#!/usr/bin/env bash
# reconcile-issues.test.sh — TDD harness for reconcile-issues.sh.
#
# Covers: absent-input (file not found); empty-input (no delta section);
# no-match (applied retro, no orphaned issues); tracked (stub returns matching
# issue); untracked (stub returns no issue); orphaned (stub returns signature
# for a now-shipped row); degraded (gh absent from PATH); --all over >=2 targets.
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

fi  # --prove-teeth

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
