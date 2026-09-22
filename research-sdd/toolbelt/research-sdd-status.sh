#!/usr/bin/env bash
# research-sdd-status.sh — structured status + deterministic next-gap for a Research-SDD corpus.
#
# WHY: RESUME was PROSE ("read RESEARCH-STATE, start from the next not-covered gap"). A human/agent
# re-derived "what's next" by eye each iteration. This mechanizes it: `status` renders the state, and
# `--next` resolves the next gap DETERMINISTICALLY (highest-priority pending gap that is not blocked),
# so the loop never guesses. Models sdd-status / sdd-continue, kept to the continuous research loop.
#
# Usage:
#   research-sdd-status.sh <target-dir>            structured status report (default)
#   research-sdd-status.sh <target-dir> --sync-state  (re-)seed the research-state.v1 envelope IN PLACE
#        from ground truth (idempotent; a second run is byte-identical). This is what verify-state.sh
#        validates against — run it after editing the backlog so --next never returns STALE on stale ints.
#   research-sdd-status.sh <target-dir> --next     print ONE machine-readable next-step line:
#        NEXT | <priority> | <gap>     — investigate this gap next
#        STOP | read-only-investigable exhausted (0)                                     — all gaps closed, issue coverage verified (0 untracked)
#        STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]  — exhausted; coverage unverifiable (specific cause on stderr)
#        ISSUES-DUE | <count> untracked delta(s) in <retro> — first retro with untracked deltas found (early-exit:
#              remaining retros NOT probed); seed: stage-retro-issues.sh <retro> --apply
#        (aggregate probing budget: _IDG_AGGREGATE_BUDGET_SECS env var, default 60s — exceeded before all-clean confirmed → unverified marker)
#        RETRO-DUE | <count> ...       — §18 cadence: too many blocks without a retro; write one before resuming
#        STALE | <reason>              — RESEARCH-STATE is internally inconsistent; run --sync-state, reconcile, retry
#        BOOTSTRAP | <reason>          — no RESEARCH-STATE yet → run research-sdd-init.sh
#   (NONE is no longer emitted: an empty eligible-backlog means derived investigable=0 → STOP by construction.)
# Exit: 0 ok · 2 bad args. (malformed backlog rows are WARNed to stderr, never silently dropped.)
set -uo pipefail

target="${1:-}"
[ -d "$target" ] || { echo "usage: research-sdd-status.sh <target-dir> [--next|--sync-state] [--focus <slug>]" >&2; exit 2; }
shift
mode="status"
focus_slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --next|--sync-state) mode="$1"; shift ;;
    --focus)
      focus_slug="${2:-}"
      [ -z "$focus_slug" ] && { echo "usage: --focus requires a focus slug" >&2; exit 2; }
      shift 2 ;;
    *) echo "usage: research-sdd-status.sh <target-dir> [--next|--sync-state] [--focus <slug>]" >&2; exit 2 ;;
  esac
done

if [ -n "$focus_slug" ]; then
  # --focus <slug>: select exactly RESEARCH-STATE-<slug>.md, ignoring sibling focuses.
  state="$(find "$target" -maxdepth 3 -name "RESEARCH-STATE-${focus_slug}.md" -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
  if [ ! -f "$state" ]; then
    [ "$mode" = "--next" ] && echo "BOOTSTRAP | no RESEARCH-STATE-${focus_slug}.md under $target" || echo "no RESEARCH-STATE-${focus_slug}.md under $target — run research-sdd-init.sh"
    exit 0
  fi
else
  state="$(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
  if [ ! -f "$state" ]; then
    [ "$mode" = "--next" ] && echo "BOOTSTRAP | no RESEARCH-STATE under $target" || echo "no RESEARCH-STATE under $target — run research-sdd-init.sh"
    exit 0
  fi
fi
corpus="$(dirname "$state")"
here="$(cd "$(dirname "$0")" && pwd)"

# Shared focus-prefix derivation — single source of truth (research-sdd-status.sh and verify-state.sh
# previously carried hand-copied derive_focus_prefix() / _focus_prefix() that were byte-identical but
# could drift; lib/focus-prefix.sh eliminates that hazard).
_FPLIB="$here/lib/focus-prefix.sh"
if [ ! -f "$_FPLIB" ]; then
  echo "research-sdd-status: cannot find helper $_FPLIB" >&2; exit 1
fi
# shellcheck source=lib/focus-prefix.sh
. "$_FPLIB"
# Fail closed: this script does NOT use `set -e`, so a failed/partial/syntax-broken source would be
# swallowed and every focus-prefix call would silently return empty, mis-counting blocks. Abort early.
declare -F derive_focus_prefix >/dev/null 2>&1 || { echo "research-sdd-status: helper $_FPLIB failed to define derive_focus_prefix" >&2; exit 1; }

# Shared state-file enumeration — single definition of the "enumerate RESEARCH-STATE*.md" incantation
# (WARNING 4: lib/state-files.sh was declared the SINGLE definition, but gate/aggregation consumers in
# this file copy-pasted the find command instead of sourcing it; a change to the exclusion set in the
# lib would silently diverge from those consumers on day one of the changeset). Sourcing here eliminates
# the drift without changing the exclusion set — verify-state.sh:33 remains the authoritative reference.
_SFLIB="$here/lib/state-files.sh"
if [ ! -f "$_SFLIB" ]; then
  echo "research-sdd-status: cannot find helper $_SFLIB" >&2; exit 1
fi
# shellcheck source=lib/state-files.sh
. "$_SFLIB"
declare -F list_state_files >/dev/null 2>&1 || { echo "research-sdd-status: helper $_SFLIB failed to define list_state_files" >&2; exit 1; }

_BFLIB="$here/lib/block-files.sh"
if [ ! -f "$_BFLIB" ]; then echo "research-sdd-status: cannot find helper $_BFLIB" >&2; exit 1; fi
# shellcheck source=lib/block-files.sh
. "$_BFLIB"
declare -F block_file_filter >/dev/null 2>&1 || { echo "research-sdd-status: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
unset _BFLIB

# --- section extractors (scope numeric/list greps to their section — never whole-file) ----------
section() { awk -v h="$1" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$state"; }   # body of "## <h>..."
stopctl()      { section '## Stop control'; }
# B3a / B3c / B5: blocked_body also scans "## Non-investigable gaps" (semantically identical to
# ## Blocked gaps; used in older/TRANE/EduVolt corpora) and "## Blocked / <qualifier>" (B3c, e.g.
# niagara-research spyder focus). Mirrors _blocked_names() and derive_blocked() in verify-state.sh.
blocked_body() { section '## Blocked gaps'; section '## Non-investigable gaps'; section '## Blocked /'; }
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
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); if (n<4) next
      gsub(/^[ \t]+|[ \t]+$/,"",a[4]); if (tolower(a[4])=="open") c++ }
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
      sub(/^\|/,"",l); sub(/\|$/,"",l)
      n=split(l,a,"|"); for(k=1;k<=n;k++) a[k]=trim(a[k])
      issep=1; for(k=1;k<=n;k++){ if(a[k] !~ /^:?-+:?$/){issep=0;break} }
      if (issep) next                                        # markdown "---" separator row
      if (!have_header) {                                    # first non-separator table row = header
        have_header=1
        for(k=1;k<=n;k++){ if(tolower(a[k]) ~ /new gaps|nuevos gaps/){ ngcol=k; break } }
        if (ngcol==0){ print "col_none\t" l; exit }
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

# Blocked gap NAMES (one trimmed name per "- <name> — needs: ..." line) — matched EXACTLY, never as
# a substring of free prose (a pending gap "hardware" must not be killed by "- x — needs: hardware").
blocked_names() {
  blocked_body | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
    | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}
is_blocked() { local g="$1" b; while IFS= read -r b; do [ "$b" = "$g" ] && return 0; done < <(blocked_names); return 1; }
# disk-DERIVED blocked_open — count of needs:-carrying entries under the standard blocked sections
# (via blocked_body) PLUS entries in ## Child gaps surfaced at close where `needs:` may appear on a
# continuation/indent line (multi-line bullet form — mirrors derive_blocked() in verify-state.sh).
# blocked_body() combines ## Blocked gaps, ## Non-investigable gaps, and ## Blocked /.
# RSDD-STATUS-CHILD-GAPS-ANCHOR: multi-line bullet form in ## Child gaps surfaced at close
derive_blocked_open() {
  local _d1 _d2
  _d1="$(blocked_body | grep -icE '^[[:space:]]*-[[:space:]].*needs:|\*\*needs:\*\*')"
  _d2="$(section '## Child gaps surfaced at close' | awk '
    BEGIN { n=0; ib=0; done=0 }
    /^[[:space:]]*$/ { ib=0; done=0; next }
    /^[[:space:]]*-[[:space:]]/ { ib=1; done=0
      if (tolower($0) ~ /needs:/) { n++; done=1 }
      next }
    { if (ib && !done && tolower($0) ~ /needs:/) { n++; done=1 } }
    END { print n+0 }')"
  echo $(( ${_d1:-0} + ${_d2:-0} ))
}
# B3b: count_deferred — count OPEN backlog rows whose priority column is exactly "deferred"
# (explicitly-parked gaps — operator decision, not blocked by hardware). Mirrors derive_deferred()
# in verify-state.sh. Reads from $state (the global current state file).
count_deferred() {
  awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      cnt=split(line,a,"|"); for(k=1;k<=cnt;k++) gsub(/^[ \t]+|[ \t]+$/,"",a[k])
      if (tolower(a[1])!="deferred") next
      if (cnt!=4) next
      st=tolower(a[4])
      if (index(a[2],"~~") || index(st,"~~") || index(st,"✅")) next
      n++ }
    END { print n+0 }' "$state"
}

