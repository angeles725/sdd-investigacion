#!/usr/bin/env bash
# hotcore-budget.test.sh — HOT-CORE/SITUATIONAL tier-list parity, membership audit,
# and a HOT-CORE size-budget guard for METHODOLOGY.md (kit issue #962, round 2).
#
# Background: METHODOLOGY.md's numbered sections are loaded in two tiers — HOT-CORE
# (read every context) and SITUATIONAL (read only when its phase fires). The tier
# lists are duplicated by hand in SKILL.md's "HOT-CORE —" bullet and PROMPT-LOOP.md's
# "Always read first" block. #962 found that §3b, §8b and §20b had fallen out of BOTH
# lists entirely — an orphan section is read by neither tier, so its rules silently
# stop applying. No instrument caught it because nothing measured tier-list membership
# or HOT-CORE's growing size.
#
# Round-2 review (Opus adversarial, blocked) found the round-1 suite's mutation
# controls recomputed their own pass/fail condition instead of running the real
# check, so a broken check could still show 15/15 teeth. Every check below is now a
# standalone `check_T*` function; both the real assertion AND its tooth call the
# SAME function (the tooth only overrides which files it reads, via RSDD_SKILL /
# RSDD_LOOP / RSDD_METH env vars) — they cannot drift apart.
#
# Checks:
#   T1  SKILL.md HOT-CORE §-token set == PROMPT-LOOP.md HOT-CORE §-token set
#   T2  SKILL.md SITUATIONAL §-token set == PROMPT-LOOP.md SITUATIONAL §-token set
#   T3  §8b is in HOT-CORE in both files
#   T3b §8b is NOT also left in SITUATIONAL in either file (moved, not duplicated)
#   T4  §3b token is in SITUATIONAL in both files
#   T4b §3b's named trigger text is inside the SITUATIONAL block specifically (bounded)
#   T5  §20b token is in SITUATIONAL in both files
#   T5b §20b's named trigger text is inside the SITUATIONAL block specifically (bounded)
#   T6  Every numbered METHODOLOGY.md section is in exactly one of {HOT-CORE,
#       SITUATIONAL, EXEMPT}. EXEMPT is computed dynamically: a `###` subsection is
#       exempt only while it is actually nested under a `##` parent that IS tiered —
#       never a hardcoded id list (round-2 m3).
#   T7  HOT-CORE's total size (id list read live from SKILL.md's own HOT-CORE bullet)
#       stays within a budget constant
#   T8  (round-2 m1) Reverse check: every §-token named by either tier, in either
#       file, names a REAL METHODOLOGY.md section — catches a phantom/typo token.
#   T9  (round-2 m2) No numbered-looking METHODOLOGY.md heading uses a form the
#       strict parser rejects (`## 24 — X`, `## §24. X`, `## 24) X`, ...) — the
#       false-negative direction of anti-silent-zero (kit CLAUDE.md §7): a heading
#       that LOOKS numbered but is silently invisible to every other check here.
#
# Code fences (round-2 m4): every heading-detecting function below reads through
# mask_code_fences first, so a `## 8b. ...`-shaped line used as prose inside a
# ```-fenced example (METHODOLOGY.md §6 has one — the RESEARCH-STATE.md template
# snippet, "## Dismissed file types") is never mistaken for a real section boundary
# or a real numbered section.
#
# Anti-silent-zero: tokens_of and methodology_sections FAIL LOUDLY (return 2) on
# zero matches — never a silent 0 read as "tier is empty" or "file has no sections".
# Every check_T* function returns 0 (holds) / 1 (violated, with a non-empty stdout
# diagnostic) / 2 (a parser call inside it could not look at all — never treated as
# a tooth bite; see bite_tooth's R3-teeth-vacuous-on-parser-failure guard below).
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
# --prove-teeth's multi-line mutant construction (replace_literal_multiline)
# needs python3; probe at startup rather than failing deep inside a mutant
# build with a bare "command not found" (kit CLAUDE.md §7: probe a runtime
# dependency, never allow/pass silently on its absence).
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== hotcore-budget.test.sh =="

# ---------------------------------------------------------------------------
# Marker pairs bounding each tier's prose in SKILL.md / PROMPT-LOOP.md. Fixed
# substrings, not regexes — the surrounding prose uses parentheses/periods that
# would otherwise need escaping for no benefit. These two files' tier-list prose
# is never inside a code fence, so no fence-masking is needed for them.
# ---------------------------------------------------------------------------
# SKILL_HC_START anchors on "HOT-CORE — <!-- slot:hotcore-cadence -->" rather
# than the old "HOT-CORE — read once per context", because kit issue #993
# (WU1: render-profile.sh) wraps that cadence wording in an install-time slot
# marker (an HTML comment, invisible to a reader, stripped only for a
# non-"claude" profile render — the checked-in source stays byte-identical
# for the "claude" profile). The marker text is a stable, unique anchor.
SKILL_HC_START="HOT-CORE — <!-- slot:hotcore-cadence -->"
SKILL_HC_END="Each iteration re-reads only RESEARCH-STATE"
SKILL_SIT_START="SITUATIONAL — read the named section"
SKILL_SIT_END="Read a situational section when its trigger is your next action."
# LOOP_HC_START anchors on "HOT-CORE <!-- slot:hotcore-loop-cadence -->" for the
# same #993-WU1-round-2 reason as SKILL_HC_START above: the cadence
# parenthetical is now a slot marker, so the old literal
# "HOT-CORE (read once per context):" is no longer contiguous.
LOOP_HC_START="HOT-CORE <!-- slot:hotcore-loop-cadence -->"
LOOP_HC_END="per-block contract."
# The §11b-is-situational clarifier sits between the HOT-CORE line and the
# "SITUATIONAL (read..." marker; start there so §11b is not dropped from the
# SITUATIONAL token set (it is documented as situational, just not inside the
# enumerated §-list on the next line).
LOOP_SIT_START="(§11b"
LOOP_SIT_END="Unsure a phase is active -> read it."

