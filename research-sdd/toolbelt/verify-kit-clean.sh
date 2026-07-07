#!/usr/bin/env bash
# verify-kit-clean.sh — is the Research-SDD KIT repo clean + committed + pushed? (kit-audit Addendum B)
#
# WHY: staging a §18 retro (or starting clean kit work) on a DIRTY tree mixes uncommitted edits into the
# retro branch; UNPUSHED main commits fold into the retro PR's squash (mixed history — the lesson baked into
# stage-retro.sh's inline guard). This is the STANDALONE gate: stage-retro guards inline, and the SessionStart
# hook (verify-kit-clean-hook.sh) surfaces this each session so a dirty kit is noticed before work starts.
#
# Usage: verify-kit-clean.sh [<kit-repo>]     (default: the git repo containing this script)
# Exit: 0 = clean (committed + pushed, or no upstream to push to) · 1 = dirty tree OR unpushed commits ·
#       2 = not a git repo / bad args.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${1:-$here}"
[ -d "$repo" ] || { echo "usage: verify-kit-clean.sh [<kit-repo>]" >&2; exit 2; }
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "verify-kit-clean: not a git repo: $repo" >&2; exit 2; }
branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)"

echo "== verify-kit-clean: $(basename "$root") (branch: ${branch:-?}) =="
rc=0

# 1. Working tree — any staged / unstaged / untracked change makes it DIRTY.
porcelain="$(git -C "$root" status --porcelain 2>/dev/null)"
if [ -n "$porcelain" ]; then
  staged=$(git -C "$root" diff --cached --name-only 2>/dev/null | grep -c . || true)
  unstaged=$(git -C "$root" diff --name-only 2>/dev/null | grep -c . || true)
  untracked=$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)
  echo "   working tree : DIRTY — uncommitted: ${staged} staged · ${unstaged} unstaged · ${untracked} untracked"
  rc=1
else
  echo "   working tree : CLEAN"
fi

# 2. Sync — local commits not on the upstream would fold into a retro PR's squash (mixed history).
# Prefer the configured tracking ref (@{upstream}); if none is set but a remote branch exists (e.g. the repo
# was pushed WITHOUT -u), fall back to origin/<branch> — a commit missing from it is still "unpushed".
upstream="$(git -C "$root" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
if [ -z "$upstream" ] && [ -n "$branch" ] && [ "$branch" != "HEAD" ] \
   && git -C "$root" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
  upstream="origin/$branch"
fi
if [ -n "$upstream" ]; then
  ahead=$(git -C "$root" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ]; then
    echo "   sync         : ${ahead} local commit(s) NOT pushed to ${upstream}"
    rc=1
  else
    echo "   sync         : up to date with ${upstream}"
  fi
else
  echo "   sync         : (no upstream configured for ${branch:-HEAD} — nothing to be un-pushed against)"
fi

if [ "$rc" = 0 ]; then
  echo "   verdict      : clean — safe to stage a retro / start clean kit work"
else
  echo "   verdict      : NOT clean — commit/stash + push before staging a retro (else mixed history)"
fi
echo "== exit $rc =="
exit $rc
