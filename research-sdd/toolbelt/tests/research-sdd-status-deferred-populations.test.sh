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
# --prove-teeth builds one mutant per changed reader (the pre-fix `cnt!=4` rule) and requires the probe that watches it
# to turn red.
#
# Usage: research-sdd-status-deferred-populations.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
for f in verify-state.sh research-sdd-status.sh; do
  [ -f "$TOOLBELT/$f" ] || { echo "FATAL: SUT not found: $TOOLBELT/$f" >&2; exit 2; }
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# mkstate <dir> <queue-ids> <backlog-body> <case> (KY[case] overrides the coverage denominator) : a state file whose envelope the readers re-derive (queue ids may be empty).
declare -A KY=() WARNWANT=() KGWANT=()
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
declare -A QDEF=()
QDEF[single4]=1; QDEF[single5]=1; QDEF[first5]=1; QDEF[mid5]=1; QDEF[last5]=1; QDEF[first4]=1; QDEF[mid4]=1; QDEF[last4]=1
QDEF[closed5]=1; QDEF[mixed]=4; QDEF[esc5]=1
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
QDEF[barepipe]=1; QDEF[wide6]=1; QDEF[outside]=1; QDEF[outsidehdr]=2; QDEF[scope5]=1; QDEF[struck5]=1
KY[barepipe]=1; KY[wide6]=1; KY[outside]=1; KY[scope5]=0; KY[struck5]=0  # 0 = the derived known_gaps stands alone (no coverage-metric floor), so the closed-row rule is what the identity checks
WARNWANT[barepipe]=1; WARNWANT[wide6]=1
KGWANT[scope5]=3; KGWANT[struck5]=2  # closed rows (backlog_rows) + open deferred (deferred_scan): the same markers close a row in both
CASES="single4 single5 first5 mid5 last5 first4 mid4 last4 closed5 mixed esc5 barepipe wide6 outside outsidehdr scope5 struck5"

declare -A PR=()
PROBES="st_count vs_count queue kg_sum warn awk_eq"
# probes <tree> : run every reader of <tree> over every case; PR_<probe> = ok | the first disagreement.
probes() {
  local t="$1" c d out n wantq line
  PR[st_count]=ok; PR[vs_count]=ok; PR[queue]=ok; PR[kg_sum]=ok; PR[warn]=ok; PR[awk_eq]=ok
  for c in $CASES; do
    d="$TMP/case.$c.$RANDOM"; mkstate "$d" "${QUEUE[$c]}" "${BODY[$c]}" "$c"
    bash "$t/research-sdd-status.sh" "$d" --sync-state >/dev/null 2>"$d/sync.err"
    if grep -q 'WARN: deferred row skipped' "$d/sync.err"; then n=1; else n=0; fi
    [ "$n" = "${WARNWANT[$c]:-0}" ] || { [ "${PR[warn]}" = ok ] && PR[warn]="$c: typed 'deferred row skipped' WARN present=$n want ${WARNWANT[$c]:-0}"; }
    n="$(sed -n 's/^deferred_open: *//p' "$d/RESEARCH-STATE.md" | head -1)"
    [ "$n" = "${WANT[$c]}" ] || { [ "${PR[st_count]}" = ok ] && PR[st_count]="$c: --sync-state deferred_open=${n:-?} want ${WANT[$c]}"; }
    out="$(bash "$t/verify-state.sh" "$d" 2>&1)"
    n="$(sed -n 's/.*deferred_open=[^/]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
    [ "$n" = "${WANT[$c]}" ] || { [ "${PR[vs_count]}" = ok ] && PR[vs_count]="$c: verify-state derived deferred_open=${n:-?} want ${WANT[$c]}"; }
    # known_gaps (derived from the backlog rows + deferred_open) must satisfy the sum identity verify-state gates.
    n="$(sed -n 's/^known_gaps: *//p' "$d/RESEARCH-STATE.md" | head -1)"
    if [ -n "${KGWANT[$c]:-}" ] && [ "$n" != "${KGWANT[$c]}" ]; then [ "${PR[kg_sum]}" = ok ] && PR[kg_sum]="$c: synced known_gaps=${n:-?} want ${KGWANT[$c]}"; fi
    if [ -z "${WARNWANT[$c]:-}" ] && grep -q 'known_gaps=.* != sum of declared counters' <<<"$out"; then [ "${PR[kg_sum]}" = ok ] && PR[kg_sum]="$c: $(grep -o 'known_gaps=.*stale' <<<"$out" | head -1)"; fi
    out="$(bash "$t/research-sdd-status.sh" "$d" --next --queue 2>&1)"
    line="$(grep -o 'next_session_queue ([^)]*)' <<<"$out" | head -1)"
    wantq="$(awk -F, '{print NF}' <<<"${QUEUE[$c]}") ids"
    case "$line" in
      *"($wantq: "*", ${QDEF[$c]} deferred, "*", 0 unknown)"*) ;;
      *) [ "${PR[queue]}" = ok ] && PR[queue]="$c: queue summary [$line] want $wantq with ${QDEF[$c]} deferred, 0 unknown" ;;
    esac
  done
  # the two awk blocks (deferred_scan / derive_deferred) are one program: byte-identical between their markers.
  if ! cmp -s <(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$t/research-sdd-status.sh") <(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$t/verify-state.sh") \
     || [ -z "$(sed -n '/# DEF-AWK-START/,/# DEF-AWK-END/p' "$t/verify-state.sh")" ]; then PR[awk_eq]="the DEF-AWK blocks differ (or are missing)"; fi
}
declare -A DESC=(
  [st_count]="research-sdd-status.sh count_deferred: --sync-state derives the open 4- and 5-cell deferred rows (first/middle/last/single, closed forms excluded)"
  [vs_count]="verify-state.sh derive_deferred: the same cases derive the same deferred_open as research-sdd-status.sh"
  [queue]="research-sdd-status.sh --queue reader: every queued deferred row (4- or 5-cell) is recognised as deferred, none unknown"
  [warn]="a deferred row whose cell count differs from its table's width (bare pipe, 6+ cells) draws the typed WARN; well-formed rows draw none"
  [awk_eq]="research-sdd-status.sh deferred_scan and verify-state.sh derive_deferred hold the byte-identical awk program"
  [kg_sum]="known_gaps: closed rows + deferred_open stay one total (struck-Gap 5-column cases), and verify-state's sum check draws no WARN"
)
probes "$TOOLBELT"
for p in $PROBES; do
  v="${PR[$p]}"
  if [ "$v" = ok ]; then ok "$p: ${DESC[$p]}"; else no "$p: ${DESC[$p]} — $v"; fi
