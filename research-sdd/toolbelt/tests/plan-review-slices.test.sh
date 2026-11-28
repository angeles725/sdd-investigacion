#!/usr/bin/env bash
# plan-review-slices.test.sh — black-box check of the plan-review-slices.sh compatibility shim (kit issue #1276).
#
# plan-review-slices.sh is a shim over the Go command `rsdd lint review-slices` (kit issue #2270). The behaviour is
# pinned in Go: internal/lint/reviewslices runs the frozen legacy script (testdata/legacy) and the command over ~140
# scenarios (stdout, stderr and exit code byte for byte) and keeps the answers as goldens; its units_test.go carries the
# guards the old mutation controls of this suite proved (table at the head of that file) and `make teeth` mutation-checks
# the package. This suite keeps the end-to-end path through the shim, with real git:
#   empty range, greedy grouping, UNSPLITTABLE, binary typed not counted, base= being a real reviewable parent,
#   every exit code a shell caller sees (2 bad ref / not a repo / bad usage / --max-lines), default base origin/main,
#   a root commit, report-only (no refs, clean tree), arguments with spaces, and the shim run from another directory.
# Moved to Go (the shim cannot run them): 8h git missing -> exit 3 (the shim itself needs dirname on PATH) is the
# scenarios git-missing, git-missing-before-usage and git-missing-before-max-check.
# Removed as duplicates of a Go differential scenario (the Go side is stronger: byte-identical to the legacy script):
#   3 3b 3c 3d boundary-*   4b 4b2 4c 4c2 4d unsplittable-first/last/alone   5 5b deletions-counted, rewrite-counts-both-sides
#   10 merge-first-parent   12 diverged-uses-merge-base   13 13b git-numstat-garbage   15 15b git-parents-lookup-fails
#   16 16b git-empty-tree-fails-on-root
# --prove-teeth mutates the SHIM (the Go behaviour's teeth are the Go tests'): it must dispatch to the sibling command
# and hand over the caller's arguments.
#
# Usage: plan-review-slices.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/plan-review-slices.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
case "${1:-}" in ""|--prove-teeth) ;; *) echo "usage: plan-review-slices.test.sh [--prove-teeth]" >&2; exit 2 ;; esac
[ $# -le 1 ] || { echo "usage: plan-review-slices.test.sh [--prove-teeth]" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth mutant_cleanup_register || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prs-test.XXXXXX")" || exit 2
mutant_cleanup_register "$TMP" || exit 2
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

# The SUT is a compatibility shim over the Go binary: `rsdd lint review-slices`. $RSDD_BIN wins; otherwise one binary is
# built into the suite temp dir (never into the tree). The behaviour's mutation controls live in the Go tests
# (internal/lint/reviewslices, `make teeth`); the controls at the end mutate the shim itself.
if [ -z "${RSDD_BIN:-}" ] || [ ! -x "${RSDD_BIN:-}" ]; then
  if ! command -v go >/dev/null 2>&1; then
    why="go not in PATH"
    [ -z "${RSDD_BIN:-}" ] || why="RSDD_BIN is not an executable file ($RSDD_BIN) and go is not in PATH"
    if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
      echo "  FAIL  rsdd-unavailable: $why (RSDD_REQUIRE_GO=1)"; echo "== 0 passed · 1 failed =="; exit 1
    fi
    echo "SKIP rsdd-unavailable: $why (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
    echo "== 0 passed · 0 failed =="; exit 0
  fi
  RSDD_BIN="$TMP/rsdd"
  ( cd "$TB/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$RSDD_BIN" ./cmd/rsdd ) >"$TMP/build.log" 2>&1 \
    || { echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$TMP/build.log" >&2; exit 2; }
fi
export RSDD_BIN

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

# slice_has <k> <needle>...: the SLICE <k> line must exist and contain every needle (binds needles to ONE line).
slice_has(){ local k="$1" line n; shift; line="$(grep -F -- "SLICE $k " <<<"$OUT" | sed -n 1p)"
  [ -n "$line" ] || return 1; for n in "$@"; do grep -qF -- "$n" <<<"$line" || return 1; done; }
slice_lacks(){ local k="$1" line n; shift; line="$(grep -F -- "SLICE $k " <<<"$OUT" | sed -n 1p)"
  [ -n "$line" ] || return 1; for n in "$@"; do grep -qF -- "$n" <<<"$line" && return 1; done; return 0; }
# mkrepo <dir> : repo with one base commit tagged `base`.
mkrepo(){ local d="$1"; mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main; }
  git -C "$d" config user.email t@t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  printf 'seed\n' > "$d/seed.txt"; git -C "$d" add -A; git -C "$d" commit -q -m base; git -C "$d" tag base; }
# add <dir> <file> <nlines> : commit that creates <file> with <nlines> lines (nlines authored changed lines).
add(){ local d="$1" f="$2" n="$3"; seq 1 "$n" | sed "s/^/${f}-/" > "$d/$f"; git -C "$d" add -A; git -C "$d" commit -q -m "add $f $n"; }

echo "-- plan-review-slices.sh (shim -> rsdd lint review-slices) --"

# 1. EMPTY-RANGE: HEAD == base -> that line only, exit 0.
d="$TMP/empty"; mkrepo "$d"
run --cwd "$d" --base-ref base; expect "1  empty range prints EMPTY-RANGE and exits 0" 0 "EMPTY-RANGE"
lacks "1b empty range prints no SLICE / PLAN line" "SLICE" "PLAN:"

# 2. Greedy grouping: 4 x 150 lines, N=400 -> two slices of two commits.
d="$TMP/greedy"; mkrepo "$d"; for i in 1 2 3 4; do add "$d" "f$i" 150; done
run --cwd "$d" --base-ref base --max-lines 400
expect "2  4x150 at N=400 groups 2+2" 0 "SLICE 1 " "commits=2 lines=300" "SLICE 2 " "PLAN: 2 slice(s) commits=4 lines=600 max=400"
lacks "2b no third slice" "SLICE 3 "

# 4. UNSPLITTABLE in the middle.
d="$TMP/unsp"; mkrepo "$d"; add "$d" a 50; add "$d" big 500; add "$d" c 50
run --cwd "$d" --base-ref base --max-lines 400
expect "4  oversized middle commit: three slices, plan totals" 0 "PLAN: 3 slice(s) commits=3 lines=600 max=400"
slice_has 2 "commits=1 UNSPLITTABLE lines=500" && ok "4a UNSPLITTABLE tag sits on slice 2" || no "4a slice 2 lacks UNSPLITTABLE: $(printf '%s' "$OUT" | tr '\n' '~')"
{ slice_lacks 1 UNSPLITTABLE && slice_lacks 3 UNSPLITTABLE; } && ok "4a2 slices 1 and 3 carry no UNSPLITTABLE tag" || no "4a2 UNSPLITTABLE leaked onto a normal slice"

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

# 8. Exit codes through the shim (8h, git missing, is a Go scenario: see the header).
run --cwd "$d" --base-ref no-such-ref; expect "8  unknown base ref exits 2" 2 "no-such-ref"
run --cwd "$TMP" --base-ref base; expect "8b not a git repository exits 2" 2 "not a git repository"
run --cwd "$TMP/does-not-exist" --base-ref base; expect "8c absent --cwd exits 2" 2 "does-not-exist"
run --cwd "$d" --base-ref base --max-lines 0; expect "8d --max-lines 0 exits 2" 2 "max-lines"
run --cwd "$d" --base-ref base --max-lines abc; expect "8e --max-lines abc exits 2" 2 "max-lines"
run --cwd "$d" --base-ref base --bogus; expect "8f unknown option exits 2" 2 "usage"
run --cwd "$d"; expect "8g default base origin/main absent exits 2 and names it" 2 "origin/main"

# 9. Default base origin/main.
d="$TMP/origin"; mkrepo "$d"; git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse base)"; add "$d" a 120
run --cwd "$d"; expect "9  default base is origin/main, default max is 400" 0 "PLAN: 1 slice(s) commits=1 lines=120 max=400"