# Backlog rows: STRICT 4-column table (`| p | gap | type | status |` → 6 pipe-fields). A gap cell
# containing a pipe yields NF!=6 → WARN (never a silent drop / mis-field). Emits "priority<TAB>gap<TAB>status".
backlog_rows() {
  # Normalize the row so both bounded (`| p | g | t | s |`) and outer-pipe-less GFM (`p | g | t | s`)
  # rows parse to exactly 4 cells; a pipe INSIDE a cell yields n!=4 → WARN (never a silent drop).
  # An unknown priority value emits a diagnostic to stderr AND a INVALID_PRIORITY<TAB><value> sentinel
  # to stdout. Callers that care check for the sentinel; callers that don't (derive_investigable etc.)
  # safely ignore the 2-field sentinel line. Silently skips: deferred (parked), strikethrough (~~p~~),
  # em-dash (—). Qualifier forms (e.g. "high (context)") emit a provisional WARN to stderr naming the
  # canonical stripped base and are still excluded. An unknown qualifier BASE fails closed.
  awk '
    /^## Gap-backlog( \([^)]+\))?$/ { in_backlog=1; in_data=0; next }
    /^## / && tolower($0) ~ /backlog/ { print "WARN: near-miss gap-backlog heading [" $0 "] — expected \"## Gap-backlog\" or \"## Gap-backlog (<label>)\" per METHODOLOGY" > "/dev/stderr" }  # NM-WARN
    /^## / { in_backlog=0; in_data=0; next }
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); for(k=1;k<=n;k++) gsub(/^[ \t]+|[ \t]+$/,"",a[k])
      p=tolower(a[1])
      if (p~/^-/) { in_data=1; next }
      if (p=="" || p=="priority" || p=="p" || p=="deferred") { next }
      if (p~/^~~.*~~$/) { next }  # BPSKIP-STRIKETHROUGH: resolved (struck-through) rows
      if (p~/^—/) { next }        # BPSKIP-EMDASH: em-dash placeholder rows
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
        }
        next
      }
      if (n!=4) {
        if (in_backlog && in_data && tolower(a[4]) ~ /^covered/) { next }  # SS-567-COVERED-PIPE-SKIP: COVERED rows may carry pipe notation in status summary; skip silently
        if (in_backlog && in_data) { print "WARN: malformed backlog row (" n " cells, expected 4 — a cell may contain a pipe): " $0 > "/dev/stderr" }
        next }
      { st=tolower(a[4]); gsub(/^\*\*/, "", st); gsub(/\*\*$/, "", st) }  # SS-634-BOLD-STRIP: strip leading/trailing ** (markdown bold artifacts) from status field
      print p "\t" a[2] "\t" st }
  ' "$state"
}

resolve_next() {
  local rows; rows="$(backlog_rows)"             # compute ONCE — else the WARN fires per priority tier
  local prio pri gap st lead tok
  for prio in high medium low; do
    while IFS=$'\t' read -r pri gap st; do
      [ -z "$gap" ] && continue
      case "$gap" in *'~~'*) continue ;; esac      # struck-through gap name: resolved row, skip silently
      lead="${st#\*\*}"; lead="${lead/\*\*/}"       # §8b: strip leading ** and its closing pair (handles **pending** (note))
      tok="${lead%% *}"
      [ "$tok" = "pending" ] || continue           # LEADING-TOKEN — bare `pending` or decorated `pending (uncovered by B7)`; NOT "not pending" / "blocked (pending review)"
      is_blocked "$gap" && continue
      printf 'NEXT | %s | %s\n' "$pri" "$gap"; return 0
    done < <(printf '%s\n' "$rows" | awk -F'\t' -v P="$prio" '$1==P')
  done
  # The walk above found NO eligible (pending, non-blocked) gap, so the DERIVED investigable count is 0 BY
  # CONSTRUCTION — the exact number verify-state.sh gates as the envelope's investigable_open, and the --next
  # STALE-gate already ensured the envelope agrees with this derivation before we got here. STOP on that, NOT
  # on the hand-authored `## Stop control` prose (which --sync-state never rewrites and verify-state never
  # gates): reading that prose here would resurrect the stale-mirror class the envelope was built to kill.
  echo "STOP | read-only-investigable exhausted (0)"
}

# --- envelope seeder (--sync-state) --------------------------------------------------------------
# derived investigable_open, reusing THIS script's backlog_rows/is_blocked — IDENTICAL to resolve_next's
# NEXT-eligibility set (single source of truth), and to what verify-state.sh recomputes.
count_investigable() {
  local gap st lead tok n=0
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    case "$gap" in *'~~'*) continue ;; esac      # struck-through gap name: resolved row, skip silently  # STRICKEN-GAP-SKIP
    lead="${st#\*\*}"; lead="${lead/\*\*/}"       # §8b: strip leading ** and its closing pair (handles **pending** (note))  # BOLD-STRIP
    tok="${lead%% *}"
    [ "$tok" = "pending" ] || {
      case "$tok" in
        requires-execution*|blocked-on-*|blocked|'~~'*|'✅'*|closed|\[closed\]|covered|\[covered\]|done|\[done\]|cubierto|\[cubierto\]) ;;  # DONE-TOKENS
        *) printf 'WARN: unrecognised Status token [%s] in gap: %s\n' "$tok" "$gap" >&2 ;;  # UNRECOG-STATUS-WARN
      esac
      continue
    }
    is_blocked "$gap" && continue
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# derived requires_execution_open — MIRRORS verify-state.sh's derive_requires_execution EXACTLY (same
# deliberate lockstep as count_investigable): OPEN backlog rows whose STATUS column (tolower'd by
# backlog_rows) is ANCHORED to the LEADING token `requires-execution` (mirrors count_investigable's
# `pending` leading-token discipline) — a free-text mention that merely NAMES the phrase
# (`pending (requires-execution)`) is NOT counted (was a CHECK E false-POSITIVE). CLOSED is decided only
# by UNAMBIGUOUS markers: a struck-through gap (~~), or a status carrying ~~/✅. The bare words
# covered/closed/done/cubierto were REMOVED from the closed-test: they appear NEGATED in genuinely OPEN
# asides (`not yet covered`, `not yet done`), and a bare substring match there false-excluded an open row
# (was a CHECK E false-NEGATIVE). Only a LOWER BOUND: a prose-tracked build gap (logosoft) has no backlog
# marker, so --sync-state prefers this count ONLY when it is > 0.
count_requires_execution() {
  local gap st lead n=0
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    # OPEN marker ANCHORED to the leading token (strip one ** bold first) — mirrors derive_investigable's
    # `pending` leading-token discipline so a free-text mention (`pending (requires-execution)`) that merely
    # names the phrase is NOT counted as a build gap (was a CHECK E false-FAIL).
    lead="${st#\*\*}"
    case "$lead" in requires-execution|requires-execution[!a-z0-9]*) ;; *) continue ;; esac
    # CLOSED only via UNAMBIGUOUS markers: a struck gap/status (~~) or a ✅ verdict. The bare words
    # covered/closed/done/cubierto were REMOVED: they appear negated in OPEN asides (`(not yet covered)`,
    # `not yet done`), and a substring match there false-excluded a genuinely open gap → CHECK E missed the
    # premature-build-STOP hazard. Canonical closure always pairs the word WITH ✅ (`✅ cubierto`), so ✅ suffices.
    case "$gap" in *'~~'*) continue ;; esac
    case "$st" in *'~~'*|*'✅'*) continue ;; esac
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# count_all_known_gaps — total backlog row count (all valid-priority rows, all statuses, excluding deferred).
# Used to derive known_gaps when the backlog total exceeds the coverage metric Y (issue #568): a new gap
# added to the backlog bumps this count even when the coverage metric prose is stale.
# Deferred rows are counted separately (count_deferred) and passed in by the caller.
# INVALID_PRIORITY rows are excluded — they are not countable and are reported separately.
count_all_known_gaps() {
  backlog_rows 2>/dev/null | grep -v '^INVALID_PRIORITY' | wc -l | tr -d ' '  # KG-ALL-BACKLOG
}
# count_attributed_sg — attributed covered-blocks count for block_scope: shared-global, mirroring
# _derive_attributed_sg() in verify-state.sh so --sync-state and CHECK A always agree.
# Source 1 (preferred): distinct B<n> ids in '## Covered blocks' body.
# Source 2 (fallback): distinct B<n> ids in the Block column of '## Iteration history'.
# Returns 0 when neither source yields any id (unverifiable — caller seeds 0 + WARN, not corpus-wide).
count_attributed_sg() {
  local ids n
  ids="$(section '## Covered blocks' | grep -oE '\bB[0-9]+\b' | sort -u)"
  if [ -z "$ids" ]; then
    ids="$(section '## Iteration history' | awk '
      BEGIN { blockcol=0 }
      /\|/ {
        gsub(/\r$/, "")
        n = split($0, a, "|")
        if (!blockcol) {
          for (i=1; i<=n; i++) { v=a[i]; gsub(/^[ \t]+|[ \t]+$/,"",v); if (tolower(v)=="block") blockcol=i }
          next
        }
        if (blockcol && n >= blockcol) { v=a[blockcol]; gsub(/^[ \t]+|[ \t]+$/,"",v); print v }
      }' | grep -oE '\bB[0-9]+\b' | sort -u)"
  fi
  [ -z "$ids" ] && { echo 0; return; }
  n="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
  echo "${n:-0}"
}
# requires-execution count from the `## Stop control` prose. Parenthesized asides are stripped FIRST and
# the number is anchored to the token itself, not to the whole line: the real logosoft line reads
# `— requires-execution (NO read-only; …, METHODOLOGY §8)**: **0 — AGOTADO.**`, and the old bare
# first-integer grep grabbed the 8 out of `§8` instead of the declared 0 (that stale 8 was live in its
# envelope). Emits the first integer AFTER the token, or nothing when the line/number is absent.
req_prose() { stopctl | sed -E 's/\([^)]*\)//g' | grep -ioE 'requires-execution[^0-9]*[0-9]+' | head -1 | grep -oE '[0-9]+$'; }
# read a field from the CURRENT envelope (for carry-forward of declared-only fields we cannot parse fresh).
env_get() { awk -v k="$1" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{v=$2; sub(/\r$/,"",v); print v; exit}' "$state"; }  # strip trailing CR (CRLF-safe)
# pick <parsed> <previous> — prefer a freshly-parsed integer, else carry the previous envelope value, else
# 0. NEVER invent: an unparseable declared field falls back to what was already recorded, not a guess.
pick() { case "$1" in ''|*[!0-9]*) case "$2" in ''|*[!0-9]*) echo 0;; *) echo "$2";; esac;; *) echo "$1";; esac; }

