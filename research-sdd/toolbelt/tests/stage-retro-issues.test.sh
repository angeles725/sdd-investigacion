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
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
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

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# SANDBOX BUILDER
# mkbox <name> [target-name]
#   Creates a hermetic sandbox:
#     $box/
#       research-sdd/
#         TARGETS.md          — one-row table pointing at $box/rh/<target>
#         toolbelt/
#           stage-retro-issues.sh   (copy of SUT)
#           lib/               (copies of required libs)
#       rh/<target>/retros/    (where test retros land)
#       bin/                   (gh stub, if mk_gh_stub is called after)
#   Returns the box path (no trailing newline; echoes to stdout).
mkbox() {
  local name="$1" tgt="${2:-target-foo}"
  local box="$ROOT/$name"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/$tgt/retros" "$box/bin"
  cp "$SUT"              "$box/research-sdd/toolbelt/stage-retro-issues.sh"
  cp "$RETRO_STATUS_LIB" "$box/research-sdd/toolbelt/lib/retro-status.sh"
  cp "$RETRO_GRAMMAR_LIB" "$box/research-sdd/toolbelt/lib/retro-grammar.sh"
  cp "$TARGET_PATHS_LIB" "$box/research-sdd/toolbelt/lib/target-paths.sh"
  # TARGETS.md with an absolute path so target_paths_all resolves correctly
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | %s | `%s` |\n' "$tgt" "$box/rh/$tgt"
  } > "$box/research-sdd/TARGETS.md"
  printf '%s' "$box"
}

# mk_gh_stub <box> [mode]
#   mode=noauth     : `gh auth status` fails (unauthenticated)
#   mode=match      : `gh issue list` returns a fake existing match (dedup)
#   mode=nomatch    : `gh issue list` returns empty (no existing issue)  [default]
#   mode=createfail : `gh issue list` returns empty; `gh issue create` exits 1 (simulates API error)
#   In all non-noauth modes: `gh issue create` logs its args and echoes a fake URL (except createfail).
mk_gh_stub() {
  local box="$1" mode="${2:-nomatch}"
  {
    printf '#!%s\n' "$BASH_BIN"
    # Log all calls for inspection
    printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box"
    if [ "$mode" = "noauth" ]; then
      printf 'case " $* " in\n'
      printf '  *" auth status "*) exit 1 ;;\n'
      printf '  *) exit 0 ;;\n'
      printf 'esac\n'
    else
      printf 'case " $* " in\n'
      printf '  *" auth status "*) exit 0 ;;\n'
      if [ "$mode" = "match" ]; then
        # Return a fake issue when searching for any Source retro signature
        printf '  *" issue list "*) printf "42\\thttps://github.com/r/issues/42\\tSource retro match\\n"; exit 0 ;;\n'
      else
        # nomatch / createfail: empty list
        printf '  *" issue list "*) exit 0 ;;\n'
      fi
      if [ "$mode" = "createfail" ]; then
        # createfail: gh issue create exits 1 to simulate an API error
        printf '  *" issue create "*) printf "ERROR: GraphQL request failed\\n"; exit 1 ;;\n'
      else
        printf '  *" issue create "*) printf "https://github.com/r/issues/99\\n"; exit 0 ;;\n'
      fi
      printf '  *) exit 0 ;;\n'
      printf 'esac\n'
    fi
  } > "$box/bin/gh"
  chmod +x "$box/bin/gh"
}

