#!/usr/bin/env bash
# serial-console.test.sh — shim contract of serial-console.sh (kit issue #2270, T8b).
#
# serial-console.sh is a compatibility shim over `rsdd serial console` (Go). The command's behavior - the argument
# validation order, the interop check, the evidence file, the preservation guards (exit 4 and 5), every message and
# every exit code - is covered by the Go tests in research-sdd/rsdd/internal/serial/console: a differential over every
# scenario of its table against the frozen pre-port script (testdata/legacy, sha256 pinned), a replay of its recorded answers
# that also runs without bash, golden cases through the registry entry, and table tests for the quoting of the two
# coreutils messages. This suite checks what the shim itself owns: it forwards arguments, the exit code and stderr
# unchanged, and it degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps a few end-to-end
# cases through the real binary and, under --prove-teeth, mutation controls on the shim.
#
# Disposition of the cases of the pre-port suite (18 cases, 2 mutation controls; kit issue #2270, T8b):
#   kept end to end through the shim and the real binary: 2 (usage), 4 (absent interop), 6 (check OK),
#     15 (run OK: evidence file, preserved line, exit 0), 18 (tee failure: exit 5, nothing cited);
#   moved to Go (differential + replay, same inputs): 3 usage-unknown-mode*, 5 absent-*-check, 7 check-* (output
#     variants), 8-9 validate-no-args..five-args, 10 validate-dash-dir-*, 11 validate-port-*, 12 validate-baud-*,
#     13 validate-empty-command, 14 absent-*-run, 16 run-exit-7-is-mirrored, 17 run-mkdir-*;
#   teeth A (tee -> /dev/null, post-tee [ ! -f ] guard) and B (exit 5 -> exit 0) mutated the bash body, which is gone:
#     they moved to the Go scenarios run-tee-permission-denied and run-evidence-file-vanishes-after-tee, mutation
#     checked by hand against internal/serial/console/run.go (see the guard table at the head of scenario_test.go).
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/serial-console.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== serial-console.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'chmod -R 755 "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line, says something on stderr and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
STUBEOF
chmod +x "$STUB"

# shim_run SHIM [args...] -> SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

# 1. arguments, exit code and stderr pass through
shim_run "$SUT" run 'a b' COM3 9600 ''
want=$'ARG[serial]\nARG[console]\nARG[run]\nARG[a b]\nARG[COM3]\nARG[9600]\nARG[]'
if [ "$SOUT" = "$want" ]; then ok "1 arguments reach rsdd verbatim after 'serial console' (spaces and an empty argument kept)"
else no "1 arguments (out=[$SOUT])"; fi
if [ "$SRC" -eq 7 ]; then ok "1 exit code of rsdd is the shim's exit code"; else no "1 exit code (rc=$SRC)"; fi
if [ "$SERR" = "stub-stderr" ]; then ok "1 stderr of rsdd passes through"; else no "1 stderr (err=[$SERR])"; fi

# 2. rsdd cannot run: typed degraded state, never a clean 0, no evidence
out="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" run "$TMP/degraded" COM3 9600 'show ver' 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded" ]; then
  ok "2 rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written"
else no "2 degrade (rc=$rc out=[$out])"; fi

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/serial-console.sh"
out="$(bash "$TMP/nolib/serial-console.sh" check 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no PowerShell driver, no tee, no preservation logic left behind.
if grep -qF 'rsdd_exec serial console "$@"' "$SUT" && ! grep -qE 'System\.IO\.Ports|powershell\.exe -|tee -- |mkdir -p' "$SUT"; then
  ok "4 shim body is 'rsdd_exec serial console \"\$@\"' with no PowerShell / tee / mkdir logic left"
else no "4 shim body"; fi

# ---- End to end through the real binary --------------------------------------
# $RSDD_BIN wins; otherwise one binary is built into the suite temp dir (never into the tree). Without Go the
# end-to-end group is a typed SKIP (FAIL under RSDD_REQUIRE_GO=1): the shim checks above never need it.
real_rsdd=""
if [ -n "${RSDD_BIN:-}" ] && [ -x "${RSDD_BIN:-}" ]; then real_rsdd="$RSDD_BIN"
elif command -v go >/dev/null 2>&1; then
  if ( cd "$TOOLBELT/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$TMP/rsdd" ./cmd/rsdd ) >"$TMP/build.log" 2>&1; then real_rsdd="$TMP/rsdd"
  else echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$TMP/build.log" >&2; exit 2; fi
fi

