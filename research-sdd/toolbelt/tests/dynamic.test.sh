#!/usr/bin/env bash
# dynamic.test.sh — red-first regression harness for dynamic.sh (Frida wrapper).
#
# WHY THIS SHAPE. dynamic.sh is the DYNAMIC-phase (METHODOLOGY §12) Frida wrapper.
# frida is NOT installed in this environment (by design — the same way the
# decompile-* scripts are tested WITHOUT running ghidra), so this suite pins the
# wrapper's LOGIC — subcommand dispatch, the boilerplate scaffold it owns, the
# preserve-to-sources/probes discipline it inherits from probe.sh, the sha256
# footer, and the graceful-degrade path when frida is absent — NOT a real trace.
#
# HERMETIC-ish SANDBOX. dynamic.sh resolves the frida binaries through the
# FRIDA_BIN / FRIDA_TRACE_BIN env overrides (mirroring VINEFLOWER/ILSPYCMD in the
# sibling scripts). A case makes frida "absent" by pointing the override at a
# guaranteed-missing path, and "present" by pointing it at a +x stub that echoes.
# Determinism comes from the override, not from what the host has installed — the
# host's real (absent) frida is exactly the default degrade path.
#
# Usage: dynamic.test.sh                (run the suite)
#        dynamic.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../dynamic.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-50s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-50s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# A guaranteed-absent frida path (degrade path) and a present echo-stub factory.
ABSENT="$ROOT/nope/frida-does-not-exist"
mkstub() { # mkstub <path> : +x script that echoes a marker line and exits 0
  local p="$1"; mkdir -p "$(dirname "$p")"
  { printf '#!%s\n' "$BASH_BIN"; printf 'echo "FRIDA-STUB-RAN $*"\n'; printf 'exit 0\n'; } > "$p"
  chmod +x "$p"
}

