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
#   A12 propose-never-apply appears in both toolchain routing and tool cataloging
#   A13 Dynamic is recommended for unattended runs (not fixed-interval)
#   A14 /loop does NOT claim to guarantee cadence (absent)
#   A15 Re-invoker check before launch ('re-invoker is already active')
#   B1  LOOP CONTINUATION names both 'dynamic self-paced, no interval' and '/loop 5m' fallback
#   B2  Fixed-interval mode does not issue ScheduleWakeup ('Do NOT issue ScheduleWakeup')
#   B3  Fixed-interval teardown references CronDelete
#   C1  METHODOLOGY §8c states focus stop ≠ campaign stop
#   C2  METHODOLOGY §8c carries precise campaign-STOP wording (no pending/active entries)
#   C3  METHODOLOGY §8c carries typed bound-stop token 'campaign-bound-reached:'
#   C4  PROMPT-LOOP LOOP CONTINUATION states teardown runs at campaign STOP
#   C5  METHODOLOGY §8c carries grammar code block for campaign_bounds (full line shape)
#   C6  METHODOLOGY §8c defines depth as parent-chain length from root
#   C7  METHODOLOGY §8c names recording location for bound stop (campaign_stop: line)
#   C8  METHODOLOGY §8c carries last_audit: field with full grammar shape
#   C9  PROMPT-LOOP RETURN CONTRACT carries 'next-entry: <queue-name>' campaign token
#   C10 METHODOLOGY §8c states resume continues active entry first
#   C11 METHODOLOGY §8c carries persisted bound counters (campaign_started + campaign_iterations)
#   C12 METHODOLOGY §8c states last_iteration_ts applies to single-focus corpora
#   C13 METHODOLOGY §8c carries 'rejected' terminal state (focus-distinctness failures)
#   C14 SKILL.md mode table carries 'do not ask which mode' (B5: mode announce rule)
#   C15 PROMPT-LOOP says 'A RUN ends only on campaign STOP' (RUN vs TURN distinction)
#   C16 PROMPT-LOOP does NOT say 'an autonomous run must stop at convergence' (absent/stale)
#   C17 PROMPT-LOOP does NOT say 'A turn ends only on campaign STOP' (absent/stale)
#   C18 PROMPT-LOOP RETURN CONTRACT carries 'STOP: campaign — ' token (presence)
#   C19 PROMPT-LOOP does NOT say 'signal "continue"' in orchestrated context (absent/stale)
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
# C-assertion function library: each assert_Cn takes one file path and returns
# 0 (pass) when the invariant holds, 1 (fail) otherwise. Teeth call the
# function on a mutant copy — the mutation must make the function return 1.
# ---------------------------------------------------------------------------
assert_C1()  { grep -qF 'A focus stop does not end the campaign' "$1"; }
assert_C2()  { grep -qF 'no entry is `pending` or `active`' "$1"; }
assert_C3()  { grep -qF 'campaign-bound-reached:' "$1"; }
assert_C4()  { grep -qF 'Teardown runs at campaign STOP' "$1"; }
assert_C5()  { grep -qF 'campaign_bounds: max-depth=<N> iterations=<N> wall-clock=<N>h' "$1"; }
assert_C6()  { grep -qF 'depth is the length of the parent chain from root' "$1"; }
assert_C7()  { grep -qF 'campaign_stop: campaign-bound-reached:' "$1"; }
assert_C8()  { grep -qF 'last_audit: <YYYY-MM-DDTHH:MM:SSZ> enqueued=<N>' "$1"; }
assert_C9()  { grep -qF 'next-entry: <queue-name>' "$1"; }
assert_C10() { grep -qF 'first continue any entry left `active`' "$1"; }
assert_C11() { grep -qF 'campaign_started:' "$1" && grep -qF 'campaign_iterations:' "$1"; }
assert_C12() { grep -qF 'Single-focus corpora' "$1"; }
assert_C13() { grep -qF '`rejected`' "$1"; }
# C14: SKILL must carry 'do not ask which mode' (B5 mode-announce rule, added in #989 round 5)
assert_C14() { grep -qF 'do not ask which mode' "$1"; }
assert_C15() { grep -qF 'A RUN ends only on campaign STOP' "$1"; }
# Absence assertions: return 0 when text is ABSENT (the good state).
assert_C16() { ! grep -qF 'an autonomous run must stop at convergence' "$1"; }
assert_C17() { ! grep -qF 'A turn ends only on' "$1"; }
# C18: PROMPT-LOOP RETURN CONTRACT must carry the 'STOP: campaign — ' token.
assert_C18() { grep -qF 'STOP: campaign — ' "$1"; }
# C19 (absence): orchestrated context must NOT say 'signal "continue"' — use RETURN CONTRACT.
assert_C19() { ! grep -qF 'signal "continue"' "$1"; }

