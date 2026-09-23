#!/usr/bin/env bash
# install.test.sh — unit tests for research-sdd/install/install.sh (pure-logic parts).
#
# Covers (no real apt/sudo required):
#   1. Unknown argument → exit 2.
#   2. Tier flags (--with-binary etc.) are accepted and set correct state.
#   3. Debian/non-Debian guard rejects absent apt-get with a clear message.
#   4. --dry-run emits a plan and writes no files (hermetic scratch HOME).
#   5. ~/.bashrc marker-block splice is idempotent (two runs → one block).
#   6. Agents-notice fires when the agent file is absent; silent when present.
#   7. Orphan-start marker: splice_marker returns 3 (warn-and-skip), file untouched
#      on both run 1 and run 2 — no data loss across repeated invocations.
#   8. Non-dry SUMMARY counts are row-anchored: fixture with 3 AVAILABLE + 1 MISSING
#      + 1 UNUSABLE + 1 PROBE_FAILED + 2 legend lines → AVAILABLE: 3 | MISSING/UNUSABLE: 3.
#      Empty cache (nonexistent RESEARCH_TOOLS_CACHE) → DEGRADED line.
#   9. Skill-deploy failure clears _baseline_ok: stub research-sdd-install.sh exits 1 →
#      SUMMARY BASELINE DEGRADED + non-zero exit (not BASELINE OK + exit 0).
#
# Teeth (--prove-teeth):
#   Tooth A — SENTINEL-IDEMPOTENT: disabling the "strip existing block" guard causes
#             a second splice to produce TWO marker blocks instead of one.
#   Tooth B — SENTINEL-DRY-RUN: zeroing _splice_is_dry causes splice_marker to write
#             the file even when dry=1.
#   Tooth C — SENTINEL-APT-DRY: neutralizing apt_install dry guard causes sudo_n to
#             be called even when dry=1.
#   Tooth D — phase-dry stub: sources SUT, overrides sudo_n to log, sets dry=1, drives
#             all phase functions, asserts zero sudo_n calls.
#   Tooth E — SENTINEL-PDF-DRY: neutralizing phase_pdf dry guard causes --dry-run
#             --with-pdf to write real files (venv creation, no sudo needed).
#   Tooth F — SENTINEL-ORPHAN-SKIP: disabling the orphan skip causes run 2 to strip
#             user content between orphan-start and the appended end marker.
#   Tooth G — SENTINEL-GREP-AV-ANCHOR: un-anchoring the AVAILABLE regex causes the
#             legend line to be counted → fixture reports 4|4 instead of 3|3.
#   Tooth H — SENTINEL-SKILL-DEPLOY: restoring || true on the skill-deploy call causes
#             a failing installer to be silently ignored → BASELINE OK + exit 0.
#
# Usage: install.test.sh [--prove-teeth]
# Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../../install/install.sh"

[ -f "$SUT" ] || { printf 'FATAL: SUT not found: %s\n' "$SUT" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL  %s  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

printf '== install.test.sh (SUT: %s) ==\n' "$(basename "$SUT")"

# ---------------------------------------------------------------------------
# 1. Unknown argument → exit 2
# ---------------------------------------------------------------------------
rc=0
bash "$SUT" --unknown-flag >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] \
  && ok "unknown arg → exit 2" \
  || no "unknown arg: expected exit 2, got $rc"

# ---------------------------------------------------------------------------
# 2. Tier flags accepted without error — source SUT and test parse_args directly
#    to avoid spawning a subprocess per flag (performance).
# ---------------------------------------------------------------------------
for flag in --with-binary --with-pcap --with-firmware --with-vm \
            --with-pdf --with-net --with-dotnet --with-latex --all-heavy; do
  # Reset globals, run parse_args for a single flag, verify no error.
  parse_test_script="$TMP/parse-test.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    "source \"$SUT\"" \
    "parse_args \"$flag\" --dry-run --harness claude" \
    > "$parse_test_script"
  rc=0
  bash "$parse_test_script" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    && ok "tier flag accepted by parse_args: $flag" \
    || no "tier flag rejected by parse_args: $flag (exit $rc)"
done

# Also verify all-heavy sets all tier flags.
all_heavy_script="$TMP/parse-all-heavy.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "parse_args --all-heavy --dry-run --harness claude" \
  'all_set=1' \
  'for v in $tier_binary $tier_pcap $tier_firmware $tier_vm $tier_pdf $tier_net $tier_dotnet $tier_latex; do' \
  '  [ "$v" -eq 1 ] || all_set=0' \
  'done' \
  '[ "$all_set" -eq 1 ]' \
  > "$all_heavy_script"
rc=0; bash "$all_heavy_script" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && ok "--all-heavy sets all tier flags" \
  || no "--all-heavy did not set all tier flags (exit $rc)"

# ---------------------------------------------------------------------------
# 3. Debian guard — rejects absent apt-get with a diagnostic message
#    Source the SUT (main is skipped) and override have() for apt-get.
# ---------------------------------------------------------------------------
guard_script="$TMP/test-debian-guard.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  'have() { case "$1" in apt-get) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }' \
  'check_debian' \
  > "$guard_script"
