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
# split-tie fixture has NO root: its expected value is the C-locale-first FOCUS file (a/RESEARCH-STATE-x.md, high gap)
TIEBL="high=1 medium=0 low=0"

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
mk_state "$sp/a/RESEARCH-STATE-x.md" "split-a gap"; mk_state "$sp/b/RESEARCH-STATE-y.md" "split-b gap" medium
got="$(run "$SUT" "$sp" --next --focus x)"
[ "$got" = "NEXT | high | split-a gap" ] && ok "7 split layout --focus x -> its file" || no "7 split --focus x: got [$got]"
got="$(run "$SUT" "$sp" --next --focus y)"
[ "$got" = "NEXT | medium | split-b gap" ] && ok "7b split layout --focus y -> its file" || no "7b split --focus y: got [$got]"
# 7d. THE TIE (resolver rc 2): a default run, equal-rank files in different dirs. The C-locale-first file
# (a/RESEARCH-STATE-x.md, high) is reported, exit 0, with the report intact (no crash, no silent drop).
out="$(bash "$SUT" "$sp" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "7d split tie, default run: exit 0" || no "7d split tie: exit $rc"
got="$(nstep "$SUT" "$sp")"
[ "$got" = "$TIEBL" ] && ok "7e split tie, default run reports the C-locale-first file (a/, high)" || no "7e split tie: got [$got] want [$TIEBL]"
case "$out" in *"== research-sdd-status:"*) ok "7f split tie: report header present" ;; *) no "7f split tie: no report header" ;; esac
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

