#!/usr/bin/env bash
# template-heading-literal.test.sh — no script-matched `## <heading>` literal inside a template
# comment (kit issue #1173, folding #1189 "scripted state-editor rules").
#
# Root class: the state scripts (research-sdd-status.sh, verify-state.sh, ...) locate sections with
# line-oriented greps/awk over '## <heading>'. They are NOT comment-aware, so a template comment that
# spells a real heading (e.g. "blocked_open (## Blocked gaps entries)") is read as that heading by a
# scripted state editor and the section boundary / row rewrite lands in the comment. The cure is
# wording: generated comments must never carry the literal text of a real heading.
#
# Enumerator (declared, §7 — the instrument must prove its own coverage):
#   phenomenon : a level-2/3 heading literal ('## X' / '### X') inside an HTML comment (single- or
#                multi-line, several per line) of any file under research-sdd/templates/
#   recognised : every heading X in the union of (a) a STATIC list of headings the toolbelt matches,
#                (b) every `section '## X'` / `_section ... '## X'` argument found by grepping the
#                toolbelt scripts, (c) every real '## X' heading line of the templates themselves
#                (parenthetical descriptor stripped)
#   excluded   : headings outside comments (they are the real structure); non-HTML comment syntaxes
#                (the .yml / .conf / .sh / .py templates are scanned too but only <!-- --> comments
#                are parsed; their own comment syntaxes are NOT covered)
#   coverage   : the run prints files scanned, comment segments seen and heading names enumerated;
#                zero of any of them is exit 2 (could-not-run), never a pass.
#
# --prove-teeth: mutants (lib/mutant.sh) re-insert the historical offending text and add new cases
# (multi-line comment, second-on-a-line, ### form); each must turn the REAL scan red.
#
# Usage: template-heading-literal.test.sh [--prove-teeth]   Exit: 0 held · 1 violation · 2 could not run.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
KIT="$(cd "$TOOLBELT/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
TPL="${TEMPLATE_DIR_OVERRIDE:-$KIT/templates}"
PROVE=0; [ "${1:-}" = "--prove-teeth" ] && PROVE=1

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

[ -d "$TPL" ] || { echo "could not run: templates dir absent: $TPL"; exit 2; }

