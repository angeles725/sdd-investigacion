#!/usr/bin/env bash
# profile-invariants.test.sh — drift guard: a per-model-family prompt profile
# (kit issue #993 WU1: render-profile.sh + research-sdd/profiles/*.slots.md)
# must never fork doctrine. This suite renders every profile with the REAL
# render-profile.sh and runs the SAME invariant assertions
# skill-invariants.test.sh runs on the checked-in sources against every
# rendered copy (kit issue #993 WU3, #1021).
#
# A profile is allowed to change CADENCE WORDING (how often to re-read, in
# what tense) inside a slot body. It is never allowed to change WHICH
# doctrine sections exist, what they say, or what campaign/STOP vocabulary
# means — those invariants must hold in a rendered "general" copy exactly as
# they hold in the checked-in "claude" source.
#
# Checks:
#   G1  at least one custom profile file exists under $KIT/profiles/*.slots.md
#       (anti-silent-zero: "no profiles" and "profiles dir missing/unreadable"
#       are distinguishable — a missing/unreadable dir is FATAL, not a silent
#       zero-profile pass)
#   G2  every profile file declares at least one '## slot:<id>' section
#       (anti-silent-zero on the profile file itself, ahead of trusting the
#       renderer's own guard)
#   R1  render-profile.sh exits 0 for every profile (claude + every custom
#       profile) — this IS the "every slot id in the sources has a body in
#       every profile" check: render-profile.sh's own GUARD-MISSING refuses
#       (exit 2) the instant a source marker has no matching profile slot
#       section, so a clean exit proves full coverage without re-parsing
#       anything here.
#   S*  every shared invariant assertion from lib/prompt-invariants.sh (the
#       SAME functions skill-invariants.test.sh runs on the checked-in
#       sources) run against each profile's RENDERED SKILL.md, PROMPT-LOOP.md
#       and METHODOLOGY.md. PRESENCE checks (the invariant names a piece of
#       text that MUST exist) stay scoped to the one rendered file whose
#       structure they describe — A2's corpus-glossary table, for instance,
#       has no reason to exist in PROMPT-LOOP.md. ABSENCE checks (A1_neg,
#       A14_neg, C16, C17, C19, E1_no_optin — the invariant names text that
#       must NEVER exist anywhere) run against ALL THREE rendered files for
#       every profile: a slot body from research-sdd/profiles/<name>.slots.md
#       can land in SKILL.md OR PROMPT-LOOP.md, so an absence invariant
#       scoped to only one of them would miss a forbidden phrase smuggled in
#       through the other (round-2 review finding F1, #1022).
#   T1  forbidden doctrine tokens (next-entry:, campaign-bound-reached:,
#       [CERT], and any §<digit> section token) are absent from every slot
#       BODY declared in a profile file (research-sdd/profiles/*.slots.md) —
#       a slot may reword cadence, never reference or redefine a doctrine
#       section. A grep failure (rc>=2: bad pattern, I/O error, ENOMEM,
#       SIGPIPE, ...) is a loud FAIL here, never folded into "no match found"
#       (kit CLAUDE.md §7; round-2 review finding, minor).
#   T2  the same forbidden tokens are absent from every slot SPAN in the
#       checked-in sources (the "claude" body between <!-- slot:id --> and
#       <!-- /slot -->) — guards the source side of the same invariant, so a
#       future claude-body edit cannot introduce what T1 already forbids on
#       the profile side. Same explicit rc 0/1/>=2 handling as T1.
#   Z1  size budget: a non-claude profile's rendered SKILL.md + PROMPT-LOOP.md
#       total bytes must not exceed the claude render's total by more than
#       10%. The arithmetic lives in ONE function (z1_check), called by both
#       the real check below and its --prove-teeth tooth, so a tooth can
#       never drift from — or silently fail to notice a regression in — the
#       logic it is supposed to be proving (round-2 review finding F2).
#   H1  hotcore-budget.test.sh's full tier-list/budget suite (unmodified,
#       via its RSDD_SKILL/RSDD_LOOP/RSDD_METH env overrides) passes against
#       the CLAUDE-rendered tree. Not run against a non-claude render: its
#       SKILL_HC_START / LOOP_HC_START anchors are literal substrings that
#       include the slot MARKER text itself (documented in its own header
#       comment as intentional, #993-WU1-round-2), so they exist only in a
#       byte-identical "claude" render — a non-claude render legitimately
#       strips them. H2/H3 below is what verifies the SAME invariant
#       (HOT-CORE/SITUATIONAL tier membership) in a profile-portable way.
#   H2  the full SET of §<digit> section tokens found anywhere in a rendered
#       SKILL.md is identical across every profile (proves the tier lists a
#       reader sees cannot differ per profile: T1/T2 already forbid a slot
#       body from containing a §-token, so everything OUTSIDE slot spans —
#       where every §-token actually lives — is untouched by rendering; this
#       check verifies that guarantee empirically, on the real rendered
#       bytes, rather than trusting the T1/T2 static analysis alone).
#   H3  same as H2, for PROMPT-LOOP.md.
#
# --prove-teeth mutation controls (kit CLAUDE.md §4): every mutant is built
# on a COPY of the kit tree (RSDD_KIT_DIR, the same fixture pattern
# render-profile.test.sh uses) and re-rendered through the REAL renderer —
# never a hand-edited "rendered" file, and never a re-implementation of the
# check being proven.
#
# Usage: profile-invariants.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
KIT="$(cd "$TOOLBELT/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
RENDERER="$TOOLBELT/render-profile.sh"
SKILL="$KIT/skills/research-sdd/SKILL.md"
PROMPTLOOP="$KIT/PROMPT-LOOP.md"
METHODOLOGY="$KIT/METHODOLOGY.md"
PROFILES_DIR="$KIT/profiles"
LIB="$HERE/lib/prompt-invariants.sh"
HOTCORE_SUITE="$HERE/hotcore-budget.test.sh"

for f in "$RENDERER" "$SKILL" "$PROMPTLOOP" "$METHODOLOGY" "$LIB" "$HOTCORE_SUITE"; do
  [ -f "$f" ] || { printf 'FATAL: required file not found: %s\n' "$f" >&2; exit 2; }
done
[ -x "$RENDERER" ] || { printf 'FATAL: render-profile.sh is not executable: %s\n' "$RENDERER" >&2; exit 2; }
[ -d "$PROFILES_DIR" ] || { printf 'FATAL: profiles directory not found: %s\n' "$PROFILES_DIR" >&2; exit 2; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 2; }
# shellcheck source=lib/prompt-invariants.sh
source "$LIB"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== profile-invariants.test.sh =="