# 11. Report-only: refs unchanged.
d="$TMP/refs"; mkrepo "$d"; add "$d" a 10; before="$(git -C "$d" for-each-ref; git -C "$d" status --porcelain)"
run --cwd "$d" --base-ref base; after="$(git -C "$d" for-each-ref; git -C "$d" status --porcelain)"
[ "$before" = "$after" ] && ok "11 run creates no refs and dirties nothing" || no "11 refs/worktree changed by the run"

# 14. Root commit on the first-parent walk (unrelated history merged in): typed base=ROOT, never a guess.
d="$TMP/root"; mkrepo "$d"; add "$d" a 10
git -C "$d" checkout -q --orphan unrelated; git -C "$d" rm -rfq . ; printf 'r\n' > "$d/r.txt"; git -C "$d" add -A; git -C "$d" commit -q -m root
git -C "$d" merge -q --allow-unrelated-histories -m merge main
run --cwd "$d" --base-ref main; expect "14 root commit on the first-parent walk: plan printed" 0 "PLAN:"
rs="$(git -C "$d" rev-parse --short=12 "$(git -C "$d" rev-list --first-parent --max-parents=0 unrelated)")"
slice_has 1 "SLICE 1 $rs.." "base=ROOT" && ok "14b base=ROOT is tied to the slice starting at the root commit" || no "14b base=ROOT not on the slice starting at $rs: $(printf '%s' "$OUT" | tr '\n' '~')"

