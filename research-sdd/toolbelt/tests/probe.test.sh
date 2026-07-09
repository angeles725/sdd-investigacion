#!/usr/bin/env bash
# probe.test.sh — red-first regression harness for probe.sh (DYNAMIC-phase probe
# wrapper, METHODOLOGY §12).
#
# WHY THIS SHAPE. probe.sh `run` executes a caller's READ-ONLY probe and PRESERVES
# its raw output under TARGET/sources/probes/ as [CERT-hw] evidence. The forensic
# contract is: a "preserved: … [CERT-hw]" line may print ONLY when a real file is on
# disk and the tee that wrote it succeeded. This suite pins that contract — the
# preservation guard, the atomic PIPESTATUS capture, the `--`/dash-leading path
# safety, and mkdir failure handling — WITHOUT needing any external tool (the probe
# command is a plain builtin like `echo`, so determinism comes from the shell alone).
#
# Usage: probe.test.sh                (run the suite)
#        probe.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../probe.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-52s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-52s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# run <args...> : invoke the SUT, capture stdout+stderr into OUT and exit into RC.
run() { OUT="$("$BASH_BIN" "$SUT" "$@" 2>&1)"; RC=$?; }
newtdir() { local d="$ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

echo "== probe.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — HAPPY PATH (positive control). A successful `run <dir> echo hello` must
#     leave a REAL evidence file under sources/probes/ carrying the '# probe run'
#     header and the command's output, AND print the 'preserved:' [CERT-hw] line
#     with the real rc. The fix must NOT suppress legit preservation.
tdir="$(newtdir c1-happy)"
run run "$tdir" echo hello
log1=("$tdir"/sources/probes/echo-*.txt)
if [ "$RC" = 0 ] \
   && [ -f "${log1[0]}" ] \
   && grep -q '# probe run'   "${log1[0]}" \
   && grep -q 'hello'         "${log1[0]}" \
   && grep -q 'preserved:'    <<<"$OUT" \
   && grep -q '\[CERT-hw\]'   <<<"$OUT" \
   && grep -q 'rc=0'          <<<"$OUT"; then
  ok "1 happy run → real preserved evidence + [CERT-hw] line" "(exit $RC · ${log1[0]##*/})"
else
  no "1 happy run → real preserved evidence + [CERT-hw] line" "exit=$RC log=[${log1[0]}] out=[$OUT]"
fi

# 2 — UNCREATABLE target-dir. When a path component is a FILE, mkdir -p cannot
#     create sources/probes → the wrapper must abort non-zero and print NO
#     'preserved:' line (no false [CERT-hw] claim over a file that isn't there).
afile="$ROOT/c2-file"; printf 'x' > "$afile"
run run "$afile/sub" echo hello
if [ "$RC" != 0 ] && ! grep -q 'preserved:' <<<"$OUT"; then
  ok "2 uncreatable target-dir → non-zero, no preserved claim" "(exit $RC)"
else
  no "2 uncreatable target-dir → non-zero, no preserved claim" "exit=$RC out=[$OUT]"
fi

# 3 — DASH-LEADING target-dir. A '-x' target-dir must NOT be misparsed as an
#     option by mkdir/tee; it is rejected with an honest error (exit 2) and
#     NEVER produces a 'preserved:' claim.
run run -x echo hello
if [ "$RC" = 2 ] && ! grep -q 'preserved:' <<<"$OUT"; then
  ok "3 dash-leading target-dir → exit 2, no preserved claim" "(exit $RC)"
else
  no "3 dash-leading target-dir → exit 2, no preserved claim" "exit=$RC out=[$OUT]"
fi

# 4 — tee FAILS but the FILE EXISTS. The naive `rc=${PIPESTATUS[0]}` split captures
#     the brace-group's exit (always 0), never tee's, so a mid-write tee failure
#     could seal a TRUNCATED log as [CERT-hw]. Fixture: under `ulimit -f 0` tee
#     CREATES the log (0 bytes) then dies writing it (SIGXFSZ) — file exists, write
#     failed. The wrapper must detect it (atomic PIPESTATUS capture) → non-zero exit,
#     NO 'preserved:' claim, even though the 0-byte file is on disk.
tdir="$(newtdir c4-teefail)"
out4="$( ulimit -f 0 2>/dev/null; "$BASH_BIN" "$SUT" run "$tdir" echo hello 2>&1 )"; rc4=$?
log4=("$tdir"/sources/probes/echo-*.txt)
if [ "$rc4" != 0 ] && ! grep -q 'preserved:' <<<"$out4" && [ -e "${log4[0]}" ]; then
  ok "4 tee fails but file exists → no false preserved claim" "(exit $rc4 · file present)"
else
  no "4 tee fails but file exists → no false preserved claim" "exit=$rc4 log=[${log4[0]}] out=[$out4]"
fi

# 5 — BAD ARGS → exit 2 (run with no probe command, and unknown mode).
tdir="$(newtdir c5-badargs)"
run run "$tdir"          # missing probe-cmd
a=$RC
run bogus-mode           # unknown mode
b=$RC
if [ "$a" = 2 ] && [ "$b" = 2 ]; then
  ok "5 bad args → exit 2 (no-cmd + unknown mode)" "(no-cmd=$a unknown=$b)"
else
  no "5 bad args → exit 2 (no-cmd + unknown mode)" "no-cmd=$a unknown=$b"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Case 4 proves the atomic PIPESTATUS capture is what
# suppresses the false preserved claim when tee dies mid-write. Mutate a throwaway
# copy of the SUT to the NAIVE split — where the first assignment resets $PIPESTATUS
# so tee_rc is a dead constant 0 — and re-run the tee-fail fixture. Against the
# mutant the guard is blind (tee_rc always 0, file exists) so it MUST false-print
# 'preserved:'. If the mutant stayed honest, case 4 would be theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: naive PIPESTATUS split, expect FALSE preserved on tee-fail fixture --"
  anchor='st=("${PIPESTATUS[@]}"); cmd_rc=${st[0]:-0}; tee_rc=${st[1]:-0}'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate atomic PIPESTATUS capture" "anchor not found — SUT drifted?"
  else
    mutant="$ROOT/probe.mutant.sh"
    naive='cmd_rc=${PIPESTATUS[0]:-0}; tee_rc=${PIPESTATUS[1]:-0}'
    printf '%s\n' "${content/"$anchor"/$naive}" > "$mutant"
    tdir="$(newtdir teeth-teefail)"
    outm="$( ulimit -f 0 2>/dev/null; "$BASH_BIN" "$mutant" run "$tdir" echo hello 2>&1 )"
    if grep -q 'preserved:' <<<"$outm"; then
      ok "teeth: naive-split mutant FALSE-preserves on tee-fail" "(case 4 has teeth)"
    else
      no "teeth: naive-split mutant FALSE-preserves on tee-fail" "mutant stayed honest — case 4 is THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