# =============================================================================
# G1/G2 — profile discovery, anti-silent-zero.
# =============================================================================
shopt -s nullglob
profile_files=("$PROFILES_DIR"/*.slots.md)
shopt -u nullglob
if [ "${#profile_files[@]}" -gt 0 ]; then
  ok "G1: ${#profile_files[@]} custom profile file(s) found under $PROFILES_DIR"
else
  no "G1: zero custom profile files found under $PROFILES_DIR — cannot verify the drift guard (anti-silent-zero)"
fi

PROFILE_NAMES=(claude)
for f in "${profile_files[@]}"; do
  base="$(basename "$f")"
  name="${base%.slots.md}"
  headers="$(grep -c '^## slot:' "$f" || true)"
  if [ "${headers:-0}" -gt 0 ]; then
    ok "G2/$name: profile file declares $headers slot section(s)"
  else
    no "G2/$name: profile file declares ZERO '## slot:<id>' sections (anti-silent-zero)"
  fi
  PROFILE_NAMES+=("$name")
done

# =============================================================================
# R1 — render every profile with the REAL renderer, against the live kit.
# A non-zero exit is the "every source slot marker has a matching profile
# body" failure signal (render-profile.sh's own GUARD-MISSING) — never
# treated as "this profile has fewer slots, skip its checks".
# =============================================================================
declare -A OUTDIR
render_failed=0
for name in "${PROFILE_NAMES[@]}"; do
  outdir="$TMP/render-$name"
  OUTDIR["$name"]="$outdir"
  if out="$("$RENDERER" "$name" "$outdir" 2>&1)"; then
    ok "R1/$name: render-profile.sh exits 0 (every source slot marker has a body in this profile)"
  else
    no "R1/$name: render-profile.sh FAILED (rc!=0) — $out"
    render_failed=1
  fi
done
if [ "$render_failed" -eq 1 ]; then
  echo "== $pass passed · $fail failed (aborting — cannot check invariants against a failed render) =="
  exit 1
fi

# =============================================================================
# S* — shared invariants (lib/prompt-invariants.sh) against every rendered
# SKILL.md / PROMPT-LOOP.md / METHODOLOGY.md. Presence checks stay scoped to
# the file whose structure they describe; every absence check runs against
# ALL THREE rendered files per profile (see header comment, F1).
# =============================================================================
SKILL_CHECKS=(A1 A2 A3 A4 A5 A6 A7 A8 A10 A11 A12a A12b A13 A15 C14)
LOOP_CHECKS=(B1 B2 B3 C4 C9 C15 C18 E2a E2b)
METH_CHECKS=(C1 C2 C3 C5 C6 C7 C8 C10 C11 C12 C13 E1a)
ABSENCE_CHECKS=(A1_neg A14_neg C16 C17 C19 E1_no_optin)

run_shared_checks() {
  local label="$1" file="$2"; shift 2
  local name fn
  for name in "$@"; do
    fn="assert_${name}"
    if "$fn" "$file"; then
      ok "$label/$name: holds"
    else
      no "$label/$name: VIOLATED on $file"
    fi
  done
}

for name in "${PROFILE_NAMES[@]}"; do
  outdir="${OUTDIR[$name]}"
  skill_file="$outdir/skills/research-sdd/SKILL.md"
  loop_file="$outdir/PROMPT-LOOP.md"
  meth_file="$outdir/METHODOLOGY.md"
  run_shared_checks "$name/SKILL"       "$skill_file" "${SKILL_CHECKS[@]}"
  run_shared_checks "$name/LOOP"        "$loop_file"  "${LOOP_CHECKS[@]}"
  run_shared_checks "$name/METHODOLOGY" "$meth_file"  "${METH_CHECKS[@]}"
  # Every absence check runs against every rendered file: an absence
  # invariant means "this text must never appear ANYWHERE", and a slot body
  # can land in SKILL.md or PROMPT-LOOP.md depending on which slot id it
  # fills (round-2 review finding F1, #1022).
  run_shared_checks "$name/SKILL"       "$skill_file" "${ABSENCE_CHECKS[@]}"
  run_shared_checks "$name/LOOP"        "$loop_file"  "${ABSENCE_CHECKS[@]}"
  run_shared_checks "$name/METHODOLOGY" "$meth_file"  "${ABSENCE_CHECKS[@]}"
done

# =============================================================================
# T1/T2 — forbidden doctrine tokens must never appear inside a slot body: a
# slot may reword cadence, never reference/redefine a doctrine section.
# '§8c' is a concrete instance already covered by the generic '§[0-9]' rule
# (kept as its own literal for a more specific failure message);
# 'campaign-bound-reached:' and '[CERT]' are NOT covered by '§[0-9]' — they
# contain no '§' character at all — so they are independent literals, not
# subsumed by the generic rule (round-2 review correction, R2-001).
# =============================================================================
FORBIDDEN_PATTERN='next-entry:|campaign-bound-reached:|\[CERT\]|§[0-9]'

# grep exit codes: 0 = match found, 1 = no match (healthy), >=2 = grep
# itself could not look (bad pattern, I/O error, ENOMEM, SIGPIPE, ...). The
# >=2 case is NEVER folded into "no match" anywhere below — a grep that
# could not look must FAIL loudly, not report a silent pass (kit CLAUDE.md
# §7; round-2 review, minor + R2-002).

# scan_profile_file FILE — prints every non-header line of FILE matching
# FORBIDDEN_PATTERN (the violations) and RETURNS 0 (violation found), 1
# (clean), or 2 (a grep stage errored). The classification is the function's
# own return code, never a side-channel global variable: every call site
# below invokes this via `x="$(scan_profile_file ...)"`, which runs the
# function's body in a subshell — a variable it sets internally would be
# lost when that subshell exits, but its exit status (this function's
# `return`) propagates to the caller's `$?` exactly as designed. A profile
# file, once past render-profile.sh's own free-text guard, consists ONLY of
# '## slot:<id>' headers, slot bodies, and blank lines — so filtering out
# header lines leaves exactly the slot bodies, with no separate parser
# needed.
scan_profile_file() {
  local file="$1" filtered rc
  filtered="$(grep -vE '^## slot:' "$file")"; rc=$?
  if [ "$rc" -ge 2 ]; then
    printf 'FATAL: scan_profile_file — grep -v errored (rc=%d) on %s\n' "$rc" "$file" >&2
    return 2
  fi
  # rc is 0 (found non-header lines) or 1 (zero non-header lines, e.g. an
  # all-header/empty file) — both are legitimate inputs to the pattern
  # match below, never an error on their own.
  if [ -z "$filtered" ]; then
    return 1
  fi
  local hits
  hits="$(grep -E "$FORBIDDEN_PATTERN" <<<"$filtered")"; rc=$?
  case "$rc" in
    0) printf '%s\n' "$hits"; return 0 ;;
    1) return 1 ;;
    *) printf 'FATAL: scan_profile_file — pattern grep errored (rc=%d) on %s\n' "$rc" "$file" >&2; return 2 ;;
  esac
}

# scan_source_slot_spans FILE — prints the text of every
# <!-- slot:id -->...<!-- /slot --> span (the "claude" body), one per line
# group, using the SAME marker regex render-profile.sh itself parses with,
# so this reads the doctrine exactly as the renderer does.
scan_source_slot_spans() {
  python3 - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
TOKEN_RE = re.compile(r'<!--\s*slot:([A-Za-z0-9_-]+)\s*-->|<!--\s*/slot\s*-->')
open_at = None
for m in TOKEN_RE.finditer(text):
    if m.group(1) is not None:
        open_at = m.end()
    elif open_at is not None:
        sys.stdout.write(text[open_at:m.start()])
        sys.stdout.write("\n")
        open_at = None
PYEOF
}

