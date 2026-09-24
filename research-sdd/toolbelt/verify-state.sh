#!/usr/bin/env bash
# verify-state.sh — living-mirror consistency lint for a Research-SDD RESEARCH-STATE.md (retro delta #6).
#
# Catches the stale-summary desync that lets the loop emit a PREMATURE STOP: a summary that claims
# "N / N gaps closed" while the backlog still lists `pending` gaps. That exact desync (summary said
# 23/23 closed while 16 gaps were pending) is what let the pruebas-dashboards run-A STOP early; three.js
# hit the same class of drift ("21 md / 3 runs" while the corpus grew to 32 blocks). The PROMPT-LOOP
# living-mirror rule already MANDATES refreshing the row on run close — this mechanizes the check so the
# rule is enforced, not just remembered.
#
# Usage: verify-state.sh <target-dir> [--focus <slug>]
# Exit: 0 = consistent · 1 = inconsistency (stale mirror) · 2 = bad args / no state file / absent-focus.
set -uo pipefail

# Shared focus-prefix derivation — single source of truth (verify-state.sh and research-sdd-status.sh
# previously carried hand-copied implementations that were byte-identical but could drift;
# lib/focus-prefix.sh eliminates that hazard).
_FPLIB="$(cd "$(dirname "$0")" && pwd)/lib/focus-prefix.sh"
if [ ! -f "$_FPLIB" ]; then
  echo "verify-state: cannot find helper $_FPLIB" >&2; exit 1
fi
# shellcheck source=lib/focus-prefix.sh
. "$_FPLIB"
# Fail closed: verify-state.sh does NOT use `set -e`, so a failed/partial/syntax-broken source would
# be swallowed and every derive_focus_prefix call would silently return empty (count ALL blocks — a
# false-pass that masks cross-focus block-count mismatches). Abort before any corpus check.
declare -F derive_focus_prefix >/dev/null 2>&1 || { echo "verify-state: helper $_FPLIB failed to define derive_focus_prefix" >&2; exit 1; }

_BFLIB="$(cd "$(dirname "$0")" && pwd)/lib/block-files.sh"
if [ ! -f "$_BFLIB" ]; then echo "verify-state: cannot find helper $_BFLIB" >&2; exit 1; fi
# shellcheck source=lib/block-files.sh
. "$_BFLIB"
declare -F block_file_filter >/dev/null 2>&1 || { echo "verify-state: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
unset _BFLIB

target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-state.sh <target-dir> [--focus <slug>]" >&2; exit 2; }
shift  # consume the target-dir positional arg; remaining args are optional flags
focus_slug=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --focus)
      focus_slug="${2:-}"
      [ -z "$focus_slug" ] && { echo "usage: verify-state.sh <target-dir> [--focus <slug>]" >&2; exit 2; }  # FOCUS-EMPTY-SLUG-GUARD
      shift 2 ;;
    *) echo "usage: verify-state.sh <target-dir> [--focus <slug>]" >&2; exit 2 ;;
  esac
done
if [ -n "$focus_slug" ]; then  # FOCUS-FILTER
  _focused="$(find "$target" -maxdepth 3 -name "RESEARCH-STATE-${focus_slug}.md" \
    -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
  if [ ! -f "$_focused" ]; then
    echo "verify-state: no RESEARCH-STATE-${focus_slug}.md found under $target" >&2; exit 2
  fi
  states=("$_focused")
else
  # Lint EVERY RESEARCH-STATE*.md under the target (a reopened / multi-focus corpus keeps one per
  # focus). Exit 2 only when NONE exists; otherwise aggregate: rc=1 if ANY state file fails CHECK 1.
  mapfile -t states < <(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null)
  [ "${#states[@]}" -gt 0 ] || { echo "verify-state: no RESEARCH-STATE*.md under $target" >&2; exit 2; }
fi

# ---------------------------------------------------------------------------------------------------
# research-state.v1 ENVELOPE — the machine-validated contract (retro delta: port of gentle-ai's
# verify-result/v1 envelope discipline). The envelope is a marker-fenced block of `key: <int>` lines
# (dead-simple grep/awk, NO nested YAML — same idiom as the rest of the toolbelt). It DECLARES the
# load-bearing counts; verify-state RECOMPUTES the disk-anchored ones and FAILs on ANY drift, so a stale
# envelope can never hand out a premature STOP. Field names use UNDERSCORES (covered_blocks, NOT the prose
# "covered blocks") precisely so envelope lines never collide with the CHECK 1/2/3 prose greps below.
has_env()   { grep -q '<!-- research-state.v1 -->' "$1"; }
env_field() { awk -v k="$2" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{v=$2; sub(/\r$/,"",v); print v; exit}' "$1"; }  # sub strips a trailing CR so a CRLF-saved envelope is not falsely rejected by is_int
is_int()    { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }


# Ground-truth derivations. These MIRROR research-sdd-status.sh (section / backlog_rows / blocked_names /
# is_blocked) EXACTLY: verify-state stays STANDALONE (no shared lib — status.sh's mutation harness copies
# only verify-state.sh into a temp dir, so a sourced lib there would break it), which makes this a
# DELIBERATE mirror that MUST stay in lockstep with status.sh and with what `--sync-state` writes.
_section()      { awk -v h="$2" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$1"; }
# BR-CACHE: avoids re-running the _backlog_rows awk (and re-emitting its structural WARNs to stderr)
# when multiple checks within the same per-state pass all call _backlog_rows. Without the cache each
# of the four callers (_bparse_out, derive_pending_rows, derive_investigable, derive_requires_execution)
# re-runs the full awk and re-emits every NM-WARN/VS-N4-WARN, producing 4× duplicates per structure
# issue. The cache ensures the awk and its WARNs run ONCE per state file.
_BR_CACHED_FILE=""
_BR_CACHED_ROWS=""

_backlog_rows() {       # emits "priority<TAB>gap-key<TAB>status" (gap-key=gap text 4-col, id 5-col) for valid 4- or 5-col rows; INVALID_PRIORITY<TAB><val>
  # for unknown priority values. Callers that derive counts safely ignore the 2-field sentinel (field 3
  # absent so no count fires); the per-state backlog parse check below treats INVALID_PRIORITY as FAIL.
  # Column layout: 4-col (`| p | gap | type | status |`) OR 5-col (`| p | id | gap | artifact | status |`);
  # expected_cols is set from the separator row and governs column-width acceptance (4 or 5 only; any
  # other width emits BP-WIDTH-WARN and rows in that table are skipped) and status extraction (a[4] vs a[5]).
  # Silently skips: deferred (parked), strikethrough (~~p~~), em-dash (—), COVERED rows whose status
  # cell contains a pipe (5C-COVERED-PIPE-SKIP / VS-567-COVERED-PIPE-SKIP). Qualifier forms ("high (ctx)")
  # emit a provisional WARN to stderr and are still excluded. Unknown qualifier BASE fails closed.
  # Note: "med" abbreviation is NOT normalized here — that is a separate calibration work unit (#941).
  #   Rows with priority "med" emit INVALID_PRIORITY and are excluded from counts.
  # U+2011-NORM: non-breaking hyphens (U+2011, UTF-8 octet \342\200\221) in heading lines are normalised
  #   to ASCII hyphen by an awk gsub so "## Gap‑backlog (prioritized)" matches the heading pattern.
  #   Scoped to heading lines only (not a whole-file rewrite); portable (no GNU sed \xNN syntax).
  # Mirrors backlog_rows() in status.sh exactly (deliberate mirror — no shared lib; see comment above).
  # Same file as last call → return cached rows; structural WARNs already emitted once.
  if [ "$_BR_CACHED_FILE" = "$1" ]; then  # BR-CACHE-HIT
    [ -n "$_BR_CACHED_ROWS" ] && printf '%s\n' "$_BR_CACHED_ROWS"
    return
  fi
  # BR-CACHE-MISS: run awk; WARNs go to stderr exactly once; capture stdout for subsequent calls.
  _BR_CACHED_FILE="$1"
  _BR_CACHED_ROWS="$(LC_ALL=C awk '
    # BACKLOG-ROWS-AWK-START
    /^## Gap-backlog( \([^)]+\))?$/ { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _nm_was_last=0; in_backlog=1; in_data=0; expected_cols=0; next }  # OOB-WARN-FLUSH
    /^## / && tolower($0) ~ /backlog/ { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _this_line_nm=1; print "WARN: near-miss gap-backlog heading [" $0 "] — expected \"## Gap-backlog\" or \"## Gap-backlog (<label>)\" per METHODOLOGY" > "/dev/stderr" }  # NM-WARN
    /^## / { if (!_this_line_nm) { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr"; _oob_count=0; _nm_was_last=0 }; _nm_was_last=_this_line_nm; _this_line_nm=0; in_backlog=0; in_data=0; expected_cols=0; next }
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); for(k=1;k<=n;k++) gsub(/^[ \t]+|[ \t]+$/,"",a[k])
      p=tolower(a[1])
      if (p~/^-+$/) { in_data=1; if (!in_backlog) next; expected_cols=(n==4||n==5)?n:-1; if (expected_cols<0) print "WARN: backlog table has " n " columns (separator: " $0 ") — only 4- or 5-column tables accepted per METHODOLOGY §8b; rows will be skipped" > "/dev/stderr"; next }  # BP-EXPECTED-COLS: accept only 4- or 5-col backlog tables; BP-WIDTH-WARN on unsupported width; BP-SEP-IN-BACKLOG: separator outside a Gap-backlog section sets in_data but does not WARN
      if (p~/^-/) { next }    # BP-LIST-ITEM-GUARD: prose list items (markdown dash marker with pipes in text) are not table rows; safe after all-dashes check above
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
      if (!in_backlog && in_data) { _oob_count++ }  # OOB-ACCUM: accumulate per-section; flushed at ## heading or EOF
      if (expected_cols < 0) { next }  # BP-WIDTH-SKIP: unsupported table width; WARN already emitted on separator
      sc = (expected_cols > 0) ? expected_cols : 4  # BP-SC-FALLBACK: default 4 if no separator seen yet
      sc_msg = (expected_cols > 0) ? sc : "4 or 5"  # BP-SC-MSG: "4 or 5" when no separator seen (fallback context)
      if (n!=sc) {
        if (sc==5 && n>sc && tolower(a[5]) ~ /^covered/) { print "WARN: COVERED row has " n " cells in 5-col table (pipe in status cell) — review: " $0 > "/dev/stderr"; next }  # VS-COVERED-PIPE-WARN: COVERED rows with extra cells emit WARN, not silent drop
        if (sc==4 && n>sc && tolower(a[4]) ~ /^covered/) { print "WARN: COVERED row has " n " cells in 4-col table (pipe in status cell) — review: " $0 > "/dev/stderr"; next }  # VS-567-COVERED-PIPE-WARN: COVERED rows with extra cells emit WARN, not silent drop
        if (in_backlog && in_data) { print "WARN: malformed backlog row (" n " cells, expected " sc_msg " — a cell may contain a pipe): " $0 > "/dev/stderr" }  # VS-MALFORMED-WARN: scoped to in_backlog only (N3)
        next }
      { st = (sc==5) ? tolower(a[5]) : tolower(a[4]); gsub(/^\*\*/, "", st); gsub(/\*\*$/, "", st) }  # VS-634-BOLD-STRIP: strip leading/trailing ** from status field (a[4] for 4-col, a[5] for 5-col)
      print p "\t" a[2] "\t" st }
    END { if (_oob_count>0 && !_nm_was_last) printf "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n",_oob_count > "/dev/stderr" }  # OOB-WARN-EOF
  ' "$1")"
  [ -n "$_BR_CACHED_ROWS" ] && printf '%s\n' "$_BR_CACHED_ROWS"
}
# B3a: _blocked_names also scans "## Non-investigable gaps" (semantically identical to ## Blocked gaps;
# used in older/TRANE/EduVolt corpora) and "## Blocked / <qualifier> gaps" (niagara-research fleet
# form, e.g. "## Blocked / non-read-only gaps", "## Blocked / requires-execution gaps"). All three
# follow the same "- <name> — needs: …" convention and map to the same blocked_open bucket.
_blocked_names() {                                  # one exact blocked gap NAME per "- <name> — needs: ..." line
  { _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; _section "$1" '## Blocked /'; } \
    | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
    | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}
