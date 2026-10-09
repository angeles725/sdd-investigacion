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
# An exported debug flag must not leak into any case (T15 sets it explicitly where it is under test).
unset MUTANT_TOOTH_DEBUG
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

# --- mutant_chain / mutant_tooth / mutant_built (kit issue #1299): the shared per-stage mutant builder,
# the exact-verdict tooth runner and the external-mutant checker that replace the per-suite mk_sed /
# mk_verify / tooth copies. Each PRINTS its own `  FAIL  ` line (mutant_tooth also its `  PASS  ` line)
# in the suite format and returns non-zero on failure, so the caller counts: nothing here touches the
# caller's pass/fail counters. mutant_chain returns 10 for a dead stage, else mutant_sed/verify's rc.
printf '#!/usr/bin/env bash\nA=1\nB=2\nC=3\n' > "$TMP/src/chain.sh"
CH="$TMP/src/chain.sh"

# C1 — every stage applies: rc 0, silent, mutant carries BOTH edits.
out="$TMP/c1.sh"; msg="$(mutant_chain c1 "$CH" "$out" 's/A=1/A=9/' 's/B=2/B=8/' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$msg" ] && grep -q 'A=9' "$out" && grep -q 'B=8' "$out"; then
  ok "chain: two live stages build one mutant, silently (rc 0)"
else no "chain: two live stages (rc=$rc msg=[$msg])"; fi

# C2 — a LAST stage that matches nothing is a defect even though the first stage changes the bytes.
out="$TMP/c2.sh"; msg="$(mutant_chain c2 "$CH" "$out" 's/A=1/A=9/' 's/NO_SUCH/x/' 2>&1)"; rc=$?
if [ "$rc" -eq 10 ] && [[ "$msg" == *"  FAIL  c2"* ]] && [[ "$msg" == *"stage 2"* ]] && [[ "$msg" == *"NO_SUCH"* ]] && [ ! -e "$out" ]; then
  ok "chain: dead last stage fails, names the stage, builds nothing"
else no "chain: dead last stage (rc=$rc msg=[$msg])"; fi

# C3 — a dead FIRST stage is caught too (list edge: first position).
out="$TMP/c3.sh"; msg="$(mutant_chain c3 "$CH" "$out" 's/NO_SUCH/x/' 's/B=2/B=8/' 2>&1)"; rc=$?
if [ "$rc" -eq 10 ] && [[ "$msg" == *"stage 1"* ]] && [[ "$msg" == *"NO_SUCH"* ]]; then ok "chain: dead first stage fails (rc 10, names stage 1)"
else no "chain: dead first stage (rc=$rc msg=[$msg])"; fi

# C4 — a single dead stage (single-element list).
out="$TMP/c4.sh"; msg="$(mutant_chain c4 "$CH" "$out" 's/NO_SUCH/x/' 2>&1)"; rc=$?
if [ "$rc" -eq 10 ] && [[ "$msg" == *"stage 1"* ]] && [[ "$msg" == *"NO_SUCH"* ]]; then ok "chain: single dead stage fails (rc 10)"
else no "chain: single dead stage (rc=$rc msg=[$msg])"; fi

# C5 — a chain whose stages all apply but break bash is refused with the helper's rc named.
out="$TMP/c5.sh"; msg="$(mutant_chain c5 "$ORIG" "$out" '/^fi$/d' 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && [[ "$msg" == *"  FAIL  c5"* ]] && [[ "$msg" == *"rc=5"* ]]; then
  ok "chain: syntax-broken mutant is refused and the rc is named"
else no "chain: syntax-broken (rc=$rc msg=[$msg])"; fi

# C6 — MUTANT_SYNTAX=none is honoured through the chain (non-bash targets).
printf 'x: 1\ny: 2\n' > "$TMP/src/data.yml"
out="$TMP/c6.yml"; msg="$(MUTANT_SYNTAX=none mutant_chain c6 "$TMP/src/data.yml" "$out" 's/x: 1/x: 2/' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'x: 2' "$out"; then ok "chain: MUTANT_SYNTAX=none builds a non-bash mutant"
else no "chain: MUTANT_SYNTAX=none (rc=$rc msg=[$msg])"; fi

# C7 — a chain with no stage at all is a FAIL (rc 1), not a vacuous identical-copy refusal.
msg="$(mutant_chain c7 "$CH" "$TMP/c7.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == *"no sed stage"* ]]; then ok "chain: zero stages fails (rc 1)"
else no "chain: zero stages (rc=$rc msg=[$msg])"; fi

# --- mutant_tooth LABEL GOOD_RC BAD_RC MUTANT [opts] -- ARGV...
printf '#!/usr/bin/env bash\nif [ "${1:-}" = fail ]; then echo "found BADTHING"; exit 1; fi\necho "all clear"; exit 0\n' > "$TMP/src/sut.sh"
SUT1="$TMP/src/sut.sh"
# shellcheck disable=SC2034  # SUT is read by the sourced mutant_tooth (default original without --orig)
SUT="$SUT1"
mutant_sed "$SUT1" "$TMP/mut-inv.sh" 's/exit 0/exit 1/' 2>/dev/null          # good rc 0  → bad rc 1
mutant_sed "$SUT1" "$TMP/mut-crash.sh" 's/echo "all clear"; exit 0/exit 2/' 2>/dev/null   # crashes with rc 2
mutant_sed "$SUT1" "$TMP/mut-same.sh" 's/all clear/all quiet/' 2>/dev/null   # rc stays 0

# T1 — exact GOOD rc on the original and exact BAD rc on the mutant → PASS line, rc 0.
msg="$(mutant_tooth t1 0 1 "$TMP/mut-inv.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$msg" == "  PASS  t1"* ]]; then ok "tooth: exact good/bad rc passes with a PASS line"
else no "tooth: exact rc (rc=$rc msg=[$msg])"; fi

# T2 — a mutant that merely CRASHES (rc 2) when BAD_RC is 1 is theater, not teeth.
msg="$(mutant_tooth t2 0 1 "$TMP/mut-crash.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t2"* ]] && [[ "$msg" == *"THEATER"* ]] && [[ "$msg" == *"mutant rc=2 (want 1)"* ]]; then
  ok "tooth: crashing mutant (rc 2) is THEATER, names the rc"
else no "tooth: crash (rc=$rc msg=[$msg])"; fi

# T3 — a wrong GOOD rc on the original fails even when the mutant matches.
msg="$(mutant_tooth t3 1 1 "$TMP/mut-inv.sh" --bad-has 'all clear' -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == *"original rc=0 (want 1)"* ]]; then ok "tooth: wrong original rc fails and says so"
else no "tooth: original rc (rc=$rc msg=[$msg])"; fi

# T4 — a mutant that does not change the verdict is theater.
msg="$(mutant_tooth t4 0 1 "$TMP/mut-same.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == *"mutant rc=0 (want 1)"* ]]; then ok "tooth: verdict-preserving mutant fails"
else no "tooth: unchanged verdict (rc=$rc msg=[$msg])"; fi