guard_out="$(bash "$guard_script" 2>&1)"; guard_rc=$?
if [ "$guard_rc" -ne 0 ] && printf '%s' "$guard_out" | grep -q 'Debian/Ubuntu'; then
  ok "debian-guard: non-zero exit with 'Debian/Ubuntu' message when apt-get absent"
else
  no "debian-guard: expected non-zero + Debian/Ubuntu message" \
     "rc=$guard_rc out=$guard_out"
fi

# Test that the guard is silent when apt-get IS present.
guard_script2="$TMP/test-debian-guard2.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  'have() { case "$1" in apt-get) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }' \
  'check_debian' \
  > "$guard_script2"
guard2_out="$(bash "$guard_script2" 2>&1)"; guard2_rc=$?
[ "$guard2_rc" -eq 0 ] \
  && ok "debian-guard: exits 0 when apt-get is present" \
  || no "debian-guard: expected exit 0 when apt-get present, got $guard2_rc" \
        "out=$guard2_out"

# ---------------------------------------------------------------------------
# 4. --dry-run emits PLAN lines and writes NO files (D1/D5: hermetic scratch HOME)
# ---------------------------------------------------------------------------
dry_scratch_home="$TMP/dry-scratch-home"
mkdir -p "$dry_scratch_home"
dry_home="$TMP/dry-home"
mkdir -p "$dry_home"
# Set HOME=scratch so detect-tools.sh cache writes (D1 leak) are caught.
# --all-heavy exercises all tiers including phase_pdf (python3 -m venv, no sudo) — DEFECT 2.
dry_out="$(HOME="$dry_scratch_home" bash "$SUT" --dry-run --all-heavy --home "$dry_home" --harness claude 2>/dev/null || true)"

# Check no files written under --home dir.
file_count_home="$(find "$dry_home" -mindepth 1 | wc -l)"
[ "$file_count_home" -eq 0 ] \
  && ok "dry-run: no files written under --home dir" \
  || no "dry-run: ${file_count_home} file(s) written under --home despite --dry-run" \
        "$(find "$dry_home" -mindepth 1)"

# Check no files written under scratch HOME (catches D1: detect-tools.sh cache leak).
file_count_env="$(find "$dry_scratch_home" -mindepth 1 | wc -l)"
[ "$file_count_env" -eq 0 ] \
  && ok "dry-run: no files written under scratch \$HOME (dry guard blocks all writes)" \
  || no "dry-run: ${file_count_env} file(s) leaked to scratch HOME despite --dry-run" \
        "$(find "$dry_scratch_home" -mindepth 1)"

# Check that PLAN lines are present in output.
if printf '%s' "$dry_out" | grep -q 'PLAN'; then
  ok "dry-run: output contains PLAN lines"
else
  no "dry-run: no PLAN lines in output" "out=$dry_out"
fi

# ---------------------------------------------------------------------------
# 5. Marker-block splice idempotency — source SUT, call splice_marker twice,
#    verify exactly ONE marker block appears in the file.
# ---------------------------------------------------------------------------
splice_script="$TMP/test-splice-idem.sh"
target_file="$TMP/bashrc-idem"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "dry=0" \
  "splice_marker \"$target_file\" 'export TEST_VAR=1'" \
  "splice_marker \"$target_file\" 'export TEST_VAR=1'" \
  > "$splice_script"
bash "$splice_script" >/dev/null 2>&1
start_count=0
[ -f "$target_file" ] && start_count="$(grep -cF '# research-sdd:start' "$target_file" || true)"
[ "$start_count" -eq 1 ] \
  && ok "marker-splice: two runs produce exactly one marker block (idempotent)" \
  || no "marker-splice: expected 1 start marker, found $start_count" \
        "$(cat "$target_file" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 6. Agents-notice: printed when agent file is absent; silent when present
# ---------------------------------------------------------------------------
notice_home="$TMP/notice-home-absent"
mkdir -p "$notice_home"
notice_out_absent="$(bash "$SUT" --dry-run --home "$notice_home" --harness claude 2>/dev/null || true)"
if printf '%s' "$notice_out_absent" | grep -q 'OPTIONAL'; then
  ok "agents-notice: OPTIONAL notice printed when agent file absent"
else
  no "agents-notice: expected OPTIONAL notice when agent file absent"
fi

notice_home2="$TMP/notice-home-present"
mkdir -p "$notice_home2/.claude/agents"
touch "$notice_home2/.claude/agents/sdd-apply.md"
notice_out_present="$(bash "$SUT" --dry-run --home "$notice_home2" --harness claude 2>/dev/null || true)"
if ! printf '%s' "$notice_out_present" | grep -q 'OPTIONAL'; then
  ok "agents-notice: no OPTIONAL notice when agent file present"
else
  no "agents-notice: unexpected OPTIONAL notice when agent file exists"
