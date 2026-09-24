#!/usr/bin/env bash
# prompt-invariants.sh — sourceable library of doctrine-invariant assertions,
# extracted from skill-invariants.test.sh (kit issue #993 WU3, #1021).
#
# Every assert_* function below takes exactly ONE argument — a file path
# ($1) — and returns 0 when the invariant HOLDS on that file, 1 when it does
# NOT. For a presence-style invariant, 0 means the anchor text IS present;
# for an absence-style invariant (the "_neg" / "_no_optin" names), 0 means
# the forbidden text is ABSENT. This uniform one-argument contract is what
# lets the SAME function run against:
#   - a checked-in source doctrine file (skills/research-sdd/SKILL.md,
#     PROMPT-LOOP.md, METHODOLOGY.md, templates/RESEARCH-STATE.template.md),
#     as skill-invariants.test.sh does, or
#   - a per-profile RENDERED copy of SKILL.md / PROMPT-LOOP.md /
#     METHODOLOGY.md produced by render-profile.sh, as
#     profile-invariants.test.sh does (#993 WU3 — the drift guard that
#     ensures a profile's swapped cadence wording never forks doctrine).
#
# Naming mirrors the invariant IDs documented in skill-invariants.test.sh's
# header comment (A1-A15, B1-B3, C1-C19, D1, E1a/E1_no_optin, E2a/E2b). This
# file defines FUNCTIONS ONLY — it must be sourced, never executed directly.
#
# No `set -euo pipefail` here deliberately: this is a sourced library, and a
# sourced `set` would mutate the CALLING script's shell options as a side
# effect. Both test suites that source this file already set their own
# `set -uo pipefail`.

# =============================================================================
# A1-A15 — SKILL.md-scoped invariants (kit issue #961/#960/#364 drift classes)
# =============================================================================
assert_A1()      { grep -qF 'the 7 markers' "$1"; }
assert_A1_neg()  { ! grep -qF 'the 5 markers' "$1"; }
assert_A2()      { grep -qF '| **corpus**' "$1"; }
assert_A3()      { grep -qF 'CARVE-OUT (intent wins)' "$1"; }
assert_A4()      { grep -qF 'UNLESS the request is a scoped factual question' "$1"; }
assert_A5()      { grep -qF 'ensure-remote.sh' "$1"; }
assert_A6()      { grep -qF 'document-unregistered-bootstrap-incident' "$1"; }
assert_A7()      { grep -qF 'detect-tools.sh' "$1"; }
assert_A8()      { grep -qF 'blocked-on-tool' "$1"; }
assert_A10()     { grep -qF 'HOT-CORE' "$1"; }
assert_A11()     { grep -qF 'alias:' "$1" && grep -qF 'kaitai-struct-compiler' "$1"; }
assert_A12a()    { grep -qF 'never applied from inside a run (§18 propose-never-apply)' "$1"; }
assert_A12b()    { grep -qF 'propose-never-apply). Provisioning is complete' "$1"; }
assert_A13()     { grep -qF 'Dynamic is recommended for unattended runs' "$1"; }
assert_A14_neg() { ! grep -qF 'guarantees the cadence' "$1"; }
assert_A15()     { grep -qF 're-invoker is already active' "$1"; }

# =============================================================================
# B1-B3 — PROMPT-LOOP.md-scoped invariants (kit issue #961)
# =============================================================================
assert_B1() { grep -qF 'dynamic self-paced, no interval' "$1" && grep -qF '/loop 5m  <paste' "$1"; }
assert_B2() { grep -qF 'Do NOT issue ScheduleWakeup' "$1"; }
assert_B3() { grep -qF 'CronDelete' "$1"; }

# =============================================================================
# C1-C19 — campaign-queue / STOP-vocabulary invariants (METHODOLOGY.md §8c,
# PROMPT-LOOP.md RETURN CONTRACT / LOOP CONTINUATION, SKILL.md mode table).
# Unchanged from the original skill-invariants.test.sh definitions.
# =============================================================================
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
assert_C14() { grep -qF 'do not ask which mode' "$1"; }
assert_C15() { grep -qF 'A RUN ends only on campaign STOP' "$1"; }
# Absence assertions: return 0 when text is ABSENT (the good state).
assert_C16() { ! grep -qF 'an autonomous run must stop at convergence' "$1"; }
assert_C17() { ! grep -qF 'A turn ends only on' "$1"; }
assert_C18() { grep -qF 'STOP: campaign — ' "$1"; }
assert_C19() { ! grep -qF 'signal "continue"' "$1"; }

# D1 (absence): RESEARCH-STATE template must NOT have a live '## Campaign
# queue' section heading outside HTML comments (R1).
assert_D1() {
  local f="$1"
  python3 - "$f" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as fh:
    text = fh.read()
stripped = re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL)
for line in stripped.splitlines():
    if re.search(r'^##\s+Campaign queue', line):
        sys.exit(1)
sys.exit(0)
PYEOF
}

# =============================================================================
# E1a/E1_no_optin/E2a/E2b — F03/F05 seal-collapse and situational-list
# invariants (METHODOLOGY.md + PROMPT-LOOP.md).
#
# E1_no_optin replaces the original inline E1b (METHODOLOGY) / E1c
# (PROMPT-LOOP) pair with ONE function called on each file, the same pattern
# assert_C19 already uses for its a/b/c call sites.
# =============================================================================
assert_E1a()       { grep -qF 'required for conclusion-bearing' "$1"; }
assert_E1_no_optin() { ! grep -qF 'OPT-IN selective seal' "$1"; }
assert_E2a()       { grep -qF '§7b' "$1"; }
assert_E2b()       { grep -qF '§11a' "$1"; }
