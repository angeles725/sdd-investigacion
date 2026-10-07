#!/usr/bin/env bash
# stage-retro-issues-dismissed.test.sh — kit issue #1944: a row a PARTIAL marker resolves as DISMISSED (rejected, not
# shipped; fleet grammar '… · shipped: #1, #3; DISMISSED: #2 (reason); DEFERRED: #7 -->') must NOT be seeded as an
# open delta. stage-retro-issues.sh skips it with a typed `no-match: dismissed (row <id>)` line, counts it with the
# shipped rows, and the all-resolved summary names "shipped or dismissed". First / middle / last / single positions.
# Every tooth asserts the failure TEXT it must produce.
#
# Usage: stage-retro-issues-dismissed.test.sh                (run the suite)
#        stage-retro-issues-dismissed.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
for _l in retro-status retro-grammar target-paths scrub-issue-text; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper lib/$_l.sh not found" >&2; exit 2; }
done
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
MUT=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

mkbox() {
  local box="$ROOT/$1" l
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh"
  for l in retro-status retro-grammar target-paths scrub-issue-text; do cp "$HERE/../lib/$l.sh" "$box/research-sdd/toolbelt/lib/$l.sh"; done
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$box/bin/gh"; chmod +x "$box/bin/gh"
  if [ "${#MUT[@]}" -gt 0 ]; then
    mutant_chain "mut-$1" "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "${MUT[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  printf '%s' "$box"
}
# mkretro <box> <marker-body> <row-count>: a retro with <n> table rows (ids 1..n) and the given marker.
mkretro() {
  local f="$1/rh/target-foo/retros/r.md" i
  { printf '<!-- review-status: %s -->\n# retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n' "$2"
    for i in $(seq 1 "$3"); do printf '| %s | Delta number %s with a long enough title | `x.sh` | B%s | feature | LOW |\n' "$i" "$i" "$i"; done; } > "$f"
  printf '%s' "$f"
}
run() {
  OUT="$(PATH="$1/bin:$PATH" RESEARCH_SDD_ISSUE_REPO=test-owner/test-kit "$BASH_BIN" "$1/research-sdd/toolbelt/stage-retro-issues.sh" "$2" 2>&1)"; RC=$?
}
planned_ids() { grep -oE 'r\.md · [0-9]+' <<<"$OUT" | sed 's/.* · //' | tr '\n' ' '; }
MSG=""
req()    { [ -z "$MSG" ] || return 0; grep -qF -- "$1" <<<"$OUT" || MSG="MISSING: $1"; }
forbid() { [ -z "$MSG" ] || return 0; ! grep -qF -- "$1" <<<"$OUT" || MSG="UNEXPECTED: $1"; }
ids()    { [ -z "$MSG" ] || return 0; [ "$(planned_ids)" = "$1" ] || MSG="PLANNED IDS: [$(planned_ids)] != [$1]"; }
verdict() { [ "$RC" = 0 ] || MSG="${MSG:-RC $RC}"; [ -z "$MSG" ] && return 0; echo "$MSG | out=[${OUT:0:300}]"; return 1; }

c_first() {   # DISMISSED id is the first row
  local b r; b="$(mkbox "first$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 2, 3; DISMISSED: 1 (ruling)' 4)"; run "$b" "$r"; MSG=""
  ids '4 '; req 'no-match: dismissed (row 1)'; forbid 'dismissed (row 2)'; verdict
}
c_middle() {
  local b r; b="$(mkbox "mid$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1, 4; DISMISSED: 2; DEFERRED: 3' 4)"; run "$b" "$r"; MSG=""
  ids '3 '; req 'no-match: dismissed (row 2)'; verdict
}
c_last() {
  local b r; b="$(mkbox "last$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1, 2; DISMISSED: 4' 4)"; run "$b" "$r"; MSG=""
  ids '3 '; req 'no-match: dismissed (row 4)'; verdict
}
c_single_all_resolved() {   # every row shipped or dismissed -> nothing planned, summary names both
  local b r; b="$(mkbox "all$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 2; DISMISSED: 1' 2)"; run "$b" "$r"; MSG=""
  ids ''; req 'no-match: dismissed (row 1)'; req 'all rows are shipped or dismissed (skipped: 2)'; verdict
}
c_fleet_shape() {   # the real rt-authoring marker: shipped 1,3,4,5,6; DISMISSED 2; DEFERRED 7 -> rows 2 skipped, 7 open
  local b r; b="$(mkbox "fleet$1")" || return 1
  r="$(mkretro "$b" 'applied 2026-09-05 · kit e0b701a · shipped: #1 (saturation pivot), #3 (obfuscated docSource), #4 (numeric constants, PR #434), #5 (peer catch), #6 (scratchpad PoC); DISMISSED: #2 ([CERT-a] — ruling, PR #434); DEFERRED: #7' 7)"; run "$b" "$r"; MSG=""
  ids '7 '; req 'no-match: dismissed (row 2)'; verdict
}
c_not_dismissed() {   # a lower-case 'dismissed:' in prose is free text: nothing is skipped as dismissed
  local b r; b="$(mkbox "prose$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1 (the dismissed: 2 idea was discussed)' 3)"; run "$b" "$r"; MSG=""
  ids '2 3 '; forbid 'no-match: dismissed'; verdict
}

CHECKS="c_first c_middle c_last c_single_all_resolved c_fleet_shape c_not_dismissed"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED with the expected failure text --"
  tooth() {
    local chk="$1" label="$2" want="$3" why
    shift 3
    MUT=("$@"); rm -f "$ROOT/unbuildable"
    if why="$($chk "mut-$label" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif [ -e "$ROOT/unbuildable" ]; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"
    elif ! grep -qF -- "$want" <<<"$why"; then no "teeth $label: $chk failed for the WRONG reason" "wanted [$want] got [${why:0:200}]"
    else ok "teeth $label: mutant breaks $chk with [$want]" "()"; fi
    MUT=()
  }
  tooth c_middle  dismissed-not-skipped 'PLANNED IDS: [2 3 ] != [3 ]'   '/STAGE_RETRO_ISSUES_DISMISSED_SKIP/s/= dismissed/= never-dismissed/'
  tooth c_first   typed-line-off        'MISSING: no-match: dismissed (row 1)' 's/echo "no-match: dismissed (row \$_rid)" >&2/:/'
  tooth c_single_all_resolved summary-not-counted 'MISSING: all rows are shipped or dismissed (skipped: 2)' 's/skipped_shipped=\$((skipped_shipped+1)); skipped_dismissed=\$((skipped_dismissed+1)); continue/skipped_dismissed=$((skipped_dismissed+1)); continue/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
