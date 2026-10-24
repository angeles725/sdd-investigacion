#!/usr/bin/env bash
# diff-driver.sh <toolbelt-dir> <mode> [args...]
#
# Runs the REAL bash libs of the kit so the Go differential test can require byte-equal output.
#   tpall         lib/target-paths.sh  target_paths_all <targets_md>
#   tppairs       lib/target-paths.sh  target_paths_pairs <targets_md>
#   tnr           lib/target-paths.sh  target_name_for_retro <targets_md> <retro>
#   isdir         reads paths on stdin, prints "<path>\t<1|0>" from the bash `[ -d ]` the sweeps use
#   liststate     lib/state-files.sh   list_state_files <dir>
#   resolvestate  lib/state-files.sh   resolve_state_file [-H] <dir> [--focus <slug>]
#   bff           lib/block-files.sh   block_file_filter [-v] [<prefix>]  (paths on stdin)
#   nwr           lib/block-files.sh   block_files_nested_worktree_roots <root>
#   pinw          lib/block-files.sh   block_files_path_in_nested_worktree <path> <roots>
#
# The function's own return code is the driver's exit code and its stderr is passed through untouched, so the
# caller compares all three channels. Harness failures exit 97 and are never confusable with a function rc
# (tnr uses 1 and 2, resolvestate 1, 2 and 3):
#   - lib file missing, sourcing failed, or the lib did NOT define the function it should (fail closed, the same
#     check every real consumer does), or an unknown mode.
# Nothing here suppresses stderr and nothing is `|| true`.
# RSDD_DRIVER_PIPEFAIL=1 turns `set -o pipefail` on (every real consumer runs with it; the default is off so
# the plain return codes are the function's own).
set -u
[ "${RSDD_DRIVER_PIPEFAIL:-0}" = 1 ] && set -o pipefail
die() { echo "diff-driver: $*" >&2; exit 97; }
tb="${1:-}"; mode="${2:-}"
[ -n "$tb" ] && [ -n "$mode" ] || die "usage: diff-driver.sh <toolbelt-dir> <mode> [args...]"
shift 2
need() { # need <lib file> <function>
  [ -f "$tb/lib/$1" ] || die "lib missing: $tb/lib/$1"
  # shellcheck source=/dev/null
  . "$tb/lib/$1" || die "sourcing $1 failed"
  declare -F "$2" >/dev/null 2>&1 || die "lib $1 failed to define $2"
}
case "$mode" in
  tpall)        need target-paths.sh target_paths_all;        target_paths_all "$@" ;;
  tppairs)      need target-paths.sh target_paths_pairs;      target_paths_pairs "$@" ;;
  tnr)          need target-paths.sh target_name_for_retro;   target_name_for_retro "$@" ;;
  liststate)    need state-files.sh list_state_files;         list_state_files "$@" ;;
  resolvestate) need state-files.sh resolve_state_file;       resolve_state_file "$@" ;;
  bff)          need block-files.sh block_file_filter;        block_file_filter "$@" ;;
  nwr)          need block-files.sh block_files_nested_worktree_roots; block_files_nested_worktree_roots "$@" ;;
  pinw)         need block-files.sh block_files_path_in_nested_worktree; block_files_path_in_nested_worktree "$@" ;;
  isdir)
    while IFS= read -r p || [ -n "$p" ]; do
      if [ -d "$p" ]; then printf '%s\t1\n' "$p"; else printf '%s\t0\n' "$p"; fi
    done ;;
  *) die "unknown mode: $mode" ;;
esac
