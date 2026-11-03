deferred_scan() {
  awk -v emit="$1" '
    # DEF-AWK-START (byte-identical in research-sdd-status.sh deferred_scan and verify-state.sh derive_deferred; the populations suite diffs the two)
    FNR==1 { ib=0; ex=0; tok=0; prv="" }
    /^## / { ib=($0 ~ /^## Gap-backlog( \([^)]+\))?$/); ex=0; tok=0; prv=""; next }
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) { prv=""; next }
      gsub(/\\\|/,"\001",line)  # GFM-EP-DEFERRED (#2148): any `\|` is an escaped pipe, never a separator
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      cnt=split(line,a,"|"); for(k=1;k<=cnt;k++) { gsub(/^[ \t]+|[ \t]+$/,"",a[k]); gsub(/\001/,"|",a[k]) }
      p=tolower(a[1]); pv=prv; prv=p; gsub(/\*\*/,"",pv)
      if (p ~ /^-+$/) { ex=cnt; tok=(pv ~ /^(priority|pr\.?|p|prioridad)$/); next }  # DEF-TABLE-WIDTH (#2162): the separator row fixes the table width; a Priority header marks a backlog table outside ## Gap-backlog
      if (p!="deferred") next
      if (!ib && !tok) next  # DEF-SCOPE (#2162): same population as backlog_rows — a ## Gap-backlog section, or a table with a Priority header
      sc=(ex>0)?ex:4
      if (sc!=4 && sc!=5) { print "WARN: deferred row skipped (table width " sc ", only 4 or 5 supported): " $0 > "/dev/stderr"; next }  # DEF-WIDTH-WARN
      if (cnt!=sc) { print "WARN: deferred row skipped (" cnt " cells, table width " sc " — a bare pipe in a cell?): " $0 > "/dev/stderr"; next }  # DEF-WIDTH-WARN (#2162): never a silent drop, never counted
      st=tolower(a[cnt])  # DEF-STATUS-LAST: status is the last cell of either width
      if (index(a[2],"~~") || (sc==5 && index(a[3],"~~")) || index(st,"~~") || index(st,"✅")) next  # DEF-CLOSED: ~~ in the first two cells (the Gap cell of either 5-column layout), or ~~ / a check mark in the status
      gsub(/^\*\*/,"",st)
      if (emit) print "deferred-open\t" a[2] "\t" st
      n++ }
    END { if (!emit) print n+0 }
    # DEF-AWK-END
  ' "$state"
}
count_deferred() { deferred_scan 0; }

