#!/usr/bin/env bash
# stage-retro-issues-unclassifiable.test.sh — kit issue #1259: unclassifiable retro items must surface as a
# stdout table with a typed count and as ONE tracking-issue proposal per run (dry-run by default; --apply
# creates / occurrence-comments through the existing guarded machinery; never in the dry-run).
#
# Usage: stage-retro-issues-unclassifiable.test.sh                (run the suite)
#        stage-retro-issues-unclassifiable.test.sh --prove-teeth  (run suite + mutation teeth)
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

# Teeth plumbing: when MUT is non-empty, mkbox turns the box's SUT copy into a mutant (sed stages), so the SAME
# check function runs against the original (must pass) and against each mutant (must fail).
MUT=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

# mkbox <name>: hermetic sandbox (TARGETS.md with target-foo, SUT + libs copy, gh stub). Prints the box path.
mkbox() {
  local box="$ROOT/$1" l
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh"
  for l in retro-status retro-grammar target-paths scrub-issue-text; do cp "$HERE/../lib/$l.sh" "$box/research-sdd/toolbelt/lib/$l.sh"; done
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  mkstub "$box"
  if [ "${#MUT[@]}" -gt 0 ]; then
    mutant_chain "mut-$1" "$SUT" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "${MUT[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  printf '%s' "$box"
}

# mkstub <box>: a compact gh stub. State files live next to it ($0.*): .occ (occurrence list reply), .dedup (signature
# search reply), .fphit (the item-set search finds a CLOSED issue), .createfail, .nosigview (read-back body lacks the signature), .body (last created body),
# .comments.N (comments of issue N), .log (every call).
mkstub() {
  cat > "$1/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$0.log"
case " $* " in
  *" auth status "*) exit 0 ;;
  *" label list "*) s=""; p=""; for a in "$@"; do [ "$p" = "--search" ] && s="$a"; p="$a"; done; printf '[{"name":"%s"}]\n' "$s"; exit 0 ;;
  *" issue list "*" number,state,title "*) if [ -f "$0.occ" ]; then cat "$0.occ"; else echo '[]'; fi; exit 0 ;;
  *" issue list "*"item set"*)   # the item-set lookup: $0.fphit = a CLOSED issue carrying the searched set line
    s=""; p=""; for a in "$@"; do [ "$p" = "--search" ] && s="$a"; p="$a"; done; s="${s#\"}"; s="${s%\"}"
    if [ -f "$0.fphit" ]; then printf '[{"state":"CLOSED","body":"x\\n%s"}]\n' "$s"; else echo '[]'; fi; exit 0 ;;
  *" issue list "*) if [ -f "$0.dedup" ]; then cat "$0.dedup"; else echo '[]'; fi; exit 0 ;;
  *" issue create "*)
    [ -f "$0.createfail" ] && { echo "gh: create failed" >&2; exit 1; }
    p=""; for a in "$@"; do [ "$p" = "--body" ] && printf '%s' "$a" > "$0.body"; p="$a"; done
    echo "https://github.com/o/r/issues/77"; exit 0 ;;
  *" issue view "*" --json body "*)
    if [ -f "$0.nosigview" ]; then echo "body without the line"; else cat "$0.body"; echo; fi; exit 0 ;;
  *" issue view "*" --json comments "*)
    for a in "$@"; do case "$a" in [0-9]*) n="$a" ;; esac; done
    [ -f "$0.comments.$n" ] && cat "$0.comments.$n"; exit 0 ;;
  *" issue comment "*)
    p=""; for a in "$@"; do [ "$p" = "--body" ] && b="$a"; case "$a" in [0-9]*) n="$a" ;; esac; p="$a"; done
    printf '%s\n' "$b" >> "$0.comments.$n"; echo "https://github.com/o/r/issues/$n#issuecomment-1"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$1/bin/gh"
}

# run <box> <retro> [args]: sets OUT (stdout+stderr) and RC.
run() {
  local box="$1" retro="$2"; shift 2
  OUT="$(PATH="$box/bin:$PATH" RESEARCH_SDD_ISSUE_REPO=test-owner/test-kit \
    "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" "$@" 2>&1)"; RC=$?
}

