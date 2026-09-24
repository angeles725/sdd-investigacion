#!/usr/bin/env bash
# stage-retro.test.sh — red-first regression harness for stage-retro.sh, which stages ONE pending
# §18 retro as a branch in the kit repo for supervised review (METHODOLOGY §18). Unlike sweep-retros,
# this script MUTATES a git repo: it runs `git checkout -b retro/<target>-<slug>`. That makes its
# review-status guard SAFETY-CRITICAL — an already-'applied' or 'dismissed' retro must be refused
# BEFORE any branch is created.
#
# WHY THIS SHAPE. The script sources the shared reader lib/retro-status.sh and gates on its output:
# an 'applied'/'dismissed' retro exits 2 (nothing to stage) unless $2 == --force. Existence of the
# helper is NOT enough — the source must have DEFINED retro_review_status. The script does not run
# under `set -e`, so a helper that exists and sources cleanly but defines NO function would leave the
# reader as a 'command not found', the guard would read an empty status, skip the applied|dismissed
# gate, and perform the DESTRUCTIVE `git checkout -b` on a retro that was already resolved (fail-OPEN).
# The post-source `declare -F` guard must instead ABORT non-zero BEFORE any git mutation (fail-CLOSED).
#
# This suite exercises a throwaway COPY of the SUT placed at <sandbox>/research-sdd/toolbelt/ so the
# script's KIT_REPO=dirname/../.. resolves to a HERMETIC git repo we init per case — no touching the
# real kit repo, no network. Each case asserts on `git branch --list 'retro/*'` in that sandbox repo,
# which is the ground truth for "did the destructive path run".
#
# Usage: stage-retro.test.sh                (run the suite)
#        stage-retro.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkrepo <name> <helper-mode> : lay down a hermetic kit git repo at <ROOT>/<name> with a runnable
# COPY of the SUT at research-sdd/toolbelt/ (so KIT_REPO=dirname/../.. resolves inside it) plus the
# shared helper. <helper-mode> = 'real' (copy the genuine helper) | 'broken' (a file that exists and
# sources cleanly but defines NO retro_review_status). Echoes the repo dir. Repo is committed clean
# on branch main so the script's clean-tree/on-main preconditions hold.
mkrepo() {
  local repo="$ROOT/$1" mode="$2"
  mkdir -p "$repo/research-sdd/toolbelt/lib"
  cp "$SUT" "$repo/research-sdd/toolbelt/stage-retro.sh"
  if [ "$mode" = broken ]; then
    printf '#!/usr/bin/env bash\n# broken helper: sources cleanly but defines no retro_review_status\n' \
      > "$repo/research-sdd/toolbelt/lib/retro-status.sh"
  else
    cp "$LIB" "$repo/research-sdd/toolbelt/lib/retro-status.sh"
  fi
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  tester
  # Pin branch.autoSetupMerge so case 10b (and its teeth mutant) do not depend on the host's
  # ambient git config: case 10b asserts the new branch has NO upstream because --no-track was
  # passed; that assertion is only meaningful when a checkout WITHOUT --no-track would otherwise
  # set an upstream. autoSetupMerge's git-wide default is "true" (upstream set on a tracking
  # start-point like origin/main), but a host or CI image can override it globally. Pinning it
  # here makes both case 10b and its teeth mutant deterministic regardless of that ambient value.
  git -C "$repo" config branch.autoSetupMerge true
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  # Set up a local bare remote so git fetch origin succeeds in the fixed SUT.
  local remote="$ROOT/$1-origin.git"
  git init -q --bare -b main "$remote"  # explicit: CI has no init.defaultBranch
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q origin main 2>/dev/null
  printf '%s' "$repo"
}

# mkretro <repo> <target> <filename> <marker-line|-> : write a retro under <repo>/<target>/retros/
# with an optional top marker and a minimal Proposed-kit-deltas section (the block the SUT prints).
# NOTE: written AFTER the init commit so the tree may be dirty; every case commits before running.
mkretro() {
  local repo="$1" tgt="$2" fname="$3" marker="$4"
  mkdir -p "$repo/$tgt/retros"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n'
  } > "$repo/$tgt/retros/$fname"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add retro $fname"
  # Push so the retro is reachable from origin/main: mkrepo places retros/ INSIDE $repo (which
  # doubles as $KIT_REPO in these hermetic fixtures), so the self-referential-target guard
  # (stage-retro.sh: F1) would otherwise refuse every unrelated case that isn't testing it.
  git -C "$repo" push -q origin main 2>/dev/null
}

# mkretro_with_tools <repo> <target> <filename> : like mkretro but includes a tools section
# between anti-patterns and metrics, so the stage-retro tools-range sed finds it.
# NOTE: first column is T1, not 1 — the T-prefix prevents sweep-retros.sh counting tool rows
# as delta rows (both tables start at 1; the delta counter uses sort -un over bare integers).
mkretro_with_tools() {
  local repo="$1" tgt="$2" fname="$3"
  mkdir -p "$repo/$tgt/retros"
  {
    printf '<!-- review-status: pending -->\n'
    printf '# retro\n\n'
    printf '## Proposed kit deltas\n\n'
    printf '| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n'
    printf '## Already covered\n\n(none)\n\n'
    printf '## Anti-patterns observed\n\n(none)\n\n'
    printf '## Tools built, adapted, or outgrown\n\n'
    printf '| # | CREATED (path - purpose) | ADAPTED | OUTGREW | ORACLE | VERDICT |\n'
    printf '|---|---|---|---|---|---|\n'
    printf '| T1 | `tools/t.py` - test tool | - | - | - | `keep-local` - target-specific |\n\n'
    printf '## Metrics\n\n(placeholder)\n'
  } > "$repo/$tgt/retros/$fname"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add retro with tools $fname"
  git -C "$repo" push -q origin main 2>/dev/null
}

# mkretro_tools_noclose <repo> <target> <filename> : retro whose tools section is followed by
# a heading other than '## Metrics'. Used to test Fix 2 (sed range must not flood to EOF when
# the named end heading is absent — it should terminate at the first subsequent ^## heading).
mkretro_tools_noclose() {
  local repo="$1" tgt="$2" fname="$3"
  mkdir -p "$repo/$tgt/retros"
  {
    printf '<!-- review-status: pending -->\n'
    printf '# retro\n\n'
    printf '## Proposed kit deltas\n\n'
    printf '| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | r1 |\n\n'
    printf '## Already covered\n\n(none)\n\n'
    printf '## Tools built, adapted, or outgrown\n\n'
    printf '| # | CREATED | ADAPTED | OUTGREW | ORACLE | VERDICT |\n'
    printf '|---|---|---|---|---|---|\n'
    printf '| T1 | `tools/t.py` - test tool | - | - | - | keep-local |\n\n'
    # The closing section is renamed to something other than '## Metrics'; if the sed range
    # is bound by the specific title '## Metrics', it floods to EOF and the text below leaks.
    # IMPORTANT: the sentinel must NOT be the last line — if it were, sed '$d' in the range
    # pipeline would delete it by accident, making the test a false GREEN (flood but no evidence).
    printf '## Honest verdict\n\n'
    printf 'SENTINEL_THIS_MUST_NOT_APPEAR_IN_STAGE_RETRO_OUTPUT\n'
    printf '(trailing line so sentinel is not last — sed $d only strips this line)\n'
  } > "$repo/$tgt/retros/$fname"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add retro tools-noclose $fname"
  git -C "$repo" push -q origin main 2>/dev/null
}