# Backlog rows: reads ALL priority-tagged rows from ALL ## Gap-backlog sections AND any table whose
# separator reveals a 4- or 5-column layout and sits outside a Gap-backlog heading (non-canonical
# placement is counted but emits OOB-WARN per METHODOLOGY §8b).
# Emits "priority<TAB>gap-key<TAB>status" (gap-key = gap text for 4-col; ID for 5-col since a[2] = id).
# Column layout: 4-col (`| p | gap | type | status |`) OR 5-col (`| p | id | gap | artifact | status |`);
# expected_cols is set from the separator row and governs column-width acceptance (4 or 5 only; any
# other width emits BP-WIDTH-WARN and rows in that table are skipped) and status extraction (a[4] vs a[5]).
# An unknown priority emits a diagnostic to stderr AND INVALID_PRIORITY<TAB><val> to stdout.
# Callers that care check for the sentinel; callers that don't safely ignore the 2-field line.
# Closed-class rows (deferred / strikethrough ~~p~~ / em-dash —) are emitted ONLY when called with arg 1
# (count_all_known_gaps, kit #1307) with priority token `deferred` (closed rows only: open deferred rows
# belong to count_deferred), `~~` or `—`; every other caller never sees them. An em-dash row whose Status
# is open (pending / requires-execution / open / queued / blocked*) is WARNed and excluded (§8b: em-dash
# means closed only). Tables OUTSIDE a Gap-backlog heading count only when a priority-shaped header row
# (Priority / Pr. / P / Prioridad) precedes the separator; otherwise WARN + ignore (a Severity table is not
# a backlog). Unknown tier tokens under a near-miss backlog heading WARN (never INVALID_PRIORITY).
# Silently skips: COVERED rows whose status
# cell contains a pipe (5C-COVERED-PIPE-SKIP / SS-567-COVERED-PIPE-SKIP). Qualifier forms (e.g.
# "high (context)") emit a WARN to stderr and are excluded. Unknown qualifier BASE fails closed.
# Note: "med" abbreviation is NOT normalized here — that is a separate calibration work unit (#941).
#   Rows with priority "med" emit INVALID_PRIORITY and are excluded from counts.
# U+2011-NORM: non-breaking hyphens (U+2011, UTF-8 octet \342\200\221) in heading lines are normalised
#   to ASCII hyphen by an awk gsub so "## Gap‑backlog (prioritized)" matches the heading pattern.
#   Scoped to heading lines only (not a whole-file rewrite); portable (no GNU sed \xNN syntax).
backlog_rows() {
  LC_ALL=C awk -v want_closed="${1:-0}" '
    # BACKLOG-ROWS-AWK-START
    # UNC-FN (#1350): UNCOUNTED marks the derived count a LOWER BOUND, so it is emitted only for a real table row (a line that
    # starts with a pipe); a prose line that merely contains pipes must never trigger the sync-state keep.
    function unc(tier) { if (isrow) print "UNCOUNTED\t" tier }
    /^## Gap-backlog( \([^)]+\))?$/ { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _nm_was_last=0; in_backlog=1; in_data=0; expected_cols=0; tbl_ok=0; prev_p=""; next }  # OOB-WARN-FLUSH
    /^## / && tolower($0) ~ /backlog/ { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _this_line_nm=1; print "WARN: near-miss gap-backlog heading [" $0 "] — expected \"## Gap-backlog\" or \"## Gap-backlog (<label>)\" per METHODOLOGY" > "/dev/stderr" }  # NM-WARN
    /^## / { if (!_this_line_nm) { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _nm_was_last=0 }; _nm_was_last=_this_line_nm; _this_line_nm=0; in_backlog=0; in_data=0; expected_cols=0; tbl_ok=0; prev_p=""; next }
    { isrow = ($0 ~ /^[ \t]*\|/); line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) { prev_p=""; next }
      gsub(/\\\|/,"\001",line)  # BP-ESCAPED-PIPE (#1319): `\|` inside a cell is a literal pipe, not a separator; restored after the split
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); for(k=1;k<=n;k++) { gsub(/^[ \t]+|[ \t]+$/,"",a[k]); gsub(/\001/,"|",a[k]) }
      p=tolower(a[1]); pp=prev_p; prev_p=p; gsub(/\*\*/,"",pp)
      if (p~/^-+$/) { in_data=1; tbl_ok=(pp ~ /^(priority|pr\.?|p|prioridad)$/); tbl_warned=0; if (!in_backlog) { expected_cols=(n==4||n==5)?n:0; next }; expected_cols=(n==4||n==5)?n:-1; if (expected_cols<0) print "WARN: backlog table has " n " columns (separator: " $0 ") — only 4- or 5-column tables accepted per METHODOLOGY §8b; rows will be skipped" > "/dev/stderr"; next }  # BP-EXPECTED-COLS: accept only 4- or 5-col backlog tables; BP-WIDTH-WARN on unsupported width; BP-SEP-IN-BACKLOG: separator outside a Gap-backlog section sets in_data and the 4/5 width (so OOB rows parse per their own width, #983) but does not WARN
      if (p~/^-/) { next }    # BP-LIST-ITEM-GUARD: prose list items (markdown dash marker with pipes in text) are not table rows; safe after all-dashes check above
      if (p=="" || p=="priority" || p=="p") { next }
      if (p=="deferred" || p~/^~~.*~~$/ || p~/^—/) {  # CLOSED-CLASS: closed/parked rows are COUNTED in known_gaps (never routable); only emitted when want_closed=1 (#1307)
        if (!want_closed) next
        if (expected_cols<0) next
        if (!in_backlog && !tbl_ok) { if (_nm_was_last && in_data) { if (!tbl_warned) { print "WARN: table under a near-miss backlog heading has no Priority header — its rows are NOT read (not a backlog, or add a Priority column)" > "/dev/stderr"; tbl_warned=1 }; unc(p) }; next }  # CC-NOHDR-UNCOUNTED
        sc = (expected_cols > 0) ? expected_cols : 4
        if (n!=sc) { if (in_backlog && in_data) { print "WARN: malformed closed-class backlog row (" n " cells, expected " sc "): " $0 > "/dev/stderr"; unc(p) }; next }  # CC-MALFORMED-UNCOUNTED (#1319): a malformed row makes the derived count a LOWER BOUND (sync-state only)
        st = (sc==5) ? tolower(a[5]) : tolower(a[4]); gsub(/^\*\*/, "", st); gsub(/\*\*$/, "", st); split(st,tk," "); tok=tk[1]
        if (p=="deferred") { if (!(index(a[2],"~~") || (sc==5 && index(a[3],"~~")) || index(st,"~~") || index(st,"✅"))) next; cp="deferred" }  # CC-DEFERRED-CLOSED: open deferred rows are counted by count_deferred/derive_deferred, not here
        else if (p~/^—/) { if (tok ~ /^(pending|requires-execution|open|queued|blocked)/) { print "WARN: em-dash priority on an OPEN row [" tok "] — METHODOLOGY §8b: em-dash means closed only; row NOT counted (give it a real tier): " $0 > "/dev/stderr"; next }; g=a[2]; gsub(/^(\*\*|~~|`|\[)+/,"",g); sub(/[ \t·:—(].*$/,"",g); gsub(/[*~`\]]+$/,"",g); if (g !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || g !~ /[0-9]/) { print "WARN: em-dash row whose Gap cell is not a gap id — treated as a note, NOT counted: " $0 > "/dev/stderr"; next }; cp="—" }  # CC-EMDASH-OPEN-WARN CC-EMDASH-NOTE
        else cp="~~"
        if (!in_backlog && in_data) { _oob_count++ }
        print cp "\t" a[2] "\t" st; next }
      base=p; sub(/ *\([^)]*\)$/, "", base)
      if (base != p) {  # BPSKIP-QUALIFIER: "base (qualifier)" — valid base emits WARN to stderr, still excluded; else fail closed
        if (base=="high" || base=="medium" || base=="low" || base=="deferred") { if (in_backlog && in_data) print "WARN: non-conforming qualifier priority [" p "] — strip the qualifier to \"" base "\" per METHODOLOGY §8b; row excluded from investigable_open until migrated" > "/dev/stderr"; next }  # BP-QUALIFIER-WARN
        if (in_backlog && in_data) {
          print "backlog: unknown priority [" p "] in row: " $0 > "/dev/stderr"
          print "INVALID_PRIORITY\t" p
        }
        next
      }
      if (p!="high" && p!="medium" && p!="low") {
        if (in_backlog && in_data) {
          print "backlog: unknown priority [" p "] in row: " $0 > "/dev/stderr"
          print "INVALID_PRIORITY\t" p
        } else if (_nm_was_last && in_data && !tbl_ok) { if (!tbl_warned) { print "WARN: table under a near-miss backlog heading has no Priority header — its rows are NOT read (not a backlog, or add a Priority column)" > "/dev/stderr"; tbl_warned=1 }; if (want_closed) unc(p) }  # NM-NOHDR-UNCOUNTED
        else if (_nm_was_last && in_data && tbl_ok) { print "WARN: unknown priority [" p "] in near-miss backlog row — excluded from counts; not a METHODOLOGY §8b tier: " $0 > "/dev/stderr"; if (want_closed) unc(p) }  # NM-UNKNOWN-WARN: UNCOUNTED marks the derived known_gaps as a LOWER BOUND (sync-state only)
        next
      }
      if (!in_backlog && !tbl_ok) { if (!tbl_warned) { print "WARN: table outside a Gap-backlog section has no Priority header — high/medium/low rows ignored (not a backlog; METHODOLOGY §8b)" > "/dev/stderr"; tbl_warned=1 }; if (_nm_was_last && in_data && want_closed) unc(p); next }  # OOB-NO-PRIORITY-HEADER
      if (!in_backlog && in_data) { _oob_count++ }  # OOB-ACCUM: accumulate per-section; flushed at ## heading or EOF
      if (expected_cols < 0) { next }  # BP-WIDTH-SKIP: unsupported table width; WARN already emitted on separator
      sc = (expected_cols > 0) ? expected_cols : 4  # BP-SC-FALLBACK: default 4 if no separator seen yet
      sc_msg = (expected_cols > 0) ? sc : "4 or 5"  # BP-SC-MSG: "4 or 5" when no separator seen (fallback context)
      if (n!=sc) {
        if (sc==5 && n>sc && tolower(a[5]) ~ /^covered/) { print "WARN: COVERED row has " n " cells in 5-col table (pipe in status cell) — review: " $0 > "/dev/stderr"; next }  # SS-COVERED-PIPE-WARN: COVERED rows with extra cells emit WARN, not silent drop
        if (sc==4 && n>sc && tolower(a[4]) ~ /^covered/) { print "WARN: COVERED row has " n " cells in 4-col table (pipe in status cell) — review: " $0 > "/dev/stderr"; next }  # SS-567-COVERED-PIPE-WARN: COVERED rows with extra cells emit WARN, not silent drop
        if (in_backlog && in_data) { print "WARN: malformed backlog row (" n " cells, expected " sc_msg " — a cell may contain a pipe): " $0 > "/dev/stderr"; if (want_closed) unc(p) }  # SS-MALFORMED-WARN CC-MALFORMED-UNCOUNTED (#1319): scoped to in_backlog only (N3)
        next }
      { st = (sc==5) ? tolower(a[5]) : tolower(a[4]); gsub(/^\*\*/, "", st); gsub(/\*\*$/, "", st) }  # SS-634-BOLD-STRIP: strip leading/trailing ** from status field (a[4] for 4-col, a[5] for 5-col)
      print p "\t" a[2] "\t" st }
    END { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr" }  # OOB-WARN-EOF
  ' "$state"
}
