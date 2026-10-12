#!/usr/bin/env bash
# table-reader-parity.test.sh — the RESEARCH-STATE.md table readers listed below apply the SAME escape rule (kit issue #2148).
#
# THE RULE (verified by rendering through GitHub: POST /markdown, mode gfm): ANY `\|` inside a table cell is an
# escaped pipe, regardless of the backslashes before it. `| x\\| y | z |` renders ONE cell, `x| y`; `| m\\\| n |`
# renders ONE cell, `m\| n`. An even run of backslashes is NOT a column break. Two instruments reading one table
# with different escape rules is the §7 two-populations defect, so this suite feeds ONE shared fixture
# (`fixtures/table-reader-parity/`: `\|`, `\\|`, `\\\|` in the first, a middle and the last cell) to every reader
# and asserts that they agree with each other and with the GFM expectation:
#   verify-state.sh          backlog rows (investigable), deferred rows, Iteration-history Block column
#   research-sdd-status.sh   backlog rows, deferred rows, Iteration-history Block column and New-gaps column,
#                            open-deferred rows of the --queue reader, document-cycle Outline rows
#   lib/gap-rows.sh          gap_rows_parse
# Kit issue #2161 adds the readers that were still on a bare-pipe split:
#   research-sdd-status.sh   count_open_contra (CONTRADICTIONS ledger, STATUS = 4th cell) and the FOCUSES.md
#                            status reader _read_focuses_tok_uncached
#   focus-partition-audit.sh FOCUSES.md row cells and the Research-State column
#   migrate-backlogs.sh      FOCUSES.md status rewrite (cells/setcell/rebuild) and the document-focus lookup
#   verify-sources.sh        the SOURCES.md registry column-count pre-check
# NOT covered here: the §18 delta-table parsers and append-iteration-row.sh (a writer that also reads the
# Iteration-history table; kit PR #2147 aligns them); the other bare-pipe readers inside verify-sources.sh
# (citation, orphan, hash and empty-digest loops) and the backlog path of migrate-backlogs.sh, which reports an
# escaped-pipe row as MANUAL malformed-row on purpose.
#
# --prove-teeth builds one mutant per reader call site (the escape step removed, i.e. the pre-GFM no-escape split)
# and requires the probe that watches THAT site to turn red.
#
# Usage: table-reader-parity.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
FX="$HERE/fixtures/table-reader-parity"
for f in verify-state.sh research-sdd-status.sh lib/gap-rows.sh focus-partition-audit.sh migrate-backlogs.sh verify-sources.sh; do
  [ -f "$TOOLBELT/$f" ] || { echo "FATAL: SUT not found: $TOOLBELT/$f" >&2; exit 2; }
done
for f in state/RESEARCH-STATE.md outline/RESEARCH-STATE.md contra/CONTRADICTIONS.md focuses/FOCUSES.md migrate/FOCUSES.md sources/sources/SOURCES.md; do
  [ -f "$FX/$f" ] || { echo "FATAL: fixture not found: $FX/$f" >&2; exit 2; }
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# GFM expectation for the shared fixture (6 pending backlog rows, 3 deferred rows, 9 distinct blocks, 9 iterations).
EXP_INV=6; EXP_DEF=3; EXP_BLOCKS=9; EXP_KNOWN=15

