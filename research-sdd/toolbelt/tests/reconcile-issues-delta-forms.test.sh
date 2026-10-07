#!/usr/bin/env bash
# reconcile-issues-delta-forms.test.sh — reconcile-issues.sh must name the SAME delta ids as the seeder for the
# forms real retros use (kit issues #1895 #1932 #1933 #1934 #1938 #1939): lettered table ids (SPKI-A), numbered
# prose items, `## Delta <ID> —` entries; and refuse (typed) what the seeder refuses (two lists sharing ids).
# The fixtures are the stage-retro-issues ones: one definition of "what the forms look like" for both tools.
# Every tooth asserts the failure TEXT it must produce.
#
# Usage: reconcile-issues-delta-forms.test.sh                (run the suite)
#        reconcile-issues-delta-forms.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../reconcile-issues.sh"
FIX="$HERE/fixtures/stage-retro-issues"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixtures not found: $FIX" >&2; exit 2; }
for _l in retro-status retro-grammar target-paths; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper lib/$_l.sh not found" >&2; exit 2; }
done
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
MUT=(); MUTLIB=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

# mkbox <name>: hermetic sandbox (TARGETS.md with target-foo, SUT + libs copy, a gh stub that answers nothing).
mkbox() {
  local box="$ROOT/$1" l
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/reconcile-issues.sh"
  for l in retro-status retro-grammar target-paths; do cp "$HERE/../lib/$l.sh" "$box/research-sdd/toolbelt/lib/$l.sh"; done
  printf '#!%s\nprintf "%%s\\n" "$1" >> "%s/bin/sleep.log"\n' "$BASH_BIN" "$box" > "$box/bin/sleep"; chmod +x "$box/bin/sleep"
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "gh $*" >> "$0.log"\ncase " $* " in *" auth status "*) exit 0 ;; *" issue list "*) echo "[]"; exit 0 ;; esac\nexit 0\n' > "$box/bin/gh"; chmod +x "$box/bin/gh"
  if [ "${#MUT[@]}" -gt 0 ]; then
    mutant_chain "mut-$1" "$SUT" "$box/research-sdd/toolbelt/reconcile-issues.sh" "${MUT[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  if [ "${#MUTLIB[@]}" -gt 0 ]; then
    mutant_chain "mutlib-$1" "$HERE/../lib/retro-grammar.sh" "$box/research-sdd/toolbelt/lib/retro-grammar.sh" "${MUTLIB[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  printf '%s' "$box"
}

# run <box> <fixture> [tracked-id...]: copies the fixture in and reconciles it against a cache that lists the given
# ids as already tracked. Sets OUT and RC.
run() {
  local box="$1" f="$2" id; shift 2
  cp "$FIX/$f" "$box/rh/target-foo/retros/$f"
  : > "$box/cache.txt"
  for id in "$@"; do printf 'Source retro: target-foo/retros/%s · %s\n' "$f" "$id" >> "$box/cache.txt"; done
  OUT="$(PATH="$box/bin:$PATH" "$BASH_BIN" "$box/research-sdd/toolbelt/reconcile-issues.sh" \
    --issues-cache "$box/cache.txt" "$box/rh/target-foo/retros/$f" 2>&1)"; RC=$?
}
MSG=""
req()    { [ -z "$MSG" ] || return 0; grep -qE -- "$1" <<<"$OUT" || MSG="MISSING: $1"; }
forbid() { [ -z "$MSG" ] || return 0; ! grep -qE -- "$1" <<<"$OUT" || MSG="UNEXPECTED: $1"; }
verdict() { [ "$RC" = 0 ] || MSG="${MSG:-RC $RC}"; if [ -z "$MSG" ]; then return 0; fi; echo "$MSG | out=[${OUT:0:400}]"; return 1; }

