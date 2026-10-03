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
eq "2d clean primary worktree: dirty 0 untracked 0 (empty status is not one line)" "$(jqe '.worktrees[]|select(.branch=="main")|[.dirty,.untracked]|map(tostring)|join(",")')" "0,0"

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

# 9. read-only: git state identical before/after. The snapshot covers refs, worktree list, status AND the
# content hash of every file under .git, so a stray write (index, config, marker file) is visible too.
snap(){ export GIT_OPTIONAL_LOCKS=0   # the snapshot itself must not refresh indexes it is hashing
  { git -C "$R" for-each-ref; git -C "$R" worktree list --porcelain; git -C "$R" status --porcelain
    ( cd "$R/.git" && find . -type f -print0 | sort -z | xargs -0 sha1sum ); } | sha1sum; }
b="$(snap)"; run --cwd "$R" --no-gh; a="$(snap)"
eq "9  repo state unchanged by a run" "$a" "$b"
: > "$R/.git/stray-marker"; s9a="$(snap)"; rm -f "$R/.git/stray-marker"
if [ "$s9a" != "$b" ]; then ok "9a snapshot is not vacuous: a stray .git write changes it"; else no "9a snapshot is blind to a stray .git write"; fi
# 9e. the SUT itself exports GIT_OPTIONAL_LOCKS=0 to every git call (deterministic: a logging git wrapper)
mkdir -p "$TMP/gitlog"; REAL_GIT="$(command -v git)"
printf '#!/bin/sh\necho "${GIT_OPTIONAL_LOCKS-unset}" >> "%s/log"\nexec "%s" "$@"\n' "$TMP/gitlog" "$REAL_GIT" > "$TMP/gitlog/git"
chmod +x "$TMP/gitlog/git"
( unset GIT_OPTIONAL_LOCKS; PATH="$TMP/gitlog:$PATH" bash "$SUT" --cwd "$R" --no-gh >/dev/null 2>&1 )
eq "9e every git call sees GIT_OPTIONAL_LOCKS=0" "$(sort -u "$TMP/gitlog/log" | tr '\n' ,)" "0,"

# 9b. the script is executable in the index and on disk (git mode 100755)
eq "9b resume-state.sh is mode 100755 in git" "$(git -C "$HERE" ls-files -s -- "$SUT" | cut -d' ' -f1)" "100755"
[ -x "$SUT" ] && ok "9c resume-state.sh is executable on disk" || no "9c resume-state.sh is not executable on disk"

# 9d. timeout missing: a typed prs_status, not a misreported gh failure (gh itself is present and healthy)
NT_TOOLS="${BASE_TOOLS/ timeout/}"
# shellcheck disable=SC2086
mkpath "$TMP/notimeout" git jq $NT_TOOLS
cp "$STUB/ok/gh" "$TMP/notimeout/gh"
OUT="$(PATH="$TMP/notimeout" "$(command -v bash)" "$SUT" --cwd "$R" 2>/dev/null)"; RC=$?
eq "9d timeout absent -> degraded:timeout-missing, prs null, rc 0" "$(jqe '[(.prs|type),.prs_status]|join(",")')|$RC" "null,degraded:timeout-missing|0"

# 10. detached HEAD worktree: branch null, still listed
( cd "$R" && git worktree add -q --detach "$TMP/wt-d" main~1 ) >/dev/null 2>&1
run --cwd "$R" --no-gh
eq "10 detached worktree has branch null" "$(jqe '.worktrees[]|select(.path|endswith("wt-d"))|[(.branch|type),.behind]|map(tostring)|join(",")')" "null,1"

# 11. a base_ref that is a bare sha is accepted
run --cwd "$R" --no-gh --base-ref "$(git -C "$R" rev-parse main~1)"
eq "11 sha base_ref accepted" "$RC" 0