# probes <tree> : run every reader of <tree> over the shared fixture and set PR_<name>=ok|<detail> (one global per probe).
declare -A PR=()
PROBES="vs_inv vs_def vs_blocks st_inv st_def st_blocks st_iter st_outline st_queue st_hdr gr_rows st_contra st_foctok fpa_rows mb_status mb_doc vsrc_hdr"
probes() {
  local t="$1" d out err rc
  # --- verify-state.sh ---
  err="$TMP/vs.err"; out="$(bash "$t/verify-state.sh" "$FX/state" 2>"$err")"; rc=$?
  VS_INV="$(sed -n 's/.*investigable_open=[^/]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
  VS_DEF="$(sed -n 's/.*deferred_open=[^/]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
  if [ "$VS_INV" = "$EXP_INV" ] && ! grep -q 'malformed backlog row' "$err"; then PR[vs_inv]=ok; else PR[vs_inv]="derived investigable_open=${VS_INV:-?} want $EXP_INV; stderr: $(head -c 160 "$err")"; fi
  if [ "$VS_DEF" = "$EXP_DEF" ]; then PR[vs_def]=ok; else PR[vs_def]="derived deferred_open=${VS_DEF:-?} want $EXP_DEF"; fi
  if [ "$rc" = 0 ] && ! grep -qE '^ +FAIL ' <<<"$out"; then PR[vs_blocks]=ok; else PR[vs_blocks]="rc=$rc; $(grep -E '^ +FAIL ' <<<"$out" | head -2 | tr '\n' '~')"; fi
  # --- research-sdd-status.sh --sync-state on a COPY (it rewrites the envelope from its own derivations) ---
  d="$TMP/sync.$RANDOM"; mkdir -p "$d"; cp "$FX/state/RESEARCH-STATE.md" "$d/"
  bash "$t/research-sdd-status.sh" "$d" --sync-state >/dev/null 2>"$TMP/st.err"
  ST_INV="$(sed -n 's/^investigable_open: *//p' "$d/RESEARCH-STATE.md" | head -1)"
  ST_DEF="$(sed -n 's/^deferred_open: *//p' "$d/RESEARCH-STATE.md" | head -1)"
  ST_BLK="$(sed -n 's/^covered_blocks: *//p' "$d/RESEARCH-STATE.md" | head -1)"
  ST_KNOWN="$(sed -n 's/^known_gaps: *//p' "$d/RESEARCH-STATE.md" | head -1)"
  if [ "$ST_INV" = "$EXP_INV" ] && [ "$ST_KNOWN" = "$EXP_KNOWN" ] && ! grep -q 'malformed backlog row' "$TMP/st.err"; then PR[st_inv]=ok; else PR[st_inv]="synced investigable_open=${ST_INV:-?} known_gaps=${ST_KNOWN:-?} want $EXP_INV/$EXP_KNOWN"; fi
  if [ "$ST_DEF" = "$EXP_DEF" ]; then PR[st_def]=ok; else PR[st_def]="synced deferred_open=${ST_DEF:-?} want $EXP_DEF"; fi
  if [ "$ST_BLK" = "$EXP_BLOCKS" ]; then PR[st_blocks]=ok; else PR[st_blocks]="synced covered_blocks=${ST_BLK:-?} want $EXP_BLOCKS"; fi
  # --- research-sdd-status.sh default report: Iteration-history New-gaps column + Outline table ---
  out="$(bash "$t/research-sdd-status.sh" "$FX/state" 2>/dev/null)"
  if grep -qF 'saturation      : active (3 new gaps in last 3 iter)' <<<"$out" && ! grep -q 'unreadable' <<<"$out"; then PR[st_iter]=ok
  else PR[st_iter]="$(grep 'saturation' <<<"$out" | head -1)"; fi
  out="$(bash "$t/research-sdd-status.sh" "$FX/outline" 2>/dev/null)"
  if grep -qF 'outline         : 9/9 covered · drafted=0 · pending=0' <<<"$out"; then PR[st_outline]=ok; else PR[st_outline]="$(grep 'outline  ' <<<"$out" | head -1)"; fi
  # --- research-sdd-status.sh queue reader: its open-deferred rows (awk -F'|' field walk) ---
  out="$(bash "$t/research-sdd-status.sh" "$FX/state" --next --queue 2>&1)"
  if grep -qF '(9 ids: 3 done, 6 deferred, 0 blocked, 0 in-progress, 0 unknown)' <<<"$out"; then PR[st_queue]=ok; else PR[st_queue]="$(grep 'queue-' <<<"$out" | head -2 | tr '\n' '~')"; fi
  # --- research-sdd-status.sh iter_gaps_rows col_none path: the printed header carries no raw mask byte ---
  out="$(bash "$t/research-sdd-status.sh" "$FX/nogaps" 2>/dev/null | grep 'saturation')"
  if [ "$out" = "  saturation      : no New-gaps column (header:  It | Fo|cus | Block )" ]; then PR[st_hdr]=ok; else PR[st_hdr]="$(printf '%s' "$out" | od -c | head -3 | tr '\n' '~')"; fi
  # --- research-sdd-status.sh count_open_contra: STATUS is the 4th cell of the CONTRADICTIONS ledger (#2161) ---
  d="$TMP/contra.$RANDOM"; mkdir -p "$d"; cp "$FX/state/RESEARCH-STATE.md" "$FX/contra/CONTRADICTIONS.md" "$d/"
  out="$(bash "$t/research-sdd-status.sh" "$d" 2>/dev/null | grep 'contradictions')"
  if [ "$out" = "  contradictions  : 5 open" ]; then PR[st_contra]=ok; else PR[st_contra]="${out:-<no contradictions line>}"; fi
  # --- research-sdd-status.sh _read_focuses_tok_uncached: the function is lifted out of the script and called per row ---
  sed -n '/^_read_focuses_tok_uncached()/,/^}/p' "$t/research-sdd-status.sh" > "$TMP/foctok.fn.sh"
  out="$(bash -c '. "$1"; for k in f1 f2 f3 f4 f5 f6 f7 f8; do printf "%s=%s " "$k" "$(_read_focuses_tok_uncached "$2" "RESEARCH-STATE-$k.md" 2>/dev/null)"; done' _ "$TMP/foctok.fn.sh" "$FX/focuses/FOCUSES.md")"
  if [ "$out" = "f1=stopped f2=paused f3=planned f4=document f5=active f6=stopped f7=paused f8=planned " ]; then PR[st_foctok]=ok; else PR[st_foctok]="$out"; fi
  # --- focus-partition-audit.sh: the Research-State column must still resolve its file after an escaped pipe ---
  d="$TMP/fpa.$RANDOM"; mkdir -p "$d"
  for k in 1 2 3 4 5 6 7 8; do mkdir -p "$d/subj/zzUnit$k"; : > "$d/subj/zzUnit$k/A.java"; done
  out="$(bash "$t/focus-partition-audit.sh" "$FX/focuses" --subject "$d/subj" 2>&1)"
  if grep -qF 'FOCUSES.md rows: 8 classified, 0 unclassifiable' <<<"$out" && grep -qF 'unresolved RESEARCH-STATE references: 0' <<<"$out" && grep -qF 'units: 8/8 chartered' <<<"$out"; then PR[fpa_rows]=ok
  else PR[fpa_rows]="$(grep -E '^(FOCUSES.md rows|unresolved|units:|WARN)' <<<"$out" | head -3 | tr '\n' '~')"; fi
  # --- migrate-backlogs.sh: FOCUSES.md `closed`/`reabierto` rewrite touches the Status cell only; document focus gets no skeleton ---
  out="$(bash "$t/migrate-backlogs.sh" "$FX/migrate" 2>&1)"
  if grep -qF '+| m1 | n\|esc | stopped | RESEARCH-STATE-m1.md | l |' <<<"$out" && grep -qF '+| m2 | n\\|even | reopened | RESEARCH-STATE-m1.md | l |' <<<"$out" \
     && grep -qF '+| m3 | n\\\|triple | stopped | RESEARCH-STATE-m1.md | l\|esc |' <<<"$out" && grep -qF '+| x\|y | n | reopened | RESEARCH-STATE-m1.md | l |' <<<"$out" \
     && grep -qF '+| x\\|y | n | stopped | RESEARCH-STATE-m1.md | l\\|even |' <<<"$out" && ! grep -q 'unknown-focus-status' <<<"$out"; then PR[mb_status]=ok
  else PR[mb_status]="$(grep -E '^(MANUAL|\+\|)' <<<"$out" | head -3 | tr '\n' '~')"; fi
  if ! grep -q 'empty-backlog-skeleton' <<<"$out" && ! grep -q '^PROPOSE d1' <<<"$out"; then PR[mb_doc]=ok; else PR[mb_doc]="$(grep -E 'empty-backlog-skeleton|^PROPOSE d1' <<<"$out" | head -2 | tr '\n' '~')"; fi
  # --- verify-sources.sh: a well-formed 6-column registry row with escaped pipes draws no malformed-row WARN ---
  out="$(bash "$t/verify-sources.sh" "$FX/sources" 2>&1)"
  if ! grep -q 'malformed row' <<<"$out"; then PR[vsrc_hdr]=ok; else PR[vsrc_hdr]="$(grep -c 'malformed row' <<<"$out") malformed-row WARN(s): $(grep -m1 'malformed row' <<<"$out" | cut -c1-120)"; fi
  # --- lib/gap-rows.sh ---
  out="$(bash -c '. "$1/lib/gap-rows.sh"; gap_rows_parse "$2"' _ "$t" "$FX/state/RESEARCH-STATE.md" 2>&1)"
  local want
  want="$(printf 'ROW\tB1-G1\t1\tpending\tmid|esc\nROW\tB1-G2\t1\tpending\tmid\\|even\nROW\tB1-G3\t1\tpending\tmid\\\\|triple\nROW\tB2-G1\t2\tpending\tok\nROW\tB2-G2\t2\tpending\tok\nROW\tB2-G3\t2\tpending\tok\nROW\tB3-G1\t3\tother\td|esc\nROW\tB3-G2\t3\tother\td\\|even\nROW\tB3-G3\t3\tother\td\\\\|triple\nROW\tB3-G4\t3\tother\tclosed\nROW\tB3-G5\t3\tother\tclosed\nROW\tB3-G6\t3\tother\tclosed\nROW\tB3-G7\t3\tother\t\nROW\tB3-G8\t3\tother\t\nROW\tB3-G9\t3\tother\t')"
  if [ "$out" = "$want" ]; then PR[gr_rows]=ok; else PR[gr_rows]="$(printf '%s' "$out" | head -c 200 | tr '\n' '~')"; fi
}

