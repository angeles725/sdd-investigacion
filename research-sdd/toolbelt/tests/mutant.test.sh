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
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
