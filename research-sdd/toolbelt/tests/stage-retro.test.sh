#!/usr/bin/env bash
# stage-retro.test.sh — shim contract of stage-retro.sh (kit issue #2663).
#
# stage-retro.sh is a compatibility shim over `rsdd retro stage` (Go). The stager's behaviour (the review-status
# and kit-retro guards, the target label, the branch name, the self-referential-target guard, every refusal exit
# code, the git side effects and every message byte) is covered by the Go tests in
# research-sdd/rsdd/internal/retro/stage: recorded goldens from the frozen pre-port script, a live differential
# against it, and the divergence tests for the defects the port fixes. This suite checks only what the shim itself
# owns: it passes its own directory as `--toolbelt <dir>` before the caller's arguments, forwards arguments, the
# exit code and stderr unchanged, degrades through rsdd-exec (typed, exit 2) when rsdd cannot run, and, when the
# runner hands it a built binary (RSDD_BIN), reaches the real stager end to end in a hermetic kit repo (including
# through a symlinked toolbelt, the profile installer's layout, kit issue #1024). Mutation controls under
# --prove-teeth.
#
# The mutation controls of the retired bash suite sed the old script body (the fail-closed helper guard, the
# `git checkout -b` checks, the self-referential guard, the -P resolutions, the registered-name lookup, the
# switch-back wording); that body is gone. Their Go replacements are named in the SKIP lines below.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/stage-retro.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== stage-retro.test.sh =="

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
  shim_run "$shim" 'a b.md' --force ''
  want=$'ARG[retro]\nARG[stage]\nARG[--toolbelt]\nARG['"$(dirname "$shim")"$']\nARG[a b.md]\nARG[--force]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'retro stage --toolbelt <own dir>' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" x.md 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q 'staging retro' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no branch staged (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/stage-retro.sh"
out="$(bash "$TMP/nolib/stage-retro.sh" x.md 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no git, sed, tr or sourced retro library left behind.
if grep -qF 'rsdd_exec retro stage --toolbelt "$_RSDD_SELF" "$@"' "$SUT" && ! grep -qE 'git |sed |tr -c|retro-status|target-paths|retro_review_status|checkout' "$SUT"; then
  ok "4 shim body is 'rsdd_exec retro stage --toolbelt \"\$_RSDD_SELF\" \"\$@\"' with no git / sed / sourced-library logic left"
else no "4 shim body"; fi

# 5. End to end through the real binary (the runner builds one and exports RSDD_BIN; without it the shim would
# build bin/rsdd inside the tree, which the kit-tree hermeticity check forbids). Every case runs in a throwaway kit
# repo with a bare origin, a fixed identity and no ambient git configuration; the kit repo here is never touched.
GENV=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com)
g() { env "${GENV[@]}" git -c maintenance.auto=false -c gc.auto=0 "$@"; }
# mkbox NAME MARKER -> a kit repo at $TMP/NAME/repo holding the real shim, the retro targetA/retros/r1.md (committed and
# pushed to a bare origin); prints nothing
mkbox() {
  local d="$TMP/$1" r="$TMP/$1/repo"
  mkdir -p "$r/research-sdd/toolbelt/lib" "$r/targetA/retros"
  cp "$SUT" "$r/research-sdd/toolbelt/stage-retro.sh"; cp "$TOOLBELT/lib/rsdd-exec.sh" "$r/research-sdd/toolbelt/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
  printf '%s\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n' "$2" > "$r/targetA/retros/r1.md"
  g -C "$r" init -q -b main && g -C "$r" add -A && g -C "$r" commit -qm init \
    && g init -q --bare -b main "$d/origin.git" && g -C "$r" remote add origin "$d/origin.git" && g -C "$r" push -q origin main
}
e2e_run() { E2E_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" "${GENV[@]}" bash "$1" "${@:2}" 2>"$TMP/e2e.err")"; E2E_RC=$?; E2E_ERR="$(cat "$TMP/e2e.err")"; }
branches() { g -C "$1" for-each-ref --format='%(refname:short)' 'refs/heads/retro/*'; }
if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
  mkbox pend '<!-- review-status: pending -->'
  e2e_run "$TMP/pend/repo/research-sdd/toolbelt/stage-retro.sh" "$TMP/pend/repo/targetA/retros/r1.md"
  if [ "$E2E_RC" -eq 0 ] && grep -qF '>> staging retro for supervised review' <<< "$E2E_OUT" && [ "$(branches "$TMP/pend/repo")" = "retro/targetA-r1" ] \
     && [ "$(g -C "$TMP/pend/repo" rev-parse retro/targetA-r1)" = "$(g -C "$TMP/pend/repo" rev-parse origin/main)" ]; then
    ok "5a pending retro through the real binary -> branch retro/targetA-r1 at origin/main, exit 0"
  else no "5a pending (rc=$E2E_RC branches=[$(branches "$TMP/pend/repo")] err=[$E2E_ERR])"; fi

  mkbox appl '<!-- review-status: applied 2026-01-01 · kit deadbeef -->'
  e2e_run "$TMP/appl/repo/research-sdd/toolbelt/stage-retro.sh" "$TMP/appl/repo/targetA/retros/r1.md"
  if [ "$E2E_RC" -eq 2 ] && grep -qF "already 'applied'" <<< "$E2E_ERR" && [ -z "$(branches "$TMP/appl/repo")" ]; then
    ok "5b applied retro -> refused with exit 2 on stderr, no branch (the guard fires before any git mutation)"
  else no "5b applied (rc=$E2E_RC branches=[$(branches "$TMP/appl/repo")] err=[$E2E_ERR])"; fi

  mkbox link '<!-- review-status: pending -->'
  mkdir -p "$TMP/link/profile/research-sdd/profile/myprofile"
  ln -s "$TMP/link/repo/research-sdd/toolbelt" "$TMP/link/profile/research-sdd/profile/myprofile/toolbelt"
  e2e_run "$TMP/link/profile/research-sdd/profile/myprofile/toolbelt/stage-retro.sh" "$TMP/link/repo/targetA/retros/r1.md"
  if [ "$E2E_RC" -eq 0 ] && [ "$(branches "$TMP/link/repo")" = "retro/targetA-r1" ]; then
    ok "5c invoked through a symlinked toolbelt dir (#1024 profile) still resolves the real kit repo"
  else no "5c symlinked toolbelt (rc=$E2E_RC branches=[$(branches "$TMP/link/repo")] err=[$E2E_ERR])"; fi

  e2e_run "$SUT"
  if [ "$E2E_RC" -eq 1 ] && grep -qF 'usage: stage-retro.sh <path-to-retro.md>' <<< "$E2E_ERR" && [ -z "$E2E_OUT" ]; then ok "5d no argument -> usage on stderr, exit 1"
  else no "5d usage (rc=$E2E_RC err=[$E2E_ERR])"; fi
