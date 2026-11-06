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
# The qualifier itself is pinned by the ur-* scenarios, idg-unverified-stop-keeps-the-backlog-qualifier and
# n-backlog-unreadable-qualifier of `rsdd status show`; this suite keeps the fixture guard. Usage: research-sdd-status-unreadable-stop.test.sh   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT_UNDER_TEST:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
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
NEAR="## Gap backlog"
COV="| high | done gap | web | covered |"
U1="| 1 | numbered one | web | pending |"
U2="| 2 | numbered two | web | pending |"
U3="| P0 | numbered three | web | pending |"

fx1="$TMP/one";   mkdir -p "$fx1";   mk_state "$fx1/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1"
fx3="$TMP/many";  mkdir -p "$fx3";   mk_state "$fx3/RESEARCH-STATE.md" "$NEAR" "$COV" "$U1" "$U2" "$U3"

# 0. fixture guards: the unreadable fixtures really have uncounted rows (else the cases below are vacuous)
for g in one:1 many:3; do
  n="$(bash "$SUT" "$TMP/${g%%:*}" --sync-state 2>&1 | grep -c 'unknown priority')"
  [ "$n" = "${g##*:}" ] && ok "0 fixture ${g%%:*}: parser WARNs on ${g##*:} unknown-priority row(s)" || no "0 fixture ${g%%:*}: want ${g##*:} unknown-priority WARNs, got $n"
done

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
