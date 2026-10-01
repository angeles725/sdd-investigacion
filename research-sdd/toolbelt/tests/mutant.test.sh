#!/usr/bin/env bash
# mutant.test.sh — suite for tests/lib/mutant.sh (kit issue #943, root class "teeth pass for the
# wrong reason"). The helper builds a mutant COPY of a SUT in a temp dir and REFUSES a mutant that
# is absent, empty, byte-identical to the original (the mutation never applied), not valid bash,
# or placed outside the temp root (it would land in the live tree — kit issue #1156).
#
# Usage: mutant.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$LIB"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Originals live in $TMP/src and mutants in $TMP: with no git, "the tree ORIG lives in" is its own
# physical dir, and an OUT beside the SUT is exactly what the helper refuses.
mkdir -p "$TMP/src"
ORIG="$TMP/src/orig.sh"
printf '#!/usr/bin/env bash\nif true; then\n  echo hello\nfi\n' > "$ORIG"

# expect_rc <label> <want-rc> <want-stderr-substring> <cmd...> — runs cmd, checks the exact rc and
# that stderr names the specific refusal (a bare non-zero is not enough: "any failure" is the
# wrong-reason class this helper exists to stop).
expect_rc(){
  local label="$1" want="$2" needle="$3"; shift 3
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$err" == *"$needle"* ]]; then ok "$label"
  else no "$label (rc=$rc want=$want; stderr=[$err])"; fi
}

# 1 — happy path: applied mutation returns 0, differs from the original, original untouched.
out="$TMP/m1.sh"
mutant_sed "$ORIG" "$out" 's/hello/goodbye/' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ] && grep -q goodbye "$out" && grep -q hello "$ORIG" && ! cmp -s "$ORIG" "$out"; then
  ok "happy path: mutant built, differs from SUT, SUT unchanged"
else no "happy path failed (rc=$rc)"; fi

# 2 — no-match: the sed script matches nothing, so the mutant is byte-identical.
out="$TMP/m2.sh"
expect_rc "no-match: byte-identical mutant is refused (rc 4, says identical)" 4 "identical" \
  mutant_sed "$ORIG" "$out" 's/NO_SUCH_ANCHOR/x/'
if [ ! -e "$out" ]; then ok "no-match: refused mutant file is not left behind"
else no "no-match: refused mutant file still exists"; fi

# 3 — empty mutant.
out="$TMP/m3.sh"
expect_rc "empty: a mutant that deletes everything is refused (rc 3, says empty)" 3 "empty" \
  mutant_sed "$ORIG" "$out" 'd'
if [ ! -e "$out" ]; then ok "empty: refused mutant file is not left behind"
else no "empty: refused mutant file still exists"; fi

# 4 — syntax: a delete that leaves a dangling `if` is refused by default, allowed when opted out.
out="$TMP/m4.sh"
expect_rc "syntax: mutant that is not valid bash is refused (rc 5, says bash -n)" 5 "bash -n" \
  mutant_sed "$ORIG" "$out" '/^fi$/d'
out="$TMP/m4b.sh"
MUTANT_SYNTAX=none mutant_sed "$ORIG" "$out" '/^fi$/d' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "syntax opt-out: MUTANT_SYNTAX=none skips the bash -n check"
else no "syntax opt-out: rc=$rc"; fi

# 5 — absent / empty original are distinct from an empty mutant.
out="$TMP/m5.sh"
expect_rc "absent original: refused (rc 2, says not a readable file)" 2 "not a readable file" \
  mutant_sed "$TMP/does-not-exist.sh" "$out" 's/a/b/'
: > "$TMP/src/empty-orig.sh"
expect_rc "empty original: refused (rc 3, says original is empty)" 3 "original is empty" \
  mutant_sed "$TMP/src/empty-orig.sh" "$out" 's/a/b/'

# 5b — mutant_verify has its OWN rc-2 paths (absent original; mutant never produced), distinct from
#      mutant_sed's: each names its specific refusal.
expect_rc "verify: absent original is refused (rc 2, says not a readable file)" 2 "not a readable file" \
  mutant_verify "$TMP/does-not-exist.sh" "$TMP/m5b.sh"
expect_rc "verify: mutant that was never produced is refused (rc 2, says was not produced)" 2 "was not produced" \
  mutant_verify "$ORIG" "$TMP/m5b-never-built.sh"

# 6 — sed itself fails (unterminated s command).
out="$TMP/m6.sh"
expect_rc "sed failure: refused (rc 6, says sed failed)" 6 "sed failed" \
  mutant_sed "$ORIG" "$out" 's/a'