# mk_retro <box> <target> <filename> <marker> <table-content>
#   Writes a retro file at $box/rh/<target>/retros/<filename>.
#   <marker>        : the leading HTML comment line, or "-" for none
#   <table-content> : extra lines appended AFTER the canonical header/separator
#                     (pass "" for an empty table, "-" to skip the delta section entirely)
mk_retro() {
  local box="$1" tgt="$2" fname="$3" marker="$4" table_content="$5"
  local f="$box/rh/$tgt/retros/$fname"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    if [ "$table_content" = "-" ]; then
      # No delta section
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

# run <box> <retro-path> [extra-args...]
#   Invoke the sandbox SUT copy; capture stdout+stderr into OUT, RC into RC.
run() {
  local box="$1" retro="$2"; shift 2
  OUT="$(PATH="$box/bin:$PATH" \
    "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" \
    "$retro" "$@" 2>&1)"; RC=$?
}

echo "== stage-retro-issues.test.sh =="

# ---------------------------------------------------------------------------
# 1 — ABSENT-INPUT: retro file not found → typed absent-input message, exit 1
box="$(mkbox case-absent)"
run "$box" "$box/rh/target-foo/retros/does-not-exist.md"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qi 'absent-input'; then
  ok "1 absent-input: missing retro → exit 1 + absent-input message" "(exit $RC)"
else
  no "1 absent-input: missing retro → exit 1 + absent-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 2 — EMPTY-INPUT: retro has no delta section → typed empty-input, exit 0
box="$(mkbox case-empty)"
retro="$(mk_retro "$box" target-foo r-empty.md "<!-- review-status: pending -->" "-")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'empty-input'; then
  ok "2 empty-input: no delta section → exit 0 + empty-input message" "(exit $RC)"
else
  no "2 empty-input: no delta section → exit 0 + empty-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 3 — NO-MATCH: all rows shipped/applied → typed no-match, exit 0
box="$(mkbox case-nomatc)"
retro="$(mk_retro "$box" target-foo r-applied.md \
  "<!-- review-status: applied 2026-01-01 · kit abc1234 -->" \
  "| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'no-match\|all.*shipped\|no open'; then
  ok "3 no-match: applied retro → exit 0 + no-match message" "(exit $RC)"
else
  no "3 no-match: applied retro → exit 0 + no-match message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 4 — PENDING RETRO DRY-RUN: pending marker, 2 rows → 2 planned issues printed
box="$(mkbox case-pending)"
retro="$(mk_retro "$box" target-foo r-pending.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | Add session cost instrument | CLAUDE.md §5 | B10 | new | HIGH |\n| 2 | Fix anti-silent-zero in sweep | sweep-retros.sh | B20 | fix | LOW |')")"
run "$box" "$retro"
issue_count="$(printf '%s\n' "$OUT" | grep -c 'planned-issue:' || true)"
if [ "$RC" = 0 ] \
   && [ "$issue_count" -ge 2 ] \
   && printf '%s' "$OUT" | grep -q 'status:needs-review' \
   && printf '%s' "$OUT" | grep -q 'target:target-foo' \
   && printf '%s' "$OUT" | grep -q 'Source retro:.*r-pending\.md.*·.*1'; then
  ok "4 pending retro dry-run → 2 planned issues, correct labels + source line" "(exit $RC)"
else
  no "4 pending retro dry-run → 2 planned issues, correct labels + source line" \
    "exit=$RC issues=$issue_count out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 5 — PARTIAL MARKER: only NON-shipped rows are open
#   Marker: applied · sha · PARTIAL — shipped: 1; deferred: 2
#   Row 1 is shipped → skip. Row 2 is deferred (not shipped) → open.
box="$(mkbox case-partial)"
retro="$(mk_retro "$box" target-foo r-partial.md \
  "<!-- review-status: applied 2026-06-01 · kit deadbeef · PARTIAL — shipped: 1; deferred: 2 -->" \
  "$(printf '| 1 | shipped delta | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | deferred delta | CLAUDE.md | B2 | new | MEDIUM |')")"
run "$box" "$retro"
row2_found=0; row1_found=0
printf '%s\n' "$OUT" | grep -q '· 2' && row2_found=1
printf '%s\n' "$OUT" | grep -q '· 1' && row1_found=1
if [ "$RC" = 0 ] && [ "$row2_found" = 1 ] && [ "$row1_found" = 0 ]; then
  ok "5 partial marker: only deferred row 2 emitted, shipped row 1 skipped" "(exit $RC)"
else
  no "5 partial marker: only deferred row 2 emitted, shipped row 1 skipped" \
    "exit=$RC row1=$row1_found row2=$row2_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 6 — WRONG-KIT ROW: row whose Target cell names another kit → skipped-wrong-kit
