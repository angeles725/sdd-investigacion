#!/usr/bin/env bash
# diff-driver.sh <toolbelt-dir> <mode> <file> [key...]
#
# Runs the REAL bash table readers of the kit so the Go differential test can require byte-equal output.
#   gaprows   lib/gap-rows.sh gap_rows_parse <file>                     (ROW/SKIPPED/UNPARSED records)
#   contra    research-sdd-status.sh count_open_contra <file>           (one integer)
#   foctok    research-sdd-status.sh _read_focuses_tok_uncached <file> <key>...   (one "key=token" per key)
#   state     research-sdd-status.sh --sync-state on a COPY of <file>    (deferred_open / covered_blocks lines)
# Functions embedded in scripts are lifted with sed exactly like table-reader-parity.test.sh does.
# Exit: 0 ok, 2 usage / SUT missing (never a silent empty result).
set -uo pipefail
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
tb="${1:?toolbelt dir}"; mode="${2:?mode}"; file="${3:?file}"; shift 3
[ -f "$file" ] || { echo "diff-driver: input not found: $file" >&2; exit 2; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
lift() { # lift <script> <function> -> file
  sed -n "/^$2()/,/^}/p" "$tb/$1" > "$tmp/$2.sh"
  [ -s "$tmp/$2.sh" ] || { echo "diff-driver: function $2 not found in $1" >&2; exit 2; }
}
case "$mode" in
  gaprows)
    [ -f "$tb/lib/gap-rows.sh" ] || { echo "diff-driver: lib/gap-rows.sh missing" >&2; exit 2; }
    bash -c '. "$1/lib/gap-rows.sh"; gap_rows_parse "$2"' _ "$tb" "$file" ;;
  contra)
    lift research-sdd-status.sh count_open_contra
    bash -c '. "$1"; count_open_contra "$2"' _ "$tmp/count_open_contra.sh" "$file" ;;
  foctok)
    lift research-sdd-status.sh _read_focuses_tok_uncached
    bash -c '. "$1"; f="$2"; shift 2; for k in "$@"; do printf "%s=%s\n" "$k" "$(_read_focuses_tok_uncached "$f" "$k" 2>/dev/null)"; done' _ "$tmp/_read_focuses_tok_uncached.sh" "$file" "$@" ;;
  state)
    # Zero the two envelope values first so the output proves --sync-state DERIVED them (a file already
    # carrying the right numbers would otherwise pass vacuously).
    sed -e 's/^deferred_open:.*/deferred_open: 0/' -e 's/^covered_blocks:.*/covered_blocks: 0/' "$file" > "$tmp/RESEARCH-STATE.md"
    bash "$tb/research-sdd-status.sh" "$tmp" --sync-state >/dev/null 2>&1
    sed -n -e 's/^deferred_open: */deferred_open=/p' -e 's/^covered_blocks: */covered_blocks=/p' "$tmp/RESEARCH-STATE.md" ;;
  *) echo "diff-driver: unknown mode: $mode" >&2; exit 2 ;;
esac
