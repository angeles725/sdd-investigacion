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
# A12: Installed SKILL.md drift guard (third twin).
#      Resolved via rsdd_field (install/adapters.sh); never a hardcoded path.
#      All three states are INFO-only — drift is expected until the operator
#      re-runs the installer.  The suite never fails on drift or absence.
# ---------------------------------------------------------------------------
ADAPTERS="$HERE/../../install/adapters.sh"

# _a12_installed_check <home> <main_skill>
# Prints one canonical INFO string (no leading prefix) to stdout.
# Four states: absent-input / error-reading (diff rc≥2) / DRIFT / in sync.
# Never collapses absence or error to in-sync (§7 anti-silent-zero).
_a12_installed_check() {
  local home="$1" main_skill="$2"
  local installed_path diff_patch _drc hunks lines
  installed_path="$(rsdd_field claude skill_path "$home")"
  if [ ! -f "$installed_path" ]; then
    printf 'installed copy: absent-input (%s not found) — drift check skipped\n' \
           "$installed_path"
    return 0
  fi
  diff_patch="$(diff -u "$installed_path" "$main_skill")"; _drc=$?
  if [ "$_drc" -ge 2 ]; then
    printf 'installed copy: error reading — drift check inconclusive (diff rc=%s)\n' "$_drc"
    return 0
  fi
  hunks="$(printf '%s\n' "$diff_patch" | grep -c '^@@')" || true
  lines="$(printf '%s\n' "$diff_patch" | grep -c '^+[^+]')" || true
  if [ "${hunks:-0}" -eq 0 ]; then
    printf 'installed copy: in sync\n'
  else
    printf 'installed copy: DRIFT — %s hunk(s) / %s line(s) behind the kit copy\n' \
           "${hunks:-0}" "${lines:-0}"
  fi
}

if [ ! -f "$ADAPTERS" ]; then
  no "A12: install/adapters.sh not found at expected path: $ADAPTERS"
else
  # shellcheck source=research-sdd/install/adapters.sh
  . "$ADAPTERS"
  _a12_out="$(_a12_installed_check "${RSDD_INSTALL_HOME:-$HOME}" "$MAIN")"
  printf '  INFO  A12: %s\n' "$_a12_out"
  ok "A12: installed drift check ran (see INFO line above)"
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

  # A12 teeth: RSDD_INSTALL_HOME → stale fixture home (1 hunk behind kit).
  # Stale output must contain 'DRIFT — 1 hunk(s)' and must NOT contain 'in sync'.
  # A12 teeth: RSDD_INSTALL_HOME → absent fixture home.
  # Absent output must contain 'absent-input' and must NOT contain 'in sync'.
  # Both collapse-mutants (drift→in-sync, absent→in-sync) go RED.
  if [ -f "$ADAPTERS" ]; then
    echo "-- prove-teeth: A12 stale fixture — exact hunk count; not in sync --"
    _fx_stale="$TMP/stale-home"
    mkdir -p "$_fx_stale/.claude/skills/research-sdd"
    # One-line file: always exactly 1 hunk behind the kit (context bridges the whole diff)
    printf 'FIXTURE: deliberately stale SKILL.md\n' \
      > "$_fx_stale/.claude/skills/research-sdd/SKILL.md"
    _stale_out="$(_a12_installed_check "$_fx_stale" "$MAIN")"
    if printf '%s\n' "$_stale_out" | grep -qF 'DRIFT — 1 hunk(s)'; then
      ok "teeth-A12-stale: stale fixture reports DRIFT — 1 hunk(s) (exact count)"
    else
      no "teeth-A12-stale: expected 'DRIFT — 1 hunk(s)'; got: $_stale_out"
    fi
    # Mutant: collapse drift → in sync — must go RED (stale must not report 'in sync')
    if printf '%s\n' "$_stale_out" | grep -qF 'in sync'; then
      no "teeth-A12-stale-collapse: stale wrongly reports 'in sync' (drift→in-sync mutant undetected)"
    else
      ok "teeth-A12-stale-collapse: drift→in-sync mutant goes RED (teeth confirmed)"
    fi

    echo "-- prove-teeth: A12 absent fixture — absent-input; not in sync --"
    _fx_absent="$TMP/absent-home"
    mkdir -p "$_fx_absent"
    # No .claude/skills/research-sdd/SKILL.md present
    _absent_out="$(_a12_installed_check "$_fx_absent" "$MAIN")"
    if printf '%s\n' "$_absent_out" | grep -qF 'absent-input'; then
      ok "teeth-A12-absent: absent fixture reports absent-input"
    else
      no "teeth-A12-absent: expected 'absent-input'; got: $_absent_out"
    fi
    # Mutant: collapse absent → in sync — must go RED (absent must not report 'in sync')
    if printf '%s\n' "$_absent_out" | grep -qF 'in sync'; then
      no "teeth-A12-absent-collapse: absent wrongly reports 'in sync' (absent→in-sync mutant undetected)"
    else
      ok "teeth-A12-absent-collapse: absent→in-sync mutant goes RED (teeth confirmed)"
    fi

    # A12 teeth: unreadable installed file — [ -f ] is TRUE but diff exits ≥2.
    # Must report 'inconclusive', NOT 'in sync'.
    # Skip if running as root (root ignores mode-000 and diff would succeed).
    echo "-- prove-teeth: A12 unreadable fixture — inconclusive; not in sync --"
    if [ "$(id -u)" = "0" ]; then
      ok "teeth-A12-unreadable: skipped (running as root; chmod 000 does not block root)"
    else
      _fx_unread="$TMP/unread-home"
      mkdir -p "$_fx_unread/.claude/skills/research-sdd"
      _unread_skill="$_fx_unread/.claude/skills/research-sdd/SKILL.md"
      : > "$_unread_skill"
      chmod 000 "$_unread_skill"
      _unread_out="$(_a12_installed_check "$_fx_unread" "$MAIN")"
      chmod 644 "$_unread_skill"   # restore so TMP cleanup can remove it
      if printf '%s\n' "$_unread_out" | grep -qF 'inconclusive'; then
        ok "teeth-A12-unreadable: unreadable fixture reports inconclusive"
      else
        no "teeth-A12-unreadable: expected 'inconclusive'; got: $_unread_out"
      fi
      # Mutant: collapse error → in sync (the old || true code path)
      if printf '%s\n' "$_unread_out" | grep -qF 'in sync'; then
        no "teeth-A12-unreadable-collapse: unreadable wrongly reports 'in sync' (error→in-sync mutant undetected)"
      else
        ok "teeth-A12-unreadable-collapse: error→in-sync mutant goes RED (teeth confirmed)"
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
