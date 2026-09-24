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
# mkbox_at <base-dir> <name> [target-name]
#   Same as mkbox (below) but the box is created under <base-dir> instead of
#   $ROOT. Used by the F1 (kit issue #1045) enclosing-repo-walk fixture, which
#   needs the box's PARENT to be a git repo while the box itself stays a plain
#   directory (never git-inited) — mkbox's own boxes are never repos, so this
#   is the only fixture that deliberately relies on git's upward remote walk;
#   every other fixture stays either its own repo (mk_git_remote/mk_foreign_repo)
#   or explicitly not a repo at all.
mkbox_at() {
  local base="$1" name="$2" tgt="${3:-target-foo}"
  local box="$base/$name"
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

mkbox() {
  mkbox_at "$ROOT" "$@"
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

# mk_git_remote <box> <url>: git-init the KIT root (= box itself, since script sits at
# $box/research-sdd/toolbelt/… and KIT_ROOT = script_dir/../..) and set 'origin' to
# <url>. Used only by tests exercising the git-remote-derivation path (kit issue
# #1037); an untouched mkbox (no git init) is what makes a box's git-remote
# resolution naturally unresolvable — that IS the "no repo configured" fixture.
mk_git_remote() {
  local box="$1" url="$2"
  git init -q "$box" >/dev/null 2>&1
  git -C "$box" remote add origin "$url" >/dev/null 2>&1 \
    || git -C "$box" remote set-url origin "$url" >/dev/null 2>&1
}

# mk_foreign_repo <dir> <url>: git-init a standalone repo at <dir> with 'origin' set
# to <url>. Simulates the retro-gate.sh Stop-hook scenario where the process cwd is
# a TARGET repo (its own, different, remote) while the kit repo lives elsewhere on
# disk — proves repo resolution reads KIT_ROOT's remote, never the process cwd's.
mk_foreign_repo() {
  local dir="$1" url="$2"
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" remote add origin "$url" >/dev/null 2>&1
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
#   RESEARCH_SDD_ISSUE_REPO defaults to a fixed fake value so every PRE-EXISTING
#   test keeps exercising gh (dedup/create/failure) without needing its own git
#   remote — the ":-" fallback means an already-exported value (used by the new
#   env-override tests) still wins, per resolution order §1.
run() {
  local box="$1" retro="$2"; shift 2
  OUT="$(PATH="$box/bin:$PATH" \
    RESEARCH_SDD_ISSUE_REPO="${RESEARCH_SDD_ISSUE_REPO:-test-owner/test-kit}" \
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
    out_t3="$(PATH="$box_t3/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
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
    out_t5="$(PATH="$box_t5/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
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

  # TOOTH SYMLINK-TOOLBELT: revert -P/pwd -P to plain cd/pwd (kit issue #1024 round 3, MEDIUM).
  echo "-- teeth SYMLINK-TOOLBELT: revert -P to plain cd/pwd --"
  box_tsym="$(mkbox teeth-symlink-toolbelt)"
  retro_tsym="$(mk_retro "$box_tsym" target-foo r-tsym.md - "| 1 | do a thing | some/file | cite | fix | P2 |")"
  mutant_tsym="$box_tsym/research-sdd/toolbelt/stage-retro-issues.sh"
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
    "$box_tsym/research-sdd/profile/general/toolbelt/stage-retro-issues.sh" "$retro_tsym" 2>&1)"
  if printf '%s' "$out_tsym" | grep -qi 'target directory.*not found'; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant re-breaks through a symlinked toolbelt/ → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant still resolved TARGETS.md — -P fix check is THEATER" \
       "(out=[$out_tsym])"
  fi

  # TOOTH 7 (kit issue #1037): drop --repo from the gh issue create call site.
  # Anchor: the literal call-site text that puts --repo right after "issue create".
  echo "-- teeth T7: drop --repo from gh issue create call --"
  anchor_t7='gh issue create --repo "$KIT_ISSUE_REPO" \'
  if [[ "$sut_content" == *"$anchor_t7"* ]]; then
    box_t7="$(mkbox teeth-t7-create-repo)"
    mk_git_remote "$box_t7" "https://github.com/kit-owner/kit-repo.git"
    mk_gh_stub "$box_t7" nomatch
    retro_t7="$(mk_retro "$box_t7" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t7 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t7="$box_t7/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t7"/gh issue create \\}" > "$mutant_t7"
    bash -n "$mutant_t7" 2>/dev/null || { no "T7 teeth: mutant_t7 failed bash -n syntax check" ""; }
    out_t7="$(PATH="$box_t7/bin:$PATH" \
      "$BASH_BIN" "$mutant_t7" "$retro_t7" --apply 2>&1)"; rc_t7=$?
    create_line_t7="$(grep 'issue create' "$box_t7/bin/gh.log" 2>/dev/null || true)"
    if [ -n "$create_line_t7" ] && ! printf '%s' "$create_line_t7" | grep -q -- '--repo'; then
      ok "T7 teeth: --repo dropped from create call → flag missing (case 19/20 have teeth)" "()"
    else
      no "T7 teeth: --repo dropped from create call → flag should be missing" \
        "still present or create not called — case 19/20 are THEATER: rc=$rc_t7 line=[$create_line_t7] out=[$out_t7]"
    fi
  else
    no "T7 teeth: locate gh issue create --repo anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 8 (kit issue #1037): drop --repo from the gh issue list (dedup) call site.
  echo "-- teeth T8: drop --repo from gh issue list call --"
  anchor_t8='gh issue list --repo "$KIT_ISSUE_REPO" --state open \'
  if [[ "$sut_content" == *"$anchor_t8"* ]]; then
    box_t8="$(mkbox teeth-t8-list-repo)"
    mk_git_remote "$box_t8" "https://github.com/kit-owner/kit-repo.git"
    mk_gh_stub "$box_t8" nomatch
    retro_t8="$(mk_retro "$box_t8" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t8 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t8="$box_t8/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t8"/gh issue list --state open \\}" > "$mutant_t8"
    bash -n "$mutant_t8" 2>/dev/null || { no "T8 teeth: mutant_t8 failed bash -n syntax check" ""; }
    out_t8="$(PATH="$box_t8/bin:$PATH" \
      "$BASH_BIN" "$mutant_t8" "$retro_t8" --apply 2>&1)"; rc_t8=$?
    list_line_t8="$(grep 'issue list' "$box_t8/bin/gh.log" 2>/dev/null || true)"
    if [ -n "$list_line_t8" ] && ! printf '%s' "$list_line_t8" | grep -q -- '--repo'; then
      ok "T8 teeth: --repo dropped from list call → flag missing (case 19 has teeth)" "()"
    else
      no "T8 teeth: --repo dropped from list call → flag should be missing" \
        "still present or list not called — case 19 is THEATER: rc=$rc_t8 line=[$list_line_t8] out=[$out_t8]"
    fi
  else
    no "T8 teeth: locate gh issue list --repo anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 9 (kit issue #1037): neuter the unresolved-repo degraded/exit guard so an
  # unresolvable repo falls back SILENTLY under --apply instead of refusing.
  echo "-- teeth T9: neuter unresolved-repo degraded/exit guard under --apply --"
  anchor_t9='if [ $apply -eq 1 ] && [ -z "$KIT_ISSUE_REPO" ]; then'
  if [[ "$sut_content" == *"$anchor_t9"* ]]; then
    box_t9="$(mkbox teeth-t9-unresolved-guard)"
    mk_gh_stub "$box_t9" nomatch
    retro_t9="$(mk_retro "$box_t9" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t9 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t9="$box_t9/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t9"/if false; then}" > "$mutant_t9"
    bash -n "$mutant_t9" 2>/dev/null || { no "T9 teeth: mutant_t9 failed bash -n syntax check" ""; }
    out_t9="$(PATH="$box_t9/bin:$PATH" \
      "$BASH_BIN" "$mutant_t9" "$retro_t9" --apply 2>&1)"; rc_t9=$?
    create_called_t9=0
    [ -f "$box_t9/bin/gh.log" ] && grep -q 'issue create' "$box_t9/bin/gh.log" && create_called_t9=1
    if [ "$create_called_t9" = 1 ]; then
      ok "T9 teeth: unresolved-repo guard neutered → create called with no repo resolved (case 23 has teeth)" "()"
    else
      no "T9 teeth: unresolved-repo guard neutered → create should still be called (silently)" \
        "create not called — case 23 is THEATER: rc=$rc_t9 out=[$out_t9]"
    fi
  else
    no "T9 teeth: locate unresolved-repo guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 10 (kit issue #1045 F1): drop the physical toplevel check so an
  # enclosing repo's remote (KIT_ROOT is NOT its own checkout) is accepted.
  echo "-- teeth T10: drop F1 physical-toplevel check --"
  anchor_t10='  if [ "$_top_phys" != "$_kit_phys" ]; then'
  if [[ "$sut_content" == *"$anchor_t10"* ]]; then
    parent_t10="$ROOT/teeth-t10-enclosing-parent"
    mkdir -p "$parent_t10"
    git init -q "$parent_t10" >/dev/null 2>&1
    git -C "$parent_t10" remote add origin \
      "https://github.com/t10-enclosing-owner/t10-enclosing-repo.git" >/dev/null 2>&1
    box_t10="$(mkbox_at "$parent_t10" nested-kit)"
    retro_t10="$(mk_retro "$box_t10" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t10 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t10="$box_t10/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t10"/  if false; then  # teeth-t10-f1-check-removed}" > "$mutant_t10"
    bash -n "$mutant_t10" 2>/dev/null || { no "T10 teeth: mutant_t10 failed bash -n syntax check" ""; }
    out_t10="$(PATH="$box_t10/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
      "$BASH_BIN" "$mutant_t10" "$retro_t10" 2>&1)"; rc_t10=$?
    if printf '%s\n' "$out_t10" | grep -q '^kit-issue-repo: t10-enclosing-owner/t10-enclosing-repo$'; then
      ok "T10 teeth: F1 toplevel check dropped → enclosing repo leaks through (case 24/25 have teeth)" "()"
    else
      no "T10 teeth: F1 toplevel check dropped → enclosing repo should leak through" \
        "enclosing origin did not leak — case 24/25 is THEATER: rc=$rc_t10 out=[$out_t10]"
    fi
  else
    no "T10 teeth: locate F1 toplevel-check anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 11 (kit issue #1045 F2): neuter shape validation so an invalid
  # override/derived value passes straight through to gh unchecked.
  echo "-- teeth T11: neuter _validate_repo_shape (F2) --"
  anchor_t11='  [[ "$1" =~ $_KIT_ISSUE_REPO_SHAPE_RE ]]'
  if [[ "$sut_content" == *"$anchor_t11"* ]]; then
    box_t11="$(mkbox teeth-t11-shape)"
    retro_t11="$(mk_retro "$box_t11" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t11 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t11="$box_t11/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t11"/  return 0  # teeth-t11-shape-check-removed}" > "$mutant_t11"
    bash -n "$mutant_t11" 2>/dev/null || { no "T11 teeth: mutant_t11 failed bash -n syntax check" ""; }
    out_t11="$(PATH="$box_t11/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
      "$BASH_BIN" "$mutant_t11" "$retro_t11" 2>&1)"; rc_t11=$?
    if printf '%s\n' "$out_t11" | grep -q '^kit-issue-repo: foo$'; then
      ok "T11 teeth: shape validation neutered → invalid override 'foo' leaks through (case 26/27 have teeth)" "()"
    else
      no "T11 teeth: shape validation neutered → invalid override should leak through" \
        "invalid value did not leak — case 26/27 is THEATER: rc=$rc_t11 out=[$out_t11]"
    fi
  else
    no "T11 teeth: locate _validate_repo_shape body anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 12 (kit issue #1045 F3): revert the slash-before-.git strip order so
  # a URL like "o/n.git/" leaves the stray "o/n.git" behind again.
  echo "-- teeth T12: revert F3 slash-before-.git strip order --"
  anchor_t12="$(printf '  rest="${rest%%/}"\n  rest="${rest%%.git}"\n  rest="${rest%%/}"')"
  if [[ "$sut_content" == *"$anchor_t12"* ]]; then
    box_t12="$(mkbox teeth-t12-slash-order)"
    mk_git_remote "$box_t12" "https://github.com/o/n.git/"
    retro_t12="$(mk_retro "$box_t12" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t12 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t12="$box_t12/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t12="$(printf '  rest="${rest%%.git}"\n  rest="${rest%%/}"')"
    printf '%s\n' "${sut_content/"$anchor_t12"/$reverted_t12}" > "$mutant_t12"
    bash -n "$mutant_t12" 2>/dev/null || { no "T12 teeth: mutant_t12 failed bash -n syntax check" ""; }
    out_t12="$(PATH="$box_t12/bin:$PATH" \
      "$BASH_BIN" "$mutant_t12" "$retro_t12" 2>&1)"; rc_t12=$?
    if printf '%s\n' "$out_t12" | grep -q '^kit-issue-repo: o/n\.git$'; then
      ok "T12 teeth: slash-before-.git order reverted → stray 'o/n.git' reappears (case 28 has teeth)" "()"
    else
      no "T12 teeth: slash-before-.git order reverted → stray '.git' should reappear" \
        "stray suffix did not reappear — case 28 is THEATER: rc=$rc_t12 out=[$out_t12]"
    fi
  else
    no "T12 teeth: locate F3 slash/.git strip-order anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 13 (kit issue #1045 F3, re-anchored for #1046 round 2): the
  # URL-scheme "keep a real non-github host" branch is neutered to always
  # drop instead, so a GHE origin silently loses its host again.
  echo "-- teeth T13: drop F3 non-github.com host retention (URL-scheme keep branch) --"
  anchor_t13='      printf '"'"'%s/%s'"'"' "$host" "$rest"'
  if [[ "$sut_content" == *"$anchor_t13"* ]]; then
    box_t13="$(mkbox teeth-t13-host-drop)"
    mk_git_remote "$box_t13" "https://ghe.corp.example.com/ghe-owner/ghe-kit.git"
    retro_t13="$(mk_retro "$box_t13" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t13 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t13="$box_t13/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t13"/      printf '%s' \"\$rest\"  # teeth-t13-host-drop}" > "$mutant_t13"
    bash -n "$mutant_t13" 2>/dev/null || { no "T13 teeth: mutant_t13 failed bash -n syntax check" ""; }
    out_t13="$(PATH="$box_t13/bin:$PATH" \
      "$BASH_BIN" "$mutant_t13" "$retro_t13" 2>&1)"; rc_t13=$?
    if printf '%s\n' "$out_t13" | grep -q '^kit-issue-repo: ghe-owner/ghe-kit$'; then
      ok "T13 teeth: GHE host retention dropped → host lost again (case 30/39/42 have teeth)" "()"
    else
      no "T13 teeth: GHE host retention dropped → host should be lost" \
        "host was not dropped — case 30/39/42 is THEATER: rc=$rc_t13 out=[$out_t13]"
    fi
  else
    no "T13 teeth: locate F3 host-retention anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 14 (kit issue #1046 round 2 item 1): neuter the github-alias-host
  # check so an alias/prefix host (e.g. "github.com-alias", "www.github.com")
  # is treated like a real GHE host and KEPT instead of dropped.
  echo "-- teeth T14: neuter github-alias host check (URL-scheme) --"
  anchor_t14='    if [[ "$(printf '"'"'%s'"'"' "$host" | tr '"'"'A-Z'"'"' '"'"'a-z'"'"')" =~ $_KIT_GITHUB_HOST_ALIAS_RE ]]; then'
  if [[ "$sut_content" == *"$anchor_t14"* ]]; then
    box_t14="$(mkbox teeth-t14-alias-check)"
    mk_git_remote "$box_t14" "https://github.com-alias/o/n.git"
    retro_t14="$(mk_retro "$box_t14" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t14 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t14="$box_t14/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t14"/    if false; then  # teeth-t14-alias-check-removed}" > "$mutant_t14"
    bash -n "$mutant_t14" 2>/dev/null || { no "T14 teeth: mutant_t14 failed bash -n syntax check" ""; }
    out_t14="$(PATH="$box_t14/bin:$PATH" \
      "$BASH_BIN" "$mutant_t14" "$retro_t14" 2>&1)"; rc_t14=$?
    if printf '%s\n' "$out_t14" | grep -q '^kit-issue-repo: github.com-alias/o/n$'; then
      ok "T14 teeth: alias check neutered → alias host leaks through (case 34/35/38 have teeth)" "()"
    else
      no "T14 teeth: alias check neutered → alias host should leak through" \
        "alias did not leak — case 34/35/38 is THEATER: rc=$rc_t14 out=[$out_t14]"
    fi
  else
    no "T14 teeth: locate github-alias host-check anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 15 (kit issue #1046 round 2 item 2): drop the :port strip so a
  # ported host is never recognized as github.com and fails shape validation.
  echo "-- teeth T15: drop :port strip from host --"
  anchor_t15='  host="${host%%:*}"'
  if [[ "$sut_content" == *"$anchor_t15"* ]]; then
    box_t15="$(mkbox teeth-t15-port-strip)"
    mk_git_remote "$box_t15" "https://github.com:443/o/n.git"
    retro_t15="$(mk_retro "$box_t15" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t15 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t15="$box_t15/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t15"/  : # teeth-t15-port-strip-removed}" > "$mutant_t15"
    bash -n "$mutant_t15" 2>/dev/null || { no "T15 teeth: mutant_t15 failed bash -n syntax check" ""; }
    out_t15="$(PATH="$box_t15/bin:$PATH" \
      "$BASH_BIN" "$mutant_t15" "$retro_t15" 2>&1)"; rc_t15=$?
    if ! printf '%s\n' "$out_t15" | grep -q '^kit-issue-repo: o/n$'; then
      ok "T15 teeth: port strip removed → 'o/n' no longer resolved (case 36/37/38/39 have teeth)" "(rc=$rc_t15)"
    else
      no "T15 teeth: port strip removed → 'o/n' should NOT resolve cleanly" \
        "still resolved cleanly — case 36/37/38/39 is THEATER: rc=$rc_t15 out=[$out_t15]"
    fi
  else
    no "T15 teeth: locate :port strip anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 16 (kit issue #1046 round 2 item 1): neuter scp-form host dropping
  # so an scp remote (alias or real) KEEPS its host, which breaks both the
  # alias case and the plain "keep real origin" regression.
  echo "-- teeth T16: neuter scp-form host drop --"
  # A bare "    printf '%s' \"\$rest\"" (4-space) is NOT unique as a plain
  # substring: it is also a substring of the 6-space-indented alias-match
  # line above it (the last 4 of those 6 spaces + the rest). Anchor on the
  # preceding comment line too, which is unique.
  anchor_t16=$'    # form always drops its host — see the docstring above for why.\n    printf \'%s\' "$rest"'
  if [[ "$sut_content" == *"$anchor_t16"* ]]; then
    box_t16="$(mkbox teeth-t16-scp-drop)"
    mk_git_remote "$box_t16" "git@github.com-alias:o/n.git"
    retro_t16="$(mk_retro "$box_t16" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t16 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t16="$box_t16/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t16=$'    # form always drops its host — see the docstring above for why.\n    printf \'%s/%s\' "$host" "$rest"  # teeth-t16-scp-host-kept'
    printf '%s\n' "${sut_content/"$anchor_t16"/$reverted_t16}" > "$mutant_t16"
    bash -n "$mutant_t16" 2>/dev/null || { no "T16 teeth: mutant_t16 failed bash -n syntax check" ""; }
    out_t16="$(PATH="$box_t16/bin:$PATH" \
      "$BASH_BIN" "$mutant_t16" "$retro_t16" 2>&1)"; rc_t16=$?
    if printf '%s\n' "$out_t16" | grep -q '^kit-issue-repo: github.com-alias/o/n$'; then
      ok "T16 teeth: scp host-drop neutered → alias host leaks through (case 33/40 have teeth)" "()"
    else
      no "T16 teeth: scp host-drop neutered → alias host should leak through" \
        "alias did not leak — case 33/40 is THEATER: rc=$rc_t16 out=[$out_t16]"
    fi
  else
    no "T16 teeth: locate scp-form host-drop anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 17 (kit issue #1046 round 2 item 4): revert the tightened shape
  # regex to the old permissive one, so '-o/n' (a leading '-') is wrongly
  # accepted instead of rejected.
  echo "-- teeth T17: revert shape-tightening regex (item 4) --"
  anchor_t17="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9][A-Za-z0-9.-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\$'"
  if [[ "$sut_content" == *"$anchor_t17"* ]]; then
    box_t17="$(mkbox teeth-t17-shape-tighten)"
    retro_t17="$(mk_retro "$box_t17" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t17 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t17="$box_t17/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t17="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9.-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\$'"
    printf '%s\n' "${sut_content/"$anchor_t17"/$reverted_t17}" > "$mutant_t17"
    bash -n "$mutant_t17" 2>/dev/null || { no "T17 teeth: mutant_t17 failed bash -n syntax check" ""; }
    out_t17="$(PATH="$box_t17/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="-o/n" \
      "$BASH_BIN" "$mutant_t17" "$retro_t17" 2>&1)"; rc_t17=$?
    if printf '%s\n' "$out_t17" | grep -q '^kit-issue-repo: -o/n$'; then
      ok "T17 teeth: shape regex reverted → '-o/n' wrongly accepted (case 43.2 has teeth)" "()"
    else
      no "T17 teeth: shape regex reverted → '-o/n' should be wrongly accepted" \
        "'-o/n' still rejected — case 43.2 is THEATER: rc=$rc_t17 out=[$out_t17]"
    fi
  else
    no "T17 teeth: locate shape-tightening regex anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 18 (kit issue #1046 round 2 item 3): re-wrap the resolve call in a
  # subshell — the exact bug class that lost _KIT_ISSUE_REPO_BAD_VALUE before
  # — and confirm the degraded message goes back to naming an empty ''.
  echo "-- teeth T18: re-wrap resolve_kit_issue_repo call in a subshell --"
  anchor_t18="$(printf 'resolve_kit_issue_repo\n_kit_issue_repo_rc=$?')"
  if [[ "$sut_content" == *"$anchor_t18"* ]]; then
    box_t18="$(mkbox teeth-t18-subshell-bug)"
    retro_t18="$(mk_retro "$box_t18" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t18 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t18="$box_t18/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t18="$(printf '( resolve_kit_issue_repo )\n_kit_issue_repo_rc=$?')"
    printf '%s\n' "${sut_content/"$anchor_t18"/$reverted_t18}" > "$mutant_t18"
    bash -n "$mutant_t18" 2>/dev/null || { no "T18 teeth: mutant_t18 failed bash -n syntax check" ""; }
    out_t18="$(PATH="$box_t18/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
      "$BASH_BIN" "$mutant_t18" "$retro_t18" 2>&1)"; rc_t18=$?
    if printf '%s\n' "$out_t18" | grep -q "invalid repo shape ''"; then
      ok "T18 teeth: resolve call re-subshelled → bad value lost again (case 45 has teeth)" "()"
    else
      no "T18 teeth: resolve call re-subshelled → bad value should be lost ('')" \
        "bad value still survived — case 45 is THEATER: rc=$rc_t18 out=[$out_t18]"
    fi
  else
    no "T18 teeth: locate resolve_kit_issue_repo call-site anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 19 (kit issue #1046 round 2 item 5): revert the F1 reason wording
  # to the old inaccurate text, so it no longer names "toplevel".
  echo "-- teeth T19: revert F1 reason wording (item 5) --"
  anchor_t19='    3) _kit_issue_repo_reason="kit root ($KIT_ROOT) is not the git checkout'"'"'s toplevel — git found an enclosing checkout rooted at ${_KIT_ISSUE_REPO_TOPLEVEL} instead" ;;'
  if [[ "$sut_content" == *"$anchor_t19"* ]]; then
    enclosing_parent_t19="$ROOT/teeth-t19-enclosing-parent"
    mkdir -p "$enclosing_parent_t19"
    git init -q "$enclosing_parent_t19" >/dev/null 2>&1
    git -C "$enclosing_parent_t19" remote add origin \
      "https://github.com/t19-owner/t19-repo.git" >/dev/null 2>&1
    box_t19="$(mkbox_at "$enclosing_parent_t19" nested-kit)"
    retro_t19="$(mk_retro "$box_t19" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t19 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t19="$box_t19/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t19='    3) _kit_issue_repo_reason="kit root is not its own git checkout — found an enclosing repo instead at $KIT_ROOT" ;;'
    printf '%s\n' "${sut_content/"$anchor_t19"/$reverted_t19}" > "$mutant_t19"
    bash -n "$mutant_t19" 2>/dev/null || { no "T19 teeth: mutant_t19 failed bash -n syntax check" ""; }
    out_t19="$(PATH="$box_t19/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
      "$BASH_BIN" "$mutant_t19" "$retro_t19" 2>&1)"; rc_t19=$?
    if ! printf '%s\n' "$out_t19" | grep -qi 'toplevel'; then
      ok "T19 teeth: F1 reason wording reverted → 'toplevel' no longer present (case 46 has teeth)" "()"
    else
      no "T19 teeth: F1 reason wording reverted → 'toplevel' should be gone" \
        "'toplevel' still present — case 46 is THEATER: rc=$rc_t19 out=[$out_t19]"
    fi
  else
    no "T19 teeth: locate F1 reason-wording anchor" "anchor not found in SUT — SUT drifted?"
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

