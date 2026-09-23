#!/usr/bin/env bash
# skill-invariants.test.sh — Drift guard for research-sdd/skills/research-sdd/SKILL.md
#
# skill-twin-parity.test.sh was deleted with OpenCode (#954) because its sole purpose
# was to check the OpenCode SKILL.md twin. The invariants it enforced on the shared
# content (A1-A11 below) were the ONLY guards on the main SKILL.md itself. This suite
# reinstates them, targeting the main SKILL.md directly.
#
# Invariants guarded:
#   A1  "the 7 markers" present (§3 section label); "the 5 markers" absent (stale claim)
#   A2  Key terms glossary table present ('| **corpus**' row)
#   A3  Quick-mode carve-out in triage bullet (CARVE-OUT intent wins)
#   A4  UNLESS clause in 'Target vs ad-hoc' paragraph
#   A5  REMOTE follow-up / ensure-remote.sh block present
#   A6  document-mode §20 example (TradingView retro reference anchor)
#   A7  TOOL-BEFORE-AGENT binary reference (detect-tools.sh)
#   A8  Walls & evidence block (blocked-on-tool typed state)
#   A10 Two-tier METHODOLOGY reading: HOT-CORE label present
#   A11 Tool-catalog alias guidance: 'alias:' + 'kaitai-struct-compiler' (#364 drift class)
#
# Usage: skill-invariants.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../../skills/research-sdd/SKILL.md"
[ -f "$SKILL" ] || { printf 'FATAL: SKILL.md not found at expected path: %s\n' "$SKILL" >&2; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== skill-invariants.test.sh =="

# ---------------------------------------------------------------------------
# A1: SKILL.md must say "the 7 markers" (CERT-hw, CERT-live, CERT, CERT-doc,
#     CERT-web, CERT-a, INFER) and must NOT say "the 5 markers" (stale).
# ---------------------------------------------------------------------------
if grep -qF 'the 7 markers' "$SKILL"; then
  ok "A1: SKILL.md says 'the 7 markers'"
else
  no "A1: SKILL.md does NOT say 'the 7 markers'"
fi

if grep -qF 'the 5 markers' "$SKILL"; then
  no "A1-neg: SKILL.md still contains false claim 'the 5 markers'"
else
  ok "A1-neg: 'the 5 markers' absent (false claim removed)"
fi

# ---------------------------------------------------------------------------
# A2: Key terms glossary table must be present.
#     Stable anchor: the '| **corpus**' header row.
# ---------------------------------------------------------------------------
if grep -qF '| **corpus**' "$SKILL"; then
  ok "A2: Key terms glossary table present ('| **corpus**' row found)"
else
  no "A2: Key terms glossary table missing (no '| **corpus**' row)"
fi

# ---------------------------------------------------------------------------
# A3: Quick-mode carve-out in the TRIAGE bullet — registered target resolves
#     to HEAVY *unless* request is a scoped factual question (intent wins).
# ---------------------------------------------------------------------------
if grep -qF 'CARVE-OUT (intent wins)' "$SKILL"; then
  ok "A3: quick-mode carve-out (CARVE-OUT intent wins) present in triage"
else
  no "A3: quick-mode carve-out missing from triage bullet"
fi

# ---------------------------------------------------------------------------
# A4: UNLESS clause in 'Target vs ad-hoc / live-install' paragraph.
# ---------------------------------------------------------------------------
if grep -qF 'UNLESS the request is a scoped factual question' "$SKILL"; then
  ok "A4: UNLESS clause present in 'Target vs ad-hoc' paragraph"
else
  no "A4: UNLESS clause missing from 'Target vs ad-hoc' paragraph"
fi

# ---------------------------------------------------------------------------
# A5: REMOTE follow-up / ensure-remote.sh consent-gated block.
# ---------------------------------------------------------------------------
if grep -qF 'ensure-remote.sh' "$SKILL"; then
  ok "A5: REMOTE follow-up / ensure-remote.sh block present"
else
  no "A5: REMOTE follow-up / ensure-remote.sh block missing"
fi

# ---------------------------------------------------------------------------
# A6: document-mode §20 example (TradingView new-target DOCUMENT run).
#     Stable anchor: the retro filename 'document-unregistered-bootstrap-incident'.
# ---------------------------------------------------------------------------
if grep -qF 'document-unregistered-bootstrap-incident' "$SKILL"; then
  ok "A6: document-mode §20 example (TradingView retro reference) present"
else
  no "A6: document-mode §20 example missing (§20 text truncated)"
fi

# ---------------------------------------------------------------------------
# A7: TOOL-BEFORE-AGENT binary line — detect-tools.sh as first move for
#     binary artifacts.
# ---------------------------------------------------------------------------
if grep -qF 'detect-tools.sh' "$SKILL"; then
  ok "A7: TOOL-BEFORE-AGENT binary reference (detect-tools.sh) present"
else
  no "A7: TOOL-BEFORE-AGENT binary reference missing (detect-tools.sh absent)"
fi

# ---------------------------------------------------------------------------
# A8: Walls & evidence block — SKILL.md must carry the typed wall-state
#     doctrine (blocked-on-tool) so the launcher surfaces METHODOLOGY §21.
# ---------------------------------------------------------------------------
if grep -qF 'blocked-on-tool' "$SKILL"; then
  ok "A8: Walls & evidence block (blocked-on-tool typed state) present"
else
  no "A8: Walls & evidence block missing (blocked-on-tool absent)"
fi

# ---------------------------------------------------------------------------
# A10: Two-tier METHODOLOGY reading — SKILL.md must carry the HOT-CORE
#      label so the lazy-load instruction is auditable without full-file read.
# ---------------------------------------------------------------------------
if grep -qF 'HOT-CORE' "$SKILL"; then
  ok "A10: HOT-CORE two-tier reading instruction present in SKILL.md"
else
  no "A10: HOT-CORE two-tier reading instruction MISSING from SKILL.md"
fi

# ---------------------------------------------------------------------------
# A11: SKILL.md must carry the tool-catalog alias guidance — the convention
#      for when the logged name and the catalog display name differ entirely
#      (e.g. kaitai-struct-compiler logged, ksc displayed).
#      Stable anchors: 'alias:' and 'kaitai-struct-compiler'.
#      Guards the #364 drift class.
# ---------------------------------------------------------------------------
if grep -qF 'alias:' "$SKILL" && grep -qF 'kaitai-struct-compiler' "$SKILL"; then
  ok "A11: alias guidance (alias: + kaitai-struct-compiler) present in SKILL.md"
else
  no "A11: alias guidance missing from SKILL.md (ksc/kaitai-struct-compiler drift)"
fi

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL: prove each assertion has teeth
# ---------------------------------------------------------------------------
if [ "$PROVE_TEETH" = 1 ]; then
  echo "-- teeth: sed mutants of SKILL.md copy; each affected assertion must go RED --"

  # Teeth A1: remove 'the 7 markers' → A1 positive check must go RED.
  mutant1="$TMP/SKILL.mutant1.md"
  sed 's/the 7 markers/the N markers/g' "$SKILL" > "$mutant1"
  if grep -qF 'the 7 markers' "$mutant1"; then
    no "teeth-A1: mutant still has 'the 7 markers' — sed did not take (no teeth)"
  else
    ok "teeth-A1: A1 assertion goes RED on mutant"
  fi

  # Teeth A1-neg: inject 'the 5 markers' → A1-neg check must go RED.
  mutant1n="$TMP/SKILL.mutant1n.md"
  sed 's/the 7 markers/the 5 markers/g' "$SKILL" > "$mutant1n"
  if grep -qF 'the 5 markers' "$mutant1n"; then
    ok "teeth-A1-neg: A1-neg assertion goes RED on mutant ('the 5 markers' injected)"
  else
    no "teeth-A1-neg: mutant does NOT have 'the 5 markers' — sed did not take (no teeth)"
  fi

  # Teeth A10: remove 'HOT-CORE' → A10 must go RED.
  mutant10="$TMP/SKILL.mutant10.md"
  sed 's/HOT-CORE/HOT_CORE_REMOVED/g' "$SKILL" > "$mutant10"
  if grep -qF 'HOT-CORE' "$mutant10"; then
    no "teeth-A10: mutant still has 'HOT-CORE' — sed did not take (no teeth)"
  else
    ok "teeth-A10: A10 assertion goes RED on mutant"
  fi

  # Teeth A11: replace 'kaitai-struct-compiler' → A11 must go RED.
  mutant11="$TMP/SKILL.mutant11.md"
  sed 's/kaitai-struct-compiler/ksc-binary/g' "$SKILL" > "$mutant11"
  if grep -qF 'kaitai-struct-compiler' "$mutant11"; then
    no "teeth-A11: mutant still has 'kaitai-struct-compiler' — sed did not take (no teeth)"
  else
    ok "teeth-A11: A11 assertion goes RED on mutant"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