# run <label-envassign...> -- args... : invoke the SUT. Any leading NAME=VAL tokens
# become env for the run; everything after `--` is argv. Captures OUT + RC.
run() {
  local env=() a="$1"
  while [ "$a" != "--" ]; do env+=("$a"); shift; a="$1"; done
  shift  # drop the --
  OUT="$(env "${env[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1)"; RC=$?
}

newtdir() { local d="$ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

echo "== dynamic.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — boilerplate is a PURE, deterministic scaffold: it MUST emit an
#     Interceptor.attach skeleton with onEnter/onLeave and Module.getExportByName
#     so a user can redirect it into a script.js and fill in specifics.
run FRIDA_BIN="$ABSENT" -- boilerplate
if [ "$RC" = 0 ] \
   && grep -q 'Interceptor.attach' <<<"$OUT" \
   && grep -q 'onEnter'            <<<"$OUT" \
   && grep -q 'onLeave'            <<<"$OUT" \
   && grep -q 'Module.getExportByName' <<<"$OUT"; then
  ok "1 boilerplate emits Interceptor.attach + onEnter/onLeave" "(exit $RC)"
else
  no "1 boilerplate emits Interceptor.attach + onEnter/onLeave" "exit=$RC out=[$OUT]"
fi

# 2 — boilerplate takes optional func + module and inlines them into the scaffold.
run FRIDA_BIN="$ABSENT" -- boilerplate my_secret_fn libtarget.so
if [ "$RC" = 0 ] && grep -q 'my_secret_fn' <<<"$OUT" && grep -q 'libtarget.so' <<<"$OUT"; then
  ok "2 boilerplate inlines func + module args" "(exit $RC)"
else
  no "2 boilerplate inlines func + module args" "exit=$RC out=[$OUT]"
fi

# 3 — frida-hook, frida ABSENT: must (a) exit non-zero, (b) print the install hint,
#     and (c) STILL preserve a copy of the script.js into sources/probes/ — the
#     preservation of the reproduction recipe happens INDEPENDENTLY of frida.
tdir="$(newtdir c3-hook-absent)"
printf '// my probe\nInterceptor.attach(ptr(0x0), {});\n' > "$ROOT/probe3.js"
run FRIDA_BIN="$ABSENT" -- frida-hook some-proc "$ROOT/probe3.js" "$tdir"
copy3=("$tdir"/sources/probes/probe3-*.js)
if [ "$RC" != 0 ] \
   && grep -q 'install: install-tool.sh frida' <<<"$OUT" \
   && [ -f "${copy3[0]}" ]; then
  ok "3 frida-hook absent → non-zero + hint + script preserved" "(exit $RC · ${copy3[0]##*/})"
else
  no "3 frida-hook absent → non-zero + hint + script preserved" "exit=$RC copy=[${copy3[0]}] out=[$OUT]"
fi

# 4 — frida-hook, frida PRESENT (echo-stub): the run is teed into
#     sources/probes/frida-hook-<ts>.log with the standard '# frida-hook run'
#     header AND a sha256(...) footer line; the script copy is preserved too.
tdir="$(newtdir c4-hook-present)"
printf '// hook\nInterceptor.attach(ptr(0x1), {});\n' > "$ROOT/probe4.js"
mkstub "$ROOT/bin/frida"
run FRIDA_BIN="$ROOT/bin/frida" -- frida-hook some-proc "$ROOT/probe4.js" "$tdir"
log4=("$tdir"/sources/probes/frida-hook-*.log)
copy4=("$tdir"/sources/probes/probe4-*.js)
if [ "$RC" = 0 ] && [ -f "${log4[0]}" ] && [ -f "${copy4[0]}" ] \
   && grep -q '# frida-hook run' "${log4[0]}" \
   && grep -q 'FRIDA-STUB-RAN'   "${log4[0]}" \
   && grep -q 'sha256('          <<<"$OUT"; then
  ok "4 frida-hook present → preserved log w/ header + sha256" "(exit $RC · ${log4[0]##*/})"
else
  no "4 frida-hook present → preserved log w/ header + sha256" "exit=$RC log=[${log4[0]}] copy=[${copy4[0]}] out=[$OUT]"
fi

# 5 — frida-trace, frida-trace ABSENT: non-zero + install hint, and it announces
#     the INTENDED output path constructed under sources/probes/frida-trace-*.log
#     (path-construction logic is what we pin; the trace itself needs real frida).
tdir="$(newtdir c5-trace-absent)"
run FRIDA_TRACE_BIN="$ABSENT" -- frida-trace some-proc -i open "$tdir"
if [ "$RC" != 0 ] \
   && grep -q 'install: install-tool.sh frida' <<<"$OUT" \
   && grep -Eq "sources/probes/frida-trace-[0-9TZ]+(-[0-9]+)?\.log" <<<"$OUT"; then
  ok "5 frida-trace absent → non-zero + hint + intended path" "(exit $RC)"
else
  no "5 frida-trace absent → non-zero + hint + intended path" "exit=$RC out=[$OUT]"
fi

# 6 — BAD ARGS → exit 2 across the board.
tdir="$(newtdir c6-badargs)"
run FRIDA_BIN="$ABSENT" -- frida-hook only-two-args "$ROOT/probe3.js"   # missing target-dir
a=$RC
run FRIDA_TRACE_BIN="$ABSENT" -- frida-trace only-target                 # too few
b=$RC
run FRIDA_TRACE_BIN="$ABSENT" -- frida-trace some-proc noflag "$tdir"    # no -i/-I
c=$RC
run FRIDA_BIN="$ABSENT" -- bogus-subcommand                             # unknown sub
d=$RC
run FRIDA_BIN="$ABSENT" --                                              # no subcommand
e=$RC
if [ "$a" = 2 ] && [ "$b" = 2 ] && [ "$c" = 2 ] && [ "$d" = 2 ] && [ "$e" = 2 ]; then
  ok "6 bad args all exit 2" "(hook=$a trace-few=$b trace-noflag=$c unknown=$d none=$e)"
else
  no "6 bad args all exit 2" "hook=$a trace-few=$b trace-noflag=$c unknown=$d none=$e"
fi

# 7 — frida-hook missing script file → exit 2 (validation before any preservation).
tdir="$(newtdir c7-noscript)"
run FRIDA_BIN="$ABSENT" -- frida-hook some-proc "$ROOT/does-not-exist.js" "$tdir"
if [ "$RC" = 2 ]; then
  ok "7 frida-hook missing script → exit 2" "(exit $RC)"
else
  no "7 frida-hook missing script → exit 2" "exit=$RC out=[$OUT]"
fi

# 8 — frida-trace 3-arg AMBIGUITY. `frida-trace T -i D` must NOT silently consume the
#     -i value (D) as the target-dir, drop the real target, and exit 0 as a false
#     success. A bare -i/-I whose value was eaten by the target-dir slice → exit 2.
tdir="$(newtdir c8-ambig)"
mkstub "$ROOT/bin/frida-trace"
run FRIDA_TRACE_BIN="$ROOT/bin/frida-trace" -- frida-trace some-proc -i "$tdir"
if [ "$RC" = 2 ]; then
  ok "8 frida-trace 'T -i D' ambiguity → exit 2" "(exit $RC)"
else
  no "8 frida-trace 'T -i D' ambiguity → exit 2" "exit=$RC out=[$OUT]"
fi

# 9 — DASH-LEADING caller path (target-dir). A '-x' target-dir must NOT be misparsed
#     as an option by mkdir/cp/tee; it is rejected with an honest error (exit 2) and
#     NEVER produces a 'preserved:' claim.
tdir="$(newtdir c9-dash)"
printf '// p\n' > "$ROOT/probe9.js"
run FRIDA_BIN="$ABSENT" -- frida-hook some-proc "$ROOT/probe9.js" -x
if [ "$RC" != 0 ] && [ "$RC" != 3 ] && ! grep -q 'preserved' <<<"$OUT"; then
  ok "9 dash-leading target-dir → honest error, no preserved claim" "(exit $RC)"
else
  no "9 dash-leading target-dir → honest error, no preserved claim" "exit=$RC out=[$OUT]"
fi

# 10 — UNCREATABLE target-dir. When a path component is a FILE, mkdir -p can't create
#      sources/probes → the script must abort with a non-zero exit and emit NO
#      'preserved' line and leave NO evidence file (no false [CERT-hw] claim).
afile="$ROOT/c10-file"; printf 'x' > "$afile"
run FRIDA_BIN="$ABSENT" -- frida-hook some-proc "$ROOT/probe9.js" "$afile/sub"
if [ "$RC" != 0 ] && ! grep -q 'preserved' <<<"$OUT"; then
  ok "10 uncreatable target-dir → non-zero, no preserved claim" "(exit $RC)"
else
  no "10 uncreatable target-dir → non-zero, no preserved claim" "exit=$RC out=[$OUT]"
fi

# 11 — SAME-SECOND COLLISION. Two rapid frida-hook runs into the same target-dir must
#      NOT overwrite each other's evidence — filenames must be unique (PID/counter),
#      so BOTH logs survive.
tdir="$(newtdir c11-collision)"
printf '// c\nInterceptor.attach(ptr(0x2), {});\n' > "$ROOT/probe11.js"
mkstub "$ROOT/bin/frida"
run FRIDA_BIN="$ROOT/bin/frida" -- frida-hook proc-a "$ROOT/probe11.js" "$tdir"
run FRIDA_BIN="$ROOT/bin/frida" -- frida-hook proc-b "$ROOT/probe11.js" "$tdir"
nlogs=$(find "$tdir/sources/probes" -maxdepth 1 -name 'frida-hook-*.log' | wc -l)
if [ "$nlogs" -ge 2 ]; then
  ok "11 same-second collision → both logs survive (unique names)" "($nlogs logs)"
else
  no "11 same-second collision → both logs survive (unique names)" "logs=$nlogs (overwritten?)"
fi

# 12 — BOILERPLATE quote-injection. A func/module arg containing a quote would break out
#      of the single-quoted JS literal and produce invalid JS → reject with exit 2.
run FRIDA_BIN="$ABSENT" -- boilerplate "ev'il"
if [ "$RC" = 2 ]; then
  ok "12 boilerplate quote arg → exit 2" "(exit $RC)"
else
  no "12 boilerplate quote arg → exit 2" "exit=$RC out=[$OUT]"
fi

# 13 — EMPTY target → exit 2 (both subcommands).
tdir="$(newtdir c13-empty)"
run FRIDA_BIN="$ABSENT" -- frida-hook "" "$ROOT/probe9.js" "$tdir"
h=$RC
run FRIDA_TRACE_BIN="$ABSENT" -- frida-trace "" -i open "$tdir"
t=$RC
if [ "$h" = 2 ] && [ "$t" = 2 ]; then
  ok "13 empty target → exit 2 (hook + trace)" "(hook=$h trace=$t)"
else
  no "13 empty target → exit 2 (hook + trace)" "hook=$h trace=$t"
fi

# 14 — boilerplate ACCEPTS legit identifiers containing '-' and '$' (R-002/R-005).
#      The documented allow-set is A-Za-z0-9_.:$- . A naive `[!...:$-]` bracket
#      expands $- (the shell's option flags) BEFORE matching, dropping literal '-'
#      and '$' and WRONGLY rejecting these. They must be accepted → exit 0, valid JS.
ok14=1; bad14=""
for id in 'sym-with-dash' '$mangled' 'libssl-1.1.so' 'a:b'; do
  run FRIDA_BIN="$ABSENT" -- boilerplate "$id"
  { [ "$RC" = 0 ] && grep -qF "$id" <<<"$OUT"; } || { ok14=0; bad14="$bad14 [$id:rc=$RC]"; }
done
# the emitted JS must also be syntactically valid (node --check), if node is present.
if [ "$ok14" = 1 ] && command -v node >/dev/null 2>&1; then
  run FRIDA_BIN="$ABSENT" -- boilerplate 'sym-with-dash' 'libssl-1.1.so'
  printf '%s\n' "$OUT" > "$ROOT/bp14.js"
  node --check "$ROOT/bp14.js" >/dev/null 2>&1 || { ok14=0; bad14="$bad14 [node-check-failed]"; }
fi
if [ "$ok14" = 1 ]; then
  ok "14 boilerplate accepts '-'/'\$' idents + valid JS" "(exit 0)"
else
  no "14 boilerplate accepts '-'/'\$' idents + valid JS" "$bad14"
fi

# 15 — tee_rc guard bites when tee FAILS but the FILE EXISTS (R-001). The naive
#      `frida_rc=${PIPESTATUS[0]}; tee_rc=${PIPESTATUS[1]}` split makes the first
#      assignment reset $PIPESTATUS, so tee_rc is ALWAYS 0 and a mid-write tee
#      failure could seal a TRUNCATED log as [CERT-hw]. Fixture: under `ulimit -f 0`
#      tee CREATES the log (0 bytes) then dies writing it (SIGXFSZ) — file exists,
#      write failed. frida-trace has no pre-tee cp, so the failure lands on the tee.
#      The wrapper must detect it (atomic PIPESTATUS capture) → non-zero exit, NO
#      'preserved:' claim, even though the 0-byte log file is present on disk.
tdir="$(newtdir c15-teefail)"
mkstub "$ROOT/bin/frida-trace"
out15="$( ulimit -f 0 2>/dev/null; env FRIDA_TRACE_BIN="$ROOT/bin/frida-trace" "$BASH_BIN" "$SUT" \
          frida-trace some-proc -i open "$tdir" 2>&1 )"; rc15=$?
log15=("$tdir"/sources/probes/frida-trace-*.log)
if [ "$rc15" != 0 ] && ! grep -q 'preserved:' <<<"$out15" && [ -e "${log15[0]}" ]; then
  ok "15 tee fails but file exists → no false preserved claim" "(exit $rc15 · file present)"
else
  no "15 tee fails but file exists → no false preserved claim" "exit=$rc15 log=[${log15[0]}] out=[$out15]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Case 3 claims the script.js is preserved EVEN WHEN
# frida is absent — i.e. the `cp` runs BEFORE the frida presence check. Mutate a
# throwaway copy of the SUT to DELETE that pre-check preservation line; against
# the mutant, an absent-frida frida-hook must NOT leave a script copy. If the
# mutant still preserved, case 3 would pass on a broken script → theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: delete pre-check preservation, expect NO script copy on absent-frida --"
  anchor='cp -- "$SCRIPT" "$SCRIPT_COPY"'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate pre-check cp line" "anchor not found — SUT drifted?"
  else
    mutant="$ROOT/dynamic.mutant.sh"
    # Replace the cp line with a harmless no-op so preservation never happens.
    printf '%s\n' "${content/"$anchor"/: # MUTANT: preservation removed}" > "$mutant"
    tdir="$(newtdir teeth-mutant)"
    printf '// t\n' > "$ROOT/teeth.js"
    env FRIDA_BIN="$ABSENT" "$BASH_BIN" "$mutant" frida-hook some-proc "$ROOT/teeth.js" "$tdir" >/dev/null 2>&1
    tcopy=("$tdir"/sources/probes/teeth-*.js)
    if [ ! -f "${tcopy[0]}" ]; then
      ok "teeth: mutant does NOT preserve on absent-frida" "(case 3 has teeth)"
    else
      no "teeth: mutant does NOT preserve on absent-frida" "mutant STILL preserved — case 3 is THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
