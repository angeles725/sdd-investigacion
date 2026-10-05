#!/usr/bin/env bash
# append-iteration-row.sh — propose-never-apply appender for ONE row of a RESEARCH-STATE.md
# `## Iteration history` table (kit issue #1606: a hand-appended row glued onto the next heading).
# Contract: append-iteration-row.v1.md (read it first).
#
# Usage: append-iteration-row.sh [--apply] <RESEARCH-STATE.md> "<row>"
#   Default is a DRY RUN: prints a unified diff on stdout and never writes. --apply writes the file
#   atomically (temp file in the same directory + mv). The row may omit its outer pipes.
# Exit: 0 diff printed (dry run) or file written (--apply) · 2 usage / absent file / not a regular file
#       3 DEGRADED (a tool in REQUIRED_TOOLS is missing — nothing measured)
#       4 NO-HEADING · 5 NO-TABLE · 6 MALFORMED-TABLE · 7 CELL-COUNT-MISMATCH · 8 AMBIGUOUS-HEADING
#       9 write failed (--apply) · 10 CONCURRENT-MODIFICATION · 11 CRLF-LINE-ENDINGS (any CR in the file)
#       12 UNCLOSED-FENCE (an unclosed code fence hides the heading) · 13 HARD-LINKED (--apply only)
# Every failure prints exactly one typed line `append-iteration-row: ERROR: <TYPE> ...` on stderr; usage text is
# printed only by --help (stdout, exit 0).
# An HTML-comment span never counts as heading or table (templates carry `## ...` inside comments, #1173).
# Neither does a fenced code block (``` or ~~~): its lines are invisible, comment openers included (#1793).

set -uo pipefail

_err() { printf 'append-iteration-row: ERROR: %s\n' "$1" >&2; }
_usage() { printf 'Usage: %s [--apply] <RESEARCH-STATE.md> "<row>"\n' "${0##*/}"; }

APPLY=0; FILE=""; ROW=""; NPOS=0
_pos() {
  if [ "$NPOS" -eq 0 ]; then FILE="$1"; elif [ "$NPOS" -eq 1 ]; then ROW="$1"
  else _err "USAGE too many arguments (try --help)"; exit 2; fi
  NPOS=$((NPOS+1))
}
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    -h|--help) _usage; exit 0 ;;
    --)        shift; break ;;
    -*)        _err "USAGE unknown argument: $1 (try --help)"; exit 2 ;;
    *)         _pos "$1"; shift ;;
  esac
done
while [ $# -gt 0 ]; do _pos "$1"; shift; done
[ "$NPOS" -eq 2 ] || { _err "USAGE needs <RESEARCH-STATE.md> and <row> (try --help)"; exit 2; }

# SENTINEL-DEGRADED-PROBE: a missing dependency is a typed DEGRADED, never a quiet success (§7).
REQUIRED_TOOLS="awk diff mktemp mv cp cat dirname cmp rm ls"
for _tool in $REQUIRED_TOOLS; do
  command -v "$_tool" >/dev/null 2>&1 || { printf 'append-iteration-row: DEGRADED: %s not found on PATH; nothing was measured\n' "$_tool" >&2; exit 3; }
done

[ -e "$FILE" ] || { _err "ABSENT-FILE $FILE"; exit 2; }
[ -L "$FILE" ] && { _err "NOT-REGULAR-FILE $FILE is a symlink (mv would replace the link)"; exit 2; }
{ [ -f "$FILE" ] && [ -r "$FILE" ]; } || { _err "NOT-REGULAR-FILE $FILE is not a readable regular file"; exit 2; }

# The row: a single non-blank line.
case "$ROW" in *$'\n'*|*$'\r'*) _err "USAGE row must be a single line"; exit 2 ;; esac
case "$ROW" in *'<!--'*|*'-->'*) _err "INVALID-ROW row contains an HTML comment delimiter (it could hide the rest of the file)"; exit 2 ;; esac
case "$ROW" in *[![:space:]]*) ;; *) _err "USAGE row is empty"; exit 2 ;; esac

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/air.XXXXXX")" || { _err "WRITE-FAILED cannot create temp dir"; exit 9; }
STAGE=""
trap 'rm -rf "$TMPD"; [ -z "$STAGE" ] || rm -f "$STAGE"' EXIT
# Snapshot: everything below (awk, diff, the unchanged-check) works from this one read of the target.
cp -- "$FILE" "$TMPD/orig" || { _err "WRITE-FAILED cannot snapshot $FILE"; exit 9; }

