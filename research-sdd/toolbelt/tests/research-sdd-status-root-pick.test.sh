#!/usr/bin/env bash
# Retired cases are pinned in Go: research-sdd/rsdd/internal/status/show/s8a_pick_test.go and scenarios_test.go.
# research-sdd-status-root-pick.test.sh — status.sh's state-file pick prefers the un-suffixed root (kit #1818 slice 2).
#
# Before: with neither --focus nor --root, status.sh took `find ... | sort | head -1`; in a flat corpus
# RESEARCH-STATE-aaa.md sorts BEFORE RESEARCH-STATE.md ('-' < '.'), so the report described a FOCUS file.
# Now the default pick goes through lib/state-files.sh resolve_state_file (root first, shallowest first),
# the same resolver archive / verify-state / verify-registry use. --root / --focus keep their behaviour.
#
# The pick itself (root first, --root, --focus, split layout, resolver failures) is pinned by the pick-*, focus-*, root-* scenarios of
# `rsdd status show` (internal/status/show: s8a_pick_test.go, s1 scenario tables); this suite keeps the fixture guard and one
# behavioural check through the shim. Usage: research-sdd-status-root-pick.test.sh   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
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

# nstep SUT_PATH ARGS... -> the plain report's "pending backlog" line, which is read from the PICKED state file.
# NOTE: the no-flag `--next` and the report's "next step" aggregate over EVERY state file (first active focus
# wins) by design (`--root` / `--focus` scope `--next` to the picked file since #1837, see
# research-sdd-status-next-scope.test.sh), so the pick is observable in per-file fields; the fixtures differ in
# the pending priority.
# The root's gap is high, the focus file's is medium.
nstep() { local s="$1"; shift; bash "$s" "$@" 2>/dev/null | sed -n 's/^  pending backlog : //p'; }

flat="$TMP/flat"; mkdir -p "$flat"
mk_state "$flat/RESEARCH-STATE.md" "root gap"
mk_state "$flat/RESEARCH-STATE-aaa.md" "aaa gap" medium
# fixture guard: the lexical-first file really is the focus file (else the case below proves nothing)
first="$(printf '%s\n' "$flat"/RESEARCH-STATE*.md | LC_ALL=C sort | head -1)"
[ "${first##*/}" = "RESEARCH-STATE-aaa.md" ] && ok "0 fixture: lexical-first is RESEARCH-STATE-aaa.md" || no "0 fixture: lexical-first is [$first]"

# 1 behavioural: the plain report (through the shim) describes the ROOT file (high=1), not the lexical-first focus file (medium=1)
got="$(nstep "$SUT" "$flat")"
[ "$got" = "high=1 medium=0 low=0" ] && ok "1 default pick reports the root's backlog (high=1), not the focus file's" || no "1 pick: [$got]"

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
