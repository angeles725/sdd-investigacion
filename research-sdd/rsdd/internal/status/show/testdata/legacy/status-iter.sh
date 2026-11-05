inv_count()    { stopctl | grep -iE 'read-only investigable' | grep -oE '[0-9]+' | head -1; }


# Corpus-level contradictions ledger(s) (informational — see METHODOLOGY §14). Optional file(s); ALL
# matching files are counted (never head-1-dropped), and >1 is WARNed to stderr like backlog_rows does.
contra_ledgers() { find "$corpus" -maxdepth 1 -name 'CONTRADICTIONS*.md' 2>/dev/null | sort; }
# Count ledger rows with an OPEN STATUS cell. Template columns: `| id | claim A | claim B | status | note |`
# → the STATUS cell is the 4th (column-scoped, mirroring backlog_rows gating on a fixed column). A row
# counts only when a[4] equals "open" exactly (lowercased) — a note/header/other cell saying "open", the
# "status" header, and the "---" separator never count. Sums across all files passed. Emits a bare integer.
count_open_contra() {
  awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      gsub(/\\\|/,"\001",line)  # GFM-EP-CONTRA (#2161): `\|` inside a cell is a literal pipe, not a separator
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); if (n<4) next
      gsub(/^[ \t]+|[ \t]+$/,"",a[4]); gsub(/\001/,"|",a[4]); if (tolower(a[4])=="open") c++ }
    END { print c+0 }' "$@"
}

# Iteration-history parser → a TYPED stream, ONE record per line (TAB-separated):
#   row\t<sortkey>\t<new-gaps>  a data row whose New-gaps cell is recognised (sortkey = the parsed
#                               iteration index, else file order — the table is chronological)
#   bad\t<raw-cell>             a data row whose New-gaps cell is present but UNRECOGNISED
#                               (gap-id list `G12`/`B3-G4`, `—`, prose) — reported, never guessed (§7)
#   col_none\t<header>          the table has no New-gaps / Nuevos gaps column at all
# The New-gaps column is selected BY HEADER NAME (/new gaps|nuevos gaps/i), NEVER by position: the fleet
# writes 8 header shapes and it is the last cell in only some of them (issue #420, 35/50 tables were
# BLIND under the old last-cell + integer-only rule). Recognised cell forms: a LEADING integer (`3`,
# `+1`, `3 new`, `2 seeded`, `3 new (focus STOP)`) → that integer; the `none…` family (`none`,
# `none net-new · …`, `none new — …`) → 0. A row with any `<...>` angle-bracket template placeholder
# cell is skipped silently (not a real iteration). Scoped to the bounded `## Iteration history` section
# only, mirroring the section()/backlog_rows idioms.
iter_gaps_rows() {
  section '## Iteration history' | awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    index($0,"<!--")>0 || index($0,"-->")>0 { next }        # skip HTML comments (may embed pipes)
    { l=trim($0)
      if (l !~ /\|/) next
      gsub(/\\\|/,"\001",l)  # GFM-EP-ITER (#2148): any `\|` is an escaped pipe, never a separator
      sub(/^\|/,"",l); sub(/\|$/,"",l)
      n=split(l,a,"|"); for(k=1;k<=n;k++) { a[k]=trim(a[k]); gsub(/\001/,"|",a[k]) }
      issep=1; for(k=1;k<=n;k++){ if(a[k] !~ /^:?-+:?$/){issep=0;break} }
      if (issep) next                                        # markdown "---" separator row
      if (!have_header) {                                    # first non-separator table row = header
        have_header=1
        for(k=1;k<=n;k++){ if(tolower(a[k]) ~ /new gaps|nuevos gaps/){ ngcol=k; break } }
        if (ngcol==0){ gsub(/\001/,"|",l); print "col_none\t" l; exit }  # GFM-EP-HDR-RESTORE (#2148): no raw mask byte reaches the output
        next
      }
      seq++
      ph=0; for(k=1;k<=n;k++){ if(a[k] ~ /^<.*>$/) ph=1 }    # <n>/<date>… template row → skip silently
      if (ph) next
      cell=a[ngcol]  # NG-COL-BYNAME
      idx=a[1]; sub(/^it\./,"",idx)
      if (match(idx,/^[0-9]+/)) { sk=substr(idx,RSTART,RLENGTH); type="row" } else { sk=seq; type="struct" }  # NG-STRUCT
      if (cell=="") { print type "\t" sk "\tbad\t(empty)"; next }   # empty cell is unreadable, NOT silently skipped (#442 review)
      isnone = (tolower(cell) ~ /^none/ || tolower(cell) ~ /^ningun/ || tolower(cell) ~ /^ningún/)  # NG-NONE
      if (cell ~ /^\+?[0-9]+/) { v=cell; sub(/^\+/,"",v); match(v,/^[0-9]+/); print type "\t" sk "\tok\t" (substr(v,RSTART,RLENGTH)+0) }
      else if (isnone) { print type "\t" sk "\tok\t0" }
      else { print type "\t" sk "\tbad\t" cell } }'      # gap-id lists (B754-G1/G2, IC1–IC4 seeded), — , prose
}
