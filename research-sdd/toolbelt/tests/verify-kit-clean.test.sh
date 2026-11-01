#!/usr/bin/env bash
# verify-kit-clean.test.sh — harness for verify-kit-clean.sh (kit-audit Addendum B), now a shim to
# `rsdd verify kit-clean` (kit issue #2354).
#
# The discriminating behaviour: is the kit repo in a CLEAN, committed, pushed state (safe to stage a retro
# or start clean work)? DIRTY working tree OR unpushed local commits → exit 1. Cases 1-13 run the SHIM
# end to end against the real Go binary (RSDD_BIN, else built once from research-sdd/rsdd); the report text
# itself is also pinned byte for byte against the old bash script by the Go differential tests
# (internal/verify, `make test`). The old case 12 (a `grep -c` that exits 2) is gone with grep: counting
# lines in Go cannot fail. Cases 14-17 pin the shim: own-directory default, explicit argument, missing lib,
# unusable binary (a typed degraded state, never a silent pass).
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate
# (`make teeth` in research-sdd/rsdd).
#
# Usage: verify-kit-clean.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-kit-clean.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi

# a committed, clean repo with a pushed upstream (bare origin) on branch main
mkrepo() {
  local d="$1" origin="$1.origin.git"
  git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" symbolic-ref HEAD refs/heads/main; }
  echo "x" > "$d/f.txt"; git -C "$d" add -A; git -C "$d" commit -q -m init
  git init -q --bare "$origin"; git -C "$d" remote add origin "$origin"
  git -C "$d" push -q -u origin main 2>/dev/null
}
runrc(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
runout(){ bash "$SUT" "$1" 2>&1; }

echo "== verify-kit-clean.test.sh =="

# 1 — a clean, committed, pushed repo → exit 0, CLEAN.
d="$TMP/clean"; mkrepo "$d"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && grep -qiE 'clean' <<<"$out"; then ok "clean+pushed repo → exit 0"
else no "clean repo exit=$(runrc "$d") :: $out"; fi

# 2 — an uncommitted modification → exit 1, DIRTY.
d="$TMP/dirty"; mkrepo "$d"; echo "changed" > "$d/f.txt"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 1 ] && grep -qiE 'dirty|uncommitted' <<<"$out"; then ok "dirty working tree → exit 1"
else no "dirty repo exit=$(runrc "$d") :: $out"; fi

# 3 — an untracked file also counts as dirty → exit 1.
d="$TMP/untracked"; mkrepo "$d"; echo "new" > "$d/extra.txt"
[ "$(runrc "$d")" = 1 ] && ok "untracked file → exit 1 (dirty)" || no "untracked file not dirty (exit $(runrc "$d"))"

# 4 — a local commit not pushed to upstream → exit 1, reports unpushed.
d="$TMP/unpushed"; mkrepo "$d"; echo "y" > "$d/g.txt"; git -C "$d" add -A; git -C "$d" commit -q -m local-only
out="$(runout "$d")"
if [ "$(runrc "$d")" = 1 ] && grep -qiE 'not pushed|unpushed|ahead' <<<"$out"; then ok "unpushed commit → exit 1"
else no "unpushed exit=$(runrc "$d") :: $out"; fi

# 5 — not a git repo → exit 2.
d="$TMP/notgit"; mkdir -p "$d"
[ "$(runrc "$d")" = 2 ] && ok "non-git dir → exit 2" || no "non-git dir exit=$(runrc "$d") (want 2)"

# 6 — clean but no upstream configured → still exit 0 (can't be 'unpushed' without an upstream), noted.
d="$TMP/noupstream"; git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" symbolic-ref HEAD refs/heads/main; }
echo x > "$d/f.txt"; git -C "$d" add -A; git -C "$d" commit -q -m init
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && grep -qiE 'no upstream|clean' <<<"$out"; then ok "clean, no upstream → exit 0 (noted)"
else no "no-upstream exit=$(runrc "$d") :: $out"; fi

