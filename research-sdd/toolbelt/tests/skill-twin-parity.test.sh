#!/usr/bin/env bash
# skill-twin-parity.test.sh — Drift guard for research-sdd/toolbelt/opencode/SKILL.md
#
# Asserts invariants that must be present in the OpenCode twin's SHARED region.
# NOT a byte-identical diff — legitimate adapter substitutions (research-sweep-*,
# research-loop.sh instead of /loop) are expected to differ and are NOT tested here.
#
# Invariants guarded (A1-A11):
#   A1  "the 7 markers" present; "the 5 markers" absent (false claim)
#   A2  Key terms glossary table present ('| **corpus**' row)
#   A3  Quick-mode carve-out in triage bullet (CARVE-OUT intent wins)
#   A4  UNLESS clause in 'Target vs ad-hoc' paragraph
#   A5  REMOTE follow-up / ensure-remote.sh block present
#   A6  document-mode §20 example (TradingView retro reference)
#   A7  TOOL-BEFORE-AGENT binary reference (detect-tools.sh)
#   A10 Two-tier METHODOLOGY reading: HOT-CORE present in both SKILLs
#   A11 Tool-catalog alias guidance present in both SKILLs (alias: + kaitai-struct-compiler)
#
# Usage: skill-twin-parity.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWIN="$HERE/../opencode/SKILL.md"
[ -f "$TWIN" ] || { printf 'FATAL: OpenCode twin SKILL.md not found: %s\n' "$TWIN" >&2; exit 2; }
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== skill-twin-parity.test.sh =="

# ---------------------------------------------------------------------------
# A1: twin must say "the 7 markers" (CERT-hw, CERT-live, CERT, CERT-doc,
#     CERT-web, CERT-a, INFER) and must NOT say "the 5 markers" (stale).
# ---------------------------------------------------------------------------
if grep -qF 'the 7 markers' "$TWIN"; then
  ok "A1: twin says 'the 7 markers'"
else
  no "A1: twin does NOT say 'the 7 markers'"
fi

if grep -qF 'the 5 markers' "$TWIN"; then
  no "A1-neg: twin still contains false claim 'the 5 markers'"
else
  ok "A1-neg: 'the 5 markers' absent (false claim removed)"
fi

# ---------------------------------------------------------------------------
# A2: Key terms glossary table must be present.
#     Stable anchor: the '| **corpus**' header row.
# ---------------------------------------------------------------------------
if grep -qF '| **corpus**' "$TWIN"; then
  ok "A2: Key terms glossary table present ('| **corpus**' row found)"
else
  no "A2: Key terms glossary table missing (no '| **corpus**' row)"
fi

# ---------------------------------------------------------------------------
# A3: Quick-mode carve-out in the TRIAGE bullet — registered target resolves
#     to HEAVY *unless* request is a scoped factual question (intent wins).
# ---------------------------------------------------------------------------
if grep -qF 'CARVE-OUT (intent wins)' "$TWIN"; then
  ok "A3: quick-mode carve-out (CARVE-OUT intent wins) present in triage"
else
  no "A3: quick-mode carve-out missing from triage bullet"
fi

# ---------------------------------------------------------------------------
# A4: UNLESS clause in 'Target vs ad-hoc / live-install' paragraph.
# ---------------------------------------------------------------------------
if grep -qF 'UNLESS the request is a scoped factual question' "$TWIN"; then
  ok "A4: UNLESS clause present in 'Target vs ad-hoc' paragraph"
else
  no "A4: UNLESS clause missing from 'Target vs ad-hoc' paragraph"
fi

# ---------------------------------------------------------------------------
# A5: REMOTE follow-up / ensure-remote.sh consent-gated block.
# ---------------------------------------------------------------------------
if grep -qF 'ensure-remote.sh' "$TWIN"; then
  ok "A5: REMOTE follow-up / ensure-remote.sh block present"
else
  no "A5: REMOTE follow-up / ensure-remote.sh block missing"
fi

# ---------------------------------------------------------------------------
# A6: document-mode §20 example (TradingView new-target DOCUMENT run).
#     Stable anchor: the retro filename 'document-unregistered-bootstrap-incident'.
# ---------------------------------------------------------------------------
if grep -qF 'document-unregistered-bootstrap-incident' "$TWIN"; then
  ok "A6: document-mode §20 example (TradingView retro reference) present"
else
  no "A6: document-mode §20 example missing (§20 text truncated)"
fi

# ---------------------------------------------------------------------------
# A7: TOOL-BEFORE-AGENT binary line — detect-tools.sh as first move for
#     binary artifacts (shared step 4, not just the adapter tooling notes).
# ---------------------------------------------------------------------------
if grep -qF 'detect-tools.sh' "$TWIN"; then
  ok "A7: TOOL-BEFORE-AGENT binary reference (detect-tools.sh) present"
else
  no "A7: TOOL-BEFORE-AGENT binary reference missing (detect-tools.sh absent)"
fi

# ---------------------------------------------------------------------------
# A8: Walls & evidence block — twin must carry the typed wall-state doctrine
#     (blocked-on-tool) so the launcher surfaces METHODOLOGY §21, kept in sync
#     with the main SKILL.md by the twin-sync convention.
# ---------------------------------------------------------------------------
if grep -qF 'blocked-on-tool' "$TWIN"; then
  ok "A8: Walls & evidence block (blocked-on-tool typed state) present"
else
  no "A8: Walls & evidence block missing (blocked-on-tool absent)"
fi

# ---------------------------------------------------------------------------
# A9: step-0 fast-path — twin must carry the injected Kit path: fast-path
#     anchor so the harness can resolve the kit O(1) from the launcher block
#     without a per-user hardcoded absolute.  Stable anchor: 'Kit path:'.
# ---------------------------------------------------------------------------
if grep -qF 'Kit path:' "$TWIN"; then
  ok "A9: step-0 Kit path: fast-path anchor present in twin"
