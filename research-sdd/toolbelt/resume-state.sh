#!/usr/bin/env bash
# resume-state.sh — machine-readable resume state, derived ONLY from git (kit issue #1274, slice 1).
#
# Prints ONE JSON document (schema research-sdd.resume-state/v1, see resume-state.v1.md) to stdout:
# worktrees, branches outside any worktree, ahead/behind vs a base ref, HEAD shas, dirty/untracked counts,
# and open PRs from `gh` when available. Nothing is hand-set and nothing is written (propose-never-apply):
# every git call is read-only. Rendering the prose handoff from this document is slice 2.
#
# Usage: resume-state.sh [--cwd DIR] [--base-ref REF] [--no-gh]
#   --cwd DIR       repository (or any directory inside it) to read; default: the current directory
#   --base-ref REF  ref ahead/behind is measured against; default: origin/main, else main
#   --no-gh         do not call gh; prs is null with prs_status "skipped"
#
# Exit: 0 ok · 2 usage / not a repository / unresolvable ref / runtime failure (git worktree list or mktemp
#       failed — no JSON) · 3 DEGRADED (git or jq missing — no JSON). A missing gh or timeout is NOT an exit:
#       it is reported inside the document as prs_status degraded:gh-missing / degraded:timeout-missing.
#
# Anti-silent-zero (CLAUDE.md §7): a worktree whose directory is gone reports exists=false with null counts
# (not 0); an unknown PR list is prs=null plus a typed prs_status, never an empty array.
set -uo pipefail

usage_text="usage: resume-state.sh [--cwd DIR] [--base-ref REF] [--no-gh]"
usage() { echo "$usage_text" >&2; exit 2; }
GH_LIMIT=1000

cwd="."; base_ref=""; use_gh=1
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) [ $# -ge 2 ] || usage; cwd="$2"; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || usage; base_ref="$2"; shift 2 ;;
    --no-gh) use_gh=0; shift ;;
    -h|--help) echo "$usage_text"; exit 0 ;;
    *) echo "resume-state.sh: unknown argument: $1" >&2; usage ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "DEGRADED: git not found; cannot derive resume state" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "DEGRADED: jq not found; cannot build the JSON document" >&2; exit 3; }

[ -d "$cwd" ] || { echo "resume-state.sh: not a directory: $cwd" >&2; exit 2; }
# Ambient GIT_* variables would redirect every call below to another repository.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || { echo "resume-state.sh: not a git repository: $cwd" >&2; exit 2; }
cd "$top" || exit 2

# An option-shaped ref would be parsed by git as a flag, not a revision.
case "$base_ref" in -*) echo "resume-state.sh: --base-ref must not start with '-': $base_ref" >&2; exit 2 ;; esac
if [ -z "$base_ref" ]; then
  if git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then base_ref="origin/main"
  elif git rev-parse --verify --quiet "main^{commit}" >/dev/null; then base_ref="main"
  else echo "resume-state.sh: no origin/main or main to measure against; pass --base-ref REF" >&2; exit 2; fi
fi
base_sha="$(git rev-parse --verify --quiet "$base_ref^{commit}")" || { echo "resume-state.sh: cannot resolve base ref: $base_ref" >&2; exit 2; }
remote="$(git config --get remote.origin.url 2>/dev/null || true)"

# ab_json <ref> : {"ahead":N,"behind":M} of <ref> relative to base_ref, or nulls when it cannot be counted.
ab_json() {
  local ref="$1" counts behind ahead
  if counts="$(git rev-list --left-right --count "$base_ref...$ref" 2>/dev/null)"; then
    read -r behind ahead <<<"$counts"
    printf '{"ahead":%s,"behind":%s}' "$ahead" "$behind"
  else
    printf '{"ahead":null,"behind":null}'
  fi
}

