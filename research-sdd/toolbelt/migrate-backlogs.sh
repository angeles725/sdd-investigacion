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
#            unknown-focus-status · empty-backlog-skeleton
# Other typed lines (stdout): `absent-input: ...` (corpus dir has no RESEARCH-STATE*.md), `empty-input: <focus>`
# (a 0-byte state file), `ok <focus>: nothing to migrate`, `PROPOSE <focus> <file>` before each diff, and always
# one closing `migrate-backlogs: N file(s) inspected · M with a mechanical proposal · K MANUAL line(s)` so a
# zero can be told from a run that never looked (CLAUDE.md §7). `degraded: ...` (stderr) when awk/diff is missing.
#
# Document-mode focuses (`document` in FOCUSES.md) have no backlog by design and get no skeleton proposal.
# Exit: 0 inspected (with or without proposals; proposals are findings, not failures) · 1 operational failure
# (awk/diff/mktemp unavailable, unreadable file) · 2 bad args or target is not a directory.
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
# Output: transformed file on stdout; MANUAL tallies "R<TAB>reason<TAB>line" on fd 3 (file $work/tally).
BACKLOG_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function iscanon(h) { return h ~ /^## Gap-backlog( \([^)]+\))?$/ }
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
  if ($0 ~ /^## /) { cur = FNR; h = norm($0); isbl[cur] = (tolower(h) ~ /backlog/); canon[cur] = iscanon(h); if (canon[cur]) anycanon = 1 }
  else if (cur && $0 ~ /^[ \t]*\|/ && !(cur in hdrseen)) {
    c = $0; sub(/^[ \t]*\|/, "", c); sub(/\|.*$/, "", c); c = tolower(trim(c)); gsub(/\*\*/, "", c)
    if (c ~ /^(priority|pr\.?|p|prioridad)$/) { hdr[cur] = 1; anyhdr = 1 }
    hdrseen[cur] = 1
  }
  next
}
FNR == 1 { cur = 0; inbl = 0; width = 0; indata = 0 }
{
  line = $0
  if (line ~ /^## /) {
    cur = FNR; h = norm(line); inbl = 0; width = 0; indata = 0
    if (canon[cur]) inbl = 1
    else if (isbl[cur] && hdr[cur]) { line = "## Gap-backlog"; inbl = 1; renamed = 1 }
    print line; next
  }
  if (!inbl || line !~ /^[ \t]*\|/) { print line; next }
  if (line ~ /\\\|/) { manual("malformed-row", FNR); print line; next }
  nc = cells(line)
  c1 = tolower(trim(raw[1])); gsub(/\*\*/, "", c1)
  if (c1 ~ /^-+$/ || c1 ~ /^:?-+:?$/) { width = (nc == 4 || nc == 5) ? nc : -1; indata = 1; print line; next }
  if (c1 ~ /^(priority|pr\.?|p|prioridad)$/) { print line; next }
  if (!indata || width <= 0 || nc != width) { if (indata) manual("malformed-row", FNR); print line; next }
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
  if (!anycanon && !renamed && !anyhdr && !skip_skel) {
    print ""
    print "## Gap-backlog"
    print ""
    print "| Priority | Gap | Artifact type / source | Status |"
    print "|---|---|---|---|"
    manual("empty-backlog-skeleton", 0)
  }
}
'

FOCUSES_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function manual(reason, ln) { print reason "\t" ln >> tally }
function cells(line,   body) {
  pre = line; sub(/\|.*$/, "", pre); body = line; sub(/^[ \t]*\|/, "", body)
  suf = ""; if (match(body, /\|[ \t]*$/)) { suf = substr(body, RSTART); body = substr(body, 1, RSTART - 1) }
  nc = split(body, raw, "|")
}
function rebuild(   i, out) { out = pre "|"; for (i = 1; i <= nc; i++) out = out raw[i] (i < nc ? "|" : ""); return out suf }
{
  line = $0
  if (line !~ /^[ \t]*\|/) { print line; next }
  cells(line)
  if (!scol) {
    for (i = 1; i <= nc; i++) { c = tolower(trim(raw[i])); gsub(/\*\*/, "", c); if (c == "status" || c == "estado") { scol = i; break } }
    print line; next
  }
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
  if ! cmp -s "$f" "$out"; then
    changed=1; n_prop=$((n_prop+1))
    echo "PROPOSE $label $rel"
    diff -u --label "a/$rel" --label "b/$rel" "$f" "$out"
  fi
  local reasons r cnt first
  reasons="$(cut -f1 "$tally" | sort -u)"
  for r in $reasons; do
    cnt="$(awk -F'\t' -v r="$r" '$1==r' "$tally" | wc -l | tr -d ' ')"
    first="$(awk -F'\t' -v r="$r" '$1==r {print $2; exit}' "$tally")"
    echo "MANUAL $label $r rows=$cnt first-line=$first"
    n_manual=$((n_manual+1))
  done
  if [ "$changed" = 0 ] && [ -z "$reasons" ]; then echo "ok $label: nothing to migrate"; fi
}

mapfile -t _states < <(list_state_files "$target")
if [ "${#_states[@]}" -eq 0 ]; then
  echo "absent-input: no RESEARCH-STATE*.md under $target — nothing to migrate"
else
  for f in "${_states[@]}"; do
    b="$(basename "$f" .md)"
    case "$b" in RESEARCH-STATE-?*) label="${b#RESEARCH-STATE-}" ;; *) label="(root)" ;; esac
    skip=0
    ff="$(dirname "$f")/FOCUSES.md"
    if [ -r "$ff" ] && [ "$label" != "(root)" ] && grep -E "^\|.*${label}.*\|.*document" "$ff" >/dev/null 2>&1; then skip=1; fi
    n_files=$((n_files+1))
    propose "$label" "$f" "$BACKLOG_AWK" -v "skip_skel=$skip"
  done
  while IFS= read -r ff; do
    n_files=$((n_files+1))
    propose "FOCUSES" "$ff" "$FOCUSES_AWK"
  done < <(find "$target" -maxdepth 3 -name 'FOCUSES.md' -not -path '*/.git/*' 2>/dev/null | sort)
fi
echo "migrate-backlogs: $n_files file(s) inspected · $n_prop with a mechanical proposal · $n_manual MANUAL line(s)"
exit 0