done

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: one mutant per changed reader (the pre-fix 4-cell-only rule restored) --"
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
  tooth st-width  research-sdd-status.sh 'if (cnt!=sc) {' 'if (0) {' st_count
  tooth vs-width  verify-state.sh 'if (cnt!=sc) {' 'if (0) {' vs_count
  tooth st-warn   research-sdd-status.sh 'print "WARN: deferred row skipped (" cnt' 'print "" cnt' warn
  tooth st-status research-sdd-status.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[4])  # DEF-STATUS-LAST' st_count
  tooth vs-status verify-state.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[4])  # DEF-STATUS-LAST' vs_count
  tooth st-scope  research-sdd-status.sh 'if (!ib && !tok) next' 'if (0) next' st_count
  tooth vs-scope  verify-state.sh 'if (!ib && !tok) next' 'if (0) next' vs_count
  tooth st-closed research-sdd-status.sh '(sc==5 && index(a[3],"~~")) || index(st,"~~") || index(st,"✅")) next  # DEF-CLOSED' 'index(st,"~~") || index(st,"✅")) next  # DEF-CLOSED' st_count
  tooth vs-closed verify-state.sh '(sc==5 && index(a[3],"~~")) || index(st,"~~") || index(st,"✅")) next  # DEF-CLOSED' 'index(st,"~~") || index(st,"✅")) next  # DEF-CLOSED' vs_count
  tooth st-queue  research-sdd-status.sh '$(deferred_scan 1)' '$(true)' queue
  tooth awk-eq    verify-state.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[cnt]);  # DEF-STATUS-LAST' awk_eq
  # the known_gaps identity: backlog_rows must close a deferred row on the same markers deferred_scan uses (else the row is in neither bucket)
  tooth kg-closed research-sdd-status.sh 'if (p=="deferred") { if (!(index(a[2],"~~") || (sc==5 && index(a[3],"~~")) ||' 'if (p=="deferred") { if (!(index(a[2],"~~") ||' kg_sum
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