# 7 — pushed WITHOUT -u (no tracking ref) but local-ahead → still caught via the origin/<branch> fallback.
d="$TMP/noupstream_ahead"
git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" symbolic-ref HEAD refs/heads/main; }
echo x > "$d/f.txt"; git -C "$d" add -A; git -C "$d" commit -q -m init
git init -q --bare "$d.origin.git"; git -C "$d" remote add origin "$d.origin.git"
git -C "$d" push -q origin main 2>/dev/null            # NOTE: no -u → no @{upstream} tracking ref
echo z > "$d/h.txt"; git -C "$d" add -A; git -C "$d" commit -q -m local-only-no-upstream
out="$(runout "$d")"
if [ "$(runrc "$d")" = 1 ] && grep -qiE 'not pushed' <<<"$out"; then ok "no -u tracking, local-ahead → caught via origin/<branch> fallback (exit 1)"
else no "no-upstream-ahead missed: exit=$(runrc "$d") :: $out"; fi

# 8 — an `audits/` dir at the kit/supervisor REPO ROOT → the advisory audits-WARN fires (audits are
#     TARGET-scoped only, §13 / PROMPT-AUDIT). An empty dir keeps git status clean, so this also proves
#     the WARN is ADDITIVE — independent of the clean/dirty verdict.
d="$TMP/withaudits"; mkrepo "$d"; mkdir -p "$d/audits"
out="$(runout "$d")"
if grep -qiE 'audits/ exists at the kit/supervisor root' <<<"$out" && [ "$(runrc "$d")" = 0 ]; then ok "audits/ at kit root → advisory WARN fires (verdict unchanged)"
else no "audits/ WARN missing or verdict changed :: $out"; fi

# 9 — NEGATIVE control: no `audits/` dir at the root → the audits-WARN does NOT fire (no false positive).
d="$TMP/noaudits"; mkrepo "$d"
out="$(runout "$d")"
if ! grep -qiE 'audits/ exists at the kit' <<<"$out"; then ok "no audits/ dir → no audits-WARN (no false positive)"
else no "audits-WARN fired without an audits/ dir :: $out"; fi

# 10 — git-status failure (git exits non-zero after a successful rev-parse) must NOT report CLEAN and must
#       exit non-zero. A git stub is placed first on PATH: it returns a plausible repo root for rev-parse
#       but exits 5 for 'status --porcelain', simulating an internal git error.
_stub10="$TMP/stub-bin-10"
mkdir -p "$_stub10"
cat > "$_stub10/git" << STUB10
#!/usr/bin/env bash
case "\$*" in
  *rev-parse*--show-toplevel*)   echo "/tmp/fake-root"; exit 0 ;;
  *rev-parse*--abbrev-ref*)      echo "main";           exit 0 ;;
  *status*--porcelain*)          exit 5                         ;;
  *rev-list*)                    echo "0";              exit 0 ;;
  *)                                                    exit 0 ;;
esac
STUB10
chmod +x "$_stub10/git"
d="$TMP/gitstatusfail"; mkdir -p "$d"
out="$(PATH="$_stub10:$PATH" bash "$SUT" "$d" 2>&1)"
PATH="$_stub10:$PATH" bash "$SUT" "$d" >/dev/null 2>&1; _grc=$?
if [ "$_grc" -ne 0 ] && ! grep -qiE 'working tree.*CLEAN|verdict.*: clean' <<<"$out" \
   && grep -qiE 'git status failed|cannot determine' <<<"$out"; then
  ok "git-status failure → non-zero exit + error reported, NOT CLEAN"
else
  no "git-status failure not detected: exit=$_grc :: $out"
fi

