#!/usr/bin/env bash
# tests/corroborate-ghidra.test.sh — shim contract of corroborate-ghidra.sh.
#
# corroborate-ghidra.sh is a compatibility shim over `rsdd corroborate ghidra` (Go). The adapter's behaviour -
# staging and identity, the Bubblewrap sandbox argv, every cap, the manifest, the evidence schema, each refusal and
# the staged-bytes guarantees - is covered by the Go tests in research-sdd/rsdd/internal/corroborate/ghidra
# (fake Ghidra and Bubblewrap through the real process runner, plus an optional real-Bubblewrap test that skips where it
# is absent). This suite checks what the shim itself owns: it forwards arguments, the exit code and stderr
# unchanged, and it degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps a few
# end-to-end cases through the real binary and, under --prove-teeth, mutation controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/corroborate-ghidra.sh"
SELF="$(cd "$TOOLBELT" && pwd -P)"   # what the shim passes as --toolbelt

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== corroborate-ghidra.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line, says something on stderr and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
EOF
chmod +x "$STUB"

# shim_run SHIM [args...] -> SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$shim" --input 'a b.elf' --output '' --max-functions 3
  want="ARG[corroborate]"$'\n'"ARG[ghidra]"$'\n'"ARG[--toolbelt]"$'\n'"ARG[$SELF]"$'\nARG[--input]\nARG[a b.elf]\nARG[--output]\nARG[]\nARG[--max-functions]\nARG[3]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'corroborate ghidra' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --input x --output "$TMP/degraded" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded" ]; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/corroborate-ghidra.sh"
out="$(bash "$TMP/nolib/corroborate-ghidra.sh" --input x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no adapter logic left behind.
if grep -qF 'rsdd_exec corroborate ghidra --toolbelt "$_RSDD_SELF" "$@"' "$SUT" && ! grep -qE 'python3|corroborate_ghidra|analysis_manifest' "$SUT" \
   && [ ! -e "$TOOLBELT/corroborate_ghidra.py" ]; then
  ok "4 shim body is 'rsdd_exec corroborate ghidra --toolbelt \"\$_RSDD_SELF\" \"\$@\"' with no python3 / corroborate_ghidra.py left"
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
if [ -z "$real_rsdd" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "e2e: rsdd-unavailable: go not in PATH and no executable RSDD_BIN (RSDD_REQUIRE_GO=1)"
  else echo "SKIP e2e (rsdd-unavailable: go not in PATH and no executable RSDD_BIN; set RSDD_REQUIRE_GO=1 to fail instead)"; fi
else
  q() { RSDD_BIN="$real_rsdd" bash "$SUT" "$@"; }
  W="$TMP/e2e"; mkdir -m 700 "$W"; printf '\177ELF fake\n' > "$W/in.elf"
  # No Ghidra on purpose: the override names a launcher that does not exist, so the run stops at its first check.
  export ANALYZE_HEADLESS="$W/nope/support/analyzeHeadless"

  # 5. Ghidra not found: one typed line, exit 2, no evidence (the shim's old pre-flight, now in Go)
  rc=0; q --input "$W/in.elf" --output "$W/t5" 2>"$W/t5.err" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(cat "$W/t5.err")" = 'corroborate-ghidra: Ghidra unavailable' ] && [ ! -e "$W/t5" ]; then
    ok "5 Ghidra unavailable: exit 2, typed message, no evidence"; else no "5 Ghidra unavailable (rc=$rc err=$(cat "$W/t5.err"))"; fi

  # 6. caps are checked before anything is looked up
  rc=0; q --input "$W/in.elf" --output "$W/t6" --max-files 11 2>"$W/t6.err" || rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'caps must be positive and max-files at least 12' "$W/t6.err" && [ ! -e "$W/t6" ]; then
    ok "6 caps: exit 2, typed message"; else no "6 caps (rc=$rc)"; fi

  # 7. a usage error is exit 2 with usage on stderr and nothing on stdout; --help is exit 0
  rc=0; so="$(q --bogus 2>"$W/t7.err")" || rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$so" ] && grep -qF 'usage: rsdd corroborate ghidra' "$W/t7.err"; then ok "7 usage error: exit 2, usage on stderr"; else no "7 usage error (rc=$rc)"; fi
  rc=0; so="$(q --help 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && grep -qF 'usage: rsdd corroborate ghidra' <<< "$so"; then ok "8 --help: exit 0, usage on stdout"; else no "8 --help (rc=$rc)"; fi
  unset ANALYZE_HEADLESS
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for corroborate-ghidra.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/corroborate-ghidra.sh" "$2" 2>/dev/null; then MS="$d/corroborate-ghidra.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  want_args="ARG[corroborate]"$'\n'"ARG[ghidra]"$'\n'"ARG[--toolbelt]"$'\n'"ARG[$SELF]"$'\nARG[--input]\nARG[x]'
  # A: arguments no longer forwarded
  if mk A 's#^\(rsdd_exec corroborate ghidra --toolbelt "\$_RSDD_SELF"\) "\$@"#\1#'; then
    shim_run "$MS" --input x
    [ "$SOUT" != "$want_args" ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec corroborate ghidra#rsdd_exec corroborate ghidr#'; then
    shim_run "$MS" --input x
    [ "$SOUT" != "$want_args" ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/corroborate-ghidra.sh"
    out="$(bash "$TMP/mt/C-nolib/corroborate-ghidra.sh" --input x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec corroborate ghidra --toolbelt "\$_RSDD_SELF" "\$@"#( rsdd_exec corroborate ghidra --toolbelt "\$_RSDD_SELF" "$@" ); exit 0#'; then
    shim_run "$MS" --input x
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the other command fails case 5 (Ghidra unavailable)
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec corroborate ghidra#rsdd_exec corroborate java-fidelity#'; then
    out="$(ANALYZE_HEADLESS="$TMP/e2e/nope/support/analyzeHeadless" RSDD_BIN="$real_rsdd" bash "$MS" --input "$TMP/e2e/in.elf" --output "$TMP/e2e/t_e" 2>&1)"
    if grep -qF "Ghidra unavailable" <<< "$out"; then no "teeth E: the wrong command still said Ghidra unavailable — THEATER"
    else ok "teeth E: wrong command -> the end-to-end Ghidra-unavailable refusal goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