box="$(mkbox case-wrongkit)"
retro="$(mk_retro "$box" target-foo r-wrongkit.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | normal delta | CLAUDE.md §7 | B1 | new | HIGH |\n| 2 | wrong kit delta | build-n4-module-kit: METHODOLOGY.md §3 | B2 | new | LOW |')")"
run "$box" "$retro"
wrong_skipped=0; normal_found=0
printf '%s\n' "$OUT" | grep -qi 'skipped-wrong-kit\|wrong.kit' && wrong_skipped=1
printf '%s\n' "$OUT" | grep -q '· 1' && normal_found=1
if [ "$RC" = 0 ] && [ "$wrong_skipped" = 1 ] && [ "$normal_found" = 1 ]; then
  ok "6 wrong-kit row: skipped with report, normal row still planned" "(exit $RC)"
else
  no "6 wrong-kit row: skipped with report, normal row still planned" \
    "exit=$RC wrong_skipped=$wrong_skipped normal=$normal_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 7 — NO-PRIORITY ROW: row with "—" in priority column → priority label omitted
box="$(mkbox case-noprio)"
retro="$(mk_retro "$box" target-foo r-noprio.md \
  "<!-- review-status: pending -->" \
  "| 1 | delta with no priority | METHODOLOGY.md | B1 | new | — |")"
run "$box" "$retro"
has_label=0; has_noprio_signal=0
printf '%s\n' "$OUT" | grep -q 'priority:' && has_label=1
printf '%s\n' "$OUT" | grep -q 'status:needs-review' && has_noprio_signal=1
if [ "$RC" = 0 ] && [ "$has_label" = 0 ] && [ "$has_noprio_signal" = 1 ]; then
  ok "7 no-priority row: priority label omitted, other labels present" "(exit $RC)"
else
  no "7 no-priority row: priority label omitted, other labels present" \
    "exit=$RC has_priority_label=$has_label has_needs_review=$has_noprio_signal out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 8 — APPLY MODE CREATES ISSUE: --apply with nomatch stub → gh issue create called
box="$(mkbox case-apply-create)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | create this issue | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
# Expect gh issue create to have been called
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
if [ "$RC" = 0 ] && [ "$create_called" = 1 ]; then
  ok "8 --apply nomatch: gh issue create called" "(exit $RC)"
else
  no "8 --apply nomatch: gh issue create called" "exit=$RC create_called=$create_called out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9 — APPLY MODE DEDUP: --apply with match stub → issue creation skipped
box="$(mkbox case-apply-dedup)"
mk_gh_stub "$box" match
retro="$(mk_retro "$box" target-foo r-dedup.md \
  "<!-- review-status: pending -->" \
  "| 1 | existing issue | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
# Expect creation NOT called, but skipped-duplicate reported
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
dup_reported=0
printf '%s\n' "$OUT" | grep -qi 'skipped-duplicate\|already.*exists\|dedup' && dup_reported=1
if [ "$RC" = 0 ] && [ "$create_called" = 0 ] && [ "$dup_reported" = 1 ]; then
  ok "9 --apply match: dedup skips create, reports skipped-duplicate" "(exit $RC)"
else
  no "9 --apply match: dedup skips create, reports skipped-duplicate" \
    "exit=$RC create_called=$create_called dup_reported=$dup_reported out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 10 — DEGRADED on missing gh under --apply (hermetic PATH: no gh available)
box="$(mkbox case-degraded)"
mk_hermetic_bin "$box"   # essentials only, NO gh
_deg_retro="$(mk_retro "$box" target-foo r-deg.md "<!-- review-status: pending -->" \
  "| 1 | d | CLAUDE.md | B1 | new | HIGH |")"
# Run with a FULLY hermetic PATH so no system gh can be found
OUT10="$(PATH="$box/bin" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" \
  "$_deg_retro" --apply 2>&1)"; RC10=$?
if [ "$RC10" != 0 ] && printf '%s' "$OUT10" | grep -qi 'degraded'; then
  ok "10 degraded: missing gh under --apply → non-zero + degraded message" "(exit $RC10)"
else
  no "10 degraded: missing gh under --apply → non-zero + degraded message" \
    "exit=$RC10 out=[$OUT10]"
fi

# ---------------------------------------------------------------------------
# 11 — SOURCE RETRO LINE: body contains 'Source retro: ...' + 'rollout #557'
box="$(mkbox case-srcline)"
retro="$(mk_retro "$box" target-foo r-src.md \
  "<!-- review-status: pending -->" \
  "| 1 | delta text | CLAUDE.md §7 | B1 | new | MEDIUM |")"