# T5 — output predicates: each of the four passes when true and fails when false.
tp(){ # tp <label> <want-rc> <mutant> <opts...>
  local label="$1" want="$2" mut="$3"; shift 3
  local m r; m="$(mutant_tooth "$label" 0 0 "$mut" "$@" -- bash @SUT@ 2>&1)"; r=$?
  if [ "$r" -eq "$want" ]; then ok "tooth opt: $label"; else no "tooth opt: $label (rc=$r want=$want msg=[$m])"; fi
}
tp good-has-true  0 "$TMP/mut-same.sh" --good-has 'all clear' --bad-has 'all quiet'
tp good-has-false 1 "$TMP/mut-same.sh" --good-has 'NEVERSEEN' --bad-has 'all quiet'
tp good-lacks-true  0 "$TMP/mut-same.sh" --good-lacks 'BADTHING' --bad-has 'all quiet'
tp good-lacks-false 1 "$TMP/mut-same.sh" --good-lacks 'all clear' --bad-has 'all quiet'
tp bad-has-true  0 "$TMP/mut-same.sh" --bad-has 'all quiet'
tp bad-has-false 1 "$TMP/mut-same.sh" --bad-has 'all clear'
tp bad-lacks-true  0 "$TMP/mut-same.sh" --bad-lacks 'all clear'
tp bad-lacks-false 1 "$TMP/mut-same.sh" --bad-lacks 'all quiet'

# T6 — @SUT@ is replaced inside an argv word, ARGV carries extra args, and --orig overrides the original.
msg="$(mutant_tooth t6 1 1 "$TMP/mut-same.sh" --orig "$SUT1" --good-has BADTHING --bad-has BADTHING -- bash @SUT@ fail 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "tooth: ARGV extra args reach both runs"; else no "tooth: argv (rc=$rc msg=[$msg])"; fi
printf '#!/usr/bin/env bash\necho "$0"\n' > "$TMP/src/echo0.sh"
mutant_sed "$TMP/src/echo0.sh" "$TMP/mut-echo0.sh" 's/echo/echo -n/' 2>/dev/null
msg="$(mutant_tooth t6b 0 0 "$TMP/mut-echo0.sh" --orig "$TMP/src/echo0.sh" --good-has 'src/echo0.sh' --bad-has 'mut-echo0.sh' -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "tooth: @SUT@ is the original for the good run and the mutant for the bad run"
else no "tooth: @SUT@ substitution (rc=$rc msg=[$msg])"; fi

# T7 — misuse is a FAIL, never a silent pass: unknown option, and a missing '--'.
msg="$(mutant_tooth t7 0 1 "$TMP/mut-inv.sh" --bogus x -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t7"* ]] && [[ "$msg" == *"bogus"* ]]; then ok "tooth: unknown option fails"
else no "tooth: unknown option (rc=$rc msg=[$msg])"; fi
msg="$(mutant_tooth t7b 0 1 "$TMP/mut-inv.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t7b"* ]] && [[ "$msg" == *'missing the "--"'* ]] && [ "$(wc -l <<<"$msg")" -eq 1 ]; then ok "tooth: missing '--' fails and says so"
else no "tooth: missing -- (rc=$rc msg=[$msg])"; fi
msg="$(mutant_tooth t7c 0 1 "$TMP/mut-inv.sh" -- 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t7c"* ]] && [[ "$msg" == *"no ARGV"* ]] && [[ "$msg" != *THEATER* ]]; then
  ok "tooth: empty ARGV after '--' fails and says so"
else no "tooth: empty ARGV (rc=$rc msg=[$msg])"; fi

# T8 — an absent mutant file (builder failed and the caller ignored it) is a FAIL, not teeth.
msg="$(mutant_tooth t8 0 1 "$TMP/does-not-exist.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t8"* ]] && [[ "$msg" == *"mutant file absent"* ]] && [[ "$msg" != *THEATER* ]]; then ok "tooth: absent mutant file fails"
else no "tooth: absent mutant (rc=$rc msg=[$msg])"; fi

# T9 — neither --orig nor $SUT: the original is unknown, which is a FAIL (never a pass on nothing).
msg="$(unset SUT; mutant_tooth t9 0 1 "$TMP/mut-inv.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t9"* ]] && [[ "$msg" == *"no original"* ]] && [[ "$msg" != *THEATER* ]]; then ok "tooth: no --orig and no \$SUT fails"
else no "tooth: no original (rc=$rc msg=[$msg])"; fi

# T10 — MUTANT_TOOTH_ICASE makes every pattern case-insensitive; the default is case-sensitive.
tp icase-default 1 "$TMP/mut-same.sh" --good-has 'ALL CLEAR'
msg="$(MUTANT_TOOTH_ICASE=1 mutant_tooth t10 0 0 "$TMP/mut-same.sh" --good-has 'ALL CLEAR' --bad-has 'ALL QUIET' -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "tooth: MUTANT_TOOTH_ICASE=1 makes --good-has/--bad-has case-insensitive"
else no "tooth: icase has (rc=$rc msg=[$msg])"; fi
msg="$(MUTANT_TOOTH_ICASE=1 mutant_tooth t10b 0 0 "$TMP/mut-same.sh" --bad-lacks 'ALL QUIET' -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == *"mutant output still matches"* ]]; then
  ok "tooth: MUTANT_TOOTH_ICASE=1 makes --bad-lacks case-insensitive"
else no "tooth: icase lacks (rc=$rc msg=[$msg])"; fi

# T11 — mutant_built: silent rc 0 for a real mutant; a refused one prints a FAIL naming the rc.
msg="$(mutant_built b1 "$ORIG" "$ext" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$msg" ]; then ok "built: externally built differing mutant is accepted silently"
else no "built: accepted (rc=$rc msg=[$msg])"; fi
cp "$ORIG" "$TMP/b2.sh"
msg="$(mutant_built b2 "$ORIG" "$TMP/b2.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 4 ] && [[ "$msg" == "  FAIL  b2"* ]] && [[ "$msg" == *"rc=4"* ]]; then ok "built: identical copy fails with the helper's rc named"
else no "built: identical (rc=$rc msg=[$msg])"; fi

# T12 — GOOD_RC == BAD_RC with no bad-side pattern cannot discriminate: refused loudly (rc 1, says so,
# not a PASS line), even when only good-side patterns are supplied; a bad-side pattern lifts the refusal.
msg="$(mutant_tooth t12 0 0 "$TMP/mut-same.sh" -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == "  FAIL  t12"* ]] && [[ "$msg" == *"cannot discriminate"* ]] && [[ "$msg" != *PASS* ]]; then
  ok "tooth: equal rcs with no pattern are refused (non-discriminating)"
else no "tooth: non-discriminating (rc=$rc msg=[$msg])"; fi
msg="$(mutant_tooth t12b 0 0 "$TMP/mut-same.sh" --good-has 'all clear' --good-lacks NOPE -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [[ "$msg" == *"cannot discriminate"* ]]; then ok "tooth: good-side patterns alone do not lift the refusal"
else no "tooth: good-only patterns (rc=$rc msg=[$msg])"; fi
msg="$(mutant_tooth t12c 0 0 "$TMP/mut-same.sh" --bad-lacks 'all clear' -- bash @SUT@ 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$msg" == "  PASS  t12c"* ]]; then ok "tooth: equal rcs with --bad-lacks discriminate and pass"
else no "tooth: bad-lacks lifts refusal (rc=$rc msg=[$msg])"; fi

# T13 — rc 6 contract beyond the code: a sed that fails leaves NO mutant file behind (a caller that
# ignores the rc must find nothing to run), even when OUT pre-existed with stale bytes.
out="$TMP/m13.sh"; printf 'stale\n' > "$out"
mutant_sed "$ORIG" "$out" 's/a' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 6 ] && [ ! -e "$out" ]; then ok "sed failure (rc 6): the stale/partial mutant file is removed"
else no "sed failure (rc 6): the stale/partial mutant file is removed (rc=$rc exists=$([ -e "$out" ] && echo y || echo n))"; fi

