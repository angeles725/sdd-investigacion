#!/usr/bin/env bash
# kit-resolve.sh — fail-closed resolution of the research-sdd kit a session may run (kit issue #2334).
#
# The research-sdd launcher (skills/research-sdd/SKILL.md) runs this first and uses its KIT line. A stale
# kit runs old tools silently: on 2026-10-24 the default checkout was 218 commits behind origin/main and
# SessionStart only warned `kit-stale`. Mirrors build-n4-module's scripts/kit-resolve.sh (niagara-tools)
# with three differences: there is no kit-main worktree, so the DEFAULT checkout itself is fast-forwarded;
# a worktree registered inside the checkout is refused; the default checkout must be on `main`.
#
# Usage:
#   kit-resolve.sh [--offline-ok]
#     --offline-ok  when `git fetch origin main` fails, accept the local origin/main (named WARN, the line
#                   says "unfetched", nothing is refreshed); without it an unreachable origin is a refusal.
#
# Candidates, first one that applies wins (a stale winner is refused, never skipped):
#   1. $RESEARCH_SDD_KIT                     — when set it must hold METHODOLOGY.md (else exit 3)
#   2. $HOME/investigacion/sdd-investigacion/research-sdd   (the kit dir of the default checkout)
# KIT= is the kit DIRECTORY (the one holding METHODOLOGY.md, what the launcher's `Kit path:` names), not
# the git top of its checkout.
#
# Success: stdout line 1 is exactly `KIT=<abs path> SHA=<short sha> (origin/main, clean)`; every other
# message goes to stderr. Clean means no TRACKED change: untracked paths never block (a fast-forward that
# would overwrite one is refused by git itself).
# Auto-refresh: when the winner is the default checkout, origin was fetched, the tree is clean and HEAD is
# a strict ancestor of origin/main, it runs `git merge --ff-only origin/main` on main and stderr says
# `kit-resolve: refreshed <old>→<new>`. $RESEARCH_SDD_KIT is never touched (refused when stale).
# Refused, each with a named reason and the exact remedy: dirty, ahead (commits not on origin/main),
# diverged, stale, not a git work tree, no origin/main, origin unreachable, and for the default checkout
# also a branch other than main (or detached) and a worktree registered INSIDE its tree (the clean and
# fast-forward checks there are unsafe).
# Fetch is a plain `git fetch origin main`: a host whose origin is ssh but has no ssh access sets
# `git config --global url.https://github.com/.insteadOf git@github.com:` once.
# Exit: 0 resolved · 2 refused · 3 usage or no candidate
set -uo pipefail

OFFLINE_OK=0
usage_exit() { printf 'usage: kit-resolve.sh [--offline-ok]\n' >&2; exit 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --offline-ok) OFFLINE_OK=1; shift ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage_exit ;;
  esac
done

say() { printf 'kit-resolve: %s\n' "$*" >&2; }
refuse() { say "REFUSED $*"; exit 2; }

command -v git >/dev/null 2>&1 || refuse "no-git: git is not on PATH; the kit's freshness cannot be checked"

DEFAULT_KIT="${HOME:-}/investigacion/sdd-investigacion/research-sdd"

# choose the candidate
KIT="" ; SOURCE=""
if [ -n "${RESEARCH_SDD_KIT:-}" ]; then
  [ -f "$RESEARCH_SDD_KIT/METHODOLOGY.md" ] || { say "RESEARCH_SDD_KIT ($RESEARCH_SDD_KIT) has no METHODOLOGY.md; fix or unset it"; exit 3; }
  KIT="$RESEARCH_SDD_KIT"; SOURCE="env"
elif [ -f "$DEFAULT_KIT/METHODOLOGY.md" ]; then
  KIT="$DEFAULT_KIT"; SOURCE="default"
else
  say "no kit found: tried \$RESEARCH_SDD_KIT (unset), $DEFAULT_KIT"
  exit 3