# branches <repo> : echo the retro/* local branches (empty when the destructive path never ran).
branches() { git -C "$1" branch --list 'retro/*' | tr -d ' *'; }

# run <repo> <retro-relpath> [extra-arg] : invoke the sandbox SUT copy, capture stdout+stderr/RC.
run() {
  local repo="$1" rel="$2"; shift 2
  OUT="$("$BASH_BIN" "$repo/research-sdd/toolbelt/stage-retro.sh" "$repo/$rel" "$@" 2>&1)"; RC=$?
}

echo "== stage-retro.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — HAPPY PATH baseline (real helper, PENDING retro) → the destructive branch IS created. This
#     anchors the suite: proves the sandbox genuinely reaches `git checkout -b` when the gate allows
#     it, so a later "no branch" assertion means the guard REFUSED, not that staging was inert.
repo="$(mkrepo happy real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 0 ] \
   && grep -q 'staging retro for supervised review' <<<"$OUT" \
   && [ "$(branches "$repo")" = "retro/targetA-r1" ]; then
  ok "1 pending retro (real helper) → branch created (destructive path reached)" "(exit $RC)"
else
  no "1 pending retro (real helper) → branch created (destructive path reached)" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 2 — GUARD baseline (real helper, APPLIED retro) → refused with exit 2, NO branch. The genuine
#     review-status gate must keep an already-resolved retro out of staging without mutating git.
repo="$(mkrepo applied real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 2 ] \
   && grep -qi "already 'applied'" <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "2 applied retro (real helper) → refused exit 2, no branch" "(exit $RC)"
else
  no "2 applied retro (real helper) → refused exit 2, no branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 3 — FAIL-CLOSED on a broken helper over the DESTRUCTIVE path (the core contract). Helper EXISTS and
