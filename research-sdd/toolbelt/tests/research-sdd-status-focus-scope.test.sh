#!/usr/bin/env bash
# Retired cases are pinned in Go: research-sdd/rsdd/internal/status/show/s4_scenarios_test.go (stale-*, scoping) and scenarios_test.go (all-*).
# research-sdd-status-focus-scope.test.sh — `--next --focus <slug>` scopes the STALE aggregation (kit #1543).
#
# Before: `--focus` selected the state file, but the STALE gate ran verify-state.sh over the WHOLE
# corpus, so defects in a legacy sibling focus (no `## Gap-backlog`, frozen envelope, unknown priority
# token) bricked `--next` for a clean active focus. Now the gate verifies ONLY the named focus; the
# corpus-wide behaviour stays the default (no flag) and has an explicit spelling, `--next --all`.
#
# The --next / --focus / --all scoping itself is pinned by the stale-* and all-* scenarios of `rsdd status show`; this suite keeps the
# fixture precondition on verify-state. Usage: research-sdd-status-focus-scope.test.sh   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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

# 0. the fixture really is broken corpus-wide and clean for the active focus (guards against a vacuous setup)
bash "$HERE/../verify-state.sh" "$multi" >/dev/null 2>&1; rc_all=$?
bash "$HERE/../verify-state.sh" "$multi" --focus active >/dev/null 2>&1; rc_act=$?
[ "$rc_all" = 1 ] && [ "$rc_act" = 0 ] && ok "0 fixture: verify-state corpus-wide=1, --focus active=0" || no "0 fixture precondition: all=$rc_all active=$rc_act"

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