fi

# ---------------------------------------------------------------------------
# 7. Orphan-start marker: splice_marker WARNS, returns 3, and leaves file
#    UNTOUCHED on BOTH run 1 and run 2 (D1: no data loss on malformed ~/.bashrc).
#    Correct doctrine: warn-and-skip, mirroring _rsdd_splice_file's on_orphan=skip path.
# ---------------------------------------------------------------------------
orphan_file="$TMP/bashrc-orphan"
printf '%s\n' \
  'BEFORE=1' \
  '# research-sdd:start' \
  'ORPHAN_CONTENT=1' \
  'AFTER_ORPHAN=2' \
  > "$orphan_file"
orphan_script="$TMP/test-splice-orphan.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "dry=0" \
  "file=\"$orphan_file\"" \
  'splice_rc1=0' \
  "splice_marker \"\$file\" 'export NEW_VAR=1' || splice_rc1=\$?" \
  'splice_rc2=0' \
  "splice_marker \"\$file\" 'export NEW_VAR=1' || splice_rc2=\$?" \
  "printf 'rc1=%s rc2=%s\n' \"\$splice_rc1\" \"\$splice_rc2\"" \
  > "$orphan_script"
orphan_out="$(bash "$orphan_script" 2>&1)"
# Both runs must return 3 (orphan path), file untouched.
if printf '%s' "$orphan_out" | grep -q 'rc1=3 rc2=3'; then
  ok "orphan-splice: both runs return 3 (warn-and-skip path)"
else
  no "orphan-splice: expected rc1=3 rc2=3" "out=$orphan_out"
fi
# File must be UNTOUCHED: all original lines present, no new block added.
if grep -qF 'BEFORE=1' "$orphan_file" \
    && grep -qF 'ORPHAN_CONTENT=1' "$orphan_file" \
    && grep -qF 'AFTER_ORPHAN=2' "$orphan_file" \
    && ! grep -qF 'NEW_VAR=1' "$orphan_file"; then
  ok "orphan-splice: file untouched after two runs (all original lines intact, no new block)"
else
  no "orphan-splice: file was modified or original content lost" \
     "file=$(cat "$orphan_file" 2>/dev/null)"
fi
if printf '%s' "$orphan_out" | grep -qi 'WARNING'; then
  ok "orphan-splice: WARNING emitted for stray marker"
else
  no "orphan-splice: no WARNING for stray marker" "out=$orphan_out"
fi

# ---------------------------------------------------------------------------
# 8. Non-dry SUMMARY counts are row-anchored and accurate against a fixture cache
#    (RESIDUAL §7): 3 AVAILABLE + 1 MISSING + 1 UNUSABLE + 1 PROBE_FAILED + 2
#    legend lines → SUMMARY must print AVAILABLE: 3 | MISSING/UNUSABLE: 3 (not 4 | 4).
#    Also: empty cache → DEGRADED line.
# ---------------------------------------------------------------------------
# Build stub KIT (detect-tools.sh no-op) and SELF (research-sdd-install.sh no-op).
stub_kit8="$TMP/stub-kit8"
stub_install8="$TMP/stub-install8"
mkdir -p "$stub_kit8/toolbelt" "$stub_install8"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_kit8/toolbelt/detect-tools.sh"
chmod +x "$stub_kit8/toolbelt/detect-tools.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_install8/research-sdd-install.sh"
chmod +x "$stub_install8/research-sdd-install.sh"

# Build fixture cache: 3 AVAILABLE, 1 MISSING, 1 UNUSABLE, 1 PROBE_FAILED + 2 legend lines.
fixture_cache8="$TMP/fixture-cache8.txt"
printf '%s\n' \
  '== Research-SDD tool capability report ==' \
  '[ test ]' \
  '  tool-a                 AVAILABLE   /usr/bin/tool-a' \
  '  tool-b                 AVAILABLE   /usr/bin/tool-b' \
  '  tool-c                 AVAILABLE   /usr/bin/tool-c' \
  '  tool-d                 MISSING     (not on PATH)' \
  '  tool-e                 UNUSABLE    /usr/bin/tool-e (smoke test failed)' \
  '  tool-f                 PROBE_FAILED /usr/bin/tool-f (probe error: exit 1)' \
  'Note: AVAILABLE means the resolver found the tool AND its bounded validation passed.' \
  'UNUSABLE means found but not runnable; MISSING means not detected.' \
  > "$fixture_cache8"

summary_home8="$TMP/summary-home8"
mkdir -p "$summary_home8"

summary_script8="$TMP/test-summary8.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "SELF=\"$stub_install8\"" \
  "KIT=\"$stub_kit8\"" \
  'apt_have() { return 0; }' \
  'have()     { return 0; }' \
  'node_ok()  { return 0; }' \
  'sudo_n()   { return 100; }' \
  "export RESEARCH_TOOLS_CACHE=\"$fixture_cache8\"" \
  "main --home \"$summary_home8\" --harness claude" \
  > "$summary_script8"

