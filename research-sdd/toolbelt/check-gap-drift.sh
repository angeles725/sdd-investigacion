#!/usr/bin/env bash
# check-gap-drift.sh — flag RESEARCH-STATE backlog rows whose text drifted from the child-gap bullet
# that defines them (kit issues #1291, #1294; ported from niagara5-research tools/check-gap-drift.py).
#
# A backlog row `| <priority> | B<n>-G<m> <text> | ... | <status> |` is a promoted COPY of the bullet
# `- **B<n>-G<m>** <text>` in block <n>'s child-gaps list. A paraphrase that changes the question sends
# the loop after the wrong gap (niagara5-research: 7 rows drifted — B50-G6, B73-G2/G3, B79-G1,
# B82-G1..G3). The check compares content words: a row sharing fewer than THRESHOLD percent of its
# own content words with its defining bullet is suspected drift. Observed drift scored 0-17 %; honest
# paraphrases on the real corpus scored >= 33 %, so the default is 20.
#
# Usage: check-gap-drift.sh <target-dir> [--state <file>] [--threshold <pct>] [--all]
#   <target-dir>  corpus root: its block files (*-block<N>.md / *-bloque<N>.md, found up to 3 levels
#                 deep, nested git worktrees and .git excluded) are the bullet source.
#   --state       state file to check (default <target-dir>/RESEARCH-STATE.md).
#   --threshold   integer percent 0-100 (default 20). Overlap strictly below it is DRIFT?.
#   --all         also check non-pending rows (default: only rows whose status starts with `pending`).
#
# Output (one line each; every state is typed so a zero cannot hide an input that was not looked at):
#   DRIFT?    <gid> overlap=NN% row='...'   row shares too few content words with its bullet
#   NO-BULLET <gid> ...                     block exists but defines the gap only in prose / not at all
#   NO-BLOCK  <gid> ...                     no block file for that number under <target-dir>
#   NO-WORDS  <gid> ...                     row has no comparable content word (not drift, not checked)
#   UNPARSED  <line>                        a gap-id table row the row grammar could not parse
#   DEGRADED: ...                           rows were in scope but not one could be compared
#   check-gap-drift: no B<n>-G<m> backlog rows ...   (not applicable) / no pending rows ...
#   checked=N suspects=N no_bullet=N no_block=N no_words=N unparsed=N skipped_nonpending=N skipped_closed=N
#                                           skipped_closed = gap-id rows with an em-dash / ~~struck~~ / numeric
#                                           priority cell (closed-class or iteration-history rows, never compared)
# Exit: 0 = no drift suspected · 1 = drift or unparsed rows · 2 = usage / unreadable input.
# NO-BULLET / NO-BLOCK alone exit 0: some gaps are legitimately defined in prose only; they are
# reported, never skipped. Read-only: never edits a corpus (propose-never-apply).
set -uo pipefail

_usage() { echo "usage: check-gap-drift.sh <target-dir> [--state <file>] [--threshold <pct>] [--all]" >&2; }

_HERE="$(cd "$(dirname "$0")" && pwd)"
_GRLIB="$_HERE/lib/gap-rows.sh"
_BFLIB="$_HERE/lib/block-files.sh"
[ -f "$_GRLIB" ] || { echo "check-gap-drift: cannot find helper $_GRLIB" >&2; exit 1; }
[ -f "$_BFLIB" ] || { echo "check-gap-drift: cannot find helper $_BFLIB" >&2; exit 1; }
# shellcheck source=lib/gap-rows.sh
. "$_GRLIB"
# shellcheck source=lib/block-files.sh
. "$_BFLIB"
declare -F gap_rows_parse >/dev/null 2>&1 || { echo "check-gap-drift: helper lib/gap-rows.sh failed to define gap_rows_parse" >&2; exit 1; }
declare -F block_file_filter >/dev/null 2>&1 || { echo "check-gap-drift: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }

target="${1:-}"
[ -n "$target" ] && [ -d "$target" ] || { _usage; exit 2; }
shift
state=""; threshold=20; all=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)     state="${2:-}"; [ -n "$state" ] || { _usage; exit 2; }; shift 2 ;;
    --threshold) threshold="${2:-}"; shift 2 ;;
    --all)       all=1; shift ;;
    *)           _usage; exit 2 ;;
  esac
done
case "$threshold" in
  ''|*[!0-9]*) echo "check-gap-drift: --threshold must be an integer percent 0-100 (got '$threshold')" >&2; exit 2 ;;