# ---------------------------------------------------------------------------
# kit issue #1024 round 3, MEDIUM: symlinked toolbelt (render dir)
# ---------------------------------------------------------------------------
# Same class of bug as reconcile-issues.sh (both climb "../.." via cd without -P). Here the
# symptom is subtler: TARGETS_MD points at a nonexistent path, so the per-retro target lookup
# silently falls back to basename and WARNs "target directory ... not found" — reproduced against
# the pre-fix SUT with this exact fixture.
box_sym="$(mkbox symlink-toolbelt)"
retro_sym="$(mk_retro "$box_sym" target-foo r-sym.md - "| 1 | do a thing | some/file | cite | fix | P2 |")"
mkdir -p "$box_sym/research-sdd/profile/general"
ln -s "$box_sym/research-sdd/toolbelt" "$box_sym/research-sdd/profile/general/toolbelt"
OUT_SYM="$(PATH="$box_sym/bin:$PATH" "$BASH_BIN" \
  "$box_sym/research-sdd/profile/general/toolbelt/stage-retro-issues.sh" "$retro_sym" 2>&1)"; RC_SYM=$?
# kit issue #1024 round 4, item 5: assert the exit code explicitly, not just the absence of the
# negative-signal text — a wrong-reason nonzero exit would otherwise slip through this check.
if [ "$RC_SYM" -eq 0 ] && ! printf '%s' "$OUT_SYM" | grep -qi 'target directory.*not found'; then
  ok "SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/, TARGETS.md target lookup still resolves (exit 0)" \
     "(rc=$RC_SYM)"