# 12. gh: explicit --limit, and a result that hits the limit is flagged truncated (not silently complete)
mkdir -p "$STUB/rec" "$STUB/full"
printf '#!/bin/sh\necho "$@" > "%s"\necho "[]"\n' "$TMP/gh-args" > "$STUB/rec/gh"
printf '#!/bin/sh\njq -nc "[range(1000)|{number:.,headRefName:\\"b\\(.)\\",state:\\"OPEN\\",url:\\"u\\"}]"\n' > "$STUB/full/gh"
chmod +x "$STUB/rec/gh" "$STUB/full/gh"
PATH="$STUB/rec:$PATH_ORIG" run --cwd "$R"
eq "12 gh is called with an explicit --limit 1000" "$(grep -c -- '--limit 1000' "$TMP/gh-args")" 1
eq "12a below the limit prs_truncated is false" "$(jqe .prs_truncated)" false
PATH="$STUB/full:$PATH_ORIG" run --cwd "$R"
eq "12b count == limit -> prs_truncated true, still ok" "$(jqe '[.prs_status,(.prs|length),.prs_truncated]|map(tostring)|join(",")')" "ok,1000,true"
run --cwd "$R" --no-gh
eq "12c prs_truncated is null when prs is unknown" "$(jqe '.prs_truncated|type')" null

# 13. a branch whose short name collides with a tag must not be dropped (full refnames)
( cd "$R" && git branch dup main && git tag dup main ) >/dev/null 2>&1
run --cwd "$R" --no-gh
eq "13 branch named like a tag is listed" "$(jqe '[.branches[]|select(.name=="dup")]|length')" 1
eq "13a its head resolves to the branch commit" "$(jqe '.branches[]|select(.name=="dup")|.head')" "$(git -C "$R" rev-parse refs/heads/dup)"

# 14. option-shaped --base-ref / --cwd never reach git as options
run --cwd "$R" --no-gh --base-ref --help
eq "14 --base-ref with a leading dash exits 2" "$RC|$(grep -c 'base' <<<"$ERR")" "2|1"
run --cwd -x --no-gh
eq "14a --cwd -x is a plain bad directory, exit 2" "$RC" 2

# 15. --help is not an error
run --help
eq "15 --help exits 0 and prints usage on stdout" "$RC|$(grep -c '^usage:' <<<"$OUT")" "0|1"

# 16. large repos: the final document must not travel through argv (ARG_MAX); a small stack ulimit shrinks it
( cd "$R" && for i in $(seq 1 700); do printf 'refs/heads/bulk/%0170d %s\n' "$i" "$(git rev-parse main)"; done \
  | while read -r ref sha; do git update-ref "$ref" "$sha"; done ) >/dev/null 2>&1