# HOT-CORE size budget (T7). Measured 862 lines / 85929 bytes on 2026-09-24 at
# 356fa15 (research-sdd repo, origin/main) for HOT-CORE (§1 §2 §3 §4 §7 §8 §8b
# §9 §11 §17); re-measured unchanged after round 3's boundary-semantics fix
# (measure_hotcore now stops at the next `##` heading of ANY kind, not just a
# numbered one — see measure_hotcore's own comment — but the real file has no
# non-numbered `##` between any two HOT-CORE-adjacent numbered sections, so
# the total does not move).
#
# HOTCORE_BUDGET_LINES is 920 — headroom over the 862-line measurement, but
# still below the ~934 lines the 2026-09-23 audit measured for HOT-CORE
# before wave B of #992 trimmed it (kit issue #962). The intent is that
# renewed, unchecked HOT-CORE growth fails this guard before it reaches that
# historical size again, not that the budget merely tracks whatever HOT-CORE
# happens to measure on the day this comment was written.
#
# HOTCORE_BUDGET_BYTES is 100000 — chosen independently of the line budget,
# not derived from it, because a HOT-CORE edit can move bytes without moving
# lines much (e.g. a dense inline table or a long unwrapped URL): about 16%
# headroom over the 85929-byte measurement, and — mirroring the line budget's
# reasoning — below the ~101 KB (~103400 bytes) the same 2026-09-23 audit
# measured for the same historical HOT-CORE.
HOTCORE_BUDGET_LINES=920
HOTCORE_BUDGET_BYTES=100000

# =============================================================================
# Parsers (shared by both the real checks and their teeth)
# =============================================================================

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
# Sorted, deduplicated §N / §Na tokens found in the bounded block. Returns 2
# (never a silent empty result) if the marker pair is not found, or if it is
# found but contains zero §-tokens: both are "the instrument could not have
# looked", never a legitimate empty tier.
tokens_of() {
  local file="$1" start="$2" endin="$3"
  local block
  block="$(extract_block_inclusive "$file" "$start" "$endin")"
  if [ -z "$block" ]; then
    printf 'FATAL: tokens_of — marker pair not found in %s (start=%q)\n' "$file" "$start" >&2
    return 2
  fi
  local toks
  toks="$(printf '%s\n' "$block" | grep -oE '§[0-9]+[a-z]?' | sort -u)"
  if [ -z "$toks" ]; then
    printf 'FATAL: tokens_of — zero section tokens in matched block of %s (start=%q)\n' "$file" "$start" >&2
    return 2
  fi
  printf '%s\n' "$toks"
}

