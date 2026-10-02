#!/usr/bin/env bash
# gap-rows.sh — shared helpers for the backlog-row drift check (kit issues #1291, #1294).
# Sourced (never executed); consumers MUST fail closed:
#   # shellcheck source=lib/gap-rows.sh
#   . "$_grlib"
#   declare -F gap_rows_parse >/dev/null 2>&1 || { echo "<script>: helper lib/gap-rows.sh failed to define gap_rows_parse" >&2; exit 1; }
#
# Domain: a RESEARCH-STATE backlog row `| <priority> | B<n>-G<m> <text> | ... | <status> |` is a copy of
# the child-gap bullet that DEFINES that id in block <n> (`- **B<n>-G<m>** <text>`). When the row is
# paraphrased wrongly it silently points the loop at a different question (niagara5-research: 7 rows
# drifted, B50-G6 / B73-G2/G3 / B79-G1 / B82-G1..G3 — kit issue #1294 evidence). These helpers hold the
# parsing and the token-overlap measure; check-gap-drift.sh owns the verdicts.
#
# gap_rows_parse <state-file>
#   stdout (tab-separated, one record per line):
#     ROW<TAB><gid><TAB><block-number><TAB><pending|other><TAB><row text after the id>
#     SKIPPED<TAB><cell 2>                a gap-id row whose priority cell is a closed-class / history marker
#                                         (em-dash `—`, `~~strike~~`, or a number — iteration-history tables):
#                                         out of scope, counted by the caller, never UNPARSED (fleet sweep:
#                                         niagara-research carries ~50 such rows)
#     UNPARSED<TAB><first 90 chars>      a table row whose 2nd cell starts with a gap id but that is not
#                                         a valid `| high|medium|low|deferred | ... | status |` row
#   A table row is a line starting with `|` (leading blanks allowed). `\|` inside a cell is a literal
#   pipe. `pending` = status cell (last cell) starts with `pending` (case-insensitive).
#   exit: awk's status (>=2 = could not read — never laundered).
#
# gap_bullet_text <block-file> <gid>
#   stdout: the defining bullet plus up to 7 continuation lines (stops at the next gap bullet, a heading
#           or a blank line), joined with spaces. exit 0 = bullet found, 1 = no bullet, >=2 = IO error.
#   Recognised bullet forms (enumerated against the real niagara5-research corpus, NOT only fixtures):
#     `- **B1-G2** text`   `- **[B1-G2]** text`   `- **B1-G2 (state, note)** text`   `- **B1-G2**: text`
#   The id must be followed by a non-digit, so B4-G1 never matches B4-G10.
#
# gap_overlap <row-text> <bullet-text>
#   stdout: "<shared> <total>" — content words of the row (>=3 chars, [a-z][a-z0-9_.]*, stop words
#           removed, de-duplicated) that also occur in the bullet, and the row's content-word count.
#   Words are stemmed by stripping ONE trailing `s` (length > 3, not "ss"): `months`/`month` must not read
#   as drift (fleet sweep: B1009-G3). No other stemming — a heavier stemmer would hide real drift.
#   <total> = 0 means the row carries no comparable word (caller must not call that drift).
#   Text travels via ENVIRON, never `awk -v` (which would interpret backslash escapes in the text).

if ! declare -F gap_rows_parse >/dev/null 2>&1; then

  gap_rows_parse() {
    LC_ALL=C awk '
      { line=$0; sub(/\r$/,"",line) }
      line !~ /^[ \t]*\|/ { next }
      {
        t=line; sub(/^[ \t]*\|/,"",t); gsub(/\\\|/,"\001",t); sub(/\|[ \t]*$/,"",t)
        n=split(t,a,"|")
        for (k=1;k<=n;k++) { gsub(/^[ \t]+|[ \t]+$/,"",a[k]); gsub(/\001/,"|",a[k]) }
        if (a[2] !~ /^B[0-9]+-G[0-9]+([ \t]|$)/) next
        pr=a[1]
        if (pr ~ /^(—|~~|[0-9]+$)/) { printf "SKIPPED\t%s\n", a[2]; next }   # closed-class / history row: not a backlog row to compare
        if (n<4 || pr !~ /^(high|medium|low|deferred)$/) { printf "UNPARSED\t%s\n", substr(line,1,90); next }
        gid=a[2]; sub(/[ \t].*$/,"",gid)
        txt=a[2]; sub(/^B[0-9]+-G[0-9]+[ \t]*/,"",txt); gsub(/\t/," ",txt)
        bn=gid; sub(/^B/,"",bn); sub(/-G.*$/,"",bn)
        st=(tolower(a[n]) ~ /^pending/) ? "pending" : "other"
        printf "ROW\t%s\t%s\t%s\t%s\n", gid, bn, st, txt
      }
    ' "$1"
  }

  gap_bullet_text() {
    GAP_GID="$2" LC_ALL=C awk '
      BEGIN { gid=ENVIRON["GAP_GID"]; found=0; cont=0 }
      { line=$0; sub(/\r$/,"",line) }
      found==0 {
        if (match(line,/^[ \t]*[-*] \*\*\[?B[0-9]+-G[0-9]+/)) {
          s=line; sub(/^[ \t]*[-*] \*\*\[?/,"",s)
          if (substr(s,1,length(gid))==gid && substr(s,length(gid)+1,1) !~ /[0-9]/) { found=1; body=line }
        }
        next
      }
      {
        if (cont>=7) exit
        if (line ~ /^[ \t]*[-*] \*\*\[?B[0-9]+-G[0-9]+/ || line ~ /^#/ || line !~ /[^ \t]/) exit
        body=body " " line; cont++
      }
      END { if (found) { print body; exit 0 } else exit 1 }
    ' "$1"
  }

  gap_overlap() {
    GAP_ROW_TEXT="$1" GAP_BULLET_TEXT="$2" LC_ALL=C awk '
      function words(text, set,    w, rest) {
        text=tolower(text); rest=text
        while (match(rest,/[a-z][a-z0-9_.]+/)) {
          w=substr(rest,RSTART,RLENGTH); rest=substr(rest,RSTART+RLENGTH)
          if (length(w)>3 && w ~ /[^s]s$/) w=substr(w,1,length(w)-1)   # trailing-s stem: months=month, ordinals=ordinal; "ss" kept
          if (length(w)>=3 && !(w in stop)) set[w]=1
        }
      }
      BEGIN {
        n=split("an the of to in on for and or vs via is are be by with from at as it its this that whether which what why how not no any all full real exact own other",sw," ")
        for (i=1;i<=n;i++) stop[sw[i]]=1
        words(ENVIRON["GAP_ROW_TEXT"],rw); words(ENVIRON["GAP_BULLET_TEXT"],bw)
        tot=0; shared=0
        for (w in rw) { tot++; if (w in bw) shared++ }
        print shared, tot
      }
    '
  }

fi
