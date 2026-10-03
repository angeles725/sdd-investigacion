#!/usr/bin/env bash
# resume-state.test.sh — harness for resume-state.sh (kit issue #1274, slice 1).
#
# The tool prints ONE JSON document derived only from git (worktrees, branches, ahead/behind vs a base ref,
# dirty/untracked counts) plus open PRs from gh when available. Cases pin: schema + required fields, the
# worktree/branch partition, ahead/behind arithmetic, dirty vs untracked, prunable (missing) worktrees,
# the PR states (ok / skipped / degraded — never an empty list standing in for "unknown"), usage errors,
# degraded exit 3 on a missing jq/git, and that nothing is written. --prove-teeth builds mutants of the SUT.
#
# Usage: resume-state.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../resume-state.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Throwaway repo: main with 1 commit, pushed to a bare "origin" so origin/main exists.
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkrepo(){ local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q -b main . && echo a > a && git add a && G commit -q -m c1 \
    && git init -q --bare "$d.origin" && git remote add origin "$d.origin" && git push -q origin main \
    && git fetch -q origin ) >/dev/null 2>&1; }

# run <args...>: stdout JSON in OUT, stderr in ERR, rc in RC.
run(){ OUT="$(timeout 30 bash "$SUT" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
jqe(){ jq -r "$1" <<<"$OUT" 2>/dev/null; }
eq(){ local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else no "$label — got [$got] want [$want]"; fi; }

echo "-- resume-state.sh --"
R="$TMP/r"; mkrepo "$R"
( cd "$R" && git worktree add -q -b feat/a "$TMP/wt-a" main \
  && cd "$TMP/wt-a" && echo x > x && git add x && G commit -q -m a1 && echo y > y && git add y && G commit -q -m a2 \
  && echo dirty >> a && echo u1 > u1 && echo u2 > u2 ) >/dev/null 2>&1
( cd "$R" && echo m > m && git add m && G commit -q -m m2 && git push -q origin main && git branch loose main~1 \
  && git branch ahead1 main && git checkout -q ahead1 && echo z > z && git add z && G commit -q -m z1 && git checkout -q main ) >/dev/null 2>&1

# 1. schema + required top-level fields, exit 0, --no-gh
run --cwd "$R" --no-gh
eq "1  exit 0" "$RC" 0
eq "1a schema id" "$(jqe .schema)" "research-sdd.resume-state/v1"
eq "1b required keys present" "$(jqe '[.generated_at,.repo.toplevel,.base_ref,.base_sha,.worktrees,.branches]|map(type)|join(",")')" "string,string,string,string,array,array"
eq "1c base_ref defaults to origin/main" "$(jqe .base_ref)" "origin/main"
eq "1d base_sha is the origin/main sha" "$(jqe .base_sha)" "$(git -C "$R" rev-parse origin/main)"
eq "1e repo.remote is the origin url" "$(jqe .repo.remote)" "$R.origin"

# 2. worktrees: primary + feat/a, dirty vs untracked, ahead/behind
eq "2  two worktrees" "$(jqe '.worktrees|length')" 2
W="$(jqe '.worktrees[]|select(.branch=="feat/a")|[.dirty,.untracked,.ahead,.behind,.exists,.head]|map(tostring)|join(",")')"
eq "2a feat/a dirty=1 untracked=2 ahead=2 behind=1 exists" "${W%,*}" "1,2,2,1,true"
eq "2b feat/a head sha" "${W##*,}" "$(git -C "$TMP/wt-a" rev-parse HEAD)"
eq "2c primary worktree is on main, ahead 0 behind 0" "$(jqe '.worktrees[]|select(.branch=="main")|[.ahead,.behind]|map(tostring)|join(",")')" "0,0"

# 3. branches: only those NOT checked out in a worktree
eq "3  branches exclude worktree branches" "$(jqe '[.branches[].name]|sort|join(",")')" "ahead1,loose"
eq "3a loose is behind 1 ahead 0" "$(jqe '.branches[]|select(.name=="loose")|[.ahead,.behind]|map(tostring)|join(",")')" "0,1"
eq "3b ahead1 is ahead 1 behind 0" "$(jqe '.branches[]|select(.name=="ahead1")|[.ahead,.behind]|map(tostring)|join(",")')" "1,0"

# 4. prunable worktree: directory removed -> exists=false, counts null (not 0)
rm -rf "$TMP/wt-a"
run --cwd "$R" --no-gh
eq "4  removed worktree exists=false" "$(jqe '.worktrees[]|select(.branch=="feat/a")|.exists')" false
eq "4a counts are null, not 0" "$(jqe '.worktrees[]|select(.branch=="feat/a")|[.dirty,.untracked]|map(tostring)|join(",")')" "null,null"
( cd "$R" && git worktree prune ) >/dev/null 2>&1

# 5. prs: skipped / degraded / ok — never [] for unknown
run --cwd "$R" --no-gh
eq "5  --no-gh -> prs null + skipped" "$(jqe '[(.prs|type),.prs_status]|join(",")')" "null,skipped"
STUB="$TMP/stub"; mkdir -p "$STUB/ok" "$STUB/bad" "$STUB/junk" "$STUB/empty"
printf '#!/bin/sh\necho '"'"'[{"number":7,"headRefName":"feat/a","state":"OPEN","url":"https://x/7"}]'"'"'\n' > "$STUB/ok/gh"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$STUB/bad/gh"
printf '#!/bin/sh\necho notjson\n' > "$STUB/junk/gh"
printf '#!/bin/sh\necho "[]"\n' > "$STUB/empty/gh"
chmod +x "$STUB"/*/gh
# A PATH holding only symlinks to the tools the SUT needs (no gh / no jq / no git), built per scenario.
mkpath(){ local d="$1"; shift; mkdir -p "$d"; local t p
  for t in "$@"; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"; done; }
BASE_TOOLS="bash sh env cat date sed awk grep tr sort head mktemp rm timeout dirname basename wc uname"
# shellcheck disable=SC2086
mkpath "$TMP/nogh" git jq $BASE_TOOLS
# shellcheck disable=SC2086
mkpath "$TMP/nojq" git $BASE_TOOLS
# shellcheck disable=SC2086
mkpath "$TMP/nogit" jq $BASE_TOOLS
PATH_ORIG="$PATH"
PATH="$STUB/ok:$PATH_ORIG" run --cwd "$R"
eq "5a gh ok -> prs array with the PR" "$(jqe '[.prs_status,(.prs|length),.prs[0].number,.prs[0].branch]|map(tostring)|join(",")')" "ok,1,7,feat/a"
PATH="$STUB/empty:$PATH_ORIG" run --cwd "$R"
eq "5b gh ok but zero PRs -> [] with status ok" "$(jqe '[.prs_status,(.prs|length)]|map(tostring)|join(",")')" "ok,0"
PATH="$STUB/bad:$PATH_ORIG" run --cwd "$R"
eq "5c gh failing -> prs null, degraded:gh-failed, rc 0" "$(jqe '[(.prs|type),.prs_status]|join(",")')|$RC" "null,degraded:gh-failed|0"
PATH="$STUB/junk:$PATH_ORIG" run --cwd "$R"
eq "5d gh non-JSON -> degraded:gh-bad-json" "$(jqe '[(.prs|type),.prs_status]|join(",")')" "null,degraded:gh-bad-json"
PATH="$TMP/nogh" run --cwd "$R"
eq "5e gh absent -> degraded:gh-missing" "$(jqe '[(.prs|type),.prs_status]|join(",")')" "null,degraded:gh-missing"

# 6. --base-ref
run --cwd "$R" --no-gh --base-ref loose
eq "6  explicit base_ref honoured" "$(jqe '[.base_ref,.base_sha]|join(",")')" "loose,$(git -C "$R" rev-parse loose)"
run --cwd "$R" --no-gh --base-ref no-such-ref
eq "6a bad ref exits 2" "$RC" 2
eq "6b bad ref names the ref and prints no JSON" "$(grep -c 'no-such-ref' <<<"$ERR")|${#OUT}" "1|0"

# 7. usage / not a repo
run --cwd "$TMP/not-a-dir" --no-gh
eq "7  missing dir exits 2" "$RC" 2
mkdir -p "$TMP/plain"; run --cwd "$TMP/plain" --no-gh
eq "7a not a repo exits 2" "$RC" 2
run --bogus
eq "7b unknown flag exits 2" "$RC" 2
run --cwd
eq "7c flag without value exits 2" "$RC" 2

# 8. degraded: jq / git missing -> exit 3 with a typed message, no JSON
PATH="$TMP/nojq" run --cwd "$R" --no-gh
eq "8  jq missing -> rc 3, DEGRADED, empty stdout" "$RC|$(grep -c 'DEGRADED' <<<"$ERR")|${#OUT}" "3|1|0"
PATH="$TMP/nogit" run --cwd "$R" --no-gh
eq "8a git missing -> rc 3, DEGRADED, empty stdout" "$RC|$(grep -c 'DEGRADED' <<<"$ERR")|${#OUT}" "3|1|0"

# 9. read-only: git state identical before/after (refs, worktree list, status)
snap(){ { git -C "$R" for-each-ref; git -C "$R" worktree list --porcelain; git -C "$R" status --porcelain; } | sha1sum; }
b="$(snap)"; run --cwd "$R" --no-gh; a="$(snap)"
eq "9  repo state unchanged by a run" "$a" "$b"

# 10. detached HEAD worktree: branch null, still listed
( cd "$R" && git worktree add -q --detach "$TMP/wt-d" main~1 ) >/dev/null 2>&1
run --cwd "$R" --no-gh
eq "10 detached worktree has branch null" "$(jqe '.worktrees[]|select(.path|endswith("wt-d"))|[(.branch|type),.behind]|map(tostring)|join(",")')" "null,1"

# 11. a base_ref that is a bare sha is accepted
run --cwd "$R" --no-gh --base-ref "$(git -C "$R" rev-parse main~1)"
eq "11 sha base_ref accepted" "$RC" 0

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: resume-state mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$(mktemp -d)"; trap 'rm -rf "$TMP" "$MUT"' EXIT
  # A prunable worktree (directory gone, not pruned) so the exists=false path has a witness.
  ( cd "$R" && git worktree add -q -b feat/p "$TMP/wt-p" main ) >/dev/null 2>&1; rm -rf "$TMP/wt-p"
  echo untracked > "$TMP/wt-d/only-untracked"   # untracked-only worktree: dirty must stay 0
  run --cwd "$R" --no-gh; GOOD="$OUT"
  # tooth <name> <sed-expr> <jq-filter>: the mutant must change the filtered value relative to the good run.
  tooth(){ local name="$1" expr="$2" filt="$3" m="$MUT/$1.sh" mo want
    want="$(jq -r "$filt" <<<"$GOOD" 2>/dev/null)"
    if ! mutant_sed "$SUT" "$m" "$expr" 2>/dev/null; then no "teeth $name: could not build mutant (pattern absent / refused by lib/mutant.sh)"; return; fi
    mo="$(timeout 30 bash "$m" --cwd "$R" --no-gh 2>/dev/null)"
    if [ "$(jq -r "$filt" <<<"$mo" 2>/dev/null)" != "$want" ]; then ok "teeth $name: mutant flips the assertion"
    else no "teeth $name: mutant still satisfies the assertion — THEATER"; fi; }
  tooth swap-ahead-behind 's/--left-right --count "\$base_ref\.\.\.\$ref"/--left-right --count "$ref...$base_ref"/' '[.branches[]|select(.name=="loose")|.behind]|first'
  tooth untracked-as-dirty 's/grep -vc /grep -c /' '[.worktrees[]|select(.path|endswith("wt-d"))|.dirty]|first'
  tooth no-skipped-status 's/"skipped"/"ok"/' '.prs_status'
  tooth keep-worktree-branches 's/is_wt_branch "\$b" && continue/false \&\& continue/' '.branches|length'
  tooth exists-always-true 's/\[ -d "\$wpath" \]/true/' '[.worktrees[]|select(.exists==false)]|length'
  tooth wrong-schema 's#research-sdd.resume-state/v1#research-sdd.resume-state/v0#' '.schema'
fi

echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
