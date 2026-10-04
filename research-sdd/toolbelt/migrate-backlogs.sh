#!/usr/bin/env bash
# migrate-backlogs.sh — PROPOSE-ONLY §8b gap-backlog migration for a Research-SDD corpus (kit #1543).
#
# WHY: a corpus written before the §8b grammar closed carries heading variants, `open`/`queued` statuses,
# `critical`/`med` tiers, qualified priorities and a FOCUSES.md `closed` token. Each makes verify-state.sh FAIL
# and, corpus-wide, bricks `research-sdd-status.sh --next` with STALE. This tool prints the MECHANICAL part of
# that migration as a unified diff per file so the operator can review and apply it. It NEVER edits the target
# (propose-never-apply, CLAUDE.md §8): every transform is computed in a private temp dir and diffed; the target
# is only ever read. Anything not purely mechanical is printed as a typed MANUAL line and left untouched.
#
# Usage: migrate-backlogs.sh <corpus-dir>
#
# Mechanical transforms (METHODOLOGY §8b "Migration" list):
#   heading    a near-miss backlog heading (`## Gap backlog`, `## Backlog`, `## Backlog de gaps`, U+2011 form,
#              `## Gap-backlog prioritized`) over a table whose first header cell is priority-shaped
#              -> `## Gap-backlog`
#   skeleton   a state file with no backlog table at all (and not a FOCUSES.md `document` focus) -> an empty
#              canonical `## Gap-backlog` section appended (always paired with MANUAL empty-backlog-skeleton:
#              the rows themselves are the operator's)
#   priority   `critical` -> `high`; `med`/`MED` -> `medium`; `**HIGH**` -> `high`; `low (deferred)` ->
#              `deferred`; `high|medium|low (note)` -> the bare tier with `(note)` moved to the END of the
#              Status cell (decoration is free text per §8b)
#   status     leading token `open` / `queued` -> `pending` (deprecated aliases)
#   focuses    FOCUSES.md status token `closed` -> `stopped`, `reabierto` -> `reopened`
# Typed MANUAL lines (never guessed), one per focus and reason:
#   MANUAL <focus> <reason> rows=<N> first-line=<L>
#   reasons: unknown-priority · emdash-open-row · bare-closure-word (covered/closed/done) ·
#            unknown-status-token · malformed-row (cell count != table width, or an escaped pipe) ·
#            unknown-focus-status · multiple-backlog-sections (a second backlog-named section with a priority
#            table beside a canonical or already-renamed one: never duplicated, merge by hand) · empty-backlog-skeleton · non-priority-backlog-table (a backlog-like heading
#            whose table has no Priority first column: reshape by hand; no skeleton is stacked beside it) ·
#            unrecognised-backlog-heading (any `*backlog*` heading outside the documented variants, e.g.
#            `## Retro backlog`: never renamed) · unsupported-table-width cols=N (reported once per table)
# Only the documented near-miss headings are rename candidates: `## Gap backlog`, `## Backlog`,
# `## Backlog de gaps`, `## Gap-backlog <free text>` and the U+2011-hyphen form (rewritten to ASCII).
# Only the FOCUSES.md registry table (header has Status/Estado and a Focus/Slug/Name column) is read or
# transformed; every other table in that file is left untouched.
# Other typed lines (stdout): `absent-input: ...` (corpus dir has no RESEARCH-STATE*.md), `empty-input: <focus>`
# (a 0-byte state file), `ok <focus>: nothing to migrate`, `PROPOSE <focus> <file>` before each diff, and always
# one closing `migrate-backlogs: N file(s) inspected · M with a mechanical proposal · K MANUAL line(s)` so a
# zero can be told from a run that never looked (CLAUDE.md §7). `degraded: ...` (stderr) when awk/diff is missing.
#
# Document-mode focuses (`document` in FOCUSES.md) have no backlog by design and get no skeleton proposal.
# Exit: 0 inspected (with or without proposals; proposals are findings, not failures) · 1 operational failure
# (awk/diff/mktemp unavailable, unreadable file, a failed state-file scan or a `diff` status >= 2 -> typed `degraded:` on stderr; diff 0 = no change, not counted) · 2 bad args or target is not a directory.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="${1:-}"
[ "$#" -eq 1 ] && [ -n "$target" ] || { echo "usage: migrate-backlogs.sh <corpus-dir>" >&2; exit 2; }
[ -d "$target" ] || { echo "absent-input: $target is not a directory" >&2; exit 2; }
for _t in awk diff mktemp; do
  command -v "$_t" >/dev/null 2>&1 || { echo "degraded: migrate-backlogs: required tool '$_t' not found — cannot compute a proposal" >&2; exit 1; }
