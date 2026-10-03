#!/usr/bin/env bash
# plan-review-slices.test.sh — harness for plan-review-slices.sh (kit issue #1276).
#
# The tool walks merge-base..HEAD (first-parent, oldest first), counts authored changed lines per
# commit (additions + deletions, binary files typed and excluded) and greedily groups consecutive
# commits into slices of at most --max-lines, cutting only at commit boundaries. Cases pin: grouping,
# the <= boundary (N fits, N+1 splits), UNSPLITTABLE commits at the first / middle / last position,
# deletions counted, binary typed not counted, the base= field being a real reviewable parent,
# EMPTY-RANGE, every exit code (2 bad ref / not a repo / bad usage, 3 git missing), merge commits,
# default base origin/main, and that the run creates no refs. --prove-teeth mutates the tool and
# requires each mutant to flip a specific assertion.
#
# Usage: plan-review-slices.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../plan-review-slices.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ OUT="$(timeout 30 bash "$SUT" "$@" 2>&1)"; RC=$?; }
has(){ grep -qF -- "$1" <<<"$OUT"; }
expect(){ local label="$1" want="$2"; shift 2; local miss=""
  [ "$RC" = "$want" ] || miss="rc=$RC(want $want) "
  for n in "$@"; do has "$n" || miss="${miss}[missing: $n] "; done
  if [ -z "$miss" ]; then ok "$label"; else no "$label — $miss| out: $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-400)"; fi; }
lacks(){ local label="$1"; shift; local hit=""
  for n in "$@"; do has "$n" && hit="${hit}[unexpected: $n] "; done
  if [ -z "$hit" ]; then ok "$label"; else no "$label — $hit| out: $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-300)"; fi; }

# mkrepo <dir> : repo with one base commit tagged `base`.
mkrepo(){ local d="$1"; mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main; }
  git -C "$d" config user.email t@t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  printf 'seed\n' > "$d/seed.txt"; git -C "$d" add -A; git -C "$d" commit -q -m base; git -C "$d" tag base; }
# add <dir> <file> <nlines> : commit that creates <file> with <nlines> lines (nlines authored changed lines).
add(){ local d="$1" f="$2" n="$3"; seq 1 "$n" | sed "s/^/${f}-/" > "$d/$f"; git -C "$d" add -A; git -C "$d" commit -q -m "add $f $n"; }

echo "-- plan-review-slices.sh --"

# 1. EMPTY-RANGE: HEAD == base -> that line only, exit 0.
d="$TMP/empty"; mkrepo "$d"
run --cwd "$d" --base-ref base; expect "1  empty range prints EMPTY-RANGE and exits 0" 0 "EMPTY-RANGE"
lacks "1b empty range prints no SLICE / PLAN line" "SLICE" "PLAN:"

# 2. Greedy grouping: 4 x 150 lines, N=400 -> two slices of two commits.
d="$TMP/greedy"; mkrepo "$d"; for i in 1 2 3 4; do add "$d" "f$i" 150; done
run --cwd "$d" --base-ref base --max-lines 400
expect "2  4x150 at N=400 groups 2+2" 0 "SLICE 1 " "commits=2 lines=300" "SLICE 2 " "PLAN: 2 slice(s) commits=4 lines=600 max=400"
lacks "2b no third slice" "SLICE 3 "

# 3. Boundary: exactly N fits, N+1 splits.
d="$TMP/edge"; mkrepo "$d"; add "$d" a 200; add "$d" b 200
run --cwd "$d" --base-ref base --max-lines 400; expect "3  200+200 at N=400 is ONE slice (<= N)" 0 "PLAN: 1 slice(s) commits=2 lines=400 max=400"
run --cwd "$d" --base-ref base --max-lines 399; expect "3b 200+200 at N=399 splits into two" 0 "PLAN: 2 slice(s) commits=2 lines=400 max=399"
run --cwd "$d" --base-ref base --max-lines 200; expect "3c a commit equal to N is not UNSPLITTABLE" 0 "PLAN: 2 slice(s)"
lacks "3d no UNSPLITTABLE at equality" "UNSPLITTABLE"

