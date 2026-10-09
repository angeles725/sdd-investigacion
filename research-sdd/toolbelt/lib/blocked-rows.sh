#!/usr/bin/env bash
# blocked-rows.sh — the ONE definition of "which RESEARCH-STATE entries are blocked" (kit #923, #913).
#
# Sourced, never executed. research-sdd-status.sh and verify-state.sh previously each carried a hand
# copy of the section extractor, of the three blocked headings and of the awk that counts multi-line
# `## Child gaps surfaced at close` entries; the copies could drift (CLAUDE.md single-definition rule).
# Both now call these functions, so the derived blocked_open can only mean one thing.
#
# Functions (all take the STATE FILE path, never a global):
#   blocked_rows_section FILE HEADING   body of the first-level "## <HEADING>..." section(s) whose heading
#                                       line STARTS with HEADING (index()==1: no regex, no substring hit)
#   blocked_rows_body FILE              the text blocked_open is derived from: `## Blocked gaps`, then
#                                       `## Non-investigable gaps`, then `## Blocked /` (METHODOLOGY §21.1)
#                                       Returns the FIRST non-zero rc of its three extractors (all three still run).
#   blocked_open_count FILE             derived blocked_open: an integer on stdout, rc 0.
#                                       FILE absent or unreadable: NOTHING on stdout, a typed message on
#                                       stderr, rc 2 — absent-input is never a silent 0 (CLAUDE.md §7).
#                                       A stage that could not run (awk/grep missing, crashing or erroring, or
#                                       yielding a non-integer): NOTHING on stdout, `blocked-rows: degraded <why>`
#                                       on stderr, rc 3 — a broken instrument is never a confident 0. Callers MUST
#                                       check the rc (command substitution hides it unless `|| ...` is used).
#
# What counts (unchanged from the two scripts' shared behaviour, plus the #913 closed-entry rule):
#   1. Standard sections: every bullet line carrying `needs:` (`^\s*-\s.*needs:`, so a bare `- none`
#      placeholder never counts) OR any line carrying the bold prose form `**needs:**`.
#   2. `## Child gaps surfaced at close`: multi-line bullet entries; an entry counts ONCE when `needs:`
#      appears on its bullet line or on a continuation line before the next blank line / bullet.
#   3. (#913) a child-gap entry whose BULLET line carries a closed marker does not count, even when it
#      keeps a `needs:` clause for the record. Closed markers: `~~` striking the whole entry (it must open
#      the bullet content: `- ~~G9 …`, `- **~~G9 …`; a partial strike mid-line closes nothing), `✅`, the
#      uppercase WHOLE WORDS `CERRADO` / `CLOSED` (`CLOSED-LOOP`, `ENCLOSED` and `CLOSEDCLOSED` are not the word),
#      or a bracketed `[closed]` / `[cerrado]` in any case. A `NOT` / `NO` / `NEVER` within the two words before
#      CLOSED/CERRADO negates it, as in `NOT YET CLOSED`; the negation words are whole words (`X-NO CLOSED` is
#      not negated); the CLOSED/CERRADO marker stays uppercase. Case rule (#2018): a negation word matches in ANY
#      case only when it is DIRECTLY adjacent to the marker or separated from it only by the fillers `YET` /
#      `LONGER` (any case): `Not CLOSED`, `no longer closed`, `not yet CLOSED` negate. Anywhere else in the
#      window only the UPPERCASE `NOT` / `NO` / `NEVER` negate, so lowercase prose such as `no repro — CLOSED`,
#      `not needed, CLOSED` or `no reproducible — CLOSED` is a closed gap, not a negated one.
#      Known ambiguity: `regression? no — CLOSED` reads as NEGATED (a lowercase `no` adjacent to the marker, after
#      punctuation, is indistinguishable from `no CLOSED`), so that closed gap is counted as open (a false open, never
#      a silent zero). Reword it (or drop the lowercase `no`) to close it.
#      Window semantics: a "word" is a run of [A-Za-z0-9_-]; punctuation and `—` between words do not stop the
#      window (`NOT — CLOSED` is negated), a standalone run of `-` / `_` (`NOT YET - CLOSED`) is not a word and
#      uses no slot, and non-ASCII bytes split words (an accented letter ends one). The match is on the bullet
#      line only, so prose such as "not closed" in an OPEN entry never closes it. Standard blocked sections are
#      unaffected: an entry listed there is blocked by definition (a closed gap leaves them, METHODOLOGY §21.1).

blocked_rows_section() {   # FILE HEADING
  awk -v h="$2" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$1"
}

blocked_rows_body() {      # FILE
  local _br_rc=0 _br_h _br_r
  for _br_h in '## Blocked gaps' '## Non-investigable gaps' '## Blocked /'; do
    blocked_rows_section "$1" "$_br_h"; _br_r=$?          # BODY-RC: remember the FIRST failing extractor, but still run the rest
    [ "$_br_r" -eq 0 ] || [ "$_br_rc" -ne 0 ] || _br_rc=$_br_r
  done
  return "$_br_rc"
}

