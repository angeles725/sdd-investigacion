#!/usr/bin/env bash
# render-profile.test.sh — behavior + mutation-control suite for render-profile.sh
# (kit issue #993, WU1: install-time slot rendering, no runtime indirection).
#
# render-profile.sh <profile> <outdir> renders the shared doctrine sources
# (SKILL.md, PROMPT-LOOP.md, METHODOLOGY.md) for one model-family profile:
#   - profile "claude": sources copied byte-identical (markers remain — they
#     are HTML comments, invisible to readers).
#   - any other profile (e.g. "general"): every `<!-- slot:<id> -->...
#     <!-- /slot -->` span is replaced by that id's body from
#     research-sdd/profiles/<profile>.slots.md, and the marker comments are
#     stripped from the rendered output.
#
# Checks (functional, always run):
#   F1  claude render is byte-identical to sources (cmp -s), all 3 files
#   F2  general render substitutes the slot body and strips the markers
#   F3  orphan   — profile declares a slot id absent from every source        -> exit 2, "orphan"
#   F4  missing  — a source marker names an id the profile lacks              -> exit 2, "missing"
#   F5  nested   — a slot:X opens while slot:Y is already open                -> exit 2, "nested"
#   F6  unbalanced (unclosed) — a slot:X with no matching /slot               -> exit 2, "unclosed" or "unbalanced"
#   F7  unbalanced (stray close) — a /slot with no open slot                  -> exit 2, "unbalanced"
#   F8  free-text — profile file has non-blank content outside a slot section -> exit 2, "free text"
#   F9  unknown-profile — no research-sdd/profiles/<profile>.slots.md         -> exit 2, "unknown profile"
#   F10 anti-silent-zero — zero slot markers anywhere in sources while the
#       profile declares >=1 slot id                                          -> exit 2, loud (never a silent no-op)
#   F11 rendered general SKILL.md still satisfies the skill-invariants
#       anchors this suite can re-check without a path arg (A1, A10, C16,
#       C19 — skill-invariants.test.sh itself has no path/env override, so a
#       full re-invocation against the rendered copy is not possible; this is
#       a targeted anchor re-check, not a substitute for the full suite)
#   F12 existing hotcore-budget.test.sh and skill-invariants.test.sh still
#       pass against the (slot-marker-bearing) real sources
#   F13 bad argument count -> exit 2
#
# --prove-teeth mutation controls (SUT mutation, per kit CLAUDE.md §4 — a
# copy of render-profile.sh is mutated, never the input fixtures, and the
# REAL fixtures from F3-F10 are re-run against each mutant): each mutant
# disables exactly one validation and must diverge from the real script's
# contract (different exit code and/or missing the expected FATAL message) —
# "bite for the right reason", not a crash misread as a pass. One positive
# control (T-subst) mutates the substitution step itself and must break F2.
#
# Usage: render-profile.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
KIT="$(cd "$TOOLBELT/.." && pwd)"
RENDERER="$TOOLBELT/render-profile.sh"
SKILL="$KIT/skills/research-sdd/SKILL.md"
PROMPTLOOP="$KIT/PROMPT-LOOP.md"
METHODOLOGY="$KIT/METHODOLOGY.md"
GENERAL_PROFILE="$KIT/profiles/general.slots.md"

