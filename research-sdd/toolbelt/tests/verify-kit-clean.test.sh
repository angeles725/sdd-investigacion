#!/usr/bin/env bash
# verify-kit-clean.test.sh — RED-FIRST harness for verify-kit-clean.sh (kit-audit Addendum B).
#
# The discriminating behaviour: is the kit repo in a CLEAN, committed, pushed state (safe to stage a retro
# or start clean work)? DIRTY working tree OR unpushed local commits → exit 1. --prove-teeth neuters the
# dirty check and asserts the dirty fixture then reports clean.
#
# Usage: verify-kit-clean.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-kit-clean.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

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
if grep -qiE 'audits/ exists at the kit/supervisor root' <<<"$out"; then ok "audits/ at kit root → advisory WARN fires"
else no "audits/ WARN missing :: $out"; fi

# 9 — NEGATIVE control: no `audits/` dir at the root → the audits-WARN does NOT fire (no false positive).
d="$TMP/noaudits"; mkrepo "$d"
out="$(runout "$d")"
if ! grep -qiE 'audits/ exists at the kit' <<<"$out"; then ok "no audits/ dir → no audits-WARN (no false positive)"
else no "audits-WARN fired without an audits/ dir :: $out"; fi

# NEGATIVE CONTROL — neuter the dirty check; the dirty fixture must then report clean (exit 0).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the porcelain dirty-check, expect the dirty fixture to pass as clean --"
  mutant="$TMP/verify-kit-clean.MUTANT.sh"
  sed 's/status --porcelain/status --porcelain --untracked-files=no/; s/\[ -n "\$porcelain" \]/[ -n "" ]/' "$SUT" > "$mutant"
  d="$TMP/teeth"; mkrepo "$d"; echo "changed" > "$d/f.txt"
  bash "$mutant" "$d" >/dev/null 2>&1; mrc=$?
  [ "$mrc" = 0 ] && ok "teeth: dirty-check-neutered mutant reports clean → check has teeth" || no "teeth: mutant exit=$mrc — dirty check not exercised (THEATER)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