# ---------------------------------------------------------------------------
# C1: METHODOLOGY.md must state that a focus stop does not end the campaign.
# ---------------------------------------------------------------------------
if assert_C1 "$METHODOLOGY"; then
  ok "C1: METHODOLOGY §8c states focus stop ≠ campaign stop"
else
  no "C1: METHODOLOGY §8c missing focus-stop ≠ campaign-stop distinction"
fi

# ---------------------------------------------------------------------------
# C2: METHODOLOGY.md must use the precise campaign-STOP wording.
# ---------------------------------------------------------------------------
if assert_C2 "$METHODOLOGY"; then
  ok "C2: METHODOLOGY §8c carries precise campaign-STOP wording (no pending/active entries)"
else
  no "C2: METHODOLOGY §8c missing precise campaign-STOP wording (no pending/active entries)"
fi

# ---------------------------------------------------------------------------
# C3: METHODOLOGY.md must carry the typed bound-stop token 'campaign-bound-reached:'.
# ---------------------------------------------------------------------------
if assert_C3 "$METHODOLOGY"; then
  ok "C3: METHODOLOGY §8c carries typed bound-stop token 'campaign-bound-reached:'"
else
  no "C3: METHODOLOGY §8c missing typed bound-stop token 'campaign-bound-reached:'"
fi

# ---------------------------------------------------------------------------
# C4: PROMPT-LOOP.md must state teardown runs at campaign STOP, not focus stop.
# ---------------------------------------------------------------------------
if assert_C4 "$PROMPTLOOP"; then
  ok "C4: PROMPT-LOOP.md states teardown at campaign STOP (not focus stop)"
else
  no "C4: PROMPT-LOOP.md missing 'Teardown runs at campaign STOP'"
fi

# ---------------------------------------------------------------------------
# C5: METHODOLOGY.md §8c must carry the full grammar line for campaign_bounds:
#     including all three keys and the correct wall-clock spelling (<N>h not <Nh>).
# ---------------------------------------------------------------------------
if assert_C5 "$METHODOLOGY"; then
  ok "C5: METHODOLOGY §8c carries full campaign_bounds grammar line (wall-clock=<N>h)"
else
  no "C5: METHODOLOGY §8c missing full campaign_bounds grammar line"
fi

# ---------------------------------------------------------------------------
# C6: METHODOLOGY.md §8c must define depth as the length of the parent chain from root.
# ---------------------------------------------------------------------------
if assert_C6 "$METHODOLOGY"; then
  ok "C6: METHODOLOGY §8c defines depth (parent-chain length from root)"
else
  no "C6: METHODOLOGY §8c missing depth definition"
fi

# ---------------------------------------------------------------------------
# C7: METHODOLOGY.md §8c must state where the bound stop is recorded.
# ---------------------------------------------------------------------------
if assert_C7 "$METHODOLOGY"; then
  ok "C7: METHODOLOGY §8c carries recording location for bound stop (campaign_stop: line)"
else
  no "C7: METHODOLOGY §8c missing recording location for bound stop"
fi