c_lettered() {   # first / middle / last of a lettered-id table: A untracked, B tracked, C untracked
  local b; b="$(mkbox "let$1")" || return 1; run "$b" lettered-table.md SPKI-B; MSG=""
  req '^untracked: row SPKI-A '; req '^tracked: row SPKI-B '; req '^untracked: row SPKI-C '; forbid 'unclassifiable'; verdict
}
c_numbered() {
  local b; b="$(mkbox "num$1")" || return 1; run "$b" numbered-prose.md 2; MSG=""
  req '^untracked: row 1 '; req '^tracked: row 2 '; req '^untracked: row 3 '; forbid 'unclassifiable'; verdict
}
c_numbered_single() {
  local b; b="$(mkbox "one$1")" || return 1; run "$b" numbered-single.md; MSG=""
  req '^untracked: row 1 '; forbid 'unclassifiable'; verdict
}
c_h2_delta() {
  local b; b="$(mkbox "h2$1")" || return 1; run "$b" h2-delta.md B; MSG=""
  req '^untracked: row A '; req '^tracked: row B '; req '^untracked: row C '; forbid 'unclassifiable'; forbid 'row Deduplication'; verdict
}
c_h3_proposals() {
  local b; b="$(mkbox "h3$1")" || return 1; run "$b" h3-proposals.md 1 3; MSG=""
  req '^tracked: row 1 '; req '^untracked: row 2 '; req '^tracked: row 3 '; forbid 'unclassifiable'; verdict
}
c_header_hyphen() {   # an upper-case hyphenated header cell is not a row id
  local b; b="$(mkbox "hdr$1")" || return 1; run "$b" header-hyphen.md; MSG=""
  req '^untracked: row D1 '; forbid 'row ITEM-ID'; verdict
}
c_rejected_h3() {
  local b; b="$(mkbox "rej$1")" || return 1; run "$b" rejected-h3.md 1; MSG=""
  req '^tracked: row 1 '; req '^untracked: row 2 '; forbid 'unclassifiable'; verdict
}
c_dup_ids() {   # two lists share ids 1,2: refused, never silently merged
  local b; b="$(mkbox "dup$1")" || return 1; run "$b" dup-ids.md; MSG=""
  req '^unclassifiable: delta items in .* share ids \(1 2\)'; forbid '^untracked: row'; verdict
}
c_lessons_unc() {   # not a delta form: no row ids invented
  local b; b="$(mkbox "les$1")" || return 1; run "$b" lessons-bullets.md; MSG=""
  forbid '^(un)?tracked: row'; verdict
}
c_evidence_unc() {
  local b; b="$(mkbox "evi$1")" || return 1; run "$b" evidence-only.md; MSG=""
  forbid '^(un)?tracked: row'; verdict
}

c_mixed() {   # prose kit-delta heading + an unrelated Proposals list: the prose heading is reported, the list is reconciled
  local b; b="$(mkbox "mix$1")" || return 1; run "$b" mixed-prose-and-list.md 1; MSG=""
  req '^unclassifiable: proposal-like heading found'; req '^tracked: row 1 '; req '^untracked: row 2 '; verdict
}
c_canon_empty() {   # canonical heading holding prose while a list elsewhere classifies
  local b; b="$(mkbox "cem$1")" || return 1; run "$b" canon-empty-plus-list.md 1; MSG=""
  req '^unclassifiable: delta section found but it produced no items'; req '^tracked: row 1 '; req '^untracked: row 2 '; verdict
}

c_list_first() {   # a Proposals list first and a prose kit-delta heading second: the second is still reported
  local b; b="$(mkbox "lf$1")" || return 1; run "$b" list-first-prose-second.md 1; MSG=""
  req '^unclassifiable: proposal-like heading found'; req '^tracked: row 1 '; req '^untracked: row 2 '; verdict
}
c_two_tables() {
  local b; b="$(mkbox "tt$1")" || return 1; run "$b" two-tables.md 2; MSG=""
  req '^untracked: row 1 '; req '^tracked: row 2 '; req '^untracked: row 3 '; req '^untracked: row 4 '; forbid 'row (Proposed|#)'; verdict
}

CHECKS="c_list_first c_two_tables c_lettered c_numbered c_numbered_single c_h2_delta c_h3_proposals c_header_hyphen c_rejected_h3 c_dup_ids c_lessons_unc c_evidence_unc c_mixed c_canon_empty"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED with the expected failure text --"
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
  tooth c_numbered   alt-fallback-off 'MISSING: ^untracked: row 1 ' sut '/RECONCILE_ISSUES_ALT_FORMS/,/^  fi$/s/_all_row_ids="\$(retro_grammar_alt_entry_rows "\$retro_path" | cut -d \$.\\037. -f1)"/_all_row_ids=""/'
  tooth c_lettered   id-rule-old2     'MISSING: ^untracked: row SPKI-A ' sut '/RECONCILE_ISSUES_ID_RULE/s/.*/        if (rid ~ \/^[[:alpha:]#][^0-9]*$\/ \&\& rid !~ \/^[A-Z][0-9]\/) next/'
  tooth c_header_hyphen header-drop-off 'UNEXPECTED: row ITEM-ID' sut '/RECONCILE_ISSUES_HEADER_DROP/s/pend = ""; next/next/'
  tooth c_dup_ids    dup-check-off    'MISSING: ^unclassifiable: delta items in' sut 's/^    if \[ -n "\$_alt_dups" \]; then$/    if false; then/'
  tooth c_mixed      heading-match-off 'MISSING: ^unclassifiable: proposal-like heading found' sut '/RECONCILE_ISSUES_ALT_HEADING_MATCH/s/\[ -z "\$_unrec_missing" \]/true/'
  tooth c_canon_empty canon-heading-off 'MISSING: ^unclassifiable: delta section found but it produced no items' sut '/RECONCILE_ISSUES_ALT_CANON_HEADING/s/if \[ -n "\$_canon_h" \] \&\& ! grep -qxF -- "\$_canon_h" <<<"\$_canon_heads"; then/if false; then/'
  tooth c_list_first unrec-all-off 'MISSING: ^unclassifiable: proposal-like heading found' sut '/RECONCILE_ISSUES_UNREC_ALL/s/.*/    _unrec_missing=""/'
  tooth c_rejected_h3 h3-reset-off    'MISSING: ^tracked: row 1 ' lib '/ALT_H3_RESET/s/.*/        flush()/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