# scan_source_file FILE — runs scan_source_slot_spans and applies
# FORBIDDEN_PATTERN to the result via a here-string (never a pipe: a pipe
# component runs in its own subshell, and this function needs the pattern
# grep's OWN exit code). RETURNS 0/1/2 the same way scan_profile_file does
# (see its comment — return code, not a side-channel global).
scan_source_file() {
  local file="$1" spans hits rc
  spans="$(scan_source_slot_spans "$file")"
  hits="$(grep -E "$FORBIDDEN_PATTERN" <<<"$spans")"; rc=$?
  case "$rc" in
    0) printf '%s\n' "$hits"; return 0 ;;
    1) return 1 ;;
    *) printf 'FATAL: scan_source_file — pattern grep errored (rc=%d) on %s\n' "$rc" "$file" >&2; return 2 ;;
  esac
}

for f in "${profile_files[@]}"; do
  name="$(basename "$f" .slots.md)"
  hits="$(scan_profile_file "$f")"; scan_rc=$?
  case "$scan_rc" in
    1) ok "T1/$name: no forbidden doctrine token in any slot body of $(basename "$f")" ;;
    0) no "T1/$name: forbidden doctrine token found in a slot body of $(basename "$f") — $hits" ;;
    *) no "T1/$name: grep ERRORED (rc>=2) while scanning $(basename "$f") — treated as FAIL, never a silent pass" ;;
  esac
done

for f in "$SKILL" "$PROMPTLOOP"; do
  label="$(basename "$f")"
  hits="$(scan_source_file "$f")"; scan_rc=$?
  case "$scan_rc" in
    1) ok "T2/$label: no forbidden doctrine token in any source slot span" ;;
    0) no "T2/$label: forbidden doctrine token found in a source slot span — $hits" ;;
    *) no "T2/$label: grep ERRORED (rc>=2) while scanning $label's slot spans — treated as FAIL, never a silent pass" ;;
  esac
done

# =============================================================================
# P1/P2/N1/N2 — kit issue #993 WU4 round 2 (Opus finding): T1/T2/S* only
# check ABSENCE of specific literal doctrine tokens; nothing previously
# verified that a general slot body still carries the no-question rule and
# the `next:` continuation token FORWARD. A slot could satisfy every
# existing check while silently telling the loop it is fine to ask the
# operator and stop. P1/P2 assert PRESENCE of the two load-bearing
# continuation behaviors in the rendered general SKILL.md step-4 region;
# N1/N2 assert ABSENCE of two concrete stop-and-wait / ask-the-operator
# instruction shapes (reproducing Opus round-2 mutants M1 and M2) across
# every rendered general file — the same "a slot body can land in SKILL.md
# OR PROMPT-LOOP.md" scoping the S* absence checks already use (F1, #1022).
# Scoped to the "general" profile only: claude's step-4 text legitimately
# defers the concrete `next:` example to PROMPT-LOOP and has no reason to
# repeat it inline.
# =============================================================================
GENERAL_SKILL="${OUTDIR[general]}/skills/research-sdd/SKILL.md"
GENERAL_FILES=("${OUTDIR[general]}/skills/research-sdd/SKILL.md" "${OUTDIR[general]}/PROMPT-LOOP.md" "${OUTDIR[general]}/METHODOLOGY.md")

# p1_holds/p2_holds FILE — the ONLY place each presence check's grep lives;
# the --prove-teeth mutants below call these same functions (never a
# re-implemented duplicate), the same discipline z1_check documents above.
p1_holds() { grep -qF 'HARD rule inside the loop' "$1"; }
p2_holds() { grep -qF 'next: <gap-id>' "$1"; }

if p1_holds "$GENERAL_SKILL"; then
  ok "P1/general: the no-question rule ('HARD rule inside the loop') is present in the rendered general SKILL.md"
else
  no "P1/general: the no-question rule ('HARD rule inside the loop') is MISSING from the rendered general SKILL.md"
fi

if p2_holds "$GENERAL_SKILL"; then
  ok "P2/general: the continuation-token example ('next: <gap-id>') is present in the rendered general SKILL.md"
else
  no "P2/general: the continuation-token example ('next: <gap-id>') is MISSING from the rendered general SKILL.md"
fi

# forbidden_present PATTERN — greps every rendered general file for PATTERN.
# Returns 0 (found — a violation) with the hit printed, 1 (clean), or 2 (a
# grep stage errored — never folded into "clean", kit CLAUDE.md §7). The
# --prove-teeth mutants below call this same function. (Renamed from
# forbidden_absent, round 4: the old name read as "returns true when the
# forbidden pattern is absent", the inverse of what it actually returns.)
forbidden_present() {
  local pattern="$1" file hits rc
  for file in "${GENERAL_FILES[@]}"; do
    hits="$(grep -F "$pattern" "$file")"; rc=$?
    case "$rc" in
      0) printf '%s: %s\n' "$file" "$hits"; return 0 ;;
      1) continue ;;
      *) printf 'FATAL: forbidden_present — grep errored (rc=%d) on %s\n' "$rc" "$file" >&2; return 2 ;;
    esac
  done
  return 1
}

hits="$(forbidden_present 'fine to ask the operator')"; rc=$?
case "$rc" in
  1) ok "N1/general: no 'fine to ask the operator' stop-and-wait instruction in any rendered general file" ;;
  0) no "N1/general: found a stop-and-wait/ask-the-operator instruction — $hits" ;;
  *) no "N1/general: grep ERRORED (rc>=2) — treated as FAIL, never a silent pass" ;;
esac

hits="$(forbidden_present 'end your turn and wait')"; rc=$?
case "$rc" in
  1) ok "N2/general: no 'end your turn and wait' stop-and-wait instruction in any rendered general file" ;;
  0) no "N2/general: found a stop-and-wait/ask-the-operator instruction — $hits" ;;
  *) no "N2/general: grep ERRORED (rc>=2) — treated as FAIL, never a silent pass" ;;
esac

# =============================================================================
# Z1 — size budget: non-claude rendered SKILL.md+PROMPT-LOOP.md must not
# exceed the claude render's total bytes by more than 10%. z1_check is the
# ONLY place this arithmetic lives; the --prove-teeth tooth below calls it
# too, so mutating the arithmetic here is guaranteed to be visible to the
# tooth (round-2 review finding F2 — the original tooth re-implemented this
# formula independently and could not detect a real regression here).
# =============================================================================

# z1_check CLAUDE_DIR OTHER_DIR — prints "<other_total> <budget> <claude_total>"
# and returns 0 (within budget) or 1 (exceeds budget).
z1_check() {
  local claude_dir="$1" other_dir="$2"
  local claude_total budget other_total
  claude_total=$(( $(wc -c < "$claude_dir/skills/research-sdd/SKILL.md") + $(wc -c < "$claude_dir/PROMPT-LOOP.md") ))
  budget=$(( claude_total * 110 / 100 ))
  other_total=$(( $(wc -c < "$other_dir/skills/research-sdd/SKILL.md") + $(wc -c < "$other_dir/PROMPT-LOOP.md") ))
  printf '%s %s %s\n' "$other_total" "$budget" "$claude_total"
  [ "$other_total" -le "$budget" ]
}

