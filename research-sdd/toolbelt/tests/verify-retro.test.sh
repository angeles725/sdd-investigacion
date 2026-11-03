#!/usr/bin/env bash
# verify-retro.test.sh — shim contract of verify-retro.sh (kit issue #2586).
#
# verify-retro.sh is a compatibility shim over `rsdd retro verify` (Go). The checker's behaviour (the review-status
# marker and its kit-retro opt-out, the title line, the four delta-section classes, the §18 honesty line, the
# unclosed-fence warning, absent-input vs non-conforming vs bad arguments, and every message byte) is covered by the
# Go tests in research-sdd/rsdd/internal/retro/verifyretro: recorded goldens from the frozen pre-port script, a live
# differential against it, and unit tests. This suite checks only what the shim itself owns: it forwards arguments,
# the exit code and stderr unchanged, degrades through rsdd-exec (typed, exit 2) when rsdd cannot run, and, when the
# runner hands it a built binary (RSDD_BIN), reaches the real checker end to end. Mutation controls under
# --prove-teeth.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/verify-retro.sh"
FIX="$HERE/fixtures/verify-retro"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-retro.test.sh =="

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

# shim_run SHIM ARGS... -> runs SHIM against the stub rsdd; sets SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$shim" 'a b.md' '' --odd
  want=$'ARG[retro]\nARG[verify]\nARG[a b.md]\nARG[]\nARG[--odd]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'retro verify' (spaces, an empty argument and a flag-like word kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" "$FIX/conforming.md" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -qF 'OK: conforming' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, never a clean 'OK: conforming'"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-retro.sh"
out="$(bash "$TMP/nolib/verify-retro.sh" "$FIX/conforming.md" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no grammar, no awk, no sourced retro library left behind.
if grep -qF 'rsdd_exec retro verify "$@"' "$SUT" && ! grep -qE 'awk|grep|retro_grammar|retro-grammar|python3' "$SUT"; then
  ok "4 shim body is 'rsdd_exec retro verify \"\$@\"' with no awk / grep / grammar logic left"
else no "4 shim body"; fi

# 5. End to end through the real binary (the runner builds one and exports RSDD_BIN; without it the shim would
# build bin/rsdd inside the tree, which the kit-tree hermeticity check forbids).
e2e_run() { E2E_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" bash "$1" "${@:2}" 2>"$TMP/e2e.err")"; E2E_RC=$?; E2E_ERR="$(cat "$TMP/e2e.err")"; }
if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
  e2e_run "$SUT" "$FIX/conforming.md"
  if [ "$E2E_RC" -eq 0 ] && [ "$E2E_OUT" = "OK: conforming" ] && [ -z "$E2E_ERR" ]; then ok "5a conforming retro through the real binary -> 'OK: conforming', exit 0, empty stderr"
  else no "5a conforming (rc=$E2E_RC out=[$E2E_OUT] err=[$E2E_ERR])"; fi
  e2e_run "$SUT" "$FIX/marker-missing.md"
  if [ "$E2E_RC" -eq 1 ] && grep -qF 'FAIL [marker-missing]' <<< "$E2E_OUT"; then ok "5b non-conforming retro -> 'FAIL [marker-missing]' on stdout, exit 1"
  else no "5b non-conforming (rc=$E2E_RC out=[$E2E_OUT])"; fi
  e2e_run "$SUT" "$TMP/absent.md"
  if [ "$E2E_RC" -eq 2 ] && [ -z "$E2E_OUT" ] && grep -qF "ERROR: file not found (absent-input): $TMP/absent.md" <<< "$E2E_ERR"; then ok "5c absent file -> typed absent-input on stderr, exit 2 (distinct from the exit 1 of 5b)"
  else no "5c absent (rc=$E2E_RC out=[$E2E_OUT] err=[$E2E_ERR])"; fi
  e2e_run "$SUT"
  if [ "$E2E_RC" -eq 2 ] && grep -qF 'Usage: verify-retro.sh <retro.md>' <<< "$E2E_ERR"; then ok "5d no argument -> usage on stderr, exit 2"
  else no "5d usage (rc=$E2E_RC err=[$E2E_ERR])"; fi
else
  printf '  SKIP  5 end to end: RSDD_BIN not set to an executable (run it through run-all.sh, which builds the binary once)\n'
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for verify-retro.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/verify-retro.sh" "$2" 2>/dev/null; then MS="$d/verify-retro.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec retro verify "\$@"#rsdd_exec retro verify#'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[x.md]'* ]] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec retro verify#rsdd_exec retro verifyy#'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[verify]'* ]] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard exits 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/verify-retro.sh"
    out="$(bash "$TMP/mt/C-nolib/verify-retro.sh" x.md 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec retro verify "\$@"#( rsdd_exec retro verify "$@" ); exit 0#'; then
    shim_run "$MS" x.md
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: end to end, a shim that hands the checker a different subcommand fails the real-binary cases
  if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
    if mk E 's#^rsdd_exec retro verify "\$@"#rsdd_exec retro verify --bogus "$@"#'; then
      e2e_run "$MS" "$FIX/marker-missing.md"
      [ "$E2E_RC" -ne 1 ] && ok "teeth E: an extra argument injected by the shim -> the end-to-end case (5b) goes red" || no "teeth E: mutant still answers 1 — THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