# 11 — DIRTY with all counters 0 (contradiction) → WARN fires.
# Stub git so that status --porcelain is non-empty but diff/ls-files return nothing.
_stub11="$TMP/stub-bin-11"; mkdir -p "$_stub11"
cat > "$_stub11/git" << 'STUB11'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*--show-toplevel*)            echo "/tmp/fake-r11"; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*)          echo "main";          exit 0 ;;
  *status*--porcelain*)                   printf '?? newfile.txt\n'; exit 0 ;;
  *diff*--cached*--name-only*)            exit 0 ;;
  *diff*--name-only*)                     exit 0 ;;
  *ls-files*--others*--exclude-standard*) exit 0 ;;
  *rev-list*)                             echo "0"; exit 0 ;;
  *rev-parse*upstream*)                   exit 1 ;;
  *)                                      exit 0 ;;
esac
STUB11
chmod +x "$_stub11/git"
d11="$TMP/contradiction"; mkdir -p "$d11"
out11="$(PATH="$_stub11:$PATH" bash "$SUT" "$d11" 2>&1)"
if <<<"$out11" grep -qi 'counters disagree\|all three counters read 0'; then
  ok "11 all-counters-0 contradiction → WARN fires"
else
  no "11 contradiction WARN missing (out=[$out11])"
fi

# 12 — (retired) the old case 12 stubbed `grep` to exit 2; the Go port counts lines without grep.

# 13 — kit issue #1820: every git read carries GIT_OPTIONAL_LOCKS=0 (a SessionStart read must never take
#       index.lock while a sibling session commits). A recording PATH-stub git logs the env it receives and
#       delegates to the real git; the dirty + upstream fixture drives the status, diff, ls-files and rev-list reads.
_stub13="$TMP/stub-bin-13"; mkdir -p "$_stub13"
_REALGIT="$(type -P git)"
cat > "$_stub13/git" << STUB13
#!/usr/bin/env bash
printf 'LOCKS=%s :: %s\n' "\${GIT_OPTIONAL_LOCKS-UNSET}" "\$*" >> "$TMP/git13.log"
exec "$_REALGIT" "\$@"
STUB13
chmod +x "$_stub13/git"
d13="$TMP/locks"; mkrepo "$d13"; echo "changed" > "$d13/f.txt"; echo n > "$d13/new.txt"
: > "$TMP/git13.log"
env -u GIT_OPTIONAL_LOCKS PATH="$_stub13:$PATH" bash "$SUT" "$d13" >/dev/null 2>&1
n13="$(grep -c . "$TMP/git13.log")"; bad13="$(grep -vc 'LOCKS=0 ::' "$TMP/git13.log")"
if [ "$n13" -ge 4 ] && [ "$bad13" = 0 ] && grep -q ' status ' "$TMP/git13.log" && grep -q ' diff ' "$TMP/git13.log"; then
  ok "13 every git read carries GIT_OPTIONAL_LOCKS=0 ($n13 calls)"
else
  no "13 git reads without GIT_OPTIONAL_LOCKS=0: calls=$n13 unlocked=$bad13 :: $(grep -v 'LOCKS=0 ::' "$TMP/git13.log" | head -3 | tr '\n' '|')"
fi

# stage_shim DEST_TOOLBELT [SHIM] — a sandbox toolbelt holding the shim (the real one, or a mutant) and lib/rsdd-exec.sh.
stage_shim() { mkdir -p "$1"; cp "${2:-$SUT}" "$1/verify-kit-clean.sh"; chmod +x "$1/verify-kit-clean.sh"; mkdir -p "$1/lib" && cp "$HERE/../lib/rsdd-exec.sh" "$1/lib/" || exit 2; }

# 14 — the default repository is the script's OWN directory (never the caller's cwd). The shim sits in a repo,
#      committed; run from a non-repo cwd it reports that repo, and turns DIRTY when the repo does.
d14="$TMP/selfrepo"; mkrepo "$d14"; stage_shim "$d14"
git -C "$d14" add -A; git -C "$d14" commit -q -m shim; git -C "$d14" push -q origin main 2>/dev/null
out14="$(cd "$TMP" && bash "$d14/verify-kit-clean.sh" 2>&1)"; rc14=$?
echo dirt > "$d14/zz.txt"
(cd "$TMP" && bash "$d14/verify-kit-clean.sh" >/dev/null 2>&1); rc14b=$?
if [ "$rc14" = 0 ] && [ "$rc14b" = 1 ] && grep -q '== verify-kit-clean: selfrepo (branch: main) ==' <<<"$out14"; then
  ok "14 no argument → checks the shim's own directory, not the cwd"
