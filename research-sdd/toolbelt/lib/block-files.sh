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