# T14 — rc 2 for an UNREADABLE original (exists, non-empty, but not readable) — distinct from absent.
# Skipped as root, where chmod 000 does not make a file unreadable.
unr="$TMP/src/unreadable.sh"; printf 'echo hi\n' > "$unr"; chmod 000 "$unr"
UNR_TESTABLE=0; [ ! -r "$unr" ] && UNR_TESTABLE=1
if [ "$UNR_TESTABLE" -eq 1 ]; then
  expect_rc "unreadable original: mutant_sed refuses (rc 2, says not a readable file)" 2 "not a readable file" \
    mutant_sed "$unr" "$TMP/m14.sh" 's/hi/x/'
  expect_rc "unreadable original: mutant_verify refuses (rc 2, says not a readable file)" 2 "not a readable file" \
    mutant_verify "$unr" "$ext"
else ok "unreadable original: SKIP — running as a user for whom chmod 000 is still readable"; fi
chmod 600 "$unr"

# T15 — MUTANT_TOOTH_DEBUG (opt-in): unset => stderr is empty and stdout unchanged; set => detail on
# STDERR only (stdout stays byte-identical, so a caller capturing stdout is unaffected).
# Explicitly clear the flag so an exported MUTANT_TOOTH_DEBUG (the obvious way to debug a tooth) cannot leak in.
dbg_off_out="$(MUTANT_TOOTH_DEBUG='' mutant_tooth d1 0 1 "$TMP/mut-inv.sh" -- bash @SUT@ 2>"$TMP/d1.err")"; rc=$?
dbg_on_out="$(MUTANT_TOOTH_DEBUG=1 mutant_tooth d1 0 1 "$TMP/mut-inv.sh" -- bash @SUT@ 2>"$TMP/d1on.err")"
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/d1.err" ]; then ok "tooth debug: unset prints nothing on stderr"
else no "tooth debug: unset prints nothing on stderr (rc=$rc err=[$(cat "$TMP/d1.err")])"; fi
if [ "$dbg_off_out" = "$dbg_on_out" ] && [ -n "$dbg_on_out" ]; then ok "tooth debug: stdout is byte-identical with the flag set"
else no "tooth debug: stdout is byte-identical with the flag set (off=[$dbg_off_out] on=[$dbg_on_out])"; fi
if grep -q 'MUTANT_TOOTH_DEBUG' "$TMP/d1on.err" && grep -q 'original rc=0' "$TMP/d1on.err" \
   && grep -q 'mutant rc=1' "$TMP/d1on.err" && grep -q 'all clear' "$TMP/d1on.err" && grep -q 'mut-inv.sh' "$TMP/d1on.err"; then
  ok "tooth debug: set prints mutant path, both rcs and run output to stderr"
else no "tooth debug: set prints mutant path, both rcs and run output to stderr (err=[$(cat "$TMP/d1on.err")])"; fi

# T16 — mutant_cleanup_register (#1576): ONE registry cleaned by a single EXIT trap that is installed
# once and CHAINS whatever EXIT trap was already there, so a suite never re-installs (and so never
# replaces) a trap. Each case runs in a child bash because the contract IS the child's exit behaviour.
cat > "$TMP/child-cleanup.sh" <<'CHILD'
set -u
case "$CH_MODE" in
  chain)  trap 'echo pre >> "$CH_MARK"' EXIT
          . "$CH_LIB"
          mutant_cleanup_register "$CH_D1"; mutant_cleanup_register "$CH_D2"; mutant_cleanup_register "$CH_D1"
          trap -p EXIT > "$CH_TRAP"
          exit 7 ;;
  plain)  . "$CH_LIB"; mutant_cleanup_register "$CH_D1"; exit 0 ;;
  heal)   trap 'echo pre >> "$CH_MARK"' EXIT
          . "$CH_LIB"
          mutant_cleanup_register "$CH_D1"
          trap 'echo other >> "$CH_MARK"' EXIT   # a suite that re-installs its own trap
          mutant_cleanup_register "$CH_D2"
          exit 0 ;;
  status) trap 'rc=$?; echo "saw=$rc" >> "$CH_MARK"; exit $rc' EXIT
          . "$CH_LIB"
          mutant_cleanup_register "$CH_D1"
          exit 3 ;;
  refuse) . "$CH_LIB"
          mutant_cleanup_register '' 2> "$CH_ERR1"; echo "empty=$?" >> "$CH_RC"
          mutant_cleanup_register "rel-dir" 2> "$CH_ERR2"; echo "rel=$?" >> "$CH_RC"
          exit 0 ;;
  slash)  rm() { printf '%s\n' "$*" >> "$CH_RMLOG"; }   # never let a regression delete a real path
          . "$CH_LIB"
          mutant_cleanup_register / 2> /dev/null; echo "slash=$?" >> "$CH_RC"
          exit 0 ;;
esac
CHILD
cc_run(){ env CH_LIB="$LIB" CH_MODE="$1" CH_D1="$TMP/cc d1" CH_D2="$TMP/cc-d2" CH_MARK="$TMP/cc.mark" \
  CH_TRAP="$TMP/cc.trap" CH_RC="$TMP/cc.rc" CH_ERR1="$TMP/cc.err1" CH_ERR2="$TMP/cc.err2" CH_RMLOG="$TMP/cc.rmlog" \
  bash "$TMP/child-cleanup.sh"; }
cc_reset(){ rm -rf "$TMP/cc d1" "$TMP/cc-d2"; mkdir -p "$TMP/cc d1/sub" "$TMP/cc-d2"; : > "$TMP/cc.mark"; : > "$TMP/cc.rc"; }

cc_reset; cc_run chain; rc=$?
if [ "$rc" -eq 7 ] && [ ! -e "$TMP/cc d1" ] && [ ! -e "$TMP/cc-d2" ]; then ok "cleanup: registered paths (space in a name, a duplicate) are removed at exit and the exit status survives"
else no "cleanup: registered paths removed at exit (rc=$rc d1=$([ -e "$TMP/cc d1" ] && echo kept || echo gone) d2=$([ -e "$TMP/cc-d2" ] && echo kept || echo gone))"; fi
if grep -qx pre "$TMP/cc.mark"; then ok "cleanup: a pre-existing EXIT trap is chained, not replaced"
else no "cleanup: a pre-existing EXIT trap is chained (marker=[$(cat "$TMP/cc.mark")])"; fi
n="$(grep -o '_mutant_cleanup_run' "$TMP/cc.trap" | wc -l)"
if [ "$n" -eq 1 ]; then ok "cleanup: three registrations install the trap exactly once"
else no "cleanup: trap installed once (runner appears $n times in [$(cat "$TMP/cc.trap")])"; fi
cc_reset; cc_run plain; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/cc d1" ]; then ok "cleanup: works with no pre-existing EXIT trap"
else no "cleanup: no pre-existing trap (rc=$rc)"; fi
cc_reset; cc_run heal; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/cc d1" ] && [ ! -e "$TMP/cc-d2" ] && grep -qx other "$TMP/cc.mark"; then
  ok "cleanup: a trap re-installed by the suite is re-chained on the next registration (nothing leaks)"
else no "cleanup: re-chain after the suite replaced the trap (rc=$rc d1=$([ -e "$TMP/cc d1" ] && echo kept || echo gone) marker=[$(cat "$TMP/cc.mark")])"; fi
cc_reset; cc_run status; rc=$?
if [ "$rc" -eq 3 ] && grep -qx 'saw=3' "$TMP/cc.mark" && [ ! -e "$TMP/cc d1" ]; then
  ok "cleanup: a chained trap that reads \$? sees the real exit status and the script still exits with it"