else
  no "SYMLINK-TOOLBELT: TARGETS.md target lookup failed through a symlinked toolbelt/ (or wrong exit code)" \
     "(rc=$RC_SYM out=[$OUT_SYM])"
fi

# ---------------------------------------------------------------------------
# kit issue #1037: gh calls must target the KIT repo explicitly, never
# whatever repo the process cwd (the retro-gate.sh Stop hook's TARGET
# directory) happens to resolve to.
# ---------------------------------------------------------------------------

# 19 — REPO FLAG ON EVERY GH CALL, CWD-INDEPENDENT: the kit root gets its own git
# remote; a SEPARATE foreign-target repo (its own remote) plays the role of the
# Stop hook's process cwd. Both gh calls made during --apply must carry
# --repo <kit-owner>/<kit-name> — never the foreign target's remote, never omitted.
box="$(mkbox case-repo-flag)"
mk_git_remote "$box" "https://github.com/kit-owner/kit-repo.git"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-repoflag.md \
  "<!-- review-status: pending -->" \
  "| 1 | needs an issue | CLAUDE.md §7 | B1 | new | HIGH |")"
foreign_cwd_19="$ROOT/foreign-target-19"
mk_foreign_repo "$foreign_cwd_19" "https://github.com/foreign-owner/foreign-target.git"
OUT19="$( (cd "$foreign_cwd_19" && PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply) 2>&1)"; RC19=$?
list_has_repo=0; create_has_repo=0; foreign_leaked=0
if [ -f "$box/bin/gh.log" ]; then
  grep -q 'issue list --repo kit-owner/kit-repo' "$box/bin/gh.log" && list_has_repo=1
  grep -q 'issue create --repo kit-owner/kit-repo' "$box/bin/gh.log" && create_has_repo=1
  grep -q 'foreign-owner' "$box/bin/gh.log" && foreign_leaked=1