for name in "${PROFILE_NAMES[@]}"; do
  [ "$name" = "claude" ] && continue
  z1_out="$(z1_check "${OUTDIR[claude]}" "${OUTDIR[$name]}")"; z1_rc=$?
  read -r z1_total z1_budget z1_claude_total <<<"$z1_out"
  if [ "$z1_rc" -eq 0 ]; then
    ok "Z1/$name: rendered size $z1_total bytes within budget (claude=$z1_claude_total, budget=$z1_budget, +10%)"
  else
    no "Z1/$name: rendered size $z1_total bytes EXCEEDS budget (claude=$z1_claude_total, budget=$z1_budget, +10%)"
  fi
done

# =============================================================================
# H1 — hotcore-budget.test.sh's full suite (unmodified) against the
# CLAUDE-rendered tree only (see header comment for why not every profile).
# Captures the nested suite's own output so a regression shows its actual
# FAIL lines here, instead of a bare "REGRESSED" with everything discarded
# to /dev/null (round-2 review, R4-H1-no-diagnostics).
# =============================================================================
if h1_out="$(RSDD_SKILL="${OUTDIR[claude]}/skills/research-sdd/SKILL.md" \
   RSDD_LOOP="${OUTDIR[claude]}/PROMPT-LOOP.md" \
   RSDD_METH="${OUTDIR[claude]}/METHODOLOGY.md" \
   bash "$HOTCORE_SUITE" 2>&1)"; then
  ok "H1: hotcore-budget.test.sh's full tier-list/budget suite passes against the claude-rendered tree"
else
  h1_fails="$(grep -F '  FAIL  ' <<<"$h1_out")"
  if [ -n "$h1_fails" ]; then
    no "H1: hotcore-budget.test.sh REGRESSED against the claude-rendered tree — $h1_fails"
  else
    no "H1: hotcore-budget.test.sh REGRESSED against the claude-rendered tree (no FAIL lines — suite may have crashed) — tail: $(tail -n 5 <<<"$h1_out")"
  fi
fi

# =============================================================================
# H2/H3 — the full §<digit> token SET found anywhere in a rendered file is
# identical across every profile (profile-portable equivalent of hotcore-
# budget's tier-list parity, per the H1 comment above).
# =============================================================================
token_set() { grep -oE '§[0-9]+[a-z]?' "$1" | sort -u; }

for rel in "skills/research-sdd/SKILL.md:H2" "PROMPT-LOOP.md:H3"; do
  file_rel="${rel%%:*}" check_id="${rel##*:}"
  base_tokens="$(token_set "${OUTDIR[claude]}/$file_rel")"
  if [ -z "$base_tokens" ]; then
    no "$check_id/claude: zero §-tokens found in $file_rel (anti-silent-zero — cannot verify parity)"
    continue
  fi
  for name in "${PROFILE_NAMES[@]}"; do
    [ "$name" = "claude" ] && continue
    other_tokens="$(token_set "${OUTDIR[$name]}/$file_rel")"
    if diff_out="$(diff <(printf '%s\n' "$base_tokens") <(printf '%s\n' "$other_tokens"))"; then
      ok "$check_id/$name: §-token set in $file_rel matches claude ($(printf '%s' "$base_tokens" | wc -l) token(s))"
    else
      no "$check_id/$name: §-token set in $file_rel DIFFERS from claude — $diff_out"
    fi
  done
done

# =============================================================================
# Q1/Q2/Q3/Q4 — kit issue #993 WU4 round 3+4 (provenance correction, then
# Opus round-4 review). git log -S / git show 6d88930 (#989) established:
# hotcore-reread-scope has NO pre-audit predecessor (pure #989 content, so
# it is now unslotted shared text — see the WU4 round-3 commit);
# hotcore-cadence's and hotcore-loop-cadence's real #989 semantic is the
# "once per context" reread cadence (round 1 mistakenly restored the
# pre-audit "every iteration" WORDING for hotcore-cadence as if it were
# still the correct BEHAVIOR, and round 3 left the identical bug in the
# sibling hotcore-loop-cadence slot — Opus round-4 finding, HIGH);
# loop-return-contract-explicit's inline `next:` example must not resurrect
# the pre-#989 "· rescheduled via <mechanism>" / "self-scheduled in <N>s"
# suffix grammar (absent from PROMPT-LOOP.md even at the
# prompts-pre-audit-2026-09-23 tag) NOR the pre-#989 "non-STOP" grammar
# (current RETURN CONTRACT: every report, INCLUDING STOP forms, ends with
# exactly one token — Opus round-4 finding, MEDIUM).
#   Q1  the (now unslotted) hotcore-reread-scope sentence renders
#       IDENTICALLY in claude and general — a differential check (compares
#       the two renders directly) rather than a hardcoded full-sentence pin,
#       so an unrelated doctrine wording edit does not turn this red (Opus
#       round-4 finding, LOW).
#   Q2  general's rendered SKILL.md HOT-CORE cadence line says
#       "once per context", never the pre-audit "every iteration" wording.
#   Q3  general's rendered SKILL.md never resurrects the dead
#       "rescheduled via" / "self-scheduled in" / "non-STOP" token grammar.
#   Q4  general's rendered PROMPT-LOOP.md HOT-CORE cadence line ALSO says
#       "once per context" — SKILL.md and PROMPT-LOOP.md must agree within
#       the same general render (Opus round-4 finding, HIGH: Q2 alone only
#       checked SKILL.md, so a contradicting PROMPT-LOOP.md went unnoticed).
# =============================================================================
q1_line() { grep -F 'Each iteration re-reads' "$1" | head -1; }

q1_claude_line="$(q1_line "${OUTDIR[claude]}/skills/research-sdd/SKILL.md")"
q1_general_line="$(q1_line "$GENERAL_SKILL")"
if [ -z "$q1_claude_line" ]; then
  no "Q1/claude: the hotcore-reread-scope sentence is MISSING from claude SKILL.md (anti-silent-zero — cannot verify parity)"
elif [ "$q1_claude_line" = "$q1_general_line" ]; then
  ok "Q1: the hotcore-reread-scope sentence renders identically in claude and general — $q1_claude_line"
else
  no "Q1: the hotcore-reread-scope sentence DIFFERS between claude and general — claude=[$q1_claude_line] general=[$q1_general_line]"
fi

q2_holds() { grep -qF 'HOT-CORE — read IN FULL once per context' "$1"; }

if q2_holds "$GENERAL_SKILL"; then
  ok "Q2/general: SKILL.md HOT-CORE cadence carries the #989 'once per context' semantic (pre-audit-explicit style, not the pre-#989 'every iteration' behavior)"
else
  no "Q2/general: SKILL.md HOT-CORE cadence is MISSING the #989 'once per context' semantic — reverted to pre-#989 'every iteration' behavior"
fi

# q3_holds FILE — returns 0 (holds), 1 (a forbidden phrase was found), or 2
# (a grep stage errored — a FATAL never folded into "holds", kit CLAUDE.md
# §7 / Opus round-4 R4-002-class discipline: an instrument that reports
# "clean" must be able to prove it actually looked).
q3_holds() {
  local f="$1" bad rc
  for bad in 'rescheduled via' 'self-scheduled in' 'non-STOP'; do
    grep -qF "$bad" "$f"; rc=$?
    case "$rc" in
      0) return 1 ;;
      1) continue ;;
      *) printf 'FATAL: q3_holds — grep errored (rc=%d) on %s\n' "$rc" "$f" >&2; return 2 ;;
    esac
  done
  return 0
}