done
_SFLIB="$here/lib/state-files.sh"
[ -f "$_SFLIB" ] || { echo "migrate-backlogs: cannot find helper $_SFLIB" >&2; exit 1; }
# shellcheck source=lib/state-files.sh
. "$_SFLIB"
declare -F list_state_files >/dev/null 2>&1 || { echo "migrate-backlogs: helper $_SFLIB failed to define list_state_files" >&2; exit 1; }

work="$(mktemp -d 2>/dev/null)" || { echo "degraded: migrate-backlogs: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# --- awk: backlog transformer. Reads the file twice (pass 1 classifies sections, pass 2 rewrites).
# Output: transformed file on stdout; MANUAL tallies go to the per-file temp file named by the awk variable `tally` ("reason<TAB>line", appended by manual()); stdout carries ONLY the transformed file.
BACKLOG_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function iscanon(h) { return h ~ /^## Gap-backlog( \([^)]+\))?$/ }
function recog(h,   l) { l = tolower(h); return (l == "## gap backlog" || l == "## backlog" || l == "## backlog de gaps" || h ~ /^## Gap-backlog /) }
function norm(h) { gsub(/\342\200\221/, "-", h); return h }
function manual(reason, ln) { print reason "\t" ln >> tally }
function cells(line,   body, n) {  # sets pre, suf, raw[1..nc]; returns nc
  pre = line; sub(/\|.*$/, "", pre); body = line; sub(/^[ \t]*\|/, "", body)
  suf = ""; if (match(body, /\|[ \t]*$/)) { suf = substr(body, RSTART); body = substr(body, 1, RSTART - 1) }
  nc = split(body, raw, "|"); return nc
}
function rebuild(   i, out) { out = pre "|"; for (i = 1; i <= nc; i++) out = out raw[i] (i < nc ? "|" : ""); return out suf }
function setcell(i, newtrim,   l, r) { l = raw[i]; sub(/[^ \t].*$/, "", l); r = raw[i]; sub(/^.*[^ \t]/, "", r); raw[i] = l newtrim r }
function mapprio(q) { if (q == "critical") return "high"; if (q == "med") return "medium"; return q }
function legal(q) { return (q == "high" || q == "medium" || q == "low" || q == "deferred") }
NR == FNR {  # pass 1 — classify
  if ($0 ~ /^## /) {
    cur = FNR; h = norm($0); canon[cur] = iscanon(h); if (canon[cur]) anycanon = 1
    isbl[cur] = (!canon[cur] && recog(h))                          # one of the documented near-miss variants
    unrec[cur] = (!canon[cur] && !isbl[cur] && tolower(h) ~ /backlog/)  # any OTHER *backlog* heading: never auto-renamed
    if (isbl[cur]) anybl = 1
    if (unrec[cur]) anyunrec = 1
  }
  else if (cur && $0 ~ /^[ \t]*\|/ && !(cur in hdrseen)) {
    c = $0; sub(/^[ \t]*\|/, "", c); sub(/\|.*$/, "", c); c = tolower(trim(c)); gsub(/\*\*/, "", c)
    if (c ~ /^(priority|pr\.?|p|prioridad)$/) { hdr[cur] = 1; if (isbl[cur] || canon[cur]) anyhdr = 1 }  # anyhdr counts priority-led tables INSIDE backlog-named sections only
    hdrseen[cur] = 1
  }
  next
}
FNR == 1 { cur = 0; inbl = 0; width = 0; indata = 0 }
{
  line = $0
  if (line ~ /^## /) {
    cur = FNR; h = norm(line); inbl = 0; width = 0; indata = 0
    if (canon[cur]) { inbl = 1; line = norm(line) }  # a U+2011 hyphen heading is rewritten to ASCII
    else if (unrec[cur]) manual("unrecognised-backlog-heading", FNR)
    else if (isbl[cur] && hdr[cur]) {
      if (anycanon || renamed) manual("multiple-backlog-sections", FNR)  # never duplicate the canonical heading; at most one rename per file
      else { line = "## Gap-backlog"; inbl = 1; renamed = 1 }
    }
    print line; next
  }
  if (!inbl || line !~ /^[ \t]*\|/) { print line; next }
  if (line ~ /\\\|/) { manual("malformed-row", FNR); print line; next }
  nc = cells(line)
  c1 = tolower(trim(raw[1])); gsub(/\*\*/, "", c1)
  if (c1 ~ /^-+$/ || c1 ~ /^:?-+:?$/) {
    width = (nc == 4 || nc == 5) ? nc : -1; indata = 1
    if (width < 0) manual("unsupported-table-width cols=" nc, FNR)  # once per table, at its separator row
    print line; next
  }
  if (c1 ~ /^(priority|pr\.?|p|prioridad)$/) { print line; next }
  if (width < 0) { print line; next }  # unsupported width: already reported once, rows are left alone
  if (!indata || width == 0 || nc != width) { if (indata) manual("malformed-row", FNR); print line; next }
  p = trim(raw[1]); q = tolower(p); np = ""; decor = ""
  if (legal(q) || q ~ /^~~(high|medium|low)~~$/ || q ~ /^—/) { np = p }
  else {
    b = q; gsub(/\*\*/, "", b)
    if (b == "low (deferred)") { np = "deferred" }
    else if (match(b, / *\([^)]*\)$/)) {
      base = substr(b, 1, RSTART - 1); qual = substr(b, RSTART); sub(/^ */, "", qual)
      base = mapprio(base)
      if (base == "high" || base == "medium" || base == "low" || base == "deferred") { np = base; decor = qual }
      else { manual("unknown-priority", FNR); print line; next }
    } else {
      m = mapprio(b)
      if (legal(m)) np = m
      else { manual("unknown-priority", FNR); print line; next }
    }
  }
  s = trim(raw[width]); lead = s; sub(/^\*\*/, "", lead); sub(/\*\*/, "", lead); split(lead, tk, /[ \t]/); tok = tk[1]; ltok = tolower(tok)
  newstat = ""
  if (np ~ /^—/) {
    if (ltok ~ /^(pending|requires-execution|open|queued|blocked)/) manual("emdash-open-row", FNR)
  } else if (ltok == "open" || ltok == "queued") {
    i = index(s, tok); newstat = substr(s, 1, i - 1) "pending" substr(s, i + length(tok))
  } else if (ltok == "covered" || ltok == "closed" || ltok == "done") { manual("bare-closure-word", FNR) }
  else if (!(ltok ~ /^(pending|requires-execution)/ || ltok ~ /^blocked-on-[a-z0-9\/-]+/ || substr(s, 1, 3) == "✅" || ltok ~ /^~~/ || substr(lead, 1, 3) == "✅")) {
    manual("unknown-status-token", FNR)
  }
  if (decor != "") { if (newstat == "") newstat = s; newstat = newstat " " decor }
  if (np != p) setcell(1, np)
  if (newstat != "") setcell(width, newstat)
  print rebuild()
}
END {
  if (!anycanon && !renamed && !anyhdr && anybl) manual("non-priority-backlog-table", 0)
  else if (!anycanon && !renamed && !anyhdr && anyunrec) { }  # reported as unrecognised-backlog-heading; no skeleton beside it
  else if (!anycanon && !renamed && !anyhdr && !skip_skel) {
    print ""
    print "## Gap-backlog"
    print ""
    print "| Priority | Gap | Artifact type / source | Status |"
    print "|---|---|---|---|"
    manual("empty-backlog-skeleton", 0)
  }
}
'

# REG_AWK: the SINGLE definition of "is this header row the focus registry?" — prepended to both DOC_AWK and
# FOCUSES_AWK below so the two programs cannot drift (cell decoration `**` and backticks stripped once, here).
REG_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function bare(s) { s = trim(s); gsub(/\*\*/, "", s); gsub(/`/, "", s); return trim(s) }
function reg_header(arr, cnt,   i, c) {  # sets global scol; true when Status/Estado AND a focus/slug column exist
  scol = 0; hasslug = 0
  for (i = 1; i <= cnt; i++) { c = tolower(bare(arr[i])); if (c == "status" || c == "estado") scol = i; if (c ~ /^(focus|slug|foco|name|nombre)$/) hasslug = 1 }
  return (scol > 0 && hasslug)
}
'

DOC_BODY='
!/^[ \t]*\|/ { intable = 0; reg = 0 }
/^[ \t]*\|/ {
  line = $0; sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line); n = split(line, a, "|")
  if (!intable) {  # header row: only the focus registry table is read
    intable = 1; reg = reg_header(a, n); next
  }
  if (!reg || a[1] ~ /^[ \t:-]+$/ || scol > n) next
  hit = (bare(a[1]) == lab); for (i = 2; i <= n; i++) if (bare(a[i]) == "RESEARCH-STATE-" lab ".md") hit = 1
  t = bare(a[scol]); sub(/[^A-Za-z-].*$/, "", t)
  if (hit && tolower(t) == "document") found = 1
}
END { print (found ? "yes" : "no") }
'

DOC_AWK="$REG_AWK$DOC_BODY"

FOCUSES_BODY='
function manual(reason, ln) { print reason "\t" ln >> tally }
function cells(line,   body) {
  pre = line; sub(/\|.*$/, "", pre); body = line; sub(/^[ \t]*\|/, "", body)
  suf = ""; if (match(body, /\|[ \t]*$/)) { suf = substr(body, RSTART); body = substr(body, 1, RSTART - 1) }
  nc = split(body, raw, "|")
}
function rebuild(   i, out) { out = pre "|"; for (i = 1; i <= nc; i++) out = out raw[i] (i < nc ? "|" : ""); return out suf }
{
  line = $0
  if (line !~ /^[ \t]*\|/) { intable = 0; reg = 0; print line; next }
  cells(line)
  if (!intable) {  # header row of a new table: only the focus REGISTRY (Status/Estado + a focus/slug column) is transformed
    intable = 1; reg = reg_header(raw, nc)
    print line; next
  }
  if (!reg) { print line; next }
  c1 = trim(raw[1]); if (c1 ~ /^:?-+:?$/) { print line; next }
  if (nc < scol) { print line; next }
  s = trim(raw[scol]); t = s; sub(/^[*`\[ ]+/, "", t); match(t, /^[A-Za-z-]+/); tok = substr(t, 1, RLENGTH); lt = tolower(tok)
  if (lt == "closed" || lt == "reabierto") {
    nw = (lt == "closed") ? "stopped" : "reopened"
    i = index(s, tok); s2 = substr(s, 1, i - 1) nw substr(s, i + length(tok))
    l = raw[scol]; sub(/[^ \t].*$/, "", l); r = raw[scol]; sub(/^.*[^ \t]/, "", r); raw[scol] = l s2 r
    print rebuild(); next
  }
  if (!(lt ~ /^(active|paused|stopped|planned|bootstrapping|reopened|document)$/)) manual("unknown-focus-status", FNR)
  print line
}
'
FOCUSES_AWK="$REG_AWK$FOCUSES_BODY"

n_files=0; n_prop=0; n_manual=0
# propose <label> <file> <awk-program> [awk -v args...]: transform, diff, tally.
propose() {
  local label="$1" f="$2" prog="$3"; shift 3
  local rel out tally
  rel="${f#"$target"/}"
  out="$work/out.$n_files"; tally="$work/tally.$n_files"; : > "$tally"
  if [ ! -r "$f" ]; then echo "migrate-backlogs: cannot read $f" >&2; exit 1; fi
  if [ ! -s "$f" ]; then echo "empty-input: $label ($rel is empty)"; return 0; fi
  if [ "$prog" = "$BACKLOG_AWK" ]; then
    LC_ALL=C awk -v tally="$tally" "$@" "$prog" "$f" "$f" > "$out" || { echo "migrate-backlogs: awk failed on $f" >&2; exit 1; }
  else
    LC_ALL=C awk -v tally="$tally" "$@" "$prog" "$f" > "$out" || { echo "migrate-backlogs: awk failed on $f" >&2; exit 1; }
  fi
  local changed=0
  # diff status is authoritative: 0 = no change (no PROPOSE, not counted) · 1 = proposal · >=2 = trouble -> degraded.
  local dfile="$work/diff.$n_files" drc
  diff -u --label "a/$rel" --label "b/$rel" "$f" "$out" > "$dfile"; drc=$?
  case "$drc" in
    0) ;;
    1) changed=1; n_prop=$((n_prop+1)); echo "PROPOSE $label $rel"; cat "$dfile" ;;
    *) echo "degraded: migrate-backlogs: diff failed (status $drc) on $rel — proposal not computed" >&2; exit 1 ;;
  esac
  local reasons r cnt first
  reasons="$(cut -f1 "$tally" | sort -u)"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    cnt="$(awk -F'\t' -v r="$r" '$1==r' "$tally" | wc -l | tr -d ' ')"
    first="$(awk -F'\t' -v r="$r" '$1==r {print $2; exit}' "$tally")"
    echo "MANUAL $label $r rows=$cnt first-line=$first"
    n_manual=$((n_manual+1))
  done <<<"$reasons"
  if [ "$changed" = 0 ] && [ -z "$reasons" ]; then echo "ok $label: nothing to migrate"; fi
}

