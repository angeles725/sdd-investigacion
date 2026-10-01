#!/usr/bin/env bash
# merge-gate.sh — pre-merge check: never merge a review-due candidate before its review (kit issue #1272).
#
# Reads gentle-ai's OWN answer (`gentle-ai review assess --committed-only --json`) for the range
# <base-ref>..HEAD of a worktree and refuses when `review_due` is true. gentle-ai already folds
# "this exact range was acknowledged" into its answer (`review_due=false`,
# `review_due_reason=already_reviewed`), so this script re-implements none of that logic.
#
# Usage:
#   merge-gate.sh --cwd <repo|worktree> --base-ref <ref> [--head <sha>] [--merge <PR#>]
#
# Typed single stdout line, one per run:
#   merge-gate: allow: <passive|already_reviewed|under_budget> (head=<sha> base=<ref>)   exit 0
#   merge-gate: refuse: review_due (<reason>) ...                                        exit 1
#   merge-gate: refuse: head_mismatch ...                                                exit 1
#   merge-gate: degraded: <why>                                                          exit 3
#   merge-gate: usage: <why>                                                             exit 2
#   merge-gate: merged: PR #N (head=<sha>)                                               exit 0
#
# A broken instrument NEVER allows (CLAUDE.md §7): missing git/jq/gentle-ai, a failing assess, an
# unparseable or off-schema answer, an unknown not-due reason and an unreadable PR head are all
# `degraded` (exit 3), never `allow`.
#
# The default run is a PURE check: no gh call, no review start, no repository write. `--merge N`
# runs `gh pr merge N --squash --match-head-commit <head>` only after an allow and only when the
# PR's current head equals the checked head. Never calls `gentle-ai review start`.
set -uo pipefail

say() { printf 'merge-gate: %s\n' "$*"; }
usage() { say "usage: $*"; echo "usage: merge-gate.sh --cwd <dir> --base-ref <ref> [--head <sha>] [--merge <PR#>]" >&2; exit 2; }
degraded() { say "degraded: $*"; exit 3; }

cwd="" base="" want_head="" pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) [ $# -ge 2 ] || usage "--cwd needs a value"; cwd="$2"; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || usage "--base-ref needs a value"; base="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || usage "--head needs a value"; want_head="$2"; shift 2 ;;
    --merge) [ $# -ge 2 ] || usage "--merge needs a PR number"; pr="$2"; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$cwd" ] || usage "--cwd is required"
[ -n "$base" ] || usage "--base-ref is required"
case "$pr" in ''|*[!0-9]*) [ -z "$pr" ] || usage "--merge needs a numeric PR number, got: $pr" ;; esac

# Probes: every runtime dependency is checked up front (typed degraded, never a silent pass).
command -v git >/dev/null 2>&1 || degraded "git not found on PATH"
command -v jq >/dev/null 2>&1 || degraded "jq not found on PATH"
command -v gentle-ai >/dev/null 2>&1 || degraded "gentle-ai not found on PATH"
if [ -n "$pr" ]; then command -v gh >/dev/null 2>&1 || degraded "gh not found on PATH (needed for --merge)"; fi

git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || degraded "--cwd is not a git repo/worktree: $cwd"
head="$(git -C "$cwd" rev-parse --verify HEAD 2>/dev/null)" || degraded "cannot resolve HEAD in $cwd"
git -C "$cwd" rev-parse --verify --quiet "${base}^{commit}" >/dev/null || degraded "base-ref does not resolve to a commit: $base"

if [ -n "$want_head" ]; then
  want_full="$(git -C "$cwd" rev-parse --verify --quiet "${want_head}^{commit}")" || degraded "--head does not resolve to a commit: $want_head"
  if [ "$want_full" != "$head" ]; then
    say "refuse: head_mismatch (--head $want_full != worktree HEAD $head)"
    exit 1
  fi
fi

# Ask gentle-ai. Capture stdout and the exit status separately; a non-zero assess is degraded
# even when its stdout happens to look like an allow.
err_file="$(mktemp 2>/dev/null)" || degraded "mktemp failed"
trap 'rm -f "$err_file"' EXIT
assess_out="$(gentle-ai review assess --cwd "$cwd" --base-ref "$base" --committed-only --json 2>"$err_file")"
assess_rc=$?
if [ "$assess_rc" -ne 0 ]; then
  # Surface gentle-ai's own first error line (e.g. untracked files need an explicit declaration).
  err_line="$(head -n 1 "$err_file" 2>/dev/null | cut -c1-200)"
  degraded "gentle-ai review assess failed (exit $assess_rc)${err_line:+: $err_line}"
fi

printf '%s' "$assess_out" | jq -e . >/dev/null 2>&1 || degraded "assess output is unparseable JSON"
schema="$(printf '%s' "$assess_out" | jq -r '.schema // empty')"
[ "$schema" = "gentle-ai.review-assessment/v1" ] || degraded "unexpected assess schema: ${schema:-<none>}"
due="$(printf '%s' "$assess_out" | jq -r 'if (.review_due | type) == "boolean" then .review_due else "invalid" end')"
case "$due" in true|false) ;; *) degraded "assess review_due is missing or not a boolean" ;; esac
reason="$(printf '%s' "$assess_out" | jq -r '.review_due_reason // empty')"
[ -n "$reason" ] || degraded "assess review_due_reason is missing"

if [ "$due" = "true" ]; then
  say "refuse: review_due ($reason) (head=$head base=$base) — review this exact head before merging"
  exit 1
fi
case "$reason" in
  passive|already_reviewed|under_budget) ;;
  *) degraded "unknown not-due reason from gentle-ai: $reason (refusing to guess)" ;;
esac
say "allow: $reason (head=$head base=$base)"

[ -n "$pr" ] || exit 0

# --merge: the PR's current head must be the head we just checked, and the merge itself pins it.
pr_head="$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)" || pr_head=""
[ -n "$pr_head" ] || degraded "cannot read PR #$pr head (gh pr view failed)"
if [ "$pr_head" != "$head" ]; then
  say "refuse: head_mismatch (PR #$pr head $pr_head != checked HEAD $head)"
  exit 1
fi
gh pr merge "$pr" --squash --match-head-commit "$head" >/dev/null 2>&1 || degraded "gh pr merge failed for PR #$pr"
say "merged: PR #$pr (head=$head)"
exit 0
