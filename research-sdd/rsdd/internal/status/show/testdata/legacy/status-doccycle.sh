# --- document-cycle mode (kit issue #1152) ------------------------------------------------------
# A corpus whose envelope says `method: document-cycle` (research-sdd-init.sh --document) is OUTLINE-driven:
# its ## Gap-backlog is empty on purpose, so gap saturation and "read-only-investigable exhausted" say nothing
# true about it. The DEFAULT REPORT then prints the Outline progress and a document-mode next step instead.
# Only the exact value `document-cycle` counts (`document-cycle-external` is a corpus authored outside this
# loop and keeps the gap-centric report), and only for a single-state-file corpus. `--next` is untouched.
#
# outline_rows — one TSV line per data row of the "## Outline" table: <#> TAB <item> TAB <status token>.
# A data row is a pipe row whose first cell is an integer; `\|` is cell text; the status token is the first
# word of the last non-empty cell, lowercased with bold marks stripped ("drafted (needs review)" -> drafted).
outline_rows() {
  section '## Outline' | awk '
    /^[[:space:]]*\|/ {
      line = $0; gsub(/\\\|/, "\001", line)  # GFM-EP-OUTLINE
      n = split(line, c, "|")
      for (i = 1; i <= n; i++) { gsub(/\001/, "|", c[i]); gsub(/^[ \t]+|[ \t]+$/, "", c[i]) }
      last = n; while (last > 2 && c[last] == "") last--
      if (c[2] !~ /^[0-9]+$/ || last < 4) next
      st = tolower(c[last]); gsub(/\*/, "", st); sub(/^[ \t]+/, "", st); split(st, w, /[ \t(]/)
      it = c[3]; sub(/^\*\*/, "", it); sub(/\*\*$/, "", it)
      printf "%s\t%s\t%s\n", c[2], it, w[1]
    }'
}
# outline_summary — sets _ol_state (empty | unseeded | seeded) and, for seeded, the counts
# _ol_total/_ol_cov/_ol_dra/_ol_pen/_ol_oth plus _ol_first ("<#> TAB <item>" of the first NON-covered row).
# Three states stay distinct (§7): a heading with no data rows, a table holding only the template placeholder
# (`<topic ...>`, which is not work), and a seeded table. A status outside covered/drafted/pending (plus the
# ✅ / cubierto spellings hand-written corpora use) is counted as unrecognised and stays OPEN — never silently
# covered. The caller guarantees the ## Outline heading exists (see _doc_mode).
outline_summary() {
  local _ol_num _ol_item _ol_tok _ol_rows=0 _ol_ph=0
  _ol_total=0; _ol_cov=0; _ol_dra=0; _ol_pen=0; _ol_oth=0; _ol_first=""
  while IFS=$'\t' read -r _ol_num _ol_item _ol_tok; do
    [ -n "$_ol_num" ] || continue
    _ol_rows=$(( _ol_rows + 1 ))
    case "$_ol_item" in '<'*'>') _ol_ph=$(( _ol_ph + 1 )); continue ;; esac
    _ol_total=$(( _ol_total + 1 ))
    case "$_ol_tok" in
      covered|done|closed|cubierto|✅) _ol_cov=$(( _ol_cov + 1 )) ;;  # DOC-COVERED-TOKENS
      drafted) _ol_dra=$(( _ol_dra + 1 )); [ -n "$_ol_first" ] || _ol_first="${_ol_num}"$'\t'"${_ol_item}" ;;
      pending) _ol_pen=$(( _ol_pen + 1 )); [ -n "$_ol_first" ] || _ol_first="${_ol_num}"$'\t'"${_ol_item}" ;;
      *) _ol_oth=$(( _ol_oth + 1 )); [ -n "$_ol_first" ] || _ol_first="${_ol_num}"$'\t'"${_ol_item}" ;;  # DOC-OTHER-OPEN
    esac
  done < <(outline_rows)
  if [ "$_ol_rows" -eq 0 ]; then _ol_state=empty
  elif [ "$_ol_total" -eq 0 ]; then _ol_state=unseeded
  else _ol_state=seeded; fi
}
outline_line() {
  local pad='  outline         : '
  case "$_ol_state" in
    empty)    echo "${pad}(0 rows — the Outline table is empty)" ;;
    unseeded) echo "${pad}(unseeded: only the template placeholder row)" ;;
    *)        echo "${pad}${_ol_cov}/${_ol_total} covered · drafted=${_ol_dra} · pending=${_ol_pen}$([ "$_ol_oth" -gt 0 ] && printf ' · unrecognised=%d' "$_ol_oth")" ;;
  esac
}
outline_next_step() {
  case "$_ol_state" in
    seeded)
      if [ -n "$_ol_first" ]; then printf 'NEXT | outline #%s | %s\n' "${_ol_first%%$'\t'*}" "${_ol_first#*$'\t'}"
      else printf 'STOP | outline fully covered (%d/%d)\n' "$_ol_cov" "$_ol_total"; fi ;;
    *) echo "BOOTSTRAP | seed the ## Outline first (document cycle step 1)" ;;
  esac
}
# A document-cycle corpus WITHOUT a `## Outline` heading is not Outline-driven in any way this report can read
# (hand-authored work-lists live elsewhere), so it keeps the gap-centric verdicts and says so on the outline line.
_doc_mode=0; _doc_noheading=0
if [ "$(env_get method)" = "document-cycle" ] && [ "$(list_state_files "$target" | wc -l | tr -d ' ')" -le 1 ]; then  # DOC-METHOD-EXACT
  if grep -qE '^## Outline' "$state"; then _doc_mode=1; else _doc_noheading=1; fi
fi