# 17. What only the shim can break: arguments reach the command intact (a space in --cwd), and the default --cwd is the
# caller's directory, whatever directory the script lives in.
d="$TMP/with space"; mkrepo "$d"; add "$d" a 12
run --cwd "$d" --base-ref base; expect "17  a --cwd with a space reaches the command intact" 0 "PLAN: 1 slice(s) commits=1 lines=12 max=400"
OUT="$(cd "$d" && timeout 30 bash "$SUT" --base-ref base 2>&1)"; RC=$?
expect "17b the default --cwd is the caller's directory" 0 "PLAN: 1 slice(s) commits=1 lines=12 max=400"
OUT="$(cd "$d" && timeout 30 bash "$SUT" --base-ref base 2>&1 >/dev/null)"; RC=$?
[ -z "$OUT" ] && ok "17c a plan prints nothing on stderr" || no "17c stderr was: $OUT"

# --- mutation controls: the SHIM itself (the Go behaviour's controls are the Go tests') ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: the shim must dispatch to rsdd lint review-slices with the caller's arguments --"
  # a mutant of the shim must still find lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
  KC="$TMP/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib"
  cat >"$TMP/runner.sh" <<'EOS'
cd "$1" || exit 99
shift
exec bash "$@"
EOS
  mk() { mutant_chain "$@" || { fail=$((fail + 1)); return 1; }; }
  tt() { if mutant_tooth "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
  # shellcheck disable=SC2016  # the sed expressions are literal text
  {
    mk "s1 dispatch" "$SUT" "$KC/s1.sh" 's/^rsdd_exec lint review-slices /rsdd_exec lint block /' \
      && tt "s1 shim dispatches to the sibling command" 0 2 "$KC/s1.sh" --good-has "lines=40 max=400" --bad-lacks "lines=40 max=400" -- bash "$TMP/runner.sh" "$TMP/bin2" @SUT@ --cwd "$TMP/bin2" --base-ref base
    mk "s2 arguments" "$SUT" "$KC/s2.sh" 's/^rsdd_exec lint review-slices "\$@"$/rsdd_exec lint review-slices/' \
      && tt "s2 shim drops the caller's arguments" 0 2 "$KC/s2.sh" --good-has "lines=40 max=400" --bad-lacks "lines=40 max=400" -- bash "$TMP/runner.sh" "$TMP/bin2" @SUT@ --base-ref base
  }
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