# mask_code_fences FILE
# Same line count/order as FILE; every line strictly between a pair of fence
# markers is replaced with a sentinel that can never match a heading regex.
# The fence-marker lines themselves pass through unchanged (they never match
# a heading regex either). Downstream line-number-based lookups stay valid
# because the line count never changes.
#
# CommonMark-ish fence matching, not a bare "toggle on any ``` line" (round-3
# review, MAJOR): a fence opens on a run of 3+ backticks OR 3+ tildes, and
# closes ONLY on a run of the SAME character that is AT LEAST as long as the
# opener. A shorter or differently-charactered run while already inside a
# fence is fence CONTENT, not a closer — e.g. a fenced ````md block that
# itself contains an example ``` line does not close early on that inner
# line; it closes only on a later run of 4+ backticks. Prints the caller's
# fence-tracking failure to stderr and exits 3 if EOF is reached still
# inside a fence (unclosed/mismatched fence) — never silently treats an
# unclosed fence as "everything after this point is masked" or, worse, as
# "unmasked" (that silent-invert was the exact round-3 defect: an unclosed
# fence used to make every line after it toggle-invert one at a time).
mask_code_fences() {
  awk '
    {
      is_fence = 0
      if (match($0, /^`+/) && RLENGTH >= 3) { ch = "`"; len = RLENGTH; is_fence = 1 }
      else if (match($0, /^~+/) && RLENGTH >= 3) { ch = "~"; len = RLENGTH; is_fence = 1 }

      if (is_fence) {
        if (!infence) { infence = 1; fch = ch; flen = len; print; next }
        else if (ch == fch && len >= flen) { infence = 0; print; next }
        # else: fence-looking line of the wrong char or too short while
        # already inside a fence — falls through, treated as content below.
      }

      if (infence) { print "\x02FENCED-LINE\x02"; next }
      print
    }
    END {
      if (infence) {
        print "mask_code_fences: unclosed or mismatched code fence (opened with " flen " x " fch ", never closed)" > "/dev/stderr"
        exit 3
      }
    }
  ' "$1"
}

# heading_index FILE
# One line per `## ` / `### ` heading, in file order, outside code fences:
# "<line-number> <level> <bare-id-or-dash>". A NUMBERED heading ("## 8b. ...")
# gets its bare id ("8b"); a non-numbered heading at the same level
# ("## Appendix", "## Purpose") gets the sentinel id "-". Both kinds are
# emitted, not just numbered ones: compute_exempt_ids needs every level-2
# heading — numbered or not — to correctly RESET its "current tiered parent"
# tracking (round-3 review, minor #3: without a reset row for "## Appendix",
# a `### 30.` heading appearing after it would wrongly inherit exemption from
# whichever NUMBERED `##` last appeared, possibly several sections earlier).
# Returns 2 (never a silent empty result) if mask_code_fences itself failed
# (an unclosed/mismatched fence — round-3 review, MAJOR).
#
# The single enumerator behind methodology_sections, measure_hotcore's
# boundary lookup, and compute_exempt_ids's nesting walk — one heading
# regex, reused everywhere a heading needs detecting, so the three can never
# disagree about what counts as a heading (kit CLAUDE.md §7: "an audit
# instrument must prove the coverage of its own enumerator").
heading_index() {
  local file="$1"
  local out rc
  out="$(mask_code_fences "$file" | awk '
    /^## [0-9]+[a-z]?\. / {
      rest = $0; sub(/^## /, "", rest); sub(/\..*/, "", rest); print NR, 2, rest; next
    }
    /^### [0-9]+[a-z]?\. / {
      rest = $0; sub(/^### /, "", rest); sub(/\..*/, "", rest); print NR, 3, rest; next
    }
    /^## / { print NR, 2, "-"; next }
    /^### / { print NR, 3, "-"; next }
  ')"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FATAL: heading_index — mask_code_fences failed on %s (rc=%d; likely an unclosed/mismatched code fence)\n' "$file" "$rc" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

# methodology_sections FILE
# Sorted, deduplicated bare section ids ("8b", "12b", ...) for every numbered
# heading (any level) in FILE — non-numbered headings (heading_index's "-"
# rows) are filtered out here, not upstream, so heading_index can keep
# emitting them for compute_exempt_ids's parent-reset walk. Returns 2 on zero
# matches (including "found headings but every one of them non-numbered") —
# never a silent 0 a caller could read as "this doctrine file has no
# sections", and propagates heading_index's own rc=2 (mask_code_fences
# failure) rather than swallowing it.
methodology_sections() {
  local file="$1"
  local idx
  idx="$(heading_index "$file")" || return 2
  if [ -z "$idx" ]; then
    printf 'FATAL: methodology_sections — zero headings of any kind found in %s\n' "$file" >&2
    return 2
  fi
  local ids
  ids="$(awk '$3 != "-" {print $3}' <<<"$idx" | sort -u)"
  if [ -z "$ids" ]; then
    printf 'FATAL: methodology_sections — headings found in %s but none numbered\n' "$file" >&2
    return 2
  fi
  printf '%s\n' "$ids"
}

# compute_exempt_ids FILE HC_IDS SIT_IDS
# A `###` (level-3) heading is exempt from needing its own tier-list entry
# ONLY while it is nested under a `##` (level-2) parent heading that is
# itself tiered (present in HC_IDS or SIT_IDS) — walked live from FILE's
# actual heading order, never a hardcoded list (round-2 m3: promoting a
# nested `### 12b.` to a top-level `## 12b.` must make it stop being exempt).
# An empty result is a legitimate "no exemptions apply" state, not a parser
# failure — only a completely empty heading_index (the file has no headings
# at all) returns 2.
compute_exempt_ids() {
  local file="$1" hc_ids="$2" sit_ids="$3"
  local idx
  idx="$(heading_index "$file")" || return 2
  if [ -z "$idx" ]; then
    printf 'FATAL: compute_exempt_ids — zero headings indexed in %s\n' "$file" >&2
    return 2
  fi
  local parent="" exempt="" lvl id
  while IFS=' ' read -r _ lvl id; do
    [ -z "${id:-}" ] && continue
    if [ "$lvl" = "2" ]; then
      # A level-2 heading ALWAYS resets the tracked parent, numbered ("23")
      # or not ("-"): a non-numbered "## Appendix" must NOT let a later
      # `### 30.` inherit exemption from whichever numbered `##` last
      # appeared, possibly several real sections earlier (round-3 minor #3).
      parent="$id"
    elif [ "$lvl" = "3" ]; then
      if [ "$id" != "-" ] && [ -n "$parent" ] && [ "$parent" != "-" ] \
         && { grep -qxF "$parent" <<<"$hc_ids" || grep -qxF "$parent" <<<"$sit_ids"; }; then
        exempt="$exempt
$id"
      fi
    fi
  done <<<"$idx"
  printf '%s\n' "$exempt" | grep -v '^$'
  return 0
}

# measure_hotcore FILE IDS
# Sums lines and bytes for every bare section id in IDS (one per line) that
# has a level-2 heading in FILE (HOT-CORE never currently lists a level-3 id;
# see the "Level-2-only" note below).
#
# Boundary semantics (round-3 review, R3-measure-boundary-semantics-shift): a
# section's content runs to the next level-2 heading of ANY kind — numbered
# OR non-numbered ("## Appendix") — not just the next NUMBERED one. Round 2's
# version only saw numbered level-2 headings (heading_index did not emit
# non-numbered ones yet), so a non-numbered `##` sitting between a HOT-CORE
# section and the next numbered section would have been skipped over,
# silently pulling that unrelated content into the HOT-CORE measurement (and
# the LAST HOT-CORE section would run all the way to EOF past any trailing
# non-numbered content). heading_index now emits non-numbered level-2 rows
# too (needed by compute_exempt_ids's parent-reset fix), and this function
# reuses that same enumerator unfiltered by id, so it gets the correct
# boundary semantics for free. Byte/line counts are read from the ORIGINAL
# (unmasked) file — masking only decides where boundaries are, never what a
# section's real content is. Returns 2 if IDS is empty or a listed id has no
# level-2 heading (a HOT-CORE bullet naming a section that does not exist is
# a broken doctrine file, not a zero-size section), or if heading_index
# itself failed (an unclosed/mismatched fence).
#
# Level-2-only, by design, not oversight: methodology_sections/heading_index
# report BOTH `##` and `###` ids (T6/T8 need to see `###` ids like 12b/12c to
# validate their dynamic nesting-exemption). measure_hotcore only sizes `##`
# ids because no HOT-CORE-listed id is ever a `###` id today, and correctly
# sizing a `###` section needs different "next heading" boundary rules (stop
# at the next heading of level <=3, not just the next `##`) that nothing here
# exercises yet. If a `###` id is ever added to HOT-CORE, this function must
# grow that case rather than silently mis-measuring it.
measure_hotcore() {
  local file="$1" ids="$2"
  if [ -z "$ids" ]; then
    printf 'FATAL: measure_hotcore — empty HOT-CORE id list (derive from SKILL.md, never hardcode)\n' >&2
    return 2
  fi
  local full_idx
  full_idx="$(heading_index "$file")" || return 2
  local lvl2
  lvl2="$(awk '$2==2' <<<"$full_idx")"
  if [ -z "$lvl2" ]; then
    printf 'FATAL: measure_hotcore — zero level-2 headings found in %s\n' "$file" >&2
    return 2
  fi
  local file_lines; file_lines="$(wc -l < "$file")"
  local total_lines=0 total_bytes=0 n s e b l row
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    row="$(awk -v id="$n" '$3==id{print; exit}' <<<"$lvl2")"
    if [ -z "$row" ]; then
      printf 'FATAL: measure_hotcore — HOT-CORE section §%s has no level-2 heading in %s\n' "$n" "$file" >&2
      return 2
    fi
    s="${row%% *}"
    e="$(awk -v s="$s" -v last="$file_lines" '$1>s{print $1-1; f=1; exit} END{if(!f) print last}' <<<"$lvl2")"
    b="$(sed -n "${s},${e}p" "$file" | wc -c)"
    l=$(( e - s + 1 ))
    total_lines=$(( total_lines + l ))
    total_bytes=$(( total_bytes + b ))
  done <<<"$ids"
  printf '%s %s\n' "$total_lines" "$total_bytes"
}

# check_unrecognized_headings FILE
# Prints one "<line>: <text>" per line (outside code fences) that LOOKS like a
# numbered heading — 1 to 6 leading `#`, then whitespace (any run of
# spaces/tabs, not just exactly one), then an optional `§`, then a digit —
# but does NOT match the strict recognized form (`## N.` / `### N.`) — e.g.
# `## 24 — X`, `## §24. X`, `## 24) X`, `##  24.` (double space), `#### 25.`,
# `# 26.`. Empty output = none found. This is deliberately a SEPARATE, looser
# scan from heading_index: its whole purpose is to catch the false-negative
# direction (kit CLAUDE.md §7) — headings the strict parser would silently
# miss — so it must not reuse the strict regex. Returns 2 (via the caller
# checking $?, since this function's own output IS the finding list and
# cannot also carry an error sentinel) if mask_code_fences itself failed.
check_unrecognized_headings() {
  local file="$1"
  local out rc
  out="$(mask_code_fences "$file" | awk '
    /^#{1,6}[ \t]+§?[0-9]/ && !/^##[#]? [0-9]+[a-z]?\. / { print NR": "$0 }
  ')"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FATAL: check_unrecognized_headings — mask_code_fences failed on %s (rc=%d)\n' "$file" "$rc" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

# =============================================================================
# check_T* — one function per invariant. Each reads its file paths from
# RSDD_SKILL / RSDD_LOOP / RSDD_METH (falling back to the real SKILL /
# PROMPTLOOP / METHODOLOGY), so a tooth can point it at a mutant copy WITHOUT
# re-implementing any of the logic above. Return 0 = holds, 1 = violated (with
# a non-empty stdout diagnostic), 2 = a parser call inside could not look.
# =============================================================================

check_T1() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local a b
  a="$(tokens_of "$skill" "$SKILL_HC_START" "$SKILL_HC_END")" || return 2
  b="$(tokens_of "$loop" "$LOOP_HC_START" "$LOOP_HC_END")" || return 2
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
}

check_T2() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local a b
  a="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  b="$(tokens_of "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")" || return 2
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
}

check_T3() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local hc1 hc2
  hc1="$(tokens_of "$skill" "$SKILL_HC_START" "$SKILL_HC_END")" || return 2
  hc2="$(tokens_of "$loop" "$LOOP_HC_START" "$LOOP_HC_END")" || return 2
  if grep -qxF '§8b' <<<"$hc1" && grep -qxF '§8b' <<<"$hc2"; then
    return 0
  fi
  printf 'skill HOT-CORE=[%s] loop HOT-CORE=[%s]\n' "$(tr '\n' ' ' <<<"$hc1")" "$(tr '\n' ' ' <<<"$hc2")"
  return 1
}

check_T3b() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local sit1 sit2
  sit1="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  sit2="$(tokens_of "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")" || return 2
  if grep -qxF '§8b' <<<"$sit1" || grep -qxF '§8b' <<<"$sit2"; then
    printf 'skill SITUATIONAL=[%s] loop SITUATIONAL=[%s]\n' "$(tr '\n' ' ' <<<"$sit1")" "$(tr '\n' ' ' <<<"$sit2")"
    return 1
  fi
  return 0
}

