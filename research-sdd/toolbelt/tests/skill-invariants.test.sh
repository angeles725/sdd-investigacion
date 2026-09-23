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
# A12a: SKILL.md REUSABLE TOOLCHAIN routing text must carry propose-never-apply.
#       Anchor: 'never applied from inside a run (§18 propose-never-apply)'
#       — unique to the toolchain routing paragraph (#960).
# ---------------------------------------------------------------------------
if grep -qF 'never applied from inside a run (§18 propose-never-apply)' "$SKILL"; then
  ok "A12a: SKILL.md toolchain routing carries propose-never-apply (#960)"
else
  no "A12a: SKILL.md toolchain routing missing propose-never-apply (#960)"
fi

# ---------------------------------------------------------------------------
# A12b: SKILL.md tool-cataloging paragraph must carry propose-never-apply.
#       Anchor: 'propose-never-apply). Provisioning is complete'
#       — unique to the tool-cataloging paragraph (#960).
# ---------------------------------------------------------------------------
if grep -qF 'propose-never-apply). Provisioning is complete' "$SKILL"; then
  ok "A12b: SKILL.md tool-cataloging carries propose-never-apply (#960)"
else
  no "A12b: SKILL.md tool-cataloging missing propose-never-apply (#960)"
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
# B1: PROMPT-LOOP.md launch section must label the no-interval form as
#     recommended ("dynamic self-paced, no interval") AND show "/loop 5m" as
#     the concrete fallback example. Both must be present. RED against
#     origin/main (which has "self-paces" + "/loop 10m", not "dynamic" + "5m").
# ---------------------------------------------------------------------------
if grep -qF 'dynamic self-paced, no interval' "$PROMPTLOOP" && \
   grep -qF '/loop 5m  <paste' "$PROMPTLOOP"; then
  ok "B1: PROMPT-LOOP.md launch section labels no-interval as recommended and /loop 5m as fallback (#961)"
else
  no "B1: PROMPT-LOOP.md launch section missing dynamic-recommended label or /loop 5m fallback (#961)"
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

METHODOLOGY="$HERE/../../METHODOLOGY.md"
[ -f "$METHODOLOGY" ] || { printf 'FATAL: METHODOLOGY.md not found at expected path: %s\n' "$METHODOLOGY" >&2; exit 2; }

# ---------------------------------------------------------------------------
# C1: METHODOLOGY.md must state that a focus stop does not end the campaign.
#     The campaign model (§8c) adds the distinction: a focus STOP fires the
#     FRONTIER-REOPEN audit and pops the next queue entry; campaign STOP is
#     a separate condition. Stable anchor: 'A focus stop does not end the campaign'
# ---------------------------------------------------------------------------
if grep -qF 'A focus stop does not end the campaign' "$METHODOLOGY"; then
  ok "C1: METHODOLOGY §8c states focus stop ≠ campaign stop"
else
  no "C1: METHODOLOGY §8c missing focus-stop ≠ campaign-stop distinction"
fi

# ---------------------------------------------------------------------------
# C2: METHODOLOGY.md must use the precise campaign-STOP wording:
#     no entry is `pending` or `active` (terminal states done/bound-stopped).
#     Stable anchor: 'no entry is `pending` or `active`'
# ---------------------------------------------------------------------------
if grep -qF 'no entry is `pending` or `active`' "$METHODOLOGY"; then
  ok "C2: METHODOLOGY §8c carries precise campaign-STOP wording (no pending/active entries)"
else
  no "C2: METHODOLOGY §8c missing precise campaign-STOP wording (no pending/active entries)"
fi

# ---------------------------------------------------------------------------
# C3: METHODOLOGY.md must carry the typed bound-stop token 'campaign-bound-reached:'
#     so declared bounds (max depth, budget) emit a recognisable typed stop
#     rather than a silent exit.
# ---------------------------------------------------------------------------
if grep -qF 'campaign-bound-reached:' "$METHODOLOGY"; then
  ok "C3: METHODOLOGY §8c carries typed bound-stop token 'campaign-bound-reached:'"
else
  no "C3: METHODOLOGY §8c missing typed bound-stop token 'campaign-bound-reached:'"