wt_branches=" "
wt_lines=""
add_worktree() { # path head branch(or empty) prunable(0/1)
  local wpath="$1" whead="$2" wbranch="$3" prunable="$4" exists dirty untracked st ab
  if [ -d "$wpath" ]; then
    exists=true
    if st="$(git --no-optional-locks -C "$wpath" status --porcelain 2>/dev/null)"; then
      # A here-string always appends a newline, so an empty status would reach grep as one blank
      # line and count as dirty=1; a clean worktree is 0/0 by definition.
      if [ -z "$st" ]; then dirty=0; untracked=0
      else dirty="$(grep -vc '^??' <<<"$st")"; untracked="$(grep -c '^??' <<<"$st")"; fi
    else dirty=null; untracked=null; fi
  else exists=false; dirty=null; untracked=null; fi
  if [ -n "$whead" ]; then ab="$(ab_json "$whead")"; else ab='{"ahead":null,"behind":null}'; fi
  [ -n "$wbranch" ] && wt_branches="$wt_branches$wbranch "
  wt_lines="$wt_lines$(jq -nc --arg path "$wpath" --arg head "$whead" --arg branch "$wbranch" \
    --argjson exists "$exists" --argjson dirty "$dirty" --argjson untracked "$untracked" \
    --argjson prunable "$([ "$prunable" = 1 ] && echo true || echo false)" --argjson ab "$ab" \
    '{path:$path, branch:(if $branch=="" then null else $branch end), head:(if $head=="" then null else $head end),
      exists:$exists, prunable:$prunable, dirty:$dirty, untracked:$untracked} + $ab')
"
}

porcelain="$(git worktree list --porcelain 2>/dev/null)" || { echo "resume-state.sh: git worktree list failed" >&2; exit 2; }
wp=""; wh=""; wb=""; wpr=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wp="${line#worktree }"; wh=""; wb=""; wpr=0 ;;
    "HEAD "*) wh="${line#HEAD }" ;;
    "branch "*) wb="${line#branch refs/heads/}" ;;
    "prunable"*) wpr=1 ;;
    "") [ -n "$wp" ] && add_worktree "$wp" "$wh" "$wb" "$wpr"; wp="" ;;
  esac
done <<<"$porcelain"
[ -n "$wp" ] && add_worktree "$wp" "$wh" "$wb" "$wpr"

is_wt_branch() { case "$wt_branches" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

br_lines=""
# Full refnames (not refname:short): a short name can be ambiguous with a tag and resolve elsewhere.
while IFS= read -r fullref; do
  b="${fullref#refs/heads/}"
  [ -n "$b" ] || continue
  is_wt_branch "$b" && continue
  sha="$(git rev-parse --verify --quiet "refs/heads/$b^{commit}")" || continue
  br_lines="$br_lines$(jq -nc --arg name "$b" --arg head "$sha" --argjson ab "$(ab_json "refs/heads/$b")" \
    '{name:$name, head:$head} + $ab')
"
done < <(git for-each-ref --format='%(refname)' refs/heads)

prs_json=null; prs_status="skipped"; prs_truncated=null
if [ "$use_gh" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then prs_status="degraded:gh-missing"
  # Without timeout the gh call would exit 127 and read as a gh failure; name the real cause instead.
  elif ! command -v timeout >/dev/null 2>&1; then prs_status="degraded:timeout-missing"
  else
    raw="$(timeout 30 gh pr list --state open --limit "$GH_LIMIT" --json number,headRefName,state,url 2>/dev/null)"; grc=$?
    if [ "$grc" = 124 ]; then prs_status="degraded:gh-timeout"
    elif [ "$grc" != 0 ]; then prs_status="degraded:gh-failed"
    elif prs_json="$(jq -c 'map({number, branch:.headRefName, state, url})' <<<"$raw" 2>/dev/null)" && [ -n "$prs_json" ]; then
      prs_status="ok"
      # gh silently caps at --limit: a full page means the list may be incomplete.
      if [ "$(jq 'length' <<<"$prs_json")" -ge "$GH_LIMIT" ]; then prs_truncated=true; else prs_truncated=false; fi
    else prs_json=null; prs_status="degraded:gh-bad-json"; fi
  fi
fi

# The sections travel through files (--slurpfile), never argv: a large repo would exceed ARG_MAX.
sect="$(mktemp -d)" || { echo "resume-state.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$sect"' EXIT
printf '%s' "$wt_lines" > "$sect/wt"; printf '%s' "$br_lines" > "$sect/br"; printf '%s' "$prs_json" > "$sect/prs"

jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg top "$top" --arg remote "$remote" \
  --arg base_ref "$base_ref" --arg base_sha "$base_sha" --arg prs_status "$prs_status" --argjson prs_truncated "$prs_truncated" \
  --slurpfile wt "$sect/wt" --slurpfile br "$sect/br" --slurpfile prs "$sect/prs" '
  {schema:"research-sdd.resume-state/v1", generated_at:$generated_at,
   repo:{toplevel:$top, remote:(if $remote=="" then null else $remote end)},
   base_ref:$base_ref, base_sha:$base_sha,
   worktrees:$wt, branches:$br, prs:$prs[0], prs_truncated:$prs_truncated, prs_status:$prs_status}'