echo "-- GFM parity: every table reader over the shared fixture --"
probes "$TOOLBELT"
declare -A DESC=(
  [vs_inv]="verify-state.sh backlog rows: 6 pending rows (\\|, \\\\|, \\\\\\| in the Gap cell and the Status cell) all parse as 4-cell rows"
  [vs_def]="verify-state.sh deferred rows: 3 deferred rows (4-column table; deferred_open counts only 4-cell rows) with \\|, \\\\|, \\\\\\| in the Gap cell are counted"
  [vs_blocks]="verify-state.sh Iteration-history Block column: 9 blocks attributed despite escapes in the first/middle/last cells"
  [st_inv]="research-sdd-status.sh backlog rows: --sync-state derives investigable_open=6 known_gaps=15, no malformed-row WARN"
  [st_def]="research-sdd-status.sh deferred rows: --sync-state derives deferred_open=3"
  [st_blocks]="research-sdd-status.sh Iteration-history Block column: --sync-state attributes 9 blocks"
  [st_iter]="research-sdd-status.sh Iteration-history New-gaps column: all 9 rows readable (none unreadable, 3 new gaps in the last 3)"
  [st_queue]="research-sdd-status.sh --queue reader: the 9 queued rows (6 deferred incl. a 5-column table, 3 closed) are all recognised, none unknown"
  [st_hdr]="research-sdd-status.sh iter_gaps_rows: a header with an escaped pipe prints on the no-New-gaps-column line with the pipe restored (no raw mask byte)"
  [st_outline]="research-sdd-status.sh Outline rows: 9/9 covered with escapes in the middle and last cells"
  [st_contra]="research-sdd-status.sh count_open_contra: 5 open ledger rows counted, the resolved row whose claim cell says open is not (escapes before and after the STATUS cell)"
  [st_foctok]="research-sdd-status.sh FOCUSES.md status reader: 8 rows read with the right status token (escapes in the first/middle/last cells)"
  [fpa_rows]="focus-partition-audit.sh: 8 FOCUSES.md rows classified, every Research-State file resolved, 8/8 units chartered"
  [mb_status]="migrate-backlogs.sh FOCUSES.md rewrite: closed/reabierto become stopped/reopened in the Status cell only, escape bytes kept"
  [mb_doc]="migrate-backlogs.sh document-focus lookup: a document focus whose row carries an escaped pipe gets no empty-backlog skeleton"
  [vsrc_hdr]="verify-sources.sh registry pre-check: 9 well-formed 6-column rows with escapes in the first/middle/last cells draw no malformed-row WARN"
  [gr_rows]="lib/gap-rows.sh gap_rows_parse: 15 ROW records, cell text unescaped by exactly one backslash-pipe"
)
for p in $PROBES; do
  v="${PR[$p]}"
  if [ "$v" = ok ]; then ok "$p: ${DESC[$p]}"; else no "$p: ${DESC[$p]} — $v"; fi
