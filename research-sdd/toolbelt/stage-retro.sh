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

# Shared review-status reader — single source of truth for the marker logic (sweep-retros.sh and
# stage-retro.sh both source it, so the leading-comment-block scan can never drift between them).
LIB="$(cd "$(dirname "$0")" && pwd)/lib/retro-status.sh"
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
git -C "$KIT_REPO" fetch -q origin 2>/dev/null || true
git -C "$KIT_REPO" pull -q --ff-only 2>/dev/null || true

# Guard: main must be in sync with origin/main. Un-pushed local commits on main become
# part of this branch's diff, so the PR's squash-merge folds them into the retro commit —
# mixing unrelated history (lesson: PR #1 folded the adversarial-verify commits into the
# niagara retro squash). Push them to main first, or override with ALLOW_UNPUSHED_BASE=1.
unpushed=$(git -C "$KIT_REPO" rev-list --count origin/main..main 2>/dev/null || echo 0)
if [ "${unpushed:-0}" -gt 0 ] && [ "${ALLOW_UNPUSHED_BASE:-}" != "1" ]; then
  echo "main has $unpushed local commit(s) not on origin/main — they would be folded into" >&2
  echo "this retro's PR squash (mixed history). Push them first:" >&2
  echo "    git -C \"$KIT_REPO\" push origin main" >&2
  echo "...or re-run with ALLOW_UNPUSHED_BASE=1 if that base is intentional." >&2
  exit 5
fi

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
echo "   2. git -C \"$KIT_REPO\" add -A && git -C \"$KIT_REPO\" commit -m 'feat(kit): apply retro deltas from $target ($slug)' -m 'Retro: $retro_ref'"
echo "   3. VALIDATE BEFORE MERGE (mandatory — the applier must NOT self-approve): launch an INDEPENDENT"
echo "      fresh-context reviewer over the applied deltas. It verifies each as FAITHFUL / DRIFT /"
echo "      HALLUCINATION / MISSING / DUPLICATE against this retro's proposed-deltas table + current kit"
echo "      state. Fix any DRIFT/hallucination on the branch first; only a clean review earns the merge."
echo "   4. gh -R \"\$(git -C \"$KIT_REPO\" remote get-url origin)\" pr create --fill --base main --head $branch \\"
echo "        --title 'retro: $target $slug' --body-file \"$retro\""
echo "   5. Review the PR (conflicts vs main, dup vs other open retro PRs, necessity). Merge = applied, close = dismissed."
echo "   6. Mark the source retro: set '<!-- review-status: applied <date> · kit <sha> -->' (or dismissed) at its top."