run "$box" "$retro"
has_src=0; has_rollout=0
printf '%s\n' "$OUT" | grep -q 'Source retro:.*r-src\.md.*·.*1' && has_src=1
printf '%s\n' "$OUT" | grep -q 'rollout #557' && has_rollout=1
if [ "$RC" = 0 ] && [ "$has_src" = 1 ] && [ "$has_rollout" = 1 ]; then
  ok "11 source retro line: body has Source retro + rollout #557" "(exit $RC)"
else
  no "11 source retro line: body has Source retro + rollout #557" \
    "exit=$RC src=$has_src rollout=$has_rollout out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 12 — TYPE LABEL MAPPING: new→feature, fix→bug, doc→docs
box="$(mkbox case-types)"
retro="$(mk_retro "$box" target-foo r-types.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | feature delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | bug delta | CLAUDE.md | B2 | fix | HIGH |\n| 3 | doc delta | CLAUDE.md | B3 | docs | HIGH |')")"
run "$box" "$retro"
feat_found=0; bug_found=0; docs_found=0
printf '%s\n' "$OUT" | grep -q 'type:feature' && feat_found=1
printf '%s\n' "$OUT" | grep -q 'type:bug'     && bug_found=1
printf '%s\n' "$OUT" | grep -q 'type:docs'    && docs_found=1
if [ "$RC" = 0 ] && [ "$feat_found" = 1 ] && [ "$bug_found" = 1 ] && [ "$docs_found" = 1 ]; then
  ok "12 type label mapping: new→feature, fix→bug, docs→docs" "(exit $RC)"
else
  no "12 type label mapping: new→feature, fix→bug, docs→docs" \
    "exit=$RC feat=$feat_found bug=$bug_found docs=$docs_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 13 — DEPRECATED ALIAS HEADING: deprecated alias still surfaces open rows
# The retro-grammar lib accepts "## Summary of proposed deltas" as a deprecated alias
box="$(mkbox case-depr)"
cat > "$box/rh/target-foo/retros/r-depr.md" <<'EOF'
<!-- review-status: pending -->
# retro

## Summary of proposed deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | delta from deprecated heading | CLAUDE.md §3 | B1 | new | LOW |
EOF
run "$box" "$box/rh/target-foo/retros/r-depr.md"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q 'planned-issue:'; then
  ok "13 deprecated alias heading: rows extracted from Summary of proposed deltas" "(exit $RC)"
else
  no "13 deprecated alias heading: rows extracted from Summary of proposed deltas" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 14 — BOLD LEAD-IN TITLE: cell opens with **phrase.** detail → title is phrase only
# The bug: strip_md_bold stripped the opening ** but left the closing ** in the
# middle, producing "phrase.** detail..." in the title.  After the fix, the title
# must be the bolded phrase only, with no stray **.
box="$(mkbox case-bold-lead)"
retro="$(mk_retro "$box" target-foo r-bold.md \
  "<!-- review-status: pending -->" \
  "| 1 | **Bold summary sentence.** Detail text explaining the change. | CLAUDE.md | B1 | new | HIGH |")"
run "$box" "$retro"
title_line14="$(printf '%s\n' "$OUT" | grep '^planned-issue:')"
bold_title_ok=0
if printf '%s\n' "$title_line14" | grep -q 'Bold summary sentence\.' \
   && ! printf '%s\n' "$title_line14" | grep -q '\*\*'; then
  bold_title_ok=1
fi
if [ "$RC" = 0 ] && [ "$bold_title_ok" = 1 ]; then
  ok "14 bold lead-in title: bolded phrase used as title, no stray **" "(exit $RC)"
else
  no "14 bold lead-in title: bolded phrase used as title, no stray **" \
    "exit=$RC bold_ok=$bold_title_ok title=[$title_line14]"
fi

# ---------------------------------------------------------------------------
# 15 — PLAIN CELL REGRESSION: cell with no bold markers → title unchanged
# Ensures the bold-lead fix does not alter plain (non-bold) delta cells.
box="$(mkbox case-plain-title)"
retro="$(mk_retro "$box" target-foo r-plain.md \
  "<!-- review-status: pending -->" \
  "| 1 | Plain text delta without bold markers here. | CLAUDE.md | B1 | new | HIGH |")"