q3_rc=0; q3_holds "$GENERAL_SKILL" || q3_rc=$?
case "$q3_rc" in
  0) ok "Q3/general: loop-return-contract-explicit does not resurrect the dead 'rescheduled via' / 'self-scheduled in' / 'non-STOP' token grammar" ;;
  1) no "Q3/general: loop-return-contract-explicit resurrects pre-#989 token grammar absent from current PROMPT-LOOP.md" ;;
  *) no "Q3/general: q3_holds ERRORED (rc>=2) — treated as FAIL, never a silent pass" ;;
esac

q4_holds() { grep -qF 'HOT-CORE (read IN FULL once per context)' "$1"; }

GENERAL_LOOP="${OUTDIR[general]}/PROMPT-LOOP.md"
if q4_holds "$GENERAL_LOOP"; then
  ok "Q4/general: PROMPT-LOOP.md HOT-CORE cadence ALSO carries the #989 'once per context' semantic (agrees with Q2's SKILL.md check in the same render)"
else
  no "Q4/general: PROMPT-LOOP.md HOT-CORE cadence is MISSING the #989 'once per context' semantic — contradicts SKILL.md's hotcore-cadence in the same render"
fi

# ===========================================================================
# --prove-teeth: mutants on COPIES of the profile file / sources / renderer,
# via RSDD_KIT_DIR pointing at a copied kit — every mutant is re-rendered
# through the REAL render-profile.sh, never hand-edited output. Pass/fail is
# always recorded in the PARENT shell (never inside a `$(...)` — a `no()`
# there is lost in the subshell, kit CLAUDE.md §3's render-profile.test.sh
# fix).
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then

  make_kit() {  # DIR
    local dir="$1"
    mkdir -p "$dir/skills/research-sdd" "$dir/profiles"
    cp "$SKILL" "$dir/skills/research-sdd/SKILL.md"
    cp "$PROMPTLOOP" "$dir/PROMPT-LOOP.md"
    cp "$METHODOLOGY" "$dir/METHODOLOGY.md"
    for f in "${profile_files[@]}"; do
      cp "$f" "$dir/profiles/$(basename "$f")"
    done
  }

  # require_anchor FILE OLD — fails loudly (prints to stderr, returns 1) if
  # OLD is not found in FILE, so a vanished anchor is a recorded FAIL, never
  # a silently skipped tooth.
  require_anchor() {
    local file="$1" old="$2"
    grep -qF "$old" "$file" && return 0
    printf 'MUTATION-ANCHOR-NOT-FOUND: %s in %s\n' "$old" "$file" >&2
    return 1
  }

  echo "-- teeth: T-drop-invariant-phrase (remove 'the 7 markers' from the copied kit's SKILL.md source, render claude, assert_A1 must go RED) --"
  kitDrop="$TMP/kitDrop"
  make_kit "$kitDrop"
  if require_anchor "$kitDrop/skills/research-sdd/SKILL.md" 'the 7 markers'; then
    sed -i 's/the 7 markers/the N markers/g' "$kitDrop/skills/research-sdd/SKILL.md"
    outDrop="$TMP/outDrop"
    if RSDD_KIT_DIR="$kitDrop" "$RENDERER" claude "$outDrop" >/dev/null 2>&1; then
      if assert_A1 "$outDrop/skills/research-sdd/SKILL.md"; then
        no "teeth-drop-invariant-phrase: assert_A1 still PASSES on the mutant render — no teeth"
      else
        ok "teeth-drop-invariant-phrase: assert_A1 goes RED on the mutant render (real renderer, real check)"
      fi
    else
      no "teeth-drop-invariant-phrase: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-drop-invariant-phrase: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-absence-phrase-in-skill-slot (inject a C16 absence phrase into the general SKILL slot body, render general, assert_C16 on the rendered SKILL.md must go RED — reproduces round-2 review finding F1) --"
  kitAbsSkill="$TMP/kitAbsSkill"
  make_kit "$kitAbsSkill"
  profileAbsSkill="$kitAbsSkill/profiles/general.slots.md"
  if [ -f "$profileAbsSkill" ] && require_anchor "$profileAbsSkill" 'read IN FULL once per context'; then
    sed -i 's/read IN FULL once per context/read IN FULL once per context. an autonomous run must stop at convergence/' "$profileAbsSkill"
    outAbsSkill="$TMP/outAbsSkill"
    if RSDD_KIT_DIR="$kitAbsSkill" "$RENDERER" general "$outAbsSkill" >/dev/null 2>&1; then
      if assert_C16 "$outAbsSkill/skills/research-sdd/SKILL.md"; then
        no "teeth-absence-phrase-in-skill-slot: assert_C16 still PASSES on the mutant general SKILL.md render — no teeth (F1 not fixed)"
      else
        ok "teeth-absence-phrase-in-skill-slot: assert_C16 goes RED on the mutant general SKILL.md render — the S* SKILL-scoped absence check is proven to actually run on a general render"
      fi
    else
      no "teeth-absence-phrase-in-skill-slot: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-absence-phrase-in-skill-slot: mutation anchor not found (no general.slots.md, or anchor moved) — cannot prove teeth"
  fi

  echo "-- teeth: T-absence-phrase-in-loop-slot (inject an A14 absence phrase into the general LOOP slot body, render general, assert_A14_neg on the rendered PROMPT-LOOP.md must go RED — reproduces round-2 review finding F1) --"
  kitAbsLoop="$TMP/kitAbsLoop"
  make_kit "$kitAbsLoop"
  profileAbsLoop="$kitAbsLoop/profiles/general.slots.md"
  if [ -f "$profileAbsLoop" ] && require_anchor "$profileAbsLoop" '(read IN FULL once per context)'; then
    sed -i 's/(read IN FULL once per context)/(read IN FULL once per context — guarantees the cadence)/' "$profileAbsLoop"
    outAbsLoop="$TMP/outAbsLoop"
    if RSDD_KIT_DIR="$kitAbsLoop" "$RENDERER" general "$outAbsLoop" >/dev/null 2>&1; then
      if assert_A14_neg "$outAbsLoop/PROMPT-LOOP.md"; then
        no "teeth-absence-phrase-in-loop-slot: assert_A14_neg still PASSES on the mutant general PROMPT-LOOP.md render — no teeth (F1 not fixed)"
      else
        ok "teeth-absence-phrase-in-loop-slot: assert_A14_neg goes RED on the mutant general PROMPT-LOOP.md render — the S* LOOP-scoped absence check is proven to actually run on a general render"
      fi
    else
      no "teeth-absence-phrase-in-loop-slot: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-absence-phrase-in-loop-slot: mutation anchor not found (no general.slots.md, or anchor moved) — cannot prove teeth"
  fi

  echo "-- teeth: T-absence-phrase-c19-in-slot (kit issue #993 WU4: inject a C19 absence phrase — signal \"continue\" — into the general loop-return-contract-explicit slot body, render general, assert_C19 on the rendered SKILL.md must go RED) --"
  kitAbsC19="$TMP/kitAbsC19"
  make_kit "$kitAbsC19"
  profileAbsC19="$kitAbsC19/profiles/general.slots.md"
  if [ -f "$profileAbsC19" ] && require_anchor "$profileAbsC19" 'A return without one is a silently stopped iteration.'; then
    sed -i 's/A return without one is a silently stopped iteration\./A return without one is a silently stopped iteration. Do not simply signal "continue"./' "$profileAbsC19"
    outAbsC19="$TMP/outAbsC19"
    if RSDD_KIT_DIR="$kitAbsC19" "$RENDERER" general "$outAbsC19" >/dev/null 2>&1; then
      if assert_C19 "$outAbsC19/skills/research-sdd/SKILL.md"; then
        no "teeth-absence-phrase-c19-in-slot: assert_C19 still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-absence-phrase-c19-in-slot: assert_C19 goes RED on the mutant general SKILL.md render — the S* SKILL-scoped C19 absence check is proven to actually run on a general render"
      fi
    else
      no "teeth-absence-phrase-c19-in-slot: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-absence-phrase-c19-in-slot: mutation anchor not found (no general.slots.md, or anchor moved) — cannot prove teeth"
  fi

  echo "-- teeth: T-doctrine-token-in-profile-body (inject a §-token into general.slots.md's slot body, T1 must go RED) --"
  kitToken="$TMP/kitToken"
  make_kit "$kitToken"
  profileCopy="$kitToken/profiles/general.slots.md"
  if [ -f "$profileCopy" ] && require_anchor "$profileCopy" 'once per context (session start'; then
    sed -i 's/once per context (session start/once per context (see §8c) (session start/' "$profileCopy"
    hits="$(scan_profile_file "$profileCopy")"; scan_rc=$?
    if [ "$scan_rc" -eq 0 ]; then
      ok "teeth-doctrine-token-in-profile-body: T1's scan catches the injected §8c token on the mutant — $hits"
    else
      no "teeth-doctrine-token-in-profile-body: T1's scan found nothing on the mutant (rc=$scan_rc) — no teeth"
    fi
  else
    no "teeth-doctrine-token-in-profile-body: mutation anchor not found (no general.slots.md, or anchor moved) — cannot prove teeth"
  fi

  echo "-- teeth: T-doctrine-token-in-source-span (inject a §-token into SKILL.md's hotcore-cadence source slot body, T2 must go RED) --"
  kitSourceToken="$TMP/kitSourceToken"
  make_kit "$kitSourceToken"
  skillCopy="$kitSourceToken/skills/research-sdd/SKILL.md"
  if require_anchor "$skillCopy" '<!-- slot:hotcore-cadence -->read once per context'; then
    sed -i 's/<!-- slot:hotcore-cadence -->read once per context/<!-- slot:hotcore-cadence -->read once per context (see §8c)/' "$skillCopy"
    hits="$(scan_source_file "$skillCopy")"; scan_rc=$?
    if [ "$scan_rc" -eq 0 ]; then
      ok "teeth-doctrine-token-in-source-span: T2's scan catches the injected §8c token on the mutant source — $hits"
    else
      no "teeth-doctrine-token-in-source-span: T2's scan found nothing on the mutant source (rc=$scan_rc) — no teeth"
    fi
  else
    no "teeth-doctrine-token-in-source-span: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-inflate-slot-past-budget (pad a slot body in the copied kit's general.slots.md, render claude+general, z1_check — the REAL Z1 logic — must go RED) --"
  kitInflate="$TMP/kitInflate"
  make_kit "$kitInflate"
  profileInflate="$kitInflate/profiles/general.slots.md"
  if [ -f "$profileInflate" ] && require_anchor "$profileInflate" 'read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not'; then
    padding="$(printf 'x%.0s' $(seq 1 20000))"
    sed -i "s/read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not/read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not ${padding}/" "$profileInflate"
    outInflateClaude="$TMP/outInflateClaude"; outInflateGeneral="$TMP/outInflateGeneral"
    if RSDD_KIT_DIR="$kitInflate" "$RENDERER" claude "$outInflateClaude" >/dev/null 2>&1 \
       && RSDD_KIT_DIR="$kitInflate" "$RENDERER" general "$outInflateGeneral" >/dev/null 2>&1; then
      z1_teeth_out="$(z1_check "$outInflateClaude" "$outInflateGeneral")"; z1_teeth_rc=$?
      if [ "$z1_teeth_rc" -ne 0 ]; then
        ok "teeth-inflate-slot-past-budget: z1_check (the REAL Z1 logic, not a re-implementation) goes RED on the mutant — $z1_teeth_out"
      else
        no "teeth-inflate-slot-past-budget: z1_check still PASSES on the mutant — $z1_teeth_out — no teeth"
      fi
    else
      no "teeth-inflate-slot-past-budget: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-inflate-slot-past-budget: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-remove-slot-body (delete a '## slot:' section from the copied kit's general.slots.md, R1 must go RED with EXACTLY render-profile.sh's GUARD-MISSING: exit 2 and a 'missing' message on stderr — round-2 review finding R3-remove-slot-teeth-any-failure) --"
  kitRemove="$TMP/kitRemove"
  make_kit "$kitRemove"
  profileRemove="$kitRemove/profiles/general.slots.md"
  if [ -f "$profileRemove" ] && require_anchor "$profileRemove" '## slot:hotcore-loop-cadence'; then
    python3 - "$profileRemove" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'## slot:hotcore-loop-cadence\n.*?(?=\n## slot:|\Z)', '', s, flags=re.DOTALL)