fi
if [ "$RC19" = 0 ] && [ "$list_has_repo" = 1 ] && [ "$create_has_repo" = 1 ] && [ "$foreign_leaked" = 0 ]; then
  ok "19 repo flag on every gh call: kit remote used, cwd-independent, no foreign leak" "(exit $RC19)"
else
  no "19 repo flag on every gh call: kit remote used, cwd-independent, no foreign leak" \
    "exit=$RC19 list=$list_has_repo create=$create_has_repo foreign_leak=$foreign_leaked out=[$OUT19] log=[$(cat "$box/bin/gh.log" 2>/dev/null)]"
fi

# ---------------------------------------------------------------------------
# 20 — ENV OVERRIDE WINS: RESEARCH_SDD_ISSUE_REPO takes precedence over a
# configured git remote at the kit root.
box="$(mkbox case-env-override)"
mk_git_remote "$box" "https://github.com/kit-owner/kit-repo.git"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-override.md \
  "<!-- review-status: pending -->" \
  "| 1 | env override delta | CLAUDE.md | B1 | new | HIGH |")"
OUT20="$(PATH="$box/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="override-owner/override-kit" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply 2>&1)"; RC20=$?
override_used=0; git_remote_leaked=0
if [ -f "$box/bin/gh.log" ]; then
  grep -q 'issue create --repo override-owner/override-kit' "$box/bin/gh.log" && override_used=1
  grep -q 'kit-owner/kit-repo' "$box/bin/gh.log" && git_remote_leaked=1
