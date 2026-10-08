#!/usr/bin/env bash
# research-sdd-status-unreadable-stop.test.sh — a `--next` STOP must not claim a clean exhaustion while backlog rows
# were UNREAD (kit issue #1959; maintainer decision on the issue: inline qualifier, non-terminal).
#
# Before: a focus whose backlog uses a non-canonical grammar (near-miss heading such as `## Gap backlog`, tier tokens
# that are not §8b tiers, ...) made `--next` print a bare `STOP | read-only-investigable exhausted (0)` — the parser
# had counted the rows as nothing, so the verdict read as "all gaps closed" while the WARN sat on stderr only.
# Now the STOP line itself carries `[backlog-unreadable: N rows]` (N = the rows the parser could not count, the same
# number sync-state treats as a lower bound), appended AFTER any `[issue-coverage: unverified]` qualifier. The line
# is still a `STOP | ` verdict (hook/loop consumers match the prefix), and `--emit-token` refuses to turn it into a
# `STOP: campaign` token (non-terminal: the unread rows must be reconciled first).
#
# Scope: no flag counts the unread rows of every state file the aggregate walked (stopped/paused focuses excluded —
# they are not part of the verdict); --root / --focus count only the PICKED file, matching the scoped verdict.
#
# Usage: research-sdd-status-unreadable-stop.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT_UNDER_TEST:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-unreadable-stop.test.sh =="

# mk_state FILE HEADING ROW... — an exhausted, derived-consistent state; HEADING is the backlog heading line and every
# ROW is a table row (`| prio | gap | src | status |`) written under it. All rows are non-routable (covered, or a
# non-tier priority), so the verdict is a STOP.
mk_state() {
  local f="$1" heading="$2"; shift 2
  {
    echo "# S — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\nblocks_since_retro: 0\n<!-- /research-state.v1 -->\n\n'
    echo "$heading"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 0"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$f"
}
CANON="## Gap-backlog (prioritized)"; NEAR="## Gap backlog"
COV="| high | done gap | web | covered |"
U1="| 1 | numbered one | web | pending |"
U2="| 2 | numbered two | web | pending |"
U3="| P0 | numbered three | web | pending |"

BARE="STOP | read-only-investigable exhausted (0)"
# nx SUT FIXTURE ARGS... -> the single --next verdict line (stdout only; stderr dropped). The environment hook
# _IDG_TIMEOUT_BIN is left to the caller.
nx() { local s="$1" f="$2"; shift 2; bash "$s" "$f" --next "$@" 2>/dev/null | head -1; }
want() { # LABEL GOT WANT
  if [ "$2" = "$3" ]; then ok "$1 -> $3"; else no "$1: want [$3], got [$2]"; fi; }

fxClean="$TMP/clean"; mkdir -p "$fxClean"; mk_state "$fxClean/RESEARCH-STATE.md" "$CANON" "$COV"
fx1="$TMP/one";   mkdir -p "$fx1";   mk_state "$fx1/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1"
fx3="$TMP/many";  mkdir -p "$fx3";   mk_state "$fx3/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1" "$U2" "$U3"

# 0. fixture guards: the unreadable fixtures really have uncounted rows (else the cases below are vacuous)
for g in one:1 many:3; do
  n="$(bash "$SUT" "$TMP/${g%%:*}" --sync-state 2>&1 | grep -c 'unknown priority')"
  [ "$n" = "${g##*:}" ] && ok "0 fixture ${g%%:*}: parser WARNs on ${g##*:} unknown-priority row(s)" || no "0 fixture ${g%%:*}: want ${g##*:} unknown-priority WARNs, got $n"
done

# 1. the cases
want "1a clean canonical backlog stays a bare STOP (no qualifier)" "$(nx "$SUT" "$fxClean")" "$BARE"
want "1b N=1 unread row" "$(nx "$SUT" "$fx1")" "$BARE [backlog-unreadable: 1 rows]"
want "1c N=3 unread rows" "$(nx "$SUT" "$fx3")" "$BARE [backlog-unreadable: 3 rows]"
want "1d the qualifier also rides --focus on a single-file corpus" "$(nx "$SUT" "$fx1" --root)" "$BARE [backlog-unreadable: 1 rows]"

# 2. focus-scoped vs whole corpus: root clean (0 unread), focus `bad` has 2 unread, focus `good` is clean
fxM="$TMP/multi"; mkdir -p "$fxM"
mk_state "$fxM/RESEARCH-STATE.md" "$CANON" "$COV"
mk_state "$fxM/RESEARCH-STATE-bad.md" "$NEAR" "$COV" "$U1" "$U2"
mk_state "$fxM/RESEARCH-STATE-good.md" "$CANON" "$COV"
want "2a whole corpus sums the walked files" "$(nx "$SUT" "$fxM")" "$BARE [backlog-unreadable: 2 rows]"
want "2b --focus bad counts only the picked focus" "$(nx "$SUT" "$fxM" --focus bad)" "$BARE [backlog-unreadable: 2 rows]"
want "2c --focus good stays bare (the sibling's unread rows are not its verdict)" "$(nx "$SUT" "$fxM" --focus good)" "$BARE"
want "2d --root stays bare" "$(nx "$SUT" "$fxM" --root)" "$BARE"
# two files contribute: 1 + 2 = 3
fxS="$TMP/sum"; mkdir -p "$fxS"
mk_state "$fxS/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1"
mk_state "$fxS/RESEARCH-STATE-bad.md" "$NEAR" "$COV" "$U1" "$U2"
want "2e whole corpus sums across two unreadable files (1 + 2)" "$(nx "$SUT" "$fxS")" "$BARE [backlog-unreadable: 3 rows]"
# a stopped focus is not part of the verdict: its unread rows are not counted
fxP="$TMP/paused"; mkdir -p "$fxP"
mk_state "$fxP/RESEARCH-STATE.md" "$CANON" "$COV"
mk_state "$fxP/RESEARCH-STATE-old.md" "$NEAR" "$COV" "$U1"
printf '| focus | status |\n|---|---|\n| old | paused |\n' > "$fxP/FOCUSES.md"
case "$(nx "$SUT" "$fxP")" in
  "$BARE"|"STOP | no active focus"*) ok "2f paused focus's unread rows are not added to the aggregate verdict" ;;
  *) no "2f paused focus: got [$(nx "$SUT" "$fxP")]" ;; esac