# ---------------------------------------------------------------------------
# C8: METHODOLOGY.md §8c must carry the full grammar shape of the last_audit: field.
# ---------------------------------------------------------------------------
if assert_C8 "$METHODOLOGY"; then
  ok "C8: METHODOLOGY §8c carries full last_audit: grammar line (with enqueued=<N>)"
else
  no "C8: METHODOLOGY §8c missing full last_audit: grammar line"
fi

# ---------------------------------------------------------------------------
# C9: PROMPT-LOOP RETURN CONTRACT must carry the 'next-entry: <queue-name>' token.
# ---------------------------------------------------------------------------
if assert_C9 "$PROMPTLOOP"; then
  ok "C9: PROMPT-LOOP RETURN CONTRACT carries 'next-entry: <queue-name>' campaign token"
else
  no "C9: PROMPT-LOOP RETURN CONTRACT missing 'next-entry: <queue-name>' campaign token"
fi

# ---------------------------------------------------------------------------
# C10: METHODOLOGY §8c must state that resume continues active entry first.
# ---------------------------------------------------------------------------
if assert_C10 "$METHODOLOGY"; then
  ok "C10: METHODOLOGY §8c states resume continues active entry first"
else
  no "C10: METHODOLOGY §8c missing resume-active-first rule"
fi

# ---------------------------------------------------------------------------
# C11: METHODOLOGY §8c must carry persisted bound counters.
# ---------------------------------------------------------------------------
if assert_C11 "$METHODOLOGY"; then
  ok "C11: METHODOLOGY §8c carries persisted bound counters (campaign_started + campaign_iterations)"
else
  no "C11: METHODOLOGY §8c missing persisted bound counters (campaign_started / campaign_iterations)"
fi

# ---------------------------------------------------------------------------
# C12: METHODOLOGY §8c must state last_iteration_ts applies to single-focus corpora.
# ---------------------------------------------------------------------------
if assert_C12 "$METHODOLOGY"; then
  ok "C12: METHODOLOGY §8c states last_iteration_ts applies to single-focus corpora"
else
  no "C12: METHODOLOGY §8c missing single-focus last_iteration_ts statement"
fi

# ---------------------------------------------------------------------------
# C13: METHODOLOGY §8c must carry the `rejected` terminal state.
# ---------------------------------------------------------------------------
if assert_C13 "$METHODOLOGY"; then
  ok "C13: METHODOLOGY §8c carries 'rejected' terminal state"
else
  no "C13: METHODOLOGY §8c missing 'rejected' terminal state"
fi

# ---------------------------------------------------------------------------
# C14: SKILL.md must carry 'do not ask which mode' (B5: announce mode, do not ask).
#      Added in #989 round 5; re-anchored from 'CronList → CronDelete' (still present,
#      no longer the C14 pin since it pins nothing new from this round).
# ---------------------------------------------------------------------------
if assert_C14 "$SKILL"; then
  ok "C14: SKILL.md carries 'do not ask which mode' (mode-announce rule)"
else
  no "C14: SKILL.md missing 'do not ask which mode' (mode-announce rule absent)"
fi

# ---------------------------------------------------------------------------
# C15: PROMPT-LOOP LOOP CONTINUATION must say 'A RUN ends only on campaign STOP'.
# ---------------------------------------------------------------------------
if assert_C15 "$PROMPTLOOP"; then
  ok "C15: PROMPT-LOOP correctly says 'A RUN ends only on campaign STOP'"
else
  no "C15: PROMPT-LOOP missing 'A RUN ends only on campaign STOP'"
fi

# ---------------------------------------------------------------------------
# C16 (absence): PROMPT-LOOP must NOT say 'an autonomous run must stop at convergence'.
# ---------------------------------------------------------------------------
if assert_C16 "$PROMPTLOOP"; then
  ok "C16: PROMPT-LOOP does not have stale convergence-stop wording"
else
  no "C16: PROMPT-LOOP still has stale 'an autonomous run must stop at convergence'"
fi

