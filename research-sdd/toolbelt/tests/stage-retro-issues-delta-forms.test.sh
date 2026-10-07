#!/usr/bin/env bash
# stage-retro-issues-delta-forms.test.sh — the delta-section forms real fleet retros use that the seeder used to
# file as "Unclassifiable retro deltas" (kit issues #1895 #1932 #1933 #1934 #1938 #1939): numbered prose items
# under a canonical heading, lettered table ids (SPKI-A), `## Delta <ID> — PRIORITY — title` H2 entries and a
# standalone `### Proposals` heading with numbered items. Every fixture under fixtures/stage-retro-issues/ is the
# shape of a real retro; the two negative fixtures MUST stay unclassifiable (a lessons list and a numbered
# Evidence list are not delta lists). The gh stub exits 0 silently and logs every call; the dry run never calls it.
#
# Usage: stage-retro-issues-delta-forms.test.sh                (run the suite)
#        stage-retro-issues-delta-forms.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
FIX="$HERE/fixtures/stage-retro-issues"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixtures not found: $FIX" >&2; exit 2; }
for _l in retro-status retro-grammar target-paths scrub-issue-text; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper lib/$_l.sh not found" >&2; exit 2; }
done
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

MUT=(); MUTLIB=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

# mkbox <name>: hermetic sandbox (TARGETS.md with target-foo, SUT + libs copy, gh stub). Prints the box path.
# MUT mutates the SUT copy, MUTLIB mutates the retro-grammar.sh copy (the delta classifier lives there).
mkbox() {
  local box="$ROOT/$1" l
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh"
  for l in retro-status retro-grammar target-paths scrub-issue-text; do cp "$HERE/../lib/$l.sh" "$box/research-sdd/toolbelt/lib/$l.sh"; done
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "gh $*" >> "$0.log"\nexit 0\n' > "$box/bin/gh"; chmod +x "$box/bin/gh"
  if [ "${#MUT[@]}" -gt 0 ]; then
    mutant_chain "mut-$1" "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "${MUT[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  if [ "${#MUTLIB[@]}" -gt 0 ]; then
    mutant_chain "mutlib-$1" "$HERE/../lib/retro-grammar.sh" "$box/research-sdd/toolbelt/lib/retro-grammar.sh" "${MUTLIB[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  printf '%s' "$box"
}

# run <box> <fixture-name>: copies the fixture into the target's retros dir, dry-runs the seeder. Sets OUT, RC.
run() {
  local box="$1" f="$2"
  cp "$FIX/$f" "$box/rh/target-foo/retros/$f"
  OUT="$(PATH="$box/bin:$PATH" RESEARCH_SDD_ISSUE_REPO=test-owner/test-kit \
    "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$box/rh/target-foo/retros/$f" 2>&1)"; RC=$?
}
planned() { grep -c '^planned-issue: ' <<<"$OUT"; }
has() { grep -qF -- "$1" <<<"$OUT"; }
fail_out() { echo "rc=$RC planned=$(planned) out=[${OUT:0:700}]"; return 1; }

c_numbered() {
  local b; b="$(mkbox "num$1")" || return 1; run "$b" numbered-prose.md
  [ "$RC" = 0 ] && [ "$(planned)" = 3 ] && has 'unclassifiable-items: 0' \
    && has 'Saturation → pivot' && has 'delegated-agent citations' && has 'Decompiler-obfuscation is a WALL' \
    && has 'numbered-prose.md · 1' && has 'numbered-prose.md · 2' && has 'numbered-prose.md · 3' \
    && ! has 'evidence list item' && ! has 'narrative, not a delta' && ! has 'unclassifiable-row' && return 0
  fail_out
}
c_numbered_single() {
  local b; b="$(mkbox "one$1")" || return 1; run "$b" numbered-single.md
  [ "$RC" = 0 ] && [ "$(planned)" = 1 ] && has 'A single numbered proposal is still a delta item' \
    && has 'numbered-single.md · 1' && has 'unclassifiable-items: 0' && return 0
  fail_out
}
c_lettered() {
  local b; b="$(mkbox "let$1")" || return 1; run "$b" lettered-table.md
  [ "$RC" = 0 ] && [ "$(planned)" = 3 ] && has 'lettered-table.md · SPKI-A' && has 'lettered-table.md · SPKI-B' \
    && has 'lettered-table.md · SPKI-C' && has 'priority:medium' && has 'unclassifiable-items: 0' && return 0
  fail_out
}
c_h2_delta() {
  local b; b="$(mkbox "h2$1")" || return 1; run "$b" h2-delta.md
  [ "$RC" = 0 ] && [ "$(planned)" = 3 ] && has 'Structure-only binary inspection recipe' \
    && has 'h2-delta.md · A' && has 'h2-delta.md · B' && has 'h2-delta.md · C' \
    && has 'priority:high' && has 'priority:medium' && has 'priority:low' \
    && ! has 'Not a delta' && ! has 'considered, not re-proposed' && has 'unclassifiable-items: 0' && return 0
  fail_out
}
c_h3_proposals() {
  local b; b="$(mkbox "h3$1")" || return 1; run "$b" h3-proposals.md
  [ "$RC" = 0 ] && [ "$(planned)" = 3 ] && has 'Retro-debt counter in the loop state' \
    && has 'Cadence hook' && ! has 'not under a proposal heading' && ! has 'Doctrine one-liner' \
    && has 'unclassifiable-items: 0' && return 0
  fail_out
}
# Negatives: still unclassifiable, nothing planned, the typed path intact.
c_lessons_stays_unc() {
  local b; b="$(mkbox "les$1")" || return 1; run "$b" lessons-bullets.md
  [ "$RC" = 0 ] && [ "$(planned)" = 0 ] && has 'unclassifiable-items: 1' && has 'retro-level=1' && return 0
  fail_out
}
c_evidence_stays_unc() {
  local b; b="$(mkbox "evi$1")" || return 1; run "$b" evidence-only.md
  [ "$RC" = 0 ] && [ "$(planned)" = 0 ] && has 'unclassifiable-items: 1' && has 'retro-level=1' && return 0
  fail_out
}

CHECKS="c_numbered c_numbered_single c_lettered c_h2_delta c_h3_proposals c_lessons_stays_unc c_evidence_stays_unc"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED --"
  # tooth <check> <label> <sut|lib> <sed-stage>...
  tooth() {
    local chk="$1" label="$2" where="$3" why
    shift 3
    MUT=(); MUTLIB=()
    if [ "$where" = lib ]; then MUTLIB=("$@"); else MUT=("$@"); fi
    rm -f "$ROOT/unbuildable"
    if why="$($chk "mut-$label" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif [ -e "$ROOT/unbuildable" ]; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"
    else ok "teeth $label: mutant breaks $chk" "()"; fi
    MUT=(); MUTLIB=()
  }
  tooth c_numbered      numbered-off      lib '/ALT_NUMBERED_ITEM/s/if (match(/if (0 \&\& match(/'
  tooth c_h2_delta      h2-off            lib '/ALT_H2_DELTA/s/.*/        if (0) {/'
  tooth c_h3_proposals  h3-off            lib '/ALT_H3_PROPOSALS/s/.*/        if (0) mode="h3"/'
  tooth c_h2_delta      med-not-medium    lib '/ALT_PRIORITY_MED/s/.*/                  if (0) pr = "MEDIUM"/'
  tooth c_lettered      lettered-rid      sut '/STAGE_RETRO_ISSUES_LETTERED_ID/s/.*/      if (rid ~ \/^[[:alpha:]#][^0-9]*$\/ \&\& rid !~ \/^[A-Z][0-9]\/) next/'
  tooth c_numbered      no-alt-fallback   sut '/STAGE_RETRO_ISSUES_ALT_FALLBACK/s/.*/  _rows=""/'
  tooth c_h2_delta      no-alt-early      sut '/STAGE_RETRO_ISSUES_ALT_EARLY/s/.*/  _alt_early=""/'
  tooth c_evidence_stays_unc evidence-matched lib '/ALT_NUMBERED_GATE/s/.*/      1 {/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