fi

# ---------------------------------------------------------------------------
# C4: PROMPT-LOOP.md must state that teardown runs at campaign STOP, not at
#     each focus stop. Stable anchor: 'Teardown runs at campaign STOP'
# ---------------------------------------------------------------------------
if grep -qF 'Teardown runs at campaign STOP' "$PROMPTLOOP"; then
  ok "C4: PROMPT-LOOP.md states teardown at campaign STOP (not focus stop)"
else
  no "C4: PROMPT-LOOP.md missing 'Teardown runs at campaign STOP'"
fi

# ---------------------------------------------------------------------------
# C5: METHODOLOGY.md §8c must carry the closed `campaign_bounds:` declaration
#     syntax so the instrument can parse declared bounds without prose parsing.
#     Stable anchor: 'campaign_bounds:'
# ---------------------------------------------------------------------------
if grep -qF 'campaign_bounds:' "$METHODOLOGY"; then
  ok "C5: METHODOLOGY §8c carries 'campaign_bounds:' declaration syntax"
else
  no "C5: METHODOLOGY §8c missing 'campaign_bounds:' declaration syntax"
fi

# ---------------------------------------------------------------------------
# C6: METHODOLOGY.md §8c must define depth as the length of the parent chain
#     from root (root entry = depth 0) so the instrument can evaluate
#     max-depth bounds without ambiguity.
#     Stable anchor: 'depth is the length of the parent chain from root'
# ---------------------------------------------------------------------------
if grep -qF 'depth is the length of the parent chain from root' "$METHODOLOGY"; then
  ok "C6: METHODOLOGY §8c defines depth (parent-chain length from root)"
else
  no "C6: METHODOLOGY §8c missing depth definition"
fi

# ---------------------------------------------------------------------------
# C7: METHODOLOGY.md §8c must state where the bound stop is recorded:
#     the entry's State becomes 'bound-stopped' AND a 'campaign_stop:' line
#     is written in RESEARCH-STATE so the instrument can distinguish a bound
#     stop from a missing stop.
#     Stable anchor: 'campaign_stop: campaign-bound-reached:'
# ---------------------------------------------------------------------------
if grep -qF 'campaign_stop: campaign-bound-reached:' "$METHODOLOGY"; then
  ok "C7: METHODOLOGY §8c carries recording location for bound stop (campaign_stop: line)"
else
  no "C7: METHODOLOGY §8c missing recording location for bound stop"
fi

# ---------------------------------------------------------------------------
# C8: METHODOLOGY.md §8c must carry the 'last_audit:' field so resume and
#     the instrument can distinguish campaign STOP (audit ran, enqueued=0)
#     from "not yet audited" (field absent or never written).
#     Stable anchor: 'last_audit:'
# ---------------------------------------------------------------------------
if grep -qF 'last_audit:' "$METHODOLOGY"; then
  ok "C8: METHODOLOGY §8c carries 'last_audit:' field for resume/instrument"
else
  no "C8: METHODOLOGY §8c missing 'last_audit:' field"
fi

# ---------------------------------------------------------------------------
# C9: PROMPT-LOOP RETURN CONTRACT must define the continuation-token format
#     and the rule that a return without either token is a silently stopped
#     iteration. SKILL.md must point there. Stable anchor: 'halted-but-silent stop'
# ---------------------------------------------------------------------------
if grep -qF 'halted-but-silent stop' "$PROMPTLOOP"; then
  ok "C9: PROMPT-LOOP RETURN CONTRACT carries continuation-token guard ('halted-but-silent stop')"
else
  no "C9: PROMPT-LOOP RETURN CONTRACT missing continuation-token guard"
fi

# ---------------------------------------------------------------------------
# C10: METHODOLOGY §8c must state that resume first continues an entry left
#      `active` (an interrupted focus) before popping the next `pending` entry.
#      Without this rule, a resumed campaign skips an in-progress focus.
#      Stable anchor: 'first continue any entry left `active`'
# ---------------------------------------------------------------------------
if grep -qF 'first continue any entry left `active`' "$METHODOLOGY"; then
  ok "C10: METHODOLOGY §8c states resume continues active entry first"