open(p, 'w', encoding='utf-8').write(s)
PYEOF
    outRemove="$TMP/outRemove"
    remove_out="$(RSDD_KIT_DIR="$kitRemove" "$RENDERER" general "$outRemove" 2>&1)"; remove_rc=$?
    if [ "$remove_rc" -eq 2 ] && grep -qi 'missing' <<<"$remove_out"; then
      ok "teeth-remove-slot-body: R1's real render-exit-code check goes RED on the mutant — render-profile.sh's own GUARD-MISSING fires with exit 2 and a 'missing' message: $remove_out"
    else
      no "teeth-remove-slot-body: mutant did NOT fail with the expected GUARD-MISSING signature (rc=$remove_rc, expected 2; out=[$remove_out]) — either it rendered (no teeth) or failed for the wrong reason"
    fi
  else
    no "teeth-remove-slot-body: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-remove-new-slot-body (kit issue #993 WU4: delete the loop-return-contract-explicit section from the copied kit's general.slots.md — the slot this work unit added — R1 must go RED with GUARD-MISSING) --"
  kitRemoveNew="$TMP/kitRemoveNew"
  make_kit "$kitRemoveNew"
  profileRemoveNew="$kitRemoveNew/profiles/general.slots.md"
  if [ -f "$profileRemoveNew" ] && require_anchor "$profileRemoveNew" '## slot:loop-return-contract-explicit'; then
    python3 - "$profileRemoveNew" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'## slot:loop-return-contract-explicit\n.*?(?=\n## slot:|\Z)', '', s, flags=re.DOTALL)