[ -f "$RENDERER" ] || { printf 'FATAL: render-profile.sh not found at expected path: %s\n' "$RENDERER" >&2; exit 2; }
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
# F2 — general render substitutes the slot body and strips the markers.
# =============================================================================
kitF2="$TMP/kitF2"; outF2="$TMP/outF2"
make_kit "$kitF2"
if out="$(run_renderer "$kitF2" general "$outF2" 2>&1)"; then
  rendered="$outF2/skills/research-sdd/SKILL.md"
  if grep -qF 'read IN FULL every iteration (framing + the per-block contract)' "$rendered" \
     && ! grep -qF 'read once per context' "$rendered" \
     && ! grep -qF '<!-- slot:hotcore-cadence -->' "$rendered" \
     && ! grep -qF '<!-- /slot -->' "$rendered"; then
    ok "F2: general render substitutes hotcore-cadence body and strips markers"
  else
    no "F2: general render did not substitute/strip correctly — $(grep -n 'HOT-CORE —' "$rendered")"
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
# F4 — missing: a source marker names an id the profile lacks.
# =============================================================================
kitF4="$TMP/kitF4"; outF4="$TMP/outF4"
make_kit "$kitF4"
sed -i 's/<!-- slot:hotcore-cadence -->/<!-- slot:no-such-id-in-profile -->/' "$kitF4/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF4" general "$outF4" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'missing' <<<"$out"; then
  ok "F4: missing profile slot section rejected (exit 2, 'missing' in message)"
else
  no "F4: missing profile slot section NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F5 — nested: a slot:X opens while slot:Y is already open.
# =============================================================================
kitF5="$TMP/kitF5"; outF5="$TMP/outF5"
make_kit "$kitF5"
sed -i 's/<!-- slot:hotcore-cadence -->read once per context/<!-- slot:hotcore-cadence --><!-- slot:double-open -->read once per context/' "$kitF5/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF5" general "$outF5" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'nested' <<<"$out"; then
  ok "F5: nested slot marker rejected (exit 2, 'nested' in message)"
else
  no "F5: nested slot marker NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F6 — unbalanced (unclosed): a slot:X with no matching /slot anywhere after it.
# =============================================================================
kitF6="$TMP/kitF6"; outF6="$TMP/outF6"
make_kit "$kitF6"
sed -i 's/<!-- \/slot -->//' "$kitF6/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF6" general "$outF6" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -Eqi 'unclosed|unbalanced' <<<"$out"; then
  ok "F6: unclosed slot marker rejected (exit 2, 'unclosed'/'unbalanced' in message)"
else
  no "F6: unclosed slot marker NOT rejected as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F7 — unbalanced (stray close): a /slot with no open slot.
# =============================================================================
kitF7="$TMP/kitF7"; outF7="$TMP/outF7"
make_kit "$kitF7"
sed -i 's/<!-- slot:hotcore-cadence -->//' "$kitF7/skills/research-sdd/SKILL.md"
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
# F10 — anti-silent-zero: profile declares slots, sources carry NONE at all.
# =============================================================================
kitF10="$TMP/kitF10"; outF10="$TMP/outF10"
make_kit "$kitF10"
sed -i -e 's/<!-- slot:hotcore-cadence -->//' -e 's/<!-- \/slot -->//' "$kitF10/skills/research-sdd/SKILL.md"
out="$(run_renderer "$kitF10" general "$outF10" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -Eqi 'zero slot markers|orphan' <<<"$out"; then
  ok "F10: zero markers in sources while profile declares slots is rejected loudly (exit 2)"
else
  no "F10: zero-marker case did NOT fail loudly as expected (rc=$rc, out=[$out])"
fi

# =============================================================================
# F11 — rendered general SKILL.md still satisfies the skill-invariants
# anchors this suite can re-check directly (no path-arg support upstream).
# =============================================================================
kitF11="$TMP/kitF11"; outF11="$TMP/outF11"
make_kit "$kitF11"
if run_renderer "$kitF11" general "$outF11" >/dev/null 2>&1; then
  rendered="$outF11/skills/research-sdd/SKILL.md"
  a1=0; a10=0; c16=0; c19=0
  grep -qF 'the 7 markers' "$rendered" && ! grep -qF 'the 5 markers' "$rendered" && a1=1
  grep -qF 'HOT-CORE' "$rendered" && a10=1
  grep -qF 'an autonomous run must stop at convergence' "$rendered" || c16=1
  grep -qF 'signal "continue"' "$rendered" || c19=1
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