else
  no "C10: METHODOLOGY §8c missing resume-active-first rule"
fi

# ---------------------------------------------------------------------------
# C11: METHODOLOGY §8c must carry `campaign_started:` and `campaign_iterations:`
#      persisted counters so iteration-count and wall-clock bounds survive
#      compaction, resume, and sub-agent handoffs.
# ---------------------------------------------------------------------------
if grep -qF 'campaign_started:' "$METHODOLOGY" && grep -qF 'campaign_iterations:' "$METHODOLOGY"; then
  ok "C11: METHODOLOGY §8c carries persisted bound counters (campaign_started + campaign_iterations)"
else
  no "C11: METHODOLOGY §8c missing persisted bound counters (campaign_started / campaign_iterations)"
fi

# ---------------------------------------------------------------------------
# C12: METHODOLOGY §8c must state that single-focus corpora (no Campaign queue
#      section) still carry `last_iteration_ts` as the stall-detection signal.
#      Stable anchor: 'Single-focus corpora'
# ---------------------------------------------------------------------------
if grep -qF 'Single-focus corpora' "$METHODOLOGY"; then
  ok "C12: METHODOLOGY §8c states last_iteration_ts applies to single-focus corpora"
else
  no "C12: METHODOLOGY §8c missing single-focus last_iteration_ts statement"
fi

# ---------------------------------------------------------------------------
# C14: SKILL.md mode table must say 'CronList → CronDelete' (not just
#      'CronDelete then disarm') — the operator-fallback clause is required so
#      the rule works when no CronList is available.
#      Stable anchor: 'CronList → CronDelete'
# ---------------------------------------------------------------------------
if grep -qF 'CronList → CronDelete' "$SKILL"; then
  ok "C14: SKILL.md mode table carries 'CronList → CronDelete' disarm wording"