# ---------------------------------------------------------------------------
# C17 (absence): PROMPT-LOOP must NOT say 'A turn ends only on'.
# ---------------------------------------------------------------------------
if assert_C17 "$PROMPTLOOP"; then
  ok "C17: PROMPT-LOOP does not have stale 'A turn ends only on'"
else
  no "C17: PROMPT-LOOP still has stale 'A turn ends only on'"
fi

# ---------------------------------------------------------------------------
# C18: PROMPT-LOOP RETURN CONTRACT must carry 'STOP: campaign — ' token.
# ---------------------------------------------------------------------------
if assert_C18 "$PROMPTLOOP"; then
  ok "C18: PROMPT-LOOP RETURN CONTRACT carries 'STOP: campaign — ' token"
else
  no "C18: PROMPT-LOOP RETURN CONTRACT missing 'STOP: campaign — ' token"
fi

# ---------------------------------------------------------------------------
# C19 (absence): PROMPT-LOOP must NOT say 'signal "continue"' in orchestrated
#      context — orchestrated mode uses RETURN CONTRACT tokens, not a bare signal.
# ---------------------------------------------------------------------------
if assert_C19 "$PROMPTLOOP"; then
  ok "C19: PROMPT-LOOP does not have stale 'signal \"continue\"' orchestrated wording"