else no "cleanup: exit status seen by a chained trap (rc=$rc marker=[$(cat "$TMP/cc.mark")] d1=$([ -e "$TMP/cc d1" ] && echo kept || echo gone))"; fi
mkdir -p "$TMP/cwd/rel-dir"; : > "$TMP/cc.rc"
(cd "$TMP/cwd" && cc_run refuse)
if grep -qx 'empty=2' "$TMP/cc.rc" && grep -qx 'rel=2' "$TMP/cc.rc" && grep -q 'REFUSED' "$TMP/cc.err1" && grep -q 'REFUSED' "$TMP/cc.err2"; then
  ok "cleanup: empty and relative paths are refused (rc 2, says REFUSED)"
else no "cleanup: empty/relative refusal (rc=[$(tr '\n' ' ' < "$TMP/cc.rc")] e1=[$(cat "$TMP/cc.err1")] e2=[$(cat "$TMP/cc.err2")])"; fi
if [ -d "$TMP/cwd/rel-dir" ]; then ok "cleanup: a refused relative path is never registered, so it is never deleted"
else no "cleanup: a refused relative path was registered and deleted at exit"; fi
: > "$TMP/cc.rc"; : > "$TMP/cc.rmlog"
cc_run slash
if grep -qx 'slash=2' "$TMP/cc.rc" && ! grep -qx -- '-rf -- /' "$TMP/cc.rmlog"; then ok "cleanup: / is refused and never handed to rm"
else no "cleanup: / refusal (rc=[$(cat "$TMP/cc.rc")] rm-log=[$(cat "$TMP/cc.rmlog")])"; fi

# T17 — mutant_py_replace (#1576): the shared Python-mutant builder. rc 2 = setup failure (original or
# anchor absent, empty anchor), rc 3 = refused (helper refusal, identical, not valid Python); the
# refused mutant file is gone and the reason is on stderr.
PYORIG="$TMP/src/orig.py"
printf 'def f():\n    return 1\n\ndef g():\n    return 1\n' > "$PYORIG"
out="$TMP/pm1.py"
mutant_py_replace pm1 "$PYORIG" 'return 1' 'return 2' "$out" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'return 2' "$out")" -eq 1 ] && [ "$(grep -c 'return 1' "$out")" -eq 1 ] && [ "$(grep -c 'return 1' "$PYORIG")" -eq 2 ]; then
  ok "py_replace: only the FIRST anchor is replaced, the original is untouched, rc 0"
else no "py_replace: first-anchor replacement (rc=$rc)"; fi
out="$TMP/pm2.py"
expect_rc "py_replace: absent anchor is rc 2 (says anchor not found)" 2 "anchor not found" \
  mutant_py_replace pm2 "$PYORIG" 'NO_SUCH_ANCHOR' 'x' "$out"
if [ ! -e "$out" ]; then ok "py_replace: an absent anchor leaves no mutant behind"; else no "py_replace: absent anchor left a mutant"; fi
expect_rc "py_replace: empty anchor is rc 2 (says empty anchor)" 2 "empty anchor" \
  mutant_py_replace pm2b "$PYORIG" '' 'x' "$TMP/pm2b.py"
expect_rc "py_replace: absent original is rc 2 (says not a readable file)" 2 "not a readable file" \
  mutant_py_replace pm2c "$TMP/does-not-exist.py" 'a' 'b' "$TMP/pm2c.py"
out="$TMP/pm3.py"
expect_rc "py_replace: a mutant that is not valid Python is rc 3 (says not valid Python)" 3 "not valid Python" \
  mutant_py_replace pm3 "$PYORIG" '    return 1' '  return (' "$out"
if [ ! -e "$out" ]; then ok "py_replace: an invalid-Python mutant is removed"; else no "py_replace: invalid-Python mutant still exists"; fi
out="$TMP/pm4.py"
# The original has NO trailing newline, so the rewritten mutant would differ from it by that newline
# alone: only the explicit OLD == NEW check can see that the mutation is a no-op.
printf 'a = 1' > "$TMP/src/nonl.py"
expect_rc "py_replace: OLD == NEW is rc 3 (says OLD and NEW are identical)" 3 "OLD and NEW are identical" \
  mutant_py_replace pm4 "$TMP/src/nonl.py" 'a = 1' 'a = 1' "$out"
ln -sf "$TMP/pm5-target.py" "$TMP/pm5.py"
expect_rc "py_replace: a symlink OUT is rc 3 (helper refusal)" 3 "symlink" \
  mutant_py_replace pm5 "$PYORIG" 'return 1' 'return 2' "$TMP/pm5.py"
if [ ! -e "$TMP/pm5-target.py" ]; then ok "py_replace: no write went through the symlink"; else no "py_replace: wrote through the symlink"; fi
expect_rc "py_replace: OUT equal to ORIG is rc 3 (says same path)" 3 "same path" \
  mutant_py_replace pm6 "$PYORIG" 'return 1' 'return 2' "$PYORIG"
if [ "$(grep -c 'return 1' "$PYORIG")" -eq 2 ]; then ok "py_replace: the original survives an OUT == ORIG request"; else no "py_replace: the original was modified"; fi
# Refusals belong on STDERR: a caller capturing stdout must see nothing.
ln -sf "$TMP/pm8-target.py" "$TMP/pm8.py"
so1="$(mutant_py_replace pm8 "$PYORIG" 'return 1' 'return 2' "$TMP/pm8.py" 2>/dev/null)"
so2="$(mutant_py_replace pm9 "$PYORIG" 'return 1' 'return 2' "$TMP/src/pm9-live.py" 2>/dev/null)"
so3="$(mutant_py_replace pm10 "$PYORIG" 'return 1' 'return 1' "$TMP/pm10.py" 2>/dev/null)"
if [ -z "$so1$so2$so3" ]; then ok "py_replace: symlink, live-tree and identical refusals print nothing on stdout"
else no "py_replace: refusal leaked to stdout (symlink=[$so1] live=[$so2] identical=[$so3])"; fi
printf 'x = 1\ny = """a\nb"""\n' > "$TMP/src/ml.py"
mutant_py_replace pm7 "$TMP/src/ml.py" $'a\nb' $'c\nd\ne' "$TMP/pm7.py" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'e"""' "$TMP/pm7.py"; then ok "py_replace: a multi-line anchor and replacement work"
else no "py_replace: multi-line anchor (rc=$rc)"; fi