else
  no "C14: SKILL.md mode table missing 'CronList → CronDelete' disarm wording"
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

  # Teeth A12a: remove propose-never-apply from toolchain routing only → A12a RED, A12b stays GREEN.
  mutant12a="$TMP/SKILL.mutant12a.md"
  sed 's/never applied from inside a run (§18 propose-never-apply)/never applied from inside a run/g' "$SKILL" > "$mutant12a"
  if grep -qF 'never applied from inside a run (§18 propose-never-apply)' "$mutant12a"; then
    no "teeth-A12a: mutant still has toolchain-routing propose-never-apply — sed did not take (no teeth)"
  else
    ok "teeth-A12a: A12a assertion goes RED on mutant (toolchain routing mutation)"
  fi

  # Teeth A12b: remove propose-never-apply from tool-cataloging only → A12b RED, A12a stays GREEN.
  mutant12b="$TMP/SKILL.mutant12b.md"
  sed 's/propose-never-apply). Provisioning is complete/propose-never-XPPLY). Provisioning is complete/g' "$SKILL" > "$mutant12b"
  if grep -qF 'propose-never-apply). Provisioning is complete' "$mutant12b"; then
    no "teeth-A12b: mutant still has tool-cataloging propose-never-apply — sed did not take (no teeth)"
  else
    ok "teeth-A12b: A12b assertion goes RED on mutant (tool-cataloging mutation)"
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

  # Teeth B1a: remove 'dynamic self-paced, no interval' → B1 must go RED (first condition fails).
  mutantB1a="$TMP/PROMPTLOOP.mutantB1a.md"
  sed 's/dynamic self-paced, no interval/dynamic, no interval/g' "$PROMPTLOOP" > "$mutantB1a"
  if grep -qF 'dynamic self-paced, no interval' "$mutantB1a"; then
    no "teeth-B1a: mutant still has 'dynamic self-paced, no interval' — sed did not take (no teeth)"
  else
    ok "teeth-B1a: B1 assertion goes RED on mutant (dynamic-label removed)"
  fi

  # Teeth B1b: remove '/loop 5m  <paste' → B1 must go RED (second condition fails).
  mutantB1b="$TMP/PROMPTLOOP.mutantB1b.md"
  sed 's|/loop 5m  <paste|/loop-5m <paste|g' "$PROMPTLOOP" > "$mutantB1b"
  if grep -qF '/loop 5m  <paste' "$mutantB1b"; then
    no "teeth-B1b: mutant still has '/loop 5m  <paste' — sed did not take (no teeth)"
  else
    ok "teeth-B1b: B1 assertion goes RED on mutant (5m fallback removed)"
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

  echo "-- teeth: METHODOLOGY.md mutants for campaign assertions C1-C3 --"

  # Teeth C1: replace anchor → C1 must go RED.
  mutantC1="$TMP/METHODOLOGY.mutantC1.md"
  sed 's/A focus stop does not end the campaign/A focus stop DOES end the campaign/g' "$METHODOLOGY" > "$mutantC1"
  if grep -qF 'A focus stop does not end the campaign' "$mutantC1"; then
    no "teeth-C1: mutant still has C1 anchor — sed did not take (no teeth)"
  else
    ok "teeth-C1: C1 assertion goes RED on mutant"
  fi

  # Teeth C2: replace 'no entry is `pending` or `active`' anchor → C2 must go RED.
  mutantC2="$TMP/METHODOLOGY.mutantC2.md"
  sed 's/no entry is `pending` or `active`/no entry is pending or active/g' "$METHODOLOGY" > "$mutantC2"
  if grep -qF 'no entry is `pending` or `active`' "$mutantC2"; then
    no "teeth-C2: mutant still has C2 anchor — sed did not take (no teeth)"
  else
    ok "teeth-C2: C2 assertion goes RED on mutant"
  fi

  # Teeth C3: replace 'campaign-bound-reached:' → C3 must go RED.
  mutantC3="$TMP/METHODOLOGY.mutantC3.md"
  sed 's/campaign-bound-reached:/campaign-bound-X:/g' "$METHODOLOGY" > "$mutantC3"
  if grep -qF 'campaign-bound-reached:' "$mutantC3"; then
    no "teeth-C3: mutant still has 'campaign-bound-reached:' — sed did not take (no teeth)"
  else
    ok "teeth-C3: C3 assertion goes RED on mutant"
  fi

  # Teeth C4: replace 'Teardown runs at campaign STOP' → C4 must go RED.
  mutantC4="$TMP/PROMPTLOOP.mutantC4.md"
  sed 's/Teardown runs at campaign STOP/Teardown runs at focus STOP/g' "$PROMPTLOOP" > "$mutantC4"
  if grep -qF 'Teardown runs at campaign STOP' "$mutantC4"; then
    no "teeth-C4: mutant still has 'Teardown runs at campaign STOP' — sed did not take (no teeth)"
  else
    ok "teeth-C4: C4 assertion goes RED on mutant"
  fi

  echo "-- teeth: METHODOLOGY.md mutants for bounds assertions C5-C8 --"

  # Teeth C5: replace 'campaign_bounds:' → C5 must go RED.
  mutantC5="$TMP/METHODOLOGY.mutantC5.md"
  sed 's/campaign_bounds:/campaign_BOUNDS_X:/g' "$METHODOLOGY" > "$mutantC5"
  if grep -qF 'campaign_bounds:' "$mutantC5"; then
    no "teeth-C5: mutant still has 'campaign_bounds:' — sed did not take (no teeth)"
  else
    ok "teeth-C5: C5 assertion goes RED on mutant"
  fi

  # Teeth C6: replace depth anchor → C6 must go RED.
  mutantC6="$TMP/METHODOLOGY.mutantC6.md"
  sed 's/depth is the length of the parent chain from root/depth is unspecified/g' "$METHODOLOGY" > "$mutantC6"
  if grep -qF 'depth is the length of the parent chain from root' "$mutantC6"; then
    no "teeth-C6: mutant still has C6 anchor — sed did not take (no teeth)"
  else
    ok "teeth-C6: C6 assertion goes RED on mutant"
  fi

  # Teeth C7: replace 'campaign_stop: campaign-bound-reached:' → C7 must go RED.
  mutantC7="$TMP/METHODOLOGY.mutantC7.md"
  sed 's/campaign_stop: campaign-bound-reached:/campaign_stop: bound-reached:/g' "$METHODOLOGY" > "$mutantC7"
  if grep -qF 'campaign_stop: campaign-bound-reached:' "$mutantC7"; then
    no "teeth-C7: mutant still has C7 anchor — sed did not take (no teeth)"
  else
    ok "teeth-C7: C7 assertion goes RED on mutant"
  fi

  # Teeth C8: replace 'last_audit:' → C8 must go RED.
  mutantC8="$TMP/METHODOLOGY.mutantC8.md"
  sed 's/last_audit:/last_AUDIT_X:/g' "$METHODOLOGY" > "$mutantC8"
  if grep -qF 'last_audit:' "$mutantC8"; then
    no "teeth-C8: mutant still has 'last_audit:' — sed did not take (no teeth)"
  else
    ok "teeth-C8: C8 assertion goes RED on mutant"
  fi

  echo "-- teeth: PROMPT-LOOP + METHODOLOGY + SKILL mutants for C9-C14 --"

  # Teeth C9: replace 'halted-but-silent stop' → C9 must go RED.
  mutantC9="$TMP/PROMPTLOOP.mutantC9.md"
  sed 's/halted-but-silent stop/halted-silently/g' "$PROMPTLOOP" > "$mutantC9"
  if grep -qF 'halted-but-silent stop' "$mutantC9"; then
    no "teeth-C9: mutant still has 'halted-but-silent stop' — sed did not take (no teeth)"
  else
    ok "teeth-C9: C9 assertion goes RED on mutant"
  fi

  # Teeth C10: replace resume anchor → C10 must go RED.
  mutantC10="$TMP/METHODOLOGY.mutantC10.md"
  sed 's/first continue any entry left `active`/first pop the next `pending` entry/g' "$METHODOLOGY" > "$mutantC10"
  if grep -qF 'first continue any entry left `active`' "$mutantC10"; then
    no "teeth-C10: mutant still has C10 anchor — sed did not take (no teeth)"
  else
    ok "teeth-C10: C10 assertion goes RED on mutant"
  fi

  # Teeth C11a: replace 'campaign_started:' → C11 must go RED (first condition fails).
  mutantC11a="$TMP/METHODOLOGY.mutantC11a.md"
  sed 's/campaign_started:/campaign_STARTED_X:/g' "$METHODOLOGY" > "$mutantC11a"
  if grep -qF 'campaign_started:' "$mutantC11a"; then
    no "teeth-C11a: mutant still has 'campaign_started:' — sed did not take (no teeth)"
  else
    ok "teeth-C11a: C11 assertion goes RED on mutant (campaign_started removed)"
  fi

  # Teeth C11b: replace 'campaign_iterations:' → C11 must go RED (second condition fails).
  mutantC11b="$TMP/METHODOLOGY.mutantC11b.md"
  sed 's/campaign_iterations:/campaign_ITERATIONS_X:/g' "$METHODOLOGY" > "$mutantC11b"
  if grep -qF 'campaign_iterations:' "$mutantC11b"; then
    no "teeth-C11b: mutant still has 'campaign_iterations:' — sed did not take (no teeth)"
  else
    ok "teeth-C11b: C11 assertion goes RED on mutant (campaign_iterations removed)"
  fi

  # Teeth C12: replace 'Single-focus corpora' → C12 must go RED.
  mutantC12="$TMP/METHODOLOGY.mutantC12.md"
  sed 's/Single-focus corpora/Multi-focus corpora/g' "$METHODOLOGY" > "$mutantC12"
  if grep -qF 'Single-focus corpora' "$mutantC12"; then
    no "teeth-C12: mutant still has 'Single-focus corpora' — sed did not take (no teeth)"
  else
    ok "teeth-C12: C12 assertion goes RED on mutant"
  fi

  # Teeth C14: replace 'CronList → CronDelete' in SKILL → C14 must go RED.
  mutantC14="$TMP/SKILL.mutantC14.md"
  sed 's/CronList → CronDelete/CronDelete directly/g' "$SKILL" > "$mutantC14"
  if grep -qF 'CronList → CronDelete' "$mutantC14"; then
    no "teeth-C14: mutant still has 'CronList → CronDelete' — sed did not take (no teeth)"
  else
    ok "teeth-C14: C14 assertion goes RED on mutant"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