OUT="$( ( ulimit -s 256; env -i PATH="$PATH" HOME="$HOME" timeout 120 bash "$SUT" --cwd "$R" --no-gh 2>"$TMP/err" ) )"; RC=$?
eq "16 700 branches under a 256K stack limit: rc 0 and all listed" "$RC|$(jqe '[.branches[]|select(.name|startswith("bulk/"))]|length')" "0|700"
( cd "$R" && git for-each-ref --format='%(refname)' refs/heads/bulk | while read -r ref; do git update-ref -d "$ref"; done ) >/dev/null 2>&1

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: resume-state mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$(mktemp -d)"; trap 'rm -rf "$TMP" "$MUT"' EXIT
  # A prunable worktree (directory gone, not pruned) so the exists=false path has a witness.
  ( cd "$R" && git worktree add -q -b feat/p "$TMP/wt-p" main ) >/dev/null 2>&1; rm -rf "$TMP/wt-p"
  echo untracked > "$TMP/wt-d/only-untracked"   # untracked-only worktree: dirty must stay 0
  # each tooth derives its own good value by running the SUT under the same settings
  # tooth <name> <sed-expr> <jq-filter>: the mutant must change the filtered value relative to the good run.
  # TOOTH_GH=1 runs both sides with the full-count gh stub on PATH instead of --no-gh.
  tooth(){ local name="$1" expr="$2" filt="$3" m="$MUT/$1.sh" mo want gargs="--no-gh" gpath="$PATH"
    [ "${TOOTH_GH:-0}" = 1 ] && { gargs=""; gpath="$STUB/full:$PATH_ORIG"; }
    # shellcheck disable=SC2086
    want="$(PATH="$gpath" timeout 30 bash "$SUT" --cwd "$R" $gargs 2>/dev/null | jq -r "$filt" 2>/dev/null)"
    if ! mutant_sed "$SUT" "$m" "$expr" 2>/dev/null; then no "teeth $name: could not build mutant (pattern absent / refused by lib/mutant.sh)"; return; fi
    # shellcheck disable=SC2086
    mo="$(PATH="$gpath" timeout 30 bash "$m" --cwd "$R" $gargs 2>/dev/null)"
    if [ "$(jq -r "$filt" <<<"$mo" 2>/dev/null)" != "$want" ]; then ok "teeth $name: mutant flips the assertion"
    else no "teeth $name: mutant still satisfies the assertion — THEATER"; fi; }
  tooth swap-ahead-behind 's/--left-right --count "\$base_ref\.\.\.\$ref"/--left-right --count "$ref...$base_ref"/' '[.branches[]|select(.name=="loose")|.behind]|first'
  tooth untracked-as-dirty 's/grep -vc /grep -c /' '[.worktrees[]|select(.path|endswith("wt-d"))|.dirty]|first'
  tooth empty-status-guard 's/if \[ -z "\$st" \]; then dirty=0; untracked=0/if false; then :/' '[.worktrees[]|select(.branch=="main")|.dirty]|first'
  tooth no-skipped-status 's/"skipped"/"ok"/' '.prs_status'
  tooth keep-worktree-branches 's/is_wt_branch "\$b" && continue/false \&\& continue/' '.branches|length'
  tooth exists-always-true 's/\[ -d "\$wpath" \]/true/' '[.worktrees[]|select(.exists==false)]|length'
  TOOTH_GH=1 tooth truncation-flag 's/-ge "\$GH_LIMIT"/-ge 99999/' '.prs_truncated'
  tooth short-refname 's/refname)/refname:short)/' '[.branches[]|select(.name=="dup")]|length'
  # timeout guard: with timeout absent the mutant (guard removed) must report gh-failed instead
  m="$MUT/no-timeout-guard.sh"
  if mutant_sed "$SUT" "$m" 's/elif ! command -v timeout >\/dev\/null 2>&1; then prs_status="degraded:timeout-missing"/elif false; then :/' 2>/dev/null; then
    mo="$(PATH="$TMP/notimeout" "$(command -v bash)" "$m" --cwd "$R" 2>/dev/null | jq -r .prs_status 2>/dev/null)"
    if [ "$mo" != "degraded:timeout-missing" ]; then ok "teeth no-timeout-guard: mutant flips the assertion"; else no "teeth no-timeout-guard: THEATER"; fi
  else no "teeth no-timeout-guard: could not build mutant"; fi
  # read-only: a mutant that writes into .git must change the snapshot used by case 9
  m="$MUT/stray-write.sh"
  if mutant_sed "$SUT" "$m" 's/^remote=\(.*\)$/remote=\1; : > "$top\/.git\/stray-write"/' 2>/dev/null; then
    snap >/dev/null; b="$(snap)"; bash "$m" --cwd "$R" --no-gh >/dev/null 2>&1; a="$(snap)"; rm -f "$R/.git/stray-write"
    if [ "$a" != "$b" ]; then ok "teeth stray-write: snapshot detects a write under .git"; else no "teeth stray-write: snapshot blind — THEATER"; fi
  else no "teeth stray-write: could not build mutant"; fi
  # optional-locks export removed: the logging git wrapper must then see the variable unset
  m="$MUT/no-optional-locks.sh"
  if mutant_sed "$SUT" "$m" 's/^export GIT_OPTIONAL_LOCKS=0$/:/' 2>/dev/null; then
    rm -f "$TMP/gitlog/log"; ( unset GIT_OPTIONAL_LOCKS; PATH="$TMP/gitlog:$PATH" bash "$m" --cwd "$R" --no-gh >/dev/null 2>&1 )
    if [ "$(sort -u "$TMP/gitlog/log" | tr '\n' ,)" != "0," ]; then ok "teeth no-optional-locks: mutant flips the assertion"; else no "teeth no-optional-locks: THEATER"; fi
  else no "teeth no-optional-locks: could not build mutant"; fi
  tooth wrong-schema 's#research-sdd.resume-state/v1#research-sdd.resume-state/v0#' '.schema'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