# 4. UNSPLITTABLE in the middle, first, last, and alone.
d="$TMP/unsp"; mkrepo "$d"; add "$d" a 50; add "$d" big 500; add "$d" c 50
run --cwd "$d" --base-ref base --max-lines 400
expect "4  oversized middle commit is its own UNSPLITTABLE slice" 0 "SLICE 2 " "commits=1 UNSPLITTABLE lines=500" "PLAN: 3 slice(s) commits=3 lines=600 max=400"
d="$TMP/unsp-first"; mkrepo "$d"; add "$d" big 500; add "$d" a 50
run --cwd "$d" --base-ref base --max-lines 400; expect "4b UNSPLITTABLE first, then a normal slice" 0 "SLICE 1 " "UNSPLITTABLE lines=500" "SLICE 2 " "PLAN: 2 slice(s)"
d="$TMP/unsp-last"; mkrepo "$d"; add "$d" a 50; add "$d" big 500
run --cwd "$d" --base-ref base --max-lines 400; expect "4c UNSPLITTABLE last, preceded by a normal slice" 0 "SLICE 1 " "SLICE 2 " "UNSPLITTABLE lines=500" "PLAN: 2 slice(s)"
d="$TMP/unsp-one"; mkrepo "$d"; add "$d" big 500
run --cwd "$d" --base-ref base --max-lines 400; expect "4d single oversized commit: one UNSPLITTABLE slice" 0 "PLAN: 1 slice(s) commits=1 lines=500" "UNSPLITTABLE"

# 5. Deletions count (additions + deletions).
d="$TMP/del"; mkrepo "$d"; add "$d" a 100
seq 1 30 | sed 's/^/a-/' > "$d/a"; git -C "$d" add -A; git -C "$d" commit -q -m shrink   # -70 lines
run --cwd "$d" --base-ref base --max-lines 400; expect "5  additions + deletions: 100 + 70" 0 "PLAN: 1 slice(s) commits=2 lines=170"
d="$TMP/mod"; mkrepo "$d"; add "$d" a 10
seq 1 10 | sed 's/^/zz-/' > "$d/a"; git -C "$d" add -A; git -C "$d" commit -q -m rewrite  # 10 add + 10 del
run --cwd "$d" --base-ref base --max-lines 400; expect "5b a 10-line rewrite counts 20 (10 added + 10 deleted)" 0 "PLAN: 1 slice(s) commits=2 lines=30"

# 6. Binary files: typed, excluded from the count.
d="$TMP/bin"; mkrepo "$d"; add "$d" a 40
head -c 4096 /dev/zero | tr '\0' '\1' > "$d/blob.bin"; printf 'x\0y\n' >> "$d/blob.bin"; git -C "$d" add -A; git -C "$d" commit -q -m binary
run --cwd "$d" --base-ref base --max-lines 400; expect "6  binary file is typed and not counted" 0 "lines=40" "binary=1"
d="$TMP/bin2"; mkrepo "$d"; add "$d" a 40
run --cwd "$d" --base-ref base --max-lines 400; lacks "6b no binary field when there is no binary file" "binary="

# 7. base= is the real parent of the first commit, so the slice is reviewable as --base-ref <base>.
d="$TMP/parents"; mkrepo "$d"; for i in 1 2 3; do add "$d" "p$i" 250; done
run --cwd "$d" --base-ref base --max-lines 400
s1="$(git -C "$d" rev-list --reverse base..HEAD | sed -n 1p)"; s2="$(git -C "$d" rev-list --reverse base..HEAD | sed -n 2p)"; s3="$(git -C "$d" rev-list --reverse base..HEAD | sed -n 3p)"
b1="$(git -C "$d" rev-parse --short=12 "$s1^")"; b2="$(git -C "$d" rev-parse --short=12 "$s2^")"; b3="$(git -C "$d" rev-parse --short=12 "$s3^")"
expect "7  slice bases are the real parents of each first commit" 0 "base=$b1" "base=$b2" "base=$b3"
c1="$(git -C "$d" rev-parse --short=12 "$s1")"; c3="$(git -C "$d" rev-parse --short=12 "$s3")"
has "SLICE 1 $c1..$c1 " && ok "7b slice range is first..last short shas" || no "7b slice 1 range not $c1..$c1: $(printf '%s' "$OUT" | tr '\n' '~')"
has "SLICE 3 $c3..$c3 " && ok "7c last slice range names the last commit" || no "7c slice 3 range not $c3..$c3"
tot="$(git -C "$d" diff --numstat "$b2" "$s2" | awk '{a+=$1+$2} END{print a+0}')"
rep="$(grep '^SLICE 2 ' <<<"$OUT" | sed -n 's/.* lines=\([0-9]*\).*/\1/p')"
[ -n "$rep" ] && [ "$tot" = "$rep" ] && ok "7d git diff of base..last of slice 2 ($tot) equals the reported lines ($rep)" || no "7d base diff is $tot, reported '$rep'"

