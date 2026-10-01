#!/usr/bin/env bash
# block-files.sh — shared helper: filter a stream of paths to canonical block files.
# Sourced (never executed); consumers MUST fail closed:
#   # shellcheck source=lib/block-files.sh
#   . "$_bflib"
#   declare -F block_file_filter >/dev/null 2>&1 || { echo "<script>: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
#
# block_file_filter [-v] [<focus_prefix>]
#   stdin : one candidate path per line
#   stdout: the lines whose basename is a canonical block file
#   exit  : grep's status VERBATIM — 0 match, 1 no-match, >=2 error (never laundered to 0)
#   -v    : inverse — pass through ONLY paths that are NOT canonical block files
#           (the unclassifiable-candidate form at verify-registry.sh)
#   <focus_prefix>: when given, interpolated as-is into the regex as a prefix anchor
#                   (preserves exact existing behaviour — metachar note: unescaped today, kept so)
#
# THE regex — one definition, replacing 16 hand-rolled copies (U11):
#   no prefix : (^|/)[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$
#   prefix P  : (^|/)P(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$
#
# Anchor: (^|/) unifies 14 sites that used /… with research-sdd-archive.sh:260 that used (^|/)…;
# both are equivalent on find(1) output (path always contains /) and git-log --name-only output
# (filename may be bare). The byte-identical fleet diff in #435 proves this holds on real corpora.
#
# SENTINEL — TOOTH-1: changing this anchor to '^' only breaks discriminator-parity.test.sh
#   (a nested retros/…-block3.md no longer matches without the '/' alternative).
# SENTINEL — TOOTH-2: making the '[^/]+-' prefix optional breaks discriminator-parity.test.sh
#   (the blocked-notes.md and block12.md decoys start matching and inflate counts).

# Idempotent: safe to source more than once (declare -F guard is the authority).
if ! declare -F block_file_filter >/dev/null 2>&1; then

  block_file_filter() {
    local _inv=0 _pfx=""
    if [ "${1:-}" = "-v" ]; then _inv=1; shift; fi
    _pfx="${1:-}"

    # stdin must be a pipe or redirected file — reject interactive invocation.
    if [ -t 0 ]; then
      echo "block-files: cannot read stdin" >&2
      return 2
    fi

    local _re
    if [ -n "$_pfx" ]; then
      # shellcheck disable=SC2064
      _re="(^|/)${_pfx}(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$"
    else
      _re='(^|/)[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'
    fi

    if [ "$_inv" -eq 0 ]; then
      grep -E "$_re"
    else
      grep -vE "$_re"
    fi
  }

fi