open(p, 'w', encoding='utf-8').write(s)
PYEOF
    outRemoveNew="$TMP/outRemoveNew"
    removeNew_out="$(RSDD_KIT_DIR="$kitRemoveNew" "$RENDERER" general "$outRemoveNew" 2>&1)"; removeNew_rc=$?
    if [ "$removeNew_rc" -eq 2 ] && grep -qi 'missing' <<<"$removeNew_out"; then
      ok "teeth-remove-new-slot-body: R1's real render-exit-code check goes RED on the mutant — GUARD-MISSING fires with exit 2 and a 'missing' message: $removeNew_out"
    else
      no "teeth-remove-new-slot-body: mutant did NOT fail with the expected GUARD-MISSING signature (rc=$removeNew_rc, expected 2; out=[$removeNew_out])"
    fi
  else
    no "teeth-remove-new-slot-body: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-p1-drop (kit issue #993 WU4 round 2: drop the HARD-rule phrase from the general slot body, render general, p1_holds — the REAL P1 logic — must go RED) --"
  kitP1Drop="$TMP/kitP1Drop"
  make_kit "$kitP1Drop"
  profileP1Drop="$kitP1Drop/profiles/general.slots.md"
  if [ -f "$profileP1Drop" ] && require_anchor "$profileP1Drop" 'HARD rule inside the loop'; then
    # Round 4: general.slots.md's slot bodies are single-line (Opus
    # round-4 LOW finding: a multi-line body renders at column 0 inside an
    # indented list item), so a plain single-line sed replace is enough —
    # no more cross-line python3 replace needed.
    sed -i 's/the no-question rule from the triage section is a HARD rule inside the loop\./the no-question rule applies./' "$profileP1Drop"
    outP1Drop="$TMP/outP1Drop"
    if RSDD_KIT_DIR="$kitP1Drop" "$RENDERER" general "$outP1Drop" >/dev/null 2>&1; then
      if p1_holds "$outP1Drop/skills/research-sdd/SKILL.md"; then
        no "teeth-p1-drop: p1_holds still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-p1-drop: p1_holds (the REAL P1 logic) goes RED on the mutant general SKILL.md render"
      fi
    else
      no "teeth-p1-drop: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-p1-drop: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-p2-drop (kit issue #993 WU4 round 2: drop the 'next: <gap-id>' example from the general slot body, render general, p2_holds — the REAL P2 logic — must go RED) --"
  kitP2Drop="$TMP/kitP2Drop"
  make_kit "$kitP2Drop"
  profileP2Drop="$kitP2Drop/profiles/general.slots.md"
  if [ -f "$profileP2Drop" ] && require_anchor "$profileP2Drop" '`next: <gap-id>` when the loop continues within the current focus.'; then
    sed -i 's/`next: <gap-id>` when the loop continues within the current focus\./a continuation token./' "$profileP2Drop"
    outP2Drop="$TMP/outP2Drop"
    if RSDD_KIT_DIR="$kitP2Drop" "$RENDERER" general "$outP2Drop" >/dev/null 2>&1; then
      if p2_holds "$outP2Drop/skills/research-sdd/SKILL.md"; then
        no "teeth-p2-drop: p2_holds still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-p2-drop: p2_holds (the REAL P2 logic) goes RED on the mutant general SKILL.md render"
      fi
    else
      no "teeth-p2-drop: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-p2-drop: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-n1-opus-m1 (kit issue #993 WU4 round 2: reproduce Opus round-2 mutant M1 — 'When unsure, it is fine to ask the operator \"shall I continue?\"' — injected into the general slot body; forbidden_present (N1's REAL logic) must go RED) --"
  kitN1M1="$TMP/kitN1M1"
  make_kit "$kitN1M1"
  profileN1M1="$kitN1M1/profiles/general.slots.md"
  if [ -f "$profileN1M1" ] && require_anchor "$profileN1M1" 'A return without one is a silently stopped iteration.'; then
    sed -i 's/A return without one is a silently stopped iteration\./A return without one is a silently stopped iteration. When unsure, it is fine to ask the operator "shall I continue?"./' "$profileN1M1"
    outN1M1="$TMP/outN1M1"
    if RSDD_KIT_DIR="$kitN1M1" "$RENDERER" general "$outN1M1" >/dev/null 2>&1; then
      # RDD round-4 finding: save/restore the global GENERAL_FILES around
      # this reassignment so a later check in this file (or a future one
      # added after this teeth block) cannot silently scan the mutant's
      # stale outdir instead of the real general render.
      saved_general_files=("${GENERAL_FILES[@]}")
      GENERAL_FILES=("$outN1M1/skills/research-sdd/SKILL.md" "$outN1M1/PROMPT-LOOP.md" "$outN1M1/METHODOLOGY.md")
      if forbidden_present 'fine to ask the operator' >/dev/null; then
        ok "teeth-n1-opus-m1: forbidden_present (the REAL N1 logic) catches Opus mutant M1 on the mutant general render"
      else
        no "teeth-n1-opus-m1: forbidden_present did NOT catch Opus mutant M1 — no teeth"
      fi
      GENERAL_FILES=("${saved_general_files[@]}")
    else
      no "teeth-n1-opus-m1: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-n1-opus-m1: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-n2-opus-m2 (kit issue #993 WU4 round 2: reproduce Opus round-2 mutant M2 — '...then end your turn and wait for the operator' — injected into the general slot body; forbidden_present (N2's REAL logic) must go RED) --"
  kitN2M2="$TMP/kitN2M2"
  make_kit "$kitN2M2"
  profileN2M2="$kitN2M2/profiles/general.slots.md"
  if [ -f "$profileN2M2" ] && require_anchor "$profileN2M2" 'A return without one is a silently stopped iteration.'; then
    sed -i 's/A return without one is a silently stopped iteration\./A return without one is a silently stopped iteration. If genuinely uncertain, then end your turn and wait for the operator./' "$profileN2M2"
    outN2M2="$TMP/outN2M2"
    if RSDD_KIT_DIR="$kitN2M2" "$RENDERER" general "$outN2M2" >/dev/null 2>&1; then
      saved_general_files=("${GENERAL_FILES[@]}")
      GENERAL_FILES=("$outN2M2/skills/research-sdd/SKILL.md" "$outN2M2/PROMPT-LOOP.md" "$outN2M2/METHODOLOGY.md")
      if forbidden_present 'end your turn and wait' >/dev/null; then
        ok "teeth-n2-opus-m2: forbidden_present (the REAL N2 logic) catches Opus mutant M2 on the mutant general render"
      else
        no "teeth-n2-opus-m2: forbidden_present did NOT catch Opus mutant M2 — no teeth"
      fi
      GENERAL_FILES=("${saved_general_files[@]}")
    else
      no "teeth-n2-opus-m2: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-n2-opus-m2: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-q1-divergence-regression (kit issue #993 WU4 round 4: re-slot the now-unslotted hotcore-reread-scope sentence in a copied kit with a DIFFERENT general body, so claude and general diverge again; Q1's differential comparison — the REAL Q1 logic — must go RED) --"
  kitQ1="$TMP/kitQ1"
  make_kit "$kitQ1"
  skillQ1="$kitQ1/skills/research-sdd/SKILL.md"
  profileQ1="$kitQ1/profiles/general.slots.md"
  if require_anchor "$skillQ1" 'Each iteration re-reads only RESEARCH-STATE, INDEX, and `--next` from the live backlog.'; then
    sed -i 's/Each iteration re-reads only RESEARCH-STATE, INDEX, and `--next` from the live backlog\./<!-- slot:hotcore-reread-scope-div -->Each iteration re-reads only RESEARCH-STATE, INDEX, and `--next` from the live backlog.<!-- \/slot -->/' "$skillQ1"
    {
      echo ""
      echo "## slot:hotcore-reread-scope-div"
      echo ""
      echo "Each iteration also re-reads RESEARCH-STATE, INDEX, and \`--next\` from the live backlog."
    } >> "$profileQ1"
    outQ1Claude="$TMP/outQ1Claude"; outQ1General="$TMP/outQ1General"
    if RSDD_KIT_DIR="$kitQ1" "$RENDERER" claude "$outQ1Claude" >/dev/null 2>&1 \
       && RSDD_KIT_DIR="$kitQ1" "$RENDERER" general "$outQ1General" >/dev/null 2>&1; then
      q1_teeth_claude="$(q1_line "$outQ1Claude/skills/research-sdd/SKILL.md")"
      q1_teeth_general="$(q1_line "$outQ1General/skills/research-sdd/SKILL.md")"
      if [ "$q1_teeth_claude" = "$q1_teeth_general" ]; then
        no "teeth-q1-divergence-regression: Q1's differential logic still PASSES though claude and general were made to diverge — no teeth"
      else
        ok "teeth-q1-divergence-regression: Q1's differential logic (the REAL logic) goes RED when claude and general diverge — claude=[$q1_teeth_claude] general=[$q1_teeth_general]"
      fi
    else
      no "teeth-q1-divergence-regression: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-q1-divergence-regression: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-q2-cadence-regression (kit issue #993 WU4 round 3: revert the general hotcore-cadence slot body to the pre-#989 'every iteration' cadence in the copied kit's general.slots.md, render general, q2_holds — the REAL Q2 logic — must go RED) --"
  kitQ2="$TMP/kitQ2"
  make_kit "$kitQ2"
  profileQ2="$kitQ2/profiles/general.slots.md"
  if [ -f "$profileQ2" ] && require_anchor "$profileQ2" 'read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not'; then
    sed -i 's/read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not/read IN FULL every iteration — never/' "$profileQ2"
    outQ2="$TMP/outQ2"
    if RSDD_KIT_DIR="$kitQ2" "$RENDERER" general "$outQ2" >/dev/null 2>&1; then
      if q2_holds "$outQ2/skills/research-sdd/SKILL.md"; then
        no "teeth-q2-cadence-regression: q2_holds still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-q2-cadence-regression: q2_holds (the REAL Q2 logic) goes RED on the mutant general SKILL.md render"
      fi
    else
      no "teeth-q2-cadence-regression: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-q2-cadence-regression: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-q3-stale-token-regression (kit issue #993 WU4 round 3: reintroduce the dead 'rescheduled via <mechanism>' suffix into the general loop-return-contract-explicit slot body, render general, q3_holds — the REAL Q3 logic — must go RED) --"
  kitQ3="$TMP/kitQ3"
  make_kit "$kitQ3"
  profileQ3="$kitQ3/profiles/general.slots.md"
  if [ -f "$profileQ3" ] && require_anchor "$profileQ3" '`next: <gap-id>` when the loop continues within the current focus.'; then
    sed -i 's/`next: <gap-id>` when the loop continues within the current focus\./`next: <gap-id> · rescheduled via <mechanism>` when the loop continues within the current focus./' "$profileQ3"
    outQ3="$TMP/outQ3"
    if RSDD_KIT_DIR="$kitQ3" "$RENDERER" general "$outQ3" >/dev/null 2>&1; then
      if q3_holds "$outQ3/skills/research-sdd/SKILL.md"; then
        no "teeth-q3-stale-token-regression: q3_holds still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-q3-stale-token-regression: q3_holds (the REAL Q3 logic) goes RED on the mutant general SKILL.md render"
      fi
    else
      no "teeth-q3-stale-token-regression: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-q3-stale-token-regression: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-q3-nonstop-regression (kit issue #993 WU4 round 4: reintroduce the dead 'non-STOP' RETURN CONTRACT grammar into the general loop-return-contract-explicit slot body, render general, q3_holds — the REAL Q3 logic — must go RED) --"
  kitQ3NS="$TMP/kitQ3NS"
  make_kit "$kitQ3NS"
  profileQ3NS="$kitQ3NS/profiles/general.slots.md"
  if [ -f "$profileQ3NS" ] && require_anchor "$profileQ3NS" 'every return MUST end with exactly one'; then
    sed -i 's/every return MUST end with exactly one/every non-STOP return MUST end with/' "$profileQ3NS"
    outQ3NS="$TMP/outQ3NS"
    if RSDD_KIT_DIR="$kitQ3NS" "$RENDERER" general "$outQ3NS" >/dev/null 2>&1; then
      if q3_holds "$outQ3NS/skills/research-sdd/SKILL.md"; then
        no "teeth-q3-nonstop-regression: q3_holds still PASSES on the mutant general SKILL.md render — no teeth"
      else
        ok "teeth-q3-nonstop-regression: q3_holds (the REAL Q3 logic) goes RED on the mutant general SKILL.md render"
      fi
    else
      no "teeth-q3-nonstop-regression: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-q3-nonstop-regression: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-q4-cadence-regression (kit issue #993 WU4 round 4 — Opus HIGH finding: revert the general hotcore-loop-cadence slot body to the pre-#989 'every iteration' cadence in the copied kit's general.slots.md, render general, q4_holds — the REAL Q4 logic — must go RED) --"
  kitQ4="$TMP/kitQ4"
  make_kit "$kitQ4"
  profileQ4="$kitQ4/profiles/general.slots.md"
  if [ -f "$profileQ4" ] && require_anchor "$profileQ4" '(read IN FULL once per context)'; then
    sed -i 's/(read IN FULL once per context)/(read IN FULL every iteration)/' "$profileQ4"
    outQ4="$TMP/outQ4"
    if RSDD_KIT_DIR="$kitQ4" "$RENDERER" general "$outQ4" >/dev/null 2>&1; then
      if q4_holds "$outQ4/PROMPT-LOOP.md"; then
        no "teeth-q4-cadence-regression: q4_holds still PASSES on the mutant general PROMPT-LOOP.md render — no teeth"
      else
        ok "teeth-q4-cadence-regression: q4_holds (the REAL Q4 logic) goes RED on the mutant general PROMPT-LOOP.md render"
      fi
    else
      no "teeth-q4-cadence-regression: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-q4-cadence-regression: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-vanished-anchor (a mutation anchor that does not exist must FAIL, not be silently skipped) --"
  kitVanished="$TMP/kitVanished"
  make_kit "$kitVanished"
  if require_anchor "$kitVanished/skills/research-sdd/SKILL.md" 'THIS-ANCHOR-DOES-NOT-EXIST-IN-ANY-KIT-SOURCE-XYZ'; then
    no "teeth-vanished-anchor: require_anchor unexpectedly SUCCEEDED on a nonexistent anchor — the guard itself is broken"
  else
    ok "teeth-vanished-anchor: require_anchor correctly reports FAILURE (rc=1) on a vanished anchor — the caller records it as FAIL, not a silent skip"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