# Scan with the helper's status captured (a sentinel line inside the substitution): a failed scan must read as
# DEGRADED, never as "absent-input / 0 files" (CLAUDE.md §7).
[ -r "$target" ] && [ -x "$target" ] || { echo "degraded: migrate-backlogs: $target is not readable/traversable — cannot scan" >&2; exit 1; }
find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -path '*/.git/*' >/dev/null 2>&1 \
  || { echo "degraded: migrate-backlogs: find failed while scanning $target (unreadable subdirectory?) — cannot tell absent from unreadable" >&2; exit 1; }
_scan="$(list_state_files "$target"; echo "@@rc=$?")"
_scan_rc="${_scan##*@@rc=}"
[ "$_scan_rc" = 0 ] || { echo "degraded: migrate-backlogs: scanning $target for RESEARCH-STATE*.md failed (status $_scan_rc) — NOT the same as no state files" >&2; exit 1; }
_scan="${_scan%@@rc=*}"
_states=()
[ -n "$_scan" ] && mapfile -t _states < <(printf '%s' "$_scan")
_fscan="$(find "$target" -maxdepth 3 -name 'FOCUSES.md' -not -path '*/.git/*' 2>&1 | sort; echo "@@rc=${PIPESTATUS[0]}")"
_fscan_rc="${_fscan##*@@rc=}"
[ "$_fscan_rc" = 0 ] || { echo "degraded: migrate-backlogs: scanning $target for FOCUSES.md failed (status $_fscan_rc)" >&2; exit 1; }
_fscan="${_fscan%@@rc=*}"
_focuses=()
[ -n "$_fscan" ] && mapfile -t _focuses < <(printf '%s' "$_fscan")
if [ "${#_states[@]}" -eq 0 ]; then
  echo "absent-input: no RESEARCH-STATE*.md under $target — nothing to migrate"
else
  for f in "${_states[@]}"; do
    b="$(basename "$f" .md)"
    case "$b" in RESEARCH-STATE-?*) label="${b#RESEARCH-STATE-}" ;; *) label="(root)" ;; esac
    skip=0
    ff="$(dirname "$f")/FOCUSES.md"
    if [ -r "$ff" ] && [ "$label" != "(root)" ]; then
      # exact parse of the FOCUSES.md table: slug cell (or state-file cell) == label AND status leading token == document
      doc="$(LC_ALL=C awk -v lab="$label" "$DOC_AWK" "$ff")" || { echo "migrate-backlogs: awk failed reading $ff" >&2; exit 1; }
      [ "$doc" = yes ] && skip=1
    fi
    n_files=$((n_files+1))
    propose "$label" "$f" "$BACKLOG_AWK" -v "skip_skel=$skip"
  done
  for ff in "${_focuses[@]+"${_focuses[@]}"}"; do
    n_files=$((n_files+1))
    propose "FOCUSES" "$ff" "$FOCUSES_AWK"
  done
fi
echo "migrate-backlogs: $n_files file(s) inspected · $n_prop with a mechanical proposal · $n_manual MANUAL line(s)"
exit 0