# ── Nested worktree exclusion (kit issue #1223) ─────────────────────────────
# A Claude Code agent worktree (<root>/.claude/worktrees/<name>/) or any other nested
# `git worktree add` checkout carries a full copy of the corpus; scanning <root> with find
# therefore lists every block/retro twice. Two helpers let a scanner drop those copies:
#
# block_files_nested_worktree_roots <root>
#   stdout: one absolute directory per line — always "<root>/.claude/worktrees" (excluded whether
#           or not it exists or holds real checkouts) plus the dirname of every nested ".git" FILE
#           whose "gitdir:" target (resolved against the file's directory when relative) is a
#           directory CONTAINING A `commondir` FILE — git writes that file for linked worktrees
#           only — AND whose back-pointer file `<gitdir>/gitdir` names that same ".git" file
#           (same inode; kit issue #1301: commondir alone is forgeable). The gitdir TEXT is never trusted: a submodule of a linked-worktree target has
#           gitdir …/.git/worktrees/<wt>/modules/<name> and a submodule can sit at a path that
#           contains "worktrees", yet neither is a worktree (review of PR #1300, B1).
#           Deliberately NOT excluded: a nested clone (".git" is a directory), a submodule, and a
#           STALE worktree whose gitdir no longer resolves (cannot be proven a worktree, so the
#           probe errs toward counting its files — a false BLOCK is recoverable, a false ALLOW
#           silently skips the retro).
#           The probe follows a symlinked <root> (find -H) and does not descend into
#           <root>/.claude/worktrees (that root is excluded wholesale anyway).
#   exit  : 0 ok · 2 <root> is not a directory · 3 the traversal was INCOMPLETE (find exited
#           non-zero, e.g. an unreadable directory): the roots found so far are still printed, and
#           a one-line typed WARN names the gap on stderr (§7: an incomplete probe is not "none").
#           Incomplete-probe detection needs bash >= 4.4 (see the `wait` note below).
#   Paths are judged relative to <root>: <root>'s OWN ".git" (a target that is itself a worktree)
#   is never a nested root, and a corpus that happens to live under .claude/worktrees/ itself is
#   not excluded wholesale.
#
# block_files_path_in_nested_worktree <path> <roots>
#   <roots>: the newline-separated output of block_files_nested_worktree_roots.
#   exit  : 0 <path> is a root or lies under one · 1 it does not (including an empty <roots>).
#           Pure bash, no fork — safe to call once per path in a hot loop.
if ! declare -F block_files_nested_worktree_roots >/dev/null 2>&1; then

  block_files_nested_worktree_roots() {
    local _root="${1:-}" _gf _line _gd _bp _fpid _frc=0
    if [ ! -d "$_root" ]; then
      echo "block-files: nested_worktree_roots: not a directory: $_root" >&2
      return 2
    fi
    _root="${_root%/}"
    printf '%s\n' "$_root/.claude/worktrees"
    while IFS= read -r -d '' _gf; do
      [ "${_gf%/.git}" = "$_root" ] && continue
      _line=""
      IFS= read -r _line < "$_gf" 2>/dev/null || [ -n "$_line" ] || continue
      case "$_line" in
        gitdir:*) ;;
        *) continue ;;
      esac
      _gd="${_line#gitdir:}"; _gd="${_gd# }"
      case "$_gd" in /*) ;; *) _gd="${_gf%/.git}/$_gd" ;; esac
      # SENTINEL-COMMONDIR-START
      [ -f "$_gd/commondir" ] || continue
      # SENTINEL-COMMONDIR-END
      # SENTINEL-BACKPOINTER-START
      # commondir alone is forgeable (`gitdir: .` plus a stray commondir in the same directory
      # satisfies it): the VCS also writes <gitdir>/gitdir, the path of the worktree's .git
      # file, and that must name THIS file (kit issue #1301). Compared with -ef (same inode) so
      # a symlinked path or a relative back-pointer still matches; a missing or mismatching one
      # means "cannot be proven a worktree" → not excluded (a false BLOCK is recoverable, a
      # false ALLOW is not).
      _bp=""
      IFS= read -r _bp < "$_gd/gitdir" 2>/dev/null || [ -n "$_bp" ] || continue
      case "$_bp" in /*) ;; *) _bp="$_gd/$_bp" ;; esac
      [ "$_bp" -ef "$_gf" ] || continue
      # SENTINEL-BACKPOINTER-END
      printf '%s\n' "${_gf%/.git}"
    done < <(find -H "$_root" -mindepth 1 \( -path "$_root/.claude/worktrees" -prune \) -o \( -type d -name .git -prune \) -o \( -type f -name .git -print0 \) 2>/dev/null)
    # find's status (lost by process substitution) comes back through `wait` on bash >= 4.4; on
    # older shells $! is not the substitution's pid and the probe can only report "complete".
    # 127 is bash's own `wait` status for "no such child" (pid not a child of this shell, or its
    # status already collected) — not find's exit code (find uses 0/1/2) — so it means "no status
    # to read", NOT "traversal incomplete", and is deliberately treated like 0.
    _fpid=$!
    wait "$_fpid" 2>/dev/null || _frc=$?
    if [ "$_frc" -ne 0 ] && [ "$_frc" -ne 127 ]; then
      echo "block-files: nested_worktree_roots: find exited $_frc under $_root — worktrees under unreadable directories may be missing" >&2
      return 3
    fi
    return 0
  }

  block_files_path_in_nested_worktree() {
    local _p="${1:-}" _roots="${2:-}" _r
    [ -n "$_roots" ] || return 1
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      case "$_p" in
        "$_r"|"$_r"/*) return 0 ;;
      esac
    done <<< "$_roots"
    return 1
  }

fi
