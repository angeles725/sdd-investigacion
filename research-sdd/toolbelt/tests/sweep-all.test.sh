#!/usr/bin/env bash
# sweep-all.test.sh — RED-first harness for sweep-all.sh (U-A20).
#
# Assertions (in order):
#   1. sweep-all.sh exists on disk
#   2. sweep-all.sh is executable
#   3. All-pass: all canonical stubs exit 0 → sweep-all exits 0
#   4. One-fail: one stub exits 1 → sweep-all exits non-zero
#   5. Run-all: even when one stub fails, all canonical stubs are called (no early bail)
#   6. Banners: PASS banner for passing script; FAIL banner for failing script
#   7. Timeout: a hanging stub is killed after timeout → sweep-all exits non-zero
#   8. Timeout-banner: the FAIL banner includes a timeout indication for the killed script
#   9. Parity: sweep-all's list == the kit's registered SessionStart hook set == CANONICAL
#  10. Real scripts: every script sweep-all lists exists and is executable in the real toolbelt
#
# Behavioral tests 3-8 are implemented by copying sweep-all.sh into a temp dir
# alongside stub replacements of the canonical scripts, so sweep-all.sh's own
# TOOLBELT=$(dirname $0) resolution finds the stubs rather than the real scripts.
#
# Usage: sweep-all.test.sh
# Exit : 0 all held · 1 regression · 2 harness error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
SUT="$TOOLBELT/sweep-all.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-all.test.sh =="

# ---- 1. Existence ----------------------------------------------------------
[ -f "$SUT" ] \
  && ok "1 sweep-all.sh exists at $SUT" \
  || no "1 sweep-all.sh NOT found at $SUT"

# ---- 2. Executable ---------------------------------------------------------
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 sweep-all.sh is executable" \
  || no "2 sweep-all.sh is NOT executable (missing +x bit)"

# ---- Bail early if SUT is missing: behavioral tests need it ----------------
if [ ! -f "$SUT" ]; then
  # Derived from this header's numbered assertion list (3 and up) so the bail count cannot drift.
  for n in $(sed -nE 's/^#[[:space:]]+([0-9]+)\..*/\1/p' "$0" | awk '$1>=3'); do
    no "$n (skipped: sweep-all.sh missing — cannot test behavior)"
  done
  echo "== $pass passed · $fail failed =="
  exit 1
fi

# ---- Temp workspace --------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/toolbelt"
mkdir -p "$FAKE"
cp "$SUT" "$FAKE/sweep-all.sh"
chmod +x "$FAKE/sweep-all.sh"

CANONICAL=(sweep-retros.sh sweep-audits.sh sweep-breakthroughs.sh verify-registry.sh verify-kit-clean.sh sweep-tools.sh verify-tool-catalog.sh verify-skill-drift.sh)