# 10. --sync-state --focus re-pick: a resolver error (rc >= 3) is a typed error, not the generic "absent" message.
# The stub lib delegates the FIRST resolve_state_file call (the startup pick) and fails every later one with rc 3.
MT="$TMP/mt"; mkdir -p "$MT"
mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
add_stub() {  # TREE [all] — fail resolve_state_file with rc 3 from its second call on (with `all`: from the FIRST call)
  local flag="$1/.rsf-called"; rm -f "$flag"
  [ "${2:-}" = all ] && : > "$flag"
  {
    echo 'eval "$(declare -f resolve_state_file | sed "1s/resolve_state_file/_real_rsf/")"'
    printf 'resolve_state_file() { if [ -e "%s" ]; then return 3; fi; : > "%s"; _real_rsf "$@"; }\n' "$flag" "$flag"
  } >> "$1/lib/state-files.sh"
}
# syncrun SUT — --sync-state --focus aaa on a throwaway copy of the flat fixture; prints "rc|stderr-first-line"
syncrun() {
  local c="$TMP/sync-copy"; rm -rf "$c"; cp -r "$flat" "$c"
  local err; err="$(bash "$1" "$c" --sync-state --focus aaa 2>&1 >/dev/null)"; local rc=$?
  printf '%s|%s' "$rc" "${err%%$'\n'*}"
}
got="$(syncrun "$SUT")"
case "$got" in 0\|*) ok "10 --sync-state --focus aaa on a healthy fixture -> exit 0" ;; *) no "10 healthy sync: got [$got]" ;; esac
t="$(mk_tree S)"; add_stub "$t"
got="$(syncrun "$t/research-sdd-status.sh")"
[ "$got" = "1|research-sdd-status: state-file resolution failed (rc 3)" ] && ok "10b --sync-state --focus, resolver rc 3 -> typed error, exit 1" || no "10b sync rc3: got [$got]"
# 10c/10d. STARTUP pick sites: the resolver fails with rc 3 on the FIRST call -> typed error, exit 1, no report body.
# startrun SUT ARGS... — prints "rc|stdout|first-stderr-line" ("-" for an empty part)
startrun() {
  local s="$1"; shift; local o e rc ef="$TMP/startrun.err"
  o="$(bash "$s" "$flat" "$@" 2>"$ef")"; rc=$?; e="$(sed -n 1p "$ef")"
  printf '%s|%s|%s' "$rc" "${o:--}" "${e:--}"
}
TYPED3="1|-|research-sdd-status: state-file resolution failed (rc 3)"
t="$(mk_tree SD)"; add_stub "$t" all
got="$(startrun "$t/research-sdd-status.sh")"
[ "$got" = "$TYPED3" ] && ok "10c default pick, resolver rc 3 -> typed error, exit 1, no report body" || no "10c default pick rc3: got [$got]"
got="$(startrun "$t/research-sdd-status.sh" --focus aaa)"
[ "$got" = "$TYPED3" ] && ok "10d --focus pick, resolver rc 3 -> typed error, exit 1, no report body" || no "10d --focus pick rc3: got [$got]"

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the state-file pick --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # tooth LABEL MUTANT_SUT WANT FIXTURE — the mutant must run to exit 0 AND print the WRONG file's specific
  # backlog value WANT (positive evidence of the wrong pick); empty output / a crash / a mere "not root" fails.
  tooth() {
    local label="$1" sut="$2" want="$3" fx="$4" out rc got
    bash -n "$sut" 2>/dev/null || { no "teeth $label: mutant does not parse"; return; }
    out="$(bash "$sut" "$fx" 2>/dev/null)"; rc=$?
    got="$(printf '%s\n' "$out" | sed -n 's/^  pending backlog : //p')"
    if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then ok "teeth $label: mutant ran (exit 0) and reported the wrong file ($got)"
    else no "teeth $label: want exit 0 + [$want], got exit $rc + [$got] — THEATER or crashed mutant"; fi
  }
  # A: restore the lexical `find | sort | head -1` default pick (anchored on the assignment line itself)
  t="$(mk_tree A)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's|^  state="\$(resolve_state_file "\$target")"; _sf_rc=\$?  # SF-DEFAULT-PICK$|  state="$(find "$target" -maxdepth 3 -name '"'"'RESEARCH-STATE*.md'"'"' -not -name '"'"'*.template.md'"'"' -not -path '"'"'*/.git/*'"'"' 2>/dev/null \| sort \| head -1)"; _sf_rc=0|' >/dev/null 2>&1
  then tooth "A lexical pick restored" "$t/research-sdd-status.sh" "$FOCBL" "$flat"
  else no "teeth A: mutant could not be built (anchor absent / refused)"; fi
  # B: the resolver's root preference removed (rank key forced to 1)
  t="$(mk_tree B)"
  if mutant_sed "$TB/lib/state-files.sh" "$t/lib/state-files.sh" 's/(b == "RESEARCH-STATE.md") ? 0 : 1/1/' >/dev/null 2>&1
  then tooth "B resolver root preference removed" "$t/research-sdd-status.sh" "$FOCBL" "$flat"
  else no "teeth B: mutant could not be built (pattern absent / refused)"; fi
  # C: rc 2 (tie) treated as fatal at the default/--focus call sites -> the tie run must go red (exit 1, typed error)
  t="$(mk_tree C)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's/\[ "\$_sf_rc" -le 2 \]/[ "$_sf_rc" -le 1 ]/' >/dev/null 2>&1; then
    out="$(bash "$t/research-sdd-status.sh" "$sp" 2>&1)"; rc=$?
    [ "$rc" = 1 ] && case "$out" in *"state-file resolution failed (rc 2)"*) true ;; *) false ;; esac \
      && ok "teeth C: rc 2 treated as fatal -> tie run exits 1 with the typed error (positive evidence)" || no "teeth C: want exit 1 + typed rc-2 error, got exit $rc [$out]"
  else no "teeth C: mutant could not be built"; fi
  # D: the tie picks the LAST path instead of the first -> must report the other dir's file (medium)
  t="$(mk_tree D)"
  if mutant_sed "$TB/lib/state-files.sh" "$t/lib/state-files.sh" 's/-k3,3)"  # RSF-RANK/-k3,3r)"  # RSF-RANK/' >/dev/null 2>&1
  then tooth "D tie picks the last path" "$t/research-sdd-status.sh" "$FOCBL" "$sp"
  else no "teeth D: mutant could not be built (anchor absent / refused)"; fi
  # F/G: the rc >= 3 guard dropped at a startup site -> the run falls through to the generic absent line, exit 0
  # (positive evidence of the wrong behaviour: exit 0 + the "no RESEARCH-STATE" line, not the typed error)
  for site in DEFAULT FOCUS; do
    t="$(mk_tree "G$site")"
    if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" "s/^  \\[ \"\\\$_sf_rc\" -le 2 \\] || {.*# SF-$site-GUARD\$/  :  # SF-$site-GUARD/" >/dev/null 2>&1; then
      add_stub "$t" all
      if [ "$site" = FOCUS ]; then got="$(startrun "$t/research-sdd-status.sh" --focus aaa)"; want="0|no RESEARCH-STATE-aaa.md under $flat — run research-sdd-init.sh|-"
      else got="$(startrun "$t/research-sdd-status.sh")"; want="0|no RESEARCH-STATE under $flat — run research-sdd-init.sh|-"; fi
      [ "$got" = "$want" ] && ok "teeth $site-guard: guard dropped -> falls through to the generic absent line, exit 0 (positive evidence)" || no "teeth $site-guard: got [$got] want [$want]"
    else no "teeth $site-guard: mutant could not be built (anchor absent / refused)"; fi
  done
  # E: --sync-state --focus ignores the resolver rc -> the typed error disappears, the generic absent message returns
  t="$(mk_tree E)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's/; _sf_rc=\$?  # SF-SYNC-FOCUS-PICK$/; _sf_rc=0  # SF-SYNC-FOCUS-PICK/' >/dev/null 2>&1; then
    add_stub "$t"; got="$(syncrun "$t/research-sdd-status.sh")"
    [ "$got" = "1|sync-state: no RESEARCH-STATE-aaa.md under $TMP/sync-copy" ] && ok "teeth E: rc ignored on sync re-pick -> generic absent message (positive evidence)" || no "teeth E: got [$got]"
  else no "teeth E: mutant could not be built"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
