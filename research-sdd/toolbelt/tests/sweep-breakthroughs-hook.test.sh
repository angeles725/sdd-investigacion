#!/usr/bin/env bash
# sweep-breakthroughs-hook.test.sh — harness for sweep-breakthroughs-hook.sh, now a shim to `rsdd sweep breakthroughs
# --hook` (kit issue #2360).
#
# Covers the SHIM contract: existence and the executable bit; the arguments handed to the binary (`sweep breakthroughs
# --hook --kit <own kit>`, then every caller argument); output and exit code passed through; a symlinked invocation;
# an unusable binary → the SessionStart DEGRADED headline and exit 0 (a hook never fails the session), a missing lib →
# an announced line, never silence; and the real Go binary end to end on a mini kit (the envelope, the collapsed
# unindexed line, --full, the failure banner).
# The summary filter, the headers, the exit-0 rule and the envelope bytes are pinned in Go (rsdd/internal/sweep,
# breakthroughs_unit_test.go (breakthroughsSummaryFilter, breakthroughsHookContext), plus a differential against the
# frozen script and a golden recorded from it), not here. The old suite stubbed sweep-breakthroughs.sh beside the
# hook; the sweep runs in process now, so that seam is gone and the pure functions are tested directly. The map from
# every old case to its Go test is L4 of odd/tasks/sweep-breakthroughs-go.md.
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate
# (`make teeth` in research-sdd/rsdd).
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
SUT="$HERE/../sweep-breakthroughs-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-breakthroughs-hook.test.sh =="

# 1. Existence and 2. executable
[ -f "$SUT" ] && ok "1 hook exists at $SUT" || no "1 hook NOT found at $SUT"
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "2 hook is executable" || no "2 hook NOT executable (missing +x bit)"
if [ ! -f "$SUT" ]; then echo "== $pass passed · $fail failed =="; exit 2; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset RSDD_RETRO_AGE_DAYS RESEARCH_HOME

# The real binary for the end-to-end cases: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_kit DEST [SHIM] — a mini kit: the hook shim (the real one, or a mutant) and every toolbelt lib (the shim
# sources lib/rsdd-exec.sh and, when degraded, lib/hook-emit.sh). The toolbelt is DEST/toolbelt.
stage_kit() {
  mkdir -p "$1/toolbelt"
  cp "${2:-$SUT}" "$1/toolbelt/sweep-breakthroughs-hook.sh"; chmod +x "$1/toolbelt/sweep-breakthroughs-hook.sh"
  rsdd_stage_libs "$1/toolbelt" || exit 2
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}
# ctx JSON — the decoded additionalContext of a SessionStart envelope.
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

stage_kit "$TMP/kit"; SHIM="$TMP/kit/toolbelt/sweep-breakthroughs-hook.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 3 — the binary gets `sweep breakthroughs --hook --kit <own kit>` and then the caller's arguments, byte for byte.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" --full >/dev/null 2>&1
want="$(printf '%s\n' sweep breakthroughs --hook --kit "$PHYS/.." --full)"
if [ "$(cat "$TMP/args")" = "$want" ]; then ok "3 binary called as 'sweep breakthroughs --hook --kit <own kit>' + the caller's arguments verbatim"
else no "3 arguments differ: [$(tr '\n' '|' < "$TMP/args")]"; fi

# 4 — output and exit code pass through unchanged.
stub_bin 0 "from the binary
"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = "from the binary" ]; then ok "4 output and exit code pass through"; else no "4 passthrough differs (rc=$RC out=[$OUT])"; fi

# 5 — invoked through a symlink in another directory, the shim still names its REAL kit.
mkdir -p "$TMP/elsewhere"; ln -s "$SHIM" "$TMP/elsewhere/link.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link.sh" >/dev/null 2>&1
if [ "$(sed -n 5p "$TMP/args")" = "$PHYS/.." ]; then ok "5 symlinked shim → binary gets the physical own kit"; else no "5 symlink: args=[$(tr '\n' '|' < "$TMP/args")]"; fi

# 6 — an unusable RSDD_BIN → exit 0 (a hook never fails the session), the typed degraded line on stderr and the
# SessionStart DEGRADED headline on stdout.
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$SHIM" 2>"$TMP/err6")"; RC=$?
if [ "$RC" = 0 ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6" \
   && [ "$(ctx "$OUT")" = "Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: $TMP/does-not-exist" ]; then
  ok "6 unusable RSDD_BIN → exit 0, typed degraded line, DEGRADED headline as additionalContext"
else no "6 unusable binary: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# 7 — the shim's own lib missing → the missing-lib line on stdout, exit 0, never an empty stdout.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/sweep-breakthroughs-hook.sh"
OUT="$(bash "$TMP/nolib/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = "Research-SDD hook: lib/rsdd-exec.sh missing beside $TMP/nolib/sweep-breakthroughs-hook.sh" ]; then
  ok "7 missing rsdd-exec.sh → announced on stdout, exit 0"
else no "7 missing lib: rc=$RC out=[$OUT]"; fi

# ---- the real binary, end to end on the mini kit ----
real() { env RSDD_BIN="$REAL_BIN" bash "$SHIM" "$@"; }
T1="$TMP/t1"; mkdir -p "$T1"
printf '# Block 1\n\n> **Breakthrough:** cracked it\n' > "$T1/pfx-block1.md"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `%s` |\n| 2 | t2 | `%s/absent` |\n' "$T1" "$TMP" > "$TMP/kit/TARGETS.md"
printf '| # | target | what | how |\n|---|---|---|---|\n' > "$TMP/kit/BREAKTHROUGHS.md"

