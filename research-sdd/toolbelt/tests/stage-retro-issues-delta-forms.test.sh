#!/usr/bin/env bash
# stage-retro-issues-delta-forms.test.sh — the delta-section forms real fleet retros use that the seeder used to
# file as "Unclassifiable retro deltas" (kit issues #1895 #1932 #1933 #1934 #1938 #1939): numbered prose items
# under a canonical heading, lettered table ids (SPKI-A), `## Delta <ID> — PRIORITY — title` H2 entries and a
# standalone `### Proposals` heading with numbered items. Every fixture under fixtures/stage-retro-issues/ is the
# shape of a real retro; the negative fixtures MUST stay unclassifiable (a lessons list and a numbered Evidence
# list are not delta lists, a prose heading is still reported when an unrelated list classifies, two lists that
# share ids are refused). The gh stub exits 0 silently and logs every call; the dry run never calls it.
# Every tooth asserts the failure TEXT it must produce, not just "red" (a mutant that breaks the check for
# another reason is a wrong-reason failure and counts as a FAIL).
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
# The first unmet expectation is the check's failure text (so a tooth can assert WHY it went red).
MSG=""
req()    { [ -z "$MSG" ] || return 0; grep -qF -- "$1" <<<"$OUT" || MSG="MISSING: $1"; }
forbid() { [ -z "$MSG" ] || return 0; ! grep -qF -- "$1" <<<"$OUT" || MSG="UNEXPECTED: $1"; }
count()  { [ -z "$MSG" ] || return 0; [ "$(planned)" = "$1" ] || MSG="PLANNED: $(planned) != $1"; }
utf8()   { [ -z "$MSG" ] || return 0; printf '%s\n' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || MSG="INVALID UTF-8 in the dry-run output"; }
verdict() { [ "$RC" = 0 ] || MSG="${MSG:-RC $RC}"; if [ -z "$MSG" ]; then return 0; fi; echo "$MSG | out=[${OUT:0:400}]"; return 1; }

c_numbered() {
  local b; b="$(mkbox "num$1")" || return 1; run "$b" numbered-prose.md; MSG=""
  count 3; req 'unclassifiable-items: 0'; req 'Saturation → pivot'; req 'delegated-agent citations'; req 'Decompiler-obfuscation is a WALL'
  req 'numbered-prose.md · 1'; req 'numbered-prose.md · 2'; req 'numbered-prose.md · 3'
  forbid 'evidence list item'; forbid 'narrative, not a delta'; forbid 'unclassifiable-row'; verdict
}
c_numbered_single() {
  local b; b="$(mkbox "one$1")" || return 1; run "$b" numbered-single.md; MSG=""
  count 1; req 'A single numbered proposal is still a delta item'; req 'numbered-single.md · 1'; req 'unclassifiable-items: 0'; verdict
}
c_lettered() {
  local b; b="$(mkbox "let$1")" || return 1; run "$b" lettered-table.md; MSG=""
  count 3; req 'lettered-table.md · SPKI-A'; req 'lettered-table.md · SPKI-B'; req 'lettered-table.md · SPKI-C'; req 'priority:medium'; req 'unclassifiable-items: 0'; verdict
}
c_h2_delta() {
  local b; b="$(mkbox "h2$1")" || return 1; run "$b" h2-delta.md; MSG=""
  count 3; req 'Structure-only binary inspection recipe'; req 'h2-delta.md · A'; req 'h2-delta.md · B'; req 'h2-delta.md · C'
  req 'priority:high'; req 'priority:medium'; req 'priority:low'; forbid 'Not a delta'; forbid 'considered, not re-proposed'; req 'unclassifiable-items: 0'; verdict
}
c_h3_proposals() {
  local b; b="$(mkbox "h3$1")" || return 1; run "$b" h3-proposals.md; MSG=""
  count 3; req 'Retro-debt counter in the loop state'; req 'Cadence hook'; forbid 'not under a proposal heading'; forbid 'Doctrine one-liner'; req 'unclassifiable-items: 0'; verdict
}
# Negatives: still unclassifiable, nothing planned, the typed path intact.
c_lessons_stays_unc() {
  local b; b="$(mkbox "les$1")" || return 1; run "$b" lessons-bullets.md; MSG=""
  count 0; req 'unclassifiable-items: 1'; req 'retro-level=1'; verdict
}
c_evidence_stays_unc() {
  local b; b="$(mkbox "evi$1")" || return 1; run "$b" evidence-only.md; MSG=""
  count 0; req 'unclassifiable-items: 1'; req 'retro-level=1'; verdict
}
# A prose kit-delta heading with no items AND an unrelated ### Proposals list: the list is staged, the prose heading
# is still reported (the suppression is per heading, not per file).
c_mixed() {
  local b; b="$(mkbox "mix$1")" || return 1; run "$b" mixed-prose-and-list.md; MSG=""
  count 2; req 'Counter in the loop state'; req 'Debt sink file'; req 'unclassifiable-items: 1'; req 'retro-level=1'; req '## B. Campaign-8 kit-delta backlog'; verdict
}
# Same for a canonical heading that holds only prose while a list elsewhere classifies.
c_canon_empty() {
  local b; b="$(mkbox "cem$1")" || return 1; run "$b" canon-empty-plus-list.md; MSG=""
  count 2; req 'Unrelated list item one'; req 'unclassifiable-items: 1'; req 'retro-level=1'; req '## Proposed kit deltas'; verdict
}
# A numbered list under `### Considered and rejected` / `### Evidence` inside the delta section is not a delta list.
c_rejected_h3() {
  local b; b="$(mkbox "rej$1")" || return 1; run "$b" rejected-h3.md; MSG=""
  count 2; req 'Adopt the real proposal one'; req 'Adopt the real proposal two'; forbid 'Rejected idea'; forbid 'evidence line that must not'; req 'unclassifiable-items: 0'; verdict
}
# Two numbered lists share ids 1,2: refused (typed), never silently merged by the signature dedup.
c_dup_ids() {
  local b; b="$(mkbox "dup$1")" || return 1; run "$b" dup-ids.md; MSG=""
  count 0; req 'unclassifiable-items: 1'; req 'share ids (1 2)'; verdict
}
# An upper-case hyphenated header cell (ITEM-ID) is a header, never a delta row.
c_header_hyphen() {
  local b; b="$(mkbox "hdr$1")" || return 1; run "$b" header-hyphen.md; MSG=""
  count 1; req 'header-hyphen.md · D1'; forbid 'ITEM-ID'; req 'unclassifiable-items: 0'; verdict
}
c_titles() {
  local b; b="$(mkbox "ttl$1")" || return 1; run "$b" title-edges.md; MSG=""
  count 7; req 'planned-issue: e.g. foo bar baz is the working title'; req 'planned-issue: See e.g. The Rules document'; req 'planned-issue: Bold title with colon'; utf8; verdict
}

