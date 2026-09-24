#!/usr/bin/env bash
# stage-retro.sh — stage ONE pending §18 retro as a branch in the kit repo for supervised
# review (METHODOLOGY §18). The SUPERVISOR (not the target run) runs this: it isolates each
# proposal on its own branch so conflicts, duplication, and necessity are judged before merge.
#
# It does the GIT PLUMBING only — creating the branch and printing the deltas + next steps.
# Applying the deltas is the supervisor's judgment (editing kit prose), never mechanical.
#
# Usage: research-sdd/toolbelt/stage-retro.sh <path-to-target/retros/<retro>.md>

set -uo pipefail
retro="${1:-}"
if [ -z "$retro" ] || [ ! -f "$retro" ]; then
  echo "usage: stage-retro.sh <path-to-retro.md>" >&2
  exit 1
fi

# Kit repo root = two dirs up from toolbelt/. `cd -P` resolves PHYSICALLY, following any
# symlink in the path — plain `cd` (no -P) tracks the LOGICAL path instead, so when toolbelt/
# itself is a symlink (e.g. the profile installer's
# <config_root>/research-sdd/profile/<name>/toolbelt -> <real kit>/research-sdd/toolbelt),
# the trailing `..` components walk back up through the SYMLINK'S location on the logical
# path, not through the real kit tree the symlink points at — landing on the profile
# directory instead of the kit repo root. `pwd` needs no -P here: once `cd -P` has landed in
# the physical directory, $PWD is already the real path.
KIT_REPO="$(cd -P "$(dirname "$0")/../.." && pwd)"

# Shared review-status reader — single source of truth for the marker logic (sweep-retros.sh and
# stage-retro.sh both source it, so the leading-comment-block scan can never drift between them).
# Same symlink hazard as KIT_REPO above — resolve physically.
LIB="$(cd -P "$(dirname "$0")" && pwd)/lib/retro-status.sh"
if [ ! -f "$LIB" ]; then
  echo "stage-retro: cannot find helper $LIB" >&2
  exit 1
fi
# shellcheck source=lib/retro-status.sh
. "$LIB"
# Fail closed: existence of $LIB is not enough — the source must have DEFINED the reader. This
# script does NOT use `set -e`, so a failed/partial/syntax-broken source would otherwise be swallowed
# and the review-status guard below would read an empty status, skip the applied|dismissed gate, and
# perform the DESTRUCTIVE `git checkout -b`. Abort here, before ANY git mutation.
declare -F retro_review_status >/dev/null 2>&1 || { echo "stage-retro: helper $LIB failed to define retro_review_status" >&2; exit 1; }

# Opt-out scope guard: a file carrying '<!-- kit-retro: exclude -->' declares itself NOT a §18 kit
# retro. Staging it would open a kit PR from the wrong scope (e.g. client-feedback retro targeting a
# separate skill). Refuse before any git mutation, consistent with the applied|dismissed refusal.
if retro_is_excluded "$retro"; then
  echo "stage-retro: this file carries '<!-- kit-retro: exclude -->' and is not a §18 kit retro — nothing to stage." >&2
  exit 2
fi

# review-status guard. Honor the marker only in the retro's LEADING HTML-comment block (see
# lib/retro-status.sh) — a marker-shaped string deeper in the body must not gate staging.
status=$(retro_review_status "$retro")
case "$status" in
  applied|dismissed)
    echo "This retro is already '$status' — nothing to stage. (Use --force to re-stage.)" >&2
    [ "${2:-}" = "--force" ] || exit 2 ;;
esac