else
  no "C19: PROMPT-LOOP still has stale 'signal \"continue\"' (use RETURN CONTRACT tokens)"
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

  # Teeth C1: replace anchor → assert_C1 must go RED.
  mutantC1="$TMP/METHODOLOGY.mutantC1.md"
  sed 's/A focus stop does not end the campaign/A focus stop DOES end the campaign/g' "$METHODOLOGY" > "$mutantC1"
  if assert_C1 "$mutantC1"; then
    no "teeth-C1: assert_C1 passed on mutant — no teeth"
  else
    ok "teeth-C1: assert_C1 goes RED on mutant"
  fi

  # Teeth C2: replace 'no entry is `pending` or `active`' anchor → assert_C2 must go RED.
  mutantC2="$TMP/METHODOLOGY.mutantC2.md"
  sed 's/no entry is `pending` or `active`/no entry is pending or active/g' "$METHODOLOGY" > "$mutantC2"
  if assert_C2 "$mutantC2"; then
    no "teeth-C2: assert_C2 passed on mutant — no teeth"
  else
    ok "teeth-C2: assert_C2 goes RED on mutant"
  fi

  # Teeth C3: replace 'campaign-bound-reached:' → assert_C3 must go RED.
  mutantC3="$TMP/METHODOLOGY.mutantC3.md"
  sed 's/campaign-bound-reached:/campaign-bound-X:/g' "$METHODOLOGY" > "$mutantC3"
  if assert_C3 "$mutantC3"; then
    no "teeth-C3: assert_C3 passed on mutant — no teeth"
  else
    ok "teeth-C3: assert_C3 goes RED on mutant"
  fi

  # Teeth C4: replace 'Teardown runs at campaign STOP' → assert_C4 must go RED.
  mutantC4="$TMP/PROMPTLOOP.mutantC4.md"
  sed 's/Teardown runs at campaign STOP/Teardown runs at focus STOP/g' "$PROMPTLOOP" > "$mutantC4"
  if assert_C4 "$mutantC4"; then
    no "teeth-C4: assert_C4 passed on mutant — no teeth"
  else
    ok "teeth-C4: assert_C4 goes RED on mutant"
  fi

  echo "-- teeth: METHODOLOGY.md mutants for bounds assertions C5-C8 --"

  # Teeth C5: mutate '<N>h' → '<Nh>' (drop closing bracket) — breaks wall-clock grammar.
  mutantC5="$TMP/METHODOLOGY.mutantC5.md"
  sed 's/wall-clock=<N>h/wall-clock=<Nh>/g' "$METHODOLOGY" > "$mutantC5"
  if assert_C5 "$mutantC5"; then
    no "teeth-C5: assert_C5 passed on mutant — no teeth"
  else
    ok "teeth-C5: assert_C5 goes RED on mutant (wall-clock bracket removed)"
  fi

  # Teeth C6: replace depth anchor → C6 must go RED.
  mutantC6="$TMP/METHODOLOGY.mutantC6.md"
  sed 's/depth is the length of the parent chain from root/depth is unspecified/g' "$METHODOLOGY" > "$mutantC6"
  if assert_C6 "$mutantC6"; then
    no "teeth-C6: assert_C6 passed on mutant — no teeth"
  else
    ok "teeth-C6: assert_C6 goes RED on mutant"
  fi

  # Teeth C7: replace 'campaign_stop: campaign-bound-reached:' → C7 must go RED.
  mutantC7="$TMP/METHODOLOGY.mutantC7.md"
  sed 's/campaign_stop: campaign-bound-reached:/campaign_stop: bound-reached:/g' "$METHODOLOGY" > "$mutantC7"
  if assert_C7 "$mutantC7"; then
    no "teeth-C7: assert_C7 passed on mutant — no teeth"
  else
    ok "teeth-C7: assert_C7 goes RED on mutant"
  fi

  # Teeth C8: mutate 'enqueued=<N>' → 'enqueued=N' (remove angle brackets) — breaks grammar.
  mutantC8="$TMP/METHODOLOGY.mutantC8.md"
  sed 's/enqueued=<N>/enqueued=N/g' "$METHODOLOGY" > "$mutantC8"
  if assert_C8 "$mutantC8"; then
    no "teeth-C8: assert_C8 passed on mutant — no teeth"
  else
    ok "teeth-C8: assert_C8 goes RED on mutant (enqueued angle brackets removed)"
  fi

  echo "-- teeth: PROMPT-LOOP + METHODOLOGY + SKILL mutants for C9-C14 --"

  # Teeth C9: replace 'next-entry: <queue-name>' in PROMPTLOOP → C9 must go RED.
  mutantC9="$TMP/PROMPTLOOP.mutantC9.md"
  sed 's/next-entry: <queue-name>/next-entry: <X>/g' "$PROMPTLOOP" > "$mutantC9"
  if assert_C9 "$mutantC9"; then
    no "teeth-C9: assert_C9 passed on mutant — no teeth"
  else
    ok "teeth-C9: assert_C9 goes RED on mutant"
  fi

  # Teeth C10: replace resume anchor → C10 must go RED.
  mutantC10="$TMP/METHODOLOGY.mutantC10.md"
  sed 's/first continue any entry left `active`/first pop the next `pending` entry/g' "$METHODOLOGY" > "$mutantC10"
  if assert_C10 "$mutantC10"; then
    no "teeth-C10: assert_C10 passed on mutant — no teeth"
  else
    ok "teeth-C10: assert_C10 goes RED on mutant"
  fi

  # Teeth C11a: replace 'campaign_started:' → C11 compound assertion must go RED.
  mutantC11a="$TMP/METHODOLOGY.mutantC11a.md"
  sed 's/campaign_started:/campaign_STARTED_X:/g' "$METHODOLOGY" > "$mutantC11a"
  if assert_C11 "$mutantC11a"; then
    no "teeth-C11a: assert_C11 passed on mutant — no teeth"
  else
    ok "teeth-C11a: assert_C11 goes RED on mutant (campaign_started removed)"
  fi

  # Teeth C11b: replace 'campaign_iterations:' → C11 compound assertion must go RED.
  mutantC11b="$TMP/METHODOLOGY.mutantC11b.md"
  sed 's/campaign_iterations:/campaign_ITERATIONS_X:/g' "$METHODOLOGY" > "$mutantC11b"
  if assert_C11 "$mutantC11b"; then
    no "teeth-C11b: assert_C11 passed on mutant — no teeth"
  else
    ok "teeth-C11b: assert_C11 goes RED on mutant (campaign_iterations removed)"
  fi

  # Teeth C12: replace 'Single-focus corpora' → C12 must go RED.
  mutantC12="$TMP/METHODOLOGY.mutantC12.md"
  sed 's/Single-focus corpora/Multi-focus corpora/g' "$METHODOLOGY" > "$mutantC12"
  if assert_C12 "$mutantC12"; then
    no "teeth-C12: assert_C12 passed on mutant — no teeth"
  else
    ok "teeth-C12: assert_C12 goes RED on mutant"
  fi

  # Teeth C13: replace '`rejected`' in METHODOLOGY → C13 must go RED.
  mutantC13="$TMP/METHODOLOGY.mutantC13.md"
  sed 's/`rejected`/`REJECTED_X`/g' "$METHODOLOGY" > "$mutantC13"
  if assert_C13 "$mutantC13"; then
    no "teeth-C13: assert_C13 passed on mutant — no teeth"
  else
    ok "teeth-C13: assert_C13 goes RED on mutant"
  fi

  # Teeth C14: replace 'do not ask which mode' in SKILL → C14 must go RED.
  mutantC14="$TMP/SKILL.mutantC14.md"
  sed 's/do not ask which mode/do not DETERMINE which mode/g' "$SKILL" > "$mutantC14"
  if assert_C14 "$mutantC14"; then
    no "teeth-C14: assert_C14 passed on mutant — no teeth"
  else
    ok "teeth-C14: assert_C14 goes RED on mutant"
  fi

  # Teeth C15: replace 'A RUN ends only on campaign STOP' → C15 must go RED.
  mutantC15="$TMP/PROMPTLOOP.mutantC15.md"
  sed 's/A RUN ends only on campaign STOP/A turn ends only on campaign STOP/g' "$PROMPTLOOP" > "$mutantC15"
  if assert_C15 "$mutantC15"; then
    no "teeth-C15: assert_C15 passed on mutant — no teeth"
  else
    ok "teeth-C15: assert_C15 goes RED on mutant"
  fi

  # Teeth C16 (absence): inject stale text → assert_C16 must return 1 (text found = fail).
  mutantC16="$TMP/PROMPTLOOP.mutantC16.md"
  sed '1s|^|an autonomous run must stop at convergence\n|' "$PROMPTLOOP" > "$mutantC16"
  if assert_C16 "$mutantC16"; then
    no "teeth-C16: assert_C16 passed on mutant — no teeth"
  else
    ok "teeth-C16: assert_C16 goes RED on mutant (stale text injected)"
  fi

  # Teeth C17 (absence): inject stale text → assert_C17 must return 1 (text found = fail).
  mutantC17="$TMP/PROMPTLOOP.mutantC17.md"
  sed '1s|^|A turn ends only on\n|' "$PROMPTLOOP" > "$mutantC17"
  if assert_C17 "$mutantC17"; then
    no "teeth-C17: assert_C17 passed on mutant — no teeth"
  else
    ok "teeth-C17: assert_C17 goes RED on mutant (stale text injected)"
  fi

  echo "-- teeth: C18/C19 mutants --"

  # Teeth C18: replace 'STOP: campaign — ' → C18 must go RED.
  mutantC18="$TMP/PROMPTLOOP.mutantC18.md"
  sed 's/STOP: campaign — /STOP: campaign X/g' "$PROMPTLOOP" > "$mutantC18"
  if assert_C18 "$mutantC18"; then
    no "teeth-C18: assert_C18 passed on mutant — no teeth"
  else
    ok "teeth-C18: assert_C18 goes RED on mutant"
  fi

  # Teeth C19 (absence): inject 'signal "continue"' → assert_C19 must return 1.
  mutantC19="$TMP/PROMPTLOOP.mutantC19.md"
  sed '1s|^|signal "continue"\n|' "$PROMPTLOOP" > "$mutantC19"
  if assert_C19 "$mutantC19"; then
    no "teeth-C19: assert_C19 passed on mutant — no teeth"
  else
    ok "teeth-C19: assert_C19 goes RED on mutant (stale text injected)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
