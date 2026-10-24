#!/usr/bin/env bash
# git-driver.sh <question> <dir> [args...]
#
# Runs the git call each instrument makes, copied verbatim from its script, so the Go differential test can
# require the same value and return code from core/git. Prints `rc=<n>` and then the value(s) as `v=<value>`
# lines. Exit 97 is a harness failure (unknown question), never confusable with a git rc.
#   remotes     research-sdd-status.sh remote_visibility_block   mapfile -t of `git -C "$target" remote`
#   url NAME    research-sdd-status.sh remote_visibility_block   `git -C "$target" remote get-url "$_rv_r"`
#   commit REV  merge-gate.sh                                    `git -C "$cwd" rev-parse --verify --quiet "${want_head}^{commit}"`
#   mb A B      merge-gate.sh                                    `git -C "$cwd" merge-base HEAD "$base"` (A is HEAD there)
#   anc A B     merge-gate.sh                                    `git -C "$cwd" merge-base --is-ancestor "$mb" "$pr_mb"`
#   count RNG   merge-gate.sh                                    `git -C "$cwd" rev-list --count "$mb..HEAD"`
q="${1:-}"; d="${2:-}"
shift 2 || { echo "git-driver: usage" >&2; exit 97; }
rc=0
case "$q" in
  remotes) target="$d"; mapfile -t _rv_arr < <(git -C "$target" remote 2>/dev/null)
           echo "rc=0"; for r in ${_rv_arr[@]+"${_rv_arr[@]}"}; do echo "v=$r"; done; exit 0 ;;
  url)     target="$d"; _rv_url="$(git -C "$target" remote get-url "$1" 2>/dev/null)" || rc=$?; v="$_rv_url" ;;
  commit)  cwd="$d"; v="$(git -C "$cwd" rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null)" || rc=$? ;;
  mb)      cwd="$d"; v="$(git -C "$cwd" merge-base "$1" "$2" 2>/dev/null)" || rc=$? ;;
  anc)     cwd="$d"; git -C "$cwd" merge-base --is-ancestor "$1" "$2" 2>/dev/null || rc=$?; v="" ;;
  count)   cwd="$d"; v="$(git -C "$cwd" rev-list --count "$1" 2>/dev/null)" || rc=$? ;;
  *)       echo "git-driver: unknown question $q" >&2; exit 97 ;;
esac
printf 'rc=%s\nv=%s\n' "$rc" "$v"
