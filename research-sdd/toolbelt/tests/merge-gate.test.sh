#!/usr/bin/env bash
# merge-gate.test.sh — shim contract of merge-gate.sh (kit issue #2434).
#
# merge-gate.sh is a compatibility shim over `rsdd gate merge` (Go). The gate's behaviour — every verdict, the
# typed lines, the exit codes, the CI gate, the path filters, the closure evidence — is covered by the Go tests in
# research-sdd/rsdd/internal/gate (merge*_test.go: unit tests per verdict, and a differential of RunMerge against the
# frozen pre-port script under testdata/legacy over ~500 scenarios, stdout, stderr, exit code and every stub call).
# This suite checks only what the shim itself owns: it forwards arguments, the exit code, stdout and stderr
# unchanged (the callers kit-wait-merge, kit-merge-train and kit-pr-pipeline read all three), and it degrades through
# rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps the byte-equality guard between the live
# .github/workflows/toolbelt-tests.yml and the frozen fixture the Go path-filter tests read (kit issue #2136).
# Mutation controls under --prove-teeth.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/merge-gate.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== merge-gate.test.sh =="

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
  shim_run "$shim" --cwd '/a b' --base-ref origin/main --merge 7 --required-checks ''
  want=$'ARG[gate]\nARG[merge]\nARG[--cwd]\nARG[/a b]\nARG[--base-ref]\nARG[origin/main]\nARG[--merge]\nARG[7]\nARG[--required-checks]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'gate merge' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
  for rc in 0 1 2 3; do
    STUB_RC=$rc shim_run "$shim" --cwd x --base-ref y
    if [ "$SRC" -eq "$rc" ]; then ok "$tag exit code $rc of rsdd is the shim's exit code"; else no "$tag exit code $rc (rc=$SRC)"; fi
  done
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --cwd x --base-ref y --merge 7 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q '^merge-gate: \(allow\|merged\)' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, nothing allowed or merged (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/merge-gate.sh"
out="$(bash "$TMP/nolib/merge-gate.sh" --cwd x --base-ref y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no gh, git, jq or gentle-ai call left behind.
CODE="$(grep -v '^#' "$SUT")"
if grep -qF 'rsdd_exec gate merge "$@"' "$SUT" && ! grep -qE '\b(jq|gh|gentle-ai|awk)\b' <<< "$CODE"; then
  ok "4 shim body is 'rsdd_exec gate merge \"\$@\"' with no jq / gh / gentle-ai / awk left"
else no "4 shim body"; fi

# 5. The byte-equality guard (kit issue #2136): the frozen workflow fixture the path-filter tests read must BE the live
# .github/workflows/toolbelt-tests.yml, or those cases test a stale shape. A missing file is its own state, never "drifted".
REAL_WF="$HERE/../../../.github/workflows/toolbelt-tests.yml"
WF_FIX="$HERE/fixtures/merge-gate/wf-real-toolbelt-tests.yml"
# wf_state <fixture> <live>: same | drifted | absent
wf_state() { if [ ! -f "$1" ] || [ ! -f "$2" ]; then echo absent; elif cmp -s "$1" "$2"; then echo same; else echo drifted; fi; }
# wf_verdict maps the state to the case verdict; the arms are what the teeth below mutate
wf_verdict() { case "$(wf_state "$1" "$2")" in same) echo PASS;; absent) echo FAIL-absent;; *) echo FAIL-drifted;; esac; }
case "$(wf_verdict "$WF_FIX" "$REAL_WF")" in
  PASS) ok "5 fixture wf-real-toolbelt-tests.yml is byte-identical to .github/workflows/toolbelt-tests.yml";;
  FAIL-absent) no "5 fixture or workflow absent: $WF_FIX / $REAL_WF (not a drift - restore the missing file)";;
  *) no "5 fixtures/merge-gate/wf-real-toolbelt-tests.yml drifted from .github/workflows/toolbelt-tests.yml (refresh it: cp the workflow over the fixture)";;
esac
# negative controls, each built from the FIXTURE (always present when this runs) so they cannot pass for the wrong reason
{ cat "$WF_FIX"; echo "# drift"; } > "$TMP/drift-wf.yml"
[ "$(wf_verdict "$TMP/drift-wf.yml" "$WF_FIX")" = FAIL-drifted ] && ok "5a drift control: a modified copy reports FAIL-drifted" || no "5a drift control: modified copy not reported drifted"
[ "$(wf_verdict "$WF_FIX" "$TMP/no-such-workflow.yml")" = FAIL-absent ] && ok "5b drift control: a missing workflow file reports FAIL-absent, not drifted" || no "5b drift control: missing file not reported absent"
[ "$(wf_verdict "$WF_FIX" "$WF_FIX")" = PASS ] && ok "5c drift control: identical files report PASS" || no "5c drift control: identical files not reported PASS"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for merge-gate.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/merge-gate.sh" "$2" 2>/dev/null; then MS="$d/merge-gate.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec gate merge "\$@"#rsdd_exec gate merge#'; then
    shim_run "$MS" --cwd x --base-ref y
    [ "$SOUT" != $'ARG[gate]\nARG[merge]\nARG[--cwd]\nARG[x]\nARG[--base-ref]\nARG[y]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec gate merge#rsdd_exec gate mergE#'; then
    shim_run "$MS" x
    [ "$SOUT" != $'ARG[gate]\nARG[merge]\nARG[x]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by a bare success)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/merge-gate.sh"
    out="$(bash "$TMP/mt/C-nolib/merge-gate.sh" x.md 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered (exec replaced by a call that returns 0)
  if mk D 's#^rsdd_exec gate merge "\$@"#( rsdd_exec gate merge "$@" ); exit 0#'; then
    shim_run "$MS" x.md
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the fixture drift arm reads green
  eval "$(declare -f wf_verdict | sed 's/^wf_verdict/wf_verdict_d/; s/FAIL-drifted/PASS/')"
  [ "$(wf_verdict_d "$TMP/drift-wf.yml" "$WF_FIX")" != FAIL-drifted ] && ok "teeth E: verdict arm drifted->PASS is detected by the drift control" || no "teeth E: drifted->PASS survived"
  # F: the absent arm collapsed into PASS
  eval "$(declare -f wf_verdict | sed 's/^wf_verdict/wf_verdict_a/; s/FAIL-absent/PASS/')"
  [ "$(wf_verdict_a "$WF_FIX" "$TMP/no-such-workflow.yml")" != FAIL-absent ] && ok "teeth F: verdict arm absent->PASS is detected by the absent control" || no "teeth F: absent->PASS survived"
  # G: the absent branch collapsed into drifted (the pre-#2136 behaviour)
  eval "$(declare -f wf_state | sed 's/^wf_state/wf_state_m/; s/echo absent/echo drifted/')"
  [ "$(wf_state_m "$WF_FIX" "$TMP/no-such-workflow.yml")" != absent ] && ok "teeth G: mutant without the absent branch is detected by the absent control" || no "teeth G: mutant survived the absent control"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