run "$box" "$retro"
title_line15="$(printf '%s\n' "$OUT" | grep '^planned-issue:')"
plain_title_ok=0
if printf '%s\n' "$title_line15" | grep -q 'Plain text delta without bold markers here\.'; then
  plain_title_ok=1
fi
if [ "$RC" = 0 ] && [ "$plain_title_ok" = 1 ]; then
  ok "15 plain cell regression: plain cell title unchanged by bold-lead fix" "(exit $RC)"
else
  no "15 plain cell regression: plain cell title unchanged by bold-lead fix" \
    "exit=$RC plain_ok=$plain_title_ok title=[$title_line15]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative controls for --prove-teeth)
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  sut_content="$(cat "$SUT")"

  # TOOTH 1: Neuter the no-match early-exit guard for applied/dismissed retros.
  # The anchor is the compound statement that prints "no-match" and exits 0 for
  # fully applied/dismissed retros. Neutering it allows rows to appear because the
  # row loop only skips shipped rows (is_partial=0 → nothing skipped there either).
  echo "-- teeth T1: neuter applied/dismissed no-match early exit --"
  anchor_t1='[ $is_partial -eq 0 ] && { echo "no-match: retro is '"'"'$status'"'"' — all rows shipped" >&2; exit 0; }'
  if [[ "$sut_content" == *"$anchor_t1"* ]]; then
    box_t1="$(mkbox teeth-applied)"
    retro_t1="$(mk_retro "$box_t1" target-foo r.md \
      "<!-- review-status: applied 2026-01-01 · kit abc1234 -->" \
      "| 1 | should appear when guard removed | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t1="$box_t1/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the guard with a no-op: rows now reach the loop (is_partial=0 skips nothing)
    printf '%s\n' "${sut_content/"$anchor_t1"/: # teeth-t1-nomatch-guard-removed}" > "$mutant_t1"
    out_t1="$(PATH="$box_t1/bin:$PATH" \
      "$BASH_BIN" "$mutant_t1" "$retro_t1" 2>&1)"; rc_t1=$?
    if printf '%s\n' "$out_t1" | grep -q 'planned-issue:'; then
      ok "T1 teeth: no-match guard neutered → rows appear for applied retro (case 3 has teeth)" "()"
    else
      no "T1 teeth: no-match guard neutered → rows appear for applied retro" \
        "mutant did not emit planned-issue — case 3 is THEATER: rc=$rc_t1 out=[$out_t1]"
    fi
  else
    no "T1 teeth: locate no-match guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 2: Neuter is_wrong_kit body → wrong-kit row is planned instead of skipped.
  # The anchor is the grep pattern inside is_wrong_kit that detects another-kit target cells.
  echo "-- teeth T2: neuter is_wrong_kit detection --"
  anchor_t2="  printf '%s' \"\$1\" | grep -qiE '[-a-zA-Z0-9]+-kit[:/]'"
  if [[ "$sut_content" == *"$anchor_t2"* ]]; then
    box_t2="$(mkbox teeth-wrongkit)"
    retro_t2="$(mk_retro "$box_t2" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | wrong kit delta | build-n4-module-kit: METHODOLOGY.md §3 | B1 | new | HIGH |")"
    mutant_t2="$box_t2/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the grep inside is_wrong_kit with one that never matches → function always returns 1
    printf '%s\n' "${sut_content/"$anchor_t2"/  false}" > "$mutant_t2"
    out_t2="$(PATH="$box_t2/bin:$PATH" \
      "$BASH_BIN" "$mutant_t2" "$retro_t2" 2>&1)"; rc_t2=$?
    if printf '%s\n' "$out_t2" | grep -q 'planned-issue:'; then
      ok "T2 teeth: is_wrong_kit neutered → wrong-kit row planned (case 6 has teeth)" "()"
    else
      no "T2 teeth: is_wrong_kit neutered → wrong-kit row planned" \
        "row not in output — case 6 is THEATER: rc=$rc_t2 out=[$out_t2]"
    fi
  else
    no "T2 teeth: locate is_wrong_kit grep anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 3: Neuter the dedup check → gh issue create is called even when a match exists.
  # The anchor is the comment + condition line that guards creation on a found duplicate.
  echo "-- teeth T3: neuter dedup check condition --"
  anchor_t3='    # STAGE_RETRO_ISSUES_DEDUP_CHECK: anchor for T3 teeth proof — skip create when match found.'
  if [[ "$sut_content" == *"$anchor_t3"* ]]; then
    box_t3="$(mkbox teeth-dedup)"
    mk_gh_stub "$box_t3" match
    retro_t3="$(mk_retro "$box_t3" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | existing delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t3="$box_t3/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the anchor comment (and thus the guard block context) with a no-op.
    # To also neuter the `if [ -n "$_existing" ]` that follows, replace the whole dedup if-block:
    # anchor the comment + next if line together.
    anchor_t3b="${anchor_t3}
    if [ -n \"\$_existing\" ]; then"
    if [[ "$sut_content" == *"$anchor_t3b"* ]]; then
      printf '%s\n' "${sut_content/"$anchor_t3b"/    # dedup check removed for teeth test
    if false; then}" > "$mutant_t3"
    else
      # Fallback: just replace the single-line anchor (leaves the if block)
      printf '%s\n' "${sut_content/"$anchor_t3"/    : # teeth-t3-dedup-anchor-removed}" > "$mutant_t3"
    fi
    out_t3="$(PATH="$box_t3/bin:$PATH" \
      "$BASH_BIN" "$mutant_t3" "$retro_t3" --apply 2>&1)"; rc_t3=$?
    create_called_t3=0
    [ -f "$box_t3/bin/gh.log" ] && grep -q 'issue create' "$box_t3/bin/gh.log" \
      && create_called_t3=1
    if [ "$create_called_t3" = 1 ]; then
      ok "T3 teeth: dedup guard neutered → create called despite match (case 9 has teeth)" "()"
    else
      no "T3 teeth: dedup guard neutered → create called despite match" \
        "create not called — case 9 is THEATER: rc=$rc_t3 out=[$out_t3]"
    fi
  else
    no "T3 teeth: locate dedup check anchor" "anchor comment not found in SUT — SUT drifted?"
  fi

  # TOOTH 4: Replace the strip_md_bold CALL SITE with a raw _delta assignment.
  # Anchor: the call-site line that invokes strip_md_bold.  For a bold-lead-in
  # cell, skipping strip_md_bold leaves ** markers in the raw _delta → stray **.
  # The STAGE_RETRO_ISSUES_BOLD_LEAD sentinel in the SUT confirms this version.
  echo "-- teeth T4: skip strip_md_bold call → raw delta used as title --"
  anchor_t4='  _title="$(strip_md_bold "$_delta")"'
  if [[ "$sut_content" == *"$anchor_t4"* ]]; then
    box_t4="$(mkbox teeth-bold)"
    retro_t4="$(mk_retro "$box_t4" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | **Bold summary sentence.** Detail text explaining the change here. | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t4="$box_t4/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the call site so _title gets the raw _delta (bold markers intact).
    printf '%s\n' "${sut_content/"$anchor_t4"/  _title=\"\$_delta\"  # T4-teeth: raw delta}" \
      > "$mutant_t4"
    out_t4="$(PATH="$box_t4/bin:$PATH" \
      "$BASH_BIN" "$mutant_t4" "$retro_t4" 2>&1)"; rc_t4=$?
    title_t4="$(printf '%s\n' "$out_t4" | grep '^planned-issue:')"
    if printf '%s\n' "$title_t4" | grep -q '\*\*'; then
      ok "T4 teeth: strip_md_bold skipped → raw ** in title (cases 14+15 have teeth)" "()"
    else
      no "T4 teeth: strip_md_bold skipped → raw ** expected in title" \
        "no ** found — cases 14+15 are THEATER: rc=$rc_t4 title=[$title_t4]"
    fi
  else
    no "T4 teeth: locate strip_md_bold call-site anchor" \
      "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 5: Remove the `failed=$((failed+1))` increment → failed stays 0 → summary shows failed=0
  # and the process exits 0 even when creates fail.
  # Uses sed on a COPY to avoid bash variable-expansion issues in the anchor string.
  # Anchor: the literal text 'failed=$((failed+1)); continue' on its own line in the SUT.
  echo "-- teeth T5: remove failed counter increment; summary must show failed=0, exit 0 (case 16 has teeth) --"
  if grep -qF 'failed=$((failed+1)); continue' "$SUT" 2>/dev/null; then
    box_t5="$(mkbox teeth-failed)"
    mk_gh_stub "$box_t5" createfail
    retro_t5="$(mk_retro "$box_t5" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | fail delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t5="$box_t5/research-sdd/toolbelt/stage-retro-issues.sh"
    # Remove the increment, keeping only 'continue'; sed replaces the whole token-containing line.
    sed 's/failed=\$((failed+1)); continue/continue  # T5-teeth-no-increment/' \
      "$SUT" > "$mutant_t5"
    bash -n "$mutant_t5" 2>/dev/null || { no "T5 teeth: mutant_t5 failed bash -n syntax check" ""; }
    out_t5="$(PATH="$box_t5/bin:$PATH" \
      "$BASH_BIN" "$mutant_t5" "$retro_t5" --apply 2>&1)"; rc_t5=$?
    sum_t5="$(printf '%s\n' "$out_t5" | grep '^summary:')"
    # With the counter removed: failed=0, exit 0 → case 16's assertion (rc_nonzero=1, failed>0) goes RED
    if [ "$rc_t5" -eq 0 ] || printf '%s' "$sum_t5" | grep -qE 'failed=0\b'; then
      ok "T5 teeth: failed counter removed → failed=0 / exit 0 (case 16 has teeth)" "(rc=$rc_t5 sum=[$sum_t5])"
    else
      no "T5 teeth: failed counter removed → should give failed=0 or exit 0" \
        "rc=$rc_t5 sum=[$sum_t5] — case 16 is THEATER"
    fi
  else
    no "T5 teeth: locate 'failed=\$((failed+1)); continue' in SUT" "line not found — SUT drifted?"
  fi

  # TOOTH 6: Restore the old case-INSENSITIVE PARTIAL grep (add -i flag).
  # Anchor: the literal text "grep -qE 'PARTIAL|shipped:'" in the SUT.
  # With -i restored: the dismissed-with-prose-partial retro trips is_partial=1 →
  # case 18 expected no-match but gets planned-issue output (regression).
  echo "-- teeth T6: restore case-insensitive PARTIAL grep; dismissed-prose-partial must false-fire (case 18 has teeth) --"
  if grep -qF "grep -qE 'PARTIAL|shipped:'" "$SUT" 2>/dev/null; then
    box_t6="$(mkbox teeth-partial-prose)"
    retro_t6="$box_t6/rh/target-foo/retros/r-t6.md"
    cat > "$retro_t6" <<'RETROEOF'