# SENTINEL-AWK-INSERT: one pass over the file. Comment spans are blanked out of the "visible" text
# first, so a heading or table row inside <!-- ... --> is invisible; only fully visible lines count.
AIR_ROW="$ROW" awk '
function cells(s,   i, n, ch, prev) {
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
  if (substr(s, 1, 1) == "|") s = substr(s, 2)
  n = 1; prev = ""
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch == "|" && prev != "\\") { if (i < length(s)) n++ }
    prev = (prev == "\\" && ch == "\\") ? "" : ch
  }
  return n
}
function visible(line,   out, p, q) {
  out = ""
  while (length(line) > 0) {
    if (inc) {
      q = index(line, "-->")
      if (q == 0) return out
      line = substr(line, q + 3); inc = 0
    } else {
      p = index(line, "<!--")
      if (p == 0) return out line
      out = out substr(line, 1, p - 1); line = substr(line, p + 4); inc = 1
    }
  }
  return out
}
function istab(i) { return V[i] ~ /^\|/ }
# fenceinfo: the fence character of a line that starts a code fence run of >= 3 (up to 3 spaces of indent), else "".
# Sets FN (run length) and FR (the rest of the line).
function fenceinfo(line,   s, ch, n) {
  s = line; sub(/^ ? ? ?/, "", s); ch = substr(s, 1, 1)
  if (ch != "`" && ch != "~") return ""
  n = 0; while (substr(s, n + 1, 1) == ch) n++
  if (n < 3) return ""
  FN = n; FR = substr(s, n + 1); return ch
}
{
  L[NR] = $0; fl = 0
  if (index($0, "\r")) cr = 1
  if (!inc) {
    c = fenceinfo($0)
    if (infence) {
      if (c != "" && c == fch && FN >= fn && FR ~ /^[ \t]*$/) infence = 0
      fl = 1
    } else if (c != "" && (c == "~" || FR !~ /`/)) { infence = 1; fch = c; fn = FN; fl = 1 }
  }
  if (fl) { V[NR] = ""; ES[NR] = 0 } else { V[NR] = visible($0); ES[NR] = inc }
  if (V[NR] ~ /^## Iteration history[ \t]*$/) { hc++; if (hc == 1) h = NR }
  if (V[NR] ~ /^#+[ \t]/) hd[NR] = 1
}
END {
  if (cr) { print "append-iteration-row: ERROR: CRLF-LINE-ENDINGS the file contains a carriage return; convert it to LF first (nothing written)" > "/dev/stderr"; exit 11 }
  if (hc == 0 && infence) { print "append-iteration-row: ERROR: UNCLOSED-FENCE a code fence is never closed, so no `## Iteration history` heading is visible" > "/dev/stderr"; exit 12 }
  if (hc == 0) { print "append-iteration-row: ERROR: NO-HEADING no `## Iteration history` heading outside an HTML comment" > "/dev/stderr"; exit 4 }
  if (hc > 1)  { print "append-iteration-row: ERROR: AMBIGUOUS-HEADING " hc " `## Iteration history` headings outside HTML comments" > "/dev/stderr"; exit 8 }
  hdr = 0
  for (i = h + 1; i <= NR; i++) { if (hd[i]) break; if (istab(i)) { hdr = i; break } }
  if (!hdr) { print "append-iteration-row: ERROR: NO-TABLE no table row between the heading and the next heading" > "/dev/stderr"; exit 5 }
  if (!(hdr < NR && istab(hdr + 1) && V[hdr + 1] ~ /^\|[ \t:|-]*-[ \t:|-]*$/)) {
    print "append-iteration-row: ERROR: MALFORMED-TABLE header row at line " hdr " is not followed by a |---| separator row" > "/dev/stderr"; exit 6
  }
  last = hdr + 1
  while (last < NR && istab(last + 1)) last++
  if (ES[last]) { print "append-iteration-row: ERROR: MALFORMED-TABLE last table row at line " last " opens an HTML comment that closes on a later line; a row appended after it would be hidden" > "/dev/stderr"; exit 6 }
  row = ENVIRON["AIR_ROW"]; sub(/^[ \t]+/, "", row); sub(/[ \t]+$/, "", row)
  if (substr(row, 1, 1) != "|") row = "| " row
  # closing pipe: missing, or present but escaped (an ODD run of backslashes before it, same rule as cells())
  nb = 0; while (length(row) - 1 - nb >= 1 && substr(row, length(row) - 1 - nb, 1) == "\\") nb++
  if (substr(row, length(row), 1) != "|" || nb % 2 == 1) row = row " |"
  want = cells(V[hdr]); got = cells(row)
  if (want != got) { print "append-iteration-row: ERROR: CELL-COUNT-MISMATCH row has " got " cell(s), the table header has " want > "/dev/stderr"; exit 7 }
  for (i = 1; i <= last; i++) print L[i]
  print row
  if (last < NR && L[last + 1] !~ /^[ \t]*$/) print ""
  for (i = last + 1; i <= NR; i++) print L[i]
}' "$TMPD/orig" > "$TMPD/out"
rc=$?
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    4|5|6|7|8|11|12) exit "$rc" ;;
    *)         _err "WRITE-FAILED awk exited $rc; $FILE unchanged"; exit 9 ;;
  esac
fi

if [ "$APPLY" -eq 0 ]; then
  diff -u --label "a/${FILE##*/}" --label "b/${FILE##*/}" "$TMPD/orig" "$TMPD/out"
  drc=$?
  [ "$drc" -le 1 ] || { _err "WRITE-FAILED diff exited $drc"; exit 9; }
  printf 'append-iteration-row: dry run, nothing written (use --apply)\n' >&2
  exit 0
fi

# --apply replaces the inode (mv), so a second hard link would silently keep the OLD content: refuse (#1793).
# Link count from `ls -ld` field 2 (portable; `stat` flags differ between GNU and BSD).
_links="$(ls -ld -- "$FILE" 2>/dev/null | awk '{ print $2 }')"
case "$_links" in
  ''|*[!0-9]*) _err "WRITE-FAILED cannot read the link count of $FILE; nothing written"; exit 9 ;;