fi
if [ "$RC20" = 0 ] && [ "$override_used" = 1 ] && [ "$git_remote_leaked" = 0 ]; then
  ok "20 env override wins over configured git remote" "(exit $RC20)"
else
  no "20 env override wins over configured git remote" \
    "exit=$RC20 override_used=$override_used remote_leaked=$git_remote_leaked out=[$OUT20]"
fi

# ---------------------------------------------------------------------------
# 21 — DERIVE FROM GIT REMOTE (https form): dry-run prints the resolved
# kit-issue-repo line, normalized from an https:// origin with a .git suffix.
box="$(mkbox case-derive-https)"
mk_git_remote "$box" "https://github.com/deriv-owner/deriv-kit.git"
retro="$(mk_retro "$box" target-foo r-derive-https.md \
  "<!-- review-status: pending -->" \
  "| 1 | derive https delta | CLAUDE.md | B1 | new | HIGH |")"
OUT21="$(PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC21=$?
if [ "$RC21" = 0 ] && printf '%s\n' "$OUT21" | grep -q '^kit-issue-repo: deriv-owner/deriv-kit$'; then
  ok "21 derive from git remote (https): kit-issue-repo printed in dry-run" "(exit $RC21)"
else
  no "21 derive from git remote (https): kit-issue-repo printed in dry-run" "exit=$RC21 out=[$OUT21]"
fi

# ---------------------------------------------------------------------------
# 22 — DERIVE FROM GIT REMOTE (scp-like ssh form: git@host:owner/name.git)
box="$(mkbox case-derive-ssh)"
mk_git_remote "$box" "git@github.com:ssh-owner/ssh-kit.git"
retro="$(mk_retro "$box" target-foo r-derive-ssh.md \
  "<!-- review-status: pending -->" \
  "| 1 | derive ssh delta | CLAUDE.md | B1 | new | HIGH |")"
OUT22="$(PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC22=$?
if [ "$RC22" = 0 ] && printf '%s\n' "$OUT22" | grep -q '^kit-issue-repo: ssh-owner/ssh-kit$'; then
  ok "22 derive from git remote (scp-like ssh): kit-issue-repo printed in dry-run" "(exit $RC22)"
else
  no "22 derive from git remote (scp-like ssh): kit-issue-repo printed in dry-run" "exit=$RC22 out=[$OUT22]"
fi

# ---------------------------------------------------------------------------
# 23 — UNRESOLVABLE REPO UNDER --apply: no env override, no git remote at the
# kit root, cwd is a foreign target repo → typed degraded line, non-zero exit,
# ZERO gh issue calls recorded (never fall back to the cwd/target repo).
box="$(mkbox case-unresolved-apply)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-unresolved.md \
  "<!-- review-status: pending -->" \
  "| 1 | should never create | CLAUDE.md | B1 | new | HIGH |")"
foreign_cwd_23="$ROOT/foreign-target-23"
mk_foreign_repo "$foreign_cwd_23" "https://github.com/foreign-owner/foreign-target.git"
OUT23="$( (cd "$foreign_cwd_23" && PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply) 2>&1)"; RC23=$?
gh_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue' "$box/bin/gh.log" && gh_called=1
if [ "$RC23" != 0 ] && printf '%s' "$OUT23" | grep -qi 'degraded' \
   && printf '%s' "$OUT23" | grep -qi 'cannot resolve' \
   && [ "$gh_called" = 0 ]; then
  ok "23 unresolvable repo under --apply: degraded, non-zero exit, zero gh issue calls" "(exit $RC23)"
else
  no "23 unresolvable repo under --apply: degraded, non-zero exit, zero gh issue calls" \
    "exit=$RC23 gh_called=$gh_called out=[$OUT23]"
fi

# ---------------------------------------------------------------------------
# kit issue #1045: harden resolve_kit_issue_repo() past #1037/#1042.
# ---------------------------------------------------------------------------

# 24 — F1 ENCLOSING-REPO WALK (dry-run): KIT_ROOT itself is NOT a git checkout
# (no .git of its own), but its PARENT directory is a repo with its own
# origin. A logical `git remote get-url origin` walks up and would return the
# enclosing repo's origin — resolve_kit_issue_repo() must refuse (unresolved),
# never the enclosing repo's value.
enclosing_parent_24="$ROOT/case-f1-enclosing-parent"
mkdir -p "$enclosing_parent_24"
git init -q "$enclosing_parent_24" >/dev/null 2>&1
git -C "$enclosing_parent_24" remote add origin \
  "https://github.com/enclosing-owner/enclosing-repo.git" >/dev/null 2>&1
box24="$(mkbox_at "$enclosing_parent_24" nested-kit)"
retro24="$(mk_retro "$box24" target-foo r-f1.md \
  "<!-- review-status: pending -->" \
  "| 1 | f1 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT24="$(PATH="$box24/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box24/research-sdd/toolbelt/stage-retro-issues.sh" "$retro24" 2>&1)"; RC24=$?
# The reason text is allowed to explain that an enclosing repo was found; what
# must never leak is the enclosing repo's OWNER/NAME being used as the value.
if [ "$RC24" = 0 ] && printf '%s\n' "$OUT24" | grep -q '^kit-issue-repo: unresolved' \
   && ! printf '%s\n' "$OUT24" | grep -q '^kit-issue-repo: enclosing-owner/enclosing-repo$'; then
  ok "24 F1 enclosing-repo walk (dry-run): unresolved, enclosing origin never surfaces" "(exit $RC24)"
else
  no "24 F1 enclosing-repo walk (dry-run): unresolved, enclosing origin never surfaces" \
    "exit=$RC24 out=[$OUT24]"
fi