# 8. Exit codes.
run --cwd "$d" --base-ref no-such-ref; expect "8  unknown base ref exits 2" 2 "no-such-ref"
run --cwd "$TMP" --base-ref base; expect "8b not a git repository exits 2" 2 "not a git repository"
run --cwd "$TMP/does-not-exist" --base-ref base; expect "8c absent --cwd exits 2" 2 "does-not-exist"
run --cwd "$d" --base-ref base --max-lines 0; expect "8d --max-lines 0 exits 2" 2 "max-lines"
run --cwd "$d" --base-ref base --max-lines abc; expect "8e --max-lines abc exits 2" 2 "max-lines"
run --cwd "$d" --base-ref base --bogus; expect "8f unknown option exits 2" 2 "usage"
run --cwd "$d"; expect "8g default base origin/main absent exits 2 and names it" 2 "origin/main"
mkdir -p "$TMP/nogit"; OUT="$(PATH="$TMP/nogit" "$BASH" "$SUT" --cwd "$d" --base-ref base 2>&1)"; RC=$?
expect "8h git missing exits 3 DEGRADED" 3 "DEGRADED"

# 9. Default base origin/main.
d="$TMP/origin"; mkrepo "$d"; git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse base)"; add "$d" a 120
run --cwd "$d"; expect "9  default base is origin/main, default max is 400" 0 "PLAN: 1 slice(s) commits=1 lines=120 max=400"

# 10. Merge commit: first-parent walk counts the merge against its first parent.
d="$TMP/merge"; mkrepo "$d"; add "$d" m1 60
git -C "$d" checkout -q -b side base; add "$d" s1 30
git -C "$d" checkout -q main; git -C "$d" merge -q --no-ff -m merge side
run --cwd "$d" --base-ref base --max-lines 400; expect "10 first-parent walk: m1 (60) + merge (30 from side)" 0 "PLAN: 1 slice(s) commits=2 lines=90"

# 11. Report-only: refs unchanged.
d="$TMP/refs"; mkrepo "$d"; add "$d" a 10; before="$(git -C "$d" for-each-ref; git -C "$d" status --porcelain)"
run --cwd "$d" --base-ref base; after="$(git -C "$d" for-each-ref; git -C "$d" status --porcelain)"
[ "$before" = "$after" ] && ok "11 run creates no refs and dirties nothing" || no "11 refs/worktree changed by the run"

# 12. Diverged base: merge-base is used, only the HEAD side counts.
d="$TMP/mb"; mkrepo "$d"; add "$d" a 20
git -C "$d" checkout -q -b other base; add "$d" o 33
run --cwd "$d" --base-ref main; expect "12 base on a diverged branch uses the merge-base (only HEAD side counted)" 0 "PLAN: 1 slice(s) commits=1 lines=33"