summary_out8="$(bash "$summary_script8" 2>/dev/null)" || true
if printf '%s' "$summary_out8" | grep -qF 'AVAILABLE: 3 | MISSING/UNUSABLE: 3'; then
  ok "summary: fixture 3 AVAILABLE + 3 MISSING/UNUSABLE/PROBE_FAILED → correct 3|3 (legend excluded)"
else
  summary_line8="$(printf '%s' "$summary_out8" | grep 'SUMMARY' || true)"
  no "summary: expected AVAILABLE: 3 | MISSING/UNUSABLE: 3" "got: $summary_line8"
fi

# Empty-cache path: RESEARCH_TOOLS_CACHE points to a non-existent file → DEGRADED.
empty_home8="$TMP/empty-home8"
mkdir -p "$empty_home8"
empty_script8="$TMP/test-empty8.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "SELF=\"$stub_install8\"" \
  "KIT=\"$stub_kit8\"" \
  'apt_have() { return 0; }' \
  'have()     { return 0; }' \
  'node_ok()  { return 0; }' \
  'sudo_n()   { return 100; }' \
  "export RESEARCH_TOOLS_CACHE=\"$TMP/nonexistent-cache.txt\"" \
  "main --home \"$empty_home8\" --harness claude" \
  > "$empty_script8"
empty_out8="$(bash "$empty_script8" 2>/dev/null || true)"
if printf '%s' "$empty_out8" | grep -q 'DEGRADED'; then
  ok "summary: empty-cache (nonexistent RESEARCH_TOOLS_CACHE) → DEGRADED line"
else
  no "summary: expected DEGRADED on empty cache" "out=$(printf '%s' "$empty_out8" | grep 'SUMMARY\|DEGRADED' || true)"
fi

# ---------------------------------------------------------------------------
# 9. Skill-deploy failure clears _baseline_ok: stub installer exits 1 →
#    SUMMARY BASELINE DEGRADED + non-zero exit (issue #963).
#    Reuses $stub_kit8 and $fixture_cache8 from case 8 setup above.
# ---------------------------------------------------------------------------
stub_install9="$TMP/stub-install9"
mkdir -p "$stub_install9"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_install9/research-sdd-install.sh"
chmod +x "$stub_install9/research-sdd-install.sh"

summary_home9="$TMP/summary-home9"
mkdir -p "$summary_home9"

summary_script9="$TMP/test-summary9.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  "source \"$SUT\"" \
  "SELF=\"$stub_install9\"" \
  "KIT=\"$stub_kit8\"" \
  'apt_have() { return 0; }' \
  'have()     { return 0; }' \
  'node_ok()  { return 0; }' \
  'sudo_n()   { return 100; }' \
  "export RESEARCH_TOOLS_CACHE=\"$fixture_cache8\"" \
  "main --home \"$summary_home9\" --harness claude" \
  > "$summary_script9"

summary_out9="$(bash "$summary_script9" 2>&1)"; summary_rc9=$?
if [ "$summary_rc9" -ne 0 ] && printf '%s' "$summary_out9" | grep -q 'BASELINE DEGRADED'; then
  ok "skill-deploy failure: BASELINE DEGRADED + non-zero exit when installer exits 1"
else
  summary_line9="$(printf '%s' "$summary_out9" | grep 'SUMMARY' || true)"
  no "skill-deploy failure: expected non-zero exit + BASELINE DEGRADED" \
     "rc=$summary_rc9 summary=$summary_line9"
fi