done
# cross-reader agreement (the §7 two-populations check): the two derivations of the same counter must be equal.
if [ "$VS_INV" = "$ST_INV" ] && [ "$VS_DEF" = "$ST_DEF" ]; then ok "agree: verify-state.sh and research-sdd-status.sh derive identical investigable ($VS_INV) and deferred ($VS_DEF) counts"
else no "agree: verify-state.sh inv/def=$VS_INV/$VS_DEF vs research-sdd-status.sh inv/def=$ST_INV/$ST_DEF"; fi
if [ "$VS_INV" = "$EXP_INV" ] && [ "$VS_DEF" = "$EXP_DEF" ] && [ "$ST_BLK" = "$EXP_BLOCKS" ]; then ok "gfm: the agreed counts equal the GFM rendering (no even-run column break)"
else no "gfm: counts $VS_INV/$VS_DEF/$ST_BLK differ from the GFM expectation $EXP_INV/$EXP_DEF/$EXP_BLOCKS"; fi

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: one mutant per reader call site (escape step removed) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_built || exit 2
  # tooth <name> <file> <literal-old> <literal-new> <probe-that-must-turn-red>
  # Copy the toolbelt (scripts + lib), replace the FIRST literal occurrence in <file>, then re-run every probe on
  # the copy: the named probe must fail. The literal is cut with bash, not sed, so no regex escaping can misapply it.
  tooth() {
    local name="$1" file="$2" old="$3" new="$4" watch="$5" t="$TMP/mut-$1" s v
    mkdir -p "$t/lib"; cp "$TOOLBELT"/*.sh "$t/"; cp -r "$TOOLBELT"/lib/. "$t/lib/"
    s="$(cat "$TOOLBELT/$file"; printf x)"; s="${s%x}"
    case "$s" in *"$old"*) ;; *) no "teeth $name: literal not found in $file — the call site moved"; return ;; esac
    printf '%s' "${s/"$old"/"$new"}" > "$t/$file"
    if ! mutant_built "teeth $name" "$TOOLBELT/$file" "$t/$file" >/dev/null 2>&1; then no "teeth $name: mutant refused by lib/mutant.sh"; return; fi
    probes "$t"; v="${PR[$watch]}"
    if [ "$v" != ok ]; then ok "teeth $name: mutant turns probe $watch red"; else no "teeth $name: probe $watch stays green on the mutant — THEATER"; fi
  }
  tooth vs-backlog    verify-state.sh 'gsub(/\\\|/,"\001",line)  # BP-ESCAPED-PIPE' 'line=line  # BP-ESCAPED-PIPE' vs_inv
  tooth vs-deferred   verify-state.sh 'gsub(/\\\|/,"\001",line)  # GFM-EP-DEFERRED' 'line=line  # GFM-EP-DEFERRED' vs_def
  tooth vs-blockcol   verify-state.sh 'gsub(/\\\|/, "\001")  # GFM-EP-BLOCKCOL' '$0=$0  # GFM-EP-BLOCKCOL' vs_blocks
  tooth st-backlog    research-sdd-status.sh 'gsub(/\\\|/,"\001",line)  # BP-ESCAPED-PIPE' 'line=line  # BP-ESCAPED-PIPE' st_inv
  tooth st-deferred   research-sdd-status.sh 'gsub(/\\\|/,"\001",line)  # GFM-EP-DEFERRED' 'line=line  # GFM-EP-DEFERRED' st_def
  tooth st-blockcol   research-sdd-status.sh 'gsub(/\\\|/, "\001")  # GFM-EP-BLOCKCOL' '$0=$0  # GFM-EP-BLOCKCOL' st_blocks
  tooth st-iter       research-sdd-status.sh 'gsub(/\\\|/,"\001",l)  # GFM-EP-ITER' 'l=l  # GFM-EP-ITER' st_iter
  tooth st-queue      research-sdd-status.sh 'ib { gsub(/\\\|/,"\001"); ' 'ib { ' st_queue
  tooth st-hdr        research-sdd-status.sh 'gsub(/\001/,"|",l); print "col_none' 'print "col_none' st_hdr
  tooth st-outline  research-sdd-status.sh 'gsub(/\\\|/, "\001", line)' 'line=line' st_outline
  tooth st-contra     research-sdd-status.sh 'gsub(/\\\|/,"\001",line)  # GFM-EP-CONTRA' 'line=line  # GFM-EP-CONTRA' st_contra
  tooth st-foctok     research-sdd-status.sh 'gsub(/\\\|/,"\001",line)  # GFM-EP-FOCTOK' 'line=line  # GFM-EP-FOCTOK' st_foctok
  tooth fpa-rows      focus-partition-audit.sh 'gsub(/\\\|/, "\001", line)  # GFM-EP-FPA' 'line=line  # GFM-EP-FPA' fpa_rows
  tooth mb-cells      migrate-backlogs.sh 'gsub(/\\\|/, "\001", body)  # GFM-EP-MIG-CELLS' 'body=body  # GFM-EP-MIG-CELLS' mb_status
  tooth mb-doc        migrate-backlogs.sh 'gsub(/\\\|/, "\001", line)  # GFM-EP-MIG-DOC' 'line=line  # GFM-EP-MIG-DOC' mb_doc
  tooth vsrc-hdr      verify-sources.sh 'gsub(/\\\|/, "\001")  # GFM-EP-VSRC' '$0=$0  # GFM-EP-VSRC' vsrc_hdr
  tooth gr-rows       lib/gap-rows.sh 'gsub(/\\\|/,"\001",t); ' '' gr_rows
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
