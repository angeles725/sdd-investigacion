#!/usr/bin/env bash
# verify-block.test.sh — shim contract of verify-block.sh (kit issue #2456).
#
# verify-block.sh is a compatibility shim over `rsdd verify block` (Go). The instrument's behaviour — the marker
# tally, the Type grammar, every citation form and its resolution, the typed DEGRADED states, the possibility-first
# lint and its sweep, the OCR flag, the empty-input digest and ephemeral-path detectors, the SCRIPTS-MANIFEST check and
# the section 14 back-pointer check — is covered by the Go tests in research-sdd/rsdd/internal/verify (block_*_test.go):
# a case table run through the Go command and compared byte for byte with the recorded output of the frozen pre-port
# script (testdata/block/legacy), and the same table re-run against that script live by the differential test.
# The three shell suites that used to mutate the script text (this one, verify-block-backpointer.test.sh and
# verify-block-possibility.test.sh) cannot mutate a shim; the Go mutation run (make teeth, TEETH_PKG=./internal/verify)
# replaces them.
# This suite checks only what the shim itself owns: it forwards arguments, the exit code and stderr unchanged, and
# it degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. Mutation controls under --prove-teeth.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/verify-block.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-block.test.sh =="

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

# check SHIM -> runs the forwarding checks against SHIM (the real shim, or a mutant of it)
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$1" --extern-check --backptr=off 'a b.md' ''
  want=$'ARG[verify]\nARG[block]\nARG[--extern-check]\nARG[--backptr=off]\nARG[a b.md]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'verify block' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --ephemeral=warn x.md 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q 'verify-block:' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, nothing verified (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-block.sh"
out="$(bash "$TMP/nolib/verify-block.sh" x.md 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no grep, awk or rule logic left behind.
if grep -qF 'rsdd_exec verify block "$@"' "$SUT" && ! grep -qE 'grep |awk |find |sed |pf_scan|scripts_manifest_rows|block_file_filter' "$SUT"; then
  ok "4 shim body is 'rsdd_exec verify block \"\$@\"' with no grep / awk / find left"
else no "4 shim body"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for verify-block.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/verify-block.sh" "$2" 2>/dev/null; then MS="$d/verify-block.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec verify block "\$@"#rsdd_exec verify block#'; then
    shim_run "$MS" --ephemeral=warn x.md
    [ "$SOUT" != $'ARG[verify]\nARG[block]\nARG[--ephemeral=warn]\nARG[x.md]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec verify block#rsdd_exec verify blok#'; then
    shim_run "$MS" x.md
    [ "$SOUT" != $'ARG[verify]\nARG[block]\nARG[x.md]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by a bare true)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/verify-block.sh"
    out="$(bash "$TMP/mt/C-nolib/verify-block.sh" x.md 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered (exec replaced by a call that returns 0)
  if mk D 's#^rsdd_exec verify block "\$@"#( rsdd_exec verify block "$@" ); exit 0#'; then
    shim_run "$MS" x.md
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