PEND='<!-- review-status: pending -->'
HDR='| # | Proposed change | Target (file) | Evidence | Type | Priority |'
# sec_retro <box> <fname> [heading-suffix]: a retro whose only proposal-like heading is a hyphenated "kit-delta"
# mid-heading — the parser cannot classify it (retro-level unclassifiable).
sec_retro() {
  local f="$1/rh/target-foo/retros/$2"
  { printf '%s\n# retro\n\n## B. Campaign-8 kit-delta backlog%s\n\nsome prose, no table rows here\n' "$PEND" "${3:-}"; } > "$f"
  printf '%s' "$f"
}
# row_retro <box> <fname> <row>...: a canonical table whose rows are the args.
row_retro() {
  local box="$1" fn="$2" f; shift 2
  f="$box/rh/target-foo/retros/$fn"
  { printf '%s\n# retro\n\n## Proposed kit deltas\n\n%s\n|---|---|---|---|---|---|\n' "$PEND" "$HDR"; printf '%s\n' "$@"; } > "$f"
  printf '%s' "$f"
}
GOOD='| 2 | a perfectly usable delta row | CLAUDE.md | B1 | fix | HIGH |'
BAD1='| 1 | LOW | CLAUDE.md | B1 | fix | HIGH |'
BAD3='| 3 | MEDIUM | CLAUDE.md | B1 | fix | HIGH |'

# --- checks: each returns 0 when the behaviour holds (prints the reason on failure) ----------------------------
c_dry_section() {
  local b r ln; b="$(mkbox "dry-sec$1")" || return 1; r="$(sec_retro "$b" r.md)"
  ln="$(grep -n 'kit-delta backlog' "$r" | head -1 | cut -d: -f1)"
  run "$b" "$r"
  [ "$RC" = 0 ] && grep -qF 'unclassifiable-items: 1 (retro-level=1 row-level=0)' <<<"$OUT" \
    && grep -qE "^\| 1 \| r\.md:$ln \| ## B\. Campaign-8 kit-delta backlog \| proposal-like heading not in a countable delta form \|\$" <<<"$OUT" \
    && grep -qF 'planned-tracking-issue: Unclassifiable retro deltas in target-foo/retros/r.md' <<<"$OUT" \
    && grep -qxF '    Unclassifiable tracker: target-foo/retros/r.md' <<<"$OUT" \
    && [ ! -e "$b/bin/gh.log" ] && return 0
  echo "rc=$RC out=[${OUT:0:700}]"; return 1
}
c_dry_row() {
  local b r ln; b="$(mkbox "dry-row$1")" || return 1; r="$(row_retro "$b" r.md "$BAD1" "$GOOD")"
  ln="$(grep -n '^| 1 | LOW' "$r" | cut -d: -f1)"
  run "$b" "$r"
  [ "$RC" = 0 ] && grep -qF 'unclassifiable-items: 1 (retro-level=0 row-level=1)' <<<"$OUT" \
    && grep -qE "^\| 1 \| r\.md:$ln \| 1: LOW \| no usable title \(a bare priority/type token\) \|\$" <<<"$OUT" \
    && grep -q '^planned-issue: a perfectly usable delta row$' <<<"$OUT" \
    && grep -q '^planned-tracking-issue: ' <<<"$OUT" && return 0
  echo "rc=$RC out=[${OUT:0:700}]"; return 1
}
c_zero_states() {
  local b r; b="$(mkbox "zero$1")" || return 1
  r="$(row_retro "$b" ok.md "$GOOD")"; run "$b" "$r"
  [ "$RC" = 0 ] && grep -qxF 'unclassifiable-items: 0 (no-match: 1 row(s) examined, none unclassifiable)' <<<"$OUT" \
    && ! grep -q '^planned-tracking-issue:' <<<"$OUT" || { echo "no-match: rc=$RC out=[${OUT:0:500}]"; return 1; }
  printf '%s\n# retro\n\nNo proposed deltas here.\n' "$PEND" > "$b/rh/target-foo/retros/empty.md"
  run "$b" "$b/rh/target-foo/retros/empty.md"
  [ "$RC" = 0 ] && grep -qE '^unclassifiable-items: 0 \(empty-input' <<<"$OUT" && return 0
  echo "empty-input: rc=$RC out=[${OUT:0:500}]"; return 1
}
c_apply_create() {
  local b r; b="$(mkbox "apply$1")" || return 1; r="$(sec_retro "$b" r.md)"
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'created: https://github.com/o/r/issues/77 (row tracker)' <<<"$OUT" \
    && grep -qF 'summary: created=1 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0 unclassifiable=1 unknown-outcome=0 failed=0' <<<"$OUT" \
    && grep -qF 'mutation-summary: confirmed=1 no_write=0 unknown=0' <<<"$OUT" \
    && grep -q -- '--label target:target-foo' "$b/bin/gh.log" \
    && grep -qxF 'Unclassifiable tracker: target-foo/retros/r.md' "$b/bin/gh.body" && return 0
  echo "rc=$RC out=[${OUT:0:700}]"; return 1
}
c_apply_occurrence() {
  local b r; b="$(mkbox "occ$1")" || return 1; r="$(row_retro "$b" r.md "$BAD1")"
  printf '[{"number":55,"state":"OPEN","title":"Unclassifiable retro deltas in target-foo/retros/r.md"}]\n' > "$b/bin/gh.occ"
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'occurrence-commented: #55 (row tracker)' <<<"$OUT" \
    && ! grep -q 'gh issue create' "$b/bin/gh.log" || { echo "first: rc=$RC out=[${OUT:0:600}]"; return 1; }
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'occurrence-exists: #55' <<<"$OUT" && [ "$(grep -c 'stage-retro-issues:occurrence' "$b/bin/gh.comments.55")" = 1 ] \
    || { echo "idempotent re-run: rc=$RC out=[${OUT:0:600}]"; return 1; }
  r="$(row_retro "$b" r.md "$BAD1" "$BAD3")"    # a CHANGED item set must add a new occurrence comment
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'occurrence-commented: #55 (row tracker)' <<<"$OUT" \
    && [ "$(grep -c 'stage-retro-issues:occurrence' "$b/bin/gh.comments.55")" = 2 ] && return 0
  echo "changed set: rc=$RC out=[${OUT:0:600}]"; return 1
}
c_apply_closed() {
  local b r; b="$(mkbox "closed$1")" || return 1; r="$(sec_retro "$b" r.md)"
  printf '[{"state":"CLOSED","body":"x\\n\\n---\\nUnclassifiable tracker: target-foo/retros/r.md\\nPart of backlog-first rollout #557"}]\n' > "$b/bin/gh.dedup"
  : > "$b/bin/gh.fphit"    # the closed tracker lists exactly this item set
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'skipped-duplicate: tracking issue for Unclassifiable tracker: target-foo/retros/r.md already exists for this item set' <<<"$OUT" \
    && ! grep -q 'gh issue create' "$b/bin/gh.log" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}