# 8 — an unindexed breakthrough and an absent target: a SessionStart envelope whose context holds the header, the
# collapsed unindexed line, the Summary and the absent aggregate pointing at --full.
OUT="$(real 2>"$TMP/err8")"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && [ ! -s "$TMP/err8" ] && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" = SessionStart ] \
   && [ "$(head -n 1 <<<"$C")" = 'Research-SDD breakthrough ledger sweep (§22):' ] \
   && grep -q '^Summary: 1 tagged breakthrough(s) across corpora · 1 unindexed' <<<"$C" \
   && grep -qF 'WARN: 1 unindexed breakthrough(s) not in BREAKTHROUGHS.md: t1/pfx-block1.md:3 — add a row each' <<<"$C" \
   && grep -q '^INFO: 1 target(s) not traversed (absent-input).*run --full to list them\.$' <<<"$C" \
   && ! grep -q 'corpus not found' <<<"$C"; then
  ok "8 end to end: envelope, header, collapsed unindexed line, summary, absent aggregate"
else no "8 summary mode: rc=$RC out=[$OUT] err=[$(cat "$TMP/err8")]"; fi

# 9 — --full keeps the per-target absent-input line, byte for byte what the sweep printed.
OUT="$(real --full 2>"$TMP/err9")"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && [ ! -s "$TMP/err9" ] && grep -qxF "INFO: corpus not found (absent-input): $TMP/absent" <<<"$C" \
   && grep -q '^WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: ' <<<"$C"; then
  ok "9 end to end: --full passes the per-target lines through"
else no "9 --full: rc=$RC out=[$OUT] err=[$(cat "$TMP/err9")]"; fi

# 10 — a sweep that cannot run (no TARGETS.md) → exit 0 and the failure banner with the sweep's own message.
mv "$TMP/kit/TARGETS.md" "$TMP/targets.keep"
OUT="$(real 2>/dev/null)"; RC=$?
KITPHYS="$(cd -P "$TMP/kit" && pwd -P)"
if [ "$RC" = 0 ] && [ "$(ctx "$OUT")" = "Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):
sweep-breakthroughs: cannot find $KITPHYS/TARGETS.md" ]; then
  ok "10 failing sweep → exit 0 and the 'breakthroughs sweep could not run' banner"
else no "10 failing sweep: rc=$RC out=[$OUT]"; fi
mv "$TMP/targets.keep" "$TMP/kit/TARGETS.md"

# NEGATIVE CONTROL — each shim mutation must lose its case.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the hook mode is no longer asked for → case 3 (the binary would print the CLI report, not an envelope).
  if mk_mut "teeth A: --hook dropped" "$SUT" "$TMP/mutA.sh" 's/ --hook --kit/ --kit/'; then
    stage_kit "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/sweep-breakthroughs-hook.sh" >/dev/null 2>&1
    if ! grep -qx -- '--hook' "$TMP/args"; then ok "teeth A: --hook dropped → case 3 would go RED"; else no "teeth A: mutant still passes --hook"; fi
  fi
  # B: the own kit is no longer handed over → case 3.
  if mk_mut "teeth B: --kit dropped" "$SUT" "$TMP/mutB.sh" 's/ --kit "\$_RSDD_SELF\/\.\."//'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/sweep-breakthroughs-hook.sh" >/dev/null 2>&1
    if ! grep -qx -- '--kit' "$TMP/args"; then ok "teeth B: --kit dropped → case 3 would go RED"; else no "teeth B: mutant still passes --kit"; fi
  fi
  # C: the caller's arguments are dropped → case 3 (the caller argument would no longer reach the binary).
  if mk_mut "teeth C: arguments dropped" "$SUT" "$TMP/mutC.sh" 's/"\$@"$//'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mC/toolbelt/sweep-breakthroughs-hook.sh" --full >/dev/null 2>&1
    if ! grep -qx -- '--full' "$TMP/args"; then ok "teeth C: arguments dropped → case 3 would go RED"; else no "teeth C: mutant still passes the arguments"; fi
  fi
  # D: the hook runs as a plain exec (the degraded mode of rsdd_exec_hook is lost) → case 6 sees exit 2, no headline.
  if mk_mut "teeth D: not a hook exec" "$SUT" "$TMP/mutD.sh" 's/rsdd_exec_hook sweep sweep breakthroughs/rsdd_exec sweep breakthroughs/'; then
    stage_kit "$TMP/mD" "$TMP/mutD.sh"
    OUTD="$(RSDD_BIN="$TMP/does-not-exist" bash "$TMP/mD/toolbelt/sweep-breakthroughs-hook.sh" 2>/dev/null)"; RCD=$?
    if [ "$RCD" != 0 ] || [ -z "$OUTD" ]; then ok "teeth D: plain rsdd_exec loses the exit-0 DEGRADED headline → case 6 would go RED"; else no "teeth D: mutant still degrades like a hook"; fi
  fi
  # E: the missing-lib guard stripped → nothing announced → case 7.
  if mk_mut "teeth E: guard removed" "$SUT" "$TMP/mutE.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    mkdir -p "$TMP/mE"; cp "$TMP/mutE.sh" "$TMP/mE/sweep-breakthroughs-hook.sh"
    OUTE="$(bash "$TMP/mE/sweep-breakthroughs-hook.sh" 2>&1)"
    if ! grep -q 'lib/rsdd-exec.sh missing beside' <<<"$OUTE"; then ok "teeth E: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth E: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