# ===========================================================================
# --prove-teeth: SUT mutation controls (kit CLAUDE.md §4). Each mutant is a
# COPY of render-profile.sh with exactly one validation weakened via sed; the
# live script is never touched. Re-runs the SAME fixtures from F3-F10 against
# the mutant and requires it to DIVERGE from the real script's contract.
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then

  # mutant_renderer NAME SED_EXPR... — copies render-profile.sh, applies the
  # sed mutation(s), returns the mutant path via stdout. Fails loudly (rc=3)
  # if the anchor text is not found (mutation did not take).
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

  # bite_tooth NAME MUTANT FIXTURE_KIT PROFILE OUTDIR_SUFFIX EXPECT_GREP
  # Runs MUTANT against the real fixture kit; a tooth is proven when the
  # mutant's observable contract (exit code + message) diverges from what F3-
  # F10 required of the real script — i.e. EXPECT_GREP (the real script's
  # required substring) is now ABSENT, or exit code is no longer 2.
  bite_tooth() {
    local tname="$1" mutant="$2" kitdir="$3" profile="$4" suffix="$5" expect="$6"
    local outdir="$TMP/teeth-out-$suffix"
    local out rc
    out="$(RSDD_KIT_DIR="$kitdir" "$mutant" "$profile" "$outdir" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ] && grep -qi "$expect" <<<"$out"; then
      no "teeth-$tname: mutant still enforces the check (rc=2, matched '$expect') — no teeth"
    else
      ok "teeth-$tname: mutant diverges from the real contract (rc=$rc, out=[$out]) — check is load-bearing"
    fi
  }

  echo "-- teeth: T-unknown-profile (disable the unknown-profile guard's condition) --"
  m="$(mutant_renderer unknown-profile -e 's/if \[ ! -f "\$PROFILE_FILE" \]; then/if false; then/')" && \
    bite_tooth unknown-profile "$m" "$kitF9" no-such-profile-xyz unknown-profile 'unknown profile'

  echo "-- teeth: T-orphan (disable the orphan check in the embedded python) --"
  m="$(mutant_renderer orphan -e "s/if orphans:/if False and orphans:/")" && \
    bite_tooth orphan "$m" "$kitF3" general orphan 'orphan'

  echo "-- teeth: T-missing (disable the per-marker missing check) --"
  m="$(mutant_renderer missing -e "s/if sid not in profile_slots:/if False:/")" && \
    bite_tooth missing "$m" "$kitF4" general missing 'missing'

  echo "-- teeth: T-nested (disable the nested-marker guard, GUARD-NESTED only) --"
  m="$(mutant_renderer nested -e "s/if open_tok is not None:  # GUARD-NESTED/if False:  # GUARD-NESTED/")" && \
    bite_tooth nested "$m" "$kitF5" general nested 'nested'

  echo "-- teeth: T-unclosed (disable the unclosed-marker guard, GUARD-UNCLOSED only) --"
  m="$(mutant_renderer unclosed -e "s/if open_tok is not None:  # GUARD-UNCLOSED/if False:  # GUARD-UNCLOSED/")" && \
    bite_tooth unclosed "$m" "$kitF6" general unclosed 'unclosed'

  echo "-- teeth: T-freetext (disable the free-text guard) --"
  m="$(mutant_renderer freetext -e "s/if line.strip() != '':/if False:/")" && \
    bite_tooth freetext "$m" "$kitF8" general freetext 'free text'

  echo "-- teeth: T-subst (positive control: break the substitution itself) --"
  m="$(mutant_renderer subst -e "s/out.append(profile_slots\[sid\])/out.append('MUTATED-NOT-SUBSTITUTED')/")"
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
      ok "teeth-subst: mutant failed to run at all — diverges from the real script's success contract"
    fi
  fi

  echo "-- teeth: T-zero (disable the zero-markers loud-failure path) --"
  m="$(mutant_renderer zero -e "s/if not encountered:/if False:/")" && \
    bite_tooth zero "$m" "$kitF10" general zero 'zero slot markers'

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
