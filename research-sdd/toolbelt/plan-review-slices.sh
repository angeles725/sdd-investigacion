#!/usr/bin/env bash
# plan-review-slices.sh — plan reviewable slices of merge-base..HEAD (kit issue #1276).
#
# Walks the commits of <merge-base(BASE,HEAD)>..HEAD first-parent, oldest first, counts the authored
# changed lines of each (additions + deletions from `git diff --numstat` against the commit's first
# parent) and greedily groups CONSECUTIVE commits into slices of at most --max-lines, cutting only at
# commit boundaries. A single commit over the budget is never cut: it becomes its own slice, typed
# UNSPLITTABLE. Report-only: it creates no branch, ref or file.
#
# Usage: plan-review-slices.sh [--cwd DIR] [--base-ref REF] [--max-lines N]
#   --cwd        repository to plan (default: current directory)
#   --base-ref   default origin/main
#   --max-lines  positive integer, default 400 (the kit delivery budget / RDD slice_budget)
#
# Output (typed; every state is distinguishable so a zero cannot hide an input that was not looked at):
#   SLICE <k> <first>..<last> commits=<c> lines=<l> [binary=<b>] base=<parent-of-first>
#   SLICE <k> <first>..<last> commits=1 UNSPLITTABLE lines=<l> [binary=<b>] base=<parent-of-first>
#   PLAN: <S> slice(s) commits=<C> lines=<L> max=<N> [binary=<B>]
#   EMPTY-RANGE base=<ref>            nothing between the merge-base and HEAD (that line only)
#   DEGRADED: git not found           git is absent
# <first>/<last> are 12-char shas; `base=` is the first parent of <first>, so the slice is reviewable
# as `--base-ref <base>` with HEAD pinned at <last>. binary= appears only when binary files were
# present: they have no line count, so they are reported and excluded from lines=.
# Generated files are NOT excluded in this version: every non-binary path counts.
# Exit: 0 plan (including UNSPLITTABLE slices and EMPTY-RANGE) · 2 usage / not a repository / bad ref
#       · 3 git missing (DEGRADED).
set -uo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "DEGRADED: git not found — cannot plan slices"
  exit 3
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

USAGE="usage: plan-review-slices.sh [--cwd DIR] [--base-ref REF] [--max-lines N]"
CWD="."; BASE="origin/main"; MAX=400
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)       [ $# -ge 2 ] || { echo "$USAGE"; exit 2; }; CWD="$2"; shift 2 ;;
    --base-ref)  [ $# -ge 2 ] || { echo "$USAGE"; exit 2; }; BASE="$2"; shift 2 ;;
    --max-lines) [ $# -ge 2 ] || { echo "$USAGE"; exit 2; }; MAX="$2"; shift 2 ;;
    *) echo "$USAGE"; exit 2 ;;
  esac
done
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || { echo "plan-review-slices: --max-lines must be a positive integer (got '$MAX')"; exit 2; }
max="$MAX"

[ -d "$CWD" ] || { echo "plan-review-slices: --cwd '$CWD' is not a directory"; exit 2; }
g(){ git -C "$CWD" "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || { echo "plan-review-slices: '$CWD' is not a git repository"; exit 2; }
if ! g rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "plan-review-slices: base ref '$BASE' does not resolve to a commit (pass --base-ref)"
  exit 2 # BADREF
fi
if ! mb="$(g merge-base "$BASE" HEAD 2>/dev/null)" || [ -z "$mb" ]; then
  echo "plan-review-slices: no merge-base between '$BASE' and HEAD (unrelated or shallow history)"
  exit 2
fi
# stderr is deliberately NOT merged into parsed stdout: a git warning must never become a "commit".
if ! commits="$(g rev-list --first-parent --reverse "$mb..HEAD" 2>/dev/null)"; then
  echo "plan-review-slices: git rev-list failed for $mb..HEAD"
  exit 2
fi
if [ -z "$commits" ]; then
  echo "EMPTY-RANGE base=$BASE"
  exit 0
fi

# Slice accumulator.
k=0; s_first=""; s_last=""; s_base=""; s_commits=0; s_lines=0; s_bin=0
t_slices=0; t_commits=0; t_lines=0; t_bin=0

emit_slice(){
  [ "$s_commits" -gt 0 ] || return 0
  k=$((k+1)); t_slices=$((t_slices+1))
  t_commits=$((t_commits+s_commits)); t_lines=$((t_lines+s_lines)); t_bin=$((t_bin+s_bin))
  local tag="" extra=""
  [ "$s_commits" -eq 1 ] && [ "$s_lines" -gt "$max" ] && tag="UNSPLITTABLE "
  [ "$s_bin" -gt 0 ] && extra="$(printf ' binary=%d' "$s_bin")"
  if [ -n "$tag" ]; then
    printf 'SLICE %d %s..%s commits=1 %slines=%d%s base=%s\n' "$k" "$s_first" "$s_last" "$tag" "$s_lines" "$extra" "$s_base"
  else
    printf 'SLICE %d %s..%s commits=%d lines=%d%s base=%s\n' "$k" "$s_first" "$s_last" "$s_commits" "$s_lines" "$extra" "$s_base"
  fi
  s_first=""; s_last=""; s_base=""; s_commits=0; s_lines=0; s_bin=0
}

# measure <commit>: sets short, pshort, cl (authored changed lines) and cb (binary files) for one
# commit, measured against its first parent (the empty tree for a root commit). Exits 2 on a git
# failure or on a numstat row that is neither "<n>\t<n>\t<path>" nor a binary "-\t-\t<path>" row.
measure(){
  local c="$1" parent from ns out
  short="$(g rev-parse --short=12 "$c" 2>/dev/null)" || { echo "plan-review-slices: cannot abbreviate $c"; exit 2; }
  if parent="$(g rev-parse --verify --quiet "$c^1" 2>/dev/null)"; then
    from="$parent"; pshort="$(g rev-parse --short=12 "$parent")"
  else
    from="$(g hash-object -t tree /dev/null)"; pshort="ROOT"
  fi
  ns="$(g diff --numstat "$from" "$c" 2>/dev/null)" || { echo "plan-review-slices: git diff failed for $short"; exit 2; }
  out="$(awk -F'\t' '
    $1 == "-" && $2 == "-" && NF >= 3 { b++; next }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 3 { a += $1 + $2; next }
    NF > 0 { bad = 1 }
    END { if (bad) print "MALFORMED"; else print a + 0, b + 0 }' <<<"$ns")"
  if [ "$out" = MALFORMED ]; then echo "plan-review-slices: malformed numstat row for $short"; exit 2; fi
  read -r cl cb <<<"$out"
}

for c in $commits; do
  measure "$c"
  if [ "$cl" -gt "$max" ]; then
    emit_slice
    s_first="$short"; s_last="$short"; s_base="$pshort"; s_commits=1; s_lines="$cl"; s_bin="$cb"
    emit_slice
  elif [ "$s_commits" -gt 0 ] && [ $((s_lines + cl)) -le "$max" ]; then
    s_last="$short"; s_commits=$((s_commits+1)); s_lines=$((s_lines+cl)); s_bin=$((s_bin+cb))
  else
    emit_slice
    s_first="$short"; s_last="$short"; s_base="$pshort"; s_commits=1; s_lines="$cl"; s_bin="$cb"
  fi
done
emit_slice # FINAL

extra=""
[ "$t_bin" -gt 0 ] && extra="$(printf ' binary=%d' "$t_bin")"
printf 'PLAN: %d slice(s) commits=%d lines=%d max=%d%s\n' "$t_slices" "$t_commits" "$t_lines" "$max" "$extra"
exit 0