# --- heading-name enumeration ---------------------------------------------------------------
NAMES="$(mktemp)"; trap 'rm -f "$NAMES"' EXIT
{
  # (a) static: headings the toolbelt matches that no template necessarily carries as a real heading.
  #     Gap-backlog..Campaign queue/Dismissed file types/History: matched by verify-state.sh,
  #     research-sdd-status.sh, migrate-backlogs.sh, census-target.sh, research-sdd-archive.sh
  #     (some via patterns the section-arg grep in (b) cannot see, e.g. awk /^## .../ regexes).
  #     Proposed kit deltas / Tools built... / Proposed delta / Summary of proposed delta: retro
  #     headings matched by stage-retro.sh, verify-retro.sh and lib/retro-grammar.sh.
  #     Stop control / Stretch goal: real state-template headings read by status/verify scripts.
  printf '%s\n' 'Gap-backlog' 'Iteration history' 'Blocked gaps' 'Non-investigable gaps' 'Blocked /' \
    'Child gaps surfaced at close' 'Covered blocks' 'Coverage' 'Outline' 'Campaign queue' \
    'Dismissed file types' 'History' 'Stop control' 'Stretch goal' \
    'Proposed kit deltas' 'Tools built, adapted, or outgrown' 'Proposed delta' 'Summary of proposed delta'
  # (b) derived from the scripts' own section lookups
  grep -hoE "section[^']*'## [^']+'" "$TOOLBELT"/*.sh 2>/dev/null | sed -E "s/^[^']*'## //; s/'\$//"
  # (c) real headings of the two state templates (other templates' headings are placeholders)
  grep -hE '^## ' "$TPL"/RESEARCH-STATE*.md 2>/dev/null | sed -E 's/^## //; s/ \(.*$//'
} | sed -E 's/[[:space:]]+$//' | awk 'NF' | sort -u >"$NAMES"
n_names="$(wc -l <"$NAMES" | tr -d ' ')"

# scan_file FILE — prints "FILE:LINE: ## name" per violation; echoes "SEGS n" on the last line.
scan_file() {
  awk -v NAMES="$NAMES" -v F="$(basename "$1")" '
    BEGIN { while ((getline l < NAMES) > 0) nm[++n] = l; close(NAMES) }
    { line = $0
      while (1) {
        if (inc) { p = index(line, "-->"); if (p) { seg = substr(line, 1, p-1); line = substr(line, p+3); inc = 0 } else { seg = line; line = "" } }
        else { p = index(line, "<!--"); if (p) { line = substr(line, p+4); inc = 1; continue } else break }
        segs++
        rest = seg
        while (match(rest, /###?[ \t]+[^ \t]/)) {  # interval-free: mawk treats {n,m} literally
          tail = substr(rest, RSTART + RLENGTH - 1)
          for (i = 1; i <= n; i++) if (index(tail, nm[i]) == 1) { printf "%s:%d: heading literal \"## %s\" inside a comment\n", F, NR, nm[i]; break }
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (line == "") break
      }
    }
    END { printf "SEGS %d\n", segs + 0 }' "$1"
}

# Positive control: the scanner must flag a known violation on THIS awk, else the regex is dead
# (e.g. mawk ignoring intervals) and every later pass would be vacuous.
PC="$(mktemp)"; printf '<!-- see ## Gap-backlog here -->\n' >"$PC"
pc_out="$(scan_file "$PC")"; rm -f "$PC"
if ! grep -q 'heading literal' <<<"$pc_out"; then
  echo "could not run: scanner positive control found no violation on this awk (silent zero refused)"; exit 2
fi

total_segs=0; nfiles=0; viol=""
for f in "$TPL"/*; do
  [ -f "$f" ] || continue
  nfiles=$((nfiles+1))
  out="$(scan_file "$f")"
  s="$(printf '%s\n' "$out" | sed -n 's/^SEGS //p')"; total_segs=$((total_segs + ${s:-0}))
  viol="$viol$(printf '%s\n' "$out" | grep -v '^SEGS ')"$'\n'
done
printf 'coverage: files scanned=%s · comment segments seen=%s · heading names enumerated=%s\n' "$nfiles" "$total_segs" "$n_names"
if [ "$nfiles" -eq 0 ] || [ "$total_segs" -eq 0 ] || [ "$n_names" -eq 0 ]; then
  echo "could not run: an enumerator saw nothing (silent zero refused)"; exit 2
fi
viol="$(printf '%s' "$viol" | awk 'NF')"
if [ -z "$viol" ]; then ok "H1: no script-matched heading literal inside any template comment"
else no "H1: script-matched heading literal(s) inside template comments:"; printf '%s\n' "$viol" | sed 's/^/        /'; fi

# H2: a commented-out scaffold section must name the exact heading text to create (in words, since the
# literal is banned inside comments), so a copy of it cannot silently lose the heading.
# Entries: "<file>|<heading text>" for every scaffold section reworded under #1173.
SCAFFOLDS=("RESEARCH-STATE.template.md|Campaign queue")
scaffold_documented() {  # FILE TEXT — rc 0 when FILE says: level-2 heading ... whose text is exactly "TEXT"
  local flat
  flat="$(tr '\n' ' ' <"$1")"
  grep -qF "level-2 heading" <<<"$flat" && grep -qF "whose text is exactly \"$2\"" <<<"$flat"
}
for e in "${SCAFFOLDS[@]}"; do
  sf="${e%%|*}"; st="${e#*|}"
  if [ ! -f "$TPL/$sf" ]; then no "H2: scaffold template absent: $sf"
  elif scaffold_documented "$TPL/$sf" "$st"; then ok "H2: $sf documents the exact heading text \"$st\" for its commented scaffold"
  else no "H2: $sf does not state the exact level-2 heading text \"$st\" for its commented scaffold"; fi
done

# --- teeth -----------------------------------------------------------------------------------
if [ "$PROVE" -eq 1 ]; then
  # shellcheck source=lib/mutant.sh
  MUTANT_SYNTAX=none; export MUTANT_SYNTAX  # mutants are markdown, not bash
  . "$HERE/lib/mutant.sh"
  MUT="$(mktemp -d)"; mutant_cleanup_register "$MUT"
  S="$TPL/RESEARCH-STATE.template.md"; D="$TPL/RESEARCH-STATE-document.template.md"
  tooth_scan() {  # LABEL SUT-FILE WANT-SUBSTR EXPR... — mutant must make scan_file report WANT; the original must not.
    local label="$1" sut="$2" want="$3"; shift 3
    mutant_chain "$label" "$sut" "$MUT/$label.md" "$@" || { fail=$((fail+1)); return 1; }
    local o m
    o="$(scan_file "$sut")"; m="$(scan_file "$MUT/$label.md")"
    if grep -q 'heading literal' <<<"$o"; then no "teeth-$label: the ORIGINAL already violates"; return 1; fi
    if grep -qF "$want" <<<"$m"; then ok "teeth-$label: mutant is red"
    else no "teeth-$label: mutant stayed green (theater)"; fi
  }
  # historical offender #1 (RESEARCH-STATE.template.md:12) re-inserted
  tooth_scan old-blocked-open "$S" '"## Blocked gaps"' 's/(Blocked-gaps section entries)/(## Blocked gaps entries)/'
  # historical offender #2 (document template header) re-inserted
  tooth_scan old-doc-outline "$D" '"## Outline"' 's/the "Outline" section below/the "## Outline" section below/'
  # a heading literal at column 0 inside a multi-line comment (the Campaign-queue shape)
  tooth_scan multiline-col0 "$S" '"## Campaign queue"' 's/^Campaign queue (scaffold only; do NOT uncomment or copy this block)\./## Campaign queue./'
  # three-hash form, second comment on the same line as a first
  tooth_scan h3-second-on-line "$S" '"## Stop control"' 's/^## Coverage$/<!-- a --> <!-- see ### Stop control -->\n&/'
  # H2 tooth: dropping the exact-heading sentence from the scaffold must turn H2 red
  mutant_chain "h2-drop" "$S" "$MUT/h2-drop.md" 's/^"Campaign queue" — the section greps.*$/(heading text omitted)/' || fail=$((fail+1))
  if [ -f "$MUT/h2-drop.md" ]; then
    if scaffold_documented "$S" "Campaign queue" && ! scaffold_documented "$MUT/h2-drop.md" "Campaign queue"; then ok "teeth-h2-drop: scaffold without the exact heading text is red"
    else no "teeth-h2-drop: H2 did not distinguish the mutant"; fi
  fi
  # a real, non-fenced heading OUTSIDE a comment must stay green (the comment rule has a tooth that does not over-fire)
  mutant_chain "outside-green" "$S" "$MUT/outside-green.md" 's/^## Coverage$/&\n\n## Gap-backlog extra/' || fail=$((fail+1))
  if [ -f "$MUT/outside-green.md" ]; then
    og="$(scan_file "$MUT/outside-green.md")"
    if grep -q 'heading literal' <<<"$og"; then no "teeth-outside-green: a heading outside a comment was flagged"
    else ok "teeth-outside-green: a heading outside a comment stays green"; fi
  fi
  # anti-silent-zero: a template dir with no comments is rc 2
  mkdir -p "$MUT/empty"; printf '# nothing\n' >"$MUT/empty/x.md"
  TEMPLATE_DIR_OVERRIDE="$MUT/empty" bash "$0" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then ok "teeth-zero-segments: a comment-free corpus is rc 2, not a pass"
  else no "teeth-zero-segments: rc=$rc (want 2)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