else
  no "A9: step-0 Kit path: fast-path anchor MISSING from twin"
fi

# ---------------------------------------------------------------------------
# A10: Two-tier METHODOLOGY reading — both SKILLs must carry the HOT-CORE
#      label so the lazy-load instruction is auditable without full-file read.
#      Stable anchor: 'HOT-CORE'.
# ---------------------------------------------------------------------------
MAIN="$HERE/../../skills/research-sdd/SKILL.md"
if [ ! -f "$MAIN" ]; then
  no "A10: main SKILL.md not found at expected path: $MAIN"
elif grep -qF 'HOT-CORE' "$TWIN" && grep -qF 'HOT-CORE' "$MAIN"; then
  ok "A10: HOT-CORE two-tier reading instruction present in both SKILL.md files"
else
  no "A10: HOT-CORE two-tier reading instruction MISSING from one or both SKILL.md files"
fi

# ---------------------------------------------------------------------------
# A11: Both SKILLs must carry the tool-catalog alias guidance — the convention
#      for when the logged name and the catalog display name differ entirely
#      (e.g. kaitai-struct-compiler logged, ksc displayed).
#      Stable anchors: 'alias:' and 'kaitai-struct-compiler' (the ksc example).
#      Guards the #364 drift class: a twin that loses this guidance fails A11.
# ---------------------------------------------------------------------------
MAIN="$HERE/../../skills/research-sdd/SKILL.md"
if [ ! -f "$MAIN" ]; then
  no "A11: main SKILL.md not found at expected path: $MAIN"
elif grep -qF 'alias:' "$TWIN" && grep -qF 'kaitai-struct-compiler' "$TWIN" \
  && grep -qF 'alias:' "$MAIN" && grep -qF 'kaitai-struct-compiler' "$MAIN"; then
  ok "A11: alias guidance (alias: + kaitai-struct-compiler) present in both SKILL.md files"
else
  no "A11: alias guidance missing from one or both SKILL.md files (ksc/kaitai-struct-compiler drift)"
fi

# ---------------------------------------------------------------------------
# --prove-teeth: mutate the A1 invariant ("the 7 markers" → "the 5 markers")
# in a COPY of the twin (never the live file).  The A1 positive assertion must
# go RED; the A1-neg assertion must go RED.  Both teeth-controls must report ok.
# ---------------------------------------------------------------------------
if [ "$PROVE_TEETH" = "1" ]; then
  echo "-- prove-teeth: mutant reverts 'the 7 markers' to 'the 5 markers' --"
  mutant="$TMP/SKILL.mutant.md"
  sed 's/the 7 markers/the 5 markers/g' "$TWIN" > "$mutant"

  # A1 positive check must go RED on mutant ('the 7 markers' now absent)
  if grep -qF 'the 7 markers' "$mutant"; then
    no "teeth-A1: mutant still has 'the 7 markers' — sed did not take (no teeth)"
  else
    ok "teeth-A1: A1 assertion goes RED on mutant (teeth confirmed)"
  fi

  # A1-neg check must go RED on mutant ('the 5 markers' now present)
  if grep -qF 'the 5 markers' "$mutant"; then
    ok "teeth-A1-neg: A1-neg assertion goes RED on mutant (teeth confirmed)"
  else
    no "teeth-A1-neg: mutant does NOT have 'the 5 markers' — sed did not take (no teeth)"
  fi

  # A9 mutation: replace 'Kit path:' with 'Kit-path:' so the anchor disappears.
  # A9's grep -qF 'Kit path:' must go RED — if it stays green the assertion has no teeth.
  echo "-- prove-teeth: mutant removes 'Kit path:' anchor (A9 fast-path check) --"
  mutant9="$TMP/SKILL.mutant9.md"
  sed 's/Kit path:/Kit-path:/g' "$TWIN" > "$mutant9"
  if grep -qF 'Kit path:' "$mutant9"; then
    no "teeth-A9: mutant still has 'Kit path:' — sed did not take (no teeth)"
  else
    ok "teeth-A9: A9 assertion goes RED on mutant (teeth confirmed)"
  fi

  # A10 mutation: remove 'HOT-CORE' from a COPY of the twin so the anchor disappears.
  # A10's grep must go RED on the mutant — if it stays green the assertion has no teeth.
  echo "-- prove-teeth: mutant removes 'HOT-CORE' anchor (A10 tiered-reading check) --"
  mutant10="$TMP/SKILL.mutant10.md"
  sed 's/HOT-CORE/HOT_CORE_REMOVED/g' "$TWIN" > "$mutant10"
  if grep -qF 'HOT-CORE' "$mutant10"; then
    no "teeth-A10: mutant still has 'HOT-CORE' — sed did not take (no teeth)"
  else
    ok "teeth-A10: A10 assertion goes RED on mutant (teeth confirmed)"
  fi

  # A11 mutation: replace 'kaitai-struct-compiler' with 'ksc-binary' in a COPY of the twin.
  # A11's grep must go RED on the mutant — if it stays green the assertion has no teeth.
  echo "-- prove-teeth: mutant removes 'kaitai-struct-compiler' anchor (A11 alias-guidance check) --"
  mutant11="$TMP/SKILL.mutant11.md"
  sed 's/kaitai-struct-compiler/ksc-binary/g' "$TWIN" > "$mutant11"
  if grep -qF 'kaitai-struct-compiler' "$mutant11"; then
    no "teeth-A11: mutant still has 'kaitai-struct-compiler' — sed did not take (no teeth)"
  else
    ok "teeth-A11: A11 assertion goes RED on mutant (teeth confirmed)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