esac
[ "$_links" -le 1 ] || { _err "HARD-LINKED $FILE has $_links hard links; --apply replaces the file and would split them, nothing written"; exit 13; }

# Atomic write: stage in the target directory (same filesystem), keep mode via cp -p, then mv.
DIR="$(dirname -- "$FILE")"
STAGE="$(mktemp "$DIR/.air.XXXXXX")" || { _err "WRITE-FAILED cannot stage in $DIR"; STAGE=""; exit 9; }
# Best-effort metadata: GNU `cp --preserve=all` (mode, owner, timestamps, xattrs, ACLs, SELinux context), else `cp -p`.
{ { cp --preserve=all -- "$FILE" "$STAGE" 2>/dev/null || cp -p -- "$FILE" "$STAGE"; } && cat -- "$TMPD/out" > "$STAGE"; } \
  || { _err "WRITE-FAILED could not stage $FILE; original left in place"; exit 9; }
# AIR_PRE_MV_HOOK: test hook (like STATE_UPDATE_VERIFY) — an executable run with the target path in the window
# between the unchanged-check inputs being fixed and the check itself.
[ -z "${AIR_PRE_MV_HOOK:-}" ] || "$AIR_PRE_MV_HOOK" "$FILE" || true
# SENTINEL-UNCHANGED-CHECK: lost-update guard. The new content was computed from the snapshot taken at the start;
# refuse when the target is no longer byte-identical to it. (A write landing between this check and mv is not
# detectable without a lock; the window is that of one cmp + one mv.)
cmp -s -- "$FILE" "$TMPD/orig"
crc=$?
[ "$crc" -ne 1 ] || { _err "CONCURRENT-MODIFICATION $FILE changed since it was read; nothing written, re-run"; exit 10; }
[ "$crc" -eq 0 ] || { _err "WRITE-FAILED cmp could not compare $FILE with its snapshot (rc=$crc); nothing written"; exit 9; }
mv -f -- "$STAGE" "$FILE" || { _err "WRITE-FAILED could not replace $FILE; original left in place"; exit 9; }
STAGE=""
printf 'append-iteration-row: appended 1 row to %s\n' "$FILE" >&2
exit 0