# 7 — never overwrite the original.
expect_rc "self-overwrite: OUT equal to the original path is refused (rc 7)" 7 "same path" \
  mutant_sed "$ORIG" "$ORIG" 's/hello/x/'
if grep -q hello "$ORIG"; then ok "self-overwrite: original bytes intact"
else no "self-overwrite: original was modified"; fi

# 8 — placement (kit issue #1156). The "live tree" here is ALWAYS a fake under $TMP — never $HERE:
# a probe written into the real toolbelt/tests would itself be the #1156 pattern.
# 8a — OUT inside the tree ORIG lives in (a git work tree) is refused BEFORE anything is written,
#      even though that tree sits UNDER the temp root (the old check only tested the temp root).
if command -v git >/dev/null 2>&1; then
  live="$TMP/live-repo"; mkdir -p "$live/sub" && git init -q "$live" 2>/dev/null
  printf '#!/usr/bin/env bash\necho hello\n' > "$live/sut.sh"
  for rel in LIVE.MUTANT.sh sub/NESTED.MUTANT.sh; do
    expect_rc "placement: OUT at live-repo/$rel is refused (rc 8, says live tree)" 8 "live tree" \
      mutant_sed "$live/sut.sh" "$live/$rel" 's/hello/x/'
    if [ ! -e "$live/$rel" ]; then ok "placement: nothing written at live-repo/$rel"
    else no "placement: refused mutant was written at live-repo/$rel"; fi
  done
else
  ok "placement: SKIP git cases — no git on PATH (the non-git fallback below still runs)"
fi
# 8b — no git: the tree ORIG lives in is its own physical dir; OUT beside the SUT is refused.
plain="$TMP/plain-tree"; mkdir -p "$plain" "$TMP/nogit-bin"; printf '#!/bin/sh\nexit 127\n' > "$TMP/nogit-bin/git"; chmod +x "$TMP/nogit-bin/git"; printf 'echo hello\n' > "$plain/sut.sh"
expect_rc "placement (no git): OUT beside the SUT is refused (rc 8, says live tree)" 8 "live tree" \
  env PATH="$TMP/nogit-bin:$PATH" "$BASH" -c ". '$LIB'; mutant_sed '$plain/sut.sh' '$plain/x.MUTANT.sh' 's/hello/x/'"
# 8c — OUT outside MUTANT_TMPROOT is refused with its own message (second, independent condition).
mkdir -p "$TMP/root-c" "$TMP/elsewhere"
expect_rc "placement: OUT outside MUTANT_TMPROOT is refused (rc 8, says temp root)" 8 "temp root" \
  env MUTANT_TMPROOT="$TMP/root-c" "$BASH" -c ". '$LIB'; mutant_sed '$ORIG' '$TMP/elsewhere/x.sh' 's/hello/x/'"
# 8d — the kit itself under the temp root (the case that broke the first version): with
#      MUTANT_TMPROOT holding a fake repo, a legitimate sibling OUT is accepted and an OUT inside the
#      repo is still refused as live tree.
if command -v git >/dev/null 2>&1; then
  mkdir -p "$TMP/root-d/out"; git init -q "$TMP/root-d/repo" 2>/dev/null
  printf '#!/usr/bin/env bash\necho hello\n' > "$TMP/root-d/repo/sut.sh"
  MUTANT_TMPROOT="$TMP/root-d" mutant_sed "$TMP/root-d/repo/sut.sh" "$TMP/root-d/out/ok.sh" 's/hello/x/' 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then ok "placement: kit under the temp root — sibling OUT dir is accepted"
  else no "placement: kit under the temp root — sibling OUT was refused (rc=$rc)"; fi
  expect_rc "placement: kit under the temp root — OUT inside the repo is refused (rc 8, live tree)" 8 "live tree" \
    env MUTANT_TMPROOT="$TMP/root-d" "$BASH" -c ". '$LIB'; mutant_sed '$TMP/root-d/repo/sut.sh' '$TMP/root-d/repo/y.sh' 's/hello/x/'"
fi
# 8e — a symlink at OUT would be written THROUGH to its target (not just a link back to ORIG,
#      which -ef catches): refused with its own code, target untouched, dangling links too.
mkdir -p "$TMP/linkdir"; printf 'VICTIM\n' > "$TMP/victim.txt"
ln -s "$TMP/victim.txt" "$TMP/linkdir/out.sh"
expect_rc "placement: OUT that is a symlink to another file is refused (rc 9, says symlink)" 9 "symlink" \
  mutant_sed "$ORIG" "$TMP/linkdir/out.sh" 's/hello/x/'