<!-- review-status: dismissed 2026-09-20 · scoped to other-kit (P1 partial) -->
# Retro

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| D1 | fix | METHODOLOGY.md | B42 | new | HIGH |
RETROEOF
    mutant_t6="$box_t6/research-sdd/toolbelt/stage-retro-issues.sh"
    # Add -i flag to restore case-insensitive matching and re-introduce the bug
    sed "s/grep -qE 'PARTIAL|shipped:'/grep -qiE 'PARTIAL|shipped:'/" \
      "$SUT" > "$mutant_t6"
    bash -n "$mutant_t6" 2>/dev/null || { no "T6 teeth: mutant_t6 failed bash -n" ""; }
    out_t6="$(PATH="$box_t6/bin:$PATH" \
      "$BASH_BIN" "$mutant_t6" "$retro_t6" 2>&1)"; rc_t6=$?
    if printf '%s\n' "$out_t6" | grep -q 'planned-issue:'; then
      ok "T6 teeth: case-insensitive PARTIAL re-enabled → false-fires on prose (case 18 has teeth)" "()"
    else
      no "T6 teeth: case-insensitive PARTIAL re-enabled → should false-fire on prose" \
        "no planned-issue — case 18 is THEATER: rc=$rc_t6 out=[$out_t6]"
    fi
  else
    no "T6 teeth: locate case-sensitive PARTIAL grep line in SUT" "line not found — SUT drifted?"
  fi