# ==========================================================================
# TEETH — mutant verification (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  printf '%s\n' '-- teeth: setting up mutant tests --'

  # ---- Tooth A: SENTINEL-IDEMPOTENT — disabling the strip-existing-block guard ----
  # Mutant: force _splice_has_existing=1 always, so the awk strip always runs.
  # On first call to an empty file, awk with no matching start marker = passthrough (ok).
  # On second call, _splice_has_existing=1 STILL, so awk strips correctly — SAME as
  # the original? No: we need the OPPOSITE mutant: force _splice_has_existing=0 always,
  # so the strip NEVER happens. Then second run appends instead of replacing → 2 blocks.
  printf '%s\n' '-- teeth-a: SENTINEL-IDEMPOTENT mutant (always skip strip) must produce 2 blocks --'
  MUTANT_A="$TMP/install.MUT-A.sh"
  if grep -q 'SENTINEL-IDEMPOTENT' "$SUT"; then
    sed 's/local _splice_has_existing=0  # SENTINEL-IDEMPOTENT.*/local _splice_has_existing=0  # MUTATED-A (always 0 → never strips)/' \
      "$SUT" > "$MUTANT_A"
    # Now also make it so the grep update to 1 is REMOVED (it's after the sentinel line).
    # Actually: the mutant already sets it to 0; but the next line does:
    #   [ -f "$file" ] && grep -qF ... && _splice_has_existing=1
    # We need to also neutralize that assignment. Use a secondary sed to change the
    # assignment to _splice_has_existing=0 again:
    sed -i \
      's/\[ -f "\$file" \] && grep -qF "\$START_MARKER" "\$file" 2>\/dev\/null && _splice_has_existing=1/: # MUTATED-A (probe disabled)/' \
      "$MUTANT_A"

    splice_script_a="$TMP/test-splice-mut-a.sh"
    target_a="$TMP/bashrc-mut-a"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_A\"" \
      "dry=0" \
      "splice_marker \"$target_a\" 'export TEST_MUTANT=1'" \
      "splice_marker \"$target_a\" 'export TEST_MUTANT=1'" \
      > "$splice_script_a"
    bash "$splice_script_a" >/dev/null 2>&1
    mut_a_count=0
    [ -f "$target_a" ] && mut_a_count="$(grep -cF '# research-sdd:start' "$target_a" || true)"
    if [ "$mut_a_count" -ge 2 ]; then
      ok "teeth-a: SENTINEL-IDEMPOTENT mutant produces $mut_a_count blocks (idempotency guard bites)"
    else
      no "teeth-a: mutant produced $mut_a_count block(s); expected >=2" \
         "file=$(cat "$target_a" 2>/dev/null)"
    fi
    # Confirm original still produces exactly 1
    [ "$start_count" -eq 1 ] \
      && ok "teeth-a: original still produces exactly 1 block (control confirmed)" \
      || no "teeth-a: original control count changed" "start_count=$start_count"
  else
    no "teeth-a: SENTINEL-IDEMPOTENT not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth B: SENTINEL-DRY-RUN — disabling the dry-run write guard ----
  # Mutant: change `local _splice_is_dry="${dry:-0}"` so it's always 0.
  # With _splice_is_dry=0, the `if [ "$_splice_is_dry" -eq 1 ]` branch never fires,
  # so splice_marker writes the file even when dry=1.
  printf '%s\n' '-- teeth-b: SENTINEL-DRY-RUN mutant (dry guard disabled) must write file --'
  MUTANT_B="$TMP/install.MUT-B.sh"
  if grep -q 'SENTINEL-DRY-RUN' "$SUT"; then
    sed 's/local _splice_is_dry="${dry:-0}"  # SENTINEL-DRY-RUN.*/local _splice_is_dry=0  # MUTATED-B (always non-dry)/' \
      "$SUT" > "$MUTANT_B"

    target_b="$TMP/bashrc-mut-b"
    splice_script_b="$TMP/test-splice-mut-b.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_B\"" \
      "dry=1" \
      "splice_marker \"$target_b\" 'export TEST_DRY=1'" \
      > "$splice_script_b"
    bash "$splice_script_b" >/dev/null 2>&1

    if [ -f "$target_b" ]; then
      ok "teeth-b: SENTINEL-DRY-RUN mutant wrote file despite dry=1 (dry guard bites)"
    else
      no "teeth-b: mutant did NOT write file — dry guard may not be load-bearing"
    fi

    # Confirm original with dry=1 does NOT write.
    target_b_orig="$TMP/bashrc-orig-b"
    splice_script_b_orig="$TMP/test-splice-orig-b.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$SUT\"" \
      "dry=1" \
      "splice_marker \"$target_b_orig\" 'export TEST_DRY=1'" \
      > "$splice_script_b_orig"
    bash "$splice_script_b_orig" >/dev/null 2>&1
    if [ ! -f "$target_b_orig" ]; then
      ok "teeth-b: original with dry=1 does NOT write file (control confirmed)"
    else
      no "teeth-b: original wrote file with dry=1 (dry guard broken in SUT)"
    fi
  else
    no "teeth-b: SENTINEL-DRY-RUN not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth C: SENTINEL-APT-DRY — disabling apt_install dry guard calls sudo_n ----
  # Mutant: neutralize the `if [ "$dry" -eq 1 ]` early-return in apt_install.
  # With guard disabled, apt_install proceeds to call sudo_n even when dry=1.
  printf '%s\n' '-- teeth-c: SENTINEL-APT-DRY mutant (apt dry guard disabled) must call sudo_n --'
  MUTANT_C="$TMP/install.MUT-C.sh"
  if grep -q 'SENTINEL-APT-DRY' "$SUT"; then
    sed 's/  if \[ "\$dry" -eq 1 \]; then emit_plan "apt-get install -y \$pkg"; return 0; fi  # SENTINEL-APT-DRY/  if [ 0 -eq 1 ]; then emit_plan "apt-get install -y $pkg"; return 0; fi  # MUTATED-C/' \
      "$SUT" > "$MUTANT_C"

    sudo_log_c="$TMP/sudo-log-c.txt"
    apt_dry_script="$TMP/test-apt-mut-c.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_C\"" \
      "dry=1" \
      "sudo_log_c=\"$sudo_log_c\"" \
      'sudo_n() { printf "called: %s\n" "$*" >> "$sudo_log_c"; return 100; }' \
      'apt_have() { return 1; }' \
      "apt_install 'fake-pkg' || true" \
      > "$apt_dry_script"
    bash "$apt_dry_script" >/dev/null 2>&1 || true
    if [ -f "$sudo_log_c" ] && [ "$(wc -l < "$sudo_log_c")" -gt 0 ]; then
      ok "teeth-c: SENTINEL-APT-DRY mutant called sudo_n in dry=1 (apt dry guard bites)"
    else
      no "teeth-c: mutant did not call sudo_n — apt dry guard may not be load-bearing"
    fi

    # Confirm original with dry=1 does NOT call sudo_n.
    sudo_log_c_orig="$TMP/sudo-log-c-orig.txt"
    apt_dry_orig="$TMP/test-apt-orig-c.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$SUT\"" \
      "dry=1" \
      "sudo_log_c_orig=\"$sudo_log_c_orig\"" \
      'sudo_n() { printf "called: %s\n" "$*" >> "$sudo_log_c_orig"; return 100; }' \
      'apt_have() { return 1; }' \
      "apt_install 'fake-pkg' || true" \
      > "$apt_dry_orig"
    bash "$apt_dry_orig" >/dev/null 2>&1 || true
    if [ ! -f "$sudo_log_c_orig" ] || [ "$(wc -l < "$sudo_log_c_orig")" -eq 0 ]; then
      ok "teeth-c: original with dry=1 does NOT call sudo_n (control confirmed)"
    else
      no "teeth-c: original called sudo_n with dry=1 (apt dry guard broken in SUT)"
    fi
  else
    no "teeth-c: SENTINEL-APT-DRY not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth D: phase-dry stub — sudo_n never called across all phases when dry=1 ----
  # Sources SUT, stubs sudo_n to log, drives every phase with dry=1; verifies zero calls.
  printf '%s\n' '-- teeth-d: phase-dry stub (sudo_n never called across all phases when dry=1) --'
  sudo_log_d="$TMP/sudo-log-d.txt"
  phase_stub="$TMP/test-phase-dry-stub.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    "source \"$SUT\"" \
    "dry=1" \
    "sudo_log_d=\"$sudo_log_d\"" \
    'sudo_n() { printf "called: %s\n" "$*" >> "$sudo_log_d"; return 100; }' \
    'apt_have() { return 1; }' \
    'have() { return 1; }' \
    'node_ok() { return 1; }' \
    'tier_binary=1; tier_pcap=1; tier_firmware=1; tier_vm=1' \
    'tier_pdf=1; tier_net=1; tier_dotnet=1; tier_latex=1' \
    'phase_binary   || true' \
    'phase_pcap     || true' \
    'phase_firmware || true' \
    'phase_vm       || true' \
    'phase_pdf      || true' \
    'phase_net      || true' \
    'phase_dotnet   || true' \
    'phase_latex    || true' \
    "apt_install 'any-pkg' || true" \
    'install_nodejs || true' \
    'install_pipx   || true' \
    > "$phase_stub"
  bash "$phase_stub" >/dev/null 2>&1 || true
  if [ ! -f "$sudo_log_d" ] || [ "$(wc -l < "$sudo_log_d")" -eq 0 ]; then
    ok "teeth-d: sudo_n never called across all phases with dry=1"
  else
    no "teeth-d: sudo_n called despite dry=1 — dry guard missing in a phase" \
       "$(cat "$sudo_log_d" 2>/dev/null)"
  fi

  # ---- Tooth E: SENTINEL-PDF-DRY — phase_pdf dry guard protects venv creation ----
  # Mutant: neutralize `if [ "$dry" -eq 1 ]; then  # SENTINEL-PDF-DRY`.
  # With guard disabled, --dry-run --with-pdf creates a real venv → writes files.
  printf '%s\n' '-- teeth-e: SENTINEL-PDF-DRY mutant (phase_pdf dry guard disabled) must write files --'
  MUTANT_E="$TMP/install.MUT-E.sh"
  if grep -q 'SENTINEL-PDF-DRY' "$SUT"; then
    sed 's/if \[ "\$dry" -eq 1 \]; then  # SENTINEL-PDF-DRY/if [ 0 -eq 1 ]; then  # MUTATED-E/' \
      "$SUT" > "$MUTANT_E"

    pdf_scratch_home="$TMP/pdf-scratch-home-e"
    pdf_kit_home="$TMP/pdf-kit-home-e"
    mkdir -p "$pdf_scratch_home" "$pdf_kit_home"
    HOME="$pdf_scratch_home" bash "$MUTANT_E" --dry-run --with-pdf \
      --home "$pdf_kit_home" --harness claude >/dev/null 2>&1 || true
    mut_e_count="$(find "$pdf_scratch_home" "$pdf_kit_home" -mindepth 1 | wc -l)"
    if [ "$mut_e_count" -gt 0 ]; then
      ok "teeth-e: SENTINEL-PDF-DRY mutant wrote ${mut_e_count} file(s) (pdf dry guard bites)"
    else
      no "teeth-e: mutant wrote 0 files — pdf dry guard may not be load-bearing"
    fi

    # Confirm original with --dry-run --with-pdf writes 0 files.
    pdf_scratch_orig="$TMP/pdf-scratch-orig-e"
    pdf_kit_orig="$TMP/pdf-kit-orig-e"
    mkdir -p "$pdf_scratch_orig" "$pdf_kit_orig"
    HOME="$pdf_scratch_orig" bash "$SUT" --dry-run --with-pdf \
      --home "$pdf_kit_orig" --harness claude >/dev/null 2>&1 || true
    orig_e_count="$(find "$pdf_scratch_orig" "$pdf_kit_orig" -mindepth 1 | wc -l)"
    if [ "$orig_e_count" -eq 0 ]; then
      ok "teeth-e: original --dry-run --with-pdf writes 0 files (control confirmed)"
    else
      no "teeth-e: original wrote ${orig_e_count} file(s) under --dry-run --with-pdf (SENTINEL-PDF-DRY broken)"
    fi
  else
    no "teeth-e: SENTINEL-PDF-DRY not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth F: SENTINEL-ORPHAN-SKIP — disabling skip causes data loss on run 2 ----
  # Mutant: neutralize `if [ "$_splice_aw" -eq 3 ]; then  # SENTINEL-ORPHAN-SKIP`.
  # With guard disabled, orphan handling falls through to append; run 2 then strips
  # the orphan-start..appended-end pair, silently deleting USER_MID content.
  printf '%s\n' '-- teeth-f: SENTINEL-ORPHAN-SKIP mutant (append on orphan) must lose content by run 2 --'
  MUTANT_F="$TMP/install.MUT-F.sh"
  if grep -q 'SENTINEL-ORPHAN-SKIP' "$SUT"; then
    sed 's/if \[ "\$_splice_aw" -eq 3 \]; then  # SENTINEL-ORPHAN-SKIP/if [ 0 -eq 3 ]; then  # MUTATED-F/' \
      "$SUT" > "$MUTANT_F"

    orphan_f="$TMP/bashrc-orphan-f"
    printf '%s\n' \
      'BEFORE_F=1' \
      '# research-sdd:start' \
      'ORPHAN_MID=1' \
      'AFTER_F=2' \
      > "$orphan_f"
    orphan_f_script="$TMP/test-splice-mut-f.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_F\"" \
      "dry=0" \
      "f=\"$orphan_f\"" \
      "splice_marker \"\$f\" 'export MUT_F=1' || true" \
      "splice_marker \"\$f\" 'export MUT_F=1' || true" \
      > "$orphan_f_script"
    bash "$orphan_f_script" >/dev/null 2>&1 || true
    if ! grep -qF 'ORPHAN_MID=1' "$orphan_f" 2>/dev/null; then
      ok "teeth-f: SENTINEL-ORPHAN-SKIP mutant lost ORPHAN_MID on run 2 (skip guard bites)"
    else
      no "teeth-f: mutant still has ORPHAN_MID — orphan skip guard may not be load-bearing" \
         "$(cat "$orphan_f" 2>/dev/null)"
    fi

    # Confirm original preserves ORPHAN_MID after two runs.
    orphan_f_orig="$TMP/bashrc-orphan-f-orig"
    printf '%s\n' \
      'BEFORE_F=1' \
      '# research-sdd:start' \
      'ORPHAN_MID=1' \
      'AFTER_F=2' \
      > "$orphan_f_orig"
    orphan_f_orig_script="$TMP/test-splice-orig-f.sh"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$SUT\"" \
      "dry=0" \
      "f=\"$orphan_f_orig\"" \
      "splice_marker \"\$f\" 'export MUT_F=1' || true" \
      "splice_marker \"\$f\" 'export MUT_F=1' || true" \
      > "$orphan_f_orig_script"
    bash "$orphan_f_orig_script" >/dev/null 2>&1 || true
    if grep -qF 'ORPHAN_MID=1' "$orphan_f_orig" 2>/dev/null; then
      ok "teeth-f: original preserves ORPHAN_MID after two runs (control confirmed)"
    else
      no "teeth-f: original lost ORPHAN_MID — orphan skip guard broken in SUT" \
         "$(cat "$orphan_f_orig" 2>/dev/null)"
    fi
  else
    no "teeth-f: SENTINEL-ORPHAN-SKIP not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth G: SENTINEL-GREP-AV-ANCHOR — un-anchoring the regex counts legend lines ----
  # Mutant: replace the anchored _av_re with bare 'AVAILABLE', so the legend line
  # "Note: AVAILABLE means..." is counted as an AVAILABLE tool row → reports 4|4 not 3|3.
  printf '%s\n' '-- teeth-g: SENTINEL-GREP-AV-ANCHOR mutant (un-anchored regex) must report 4|4 --'
  MUTANT_G="$TMP/install.MUT-G.sh"
  if grep -q 'SENTINEL-GREP-AV-ANCHOR' "$SUT"; then
    sed "s/local _av_re='.*'  # SENTINEL-GREP-AV-ANCHOR/local _av_re='AVAILABLE'  # MUTATED-G/" \
      "$SUT" > "$MUTANT_G"

    mut_g_script="$TMP/test-summary-mut-g.sh"
    mut_g_home="$TMP/summary-home-mut-g"
    mkdir -p "$mut_g_home"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_G\"" \
      "SELF=\"$stub_install8\"" \
      "KIT=\"$stub_kit8\"" \
      'apt_have() { return 0; }' \
      'have()     { return 0; }' \
      'node_ok()  { return 0; }' \
      'sudo_n()   { return 100; }' \
      "export RESEARCH_TOOLS_CACHE=\"$fixture_cache8\"" \
      "main --home \"$mut_g_home\" --harness claude" \
      > "$mut_g_script"
    mut_g_out="$(bash "$mut_g_script" 2>/dev/null || true)"
    if printf '%s' "$mut_g_out" | grep -qF 'AVAILABLE: 4'; then
      ok "teeth-g: SENTINEL-GREP-AV-ANCHOR mutant reports 4 AVAILABLE (legend line counted; anchor bites)"
    else
      mut_g_line="$(printf '%s' "$mut_g_out" | grep 'SUMMARY' || true)"
      no "teeth-g: mutant did not report AVAILABLE: 4 — anchor may not be load-bearing" \
         "got: $mut_g_line"
    fi

    # Confirm original still reports 3 AVAILABLE (control).
    if printf '%s' "$summary_out8" | grep -qF 'AVAILABLE: 3'; then
      ok "teeth-g: original reports AVAILABLE: 3 (control confirmed; legend excluded)"
    else
      orig_g_line="$(printf '%s' "$summary_out8" | grep 'SUMMARY' || true)"
      no "teeth-g: original does not report AVAILABLE: 3 (SUT anchor broken)" \
         "got: $orig_g_line"
    fi
  else
    no "teeth-g: SENTINEL-GREP-AV-ANCHOR not found in SUT (cannot anchor mutation)"
  fi

  # ---- Tooth H: SENTINEL-SKILL-DEPLOY — restoring || true swallows deploy failure ----
  # Mutant: change `|| _baseline_ok=0  # SENTINEL-SKILL-DEPLOY` back to `|| true`.
  # With || true, a failing installer leaves _baseline_ok=1 → BASELINE OK + exit 0.
  printf '%s\n' '-- teeth-h: SENTINEL-SKILL-DEPLOY mutant (|| true restored) must report BASELINE OK exit 0 --'
  MUTANT_H="$TMP/install.MUT-H.sh"
  if grep -q 'SENTINEL-SKILL-DEPLOY' "$SUT"; then
    sed 's/|| _baseline_ok=0  # SENTINEL-SKILL-DEPLOY/|| true  # MUTATED-H/' \
      "$SUT" > "$MUTANT_H"

    mut_h_script="$TMP/test-summary-mut-h.sh"
    mut_h_home="$TMP/summary-home-mut-h"
    mkdir -p "$mut_h_home"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -uo pipefail' \
      "source \"$MUTANT_H\"" \
      "SELF=\"$stub_install9\"" \
      "KIT=\"$stub_kit8\"" \
      'apt_have() { return 0; }' \
      'have()     { return 0; }' \
      'node_ok()  { return 0; }' \
      'sudo_n()   { return 100; }' \
      "export RESEARCH_TOOLS_CACHE=\"$fixture_cache8\"" \
      "main --home \"$mut_h_home\" --harness claude" \
      > "$mut_h_script"
    mut_h_out="$(bash "$mut_h_script" 2>&1)"; mut_h_rc=$?
    if [ "$mut_h_rc" -eq 0 ] && printf '%s' "$mut_h_out" | grep -q 'BASELINE OK'; then
      ok "teeth-h: SENTINEL-SKILL-DEPLOY mutant reports BASELINE OK exit 0 (deploy-failure guard bites)"
    else
      mut_h_line="$(printf '%s' "$mut_h_out" | grep 'SUMMARY' || true)"
      no "teeth-h: mutant did not report BASELINE OK exit 0 — deploy-failure guard may not be load-bearing" \
         "rc=$mut_h_rc summary=$mut_h_line"
    fi

    # Confirm original (fixed SUT) reports BASELINE DEGRADED + non-zero exit (control).
    if [ "$summary_rc9" -ne 0 ] && printf '%s' "$summary_out9" | grep -q 'BASELINE DEGRADED'; then
      ok "teeth-h: original (fixed SUT) reports BASELINE DEGRADED + non-zero exit (control confirmed)"
    else
      no "teeth-h: original SUT control failed — fix not in place?" \
         "rc=$summary_rc9 summary=$(printf '%s' "$summary_out9" | grep 'SUMMARY' || true)"
    fi
  else
    no "teeth-h: SENTINEL-SKILL-DEPLOY not found in SUT (cannot anchor mutation)"
  fi
fi

# --------------------------------------------------------------------------
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { printf 'FATAL: zero tests executed\n' >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
