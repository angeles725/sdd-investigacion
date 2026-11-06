#!/usr/bin/env bash
# research-sdd-status-deferred-populations.test.sh — every deferred-row reader counts ONE population (kit issue #2162).
#
# THE RULE: an OPEN backlog row whose priority cell is `deferred` is one population whether its table has 4 cells
# (`| deferred | gap | type | status |`) or 5 (`| deferred | id | gap | artifact | status |`, METHODOLOGY §8b). Status is
# the LAST cell; a row is closed by `~~` in its 2nd cell, or `~~` / a check mark in its status. Four readers walk
# those rows and must agree (CLAUDE.md §7 — two populations under one name):
#   research-sdd-status.sh  count_deferred   (--sync-state writes deferred_open)
#   verify-state.sh         derive_deferred  (the derived side of `deferred_open=declared/derived`)
#   research-sdd-status.sh  --queue reader   (open-deferred awk; classifies a queued id as `deferred`)
#   research-sdd-status.sh  known_gaps       (count_all_known_gaps + deferred_open; checked via the verify-state sum WARN)
# SCOPE and WIDTH are judged ONE way by all of them: a deferred row counts only inside a `## Gap-backlog` section (or a table
# with a Priority header, the backlog_rows rule), its cell count must equal the width its table's separator row fixes (a
# mismatch is a typed `WARN: deferred row skipped`, never a silent drop and never a guessed "open" row), and a struck Gap cell
# (`~~` in the first two cells of a 5-column row, whichever of the two layouts it uses) closes it. The two awk blocks that
# implement this (deferred_scan / derive_deferred) must stay byte-identical: probe awk_eq diffs them.
# Before #2162 the first two required exactly 4 cells, so a 5-column open deferred row was queue-recognised and in
# known_gaps but never in deferred_open. The cases put 4- and 5-cell rows in the FIRST, a MIDDLE and the LAST position of
# their table, and alone (single-element), per CLAUDE.md §7 (test the list edges).
#
# The count_deferred, --queue, known_gaps and WARN readers of research-sdd-status.sh are pinned by the def-* scenarios of
# `rsdd status show` (internal/status/show/s2_scenarios_test.go); this suite keeps the verify-state agreement (vs_count) and the
# byte-equality of the DEF-AWK block against the frozen oracle (awk_eq). --prove-teeth mutates that block and requires awk_eq red.
#
# Usage: research-sdd-status-deferred-populations.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
# verify-state.sh is a shim to the Go `rsdd verify state` (kit issue #2457); its old awk program lives on, frozen, as the
# parity oracle of the Go differential tests. The awk_eq probe keeps research-sdd-status.sh equal to that frozen copy.
ORACLE="$HERE/../../rsdd/internal/verify/testdata/state-legacy/verify-state.sh"
[ -f "$ORACLE" ] || { echo "FATAL: frozen oracle not found: $ORACLE" >&2; exit 2; }
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  _bin="$(mktemp -d)"; ( cd "$HERE/../../rsdd" && go build -o "$_bin/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$_bin/rsdd"
fi
for f in verify-state.sh research-sdd-status.sh; do
  [ -f "$TOOLBELT/$f" ] || { echo "FATAL: SUT not found: $TOOLBELT/$f" >&2; exit 2; }
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# mkstate <dir> <queue-ids> <backlog-body> <case> (KY[case] overrides the coverage denominator) : a state file whose envelope the readers re-derive (queue ids may be empty).
declare -A KY=()
mkstate() {
  mkdir -p "$1"
  {
    echo "# Deferred populations"
    [ -n "$2" ] && echo "next_session_queue: $2"
    printf '\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 1\nblock_scope: shared-global\n'
    printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n'
    printf '<!-- /research-state.v1 -->\n\n## Coverage\n- **Coverage metric**: %s / %s closed\n\n## Gap-backlog (prioritized)\n%s\n\n## Iteration history\n| It | Focus | Block | New gaps |\n|---|---|---|---|\n| 1 | f | B1 | 0 |\n\n## Stop control\n' "$(grep -c '^| deferred .*\(~~\|✅\)' <<<"$3")" "${KY[$4]:-$(grep -c '^| \(deferred\|high\) ' <<<"$3")}" "$3"
  } > "$1/RESEARCH-STATE.md"
}
H4=$'| Priority | Gap | Artifact | Status |\n|---|---|---|---|'
H5=$'| Priority | ID | Gap | Artifact | Status |\n|---|---|---|---|---|'
# case name -> backlog body and expected open-deferred count
declare -A BODY=() WANT=() QUEUE=()
BODY[single4]="$H4"$'\n| deferred | B1-G1 a | x | parked |'
BODY[single5]="$H5"$'\n| deferred | B1-G1 | a | x | parked |'
BODY[first5]="$H5"$'\n| deferred | B1-G1 | a | x | parked |\n| high | B1-G2 | b | x | pending |\n| high | B1-G3 | c | x | pending |'
BODY[mid5]="$H5"$'\n| high | B1-G1 | a | x | pending |\n| deferred | B1-G2 | b | x | parked |\n| high | B1-G3 | c | x | pending |'
BODY[last5]="$H5"$'\n| high | B1-G1 | a | x | pending |\n| high | B1-G2 | b | x | pending |\n| deferred | B1-G3 | c | x | parked |'
BODY[first4]="$H4"$'\n| deferred | B1-G1 a | x | parked |\n| high | B1-G2 b | x | pending |\n| high | B1-G3 c | x | pending |'
BODY[mid4]="$H4"$'\n| high | B1-G1 a | x | pending |\n| deferred | B1-G2 b | x | parked |\n| high | B1-G3 c | x | pending |'
BODY[last4]="$H4"$'\n| high | B1-G1 a | x | pending |\n| high | B1-G2 b | x | pending |\n| deferred | B1-G3 c | x | parked |'
# closed 5-cell rows are NOT open: ~~ in the id cell, ~~ in the status, a check mark in the status; the last row is open.
BODY[closed5]="$H5"$'\n| deferred | ~~B1-G1~~ | a | x | parked |\n| deferred | B1-G2 | b | x | ~~dropped~~ |\n| deferred | B1-G3 | c | x | ✅ done |\n| deferred | B1-G4 | d | x | parked |'
# both widths in one file, in two tables: 2 + 2 open, 1 closed per table.
BODY[mixed]="$H4"$'\n| deferred | B1-G1 a | x | parked |\n| deferred | B1-G2 b | x | ✅ done |\n| deferred | B1-G3 c | x | parked |\n\n'"$H5"$'\n| deferred | B1-G4 | d | x | parked |\n| deferred | B1-G5 | e | x | ✅ done |\n| deferred | B1-G6 | f | x | parked |'
# a 5-cell deferred row whose gap cell holds an escaped pipe (GFM, #2148) is still ONE 5-cell row.
BODY[esc5]="$H5"$'\n| deferred | B1-G1 | a\\|b | x | parked\\|more |'
WANT[single4]=1; WANT[single5]=1; WANT[first5]=1; WANT[mid5]=1; WANT[last5]=1
WANT[first4]=1; WANT[mid4]=1; WANT[last4]=1; WANT[closed5]=1; WANT[mixed]=4; WANT[esc5]=1
QUEUE[single4]="B1-G1"; QUEUE[single5]="B1-G1"; QUEUE[first5]="B1-G1"; QUEUE[mid5]="B1-G2"
QUEUE[last5]="B1-G3"; QUEUE[first4]="B1-G1"; QUEUE[mid4]="B1-G2"; QUEUE[last4]="B1-G3"
QUEUE[closed5]="B1-G1,B1-G2,B1-G3,B1-G4"; QUEUE[mixed]="B1-G1,B1-G2,B1-G3,B1-G4,B1-G5,B1-G6"; QUEUE[esc5]="B1-G1"
# queue-reader expectation: ids classified `deferred` (open) + `done` (closed) = every id, none unknown.
H5S=$'| Priority | Gap | Scope | Where | Status |\n|---|---|---|---|---|'
# a bare (unescaped) pipe in a 4-column table's status cell makes a CLOSED row look like an open 5-cell row: width is judged per
# table, so the row is skipped with a typed WARN (not counted as open); the genuine open row after it still counts.
BODY[barepipe]="$H4"$'\n| deferred | B1-G1 a | x | ✅ done | y |\n| deferred | B1-G2 b | x | parked |'
# a 6-cell row in a 5-column table: typed WARN, not counted.
BODY[wide6]="$H5"$'\n| deferred | B1-G1 | a | x | parked | extra |\n| deferred | B1-G2 | b | x | parked |'
# a deferred row in a table OUTSIDE ## Gap-backlog with no Priority header is not a backlog row; with a Priority header it is.
BODY[outside]="$H4"$'\n| deferred | B1-G1 a | x | parked |\n\n## Notes\n| Severity | Gap | Type | Status |\n|---|---|---|---|\n| deferred | B1-G2 n | x | parked |'
BODY[outsidehdr]="$H4"$'\n| deferred | B1-G1 a | x | parked |\n\n## Other backlog\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| deferred | B1-G2 n | x | parked |'
# Gap | Scope | Where | Status layout (Gap in the 2nd cell): open, struck Gap cell, and a struck 3rd cell (the id-first layout's Gap).
BODY[scope5]="$H5S"$'\n| deferred | B1-G1 a | s | w | parked |\n| deferred | ~~B1-G2 b~~ | s | w | parked |\n| deferred | B1-G3 c | ~~s~~ | w | parked |'
# id-first layout with a struck Gap cell (3rd cell): closed.
BODY[struck5]="$H5"$'\n| deferred | B1-G1 | a | x | parked |\n| deferred | B1-G2 | ~~b~~ | x | parked |'
WANT[barepipe]=1; WANT[wide6]=1; WANT[outside]=1; WANT[outsidehdr]=2; WANT[scope5]=1; WANT[struck5]=1
QUEUE[barepipe]="B1-G2"; QUEUE[wide6]="B1-G2"; QUEUE[outside]="B1-G1"; QUEUE[outsidehdr]="B1-G1,B1-G2"; QUEUE[scope5]="B1-G1,B1-G2,B1-G3"; QUEUE[struck5]="B1-G1,B1-G2"
KY[barepipe]=1; KY[wide6]=1; KY[outside]=1; KY[scope5]=0; KY[struck5]=0  # 0 = the derived known_gaps stands alone (no coverage-metric floor), so the closed-row rule is what the identity checks
CASES="single4 single5 first5 mid5 last5 first4 mid4 last4 closed5 mixed esc5 barepipe wide6 outside outsidehdr scope5 struck5"

declare -A PR=()
PROBES="vs_count awk_eq"
# probes <tree> : run every reader of <tree> over every case; PR_<probe> = ok | the first disagreement.
probes() {
  local t="$1" c d out n
  PR[vs_count]=ok; PR[awk_eq]=ok
  for c in $CASES; do
    d="$TMP/case.$c.$RANDOM"; mkstate "$d" "${QUEUE[$c]}" "${BODY[$c]}" "$c"
    bash "$t/research-sdd-status.sh" "$d" --sync-state >/dev/null 2>/dev/null
    out="$(bash "$t/verify-state.sh" "$d" 2>&1)"
    n="$(sed -n 's/.*deferred_open=[^/]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
    [ "$n" = "${WANT[$c]}" ] || { [ "${PR[vs_count]}" = ok ] && PR[vs_count]="$c: verify-state derived deferred_open=${n:-?} want ${WANT[$c]}"; }
  done
  # the two awk blocks (deferred_scan / derive_deferred) are one program: byte-identical between their markers.
  if ! cmp -s <(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$t/research-sdd-status.sh") <(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$ORACLE") \
     || [ -z "$(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$ORACLE")" ]; then PR[awk_eq]="the DEF-AWK blocks differ (or are missing)"; fi
}
declare -A DESC=(
  [vs_count]="verify-state.sh derive_deferred: the same cases derive the same deferred_open as research-sdd-status.sh"
  [awk_eq]="research-sdd-status.sh deferred_scan and the frozen verify-state.sh derive_deferred (the Go port's oracle) hold the byte-identical awk program"
)
probes "$TOOLBELT"
for p in $PROBES; do
  v="${PR[$p]}"
  if [ "$v" = ok ]; then ok "$p: ${DESC[$p]}"; else no "$p: ${DESC[$p]} — $v"; fi
done

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: one mutant of the DEF-AWK block (the byte-equality probe awk_eq must turn red) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_built || exit 2
  # tooth <name> <file> <literal-old> <literal-new> <probe-that-must-turn-red>
  tooth() {
    local name="$1" file="$2" old="$3" new="$4" watch="$5" t="$TMP/mut-$1" s v
    mkdir -p "$t/lib"; cp "$TOOLBELT"/*.sh "$t/"; cp -r "$TOOLBELT"/lib/. "$t/lib/"
    s="$(cat "$TOOLBELT/$file"; printf x)"; s="${s%x}"
    case "$s" in *"$old"*) ;; *) no "teeth $name: literal not found in $file — the call site moved"; return ;; esac
    printf '%s' "${s/"$old"/"$new"}" > "$t/$file"
    if ! mutant_built "teeth $name" "$TOOLBELT/$file" "$t/$file" >/dev/null 2>&1; then no "teeth $name: mutant refused by lib/mutant.sh"; return; fi
    probes "$t"; v="${PR[$watch]}"
    if [ "$v" != ok ]; then ok "teeth $name: mutant turns probe $watch red"; else no "teeth $name: probe $watch stays green on the mutant — THEATER"; fi
  }
  # (the st-* and kg-closed teeth mutated the bash readers; those readers are Go now, pinned by the def-* scenarios of rsdd status show)
  tooth awk-eq    research-sdd-status.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[cnt]);  # DEF-STATUS-LAST' awk_eq
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
