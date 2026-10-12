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

# mkstate <dir> <queue-ids> <backlog-body> : a state file whose envelope the readers re-derive (queue ids may be empty).
mkstate() {
  mkdir -p "$1"
  {
    echo "# Deferred populations"
    [ -n "$2" ] && echo "next_session_queue: $2"
    printf '\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 1\nblock_scope: shared-global\n'
    printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n'
    printf '<!-- /research-state.v1 -->\n\n## Coverage\n- **Coverage metric**: %s / %s closed\n\n## Gap-backlog (prioritized)\n%s\n\n## Iteration history\n| It | Focus | Block | New gaps |\n|---|---|---|---|\n| 1 | f | B1 | 0 |\n\n## Stop control\n' "$(grep -c '^| deferred .*\(~~\|✅\)' <<<"$3")" "$(grep -c '^| \(deferred\|high\) ' <<<"$3")" "$3"
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
CASES="single4 single5 first5 mid5 last5 first4 mid4 last4 closed5 mixed esc5"

declare -A PR=()
PROBES="st_count vs_count queue kg_sum"
# probes <tree> : run every reader of <tree> over every case; PR_<probe> = ok | the first disagreement.
probes() {
  local t="$1" c d out n wantq line
  PR[st_count]=ok; PR[vs_count]=ok; PR[queue]=ok; PR[kg_sum]=ok
  for c in $CASES; do
    d="$TMP/case.$c.$RANDOM"; mkstate "$d" "${QUEUE[$c]}" "${BODY[$c]}"
    bash "$t/research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
    n="$(sed -n 's/^deferred_open: *//p' "$d/RESEARCH-STATE.md" | head -1)"
    [ "$n" = "${WANT[$c]}" ] || { [ "${PR[st_count]}" = ok ] && PR[st_count]="$c: --sync-state deferred_open=${n:-?} want ${WANT[$c]}"; }
    out="$(bash "$t/verify-state.sh" "$d" 2>&1)"
    n="$(sed -n 's/.*deferred_open=[^/]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
    [ "$n" = "${WANT[$c]}" ] || { [ "${PR[vs_count]}" = ok ] && PR[vs_count]="$c: verify-state derived deferred_open=${n:-?} want ${WANT[$c]}"; }
    # known_gaps (derived from the backlog rows + deferred_open) must satisfy the sum identity verify-state gates.
    if grep -q 'known_gaps=.* != sum of declared counters' <<<"$out"; then [ "${PR[kg_sum]}" = ok ] && PR[kg_sum]="$c: $(grep -o 'known_gaps=.*stale' <<<"$out" | head -1)"; fi
    out="$(bash "$t/research-sdd-status.sh" "$d" --next --queue 2>&1)"
    line="$(grep -o 'next_session_queue ([^)]*)' <<<"$out" | head -1)"
    wantq="$(awk -F, '{print NF}' <<<"${QUEUE[$c]}") ids"
    case "$line" in
      *"($wantq: "*", ${QDEF[$c]} deferred, "*", 0 unknown)"*) ;;
      *) [ "${PR[queue]}" = ok ] && PR[queue]="$c: queue summary [$line] want $wantq with ${QDEF[$c]} deferred, 0 unknown" ;;
    esac
  done
}
declare -A DESC=(
  [st_count]="research-sdd-status.sh count_deferred: --sync-state derives the open 4- and 5-cell deferred rows (first/middle/last/single, closed forms excluded)"
  [vs_count]="verify-state.sh derive_deferred: the same cases derive the same deferred_open as research-sdd-status.sh"
  [queue]="research-sdd-status.sh --queue reader: every queued deferred row (4- or 5-cell) is recognised as deferred, none unknown"
  [kg_sum]="known_gaps identity: backlog rows + deferred_open satisfy verify-state's sum check (no known_gaps != sum WARN)"
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
  tooth st-count research-sdd-status.sh 'if (cnt!=4 && cnt!=5) next  # DEF-WIDTH' 'if (cnt!=4) next  # DEF-WIDTH' st_count
  tooth st-status research-sdd-status.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[4])  # DEF-STATUS-LAST' st_count
  tooth vs-count verify-state.sh 'if (cnt!=4 && cnt!=5) next  # DEF-WIDTH' 'if (cnt!=4) next  # DEF-WIDTH' vs_count
  tooth vs-status verify-state.sh 'st=tolower(a[cnt])  # DEF-STATUS-LAST' 'st=tolower(a[4])  # DEF-STATUS-LAST' vs_count
  tooth st-queue research-sdd-status.sh '(NF!=6 && NF!=7)) next  # DEF-WIDTH' '(NF!=6)) next  # DEF-WIDTH' queue
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