# derived investigable_open = pending (LEADING-TOKEN) backlog rows whose gap is NOT blocked. This is
# resolve_next's NEXT-eligibility set by construction — the STOP-CRITICAL number that closes the
# premature-STOP class: if the envelope under-declares it, verify-state FAILs → --next returns STALE.
derive_investigable() {
  local sf="$1" blk gap st n=0 b hit
  blk="$(_blocked_names "$sf")"
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    [ "${st%% *}" = "pending" ] || continue         # bare `pending` or decorated `pending (...)`; NOT "blocked (pending review)"
    hit=0; while IFS= read -r b; do [ -n "$b" ] && [ "$b" = "$gap" ] && { hit=1; break; }; done <<<"$blk"
    [ "$hit" = 1 ] && continue                       # exact-name blocked exclusion (mirrors is_blocked)
    n=$((n+1))
  done < <(_backlog_rows "$sf")
  echo "$n"
}
# derived pending_rows = backlog table rows whose STATUS leading-token is `pending` (bare or decorated),
# using the SAME line-61 discriminator as derive_investigable. This REPLACES CHECK 1's old whole-file
# `grep -icE '\bpending\b'`, which counted EVERY prose occurrence of the ordinary English word "pending"
# (iteration-history narratives, coverage notes) as a backlog gap — a false-positive that forced rewording
# HISTORY to please the linter (a state linter greps STRUCTURE, not vocabulary). UNLIKE derive_investigable
# this does NOT exclude blocked gaps: a blocked-but-pending gap is still not closed, so it belongs in the
# stale-mirror count CHECK 1 reports.
derive_pending_rows() {
  local sf="$1" gap st n=0
  while IFS=$'\t' read -r _ gap st; do              # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    [ "${st%% *}" = "pending" ] && n=$((n+1))        # bare `pending` or decorated `pending (...)`; leading-token only
  done < <(_backlog_rows "$sf")
  echo "$n"
}
# derived blocked_open = count of gap entries under ## Blocked gaps OR ## Non-investigable gaps
# that carry a `needs:` token.  Three structural forms appear in the fleet:
#
#   Bullet form (sdd-investigacion, sullair, fluke-177x-datos):
#     - <name> — needs: <resource>
#   Prose-paragraph form (blender-llm): multi-line paragraph, `needs:` bolded:
#     G54 — description. **needs:** <resource>
#   Multi-line bullet form (niagara-research database focus only, ## Child gaps surfaced at close):
#     - <name> — `blocked-on-<reason>`.\n  `tried:` ...\n  `needs:` <resource>
#     (the `needs:` token appears on a continuation/indent line, NOT on the bullet line itself)
#
# The bullet branch is anchored to '^[[:space:]]*-[[:space:]]' so a bare '- none' placeholder never
# inflates the count.  The prose branch matches **needs:** (bold markdown), which excludes
# historical/parenthetical backtick mentions such as "G6's original `needs:` was tshark".
# Both branches may match the same line without double-counting (grep -c counts matching lines).
# The third form is handled by a separate awk pass scoped to ## Child gaps surfaced at close ONLY;
# it tracks bullet-entry state across lines so continuation-line `needs:` is attributed to its gap.
# Scoping this awk to that heading keeps the existing grep's false-positive guard intact for the
# standard sections (e.g. warp.md's '- none (... then record `needs:` ...)' advisory placeholder).
derive_blocked() {
  local _d1 _d2
  _d1="$({ _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; _section "$1" '## Blocked /'; } | grep -icE '^[[:space:]]*-[[:space:]].*needs:|\*\*needs:\*\*')"  # RSDD-PROSE-BLOCKED-ANCHOR
  # RSDD-CHILD-GAPS-ANCHOR: multi-line bullet form in ## Child gaps surfaced at close
  _d2="$(_section "$1" '## Child gaps surfaced at close' | awk '
    BEGIN { n=0; ib=0; done=0 }
    /^[[:space:]]*$/ { ib=0; done=0; next }
    /^[[:space:]]*-[[:space:]]/ { ib=1; done=0
      if (tolower($0) ~ /needs:/) { n++; done=1 }
      next }
    { if (ib && !done && tolower($0) ~ /needs:/) { n++; done=1 } }
    END { print n+0 }')"
  echo $(( ${_d1:-0} + ${_d2:-0} ))
}
# P23: count blocked/absent gap entries that carry `needs:` but NOT `tried:` (a tried: clause is
# mandatory before a gap can be closed as absent-input; its absence means the operator parked the
# gap without documenting what they attempted, collapsing absent-input and untried into one signal).
# Counting unit: one gap entry = one bullet line (bullet form) OR one blank-line-delimited prose
# paragraph containing **needs:** (prose form).  For prose, tried: may be on a different line
# within the same paragraph, so we accumulate paragraph state across lines using awk.
derive_missing_tried() {
  { _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; _section "$1" '## Blocked /'; } \
  | awk '
    BEGIN { need=0; tried=0; miss=0 }
    /^[[:space:]]*$/ {
      if (need && !tried) miss++
      need=0; tried=0; next
    }
    /^[[:space:]]*-[[:space:]]/ {
      if (tolower($0) ~ /needs:/ && tolower($0) !~ /tried:/) miss++
      need=0; tried=0; next
    }
    {
      if ($0 ~ /\*\*needs:\*\*/) need=1
      if ($0 ~ /\*\*tried:\*\*/) tried=1
    }
    END {
      if (need && !tried) miss++
      print miss+0
    }
  '
}
# B3b: derived deferred_open = count of OPEN backlog rows whose priority column is exactly "deferred"
# (explicitly-parked gaps — operator decision, not blocked by hardware/keys). Closed rows (~~, ✅) excluded.
# Mirrors count_deferred() in research-sdd-status.sh (same lockstep as the other derivations above).
derive_deferred() {
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
    END { print n+0 }' "$1"
}
# derived requires_execution_open = OPEN requires-execution (§19 build/PoC) backlog rows: the STATUS column
# (already tolower'd by _backlog_rows) is ANCHORED to the LEADING token `requires-execution` (mirrors
# derive_investigable's `pending` leading-token discipline) — a free-text mention that merely NAMES the
# phrase (`pending (requires-execution)`) is NOT counted (was a CHECK E false-POSITIVE). CLOSED is decided
# only by UNAMBIGUOUS markers: a struck-through gap (~~), or a status carrying ~~/✅. The bare words
# covered/closed/done/cubierto were REMOVED from the closed-test: they appear NEGATED in genuinely OPEN
# asides (`not yet covered`, `not yet done`), and a bare substring match there false-excluded an open row
# (was a CHECK E false-NEGATIVE — the exact premature-build-STOP hazard this check exists to catch).
# UNLIKE investigable_open this derivation is only a LOWER BOUND: real corpora (logosoft) legitimately
# track build gaps in prose with NO backlog marker, so CHECK E below gates only the premature build-STOP
# direction (declared 0 while marked-open rows remain) and never demands strict equality against this count.
derive_requires_execution() {
  local sf="$1" gap st lead n=0
  while IFS=$'\t' read -r _ gap st; do              # field 1 (priority) unused here → discard into _
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
  done < <(_backlog_rows "$sf")
  echo "$n"
}

