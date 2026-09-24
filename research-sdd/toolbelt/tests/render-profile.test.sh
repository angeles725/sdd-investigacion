#!/usr/bin/env bash
# render-profile.test.sh — behavior + mutation-control suite for render-profile.sh
# (kit issue #993, WU1: install-time slot rendering, no runtime indirection).
#
# render-profile.sh <profile> <outdir> renders the shared doctrine sources
# (SKILL.md, PROMPT-LOOP.md, METHODOLOGY.md — METHODOLOGY.md never carries a
# slot marker, enforced) for one model-family profile:
#   - profile "claude": sources copied byte-identical (markers remain — they
#     are HTML comments, invisible to readers).
#   - any other profile (e.g. "general"): every `<!-- slot:<id> -->...
#     <!-- /slot -->` span is replaced by that id's non-empty body from
#     research-sdd/profiles/<profile>.slots.md, and the marker comments are
#     stripped from the rendered output.
#
# Round-2 review (Opus, blocked) findings addressed here:
#   - Coherence: SKILL.md now carries THREE cadence slots (hotcore-cadence,
#     hotcore-reread-scope) and PROMPT-LOOP.md carries hotcore-loop-cadence,
#     so the "general" render never contradicts itself (F14).
#   - outdir/KIT_DIR containment refusal (F15), profile-name format (F16),
#     case-sensitive/loud marker detection (F17), empty-slot-body rejection
#     (F18), and the METHODOLOGY.md-never-carries-slots invariant (F19).
#   - Every --prove-teeth mutant is reworked so it completes a render (exit
#     0, wrong output) where the real script refuses — a crash NEVER counts
#     as a bite (a Python traceback is explicitly detected and rejected).
#   - mutant_renderer failures are no longer swallowed by `&&` chaining.
#   - F10 asserts the EXACT zero-marker message (not "zero-or-orphan").
#
# Checks (functional, always run):
#   F1  claude render is byte-identical to sources (cmp -s), all 3 files
#   F2  general render substitutes all 3 slot bodies and strips all markers,
#       in both SKILL.md and PROMPT-LOOP.md
#   F3  orphan   — profile declares a slot id absent from every source        -> exit 2, "orphan"
#   F4  missing  — a source marker names an id the profile lacks              -> exit 2, "missing"
#   F5  nested   — a slot:X opens while slot:X is already open (same id)      -> exit 2, "nested"
#   F6  unbalanced (unclosed) — a slot:X with no matching /slot               -> exit 2, "unclosed" or "unbalanced"
#   F7  unbalanced (stray close) — a /slot with no open slot                  -> exit 2, "unbalanced"
#   F8  free-text — profile file has non-blank content outside a slot section -> exit 2, "free text"
#   F9  unknown-profile — no research-sdd/profiles/<profile>.slots.md         -> exit 2, "unknown profile"
#   F10 anti-silent-zero — zero slot markers anywhere in sources while the
#       profile declares >=1 slot id                                          -> exit 2, EXACT "zero slot markers" message
#   F11 rendered general SKILL.md still satisfies the skill-invariants
#       anchors this suite can re-check without a path arg (A1, A10, C16,
#       C19 — skill-invariants.test.sh itself has no path/env override, so a
#       full re-invocation against the rendered copy is not possible; this is
#       a targeted anchor re-check, not a substitute for the full suite)
#   F12 existing hotcore-budget.test.sh and skill-invariants.test.sh still
#       pass against the (slot-marker-bearing) real sources
#   F13 bad argument count -> exit 2
#   F14 coherence — the general render of SKILL.md + PROMPT-LOOP.md never
#       contains a leftover claude-cadence phrase ("once per context",
#       "re-reads only")
#   F15 containment — outdir equals / is inside / contains KIT_DIR is
#       refused (exit 2) in all three directions (reproduces the reported
#       "render-profile.sh general <kitdir>" self-strip)
#   F16 profile-name format — "../profiles/general" and an uppercase name
#       are rejected before any filesystem lookup
#   F17 marker case — a near-miss-cased marker (`<!-- SLOT:x -->`) is
#       rejected loudly, not silently passed through
#   F18 empty slot body in the profile file is fatal
#   F19 METHODOLOGY.md carrying a slot-marker-shaped HTML comment is fatal,
#       even for the "claude" profile
#
# --prove-teeth mutation controls (SUT mutation, per kit CLAUDE.md §4 — a
# copy of render-profile.sh is mutated, never the input fixtures, and the
# REAL fixtures are re-run against each mutant). A tooth is proven ONLY when
# the mutant completes a render (exit 0) where the real script refuses; a
# crash (e.g. an uncaught Python traceback) is detected explicitly and NEVER
# counts as a bite. GUARD-STRAYCLOSE and GUARD-ZERO have no INDEPENDENT
# tooth — documented inline why (GUARD-STRAYCLOSE cannot be disabled without
# an unrelated crash; GUARD-ZERO is a documented strict subset of
# GUARD-ORPHAN, proven only in combination).
#
# Usage: render-profile.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test-driver SUT-locating derivation, never reached through a render (kit issue #1024 round 4)
KIT="$(cd "$TOOLBELT/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test-driver SUT-locating derivation, never reached through a render (kit issue #1024 round 4)
RENDERER="$TOOLBELT/render-profile.sh"
SKILL="$KIT/skills/research-sdd/SKILL.md"
PROMPTLOOP="$KIT/PROMPT-LOOP.md"
METHODOLOGY="$KIT/METHODOLOGY.md"
GENERAL_PROFILE="$KIT/profiles/general.slots.md"

[ -f "$RENDERER" ] || { printf 'FATAL: render-profile.sh not found at expected path: %s\n' "$RENDERER" >&2; exit 2; }
[ -x "$RENDERER" ] || { printf 'FATAL: render-profile.sh is not executable: %s\n' "$RENDERER" >&2; exit 2; }
[ -f "$SKILL" ] || { printf 'FATAL: SKILL.md not found at expected path: %s\n' "$SKILL" >&2; exit 2; }
[ -f "$PROMPTLOOP" ] || { printf 'FATAL: PROMPT-LOOP.md not found at expected path: %s\n' "$PROMPTLOOP" >&2; exit 2; }
[ -f "$METHODOLOGY" ] || { printf 'FATAL: METHODOLOGY.md not found at expected path: %s\n' "$METHODOLOGY" >&2; exit 2; }
[ -f "$GENERAL_PROFILE" ] || { printf 'FATAL: general.slots.md not found at expected path: %s\n' "$GENERAL_PROFILE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== render-profile.test.sh =="

# =============================================================================
# Fixture builders — a full mutant "kit" tree (skills/research-sdd/SKILL.md,
# PROMPT-LOOP.md, METHODOLOGY.md, profiles/<name>.slots.md) that
# render-profile.sh reads via RSDD_KIT_DIR, so every test below exercises the
# REAL renderer script unmodified — only its input sources vary.
# =============================================================================

# make_kit DIR — seeds DIR with copies of the real sources + real general
# profile, ready for per-test mutation before render-profile.sh is invoked
# with RSDD_KIT_DIR="DIR".
make_kit() {
  local dir="$1"
  mkdir -p "$dir/skills/research-sdd" "$dir/profiles"
  cp "$SKILL" "$dir/skills/research-sdd/SKILL.md"
  cp "$PROMPTLOOP" "$dir/PROMPT-LOOP.md"
  cp "$METHODOLOGY" "$dir/METHODOLOGY.md"
  cp "$GENERAL_PROFILE" "$dir/profiles/general.slots.md"
}

run_renderer() {
  local kitdir="$1" profile="$2" outdir="$3"
  shift 3
  RSDD_KIT_DIR="$kitdir" "$RENDERER" "$profile" "$outdir" "$@"
}

# =============================================================================
# F1 — claude render is byte-identical to sources.
# =============================================================================
kitF1="$TMP/kitF1"; outF1="$TMP/outF1"
make_kit "$kitF1"
if out="$(run_renderer "$kitF1" claude "$outF1" 2>&1)"; then
  ok1=1
  for rel in skills/research-sdd/SKILL.md PROMPT-LOOP.md METHODOLOGY.md; do
    cmp -s "$kitF1/$rel" "$outF1/$rel" || { ok1=0; printf '  (F1 mismatch: %s)\n' "$rel"; }
  done
  if [ "$ok1" -eq 1 ]; then
    ok "F1: claude render is byte-identical to sources (cmp -s, 3 files)"
  else
    no "F1: claude render diverged from sources"
  fi
else
  no "F1: claude render failed to run — $out"
fi

# =============================================================================
# F2 — general render substitutes all 3 slot bodies and strips all markers.
# =============================================================================
kitF2="$TMP/kitF2"; outF2="$TMP/outF2"
make_kit "$kitF2"
if out="$(run_renderer "$kitF2" general "$outF2" 2>&1)"; then
  rskill="$outF2/skills/research-sdd/SKILL.md"
  rloop="$outF2/PROMPT-LOOP.md"
  f2ok=1
  grep -qF 'read IN FULL every iteration (framing + the per-block contract)' "$rskill" || f2ok=0
  grep -qF 'Each iteration also re-reads RESEARCH-STATE, INDEX, and `--next` from the live backlog.' "$rskill" || f2ok=0
  grep -qF 'HOT-CORE (read in full now):' "$rloop" || f2ok=0
  for bad in '<!-- slot:' '<!-- /slot -->' 'once per context' 're-reads only'; do
    grep -qF "$bad" "$rskill" && f2ok=0
    grep -qF "$bad" "$rloop" && f2ok=0
  done
  if [ "$f2ok" -eq 1 ]; then
    ok "F2: general render substitutes all 3 slot bodies and strips all markers"
  else
    no "F2: general render did not substitute/strip correctly — $(grep -n 'HOT-CORE' "$rskill" "$rloop")"
  fi
else
  no "F2: general render failed to run — $out"
fi

# =============================================================================
# F3 — orphan: profile declares a slot id with no marker anywhere in sources.
# =============================================================================
kitF3="$TMP/kitF3"; outF3="$TMP/outF3"
make_kit "$kitF3"
{
  echo ""
  echo "## slot:orphan-id-never-marked"
  echo ""
  echo "unreachable body"
} >> "$kitF3/profiles/general.slots.md"
out="$(run_renderer "$kitF3" general "$outF3" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'orphan' <<<"$out"; then
  ok "F3: orphan slot id rejected (exit 2, 'orphan' in message)"
else
  no "F3: orphan slot id NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F4 — missing: a source marker names an id the profile lacks. Inserted as
# an EXTRA, standalone, well-balanced marker (not a rename of one of the 3
# real markers) so the 3 real slots stay fully matched — renaming a real
# marker's id would itself create an orphan for that real id, which the
# (unrelated, still-active) orphan guard would then catch first.
# =============================================================================
kitF4="$TMP/kitF4"; outF4="$TMP/outF4"
make_kit "$kitF4"
sed -i 's/§17 resume\./§17 resume. <!-- slot:no-such-id-in-profile -->stray<!-- \/slot -->/' "$kitF4/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF4" general "$outF4" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'missing' <<<"$out"; then
  ok "F4: missing profile slot section rejected (exit 2, 'missing' in message)"
else
  no "F4: missing profile slot section NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F5 — nested: a slot:hotcore-cadence opens twice in a row (same id), no
# close between — the second open fires while the first is still open.
# =============================================================================
kitF5="$TMP/kitF5"; outF5="$TMP/outF5"
make_kit "$kitF5"
sed -i 's/<!-- slot:hotcore-cadence -->read once per context/<!-- slot:hotcore-cadence --><!-- slot:hotcore-cadence -->read once per context/' "$kitF5/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF5" general "$outF5" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'nested' <<<"$out"; then
  ok "F5: nested slot marker rejected (exit 2, 'nested' in message)"
else
  no "F5: nested slot marker NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F6 — unbalanced (unclosed): hotcore-reread-scope's close marker is
# stripped, targeted by its unique preceding text. It is the LAST marker in
# SKILL.md's token stream, so this genuinely reaches EOF still open — unlike
# stripping hotcore-cadence's close (the FIRST marker), which would instead
# be caught by GUARD-NESTED the moment hotcore-reread-scope's own open token
# is reached (still correct behavior, just a different guard than intended).
# =============================================================================
kitF6="$TMP/kitF6"; outF6="$TMP/outF6"
make_kit "$kitF6"
sed -i 's/from the live backlog\.<!-- \/slot -->/from the live backlog./' "$kitF6/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF6" general "$outF6" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -Eqi 'unclosed|unbalanced' <<<"$out"; then
  ok "F6: unclosed slot marker rejected (exit 2, 'unclosed'/'unbalanced' in message)"
else
  no "F6: unclosed slot marker NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F7 — unbalanced (stray close): hotcore-cadence's open marker is stripped
# (targeted precisely), leaving its close marker dangling with no open.
# =============================================================================
kitF7="$TMP/kitF7"; outF7="$TMP/outF7"
make_kit "$kitF7"
sed -i 's/<!-- slot:hotcore-cadence -->read once per context/read once per context/' "$kitF7/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF7" general "$outF7" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'unbalanced' <<<"$out"; then
  ok "F7: stray /slot with no open marker rejected (exit 2, 'unbalanced' in message)"
else
  no "F7: stray /slot NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F8 — free text in the profile file outside a slot section.
# =============================================================================
kitF8="$TMP/kitF8"; outF8="$TMP/outF8"
make_kit "$kitF8"
{
  echo "stray free-text line before any slot header"
  cat "$kitF8/profiles/general.slots.md"
} > "$TMP/f8.tmp" && mv "$TMP/f8.tmp" "$kitF8/profiles/general.slots.md"
out="$(run_renderer "$kitF8" general "$outF8" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'free text' <<<"$out"; then
  ok "F8: free text outside a slot section rejected (exit 2, 'free text' in message)"
else
  no "F8: free text NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F9 — unknown profile: no research-sdd/profiles/<profile>.slots.md.
# =============================================================================
kitF9="$TMP/kitF9"; outF9="$TMP/outF9"
make_kit "$kitF9"
out="$(run_renderer "$kitF9" no-such-profile-xyz "$outF9" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'unknown profile' <<<"$out"; then
  ok "F9: unknown profile rejected (exit 2, 'unknown profile' in message)"
else
  no "F9: unknown profile NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F10 — anti-silent-zero: profile declares slots, sources carry NONE at all
# (all 3 markers stripped from both files). Asserts the EXACT zero-marker
# message (R3: the default suite must exercise that specific message, not
# just accept it OR the generic orphan message as an either/or).
# =============================================================================
kitF10="$TMP/kitF10"; outF10="$TMP/outF10"
make_kit "$kitF10"
sed -i -e 's/<!-- slot:hotcore-cadence -->//' -e 's/<!-- slot:hotcore-reread-scope -->//' -e 's/<!-- \/slot -->//' "$kitF10/skills/research-sdd/SKILL.md"
sed -i -e 's/<!-- slot:hotcore-loop-cadence -->//' -e 's/<!-- \/slot -->//' "$kitF10/PROMPT-LOOP.md"
out="$(run_renderer "$kitF10" general "$outF10" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'zero slot markers' <<<"$out"; then
  ok "F10: zero markers in sources while profile declares slots fails with the EXACT zero-marker message (exit 2)"
else
  no "F10: zero-marker case did NOT fail with the exact expected message (rc=$rc, out=[$out])"
fi

# =============================================================================
# F11 — rendered general SKILL.md still satisfies the skill-invariants
# anchors this suite can re-check directly (no path-arg support upstream).
# A1/A10 are PRESENCE checks (flag=1 when the required text IS found); C16/
# C19 are ABSENCE checks (flag=1 when the forbidden text is NOT found) — the
# asymmetry is inherent to what each invariant asserts (skill-invariants.
# test.sh's own assert_C16/assert_C19 are likewise negated greps), not an
# accidental inconsistency; each flag is still set via the same explicit
# if/then shape for readability (R2-f11-inverted-flags).
# =============================================================================
kitF11="$TMP/kitF11"; outF11="$TMP/outF11"
make_kit "$kitF11"
if run_renderer "$kitF11" general "$outF11" >/dev/null 2>&1; then
  rendered="$outF11/skills/research-sdd/SKILL.md"
  a1=0; a10=0; c16=0; c19=0
  if grep -qF 'the 7 markers' "$rendered" && ! grep -qF 'the 5 markers' "$rendered"; then a1=1; fi
  if grep -qF 'HOT-CORE' "$rendered"; then a10=1; fi
  if ! grep -qF 'an autonomous run must stop at convergence' "$rendered"; then c16=1; fi
  if ! grep -qF 'signal "continue"' "$rendered"; then c19=1; fi
  if [ "$a1" -eq 1 ] && [ "$a10" -eq 1 ] && [ "$c16" -eq 1 ] && [ "$c19" -eq 1 ]; then
    ok "F11: rendered general SKILL.md holds the re-checkable skill-invariants anchors (A1, A10, C16, C19)"
  else
    no "F11: rendered general SKILL.md FAILED an anchor re-check (A1=$a1 A10=$a10 C16=$c16 C19=$c19)"
  fi
else
  no "F11: general render failed to run, cannot check invariants"
fi

# =============================================================================
# F12 — existing suites still pass against the (marker-bearing) real sources.
# =============================================================================
if bash "$HERE/hotcore-budget.test.sh" >/dev/null 2>&1; then
  ok "F12a: hotcore-budget.test.sh still passes against the real (slotted) sources"
else
  no "F12a: hotcore-budget.test.sh REGRESSED against the real (slotted) sources"
fi
if bash "$HERE/skill-invariants.test.sh" >/dev/null 2>&1; then
  ok "F12b: skill-invariants.test.sh still passes against the real (slotted) sources"
else
  no "F12b: skill-invariants.test.sh REGRESSED against the real (slotted) sources"
fi

# =============================================================================
# F13 — bad argument count.
# =============================================================================
out="$("$RENDERER" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "F13: zero arguments rejected (exit 2)"
else
  no "F13: zero arguments NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F14 — coherence: the general render never contains a leftover
# claude-cadence phrase anywhere in SKILL.md or PROMPT-LOOP.md (round-2 HIGH
# finding: the pre-fix render said "read IN FULL every iteration" AND
# "re-reads only" AND "(read once per context)" all at once).
# =============================================================================
kitF14="$TMP/kitF14"; outF14="$TMP/outF14"
make_kit "$kitF14"
if run_renderer "$kitF14" general "$outF14" >/dev/null 2>&1; then
  f14ok=1
  for bad in 'once per context' 're-reads only'; do
    grep -qF "$bad" "$outF14/skills/research-sdd/SKILL.md" && f14ok=0
    grep -qF "$bad" "$outF14/PROMPT-LOOP.md" && f14ok=0
  done
  if [ "$f14ok" -eq 1 ]; then
    ok "F14: general render of SKILL.md + PROMPT-LOOP.md has no leftover claude-cadence phrase"
  else
    no "F14: general render still contains a leftover claude-cadence phrase — $(grep -nE 'once per context|re-reads only' "$outF14/skills/research-sdd/SKILL.md" "$outF14/PROMPT-LOOP.md")"
  fi
else
  no "F14: general render failed to run, cannot check coherence"
fi

# =============================================================================
# F15 — containment: outdir equals / is inside / contains KIT_DIR is refused
# in all three directions. Reproduces "render-profile.sh general <kitdir>"
# stripping the kit's own markers in place.
# =============================================================================
kitF15="$TMP/kitF15"
make_kit "$kitF15"
out="$(run_renderer "$kitF15" general "$kitF15" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'outdir equals the kit directory' <<<"$out"; then
  ok "F15a: outdir == KIT_DIR refused (exit 2)"
else
  no "F15a: outdir == KIT_DIR NOT refused as expected (rc=$rc, out=[$out])"
fi
out="$(run_renderer "$kitF15" general "$kitF15/rendered/nested" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'outdir is inside the kit directory' <<<"$out"; then
  ok "F15b: outdir inside KIT_DIR refused (exit 2)"
else
  no "F15b: outdir inside KIT_DIR NOT refused as expected (rc=$rc, out=[$out])"
fi
out="$(run_renderer "$kitF15" general "$(dirname "$kitF15")" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'contains the kit directory' <<<"$out"; then
  ok "F15c: outdir containing KIT_DIR refused (exit 2)"
else
  no "F15c: outdir containing KIT_DIR NOT refused as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F16 — profile-name format: rejected before any filesystem lookup.
# =============================================================================
kitF16="$TMP/kitF16"; outF16="$TMP/outF16"
make_kit "$kitF16"
out="$(run_renderer "$kitF16" "../profiles/general" "$outF16" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'invalid profile name' <<<"$out"; then
  ok "F16a: path-traversal profile name '../profiles/general' rejected (exit 2)"
else
  no "F16a: path-traversal profile name NOT rejected as expected (rc=$rc, out=[$out])"
fi
out="$(run_renderer "$kitF16" "General" "$outF16" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'invalid profile name' <<<"$out"; then
  ok "F16b: uppercase profile name 'General' rejected (exit 2)"
else
  no "F16b: uppercase profile name NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F17 — marker case: a near-miss-cased marker is rejected loudly.
# =============================================================================
kitF17="$TMP/kitF17"; outF17="$TMP/outF17"
make_kit "$kitF17"
sed -i 's/<!-- slot:hotcore-cadence -->read once per context/<!-- SLOT:extra-uppercase -->stray<!-- \/SLOT -->\n<!-- slot:hotcore-cadence -->read once per context/' "$kitF17/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF17" general "$outF17" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -Eqi 'non-canonical|case' <<<"$out"; then
  ok "F17: near-miss-cased marker rejected loudly (exit 2)"
else
  no "F17: near-miss-cased marker NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F18 — empty slot body in the profile file is fatal.
# =============================================================================
kitF18="$TMP/kitF18"; outF18="$TMP/outF18"
make_kit "$kitF18"
python3 -c "
import re
p = '$kitF18/profiles/general.slots.md'
s = open(p, encoding='utf-8').read()
s = re.sub(r'## slot:hotcore-cadence\n\nread IN FULL every iteration \(framing \+ the per-block contract\)\n', '## slot:hotcore-cadence\n\n\n', s)
open(p, 'w', encoding='utf-8').write(s)
"
out="$(run_renderer "$kitF18" general "$outF18" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'empty body' <<<"$out"; then
  ok "F18: empty slot body in the profile file is fatal (exit 2)"
else
  no "F18: empty slot body NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F19 — METHODOLOGY.md carrying a slot-marker-shaped HTML comment is fatal,
# even for the "claude" profile (the invariant is checked before branching).
# =============================================================================
kitF19="$TMP/kitF19"; outF19="$TMP/outF19"
make_kit "$kitF19"
printf '\n<!-- slot:hotcore-cadence -->stray<!-- /slot -->\n' >> "$kitF19/METHODOLOGY.md"
out="$(run_renderer "$kitF19" claude "$outF19" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'METHODOLOGY.md must never carry' <<<"$out"; then
  ok "F19a: METHODOLOGY.md with a stray slot marker rejected for 'claude' profile (exit 2)"
else
  no "F19a: METHODOLOGY.md stray marker NOT rejected for 'claude' as expected (rc=$rc, out=[$out])"
fi
out="$(run_renderer "$kitF19" general "$outF19" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'METHODOLOGY.md must never carry' <<<"$out"; then
  ok "F19b: METHODOLOGY.md with a stray slot marker rejected for 'general' profile (exit 2)"
else
  no "F19b: METHODOLOGY.md stray marker NOT rejected for 'general' as expected (rc=$rc, out=[$out])"
fi

# ===========================================================================
# --prove-teeth: SUT mutation controls (kit CLAUDE.md §4). Each mutant is a
# COPY of render-profile.sh with exactly one validation weakened via sed; the
# live script is never touched. A tooth is proven ONLY when the mutant
# completes a render (exit 0) where the real script refuses — never a crash.
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then

  # mutant_renderer NAME SED_EXPR... — copies render-profile.sh, applies the
  # sed mutation(s), returns the mutant path via stdout and rc 0. Fails
  # loudly (rc=3, prints to stderr) if the anchor text is not found, i.e.
  # the mutation did not take — callers MUST check this explicitly (never
  # `&&`-chain into bite_tooth: an `&&` short-circuit on a non-zero
  # mutant_renderer silently drops the whole tooth with no PASS/FAIL
  # recorded — R2/R3/R4-teeth-silent-skip).
  mutant_renderer() {
    local name="$1"; shift
    local m="$TMP/mutant.$name.render-profile.sh"
    cp "$RENDERER" "$m"
    local before after
    before="$(md5sum "$m" | cut -d' ' -f1)"
    sed -i "$@" "$m"
    after="$(md5sum "$m" | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
      printf 'MUTATION-DID-NOT-TAKE\n' >&2
      return 3
    fi
    chmod +x "$m"
    printf '%s\n' "$m"
  }

  # require_mutant NAME SED_EXPR... — wraps mutant_renderer so a construction
  # failure is a LOUD `no` (never a silent drop), prints the mutant path to
  # stdout on success. Callers do: `if m="$(require_mutant ...)"; then ...`.
  require_mutant() {
    local name="$1"; shift
    local m
    if m="$(mutant_renderer "$name" "$@")"; then
      printf '%s\n' "$m"
      return 0
    fi
    # Runs inside $(...): a no() here would be lost in the subshell. Report on
    # stderr and let the caller record the failure in the parent shell.
    printf 'teeth-%s: mutant_renderer could not construct the mutant (mutation anchor not found)\n' "$name" >&2
    return 1
  }

  # bite_tooth NAME MUTANT FIXTURE_KIT PROFILE OUTDIR_SUFFIX EXPECT_DESC
  # A tooth is proven ONLY when the mutant completes a render (exit 0) where
  # the real script refuses. A crash (uncaught Python traceback) is detected
  # explicitly and never counts as a bite — kit issue #943.
  bite_tooth() {
    # Optional $7 overrides the render target (T-containment must render INTO the kit itself).
    local tname="$1" mutant="$2" kitdir="$3" profile="$4" suffix="$5" expect="$6"
    local outdir="${7:-$TMP/teeth-out-$suffix}"
    local out rc
    out="$(RSDD_KIT_DIR="$kitdir" "$mutant" "$profile" "$outdir" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "teeth-$tname: mutant completes a render (exit 0) where the real script refuses ($expect) — check is load-bearing"
    elif grep -qi 'Traceback (most recent call last)' <<<"$out"; then
      no "teeth-$tname: mutant CRASHED (Python traceback) instead of rendering — not a valid bite (a crash never counts, #943)"
    else
      no "teeth-$tname: mutant still refuses (rc=$rc, out=[$out]) — no teeth"
    fi
  }

  echo "-- teeth: T-unknown-profile (disable the unknown-profile bash guard; sources carry ZERO markers so the GUARD-MISSING-PROFILE python fallback alone decides) --"
  kitTUnknown="$TMP/kitTUnknown"
  make_kit "$kitTUnknown"
  sed -i -e 's/<!-- slot:hotcore-cadence -->//' -e 's/<!-- slot:hotcore-reread-scope -->//' -e 's/<!-- \/slot -->//' "$kitTUnknown/skills/research-sdd/SKILL.md"
  sed -i -e 's/<!-- slot:hotcore-loop-cadence -->//' -e 's/<!-- \/slot -->//' "$kitTUnknown/PROMPT-LOOP.md"
  if m="$(require_mutant unknown-profile -e 's/if \[ ! -f "\$PROFILE_FILE" \]; then/if false; then/')"; then
    bite_tooth unknown-profile "$m" "$kitTUnknown" no-such-profile-xyz unknown-profile "unknown profile"
  else
    no "teeth-unknown-profile: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-orphan (disable the orphan check) --"
  if m="$(require_mutant orphan -e 's/if orphans:/if False and orphans:/')"; then
    bite_tooth orphan "$m" "$kitF3" general orphan "orphan"
  else
    no "teeth-orphan: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-missing (disable the per-marker missing check; the .get(sid, '') fallback substitutes an empty string instead of crashing) --"
  if m="$(require_mutant missing -e 's/if sid not in profile_slots:  # GUARD-MISSING/if False:  # GUARD-MISSING/')"; then
    bite_tooth missing "$m" "$kitF4" general missing "missing"
  else
    no "teeth-missing: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-nested (disable GUARD-NESTED; F5's same-id-reuse fixture means the surviving span still substitutes normally, so the mutant completes cleanly with a dangling raw marker in the output)  --"
  if m="$(require_mutant nested -e 's/if open_tok is not None:  # GUARD-NESTED/if False:  # GUARD-NESTED/')"; then
    bite_tooth nested "$m" "$kitF5" general nested "nested"
  else
    no "teeth-nested: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-unclosed (disable GUARD-UNCLOSED; a DEDICATED fixture with an undeclared, non-interfering dangling marker so no other guard backstops it) --"
  kitTUnclosed="$TMP/kitTUnclosed"
  make_kit "$kitTUnclosed"
  # Inserted AFTER hotcore-reread-scope's complete (open+close) span — the
  # LAST marker in SKILL.md's token stream — so the dangling open genuinely
  # reaches EOF still open, instead of a SUBSEQUENT real marker's open
  # tripping GUARD-NESTED first (which is what happens if the unclosed
  # fragment is inserted BEFORE another marker in the same file).
  sed -i 's/from the live backlog\.<!-- \/slot -->/from the live backlog.<!-- \/slot --> <!-- slot:leftover-fragment -->this text is permanently unclosed/' "$kitTUnclosed/skills/research-sdd/SKILL.md"
  if m="$(require_mutant unclosed -e 's/if open_tok is not None:  # GUARD-UNCLOSED/if False:  # GUARD-UNCLOSED/')"; then
    bite_tooth unclosed "$m" "$kitTUnclosed" general unclosed "unclosed"
  else
    no "teeth-unclosed: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-zero-and-orphan (GUARD-ZERO is a documented strict SUBSET of GUARD-ORPHAN — see render-profile.sh — so it can only be proven by disabling BOTH together as one unit; disabling GUARD-ZERO alone still refuses via the outer orphan branch) --"
  if m="$(require_mutant zero-and-orphan -e 's/if orphans:  # GUARD-ORPHAN/if False:  # GUARD-ORPHAN/' -e "s/if not encountered:  # GUARD-ZERO (documented subset of GUARD-ORPHAN, see above)/if False:  # GUARD-ZERO/")"; then
    bite_tooth zero-and-orphan "$m" "$kitF10" general zero "zero slot markers / orphan"
  else
    no "teeth-zero-and-orphan: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-freetext (disable the free-text guard) --"
  if m="$(require_mutant freetext -e "s/if line.strip() != '':  # GUARD-FREETEXT/if False:  # GUARD-FREETEXT/")"; then
    bite_tooth freetext "$m" "$kitF8" general freetext "free text"
  else
    no "teeth-freetext: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-emptybody (disable GUARD-EMPTYBODY) --"
  if m="$(require_mutant emptybody -e 's/if not body.strip():  # GUARD-EMPTYBODY/if False:  # GUARD-EMPTYBODY/')"; then
    bite_tooth emptybody "$m" "$kitF18" general emptybody "empty body"
  else
    no "teeth-emptybody: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-markercase (disable GUARD-MARKERCASE) --"
  if m="$(require_mutant markercase -e 's/if not TOKEN_RE.fullmatch(span_text):  # GUARD-MARKERCASE/if False:  # GUARD-MARKERCASE/')"; then
    bite_tooth markercase "$m" "$kitF17" general markercase "non-canonical marker"
  else
    no "teeth-markercase: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-containment (disable ONLY the outdir==KIT_DIR guard; the mutant then reproduces the ORIGINAL reported bug — rendering into, and stripping the markers of, the kit's own directory) --"
  if m="$(require_mutant containment -e 's/if \[ "\$OUTDIR_REAL" = "\$KIT_REAL" \]; then/if false; then/')"; then
    bite_tooth containment "$m" "$kitF15" general containment "outdir equals the kit directory" "$kitF15"
  else
    no "teeth-containment: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-profilename (disable the profile-name regex guard; '../profiles/general' then resolves, via plain path concatenation, to the SAME real general.slots.md the honest 'general' name would) --"
  kitTProfileName="$TMP/kitTProfileName"
  make_kit "$kitTProfileName"
  if m="$(require_mutant profilename -e "s/if ! \[\[ \"\\\$PROFILE\" =~ \^\[a-z0-9_-\]+\\\$ \]\]; then/if false; then/")"; then
    bite_tooth profilename "$m" "$kitTProfileName" "../profiles/general" profilename "invalid profile name"
  else
    no "teeth-profilename: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-methodology-invariant (disable the METHODOLOGY.md-never-carries-slots bash guard; the marker then gets substituted like any other source) --"
  kitTMeth="$TMP/kitTMeth"
  make_kit "$kitTMeth"
  printf '\n<!-- slot:hotcore-cadence -->stray<!-- /slot -->\n' >> "$kitTMeth/METHODOLOGY.md"
  if m="$(require_mutant methodology -e 's|^if grep -qiE .*METH_SRC.*; then$|if false; then|')"; then
    bite_tooth methodology "$m" "$kitTMeth" general methodology "METHODOLOGY.md must never carry"
  else
    no "teeth-methodology: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-subst (positive control: break the substitution itself) --"
  m="$(mutant_renderer subst -e "s/out.append(body)/out.append('MUTATED-NOT-SUBSTITUTED')/")"
  if [ -n "$m" ]; then
    outdir="$TMP/teeth-out-subst"
    if RSDD_KIT_DIR="$kitF2" "$m" general "$outdir" >/dev/null 2>&1; then
      rendered="$outdir/skills/research-sdd/SKILL.md"
      if grep -qF 'MUTATED-NOT-SUBSTITUTED' "$rendered" && ! grep -qF 'read IN FULL every iteration' "$rendered"; then
        ok "teeth-subst: mutant renders the mutated body, not the real slot body — F2's assertion would catch this"
      else
        no "teeth-subst: mutant did not visibly diverge — no teeth"
      fi
    else
      no "teeth-subst: mutant failed to run (expected exit 0 with wrong output, not a refusal) — cannot prove this positive control"
    fi
  else
    no "teeth-subst: mutant_renderer could not construct the mutant (mutation anchor not found) — cannot prove teeth"
  fi

  # No independent tooth for GUARD-STRAYCLOSE: disabling it alone makes the
  # very next line (`ostart, sid, _oend = open_tok`) unpack `None`, which is
  # an unconditional Python crash regardless of fixture — the exact
  # never-a-bite case this suite is designed to reject (#943). F7 above
  # already proves the real script refuses a stray close; that is the
  # complete coverage this guard gets.

  # TOOTH SYMLINK-TOOLBELT (kit issue #1024 round 4, SYSTEMIC — found via the new
  # verify-cd-physical.sh lint, same bug class as verify-skill-drift.sh/verify-registry.sh/
  # research-sdd-init.sh above it in this round). HERE/KIT_DIR used to be derived via plain
  # (logical) cd/pwd; invoked through a render dir's symlinked toolbelt/ (kit issue #993 WU2 +
  # #1024 F1's completion symlinks), KIT_DIR collapsed onto the render dir itself instead of the
  # real kit root. A fully SYNTHETIC mini-kit (mktemp -d) — never the real toolbelt/ — with a
  # single whole-directory symlink render/profile/general/toolbelt -> mini/toolbelt (the real F1
  # shape). GREEN (fixed SUT, invoked through the symlink): renders cleanly into the render dir.
  # RED (mutant, -P reverted on both hops): KIT_DIR collapses onto the render dir; since the
  # render dir IS ALSO the render outdir argument here, render-profile.sh's OWN F15 containment
  # guard is the first thing to catch the wrong KIT_DIR — "outdir equals the kit directory" — a
  # different message than verify-skill-drift.sh's "zero slot markers", but the SAME root cause,
  # and the one this exact isolated invocation shape genuinely produces (measured, not assumed).
  echo "-- teeth SYMLINK-TOOLBELT: revert -P on HERE/KIT_DIR, invoke directly through a symlinked toolbelt/ --"
  MINI_SYM="$TMP/mini-symlink-toolbelt"
  mkdir -p "$MINI_SYM/mini/toolbelt" "$MINI_SYM/mini/profiles" "$MINI_SYM/mini/skills/research-sdd" \
    "$MINI_SYM/render/profile/general"
  cp "$RENDERER" "$MINI_SYM/mini/toolbelt/render-profile.sh"
  chmod +x "$MINI_SYM/mini/toolbelt/render-profile.sh"
  cp "$GENERAL_PROFILE" "$MINI_SYM/mini/profiles/general.slots.md"
  cp "$SKILL" "$MINI_SYM/mini/skills/research-sdd/SKILL.md"
  cp "$PROMPTLOOP" "$MINI_SYM/mini/PROMPT-LOOP.md"
  cp "$METHODOLOGY" "$MINI_SYM/mini/METHODOLOGY.md"
  ln -s "$MINI_SYM/mini/toolbelt" "$MINI_SYM/render/profile/general/toolbelt"

  GREEN_SYM_OUT="$(bash "$MINI_SYM/render/profile/general/toolbelt/render-profile.sh" general \
    "$MINI_SYM/render/profile/general" 2>&1)"; GREEN_SYM_RC=$?
  if [ "$GREEN_SYM_RC" -eq 0 ]; then
    ok "SYMLINK-TOOLBELT: fixed render-profile.sh, invoked through a symlinked toolbelt/, renders cleanly"
  else
    no "SYMLINK-TOOLBELT: fixed render-profile.sh failed through a symlinked toolbelt/ (rc=$GREEN_SYM_RC out=[$GREEN_SYM_OUT])"
  fi

  MUT_SYM_RPS="$TMP/render-profile-mut-sym.sh"
  sed -e 's/HERE="\$(cd -P "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd -P)"/HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" \&\& pwd)"/' \
      -e 's/KIT_DIR="\${RSDD_KIT_DIR:-\$(cd -P "\$HERE\/\.\." \&\& pwd -P)}"/KIT_DIR="${RSDD_KIT_DIR:-$(cd "$HERE\/.." \&\& pwd)}"/' \
      "$RENDERER" > "$MUT_SYM_RPS"
  chmod +x "$MUT_SYM_RPS"
  if diff -q "$RENDERER" "$MUT_SYM_RPS" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: mutant = SUT — -P pattern not found (did the fix change shape?)"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: mutant differs (-P reverted on both hops)"
  fi
  cp "$MUT_SYM_RPS" "$MINI_SYM/mini/toolbelt/render-profile.sh"
  chmod +x "$MINI_SYM/mini/toolbelt/render-profile.sh"
  MUT_SYM_OUT="$(bash "$MINI_SYM/render/profile/general/toolbelt/render-profile.sh" general \
    "$MINI_SYM/render/profile/general" 2>&1)"; MUT_SYM_RC=$?
  if [ "$MUT_SYM_RC" -eq 2 ] && printf '%s' "$MUT_SYM_OUT" | grep -qi 'outdir equals the kit directory'; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant re-breaks through a symlinked toolbelt/ (outdir-equals-kit refusal, rc=2) → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant did not re-break — -P fix check is THEATER (rc=$MUT_SYM_RC out=[$MUT_SYM_OUT])"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