# T18 — count-once wrappers (#1576): a failure is counted EXACTLY once, in the caller's variable, by
# the helper, so a call site cannot forget (or double) the `else fail=$((fail+1))` branch.
cnt=0
mutant_chain_or_count cnt co1 "$ORIG" "$TMP/co1.sh" 's/hello/bye/' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$cnt" -eq 0 ]; then ok "count-once: a built mutant is not counted"
else no "count-once: success counted (rc=$rc cnt=$cnt)"; fi
cnt=0
mutant_chain_or_count cnt co2 "$ORIG" "$TMP/co2.sh" 's/NO_SUCH_ANCHOR/x/' > "$TMP/co2.out" 2>&1; rc=$?
if [ "$rc" -eq 10 ] && [ "$cnt" -eq 1 ] && grep -q '^  FAIL  co2' "$TMP/co2.out"; then ok "count-once: a dead stage is counted once, keeps rc 10 and prints the FAIL line"
else no "count-once: dead stage (rc=$rc cnt=$cnt out=[$(cat "$TMP/co2.out")])"; fi
cnt=0
mutant_chain_or_count cnt co3 "$ORIG" "$TMP/co3.sh" 's/hello/hello/' >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$cnt" -eq 1 ]; then ok "count-once: a chain build refused by the helper is counted once"
else no "count-once: refused chain (rc=$rc cnt=$cnt)"; fi
cnt=0
mutant_built_or_count cnt co4 "$ORIG" "$TMP/co4-never-built.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ "$cnt" -eq 1 ]; then ok "count-once: a refused mutant_built (not produced, rc 2) is counted once"
else no "count-once: refused built (rc=$rc cnt=$cnt)"; fi
unset cnt_unset
mutant_or_count cnt_unset false >/dev/null 2>&1
if [ "${cnt_unset:-}" = 1 ]; then ok "count-once: an unset counter starts at 0"; else no "count-once: unset counter (got [${cnt_unset:-}])"; fi
co_in_fn(){ local lc=5; mutant_or_count lc false >/dev/null 2>&1; echo "$lc"; }
lc_got="$(co_in_fn)"
if [ "$lc_got" = 6 ]; then ok "count-once: a function-local counter of the caller is the one incremented"; else no "count-once: local counter (got [$lc_got])"; fi
cnt=3; mutant_or_count 'bad;name' true > "$TMP/co5.out" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'bad counter' "$TMP/co5.out" && [ "$cnt" -eq 3 ]; then ok "count-once: an invalid counter name is refused loudly (rc 2)"
else no "count-once: invalid counter name (rc=$rc out=[$(cat "$TMP/co5.out")])"; fi
# The helper's own locals must not shadow the caller's counter: counters named like plain locals work.
for nm in rc c counter; do
  ( eval "$nm=0"; mutant_or_count "$nm" false >/dev/null 2>&1; mutant_chain_or_count "$nm" w "$ORIG" "$TMP/co7.sh" 's/NO_SUCH_ANCHOR/x/' >/dev/null 2>&1
    echo "got=${!nm}" ) > "$TMP/co7.out" 2>&1
  if grep -qx 'got=2' "$TMP/co7.out"; then ok "count-once: a counter named '$nm' increments the caller's variable (direct and via a wrapper)"
  else no "count-once: counter named $nm shadowed (out=[$(cat "$TMP/co7.out")])"; fi
done
( _moc_rc=0; mutant_or_count _moc_rc false; echo "rc=$?" ) > "$TMP/co8.out" 2>&1
if grep -qx 'rc=2' "$TMP/co8.out" && grep -q 'bad counter' "$TMP/co8.out"; then ok "count-once: a counter in the helper's reserved _moc_ namespace is refused (rc 2)"
else no "count-once: reserved counter name (out=[$(cat "$TMP/co8.out")])"; fi
# In a subshell: a regression that evaluates the value would abort the whole suite under `set -u`.
( cnt='x'; mutant_or_count cnt false; echo "rc=$?" ) > "$TMP/co6.out" 2>&1
if grep -qx 'rc=2' "$TMP/co6.out" && grep -q 'not a number' "$TMP/co6.out"; then ok "count-once: a non-numeric counter value is refused, not evaluated (rc 2)"
else no "count-once: non-numeric counter (out=[$(cat "$TMP/co6.out")])"; fi

# T18 — shared VM-executor tooth kit (#1576): mutant_vm_tooth_py_src (the python `_tooth_run` scenario
# runner) and mutant_vm_core_teeth (stage / staging control / three real-SUT mutants), both parameterised
# by the executor name so detonate-exec and trace-exec stop carrying two copies. The fixture is a tiny fake
# SUT tree whose "scenario runner" reads the mutated vm_boot_core.py, so the verdicts are deterministic.
VM="$TMP/vm"; mkdir -p "$VM/tests" "$VM/lib" "$VM/pystub"
cat > "$VM/lib/vm_boot_core.py" <<'PY'
import uuid
def run_vm():
    run_dir = _dc.make_run_subdir(uuid.uuid4().hex)
    try:
        boot()
    except BaseException:
        shutil.rmtree(run_dir, ignore_errors=True)
        raise
PY
printf 'x = 1\n' > "$VM/lib/fake_exec.py"; printf 'x = 1\n' > "$VM/fake_plan.py"
cat > "$VM/tests/self-good.sh" <<'SH'
#!/usr/bin/env bash
core="$(dirname "$3")/vm_boot_core.py"
case "$2" in
  red11) if grep -q TOOTH_UUID "$core"; then echo TOOTH_RED11=preexisting; else echo TOOTH_RED11=fresh; fi ;;
  inv5)  if grep -q '^        pass$' "$core"; then echo TOOTH_INV5=leaked; else echo TOOTH_INV5=reaped; fi ;;
  alloc) echo "TOOTH_ALLOC=$(grep -c 'make_run_subdir(' "$core")" ;;
esac
SH
# blunt: always the GOOD verdicts, so no mutant ever bites. crash: right verdicts plus a python traceback.
printf '#!/usr/bin/env bash\ncase "$2" in red11) echo TOOTH_RED11=fresh;; inv5) echo TOOTH_INV5=reaped;; alloc) echo TOOTH_ALLOC=1;; esac\n' > "$VM/tests/self-blunt.sh"
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/self-blunt.sh" "$@"; echo "Traceback (most recent call last):"\n' > "$VM/tests/self-crash.sh"
vm_run(){  # vm_run <self-script> <mut-dir> [tree]  -> prints the helper's lines then MVC=<pass>/<fail>
  local t="${3:-$VM}"; mkdir -p "$2"
  ( mutant_vm_core_teeth fake "$t/tests" "$t/tests/$1" "$t/lib/fake_exec.py" "$2"; echo "MVC=$MVC_PASS/$MVC_FAIL" ) 2>&1
}
res="$(vm_run self-good.sh "$TMP/vmmut1")"
if grep -qx 'MVC=6/0' <<<"$res" && grep -q 'PASS  teeth-mut-alloc' <<<"$res"; then
  ok "vm core: three staging controls and three real mutants all hold (6 pass, 0 fail)"
else no "vm core: faithful scenario runner gives 6/0 (got [$res])"; fi
res="$(vm_run self-blunt.sh "$TMP/vmmut2")"
if grep -qx 'MVC=3/3' <<<"$res" && grep -q 'THEATER' <<<"$res"; then
  ok "vm core: a scenario runner that never bites is 3 counted failures (THEATER), not a pass"
else no "vm core: non-biting suite counts 3 failures (got [$res])"; fi
res="$(vm_run self-crash.sh "$TMP/vmmut3")"
if grep -qx 'MVC=0/6' <<<"$res"; then ok "vm core: a traceback on the unmutated tree fails the staging control"
else no "vm core: crash on the clean tree fails the staging control (got [$res])"; fi
cp -R "$VM" "$TMP/vm2"; sed -i 's/ignore_errors=True/ignore_errors=False/' "$TMP/vm2/lib/vm_boot_core.py"
res="$(vm_run self-good.sh "$TMP/vmmut4" "$TMP/vm2")"
if grep -qx 'MVC=5/1' <<<"$res" && grep -q 'FAIL  teeth-mut-inv5' <<<"$res"; then
  ok "vm core: a dead mutation anchor is counted once and the other mutants still run (5 pass, 1 fail)"
else no "vm core: a dead anchor is counted once (got [$res])"; fi
# The python half: compile the shared source, then drive its scenarios against a stub executor.
mutant_vm_tooth_py_src > "$VM/tooth.py"
if python3 -I -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$VM/tooth.py" 2>/dev/null \
   && grep -q '^def _tooth_run(name, plan_flags, mod, cls):$' "$VM/tooth.py"; then
  ok "vm tooth py: the shared runner source compiles and has the (name, plan_flags, mod, cls) signature"
