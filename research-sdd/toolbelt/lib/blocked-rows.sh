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
#   blocked_open_count FILE             derived blocked_open: an integer on stdout, rc 0.
#                                       FILE absent or unreadable: NOTHING on stdout, a typed message on
#                                       stderr, rc 2 — absent-input is never a silent 0 (CLAUDE.md §7).
#
# What counts (unchanged from the two scripts' shared behaviour, plus the #913 closed-entry rule):
#   1. Standard sections: every bullet line carrying `needs:` (`^\s*-\s.*needs:`, so a bare `- none`
#      placeholder never counts) OR any line carrying the bold prose form `**needs:**`.
#   2. `## Child gaps surfaced at close`: multi-line bullet entries; an entry counts ONCE when `needs:`
#      appears on its bullet line or on a continuation line before the next blank line / bullet.
#   3. (#913) a child-gap entry whose BULLET line carries a closed marker does not count, even when it
#      keeps a `needs:` clause for the record. Closed markers: `~~` striking the whole entry (it must open
#      the bullet content: `- ~~G9 …`, `- **~~G9 …`; a partial strike mid-line closes nothing), `✅`, the
#      uppercase WHOLE WORDS `CERRADO` / `CLOSED` (`CLOSED-LOOP` and `ENCLOSED` are not the word, and a
#      `NOT` / `NO` / `NEVER` within the two words before it negates it, as in `NOT YET CLOSED`; those are whole
#      words too, so `X-NO CLOSED` is not negated, and `CLOSEDCLOSED` is not the word).
#      Window semantics: a "word" is a run of [A-Za-z0-9_-]; punctuation and `—` between words do not stop the
#      window (`NOT — CLOSED` is negated), and non-ASCII bytes split words (an accented letter ends one)., and a bracketed `[closed]` / `[cerrado]` in any case. The match
#      is on the bullet line only, so prose such as "not closed" in an OPEN entry never closes it. Standard blocked sections are unaffected: an entry listed there is blocked
#      by definition (a closed gap leaves them, METHODOLOGY §21.1).

blocked_rows_section() {   # FILE HEADING
  awk -v h="$2" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$1"
}

blocked_rows_body() {      # FILE
  blocked_rows_section "$1" '## Blocked gaps'
  blocked_rows_section "$1" '## Non-investigable gaps'
  blocked_rows_section "$1" '## Blocked /'
}

blocked_open_count() {     # FILE
  local _f="$1" _d1 _d2
  if [ ! -r "$_f" ] || [ -d "$_f" ]; then
    echo "blocked-rows: state file absent or unreadable: ${_f:-<empty path>}" >&2
    return 2
  fi
  _d1="$(blocked_rows_body "$_f" | grep -icE '^[[:space:]]*-[[:space:]].*needs:|\*\*needs:\*\*')"  # RSDD-PROSE-BLOCKED-ANCHOR
  # RSDD-CHILD-GAPS-ANCHOR: multi-line bullet form in ## Child gaps surfaced at close
  _d2="$(blocked_rows_section "$_f" '## Child gaps surfaced at close' | awk '
    function negated(pre,   p, k, w) {                       # NEGATION-WINDOW: NOT/NO/NEVER in the 2 words before
      p = pre
      for (k = 0; k < 2; k++) {
        if (!match(p, /[A-Za-z0-9_-]+[^A-Za-z0-9_-]*$/)) return 0
        w = substr(p, RSTART, RLENGTH); sub(/[^A-Za-z0-9_-]+$/, "", w)
        if (w == "NOT" || w == "NO" || w == "NEVER") return 1      # whole word, same boundary set as bef/aft
        p = substr(p, 1, RSTART - 1)
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
    END { print n+0 }')"
  echo $(( ${_d1:-0} + ${_d2:-0} ))
}
