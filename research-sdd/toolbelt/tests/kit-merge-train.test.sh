#!/usr/bin/env bash
# kit-merge-train.test.sh — shim contract of maint/kit-merge-train.sh (kit issue #2499).
#
# kit-merge-train.sh is a compatibility shim over `rsdd gate merge-train` (Go). The train's behaviour — the per-PR
# checks, the local train branch, the one gate, bisect, the ordered merge, the receipt, every typed state and exit
# code — is covered by the Go tests in research-sdd/rsdd/internal/gate (mergetrain*_test.go: one scenario table that
# asserts the contract, goldens of the transcripts, and a differential of the port against the frozen pre-port script
# and the kit-gate.sh / kit-wait-merge.sh it called, under testdata/legacy/mergetrain, over every scenario of the
# former bash suite). This suite checks only what the shim itself owns: it forwards arguments, the exit code, stdout
# and stderr unchanged (the callers read all three), and it degrades through rsdd-exec (typed, exit 2) when rsdd
# cannot run. Mutation controls under --prove-teeth.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/maint/kit-merge-train.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== kit-merge-train.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line on stdout, says something on stderr and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
EOF
chmod +x "$STUB"

shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want rc
  shim_run "$shim" --rdd-ok '1=abcdef1' --pr-cwd '1=/a b' --gate-cmd '' --bisect 1 2
  want=$'ARG[gate]\nARG[merge-train]\nARG[--rdd-ok]\nARG[1=abcdef1]\nARG[--pr-cwd]\nARG[1=/a b]\nARG[--gate-cmd]\nARG[]\nARG[--bisect]\nARG[1]\nARG[2]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'gate merge-train' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
  for rc in 0 2 3 27 33; do
    STUB_RC=$rc shim_run "$shim" 1
    if [ "$SRC" -eq "$rc" ]; then ok "$tag exit code $rc of rsdd is the shim's exit code"; else no "$tag exit code $rc (rc=$SRC)"; fi
  done
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" 1 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q 'kit-merge-train: merged' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, nothing merged (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib/maint"; cp "$SUT" "$TMP/nolib/maint/kit-merge-train.sh"
out="$(bash "$TMP/nolib/maint/kit-merge-train.sh" 1 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no git, gh, jq or flock call left behind.
CODE="$(grep -v '^#' "$SUT")"
if grep -qF 'rsdd_exec gate merge-train "$@"' "$SUT" && ! grep -qE '\b(jq|gh|git|flock|awk)\b' <<< "$CODE"; then
  ok "4 shim body is 'rsdd_exec gate merge-train \"\$@\"' with no git / gh / jq / flock / awk left"
else no "4 shim body"; fi

# 5. Resolved through a symlink the shim still finds lib/ beside the REAL maint/ directory.
mkdir -p "$TMP/links"; ln -sf "$SUT" "$TMP/links/kit-merge-train.sh"
shim_run "$TMP/links/kit-merge-train.sh" 1
if [ "$SRC" -eq 7 ] && [[ "$SOUT" == *'ARG[merge-train]'* ]]; then ok "5 a symlinked shim resolves lib/rsdd-exec.sh through its real directory"
else no "5 symlinked shim (rc=$SRC out=[$SOUT] err=[$SERR])"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for kit-merge-train.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME/maint; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" "$d/maint" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/maint/kit-merge-train.sh" "$2" 2>/dev/null; then MS="$d/maint/kit-merge-train.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec gate merge-train "\$@"#rsdd_exec gate merge-train#'; then
    shim_run "$MS" 1 2
    [ "$SOUT" != $'ARG[gate]\nARG[merge-train]\nARG[1]\nARG[2]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec gate merge-train#rsdd_exec gate merge#'; then
    shim_run "$MS" 1
    [ "$SOUT" != $'ARG[gate]\nARG[merge-train]\nARG[1]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by a bare success)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib/maint"; cp "$MS" "$TMP/mt/C-nolib/maint/kit-merge-train.sh"
    out="$(bash "$TMP/mt/C-nolib/maint/kit-merge-train.sh" 1 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered (exec replaced by a call that returns 0)
  if mk D 's#^rsdd_exec gate merge-train "\$@"#( rsdd_exec gate merge-train "$@" ); exit 0#'; then
    shim_run "$MS" 1
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the library resolved beside the shim instead of one level up (the maint/ depth forgotten)
  if mk E 's#"\$_RSDD_SELF/../lib/rsdd-exec.sh"#"$_RSDD_SELF/lib/rsdd-exec.sh"#'; then
    out="$(RSDD_BIN="$STUB" bash "$MS" 1 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] && ok "teeth E: wrong library depth -> the shim degrades (exit 2) instead of forwarding" || no "teeth E: mutant still forwards — THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