if [ "$(cat "$TMP/victim.txt")" = "VICTIM" ]; then ok "placement: symlink target was not written through"
else no "placement: symlink target was overwritten"; fi
ln -s "$TMP/never-created.txt" "$TMP/linkdir/dangling.sh"
expect_rc "placement: OUT that is a dangling symlink is refused (rc 9)" 9 "symlink" \
  mutant_sed "$ORIG" "$TMP/linkdir/dangling.sh" 's/hello/x/'
if [ ! -e "$TMP/never-created.txt" ]; then ok "placement: dangling symlink target was not created"
else no "placement: dangling symlink target was created"; fi

# 8f — TMPDIR inside a git repo (e.g. <repo>/.tmp, git-ignored): a legitimate temp OUT lies under
#      the repo's top level. A git-IGNORED OUT is accepted (it can neither be committed nor is it
#      the tracked tree); an un-ignored path in the same repo is still refused.
if command -v git >/dev/null 2>&1; then
  rep="$TMP/repo-f"; mkdir -p "$rep/.tmp/out" "$rep/other" && git init -q "$rep" 2>/dev/null
  printf '.tmp/\n' > "$rep/.gitignore"
  printf '#!/usr/bin/env bash\necho hello\n' > "$rep/sut.sh"; git -C "$rep" add sut.sh .gitignore 2>/dev/null
  MUTANT_TMPROOT="$rep/.tmp" mutant_sed "$rep/sut.sh" "$rep/.tmp/out/ok.sh" 's/hello/x/' 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then ok "placement: TMPDIR inside a repo — git-ignored OUT is accepted"
  else no "placement: TMPDIR inside a repo — git-ignored OUT was refused (rc=$rc)"; fi
  expect_rc "placement: TMPDIR inside a repo — un-ignored OUT in the same repo is still refused (rc 8, live tree)" 8 "live tree" \
    env MUTANT_TMPROOT="$rep" "$BASH" -c ". '$LIB'; mutant_sed '$rep/sut.sh' '$rep/other/y.sh' 's/hello/x/'"
fi

# 8g — inherited GIT_DIR / GIT_WORK_TREE must not redirect the live-tree lookup to another repo
#      (with GIT_DIR pointing elsewhere the old lookup resolved the wrong "live tree" and wrote into
#      the real one, rc 0).
if command -v git >/dev/null 2>&1; then
  git init -q "$TMP/decoy-repo" 2>/dev/null
  expect_rc "placement: inherited GIT_DIR/GIT_WORK_TREE are ignored (rc 8, live tree)" 8 "live tree" \
    env GIT_DIR="$TMP/decoy-repo/.git" GIT_WORK_TREE="$TMP/decoy-repo" MUTANT_TMPROOT="$TMP/root-d" \
    "$BASH" -c ". '$LIB'; mutant_sed '$TMP/root-d/repo/sut.sh' '$TMP/root-d/repo/z.sh' 's/hello/x/'"
fi

# 8h — OUT whose parent directory does not exist: refused, but NOT mislabelled as "live tree".
nd_err="$(mutant_sed "$ORIG" "$TMP/no-such-dir/x.sh" 's/hello/x/' 2>&1 >/dev/null)"; nd_rc=$?
if [ "$nd_rc" -eq 8 ] && [[ "$nd_err" == *"does not exist"* ]] && [[ "$nd_err" != *"live tree"* ]]; then
  ok "placement: OUT in a missing directory is refused as missing (rc 8), not as live tree"
else no "placement: OUT in a missing directory (rc=$nd_rc; stderr=[$nd_err])"; fi

# 9 — mutant_verify on an externally built mutant (non-sed construction).
ext="$TMP/ext.sh"; cp "$ORIG" "$ext"
expect_rc "verify: externally built identical copy is refused (rc 4)" 4 "identical" \
  mutant_verify "$ORIG" "$ext"
printf '#!/usr/bin/env bash\necho changed\n' > "$ext"
mutant_verify "$ORIG" "$ext" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "verify: externally built differing mutant is accepted"
else no "verify: rc=$rc"; fi

# 9b — mutant_verify enforces placement too (an externally built mutant dropped in the live tree).
if command -v git >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\necho changed\n' > "$live/EXT.MUTANT.sh"
  expect_rc "verify: externally built mutant inside the live tree is refused (rc 8, says live tree)" 8 "live tree" \
    mutant_verify "$live/sut.sh" "$live/EXT.MUTANT.sh"
  rm -f "$live/EXT.MUTANT.sh"
fi
ln -s "$TMP/victim.txt" "$TMP/linkdir/ext-link.sh"
expect_rc "verify: OUT that is a symlink is refused (rc 9)" 9 "symlink" \
  mutant_verify "$ORIG" "$TMP/linkdir/ext-link.sh"