# _read_focuses_tok — read and validate the leading status token for a focus from FOCUSES.md.
# This is the FIRST checker to read the focus-status cell (METHODOLOGY §16).
# Args: $1=FOCUSES.md path  $2=state-file basename (e.g. RESEARCH-STATE-alpha.md)
# Stdout: validated leading token (lowercased), or empty when absent/not-found/non-conforming.
# Grammar: active|paused|stopped|planned|bootstrapping|reopened|document (METHODOLOGY §16).
# closed is NOT a valid token; regional variants are non-conforming (METHODOLOGY §16).
# Columns recognised by header: Focus (identity), Status|Estado (status), Research-State|State file (identity).
# Cell decoration stripped before matching: `backtick-wrap` and **bold-wrap** (BOLD-STRIP).
# WARNs to stderr: token outside closed vocabulary, or state file absent from the index.
_read_focuses_tok() {
  local ffile="$1" sbase="$2"
  [ -f "$ffile" ] || return  # N194-FOCUSES-SKIP-FN
  local fslug="${sbase#RESEARCH-STATE-}"; fslug="${fslug%.md}"
  awk -v sbase="$sbase" -v fslug="$fslug" '
    function trim(s)  { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function strip_markup(s,   r) {
      r = s
      if (r ~ /^\[[^]]*\]\([^)]*\)$/) { sub(/^\[/, "", r); sub(/\]\(.*\)$/, "", r) }  # link [text](url) — LINK-STRIP
      if (r ~ /^`[^`]*`$/)            { sub(/^`/, "", r); sub(/`$/, "", r) }            # backtick-wrap
      sub(/^\*\*/, "", r); sub(/\*\*/, "", r)                                            # BOLD-STRIP + §8b half-bold
      return r
    }
    function lead_tok(s,   t) {
      t = strip_markup(s); sub(/[[:space:]].*$/, "", t); return tolower(t)
    }
    BEGIN { hdone=0; fcol=0; scol=0; sfcol=0; found=0 }
    {
      if (index($0, "|") == 0) next
      line = $0
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, a, "|"); for (k=1; k<=n; k++) a[k] = trim(a[k])
      issep=1; for (k=1; k<=n; k++) { if (a[k] !~ /^:?-+:?$/) { issep=0; break } }
      if (issep) next
      if (!hdone) {
        hdone = 1
        for (k=1; k<=n; k++) {
          h = tolower(a[k])
          if (h == "focus")                                fcol  = k
          if (h == "status" || h == "estado")              scol  = k
          if (h == "research-state" || h == "state file") sfcol = k
        }
        if (scol == 0 && fcol > 0) scol = fcol + 1  # fallback: column after Focus
        next
      }
      # identity match: Focus column and state-file column only (D4 — no any-cell hazard)
      matched = 0
      if (fcol > 0 && fcol <= n) {
        cv = strip_markup(a[fcol])
        if (cv == sbase || cv == fslug) matched = 1
      }
      if (!matched && sfcol > 0 && sfcol <= n) {
        cv = strip_markup(a[sfcol])
        if (cv == sbase || cv == fslug) matched = 1
      }
      if (!matched) next
      # row found — validate status cell
      found = 1
      if (scol == 0 || scol > n) {
        print "WARN: FOCUSES.md row " fslug ": no status column found" > "/dev/stderr"
        exit
      }
      tok = lead_tok(a[scol])
      if (tok == "active"   || tok == "paused"       || tok == "stopped" ||
          tok == "planned"  || tok == "bootstrapping" || tok == "reopened" ||
          tok == "document") {
        print tok; exit
      }
      # token outside closed vocabulary → WARN, return empty (no skip triggered)
      print "WARN: FOCUSES.md row " fslug ": unreadable/nonconforming status token [" strip_markup(a[scol]) "]" > "/dev/stderr"
      exit
    }
    END {
      # FOCUSES.md present with a table but no matching row → drift WARN
      if (hdone && !found) {
        print "WARN: FOCUSES.md has no row for " sbase > "/dev/stderr"
      }
    }
  ' "$ffile"
}

if [ "$mode" = "--sync-state" ]; then
  # Seed the research-state.v1 envelope in EVERY RESEARCH-STATE*.md of the corpus. §16 multi-focus corpora
  # keep ONE state file per focus, each with its OWN backlog. Seeding only the head-1 file (as this did before)
  # left sibling foci envelope-less, and verify-state.sh — which lints ALL of them (its line ~19) — then FAILs,
  # BRICKING the whole corpus under the --next STALE-gate. ALL envelope fields are derived PER STATE FILE:
  # investigable_open / blocked_open / coverage from each focus's own backlog, and covered_blocks from that
  # file's OWN directory — recomputed INSIDE the loop with the SAME strict discriminator + dirname scoping that
  # verify-state.sh:101 uses. A once-at-$corpus cb would disagree with verify-state for any focus file living in
  # a subdirectory (verify-state recomputes ondisk per dirname($state)), FAILing the envelope we just wrote.
  render_envelope() {   # reads the per-file globals: cb/gc/kg/io/req/bo/def/uf/_extra_env_lines
    printf '<!-- research-state.v1 -->\n'
    printf 'schema: research-state.v1\n'
    printf 'covered_blocks: %s\n' "$cb"
    printf 'gaps_closed: %s\n' "$gc"
    printf 'known_gaps: %s\n' "$kg"
    printf 'investigable_open: %s\n' "$io"
    printf 'requires_execution_open: %s\n' "$req"
    printf 'blocked_open: %s\n' "$bo"
    printf 'deferred_open: %s\n' "$def"
    printf 'undocumented_findings: %s\n' "$uf"
    [ -n "$_extra_env_lines" ] && printf '%s\n' "$_extra_env_lines"  # PREAMBLE-CARRY-FORWARD
    printf '<!-- /research-state.v1 -->'
  }
  # Reassigning the global `state` per iteration is deliberate: section/backlog_rows/blocked_body/env_get all
  # read $state at call time, so each focus derives from its OWN file (single source of truth, same helpers).
  # Scan $target (not $corpus) so split-layout corpora (focuses in sibling subdirectories) are fully seeded;
  # scanning only $corpus=dirname(first) left sibling focuses unseeded — the BLOCKER 2 / WARNING 4 root cause.
  mapfile -t _states < <(list_state_files "$target")
  # When --focus is given, restrict the sync to that single file only (avoids seeding siblings).
  if [ -n "$focus_slug" ]; then
    _focused="$(find "$target" -maxdepth 3 -name "RESEARCH-STATE-${focus_slug}.md" -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
    if [ ! -f "$_focused" ]; then
      printf 'sync-state: no RESEARCH-STATE-%s.md under %s\n' "$focus_slug" "$target" >&2; exit 1
    fi
    _states=("$_focused")
  fi
  # FIX 2: scope guard — refuse to silently rewrite all siblings when no --focus is given.
  # Multiple RESEARCH-STATE files in a corpus must be targeted one at a time so that per-focus
  # preamble fields are never clobbered by a corpus-wide sweep.
  if [ -z "$focus_slug" ] && [ "${#_states[@]}" -gt 1 ]; then
    printf 'sync-state: WARN: %d RESEARCH-STATE files found under %s — use --focus <slug> to target one focus (refusing without explicit scope)\n' \
      "${#_states[@]}" "$target" >&2
    exit 1  # SYNC-SCOPE-GUARD
  fi
  for state in "${_states[@]}"; do
    # Write THROUGH a symlinked state file to its real path (else the mv below would replace the symlink
    # with a regular file, silently breaking a shared/canonical state). readlink -f also canonicalizes a
    # plain path harmlessly. The temp then lives in the target's OWN directory so mv is a same-filesystem
    # atomic rename (a bare mktemp lands in TMPDIR, and a cross-device mv is a non-atomic copy+unlink).
    state="$(readlink -f "$state" 2>/dev/null || printf '%s' "$state")"
    # BACKLOG PARSE CHECK — refuse to seed an envelope from an unparseable backlog. Unknown priority
    # values (not high/medium/low/deferred) emit an INVALID_PRIORITY sentinel to stdout; seeding from
    # a partial backlog would record a wrong investigable_open, disarming verify-state's gate.
    _brows_invalid="$(backlog_rows | grep '^INVALID_PRIORITY')"
    if [ -n "$_brows_invalid" ]; then  # BP-SYNC-INVALID-REFUSE
      printf 'sync-state: ERROR: %s: backlog NOT FULLY PARSEABLE — unknown priority value(s) found\n' \
        "$(basename "$state")" >&2
      printf '  (diagnostics above name the offending row(s); envelope NOT rewritten — fix the priority value(s) first)\n' >&2
      exit 1
    fi
    # block_scope: carry-forward through --sync-state round-trips so the declaration survives. env_get
    # handles indented+space forms (whitespace-split awk). Fallback probe uses the same whitespace-tolerant
    # /^[[:space:]]*key:/ convention as verify-state.sh (# BS-INDENTED-PROBE) and the UF probe below — catches indented and
    # no-space forms. Only legal values are carried; illegal values stay for verify-state to FAIL on.
    # _e_bs is read into render_envelope via the shared shell scope.
    _e_bs="$(env_get block_scope)"
    if [ -z "$_e_bs" ]; then
      _raw_bs="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*block_scope:/{v=$0; sub(/^[[:space:]]*block_scope:[[:space:]]*/,"",v); print v; exit}' "$state")"  # BS-SYNC-PROBE
      case "$_raw_bs" in per-focus|shared-global) _e_bs="$_raw_bs" ;; esac
    fi
    # Generalized preamble carry-forward: collect all non-owned lines from the existing
    # envelope, normalized (leading whitespace stripped, space ensured after colon).
    # The 9 owned keys below are recomputed fresh every run; every other line —
    # block_scope:, method:, or any unknown future field — passes through unchanged.
    # Empty on first-seed (fence absent): nothing to carry forward yet.
    _extra_env_lines=''
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      _extra_env_lines="$(awk '
        /<!-- research-state.v1 -->/{b=1;next}
        /<!-- \/research-state.v1 -->/{b=0}
        b {
          line=$0; sub(/^[[:space:]]+/,"",line)
          colon=index(line,":")
          if (colon==0) next
          key=substr(line,1,colon-1)
          if (key=="schema"||key=="covered_blocks"||key=="gaps_closed"||key=="known_gaps"||
              key=="investigable_open"||key=="requires_execution_open"||key=="blocked_open"||
              key=="deferred_open"||key=="undocumented_findings") next
          val=substr(line,colon+1); sub(/^[[:space:]]+/,"",val); sub(/[[:space:]]+$/,"",val)
          printf "%s: %s\n",key,val
        }' "$state")"  # PREAMBLE-CARRY-FORWARD
    fi
    # covered_blocks from THIS file's own directory — identical discriminator + dirname scoping to
    # verify-state.sh (single definition rule, prevents dual-authority drift on this count).
    # B5 FIX: focus-prefix filter for multi-focus corpora; shared-global path mirrors BS-SHARED-GLOBAL-ONDISK.
    _sfpfx="$(derive_focus_prefix "$state")"
    if [ "$_e_bs" = "shared-global" ]; then
      # block_scope: shared-global → use attributed B<n> count (mirrors verify-state.sh CHECK A via
      # count_attributed_sg / _derive_attributed_sg respectively, so the two scripts always agree).
      # When no attributed ids are found: seed covered_blocks=0 (anti-silent-zero §7 — the three
      # states are: attributed count known → use it; 0 attributed → warn + seed 0; not shared-global
      # → per-focus or corpus-wide).  The old corpus-wide fallback was WRONG: it silently produced a
      # confident count that was not the attributed count METHODOLOGY §16 requires. verify-state.sh
      # correctly reports INFO unverifiable for the 0 case; seeder and verifier now agree.
      _attr_sg="$(count_attributed_sg)"  # SG-ATTR-SYNC
      if [ "${_attr_sg:-0}" -gt 0 ] 2>/dev/null; then
        cb="$_attr_sg"
      else
        cb=0  # SG-ZERO-UNVERIFIABLE
        printf 'sync-state: WARN: %s: shared-global focus has no attributed block ids (no B<n> in ## Covered blocks or ## Iteration history) — seeding covered_blocks=0; add B<n> ids to make this verifiable.\n' "$(basename "$state")" >&2  # SG-ZERO-WARN
      fi
    elif [ -n "$_sfpfx" ]; then
      cb="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
        | block_file_filter "${_sfpfx}" | wc -l | tr -d ' ')"
    else
      cb="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
        | block_file_filter | wc -l | tr -d ' ')"
    fi
    io="$(count_investigable)"
    bo="$(derive_blocked_open)"   # same disk-derived helper the status display reuses (single source of truth)
    def="$(count_deferred)"
    # declared-only figures from THIS file's prose (coverage metric X/Y), carrying the previous envelope
    # value when a figure is absent/unparseable (never invent — see pick()).
    cov="$(section '## Coverage' | grep -iE 'coverage metric' | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
    gc="$(pick "${cov%%/*}" "$(env_get gaps_closed)")"
    # known_gaps: take the larger of the backlog-derived total and the coverage metric Y (issue #568).
    # Backlog-derived: captures newly-added gaps even when the coverage metric prose is stale.
    # Coverage metric Y: preserved when closed gaps are tracked only in the prose and not as backlog rows.
    _dkg="$(count_all_known_gaps)"
    _dkg_total=$(( ${_dkg:-0} + ${def:-0} ))
    _cm_kg="${cov##*/}"
    if printf '%s' "${_dkg_total}" | grep -qE '^[0-9]+$' \
       && printf '%s' "${_cm_kg:-0}" | grep -qE '^[0-9]+$' \
       && [ "${_dkg_total}" -gt "${_cm_kg:-0}" ] 2>/dev/null; then
      kg="${_dkg_total}"  # KG-BACKLOG-EXCEEDS
    else
      kg="$(pick "${_cm_kg}" "$(env_get known_gaps)")"
    fi
    # requires_execution_open PREFERS the backlog-derived count (rows whose Status carries the
    # `requires-execution` marker → disk-anchored, in lockstep with verify-state.sh's CHECK E) and only
    # falls back to the prose stop-control number / previous envelope when NO row is marked — a marked
    # backlog is authoritative, a prose-only corpus (logosoft) keeps its declared counter.
    dreq="$(count_requires_execution)"
    if [ "$dreq" -gt 0 ]; then
      req="$dreq"
    else
      req="$(pick "$(req_prose)" "$(env_get requires_execution_open)")"
    fi
    # undocumented_findings: distinguish the three cases that pick("","...") collapses into one silent 0.
    # ABSENT       → seed 0 (METHODOLOGY §7 seeding contract; no warning — documented legacy path).
    # VALID        → carry the integer forward unchanged.
    # UNPARSEABLE  → warn loudly and carry the raw value forward; NOT replaced with 0 because that
    #                would erase real debt silently (the exact silent-loss channel BLOCKER 1B closes).
    #                verify-state CHECK G FAILs on the carried non-integer, so --next returns STALE.
    #
    # BLIND SPOT: env_get uses $1==key":" (whitespace field split).  A no-space typo like
    # `undocumented_findings:7` makes $1=="undocumented_findings:7" which never matches, so env_get
    # returns "" — identical to the ABSENT case — and the ABSENT branch would silently seed 0.
    # FIX: if env_get returns empty, apply the SAME whitespace-tolerant probe as verify-state.sh's
    # _uf_present (/^[[:space:]]*key:/ convention) to detect absent vs present-but-unreadable-by-env_get,
    # including indented forms and no-space forms (e.g. `  undocumented_findings:7`).
    _raw_uf="$(env_get undocumented_findings)"
    if [ -z "$_raw_uf" ]; then
      # Probe by KEY regex: whitespace-tolerant, matches indented and no-space forms alike.
      _raw_uf="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*undocumented_findings:/{val=$0; sub(/^[[:space:]]*undocumented_findings:[[:space:]]*/,"",val); print val; exit}' "$state")"  # UF-SYNC-PROBE
      # If still empty the line is genuinely absent → the case below takes the absent branch (seed 0).
    fi
    case "$_raw_uf" in
      '')           uf=0 ;;
      *[!0-9]*)
        printf 'sync-state: WARN: %s: undocumented_findings=%s is not a non-negative integer; value NOT replaced with 0 — fix manually and re-run --sync-state.\n' \
          "$(basename "$state")" "$_raw_uf" >&2
        uf="$_raw_uf" ;;
      *)            uf="$_raw_uf" ;;
    esac
    repl="$(render_envelope)"
    tmp="$(mktemp "$(dirname "$state")/.rsdd-sync.XXXXXX")"
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      # fence EXISTS → replace ONLY between the markers (idempotent; surrounding prose untouched).
      awk -v repl="$repl" '
        $0 ~ /<!-- research-state.v1 -->/ { print repl; skip=1; next }
        skip && $0 ~ /<!-- \/research-state.v1 -->/ { skip=0; next }
        skip { next }
        { print }' "$state" > "$tmp"
    else
      # fence ABSENT → insert right after the top intro blockquote (the first contiguous run of `>` lines);
      # if there is no blockquote, append at EOF. Either way a SECOND run finds the fence → byte-identical.
      awk -v repl="$repl" '
        { line=$0
          if (!done) {
            if (line ~ /^>/) inbq=1
            else if (inbq) { print repl; print ""; done=1 }
          }
          print line }
        END { if (!done) { print ""; print repl } }' "$state" > "$tmp"
    fi
    mv "$tmp" "$state"
    echo "sync-state: $(basename "$state") → covered_blocks=$cb gaps_closed=$gc known_gaps=$kg investigable_open=$io requires_execution_open=$req blocked_open=$bo deferred_open=$def undocumented_findings=$uf"
  done
  exit 0
fi

# _stop_exhausted — single source of truth for the exhausted-investigable STOP message.
# Both issues_due_gate and the --focus arm use this to prevent literal drift.
_stop_exhausted() { printf 'STOP | read-only-investigable exhausted (0)\n'; }

# --- ISSUES-DUE gate (--next terminal) ---------------------------------------------------------
# When the NEXT-resolution loop yields STOP (no investigable gaps), probe each retro under
# the target for untracked deltas via reconcile-issues.sh.  If any exist, emit ISSUES-DUE
# instead of STOP so the caller knows to seed them as GitHub issues.
# Enumeration: matches sweep-retros.sh idiom (maxdepth 4, */retros/*.md, no .git, no *index*,
#              -type f) so nested corpus layouts (corpus/retros/, research/retros/) are visible.
# Anti-silent-zero §7: "couldn't look" (find error) is distinct from "found zero".
# Early-exit (R4-budget): on first untracked retro, emit ISSUES-DUE immediately and return —
#                 do NOT probe remaining retros; do NOT report a fleet-wide denominator.
#                 The count and path in the output are scoped to that one retro only.
# Aggregate budget: probing all clean retros is bounded by _IDG_AGGREGATE_BUDGET_SECS (default
#                 60s). If exceeded before all-clean is confirmed, emit the unverified marker.
# Degraded probe: reconcile-issues.sh ^degraded: on stderr → WARN, set unverified flag, continue;
#                 never break on one retro's error.
# Timeout (R4-SERIAL): each reconcile call is wrapped in `timeout` (or `gtimeout` on macOS;
#                 _IDG_RECONCILE_TIMEOUT_SECS, default 15s); exit 124 → unverified, WARN, continue.
#                 If neither `timeout` nor `gtimeout` is present, FAIL CLOSED for liveness: mark
#                 coverage unverified and skip ALL probes (unbounded calls risk --next never returning).
#                 _IDG_TIMEOUT_BIN (test hook): when set (even to empty), overrides auto-detection.
# Stdout contract: verified-clean → bare STOP; unverified-coverage (any cause) → STOP
#                 with the generic suffix `[issue-coverage: unverified]` (R4-DEGRADED); the
#                 specific cause is reported on stderr by the branch that set _idg_had_unverified.
# Operational failure: non-degraded reconcile error → DISTINCT WARN naming the real failure.
# PERF: retros with applied/dismissed marker are skipped (zero gh calls per such retro).
issues_due_gate() {
  local -a _idg_retros
  local _idg_had_unverified _idg_total _idg_can_probe
  local _ri _ri_out _ri_rc _n _n_rc _n_rev _ri_rev_out _ri_rev_rc _idg_retro _find_rc _sort_rc
  local _idg_cache_file _idg_gh_fetch_rc _idg_gh_fetch_out
  local _ri_err_content _find_out_tmp _find_err_tmp _ri_err_tmp _rs_tok
  local _idg_timeout_secs _idg_timeout_bin _idg_aggr_budget _idg_aggr_start
  _idg_had_unverified=0; _idg_can_probe=1; _idg_total=0

  # F3: enumerate retros using sweep-retros.sh idiom — maxdepth 4, */retros/*.md, no .git,
  # no *index*.md, -type f — so nested layouts (corpus/retros/, research/retros/) are visible.
  # F4 (§7): completeness is decided by find EXIT STATUS, not stderr-non-empty.
  # Harden mktemp: if it fails → unverified coverage; skip probing (redirections would fail).
  _find_out_tmp="$(mktemp)" || { _idg_had_unverified=1; _idg_can_probe=0  # IDG-ENUM-MKTEMP-GUARD
    printf 'WARN: mktemp failed for retro enumeration — marking coverage unverified\n' >&2; }
  _find_err_tmp=""
  if [ "$_idg_can_probe" -eq 1 ]; then
    _find_err_tmp="$(mktemp)" || { _idg_had_unverified=1; _idg_can_probe=0
      rm -f "$_find_out_tmp"
      printf 'WARN: mktemp failed for retro enumeration stderr — marking coverage unverified\n' >&2; }
  fi
  if [ "$_idg_can_probe" -eq 1 ]; then
    # IDG-ENUM-PRED: predicate is INTENTIONALLY IDENTICAL to sweep-retros.sh (same -maxdepth 4,
    # -path '*/retros/*.md', same exclusions); -type f is an additional safety guard not present
    # in sweep-retros.sh's loop (which naturally ignores non-files in its read body). "0 retros
    # found" here means the same as "0 retros" in the fleet enumerator — not a gate-specific
    # blind spot.
    find "$target" -maxdepth 4 -path '*/retros/*.md' \
      -not -path '*/.git/*' -not -iname '*index*.md' -type f \
      >"$_find_out_tmp" 2>"$_find_err_tmp"
    _find_rc=$?
    sort -o "$_find_out_tmp" "$_find_out_tmp"   # IDG-SORT-IN-PLACE
    _sort_rc=$?
    mapfile -t _idg_retros < "$_find_out_tmp"
    rm -f "$_find_out_tmp" "$_find_err_tmp"
    # F4 (§7): partial visibility (find exited non-zero) → unverified; DO NOT discard listed retros —
    # those paths ARE visible and must still be probed.  Stderr noise on a clean exit is not an error.
    if [ "$_find_rc" -ne 0 ]; then
      _idg_had_unverified=1  # IDG-FIND-EXIT-UNVERIFIED
      printf 'WARN: retro enumeration incomplete (find exit %s) — treating coverage as unverified\n' \
        "$_find_rc" >&2
    fi
    # R4-sort-silent-zero: sort failure (TMPDIR full, OOM, sort absent) may produce a truncated array;
    # the find-exit check above does not cover the sort stage.  Treat any non-zero sort exit as unverified.
    if [ "$_sort_rc" -ne 0 ]; then
      _idg_had_unverified=1  # IDG-SORT-EXIT-UNVERIFIED
      printf 'WARN: retro enumeration sort failed (exit %s) — treating coverage as unverified\n' \
        "$_sort_rc" >&2
    fi
    # absent-input or empty-input: no retros found → nothing to probe; fall through to unified decision.
    if [ "${#_idg_retros[@]}" -eq 0 ]; then
      _idg_can_probe=0
    fi
  fi

  if [ "$_idg_can_probe" -eq 1 ]; then
    _ri="$here/reconcile-issues.sh"
    if [ ! -x "$_ri" ]; then
      _idg_had_unverified=1  # reconcile unavailable → unverified coverage, not bare STOP
      _idg_can_probe=0
      printf 'WARN: reconcile-issues.sh not executable at %s — skipping issues gate\n' "$_ri" >&2
    fi
  fi

  if [ "$_idg_can_probe" -eq 1 ]; then
    # R4-SERIAL: probe for timeout binary once; use _IDG_RECONCILE_TIMEOUT_SECS env override (default 15s).
    _idg_timeout_secs="${_IDG_RECONCILE_TIMEOUT_SECS:-15}"
    _idg_timeout_bin=""
    if [ "${_IDG_TIMEOUT_BIN+x}" = "x" ]; then
      _idg_timeout_bin="$_IDG_TIMEOUT_BIN"  # IDG-TIMEOUT-BIN-OVERRIDE (test hook)
    elif command -v timeout >/dev/null 2>&1; then
      _idg_timeout_bin="timeout"  # IDG-TIMEOUT-AVAIL-CHECK
    elif command -v gtimeout >/dev/null 2>&1; then
      _idg_timeout_bin="gtimeout"  # IDG-GTIMEOUT-AVAIL-CHECK
    fi
    if [ -z "$_idg_timeout_bin" ]; then
      _idg_had_unverified=1  # IDG-TIMEOUT-ABSENT-FAIL-CLOSED
      printf 'WARN: timeout(1)/gtimeout not available — cannot bound reconcile calls; marking coverage unverified\n' >&2
    fi

    # R4-AGGREGATE-BUDGET: bound total wall time for verifying all retros are clean.
    # Started BEFORE the batch fetch so the batch fetch is within the bounded region.
    # The early-exit path (IDG-EARLY-EXIT) fires on the first untracked retro and returns immediately;
    # this budget gates only the all-clean verification path where every retro must be probed.
    # Override via _IDG_AGGREGATE_BUDGET_SECS (default 60s).
    _idg_aggr_budget="${_IDG_AGGREGATE_BUDGET_SECS:-60}"  # IDG-AGGREGATE-BUDGET
    _idg_aggr_start="$SECONDS"

    # BATCH PREFETCH (fast path): fetch all open issue bodies ONCE per --next terminal.
    # The batch gh call is timeout-wrapped (same per-call bound as per-retro probes), and the
    # aggregate budget starts above so the batch fetch is within the bounded region.
    # Bounded by --limit (default 5000; override via _IDG_BATCH_LIMIT) to cap page size.
    # On batch failure (any non-zero exit, including timeout exit 124): cache stays empty;
    # the loop below uses the per-retro FALLBACK path (each retro does its own bounded gh probe).
    # A stale cache is impossible: _idg_cache_file is a tmpfile created here and deleted after the loop.
    _idg_cache_file=""
    if [ -n "$_idg_timeout_bin" ]; then
      _idg_cache_file="$(mktemp)" || {
        _idg_had_unverified=1
        printf 'WARN: mktemp failed for issue-cache — marking coverage unverified\n' >&2
      }
      if [ -n "$_idg_cache_file" ]; then
        # IDG-BATCH-GH-CALL: one gh issue list call covers ALL retros in this --next terminal.
        # IDG-BATCH-GH-TIMEOUT-WRAP: batch call timeout-wrapped (same per-call bound as per-retro probes).
        _idg_gh_fetch_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" gh issue list \
            --repo "angeles725/sdd-investigacion" \
            --state open \
            --json body \
            --limit "${_IDG_BATCH_LIMIT:-5000}" \
            --jq '.[].body' 2>/dev/null)"  # IDG-BATCH-LIMIT-PRESENT
        _idg_gh_fetch_rc=$?
        if [ "$_idg_gh_fetch_rc" -ne 0 ]; then
          # IDG-BATCH-FAILURE: any non-zero rc (incl. timeout 124) → clear cache; per-retro fallback.
          rm -f "$_idg_cache_file"; _idg_cache_file=""
          printf 'WARN: batch issue prefetch failed (exit %s) — falling back to per-retro reconcile\n' \
            "$_idg_gh_fetch_rc" >&2
        else
          printf '%s\n' "$_idg_gh_fetch_out" > "$_idg_cache_file"
        fi
      fi
    fi

    # PERF: source retro-status lib for pre-filtering applied/dismissed retros (avoids gh call).
    _rs_lib="$here/lib/retro-status.sh"
    if [ -f "$_rs_lib" ]; then
      # shellcheck source=lib/retro-status.sh
      . "$_rs_lib"
    fi

    _idg_total="${#_idg_retros[@]}"
    # Harden mktemp: if it fails we cannot safely capture stderr per-retro; mark coverage unverified.
    _ri_err_tmp="$(mktemp)" || { _idg_had_unverified=1; _ri_err_tmp=""; printf 'WARN: mktemp failed — cannot capture reconcile stderr; marking coverage unverified\n' >&2; }
    for _idg_retro in "${_idg_retros[@]}"; do
      # PERF: skip retros whose marker is applied/dismissed — no gh call needed.
      if declare -F retro_review_status >/dev/null 2>&1; then
        _rs_tok="$(retro_review_status "$_idg_retro")"
        case "$_rs_tok" in applied|dismissed) continue ;; esac
      fi

      # Guard: skip reconcile call if mktemp failed (stderr cannot be safely redirected).
      if [ -z "$_ri_err_tmp" ]; then continue; fi

      # R4-AGGREGATE-BUDGET: stop probing when wall budget is exceeded before confirming all-clean.
      # On first untracked retro, IDG-EARLY-EXIT returns immediately so this check is only
      # reached on the clean path where every retro needs to be verified.
      if (( (SECONDS - _idg_aggr_start) >= _idg_aggr_budget )); then  # IDG-AGGREGATE-EXCEEDED
        _idg_had_unverified=1
        printf 'WARN: aggregate reconcile budget (%ss) exceeded — marking coverage unverified\n' \
          "$_idg_aggr_budget" >&2
        break
      fi

      # F4/F5: capture reconcile stderr; do NOT discard into /dev/null.
      # R4-SERIAL: when no timeout binary is available, skip this probe (fail-closed for liveness);
      # _idg_had_unverified was already set in the availability check above.
      [ -z "$_idg_timeout_bin" ] && continue  # IDG-TIMEOUT-ABSENT-SKIP
      # IDG-BATCH-FALLBACK: on batch failure (_idg_cache_file empty) → per-retro gh probe (no SPOF).
      # IDG-BATCH-PASS-CACHE: on batch success (_idg_cache_file set) → use pre-fetched cache.
      if [ -n "$_idg_cache_file" ]; then
        # IDG-BATCH-PASS-CACHE: pass pre-fetched issue bodies; reconcile reads cache, no per-retro gh call.
        _ri_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" --issues-cache "$_idg_cache_file" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-TIMEOUT-WRAP
      else
        # IDG-BATCH-FALLBACK-PER-RETRO: batch failed; each retro does its own bounded gh probe.
        _ri_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-TIMEOUT-WRAP
      fi
      _ri_rc=$?
      _ri_err_content="$(cat "$_ri_err_tmp")"
      : > "$_ri_err_tmp"  # clear for next iteration

      if [ "$_ri_rc" -ne 0 ]; then
        if [ "$_ri_rc" -eq 124 ]; then
          # R4-SERIAL: reconcile timed out → unverified coverage; WARN, continue
          _idg_had_unverified=1
          printf 'WARN: reconcile-issues.sh timed out for %s — treating as unverified\n' \
            "$(basename "$_idg_retro")" >&2
        elif printf '%s\n' "$_ri_err_content" | grep -qE '^degraded:'; then
          # F5a: gh degraded → WARN + continue (fall through; don't break, don't block offline)
          _idg_had_unverified=1
          printf 'WARN: could not verify issue coverage (gh degraded) — seed manually\n' >&2
        else
          # F5b: operational failure — any non-zero exit not covered above is also unverified coverage.
          _idg_had_unverified=1  # IDG-OPFAIL-SENTINEL
          printf 'WARN: reconcile-issues.sh failed for %s (exit %s) — %s\n' \
            "$(basename "$_idg_retro")" "$_ri_rc" "${_ri_err_content:-no stderr}" >&2
        fi
        continue  # F5c: never break; accumulate from remaining retros
      fi
      _n="$(printf '%s\n' "$_ri_out" | awk '/^untracked:/{n++} END{print n+0}')"  # IDG-UNTRACKED-PATTERN
      _n_rc=$?
      # Sweep: awk failure (OOM, absent) → count unreliable; treat as unverified, never as clean.
      if [ "$_n_rc" -ne 0 ]; then
        _idg_had_unverified=1  # IDG-AWK-COUNT-FAIL
        printf 'WARN: awk untracked-count failed for %s (exit %s) — treating as unverified\n' \
          "$(basename "$_idg_retro")" "$_n_rc" >&2
        continue
      fi
      # IDG-BATCH-UNTRACKED-REVERIFY: when the batch cache was used and this retro came back untracked,
      # a truncated/empty/rate-limited batch (or a page hitting the --limit cap) can produce a false
      # negative. Positive evidence (tracked) from the batch is trustworthy; negative evidence is not.
      # Re-verify with one per-retro narrowed gh query before emitting ISSUES-DUE.
      if [ "${_n:-0}" -gt 0 ] && [ -n "$_idg_cache_file" ]; then  # IDG-BATCH-UNTRACKED-REVERIFY
        _ri_rev_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-REVERIFY-TIMEOUT-WRAP
        _ri_rev_rc=$?
        _ri_err_content="$(cat "$_ri_err_tmp")"
        : > "$_ri_err_tmp"
        if [ "$_ri_rev_rc" -ne 0 ]; then
          if [ "$_ri_rev_rc" -eq 124 ]; then
            _idg_had_unverified=1
            printf 'WARN: re-verify timed out for %s — treating as unverified\n' \
              "$(basename "$_idg_retro")" >&2
          elif printf '%s\n' "$_ri_err_content" | grep -qE '^degraded:'; then
            _idg_had_unverified=1
            printf 'WARN: could not re-verify issue coverage (gh degraded) — seed manually\n' >&2
          else
            _idg_had_unverified=1
            printf 'WARN: re-verify failed for %s (exit %s) — %s\n' \
              "$(basename "$_idg_retro")" "$_ri_rev_rc" "${_ri_err_content:-no stderr}" >&2
          fi
          continue
        fi
        _n_rev="$(printf '%s\n' "$_ri_rev_out" | awk '/^untracked:/{n++} END{print n+0}')"
        if [ "${_n_rev:-0}" -eq 0 ]; then
          # Per-retro re-verify says tracked → batch was a false negative (truncation/lag) → not untracked.
          continue  # IDG-BATCH-REVERIFY-CLEAN
        fi
        # Both batch and re-verify say untracked → genuinely untracked → proceed to ISSUES-DUE.
        _n="$_n_rev"  # use the re-verified count
      fi
      if [ "${_n:-0}" -gt 0 ]; then  # ISSUES-DUE-GATE-COND
        # IDG-EARLY-EXIT: first retro with untracked deltas → emit ISSUES-DUE immediately and stop.
        # Do NOT probe remaining retros; do NOT report _idg_total as a denominator (includes
        # unprobed retros). Count and path are scoped to THIS retro only.
        [ -n "$_ri_err_tmp" ] && rm -f "$_ri_err_tmp"
        [ -n "$_idg_cache_file" ] && rm -f "$_idg_cache_file"
        printf 'ISSUES-DUE | %s untracked delta(s) in %s — seed: stage-retro-issues.sh %s --apply\n' \
          "$_n" "$_idg_retro" "$_idg_retro"
        return  # IDG-EARLY-EXIT
      fi
    done
    [ -n "$_ri_err_tmp" ] && rm -f "$_ri_err_tmp"
    [ -n "$_idg_cache_file" ] && rm -f "$_idg_cache_file"
  fi

  # Unified decision: unverified wins over verified-clean; verified-clean last.
  # Note: ISSUES-DUE is emitted early-exit (IDG-EARLY-EXIT) inside the loop above; it never
  # reaches this point.
  # R4-DEGRADED: distinguish unverified-coverage (degraded or timeout) from verified-clean.
  # Untracked wins over unverified (ISSUES-DUE already returned above when >0).
  if [ "$_idg_had_unverified" -gt 0 ]; then
    printf 'STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]\n'  # IDG-UNVERIFIED-MARKER
    return
  fi
  # no-match: retros exist, all deltas tracked (or empty retros with clean find) → verified-clean STOP
  _stop_exhausted
}

if [ "$mode" = "--next" ]; then
  # Refuse to hand out work on an internally inconsistent state (summary claims done while backlog
  # lists pending — verify-state.sh exits 1 on that). An agent trusting --next alone must reconcile first.
  # Use $target (not $corpus) so the STALE gate covers the same scope as the aggregation below: scanning
  # only $corpus=dirname(first) would miss sibling focuses in a split-layout and give a false green light.
  if ! "$here/verify-state.sh" "$target" >/dev/null 2>&1; then
    if [ -z "$focus_slug" ]; then
      # Multi-focus bypass (issue #194): verify-state failed, but the failure may be ONLY from
      # genuinely stopped focuses whose envelopes were not re-seeded after all gaps were covered.
      # A stopped focus's stale envelope must NOT brick the corpus-wide --next result.
      # Classify each focus: unparseable backlog OR active focus (d_inv>0) with a stale critical
      # field → real STALE; stopped focus (parseable + d_inv=0) → skip (forgive stale envelope).
      mapfile -t _stale_chk < <(list_state_files "$target")
      _any_real_stale=0  # N194-STOPPED-BYPASS
      # Bypass scope: multi-focus only. A stopped focus must have an active sibling to fall through
      # to; a single-focus corpus with a failing verify-state has no such sibling and must always
      # surface as STALE. This also prevents BPSKIP-form priorities (strikethrough, em-dash,
      # qualifier) from driving count_investigable to 0 and being mistaken for a legitimate stop:
      # in a single-focus corpus the ONLY way d_inv=0 is trustworthy is with a clean verify-state,
      # which would have passed above and never reached this bypass path.
      if [ "${#_stale_chk[@]}" -lt 2 ]; then
        echo "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
        exit 0
      fi
      for state in "${_stale_chk[@]}"; do
        # FOCUSES.md check FIRST (issue #641): a stopped/paused focus with malformed priority must be
        # skipped before the INVALID_PRIORITY guard fires, or its unparseable backlog bricks the corpus.
        # Extends N194-STOPPED-BYPASS to also cover stopped focuses whose priority column is unknown.
        # The INVALID_PRIORITY guard below is therefore only reached for ACTIVE focuses.  # N194-FOCUSES-SKIP  # N641-FOCUSES-BEFORE-INVALID-PRIORITY
        _sfoc_file="$(dirname "$state")/FOCUSES.md"
        _sfoc_tok="$(_read_focuses_tok "$_sfoc_file" "$(basename "$state")")"
        if [ "$_sfoc_tok" = "stopped" ] || [ "$_sfoc_tok" = "paused" ]; then
          continue
        fi
        # Unparseable backlog is a real failure for ACTIVE focuses (concealment hazard, BP-INVALID-PRIORITY-FAIL).
        if backlog_rows 2>/dev/null | grep -q '^INVALID_PRIORITY'; then
          _any_real_stale=1; break
        fi
        _d_inv="$(count_investigable)"
        if [ "${_d_inv}" != "0" ]; then
          # Active focus — check critical envelope consistency (mirrors verify-state CHECK B + CHECK D).
          if ! grep -q '<!-- research-state.v1 -->' "$state" 2>/dev/null; then
            _any_real_stale=1; break
          fi
          _e_inv="$(env_get investigable_open)"
          if [ "${_e_inv}" != "${_d_inv}" ]; then
            _any_real_stale=1; break
          fi
          # CHECK D mirror: declared full coverage (gc==kg, kg>0) while investigable gaps remain.
          _e_gc="$(env_get gaps_closed)"; _e_kg="$(env_get known_gaps)"
          if [ -n "${_e_gc}" ] && [ -n "${_e_kg}" ] \
             && printf '%s%s' "${_e_gc}" "${_e_kg}" | grep -qE '^[0-9]+$' \
             && [ "${_e_kg}" -gt 0 ] 2>/dev/null \
             && [ "${_e_gc}" = "${_e_kg}" ]; then
            _any_real_stale=1; break
          fi
        fi
        # d_inv=0 + parseable: genuinely stopped focus — its stale envelope is bypassed (#194).
      done
      if [ "${_any_real_stale}" = 1 ]; then
        echo "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
        exit 0
      fi
      # All verify-state failures are from stopped focuses — fall through to aggregation.
    else
      echo "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
      exit 0
    fi
  fi
  # RETRO-DUE (§18 cadence): after STALE passes, check for blocks_since_retro > 10.
  # Check the relevant state file(s): just $state for single-focus, all active files for multi-focus.
  # Emits RETRO-DUE and exits before NEXT/STOP so the cadence advisory reaches the caller.  # RD-BLOCKS-SINCE-RETRO-CHECK
  _rd_threshold=10
  if [ -n "$focus_slug" ]; then
    _rd_states=("$state")
  else
    mapfile -t _rd_states < <(list_state_files "$target")
  fi
  for state in "${_rd_states[@]}"; do
    _rd_foc_file="$(dirname "$state")/FOCUSES.md"
    _rd_foc_tok="$(_read_focuses_tok "$_rd_foc_file" "$(basename "$state")")"
    if [ "$_rd_foc_tok" = "stopped" ] || [ "$_rd_foc_tok" = "paused" ]; then continue; fi
    _rd_bsr="$(env_get blocks_since_retro)"
    if printf '%s' "$_rd_bsr" | grep -qE '^[0-9]+$' && [ "$_rd_bsr" -gt "$_rd_threshold" ]; then  # RD-THRESHOLD-CHECK
      echo "RETRO-DUE | ${_rd_bsr} blocks since last retro (§18 threshold: ${_rd_threshold})"
      exit 0
    fi
  done
  if [ -z "$focus_slug" ]; then
    # Multi-focus guard (chihuahua/px-chart-classic regression + BLOCKER 2 split-layout): iterate every
    # state file under $target (not just $corpus=dirname(first)), so focuses in sibling subdirectories are
    # not missed. Return NEXT from the first active focus; only emit STOP when ALL focuses are stopped.
    # Scanning $corpus alone was the C3 false-STOP root cause one directory level up: alpha (stopped)
    # sorted first → corpus=alpha → aggregation never reached beta (active) → false STOP.
    mapfile -t _next_states < <(list_state_files "$target")
    _nxt_skip_gaps=0
    : # IDG-PREC-SENTINEL (teeth-IDG-precedence: replace with 'issues_due_gate; exit 0' to verify gate fires AFTER resolve_next)
    for state in "${_next_states[@]}"; do
      _nxt_foc_slug="$(basename "$state" .md)"; _nxt_foc_slug="${_nxt_foc_slug#RESEARCH-STATE-}"
      _nxt_foc_file="$(dirname "$state")/FOCUSES.md"
      _nxt_foc_tok="$(_read_focuses_tok "$_nxt_foc_file" "$(basename "$state")")"  # N194-FOCUSES-SKIP
      if [ "$_nxt_foc_tok" = "stopped" ] || [ "$_nxt_foc_tok" = "paused" ]; then
        printf 'INFO: skipped %s (focus-status: %s in FOCUSES.md)\n' "$_nxt_foc_slug" "$_nxt_foc_tok" >&2
        [ -r "$state" ] || printf 'WARN: cannot read state file %s\n' "$state" >&2
        _nxt_skip_d_inv="$(count_investigable 2>/dev/null)"
        [ "${_nxt_skip_d_inv:-0}" != "0" ] && _nxt_skip_gaps=$(( _nxt_skip_gaps + 1 ))
        continue
      fi
      _r="$(resolve_next)"
      case "$_r" in NEXT\ *) echo "$_r"; exit 0;; esac
    done
    if [ "$_nxt_skip_gaps" -gt 0 ]; then
      echo "STOP | no active focus (${_nxt_skip_gaps} declared stopped/paused in FOCUSES.md with open gaps)"
    else
      issues_due_gate
    fi
  else
    _rn_out="$(resolve_next)"
    case "$_rn_out" in
      "STOP | read-only-investigable exhausted (0)") issues_due_gate ;;  # IDG-FOCUS-GATE
      *) printf '%s\n' "$_rn_out" ;;
    esac
  fi
  exit 0
fi

# --- default: structured status report ---------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"
metric="$(section '## Coverage' | grep -iE 'coverage metric' | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
covered="$(section '## Coverage' | grep -iE 'covered blocks' | grep -oE '[0-9]+' | head -1)"
# B5 FIX: derive per-focus block count (mirrors --sync-state and verify-state.sh).
_stpfx="$(derive_focus_prefix "$state")"
if [ -n "$_stpfx" ]; then
  ondisk="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter "${_stpfx}" | wc -l | tr -d ' ')"
else
  ondisk="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter | wc -l | tr -d ' ')"
fi
inv="$(inv_count)"
req="$(req_prose)"   # token-anchored + paren-stripped (a bare first-integer grep grabbed §8 on logosoft)
blk="$(derive_blocked_open)"   # disk-DERIVED (needs:-anchored) — NOT the stop-control prose, whose bare first-integer grep grabbed a "§8" section number (logosoft showed blocked=8)
ph=$(backlog_rows 2>/dev/null | awk -F'\t' '$2~/~~/{next} {st=$3; sub(/^\*\*/, "", st); sub(/\*\*$/, "", st)} st=="pending"{n[$1]++} END{printf "high=%d medium=%d low=%d", n["high"], n["medium"], n["low"]}')

echo "== research-sdd-status: $(basename "$target")  ·  corpus: $rel =="
echo "  coverage metric : ${metric:-<none>}"
echo "  covered blocks  : ${covered:-<none>} claimed · ${ondisk} on disk"
echo "  pending backlog : $ph"
echo "  stop-control    : investigable=${inv:-?} · requires-execution=${req:-?} · blocked=${blk:-?}"
mapfile -t ledgers < <(contra_ledgers)
if [ "${#ledgers[@]}" -eq 0 ]; then
  echo "  contradictions  : (no ledger)"
else
  [ "${#ledgers[@]}" -gt 1 ] && echo "WARN: multiple CONTRADICTIONS*.md ledgers under $corpus — counting all ${#ledgers[@]}" >&2
  nopen="$(count_open_contra "${ledgers[@]}")"
  [ "$nopen" -gt 0 ] && echo "  contradictions  : ${nopen} open" || echo "  contradictions  : (none)"
fi
saturation_line
# next step: aggregate across ALL focuses under $target (not just the alphabetically-first one via $state).
# WARNING 3: the default report was binding resolve_next to $state=head-1, so a stopped alpha printed
# "STOP" while beta had open gaps — the supervisor saw misinformation with a green consistency footer.
# Using a subshell keeps $state (and thus $corpus) unchanged in the parent for the footer below.
printf '  next step       : '
(
  _ns_skip_gaps=0
  mapfile -t _ns_states < <(list_state_files "$target")
  for state in "${_ns_states[@]}"; do
    _ns_foc_slug="$(basename "$state" .md)"; _ns_foc_slug="${_ns_foc_slug#RESEARCH-STATE-}"
    _ns_foc_file="$(dirname "$state")/FOCUSES.md"
    _ns_foc_tok="$(_read_focuses_tok "$_ns_foc_file" "$(basename "$state")")"
    if [ "$_ns_foc_tok" = "stopped" ] || [ "$_ns_foc_tok" = "paused" ]; then
      printf 'INFO: skipped %s (focus-status: %s in FOCUSES.md)\n' "$_ns_foc_slug" "$_ns_foc_tok" >&2
      [ -r "$state" ] || printf 'WARN: cannot read state file %s\n' "$state" >&2
      _ns_inv="$(count_investigable 2>/dev/null)"
      [ "${_ns_inv:-0}" != "0" ] && _ns_skip_gaps=$(( _ns_skip_gaps + 1 ))
      continue
    fi
    _r="$(resolve_next)"
    case "$_r" in NEXT\ *) echo "$_r"; exit 0;; esac
  done
  if [ "$_ns_skip_gaps" -gt 0 ]; then
    echo "STOP | no active focus (${_ns_skip_gaps} declared stopped/paused in FOCUSES.md with open gaps)"
  else
    echo "STOP | read-only-investigable exhausted (0)"
  fi
)
echo "  --- consistency (verify-state.sh) ---"
"$here/verify-state.sh" "$corpus" 2>&1 | sed -n '/summary\|FAIL\|WARN\|ok /p' | sed 's/^/  /'
exit 0   # a stale-mirror FAIL is REPORTED in the consistency line above; it must not become our exit code (contract: 0 ok / 2 bad args)