fi  # --prove-teeth

# ---------------------------------------------------------------------------
# 16 — APPLY MODE CREATE FAILURE: --apply with all creates failing → failed=N in summary, exit non-zero
# RED against origin/main: exits 0 and summary has no failed= field.
box="$(mkbox case-createfail)"
mk_gh_stub "$box" createfail
retro="$(mk_retro "$box" target-foo r-createfail.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | first delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | second delta | CLAUDE.md | B2 | fix | LOW |')")"
run "$box" "$retro" --apply
summary_line16="$(printf '%s\n' "$OUT" | grep '^summary:')"
has_failed_field=0; failed_count_nonzero=0; rc_nonzero=0
printf '%s' "$summary_line16" | grep -qE 'failed=[0-9]' && has_failed_field=1
printf '%s' "$summary_line16" | grep -qE 'failed=[1-9]' && failed_count_nonzero=1
[ "$RC" -ne 0 ] && rc_nonzero=1
if [ "$rc_nonzero" = 1 ] && [ "$has_failed_field" = 1 ] && [ "$failed_count_nonzero" = 1 ]; then
  ok "16 --apply createfail: failed= in summary, non-zero exit" "(exit $RC summary=[$summary_line16])"
else
  no "16 --apply createfail: failed= in summary, non-zero exit" \
    "exit=$RC rc_nonzero=$rc_nonzero has_failed=$has_failed_field nonzero_count=$failed_count_nonzero summary=[$summary_line16]"