# 13. A malformed numstat row fails loudly (exit 2), never counts as 0. A git shim corrupts numstat output.
d="$TMP/malformed"; mkrepo "$d"; add "$d" a 20
mkdir -p "$TMP/shim"; REALGIT="$(command -v git)"
printf '#!/bin/sh\ncase "$*" in *--numstat*) echo garbage-row; exit 0;; esac\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim/git"; chmod +x "$TMP/shim/git"
OUT="$(PATH="$TMP/shim:$PATH" timeout 30 bash "$SUT" --cwd "$d" --base-ref base 2>&1)"; RC=$?
expect "13 malformed numstat row exits 2 and names it" 2 "malformed numstat"
lacks "13b no PLAN line is printed for a malformed measurement" "PLAN:"

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: plan-review-slices mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mkdir -p "$TMP/mut"
  # tooth <name> <sed-expr> <good rc> <needle GOOD prints> <repo> [args...]: the mutant must lose the needle or change rc.
  tooth(){ local name="$1" expr="$2" grc="$3" needle="$4" repo="$5"; shift 5
    local m="$TMP/mut/$name.sh"
    if ! mutant_sed "$SUT" "$m" "$expr" 2>/dev/null; then no "teeth $name: could not build mutant (pattern absent / refused by lib/mutant.sh)"; return; fi
    local mo mrc go grcr
    mo="$(timeout 30 bash "$m" --cwd "$repo" "$@" 2>&1)"; mrc=$?
    go="$(timeout 30 bash "$SUT" --cwd "$repo" "$@" 2>&1)"; grcr=$?
    if [ "$grcr" != "$grc" ] || ! grep -qF -- "$needle" <<<"$go"; then no "teeth $name: ORIGINAL does not satisfy the assertion (rc=$grcr)"; return; fi
    if [ "$mrc" != "$grc" ] || ! grep -qF -- "$needle" <<<"$mo"; then ok "teeth $name: mutant flips the assertion (rc=$mrc)"
    else no "teeth $name: mutant still satisfies the assertion — THEATER"; fi; }
  tooth fits-at-equal 's/-le "\$max"/-lt "$max"/' 0 "PLAN: 1 slice(s) commits=2 lines=400 max=400" "$TMP/edge" --base-ref base --max-lines 400
  tooth unsplittable-gate 's/-gt "\$max"/-gt 99999999/' 0 "UNSPLITTABLE lines=500" "$TMP/unsp" --base-ref base --max-lines 400
  tooth deletions-counted 's/a += \$1 + \$2/a += $1/' 0 "lines=170" "$TMP/del" --base-ref base --max-lines 400
  tooth binary-detected 's/\$1 == "-"/$1 == "NEVER"/' 0 "binary=1" "$TMP/bin" --base-ref base --max-lines 400
  tooth binary-typed 's/binary=%d/bin=%d/' 0 "binary=1" "$TMP/bin" --base-ref base --max-lines 400
  tooth base-is-parent 's/base=%s/base=%.0s/' 0 "base=$b1" "$TMP/parents" --base-ref base --max-lines 400
  tooth flush-final 's/^emit_slice # FINAL$/:/' 0 "PLAN: 2 slice(s) commits=4 lines=600 max=400" "$TMP/greedy" --base-ref base --max-lines 400
  tooth empty-range 's/^  echo "EMPTY-RANGE/  echo "NOPE/' 0 "EMPTY-RANGE" "$TMP/empty" --base-ref base
  tooth first-parent 's/--first-parent //' 0 "PLAN: 1 slice(s) commits=2 lines=90" "$TMP/merge" --base-ref base --max-lines 400
  tooth merge-base-used 's/g merge-base "\$BASE"/g rev-parse "$BASE"/' 0 "PLAN: 1 slice(s) commits=1 lines=33" "$TMP/mb" --base-ref main
  # shim tooth: the original exits 2 on the corrupted numstat; the mutant must not.
  shimtooth(){ local name="$1" expr="$2" m="$TMP/mut/$1.sh" mo mrc
    if ! mutant_sed "$SUT" "$m" "$expr" 2>/dev/null; then no "teeth $name: could not build mutant"; return; fi
    mo="$(PATH="$TMP/shim:$PATH" timeout 30 bash "$m" --cwd "$TMP/malformed" --base-ref base 2>&1)"; mrc=$?
    if [ "$mrc" != 2 ]; then ok "teeth $name: mutant flips the assertion (rc=$mrc)"; else no "teeth $name: mutant still exits 2 — THEATER"; fi; }
  shimtooth malformed-check 's/NF > 0 { bad = 1 }/NF > 0 { bad = 0 }/'
  tooth bad-ref-exit 's/exit 2 # BADREF/exit 0 # BADREF/' 2 "no-such-ref" "$TMP/parents" --base-ref no-such-ref
  tooth max-validation 's/^\[\[ "\$MAX" =~ \^\[1-9\]\[0-9\]\*\$ \]\] || /true || /' 2 "max-lines" "$TMP/parents" --base-ref base --max-lines abc
fi

echo "== plan-review-slices: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
