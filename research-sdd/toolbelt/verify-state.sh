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

_backlog_rows() {       # emits "priority<TAB>gap<TAB>status" for valid 4-col rows; INVALID_PRIORITY<TAB><val>
  # for unknown priority values. Callers that derive counts safely ignore the 2-field sentinel (field 3
  # absent so no count fires); the per-state backlog parse check below treats INVALID_PRIORITY as FAIL.
  # Silently skips: deferred (parked), strikethrough (~~p~~), em-dash (—). Qualifier forms ("high (ctx)")
  # emit a provisional WARN to stderr and are still excluded. Unknown qualifier BASE fails closed.
  # Mirrors backlog_rows() in status.sh exactly.
  # Same file as last call → return cached rows; structural WARNs already emitted once.
  if [ "$_BR_CACHED_FILE" = "$1" ]; then  # BR-CACHE-HIT
    [ -n "$_BR_CACHED_ROWS" ] && printf '%s\n' "$_BR_CACHED_ROWS"
    return
  fi
  # BR-CACHE-MISS: run awk; WARNs go to stderr exactly once; capture stdout for subsequent calls.
  _BR_CACHED_FILE="$1"
  _BR_CACHED_ROWS="$(awk '
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
      if (n!=4) { print "WARN: malformed backlog row (" n " cells, expected 4 — a cell may contain a pipe): " $0 > "/dev/stderr"; next }  # VS-N4-WARN
      print p "\t" a[2] "\t" tolower(a[4]) }' "$1")"
  [ -n "$_BR_CACHED_ROWS" ] && printf '%s\n' "$_BR_CACHED_ROWS"
}
# B3a: _blocked_names also scans "## Non-investigable gaps" (semantically identical to ## Blocked gaps;
# used in older/TRANE/EduVolt corpora). Both sections follow the same "- <name> — needs: …" convention.
_blocked_names() {                                  # one exact blocked gap NAME per "- <name> — needs: ..." line
  { _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; } \
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
# derived blocked_open = count of "- <name> — needs: ..." entries under ## Blocked gaps OR
# ## Non-investigable gaps (B3a: both headings are semantically identical; needs:-anchored so a bare
# "- none" placeholder never inflates the count).
derive_blocked() { { _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; } | grep -icE '^[[:space:]]*-[[:space:]].*needs:'; }
# P23: count blocked/absent gap entries that carry `needs:` but NOT `tried:` (a tried: clause is
# mandatory before a gap can be closed as absent-input; its absence means the operator parked the
# gap without documenting what they attempted, collapsing absent-input and untried into one signal).
derive_missing_tried() {
  { _section "$1" '## Blocked gaps'; _section "$1" '## Non-investigable gaps'; } \
    | grep -iE '^[[:space:]]*-[[:space:]].*needs:' \
    | grep -civE 'tried:'
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
  #   (a) block_scope: shared-global (this becomes the authoritative ondisk count), and
  #   (b) the cannot-see diagnostic when per-focus ondisk==0 while other-prefix blocks exist.
  _ondisk_global="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter | wc -l | tr -d ' ')"
  : # BS-ONDISK-GLOBAL-COMPUTED — override this line with _ondisk_global="0" to test cannot-see-pass teeth
  if [ "$_bs_valid" = 1 ] && [ -n "$_bs_present" ] && [ "$e_bs" = "shared-global" ]; then
    ondisk="$_ondisk_global"  # BS-SHARED-GLOBAL-ONDISK
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

  echo "-- summary --"
  echo "   coverage metric : ${xy:-<none>}"
  echo "   covered blocks  : ${covered_claim:-<none>} claimed · ${ondisk} block file(s) on disk"
  echo "   backlog pending : ${pending}"
  echo "   envelope        : covered_blocks=${e_covered:-<none>}/${ondisk} · investigable_open=${e_inv:-<none>}/${d_inv} · requires_execution_open=${e_req:-<none>}/${d_req} · blocked_open=${e_blocked:-<none>}/${d_blocked} · deferred_open=${e_def:-<none>}/${d_def} · undocumented_findings=${e_uf:-<none>}  (declared/derived; undocumented_findings is manually-maintained)"

  # ENVELOPE CHECK A (FAIL) — declared covered_blocks must equal on-disk block files.
  # For block_scope: shared-global, ondisk is already the global count (set above).
  # For absent/per-focus with a focus prefix, distinguish the cannot-see case (focus-filtered=0 while
  # other-prefix blocks exist) from a genuine zero or a real staleness mismatch.
  if ! is_int "$e_covered" || [ "$e_covered" != "$ondisk" ]; then
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

  # P7: INDEX.md still contains template placeholders (<UPPER-CASE> tokens) while blocks exist on
  # disk. A corpus whose INDEX.md was never updated is a half-open corpus; placeholders mislead
  # readers about the subject and date. WARN-only — never fails the run (not a structural defect).
  _idx="$(dirname "$state")/INDEX.md"
  if [ "${ondisk:-0}" -gt 0 ] && [ -f "$_idx" ]; then
    if grep -qE '<[A-Z][A-Z0-9_-]*>' "$_idx" 2>/dev/null; then  # P7-INDEX-PLACEHOLDER-WARN
      echo "   WARN   INDEX.md still contains template placeholders (e.g. <SUBJECT>, <YYYY-MM-DD>) while $ondisk block file(s) on disk — update the corpus index."
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
  if [ -n "${covered_claim:-}" ] && [ "${ondisk:-0}" -gt 0 ] && [ "$covered_claim" != "$ondisk" ]; then
    echo "   WARN   'Covered blocks: $covered_claim' disagrees with $ondisk block file(s) on disk — refresh the mirror."
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
    | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' \
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