else no "14 default repo wrong: rc=$rc14/$rc14b :: $out14"; fi
rm -f "$d14/zz.txt"

# 15 — an explicit argument wins over the own-directory default.
d15="$TMP/arg-dirty"; mkrepo "$d15"; echo changed > "$d15/f.txt"
bash "$d14/verify-kit-clean.sh" "$d15" >/dev/null 2>&1; rc15=$?
if [ "$rc15" = 1 ]; then ok "15 explicit repo argument overrides the own-directory default"; else no "15 argument ignored (rc=$rc15, want 1)"; fi

# 16 — the shim's own lib missing → a typed degraded line, rc 2, nothing on stdout (never a silent pass).
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-kit-clean.sh"
out16="$(bash "$TMP/nolib/verify-kit-clean.sh" 2>"$TMP/err16")"; rc16=$?
if [ "$rc16" = 2 ] && [ -z "$out16" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/verify-kit-clean.sh\$" "$TMP/err16"; then
  ok "16 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "16 missing lib: rc=$rc16 out=[$out16] err=[$(cat "$TMP/err16")]"; fi

# 17 — an unusable RSDD_BIN → typed degraded line, rc 2 (the gate could not run: not clean, not a pass).
out17="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" "$TMP/clean" 2>"$TMP/err17")"; rc17=$?
if [ "$rc17" = 2 ] && [ -z "$out17" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err17"; then
  ok "17 unusable RSDD_BIN → typed degraded line, rc 2"
else no "17 unusable binary: rc=$rc17 out=[$out17] err=[$(cat "$TMP/err17")]"; fi

# NEGATIVE CONTROL — each shim mutation must lose its case.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the argument is dropped (always the own directory) → case 15.
  if mk_mut "teeth A: argument ignored" "$SUT" "$TMP/mutA.sh" 's/"\${1:-\$_RSDD_SELF}"/"$_RSDD_SELF"/'; then
    stage_shim "$TMP/mA" "$TMP/mutA.sh"   # not a repo: an ignored argument falls back to it → rc 2
    bash "$TMP/mA/verify-kit-clean.sh" "$d15" >/dev/null 2>&1; mrc=$?
    if [ "$mrc" != 1 ]; then ok "teeth A: argument ignored → case 15 would go RED (rc $mrc)"; else no "teeth A: mutant still honours the argument"; fi
  fi
  # B: the default becomes the cwd instead of the own directory → case 14.
  if mk_mut "teeth B: default is cwd" "$SUT" "$TMP/mutB.sh" 's/"\${1:-\$_RSDD_SELF}"/"${1:-}"/'; then
    stage_shim "$TMP/mB" "$TMP/mutB.sh"
    ( cd "$TMP" && bash "$TMP/mB/verify-kit-clean.sh" >/dev/null 2>&1 ); mrc=$?
    if [ "$mrc" = 2 ]; then ok "teeth B: cwd default from a non-repo cwd → rc 2, case 14 would go RED"; else no "teeth B: mutant rc=$mrc (want 2)"; fi
  fi
  # C: the shim runs the hook command instead of the check → no report, case 1 loses 'verdict'.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/verify kit-clean /verify kit-clean-hook /'; then
    stage_shim "$TMP/mC" "$TMP/mutC.sh"
    outc="$(bash "$TMP/mC/verify-kit-clean.sh" "$TMP/dirty" 2>&1)"
    if [ "${outc:0:1}" = "{" ] && grep -q hookSpecificOutput <<<"$outc"; then ok "teeth C: wrong command → report replaced by an envelope, cases 2/4 would go RED"; else no "teeth C: mutant still prints the report"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 16.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-kit-clean.sh"
    bash "$TMP/mD/verify-kit-clean.sh" >/dev/null 2>"$TMP/errD"; mrc=$?
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 16 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