# 25 — F1 ENCLOSING-REPO WALK (--apply): same fixture, --apply must refuse
# BEFORE any gh call, and the enclosing repo's owner/name must never leak into
# stdout/stderr (never used as the target repo).
box25="$(mkbox_at "$enclosing_parent_24" nested-kit-apply)"
mk_gh_stub "$box25" nomatch
retro25="$(mk_retro "$box25" target-foo r-f1-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | f1 apply delta | CLAUDE.md | B1 | new | HIGH |")"
OUT25="$(PATH="$box25/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box25/research-sdd/toolbelt/stage-retro-issues.sh" "$retro25" --apply 2>&1)"; RC25=$?
gh_called_25=0
[ -f "$box25/bin/gh.log" ] && grep -q 'issue' "$box25/bin/gh.log" && gh_called_25=1
# The reason text is allowed to explain that an enclosing repo was found; what
# must never leak is the enclosing repo's OWNER/NAME being used as the value.
if [ "$RC25" != 0 ] && printf '%s' "$OUT25" | grep -qi 'degraded' \
   && ! printf '%s' "$OUT25" | grep -q 'enclosing-owner/enclosing-repo' \
   && [ "$gh_called_25" = 0 ]; then
  ok "25 F1 enclosing-repo walk (--apply): degraded before any gh call, no leak" "(exit $RC25)"
else
  no "25 F1 enclosing-repo walk (--apply): degraded before any gh call, no leak" \
    "exit=$RC25 gh_called=$gh_called_25 out=[$OUT25]"
fi

# ---------------------------------------------------------------------------
# 26 — F2 SHAPE VALIDATION (override): a RESEARCH_SDD_ISSUE_REPO override that
# does not match `[host/]owner/repo` must resolve to unresolved (dry-run) /
# typed degraded + exit 1 BEFORE any gh call (--apply), never pass through.
box26="$(mkbox case-f2-shape-override)"
mk_gh_stub "$box26" nomatch
retro26="$(mk_retro "$box26" target-foo r-f2.md \
  "<!-- review-status: pending -->" \
  "| 1 | f2 delta | CLAUDE.md | B1 | new | HIGH |")"
f2_bad_values=(
  "foo"
  "a b/c"
  "o/n/x/y"
  "file:///srv/git/n.git"
)
f2_idx=0
for f2_bad in "${f2_bad_values[@]}"; do
  f2_idx=$((f2_idx+1))
  f2_out_dry="$(PATH="$box26/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$f2_bad" \
    "$BASH_BIN" "$box26/research-sdd/toolbelt/stage-retro-issues.sh" "$retro26" 2>&1)"; f2_rc_dry=$?
  : > "$box26/bin/gh.log"
  f2_out_apply="$(PATH="$box26/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$f2_bad" \
    "$BASH_BIN" "$box26/research-sdd/toolbelt/stage-retro-issues.sh" "$retro26" --apply 2>&1)"; f2_rc_apply=$?
  f2_gh_called=0
  [ -f "$box26/bin/gh.log" ] && grep -q 'issue' "$box26/bin/gh.log" && f2_gh_called=1
  if [ "$f2_rc_dry" = 0 ] && printf '%s\n' "$f2_out_dry" | grep -q '^kit-issue-repo: unresolved' \
     && [ "$f2_rc_apply" != 0 ] && printf '%s' "$f2_out_apply" | grep -qi 'degraded' \
     && [ "$f2_gh_called" = 0 ]; then
    ok "26.$f2_idx F2 shape-invalid override '$f2_bad' → unresolved/degraded, zero gh calls" \
      "(dry=$f2_rc_dry apply=$f2_rc_apply)"
  else
    no "26.$f2_idx F2 shape-invalid override '$f2_bad' → unresolved/degraded, zero gh calls" \
      "dry_rc=$f2_rc_dry dry_out=[$f2_out_dry] apply_rc=$f2_rc_apply apply_out=[$f2_out_apply] gh_called=$f2_gh_called"
  fi
done

# 27 — F2 SHAPE VALIDATION (derived): a git remote whose normalized value does
# not match `[host/]owner/repo` (e.g. a file:// origin) must also resolve to
# unresolved/degraded, never reach gh with a bogus --repo value.
box27="$(mkbox case-f2-shape-derived)"
git init -q "$box27" >/dev/null 2>&1
git -C "$box27" remote add origin "file:///srv/git/n.git" >/dev/null 2>&1
mk_gh_stub "$box27" nomatch
retro27="$(mk_retro "$box27" target-foo r-f2-derived.md \
  "<!-- review-status: pending -->" \
  "| 1 | f2 derived delta | CLAUDE.md | B1 | new | HIGH |")"
OUT27="$(PATH="$box27/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box27/research-sdd/toolbelt/stage-retro-issues.sh" "$retro27" 2>&1)"; RC27=$?
: > "$box27/bin/gh.log"
OUT27B="$(PATH="$box27/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box27/research-sdd/toolbelt/stage-retro-issues.sh" "$retro27" --apply 2>&1)"; RC27B=$?
gh_called_27=0
[ -f "$box27/bin/gh.log" ] && grep -q 'issue' "$box27/bin/gh.log" && gh_called_27=1
if [ "$RC27" = 0 ] && printf '%s\n' "$OUT27" | grep -q '^kit-issue-repo: unresolved' \
   && [ "$RC27B" != 0 ] && printf '%s' "$OUT27B" | grep -qi 'degraded' \
   && [ "$gh_called_27" = 0 ]; then
  ok "27 F2 shape-invalid derived (file:// origin) → unresolved/degraded, zero gh calls" \
    "(dry=$RC27 apply=$RC27B)"
else
  no "27 F2 shape-invalid derived (file:// origin) → unresolved/degraded, zero gh calls" \
    "dry_rc=$RC27 dry_out=[$OUT27] apply_rc=$RC27B apply_out=[$OUT27B] gh_called=$gh_called_27"
fi

# ---------------------------------------------------------------------------
# 28 — F3 NORMALIZATION: trailing slash stripped BEFORE the .git suffix.
# "https://github.com/o/n.git/" must resolve to "o/n", not "o/n.git" or
# unresolved.
box28="$(mkbox case-f3-slash-before-git)"
mk_git_remote "$box28" "https://github.com/o/n.git/"
retro28="$(mk_retro "$box28" target-foo r-f3-slash.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 slash delta | CLAUDE.md | B1 | new | HIGH |")"
OUT28="$(PATH="$box28/bin:$PATH" \
  "$BASH_BIN" "$box28/research-sdd/toolbelt/stage-retro-issues.sh" "$retro28" 2>&1)"; RC28=$?
if [ "$RC28" = 0 ] && printf '%s\n' "$OUT28" | grep -q '^kit-issue-repo: o/n$'; then
  ok "28 F3 trailing slash before .git: 'o/n.git/' -> 'o/n'" "(exit $RC28)"
else
  no "28 F3 trailing slash before .git: 'o/n.git/' -> 'o/n'" "exit=$RC28 out=[$OUT28]"
fi

# 29 — F3 NORMALIZATION: scp form WITHOUT user@ (e.g. "github.com:o/n").
box29="$(mkbox case-f3-scp-no-user)"
mk_git_remote "$box29" "github.com:scp-owner/scp-kit"
retro29="$(mk_retro "$box29" target-foo r-f3-scp.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 scp delta | CLAUDE.md | B1 | new | HIGH |")"
OUT29="$(PATH="$box29/bin:$PATH" \
  "$BASH_BIN" "$box29/research-sdd/toolbelt/stage-retro-issues.sh" "$retro29" 2>&1)"; RC29=$?
if [ "$RC29" = 0 ] && printf '%s\n' "$OUT29" | grep -q '^kit-issue-repo: scp-owner/scp-kit$'; then
  ok "29 F3 scp form without user@: 'github.com:o/n' -> 'o/n'" "(exit $RC29)"