fi

# ---------------------------------------------------------------------------
# 17 — MARKER AFTER H1: retro with applied marker placed after H1+blank → no-match (not seeded)
# Real example: niagara-research/retros/*-closure.md has H1 on line 1, blank on line 2, marker on line 3.
# RED against origin/main: marker is missed → rows are emitted as planned-issues instead of no-match.
box="$(mkbox case-after-h1-applied)"
retro_after_h1="$box/rh/target-foo/retros/r-after-h1.md"
cat > "$retro_after_h1" <<'RETROEOF'
# §18 Retro — focus: signing-pki

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
| 2 | another thing | CLAUDE.md | B43 | fix | MEDIUM |
RETROEOF
run "$box" "$retro_after_h1"
after_h1_nomatch=0; after_h1_planned=0
printf '%s\n' "$OUT" | grep -qi 'no-match\|all.*shipped\|applied' && after_h1_nomatch=1
printf '%s\n' "$OUT" | grep -q 'planned-issue:' && after_h1_planned=1
if [ "$RC" = 0 ] && [ "$after_h1_nomatch" = 1 ] && [ "$after_h1_planned" = 0 ]; then
  ok "17 marker after H1: applied retro not seeded → no-match" "(exit $RC)"
else
  no "17 marker after H1: applied retro not seeded → no-match" \
    "exit=$RC nomatch=$after_h1_nomatch planned=$after_h1_planned out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 18 — DISMISSED MARKER WITH PROSE "partial": dismissed retro with lowercase "partial" in marker prose
# should NOT trigger is_partial. Real example: 2026-09-01-build-n4-module-kit-v0.2-retro.md has
# "dismissed ... (P1 partial)" in the marker text. The case-insensitive grep currently flips is_partial.
# RED against origin/main: the dismissed retro creates issues instead of exiting with no-match.
box="$(mkbox case-dismissed-prose-partial)"
retro_dpp="$box/rh/target-foo/retros/r-dismissed-partial-prose.md"
cat > "$retro_dpp" <<'RETROEOF'
<!-- review-status: dismissed 2026-09-20 · scoped to other-kit — deltas owned there (D1-D5, P1 partial) -->
# Retro — build-n4-module kit v0.2

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| D1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
| D2 | another thing | CLAUDE.md | B43 | fix | MEDIUM |
RETROEOF
run "$box" "$retro_dpp"
dpp_nomatch=0; dpp_planned=0
# grep for the explicit no-match: message, NOT for the word "dismissed" (which would match the filename)
printf '%s\n' "$OUT" | grep -qi '^no-match:' && dpp_nomatch=1
printf '%s\n' "$OUT" | grep -q 'planned-issue:' && dpp_planned=1
if [ "$RC" = 0 ] && [ "$dpp_nomatch" = 1 ] && [ "$dpp_planned" = 0 ]; then
  ok "18 dismissed with prose 'partial': not seeded → no-match" "(exit $RC)"
else
  no "18 dismissed with prose 'partial': not seeded → no-match" \
    "exit=$RC nomatch=$dpp_nomatch planned=$dpp_planned out=[$OUT]"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