# 3. a NEXT verdict is untouched even when unread rows exist
fxN="$TMP/next"; mkdir -p "$fxN"; mk_state "$fxN/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1" "| high | real gap | web | pending |"
sed -i 's/^investigable_open: 0/investigable_open: 1/; s/^- \*\*Open gaps — read-only investigable\*\*: 0/- **Open gaps — read-only investigable**: 1/' "$fxN/RESEARCH-STATE.md"
want "3 a routable pending gap still wins: NEXT carries no qualifier" "$(nx "$SUT" "$fxN")" "NEXT | high | real gap"

# 4. combined with the unverified qualifier (no timeout binary -> coverage cannot be bounded -> unverified), the new
#    qualifier is appended AFTER it
fxV="$TMP/unverified"; mkdir -p "$fxV/retros"; mk_state "$fxV/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1"
: > "$fxV/retros/2026-10-01-r.md"
got="$(_IDG_TIMEOUT_BIN="" nx "$SUT" "$fxV")"
want "4 unverified + unreadable: both qualifiers, unverified first" "$got" "$BARE [issue-coverage: unverified] [backlog-unreadable: 1 rows]"

# 5. --emit-token: the suffixed STOP must not become a STOP: campaign token (non-terminal); clean STOP still does
et() { bash "$SUT" "$1" --next --emit-token 2>/dev/null | grep '^return-token:'; }
case "$(et "$fx1")" in
  "return-token: unavailable ("*"backlog-unreadable"*) ok "5a emit-token: unreadable STOP -> unavailable naming backlog-unreadable (never STOP: campaign)" ;;
  *) no "5a emit-token on unreadable STOP: got [$(et "$fx1")]" ;; esac
