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
if printf '%s\n' "$out11" | grep -qi 'counters disagree\|all three counters read 0'; then
  ok "11 all-counters-0 contradiction → WARN fires"
else
  no "11 contradiction WARN missing (out=[$out11])"
fi

# 12 — grep exits 2 (counter failure) → WARN: count FAILED fires.
_stub12="$TMP/stub-bin-12"; mkdir -p "$_stub12"
cat > "$_stub12/git" << 'STUB12'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*--show-toplevel*)            echo "/tmp/fake-r12"; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*)          echo "main";          exit 0 ;;
  *status*--porcelain*)                   printf 'M  modified.txt\n'; exit 0 ;;
  *diff*--cached*--name-only*)            printf 'modified.txt\n'; exit 0 ;;
  *diff*--name-only*)                     exit 0 ;;
  *ls-files*--others*--exclude-standard*) exit 0 ;;
  *rev-list*)                             echo "0"; exit 0 ;;
  *rev-parse*upstream*)                   exit 1 ;;
  *)                                      exit 0 ;;
esac
STUB12
chmod +x "$_stub12/git"
cat > "$_stub12/grep" << 'STUBGREP'
#!/usr/bin/env bash
# Exit 2 (grep error) for -c (count) calls; pass through all others.
case "$*" in
  *-c*) exit 2 ;;
  *)    /usr/bin/grep "$@" ;;
esac
STUBGREP
chmod +x "$_stub12/grep"
d12="$TMP/greparr"; mkdir -p "$d12"
out12="$(PATH="$_stub12:$PATH" bash "$SUT" "$d12" 2>&1)"
if printf '%s\n' "$out12" | grep -qi 'count FAILED\|grep exit'; then
  ok "12 grep exit 2 on counter → 'count FAILED' WARN fires"
else
  no "12 count-FAILED WARN missing (out=[$out12])"
fi

# NEGATIVE CONTROL — neuter the dirty check; the dirty fixture must then report clean (exit 0).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the porcelain dirty-check, expect the dirty fixture to pass as clean --"
  mutant="$TMP/verify-kit-clean.MUTANT.sh"
  sed 's/status --porcelain/status --porcelain --untracked-files=no/; s/\[ -n "\$porcelain" \]/[ -n "" ]/' "$SUT" > "$mutant"
  d="$TMP/teeth"; mkrepo "$d"; echo "changed" > "$d/f.txt"
  bash "$mutant" "$d" >/dev/null 2>&1; mrc=$?
  [ "$mrc" = 0 ] && ok "teeth: dirty-check-neutered mutant reports clean → check has teeth" || no "teeth: mutant exit=$mrc — dirty check not exercised (THEATER)"

  # Additional mutation control: neuter the git-status rc-check; the git-fail stub must then exit 0 (CLEAN).
  echo "-- teeth: neuter the git_rc check, expect git-status failure to pass silently as clean --"
  mutant2="$TMP/verify-kit-clean.MUTANT2.sh"
  sed 's/git_rc=\$?/git_rc=0/' "$SUT" > "$mutant2"
  d_tf="$TMP/teeth-gitfail"; mkdir -p "$d_tf"
  PATH="$_stub10:$PATH" bash "$mutant2" "$d_tf" >/dev/null 2>&1; mrc2=$?
  [ "$mrc2" -eq 0 ] && ok "teeth: git-rc-check-neutered mutant exits 0 (silently clean) → rc-check has teeth" \
    || no "teeth: mutant exit=$mrc2 — git-status rc check not exercised (THEATER)"

  # Tooth: reintroduce || true on one counter + stub grep to exit 2 → contradiction/failed WARN disappears.
  echo "-- teeth: || true on counter + grep exit 2 → WARNs must disappear (tests 11+12 go RED) --"
  mutant3="$TMP/verify-kit-clean.MUTANT3.sh"
  # Neuter the _sgrc check by replacing grep -c . with 'grep -c . || true' style:
  # Replace '; _sgrc=$?' with '|| true); _sgrc=$?' and remove the WARN checks.
  sed 's/grep -c \./grep -c . || true/g; /WARN: DIRTY but all three counters/d; /WARN: staged count FAILED/d; /WARN: unstaged count FAILED/d; /WARN: untracked count FAILED/d' \
    "$SUT" > "$mutant3"
  # Run the contradiction scenario (stub11) against mutant3 — WARN must be absent.
  out_m3="$(PATH="$_stub11:$PATH" bash "$mutant3" "$d11" 2>&1)"
  if ! printf '%s\n' "$out_m3" | grep -qi 'counters disagree\|count FAILED'; then
    ok "teeth: || true mutant silences contradiction/failed WARNs → tests 11+12 would catch it (RED)"
  else
    no "teeth: || true mutant still emits WARNs — tooth has no bite"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