check_T4() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local sit1 sit2
  sit1="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  sit2="$(tokens_of "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")" || return 2
  if grep -qxF '§3b' <<<"$sit1" && grep -qxF '§3b' <<<"$sit2"; then
    return 0
  fi
  printf 'skill SITUATIONAL=[%s] loop SITUATIONAL=[%s]\n' "$(tr '\n' ' ' <<<"$sit1")" "$(tr '\n' ' ' <<<"$sit2")"
  return 1
}

check_T4b() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local sit1 sit2
  sit1="$(extract_block_inclusive "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")"
  sit2="$(extract_block_inclusive "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")"
  if [ -z "$sit1" ] || [ -z "$sit2" ]; then
    printf 'FATAL: check_T4b — SITUATIONAL marker pair not found\n' >&2
    return 2
  fi
  if grep -qF '§3b corpus layout' <<<"$sit1" && grep -qF '§3b corpus layout' <<<"$sit2"; then
    return 0
  fi
  printf 'trigger phrase "§3b corpus layout" not found inside the bounded SITUATIONAL block of skill and/or loop\n'
  return 1
}

check_T5() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local sit1 sit2
  sit1="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  sit2="$(tokens_of "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")" || return 2
  if grep -qxF '§20b' <<<"$sit1" && grep -qxF '§20b' <<<"$sit2"; then
    return 0
  fi
  printf 'skill SITUATIONAL=[%s] loop SITUATIONAL=[%s]\n' "$(tr '\n' ' ' <<<"$sit1")" "$(tr '\n' ' ' <<<"$sit2")"
  return 1
}

# check_T5b anchors "§20b" to its trigger wording as ONE contiguous phrase,
# the same way T4b does for §3b — not two independent grep -qF calls that
# could each match anywhere in the block regardless of adjacency (round-3
# review, R2-T5b-trigger-not-bound: the round-2 version checked '§20b' and
# 'journal mode' as separate co-occurring substrings, so a mutant that moved
# 'journal mode' text elsewhere in the block while leaving '§20b' bare would
# have still passed). SKILL.md's phrasing wraps across a line
# ("§20b block mode vs.\n       journal mode → ..."), so the block is
# whitespace-normalized (newlines and repeated spaces collapsed to one space
# each) before the anchored substring check, which PROMPT-LOOP.md's
# single-line phrasing does not need but tolerates harmlessly.
check_T5b() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}"
  local sit1 sit2 norm1 norm2
  sit1="$(extract_block_inclusive "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")"
  sit2="$(extract_block_inclusive "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")"
  if [ -z "$sit1" ] || [ -z "$sit2" ]; then
    printf 'FATAL: check_T5b — SITUATIONAL marker pair not found\n' >&2
    return 2
  fi
  norm1="$(tr '\n' ' ' <<<"$sit1" | tr -s ' ')"
  norm2="$(tr '\n' ' ' <<<"$sit2" | tr -s ' ')"
  if grep -qF '§20b block mode vs. journal mode' <<<"$norm1" \
     && grep -qF '§20b bloque vs. diario' <<<"$norm2"; then
    return 0
  fi
  printf 'anchored trigger phrase for §20b ("§20b block mode vs. journal mode" / "§20b bloque vs. diario") not found as one contiguous phrase inside the bounded SITUATIONAL block of skill and/or loop\n'
  return 1
}