#     sources cleanly but defines NO retro_review_status. The retro is already 'applied'. WITHOUT the
#     post-source `declare -F` guard the reader is 'command not found', status reads empty, the
#     applied|dismissed gate is skipped, and `git checkout -b` runs — staging an already-resolved
#     retro (fail-OPEN on the dangerous path). WITH the guard the script MUST abort non-zero with the
#     helper-error message and create NO branch. This is the assertion the whole suite exists for.
repo="$(mkrepo broken-applied broken)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_review_status' <<<"$OUT" \
   && ! grep -q 'staging retro for supervised review' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "3 broken helper + applied retro → fail-closed, NO retro/* branch" "(exit $RC)"
else
  no "3 broken helper + applied retro → fail-closed, NO retro/* branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 4 — FAIL-CLOSED even for a PENDING retro. The guard is unconditional: a broken helper aborts before
#     ANY staging regardless of the (unreadable) status. So even a retro that WOULD be stageable must
#     be refused non-zero with no branch — the script never proceeds on an undefined reader.
repo="$(mkrepo broken-pending broken)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_review_status' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "4 broken helper + pending retro → fail-closed, NO branch" "(exit $RC)"
else
  no "4 broken helper + pending retro → fail-closed, NO branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 5 — Guard fires BEFORE the missing-file usage error is the only exit. A nonexistent retro path still
#     exits non-zero via the arg check (that check precedes the source), so this case pins that the
#     broken-helper guard does not REGRESS the ordinary usage guard: bad arg → non-zero, no branch.
repo="$(mkrepo broken-badarg broken)"
run "$repo" "targetA/retros/does-not-exist.md"
if [ "$RC" != 0 ] && [ -z "$(branches "$repo")" ]; then
  ok "5 broken helper + missing retro arg → non-zero, no branch" "(exit $RC)"
else
  no "5 broken helper + missing retro arg → non-zero, no branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 6 — TRACEABILITY BACKLINK (Feature #27): the SUGGESTED commit line carries a `Retro:` trailer pointing back
#     to the source retro as <target>/retros/<file>@<target-sha>. The happy-path retro is committed in the
#     sandbox repo, so stage-retro resolves a short sha and prints the full ref. SUGGESTED message only — the
#     script still auto-commits nothing (assert no retro/* branch is required; case 1 already covers staging).
repo="$(mkrepo trailer real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 0 ] && grep -qE 'Retro: targetA/retros/r1\.md@[0-9a-f]+' <<<"$OUT"; then
  ok "6 suggested commit carries Retro: <target>/retros/<file>@<sha> trailer" "(exit $RC)"
else
  no "6 suggested commit carries Retro: <target>/retros/<file>@<sha> trailer" "exit=$RC out=[$OUT]"
fi

# 6b — FIX-2 REGRESSION PIN: the SAME trailer, but invoked with a RELATIVE retro path (relative to the repo
#      root, not target_root). Pre-fix, `git -C "$target_root" log -- "$retro"` re-resolved that relative
#      pathspec AGAINST the rebased -C cwd (target_root), effectively looking for
#      "$target_root/targetA/retros/r1.md" — never matches a genuinely TRACKED retro, so the sha silently
#      comes back empty and the '@<sha>' suffix is dropped (misreported as untracked). Absolutizing the
#      retro path before the git log call fixes it; this must still resolve the sha under a relative arg.
repo="$(mkrepo trailer-relative real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
relOUT="$(cd "$repo" && "$BASH_BIN" "research-sdd/toolbelt/stage-retro.sh" "targetA/retros/r1.md" 2>&1)"; relRC=$?
if [ "$relRC" = 0 ] && grep -qE 'Retro: targetA/retros/r1\.md@[0-9a-f]+' <<<"$relOUT"; then
  ok "6b RELATIVE retro path still resolves the Retro: <sha> trailer (FIX-2 regression pin)" "(exit $relRC)"
else
  no "6b RELATIVE retro path still resolves the Retro: <sha> trailer (FIX-2 regression pin)" "exit=$relRC out=[$relOUT]"
fi

# 7 — EXCLUDED marker → refused exit 2, NO branch. A file carrying '<!-- kit-retro: exclude -->'
#     declares that it is NOT a §18 kit retro. Staging it would open a kit PR proposing changes from
#     the wrong scope (e.g. client-feedback targeting a separate skill's references/). The script must
#     refuse non-zero before any git mutation, mirroring the applied|dismissed refusal pattern.
repo="$(mkrepo excluded real)"
mkretro "$repo" "targetA" "client.md" "<!-- kit-retro: exclude -->"
run "$repo" "targetA/retros/client.md"
if [ "$RC" = 2 ] \
   && grep -qiE 'kit-retro.*exclude|not a.*§18|nothing to stage' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "7 excluded retro → refused exit 2, no branch" "(exit $RC)"
else
  no "7 excluded retro → refused exit 2, no branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 8 — TOOLS TABLE printed: a retro with a tools section must surface that section in stage-retro
#     output alongside the proposed-deltas block so the supervisor reads tool promotions and
#     absorb-verdicts at the same time as kit deltas. Assert on actual TABLE ROW content (a tool
#     path that only appears in a row), not just the heading — so a mutant that prints only the
#     heading still fails this case (the heading check alone has no tooth; see --prove-teeth).
repo="$(mkrepo tools-print real)"
mkretro_with_tools "$repo" "targetA" "r-tools.md"
run "$repo" "targetA/retros/r-tools.md"
if [ "$RC" = 0 ] \
   && grep -q 'Tools built, adapted, or outgrown' <<<"$OUT" \
   && grep -q 'tools/t.py' <<<"$OUT"; then
  ok "8 retro with tools section -> tools table printed in stage-retro output" "(exit $RC)"
else
  no "8 retro with tools section -> tools table printed in stage-retro output" "exit=$RC out=[$OUT]"
fi

# 8b — TOOLS RANGE BOUNDED (Fix 2): a retro whose tools section is followed by a heading other
#      than '## Metrics' must NOT flood stage-retro output to EOF. The sed range must terminate
#      at the first subsequent ^## heading, regardless of its name.
#      RED: current code uses '## Metrics' as the end anchor; a renamed heading causes it to run
#      to EOF, printing the sentinel text. GREEN: generic '^## ' end address bounds it.
repo="$(mkrepo tools-noclose real)"
mkretro_tools_noclose "$repo" "targetA" "r-noclose.md"
run "$repo" "targetA/retros/r-noclose.md"
if [ "$RC" = 0 ] \
   && grep -q 'Tools built, adapted, or outgrown' <<<"$OUT" \
   && ! grep -q 'SENTINEL_THIS_MUST_NOT_APPEAR_IN_STAGE_RETRO_OUTPUT' <<<"$OUT"; then
  ok "8b tools range bounded — renamed end heading does not flood to EOF" "(exit $RC)"
else
  no "8b tools range bounded — renamed end heading does not flood to EOF" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9 — FETCH FAILURE emits typed degraded state and refuses before any branch mutation.
#     A failing `git fetch origin` (bad/unreachable remote) must produce a `degraded:` message on
#     stderr and exit non-zero WITHOUT creating any retro/* branch.  Pre-fix, `|| true` swallowed
#     the failure silently; the script branched from a stale local main.
repo="$(mkrepo fetch-fail real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
git -C "$repo" remote set-url origin "/nonexistent/path/does-not-exist.git"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" -ne 0 ] \
   && grep -q 'degraded:' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "9 fetch fails → degraded exit, no branch created" "(exit $RC)"
else
  no "9 fetch fails → degraded exit, no branch created" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 10 — NEW BRANCH IS BASED ON origin/main, NOT stale local main.
#      When origin/main is ahead of local main (remote has a commit local main lacks), the new
#      branch must start at origin/main — not at the stale local HEAD.  Pre-fix, branching was
#      `checkout -b "$branch"` (from local HEAD); the fix uses `checkout -b "$branch" origin/main`.
repo="$(mkrepo behind-origin real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
# Add a commit to origin via a second clone so remote is ahead of local main.
remote_path="$(git -C "$repo" remote get-url origin)"
tmpclone="$ROOT/behind-origin-extra"
git clone -q "$remote_path" "$tmpclone" 2>/dev/null
git -C "$tmpclone" config user.email t@example.com
git -C "$tmpclone" config user.name  tester
printf 'extra-from-remote\n' > "$tmpclone/extra-from-remote.txt"
git -C "$tmpclone" add extra-from-remote.txt
git -C "$tmpclone" commit -qm "extra remote commit"
git -C "$tmpclone" push -q origin main 2>/dev/null
local_main_sha="$(git -C "$repo" rev-parse main)"
run "$repo" "targetA/retros/r1.md"
origin_main_sha="$(git -C "$repo" rev-parse origin/main 2>/dev/null)"
branch_sha="$(git -C "$repo" rev-parse "retro/targetA-r1" 2>/dev/null)"
if [ "$RC" = 0 ] \
   && [ -n "$branch_sha" ] \
   && [ "$branch_sha" = "$origin_main_sha" ] \
   && [ "$local_main_sha" != "$origin_main_sha" ]; then
  ok "10 local main behind origin → new branch is at origin/main, not stale local main" "(exit $RC)"
else
  no "10 local main behind origin → new branch is at origin/main, not stale local main" \
     "exit=$RC branch=$branch_sha origin=$origin_main_sha local=$local_main_sha out=[$OUT]"
fi
# 10b — the new branch must NOT track origin/main: with push.default=upstream a bare
#       `git push` from the retro branch would otherwise update main on the remote.
upstream10="$(git -C "$repo" rev-parse --abbrev-ref "retro/targetA-r1@{upstream}" 2>/dev/null)"
if [ "$RC" = 0 ] && [ -z "$upstream10" ]; then
  ok "10b new branch has no upstream (does not track origin/main)" "()"
else
  no "10b new branch has no upstream (does not track origin/main)" "exit=$RC upstream=[$upstream10]"
fi

# 11 — CHECKOUT -b FAILURE IS CHECKED (#976): if `git checkout -q --no-track -b "$branch" origin/main`
#      itself fails (e.g. a ref-path collision under refs/heads/), the script must abort with the
#      dedicated "cannot create/checkout the retro branch" exit code (5, RDD round-2 coherence pass)
#      and must NOT print the "on branch ... proposed deltas" banner — that banner would falsely
#      claim the branch was created when it was not. Pre-fix, the unchecked checkout's failure was
#      swallowed (the script has no `set -e`) and execution fell through to print the banner and the
#      full "next steps" regardless of whether the branch actually exists.
repo="$(mkrepo checkoutb-fail real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
# Force `git checkout -b retro/targetA-r1` to fail: pre-create a branch UNDER that exact ref path
# (refs/heads/retro/targetA-r1/blocker) so git's loose-ref directory/file collision fires — git
# cannot create a ref at a path that is already a directory prefix of another ref.
git -C "$repo" branch -q "retro/targetA-r1/blocker"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 5 ] \
   && ! grep -q 'on branch retro/targetA-r1 (from origin/main)' <<<"$OUT" \
   && [ -z "$(git -C "$repo" rev-parse --verify refs/heads/retro/targetA-r1 2>/dev/null)" ]; then
  ok "11 checkout -b failure is checked → exact exit 5, no false 'on branch' banner" "(exit $RC)"
else
  no "11 checkout -b failure is checked → exact exit 5, no false 'on branch' banner" "exit=$RC out=[$OUT]"
fi

# 12 — SYMLINKED TOOLBELT DIR STILL RESOLVES THE REAL KIT REPO. The #1024 profile installer
#      creates <config_root>/research-sdd/profile/<name>/toolbelt as a SYMLINK to the real
#      kit's research-sdd/toolbelt/. KIT_REPO and LIB are derived from `dirname "$0")/../..`
#      (or `/..`): plain `cd` (no -P) tracks bash's LOGICAL $PWD, so the trailing `..` walks
#      back up through the SYMLINK's own location (.../profile) rather than through the real
#      kit tree the symlink points at — landing on the profile dir, which is not a git repo at
#      all. `cd -P` resolves physically, following the symlink, and must land back on the real
#      kit repo regardless of which path the script was invoked through.
repo="$(mkrepo symlink-real real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
_symroot="$ROOT/symlink-profile-root"
mkdir -p "$_symroot/research-sdd/profile/myprofile"
ln -s "$repo/research-sdd/toolbelt" "$_symroot/research-sdd/profile/myprofile/toolbelt"
symOUT="$("$BASH_BIN" "$_symroot/research-sdd/profile/myprofile/toolbelt/stage-retro.sh" \
  "$repo/targetA/retros/r1.md" 2>&1)"; symRC=$?
if [ "$symRC" = 0 ] \
   && grep -q 'staging retro for supervised review' <<<"$symOUT" \
   && [ "$(branches "$repo")" = "retro/targetA-r1" ]; then
  ok "12 invoked through a symlinked toolbelt dir (#1024 profile) still resolves the real kit repo" "(exit $symRC)"
else
  no "12 invoked through a symlinked toolbelt dir (#1024 profile) still resolves the real kit repo" \
     "exit=$symRC branches=[$(branches "$repo")] out=[$symOUT]"
fi

# 13 — SELF-REFERENTIAL TARGET, RETRO UNPUSHED (RDD round 2, F1/HIGH). TARGETS.md row 22
#      (`sdd-investigacion`) is self-referential: the kit repo can research ITSELF, so its own
#      retros/ dir lives INSIDE $KIT_REPO — exactly the shape these hermetic fixtures already
#      use ($repo doubles as both). Reproduced by Opus: with the retro committed only to LOCAL
#      main (never pushed), `checkout -b … origin/main` replaces the whole working tree with
#      origin/main's content, which lacks the retro — it silently vanishes, the sed below reads
#      a now-missing file, and the script printed an empty deltas section at exit 0 with a
#      `--body-file` pointing at a file that no longer exists. Must now refuse (exit 7) BEFORE
#      any checkout, with a message telling the supervisor to push first — and must not have
#      moved off main or created the retro/* branch while refusing.
repo="$(mkrepo selfref-unpushed real)"
mkdir -p "$repo/targetA/retros"
{
  printf '<!-- review-status: pending -->\n'
  printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n'
} > "$repo/targetA/retros/r1.md"
git -C "$repo" add -A
git -C "$repo" commit -qm "add retro r1.md (local main only, deliberately NOT pushed)"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 7 ] \
   && grep -qi 'push' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ] \
   && [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "main" ]; then
  ok "13 self-referential retro unpushed to origin/main → refused exit 7 before any checkout" "(exit $RC)"
else
  no "13 self-referential retro unpushed to origin/main → refused exit 7 before any checkout" \
     "exit=$RC branches=[$(branches "$repo")] head=[$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)] out=[$OUT]"
fi

# 14 — EXISTING-BRANCH CHECKOUT FAILURE IS CHECKED (RDD round 2, F2/MEDIUM — same class as
#      #976's new-branch checkout). Reproduced by Opus: hold `retro/targetA-r1` open in a
#      SEPARATE worktree (git refuses to check out a branch that is already checked out
#      elsewhere), then stage a retro that resolves to that same branch name. Pre-fix, the
#      unchecked `git checkout -q "$branch"` on the "already exists" path failed silently and
#      the script printed the "on branch" banner while still sitting on main. Must abort with
#      the exact "cannot create/checkout the retro branch" code (5) and leave HEAD on main.
repo="$(mkrepo existing-branch-held real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
git -C "$repo" branch -q "retro/targetA-r1" origin/main
_wt14="$ROOT/existing-branch-held-wt"
git -C "$repo" worktree add -q "$_wt14" "retro/targetA-r1"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 5 ] \
   && grep -qi 'cannot check out existing branch' <<<"$OUT" \
   && [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "main" ]; then
  ok "14 existing branch held by another worktree → checkout checked, exact exit 5" "(exit $RC)"
else
  no "14 existing branch held by another worktree → checkout checked, exact exit 5" \
     "exit=$RC head=[$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)] out=[$OUT]"
fi
git -C "$repo" worktree remove -f "$_wt14" 2>/dev/null || true

# 15 — DEFENSIVE READABILITY CHECK CATCHES A STALE PRE-EXISTING BRANCH (RDD round 2, F1
#      follow-through). The F1 reachability guard in case 13 only protects the NEW-branch-
#      from-origin/main path; it checks the retro against the CURRENT origin/main, not against
#      whatever tree a pre-existing $branch happens to hold. Reproduced by Opus: pre-create
#      `retro/targetA-r1` BEFORE the retro exists (a stale leftover from an earlier, abandoned
#      staging attempt), then add+push the retro to main afterwards. F1 passes (the retro IS
#      reachable from the current origin/main); the "branch already exists" path then checks
#      out that STALE branch, whose tree predates the retro — it is genuinely absent from the
#      checked-out worktree even though origin/main has it. Must be caught post-checkout and
#      refused with exit 8, not printed as an empty deltas section. RDD round 3 (R4-exit8-
#      remediation-fails/MEDIUM): the script must also switch back to main before exiting, so
#      the printed `branch -D $branch` remediation does not immediately fail with "cannot
#      delete the branch you are on" — assert that AND that running the actual printed
#      remediation command succeeds.
repo="$(mkrepo stale-branch-predates-retro real)"
git -C "$repo" branch -q "retro/targetA-r1" origin/main
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 8 ] \
   && grep -qi 'not readable' <<<"$OUT" \
   && [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "main" ]; then
  ok "15 stale pre-existing branch predates retro → caught post-checkout, exact exit 8, back on main" "(exit $RC)"
else
  no "15 stale pre-existing branch predates retro → caught post-checkout, exact exit 8, back on main" \
     "exit=$RC head=[$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)] out=[$OUT]"
fi
# 15b — the plain `branch -D $branch` half of the remediation must succeed AS-IS, with no
# extra manual checkout — this is what actually regresses if the script does not switch back:
# git refuses to delete the branch that is currently checked out ("cannot delete branch ...
# used by worktree" / "cannot force-delete the branch you are on"), which is precisely the
# defect. Deliberately does NOT checkout main itself first, unlike the compound advice text.
_remediate_out="$(git -C "$repo" branch -D "retro/targetA-r1" 2>&1)"; _remediate_rc=$?
if [ "$_remediate_rc" = 0 ]; then
  ok "15b plain 'branch -D \$branch' succeeds with no extra manual checkout (script already switched back)"
else
  no "15b plain 'branch -D \$branch' succeeds with no extra manual checkout" "$_remediate_out"
fi

# 16 — SELF-REFERENTIAL TARGET, PUSHED RETRO HAS STALE CONTENT (RDD round 3, R4-selfref-guard-
#      existence-only/HIGH). Reproduced by Opus: push r1.md with OLD content to origin/main.
#      Locally (unpushed) update r1.md to NEW content AND add a second, unrelated retro r2.md
#      in the same commit. The EXISTENCE-only guard (case 13) passes: origin/main DOES have a
#      blob at r1.md's path — just the stale OLD one. Staging then silently proceeds on that
#      OLD content: the printed Retro: trailer and --body-file would point at a version of
#      r1.md the supervisor never reviewed, and r2.md's changes never make it onto the branch
#      at all. Must refuse (exit 7) unless origin/main's blob at that exact path is the SAME
#      blob as HEAD's, not merely present.
repo="$(mkrepo selfref-stale-content real)"
mkdir -p "$repo/targetA/retros"
printf '<!-- review-status: pending -->\n# retro\n\nOLD content.\n' > "$repo/targetA/retros/r1.md"
git -C "$repo" add -A
git -C "$repo" commit -qm "add retro r1.md (OLD)"
git -C "$repo" push -q origin main 2>/dev/null
printf '<!-- review-status: pending -->\n# retro\n\nNEW content.\n' > "$repo/targetA/retros/r1.md"
printf '# retro 2\n' > "$repo/targetA/retros/r2.md"
git -C "$repo" add -A
git -C "$repo" commit -qm "update r1.md to NEW + add r2.md (deliberately NOT pushed)"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 7 ] \
   && [ -z "$(branches "$repo")" ] \
   && [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "main" ]; then
  ok "16 origin/main's retro blob is stale (exists but differs from HEAD) → refused exit 7" "(exit $RC)"
else
  no "16 origin/main's retro blob is stale (exists but differs from HEAD) → refused exit 7" \
     "exit=$RC branches=[$(branches "$repo")] head=[$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)] out=[$OUT]"
fi

# 17 — SYMLINKED RETRO PATH CANNOT SKIP THE SELF-REFERENTIAL GUARD (Opus minor). $KIT_REPO is
#      resolved PHYSICALLY (`cd -P`, #1024 fix). If $retro_abs stayed LOGICAL (plain `pwd`),
#      passing the retro through a symlink that points INTO the kit repo would make retro_abs
#      keep the symlink's own path text instead of the real one — `case "$retro_abs" in
#      "$KIT_REPO"/*)` would then never match, silently SKIPPING the guard case 13/16 exist
#      for, even though the retro genuinely lives inside the kit repo. Reproduced: an unpushed
#      retro reached through a symlinked retros/ dir must still be refused (exit 7), exactly
#      like case 13's direct-path reproduction.
repo="$(mkrepo selfref-symlinked-retro real)"
mkdir -p "$repo/targetA/retros"
printf '<!-- review-status: pending -->\n# retro\n\nOLD content.\n' > "$repo/targetA/retros/r1.md"
git -C "$repo" add -A
git -C "$repo" commit -qm "add retro r1.md (local main only, deliberately NOT pushed)"
_sym17="$ROOT/symlink-to-retros-17"
ln -s "$repo/targetA/retros" "$_sym17"
symOUT17="$("$BASH_BIN" "$repo/research-sdd/toolbelt/stage-retro.sh" "$_sym17/r1.md" 2>&1)"; symRC17=$?
if [ "$symRC17" = 7 ] \
   && [ -z "$(branches "$repo")" ] \
   && [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "main" ]; then
  ok "17 retro reached through a symlinked retros/ dir still hits the self-referential guard" "(exit $symRC17)"
else
  no "17 retro reached through a symlinked retros/ dir still hits the self-referential guard" \
     "exit=$symRC17 branches=[$(branches "$repo")] head=[$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)] out=[$symOUT17]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Case 3 claims the post-source `declare -F` guard is what turns a broken
# helper into a fail-CLOSED abort on the destructive path. Neuter the guard on a throwaway copy so its
# check can never fail (force it always-true), pair it with the broken helper + an APPLIED retro, and
# re-run: with the guard dead the script MUST fall back to the OLD fail-OPEN — it reaches the staging
# banner and CREATES the retro/* branch on an already-resolved retro. If the mutant stayed closed
# (no branch), case 3 would be theater — the guard would not be what protects the destructive path.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the fail-closed guard, expect a broken helper to fail-OPEN and BRANCH --"
  anchor='declare -F retro_review_status >/dev/null 2>&1 || { echo "stage-retro: helper $LIB failed to define retro_review_status" >&2; exit 1; }'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate fail-closed guard" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-guard broken)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"   # replace the sandbox copy with the mutant
    # Neuter the guard to a no-op ':' — a literal replacement with NO '&' (bash 5.1+ expands an
    # unescaped '&' in the replacement to the matched text, which would corrupt the mutant).
    neutered=':'
    printf '%s\n' "${content/"$anchor"/$neutered}" > "$mutant"
    # Overwriting the committed SUT copy dirties the tree; commit it so the script's clean-tree
    # precondition holds and the ONLY thing that can stop staging is the (neutered) guard.
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant
    # Push mutant commit so origin/main stays in sync with local main; the fixed SUT's fetch
    # check and the self-referential-target reachability guard (F1) must not fire before the
    # guard under test runs (mkretro already pushed the retro itself; this push is for the
    # mutant script edit).
    git -C "$repo" push -q origin main 2>/dev/null
    outm="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"
    if grep -q 'staging retro for supervised review' <<<"$outm" \
       && [ "$(branches "$repo")" = "retro/targetA-r1" ]; then
      ok "teeth: guard-neutered mutant fails OPEN and creates retro/* branch" "(case 3 has teeth)"
    else
      no "teeth: guard-neutered mutant fails OPEN and creates retro/* branch" "mutant stayed closed — case 3 is THEATER: branches=[$(branches "$repo")] [$outm]"
    fi
  fi

  # Teeth for case 7: neuter the exclusion guard → excluded file is staged (branch created).
  # Proves case 7 has teeth: the guard is what stops the destructive path, not inertia.
  echo "-- teeth: neuter exclusion guard, expect excluded retro to stage (retro/* branch created) --"
  anchor_e='if retro_is_excluded "$retro"; then'
  if [[ "$content" != *"$anchor_e"* ]]; then
    no "teeth: locate exclusion guard" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-excl real)"
    mkretro "$repo" "targetA" "client.md" "<!-- kit-retro: exclude -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    # Neuter the guard block by replacing 'if retro_is_excluded ...' with a no-op. Inject a
    # SINGLE-LINE no-op that bridges the if..fi; the bash string substitution replaces the anchor
    # (the 'if' line only). The remaining 'exit 2' and 'fi' after it stay, so we need to cancel
    # the whole block. Use 'if false; then' — the body never runs, and the existing fi closes it.
    neutered='if false; then'
    printf '%s\n' "${content/"$anchor_e"/$neutered}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-excl
    git -C "$repo" push -q origin main 2>/dev/null
    outm="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/client.md" 2>&1)"
    if grep -q 'staging retro for supervised review' <<<"$outm" \
       && [ "$(branches "$repo")" = "retro/targetA-client" ]; then
      ok "teeth: excl-guard-neutered mutant stages excluded file (case 7 has teeth)" "()"
    else
      no "teeth: excl-guard-neutered mutant stages excluded file" "mutant stayed closed — case 7 is THEATER: branches=[$(branches "$repo")] [$outm]"
    fi
  fi

  # Teeth for case 8: replace the tools sed range with a print of only the heading — no table
  # rows. Proves the 'tools/t.py' row-content assertion in case 8 is load-bearing: the old
  # heading-only check would PASS the mutant (heading is printed), but the new row-content check
  # catches it (tool path is absent). RED = case 8 fails against the mutant.
  echo "-- teeth: replace tools sed range with heading-only echo, expect case 8 row assertion to fail --"
  # Build the anchor as a concatenation so the literal '$retro' and '$d' strings survive without
  # expansion (same technique as the SUT itself uses for quoting these within single quotes).
  q="'"
  anchor_t8="sed -n ${q}/^## Tools built, adapted, or outgrown/,/^## /p${q} \"\$retro\" | sed ${q}\$d${q}"
  if [[ "$content" != *"$anchor_t8"* ]]; then
    no "teeth: locate tools sed range in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-tools real)"
    mkretro_with_tools "$repo" "targetA" "r-tools.md"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    # Replace the tools sed range with an echo that only prints the heading — no table rows.
    neutered_t8="echo '## Tools built, adapted, or outgrown'"
    printf '%s\n' "${content/"$anchor_t8"/$neutered_t8}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-tools
    git -C "$repo" push -q origin main 2>/dev/null
    outm="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r-tools.md" 2>&1)"
    # The mutant outputs the heading but NOT the table rows. Case 8's row-content assertion
    # ('tools/t.py' must appear) must FAIL — meaning the mutant goes RED on that check.
    if grep -q 'Tools built, adapted, or outgrown' <<<"$outm" \
       && ! grep -q 'tools/t.py' <<<"$outm"; then
      ok "teeth: tools-range mutant prints heading but no rows (case 8 row assertion has teeth)" "()"
    else
      no "teeth: tools-range mutant prints heading but no rows" "row found in mutant output — case 8 row assertion is THEATER: [$outm]"
    fi
  fi

  # Teeth for case 9: neuter the fetch-failure guard → script swallows fetch failure and
  # proceeds (exits 0, no degraded message).  Proves that the guard is what produces the
  # typed degraded exit; without it, the failure is silent and exit is 0.
  # The anchor must span the COMPLETE `|| { ... exit 6; }` clause so the bash substitution
  # replaces the whole compound-command — a short anchor would leave trailing shell syntax.
  echo "-- teeth: neuter fetch-fail guard, expect script to swallow failure and exit 0 --"
  anchor_f='fetch -q origin || { echo "degraded: git fetch origin failed — cannot verify remote state; refusing to branch from a possibly stale base." >&2; exit 6; }'
  if [[ "$content" != *"$anchor_f"* ]]; then
    no "teeth: locate fetch-fail guard in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-fetch-fail real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    neutered_f='fetch -q origin 2>/dev/null || true'
    printf '%s\n' "${content/"$anchor_f"/$neutered_f}" > "$mutant"
    # Commit and PUSH before breaking the remote so origin/main is in sync with local main —
    # the FETCH guard is the one under test, and it must be the first thing to fire.
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-fetch-fail
    git -C "$repo" push -q origin main 2>/dev/null
    # Break the remote AFTER the push so the mutant runs with a failing fetch.
    git -C "$repo" remote set-url origin "/nonexistent/path/does-not-exist.git"
    out_tf="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rc_tf=$?
    # Mutant swallows fetch failure → no degraded msg, exits 0 (last command is echo, not exit 6).
    if [ "$rc_tf" = 0 ] && ! grep -q 'degraded:' <<<"$out_tf"; then
      ok "teeth: fetch-fail guard neutered → exits 0, no degraded msg (case 9 has teeth)" "()"
    else
      no "teeth: fetch-fail guard neutered" \
         "expected exit 0 + no degraded; got exit=$rc_tf out=[$out_tf]"
    fi
  fi

  # Teeth for case 10: remove origin/main from `checkout -b` → branch lands on local main, not
  # origin/main.  Proves the `origin/main` argument is load-bearing; removing it causes the
  # branch to start at local HEAD, which is behind origin/main in the test setup.
  # Setup order: push mutant FIRST so local/origin are in sync, THEN add an extra remote commit
  # via a second clone.  Now origin/main is AHEAD of local main, and the branch lands at local
  # main != origin/main (the mutant's fetch still runs and succeeds; only checkout -b regressed).
  echo "-- teeth: remove origin/main from checkout -b, expect branch at local main not origin --"
  anchor_c='checkout -q --no-track -b "$branch" origin/main'
  if [[ "$content" != *"$anchor_c"* ]]; then
    no "teeth: locate origin/main checkout in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-behind-origin real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    neutered_c='checkout -q --no-track -b "$branch"'
    printf '%s\n' "${content/"$anchor_c"/$neutered_c}" > "$mutant"
    # Push mutant before adding extra remote commit so origin/main == local main at this point.
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-behind-origin
    git -C "$repo" push -q origin main 2>/dev/null
    local_main_sha_t="$(git -C "$repo" rev-parse main)"
    # Now add a commit to origin only via a second clone, making origin/main ahead of local main.
    remote_path_t="$(git -C "$repo" remote get-url origin)"
    tmpclone_t="$ROOT/teeth-behind-origin-extra"
    git clone -q "$remote_path_t" "$tmpclone_t" 2>/dev/null
    git -C "$tmpclone_t" config user.email t@example.com
    git -C "$tmpclone_t" config user.name  tester
    printf 'extra-teeth\n' > "$tmpclone_t/extra-teeth.txt"
    git -C "$tmpclone_t" add extra-teeth.txt
    git -C "$tmpclone_t" commit -qm "extra remote commit for teeth"
    git -C "$tmpclone_t" push -q origin main 2>/dev/null
    # local_main stays at the mutant commit; origin/main is one commit ahead of it.
    "$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" >/dev/null 2>&1
    origin_main_sha_t="$(git -C "$repo" rev-parse origin/main 2>/dev/null)"
    branch_sha_t="$(git -C "$repo" rev-parse --verify "refs/heads/retro/targetA-r1" 2>/dev/null)"
    # Mutant branches from local main (not origin/main); local_main != origin_main in this setup.
    if [ -n "$branch_sha_t" ] \
       && [ "$branch_sha_t" = "$local_main_sha_t" ] \
       && [ "$local_main_sha_t" != "$origin_main_sha_t" ]; then
      ok "teeth: origin/main removed → branch at local main (case 10 has teeth)" "()"
    else
      no "teeth: origin/main removed → branch at local main" \
         "branch=$branch_sha_t local=$local_main_sha_t origin=$origin_main_sha_t"
    fi
  fi

  # Teeth for case 10b: drop --no-track → the branch tracks origin/main → 10b's assertion must fail.
  echo "-- teeth: remove --no-track, expect the new branch to track origin/main --"
  anchor_d='checkout -q --no-track -b "$branch" origin/main'
  if [[ "$content" != *"$anchor_d"* ]]; then
    no "teeth: locate --no-track checkout in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-no-track real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_d"/checkout -q -b \"\$branch\" origin/main}" > "$mutant"
    if cmp -s "$mutant" "$SUT"; then
      no "teeth: --no-track mutant differs from SUT" "mutant identical — substitution did not apply"
    else
      git -C "$repo" add -A; git -C "$repo" commit -qm mutant-no-track
      git -C "$repo" push -q origin main 2>/dev/null
      "$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" >/dev/null 2>&1
      up_t="$(git -C "$repo" rev-parse --abbrev-ref "retro/targetA-r1@{upstream}" 2>/dev/null)"
      if [ "$up_t" = "origin/main" ]; then
        ok "teeth: --no-track removed → branch tracks origin/main (case 10b has teeth)" "()"
      else
        no "teeth: --no-track removed → branch tracks origin/main" "upstream=[$up_t]"
      fi
    fi
  fi

  # Teeth for case 11: drop the `|| { echo …; exit 5; }` clause on the checkout -b call →
  # the same ref-path collision that made case 11's checkout fail must now be swallowed: the
  # script falls through, prints the "on branch ... proposed deltas" banner, and exits 0 —
  # even though no retro/<slug> branch was actually created (checkout -b itself still failed;
  # only the SCRIPT's reaction to that failure changed).
  echo "-- teeth: drop checkout -b error check, expect ref-collision failure to be swallowed --"
  anchor_cb='git -C "$KIT_REPO" checkout -q --no-track -b "$branch" origin/main \
    || { echo "cannot create branch $branch from origin/main" >&2; exit 5; }'
  if [[ "$content" != *"$anchor_cb"* ]]; then
    no "teeth: locate checkout -b error check in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-checkoutb-fail real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    git -C "$repo" branch -q "retro/targetA-r1/blocker"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    neutered_cb='git -C "$KIT_REPO" checkout -q --no-track -b "$branch" origin/main'
    printf '%s\n' "${content/"$anchor_cb"/$neutered_cb}" > "$mutant"
    # Overwriting the committed SUT copy dirties the tree; commit it so the script's clean-tree
    # precondition holds (same pattern as the other mutants above).
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-checkoutb
    git -C "$repo" push -q origin main 2>/dev/null
    out_cb="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rc_cb=$?
    if [ "$rc_cb" = 0 ] && grep -q 'on branch retro/targetA-r1 (from origin/main)' <<<"$out_cb"; then
      ok "teeth: checkout -b error check removed → failure swallowed, false banner printed (case 11 has teeth)" "()"
    else
      no "teeth: checkout -b error check removed → failure swallowed, false banner printed" \
         "expected exit 0 + banner; got exit=$rc_cb out=[$out_cb]"
    fi
  fi

  # Teeth for case 12: drop `-P` from BOTH `cd -P` resolutions → invoked through a symlinked
  # toolbelt dir (the #1024 profile-installer layout), KIT_REPO/LIB resolve to the LOGICAL path
  # (the profile dir) instead of the real kit repo, so the script can no longer find a git repo
  # there at all and must fail — proving `-P` is what makes case 12 work.
  echo "-- teeth: drop -P from both cd resolutions, expect symlinked invocation to fail --"
  anchor_p1='KIT_REPO="$(cd -P "$(dirname "$0")/../.." && pwd)"'
  anchor_p2='LIB="$(cd -P "$(dirname "$0")" && pwd)/lib/retro-status.sh"'
  if [[ "$content" != *"$anchor_p1"* ]] || [[ "$content" != *"$anchor_p2"* ]]; then
    no "teeth: locate -P resolutions in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-symlink real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    neutered_p1='KIT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"'
    neutered_p2='LIB="$(cd "$(dirname "$0")" && pwd)/lib/retro-status.sh"'
    mutated="${content/"$anchor_p1"/$neutered_p1}"
    mutated="${mutated/"$anchor_p2"/$neutered_p2}"
    printf '%s\n' "$mutated" > "$repo/research-sdd/toolbelt/stage-retro.sh"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-nophysical
    git -C "$repo" push -q origin main 2>/dev/null
    _symroot_t="$ROOT/teeth-symlink-profile-root"
    mkdir -p "$_symroot_t/research-sdd/profile/myprofile"
    ln -s "$repo/research-sdd/toolbelt" "$_symroot_t/research-sdd/profile/myprofile/toolbelt"
    outm_sym="$("$BASH_BIN" "$_symroot_t/research-sdd/profile/myprofile/toolbelt/stage-retro.sh" \
      "$repo/targetA/retros/r1.md" 2>&1)"; rcm_sym=$?
    if [ "$rcm_sym" != 0 ] && [ -z "$(branches "$repo")" ]; then
      ok "teeth: -P dropped → symlinked invocation fails to find the real kit repo (case 12 has teeth)" "()"
    else
      no "teeth: -P dropped → symlinked invocation should fail but did not" \
         "exit=$rcm_sym branches=[$(branches "$repo")] out=[$outm_sym]"
    fi
  fi

  # Teeth for case 13: strip the ENTIRE self-referential-target reachability guard (the whole
  # `case "$retro_abs" in ... esac` block) → the unpushed retro is no longer refused BEFORE the
  # checkout. It is still caught by the SEPARATE post-checkout defensive re-check (case 15's
  # guard, deliberately left intact here), but only AFTER the destructive checkout -b already
  # created the branch — proving case 13's specific assertions (exit code 7, and NO branch left
  # behind) depend on the F1 guard specifically, not on the defensive check picking up the slack.
  echo "-- teeth: strip the self-referential reachability guard (F1), expect branch created + wrong exit code --"
  anchor_f1='case "$retro_abs" in
  "$KIT_REPO"/*)
    _retro_rel_to_kit="${retro_abs#"$KIT_REPO"/}"
    _retro_origin_blob="$(git -C "$KIT_REPO" rev-parse -q --verify "origin/main:${_retro_rel_to_kit}" 2>/dev/null)"
    _retro_head_blob="$(git -C "$KIT_REPO" rev-parse -q --verify "HEAD:${_retro_rel_to_kit}" 2>/dev/null)"
    if [ -z "$_retro_origin_blob" ] || [ "$_retro_origin_blob" != "$_retro_head_blob" ]; then
      echo "this retro lives inside the kit repo itself ($_retro_rel_to_kit) and origin/main does" >&2
      echo "not have the SAME content as the local commit — staging would branch from origin/main" >&2
      echo "and silently stage a stale (or entirely missing) version of this file. Push it first:" >&2
      echo "    git -C \"$KIT_REPO\" push origin main" >&2
      echo "...then re-run stage-retro.sh." >&2
      exit 7
    fi
    ;;
esac'
  if [[ "$content" != *"$anchor_f1"* ]]; then
    no "teeth: locate F1 reachability guard in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-selfref-guard real)"
    mkdir -p "$repo/targetA/retros"
    printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n' \
      > "$repo/targetA/retros/r1.md"
    git -C "$repo" add -A; git -C "$repo" commit -qm "add retro (unpushed)"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_f1"/}" > "$mutant"
    # Overwriting the tracked SUT copy dirties the LOCAL-only tree; this is exactly the
    # scenario under test (retro committed but not pushed), so do NOT push this commit.
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-selfref-guard
    outm_f1="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rcm_f1=$?
    if [ "$rcm_f1" != 7 ] && [ -n "$(branches "$repo")" ]; then
      ok "teeth: F1 guard stripped → branch created despite unpushed retro, wrong exit code (case 13 has teeth)" "(exit=$rcm_f1)"
    else
      no "teeth: F1 guard stripped → should have created a branch with a non-7 exit" \
         "exit=$rcm_f1 branches=[$(branches "$repo")] out=[$outm_f1]"
    fi
  fi

  # Teeth for case 16 specifically: revert the F1 guard's blob-EQUALITY check back to the OLD
  # EXISTENCE-only check (RDD R4-selfref-guard-existence-only) — proves case 16's assertion
  # depends on comparing blob shas, not merely on the guard block existing at all (that's the
  # teeth above). With existence-only, origin/main having ANY blob at this path (even a stale
  # one) satisfies the mutant guard, and the stale-content bug must reproduce (exit 0, staged).
  echo "-- teeth: F1 guard reverted to EXISTENCE-only, expect the stale-content bug to reproduce --"
  anchor_eq='if [ -z "$_retro_origin_blob" ] || [ "$_retro_origin_blob" != "$_retro_head_blob" ]; then'
  neutered_eq='if ! git -C "$KIT_REPO" cat-file -e "origin/main:${_retro_rel_to_kit}" 2>/dev/null; then'
  if [[ "$content" != *"$anchor_eq"* ]]; then
    no "teeth: locate F1 blob-equality check in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-selfref-stale-content real)"
    mkdir -p "$repo/targetA/retros"
    printf '<!-- review-status: pending -->\n# retro\n\nOLD content.\n' > "$repo/targetA/retros/r1.md"
    git -C "$repo" add -A; git -C "$repo" commit -qm "add retro r1.md (OLD)"
    git -C "$repo" push -q origin main 2>/dev/null
    printf '<!-- review-status: pending -->\n# retro\n\nNEW content.\n' > "$repo/targetA/retros/r1.md"
    git -C "$repo" add -A; git -C "$repo" commit -qm "update r1.md to NEW (deliberately NOT pushed)"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_eq"/$neutered_eq}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-selfref-existence-only
    outm_eq="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rcm_eq=$?
    if [ "$rcm_eq" = 0 ] && [ -n "$(branches "$repo")" ]; then
      ok "teeth: F1 reverted to existence-only → stale-content bug reproduces (case 16 has teeth)" "(exit=$rcm_eq)"
    else
      no "teeth: F1 reverted to existence-only → should have staged the stale retro at exit 0" \
         "exit=$rcm_eq branches=[$(branches "$repo")] out=[$outm_eq]"
    fi
  fi

  # Teeth for case 17: revert retro_abs's resolution from `cd -P` back to plain `cd` — proves
  # case 17's assertion depends specifically on physical resolution, not just on KIT_REPO being
  # physical. Reuses case 17's own symlinked-retros/ fixture shape.
  echo "-- teeth: retro_abs resolved with plain cd (not -P), expect the symlinked guard bypass to reproduce --"
  anchor_pP='retro_abs="$(cd -P "$(dirname "$retro")" 2>/dev/null && pwd)/$(basename "$retro")"'
  neutered_pP='retro_abs="$(cd "$(dirname "$retro")" 2>/dev/null && pwd)/$(basename "$retro")"'
  if [[ "$content" != *"$anchor_pP"* ]]; then
    no "teeth: locate retro_abs -P resolution in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-selfref-symlinked-retro real)"
    mkdir -p "$repo/targetA/retros"
    printf '<!-- review-status: pending -->\n# retro\n\nOLD content.\n' > "$repo/targetA/retros/r1.md"
    git -C "$repo" add -A; git -C "$repo" commit -qm "add retro r1.md (unpushed)"
    _sym_t17="$ROOT/teeth-symlink-to-retros"
    ln -s "$repo/targetA/retros" "$_sym_t17"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_pP"/$neutered_pP}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-retro-abs-logical
    outm_pP="$("$BASH_BIN" "$mutant" "$_sym_t17/r1.md" 2>&1)"; rcm_pP=$?
    if [ "$rcm_pP" != 7 ] && [ -n "$(branches "$repo")" ]; then
      ok "teeth: retro_abs plain-cd → symlinked guard bypass reproduces (case 17 has teeth)" "(exit=$rcm_pP)"
    else
      no "teeth: retro_abs plain-cd → symlinked guard bypass should have reproduced" \
         "exit=$rcm_pP branches=[$(branches "$repo")] out=[$outm_pP]"
    fi
  fi

  # Teeth for case 14: drop the `|| { …; exit 5; }` clause from the EXISTING-branch checkout
  # (distinct call site from case 11's NEW-branch checkout) → a branch held open by another
  # worktree fails silently, HEAD stays on main, but the script still prints the false
  # "on branch" banner and exits 0.
  echo "-- teeth: drop the existing-branch checkout error check (F2), expect false banner + exit 0 --"
  anchor_f2='git -C "$KIT_REPO" checkout -q "$branch" \
    || { echo "cannot check out existing branch $branch" >&2; exit 5; }'
  if [[ "$content" != *"$anchor_f2"* ]]; then
    no "teeth: locate existing-branch checkout error check in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-existing-branch-held real)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    git -C "$repo" branch -q "retro/targetA-r1" origin/main
    _wt_t14="$ROOT/teeth-existing-branch-held-wt"
    git -C "$repo" worktree add -q "$_wt_t14" "retro/targetA-r1"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    neutered_f2='git -C "$KIT_REPO" checkout -q "$branch"'
    printf '%s\n' "${content/"$anchor_f2"/$neutered_f2}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-existing-branch
    git -C "$repo" push -q origin main 2>/dev/null
    outm_f2="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rcm_f2=$?
    git -C "$repo" worktree remove -f "$_wt_t14" 2>/dev/null || true
    if [ "$rcm_f2" = 0 ] && grep -q 'on branch retro/targetA-r1 (from origin/main)' <<<"$outm_f2"; then
      ok "teeth: existing-branch checkout error check removed → false banner, exit 0 (case 14 has teeth)" "()"
    else
      no "teeth: existing-branch checkout error check removed → should print false banner at exit 0" \
         "exit=$rcm_f2 out=[$outm_f2]"
    fi
  fi

  # Teeth for case 15: drop the post-checkout defensive readability re-check → a stale branch
  # that predates the retro is checked out, the retro silently vanishes, and the script falls
  # through to sed errors + an empty deltas section at exit 0, exactly like the pre-#984 defect.
  echo "-- teeth: drop the post-checkout readability re-check, expect sed errors + exit 0 --"
  anchor_f3='if [ ! -r "$retro" ]; then
  echo "retro file $retro is not readable on branch $branch after checkout — refusing to" >&2
  echo "print stale/empty deltas." >&2
  # Switch back to main before exiting: `git branch -D $branch` refuses to delete the branch
  # that is currently checked out (RDD R4-exit8-remediation-fails), so leaving the repo on
  # $branch would make the remediation advice below fail the moment it is run. Best-effort —
  # print the checkout as part of the advice too, in case this one somehow does not take.
  git -C "$KIT_REPO" checkout -q main 2>/dev/null
  echo "Switched back to main. If $branch is a stale leftover branch that predates this retro," >&2
  echo "delete it: git -C \"$KIT_REPO\" checkout main && git -C \"$KIT_REPO\" branch -D $branch" >&2
  exit 8
fi'
  if [[ "$content" != *"$anchor_f3"* ]]; then
    no "teeth: locate post-checkout readability re-check in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-stale-branch real)"
    git -C "$repo" branch -q "retro/targetA-r1" origin/main
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_f3"/}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-stale-branch
    git -C "$repo" push -q origin main 2>/dev/null
    outm_f3="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"; rcm_f3=$?
    if [ "$rcm_f3" = 0 ] && grep -q "can't read" <<<"$outm_f3"; then
      ok "teeth: post-checkout readability re-check removed → sed errors leak through, exit 0 (case 15 has teeth)" "()"
    else
      no "teeth: post-checkout readability re-check removed → should leak sed errors at exit 0" \
         "exit=$rcm_f3 out=[$outm_f3]"
    fi
  fi

  # Teeth for case 15b (RDD R4-exit8-remediation-fails/MEDIUM): drop ONLY the proactive
  # `checkout -q main` before exit 8, keeping the readability guard itself intact. Proves 15b's
  # assertion depends specifically on the switch-back, not merely on exit 8 firing at all.
  echo "-- teeth: drop the exit-8 checkout-back-to-main, expect 'branch -D' remediation to fail --"
  anchor_swb='  git -C "$KIT_REPO" checkout -q main 2>/dev/null
  echo "Switched back to main. If $branch is a stale leftover branch that predates this retro," >&2'
  neutered_swb='  echo "If $branch is a stale leftover branch that predates this retro," >&2'
  if [[ "$content" != *"$anchor_swb"* ]]; then
    no "teeth: locate exit-8 checkout-back-to-main in SUT" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-exit8-no-switchback real)"
    git -C "$repo" branch -q "retro/targetA-r1" origin/main
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"
    printf '%s\n' "${content/"$anchor_swb"/$neutered_swb}" > "$mutant"
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant-exit8-no-switchback
    git -C "$repo" push -q origin main 2>/dev/null
    "$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" >/dev/null 2>&1
    _swb_branch_d_out="$(git -C "$repo" branch -D "retro/targetA-r1" 2>&1)"; _swb_branch_d_rc=$?
    if [ "$_swb_branch_d_rc" != 0 ]; then
      ok "teeth: exit-8 switch-back removed → 'branch -D' remediation now fails (case 15b has teeth)" "($_swb_branch_d_out)"
    else
      no "teeth: exit-8 switch-back removed → 'branch -D' remediation should have failed but succeeded" \
         "rc=$_swb_branch_d_rc"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
