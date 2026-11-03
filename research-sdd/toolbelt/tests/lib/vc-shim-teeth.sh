#!/usr/bin/env bash
# vc-shim-teeth.sh — the mutation controls shared by the verify-corrections*.test.sh suites (kit issue #2625).
#
# verify-corrections.sh is a shim to `rsdd verify corrections`; the rules live in Go (unit and differential tests,
# `make teeth`). What a shell suite can still lose is the SHIM: the arguments it forwards, the exit code it returns,
# the command it names. vc_shim_teeth builds one mutant of the shim per property and requires the suite's fixture
# verdict to flip. Sourced ONLY on the --prove-teeth path, after lib/mutant.sh.
#
# Expects in the caller: HERE (the tests dir), SUT (the shim), TMP (scratch), RSDD_BIN (the binary), the counters
# pass/fail, and mutant_bootstrap & co. from lib/mutant.sh. The fixture is its own: a one-directional correction
# (B2 declares a correction of block 1, which carries no backlink), whose report is a FAIL line and exit 1.

vc_shim_teeth() {
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || return 2
  local crash d mutant
  crash="$(mutant_crash_re bash cmd tb)" || return 2
  # The mutants sit in $TMP beside a copy of rsdd-exec.sh (the shim sources lib/rsdd-exec.sh at its own dir).
  mkdir -p "$TMP/lib"; cp "$HERE/../lib/rsdd-exec.sh" "$TMP/lib/rsdd-exec.sh"   # stage-libs-ok: the shim's one helper
  d="$TMP/vc-teeth-onedir"; mkdir -p "$d"
  printf '# Block 1\n\nOriginal claim.\n' > "$d/t-block1.md"
  printf '# Block 2\n\n> Corrects [Block 1].\n' > "$d/t-block2.md"
  # Preflight: the properties the mutants rely on. A wrong assumption is a harness error (exit 2), not a green tooth.
  local rc
  bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] || { echo "FATAL: teeth fixture: the real shim exits $rc on the one-directional corpus, want 1" >&2; return 2; }
  "$RSDD_BIN" verify registry "$d" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || { echo "FATAL: teeth preflight: 'rsdd verify registry' exits $rc on a block directory, want 2 (the wrong-command mutant assumes it)" >&2; return 2; }

  echo "-- teeth: the shim drops the caller's arguments; the target is lost (usage, exit 2) --"
  mutant="$TMP/verify-corrections.ARGS.sh"
  if mutant_chain_or_count fail "teeth: args dropped" "$SUT" "$mutant" 's/^rsdd_exec verify corrections "\$@"$/rsdd_exec verify corrections/'; then
    if mutant_tooth "teeth: args-dropping shim loses the one-directional verdict (exit 2, not 1)" 1 2 "$mutant" --orig "$SUT" \
         --good-has '^ *FAIL' --bad-lacks '^ *FAIL' --bad-lacks "$crash" -- bash @SUT@ "$d"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi

  echo "-- teeth: the shim swallows the binary's exit code (exit 0 after a FAIL) --"
  mutant="$TMP/verify-corrections.RC.sh"
  if mutant_chain_or_count fail "teeth: rc swallowed" "$SUT" "$mutant" 's/^rsdd_exec verify corrections "\$@"$/( rsdd_exec verify corrections "$@" ); exit 0/'; then
    if mutant_tooth "teeth: rc-swallowing shim reports success on a one-directional correction (exit 0)" 1 0 "$mutant" --orig "$SUT" \
         --good-has '^ *FAIL' --bad-has '^ *FAIL' --bad-lacks "$crash" -- bash @SUT@ "$d"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi

  echo "-- teeth: the shim runs another command (verify registry, exit 2 on this corpus: preflighted above) --"
  mutant="$TMP/verify-corrections.CMD.sh"
  if mutant_chain_or_count fail "teeth: wrong command" "$SUT" "$mutant" 's/^rsdd_exec verify corrections /rsdd_exec verify registry /'; then
    if mutant_tooth "teeth: wrong-command shim does not produce the corrections report" 1 2 "$mutant" --orig "$SUT" \
         --good-has '^ *FAIL' --bad-lacks '^ *FAIL' --bad-lacks "$crash" -- bash @SUT@ "$d"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi
}