check_T6() {
  local skill="${RSDD_SKILL:-$SKILL}" meth="${RSDD_METH:-$METHODOLOGY}"
  local hc sit
  hc="$(tokens_of "$skill" "$SKILL_HC_START" "$SKILL_HC_END")" || return 2
  sit="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  local hc_ids sit_ids
  hc_ids="$(sed 's/§//' <<<"$hc" | sort -u)"
  sit_ids="$(sed 's/§//' <<<"$sit" | sort -u)"
  local all_sections
  all_sections="$(methodology_sections "$meth")" || return 2
  local exempt_ids
  exempt_ids="$(compute_exempt_ids "$meth" "$hc_ids" "$sit_ids")" || return 2
  local orphans="" multi="" checked=0 id in_hc in_sit in_ex count
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    checked=$((checked+1))
    in_hc=0; in_sit=0; in_ex=0
    grep -qxF "$id" <<<"$hc_ids" && in_hc=1
    grep -qxF "$id" <<<"$sit_ids" && in_sit=1
    grep -qxF "$id" <<<"$exempt_ids" && in_ex=1
    count=$((in_hc + in_sit + in_ex))
    if [ "$count" -eq 0 ]; then
      orphans="$orphans §$id"
    elif [ "$count" -gt 1 ]; then
      multi="$multi §$id(hc=$in_hc,sit=$in_sit,exempt=$in_ex)"
    fi
  done <<<"$all_sections"
  if [ -n "$orphans" ] || [ -n "$multi" ]; then
    printf 'checked=%d orphans:[%s ] multi-tier:[%s ]\n' "$checked" "$orphans" "$multi"
    return 1
  fi
  printf 'checked=%d\n' "$checked"
  return 0
}

check_T7() {
  local skill="${RSDD_SKILL:-$SKILL}" meth="${RSDD_METH:-$METHODOLOGY}"
  local hc hc_ids out lines bytes
  hc="$(tokens_of "$skill" "$SKILL_HC_START" "$SKILL_HC_END")" || return 2
  hc_ids="$(sed 's/§//' <<<"$hc" | sort -u)"
  out="$(measure_hotcore "$meth" "$hc_ids")" || return 2
  lines="$(awk '{print $1}' <<<"$out")"
  bytes="$(awk '{print $2}' <<<"$out")"
  printf '%s lines / %s bytes (budget %s / %s)\n' "$lines" "$bytes" "$HOTCORE_BUDGET_LINES" "$HOTCORE_BUDGET_BYTES"
  if [ "$lines" -le "$HOTCORE_BUDGET_LINES" ] && [ "$bytes" -le "$HOTCORE_BUDGET_BYTES" ]; then
    return 0
  fi
  return 1
}

# T8 (round-2 m1): reverse check — every §-token named by either tier, in
# either file, must name a section that actually exists in METHODOLOGY.md.
check_T8() {
  local skill="${RSDD_SKILL:-$SKILL}" loop="${RSDD_LOOP:-$PROMPTLOOP}" meth="${RSDD_METH:-$METHODOLOGY}"
  local all_ids
  all_ids="$(methodology_sections "$meth")" || return 2
  local hc1 sit1 hc2 sit2
  hc1="$(tokens_of "$skill" "$SKILL_HC_START" "$SKILL_HC_END")" || return 2
  sit1="$(tokens_of "$skill" "$SKILL_SIT_START" "$SKILL_SIT_END")" || return 2
  hc2="$(tokens_of "$loop" "$LOOP_HC_START" "$LOOP_HC_END")" || return 2
  sit2="$(tokens_of "$loop" "$LOOP_SIT_START" "$LOOP_SIT_END")" || return 2
  local bad="" toks tok id
  for toks in "$hc1" "$sit1" "$hc2" "$sit2"; do
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      id="${tok#§}"
      grep -qxF "$id" <<<"$all_ids" || bad="$bad $tok"
    done <<<"$toks"
  done
  if [ -n "$bad" ]; then
    printf 'phantom token(s) (no matching METHODOLOGY.md section):%s\n' "$bad"
    return 1
  fi
  return 0
}

# T9 (round-2 m2): no numbered-looking heading uses an unrecognized form.
check_T9() {
  local meth="${RSDD_METH:-$METHODOLOGY}"
  local bad
  bad="$(check_unrecognized_headings "$meth")" || return 2
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# =============================================================================
# run_check NAME OK_DESC FAIL_DESC — runs a check_T* function once, reports it.
# =============================================================================
run_check() {
  local name="$1" desc_ok="$2" desc_fail="$3"
  local out rc
  out="$("$name")"
  rc=$?
  case "$rc" in
    0) ok "$name: $desc_ok${out:+ ($out)}" ;;
    1) no "$name: $desc_fail${out:+ — $out}" ;;
    *) no "$name: PARSER FAILURE (rc=$rc)${out:+ — $out}" ;;
  esac
}

run_check check_T1  "HOT-CORE token set agrees between SKILL.md and PROMPT-LOOP.md" "HOT-CORE token sets differ"
run_check check_T2  "SITUATIONAL token set agrees between SKILL.md and PROMPT-LOOP.md" "SITUATIONAL token sets differ"
run_check check_T3  "§8b is in HOT-CORE in both files" "§8b missing from HOT-CORE in SKILL.md and/or PROMPT-LOOP.md (#962)"
run_check check_T3b "§8b is not duplicated into SITUATIONAL in either file" "§8b still left in SITUATIONAL somewhere"
run_check check_T4  "§3b token is in SITUATIONAL in both files" "§3b token missing from SITUATIONAL (#962)"
run_check check_T4b "§3b's trigger text is inside the bounded SITUATIONAL block in both files" "§3b trigger text missing/out of the SITUATIONAL bounds"
run_check check_T5  "§20b token is in SITUATIONAL in both files" "§20b token missing from SITUATIONAL (#962)"
run_check check_T5b "§20b's trigger text is inside the bounded SITUATIONAL block in both files" "§20b trigger text missing/out of the SITUATIONAL bounds"
run_check check_T6  "every numbered METHODOLOGY.md section is in exactly one tier or dynamically-nested EXEMPT" "orphan or multi-tier section(s) found"
run_check check_T7  "HOT-CORE size within budget" "HOT-CORE size EXCEEDS budget"
run_check check_T8  "every tiered §-token names a real METHODOLOGY.md section" "phantom token(s) found"
run_check check_T9  "no unrecognized numbered-heading form(s) in METHODOLOGY.md" "unrecognized numbered-heading form(s) found"

