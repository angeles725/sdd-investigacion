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
PROMPTLOOP="$HERE/../../PROMPT-LOOP.md"
[ -f "$PROMPTLOOP" ] || { printf 'FATAL: PROMPT-LOOP.md not found at expected path: %s\n' "$PROMPTLOOP" >&2; exit 2; }

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
# A12: SKILL.md must reference 'propose-never-apply' — confirms the REUSABLE
#      TOOLCHAIN routing and tool-cataloging paragraph both enforce the rule
#      that kit changes are proposed (not applied) from inside a run (#960).
# ---------------------------------------------------------------------------
if grep -qF 'propose-never-apply' "$SKILL"; then
  ok "A12: propose-never-apply rule referenced in SKILL.md (#960)"
else
  no "A12: propose-never-apply rule MISSING from SKILL.md (#960)"
fi

# ---------------------------------------------------------------------------
# A13: SKILL.md must recommend dynamic (no interval) as the default unattended
#      launch, with fixed-interval as fallback (cadence decision, #961).
#      Anchor: 'Dynamic is recommended for unattended runs' in Execution mode.
# ---------------------------------------------------------------------------
if grep -qF 'Dynamic is recommended for unattended runs' "$SKILL"; then
  ok "A13: SKILL.md recommends dynamic (no interval) as default launch mode (#961)"
else
  no "A13: SKILL.md missing dynamic-recommended statement in Execution mode (#961)"
fi

# ---------------------------------------------------------------------------
# A14: SKILL.md must NOT contain 'guarantees the cadence' — that claim is
#      false when /loop is used without an interval (#961).
# ---------------------------------------------------------------------------
if grep -qF 'guarantees the cadence' "$SKILL"; then
  no "A14: SKILL.md still contains false claim 'guarantees the cadence' (#961)"
else
  ok "A14: false claim 'guarantees the cadence' absent from SKILL.md (#961)"
fi

# ---------------------------------------------------------------------------
# A15: SKILL.md must contain 're-invoker is already active' — the detection
#      rule that prevents nested /loop launches (#961).
# ---------------------------------------------------------------------------
if grep -qF 're-invoker is already active' "$SKILL"; then
  ok "A15: re-invoker detection rule present in SKILL.md (#961)"
else
  no "A15: re-invoker detection rule MISSING from SKILL.md (#961)"
fi

# ---------------------------------------------------------------------------
# B1: PROMPT-LOOP.md launch section must show dynamic (no interval) as the
#     recommended form. Anchor: '/loop  <paste' — two spaces between '/loop'
#     and '<paste', no '10m' in between (cadence decision, #961).
# ---------------------------------------------------------------------------
if grep -qF '/loop  <paste' "$PROMPTLOOP"; then
  ok "B1: PROMPT-LOOP.md launch section shows dynamic (no interval) as recommended (#961)"
else
  no "B1: PROMPT-LOOP.md launch section missing dynamic (no interval) example (#961)"
fi

# ---------------------------------------------------------------------------
# B2: PROMPT-LOOP.md LOOP CONTINUATION fixed-interval case must carry the
#     behavioral prohibition "Do NOT issue ScheduleWakeup" — stronger than a
#     bare token check; proves the double-fire rule is stated, not just named.
# ---------------------------------------------------------------------------
if grep -qF 'Do NOT issue ScheduleWakeup' "$PROMPTLOOP"; then
  ok "B2: PROMPT-LOOP.md LOOP CONTINUATION carries ScheduleWakeup prohibition"
else
  no "B2: PROMPT-LOOP.md LOOP CONTINUATION missing 'Do NOT issue ScheduleWakeup'"
fi

# ---------------------------------------------------------------------------
# B3: PROMPT-LOOP.md LOOP CONTINUATION must carry the fixed-interval teardown
#     rule: when STOP fires the agent must disarm the re-invoker (CronDelete in
#     Claude Code, or explicit operator instruction). Without this the harness
#     cron keeps re-firing every <N>m after STOP — a token drain.
#     Stable anchor: 'CronDelete' (the specific Claude Code disarm tool).
# ---------------------------------------------------------------------------
if grep -qF 'CronDelete' "$PROMPTLOOP"; then
  ok "B3: PROMPT-LOOP.md LOOP CONTINUATION carries fixed-interval teardown rule (CronDelete)"