esac
[ "$threshold" -le 100 ] || { echo "check-gap-drift: --threshold must be an integer percent 0-100 (got '$threshold')" >&2; exit 2; }
[ -n "$state" ] || state="$target/RESEARCH-STATE.md"
[ -f "$state" ] && [ -r "$state" ] || { echo "check-gap-drift: cannot read state file $state" >&2; exit 2; }

# Block index: one find, filtered to canonical block files (shared regex), nested worktrees pruned.
_found="$(find -H "$target" -maxdepth 3 \( -path "$target/.claude/worktrees" -o -name .git \) -prune -o -type f -name '*.md' -print 2>/dev/null)" \
  || { echo "check-gap-drift: cannot list block files under $target" >&2; exit 2; }
_rc=0
blocks="$(printf '%s\n' "$_found" | block_file_filter)" || _rc=$?
# block_file_filter returns grep's status verbatim: 1 = no block files at all (legitimate), >=2 = error.
[ "$_rc" -le 1 ] || { echo "check-gap-drift: block filter failed (rc=$_rc)" >&2; exit 2; }

parsed="$(gap_rows_parse "$state")" || { echo "check-gap-drift: cannot parse $state" >&2; exit 2; }

checked=0; suspects=0; no_bullet=0; no_block=0; no_words=0; unparsed=0; skipped=0; skipped_closed=0; rows=0
out_drift=""; out_nobullet=""; out_noblock=""; out_nowords=""; out_unparsed=""

while IFS=$'\t' read -r kind gid bnum pend text; do
  [ -n "$kind" ] || continue
  if [ "$kind" = "SKIPPED" ]; then skipped_closed=$((skipped_closed+1)); continue; fi
  if [ "$kind" = "UNPARSED" ]; then
    unparsed=$((unparsed+1)); out_unparsed="${out_unparsed}UNPARSED ${gid}"$'\n'; continue
  fi
  rows=$((rows+1))
  if [ "$all" -eq 0 ] && [ "$pend" != "pending" ]; then skipped=$((skipped+1)); continue; fi
  files="$(printf '%s\n' "$blocks" | grep -E -- "-(block|bloque)${bnum}(-[[:alnum:]_-]+)?\.md$")" || files=""
  if [ -z "$files" ]; then
    no_block=$((no_block+1)); out_noblock="${out_noblock}NO-BLOCK ${gid} (no block file for block ${bnum} under ${target})"$'\n'; continue
  fi
  bullet=""; have=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(gap_bullet_text "$f" "$gid")"; brc=$?
    if [ "$brc" -eq 0 ]; then bullet="$b"; have=1; break; fi
    [ "$brc" -eq 1 ] || { echo "check-gap-drift: cannot read $f" >&2; exit 2; }
  done <<<"$files"
  if [ "$have" -eq 0 ]; then
    no_bullet=$((no_bullet+1)); out_nobullet="${out_nobullet}NO-BULLET ${gid} (no '- **${gid}**' bullet in its block; prose-only or undefined)"$'\n'; continue
  fi
  read -r shared total <<<"$(gap_overlap "$text" "$bullet")"
  if [ "${total:-0}" -eq 0 ]; then
    no_words=$((no_words+1)); out_nowords="${out_nowords}NO-WORDS ${gid} (row text has no comparable content word)"$'\n'; continue
  fi
  checked=$((checked+1))
  if [ $((shared*100)) -lt $((threshold*total)) ]; then
    suspects=$((suspects+1)); out_drift="${out_drift}DRIFT? ${gid} overlap=$((shared*100/total))% row='${text:0:90}'"$'\n'
  fi
done <<<"$parsed"

printf '%s' "$out_drift$out_nobullet$out_noblock$out_nowords$out_unparsed"
if [ "$rows" -eq 0 ] && [ "$unparsed" -eq 0 ]; then
  echo "check-gap-drift: no B<n>-G<m> backlog rows in $state (not applicable)"
elif [ "$rows" -gt 0 ] && [ "$rows" -eq "$skipped" ]; then
  echo "check-gap-drift: no pending B<n>-G<m> rows ($skipped non-pending skipped; use --all)"
elif [ "$checked" -eq 0 ] && [ $((rows-skipped)) -gt 0 ]; then
  echo "DEGRADED: $((rows-skipped)) row(s) in scope but none could be compared (no_block=$no_block no_bullet=$no_bullet no_words=$no_words) — this is not a clean result"
fi
echo "checked=$checked suspects=$suspects no_bullet=$no_bullet no_block=$no_block no_words=$no_words unparsed=$unparsed skipped_nonpending=$skipped skipped_closed=$skipped_closed"
[ "$suspects" -eq 0 ] && [ "$unparsed" -eq 0 ]
rc=$?
[ "$rc" -eq 0 ] || exit 1
exit 0