blocked_open_count() {     # FILE
  local _f="$1" _body _sec _d1 _d2 _rc
  if [ ! -r "$_f" ] || [ -d "$_f" ]; then
    echo "blocked-rows: state file absent or unreadable: ${_f:-<empty path>}" >&2
    return 2
  fi
  # Every stage's exit status is captured: an awk/grep that cannot run or errors must surface as a typed
  # degraded state (rc 3), never as a confident 0 (CLAUDE.md §7, third question: could the instrument run?).
  _body="$(blocked_rows_body "$_f")"; _rc=$?
  [ "$_rc" -eq 0 ] || { echo "blocked-rows: degraded section extractor (awk) exited $_rc on $_f" >&2; return 3; }
  _d1="$(printf '%s\n' "$_body" | grep -icE '^[[:space:]]*-[[:space:]].*needs:|\*\*needs:\*\*')"; _rc=$?  # RSDD-PROSE-BLOCKED-ANCHOR
  # grep -c prints the count and exits 1 on zero matches; only rc >= 2 is an error
  [ "$_rc" -le 1 ] || { echo "blocked-rows: degraded standard-section counter (grep) exited $_rc on $_f" >&2; return 3; }
  _sec="$(blocked_rows_section "$_f" '## Child gaps surfaced at close')"; _rc=$?
  [ "$_rc" -eq 0 ] || { echo "blocked-rows: degraded child-gap extractor (awk) exited $_rc on $_f" >&2; return 3; }
  # RSDD-CHILD-GAPS-ANCHOR: multi-line bullet form in ## Child gaps surfaced at close
  _d2="$(printf '%s\n' "$_sec" | awk '
    function negated(pre,   p, k, w, u, fill) {              # NEGATION-WINDOW: NOT/NO/NEVER in the 2 words before
      p = pre; k = 0; fill = 1                               # fill: every word between here and CLOSED is a filler
      while (k < 2) {
        if (!match(p, /[A-Za-z0-9_-]+[^A-Za-z0-9_-]*$/)) return 0
        w = substr(p, RSTART, RLENGTH); sub(/[^A-Za-z0-9_-]+$/, "", w)
        p = substr(p, 1, RSTART - 1)
        if (w ~ /^[-_]+$/) continue                          # DASH-SKIP: a bare - / _ run is punctuation, not a word
        u = toupper(w)                                       # NEGATION-ICASE: adjacent / filler-separated negation matches in any case
        if (u == "NOT" || u == "NO" || u == "NEVER") {       # whole word, same boundary set as bef/aft
          if (fill || w == u) return 1                       # NEGATION-ADJACENT: any case only when adjacent (or via YET/LONGER); else UPPERCASE only
        }
        if (u != "YET" && u != "LONGER") fill = 0            # NEGATION-FILLER: the known fillers keep the any-case rule alive
        k++
      }
      return 0
    }
    function has_word(s, w,   t, off, pos, rl, bef, aft) {  # whole-word match; negated by NOT/NO/NEVER just before
      t = s; off = 0
      while (match(t, w)) {
        pos = off + RSTART; rl = RLENGTH                     # RESCAN-OFFSET: position in the ORIGINAL string
        bef = (pos > 1) ? substr(s, pos - 1, 1) : ""; aft = substr(s, pos + rl, 1)
        if (bef !~ /[A-Za-z0-9_-]/ && aft !~ /[A-Za-z0-9_-]/ && !negated(substr(s, 1, pos - 1))) return 1
        off = pos + rl - 1; t = substr(s, off + 1)           # keep the real preceding char after a rejected match
      }
      return 0
    }
    function is_closed(s) {                                  # CHILD-CLOSED-MARKER (#913)
      if (s ~ /^[[:space:]]*-[[:space:]]+(\*\*)?~~/) return 1   # CLOSED-STRIKE
      if (index(s, "✅")) return 1                            # CLOSED-TICK
      if (has_word(s, "CERRADO")) return 1                    # CLOSED-CERRADO
      if (has_word(s, "CLOSED")) return 1                     # CLOSED-WORD
      return (tolower(s) ~ /\[(closed|cerrado)\]/)            # CLOSED-BRACKET
    }
    BEGIN { n=0; ib=0; done=0; cl=0 }
    /^[[:space:]]*$/ { ib=0; done=0; cl=0; next }
    /^[[:space:]]*-[[:space:]]/ { ib=1; done=0; cl=is_closed($0)
      if (!cl && tolower($0) ~ /needs:/) { n++; done=1 }
      next }
    { if (ib && !done && !cl && tolower($0) ~ /needs:/) { n++; done=1 } }
    END { print n+0 }')"; _rc=$?
  [ "$_rc" -eq 0 ] || { echo "blocked-rows: degraded child-gap counter (awk) exited $_rc on $_f" >&2; return 3; }
  case "$_d1" in ''|*[!0-9]*) echo "blocked-rows: degraded standard-section counter gave non-integer [$_d1] on $_f" >&2; return 3 ;; esac
  case "$_d2" in ''|*[!0-9]*) echo "blocked-rows: degraded child-gap counter gave non-integer [$_d2] on $_f" >&2; return 3 ;; esac
  echo $(( _d1 + _d2 ))
}
