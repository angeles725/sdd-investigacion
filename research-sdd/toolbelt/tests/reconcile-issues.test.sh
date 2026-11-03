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
  # `sleep` stub (kit issue #1784): never really waits; logs its argument so a test can read the backoff.
  printf '#!%s\nprintf "%%s\\n" "$1" >> "%s/bin/sleep.log"\n' "$BASH_BIN" "$box" > "$box/bin/sleep"; chmod +x "$box/bin/sleep"
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
#   mode=closed-completed <body> [<comment>] / closed-notplanned <body> / closed-fail: only a --state closed list answers
#                       (completed/notplanned run the SUT's own --jq through real jq over a JSON array)
#                       (kit issue #1555); the open list is empty
#   mode=nomatch (default): issue list returns empty (all untracked)
mk_gh_stub() {
  local box="$1" mode="${2:-nomatch}"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box"
    # Kit issue #1369 (c): REJECT what real gh would reject instead of inventing support. `gh issue
    # list` accepts only --repo/--state/--search/--jq/--limit/--json; --limit a positive integer;
    # --json fields from {body, state, stateReason}; --state open|closed|all. Anything else exits 2.
    cat <<'STUBHELP'
_validate_list() {
  local _sk="" _a _f
  for _a in "$@"; do
    if [ -n "$_sk" ]; then
      case "$_sk" in
        json)  for _f in ${_a//,/ }; do case "$_f" in stateReason) if [ -n "${GH_STUB_OLD_GH:-}" ]; then echo "Unknown JSON field: \"stateReason\"" >&2; return 1; fi ;; body|state|number|comments) ;; *) echo "gh stub: unknown JSON field: $_f" >&2; return 1 ;; esac; done ;;
        limit) case "$_a" in ''|*[!0-9]*|0) echo "gh stub: invalid --limit: $_a" >&2; return 1 ;; esac ;;
        state) case "$_a" in open|closed|all) ;; *) echo "gh stub: invalid --state: $_a" >&2; return 1 ;; esac ;;
      esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|list) ;;
      --repo|--search|--jq) _sk=val ;;
      --state) _sk=state ;;
      --json)  _sk=json ;;
      --limit) _sk=limit ;;
      *) echo "gh stub: unknown flag: $_a" >&2; return 1 ;;
    esac
  done
}
case " $* " in *" issue list "*) _validate_list "$@" || exit 2 ;; esac
STUBHELP
    printf 'case " $* " in\n'
    if [ "$mode" = "noauth" ]; then
      printf '  *" auth status "*) exit 1 ;;\n'
    else
      printf '  *" auth status "*) exit 0 ;;\n'
    fi
    # kit issue #1555: the OPEN-issue modes below answer only an open/default-state list. A CLOSED-state
    # list gets an empty reply unless the mode is one of the closed-* modes (which answer ONLY it).
    case "$mode" in
      closed-*|noauth) ;;
      *) printf '  *" issue list "*" --state closed "*) exit 0 ;;\n' ;;
    esac
    case "$mode" in
      closed-completed|closed-notplanned)
        # $3 = body text of ONE closed issue; the mode sets its stateReason. The stub answers like gh does:
        # it feeds a real JSON array to the SUT's own --jq expression (run by the real jq), so the
        # SUT's stateReason filter is what decides the output. Open-state lists see an empty reply.
        _sr="COMPLETED"; [ "$mode" = "closed-notplanned" ] && _sr="NOT_PLANNED"
        _srl="completed"; [ "$mode" = "closed-notplanned" ] && _srl="not_planned"
        # gh api (the old-gh fallback reads state_reason from ONE batched listing): GH_STUB_API_FAIL makes it fail.
        printf '  *" api "*) [ -n "${GH_STUB_API_FAIL:-}" ] && { echo "${GH_STUB_API_FAIL_MSG:-gh: HTTP 500}" >&2; exit 1; }; if [ -n "${GH_STUB_API_UPDATED:-}" ]; then _s=""; case "$*" in *since=*) _a="$*"; _s="${_a##*since=}"; _s="${_s// */}" ;; esac; if [ -n "$_s" ] && [[ "$GH_STUB_API_UPDATED" < "$_s" ]]; then exit 0; fi; fi; printf "7 %%s\\n" "%s"; exit 0 ;;\n' "$_srl"
        _cm=""; [ -n "${4:-}" ] && _cm="{\"body\":\"$4\",\"authorAssociation\":\"${5:-OWNER}\"}"
        printf '  *" issue list "*" --state closed "*) if [ -n "${GH_STUB_OLDGH_LIST_FAIL:-}" ]; then case " $* " in *stateReason*) ;; *) echo "gh: HTTP 502" >&2; exit 1 ;; esac; fi; _jq=""; _p=""; for _a in "$@"; do [ "$_p" = "--jq" ] && _jq="$_a"; _p="$_a"; done; printf %%s '"'"'[{"number":7,"body":"%s","stateReason":"%s","comments":[%s]}]'"'"' | "%s" -r "$_jq"; exit 0 ;;\n' "${3:-}" "$_sr" "$_cm" "$JQ_BIN"
        printf '  *" issue list "*) exit 0 ;;\n'
        ;;
      closed-fill)
        # honours --limit like gh: a closed-state list returns exactly <limit> issues (all COMPLETED,
        # bodies of unrelated issues), run through the SUT's own --jq by real jq. Truncation fixture.
        printf '  *" issue list "*" --state closed "*) _jq=""; _l=5; _p=""; for _a in "$@"; do [ "$_p" = "--jq" ] && _jq="$_a"; [ "$_p" = "--limit" ] && _l="$_a"; _p="$_a"; done; _j="["; for ((_i = 1; _i <= _l; _i++)); do _j="$_j{\\"body\\":\\"unrelated $_i\\",\\"stateReason\\":\\"COMPLETED\\"},"; done; printf "%%s" "${_j%%,}]" | "%s" -r "$_jq"; exit 0 ;;\n' "$JQ_BIN"
        printf '  *" issue list "*) exit 0 ;;\n'
        ;;
      closed-multi)
        # kit issue #1752 round 1: SEVERAL closed issues with mixed state_reason. $3 = JSON array file
        # (objects with number/body/comments); `gh api` answers not_planned for issue 8, completed otherwise.
        printf '  *" api "*) [ -n "${GH_STUB_API_FAIL:-}" ] && { echo "${GH_STUB_API_FAIL_MSG:-gh: HTTP 403 rate limit exceeded}" >&2; exit 1; }; printf "7 completed\\n8 not_planned\\n9 completed\\n"; exit 0 ;;\n'
        printf '  *" issue list "*" --state closed "*) _jq=""; _p=""; for _a in "$@"; do [ "$_p" = "--jq" ] && _jq="$_a"; _p="$_a"; done; "%s" -r "$_jq" < "%s"; exit 0 ;;\n' "$JQ_BIN" "${3:-/dev/null}"
        printf '  *" issue list "*) exit 0 ;;\n'
        ;;
      closed-fail)
        printf '  *" issue list "*" --state closed "*) printf "gh: HTTP 502\\n" >&2; exit 1 ;;\n'
        printf '  *" issue list "*) exit 0 ;;\n'
        ;;
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
      page2)
        # two NON-matching issues; honours --limit like gh (at most <limit> come back). The reply is
        # what the SUT's --jq produces: each body followed by the record-separator line (octal 036).
        printf '  *" issue list "*) _l=""; _p=""; for _a in "$@"; do [ "$_p" = "--limit" ] && _l="$_a"; _p="$_a"; done; _n=2; [ -n "$_l" ] && [ "$_l" -lt 2 ] && _n="$_l"; for ((_i = 1; _i <= _n; _i++)); do printf "unrelated body %%s\\n\\036\\n" "$_i"; done; exit 0 ;;\n'
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

# open_lists <gh.log>: count of OPEN-state `gh issue list` calls (kit issue #1555 added a separate
# --state closed query, so the 38x cases that pin the open/legacy query count must not count it).
open_lists() { grep 'issue list' "$1" | grep -vc -- '--state closed'; }
# open_limit <gh.log>: true when an OPEN-state list call carries an explicit --limit (the closed query has its own).
open_limit() { [ "$(grep 'issue list' "$1" | grep -v -- '--state closed' | grep -cE -- '--limit [0-9]+')" -ge 1 ]; }

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

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