# ===========================================================================
# --prove-teeth: mutation controls. Each mutant is a modified COPY in $TMP;
# the live tree is never touched. bite_tooth calls the REAL check_T* function
# against the mutant (via an RSDD_* override), never a re-implementation of
# the check's logic — this is what M1 (round-2 review) required.
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then

  # replace_literal_multiline FILE OLD NEW
  # Literal (non-regex) substring replacement across the whole file, including
  # a span that wraps a newline. awk gsub()/sed treat OLD as an ERE, and some
  # of the doctrine prose this needs to match contains regex metacharacters
  # (parentheses in particular) that would silently fail to match as a
  # "literal" pattern — Python's str.replace() has no such ambiguity. Fails
  # loudly (rc=3) if OLD is not found, so a later prose edit that moves the
  # anchor text breaks this mutant construction instead of silently producing
  # a no-op mutant (which would show up as a false "no teeth").
  replace_literal_multiline() {
    local file="$1" old="$2" new="$3"
    python3 -c '
import sys
file, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(file, encoding="utf-8").read()
if old not in s:
    sys.stderr.write("REPLACE-ANCHOR-NOT-FOUND\n")
    sys.exit(3)
sys.stdout.write(s.replace(old, new))
' "$file" "$old" "$new"
  }

  # bite_tooth NAME CHECK_FN VAR_NAME VAR_VAL
  # Temporarily points VAR_NAME (RSDD_SKILL / RSDD_LOOP / RSDD_METH) at a
  # mutant file, calls CHECK_FN, restores VAR_NAME, then classifies:
  #   rc=2            -> not a valid bite (parser crashed; R3-teeth-vacuous-on-parser-failure)
  #   rc=1, out empty -> not a valid bite (failed, but printed nothing — cannot
  #                      confirm the parser actually looked at the mutant)
  #   rc=1, out set   -> BITTEN
  #   rc=0             -> no teeth (mutation did not change the outcome)
  bite_tooth() {
    local tooth_name="$1" check_fn="$2" var_name="$3" var_val="$4"
    local had_prev=0 prev=""
    if [ -n "${!var_name+x}" ]; then had_prev=1; prev="${!var_name}"; fi
    printf -v "$var_name" '%s' "$var_val"
    local out rc
    out="$("$check_fn")"
    rc=$?
    if [ "$had_prev" -eq 1 ]; then printf -v "$var_name" '%s' "$prev"; else unset "$var_name"; fi
    case "$rc" in
      2) no "teeth-$tooth_name: $check_fn crashed on the mutant (rc=2) — not a valid bite (R3-teeth-vacuous-on-parser-failure)" ;;
      1) if [ -n "$out" ]; then
           ok "teeth-$tooth_name: $check_fn goes RED (rc=1) on the mutant — $out"
         else
           no "teeth-$tooth_name: $check_fn failed (rc=1) but printed no detail — cannot confirm it looked (R3-teeth-vacuous-on-parser-failure)"
         fi ;;
      0) no "teeth-$tooth_name: $check_fn still returns 0 (passing) on the mutant — no teeth" ;;
      *) no "teeth-$tooth_name: $check_fn returned unexpected rc=$rc on the mutant" ;;
    esac
  }

  echo "-- teeth: T1 (drop a HOT-CORE token from PROMPT-LOOP.md) --"
  m="$TMP/T1.PROMPTLOOP.md"
  sed 's/§8 §8b backlog-cell-grammar (written every iteration) §9/§8 §9/' "$PROMPTLOOP" > "$m"
  bite_tooth T1 check_T1 RSDD_LOOP "$m"

  echo "-- teeth: T2 (drop §23 from PROMPT-LOOP.md SITUATIONAL) --"
  m="$TMP/T2.PROMPTLOOP.md"
  old=$'§21 wall · §22 breakthrough-ledger ·\n         §23 kit-change template (coordinating a kit change across sessions). Unsure a phase is active -> read it.'
  new='§21 wall · §22 breakthrough-ledger. Unsure a phase is active -> read it.'
  replace_literal_multiline "$PROMPTLOOP" "$old" "$new" > "$m"
  bite_tooth T2 check_T2 RSDD_LOOP "$m"

  echo "-- teeth: T3 (remove §8b from SKILL.md HOT-CORE) --"
  m="$TMP/T3.SKILL.md"
  sed 's/§8 stopping + terminal trigger, §8b backlog cell grammar (written every iteration),/§8 stopping + terminal trigger,/' "$SKILL" > "$m"
  bite_tooth T3 check_T3 RSDD_SKILL "$m"

  echo "-- teeth: T3b (re-add §8b into SKILL.md SITUATIONAL, simulating 'duplicated, not moved') --"
  m="$TMP/T3b.SKILL.md"
  sed 's/shared-prefix corpus; §8c campaign queue/shared-prefix corpus; §8b backlog cell grammar → writing or editing a Gap-backlog row; §8c campaign queue/' "$SKILL" > "$m"
  bite_tooth T3b check_T3b RSDD_SKILL "$m"

  echo "-- teeth: T4 (strip the §3b token itself from SKILL.md SITUATIONAL, keep the prose) --"
  m="$TMP/T4.SKILL.md"
  sed 's/§3b corpus layout →/corpus layout →/' "$SKILL" > "$m"
  bite_tooth T4 check_T4 RSDD_SKILL "$m"

  echo "-- teeth: T4b (keep the §3b token, strip its 'corpus layout' trigger wording) --"
  m="$TMP/T4b.SKILL.md"
  sed 's/§3b corpus layout →/§3b →/' "$SKILL" > "$m"
  bite_tooth T4b check_T4b RSDD_SKILL "$m"

  echo "-- teeth: T5 (strip the §20b token itself from SKILL.md SITUATIONAL, keep the prose) --"
  m="$TMP/T5.SKILL.md"
  sed 's/; §20b block mode vs\./; block mode vs./' "$SKILL" > "$m"
  bite_tooth T5 check_T5 RSDD_SKILL "$m"

  echo "-- teeth: T5b (keep the §20b token, strip its 'journal mode' trigger wording) --"
  m="$TMP/T5b.SKILL.md"
  sed 's/journal mode → deciding whether applied work/mode → deciding whether applied work/' "$SKILL" > "$m"
  bite_tooth T5b check_T5b RSDD_SKILL "$m"

  echo "-- teeth: T5b-not-adjacent (co-occurrence without adjacency must NOT pass — round-3 R2-T5b-trigger-not-bound) --"
  m="$TMP/T5bNotAdjacent.SKILL.md"
  # Strip "journal mode" from its real spot next to §20b, AND plant the same
  # words somewhere else in the SITUATIONAL block. The round-2 unanchored
  # check ('§20b' and 'journal mode' as two independent greps) would have
  # passed this (both substrings still occur somewhere); the anchored check
  # must not.
  sed -e 's/journal mode → deciding whether applied work/mode → deciding whether applied work/' \
      -e 's/adding\/preserving\/citing an external source;/adding\/preserving\/citing an external source (journal mode mentioned here for testing);/' \
      "$SKILL" > "$m"
  bite_tooth T5b-not-adjacent check_T5b RSDD_SKILL "$m"

  echo "-- teeth: T6-orphan (delete §3b's SITUATIONAL mention entirely) --"
  m="$TMP/T6orphan.SKILL.md"
  old=$'coordinating a kit change across separate coordinator / researcher / QA sessions; §3b corpus layout →\n       creating or moving corpus files; '
  new='coordinating a kit change across separate coordinator / researcher / QA sessions; '
  replace_literal_multiline "$SKILL" "$old" "$new" > "$m"
  bite_tooth T6-orphan check_T6 RSDD_SKILL "$m"

  echo "-- teeth: T6-multi (also list §3b in SKILL.md HOT-CORE, so it is tiered twice) --"
  m="$TMP/T6multi.SKILL.md"
  sed 's/§8b backlog cell grammar (written every iteration), §9 golden rules,/§8b backlog cell grammar (written every iteration), §3b duplicate-test, §9 golden rules,/' "$SKILL" > "$m"
  bite_tooth T6-multi check_T6 RSDD_SKILL "$m"

  echo "-- teeth: T7 (inflate §1 with 2500 padding lines) --"
  m="$TMP/T7.METHODOLOGY.md"
  s1="$(grep -n '^## 1\. ' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  {
    sed -n "1,${s1}p" "$METHODOLOGY"
    for _ in $(seq 1 2500); do echo "padding line to blow the HOT-CORE budget"; done
    sed -n "$((s1+1)),\$p" "$METHODOLOGY"
  } > "$m"
  bite_tooth T7 check_T7 RSDD_METH "$m"

  echo "-- teeth: R3a (an unnumbered '## Appendix' with 2000 lines right after §1 must NOT inflate the HOT-CORE measurement) --"
  # Round-2's boundary lookup only recognized NUMBERED level-2 headings, so a
  # non-numbered '##' sitting between a HOT-CORE section and the next
  # numbered section was invisible to it: §1's range would have kept
  # extending straight through the appendix to '## 2.', silently inflating
  # §1's measured size. Round 3's boundary is "next `##` of ANY kind" (see
  # measure_hotcore's comment), so §1 must stop exactly where it always did.
  m="$TMP/R3a.METHODOLOGY.md"
  s1="$(grep -n '^## 1\. ' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  e1="$(awk -v s="$s1" '$0 ~ /^## / && NR>s {print NR-1; f=1; exit} END{if(!f) print NR}' "$METHODOLOGY")"
  {
    # Lines 1..e1 are §1 UNCHANGED (including whatever spacer line already
    # precedes the next heading in the real file); "## Appendix" becomes the
    # new immediate next line so §1's own measured range cannot shift by even
    # one line — inserting an extra blank separator here would inflate §1 by
    # exactly that many lines and defeat the point of this tooth.
    sed -n "1,${e1}p" "$METHODOLOGY"
    echo "## Appendix"
    echo ""
    for _ in $(seq 1 2000); do echo "appendix padding line that must not count toward any HOT-CORE section"; done
    sed -n "$((e1+1)),\$p" "$METHODOLOGY"
  } > "$m"
  baseline_out="$(check_T7)"
  mutant_out="$(RSDD_METH="$m" check_T7)"; mutant_rc=$?
  if [ "$mutant_rc" -eq 0 ] && [ "$mutant_out" = "$baseline_out" ]; then
    ok "teeth-R3a: 2000-line unnumbered appendix right after §1 does not move the HOT-CORE measurement — $mutant_out"
  else
    no "teeth-R3a: appendix leaked into the HOT-CORE measurement (baseline=[$baseline_out] mutant=[$mutant_out] rc=$mutant_rc) — boundary-semantics fix broken"
  fi

  echo "-- teeth: m1/T8 (inject a phantom §99 token into SKILL.md HOT-CORE) --"
  m="$TMP/T8.SKILL.md"
  sed 's/§17 resume\./§17 resume. §99 phantom-token./' "$SKILL" > "$m"
  bite_tooth m1-phantom-token check_T8 RSDD_SKILL "$m"

  echo "-- teeth: m2/T9 (append near-miss numbered-heading forms to METHODOLOGY.md) --"
  m="$TMP/T9.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  {
    echo ""
    echo "## 24 — Fake Section"
    echo "## §24. Fake Section"
    echo "## 24) Fake Section"
  } >> "$m"
  bite_tooth m2-unrecognized-heading check_T9 RSDD_METH "$m"

  echo "-- teeth: m2-widened (double space, 4 hashes, 1 hash — round-3 minor #2) --"
  m="$TMP/T9widened.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  {
    echo ""
    echo "##  24. Fake Section (double space)"
    echo "#### 25. Fake Section (four hashes)"
    echo "# 26. Fake Section (one hash)"
  } >> "$m"
  bite_tooth m2-widened check_T9 RSDD_METH "$m"

  echo "-- teeth: m3 (promote nested '### 12b.' to top-level '## 12b.' — dynamic exempt must revoke it) --"
  m="$TMP/m3.METHODOLOGY.md"
  sed 's/^### 12b\. /## 12b. /' "$METHODOLOGY" > "$m"
  if ! grep -qE '^## 12b\. ' "$m"; then
    no "teeth-m3: mutation of '### 12b.' -> '## 12b.' did not take — no teeth"
  else
    bite_tooth m3-dynamic-exempt check_T6 RSDD_METH "$m"
  fi

  echo "-- teeth: m3-parent-reset (a non-numbered '## Appendix' must reset the tracked parent — round-3 minor #3) --"
  # Insert right after §12c's real content (its tiered parent §12 would
  # otherwise be the most recent level-2 heading compute_exempt_ids has
  # seen): a non-numbered '## Appendix' followed by a numbered '### 30.'.
  # Without the parent-reset fix, §30 would wrongly inherit §12's tiered
  # status (the same bug class the review calls "make every `###` exempt →
  # must go RED": ANY implementation that fails to re-check the REAL nearest
  # parent — whether by not resetting on non-numbered headings, or by a
  # frankly broken 'always exempt' condition — makes §30 exempt when it must
  # not be, and this tooth catches either.
  m="$TMP/m3ParentReset.METHODOLOGY.md"
  s13="$(grep -n '^## 13\. ' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  {
    sed -n "1,$((s13-1))p" "$METHODOLOGY"
    echo "## Appendix"
    echo ""
    echo "### 30. Stray"
    echo ""
    echo "Content that must not inherit exemption from any earlier tiered section."
    echo ""
    sed -n "${s13},\$p" "$METHODOLOGY"
  } > "$m"
  out="$(RSDD_METH="$m" check_T6)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q '§30' <<<"$out"; then
    ok "teeth-m3-parent-reset: §30 after a non-numbered '## Appendix' is correctly caught as an orphan (rc=1) — $out"
  else
    no "teeth-m3-parent-reset: §30 was NOT caught (rc=$rc, out=[$out]) — parent-reset missing, §30 wrongly inherited exemption"
  fi

  echo "-- teeth: m4a (numbered heading INSIDE a fence must stay invisible to check_T6) --"
  mFenced="$TMP/m4.fenced.METHODOLOGY.md"
  cp "$METHODOLOGY" "$mFenced"
  {
    echo ""
    echo '```'
    echo "## 99. Fake Phantom Section"
    echo '```'
  } >> "$mFenced"
  out_fenced="$(RSDD_METH="$mFenced" check_T6)"; rc_fenced=$?
  out_baseline="$(check_T6)"
  if [ "$rc_fenced" -eq 0 ] && [ "$out_fenced" = "$out_baseline" ] && ! grep -q '§99' <<<"$out_fenced"; then
    ok "teeth-m4a: fenced '## 99.' heading stays invisible — check_T6 unchanged (checked count and outcome match baseline)"
  else
    no "teeth-m4a: fenced '## 99.' heading leaked into check_T6 (rc=$rc_fenced, out=[$out_fenced], baseline=[$out_baseline]) — fence-masking broken"
  fi

  echo "-- teeth: m4b (control: the SAME heading OUTSIDE a fence must be caught as a new orphan) --"
  m="$TMP/m4.unfenced.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  {
    echo ""
    echo "## 99. Fake Phantom Section"
  } >> "$m"
  out="$(RSDD_METH="$m" check_T6)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q '§99' <<<"$out"; then
    ok "teeth-m4b: the same heading OUTSIDE a fence IS caught as a new orphan (rc=1) — $out"
  else
    no "teeth-m4b: heading outside a fence was NOT caught (rc=$rc, out=[$out]) — control failed, m4a's PASS would be meaningless"
  fi

  echo "-- teeth: fence-unclosed (round-3 review MAJOR, repro #1: an unclosed fence must FATAL, not silently pass) --"
  # Exact reproduction: appending an unclosed ```text fence followed by a
  # real-looking numbered heading used to give a silent "12/0 PASS" (the
  # heading, never actually masked past EOF, either vanished or leaked
  # depending on toggle parity). Now it must make check_T6 return 2.
  m="$TMP/FenceUnclosed.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  { echo ""; echo '```text'; echo "## 24. New untiered section"; } >> "$m"
  out="$(RSDD_METH="$m" check_T6 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-fence-unclosed: unclosed fence makes check_T6 return 2 (FATAL), not a silent PASS"
  else
    no "teeth-fence-unclosed: unclosed fence did NOT trigger rc=2 (rc=$rc, out=[$out]) — silent pass would slip through"
  fi

  echo "-- teeth: fence-unclosed-via-T9 (the SAME unclosed fence must also FATAL through check_T9's path) --"
  # heading_index and check_unrecognized_headings are two SEPARATE consumers
  # of mask_code_fences; the review named both by name as needing the rc=2
  # conversion, so both get their own tooth against the same mutant.
  out="$(RSDD_METH="$m" check_T9 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-fence-unclosed-via-T9: unclosed fence makes check_T9 return 2 (FATAL) too"
  else
    no "teeth-fence-unclosed-via-T9: unclosed fence did NOT trigger rc=2 via check_T9 (rc=$rc, out=[$out])"
  fi

  echo "-- teeth: fence-4backtick-nested-3backtick (round-3 review MAJOR, repro #2) --"
  # A ````md (4-backtick) fence containing a ``` (3-backtick) line: the inner
  # line must NOT close the outer fence (wrong length), so the numbered
  # heading inside stays masked, and since the outer fence is never actually
  # closed with 4+ backticks here, the whole thing is correctly unclosed.
  m="$TMP/Fence4Nested3.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  { echo ""; echo '````md'; echo '```'; echo "## 24. New untiered section"; } >> "$m"
  out="$(RSDD_METH="$m" check_T6 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-fence-4backtick-nested-3backtick: the inner shorter run does not close the fence early — check_T6 returns 2"
  else
    no "teeth-fence-4backtick-nested-3backtick: did NOT return 2 (rc=$rc, out=[$out]) — the inner line likely closed the fence early, leaking '## 24.'"
  fi

  echo "-- teeth: fence-tilde-unclosed (round-3 review MAJOR, repro #3: ~~~ fences must be tracked too) --"
  m="$TMP/FenceTilde.METHODOLOGY.md"
  cp "$METHODOLOGY" "$m"
  { echo ""; echo '~~~text'; echo "## 24. New untiered section"; } >> "$m"
  out="$(RSDD_METH="$m" check_T6 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-fence-tilde-unclosed: unclosed ~~~ fence makes check_T6 return 2 (tilde fences are tracked)"
  else
    no "teeth-fence-tilde-unclosed: unclosed ~~~ fence did NOT trigger rc=2 (rc=$rc, out=[$out]) — tilde fences not recognized, '## 24.' leaked as a real heading"
  fi

  echo "-- teeth: anti-silent-zero (blank out every HOT-CORE token in SKILL.md) --"
  m="$TMP/zero.SKILL.md"
  sed 's/§1 guiding principle, §2 phases, §3 the 7 markers, §4 block anatomy, §7 state\/memory,/no tokens here at all,/' "$SKILL" \
    | sed 's/§8 stopping + terminal trigger, §8b backlog cell grammar (written every iteration), §9 golden rules,/still no tokens,/' \
    | sed 's/§11 self-verify, §17 resume\./no tokens at all./' \
    > "$m"
  ( tokens_of "$m" "$SKILL_HC_START" "$SKILL_HC_END" >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "teeth-anti-silent-zero: zero-token mutant makes tokens_of return 2 (not a silent empty pass)"
  else
    no "teeth-anti-silent-zero: zero-token mutant did NOT trigger the guard (rc=$rc) — silent zero would slip through"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
