#!/usr/bin/env bash
# score-loop-transcript.test.sh — shim contract of score-loop-transcript.sh (kit issue #993).
#
# score-loop-transcript.sh is a compatibility shim over `rsdd eval score-loop` (Go). The scorer's behaviour (C1-C4
# verdicts, the window scan, the jq-shaped transcript reader, the status-script integration, every message byte and
# exit code) is covered by the Go tests in research-sdd/rsdd/internal/eval/scoreloop: recorded goldens from the frozen
# pre-port script (about 340 black-box cases), a live differential against it, unit tests per guard, and the declared
# divergences (tool-registry.d/score-loop-transcript.md). This suite checks only what the shim itself owns: it passes
# its own directory as `--toolbelt <dir>` before the caller's arguments, forwards arguments, the exit code and stderr
# unchanged, degrades through rsdd-exec (typed, exit 2) when rsdd cannot run, and, when the runner hands it a built
# binary (RSDD_BIN), reaches the real scorer end to end on a fixture corpus and transcript. Mutation controls under
# --prove-teeth.
#
# The mutation controls of the retired bash suite sed the old script body (the matching seams of C1-C4); that body is
# gone. Their Go replacements are named in the SKIP lines below.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/score-loop-transcript.sh"
FIX="$HERE/fixtures/score-loop"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== score-loop-transcript.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: absent-input: git not on PATH" >&2; exit 2; }
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
  shim_run "$shim" --corpus 'a b' --since ''
  want=$'ARG[eval]\nARG[score-loop]\nARG[--toolbelt]\nARG['"$(dirname "$shim")"$']\nARG[--corpus]\nARG[a b]\nARG[--since]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'eval score-loop --toolbelt <own dir>' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --corpus x 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q '^C1 ' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no verdict printed (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/score-loop-transcript.sh"
out="$(bash "$TMP/nolib/score-loop-transcript.sh" --corpus x 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no jq, date, base64, git or sed logic left behind.
if grep -qF 'rsdd_exec eval score-loop --toolbelt "$_RSDD_SELF" "$@"' "$SUT" && ! grep -qE 'jq |date |base64|git |sed |BASH_REMATCH|research-sdd-status' "$SUT"; then
  ok "4 shim body is 'rsdd_exec eval score-loop --toolbelt \"\$_RSDD_SELF\" \"\$@\"' with no jq / date / base64 / git logic left"
else no "4 shim body"; fi

# 5. End to end through the real binary (the runner builds one and exports RSDD_BIN; without it the shim would build
# bin/rsdd inside the tree, which the kit-tree hermeticity check forbids). The corpus is a throwaway repo with a fixed
# identity and no ambient git configuration; a stub status script stands in for research-sdd-status.sh.
GENV=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com)
g() { env "${GENV[@]}" git -c maintenance.auto=false -c gc.auto=0 "$@"; }
# mkcorpus DIR [<iso-date> <subject>]... -> a git repo with one commit per pair
mkcorpus() {
  local d="$1" n=0; shift
  g init -q "$d" || return 1
  while [ "$#" -ge 2 ]; do
    n=$((n+1)); echo "$n" > "$d/f.txt"; g -C "$d" add f.txt
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g -C "$d" commit -q -m "$2" || return 1
    shift 2
  done
}
e2e_run() { E2E_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" RSDD_STATUS_SCRIPT="$FIX/stub-status-stop-empty.sh" "${GENV[@]}" bash "$1" "${@:2}" 2>"$TMP/e2e.err")"; E2E_RC=$?; E2E_ERR="$(cat "$TMP/e2e.err")"; }
if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
  mkcorpus "$TMP/continue" "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" "2026-06-01T00:20:00Z" "research(demo): B2 gap-b"
  e2e_run "$SUT" --corpus "$TMP/continue" --transcript "$FIX/continue-clean.jsonl"
  if [ "$E2E_RC" -eq 0 ] && grep -qE '^C1 pass 2 block commits, 0 operator turns' <<< "$E2E_OUT" \
     && grep -qE '^C3 pass no compaction, 2 block\(s\)$' <<< "$E2E_OUT" && grep -qE '^SUMMARY pass=' <<< "$E2E_OUT"; then
    ok "5a clean transcript through the real binary -> C1 and C3 pass with a SUMMARY line, exit 0"
  else no "5a clean run (rc=$E2E_RC out=[$E2E_OUT] err=[$E2E_ERR])"; fi

  e2e_run "$SUT" --corpus "$TMP/continue" --transcript "$FIX/operator-interrupt.jsonl"
  if [ "$E2E_RC" -eq 0 ] && grep -qE '^C1 fail 2 block commits but 1 of 1 gap' <<< "$E2E_OUT"; then
    ok "5b an operator turn between two block commits -> C1 fail (findings do not fail the run)"
  else no "5b operator interrupt (rc=$E2E_RC out=[$E2E_OUT])"; fi

  e2e_run "$SUT" --corpus "$TMP/continue" --transcript "$FIX/origin-less.jsonl"
  if grep -qE '^C1 degraded unrecognized transcript shape' <<< "$E2E_OUT" && grep -qE '^SUMMARY pass=0 fail=0 n/a=0 degraded=4$' <<< "$E2E_OUT"; then
    ok "5c a transcript of an unrecognised shape degrades every criterion instead of scoring a clean pass"
  else no "5c unrecognised shape (rc=$E2E_RC out=[$E2E_OUT])"; fi

  e2e_run "$SUT" --bogus
  if [ "$E2E_RC" -eq 2 ] && grep -qF 'usage' <<< "$E2E_ERR" && [ -z "$E2E_OUT" ]; then ok "5d unknown option -> usage on stderr, exit 2"
  else no "5d usage (rc=$E2E_RC err=[$E2E_ERR])"; fi

  mkdir -p "$TMP/link/profile/research-sdd/profile/p"
  ln -s "$TOOLBELT" "$TMP/link/profile/research-sdd/profile/p/toolbelt"
  e2e_run "$TMP/link/profile/research-sdd/profile/p/toolbelt/score-loop-transcript.sh" --corpus "$TMP/continue" --transcript "$FIX/continue-clean.jsonl"
  if [ "$E2E_RC" -eq 0 ] && grep -qE '^C1 pass 2 block commits' <<< "$E2E_OUT"; then
    ok "5e invoked through a symlinked toolbelt dir (#1024 profile) still runs the scorer"
  else no "5e symlinked toolbelt (rc=$E2E_RC out=[$E2E_OUT] err=[$E2E_ERR])"; fi