else
  no "29 F3 scp form without user@: 'github.com:o/n' -> 'o/n'" "exit=$RC29 out=[$OUT29]"
fi

# 30 — F3 NORMALIZATION: non-github.com host (GHE) is KEPT as "HOST/o/n" (gh
# accepts HOST/OWNER/REPO).
box30="$(mkbox case-f3-ghe-host)"
mk_git_remote "$box30" "https://ghe.corp.example.com/ghe-owner/ghe-kit.git"
retro30="$(mk_retro "$box30" target-foo r-f3-ghe.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 ghe delta | CLAUDE.md | B1 | new | HIGH |")"
OUT30="$(PATH="$box30/bin:$PATH" \
  "$BASH_BIN" "$box30/research-sdd/toolbelt/stage-retro-issues.sh" "$retro30" 2>&1)"; RC30=$?
if [ "$RC30" = 0 ] && printf '%s\n' "$OUT30" | grep -q '^kit-issue-repo: ghe.corp.example.com/ghe-owner/ghe-kit$'; then
  ok "30 F3 non-github.com host kept: 'HOST/o/n' preserved for GHE" "(exit $RC30)"
else
  no "30 F3 non-github.com host kept: 'HOST/o/n' preserved for GHE" "exit=$RC30 out=[$OUT30]"
fi

# ---------------------------------------------------------------------------
# 31 — GIT MISSING (dry-run): no override, git absent from PATH → typed
# degraded reason naming git, printed inline in the dry-run unresolved line.
box31="$(mkbox case-vcs-missing-dry)"
mk_hermetic_bin "$box31"
retro31="$(mk_retro "$box31" target-foo r-vcs-missing.md \
  "<!-- review-status: pending -->" \
  "| 1 | vcs missing delta | CLAUDE.md | B1 | new | HIGH |")"
OUT31="$(PATH="$box31/bin" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box31/research-sdd/toolbelt/stage-retro-issues.sh" "$retro31" 2>&1)"; RC31=$?
# Isolate the kit-issue-repo LINE specifically — the row body/title text is
# attacker-controlled fixture prose and must not be able to false-positive
# this assertion by coincidentally containing the word "git".
kir_line31="$(printf '%s\n' "$OUT31" | grep '^kit-issue-repo: unresolved')"
if [ "$RC31" = 0 ] && [ -n "$kir_line31" ] && printf '%s' "$kir_line31" | grep -qi 'git not found'; then
  ok "31 git missing (dry-run): unresolved reason names git" "(exit $RC31)"
else
  no "31 git missing (dry-run): unresolved reason names git" "exit=$RC31 line=[$kir_line31] out=[$OUT31]"
fi

# 32 — GIT MISSING (--apply): gh IS present (probe passes) but git is absent
# → typed degraded message naming git, exit 1, zero gh issue calls.
box32="$(mkbox case-vcs-absent-apply)"
mk_gh_stub "$box32" nomatch
mk_no_git_bin "$box32"
retro32="$(mk_retro "$box32" target-foo r-vcs-absent-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | vcs absent apply delta | CLAUDE.md | B1 | new | HIGH |")"
OUT32="$(PATH="$box32/nogit-bin" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box32/research-sdd/toolbelt/stage-retro-issues.sh" "$retro32" --apply 2>&1)"; RC32=$?
gh_called_32=0
[ -f "$box32/bin/gh.log" ] && grep -q 'issue' "$box32/bin/gh.log" && gh_called_32=1
if [ "$RC32" != 0 ] && printf '%s' "$OUT32" | grep -qi 'degraded' \
   && printf '%s' "$OUT32" | grep -qi 'git not found' && [ "$gh_called_32" = 0 ]; then
  ok "32 git missing (--apply): degraded names git, exit 1, zero gh calls" "(exit $RC32)"
else
  no "32 git missing (--apply): degraded names git, exit 1, zero gh calls" \
    "exit=$RC32 gh_called=$gh_called_32 out=[$OUT32]"
fi

# ---------------------------------------------------------------------------
# kit issue #1046 round 2: SSH host aliases, ports, shape tightening, the
# lost-bad-value subshell bug, and the F1 reason wording.
# ---------------------------------------------------------------------------

# derive_dry <box> <url>: git-init <box> with origin <url>, run a plain
# dry-run (no override), and set OUT/RC. Small helper to keep cases 33-42
# terse — they all share this exact shape.
derive_dry() {
  local box="$1" url="$2" tgt="${3:-target-foo}"
  mk_git_remote "$box" "$url"
  local retro
  retro="$(mk_retro "$box" "$tgt" r.md \
    "<!-- review-status: pending -->" \
    "| 1 | delta | CLAUDE.md | B1 | new | HIGH |")"
  OUT="$(PATH="$box/bin:$PATH" "$BASH_BIN" \
    "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC=$?
}

# 33 — ITEM 1: scp form, SSH config Host alias (no user@) → host ALWAYS
# dropped for scp form, regardless of whether it looks like a github alias.
box33="$(mkbox case-scp-alias)"
derive_dry "$box33" "git@github.com-alias:o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "33 ITEM1 scp alias host dropped: 'git@github.com-alias:o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "33 ITEM1 scp alias host dropped: 'git@github.com-alias:o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 34 — ITEM 1: URL-scheme, "www." alias prefix → dropped.
box34="$(mkbox case-https-www-alias)"
derive_dry "$box34" "https://www.github.com/o/n"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "34 ITEM1 https www. alias dropped: 'https://www.github.com/o/n' -> 'o/n'" "(exit $RC)"
else
  no "34 ITEM1 https www. alias dropped: 'https://www.github.com/o/n' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 35 — ITEM 1: URL-scheme, SSH config Host alias suffix → dropped.
box35="$(mkbox case-https-alias-suffix)"
derive_dry "$box35" "https://github.com-alias/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "35 ITEM1 https alias-suffix host dropped: 'github.com-alias' -> 'o/n'" "(exit $RC)"
else
  no "35 ITEM1 https alias-suffix host dropped: 'github.com-alias' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 36 — ITEM 2: ssh:// scp-style with :port → port stripped, github.com dropped.
box36="$(mkbox case-ssh-port)"
derive_dry "$box36" "ssh://git@github.com:22/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "36 ITEM2 ssh:// with :port: 'ssh://git@github.com:22/o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "36 ITEM2 ssh:// with :port: 'ssh://git@github.com:22/o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 37 — ITEM 2: https:// with :port → port stripped, github.com dropped.
box37="$(mkbox case-https-port)"
derive_dry "$box37" "https://github.com:443/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "37 ITEM2 https:// with :port: 'https://github.com:443/o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "37 ITEM2 https:// with :port: 'https://github.com:443/o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 38 — ITEM 2: ssh:// alias host ("ssh.github.com") WITH :port → both the
# port-strip and the alias check must fire together.
box38="$(mkbox case-ssh-alias-port)"
derive_dry "$box38" "ssh://git@ssh.github.com:443/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: o/n$'; then
  ok "38 ITEM2 ssh alias host with :port: 'ssh.github.com:443' -> 'o/n'" "(exit $RC)"
else
  no "38 ITEM2 ssh alias host with :port: 'ssh.github.com:443' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 39 — ITEM 2 (non-github host): a real GHE host with :port keeps the HOST
