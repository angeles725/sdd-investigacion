#!/usr/bin/env bash
# research-sdd-status-root-pick.test.sh — status.sh's state-file pick prefers the un-suffixed root (kit #1818 slice 2).
#
# Before: with neither --focus nor --root, status.sh took `find ... | sort | head -1`; in a flat corpus
# RESEARCH-STATE-aaa.md sorts BEFORE RESEARCH-STATE.md ('-' < '.'), so the report described a FOCUS file.
# Now the default pick goes through lib/state-files.sh resolve_state_file (root first, shallowest first),
# the same resolver archive / verify-state / verify-registry use. --root / --focus keep their behaviour.
#
# Usage: research-sdd-status-root-pick.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-root-pick.test.sh =="

# mk_state FILE GAP — a clean, derived-consistent state with ONE pending high gap named GAP.
mk_state() {
  {
    echo "# S — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| ${3:-high} | $2 | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 1"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$1"
}

# run SUT_PATH ARGS... -> stdout (stderr dropped)
run() { local s="$1"; shift; bash "$s" "$@" 2>/dev/null; }
# nstep SUT_PATH ARGS... -> the plain report's "pending backlog" line, which is read from the PICKED state file.
# NOTE: `--next` and the report's "next step" aggregate over EVERY state file (first active focus wins) by
# design, so the pick is observable in per-file fields; the fixtures differ in the pending priority.
# The root's gap is high, the focus file's is medium.
nstep() { local s="$1"; shift; bash "$s" "$@" 2>/dev/null | sed -n 's/^  pending backlog : //p'; }
ROOTBL="high=1 medium=0 low=0"; FOCBL="high=0 medium=1 low=0"

flat="$TMP/flat"; mkdir -p "$flat"
mk_state "$flat/RESEARCH-STATE.md" "root gap"
mk_state "$flat/RESEARCH-STATE-aaa.md" "aaa gap" medium
# fixture guard: the lexical-first file really is the focus file (else the case below proves nothing)
first="$(printf '%s\n' "$flat"/RESEARCH-STATE*.md | LC_ALL=C sort | head -1)"
[ "${first##*/}" = "RESEARCH-STATE-aaa.md" ] && ok "0 fixture: lexical-first is RESEARCH-STATE-aaa.md" || no "0 fixture: lexical-first is [$first]"

# 1. THE #1818 case: default run reports the ROOT, not the lexically-first focus file
got="$(nstep "$SUT" "$flat")"
[ "$got" = "$ROOTBL" ] && ok "1 default report on flat root+focus describes the root" || no "1 default report: got [$got] want [$ROOTBL]"
got="$(nstep "$SUT" "$flat" --next)"
[ -z "$got" ] && ok "2 (--next prints a verdict, not the report: helper sanity)" || no "2 helper sanity: [$got]"

# 3. --root / --focus unchanged
got="$(nstep "$SUT" "$flat" --root)"
[ "$got" = "$ROOTBL" ] && ok "3 --root report -> root" || no "3 --root report: got [$got] want [$ROOTBL]"
got="$(nstep "$SUT" "$flat" --focus aaa)"
[ "$got" = "$FOCBL" ] && ok "4 --focus aaa report -> focus file" || no "4 --focus aaa: got [$got] want [$FOCBL]"
got="$(run "$SUT" "$flat" --next --focus aaa)"
[ "$got" = "NEXT | medium | aaa gap" ] && ok "4b --next --focus aaa -> focus gap" || no "4b --next --focus aaa: got [$got]"
got="$(run "$SUT" "$flat" --next --focus nope)"
[ "$got" = "BOOTSTRAP | no RESEARCH-STATE-nope.md under $flat" ] && ok "5 --focus unknown -> typed BOOTSTRAP line" || no "5 --focus unknown: got [$got]"

# 6. flat focus-only corpus (no root): the C-locale-first focus file, as before
fo="$TMP/focus-only"; mkdir -p "$fo"
mk_state "$fo/RESEARCH-STATE-aaa.md" "aaa gap"; mk_state "$fo/RESEARCH-STATE-bbb.md" "bbb gap"
got="$(run "$SUT" "$fo" --next --focus aaa)"
[ "$got" = "NEXT | high | aaa gap" ] && ok "6 focus-only corpus: --focus aaa" || no "6 focus-only --focus aaa: got [$got]"

# 7. split layout (equal rank in different dirs, resolver rc 2): accepted, C-locale-first dir wins as before
sp="$TMP/split"; mkdir -p "$sp/a" "$sp/b"
mk_state "$sp/a/RESEARCH-STATE-x.md" "split-a gap"; mk_state "$sp/b/RESEARCH-STATE-y.md" "split-b gap"
got="$(run "$SUT" "$sp" --next --focus x)"
[ "$got" = "NEXT | high | split-a gap" ] && ok "7 split layout --focus x -> its file" || no "7 split --focus x: got [$got]"
got="$(run "$SUT" "$sp" --next --focus y)"
[ "$got" = "NEXT | high | split-b gap" ] && ok "7b split layout --focus y -> its file" || no "7b split --focus y: got [$got]"
got="$(run "$SUT" "$sp" --next --root)"
case "$got" in BOOTSTRAP*) ok "7c split --root with no root -> BOOTSTRAP (unchanged)" ;; *) no "7c split --root: got [$got]" ;; esac

