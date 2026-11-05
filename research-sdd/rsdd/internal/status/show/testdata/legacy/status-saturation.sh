# SATURATION signal — INFORMATIONAL ONLY (a soft REVIEW prompt, NOT an auto-STOP). §8's read-only
# exhaustion stays the terminal trigger; exit codes, resolve_next, and the --next contract are UNTOUCHED
# (mirrors how contradictions are surfaced above). Over the LAST 3 recognised iterations (ordered by the
# parsed index): THRESHOLD = the window sums to EXACTLY 0 new gaps → SATURATED (review); any positive sum
# → active. THREE-STATE HONESTY (#420, §7): the section absent → (no iteration history); present but with
# no New-gaps column → "no New-gaps column (header: …)"; rows the parser could not read → a VISIBLE
# "N of M rows unreadable (forms: …)" WARN so a blind parse can never masquerade as "insufficient
# history (0)". <3 recognised rows → insufficient history. Never errors.
saturation_line() {
  local pad='  saturation      : '
  grep -qF '## Iteration history' "$state" || { echo "${pad}(no iteration history)"; return; }
  local stream colhdr iter_data struct_data all_sorted nrows nstruct w iter_window badwin wforms nbad forms sum warn note_struct note_seed total_rows last_struct_ok
  stream="$(iter_gaps_rows)"
  colhdr="$(printf '%s\n' "$stream" | awk -F'\t' '$1=="col_none"{print $2; exit}')"
  if [ -n "$colhdr" ]; then echo "${pad}no New-gaps column (header: ${colhdr})"; return; fi
  # iteration rows: parsable numeric index; structural rows: bootstrap/reopen/synthesis (no numeric idx)  # NG-STRUCT-SPLIT
  iter_data="$(printf '%s\n' "$stream" | awk -F'\t' '$1=="row"{print $2"\t"$3"\t"$4}' | sort -t$'\t' -k1,1n)"
  struct_data="$(printf '%s\n' "$stream" | awk -F'\t' '$1=="struct"{print $2"\t"$3"\t"$4}')"
  nrows="$(printf '%s' "$iter_data" | grep -c .)"
  nstruct="$(printf '%s' "$struct_data" | grep -c .)"
  # All data rows sorted stably by sk — struct rows at seq=K tie with iter rows at index=K; file position wins ties
  all_sorted="$(printf '%s\n' "$stream" | awk -F'\t' '($1=="row"||$1=="struct"){print $2"\t"$3"\t"$4}' | sort -s -t$'\t' -k1,1n)"  # NG-FORMS-STABLE-SORT NG-WFORMS-STRUCT
  # excluded-rows note — never silent: structural rows are always announced (#449)
  note_struct=""
  if [ "$nstruct" -gt 0 ]; then
    note_struct="  [${nstruct} unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]"
  fi
  # latest-unnumbered-row-seeded note: last data row in file order is a struct with ok positive gaps
  note_seed=""
  last_struct_ok="$(printf '%s\n' "$stream" | awk -F'\t' '($1=="row"||$1=="struct"){t=$1;s=$3;v=$4} END{if(t=="struct"&&s=="ok"&&v+0>0)print v+0}')"
  if [ -n "$last_struct_ok" ]; then
    note_seed="  · latest unnumbered row seeded ${last_struct_ok} gaps — not yet an iteration"
  fi
  if [ "$nrows" -lt 1 ]; then echo "${pad}insufficient history (0 iterations)${note_struct}${note_seed}"; return; fi
  w=$(( nrows < 3 ? nrows : 3 ))
  iter_window="$(printf '%s\n' "$iter_data" | tail -n "$w")"
  # WINDOW HONESTY: if any iter row in the last-w iter window is unreadable, do NOT compute on the
  # readable subset — a readable-but-older row must never rescue an unreadable tail (#420).
  badwin="$(printf '%s\n' "$iter_window" | awk -F'\t' '$2=="bad"' | grep -c .)"
  if [ "$badwin" -gt 0 ]; then  # NG-WINDOW
    wforms="$(printf '%s\n' "$iter_window" | awk -F'\t' '$2=="bad" && !seen[$3]++ {n++; if(n<=2)o=o (n>1?",":"") $3} END{print o}')"  # NG-WFORMS-ITER-ONLY
    echo "${pad}unreadable window — ${badwin} of last ${w} rows unrecognised (forms: ${wforms})${note_struct}${note_seed}"; return
  fi
  if [ "$nrows" -lt 3 ]; then echo "${pad}insufficient history ($nrows iterations)${note_struct}${note_seed}"; return; fi
  sum="$(printf '%s\n' "$iter_window" | awk -F'\t' '{s+=$3} END{print s+0}')"
  # partial WARN: count and collect forms in sortkey order (stable — ties by file position, struct included)
  total_rows=$(( nrows + nstruct ))
  nbad="$(printf '%s\n' "$all_sorted" | awk -F'\t' '$2=="bad"' | grep -c .)"
  warn=""
  if [ "$nbad" -gt 0 ]; then
    forms="$(printf '%s\n' "$all_sorted" | awk -F'\t' '$2=="bad" && !seen[$3]++ {n++; if(n<=2)o=o (n>1?",":"") $3} END{print o}')"
    warn="  [WARN: ${nbad} of ${total_rows} rows unreadable (forms: ${forms})]"
  fi
  if [ "$sum" -eq 0 ]; then
    echo "${pad}SATURATED (review) — last 3 iterations netted 0 new gaps${warn}${note_struct}${note_seed}"
  else
    echo "${pad}active ($sum new gaps in last 3 iter)${warn}${note_struct}${note_seed}"
  fi
}