# make_stub <dir> <exit_code> <text>: an executable stand-in for powershell.exe that ignores its arguments, prints
# <text> (no single quote in it) and exits <exit_code>. Prints the stub's path.
make_stub() {
  local dir="$1" rc="$2" txt="$3" stub
  mkdir -p -- "$dir"; stub="$dir/stub-pwsh.sh"
  { printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' "printf '%s\\n' '$txt'"; printf 'exit %s\n' "$rc"; } > "$stub"
  chmod +x "$stub"; printf '%s' "$stub"
}

if [ -z "$real_rsdd" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "e2e: rsdd-unavailable: go not in PATH and no executable RSDD_BIN (RSDD_REQUIRE_GO=1)"
  else echo "SKIP e2e (rsdd-unavailable: go not in PATH and no executable RSDD_BIN; set RSDD_REQUIRE_GO=1 to fail instead)"; fi
else
  q() { RSDD_BIN="$real_rsdd" bash "$SUT" "$@"; }
  ABSENT="$TMP/no-such-powershell"

  # 5. (old 2) no mode: exit 2 and the usage on stderr
  OUT="$(q 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ] && grep -qF 'usage:' <<< "$OUT" && grep -qF 'serial-console.sh run <target-dir> <com-port> <baud> <command>' <<< "$OUT"; then ok "5 no mode: exit 2 + usage on stderr"
  else no "5 no mode (rc=$RC out=[$OUT])"; fi

  # 6. (old 4) absent PowerShell: exit 3 and the interop hint, no evidence directory made
  OUT="$(POWERSHELL_BIN="$ABSENT" q run "$TMP/t6" COM3 9600 'show ver' 2>&1)"; RC=$?
  if [ "$RC" -eq 3 ] && grep -qF 'cannot reach Windows PowerShell' <<< "$OUT" && grep -qF 'WSLInterop' <<< "$OUT" && [ ! -e "$TMP/t6" ]; then
    ok "6 absent PowerShell: exit 3 + interop hint, nothing created"
  else no "6 absent PowerShell (rc=$RC out=[$OUT])"; fi

  # 7. (old 6) check against a stub that answers OK
  S7="$(make_stub "$TMP/s7" 0 OK)"
  OUT="$(POWERSHELL_BIN="$S7" q check 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "interop: OK ($S7 reachable)" ]; then ok "7 check + OK stub: exit 0 + 'interop: OK'"
  else no "7 check (rc=$RC out=[$OUT])"; fi

  # 8. (old 15) run: evidence file, citation line, exit 0
  T8="$TMP/t8"; mkdir -p -- "$T8"; S8="$(make_stub "$TMP/s8" 0 'hw output line')"
  OUT="$(POWERSHELL_BIN="$S8" q run "$T8" COM3 9600 'show version' 2>&1)"; RC=$?
  F8="$(find "$T8/sources/probes" -name 'serial-COM3-*.txt' 2>/dev/null | head -1)"
  if [ "$RC" -eq 0 ] && grep -qF 'preserved: ' <<< "$OUT" && grep -qF '[CERT-hw]' <<< "$OUT" && [ -n "$F8" ] && grep -qF 'hw output line' "$F8" && grep -qF '# port: COM3  baud: 9600  cmd: show version' "$F8"; then
    ok "8 run: evidence file written, 'preserved: ... [CERT-hw]' printed, exit 0"
  else no "8 run (rc=$RC file=[$F8] out=[$OUT])"; fi

  # 9. (old 18) tee failure: exit 5, nothing cited. A read-only evidence directory (not a root scenario).
  T9="$TMP/t9"; mkdir -p -- "$T9/sources/probes"; chmod 555 "$T9/sources/probes"; S9="$(make_stub "$TMP/s9" 0 'hw output')"
  OUT="$(POWERSHELL_BIN="$S9" q run "$T9" COM3 9600 'show ver' 2>&1)"; RC=$?
  chmod 755 "$T9/sources/probes"
  if [ "$RC" -eq 5 ] && grep -qF 'preservation FAILED' <<< "$OUT" && ! grep -qF 'preserved:' <<< "$OUT"; then ok "9 tee failure: exit 5 + preservation-FAILED, no citation line"
  else no "9 tee failure (rc=$RC out=[$OUT])"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for serial-console.sh (shim); the command's own guards are mutation checked in Go --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/serial-console.sh" "$2" 2>/dev/null; then MS="$d/serial-console.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec serial console "\$@"#rsdd_exec serial console#'; then
    shim_run "$MS" check
    [ "$SOUT" != $'ARG[serial]\nARG[console]\nARG[check]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec serial console#rsdd_exec serial consol#'; then
    shim_run "$MS" check
    [ "$SOUT" != $'ARG[serial]\nARG[console]\nARG[check]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/serial-console.sh"
    out="$(bash "$TMP/mt/C-nolib/serial-console.sh" check 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec serial console "\$@"#( rsdd_exec serial console "$@" ); exit 0#'; then
    shim_run "$MS" check
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the capture command no longer answers the interop check
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec serial console#rsdd_exec serial frame-capture#'; then
    SE="$(make_stub "$TMP/se" 0 OK)"
    OUT="$(POWERSHELL_BIN="$SE" RSDD_BIN="$real_rsdd" bash "$MS" check 2>&1)"
    if [ "$OUT" = "interop: OK ($SE reachable)" ]; then no "teeth E: the wrong command still answered the interop check — THEATER"
    else ok "teeth E: wrong command -> the end-to-end check goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