else no "vm tooth py: the shared runner source compiles with the documented signature"; fi
printf 'import tempfile\n_DEFAULT_RSDD_ROOT = "x"\ndef make_run_subdir(run_uuid, root=_DEFAULT_RSDD_ROOT):\n    return tempfile.mkdtemp(prefix="mvc-")\n' > "$VM/pystub/docker_common.py"
printf 'class GateError(Exception):\n    pass\n' > "$VM/pystub/gate.py"
printf 'import docker_common as dc\nfrom gate import GateError\nclass FakeExec:\n    def __init__(self, out): pass\n    def evaluate(self, plan):\n        dc.make_run_subdir("a"); dc.make_run_subdir("b")\n        raise GateError("sentinel not found in planned_argv")\n' > "$VM/pystub/fakeexec.py"
cat > "$VM/drv.py" <<'PY'
import os, sys, tempfile, json
from pathlib import Path
sys.path.insert(0, sys.argv[1])
def _shims(t): return os.environ.get("PATH", "")
def _elf(t): return t
def cli(*a, **k): raise SystemExit("cli is not used by this fixture")
_GOOD_ARGV = ["x"]
exec(os.environ["RSDD_TOOTH_PY"], globals())
_tooth_run(sys.argv[2], lambda elf: [], "fakeexec", "FakeExec")
PY
vm_tp(){ RSDD_TOOTH_PY="$(mutant_vm_tooth_py_src)" python3 -I "$VM/drv.py" "$VM/pystub" "$1" 2>&1; }
if [ "$(vm_tp alloc)" = "TOOTH_ALLOC=2" ]; then ok "vm tooth py: alloc counts both run_dir allocations made by the executor"
else no "vm tooth py: alloc counts allocations (got [$(vm_tp alloc)])"; fi
if [ "$(vm_tp inv5)" = "TOOTH_INV5=leaked" ]; then ok "vm tooth py: inv5 reports leaked when the executor does not reap its run_dir"
else no "vm tooth py: inv5 leak verdict (got [$(vm_tp inv5)])"; fi
if [ "$(vm_tp zzz)" = "TOOTH_ERROR=unknown scenario zzz" ]; then ok "vm tooth py: an unknown scenario is a typed error, not a silent pass"
else no "vm tooth py: unknown scenario (got [$(vm_tp zzz)])"; fi