CHECKS="c_numbered c_numbered_single c_lettered c_h2_delta c_h3_proposals c_lessons_stays_unc c_evidence_stays_unc c_mixed c_canon_empty c_rejected_h3 c_dup_ids c_header_hyphen c_titles"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED with the expected failure text --"
  # tooth <check> <label> <expected-failure-text> <sut|lib> <sed-stage>...
  tooth() {
    local chk="$1" label="$2" want="$3" where="$4" why
    shift 4
    MUT=(); MUTLIB=()
    if [ "$where" = lib ]; then MUTLIB=("$@"); else MUT=("$@"); fi
    rm -f "$ROOT/unbuildable"
    if why="$($chk "mut-$label" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif [ -e "$ROOT/unbuildable" ]; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"
    elif ! grep -qF -- "$want" <<<"$why"; then no "teeth $label: $chk failed for the WRONG reason" "wanted [$want] got [${why:0:200}]"
    else ok "teeth $label: mutant breaks $chk with [$want]" "()"; fi
    MUT=(); MUTLIB=()
  }
  tooth c_numbered      numbered-off      'PLANNED: 0 != 3'  lib '/ALT_NUMBERED_ITEM/s/if (match(/if (0 \&\& match(/'
  tooth c_h2_delta      h2-off            'PLANNED: 0 != 3'  lib '/ALT_H2_DELTA/s/.*/        if (0) {/'
  tooth c_h3_proposals  h3-off            'PLANNED: 0 != 3'  lib '/ALT_H3_PROPOSALS/s/.*/        if (0) mode="h3"/'
  tooth c_h2_delta      med-not-medium    'MISSING: priority:medium' lib '/ALT_PRIORITY_MED/s/.*/                  if (0) pr = "MEDIUM"/'
  tooth c_lettered      lettered-id       'PLANNED: 0 != 3'  lib 's/if (tok !~ \/\[0-9-\]\/ \&\& length(tok) > 1) return 0/if (length(tok) > 1) return 0/'
  tooth c_numbered      no-alt-fallback   'PLANNED: 0 != 3'  sut '/STAGE_RETRO_ISSUES_ALT_FALLBACK/s/.*/  _rows=""/'
  tooth c_h2_delta      no-alt-early      'PLANNED: 0 != 3'  sut '/STAGE_RETRO_ISSUES_ALT_EARLY/s/.*/  _alt_early=""/'
  tooth c_evidence_stays_unc evidence-matched 'PLANNED: 2 != 0' lib '/ALT_NUMBERED_GATE/s/.*/      1 {/'
  tooth c_mixed         heading-match-off 'MISSING: unclassifiable-items: 1' sut '/STAGE_RETRO_ISSUES_ALT_HEADING_MATCH/s/grep -qxF -- "\$_unrec_heading" <<<"\$_alt_heads"/true/'
  tooth c_canon_empty   canon-heading-off 'MISSING: unclassifiable-items: 1' sut 's/if \[ "\$_found_field" = "1" \] \&\& \[ -n "\$_h" \] \&\& ! grep -qxF -- "\$_h" <<<"\$_alt_heads"; then/if false; then/'
  tooth c_rejected_h3   h3-reset-off      'PLANNED: 0 != 2'  lib '/ALT_H3_RESET/s/.*/        flush()/'
  tooth c_dup_ids       dup-check-off     'PLANNED: 4 != 0'  sut 's/^    if \[ -n "\$_dups" \]; then$/    if false; then/'
  tooth c_header_hyphen header-drop-off   'PLANNED: 2 != 1'  sut '/STAGE_RETRO_ISSUES_HEADER_DROP/s/pend = ""/pend = pend/'
  tooth c_titles        cut-splits-utf8   'INVALID UTF-8'    lib '/ALT_CUT_BACKOFF/s/.*/        k = k/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