# 8. absent: no state file -> typed BOOTSTRAP / plain line
ab="$TMP/absent"; mkdir -p "$ab"
got="$(run "$SUT" "$ab" --next)"
[ "$got" = "BOOTSTRAP | no RESEARCH-STATE under $ab" ] && ok "8 absent --next -> BOOTSTRAP" || no "8 absent --next: got [$got]"
got="$(run "$SUT" "$ab")"
[ "$got" = "no RESEARCH-STATE under $ab — run research-sdd-init.sh" ] && ok "8b absent plain -> typed line" || no "8b absent plain: got [$got]"

# 9. nested single (COB-IM2 shape): root beside a focus file in a subdir -> root
ne="$TMP/nested"; mkdir -p "$ne/corpus"
mk_state "$ne/corpus/RESEARCH-STATE.md" "nested root gap"; mk_state "$ne/corpus/RESEARCH-STATE-arch.md" "nested arch gap" medium
got="$(nstep "$SUT" "$ne")"
[ "$got" = "$ROOTBL" ] && ok "9 nested root beside focus -> root" || no "9 nested: got [$got] want [$ROOTBL]"

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the default state-file pick --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # A: restore the lexical `find | sort | head -1` default pick -> case 1 must go red
  t="$(mk_tree A)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" '/# SF-DEFAULT-PICK/{n;s/.*/  state="$(find "$target" -maxdepth 3 -name '"'"'RESEARCH-STATE*.md'"'"' -not -name '"'"'*.template.md'"'"' -not -path '"'"'*\/.git\/*'"'"' 2>\/dev\/null | sort | head -1)"; _sf_rc=0/;}' >/dev/null 2>&1; then
    got="$(nstep "$t/research-sdd-status.sh" "$flat")"
    [ "$got" = "$ROOTBL" ] && no "teeth A: lexical-pick mutant still reports the root — THEATER" || ok "teeth A: lexical pick restored -> case 1 has teeth (got [$got])"
  else no "teeth A: mutant could not be built (marker absent / refused)"; fi
  # B: the resolver's root preference removed (rank key forced to 1) -> case 1 must go red
  t="$(mk_tree B)"
  if mutant_sed "$TB/lib/state-files.sh" "$t/lib/state-files.sh" 's/(b == "RESEARCH-STATE.md") ? 0 : 1/1/' >/dev/null 2>&1; then
    got="$(nstep "$t/research-sdd-status.sh" "$flat")"
    [ "$got" = "$ROOTBL" ] && no "teeth B: root preference removed but status still reports the root — THEATER" || ok "teeth B: resolver root preference removed -> case 1 has teeth (got [$got])"
  else no "teeth B: mutant could not be built (pattern absent / refused)"; fi
fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