# make_stub <name> <exit_code> — write a stub script that logs its name then exits
make_stub() {
  local name="$1" rc="${2:-0}"
  printf '#!/usr/bin/env bash\necho "stub:%s"\nexit %s\n' "$name" "$rc" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# make_logging_stub <name> <exit_code> <log_file> — stub that logs call to a file
make_logging_stub() {
  local name="$1" rc="$2" log="$3"
  printf '#!/usr/bin/env bash\necho "%s" >> %s\necho "stub:%s"\nexit %s\n' \
    "$name" "$log" "$name" "$rc" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# make_hanging_stub <name> <log_file> — stub that logs its name then sleeps forever
make_hanging_stub() {
  local name="$1" log="$2"
  printf '#!/usr/bin/env bash\necho "%s" >> %s\necho "stub:%s hanging"\nsleep 9999\n' \
    "$name" "$log" "$name" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# ---- 3. All-pass → exit 0 --------------------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
  && ok "3 all-pass: all ${#CANONICAL[@]} stubs pass → sweep-all exits 0" \
  || no "3 all-pass: expected exit 0 got $RC (out=[$OUT])"

# ---- 4. One-fail → exit non-zero ------------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
make_stub "sweep-audits.sh" 1   # override one to fail
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "4 one-fail: sweep-audits.sh exits 1 → sweep-all exits non-zero (rc=$RC)" \
  || no "4 one-fail: expected non-zero exit, got 0 (out=[$OUT])"

# ---- 5. Run-all: all N called even when one fails --------------------------
CALL_LOG="$TMP/call5.log"; rm -f "$CALL_LOG"
for s in "${CANONICAL[@]}"; do
  make_logging_stub "$s" 0 "$CALL_LOG"
done
# Override sweep-audits.sh to fail (still log its call first)
make_logging_stub "sweep-audits.sh" 1 "$CALL_LOG"
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
called_count="$(grep -c '^' "$CALL_LOG" 2>/dev/null || echo 0)"
# Derived from ${#CANONICAL[@]} rather than a hardcoded literal: a hardcoded expected count is
# exactly the magic-number drift class that bit this suite when the canonical set last grew.
[ "$called_count" -eq "${#CANONICAL[@]}" ] && [ "$RC" -ne 0 ] \
  && ok "5 run-all: all ${#CANONICAL[@]} stubs called despite failure (calls=$called_count, rc=$RC)" \
  || no "5 run-all: expected calls=${#CANONICAL[@]} rc!=0, got calls=$called_count rc=$RC (out=[$OUT])"

# ---- 6. PASS/FAIL banners per script ---------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
make_stub "sweep-retros.sh" 1   # retros fails; others pass
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"
pass_banner=0; fail_banner=0
<<<"$OUT" grep -qiE 'PASS.*sweep-audits' && pass_banner=1
<<<"$OUT" grep -qiE 'FAIL.*sweep-retros' && fail_banner=1
[ "$pass_banner" -eq 1 ] && [ "$fail_banner" -eq 1 ] \
  && ok "6 banners: PASS for passing scripts, FAIL for failing scripts" \
  || no "6 banners: expected PASS(sweep-audits) and FAIL(sweep-retros) in output (out=[$OUT])"

# ---- 7. Timeout → exits non-zero after short timeout ----------------------
CALL_LOG7="$TMP/call7.log"; rm -f "$CALL_LOG7"
for s in "${CANONICAL[@]}"; do
  make_logging_stub "$s" 0 "$CALL_LOG7"
done
# Override sweep-audits.sh (second script) to hang after logging its call
make_hanging_stub "sweep-audits.sh" "$CALL_LOG7"
# Use a 1-second timeout so the test completes quickly
OUT="$(RSDD_SWEEP_TIMEOUT=1 bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "7 timeout: hanging stub killed → sweep-all exits non-zero (rc=$RC)" \
  || no "7 timeout: expected non-zero exit after timeout, got 0"

# ---- 8. Timeout banner includes timeout indication -------------------------
<<<"$OUT" grep -qiE 'FAIL.*sweep-audits.*(timeout|timed)' \
  && ok "8 timeout-banner: FAIL banner mentions timeout for killed script" \
  || no "8 timeout-banner: expected FAIL+timeout indication (out=[$OUT])"

# ---- 9. SessionStart-set parity (both directions) --------------------------
# sweep-all.sh is the manual stand-in for Claude's SessionStart hooks, so its script list must equal
# the set the kit's own .claude/settings.json registers (each <name>-hook.sh maps to <name>.sh). A hook
# added without a sweep-all entry (or the reverse) is exactly how verify-skill-drift went unwired.
SETTINGS="$TOOLBELT/../../.claude/settings.json"
# listed_scripts <sweep-all-path> — the unique, sorted script names the file lists as "$TOOLBELT/<name>.sh".
# The single extraction pipeline for tests 9 and 10 and their teeth (kit issue #1787).
listed_scripts() {
  grep -oE '\$TOOLBELT/[A-Za-z0-9_.-]+\.sh' "$1" | sed 's#^\$TOOLBELT/##' | sort -u
}
# parity_diff <sweep-all-path> — prints the divergence ("registered-only=[..] sweep-all-only=[..]");
# empty output means the two sets are equal. rc 2 = could not extract a set (never a silent pass).
parity_diff() {
  local sut="$1" reg mine only_reg only_sa
  reg="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for grp in d.get("hooks", {}).get("SessionStart", []):
    for h in grp.get("hooks", []):
        m = re.search(r"toolbelt/([A-Za-z0-9_.-]+)-hook\.sh", h.get("command", ""))
        if m:
            print(m.group(1) + ".sh")
PY
)"
  reg="$(printf '%s\n' "$reg" | sort -u)"
  mine="$(listed_scripts "$sut")"
  if [ -z "$reg" ] || [ -z "$mine" ]; then
    echo "could not extract a set (registered=[${reg//$'\n'/ }] sweep-all=[${mine//$'\n'/ }])"; return 2
  fi
  only_reg="$(comm -23 <(printf '%s\n' "$reg") <(printf '%s\n' "$mine") | tr '\n' ' ')"
  only_sa="$(comm -13 <(printf '%s\n' "$reg") <(printf '%s\n' "$mine") | tr '\n' ' ')"
  [ -z "$only_reg" ] && [ -z "$only_sa" ] || echo "registered-only=[$only_reg] sweep-all-only=[$only_sa]"
}
if [ ! -f "$SETTINGS" ]; then
  no "9 parity: $SETTINGS not found (cannot prove the SessionStart set)"
else
  diff9="$(parity_diff "$SUT")"; rc9=$?
  canon="$(printf '%s\n' "${CANONICAL[@]}" | sort -u)"
  mine9="$(listed_scripts "$SUT")"
  [ "$rc9" -eq 0 ] && [ -z "$diff9" ] && [ "$canon" = "$mine9" ] \
    && ok "9 parity: sweep-all script list == registered SessionStart hook set == test CANONICAL" \
    || no "9 parity: $diff9 (rc=$rc9, canonical-equals-sut=$([ "$canon" = "$mine9" ] && echo y || echo n))"
fi

# ---- 10. Every listed script exists + is executable in the REAL toolbelt -----
# Tests 3-8 stub every script, so nothing else proves the real list resolves; a missing script would
# FAIL every real sweep. missing_real <sweep-all-path> lists the entries absent / non-executable here.
missing_real() {
  local f
  while IFS= read -r f; do
    [ -f "$TOOLBELT/$f" ] && [ -x "$TOOLBELT/$f" ] || printf '%s ' "$f"
  done < <(listed_scripts "$1")
}
listed10="$(listed_scripts "$SUT" | grep -c '^')"
miss10="$(missing_real "$SUT")"
[ "$listed10" -gt 0 ] && [ -z "$miss10" ] \
  && ok "10 real-scripts: all $listed10 listed scripts exist and are executable in the real toolbelt" \
  || no "10 real-scripts: listed=$listed10 missing-or-not-executable=[$miss10]"

# ---- Teeth: prove run-all invariant catches a dropped script ----------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # Sourced only here: a plain run never depends on the mutation helper.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  echo "-- teeth: early-bail mutant must be caught by run-all assertion --"
  CALL_LOG_T="$TMP/callT.log"; rm -f "$CALL_LOG_T"
  for s in "${CANONICAL[@]}"; do make_logging_stub "$s" 0 "$CALL_LOG_T"; done
  # Mutant sweep-all.sh: exits immediately after first script passes (dropping the rest).
  # Built through lib/mutant.sh (refuses a dead stage, an identical/empty/syntax-broken or live-tree
  # mutant). It lives beside the stubs in $FAKE so they resolve: the shortfall below is the `break`,
  # not missing stubs.
  if ! mutant_chain "teeth: early-bail mutant build" "$SUT" "$FAKE/mutant-sweep-all.sh" '/^for script/a\  break'; then
    no "teeth: could not build early-bail mutant (anchor drifted or refused by lib/mutant.sh)"
    echo "== $pass passed · $fail failed =="
    exit 1
  fi
  chmod +x "$FAKE/mutant-sweep-all.sh"
  # The verdict needs the mutant's typed early-bail shape, not just "few calls": a mutant that crashes
  # before calling any stub also logs 0 calls and would read as a bite (kit issue #1576). A clean
  # early-bail runs to the end: exit 0 (nothing failed), the summary header printed, and no per-script
  # PASS/FAIL line (the loop body never ran).
  mutant_out="$(bash "$FAKE/mutant-sweep-all.sh" 2>&1)"; mutant_rc=$?
  mutant_calls="$(grep -c '^' "$CALL_LOG_T" 2>/dev/null || echo 0)"
  mutant_banners="$(printf '%s\n' "$mutant_out" | grep -cE '^(PASS|FAIL)  ')"
  if [ "$mutant_rc" -eq 0 ] && [ "$mutant_banners" -eq 0 ] \
     && <<<"$mutant_out" grep -qF '== sweep-all summary' \
     && [ "$mutant_calls" -lt "${#CANONICAL[@]}" ]; then
    ok "teeth: early-bail mutant calls $mutant_calls < ${#CANONICAL[@]} with a clean early-bail (rc=0, summary printed, 0 banners) → run-all check would catch it (RED)"
  else
    no "teeth: early-bail mutant not a clean early-bail (rc=$mutant_rc calls=$mutant_calls banners=$mutant_banners) — run-all check is THEATER or the mutant crashed (out=[$mutant_out])"
  fi
  # Parity teeth: dropping one script (the original gap) and adding an unregistered one must each diverge.
  if mutant_chain "teeth: parity drop-script mutant build" "$SUT" "$FAKE/mutant-drop.sh" '/verify-skill-drift\.sh"/d'; then
    d="$(parity_diff "$FAKE/mutant-drop.sh")"
    [ -n "$d" ] && ok "teeth: dropped script is reported by parity ($d)" || no "teeth: parity did not notice a dropped script — THEATER"
  else no "teeth: could not build parity drop mutant"; fi
  if mutant_chain "teeth: parity extra-script mutant build" "$SUT" "$FAKE/mutant-extra.sh" '/verify-skill-drift\.sh"/a\  "$TOOLBELT/not-a-hook.sh"'; then
    d="$(parity_diff "$FAKE/mutant-extra.sh")"
    [ -n "$d" ] && ok "teeth: extra script is reported by parity ($d)" || no "teeth: parity did not notice an extra script — THEATER"
  else no "teeth: could not build parity extra mutant"; fi
  if mutant_chain "teeth: missing-script mutant build" "$SUT" "$FAKE/mutant-missing.sh" '/verify-skill-drift\.sh"/a\  "$TOOLBELT/does-not-exist.sh"'; then
    d="$(missing_real "$FAKE/mutant-missing.sh")"
    [ -n "$d" ] && ok "teeth: nonexistent listed script is reported by real-script check ($d)" || no "teeth: real-script check did not notice a missing script — THEATER"
  else no "teeth: could not build missing-script mutant"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
