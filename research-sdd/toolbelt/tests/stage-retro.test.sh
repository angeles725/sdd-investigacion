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
  # Keep origin/main in sync so the unpushed-commits guard does not fire on unrelated cases.
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
    # Push mutant commit so origin/main stays in sync with local main; the fixed SUT's fetch check
    # and the unpushed-commits guard must not fire before the guard under test runs.
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
    # Commit and PUSH before breaking the remote so origin/main is in sync with local main;
    # the unpushed-commits guard must not fire — the FETCH guard is the one under test.
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
  # via a second clone.  Now origin/main is AHEAD of local main, the unpushed guard stays quiet
  # (local has 0 commits not in origin), and the branch lands at local main != origin/main.
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
    # local_main stays at mutant commit; origin/main is one ahead; unpushed = 0 (local not ahead).
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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
