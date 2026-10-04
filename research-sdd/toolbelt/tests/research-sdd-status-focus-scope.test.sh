#!/usr/bin/env bash
# research-sdd-status-focus-scope.test.sh — `--next --focus <slug>` scopes the STALE aggregation (kit #1543).
#
# Before: `--focus` selected the state file, but the STALE gate ran verify-state.sh over the WHOLE
# corpus, so defects in a legacy sibling focus (no `## Gap-backlog`, frozen envelope, unknown priority
# token) bricked `--next` for a clean active focus. Now the gate verifies ONLY the named focus; the
# corpus-wide behaviour stays the default (no flag) and has an explicit spelling, `--next --all`.
#
# Usage: research-sdd-status-focus-scope.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-focus-scope.test.sh =="

# mk_active FILE — a clean focus: derived-consistent envelope, one pending high gap.
mk_active() {
  {
    echo "# A — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| high | the active gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 1"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$1"
}
# mk_legacy FILE [noheading] — the defects of kit #1543: a frozen envelope (covered_blocks=266 against 0
# block files on disk), an unknown priority token (SES2) under the canonical heading; with `noheading`
# the table sits under a non-canonical heading instead (the "8 files without ## Gap-backlog" form).
mk_legacy() {
  local h="## Gap-backlog (prioritized)"; [ "${2:-}" = noheading ] && h="## Backlog notes"
  {
    echo "# L — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 266\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "$h"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| SES2 | the legacy gap | web | pending |"
  } > "$1"
}

multi="$TMP/multi"; mkdir -p "$multi"
mk_active "$multi/RESEARCH-STATE-active.md"; mk_legacy "$multi/RESEARCH-STATE-legacy.md"
mk_legacy "$multi/RESEARCH-STATE-oldnotes.md" noheading
single="$TMP/single"; mkdir -p "$single"; mk_active "$single/RESEARCH-STATE-active.md"
brokensingle="$TMP/brokensingle"; mkdir -p "$brokensingle"; mk_legacy "$brokensingle/RESEARCH-STATE-legacy.md"

# run SUT_PATH ARGS... -> stdout (stderr dropped)
run() { local s="$1"; shift; bash "$s" "$@" 2>/dev/null; }

# 0. the fixture really is broken corpus-wide and clean for the active focus (guards against a vacuous setup)
bash "$HERE/../verify-state.sh" "$multi" >/dev/null 2>&1; rc_all=$?
bash "$HERE/../verify-state.sh" "$multi" --focus active >/dev/null 2>&1; rc_act=$?
[ "$rc_all" = 1 ] && [ "$rc_act" = 0 ] && ok "0 fixture: verify-state corpus-wide=1, --focus active=0" || no "0 fixture precondition: all=$rc_all active=$rc_act"

# 1. the issue's case: --next --focus active returns the active focus's NEXT, not STALE
got="$(run "$SUT" "$multi" --next --focus active)"
[ "$got" = "NEXT | high | the active gap" ] && ok "1 --next --focus active -> NEXT (legacy defects out of scope)" || no "1 --focus active: got [$got]"

# 2. --next --all still reports STALE with the legacy corpus named
got="$(run "$SUT" "$multi" --next --all)"
case "$got" in "STALE | "*) ok "2a --next --all -> STALE" ;; *) no "2a --next --all: got [$got]" ;; esac
case "$got" in *"legacy"*) ok "2b --all STALE names the legacy focus" ;; *) no "2b --all STALE does not name the legacy focus: [$got]" ;; esac

case "$got" in *"failing focus: "*active*) no "2c --all STALE wrongly names the clean focus: [$got]" ;; *) ok "2c --all STALE does not name the clean focus" ;; esac

# 3. default (neither flag) is unchanged: corpus-wide, identical to --all
d="$(run "$SUT" "$multi" --next)"; a="$(run "$SUT" "$multi" --next --all)"
[ "$d" = "$a" ] && case "$d" in "STALE | "*) true ;; *) false ;; esac && ok "3 default == --all (corpus-wide, STALE) in a multi-focus corpus" || no "3 default [$d] vs --all [$a]"

# 4. --focus legacy still reports STALE for the broken focus itself (scoping must not hide its own defects)
got="$(run "$SUT" "$multi" --next --focus legacy)"
case "$got" in "STALE | "*) ok "4 --next --focus legacy -> STALE (its own defects still surface)" ;; *) no "4 --focus legacy: got [$got]" ;; esac

# 5. single-focus corpora: --focus, --all and default agree (byte-identical contract)
a="$(run "$SUT" "$single" --next)"; b="$(run "$SUT" "$single" --next --focus active)"; c="$(run "$SUT" "$single" --next --all)"
[ "$a" = "NEXT | high | the active gap" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ] && ok "5 single-focus: default == --focus == --all" || no "5 single-focus: [$a] [$b] [$c]"
a="$(run "$SUT" "$brokensingle" --next)"; b="$(run "$SUT" "$brokensingle" --next --focus legacy)"
case "$a" in "STALE | "*) [ "$a" = "$b" ] && ok "5b broken single-focus: default == --focus (both STALE, identical line)" || no "5b: [$a] vs [$b]" ;; *) no "5b broken single-focus not STALE: [$a]" ;; esac

# 6. argument validation: --all is --next-only and excludes --focus / --root (typed usage error, exit 2)
bash "$SUT" "$multi" --next --all --focus active >/dev/null 2>&1; r1=$?
bash "$SUT" "$multi" --next --all --root >/dev/null 2>&1; r2=$?
bash "$SUT" "$multi" --all >/dev/null 2>&1; r3=$?
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && ok "6 --all with --focus / --root / without --next -> exit 2" || no "6 exit codes: $r1 $r2 $r3"

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the focus-scoped STALE gate --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TB="$HERE/.."
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # A: the scoping is dropped (verify-state always runs corpus-wide) -> case 1 must go red
  t="$(mk_tree A)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's/ --focus "\$focus_slug" >\/dev\/null 2>&1$/ >\/dev\/null 2>\&1/' >/dev/null 2>&1; then
    got="$(run "$t/research-sdd-status.sh" "$multi" --next --focus active)"
    [ "$got" = "NEXT | high | the active gap" ] && no "teeth A: unscoped mutant still returns NEXT — THEATER" || ok "teeth A: scoping dropped -> case 1 has teeth (got [${got%% |*}])"
  else no "teeth A: mutant could not be built (pattern absent / refused)"; fi
  # B: --all is treated as the focus scope-out of the gate (gate skipped) -> case 2a must go red
  t="$(mk_tree B)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's/^  if ! _gate_verify; then/  if false; then/' >/dev/null 2>&1; then
    got="$(run "$t/research-sdd-status.sh" "$multi" --next --all)"
    case "$got" in "STALE | "*) no "teeth B: gate-disabled mutant still STALE — THEATER" ;; *) ok "teeth B: gate disabled -> case 2a has teeth" ;; esac
  else no "teeth B: mutant could not be built (pattern absent / refused)"; fi
  # C: the --all/--focus exclusion is removed -> case 6 must go red
  t="$(mk_tree C)"
  if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" 's/^\[ "\$all_flag" = 1 \] && { \[ "\$root_flag" = 1 \] || \[ -n "\$focus_slug" \]; }.*$/: # mutated/' >/dev/null 2>&1; then
    bash "$t/research-sdd-status.sh" "$multi" --next --all --focus active >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && no "teeth C: exclusion removed but still exit 2 — THEATER" || ok "teeth C: exclusion removed -> case 6 has teeth (rc=$rc)"
  else no "teeth C: mutant could not be built (pattern absent / refused)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