want "5b emit-token: clean STOP still maps to the campaign token" "$(et "$fxClean")" "return-token: STOP: campaign — read-only-investigable exhausted (0)"
bash "$SUT" "$fx1" --next --emit-token >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "5c emit-token: unavailable exits 1" || no "5c emit-token unavailable rc=$rc (want 1)"

# 6. consumer parse: the suffixed line is still selected by the `STOP | ` prefix exactly once (the verdict-pick shape
#    return-token-gate and score-loop-transcript rely on)
n="$(bash "$SUT" "$fx3" --next 2>/dev/null | grep -c '^STOP | ')"
[ "$n" = 1 ] && ok "6 exactly one '^STOP | ' verdict line on the suffixed output" || no "6 want 1 STOP-prefixed line, got $n"

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the backlog-unreadable qualifier --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  mutate() { # NAME SEDEXPR -> sets MUT
    local t; t="$(mk_tree "$1")"
    if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" "$2" >/dev/null 2>&1; then MUT="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $1: mutant could not be built (anchor absent / refused by lib/mutant.sh)"; return 1
  }
  # A: the exhausted STOP drops the qualifier -> 1b/1c go red
  if mutate A '/BU-STOP-EXHAUSTED/s/(0)%s/(0)/'; then
    [ "$(nx "$MUT" "$fx1")" = "$BARE" ] && ok "teeth A: qualifier dropped from the exhausted STOP -> case 1b has teeth" || no "teeth A: mutant still qualified - THEATER"; fi
  # B: the unverified STOP drops the qualifier -> case 4 goes red
  if mutate B '/IDG-UNVERIFIED-MARKER/s/\]%s/]/'; then
    [ "$(_IDG_TIMEOUT_BIN="" nx "$MUT" "$fxV")" = "$BARE [issue-coverage: unverified]" ] && ok "teeth B: qualifier dropped from the unverified STOP -> case 4 has teeth" || no "teeth B: THEATER or crashed mutant"; fi
  # C: the scoped path counts every file instead of the picked one -> 2c goes red
  if mutate C '/BU-SCOPE/s/_bu_compute "\$_ns_pick"/_bu_compute $(list_state_files "$target")/'; then
    [ "$(nx "$MUT" "$fxM" --focus good)" = "$BARE [backlog-unreadable: 2 rows]" ] && ok "teeth C: scope ignored -> case 2c has teeth" || no "teeth C: THEATER or crashed mutant"; fi
  # D: only the last walked file is counted (no sum) -> 2e goes red
  if mutate D '/BU-SUM/s/_bu_total=\$(( _bu_total + _bu_n ))/_bu_total=$_bu_n/'; then
    [ "$(nx "$MUT" "$fxS")" != "$BARE [backlog-unreadable: 3 rows]" ] && [ "$(nx "$MUT" "$fxS")" != "$BARE" ] && ok "teeth D: sum dropped -> case 2e has teeth" || no "teeth D: THEATER or crashed mutant"; fi
  # E: the walked list is replaced by an empty one (stopped/paused filtering lost its input) -> 1b/2a go red
  if mutate E '/BU-WALKED/s/_bu_compute .*  # BU-WALKED/_bu_compute  # BU-WALKED/'; then
    [ "$(nx "$MUT" "$fx1")" = "$BARE" ] && ok "teeth E: walked-file list dropped -> case 1b has teeth" || no "teeth E: THEATER or crashed mutant"; fi
  # F: emit-token maps the suffixed STOP to the campaign token -> 5a goes red
  if mutate F '/ET-BU-NONTERMINAL/d'; then
    case "$(bash "$MUT" "$fx1" --next --emit-token 2>/dev/null | grep '^return-token:')" in "return-token: STOP: campaign"*) ok "teeth F: non-terminal guard dropped -> case 5a has teeth" ;; *) no "teeth F: THEATER or crashed mutant" ;; esac; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