else
  printf '  SKIP  5 end to end: RSDD_BIN not set to an executable (run it through run-all.sh, which builds the binary once)\n'
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for stage-retro.sh (shim) --"
  # The retired controls sed the old script body, which is gone: each is a typed SKIP naming the Go test that replaces it
  # (research-sdd/rsdd/internal/retro/stage).
  printf '  SKIP  teeth (old cases 3, 4, 25) fail-closed helper guard: the grammar and the registry reader are linked in, so no helper can be missing; TestNoHelperFilesAreNeeded\n'
  printf '  SKIP  teeth (old cases 9-17 and their mutants) checkout / fetch / self-referential / readability guards: parity/09 .. parity/17 of TestGoldenReplay and TestDifferential, TestExit8*\n'
  printf '  SKIP  teeth (old cases 20-24, T1287a-c, T1369d) registered-name label and its fallbacks: parity/20 .. parity/25 of TestGoldenReplay\n'
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/stage-retro.sh" "$2" 2>/dev/null; then MS="$d/stage-retro.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec retro stage --toolbelt "\$_RSDD_SELF" "\$@"#rsdd_exec retro stage --toolbelt "\$_RSDD_SELF"#'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[x.md]'* ]] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec retro stage #rsdd_exec retro stagee #'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[stage]'* ]] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard exits 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/stage-retro.sh"
    out="$(bash "$TMP/mt/C-nolib/stage-retro.sh" x.md 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec retro stage --toolbelt "\$_RSDD_SELF" "\$@"#( rsdd_exec retro stage --toolbelt "$_RSDD_SELF" "$@" ); exit 0#'; then
    shim_run "$MS" x.md
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the shim's own directory is no longer handed over (the Go command would have no kit root)
  if mk E 's#--toolbelt "\$_RSDD_SELF" ##'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[--toolbelt]'* ]] && ok "teeth E: --toolbelt dropped -> forwarding check goes red" || no "teeth E: mutant still passes --toolbelt — THEATER"
  fi
  # F: end to end, a shim that hands the stager another directory finds another kit root and stages nothing: the
  # real-binary case (5a) goes red
  if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ]; then
    mkbox mut '<!-- review-status: pending -->'
    mkdir -p "$TMP/mt/F/lib"; cp "$TOOLBELT/lib/rsdd-exec.sh" "$TMP/mt/F/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
    if mutant_sed "$SUT" "$TMP/mt/F/stage-retro.sh" 's#--toolbelt "\$_RSDD_SELF"#--toolbelt "/nonexistent-toolbelt/x"#' 2>/dev/null; then
      e2e_run "$TMP/mt/F/stage-retro.sh" "$TMP/mut/repo/targetA/retros/r1.md"
      [ -z "$(branches "$TMP/mut/repo")" ] && ok "teeth F: a wrong --toolbelt stages nothing -> the end-to-end case (5a) goes red" || no "teeth F: mutant still stages — THEATER"
    else no "teeth F: could not build mutant"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