# Derive target (dir holding retros/) and a slug from the filename.
target_root="$(cd "$(dirname "$(dirname "$retro")")" 2>/dev/null && pwd)" || target_root="$(dirname "$(dirname "$retro")")"
target=$(basename "$target_root")
slug=$(basename "$retro" .md | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-\{2,\}/-/g;s/^-//;s/-$//')
branch="retro/${target}-${slug}"

# TRACEABILITY BACKLINK (Feature #27): build a `Retro:` commit trailer so the kit commit that applies these
# deltas is traceable BACK to the exact source retro (the forward link — the retro's 'applied … · kit <sha>'
# marker — already points kit-ward). Reverse ref = <target>/retros/<file>@<target-sha> (drop '@<sha>' when
# the retro is untracked / git is unavailable). SUGGESTED message only — this script auto-commits nothing.
retro_ref="${target}/retros/$(basename "$retro")"
# Absolutize the retro path before the git log pathspec: `-C "$target_root"` is already absolute, but a
# RELATIVE $retro pathspec is then resolved AGAINST that rebased cwd (not the original cwd), so it can miss
# a genuinely tracked retro and silently drop the '@<sha>' suffix (misreporting it as untracked).
retro_abs="$(cd "$(dirname "$retro")" 2>/dev/null && pwd)/$(basename "$retro")"
retro_sha="$(git -C "$target_root" log -1 --format=%h -- "$retro_abs" 2>/dev/null)"
[ -n "$retro_sha" ] && retro_ref="${retro_ref}@${retro_sha}"

# The kit repo must be clean and on main before we branch.
if [ -n "$(git -C "$KIT_REPO" status --porcelain)" ]; then
  echo "kit repo has uncommitted changes — commit/stash them first, then re-run." >&2
  exit 3
fi

echo ">> staging retro for supervised review"
echo "   retro : $retro"
echo "   target: $target"
echo "   branch: $branch"
echo ""

git -C "$KIT_REPO" checkout -q main || { echo "cannot checkout main" >&2; exit 4; }
git -C "$KIT_REPO" fetch -q origin || { echo "degraded: git fetch origin failed — cannot verify remote state; refusing to branch from a possibly stale base." >&2; exit 6; }
# Do NOT pull into the shared checkout's main (CLAUDE.md §3 / §12.4) — the new branch is
# created from origin/main directly below, so local main does not need to advance. This is
# also why there is no "local main must be in sync with origin/main" guard here any more: the
# retro branch never starts from local main (it always branches from origin/main, below), so
# unpushed commits sitting on local main cannot bleed into it.

# Self-referential-target guard: TARGETS.md can list the kit repo itself as a research target
# (its own retros/ dir then lives INSIDE $KIT_REPO). Checking out origin/main below replaces
# the ENTIRE working tree with that ref's content — if this retro was committed only to local
# main (not yet pushed), it is absent from origin/main and vanishes from the worktree the
# instant we check out $branch, before the sed below ever reads it. Catch that BEFORE any
# checkout, not after: refuse and tell the supervisor to push it first.
case "$retro_abs" in
  "$KIT_REPO"/*)
    _retro_rel_to_kit="${retro_abs#"$KIT_REPO"/}"
    if ! git -C "$KIT_REPO" cat-file -e "origin/main:${_retro_rel_to_kit}" 2>/dev/null; then
      echo "this retro lives inside the kit repo itself ($_retro_rel_to_kit) and is not yet" >&2
      echo "reachable from origin/main — staging would branch from origin/main and the retro" >&2
      echo "file would vanish from the new branch's working tree. Push it first:" >&2
      echo "    git -C \"$KIT_REPO\" push origin main" >&2
      echo "...then re-run stage-retro.sh." >&2
      exit 7
    fi
    ;;
esac

if git -C "$KIT_REPO" show-ref --quiet "refs/heads/$branch"; then
  echo "branch $branch already exists — checking it out."
  git -C "$KIT_REPO" checkout -q "$branch" \
    || { echo "cannot check out existing branch $branch" >&2; exit 5; }
else
  # --no-track: never set origin/main as upstream (a bare `git push` could otherwise target main).
  git -C "$KIT_REPO" checkout -q --no-track -b "$branch" origin/main \
    || { echo "cannot create branch $branch from origin/main" >&2; exit 5; }
fi

# Defensive re-check: the reachability guard above only protects the NEW-branch-from-
# origin/main path. A pre-existing $branch (the show-ref case above) can predate the retro —
# e.g. a stale branch left over from an earlier, abandoned staging attempt — so checking it
# out can still make $retro vanish from the worktree even though it IS reachable from the
# current origin/main. Catch that here, for either checkout path, rather than printing an
# empty deltas section and a --body-file pointing at a file that no longer exists.
if [ ! -r "$retro" ]; then
  echo "retro file $retro is not readable on branch $branch after checkout — refusing to" >&2
  echo "print stale/empty deltas. If $branch is a stale leftover branch that predates this" >&2
  echo "retro, delete it (git -C \"$KIT_REPO\" branch -D $branch) and re-run." >&2
  exit 8
fi

echo ">> on branch $branch (from origin/main). Proposed deltas to review/apply:"
echo ""
# Both sed ranges use '^## ' (any level-2 heading) as the end address rather than a specific
# section title. This bounds the output even when a section is renamed or reordered — if the
# named end heading is absent, a specific-title range floods to EOF. The generic pattern
# terminates at whatever heading follows, and sed '$d' still removes that closing heading line
# so the output for a well-formed retro is identical to the specific-title approach.
sed -n '/^## Proposed kit deltas/,/^## /p' "$retro" | sed '$d'
echo ""
sed -n '/^## Tools built, adapted, or outgrown/,/^## /p' "$retro" | sed '$d'
echo ""
echo ">> NEXT STEPS (supervisor):"
echo "   1. Apply the ACCEPTED deltas to the kit files on THIS branch (skip duplicates/unneeded ones)."
echo "   2. git -C \"$KIT_REPO\" add -A && git -C \"$KIT_REPO\" commit -m 'feat(kit): apply retro deltas from $target ($slug)' -m 'Retro: $retro_ref'"
echo "   3. VALIDATE BEFORE MERGE (mandatory — the applier must NOT self-approve): launch an INDEPENDENT"
echo "      fresh-context reviewer over the applied deltas. It verifies each as FAITHFUL / DRIFT /"
echo "      HALLUCINATION / MISSING / DUPLICATE against this retro's proposed-deltas table + current kit"
echo "      state. Fix any DRIFT/hallucination on the branch first; only a clean review earns the merge."
echo "   4. gh -R \"\$(git -C \"$KIT_REPO\" remote get-url origin)\" pr create --fill --base main --head $branch \\"
echo "        --title 'retro: $target $slug' --body-file \"$retro\""
echo "   5. Review the PR (conflicts vs main, dup vs other open retro PRs, necessity). Merge = applied, close = dismissed."
echo "   6. Mark the source retro: set '<!-- review-status: applied <date> · kit <sha> -->' (or dismissed) at its top."
echo "   7. Clean up the staging branch and the review transaction:"
echo "      After the PR is merged or closed:"
echo "        git -C \"\$KIT_REPO\" branch -d $branch"
echo "        git push origin --delete $branch   (if the remote branch still exists)"
echo "      If 'gentle-ai review status' returns 'lineage_selection_required', run it first to"
echo "      pick the right lineage, then validate: gentle-ai review validate --gate pre-commit"
echo "      --cwd \"\$KIT_REPO\". Stale .git/gentle-ai/review-transactions/v2/<lineage>/ dirs can"
echo "      be archived once their PR is closed — 36 accumulated because this step was missing."