# T19 -- shared suite bootstrap and crash classifier (#1576): mutant_bootstrap replaces the copied
# `for _fn in ...; declare -F` probe loops; mutant_crash_re / mutant_is_crash replace copied CRASH regex
# literals where the classes compose byte-identically. MIGRATED: the verify-registry teeth block
# (bash py), the install suite's --verify teeth _CRASH (bash py cmd), the mutant_vm_core_teeth crash regex
# (mutant_vm_crash_re = py + SyntaxError), and the mutant.sh bootstraps of verify-retro, adapter-core,
# adapter-helpers, analysis-manifest, vm-disk-policy, discriminator-parity, gh-visibility, templates,
# mutant-syntax-export-lint, detonate-exec and trace-exec; batch 1 (56 suites) moved every other
# mutant.sh-only probe loop. NOT MIGRATED (deferred, scope is partial):
# hand-rolled probe loops remain in 3 suites (owned by another open PR; enumerate with
# `rg -l 'lib/mutant.sh (did not define|lacks)' research-sdd`, minus lib/mutant.sh itself); crash literals
# that differ in meaning stay local: decompile-net/decompile-native CRASH_RE (ImportError without
# ModuleNotFoundError), research-sdd-status-followups CRASH and verify-skill-drift-hook _CRASH (no
# `integer expression expected`); decompile-native probes suite-local functions, not mutant.sh ones.
# Each class is a named, explicit piece so variants that differ in meaning stay different.
mutant_bootstrap mutant_chain mutant_tooth >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "bootstrap: every named helper defined -> rc 0"; else no "bootstrap: defined helpers (rc=$rc)"; fi
mb_err="$(mutant_bootstrap mutant_chain mutant_no_such_helper_zz mutant_tooth 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && [[ "$mb_err" == "FATAL: lib/mutant.sh ("*"mutant.sh) did not define mutant_no_such_helper_zz" ]]; then ok "bootstrap: a missing helper is rc 2 and named in the FATAL line, with the library path"
else no "bootstrap: missing helper (rc=$rc err=[$mb_err])"; fi
mb_err="$(mutant_bootstrap 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && [[ "$mb_err" == *REFUSED* ]]; then ok "bootstrap: no helper names is refused (a probe that checks nothing proves nothing)"
else no "bootstrap: empty probe list (rc=$rc err=[$mb_err])"; fi
mb_err="$(mutant_bootstrap mutant_chain mutant_zz_last 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && [[ "$mb_err" == *mutant_zz_last* ]]; then ok "bootstrap: a missing helper in LAST position is caught"
else no "bootstrap: last position (rc=$rc err=[$mb_err])"; fi
mb_err="$(mutant_bootstrap mutant_zz_only 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && [[ "$mb_err" == *mutant_zz_only* ]]; then ok "bootstrap: a single missing helper is caught"
else no "bootstrap: single element (rc=$rc err=[$mb_err])"; fi
CRASH_BASH='integer expression expected|syntax error|unbound variable'
cr_got="$(mutant_crash_re)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$cr_got" = "$CRASH_BASH|Traceback|ImportError|ModuleNotFoundError" ]; then ok "crash_re: no classes = the canonical bash + python set"
else no "crash_re: default (rc=$rc got=[$cr_got])"; fi
cr_got="$(mutant_crash_re bash)"
if [ "$cr_got" = "$CRASH_BASH" ]; then ok "crash_re: class bash"; else no "crash_re: class bash (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re tb)"
if [ "$cr_got" = "Traceback" ]; then ok "crash_re: class tb"; else no "crash_re: class tb (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re imp)"
if [ "$cr_got" = "ImportError|ModuleNotFoundError" ]; then ok "crash_re: class imp"; else no "crash_re: class imp (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re py)"
if [ "$cr_got" = "Traceback|ImportError|ModuleNotFoundError" ]; then ok "crash_re: class py"; else no "crash_re: class py (got=[$cr_got])"; fi
mutant_is_crash 'Traceback (most recent call last):' tb; rc=$?
if [ "$rc" -eq 0 ]; then ok "crashtb: class tb matches Traceback"; else no "crashtb: Traceback (rc=$rc)"; fi
mutant_is_crash 'ImportError: x' tb; rc=$?
if [ "$rc" -eq 1 ]; then ok "crashtb: class tb does NOT match ImportError (no widening)"; else no "crashtb: ImportError (rc=$rc)"; fi
mutant_is_crash 'ImportError: x' py; rc=$?; mutant_is_crash 'ModuleNotFoundError: x' py; rc2=$?; mutant_is_crash 'Traceback' py; rc3=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ]; then ok "crashpy: class py matches Traceback, ImportError and ModuleNotFoundError"; else no "crashpy: members (rc=$rc/$rc2/$rc3)"; fi
if [ "$(mutant_crash_re py)" = "$(mutant_crash_re tb imp)" ]; then ok "crashpy: py is exactly tb then imp (one source of truth)"; else no "crashpy: py != tb|imp"; fi
mutant_is_crash 'all fine' py; rc=$?
if [ "$rc" -eq 1 ]; then ok "crashpy: clean output is not a crash"; else no "crashpy: clean (rc=$rc)"; fi
vc_got="$(mutant_vm_crash_re)"
if [ "$vc_got" = "Traceback|ImportError|ModuleNotFoundError|SyntaxError" ]; then ok "vm_crash_re: pinned value (py classes + SyntaxError)"; else no "vm_crash_re: value (got=[$vc_got])"; fi
cr_got="$(mutant_crash_re cmd)"
if [ "$cr_got" = "command not found" ]; then ok "crash_re: class cmd"; else no "crash_re: class cmd (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re awk)"
if [ "$cr_got" = "awk: " ]; then ok "crash_re: class awk keeps its trailing space"; else no "crash_re: class awk (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re bash cmd tb awk)"
if [ "$cr_got" = "$CRASH_BASH|command not found|Traceback|awk: " ]; then ok "crash_re: classes compose in the order given (the variant the verify-corrections suites carry)"
else no "crash_re: composition order (got=[$cr_got])"; fi
cr_got="$(mutant_crash_re bash nosuchclass 2>"$TMP/cr.err")"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$cr_got" ] && grep -q 'unknown class \[nosuchclass\]' "$TMP/cr.err"; then ok "crash_re: an unknown class is rc 2 with NO output (an empty regex would match everything)"
else no "crash_re: unknown class (rc=$rc got=[$cr_got] err=[$(cat "$TMP/cr.err")])"; fi
cr_got="$(mutant_crash_re nosuchclass bash 2>/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$cr_got" ]; then ok "crash_re: an unknown class in FIRST position is refused too"
else no "crash_re: unknown class first (rc=$rc got=[$cr_got])"; fi
mutant_is_crash 'line 4: x: unbound variable'; rc=$?
if [ "$rc" -eq 0 ]; then ok "is_crash: a bash crash signature is a crash"; else no "is_crash: bash signature (rc=$rc)"; fi
mutant_is_crash 'ModuleNotFoundError: No module named x'; rc=$?
if [ "$rc" -eq 0 ]; then ok "is_crash: a python signature is a crash (default classes)"; else no "is_crash: python signature (rc=$rc)"; fi
mutant_is_crash 'all good, 3 findings'; rc=$?
if [ "$rc" -eq 1 ]; then ok "is_crash: clean output is rc 1"; else no "is_crash: clean output (rc=$rc)"; fi
mutant_is_crash 'foo: command not found'; rc=$?
if [ "$rc" -eq 1 ]; then ok "is_crash: command-not-found is NOT a crash unless the cmd class is named"; else no "is_crash: cmd class not default (rc=$rc)"; fi
mutant_is_crash 'foo: command not found' bash cmd; rc=$?
if [ "$rc" -eq 0 ]; then ok "is_crash: command-not-found IS a crash when the cmd class is named"; else no "is_crash: cmd class (rc=$rc)"; fi
mutant_is_crash 'awk: cmd. line:1: fatal' bash awk; rc=$?
if [ "$rc" -eq 0 ]; then ok "is_crash: awk diagnostic is a crash when the awk class is named"; else no "is_crash: awk class (rc=$rc)"; fi
mutant_is_crash 'unbound variable' bash nosuchclass 2>/dev/null; rc=$?
if [ "$rc" -eq 2 ]; then ok "is_crash: an unknown class is rc 2, never a quiet 'not a crash'"; else no "is_crash: unknown class (rc=$rc)"; fi

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
  teeth_case sedrm '/SENTINEL-SED-FAIL-CHECK/,+3s/rm -f -- "\$out"; //' \
    "sed failure (rc 6): the stale/partial mutant file is removed"
  if [ "$UNR_TESTABLE" -eq 1 ]; then
    teeth_case unreadable '/^mutant_sed/,/^}/s/ || \[ ! -r "\$orig" \]//' \
      "unreadable original: mutant_sed refuses"
    teeth_case unreadablever '/^mutant_verify/,/^}/s/ || \[ ! -r "\$orig" \]//' \
      "unreadable original: mutant_verify refuses"
  else
    ok "teeth unreadable/unreadablever: SKIP — chmod 000 is still readable here (same check as T14)"
  fi
  teeth_case debugon 's/if \[ -n "\${MUTANT_TOOTH_DEBUG:-}" \]; then/if true; then/' \
    "tooth debug: unset prints nothing on stderr"
  teeth_case debugstdout '/^_mutant_debug()/s/ >&2//' \
    "tooth debug: stdout is byte-identical"
  teeth_case debugquiet '/^_mutant_debug()/s/printf .*$/:; }/' \
    "tooth debug: set prints mutant path, both rcs and run output to stderr"
  # mutant_chain / mutant_built / mutant_tooth (#1299)
  teeth_case chaindead '/SENTINEL-CHAIN-DEAD-STAGE/,+1s/cmp -s - "\$orig"/false/' \
    "chain: dead last stage"
  teeth_case chaindeadrc 's/return 10/return 1/' \
    "chain: dead first stage"
  teeth_case chainnostage '/given no sed stage/s/return 1/:/' \
    "chain: zero stages"
  teeth_case chainrc '/^mutant_chain/,/^}/s/return "\$rc"/return 1/' \
    "chain: syntax-broken"
  teeth_case builtsilent '/^mutant_built/,/^}/s/-ne 0/-eq 0/' \
    "built: accepted"
  teeth_case toothbadrc '/SENTINEL-TOOTH-BADRC/,+1s/\[ "\$mrc_a" = "\$brc" \] ||/:/' \
    "tooth: crash"
  teeth_case toothgoodrc 's/^  \[ "\$grc_a" = "\$grc" \] || why=.*$/  :/' \
    "tooth: original rc"
  teeth_case toothghas '/SENTINEL-TOOTH-PATTERNS/,+3s/\[ -n "\$ghas" \]/false/' \
    "tooth opt: good-has-false"
  teeth_case toothglack '/SENTINEL-TOOTH-PATTERNS/,+3s/\[ -n "\$glack" \]/false/' \
    "tooth opt: good-lacks-false"
  teeth_case toothbhas '/SENTINEL-TOOTH-BADRC/,+3s/\[ -n "\$bhas" \]/false/' \
    "tooth opt: bad-has-false"
  teeth_case toothblack '/SENTINEL-TOOTH-BADRC/,+3s/\[ -n "\$black" \]/false/' \
    "tooth opt: bad-lacks-false"
  teeth_case toothicase 's/gi="-i"/gi=""/' \
    "tooth: icase has"
  teeth_case toothnondisc '/SENTINEL-TOOTH-NONDISCRIMINATING/,+3s/return 1/:/' \
    "tooth: non-discriminating"
  teeth_case toothoption '/bad option/s/return 1 ;;/: ;;/' \
    "tooth: unknown option"
  teeth_case toothnodash '/missing the "--"/s/return 1 ;;/: ;;/' \
    "tooth: missing --"
  teeth_case toothnoargv '/has no ARGV/s/return 1;/:;/' \
    "tooth: empty ARGV"
  teeth_case toothnoorig '/has no original/s/return 1;/:;/' \
    "tooth: no original"
  teeth_case toothabsent '/mutant file absent/s/return 1;/:;/' \
    "tooth: absent mutant"
  teeth_case toothdefault 's/orig="\${SUT:-}"/orig=""/' \
    "tooth: exact rc"
  teeth_case toothsubst 's/@SUT@\/"\$orig"/@SUT@\/"$mut"/' \
    "tooth: @SUT@ substitution"
  # mutant_cleanup_register / mutant_py_replace / mutant_or_count (#1576). Needles are the FAIL-side
  # text of the case, which differs from its PASS-side text.
  teeth_case cleanuprm '/^_mutant_cleanup_run/,/^}/s/rm -rf -- "\$p"/:/' \
    "cleanup: registered paths removed at exit"
  teeth_case cleanupchain 's/\${cmd:+; \$cmd}//' \
    "cleanup: a pre-existing EXIT trap is chained"
  teeth_case cleanuponce 's/\*_mutant_cleanup_run\*) ;;/*_NEVER_MATCHES_*) ;;/' \
    "cleanup: trap installed once"
  teeth_case cleanupheal 's/^  prev="\$(trap -p EXIT)"$/  prev="$(trap -p EXIT)"; [ "${#_MUTANT_CLEANUP_PATHS[@]}" -le 1 ] || prev=_mutant_cleanup_run/' \
    "cleanup: re-chain after the suite replaced the trap"
  teeth_case cleanuprel 's/if \[ "\${p#\/}" = "\$p" \] || /if /' \
    "cleanup: empty/relative refusal"
  teeth_case cleanupslash 's/ || \[ "\$p" = \/ \]; then/; then/' \
    "cleanup: / refusal"
  teeth_case cleanupstatus 's/(exit \\"\\\$__mrc\\")/:/' \
    "cleanup: exit status seen by a chained trap"
  teeth_case countshadowrc 's/_moc_rc/rc/g' \
    "count-once: counter named rc shadowed"
  teeth_case countshadowname 's/_moc_name/counter/g' \
    "count-once: counter named counter shadowed"
  teeth_case countreserved 's/ || \[\[ "\$_moc_name" == _moc_\* \]\]//' \
    "count-once: reserved counter name"
  teeth_case pyrefusestdout '/^mutant_py_replace/,/^}/s/_mutant_check_out "\$orig" "\$out" || return 3/_mutant_check_out "$orig" "$out" 2>\&1 || return 3/' \
    "py_replace: refusal leaked to stdout"
  teeth_case pyanchor '/anchor not found/s/return 2/:/' \
    "py_replace: absent anchor is rc 2"
  teeth_case pyempty '/empty anchor/s/return 2/:/' \
    "py_replace: empty anchor is rc 2"
  teeth_case pyorig '/^mutant_py_replace/,/^}/s/if \[ ! -f "\$orig" \] || \[ ! -r "\$orig" \]; then/if false; then/' \
    "py_replace: absent original is rc 2"
  teeth_case pyidentical '/OLD and NEW are identical/s/return 3/:/' \
    "py_replace: OLD == NEW is rc 3"
  teeth_case pycompile '/SENTINEL-PY-COMPILE/,+2s/return 3/:/' \
    "py_replace: a mutant that is not valid Python is rc 3"
  teeth_case pyrm '/SENTINEL-PY-COMPILE/,+2s/rm -f -- "\$out"; //' \
    "py_replace: invalid-Python mutant still exists"
  teeth_case pysymlink '/^mutant_py_replace/,/^}/s/^  _mutant_check_out .*$/  :/' \
    "py_replace: wrote through the symlink"
  teeth_case pyself '/^mutant_py_replace/,/^}/s/if \[ "\$orig" -ef "\$out" \]; then/if false; then/' \
    "py_replace: OUT equal to ORIG is rc 3"
  teeth_case countonce '/SENTINEL-COUNT-ONCE/,+1s/+ 1/+ 2/' \
    "count-once: dead stage"
  teeth_case countalways 's/if \[ "\$_moc_rc" -ne 0 \]; then printf -v/if true; then printf -v/' \
    "count-once: success counted"
  teeth_case countrc '/^mutant_or_count/,/^}/s/return "\$_moc_rc"/return 0/' \
    "count-once: dead stage"
  teeth_case countname 's|\^\[A-Za-z_\]\[A-Za-z0-9_\]\*\$|^.*$|' \
    "count-once: invalid counter name"
  teeth_case countnum 's|=~ \^\[0-9\]+\$ \]\]|=~ ^.*$ ]]|' \
    "count-once: non-numeric counter"
  teeth_case countchain 's/mutant_or_count "\${1:-}" mutant_chain "\${@:2}"/mutant_chain "${@:2}"/' \
    "count-once: dead stage"
  teeth_case countbuilt 's/mutant_or_count "\${1:-}" mutant_built "\${@:2}"/mutant_built "${@:2}"/' \
    "count-once: refused built"
  # shared VM-executor tooth kit (#1576)
  teeth_case vmalloc 's/n = len(made); _cleanup(); print(f"TOOTH_ALLOC={n}"); return/n = len(made) + 1; _cleanup(); print(f"TOOTH_ALLOC={n}"); return/' \
    "vm tooth py: alloc counts allocations"
  teeth_case vmleaked 's/("leaked" if leaked else "reaped")/("reaped" if leaked else "leaked")/' \
    "vm tooth py: inv5 leak verdict"
  teeth_case vmunknown 's/print(f"TOOTH_ERROR=unknown scenario {name}")/pass/' \
    "vm tooth py: unknown scenario"
  teeth_case vmcount 's/else MVC_FAIL=\$((MVC_FAIL+1)); fi; }/else :; fi; }/' \
    "vm core: non-biting suite counts 3 failures"
  teeth_case vmanchor 's/"\$core" "\$mut\/\$2\/lib\/vm_boot_core.py" "\$3"; then MVC_FAIL=\$((MVC_FAIL+1)); return 1/"$core" "$mut\/$2\/lib\/vm_boot_core.py" "$3"; then return 1/' \
    "vm core: a dead anchor is counted once"
  teeth_case vmcrash 's/ \&\& ! grep -qE "\$crash" <<<"\$o"//' \
    "vm core: crash on the clean tree fails the staging control"
  teeth_case vmmutate 's|/        pass/;}|/        raise/;}|' \
    "vm core: faithful scenario runner gives 6/0"
  # shared bootstrap probe + crash classifier (#1576)
  teeth_case bootprobe '/^mutant_bootstrap/,/^}/s/declare -F "\$_mb_fn" >\/dev\/null 2>&1 ||/true ||/' \
    "bootstrap: missing helper"
  teeth_case bootrc '/^mutant_bootstrap/,/^}/s/"\$_mb_fn" >&2; return 2;/"$_mb_fn" >\&2; return 0;/' \
    "bootstrap: missing helper"
  teeth_case bootnone '/^mutant_bootstrap/,/^}/s/if \[ "\$#" -eq 0 \]; then/if false; then/' \
    "bootstrap: empty probe list"
  teeth_case bootname 's/did not define %s\\n/is absent %s\\n/' \
    "bootstrap: missing helper"
  teeth_case crashdefault 's/\[ "\$#" -gt 0 \] || set -- bash py/[ "$#" -gt 0 ] || set -- bash/' \
    "crash_re: default"
  teeth_case crashbash "s/syntax error|unbound variable' ;;/unbound variable' ;;/" \
    "crash_re: class bash"
  teeth_case crashimp "s/imp)  printf '%s' 'ImportError|ModuleNotFoundError'/imp)  printf '%s' 'ImportError'/" \
    "crash_re: class imp"
  teeth_case crashcmd "s/'command not found' ;;/'command not found ' ;;/" \
    "crash_re: class cmd"
  teeth_case crashawk "s/'awk: ' ;;/'awk:' ;;/" \
    "crash_re: class awk"
  teeth_case crashorder 's/_mc_re="\${_mc_re:+\$_mc_re|}\$_mc_part"/_mc_re="${_mc_part}${_mc_re:+|$_mc_re}"/' \
    "crash_re: composition order"
  teeth_case crashunknown '/^mutant_crash_re/,/^}/s/return 2; }$/continue; }/' \
    "crash_re: unknown class"
  teeth_case crashrc2 '/^mutant_is_crash/,/^}/s/ || return 2$/ || :/' \
    "is_crash: unknown class"
  teeth_case crashgrep 's/grep -qE -- "\$_mi_re" <<<"\$_mi_text"/grep -qE -- "$_mi_re" <<<""/' \
    "is_crash: bash signature"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