# A CLOSED tracker that lists a DIFFERENT item set must not suppress new lost items: a new tracker is created.
c_apply_closed_changed() {
  local b r; b="$(mkbox "closedchg$1")" || return 1; r="$(sec_retro "$b" r.md)"
  printf '[{"state":"CLOSED","body":"x\\n\\n---\\nUnclassifiable tracker: target-foo/retros/r.md\\nPart of backlog-first rollout #557"}]\n' > "$b/bin/gh.dedup"
  run "$b" "$r" --apply
  [ "$RC" = 0 ] && grep -qF 'tracker-set-changed:' <<<"$OUT" && grep -qF 'created: https://github.com/o/r/issues/77 (row tracker)' <<<"$OUT" \
    && grep -qE -- '--title Unclassifiable retro deltas in target-foo/retros/r\.md \(item set [0-9]+\)' "$b/bin/gh.log" \
    && grep -qE '^Unclassifiable item set: [0-9]+$' "$b/bin/gh.body" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}
# The privacy scrub failing on the tracker is a refusal that FAILS the run: exit 2, failed=1, nothing written.
c_scrub_fail() {
  local b r; b="$(mkbox "scrubfail$1")" || return 1; r="$(sec_retro "$b" r.md)"
  printf '%s\n' 'scrub_issue_text() { cat >/dev/null; return 1; }' 'scrub_issue_text_count() { cat >/dev/null; echo "redactions: 0"; }' > "$b/research-sdd/toolbelt/lib/scrub-issue-text.sh"
  run "$b" "$r" --apply
  [ "$RC" = 2 ] && grep -qF 'privacy scrub failed for the unclassifiable tracker' <<<"$OUT" && grep -qF 'failed=1' <<<"$OUT" \
    && ! grep -q 'gh issue create' "$b/bin/gh.log" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}