# 10 — list edges: the anchor on the FIRST line, LAST line (no trailing newline) and a
# single-line original all register as applied mutations.
printf 'first\nmiddle\nlast' > "$TMP/src/edge.sh"
for pair in 's/^first$/FIRST/' 's/^last$/LAST/' 's/^middle$/MIDDLE/'; do
  MUTANT_SYNTAX=none mutant_sed "$TMP/src/edge.sh" "$TMP/edge.out" "$pair" 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then ok "edge: $pair applies"; else no "edge: $pair refused (rc=$rc)"; fi
done
printf 'solo\n' > "$TMP/src/solo.sh"
MUTANT_SYNTAX=none mutant_sed "$TMP/src/solo.sh" "$TMP/solo.out" 's/solo/duo/' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "edge: single-line original mutates"
else no "edge: single-line original refused (rc=$rc)"; fi

# --- teeth: mutate the HELPER (built with the helper) and require the specific case to go red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  SELFTEST="$HERE/mutant.test.sh"
  # teeth_case <name> <sed-script> <expected FAIL substring>
  teeth_case(){
    local name="$1" script="$2" needle="$3" m="$TMP/helper-$1.sh" res
    if ! mutant_sed "$LIB" "$m" "$script" 2>"$TMP/helper-$name.err"; then
      no "teeth $name: could not build a valid helper mutant ($(cat "$TMP/helper-$name.err"))"; return
    fi
    res="$(MUTANT_LIB="$m" bash "$SELFTEST" 2>&1)"
    if grep -qF "  FAIL  $needle" <<<"$res"; then
      ok "teeth $name: mutated helper turns the named case red"
    else no "teeth $name: mutated helper did NOT fail case [$needle] — check is THEATER"; fi
  }
  echo "-- teeth: helper mutants (each must fail the specific case, not just any case) --"
  teeth_case identical '/SENTINEL-IDENTICAL-CHECK/,+3s/return 4/:/' \
    "no-match: byte-identical mutant is refused"
  teeth_case empty '/SENTINEL-EMPTY-CHECK/,+3s/return 3/:/' \
    "empty: a mutant that deletes everything is refused"
  teeth_case syntax '/SENTINEL-SYNTAX-CHECK/,+6s/return 5/:/' \
    "syntax: mutant that is not valid bash is refused"
  teeth_case livetree '/SENTINEL-LIVE-TREE-CHECK/,+5s/_mutant_under "\$real_out" "\$live"/false/' \
    "placement: OUT at live-repo/LIVE.MUTANT.sh is refused"
  teeth_case ignoreexempt '/SENTINEL-LIVE-TREE-CHECK/,+5s/&& ! _mutant_git "\$live" check-ignore -q -- "\$real_out\/\$(basename -- "\$out")" 2>\/dev\/null;/\&\& true;/' \
    "placement: TMPDIR inside a repo — git-ignored OUT was refused"
  teeth_case ignoreall '/SENTINEL-LIVE-TREE-CHECK/,+5s/&& ! _mutant_git "\$live" check-ignore -q -- "\$real_out\/\$(basename -- "\$out")" 2>\/dev\/null;/\&\& false;/' \
    "placement: TMPDIR inside a repo — un-ignored OUT in the same repo is still refused"
  teeth_case gitenv 's/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git/git/' \
    "placement: inherited GIT_DIR/GIT_WORK_TREE are ignored"
  teeth_case tmproot '/SENTINEL-TMPROOT-CHECK/,+1s/! _mutant_under "\$real_out" "\$real_root"/false/' \
    "placement: OUT outside MUTANT_TMPROOT is refused"
  teeth_case symlink '/SENTINEL-SYMLINK-CHECK/,+3s/return 9/:/' \
    "placement: OUT that is a symlink to another file is refused"
  teeth_case sedorig '/SENTINEL-SED-ORIG-CHECK/,+3s/return 2/:/' \
    "absent original: refused (rc 2, says not a readable file)"
  teeth_case verifyorig '/SENTINEL-VERIFY-ORIG-CHECK/,+3s/return 2/:/' \
    "verify: absent original is refused (rc 2, says not a readable file)"
  teeth_case notproduced '/SENTINEL-NOT-PRODUCED-CHECK/,+3s/return 2/:/' \
    "verify: mutant that was never produced is refused (rc 2, says was not produced)"
  teeth_case sedfail '/SENTINEL-SED-FAIL-CHECK/,+3s/return 6/:/' \
    "sed failure: refused (rc 6, says sed failed)"
  teeth_case selfoverwrite '/SENTINEL-SELF-CHECK/,+3s/return 7/:/' \
    "self-overwrite: OUT equal to the original path is refused"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