# (port stripped, hostname retained) — proves port-stripping isn't
# github-specific.
box39="$(mkbox case-ghe-port)"
derive_dry "$box39" "https://ghe.corp.com:8443/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: ghe.corp.com/o/n$'; then
  ok "39 ITEM2 GHE host with :port: 'ghe.corp.com:8443' -> 'ghe.corp.com/o/n'" "(exit $RC)"
else
  no "39 ITEM2 GHE host with :port: 'ghe.corp.com:8443' -> 'ghe.corp.com/o/n'" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# KEEP regressions (explicit): these three forms must NOT change behaviour.
# 40 — real origin, scp form, user@.
box40="$(mkbox case-keep-real-origin)"
derive_dry "$box40" "git@github.com:angeles725/sdd-investigacion.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: angeles725/sdd-investigacion$'; then
  ok "40 KEEP real origin scp: 'git@github.com:angeles725/sdd-investigacion.git' unchanged" "(exit $RC)"
else
  no "40 KEEP real origin scp: 'git@github.com:angeles725/sdd-investigacion.git' unchanged" "exit=$RC out=[$OUT]"
fi

# 41 — mixed-case host, underscore/dot in owner/repo.
box41="$(mkbox case-keep-mixedcase)"
derive_dry "$box41" "https://GitHub.com/My_Org/Repo.Name.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: My_Org/Repo.Name$'; then
  ok "41 KEEP mixed-case host + owner/repo: 'GitHub.com/My_Org/Repo.Name.git' -> 'My_Org/Repo.Name'" "(exit $RC)"
else
  no "41 KEEP mixed-case host + owner/repo: 'GitHub.com/My_Org/Repo.Name.git' -> 'My_Org/Repo.Name'" "exit=$RC out=[$OUT]"
fi

# 42 — GHE https, no port, host kept verbatim.
box42="$(mkbox case-keep-ghe)"
derive_dry "$box42" "https://ghe.corp.com/o/n.git"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^kit-issue-repo: ghe.corp.com/o/n$'; then
  ok "42 KEEP GHE https: 'https://ghe.corp.com/o/n.git' -> 'ghe.corp.com/o/n'" "(exit $RC)"
else
  no "42 KEEP GHE https: 'https://ghe.corp.com/o/n.git' -> 'ghe.corp.com/o/n'" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# ITEM 4 — tightened shape: owner/repo/host segments must START with
# [A-Za-z0-9]; this alone rejects a bare '.'/'..' segment and a leading '-'.
box_shape="$(mkbox case-item4-shape)"
mk_gh_stub "$box_shape" nomatch
retro_shape="$(mk_retro "$box_shape" target-foo r-shape.md \
  "<!-- review-status: pending -->" \
  "| 1 | shape delta | CLAUDE.md | B1 | new | HIGH |")"
shape_bad_values=(
  "../o/n"
  "-o/n"
  "o/.."
)
shape_idx=0
for shape_bad in "${shape_bad_values[@]}"; do
  shape_idx=$((shape_idx+1))
  shape_out_dry="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$shape_bad" \
    "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" 2>&1)"; shape_rc_dry=$?
  : > "$box_shape/bin/gh.log"
  shape_out_apply="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$shape_bad" \
    "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" --apply 2>&1)"; shape_rc_apply=$?
  shape_gh_called=0
  [ -f "$box_shape/bin/gh.log" ] && grep -q 'issue' "$box_shape/bin/gh.log" && shape_gh_called=1
  if [ "$shape_rc_dry" = 0 ] && printf '%s\n' "$shape_out_dry" | grep -q "^kit-issue-repo: unresolved (invalid repo shape '${shape_bad}'" \
     && [ "$shape_rc_apply" != 0 ] && printf '%s' "$shape_out_apply" | grep -qi 'degraded' \
     && [ "$shape_gh_called" = 0 ]; then
    ok "43.$shape_idx ITEM4 shape-tightening rejects '$shape_bad'" "(dry=$shape_rc_dry apply=$shape_rc_apply)"
  else
    no "43.$shape_idx ITEM4 shape-tightening rejects '$shape_bad'" \
      "dry_rc=$shape_rc_dry dry_out=[$shape_out_dry] apply_rc=$shape_rc_apply apply_out=[$shape_out_apply] gh_called=$shape_gh_called"
  fi
done

# 44 — ITEM4 positive control: dots/underscores mid-segment stay ACCEPTED —
# the tightened regex must reject only a BAD leading character, not dots or
# underscores in general.
OUT44="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="My_Org/Repo.Name" \
  "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" 2>&1)"; RC44=$?
if [ "$RC44" = 0 ] && printf '%s\n' "$OUT44" | grep -q '^kit-issue-repo: My_Org/Repo.Name$'; then
  ok "44 ITEM4 positive control: 'My_Org/Repo.Name' still accepted" "(exit $RC44)"
else
  no "44 ITEM4 positive control: 'My_Org/Repo.Name' still accepted" "exit=$RC44 out=[$OUT44]"
fi

# ---------------------------------------------------------------------------
# 45 — ITEM 3: the degraded/unresolved message must NAME the bad value, not
# print an empty 'invalid repo shape '' — proves resolve_kit_issue_repo() is
# no longer called through a `$(...)` subshell that discards its globals.
box45="$(mkbox case-item3-bad-value-survives)"
retro45="$(mk_retro "$box45" target-foo r-item3.md \
  "<!-- review-status: pending -->" \
  "| 1 | item3 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT45="$(PATH="$box45/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
  "$BASH_BIN" "$box45/research-sdd/toolbelt/stage-retro-issues.sh" "$retro45" 2>&1)"; RC45=$?
if [ "$RC45" = 0 ] && printf '%s\n' "$OUT45" | grep -q "^kit-issue-repo: unresolved (invalid repo shape 'foo' — expected \[HOST/\]OWNER/REPO)$"; then
  ok "45 ITEM3 bad value survives the call: message names 'foo', not ''" "(exit $RC45)"
else
  no "45 ITEM3 bad value survives the call: message names 'foo', not ''" "exit=$RC45 out=[$OUT45]"
fi

# ---------------------------------------------------------------------------
# 46 — ITEM 5: the F1 enclosing-repo reason must say the kit root is not the
# git TOPLEVEL (not the vaguer/inaccurate "not its own git checkout"), and
# must name the enclosing checkout's actual root.
enclosing_parent_46="$ROOT/case-item5-enclosing-parent"
mkdir -p "$enclosing_parent_46"
git init -q "$enclosing_parent_46" >/dev/null 2>&1
git -C "$enclosing_parent_46" remote add origin \
  "https://github.com/item5-owner/item5-repo.git" >/dev/null 2>&1
box46="$(mkbox_at "$enclosing_parent_46" nested-kit)"
retro46="$(mk_retro "$box46" target-foo r-item5.md \
  "<!-- review-status: pending -->" \
  "| 1 | item5 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT46="$(PATH="$box46/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box46/research-sdd/toolbelt/stage-retro-issues.sh" "$retro46" 2>&1)"; RC46=$?
if [ "$RC46" = 0 ] && printf '%s\n' "$OUT46" | grep -qi 'toplevel' \
   && printf '%s\n' "$OUT46" | grep -q "$enclosing_parent_46"; then
  ok "46 ITEM5 F1 reason names 'toplevel' and the enclosing root path" "(exit $RC46)"
else
  no "46 ITEM5 F1 reason names 'toplevel' and the enclosing root path" "exit=$RC46 out=[$OUT46]"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