else
  printf '  SKIP  5 end to end: RSDD_BIN not set to an executable (run it through run-all.sh, which builds the binary once)\n'
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for score-loop-transcript.sh (shim) --"
  # The retired controls sed the old script body, which is gone: each is a typed SKIP naming the Go test that replaces it
  # (research-sdd/rsdd/internal/eval/scoreloop).
  printf '  SKIP  teeth (old C1/C2/C3 matching seams) block-commit, question and compaction matching: TestGoldenReplay c1-*, c2-*, c3-* cases and TestWeigh, TestBuiltinVerdict, TestLastParagraph\n'
  printf '  SKIP  teeth (old C4 seams) STOP token, status --next, queue and after-STOP rules: TestGoldenReplay c4-* cases and TestClassifyNext, TestParseQueue, TestC4Verdict, TestGraceDeadline\n'
  printf '  SKIP  teeth (old degraded seams) dependency probes and unrecognised shapes: TestGoldenReplay jq-*, base64-*, date-*, shape-* cases and TestStatusRunnerProblems, TestJQRunner\n'
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/score-loop-transcript.sh" "$2" 2>/dev/null; then MS="$d/score-loop-transcript.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec eval score-loop --toolbelt "\$_RSDD_SELF" "\$@"#rsdd_exec eval score-loop --toolbelt "\$_RSDD_SELF"#'; then
    shim_run "$MS" --corpus x
    [[ "$SOUT" != *'ARG[--corpus]'* ]] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec eval score-loop #rsdd_exec eval score-loops #'; then
    shim_run "$MS" --corpus x
    [[ "$SOUT" != *'ARG[score-loop]'* ]] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard exits 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/score-loop-transcript.sh"
    out="$(bash "$TMP/mt/C-nolib/score-loop-transcript.sh" --corpus x 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec eval score-loop --toolbelt "\$_RSDD_SELF" "\$@"#( rsdd_exec eval score-loop --toolbelt "$_RSDD_SELF" "$@" ); exit 0#'; then
    shim_run "$MS" --corpus x
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the shim's own directory is no longer handed over (the Go command would have no toolbelt to find the status script in)
  if mk E 's#--toolbelt "\$_RSDD_SELF" ##'; then
    shim_run "$MS" --corpus x
    [[ "$SOUT" != *'ARG[--toolbelt]'* ]] && ok "teeth E: --toolbelt dropped -> forwarding check goes red" || no "teeth E: mutant still passes --toolbelt — THEATER"
  fi
  # F: end to end, a shim that hands the scorer another toolbelt cannot find research-sdd-status.sh: with no RSDD_STATUS_SCRIPT
  # override the C4 line degrades instead of reading the real status output, so the real-binary case goes red
  if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
    mkdir -p "$TMP/mt/F/lib"; cp "$TOOLBELT/lib/rsdd-exec.sh" "$TMP/mt/F/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
    if mutant_sed "$SUT" "$TMP/mt/F/score-loop-transcript.sh" 's#--toolbelt "\$_RSDD_SELF"#--toolbelt "/nonexistent-toolbelt/x"#' 2>/dev/null; then
      F_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" "${GENV[@]}" bash "$TMP/mt/F/score-loop-transcript.sh" --corpus "$TMP/continue" --transcript "$FIX/continue-clean.jsonl" 2>/dev/null)"
      T_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" "${GENV[@]}" bash "$SUT" --corpus "$TMP/continue" --transcript "$FIX/continue-clean.jsonl" 2>/dev/null)"
      [ "$F_OUT" != "$T_OUT" ] && ok "teeth F: a wrong --toolbelt changes the scorer's output (C4 cannot reach the status script) -> end-to-end case goes red" || no "teeth F: mutant output identical — THEATER"
    else no "teeth F: could not build mutant"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
