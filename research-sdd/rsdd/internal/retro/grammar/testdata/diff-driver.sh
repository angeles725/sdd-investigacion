#!/usr/bin/env bash
# diff-driver.sh <toolbelt-dir> <mode>
#
# Runs the REAL lib/retro-grammar.sh so the Go differential tests can require byte-equal output. Every mode reads
# its inputs on stdin, one per line, and calls the bash function once per input (one bash process per mode keeps
# a fleet pass cheap). Each call is framed on stdout as
#   <rc> <stdout-bytes> <stderr-bytes>\n<stdout><stderr>
# so the caller compares all three channels per input.
#   File modes (input = a path):
#     defenced  retro_grammar_defenced        delta    retro_grammar_delta_info
#     entryrows retro_grammar_entry_rows      entryids retro_grammar_entry_ids     entrywarn retro_grammar_entry_warn
#     altrows   retro_grammar_alt_entry_rows  altheads retro_grammar_alt_entry_rows <f> heads
#     canon     retro_grammar_canonical_heading           unrec retro_grammar_unrec_headings
#     honesty   retro_grammar_has_honesty     rowtitles retro_grammar_row_titles
#   Token modes (input = one argument):
#     idsafe    retro_grammar_id_signature_safe           titleid retro_grammar_title_has_identity
#     deltaid   awk rg_delta_id (prints 0/1)              idskip  awk rg_table_id_skip (prints 0/1)
#   Stream mode: dupids  retro_grammar_dup_ids over the whole stdin (one frame).
#
# Harness failures exit 97 and never look like a function rc: the lib missing, sourcing failing, the lib not
# defining a function (the same fail-closed check every real consumer does), or an unknown mode.
set -u
die() { echo "diff-driver: $*" >&2; exit 97; }
tb="${1:-}"; mode="${2:-}"
[ -n "$tb" ] && [ -n "$mode" ] || die "usage: diff-driver.sh <toolbelt-dir> <mode>"
lib="$tb/lib/retro-grammar.sh"
[ -f "$lib" ] || die "lib missing: $lib"
# shellcheck source=/dev/null
. "$lib" || die "sourcing $lib failed"
for fn in retro_grammar_defenced retro_grammar_delta_info retro_grammar_entry_rows retro_grammar_entry_ids \
  retro_grammar_entry_warn retro_grammar_alt_entry_rows retro_grammar_canonical_heading retro_grammar_unrec_headings \
  retro_grammar_dup_ids retro_grammar_has_honesty retro_grammar_id_signature_safe retro_grammar_title_has_identity \
  retro_grammar_row_titles; do
  declare -F "$fn" >/dev/null 2>&1 || die "lib failed to define $fn"
done
[ -n "${_RG_AWK_ID_FN:-}" ] || die "lib failed to define _RG_AWK_ID_FN"
tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

frame() { # frame <cmd...>: run it with both streams captured, then print the frame
  "$@" >"$tmp/o" 2>"$tmp/e"
  local rc=$?
  printf '%d %d %d\n' "$rc" "$(wc -c <"$tmp/o")" "$(wc -c <"$tmp/e")"
  cat "$tmp/o" "$tmp/e"
}
awk_id() { printf '%s\n' "$2" | awk "$_RG_AWK_ID_FN"'{ print '"$1"'($0) }'; }

case "$mode" in
  defenced)  fn=retro_grammar_defenced ;;
  delta)     fn=retro_grammar_delta_info ;;
  entryrows) fn=retro_grammar_entry_rows ;;
  entryids)  fn=retro_grammar_entry_ids ;;
  entrywarn) fn=retro_grammar_entry_warn ;;
  altrows)   fn=retro_grammar_alt_entry_rows ;;
  altheads)  fn=alt_heads; alt_heads() { retro_grammar_alt_entry_rows "$1" heads; } ;;
  canon)     fn=retro_grammar_canonical_heading ;;
  unrec)     fn=retro_grammar_unrec_headings ;;
  honesty)   fn=retro_grammar_has_honesty ;;
  rowtitles) fn=retro_grammar_row_titles ;;
  idsafe)    fn=retro_grammar_id_signature_safe ;;
  titleid)   fn=retro_grammar_title_has_identity ;;
  deltaid)   fn="awk_id rg_delta_id" ;;
  idskip)    fn="awk_id rg_table_id_skip" ;;
  dupids)    frame retro_grammar_dup_ids; exit 0 ;;
  *)         die "unknown mode: $mode" ;;
esac
while IFS= read -r arg || [ -n "$arg" ]; do
  # shellcheck disable=SC2086 # fn may carry a fixed first argument
  frame $fn "$arg" </dev/null
done