else
  no "B3: PROMPT-LOOP.md LOOP CONTINUATION missing teardown rule (CronDelete absent)"
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

  # Teeth A12: remove 'propose-never-apply' → A12 must go RED.
  mutant12="$TMP/SKILL.mutant12.md"
  sed 's/propose-never-apply/propose-never-xpply/g' "$SKILL" > "$mutant12"
  if grep -qF 'propose-never-apply' "$mutant12"; then
    no "teeth-A12: mutant still has 'propose-never-apply' — sed did not take (no teeth)"
  else
    ok "teeth-A12: A12 assertion goes RED on mutant"
  fi

  # Teeth A13: replace 'Dynamic is recommended' → A13 must go RED.
  mutant13="$TMP/SKILL.mutant13.md"
  sed 's/Dynamic is recommended for unattended runs/Fixed-interval is recommended for unattended runs/g' "$SKILL" > "$mutant13"
  if grep -qF 'Dynamic is recommended for unattended runs' "$mutant13"; then
    no "teeth-A13: mutant still has 'Dynamic is recommended for unattended runs' — sed did not take (no teeth)"
  else
    ok "teeth-A13: A13 assertion goes RED on mutant"
  fi

  # Teeth A14: inject 'guarantees the cadence' → A14 negative check must go RED.
  mutant14="$TMP/SKILL.mutant14.md"
  sed '1s|^|/loop guarantees the cadence\n|' "$SKILL" > "$mutant14"
  if grep -qF 'guarantees the cadence' "$mutant14"; then
    ok "teeth-A14: A14 negative check goes RED on mutant ('guarantees' injected)"
  else
    no "teeth-A14: mutant does NOT have 'guarantees the cadence' — sed did not take (no teeth)"
  fi

  # Teeth A15: replace 're-invoker is already active' → A15 must go RED.
  mutant15="$TMP/SKILL.mutant15.md"
  sed 's/re-invoker is already active/re-invoker X already active/g' "$SKILL" > "$mutant15"
  if grep -qF 're-invoker is already active' "$mutant15"; then
    no "teeth-A15: mutant still has 're-invoker is already active' — sed did not take (no teeth)"
  else
    ok "teeth-A15: A15 assertion goes RED on mutant"
  fi

  # Teeth B1: remove the dynamic launch form → B1 must go RED.
  #            Replace '/loop  <paste' (two spaces) with '/loopNOINT <paste' so
  #            the anchor string is absent from the mutant.
  mutantB1="$TMP/PROMPTLOOP.mutantB1.md"
  sed 's|/loop  <paste|/loopNOINT <paste|g' "$PROMPTLOOP" > "$mutantB1"
  if grep -qF '/loop  <paste' "$mutantB1"; then
    no "teeth-B1: mutant still has '/loop  <paste' — sed did not take (no teeth)"
  else
    ok "teeth-B1: B1 assertion goes RED on mutant"
  fi

  # Teeth B2: replace 'Do NOT issue ScheduleWakeup' → B2 must go RED.
  mutantB2="$TMP/PROMPTLOOP.mutantB2.md"
  sed 's/Do NOT issue ScheduleWakeup/Do NOT use ScheduleWakeup_REMOVED/g' "$PROMPTLOOP" > "$mutantB2"
  if grep -qF 'Do NOT issue ScheduleWakeup' "$mutantB2"; then
    no "teeth-B2: mutant still has 'Do NOT issue ScheduleWakeup' — sed did not take (no teeth)"
  else
    ok "teeth-B2: B2 assertion goes RED on mutant"
  fi

  # Teeth B3: replace 'CronDelete' → B3 must go RED.
  mutantB3="$TMP/PROMPTLOOP.mutantB3.md"
  sed 's/CronDelete/DisarmJob/g' "$PROMPTLOOP" > "$mutantB3"
  if grep -qF 'CronDelete' "$mutantB3"; then
    no "teeth-B3: mutant still has 'CronDelete' — sed did not take (no teeth)"
  else
    ok "teeth-B3: B3 assertion goes RED on mutant"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
