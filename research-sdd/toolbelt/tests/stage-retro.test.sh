#!/usr/bin/env bash
# stage-retro.test.sh — end-to-end contract of stage-retro.sh (kit issue #2663).
#
# stage-retro.sh stages ONE pending §18 retro as a branch in the kit repo for supervised review (METHODOLOGY §18).
# It MUTATES a git repo (`git checkout -b retro/<target>-<slug>`), so its review-status guard is safety-critical:
# an already-applied or dismissed retro must be refused BEFORE any branch is created.
#
# The behaviour of the stager (the review-status and kit-retro guards, the target label, the branch name, the
# self-referential-target guard, every refusal exit code, the git side effects and every message byte) is covered
# by the Go tests in research-sdd/rsdd/internal/retro/stage: goldens recorded from this very script (frozen under
# testdata/legacy), a live differential against it, and the divergence tests for the defects the port fixes. This
# suite keeps only what a caller sees end to end in a hermetic kit repo with a bare origin: a pending retro is
# staged, an applied one is refused before any git mutation, a symlinked toolbelt (the profile installer's layout,
# kit issue #1024) still finds the real kit repo, and no argument prints the usage.
#
# The mutation controls of the previous suite sed the script body; the Go tests replace them (named in the SKIP
# lines under --prove-teeth).
#
# Usage: stage-retro.test.sh                (run the suite)
#        stage-retro.test.sh --prove-teeth  (the same, plus the typed SKIPs of the retired controls)
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/stage-retro.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== stage-retro.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] || { echo "FATAL: absent-input: script under test: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: absent-input: git not on PATH" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Every case runs in a throwaway kit repo with a bare origin, a fixed identity and no ambient git configuration; the
# kit repo this suite lives in is never touched.
GENV=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com)
g() { env "${GENV[@]}" git -c maintenance.auto=false -c gc.auto=0 "$@"; }
# mkbox NAME MARKER -> a kit repo at $TMP/NAME/repo holding the script and its libs under research-sdd/toolbelt, the
# retro targetA/retros/r1.md (committed and pushed to a bare origin)
mkbox() {
  local d="$TMP/$1" r="$TMP/$1/repo"
  mkdir -p "$r/research-sdd/toolbelt/lib" "$r/targetA/retros"
  cp "$SUT" "$r/research-sdd/toolbelt/stage-retro.sh"
  cp "$TOOLBELT/lib/retro-status.sh" "$TOOLBELT/lib/target-paths.sh" "$r/research-sdd/toolbelt/lib/"   # stage-libs-ok: the script sources exactly these two
  printf '%s\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n' "$2" > "$r/targetA/retros/r1.md"
  g -C "$r" init -q -b main && g -C "$r" add -A && g -C "$r" commit -qm init \
    && g init -q --bare -b main "$d/origin.git" && g -C "$r" remote add origin "$d/origin.git" && g -C "$r" push -q origin main
}
e2e_run() { E2E_OUT="$(env -i PATH="$PATH" HOME="$TMP" "${GENV[@]}" bash "$1" "${@:2}" 2>"$TMP/e2e.err")"; E2E_RC=$?; E2E_ERR="$(cat "$TMP/e2e.err")"; }
branches() { g -C "$1" for-each-ref --format='%(refname:short)' 'refs/heads/retro/*'; }

mkbox pend '<!-- review-status: pending -->'
e2e_run "$TMP/pend/repo/research-sdd/toolbelt/stage-retro.sh" "$TMP/pend/repo/targetA/retros/r1.md"
if [ "$E2E_RC" -eq 0 ] && grep -qF '>> staging retro for supervised review' <<< "$E2E_OUT" && [ "$(branches "$TMP/pend/repo")" = "retro/targetA-r1" ] \
   && [ "$(g -C "$TMP/pend/repo" rev-parse retro/targetA-r1)" = "$(g -C "$TMP/pend/repo" rev-parse origin/main)" ]; then
  ok "5a pending retro -> branch retro/targetA-r1 at origin/main, exit 0"
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

e2e_run "$TMP/pend/repo/research-sdd/toolbelt/stage-retro.sh"
if [ "$E2E_RC" -eq 1 ] && grep -qF 'usage: stage-retro.sh <path-to-retro.md>' <<< "$E2E_ERR" && [ -z "$E2E_OUT" ]; then ok "5d no argument -> usage on stderr, exit 1"
else no "5d usage (rc=$E2E_RC err=[$E2E_ERR])"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: the mutation controls of the retired suite sed the script body; the Go tests replace them --"
  printf '  SKIP  teeth (old cases 3, 4, 25) fail-closed helper guard: TestNoHelperFilesAreNeeded\n'
  printf '  SKIP  teeth (old cases 9-17 and their mutants) checkout / fetch / self-referential / readability guards: parity/09 .. parity/17 of TestGoldenReplay and TestDifferential, TestExit8*\n'
  printf '  SKIP  teeth (old cases 20-24, T1287a-c, T1369d) registered-name label and its fallbacks: parity/20 .. parity/25 of TestGoldenReplay\n'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
