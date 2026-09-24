#!/usr/bin/env bash
# hotcore-budget.test.sh — HOT-CORE/SITUATIONAL tier-list parity, membership audit,
# and a HOT-CORE size-budget guard for METHODOLOGY.md (kit issue #962).
#
# Background: METHODOLOGY.md's ~23 top-level sections are loaded in two tiers —
# HOT-CORE (read every context) and SITUATIONAL (read only when its phase fires).
# The tier lists are duplicated by hand in two places: SKILL.md's "HOT-CORE —"
# bullet and PROMPT-LOOP.md's "Always read first" block. #962 found that §3b, §8b
# and §20b had fallen out of BOTH lists entirely — an orphan section is read by
# neither tier, so its rules silently stop applying. No instrument caught it
# because nothing measured tier-list membership or HOT-CORE's growing size.
#
# Guards:
#   T1  SKILL.md HOT-CORE §-token set == PROMPT-LOOP.md HOT-CORE §-token set
#   T2  SKILL.md SITUATIONAL §-token set == PROMPT-LOOP.md SITUATIONAL §-token set
#   T3  §8b is in HOT-CORE in both files (backlog rows are written every
#       iteration — issue #962 prefers HOT-CORE over a situational trigger)
#   T3b §8b is NOT also left behind in SITUATIONAL in either file (moved, not duplicated)
#   T4  §3b is in SITUATIONAL in both files, with a named trigger
#   T5  §20b is in SITUATIONAL in both files, with a named trigger
#   T6  Every numbered `## N.` / `### N.` top-level section of METHODOLOGY.md is in
#       exactly one of {HOT-CORE, SITUATIONAL, EXEMPT} — catches the orphan-section
#       class directly, independent of which specific sections #962 named
#   T7  HOT-CORE's total size (section list derived from SKILL.md's own HOT-CORE
#       bullet — never a hardcoded copy) stays within a budget constant
#
# Anti-silent-zero: the §-token parser, the METHODOLOGY.md heading parser, and the
# per-section byte-count lookup all FAIL LOUDLY (FATAL, exit 2) on zero matches or
# a listed-but-absent heading — never a silent 0 that a caller could read as "tier
# is empty" or "section is free".
#
# Usage: hotcore-budget.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../../skills/research-sdd/SKILL.md"
[ -f "$SKILL" ] || { printf 'FATAL: SKILL.md not found at expected path: %s\n' "$SKILL" >&2; exit 2; }
PROMPTLOOP="$HERE/../../PROMPT-LOOP.md"
[ -f "$PROMPTLOOP" ] || { printf 'FATAL: PROMPT-LOOP.md not found at expected path: %s\n' "$PROMPTLOOP" >&2; exit 2; }
METHODOLOGY="$HERE/../../METHODOLOGY.md"
[ -f "$METHODOLOGY" ] || { printf 'FATAL: METHODOLOGY.md not found at expected path: %s\n' "$METHODOLOGY" >&2; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== hotcore-budget.test.sh =="

# ---------------------------------------------------------------------------
# Marker pairs bounding each tier's prose in each file. Fixed substrings, not
# regexes — the surrounding prose uses parentheses/periods that would otherwise
# need escaping for no benefit.
# ---------------------------------------------------------------------------
SKILL_HC_START="HOT-CORE — read once per context"
SKILL_HC_END="Each iteration re-reads only RESEARCH-STATE"
SKILL_SIT_START="SITUATIONAL — read the named section"
SKILL_SIT_END="Read a situational section when its trigger is your next action."
# PROMPT-LOOP's HOT-CORE list lives entirely on one line.
LOOP_HC_START="HOT-CORE (read once per context):"
LOOP_HC_END="per-block contract."
# The §11b-is-situational clarifier sits between the HOT-CORE line and the
# "SITUATIONAL (read..." marker; start there so §11b is not dropped from the
# SITUATIONAL token set (it is documented as situational, just not inside the
# enumerated §-list on the next line).
LOOP_SIT_START="(§11b"
LOOP_SIT_END="Unsure a phase is active -> read it."

# extract_block_inclusive FILE START END
# Prints every line from the first line containing START through the first
# subsequent line containing END (both inclusive). Fixed-substring match
# (index()), not a regex, so callers never need to escape prose punctuation.
extract_block_inclusive() {
  local file="$1" start="$2" endin="$3"
  awk -v start="$start" -v endin="$endin" '
    index($0, start) > 0 { capture=1 }
    capture { print }
    capture && index($0, endin) > 0 { exit }
  ' "$file"
}

# tokens_of FILE START END
# Sorted, deduplicated §N / §Na tokens found in the bounded block. FATAL
# (exit 2 — this is a subshell-local exit via command substitution, see
# callers) if the marker pair is not found, or if it is found but contains
# zero §-tokens: both are "the instrument could not have looked", never a
# legitimate empty tier — SITUATIONAL and HOT-CORE both always list sections.
tokens_of() {
  local file="$1" start="$2" endin="$3"
  local block
  block="$(extract_block_inclusive "$file" "$start" "$endin")"
  if [ -z "$block" ]; then
    printf 'FATAL: tokens_of — marker pair not found in %s (start=%q)\n' "$file" "$start" >&2
    exit 2
  fi
  local toks
  toks="$(printf '%s\n' "$block" | grep -oE '§[0-9]+[a-z]?' | sort -u)"
  if [ -z "$toks" ]; then
    printf 'FATAL: tokens_of — zero section tokens in matched block of %s (start=%q) — broken parser, not an empty tier\n' "$file" "$start" >&2
    exit 2
  fi
  printf '%s\n' "$toks"
}

# Each call below runs in a command-substitution subshell, so a tokens_of
# FATAL exits only that subshell; $? is checked immediately after.
skill_hotcore="$(tokens_of "$SKILL" "$SKILL_HC_START" "$SKILL_HC_END")" \
  || { echo "FATAL: could not derive SKILL.md HOT-CORE token set" >&2; exit 2; }
skill_situational="$(tokens_of "$SKILL" "$SKILL_SIT_START" "$SKILL_SIT_END")" \
  || { echo "FATAL: could not derive SKILL.md SITUATIONAL token set" >&2; exit 2; }
loop_hotcore="$(tokens_of "$PROMPTLOOP" "$LOOP_HC_START" "$LOOP_HC_END")" \
  || { echo "FATAL: could not derive PROMPT-LOOP.md HOT-CORE token set" >&2; exit 2; }
loop_situational="$(tokens_of "$PROMPTLOOP" "$LOOP_SIT_START" "$LOOP_SIT_END")" \
  || { echo "FATAL: could not derive PROMPT-LOOP.md SITUATIONAL token set" >&2; exit 2; }

# ---------------------------------------------------------------------------
# T1 / T2: the two files must name the SAME sections per tier.
# ---------------------------------------------------------------------------
d="$(diff <(printf '%s\n' "$skill_hotcore") <(printf '%s\n' "$loop_hotcore") 2>&1)"
if [ -z "$d" ]; then
  ok "T1: HOT-CORE token set agrees between SKILL.md and PROMPT-LOOP.md"
else
  no "T1: HOT-CORE token sets differ between SKILL.md and PROMPT-LOOP.md — $d"
fi

d="$(diff <(printf '%s\n' "$skill_situational") <(printf '%s\n' "$loop_situational") 2>&1)"
if [ -z "$d" ]; then
  ok "T2: SITUATIONAL token set agrees between SKILL.md and PROMPT-LOOP.md"
else
  no "T2: SITUATIONAL token sets differ between SKILL.md and PROMPT-LOOP.md — $d"
fi

# ---------------------------------------------------------------------------
# T3 / T3b: §8b lives in HOT-CORE (backlog rows are written every iteration —
# issue #962 prefers HOT-CORE over a situational trigger), in both files, and
# only there (moved, not duplicated into SITUATIONAL as well).
# ---------------------------------------------------------------------------
if grep -qxF '§8b' <<<"$skill_hotcore" && grep -qxF '§8b' <<<"$loop_hotcore"; then
  ok "T3: §8b is in HOT-CORE in both SKILL.md and PROMPT-LOOP.md"
else
  no "T3: §8b missing from HOT-CORE in SKILL.md and/or PROMPT-LOOP.md (#962)"
fi

if grep -qxF '§8b' <<<"$skill_situational" || grep -qxF '§8b' <<<"$loop_situational"; then
  no "T3b: §8b still left in SITUATIONAL somewhere (should be moved, not duplicated)"
else
  ok "T3b: §8b is not duplicated into SITUATIONAL in either file"
fi

# ---------------------------------------------------------------------------
# T4 / T5: §3b and §20b live in SITUATIONAL, with a named trigger, in both files.
# ---------------------------------------------------------------------------
if grep -qxF '§3b' <<<"$skill_situational" && grep -qxF '§3b' <<<"$loop_situational"; then
  ok "T4: §3b is in SITUATIONAL in both SKILL.md and PROMPT-LOOP.md"
else
  no "T4: §3b missing from SITUATIONAL in SKILL.md and/or PROMPT-LOOP.md (#962)"
fi
if grep -qF '§3b corpus layout' "$SKILL" && grep -qF '§3b corpus layout' "$PROMPTLOOP"; then
  ok "T4b: §3b carries a named trigger ('corpus layout') in both files"
else
  no "T4b: §3b is missing its named trigger text in SKILL.md and/or PROMPT-LOOP.md"
fi

if grep -qxF '§20b' <<<"$skill_situational" && grep -qxF '§20b' <<<"$loop_situational"; then
  ok "T5: §20b is in SITUATIONAL in both SKILL.md and PROMPT-LOOP.md"
else
  no "T5: §20b missing from SITUATIONAL in SKILL.md and/or PROMPT-LOOP.md (#962)"
fi
if grep -qF '§20b' "$SKILL" && grep -qF 'journal mode' "$SKILL" \
   && grep -qF '§20b' "$PROMPTLOOP" && grep -qF 'diario' "$PROMPTLOOP"; then
  ok "T5b: §20b carries a named trigger (block-vs-journal mode) in both files"
else
  no "T5b: §20b is missing its named trigger text in SKILL.md and/or PROMPT-LOOP.md"
fi

# ---------------------------------------------------------------------------
# methodology_sections FILE
# Sorted, deduplicated bare section ids ("8b", "12b", ...) for every top-level
# `## N.` / `### N.` heading in METHODOLOGY.md. FATAL on zero matches: the
# regex or the file itself is broken, this is never a legitimately section-less
# doctrine file.
# ---------------------------------------------------------------------------
methodology_sections() {
  local file="$1"
  local ids
  ids="$(grep -oE '^##[#]? [0-9]+[a-z]?\.' "$file" | grep -oE '[0-9]+[a-z]?' | sort -u)"
  if [ -z "$ids" ]; then
    printf 'FATAL: methodology_sections — zero numbered section headings found in %s\n' "$file" >&2
    exit 2
  fi
  printf '%s\n' "$ids"
}

# ---------------------------------------------------------------------------
# T6: every numbered METHODOLOGY.md section is in exactly one of
# {HOT-CORE, SITUATIONAL, EXEMPT}. This is the general orphan-section guard:
# it would have caught #962 (§3b/§8b/§20b) without naming them, and it keeps
# catching the same class for any future section.
#
# EXEMPT — sections deliberately NOT named in either tier list because they are
# `###` subsections physically nested inside a section that IS tiered, and are
# therefore read whenever their parent is read "in full":
#   12b, 12c — nested inside "## 12. Dynamic phase" (SITUATIONAL); neither is
#              ever listed on its own in SKILL.md or PROMPT-LOOP.md.
# ---------------------------------------------------------------------------
EXEMPT_IDS="12b
12c"

all_sections="$(methodology_sections "$METHODOLOGY")" \
  || { echo "FATAL: could not derive METHODOLOGY.md section list" >&2; exit 2; }

hc_ids="$(sed 's/§//' <<<"$skill_hotcore" | sort -u)"
sit_ids="$(sed 's/§//' <<<"$skill_situational" | sort -u)"

t6_orphans=""
t6_multi=""
t6_checked=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  t6_checked=$((t6_checked+1))
  in_hc=0; in_sit=0; in_ex=0
  grep -qxF "$id" <<<"$hc_ids" && in_hc=1
  grep -qxF "$id" <<<"$sit_ids" && in_sit=1
  grep -qxF "$id" <<<"$EXEMPT_IDS" && in_ex=1
  count=$((in_hc + in_sit + in_ex))
  if [ "$count" -eq 0 ]; then
    t6_orphans="$t6_orphans §$id"
  elif [ "$count" -gt 1 ]; then
    t6_multi="$t6_multi §$id(hc=$in_hc,sit=$in_sit,exempt=$in_ex)"
  fi
done <<<"$all_sections"

if [ -z "$t6_orphans" ] && [ -z "$t6_multi" ]; then
  ok "T6: every numbered METHODOLOGY.md section ($t6_checked checked) is in exactly one tier or EXEMPT"
else
  no "T6: orphan sections:[$t6_orphans ] multi-tier sections:[$t6_multi ]"
fi

# ---------------------------------------------------------------------------
# measure_hotcore METHODOLOGY_FILE HC_IDS_STR
# Sums lines and bytes for every section id in HC_IDS_STR (bare ids, one per
# line) by locating its "## N. " heading and the next "## " heading (or EOF)
# in METHODOLOGY_FILE. Prints "<lines> <bytes>". FATAL if a listed id has no
# matching heading (a HOT-CORE bullet naming a section that does not exist is
# a broken doctrine file, not zero-size section) or if HC_IDS_STR is empty.
# ---------------------------------------------------------------------------
measure_hotcore() {
  local file="$1" ids="$2"
  if [ -z "$ids" ]; then
    printf 'FATAL: measure_hotcore — empty HOT-CORE id list (derive from SKILL.md, never hardcode)\n' >&2
    exit 2
  fi
  local total_lines=0 total_bytes=0 n s e b l
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    s="$(grep -n "^## ${n}\. " "$file" | head -1 | cut -d: -f1)"
    if [ -z "$s" ]; then
      printf 'FATAL: measure_hotcore — HOT-CORE section §%s has no "## %s. " heading in %s\n' "$n" "$n" "$file" >&2
      exit 2
    fi
    e="$(awk -v s="$s" 'NR>s && /^## / { print NR-1; f=1; exit } END { if (!f) print NR }' "$file")"
    b="$(sed -n "${s},${e}p" "$file" | wc -c)"
    l=$(( e - s + 1 ))
    total_lines=$(( total_lines + l ))
    total_bytes=$(( total_bytes + b ))
  done <<<"$ids"
  printf '%s %s\n' "$total_lines" "$total_bytes"
}

# ---------------------------------------------------------------------------
# T7: HOT-CORE size budget. The section list is `hc_ids`, derived above from
# SKILL.md's own HOT-CORE bullet — never a hardcoded copy — so a future tier
# edit only needs to update SKILL.md (and, per T1, PROMPT-LOOP.md to match)
# for this budget to track the real HOT-CORE.
#
# Budget constants: measured $hc_lines lines / $hc_bytes bytes for HOT-CORE
# (§1 §2 §3 §4 §7 §8 §8b §9 §11 §17) on 2026-09-24 at sha 356fa15a1087238c
# (research-sdd repo, origin/main). Set with headroom, but deliberately BELOW
# the ~934-line / ~101 KB regrowth the 2026-09-23 audit measured for the
# pre-#992-wave-B HOT-CORE (kit issue #962) — the intent is that renewed
# unchecked growth toward that historical bad state fails this guard before
# reaching it again, not that the budget tracks whatever HOT-CORE happens to
# measure today.
# ---------------------------------------------------------------------------
HOTCORE_BUDGET_LINES=1000
HOTCORE_BUDGET_BYTES=100000

read -r hc_lines hc_bytes < <(measure_hotcore "$METHODOLOGY" "$hc_ids") \
  || { echo "FATAL: could not measure HOT-CORE size" >&2; exit 2; }

if [ "$hc_lines" -le "$HOTCORE_BUDGET_LINES" ] && [ "$hc_bytes" -le "$HOTCORE_BUDGET_BYTES" ]; then
  ok "T7: HOT-CORE size within budget ($hc_lines lines / $hc_bytes bytes <= $HOTCORE_BUDGET_LINES / $HOTCORE_BUDGET_BYTES)"
else
  no "T7: HOT-CORE size EXCEEDS budget ($hc_lines lines / $hc_bytes bytes > $HOTCORE_BUDGET_LINES / $HOTCORE_BUDGET_BYTES)"
fi

# ===========================================================================
# --prove-teeth: mutation controls. Each mutant is a modified COPY in $TMP;
# the live tree is never touched.
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then
  echo "-- teeth: T1 mutant (drop a HOT-CORE token from PROMPT-LOOP.md) --"
  mutantLoop1="$TMP/PROMPTLOOP.mutantT1.md"
  sed 's/§8 §8b backlog-cell-grammar (written every iteration) §9/§8 §9/' "$PROMPTLOOP" > "$mutantLoop1"
  mut_hc="$(tokens_of "$mutantLoop1" "$LOOP_HC_START" "$LOOP_HC_END" 2>/dev/null)"
  if [ -z "$(diff <(printf '%s\n' "$skill_hotcore") <(printf '%s\n' "$mut_hc") 2>&1)" ]; then
    no "teeth-T1: mutant HOT-CORE token set still matches SKILL.md — no teeth"
  else
    ok "teeth-T1: mutant HOT-CORE token set diverges from SKILL.md (T1 would go RED)"
  fi

  echo "-- teeth: T3 mutant (remove §8b from SKILL.md HOT-CORE) --"
  mutantSkillT3="$TMP/SKILL.mutantT3.md"
  sed 's/§8 stopping + terminal trigger, §8b backlog cell grammar (written every iteration),/§8 stopping + terminal trigger,/' "$SKILL" > "$mutantSkillT3"
  mut_hc="$(tokens_of "$mutantSkillT3" "$SKILL_HC_START" "$SKILL_HC_END" 2>/dev/null)"
  if grep -qxF '§8b' <<<"$mut_hc"; then
    no "teeth-T3: mutant SKILL.md still has §8b in HOT-CORE — no teeth"
  else
    ok "teeth-T3: mutant SKILL.md loses §8b from HOT-CORE (T3 would go RED)"
  fi

  echo "-- teeth: T6 mutant (orphan a section by deleting its situational mention) --"
  mutantSkillT6="$TMP/SKILL.mutantT6.md"
  # The §3b trigger phrase wraps across two lines in SKILL.md prose; RS="\x01"
  # makes awk read the whole file as one record so gsub can match across the
  # line wrap without needing a sentinel-byte round trip through sed.
  t6_old=$'coordinating a kit change across separate coordinator / researcher / QA sessions; §3b corpus layout →\n       creating or moving corpus files; '
  t6_new='coordinating a kit change across separate coordinator / researcher / QA sessions; '
  awk -v old="$t6_old" -v new="$t6_new" 'BEGIN{RS="\x01"} { gsub(old, new); printf "%s", $0 }' "$SKILL" > "$mutantSkillT6"
  mut_sit="$(tokens_of "$mutantSkillT6" "$SKILL_SIT_START" "$SKILL_SIT_END" 2>/dev/null)"
  mut_hc_ids="$(sed 's/§//' <<<"$hc_ids" | sort -u)"
  mut_sit_ids="$(sed 's/§//' <<<"$mut_sit" | sort -u)"
  if grep -qxF '3b' <<<"$mut_sit_ids"; then
    no "teeth-T6: mutant still has §3b in SITUATIONAL — mutation did not take, no teeth"
  else
    orphaned=0
    grep -qxF '3b' <<<"$mut_hc_ids" || orphaned=1
    if [ "$orphaned" -eq 1 ]; then
      ok "teeth-T6: §3b becomes an orphan on the mutant (in neither tier) — T6 would go RED"
    else
      no "teeth-T6: §3b unexpectedly still covered on the mutant — no teeth"
    fi
  fi

  echo "-- teeth: T7 mutant (inflate a HOT-CORE section past budget) --"
  mutantMethT7="$TMP/METHODOLOGY.mutantT7.md"
  cp "$METHODOLOGY" "$mutantMethT7"
  # Inflate section §1 with 2500 padding lines, well past the byte/line budget.
  s1="$(grep -n '^## 1\. ' "$mutantMethT7" | head -1 | cut -d: -f1)"
  {
    sed -n "1,${s1}p" "$mutantMethT7"
    for _ in $(seq 1 2500); do echo "padding line to blow the HOT-CORE budget"; done
    sed -n "$((s1+1)),\$p" "$mutantMethT7"
  } > "$TMP/METHODOLOGY.mutantT7.inflated.md"
  read -r mut_lines mut_bytes < <(measure_hotcore "$TMP/METHODOLOGY.mutantT7.inflated.md" "$hc_ids" 2>/dev/null)
  if [ -n "${mut_lines:-}" ] && { [ "$mut_lines" -gt "$HOTCORE_BUDGET_LINES" ] || [ "$mut_bytes" -gt "$HOTCORE_BUDGET_BYTES" ]; }; then
    ok "teeth-T7: inflated mutant ($mut_lines lines / $mut_bytes bytes) exceeds budget (T7 would go RED)"
  else
    no "teeth-T7: inflated mutant did NOT exceed budget ($mut_lines lines / $mut_bytes bytes) — no teeth"
  fi

  echo "-- teeth: anti-silent-zero mutant (blank out HOT-CORE token list) --"
  mutantSkillZero="$TMP/SKILL.mutantZero.md"
  sed 's/§1 guiding principle, §2 phases, §3 the 7 markers, §4 block anatomy, §7 state\/memory,/no tokens here at all,/' "$SKILL" \
    | sed 's/§8 stopping + terminal trigger, §8b backlog cell grammar (written every iteration), §9 golden rules,/still no tokens,/' \
    | sed 's/§11 self-verify, §17 resume\./no tokens at all./' \
    > "$mutantSkillZero"
  ( tokens_of "$mutantSkillZero" "$SKILL_HC_START" "$SKILL_HC_END" >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-anti-silent-zero: zero-token mutant makes tokens_of FATAL (exit 2), not a silent empty pass"
  else
    no "teeth-anti-silent-zero: zero-token mutant did NOT trigger FATAL (rc=$rc) — silent zero would slip through"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
