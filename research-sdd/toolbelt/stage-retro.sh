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

# Kit repo root = two dirs up from toolbelt/.
KIT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# review-status guard.
status=$(grep -oiE 'review-status:[[:space:]]*[a-z]+' "$retro" 2>/dev/null \
         | head -1 | sed -E 's/.*:[[:space:]]*//' | tr 'A-Z' 'a-z')
case "$status" in
  applied|dismissed)
    echo "This retro is already '$status' — nothing to stage. (Use --force to re-stage.)" >&2
    [ "${2:-}" = "--force" ] || exit 2 ;;
esac

# Derive target (dir holding retros/) and a slug from the filename.
target=$(basename "$(dirname "$(dirname "$retro")")")
slug=$(basename "$retro" .md | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-\{2,\}/-/g;s/^-//;s/-$//')
branch="retro/${target}-${slug}"

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
git -C "$KIT_REPO" pull -q --ff-only 2>/dev/null || true
if git -C "$KIT_REPO" show-ref --quiet "refs/heads/$branch"; then
  echo "branch $branch already exists — checking it out." ; git -C "$KIT_REPO" checkout -q "$branch"
else
  git -C "$KIT_REPO" checkout -q -b "$branch"
fi

echo ">> on branch $branch (from main). Proposed deltas to review/apply:"
echo ""
sed -n '/^## Proposed kit deltas/,/^## Already covered/p' "$retro" | sed '$d'
echo ""
echo ">> NEXT STEPS (supervisor):"
echo "   1. Apply the ACCEPTED deltas to the kit files on THIS branch (skip duplicates/unneeded ones)."
echo "   2. git -C \"$KIT_REPO\" add -A && git -C \"$KIT_REPO\" commit -m 'feat(kit): apply retro deltas from $target ($slug)'"
echo "   3. gh -R \"\$(git -C \"$KIT_REPO\" remote get-url origin)\" pr create --fill --base main --head $branch \\"
echo "        --title 'retro: $target $slug' --body-file \"$retro\""
echo "   4. Review the PR (conflicts vs main, dup vs other open retro PRs, necessity). Merge = applied, close = dismissed."
echo "   5. Mark the source retro: set '<!-- review-status: applied <date> · kit <sha> -->' (or dismissed) at its top."