fi
KIT="$(cd "$KIT" && pwd -P)"

TOP="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)" \
  || refuse "untracked: $KIT is not in a git work tree; its freshness cannot be checked"
TOP="$(cd "$TOP" && pwd -P)"

short() { git -C "$TOP" rev-parse --short=7 "$1"; }

if [ "$SOURCE" = default ]; then
  # a worktree registered under TOP sits inside the tree the clean and ff checks judge
  while IFS= read -r line; do
    wt="${line#worktree }"
    [ "$wt" = "$line" ] && continue
    wt="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
    [ "${wt#"$TOP"/}" != "$wt" ] \
      && refuse "nested worktree: $wt is registered inside $TOP — move it out: git -C $TOP worktree move $wt ${TOP}-worktrees/${wt##*/}"
  done < <(git -C "$TOP" worktree list --porcelain)
  branch="$(git -C "$TOP" symbolic-ref -q --short HEAD)" || branch="(detached at $(short HEAD))"
  [ "$branch" = main ] || refuse "not on main: $TOP is on $branch — git -C $TOP switch main"
  REMEDY="fast-forward: git -C $TOP merge --ff-only origin/main"
  AHEAD_REMEDY="keep the commits on a branch and return main to origin/main: git -C $TOP branch <name> && git -C $TOP reset --keep origin/main"
else
  REMEDY="update $TOP to origin/main, or unset RESEARCH_SDD_KIT to use the default checkout"
  AHEAD_REMEDY="$REMEDY"
fi

FRESH="origin/main"
if ! GIT_TERMINAL_PROMPT=0 git -C "$TOP" fetch -q origin main >/dev/null 2>&1; then
  say "WARN offline: could not fetch origin; freshness unchecked"
  [ "$OFFLINE_OK" -eq 1 ] || refuse "offline: rerun with --offline-ok to accept the local origin/main"
  FRESH="origin/main unfetched"
fi
git -C "$TOP" rev-parse -q --verify origin/main >/dev/null || refuse "no origin/main ref in $TOP"

dirty_count() { git -C "$TOP" status --porcelain --untracked-files=no | wc -l | tr -d ' '; }
behind() { git -C "$TOP" rev-list --count HEAD..origin/main; }
ancestor() { git -C "$TOP" merge-base --is-ancestor HEAD origin/main; }

# auto-refresh: default checkout only, only after a successful fetch, only clean, only a strict fast-forward
if [ "$SOURCE" = default ] && [ "$FRESH" = origin/main ] && [ "$(dirty_count)" -eq 0 ] \
   && [ "$(behind)" -gt 0 ] && ancestor; then
  old="$(short HEAD)"
  git -C "$TOP" merge -q --ff-only origin/main >/dev/null 2>&1 \
    || refuse "refresh failed: git merge --ff-only origin/main refused in $TOP (an untracked path in the way?) — $REMEDY"
  say "refreshed $old→$(short HEAD)"
fi

n_dirty="$(dirty_count)"
[ "$n_dirty" -eq 0 ] \
  || refuse "dirty: $TOP has uncommitted tracked changes ($n_dirty path(s)); commit or stash them first — $REMEDY"
n="$(behind)"
# any candidate: HEAD must be origin/main or behind it — unmerged commits are never served as the kit
if ! ancestor; then
  [ "$n" -eq 0 ] && refuse "ahead: $TOP HEAD $(short HEAD) has commits not on origin/main ($(short origin/main)) — $AHEAD_REMEDY"
  refuse "diverged: $TOP HEAD $(short HEAD) has commits not on origin/main ($(short origin/main)) and is $n commit(s) behind — $AHEAD_REMEDY"
fi
[ "$n" -eq 0 ] || refuse "stale: $TOP is $n commit(s) behind origin/main — $REMEDY"

printf 'KIT=%s SHA=%s (%s, clean)\n' "$KIT" "$(git -C "$TOP" rev-parse --short HEAD)" "$FRESH"