# block_scope validation helper (called inside the per-state loop).
# Returns 0 when the field is absent (legal — defaults to per-focus) or holds a legal value.
# Returns 1 and emits a FAIL when present but holding an illegal value (including empty).
_validate_block_scope() {
  local bs_present="$1" bs="$2"
  [ -z "$bs_present" ] && return 0
  case "$bs" in
    per-focus|shared-global) return 0 ;;
    *)
      if [ -z "$bs" ]; then
        # bs_present non-empty but env_field returned empty: the line exists but is unparseable by the
        # whitespace-field-split awk — most likely a missing space after the colon.  Mirrors the
        # undocumented_findings precedent documented at :246-248.
        echo "   FAIL   envelope block_scope is present but unparseable — check for a missing space after the colon (e.g. 'block_scope:shared-global' must be 'block_scope: shared-global') — must be 'per-focus' or 'shared-global'"
      else
        echo "   FAIL   envelope block_scope=${bs} is not a legal value — must be 'per-focus' or 'shared-global'"
      fi
      return 1 ;;
  esac
}

# Under shared-global, derive count of blocks ATTRIBUTED to this focus.
# Source 1 (preferred): distinct B<n> ids in the '## Covered blocks' section body.
# Source 2 (fallback): distinct B<n> ids in the '## Iteration history' Block column.
# Returns 0 when neither yields any id (unverifiable — §7 three-state rule).
_derive_attributed_sg() {
  local sf="$1" ids n
  ids="$(_section "$sf" '## Covered blocks' | grep -oE '\bB[0-9]+\b' | sort -u)"
  if [ -z "$ids" ]; then
    ids="$(_section "$sf" '## Iteration history' | awk '
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

# P8 helpers: derive the settings.json-declared hook COMMAND SET (kit issue #991). A target's real
# hooks are whatever .claude/settings.json (and its untracked settings.local.json override) actually
# run — niagara-research runs them from tools/hooks/, entirely outside .claude/hooks/, and a hook may
# be .py (or any other type), not only .sh. Scanning only .claude/hooks/*.sh made both invisible.
# These helpers turn a raw settings.json `command` string into a resolved file path WITHOUT ever
# executing it — command strings are read-only corpus data (§8); no eval, no variable expansion.
# Scope: only the project-level $target/.claude/{settings.json,settings.local.json} are read; the
# user-level ~/.claude/settings.json is a machine-wide file, not part of the target corpus, and is
# deliberately out of scope.

# _p8_looks_like_path <token>: true if <token> is a candidate script path (contains "/", or ends in
# a recognized script extension) rather than a bare interpreter name or a flag.
_p8_looks_like_path() {
  case "$1" in
    */*|*.sh|*.py|*.rb|*.js|*.pl|*.ps1) return 0 ;;  # P8-LOOKS-LIKE-PATH-CASE
    *) return 1 ;;
  esac
}

# _p8_first_path_token <command>: safely tokenizes <command> (xargs quote-parsing — no eval, no
# variable expansion) and prints the FIRST token that looks like a script path, skipping a leading
# interpreter/env wrapper (`python3 tools/hooks/x.py --flag`, `env bash tools/hooks/x.sh`) and any
# flag token. Prints nothing (exit 1) when no such token exists — the caller reports the raw command
# as unresolved (§7: loud, never silently skipped). Callers MUST guard the assignment with `|| true`
# (`tok="$(_p8_first_path_token "$cmd" || true)"`) — a command substitution feeding a plain assignment
# is NOT exempt from `errexit` the way an `if`/`while` condition is, so a bare-word command like
# `echo hi` (no path token at all; this function's ordinary, expected `return 1`) would abort the
# whole run under `set -e` instead of reaching the loud "could not be resolved" branch below. This
# script does not itself set `-e`, but the guard costs nothing and removes that latent fragility.
_p8_first_path_token() {
  local tok
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      -*) continue ;;
      bash|sh|dash|zsh|ksh|env|python|python2|python3|node|nodejs|ruby|perl|pwsh) continue ;;
    esac
    if _p8_looks_like_path "$tok"; then printf '%s\n' "$tok"; return 0; fi
  done < <(printf '%s' "$1" | xargs -n1 printf '%s\n' 2>/dev/null)
  return 1
}

# _p8_resolve_hook_path <token> <hroot>: resolves a script token to an absolute path — the three
# forms #991 names: a $CLAUDE_PROJECT_DIR / ${CLAUDE_PROJECT_DIR} prefix (→ <hroot>), an already-
# absolute path (used as-is), or a bare path resolved relative to <hroot>. Existence is NOT checked
# here — the caller does, so a dangling path is reported unresolved rather than silently dropped.
# The caller also runs this through _p8_root_check (§8/privacy: an absolute command like
# `cat /etc/hostname`, or a relative one that escapes via ".." or a symlink, resolves to a real,
# readable, existing file that is nonetheless not part of this target's corpus, and must never be
# opened).
_p8_resolve_hook_path() {
  local tok="$1" hroot="$2" rest
  case "$tok" in
    \$CLAUDE_PROJECT_DIR/*)
      rest="${tok#\$CLAUDE_PROJECT_DIR}"
      printf '%s%s\n' "$hroot" "$rest" ;;
    \$\{CLAUDE_PROJECT_DIR\}/*)
      rest="${tok#\$\{CLAUDE_PROJECT_DIR\}}"
      printf '%s%s\n' "$hroot" "$rest" ;;
    /*) printf '%s\n' "$tok" ;;
    *) printf '%s/%s\n' "$hroot" "$tok" ;;
  esac
}

# _p8_root_check <path> <hroot_real> <has_realpath>: the single gate every candidate hook path
# passes through — settings-derived AND .claude/hooks/* listing entries alike — before it is ever
# added to the inspected set or opened. <hroot_real> is already canonical (see the `cd + pwd -P`
# derivation below), so this needs no separate raw-<hroot> parameter. On success sets
# $_p8_rc_result to the safe path to use and returns 0. On failure sets $_p8_rc_reason
# ("out-of-root" or "degraded") and $_p8_rc_detail (the path to name in the caller's WARN) and
# returns 1; the caller never reads the file.
#   - has_realpath=1: canonicalize with `realpath` (resolves both ".." and every symlink in the
#     chain) and require the result to sit under <hroot_real>. This is the precise check.
#   - has_realpath=0 (degraded — a purely textual prefix match is not enough: `../` lexically
#     cancels back under <hroot_real> without ever leaving it on paper, and a symlink leaf or a
#     symlinked DIRECTORY COMPONENT partway down both point the read somewhere the text never
#     mentions): a path that does not even textually start under <hroot_real> is unambiguous
#     ("out-of-root", no realpath needed to see that). One that does is walked component by
#     component from <hroot_real> down with `-L`, and rejected ("degraded") if any component still
#     is a symlink or the remainder still contains a ".." segment. This function first
#     canonicalizes the candidate's DIRECTORY with the `cd -P`/`pwd -P` builtins where it exists,
#     so in practice what remains to refuse is a symlinked LEAF or a ".." in a path whose directory
#     does not exist — conservative by design: without realpath this never tries to prove where a
#     symlinked leaf points. The split uses
#     `read -ra` on a quoted here-string, NOT an unquoted `for x in $rel` — the latter runs each
#     split component back through pathname expansion, so a component that happens to be
#     glob-shaped (e.g. a directory literally named `[l]`) would expand against the process's OWN
#     cwd instead of staying the literal string, making `-L` test an unrelated, attacker-chosen path.
#     `read` also reads only ONE LINE — a path containing an embedded newline would silently
#     truncate the split there, component-walking only the prefix and reporting the WHOLE
#     (unchecked) remainder as safe, so any path containing a newline is refused outright before
#     any splitting happens, rather than trusted on a partial check. Before comparing textually,
#     an ABSOLUTE degraded-mode candidate's DIRECTORY is canonicalized too (when it exists) with
#     the same builtin `cd -P` + `pwd -P` combo the root itself uses — otherwise a candidate
#     reached through a symlinked ancestor (e.g. a settings-declared absolute command under
#     `/var` where `/var -> /private/var`) never textually matches a canonical <hroot_real>.
_p8_root_check() {
  local path="$1" hroot_real="$2" has_rp="$3" real rel comp walked parts path_dir path_base canon_dir
  _p8_rc_result=""; _p8_rc_reason=""; _p8_rc_detail=""
  case "$path" in
    *$'\n'*) _p8_rc_reason="degraded"; _p8_rc_detail="$path"; return 1 ;;
  esac
  if [ "$has_rp" -eq 1 ]; then
    real="$(realpath -- "$path" 2>/dev/null || printf '%s' "$path")"
    case "$real" in
      "$hroot_real"/*) _p8_rc_result="$real"; return 0 ;;  # P8-ROOT-CHECK-INROOT-CASE
      *) _p8_rc_reason="out-of-root"; _p8_rc_detail="$real"; return 1 ;;
    esac
  fi
  case "$path" in
    /*)
      path_dir="$(dirname "$path")"
      if [ -d "$path_dir" ]; then
        # shellcheck disable=SC1007  # CDPATH= (empty) is a deliberate prefix assignment, not a typo.
        canon_dir="$(CDPATH= cd -P -- "$path_dir" 2>/dev/null && pwd -P)"
        case "$canon_dir" in
          ''|*$'\n'*) ;;  # canonicalization failed/corrupted — keep path as-is
          *) path_base="$(basename "$path")"; path="$canon_dir/$path_base" ;;
        esac
      fi
      ;;
  esac
  case "$path" in
    "$hroot_real"/*) ;;
    *) _p8_rc_reason="out-of-root"; _p8_rc_detail="$path"; return 1 ;;
  esac
  rel="${path#"$hroot_real"/}"
  case "/$rel/" in
    *'/../'*) _p8_rc_reason="degraded"; _p8_rc_detail="$path"; return 1 ;;
  esac
  walked="$hroot_real"
  IFS='/' read -ra parts <<< "$rel"  # P8-DEGRADED-WALK-SPLIT: no-glob split (read never expands)
  for comp in "${parts[@]}"; do
    [ -z "$comp" ] && continue
    walked="$walked/$comp"
    if [ -L "$walked" ]; then _p8_rc_reason="degraded"; _p8_rc_detail="$path"; return 1; fi
  done
  _p8_rc_result="$path"
  return 0
}

# P8: hook scripts still containing unreplaced template placeholders. The INSPECTED SET is the UNION
# of (a) settings.json's hook commands, (b) settings.local.json's hook commands, and (c) every file
# or symlink directly under .claude/hooks/ (not only *.sh) — deduplicated, so the same physical
# script named from more than one place is inspected once. Each source is read independently: a
# settings.json hook never hides settings.local.json or .claude/hooks/, and vice versa.
# §7 anti-silent-zero, FOUR distinct final states: absent-input (nothing exists) / empty-input (a
# source exists and is genuinely empty) / no-match (files exist, all clean — silent) /
# found-but-none-inspectable (something was found but every candidate was refused — never
# conflated with empty-input). jq absence is a typed 'degraded' state; invalid JSON is a typed
# 'malformed' state, distinct from 'unreadable' (a permission failure); every settings-declared
# command that fails to resolve to a file is reported loudly, never skipped; a path OUTSIDE the
# target root — via an absolute command, a ".." segment, or a symlink (leaf or a directory
# component partway down) — is reported 'out-of-root' (or, without `realpath` available to prove
# it, conservatively 'degraded') and never opened (§8 read-only corpora — this instrument reads
# only the target). See _p8_root_check below for the containment check itself.
# Runs ONCE per target (before per-state loop) — not once per RESEARCH-STATE file.
# F1: exact allowlist of forms found in research-sdd/templates/ hook files (not a generic UPPER regex).
# F2: when called with a nested corpus dir ($target/corpus), .claude/ lives at the target root; walk
#     up one level bounded to the dir holding .claude/ and report which dir was inspected.
# F4: skip lines that are pure #-comments; print line numbers in WARN output.
_p8_hroot="$target"
if [ ! -d "$_p8_hroot/.claude" ] && [ -d "$(dirname "$_p8_hroot")/.claude" ]; then
  _p8_hroot="$(dirname "$_p8_hroot")"
fi
# Canonicalize the root itself with the `cd + pwd -P` builtin combo — no external `realpath`
# needed, so this works identically whether or not that binary is on PATH. Without it, a target
# given as "." (or reached through a symlink at any point in its path) left $_p8_hroot uncanonical
# while an ABSOLUTE settings-derived command naturally resolves to the canonical form, so the two
# never textually matched: a real, in-root file was reported out-of-root. `CDPATH=` neutralizes an
# exported CDPATH — otherwise `cd` can resolve the WRONG directory (a same-named one on CDPATH) and
# additionally auto-print the path it found, corrupting the captured value into two lines. `cd` CAN
# still fail for other environmental reasons (removed between the top-of-script check and here, a
# permission change, etc.) — verified below, never assumed.
# shellcheck disable=SC1007  # CDPATH= (empty) is a deliberate prefix assignment, not a typo.
_p8_canon="$(CDPATH= cd -- "$_p8_hroot" 2>/dev/null && pwd -P)"
_p8_root_ok=1
case "$_p8_canon" in
  ''|*$'\n'*) _p8_root_ok=0 ;;
esac
if [ "$_p8_root_ok" -eq 1 ]; then
  _p8_hroot="$_p8_canon"
else
  echo "   degraded   hook-set: cannot canonicalize target root ($_p8_hroot) — every candidate hook is refused, never read"
fi
unset _p8_canon
_p8_hdir="$_p8_hroot/.claude/hooks"

_p8_realpath_ok=1
command -v realpath >/dev/null 2>&1 || _p8_realpath_ok=0
if [ "$_p8_realpath_ok" -eq 0 ]; then
  echo "   degraded   hook-set: realpath not found on PATH — directory components are canonicalized with the cd -P/pwd -P builtins; a symlinked leaf, or a '..' still present after that, is refused rather than trusted (§8)"
fi

_p8_combined=""       # newline list of safe, in-root, existing file paths (pre-dedup)
_p8_src_report=""     # newline list of "<label>: N file(s)" — one per source that contributed >=1
_p8_any_seen=0        # did ANY of settings.json / settings.local.json / .claude/hooks/ exist at all
_p8_any_rejected=0    # did any FOUND candidate get refused (unresolved/out-of-root/degraded/unreadable/malformed/dangling-or-non-file-symlink)?

# (a) + (b): settings.json and settings.local.json — identical extraction/resolution, looped so the
# second source is never silently skipped just because the first one already had hooks.
for _p8_pair in "$_p8_hroot/.claude/settings.json:settings.json" \
                "$_p8_hroot/.claude/settings.local.json:settings.local.json"; do
  _p8_spath="${_p8_pair%:*}"
  _p8_slabel="${_p8_pair##*:}"
  [ -f "$_p8_spath" ] || continue
  _p8_any_seen=1
  if [ ! -r "$_p8_spath" ]; then
    echo "   unreadable   hook-set: $_p8_slabel at $_p8_hroot is not readable — cannot derive its hook commands"
    _p8_any_rejected=1
    continue
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "   degraded   hook-set: jq not found on PATH — cannot parse $_p8_slabel hook commands (hooks declared outside .claude/hooks/, e.g. tools/hooks/, are invisible in this mode)"
    _p8_any_rejected=1
    continue
  fi
  if ! _p8_cmds="$(jq -r '(.hooks // {}) | [.. | objects | .command? // empty] | .[]' "$_p8_spath" 2>/dev/null)"; then  # P8-SETTINGS-JQ-EXTRACT
    echo "   malformed   hook-set: $_p8_slabel at $_p8_hroot is not valid JSON — cannot derive its hook commands"
    _p8_any_rejected=1
    continue
  fi
  [ -z "$_p8_cmds" ] && continue
  _p8_src_n=0
  while IFS= read -r _p8_cmd; do
    [ -z "$_p8_cmd" ] && continue
    _p8_tok="$(_p8_first_path_token "$_p8_cmd" || true)"
    _p8_resolved_path=""
    [ -n "$_p8_tok" ] && _p8_resolved_path="$(_p8_resolve_hook_path "$_p8_tok" "$_p8_hroot")"
    if [ -z "$_p8_resolved_path" ] || [ ! -f "$_p8_resolved_path" ]; then
      echo "   WARN   hook-set: $_p8_slabel hook command could not be resolved to a script file (inspected: $_p8_hroot): $_p8_cmd"
      _p8_any_rejected=1
      continue
    fi
    if [ "$_p8_root_ok" -eq 0 ]; then
      echo "   WARN   hook-set: $_p8_slabel hook command refused — target root could not be canonicalized (inspected: $_p8_hroot): $_p8_resolved_path"
      _p8_any_rejected=1
    elif _p8_root_check "$_p8_resolved_path" "$_p8_hroot" "$_p8_realpath_ok"; then
      _p8_combined="${_p8_combined}${_p8_rc_result}"$'\n'
      _p8_src_n=$((_p8_src_n + 1))
    else
      _p8_any_rejected=1
      if [ "$_p8_rc_reason" = "out-of-root" ]; then
        echo "   WARN   hook-set: $_p8_slabel hook command resolves outside the target root (inspected: $_p8_hroot) — refusing to read it (out-of-root): $_p8_rc_detail"
      else
        echo "   WARN   hook-set: $_p8_slabel hook command's path could not be safely verified without realpath (contains '..' or crosses a symlink) — refusing to read it (degraded): $_p8_rc_detail"
      fi
    fi
  done <<< "$_p8_cmds"
  [ "$_p8_src_n" -gt 0 ] && _p8_src_report="${_p8_src_report}${_p8_slabel}: ${_p8_src_n} file(s)"$'\n'
done

# (c): every file OR symlink directly under .claude/hooks/ (ALL types, not only *.sh — a hook can be
# any script type, and a hook can be a symlink, e.g. into a shared tools/ dir). Each entry passes
# through the SAME _p8_root_check as a settings-derived command before being trusted — a symlink can
# escape the target root exactly as an absolute command path can. `[ -f ]` after the check drops a
# genuine subdirectory silently (never a candidate hook in the first place), but a SYMLINK that is
# in-root (or unverifiable-safe) yet not ultimately a regular file — dangling, or pointing at a
# directory — is reported loudly below, never dropped: it is still a hook entry, just a broken one.
if [ -d "$_p8_hdir" ]; then
  _p8_any_seen=1
  if [ ! -r "$_p8_hdir" ]; then
    echo "   unreadable   hook-placeholder: .claude/hooks/ at $_p8_hroot is not readable — cannot inspect"
    _p8_any_rejected=1
  else
    _p8_hooks_n=0
    while IFS= read -r _p8_hf; do
      [ -z "$_p8_hf" ] && continue
      if [ "$_p8_root_ok" -eq 0 ]; then
        echo "   WARN   hook-set: .claude/hooks/ entry refused — target root could not be canonicalized (inspected: $_p8_hroot): $_p8_hf"
        _p8_any_rejected=1
      elif _p8_root_check "$_p8_hf" "$_p8_hroot" "$_p8_realpath_ok"; then
        if [ -f "$_p8_rc_result" ]; then
          _p8_combined="${_p8_combined}${_p8_rc_result}"$'\n'
          _p8_hooks_n=$((_p8_hooks_n + 1))
        elif [ -L "$_p8_hf" ]; then
          # In-root (or unverifiable-safe) per _p8_root_check, but not ultimately a regular file:
          # a dangling symlink, or one pointing at a directory. Silently dropping this — as a
          # subdirectory always was — hid a hook the old *.sh glob used to WARN on; report it.
          echo "   WARN   hook-set: .claude/hooks/ entry is a dangling or non-file symlink: $_p8_hf"
          _p8_any_rejected=1
        fi
      else
        _p8_any_rejected=1
        if [ "$_p8_rc_reason" = "out-of-root" ]; then
          echo "   WARN   hook-set: .claude/hooks/ entry resolves outside the target root (inspected: $_p8_hroot) — refusing to read it (out-of-root): $_p8_rc_detail"
        else
          echo "   WARN   hook-set: .claude/hooks/ entry's path could not be safely verified without realpath (contains '..' or crosses a symlink) — refusing to read it (degraded): $_p8_rc_detail"
        fi
      fi
    done < <(find "$_p8_hdir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)
    [ "$_p8_hooks_n" -gt 0 ] && _p8_src_report="${_p8_src_report}.claude/hooks/*: ${_p8_hooks_n} file(s)"$'\n'
  fi
fi

# Dedup (the same physical script named from settings.json, settings.local.json, and/or sitting in
# .claude/hooks/ is inspected once) and report the union — which sources were read and how many
# files came from each, per the summary line below.
mapfile -t _p8_files < <(printf '%s\n' "$_p8_combined" | grep -v '^$' | sort -u)  # P8-UNION-DEDUP
_p8_pre_dedup_n=$(printf '%s\n' "$_p8_combined" | grep -vc '^$' || true)
_p8_dupes=$(( _p8_pre_dedup_n - ${#_p8_files[@]} ))

# §7 three-state (extended): absent-input (nothing existed) / empty-input (a source existed and was
# genuinely empty) / found-but-none-inspectable (something was FOUND — a command, an entry — but
# every one of them was refused above: unresolved, out-of-root, degraded, unreadable, malformed, or
# a dangling/non-file symlink) are three DIFFERENT zeros. Conflating the last two under one "empty"
# message was itself a silent-zero bug: a target whose only hook was refused as out-of-root read as
# indistinguishable from a target with no hooks declared at all, even though the WARN lines above
# already proved otherwise for a careful reader — the summary line must not contradict them.
if [ "${#_p8_files[@]}" -gt 0 ]; then
  _p8_src_summary="$(printf '%s' "$_p8_src_report" | grep -v '^$' | tr '\n' ';' | sed 's/;/; /g; s/; $//')"
  echo "   INFO   hook-set: inspected ${#_p8_files[@]} hook file(s) — ${_p8_src_summary} (${_p8_dupes} duplicate(s) removed; root: $_p8_hroot)"
elif [ "$_p8_any_seen" -eq 0 ]; then
  echo "   INFO   hook-placeholder: .claude/hooks/ not found and no settings.json/settings.local.json present (inspected: $_p8_hroot) — no installed hooks to inspect"
elif [ "$_p8_any_rejected" -eq 1 ]; then
  echo "   INFO   hook-placeholder: found-but-none-inspectable — every candidate hook was unresolved, out-of-root, degraded, unreadable, malformed, or a dangling/non-file symlink (see the report above); none could be inspected (inspected: $_p8_hroot)"
else
  echo "   INFO   hook-placeholder: no hooks found (empty) across .claude/settings.json, settings.local.json, and .claude/hooks/ (inspected: $_p8_hroot) — no installed hooks to inspect"
fi

for _p8f in "${_p8_files[@]}"; do
  [ -z "$_p8f" ] && continue
  if [ ! -r "$_p8f" ]; then
    echo "   unreadable   hook-placeholder: $(basename "$_p8f") is not readable — cannot inspect for placeholders"
  else
    # F4: skip #-comment lines; F1: exact placeholder allowlist from templates/
    _p8_lines="$(grep -nE '<SUBJECT>|<KIT>|<TARGET>|<prefix>|<path to binaries/decompiled output/source code of the system under study>' "$_p8f" | grep -vE '^[0-9]+:[[:space:]]*#')"  # P8-HOOK-PLACEHOLDER-GREP
    if [ -n "$_p8_lines" ]; then
      _p8_phs="$(printf '%s\n' "$_p8_lines" | grep -oE '<SUBJECT>|<KIT>|<TARGET>|<prefix>|<path to binaries/decompiled output/source code of the system under study>' | sort -u | tr '\n' ' ' | sed 's/ $//')"
      _p8_lns="$(printf '%s\n' "$_p8_lines" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
      echo "   WARN   hook-placeholder: $(basename "$_p8f") line(s) $_p8_lns still has unreplaced placeholder(s): $_p8_phs — adapt this hook for the target before use (inspected: $_p8_hroot)"
    fi
  fi
done
# no-match: hooks exist and all clean — silent, covered by per-state ok line
unset _p8f _p8_phs _p8_lns _p8_lines _p8_cmd _p8_cmds _p8_tok _p8_resolved_path _p8_pair _p8_spath
unset _p8_slabel _p8_src_n _p8_hf _p8_hooks_n _p8_src_report _p8_src_summary _p8_pre_dedup_n
unset _p8_dupes _p8_any_seen _p8_any_rejected _p8_hdir _p8_hroot _p8_combined _p8_files _p8_root_ok
unset _p8_realpath_ok _p8_rc_result _p8_rc_reason _p8_rc_detail

rc=0
for state in "${states[@]}"; do
  echo "== verify-state: $(basename "$state") (target: $target) =="
  frc=0

  # ENVELOPE GATE (STALE-gate, NOT a soft fallback) — an un-migrated state with NO research-state.v1
  # envelope is a hard FAIL: its counts are not machine-validated, so the loop must not trust the prose.
  # This makes research-sdd-status.sh --next return STALE (its verify-state gate), blocking the loop until
  # the envelope is seeded. Distinct, actionable message so the fix is obvious.
  if ! has_env "$state"; then
    echo "   FAIL   no research-state.v1 envelope — run: research-sdd-status.sh $target --sync-state to seed it"
    echo "          Unmigrated state: the counts are not machine-validated, so --next returns STALE until seeded."
    rc=1
    continue
  fi

  # BACKLOG PARSE CHECK (FAIL) — unknown priority values make the backlog NOT FULLY PARSEABLE.
  # CLAUDE.md §7 three-state rule: unparseable != absent != empty. An unparseable backlog must not be
  # laundered into investigable_open=0 by --sync-state (which would disarm this very gate).
  # _bparse_out captures BOTH valid rows ("priority<TAB>gap<TAB>status") AND INVALID_PRIORITY sentinels.
  # derive_investigable() etc. safely ignore 2-field sentinel lines (field 3 absent → "pending" never matches).
  #
  # BR-CACHE-PRIME-CALL: call _backlog_rows DIRECTLY in the main shell (not inside $(...)) so that
  # _BR_CACHED_FILE and _BR_CACHED_ROWS are set here and inherited by all subshells spawned by the
  # derive-function calls below. Without this prime call, each $(_backlog_rows) or < <(_backlog_rows)
  # invocation runs in its own subshell where the cache assignment never propagates back, causing awk
  # (and its structural WARNs) to re-run 4× per state. stdout is discarded; WARNs go to stderr once.
  _backlog_rows "$state" > /dev/null  # BR-CACHE-PRIME-CALL
  _bparse_out="$_BR_CACHED_ROWS"
  _bparse_invalid="$(printf '%s\n' "$_bparse_out" | grep '^INVALID_PRIORITY')"
  if [ -n "$_bparse_invalid" ]; then  # BP-INVALID-PRIORITY-FAIL
    echo "   FAIL   backlog NOT FULLY PARSEABLE — unknown priority value(s) found:"
    printf '%s\n' "$_bparse_invalid" | while IFS=$'\t' read -r _ val; do
      echo "          unknown priority value [$val] — valid: high, medium, low, deferred"
    done
    echo "          Fix the priority value(s) in the backlog, then re-seed: --sync-state"
    frc=1; rc=1; continue
  fi

  # GB-PRESENT-CHECK (FAIL) — a backlog section heading must be PRESENT. Absent ≠ empty (§7 anti-silent-zero).
  # A corpus without any backlog heading is structurally incomplete: derive_investigable returns 0 silently,
  # which launders a missing section into investigable_open=0 (false ok).
  # The check accepts any `## ` heading that contains "backlog" (case-insensitive): canonical
  # `## Gap-backlog`, legacy `## Backlog`, and near-miss forms like `## Gap backlog` (which the NM-WARN
  # already flags). A near-miss heading IS present — its mis-spelling is a different class of problem from
  # total absence. The check fires only when there is truly NO heading containing "backlog" at all.
  if ! grep -qiE '^##[[:space:]].*backlog' "$state" 2>/dev/null; then  # GB-PRESENT-CHECK
    echo "   FAIL   ## Gap-backlog section absent — section must be present (even if empty). Add it and re-seed: --sync-state"
    frc=1; rc=1; continue
  fi

  # 1. backlog `pending` gap ROWS — leading-token status, NOT a whole-file word count (retro delta): the old
  #    `grep -icE '\bpending\b'` counted every prose mention of "pending" (iteration-history narratives,
  #    coverage notes) as a gap, false-firing CHECK 1 and forcing edits to HISTORY. Anchor to backlog rows.
  pending="$(derive_pending_rows "$state")"

  # 2. coverage metric "X / Y ... closed"
  # CM-ANCHOR-GREP: anchor to the *canonical* 'Coverage metric:' line (with optional bold ** marks)
  # instead of the old broad pattern ('gaps? closed', 'declared gaps closed') that also matched
  # iteration-history TABLE HEADERS like '| Gap closed |' — the first such header shadowed the
  # real metric line via head-1, reporting <none> for the oem-honeywell-tail corpus (line 84 vs 104).
  # Mirrors the derive_pending_rows precedent at §263: anchor to STRUCTURE (the 'Coverage metric:'
  # key), not to a vocabulary word that appears in both the key and unrelated table headers.
  metric="$(grep -iE '\*{0,2}coverage metric\*{0,2}:' "$state" 2>/dev/null | head -1)"  # CM-ANCHOR-GREP
  xy="$(printf '%s' "$metric" | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
  cx="${xy%%/*}"; cy="${xy##*/}"

  # 3. covered-blocks claim vs on-disk block files. Use the SAME STRICT discriminator as gen-catalog.py
  #    (BLOCK_RE) and research-sdd-archive.sh: `<prefix>-(block|bloque)<N>[-suffix].md`. A loose `*block*`
  #    glob wrongly counts decoys like `blocked-notes.md`; keeping ONE definition of "a block file" across
  #    verify-state / --sync-state / archive / catalog kills the dual-authority drift on this count.
  #    B3 FIX: in a multi-focus corpus every RESEARCH-STATE-*.md lives in the same corpus dir, so a
  #    focus-blind find counts ALL focuses' blocks. Derive the focus prefix from the state filename (or
  #    FOCUSES.md for the legacy RESEARCH-STATE.md case) and filter to only that focus's blocks.
  covered_claim="$(grep -iE 'covered blocks' "$state" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  _fpfx="$(derive_focus_prefix "$state")"
  # block_scope: optional envelope field — 'per-focus' (default when absent) or 'shared-global'.
  # Present but neither legal value (including empty) is a hard FAIL: the gate must know which mode applies.
  # This is the §7 three-state rule: absent ≠ empty ≠ illegal value.
  e_bs="$(env_field "$state" block_scope)"
  _bs_present="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*block_scope:/{print; exit}' "$state")"  # BS-INDENTED-PROBE
  _bs_valid=1  # set to 0 when present but holds an illegal value (including empty)
  if ! _validate_block_scope "$_bs_present" "$e_bs"; then  # BS-BLOCK_SCOPE-VALIDATE
    frc=1; rc=1; _bs_valid=0
  fi
  # Always compute the focus-blind global block count — needed for:
  #   (a) block_scope: shared-global (corpus-total INFO and cannot-see diagnostic), and
  #   (b) the cannot-see diagnostic when per-focus ondisk==0 while other-prefix blocks exist.
  _ondisk_global="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter | wc -l | tr -d ' ')"
  : # BS-ONDISK-GLOBAL-COMPUTED — override this line with _ondisk_global="0" to test cannot-see-pass teeth
  _sg_attributed=""   # SG-ATTR-INIT: empty when per-focus; populated when shared-global
  _sg_check_a_done=0  # SG-CHECK-A-SKIP: 1 = shared-global handled covered_blocks CHECK A above
  if [ "$_bs_valid" = 1 ] && [ -n "$_bs_present" ] && [ "$e_bs" = "shared-global" ]; then
    _sg_attributed="$(_derive_attributed_sg "$state")"  # SG-DERIVE-ATTRIBUTED
    ondisk="$_ondisk_global"   # corpus total; used in summary only — CHECK A uses attributed count
    _sg_check_a_done=1  # SG-CHECK2-GUARD
  elif [ -n "$_fpfx" ]; then
    ondisk="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
      | block_file_filter "${_fpfx}" | wc -l | tr -d ' ')"
  else
    ondisk="$_ondisk_global"
  fi

  # --- envelope contract: recompute ground truth, compare to declared ints ---------------------
  d_inv="$(derive_investigable "$state")"
  d_blocked="$(derive_blocked "$state")"
  d_req="$(derive_requires_execution "$state")"
  d_def="$(derive_deferred "$state")"
  e_covered="$(env_field "$state" covered_blocks)"
  e_inv="$(env_field "$state" investigable_open)"
  e_blocked="$(env_field "$state" blocked_open)"
  e_req="$(env_field "$state" requires_execution_open)"
  e_def="$(env_field "$state" deferred_open)"
  e_gc="$(env_field "$state" gaps_closed)"
  e_kg="$(env_field "$state" known_gaps)"
  # undocumented_findings — computed here (before the summary line) so SUGGESTION 8 can show it.
  # _uf_present: whether the undocumented_findings LINE exists in the envelope at all.  env_field's awk
  # requires `key: value` (space after colon); a no-space typo like `undocumented_findings:7` returns
  # empty — identical to the absent case — so we use a separate presence check anchored to the key prefix.
  # This distinguishes: absent (silent), present+valid (threshold checks), present+malformed (FAIL).
  e_uf="$(env_field "$state" undocumented_findings)"
  _uf_present="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*undocumented_findings:/{print; exit}' "$state")"  # UF-INDENTED-PROBE
  # blocks_since_retro — same pattern as undocumented_findings: optional manually-maintained counter.
  # _bsr_present: whether the blocks_since_retro LINE exists in the envelope at all (probe for CHECK P18).
  e_bsr="$(env_field "$state" blocks_since_retro)"
  _bsr_present="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*blocks_since_retro:/{print; exit}' "$state")"  # P18-BSR-PROBE
  # KSW-EXTRACT: known_stale_warns — comma-separated suppression ids. env_field uses `$2` (splits on spaces)
  # but this value may contain spaces between items; use a full-line awk to extract reliably.
  e_ksw="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*known_stale_warns:/{v=$0; sub(/^[[:space:]]*known_stale_warns:[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit}' "$state")"  # KSW-EXTRACT
  _ksw_has() { printf '%s\n' "${e_ksw}" | tr ',' '\n' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' | grep -qxF "$1"; }

  echo "-- summary --"
  echo "   coverage metric : ${xy:-<none>}"
  echo "   covered blocks  : ${covered_claim:-<none>} claimed · ${ondisk} block file(s) on disk"
  echo "   backlog pending : ${pending}"
  echo "   envelope        : covered_blocks=${e_covered:-<none>}/${ondisk} · investigable_open=${e_inv:-<none>}/${d_inv} · requires_execution_open=${e_req:-<none>}/${d_req} · blocked_open=${e_blocked:-<none>}/${d_blocked} · deferred_open=${e_def:-<none>}/${d_def} · undocumented_findings=${e_uf:-<none>}  (declared/derived; undocumented_findings is manually-maintained)"

  # ENVELOPE CHECK A (shared-global) — attributed block count comparison (SG-CHECK-A-SKIP).
  # covered_blocks must equal blocks ATTRIBUTED to this focus (from ## Covered blocks or Iteration history);
  # corpus-wide total is informational only. When no attributed ids are listed: INFO (never FAIL).
  if [ "$_sg_check_a_done" = 1 ]; then
    echo "   INFO   corpus total ${_ondisk_global} block file(s) (shared-global, informational)"  # SG-CORPUS-INFO
    if [ "${_sg_attributed:-0}" -eq 0 ]; then  # SG-UNVERIFIABLE-COND
      echo "   INFO   covered_blocks unverifiable under shared-global: no attributed block ids listed"
    elif ! is_int "$e_covered" || [ "$e_covered" != "$_sg_attributed" ]; then  # SG-ATTR-CHECK
      echo "   FAIL   envelope covered_blocks=${e_covered:-<missing>} != ${_sg_attributed} attributed block(s) under shared-global — re-seed: --sync-state"
      frc=1; rc=1
    fi
  fi
  # ENVELOPE CHECK A (per-focus) — declared covered_blocks must equal on-disk block files (absent/per-focus).
  # Shared-global is handled above (SG-CHECK-A-SKIP). For absent/per-focus with a focus prefix, distinguish
  # the cannot-see case (focus-filtered=0 while other-prefix blocks exist) from a genuine zero or real mismatch.
  if [ "$_sg_check_a_done" = 0 ] && { ! is_int "$e_covered" || [ "$e_covered" != "$ondisk" ]; }; then  # SG-CHECK-A-SKIP
    if [ -n "$_fpfx" ] && [ "${ondisk:-0}" -eq 0 ] && [ "${_ondisk_global:-0}" -gt 0 ] && [ "$_bs_valid" = 1 ] && [ "$e_bs" != "shared-global" ]; then  # BS-CANNOT-SEE-COND
      echo "   FAIL   envelope covered_blocks=${e_covered:-<missing>}: no block file matches prefix '${_fpfx}' — ${_ondisk_global} block file(s) exist under other prefixes; if the corpus uses shared block numbering across focuses, declare block_scope: shared-global then re-seed: --sync-state"
    else
      echo "   FAIL   envelope covered_blocks=${e_covered:-<missing>} != ${ondisk} block file(s) on disk — re-seed: --sync-state"
    fi
    frc=1; rc=1
  fi
  # ENVELOPE CHECK A — PASS-PATH WARN (issue #126 item 1): covered_blocks=0 and focus-filtered ondisk=0
  # (CHECK A passes: 0==0) while _ondisk_global > 0. The instrument could not take the count it certified
  # because no block file matched the focus prefix. Advisory WARN per §8 (finding, not operational failure).
  if is_int "$e_covered" && [ "$e_covered" = "$ondisk" ] && [ -n "$_fpfx" ] && [ "${ondisk:-0}" -eq 0 ] && [ "${_ondisk_global:-0}" -gt 0 ] && [ "$_bs_valid" = 1 ] && [ "$e_bs" != "shared-global" ]; then  # BS-CANNOT-SEE-PASS
    echo "   WARN   envelope covered_blocks=0: declared 0 matches 0 focus-filtered on-disk — but ${_ondisk_global} block file(s) exist under other prefixes (focus '${_fpfx}' matches none); if the corpus uses shared block numbering across focuses, declare block_scope: shared-global then re-seed: --sync-state"
  fi
  # ENVELOPE CHECK B (FAIL, STOP-CRITICAL) — declared investigable_open must equal the NEXT-eligible set.
  # This is the check that closes the premature-STOP class BY CONSTRUCTION: an under-declared count here
  # (e.g. investigable_open: 0 while 2 pending non-blocked gaps remain) FAILs → --next returns STALE, not STOP.
  if ! is_int "$e_inv" || [ "$e_inv" != "$d_inv" ]; then
    echo "   FAIL   envelope investigable_open=${e_inv:-<missing>} != ${d_inv} NEXT-eligible pending gap(s) — re-seed: --sync-state"
    echo "          A stale investigable_open is the premature-STOP hazard; verify-state refuses to certify it."
    frc=1; rc=1
  fi
  # ENVELOPE CHECK C (FAIL) — declared blocked_open must equal the on-disk "## Blocked gaps" entry count.
  if ! is_int "$e_blocked" || [ "$e_blocked" != "$d_blocked" ]; then
    echo "   FAIL   envelope blocked_open=${e_blocked:-<missing>} != ${d_blocked} blocked entr(y/ies) — re-seed: --sync-state"
    frc=1; rc=1
  fi
  # ENVELOPE CHECK D (FAIL) — envelope-side of CHECK 1: declared FULL coverage (gaps_closed == known_gaps,
  # denominator > 0) while investigable gaps still remain. gaps_closed/known_gaps are declared-only (not
  # disk-derivable), so this is a consistency check against the DERIVED investigable count, not a mismatch.
  if is_int "$e_gc" && is_int "$e_kg" && [ "$e_kg" -gt 0 ] && [ "$e_gc" = "$e_kg" ] && [ "$d_inv" -gt 0 ]; then
    echo "   FAIL   envelope gaps_closed=$e_gc == known_gaps=$e_kg while $d_inv investigable gap(s) remain — premature-STOP hazard."
    frc=1; rc=1
  fi
  # ENVELOPE CHECK E (CALIBRATED, hazard-direction only) — requires_execution_open vs marked-open backlog
  # rows. There is NO uniform on-disk marker for open build gaps (logosoft tracked its counter in prose
  # only), so strict equality here would FALSE-FAIL prose-tracked corpora. FAIL fires ONLY on the exact
  # analog of the investigable premature-STOP gate: the envelope declares the build loop DONE (0) while the
  # backlog still carries marked-open requires-execution rows. Any other divergence with marked rows on disk
  # is a WARN (mirror hygiene); d_req==0 proves nothing (prose-tracked is legitimate) and stays silent.
  if is_int "$e_req" && [ "$e_req" -eq 0 ] && [ "$d_req" -gt 0 ]; then
    echo "   FAIL   envelope requires_execution_open=0 (build loop declared done) while $d_req open requires-execution backlog gap(s) remain — premature build-STOP hazard; re-seed --sync-state."
    frc=1; rc=1
  elif is_int "$e_req" && [ "$d_req" -gt 0 ] && [ "$e_req" != "$d_req" ]; then
    echo "   WARN   envelope requires_execution_open=$e_req != $d_req marked-open requires-execution backlog gap(s) — mirror hygiene; re-seed --sync-state."
  elif ! is_int "$e_req"; then
    echo "   WARN   envelope requires_execution_open=${e_req:-<missing>} is not an integer — seed it: --sync-state."
  fi

  # ENVELOPE CHECK F (FAIL) — declared deferred_open must equal the backlog's deferred-priority row count.
  # Deferred gaps (explicitly parked by operator decision, NOT hardware-blocked) use priority "deferred"
  # in the backlog table — a distinct bucket from high/medium/low (investigate) and blocked (needs:).
  # A missing deferred_open field in legacy envelopes is a seed-prompt, not a hard FAIL (corpora written
  # before this field existed have 0 deferred rows and no field → both sides zero → no mismatch, silent).
  if is_int "$e_def"; then
    if [ "$e_def" != "$d_def" ]; then
      echo "   FAIL   envelope deferred_open=${e_def} != ${d_def} deferred backlog gap(s) — re-seed: --sync-state"
      frc=1; rc=1
    fi
  elif [ "$d_def" -gt 0 ]; then
    echo "   WARN   envelope deferred_open missing while $d_def deferred backlog gap(s) found — seed it: --sync-state"
  fi

  # ENVELOPE CHECK H (WARN-ONLY) — known_gaps declared identity: declared known_gaps must equal the sum
  # of its five DECLARED constituent terms (all from the envelope, not derived from disk):
  #   gaps_closed + investigable_open + blocked_open + deferred_open + requires_execution_open == known_gaps
  # This is an INTERNAL-CONSISTENCY check on the declared envelope fields. Disk-vs-declared staleness for
  # each individual term is already CHECK B/C/E/F's job — mixing derived values here conflates two invariants
  # and causes false positives on prose-tracked corpora (e.g. e_req=1 declared but d_req=0 → declared sum
  # correct but a derived-counter check would false-fire). Using declared counters matches §8 doctrine exactly.
  # LEGACY ENVELOPES: deferred_open predates some envelopes. Treat absent as 0 (mirrors CHECK F: "both sides
  # zero → no mismatch, silent" — same reasoning: pre-field corpora have 0 deferred rows by construction).
  # Do NOT apply absent-as-0 to any other field: e_inv/e_blocked/e_req absent means malformed envelope
  # (already caught by the individual field-presence checks); do not guess a sum from partial data.
  # Real-corpus examples (niagara-research, COB-IM2, blender-llm, HotelHilton, HotelPalace, sullair,
  # fluke-177x, all present corpora swept 2026-09-16; 20 true-positive WARNs measured that date):
  #   apis: gc+inv+blocked+def+req ≠ kg; build-kit-campaign8: kg=20 (= gc declared) OMITS declared req=6;
  #   oem-honeywell-tail: kg=0 but requires_execution_open=1 declared;
  #   optimizer-docs: gc=14 + blocked_open=6 declared → sum=20 ≠ kg=14 (also flagged by CHECK C for disk
  #   divergence — both invariants true, different checks); energeticos/webChart/database similarly.
  # WHY no-SIGPIPE-fallback: all five declared counters are already shell variables read above —
  # no grep pipe needed (§7: || echo 0 converts a real error into a confident zero).
  # WARN-ONLY: premature-STOP is owned by CHECK B (investigable_open) and CHECK D (full-coverage corner).
  # Skip when any of the five CORE declared counters (e_gc, e_kg, e_inv, e_blocked, e_req) is non-integer
  # (present-but-malformed field is already caught by the individual field-presence checks).
  _h_def=0; is_int "$e_def" && _h_def="$e_def"  # IDENTITY-DEF-ABSENT-AS-ZERO: absent OR non-integer deferred_open ⇒ 0 (CHECK F's is_int split)
  if is_int "$e_gc" && is_int "$e_kg" && is_int "$e_inv" && is_int "$e_blocked" && is_int "$e_req"; then  # IDENTITY-INT-GUARD
    _identity_sum=$(( e_gc + e_inv + e_blocked + _h_def + e_req ))  # IDENTITY-REQ-VAR
    if [ "$_identity_sum" -ne "$e_kg" ]; then  # IDENTITY-SUM-CHECK
      echo "   WARN   envelope known_gaps=$e_kg != sum of declared counters (gaps_closed+investigable_open+blocked_open+deferred_open+requires_execution_open)=$_identity_sum — stale denominator; reconcile."
    fi
  fi

  # P23: blocked/absent gaps missing a tried: clause. A tried: entry documents what alternatives
  # were explored and what measurement confirmed the gap was actually blocked (not just untried).
  # WARN-only — never fails the run; this is advisory hygiene, not a structural defect.
  d_missing_tried="$(derive_missing_tried "$state")"
  if [ "${d_missing_tried:-0}" -gt 0 ]; then  # P23-MISSING-TRIED-WARN
    echo "   WARN   $d_missing_tried blocked gap(s) missing a tried: clause (alternatives considered + what measurement closed each) — document before closing as absent-input."
  fi

  # ENVELOPE CHECK G — undocumented_findings: value validation then threshold gates.
  # e_uf and _uf_present are computed before the summary line above (SUGGESTION 8 visibility).
  # THREE cases, not two: absent (silent — legacy seeding contract), valid integer (threshold checks),
  # present-but-not-integer (FAIL — the gate cannot do its job; an unparseable value is a silent gate
  # evasion because --sync-state's pick() previously returned 0 for any non-integer, erasing real debt).
  # SEVERITY rationale: FAIL (not WARN) for unparseable, because the entire purpose of this counter is
  # blocking an archive when debt > 6; an unparseable value makes that gate permanently invisible.
  # Compare CHECK E (WARN for non-integer): CHECK E is a calibrated lower-bound gate; CHECK G is the
  # only gate for this counter and has no fallback — "unparseable" means "gate evaded".
  if [ -n "$_uf_present" ] && ! is_int "$e_uf"; then
    echo "   FAIL   envelope undocumented_findings=${e_uf:-<unparseable>} is not a valid non-negative integer — the archive gate cannot check debt."
    echo "          Correct the value manually in the envelope first (change it to a non-negative integer);"
    echo "          then re-seed with --sync-state. Running --sync-state without fixing the value first"
    echo "          will warn and carry the bad value forward — it will NOT zero it — but verify-state"
    echo "          will continue to FAIL until the value is a valid non-negative integer."
    frc=1; rc=1
  elif is_int "$e_uf" && [ "$e_uf" -gt 6 ]; then
    echo "   FAIL   envelope undocumented_findings=$e_uf > 6 — write the missing block(s), decrement to 0, re-seed: --sync-state. Memory is a MIRROR, not the record."
    frc=1; rc=1
  elif is_int "$e_uf" && [ "$e_uf" -gt 3 ]; then
    echo "   WARN   envelope undocumented_findings=$e_uf > 3 — findings exist only in memory (no block); write the block(s) and decrement."
  fi

  # ENVELOPE CHECK P18 — blocks_since_retro: §18 cadence threshold lint.
  # THREE cases (same rationale as CHECK G): absent (silent — optional manually-maintained field),
  # valid integer and >10 (WARN — cadence advisory, not structural failure so not FAIL),
  # present-but-non-integer (FAIL — gate cannot do its job).
  # Threshold from METHODOLOGY §18 "every ~10 blocks" → warn when the counter exceeds 10.
  if [ -n "$_bsr_present" ] && ! is_int "$e_bsr"; then
    echo "   FAIL   envelope blocks_since_retro=${e_bsr:-<unparseable>} is not a valid non-negative integer — fix the value manually."  # P18-NONINT-FAIL-CASE
    frc=1; rc=1
  elif is_int "$e_bsr" && [ "$e_bsr" -gt 10 ]; then  # P18-THRESHOLD-WARN-CASE
    echo "   WARN   envelope blocks_since_retro=$e_bsr > 10 — §18 retro cadence exceeded; write a retro and reset to 0."
  fi

  # P7: INDEX.md still contains template placeholders (<UPPER-CASE> tokens) while blocks exist on
  # disk. A corpus whose INDEX.md was never updated is a half-open corpus; placeholders mislead
  # readers about the subject and date. WARN-only — never fails the run (not a structural defect).
  _idx="$(dirname "$state")/INDEX.md"
  if [ "${ondisk:-0}" -gt 0 ] && [ -f "$_idx" ]; then
    if grep -qE '<[A-Z][A-Z0-9_-]*>' "$_idx" 2>/dev/null; then  # P7-INDEX-PLACEHOLDER-WARN
      if _ksw_has "p7-index-placeholder"; then  # KSW-P7-SUPPRESS
        echo "   INFO   INDEX.md placeholder WARN suppressed (known_stale_warns: p7-index-placeholder)"
      else
        echo "   WARN   INDEX.md still contains template placeholders (e.g. <SUBJECT>, <YYYY-MM-DD>) while $ondisk block file(s) on disk — update the corpus index."
      fi
    fi
  fi

  # P8 runs once per target above the per-state loop (not per state file).

  # SC-CROSS-CHECK (FAIL) — stop-control prose "Open gaps — read-only investigable: N" must match the
  # backlog-derived d_inv. The stop-control section is the human-readable STOP decision surface; a stale
  # number there points to a different N than the envelope and misleads the operator into a premature STOP.
  # Only fires when the prose line is PRESENT (absent prose = a different structural problem, not this check).
  # SC-CROSS-CHECK: stop-control prose format is "**Open gaps — read-only investigable**: N" (bold markers
  # wrap the label, colon follows the closing **). Accept both `investigable**: N` and `investigable: N`.
  # Three confirmed real-world forms (enumerated 2026-09-22 against real corpora):
  #   1. "**: N   ← annotation with trailing number"   (sdd-investigacion/RESEARCH-STATE.md)
  #   2. "**: N (G74 gap list with gap IDs)"            (blender-llm/RESEARCH-STATE.md)
  #   3. "**: **N** (gap list...)"  bold-wrapped value  (niagara-research/RESEARCH-STATE.md)
  # The old grep -oE '[0-9]+' | tail -1 took the LAST number anywhere on the line: form 1 returned
  # 0 (from "hits 0"), form 2 returned 74 (from G74). Fix: re-match the field prefix up to the value
  # so only the number that immediately follows the colon is captured.
  # Unparseable-value verdict: if the first regex matches (line present with a number after colon) but
  # the anchored extraction finds nothing, that is impossible by construction (same [0-9]+ anchor in
  # both regexes), so empty _sc_n means the prose line is absent → silently skip (§7: absent-input
  # vs empty-input; absent prose is a different structural problem, not this check's scope).
  _sc_prose="$(grep -iE 'read-only investigable\*{0,2}:[[:space:]]*\*{0,2}[0-9]+' "$state" 2>/dev/null | head -1)"
  if [ -n "$_sc_prose" ]; then
    _sc_n="$(printf '%s' "$_sc_prose" | grep -oiE 'investigable\*{0,2}:[[:space:]]*\*{0,2}[0-9]+' | grep -oE '[0-9]+$')"  # SCEX-EXTRACT-ANCHOR
    if [ -n "$_sc_n" ] && [ "$_sc_n" != "$d_inv" ]; then  # SC-CROSS-CHECK
      echo "   FAIL   stop-control prose 'read-only-investigable: ${_sc_n}' but backlog derives ${d_inv} investigable gap(s) — refresh the Stop control section and re-seed: --sync-state"
      frc=1; rc=1
    fi
  fi

  # CHECK 1 (FAIL) — summary claims every gap closed, but the backlog still lists pending gaps.
  if [ -n "${cx:-}" ] && [ -n "${cy:-}" ] && [ "$cx" = "$cy" ] && [ "${pending:-0}" -gt 0 ]; then
    echo "   FAIL   summary claims ALL $cy gaps closed, but the backlog lists $pending 'pending' gap(s)."
    echo "          Stale mirror — this desync is what lets the loop emit a PREMATURE STOP. Refresh the"
    echo "          coverage metric (or reopen it) so it matches the backlog before honoring any STOP."
    frc=1; rc=1
  fi

  # CHECK 2 (WARN) — covered-blocks claim drifted from the on-disk block count.
  # Skipped for shared-global (_sg_check_a_done=1): ondisk = corpus total there, but covered_claim
  # reflects attributed blocks (a focus-level count), so comparing them always misfires when the
  # focus has not covered all corpus blocks.
  if [ -n "${covered_claim:-}" ] && [ "${ondisk:-0}" -gt 0 ] && [ "$_sg_check_a_done" = 0 ] && [ "$covered_claim" != "$ondisk" ]; then  # SG-CHECK2-COND
    if _ksw_has "check-2-covered-blocks"; then  # KSW-CHECK2-SUPPRESS
      echo "   INFO   covered-blocks mismatch WARN suppressed (known_stale_warns: check-2-covered-blocks)"
    else
      echo "   WARN   'Covered blocks: $covered_claim' disagrees with $ondisk block file(s) on disk — refresh the mirror."
    fi
  fi

  # CHECK 3 (WARN) — contradictory CANONICAL coverage numbers. RESEARCH-STATE must carry ONE canonical
  # coverage figure; the real pruebas-dashboards corpus instead ACCRETED 16/16, 22/16, 24/16, then 26/26
  # (the denominator drifted 16→26 with no reconciliation) so no reader could get one true number. The
  # `## Iteration history` table LEGITIMATELY snapshots a different cumulative ratio per row, so strip
  # that section first (awk drops everything from its history header to the next `## ` header). The fence
  # is matched CASE-INSENSITIVELY (tolower) and also accepts the bare `## History` alias: over-recognizing
  # the history fence is cheap (a miss there is low-cost), while a false alarm is the whole risk. Only
  # canonical coverage-metric lines OUTSIDE it are gathered. NOTE: this diffs on distinct DENOMINATORS
  # only — same-denominator/different-numerator drift (22/16 vs 24/16) is intentionally NOT flagged.
  # Two-or-more DISTINCT denominators ⇒ WARN (mirror hygiene, not a STOP hazard — no rc change, like CHECK 2).
  noniter="$(awk '
    tolower($0) ~ /^##[[:space:]]+(iteration )?history/ { inhist=1; next }
    /^##[[:space:]]/ { inhist=0 }
    !inhist { print }
  ' "$state" 2>/dev/null)"
  mapfile -t denoms < <(printf '%s\n' "$noniter" \
    | grep -iE 'coverage metric|declared gaps closed|gaps? closed|coverage \(after' \
    | LC_ALL=C awk 'match($0, /[0-9]+[[:space:]]*\/[[:space:]]*[0-9]+/) { print substr($0, RSTART, RLENGTH) }' \
    | sed -E 's#.*/[[:space:]]*##' \
    | sort -un)
  if [ "${#denoms[@]}" -ge 2 ]; then
    joined="$(printf '%s vs ' "${denoms[@]}")"; joined="${joined% vs }"
    echo "   WARN   contradictory coverage denominators ($joined) — collapse to one canonical coverage number"
  fi

  [ "$frc" -eq 0 ] && echo "   ok     envelope validated + summary consistent with the backlog."
done

echo "== exit $rc =="
exit $rc