# Row-level line lookup is confined to the table rows: a bare token like LOW in prose above the table is not the
# row, and an ambiguous (repeated) row prints `?` instead of a wrong line.
c_row_line() {
  local b r ln f; b="$(mkbox "rowline$1")" || return 1
  f="$b/rh/target-foo/retros/r.md"
  { printf '%s\n# retro\n\nPriority LOW items are tracked elsewhere; 1 | LOW mention in prose.\n\n## Proposed kit deltas\n\n%s\n|---|---|---|---|---|---|\n' "$PEND" "$HDR"
    printf '%s\n' "$BAD1"; } > "$f"
  ln="$(grep -n '^| 1 | LOW' "$f" | cut -d: -f1)"
  run "$b" "$f"
  grep -qE "^\| 1 \| r\.md:$ln \|" <<<"$OUT" || { echo "unique: ln=$ln out=[${OUT:0:500}]"; return 1; }
  printf '%s\n' "$BAD1" >> "$f"      # the same row twice: ambiguous
  run "$b" "$f"
  grep -qE '^\| 1 \| r\.md:\? \|' <<<"$OUT" && return 0
  echo "ambiguous: out=[${OUT:0:500}]"; return 1
}
c_apply_createfail() {
  local b r; b="$(mkbox "cfail$1")" || return 1; r="$(sec_retro "$b" r.md)"; : > "$b/bin/gh.createfail"
  run "$b" "$r" --apply
  [ "$RC" = 2 ] && grep -qF 'ERROR: gh issue create failed for row tracker' <<<"$OUT" && grep -qF 'failed=1' <<<"$OUT" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}
c_apply_readback() {
  local b r; b="$(mkbox "rb$1")" || return 1; r="$(sec_retro "$b" r.md)"; : > "$b/bin/gh.nosigview"
  run "$b" "$r" --apply
  [ "$RC" = 3 ] && grep -qF 'unknown-outcome: gh issue create returned' <<<"$OUT" && grep -qF 'mutation-summary: confirmed=0 no_write=0 unknown=1' <<<"$OUT" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}
c_scrub() {
  local b r; b="$(mkbox "scrub$1")" || return 1; r="$(sec_retro "$b" r.md ' /home/alice/notes.txt')"
  run "$b" "$r"
  [ "$RC" = 0 ] && ! grep -qF '/home/alice' <<<"$OUT" && grep -qE '^  redactions: [1-9]' <<<"$OUT" && return 0
  echo "rc=$RC out=[${OUT:0:600}]"; return 1
}

CHECKS="c_dry_section c_dry_row c_zero_states c_apply_create c_apply_occurrence c_apply_closed c_apply_closed_changed c_scrub_fail c_row_line c_apply_createfail c_apply_readback c_scrub"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth (kit issue #1259): each mutant must turn its check RED --"
  # tooth <check> <label> <sed-stage>...: the mutant is built by mutant_chain (empty/identical/unbuildable = FAIL).
  tooth() {
    local chk="$1" label="$2" why
    shift 2
    MUT=("$@"); rm -f "$ROOT/unbuildable"
    if why="$($chk "mut-$label" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif [ -e "$ROOT/unbuildable" ]; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"
    else ok "teeth $label: mutant breaks $chk" "()"; fi
    MUT=()
  }
  tooth c_dry_section    sec-record   '/"proposal-like heading not in a countable delta form"$/s/.*/    :/'
  tooth c_dry_row        row-record   '/"no usable title (\$_title_reason)"$/s/.*/    :/'
  tooth c_zero_states    zero-line    '/^    echo "unclassifiable-items: 0 (\$1)"; return 0$/s/.*/    return 0/'
  tooth c_dry_section    dry-banner   "s/planned-tracking-issue: /planned-tracker: /"
  tooth c_apply_closed   closed-dedup '/^  if grep -q .*OPEN.*CLOSED.*<<<"\$_lk"; then$/s/.*/  if false; then/'
  tooth c_apply_occurrence occ-find   '/^  if \[ -n "\$_occ_nums" \]; then$/s/.*/  if false; then/'
  tooth c_apply_occurrence fingerprint 's/ #\${_fp} -->/ -->/'
  tooth c_apply_readback readback     's/ || ! grep -qxF -- "\$_sig" <<<"\$_rb"; then/; then/'
  tooth c_apply_closed_changed closed-set-ignored '/^  _unc_lookup "\$_sigfp" || return 0$/s/.*/  _lk="[{\\"state\\":\\"CLOSED\\"}]"/'
  tooth c_scrub_fail     failed-uncounted '/^  echo "ERROR: \$2" >&2; failed=\$((failed+1))$/s/; failed=.*//'
  tooth c_row_line       row-line-anywhere 's/_unc_add row "\$(_unc_row_line "\$_rid" "\$_delta")"/_unc_add row "$(_unc_line_of "$_delta")"/'
  tooth c_scrub          scrub-body   's/"\$_tmp" | scrub_issue_text)" && _tn=/"$_tmp" | cat)" \&\& _tn=/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
