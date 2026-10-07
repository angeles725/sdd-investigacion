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
#        Every counter that differs from the declared envelope is REPORTED (`sync-state: CHANGED <file>
#        <field>: <old> -> <new>`); --only <field[,field...]> rewrites just the named counters and keeps the
#        rest as declared (kit #911). A fence that lacks undocumented_findings is NOT given an invented 0.
#        gaps_closed/known_gaps are DECLARED-only (kit #1637): a declared integer ABOVE the derived value is KEPT and
#        reported as `sync-state: DECLARED <field>=<n> (derived <m>) — kept; verify the declared value or correct it by
#        hand`; at or below the derived value the derivation wins (reported as CHANGED); an absent or non-integer
#        counter is seeded from the derivation; --only <field> writes the derived value (it bypasses the keep).
#   --root selects the un-suffixed RESEARCH-STATE.md of a multi-focus corpus (mutually exclusive with --focus; kit #906).
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
#   --emit-token (with --next; kit #1706) appends ONE line `return-token: <token>` after the normal output, mapped from
#        the same verdict (NEXT → `next: <gap>`; STOP → `STOP: campaign — <reason>` only for a single state file with no
#        `## Campaign queue`; the count is corpus-wide, NOT narrowed by --focus/--root — kit #1726). The verdict line is
#        picked by prefix; zero or several verdict lines are unavailable too. Any other verdict, or a non-zero --next, prints `return-token: unavailable (<reason>)` and
#        exits 1 — never a guessed token. Without the flag the output is unchanged. Requires --next (exit 2).
#   --focus <slug> (with --next) scopes the STALE gate to THAT focus's verify-state only (kit #1543): defects in
#        a legacy sibling focus no longer brick a clean active focus. --all is the explicit corpus-wide form;
#        it is also the DEFAULT when neither --focus nor --root is given (kept unchanged on purpose: the
#        corpus-wide gate is the safe default). --all excludes --focus/--root and requires --next (exit 2).
#        In a multi-focus corpus the corpus-wide STALE line appends `[failing focus: a,b]` naming the focuses
#        whose own verify-state fails. Every STALE line then ends with `[first failure: <file>: <check>]` (kit
#        #1544): the first verify-state FAIL of the same scope (for several failing focuses, the first in
#        C-locale sort order = the first one in `[failing focus: …]`; a stale root RESEARCH-STATE.md falls back to
#        the corpus-wide run). When verify-state printed no FAIL line the pointer is the typed
#        `[first failure: unavailable — verify-state printed no FAIL line (rc=N)]`, never omitted.
#        The default report's `Stop hook` line ends with `(checked: <absolute target path>)` (kit #1150 item 1).
#   --root / --focus <slug> (with --next) also scope the NEXT/STOP verdict (and the RETRO-DUE check) to the PICKED
#        state file (kit #1837); only the no-flag form and --all aggregate over every state file. NOT scoped: the
#        --root STALE gate stays corpus-wide (only --focus narrows it, #1543), so an active stale sibling focus
#        still makes `--root --next` print STALE.
#   (NONE is no longer emitted: an empty eligible-backlog means derived investigable=0 → STOP by construction.)
# Exit: 0 ok · 1 --emit-token with no token available (`return-token: unavailable`) · 2 bad args. (malformed backlog rows are WARNed to stderr, never silently dropped.)
set -uo pipefail

_orig_args=("$@")   # --emit-token re-runs this script with the same argv minus the flag (kit #1706)
target="${1:-}"
[ -d "$target" ] || { echo "usage: research-sdd-status.sh <target-dir> [--next|--sync-state] [--focus <slug>]" >&2; exit 2; }
shift
mode="status"
focus_slug=""
emit_token=0       # --emit-token: with --next, append the literal RETURN CONTRACT token line (kit #1706)
all_flag=0         # --all: explicit corpus-wide --next (kit #1543); same as the default when no --focus/--root is given
root_flag=0        # --root: target the un-suffixed RESEARCH-STATE.md (kit #906)
only_list=""       # --only: comma-separated owned counters --sync-state may rewrite (kit #911)
only_set=0
_OWNED_COUNTERS="covered_blocks gaps_closed known_gaps investigable_open requires_execution_open blocked_open deferred_open undocumented_findings"
stall_minutes=15   # default stall threshold in minutes (§8c)
while [ $# -gt 0 ]; do
  case "$1" in
    --next|--sync-state) mode="$1"; shift ;;
    --root) root_flag=1; shift ;;
    --all) all_flag=1; shift ;;
    --emit-token) emit_token=1; shift ;;
    --only)
      only_list="${2-}"; only_set=1
      case "$only_list" in *[[:space:]]*) echo "usage: --only: counter list must be comma-separated with no whitespace (e.g. --only covered_blocks,blocked_open)" >&2; exit 2 ;; esac
      case "$only_list" in ''|,*|*,|*,,*) echo "usage: --only requires a counter list, e.g. --only covered_blocks,blocked_open (no empty elements)" >&2; exit 2 ;; esac
      _oi="${only_list//,/ }"
      for _of in $_oi; do
        case " $_OWNED_COUNTERS " in *" $_of "*) ;; *) echo "usage: --only: unknown counter '$_of' (valid: $_OWNED_COUNTERS)" >&2; exit 2 ;; esac
      done
      shift 2 ;;
    --focus)
      focus_slug="${2:-}"
      [ -z "$focus_slug" ] && { echo "usage: --focus requires a focus slug" >&2; exit 2; }
      shift 2 ;;
    --stall-minutes)
      stall_minutes="${2:-}"
      # R2-001: the message says "positive integer" — 0 is not one, so reject it here too
      # (the digits-only regex alone would accept "0", contradicting the usage message).
      # SM-ZERO-REJECT-ANCHOR (next line)
      { grep -qE '^[0-9]+$' <<<"$stall_minutes" && [ "$stall_minutes" -ne 0 ]; } \
        || { echo "usage: --stall-minutes requires a positive integer" >&2; exit 2; }
      shift 2 ;;
    *) echo "usage: research-sdd-status.sh <target-dir> [--next [--all] [--emit-token]|--sync-state [--only <counters>]] [--focus <slug>|--root] [--stall-minutes N]" >&2; exit 2 ;;
  esac
done
# only_has <counter>: true when this counter WILL be written (no --only, or named in it).
only_has() { [ "$only_set" = 0 ] && return 0; case ",$only_list," in *",$1,"*) return 0 ;; esac; return 1; }
[ "$only_set" = 1 ] && [ "$mode" != "--sync-state" ] && { echo "usage: --only requires --sync-state" >&2; exit 2; }
[ "$root_flag" = 1 ] && [ -n "$focus_slug" ] && { echo "usage: --root and --focus are mutually exclusive" >&2; exit 2; }
[ "$all_flag" = 1 ] && [ "$mode" != "--next" ] && { echo "usage: --all requires --next" >&2; exit 2; }
[ "$all_flag" = 1 ] && { [ "$root_flag" = 1 ] || [ -n "$focus_slug" ]; } && { echo "usage: --all is corpus-wide and excludes --focus/--root" >&2; exit 2; }
[ "$emit_token" = 1 ] && [ "$mode" != "--next" ] && { echo "usage: --emit-token requires --next" >&2; exit 2; }

# --emit-token (kit #1706): print the normal --next output, then ONE literal `return-token: <token>` line mapped from the
# SAME verdict (this script re-runs itself without the flag, so the verdict is the one --next computes and the no-flag
# output is untouched). The token is the PROMPT-LOOP RETURN CONTRACT form the agent copies instead of composing:
#   NEXT | <prio> | <gap>  ->  next: <gap>
#   STOP | <reason>        ->  STOP: campaign — <reason>   ONLY for one state file with no `## Campaign queue`
# The verdict line is selected by prefix (NEXT/STOP/ISSUES-DUE/RETRO-DUE/STALE/BOOTSTRAP + " | "); zero or several
# such lines -> unavailable (kit #1726). The STOP guard counts EVERY state file under the target on purpose and is NOT
# scoped by --focus/--root: those flags scope which file the VERDICT is read from, but `STOP: campaign` is a claim about
# the whole campaign, and a focus-scoped STOP in a multi-focus corpus only says that focus is exhausted (the other
# focuses and the §8c queue/partition check are not computed here) -> conservative `unavailable`.
# Anything else (RETRO-DUE / ISSUES-DUE / STALE / BOOTSTRAP, a STOP over several focuses or a queue, a non-zero --next)
# has no single contract token: `return-token: unavailable (<reason>)` + exit 1 — never a guessed token.
if [ "$emit_token" = 1 ]; then
  _et_args=()
  for _et_a in "${_orig_args[@]}"; do [ "$_et_a" = "--emit-token" ] || _et_args+=("$_et_a"); done
  _et_out="$(bash "${BASH_SOURCE[0]}" "${_et_args[@]}")"; _et_rc=$?
  [ -n "$_et_out" ] && printf '%s\n' "$_et_out"
  _et_unavail() { printf 'return-token: unavailable (%s)\n' "$1"; exit 1; }
  [ "$_et_rc" -ne 0 ] && _et_unavail "--next exited $_et_rc"  # ET-RC-GATE
  [ -n "$_et_out" ] || _et_unavail "--next printed nothing"
  # Pick the verdict line by its PREFIX, not by position (kit #1726): a trailing note line must not become the verdict,
  # and zero or several verdict lines mean the output is not the one-verdict shape this mapping understands.
  _et_verdict=""; _et_nv=0
  while IFS= read -r _et_ln; do
    case "$_et_ln" in
      "NEXT | "*|"STOP | "*|"ISSUES-DUE | "*|"RETRO-DUE | "*|"STALE | "*|"BOOTSTRAP | "*) _et_verdict="$_et_ln"; _et_nv=$((_et_nv+1)) ;;  # ET-VERDICT-PICK
    esac
  done <<<"$_et_out"
  [ "$_et_nv" -eq 1 ] || _et_unavail "--next output carries $_et_nv verdict lines (want exactly 1)"  # ET-VERDICT-ONE
  case "$_et_verdict" in
    "NEXT | "*)
      _et_gap="${_et_verdict#NEXT | }"; _et_gap="${_et_gap#* | }"
      [ -n "$_et_gap" ] && [ "$_et_gap" != "${_et_verdict#NEXT | }" ] || _et_unavail "NEXT verdict carries no gap"
      printf 'return-token: next: %s\n' "$_et_gap"  # ET-NEXT-MAP
      exit 0 ;;
    "STOP | "*)
      _et_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # shellcheck source=lib/state-files.sh
      . "$_et_here/lib/state-files.sh" 2>/dev/null
      declare -F list_state_files >/dev/null 2>&1 || _et_unavail "STOP: cannot enumerate state files (lib/state-files.sh unavailable)"
      mapfile -t _et_states < <(list_state_files "$target")
      [ "${#_et_states[@]}" -eq 1 ] || _et_unavail "STOP over ${#_et_states[@]} state files needs the §8c campaign-close partition check (--focus/--root scope the verdict, not the campaign)"  # ET-STOP-MULTI-GUARD
      grep -q '^## Campaign queue' "${_et_states[0]}" 2>/dev/null; _et_g=$?
      [ "$_et_g" -eq 1 ] || _et_unavail "STOP with a ## Campaign queue (or unreadable state) needs next-entry vs STOP: campaign from §8c"  # ET-STOP-QUEUE-GUARD
      printf 'return-token: STOP: campaign — %s\n' "${_et_verdict#STOP | }"  # ET-STOP-MAP
      exit 0 ;;
    *)
      _et_unavail "verdict '${_et_verdict%% *}' has no RETURN CONTRACT token; resolve it first" ;;  # ET-OTHER-UNAVAILABLE
  esac
fi

# The default / --focus pick goes through lib/state-files.sh resolve_state_file (kit #1818): root first,
# shallowest first, one definition shared with archive / verify-state / verify-registry. Sourced HERE, before
# the pick, because the pick decides $corpus that everything below derives from.
_SFLIB="$(cd "$(dirname "$0")" && pwd)/lib/state-files.sh"
if [ ! -f "$_SFLIB" ]; then
  echo "research-sdd-status: cannot find helper $_SFLIB" >&2; exit 1
fi
# shellcheck source=lib/state-files.sh
. "$_SFLIB"
declare -F list_state_files >/dev/null 2>&1 && declare -F resolve_state_file >/dev/null 2>&1 || { echo "research-sdd-status: helper $_SFLIB failed to define list_state_files/resolve_state_file" >&2; exit 1; }

if [ "$root_flag" = 1 ]; then
  # --root: select exactly the un-suffixed RESEARCH-STATE.md, ignoring every RESEARCH-STATE-<focus>.md.
  # A root is the TOP-LEVEL file, or the sole nested one that sits beside RESEARCH-STATE-<focus>.md
  # siblings. A lone nested file with no siblings (archive/, backup/) or several candidates is refused.
  state=""; _root_cands="$(find "$target" -maxdepth 3 -name 'RESEARCH-STATE.md' -not -path '*/.git/*' 2>/dev/null | sort)"
  if [ -f "$target/RESEARCH-STATE.md" ]; then
    state="$target/RESEARCH-STATE.md"
  elif [ -n "$_root_cands" ]; then
    _root_sib=""; _root_nsib=0
    while IFS= read -r _rc; do
      if [ -n "$(find "$(dirname "$_rc")" -maxdepth 1 -name 'RESEARCH-STATE-*.md' -not -name '*.template.md' -print -quit 2>/dev/null)" ]; then  # ROOT-PICK-SIBLINGS
        _root_sib="$_rc"; _root_nsib=$((_root_nsib+1))
      fi
    done <<<"$_root_cands"
    if [ "$_root_nsib" = 1 ]; then state="$_root_sib"
    else
      printf 'root-select: ERROR: --root is ambiguous or unsupported under %s: no top-level RESEARCH-STATE.md and %s root candidate(s) beside focus siblings; candidates:\n%s\n' \
        "$target" "$_root_nsib" "$(printf '%s\n' "$_root_cands" | sed 's/^/  /')" >&2
      exit 1
    fi
  fi
  if [ ! -f "$state" ]; then
    [ "$mode" = "--sync-state" ] && { printf 'sync-state: no RESEARCH-STATE.md under %s\n' "$target" >&2; exit 1; }
    [ "$mode" = "--next" ] && echo "BOOTSTRAP | no RESEARCH-STATE.md under $target" || echo "no RESEARCH-STATE.md under $target — run research-sdd-init.sh"
    exit 0
  fi
elif [ -n "$focus_slug" ]; then
  # --focus <slug>: select exactly RESEARCH-STATE-<slug>.md, ignoring sibling focuses.
  # rc 2 (same slug in two same-depth dirs) is accepted: the C-locale-first pick is what this always chose.
  state="$(resolve_state_file "$target" --focus "$focus_slug")"; _sf_rc=$?  # SF-FOCUS-PICK
  [ "$_sf_rc" -le 2 ] || { echo "research-sdd-status: state-file resolution failed (rc $_sf_rc)" >&2; exit 1; }  # SF-FOCUS-GUARD
  if [ ! -f "$state" ]; then
    [ "$mode" = "--next" ] && echo "BOOTSTRAP | no RESEARCH-STATE-${focus_slug}.md under $target" || echo "no RESEARCH-STATE-${focus_slug}.md under $target — run research-sdd-init.sh"
    exit 0
  fi
else
  state="$(resolve_state_file "$target")"; _sf_rc=$?  # SF-DEFAULT-PICK
  [ "$_sf_rc" -le 2 ] || { echo "research-sdd-status: state-file resolution failed (rc $_sf_rc)" >&2; exit 1; }  # SF-DEFAULT-GUARD
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
declare -F inplace_blocked_count >/dev/null 2>&1 || { echo "research-sdd-status: helper $_FPLIB failed to define inplace_blocked_count" >&2; exit 1; }

# lib/state-files.sh (list_state_files / resolve_state_file) was already sourced above, before the pick
# that decides $corpus — the single definition of the "enumerate RESEARCH-STATE*.md" incantation
# (verify-state.sh:33 remains the authoritative reference for the exclusion set).

_BFLIB="$here/lib/block-files.sh"
if [ ! -f "$_BFLIB" ]; then echo "research-sdd-status: cannot find helper $_BFLIB" >&2; exit 1; fi
# shellcheck source=lib/block-files.sh
. "$_BFLIB"
declare -F block_file_filter >/dev/null 2>&1 || { echo "research-sdd-status: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
unset _BFLIB

# Shared Stop-hook wiring predicate (kit issue #1109): single source of truth with
# sweep-retros.sh's WIRING-STATUS fleet pass and verify-registry.sh's 'hook yes' claim check.
_HWLIB="$here/lib/hook-wiring.sh"
if [ ! -f "$_HWLIB" ]; then echo "research-sdd-status: cannot find helper $_HWLIB" >&2; exit 1; fi
# shellcheck source=lib/hook-wiring.sh
. "$_HWLIB"
declare -F hook_stop_wiring_state >/dev/null 2>&1 || { echo "research-sdd-status: helper lib/hook-wiring.sh failed to define hook_stop_wiring_state" >&2; exit 1; }
unset _HWLIB

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

# TERMINAL NO-GARBAGE WARN (kit #1277 slice 2; METHODOLOGY §15, contract clean-check.v1.md). When --next resolves to an
# EXHAUSTED STOP (the §8 terminal trigger: `STOP | read-only-investigable exhausted (0)`, with or without the
# issue-coverage marker), run clean-check.sh over the target and echo its findings to STDERR as a loud WARN. Report-only by
# the maintainer decision (slice 1 = report-only): stdout, the verdict line, the --emit-token mapping and the exit code are
# UNCHANGED. Three states (§7): clean (one `INFO: clean-check: clean` line), findings (`WARN: clean-check: ...` per line), and
# unverifiable (a typed `WARN: clean-check: unverifiable (...)` for a missing script, a non-git target, or exit 2/3) — never a silent zero.
# RSDD_STATUS_NO_CLEAN_CHECK=1 skips it (the caller already ran clean-check).
terminal_clean_warn() {
  # No verdict argument: the only two callers sit on the exhausted-STOP print sites inside issues_due_gate, so there is no
  # second copy of the verdict text to drift (RDD round 2).
  [ "${RSDD_STATUS_NO_CLEAN_CHECK:-0}" = "1" ] && return 0
  local _cc_here _cc_script _cc_out _cc_rc _cc_ln
  _cc_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _cc_script="$_cc_here/clean-check.sh"
  if [ ! -f "$_cc_script" ]; then
    printf 'WARN: clean-check: unverifiable (clean-check.sh not found beside research-sdd-status.sh) — terminal no-garbage check NOT run\n' >&2
    return 0
  fi
  # Bounded (RSDD_STATUS_CLEAN_CHECK_TIMEOUT seconds, default 20): --next also runs from the Stop hook. No timeout/gtimeout =
  # typed unverifiable WARN, never an unbounded run.
  local _cc_to _cc_secs="${RSDD_STATUS_CLEAN_CHECK_TIMEOUT:-20}"
  # Exact positive-integer test (#1277 follow-up): digits only, and non-zero once leading zeros are stripped. The old
  # `0|0[0]*` glob rejected 005/007 (any `00`-prefixed value) yet accepted 01. GNU timeout treats 0 as "no limit", so a
  # zero value is never passed through; a valid value is normalised (010 -> 10).
  local _cc_stripped
  case "$_cc_secs" in
    ''|*[!0-9]*) _cc_stripped="" ;;
    *) _cc_stripped="${_cc_secs#"${_cc_secs%%[!0]*}"}" ;;
  esac
  if [ -z "$_cc_stripped" ]; then
    printf 'WARN: clean-check: invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT=%s (need an integer >= 1) — using 20\n' "$_cc_secs" >&2; _cc_secs=20
  else
    _cc_secs="$_cc_stripped"
  fi
  _cc_to="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -z "$_cc_to" ]; then
    printf 'WARN: clean-check: unverifiable (timeout/gtimeout not found, unbounded run refused) — terminal no-garbage check NOT run\n' >&2
    return 0
  fi
  _cc_out="$("$_cc_to" -k 5 "$_cc_secs" bash "$_cc_script" --target "$target" 2>&1)"; _cc_rc=$?
  case "$_cc_rc" in
    124|137) printf 'WARN: clean-check: unverifiable (timed out after %ss) — terminal no-garbage check NOT confirmed\n' "$_cc_secs" >&2 ;;
    0) printf 'INFO: clean-check: clean at terminal STOP\n' >&2 ;;
    1) printf 'WARN: clean-check: findings at terminal STOP — resolve or declare in <target>/.research-sdd/keep.txt before closing\n' >&2
       while IFS= read -r _cc_ln; do printf 'WARN: clean-check: %s\n' "$_cc_ln" >&2; done <<<"$_cc_out" ;;
    *) printf 'WARN: clean-check: unverifiable (exit %s: %s) — terminal no-garbage check NOT confirmed\n' "$_cc_rc" "$(printf '%s' "$_cc_out" | tail -n 1)" >&2 ;;
  esac
  return 0
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
        if (p=="deferred") { if (!(index(a[2],"~~") || index(st,"~~") || index(st,"✅"))) next; cp="deferred" }  # CC-DEFERRED-CLOSED: open deferred rows are counted by count_deferred/derive_deferred, not here
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
        requires-execution*|blocked-on-*|blocked|blocked:|blocked,|'~~'*|'✅'*|closed|\[closed\]|covered|\[covered\]|done|\[done\]|cubierto|\[cubierto\]) ;;  # DONE-TOKENS
        re-typed*|retyped*) printf 'WARN: re-typed row still carries "re-typed" — write its Status as the re-typed form "blocked (requires-<what>)" per METHODOLOGY §8b (or move it to the Blocked-gaps section) [gap: %s]\n' "$gap" >&2 ;;  # RETYPED-WARN (#1638): uncounted by design, never silent; mirrored in verify-state.sh
        *) printf 'WARN: unrecognised Status token [%s] in gap: %s\n' "$tok" "$gap" >&2 ;;  # UNRECOG-STATUS-WARN
      esac
      continue
    }
    is_blocked "$gap" && continue
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# count_retyped_in_table — OPEN backlog rows whose leading Status token is `re-typed`/`retyped` (#1638). Such a
# row is deliberately NOT investigable and NOT a blocked bucket (METHODOLOGY §8b: it leaves the main table in
# the same edit) — this makes it VISIBLE so it is never counted nowhere. MIRRORS verify-state.sh's
# derive_retyped_in_table EXACTLY (same token set, same struck-gap skip).
count_retyped_in_table() {
  local gap st lead tok n=0
  while IFS=$'\t' read -r _ gap st; do
    [ -z "$gap" ] && continue
    case "$gap" in *'~~'*) continue ;; esac
    lead="${st#\*\*}"; lead="${lead/\*\*/}"
    tok="${lead%% *}"
    case "$tok" in re-typed*|retyped*) n=$((n+1)) ;; esac  # RETYPED-COUNT RETYPED-TOKENS
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# warn_inplace_blocked FILE N — the typed actionable WARN for the in-place bucket (prints nothing when N is 0).
# Called on every path that derives gaps_closed (backlog-derived AND declared-keep).
warn_inplace_blocked() {
  [ "${2:-0}" -gt 0 ] || return 0
  printf 'sync-state: WARN: %s: %d in-place blocked row(s) (Status blocked / blocked-on-*) are open but not in blocked_open (section-derived) — NOT counted as closed in gaps_closed; move them to ## Blocked gaps (METHODOLOGY §21.1) so blocked_open and the known_gaps identity (verify-state CHECK H) agree.\n' "$1" "$2" >&2
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
# count_all_known_gaps — total backlog row count: all valid-priority rows (all statuses) PLUS the closed-class
# rows (kit #1307): em-dash and struck-tier rows, and CLOSED deferred rows (✅ / ~~). Those are gaps that were
# closed, so they belong in known_gaps (and, by the kg − open-buckets derivation, in gaps_closed) but are
# never routable. OPEN deferred rows are NOT in this count: they are counted by count_deferred and added by
# the caller, so no row is counted twice. An em-dash row whose Status is open is excluded with a WARN (§8b).
# Used to derive known_gaps when the backlog total exceeds the coverage metric Y (issue #568): a new gap
# added to the backlog bumps this count even when the coverage metric prose is stale.
# INVALID_PRIORITY rows are excluded — they are not countable and are reported separately.
count_all_known_gaps() {
  # Stderr is captured, not discarded: the closed-class WARNs (open em-dash row, malformed closed-class row) exist ONLY
  # on this call's path and must reach the operator; the structural WARNs were already printed by the parse check.
  local _kg_err _kg_rows; _kg_err="$(mktemp)" || { echo "sync-state: ERROR: mktemp failed" >&2; echo 0; return; }
  _kg_rows="$(backlog_rows 1 2>"$_kg_err")"  # KG-ALL-BACKLOG (arg 1 = ALSO closed-class rows, #1307)
  grep -E 'em-dash priority on an OPEN row|malformed closed-class backlog row|em-dash row whose Gap cell is not a gap id|near-miss backlog heading has no Priority header' "$_kg_err" >&2
  rm -f "$_kg_err"
  printf '%s\n' "$_kg_rows" | grep -v -e '^INVALID_PRIORITY' -e '^UNCOUNTED' | grep -c . | tr -d ' '  # KG-COUNT-NONEMPTY
}
# count_uncounted_rows — rows under a near-miss backlog heading whose tier token is not a §8b tier (numeric,
# bold, ...). They are excluded from count_all_known_gaps (and WARNed), so a derived known_gaps is then only a
# LOWER BOUND: --sync-state must not lower a declared known_gaps below it (kit #1307).
count_uncounted_rows() { backlog_rows 1 2>/dev/null | grep -c '^UNCOUNTED' | tr -d ' '; }
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
# env_raw <key> — full declared value (everything after "key:", trimmed, CR-stripped) from the CURRENT
# envelope; exit 1 when the key is ABSENT (absent != empty). Whitespace/indent tolerant like the UF probe.
env_raw() { awk -v k="$1" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0}
  b { l=$0; sub(/^[[:space:]]+/,"",l); if (index(l,k":")==1) { v=substr(l,length(k)+2); sub(/^[[:space:]]+/,"",v); sub(/[[:space:]\r]+$/,"",v); print v; f=1; exit } }
  END { exit f?0:1 }' "$state"; }  # ENV-RAW
# cov_ratio — the "N/M" of the Coverage metric FIELD in "## Coverage" (kit issue #1154), or empty when there is none.
# The label is the field's identity: a line only counts when it STARTS with `Coverage metric` (an optional list
# marker, bold marks, and a parenthetical qualifier such as `(this focus)` allowed) followed by `:` or `=`.
# Matching the bare phrase anywhere in the section read any note that merely mentioned it (e.g. an Outline line
# pointing at the field) as the gap ratio. Label forms measured on the fleet: `**Coverage metric**:` and the
# qualified `**Coverage metric (this focus)**:`; no prefixed label (`Gap coverage metric:`) occurs.
# Anti-silent-zero (§7): when NO line in the section matches the label at all, but a line still mentions the
# phrase AND carries a ratio, the figure is NOT silently dropped (that would print <none> / let --sync-state
# carry a stale envelope value forward): a typed WARN names the unrecognised line on stderr. A label line that
# EXISTS but carries no ratio (intentionally blank, e.g. document mode) means "metric not set": no WARN, even if
# another line mentions the phrase with a ratio.
COVMETRIC_LABEL_RE='^[[:space:]]*([-*+][[:space:]]+)?\*{0,2}coverage metric\*{0,2}[[:space:]]*(\([^)]*\))?\*{0,2}[[:space:]]*[:=]'  # CM-LABEL-ANCHOR
cov_ratio() {
  local _cr_r _cr_loose _cr_nlab
  _cr_r="$(section '## Coverage' | grep -iE "$COVMETRIC_LABEL_RE" | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
  _cr_nlab="$(section '## Coverage' | grep -ciE "$COVMETRIC_LABEL_RE")"  # CM-LABEL-PRESENT
  if [ -z "$_cr_r" ] && [ "${_cr_nlab:-0}" -eq 0 ]; then
    _cr_loose="$(section '## Coverage' | grep -iE 'coverage metric' | grep -E '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | cut -c1-100)"  # CM-UNRECOGNISED-LABEL
    [ -z "$_cr_loose" ] || printf 'WARN: %s: unrecognised coverage label — a line mentions the coverage metric with a ratio but does not start with the "Coverage metric:" label, so it is NOT read as the metric: %s\n' "$(basename "$state")" "$_cr_loose" >&2
  fi
  printf '%s\n' "$_cr_r"
}

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
#
# Memoized per (ffile, sbase): the default report reads the token once per state file from the campaign block
# AND again from the next-step block, and the awk scan emits its WARNs, so an unmemoized read would print every
# nonconforming-row WARN twice. The token is still computed once, from the same file, by the same logic; only
# the second and later reads within one run are served from the cache.
#
# The cache is an in-process array and the reader is called as a PLAIN statement (never inside `$(...)`), so
# nothing is forked, nothing is written to a shared or world-readable location, and the cache only ever holds
# values this process computed itself. A file-backed cache would be attacker-influenceable (symlink clobber, a
# planted "<key>\tstopped" line forcing a false STOP — a silent zero, CLAUDE.md §7). The next-step `( … )`
# subshell inherits a COPY of the array at fork time, so entries the campaign block populated are hits there.
#
# Requires bash >= 4 (`declare -A`).
# SENTINEL-RFT-HARNESS-BEGIN (the shadowing test extracts exactly the code between BEGIN and END)
declare -A _RSDD_FOC_TOK_CACHE=()  # W2-NO-PROBE-WRITE-ANCHOR
# Every local is prefixed `__rft_` on purpose. `printf -v "$__rft_target"` assigns to a variable NAME the caller
# supplies; if that name equalled one of this function's own locals, `printf -v` would resolve to the local
# (locals shadow) and leave the caller's variable unset or stale. The prefix makes such a collision require a
# call site that deliberately picks a `__rft_`-prefixed name.
_read_focuses_tok_into() {
  local __rft_target="$1" __rft_ffile="$2" __rft_sbase="$3"
  local __rft_cache_key
  __rft_cache_key="${__rft_ffile}$(printf '\x1e')${__rft_sbase}"
  if [ "${_RSDD_FOC_TOK_CACHE[$__rft_cache_key]+_set}" = "_set" ]; then  # W2-DEDUP-CACHE-ANCHOR
    printf -v "$__rft_target" '%s' "${_RSDD_FOC_TOK_CACHE[$__rft_cache_key]}"
    return
  fi
  local __rft_tok
  __rft_tok="$(_read_focuses_tok_uncached "$__rft_ffile" "$__rft_sbase")"
  _RSDD_FOC_TOK_CACHE[$__rft_cache_key]="$__rft_tok"
  printf -v "$__rft_target" '%s' "$__rft_tok"
}

_read_focuses_tok_uncached() {
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
# SENTINEL-RFT-HARNESS-END

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
    [ "$_uf_omit" = 1 ] || printf 'undocumented_findings: %s\n' "$uf"   # UF-NO-INVENT: never seed a manually-maintained 0 into an existing fence
    [ -n "$_extra_env_lines" ] && printf '%s\n' "$_extra_env_lines"  # PREAMBLE-CARRY-FORWARD
    printf '<!-- /research-state.v1 -->'
  }
  # Reassigning the global `state` per iteration is deliberate: section/backlog_rows/blocked_body/env_get all
  # read $state at call time, so each focus derives from its OWN file (single source of truth, same helpers).
  # Scan $target (not $corpus) so split-layout corpora (focuses in sibling subdirectories) are fully seeded;
  # scanning only $corpus=dirname(first) left sibling focuses unseeded — the BLOCKER 2 / WARNING 4 root cause.
  mapfile -t _states < <(list_state_files "$target")
  # When --focus is given, restrict the sync to that single file only (avoids seeding siblings).
  if [ -n "$focus_slug" ] || [ "$root_flag" = 1 ]; then
    if [ "$root_flag" = 1 ]; then _focused="$state"  # ROOT-SYNC-SELECT: the root already resolved (and vetted) at startup
    else
      # rc 0/2 keep the pick (a tie keeps the C-locale-first file); rc 1 prints nothing -> the -f guard below
      # reports the absent message; rc >= 3 is a real resolver error, typed like the startup call sites.
      _focused="$(resolve_state_file "$target" --focus "$focus_slug")"; _sf_rc=$?  # SF-SYNC-FOCUS-PICK
      [ "$_sf_rc" -le 2 ] || { echo "research-sdd-status: state-file resolution failed (rc $_sf_rc)" >&2; exit 1; }
    fi
    if [ ! -f "$_focused" ]; then
      printf 'sync-state: no RESEARCH-STATE%s.md under %s\n' "${focus_slug:+-$focus_slug}" "$target" >&2; exit 1
    fi
    _states=("$_focused")
  fi
  # FIX 2: scope guard — refuse to silently rewrite all siblings when no --focus is given.
  # Multiple RESEARCH-STATE files in a corpus must be targeted one at a time so that per-focus
  # preamble fields are never clobbered by a corpus-wide sweep.
  if [ -z "$focus_slug" ] && [ "$root_flag" != 1 ] && [ "${#_states[@]}" -gt 1 ]; then
    printf 'sync-state: WARN: %d RESEARCH-STATE files found under %s — use --focus <slug> (or --root for the un-suffixed RESEARCH-STATE.md) to target one focus (refusing without explicit scope)\n' \
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
    # kit #906: the un-suffixed root of a MULTI-focus corpus with no block prefix in FOCUSES.md would get the
    # corpus-wide block count — not its own scope. Flag it; the reconciliation below KEEPS a declared value
    # unless covered_blocks is named in --only, and says so.
    _cw=0
    if [ "$(basename "$state")" = "RESEARCH-STATE.md" ] && [ -z "$_sfpfx" ] && [ "$_e_bs" != "shared-global" ] \
       && [ "$(list_state_files "$target" | wc -l | tr -d ' ')" -gt 1 ]; then _cw=1; fi  # ROOT-CORPUS-WIDE
    io="$(count_investigable)"
    bo="$(derive_blocked_open)"   # same disk-derived helper the status display reuses (single source of truth)
    def="$(count_deferred)"
    _ipb="$(backlog_rows 2>/dev/null | inplace_blocked_count "$(blocked_body)")"   # in-place blocked rows (#1915; shared lib/focus-prefix.sh helper, mirrored by verify-state CHECK H): open, in no other bucket — never closed
    # requires_execution_open: compute BEFORE cov/kg so KG-BACKLOG-GC can use dreq.
    # PREFERS the backlog-derived count (rows whose Status carries the `requires-execution` marker →
    # disk-anchored, in lockstep with verify-state.sh's CHECK E) and only falls back to the prose
    # stop-control number / previous envelope when NO row is marked — a marked backlog is
    # authoritative, a prose-only corpus (logosoft) keeps its declared counter.
    dreq="$(count_requires_execution)"
    if [ "$dreq" -gt 0 ]; then
      req="$dreq"
    else
      req="$(pick "$(req_prose)" "$(env_get requires_execution_open)")"
    fi
    # declared-only figures from THIS file's prose (coverage metric X/Y), carrying the previous envelope
    # value when a figure is absent/unparseable (never invent — see pick()).
    cov="$(cov_ratio)"
    # known_gaps: take the larger of the backlog-derived total and the coverage metric Y (issue #568).
    # Backlog-derived: captures newly-added gaps even when the coverage metric prose is stale.
    # Coverage metric Y: preserved when closed gaps are tracked only in the prose and not as backlog rows.
    _dkg="$(count_all_known_gaps)"
    _dkg_total=$(( ${_dkg:-0} + ${def:-0} ))
    _cm_kg="${cov##*/}"
    # KG-LOWER-BOUND (#1307): rows excluded for an undeclared tier make the derived total a LOWER bound. If the
    # envelope already declares a LARGER known_gaps, keep the declared pair instead of clobbering it with the undercount.
    _kg_lb=0; _unc="$(count_uncounted_rows)"; _decl_kg="$(env_get known_gaps)"; _decl_gc="$(env_get gaps_closed)"
    _plain="$(backlog_rows 2>/dev/null | grep -v '^INVALID_PRIORITY' | grep -c . | tr -d ' ')"  # rows the pre-#1307 derivation saw
    [ "${_unc:-0}" -gt 0 ] && printf 'sync-state: WARN: %s: %d backlog row(s) are NOT counted (undeclared tier / malformed row / table without a Priority header) — known_gaps and gaps_closed are LOWER bounds, verify against the prose.\n' \
      "$(basename "$state")" "${_unc}" >&2
    if grep -qE '^[0-9]+$' <<<"${_decl_kg}" && [ "${_decl_kg}" -ge "${_dkg_total}" ] 2>/dev/null; then
      if [ "${_unc:-0}" -gt 0 ]; then
        # KG-LB-UPPER (#1350): the keep is LOUD, never destructive. A declared total above derived + uncounted cannot be explained by the
        # uncounted rows alone, but it is NOT provably stale: it may include closed gaps tracked outside the backlog table (prose, another
        # heading). So it is still kept (propose-never-apply) and the unexplained excess is WARNed for a hand check.
        _kg_lb=1; printf 'sync-state: WARN: %s: keeping the declared known_gaps=%s (derived %d is below it); gaps_closed = max(declared, derived).\n' "$(basename "$state")" "${_decl_kg}" "${_dkg_total}" >&2
        [ "${_decl_kg}" -gt "$(( ${_dkg_total} + ${_unc} ))" ] && printf 'sync-state: WARN: %s: declared known_gaps=%s exceeds what the parser can count (derived %d + %d uncounted) — NOT rewritten; it may include gaps tracked outside the backlog table (prose, other headings) — verify by hand.\n' \
          "$(basename "$state")" "${_decl_kg}" "${_dkg_total}" "${_unc}" >&2
      # B1-NO-UPPER (#1350): this branch keeps WITHOUT an upper bound on purpose: with only closed-class rows and no Coverage metric there is no
      # counted evidence to bound the declared total against, so any declared value is kept (and WARNed below).
      elif [ -z "${_cm_kg}" ] && [ "$(( ${_plain:-0} + ${def:-0} ))" -eq 0 ]; then  # B1: only closed-class rows, no prose metric: nothing proves the declared total shrank
        _kg_lb=1
        printf 'sync-state: WARN: %s: the backlog has only closed-class rows and there is no Coverage metric N/M — derived known_gaps=%d is not evidence the declared total shrank; keeping the declared known_gaps/gaps_closed.\n' \
          "$(basename "$state")" "${_dkg_total}" >&2
      fi
    fi
    if [ "$_kg_lb" = 1 ]; then  # KG-LB-KEEP: assign the DECLARED total explicitly (a stale prose Y must not win); gaps_closed = max(declared, derived) so a real closure is not hidden
      kg="${_decl_kg}"
      warn_inplace_blocked "$(basename "$state")" "${_ipb:-0}"  # INPLACE-BLOCKED-WARN
      _gc_d=$(( ${_dkg_total} - ${io:-0} - ${req:-0} - ${bo:-0} - ${def:-0} - ${_ipb:-0} )); [ "$_gc_d" -lt 0 ] && _gc_d=0
      gc="${_decl_gc}"; grep -qE '^[0-9]+$' <<<"$gc" || gc=0
      [ "$_gc_d" -gt "$gc" ] && gc="$_gc_d"
      [ "$gc" -gt "$kg" ] && gc="$kg"
    fi
    if [ "$_kg_lb" = 0 ] \
       && grep -qE '^[0-9]+$' <<<"${_dkg_total}" \
       && grep -qE '^[0-9]+$' <<<"${_cm_kg:-0}" \
       && [ "${_dkg_total}" -gt "${_cm_kg:-0}" ] 2>/dev/null; then  # KG-BACKLOG-GATE
      kg="${_dkg_total}"  # KG-BACKLOG-EXCEEDS
      # KG-BACKLOG-GC: when kg comes from backlog, gc = closed rows = kg − (io + req + bo + def + in-place blocked).
      # Coverage prose numerator is stale in this path; compute gc from the backlog rows directly.
      _gc_backlog=$(( _dkg_total - ${io:-0} - ${req:-0} - ${bo:-0} - ${def:-0} - ${_ipb:-0} ))  # INPLACE-GC-SUBTRACT
      warn_inplace_blocked "$(basename "$state")" "${_ipb:-0}"  # INPLACE-BLOCKED-WARN
      gc="${_gc_backlog}"  # KG-BACKLOG-GC
      if [ "$gc" -lt 0 ]; then  # GC-CLAMP (kit #983): open buckets can overlap (a requires-execution row also listed blocked)
        # Never write an invented 0 over a DECLARED value: keep the declared gaps_closed (as pick() does); 0 only when none was declared.
        only_has gaps_closed && printf 'sync-state: WARN: %s: derived gaps_closed=%d is negative (known_gaps %d < open buckets io+req+bo+def+in-place-blocked = %d; a row is probably counted in two buckets) — clamp: NOT written, keeping the declared value (0 when none); reconcile the backlog by hand.\n' \
          "$(basename "$state")" "$gc" "${_dkg_total}" "$(( ${io:-0} + ${req:-0} + ${bo:-0} + ${def:-0} + ${_ipb:-0} ))" >&2
        gc="$(pick "" "$(env_get gaps_closed)")"  # GC-CLAMP-KEEP
      fi
      printf 'WARN: Coverage prose denominator is stale (coverage metric %s/%s, backlog has %d known gaps) — update Coverage metric to %d/%d\n' \
        "${cov%%/*}" "${_cm_kg:-?}" "${_dkg_total}" "${gc}" "${kg}" >&2
    elif [ "$_kg_lb" = 1 ]; then
      :  # KG-LB-KEEP above already assigned the declared kg and max(declared, derived) gc
    else
      kg="$(pick "${_cm_kg}" "$(env_get known_gaps)")"
      gc="$(pick "${cov%%/*}" "$(env_get gaps_closed)")"
    fi
    # DECLARED-KEEP (#1637): gaps_closed / known_gaps are DECLARED-only (read from prose, NOT disk-validated —
    # RESEARCH-STATE.template.md). A declared integer ABOVE the derived value is kept and the advisory names both
    # values: the derivation cannot tell a hand-truthful +1 from a stale over-count, so the operator must verify.
    # If the kept pair would leave gaps_closed > known_gaps, neither declared value is kept (DECLARED-PAIR-CHECK).
    # A declared integer at or below the derived value is NOT kept (the derivation is evidence of an undercount;
    # the existing CHANGED line reports the rewrite). Absent or non-integer is not 0: it is seeded from the
    # derivation. --only <name> is the explicit opt-in to write the derived value, so it bypasses the keep.
    if [ "$only_set" = 0 ]; then
      _dk_gc="$gc"; _dk_kg="$kg"; _dk_adv=""
      for _dk_f in gaps_closed known_gaps; do
        _dk_decl="$(env_get "$_dk_f")"
        grep -qE '^[0-9]+$' <<<"${_dk_decl}" || continue
        case "$_dk_f" in gaps_closed) _dk_der="$gc" ;; known_gaps) _dk_der="$kg" ;; esac
        [ "${_dk_decl}" -gt "${_dk_der}" ] || continue  # declared <= derived: the derivation is evidence of an undercount, not a falsification
        case "$_dk_f" in gaps_closed) _dk_gc="${_dk_decl}" ;; known_gaps) _dk_kg="${_dk_decl}" ;; esac
        _dk_adv="${_dk_adv}sync-state: DECLARED ${_dk_f}=${_dk_decl} (derived ${_dk_der}) — kept; verify the declared value or correct it by hand"$'\n'
      done
      # Pair invariant: the per-field decisions are independent, so a kept gaps_closed next to a derived known_gaps can
      # leave gaps_closed > known_gaps. Then NEITHER declared value is kept: the derived pair is written. (The sum
      # identity gc+open buckets = known_gaps stays verify-state CHECK H's WARN; only gc <= kg is enforced here.)
      if [ "$_dk_gc" -gt "$_dk_kg" ] && { [ "$_dk_gc" != "$gc" ] || [ "$_dk_kg" != "$kg" ]; }; then  # DECLARED-PAIR-CHECK
        printf 'sync-state: DECLARED gaps_closed=%s known_gaps=%s inconsistent with derived %s/%s — derived pair written; correct the declaration by hand\n' \
          "$(env_get gaps_closed)" "$(env_get known_gaps)" "$gc" "$kg"
      else
        [ -n "$_dk_adv" ] && printf '%s' "$_dk_adv"  # DECLARED-KEEP-ADVISORY
        gc="$_dk_gc"; kg="$_dk_kg"  # DECLARED-KEEP
      fi
    fi
    # undocumented_findings: distinguish the three cases that pick("","...") collapses into one silent 0.
    # ABSENT       → FIRST seed (no fence): seed 0 (METHODOLOGY §7 seeding contract). Existing fence: the field is
    #                left absent (UF-NO-INVENT, reconciliation block below) — never an invented 0.
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
    # --- declared-vs-derived reconciliation (kit #911) --------------------------------------------
    # Only meaningful when a fence already exists (a first seed declares nothing to compare/preserve).
    # --only keeps every NON-named counter at its DECLARED value (an absent one cannot be preserved, so it
    # is derived); every counter whose final value differs from the declared one is REPORTED, never silent.
    _uf_omit=0; _cw_kept=""
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      _changed_lines=''
      for _cf in $_OWNED_COUNTERS; do
        case "$_cf" in
          covered_blocks) _nv="$cb" ;; gaps_closed) _nv="$gc" ;; known_gaps) _nv="$kg" ;;
          investigable_open) _nv="$io" ;; requires_execution_open) _nv="$req" ;; blocked_open) _nv="$bo" ;;
          deferred_open) _nv="$def" ;; undocumented_findings) _nv="$uf" ;;
        esac
        if _ov="$(env_raw "$_cf")"; then _have=1; else _have=0; fi
        if [ "$_cf" = undocumented_findings ] && [ "$_have" = 0 ]; then _uf_omit=1; continue; fi  # UF-NO-INVENT
        if [ "$only_set" = 1 ] && [ "$_have" = 1 ]; then
          case ",$only_list," in *",$_cf,"*) ;; *) _nv="$_ov" ;; esac   # ONLY-KEEP-DECLARED not named → keep declared value
        fi
        if [ "$_cf" = covered_blocks ] && [ "$_cw" = 1 ] && [ "$_have" = 1 ] && [ "$only_set" = 0 ]; then  # CW-KEEP-DECLARED
          _cw_kept="$_nv"; _nv="$_ov"   # corpus-wide count is not this focus's number: keep what is declared
        fi
        if [ "$_have" = 0 ]; then _ov="(absent)"; fi
        [ "$_ov" = "$_nv" ] || _changed_lines="${_changed_lines}sync-state: CHANGED $(basename "$state") ${_cf}: ${_ov} -> ${_nv}"$'\n'
        case "$_cf" in
          covered_blocks) cb="$_nv" ;; gaps_closed) gc="$_nv" ;; known_gaps) kg="$_nv" ;;
          investigable_open) io="$_nv" ;; requires_execution_open) req="$_nv" ;; blocked_open) bo="$_nv" ;;
          deferred_open) def="$_nv" ;; undocumented_findings) uf="$_nv" ;;
        esac
      done
      [ -n "$_changed_lines" ] && printf '%s' "$_changed_lines"
    fi
    if [ "$_cw" = 1 ] && only_has covered_blocks; then  # ROOT-CORPUS-WIDE-WARN
      if [ -n "$_cw_kept" ]; then
        printf 'sync-state: WARN: %s: covered_blocks would be %s, the CORPUS-WIDE block count (no block prefix for the root focus in FOCUSES.md), not this focus'"'"'s number — KEPT the declared %s; name covered_blocks in --only to write it.\n' \
          "$(basename "$state")" "$_cw_kept" "$cb" >&2
      else
        printf 'sync-state: WARN: %s: covered_blocks=%s written is the CORPUS-WIDE block count (no block prefix for the root focus in FOCUSES.md) — not scoped to this focus; verify it.\n' \
          "$(basename "$state")" "$cb" >&2
      fi
    fi
    repl="$(render_envelope)"
    tmp="$(mktemp "$(dirname "$state")/.rsdd-sync.XXXXXX")"
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      # fence EXISTS → replace ONLY between the markers (idempotent; surrounding prose untouched).
      awk -v repl="$repl" '
        $0 ~ /<!-- research-state.v1 -->/ { print repl; skip=1; next }
        skip && $0 ~ /<!-- \/research-state.v1 -->/ { skip=0; next }
        skip { next }
        { print }' "$state" > "$tmp" || { rm -f "$tmp"; printf 'sync-state: ERROR: %s: rewriting the envelope failed (awk exit) — file NOT modified.\n' "$state" >&2; exit 1; }  # AWK-CHECK
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
        END { if (!done) { print ""; print repl } }' "$state" > "$tmp" || { rm -f "$tmp"; printf 'sync-state: ERROR: %s: rewriting the envelope failed (awk exit) — file NOT modified.\n' "$state" >&2; exit 1; }  # AWK-CHECK
    fi
    mv "$tmp" "$state"
    echo "sync-state: wrote $state"
    echo "sync-state: $(basename "$state") → covered_blocks=$cb gaps_closed=$gc known_gaps=$kg investigable_open=$io requires_execution_open=$req blocked_open=$bo deferred_open=$def undocumented_findings=$([ "$_uf_omit" = 1 ] && echo - || echo "$uf")"
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
        elif grep -qE '^degraded:' <<<"$_ri_err_content"; then
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
      # kit issue #1130 finding 1: reconcile-issues.sh's out-of-scope-marker guard now exits 0
      # (a corpus finding — the retro's own marker is mispositioned — not an operational failure
      # of the instrument, per CLAUDE.md §8). But rc=0 with zero ^untracked: lines would
      # otherwise fall through to the clean count below and read as "verified clean" — the exact
      # silent-zero shape §7 forbids, since this retro's rows were never actually classified.
      # Treat it as unverified coverage, the same bucket as an operational failure.
      if grep -qE '^out-of-scope-marker:' <<<"$_ri_err_content"; then
        _idg_had_unverified=1  # IDG-OOS-SENTINEL
        printf 'WARN: reconcile-issues.sh reported an out-of-scope review-status marker for %s — treating as unverified\n' \
          "$(basename "$_idg_retro")" >&2
        continue
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
          elif grep -qE '^degraded:' <<<"$_ri_err_content"; then
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
    terminal_clean_warn  # TC-WARN-CALL-UNVERIFIED
    return
  fi
  # no-match: retros exist, all deltas tracked (or empty retros with clean find) → verified-clean STOP
  _stop_exhausted
  terminal_clean_warn  # TC-WARN-CALL
}

if [ "$mode" = "--next" ]; then
  # kit issue #1837: the state file the --root / --focus picker chose. The STALE-bypass loop below reassigns the
  # global $state (count_investigable / env_get read it), so a scoped --next must read THIS copy, never $state.
  _ns_pick="$state"  # NEXT-PICK-SAVE
  # Refuse to hand out work on an internally inconsistent state (summary claims done while backlog
  # lists pending — verify-state.sh exits 1 on that). An agent trusting --next alone must reconcile first.
  # Use $target (not $corpus) so the STALE gate covers the same scope as the aggregation below: scanning
  # only $corpus=dirname(first) would miss sibling focuses in a split-layout and give a false green light.
  # kit #1543: with --focus <slug> the STALE gate verifies ONLY that focus (a legacy sibling's defects
  # must not brick a clean active focus). Without --focus (the default) or with --all it stays
  # corpus-wide, exactly as before.
  _gate_verify() {
    if [ -n "$focus_slug" ]; then "$here/verify-state.sh" "$target" --focus "$focus_slug" >/dev/null 2>&1
    else "$here/verify-state.sh" "$target" >/dev/null 2>&1; fi
  }
  # _stale_line: the STALE line. In a MULTI-focus corpus (corpus-wide mode) it also names the focus(es)
  # whose own verify-state fails, so the operator sees WHICH legacy focus bricks --next (kit #1543).
  # EVERY STALE line (single-focus, --focus, multi-focus) ends with `[first failure: <file>: <check>]` (kit #1544,
  # below); only the `[failing focus: …]` segment is multi-focus-only. The pre-#1543 prefix is unchanged.
  # kit #1544: the line also carries the FIRST failing verify-state check and the file it belongs to
  # (`[first failure: <file>: <check>]`), so the operator need not re-run the full report to find it.
  # _first_failure <verify-state args...>: first `   FAIL   ` line, prefixed by the `== verify-state: <file> (`
  # header it sits under. A FAIL line ending in ':' (e.g. "...found:") also carries the value line that follows.
  # Truncated to ~160 BYTES on a character boundary (LC_ALL=C awk + continuation-byte back-off, so mawk and
  # gawk agree and a multibyte char is never split). §7: when verify-state printed NO FAIL line (helper missing,
  # degraded, crash — its stderr is dropped) the pointer is the typed `unavailable — … (rc=N)`, never omitted.
  _first_failure() {
    local _ff_out _ff_rc=0 _ff_line
    _ff_out="$("$here/verify-state.sh" "$@" 2>/dev/null)" || _ff_rc=$?
    _ff_line="$(LC_ALL=C awk '
      function emit(  n) {
        n=157
        if (length(c)>160) { while (n>0 && substr(c,n+1,1) ~ /[\200-\277]/) n--; c=substr(c,1,n) "..." }
        print (f==""?"?":f) ": " c; done=1; exit
      }
      /^== verify-state: / { f=$0; sub(/^== verify-state: /,"",f); sub(/ \(target: .*$/,"",f); next }
      pend { v=$0; sub(/^[ \t]+/,"",v); c=c " " v; emit() }
      /^   FAIL   / { c=$0; sub(/^   FAIL   /,"",c); if (c ~ /:$/) { pend=1; next } emit() }
      END { if (!done && pend) emit() }
    ' <<<"$_ff_out")"  # STALE-FIRST-FAILURE
    if [ -n "$_ff_line" ]; then printf '%s' "$_ff_line"
    else printf 'unavailable — verify-state printed no FAIL line (rc=%s)' "$_ff_rc"; fi
  }
  _stale_line() {
    local _sl_line="STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
    local _sl_files _sl_f _sl_b _sl_names="" _sl_first="" _sl_ff=""
    mapfile -t _sl_files < <(list_state_files "$target")
    if [ "${#_sl_files[@]}" -ge 2 ] && [ -z "$focus_slug" ]; then
      for _sl_f in "${_sl_files[@]}"; do
        _sl_b="$(basename "$_sl_f" .md)"
        case "$_sl_b" in RESEARCH-STATE-?*) _sl_b="${_sl_b#RESEARCH-STATE-}" ;; *) continue ;; esac
        "$here/verify-state.sh" "$target" --focus "$_sl_b" >/dev/null 2>&1 || { _sl_names="${_sl_names:+$_sl_names,}$_sl_b"; [ -n "$_sl_first" ] || _sl_first="$_sl_b"; }
      done
      [ -n "$_sl_names" ] && _sl_line="$_sl_line [failing focus: $_sl_names]"
      # no focus file fails on its own (a stale ROOT RESEARCH-STATE.md, or a corpus-wide-only check): fall back
      # to the corpus-wide run so the pointer is still named instead of silently dropped.
      if [ -n "$_sl_first" ]; then _sl_ff="$(_first_failure "$target" --focus "$_sl_first")"
      else _sl_ff="$(_first_failure "$target")"; fi  # STALE-ROOT-FALLBACK
    elif [ -n "$focus_slug" ]; then
      _sl_ff="$(_first_failure "$target" --focus "$focus_slug")"
    else
      _sl_ff="$(_first_failure "$target")"
    fi
    [ -n "$_sl_ff" ] && _sl_line="$_sl_line [first failure: $_sl_ff]"
    printf '%s\n' "$_sl_line"
  }
  if ! _gate_verify; then
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
        _stale_line
        exit 0
      fi
      for state in "${_stale_chk[@]}"; do
        # FOCUSES.md check FIRST (issue #641): a stopped/paused focus with malformed priority must be
        # skipped before the INVALID_PRIORITY guard fires, or its unparseable backlog bricks the corpus.
        # Extends N194-STOPPED-BYPASS to also cover stopped focuses whose priority column is unknown.
        # The INVALID_PRIORITY guard below is therefore only reached for ACTIVE focuses.  # N194-FOCUSES-SKIP  # N641-FOCUSES-BEFORE-INVALID-PRIORITY
        _sfoc_file="$(dirname "$state")/FOCUSES.md"
        _read_focuses_tok_into _sfoc_tok "$_sfoc_file" "$(basename "$state")"
        # shellcheck disable=SC2154 # _sfoc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
        if [ "$_sfoc_tok" = "stopped" ] || [ "$_sfoc_tok" = "paused" ]; then
          continue
        fi
        # Unparseable backlog is a real failure for ACTIVE focuses (concealment hazard, BP-INVALID-PRIORITY-FAIL).
        if grep -q '^INVALID_PRIORITY' < <(backlog_rows 2>/dev/null); then
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
             && grep -qE '^[0-9]+$' <<<"${_e_gc}${_e_kg}" \
             && [ "${_e_kg}" -gt 0 ] 2>/dev/null \
             && [ "${_e_gc}" = "${_e_kg}" ]; then
            _any_real_stale=1; break
          fi
        fi
        # d_inv=0 + parseable: genuinely stopped focus — its stale envelope is bypassed (#194).
      done
      if [ "${_any_real_stale}" = 1 ]; then
        _stale_line
        exit 0
      fi
      # All verify-state failures are from stopped focuses — fall through to aggregation.
    else
      _stale_line
      exit 0
    fi
  fi
  # RETRO-DUE (§18 cadence): after STALE passes, check for blocks_since_retro > 10.
  # Check the relevant state file(s): just $state for single-focus, all active files for multi-focus.
  # Emits RETRO-DUE and exits before NEXT/STOP so the cadence advisory reaches the caller.  # RD-BLOCKS-SINCE-RETRO-CHECK
  # kit issue #1837: --root and --focus both PICK one state file ($state, resolved above); --next then reports from
  # that file alone. The no-flag form (and --all, which excludes both flags) keeps the corpus-wide aggregate.
  _ns_scoped=0  # NEXT-SCOPE-DEFAULT
  [ -n "$focus_slug" ] && _ns_scoped=1  # NEXT-FOCUS-SCOPE
  [ "$root_flag" = 1 ] && _ns_scoped=1  # NEXT-ROOT-SCOPE
  _rd_threshold=10
  if [ "$_ns_scoped" = 1 ]; then
    # The RETRO-DUE loop below leaves the global $state on this file, which is what resolve_next reads afterwards.
    _rd_states=("$_ns_pick")  # NEXT-PICK-RD
  else
    mapfile -t _rd_states < <(list_state_files "$target")
  fi
  for state in "${_rd_states[@]}"; do
    _rd_foc_file="$(dirname "$state")/FOCUSES.md"
    _read_focuses_tok_into _rd_foc_tok "$_rd_foc_file" "$(basename "$state")"
    # shellcheck disable=SC2154 # _rd_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
    if [ "$_rd_foc_tok" = "stopped" ] || [ "$_rd_foc_tok" = "paused" ]; then continue; fi
    _rd_bsr="$(env_get blocks_since_retro)"
    if grep -qE '^[0-9]+$' <<<"$_rd_bsr" && [ "$_rd_bsr" -gt "$_rd_threshold" ]; then  # RD-THRESHOLD-CHECK
      echo "RETRO-DUE | ${_rd_bsr} blocks since last retro (§18 threshold: ${_rd_threshold})"
      exit 0
    fi
  done
  if [ "$_ns_scoped" = 0 ]; then
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
      _read_focuses_tok_into _nxt_foc_tok "$_nxt_foc_file" "$(basename "$state")"  # N194-FOCUSES-SKIP
      # shellcheck disable=SC2154 # _nxt_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
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

# --- §8c campaign queue helpers ----------------------------------------------------------------

# _CQ_COMMENT_SKIP_AWK: shared HTML-comment-skip state machine body, textually shared by
# campaign_section() and campaign_queue_present() (R2 round 3: this used to be hand-duplicated in
# each function — a fix to one could silently drift from the other, and a mutation anchor only ever
# covered whichever copy it happened to sit in). Defined ONCE as a bash string and interpolated into
# both awk programs below, so there is exactly one physical copy of this logic in the source file,
# and a single sed-targeted mutation against it exercises both callers.
#
# The template wraps its own "## Campaign queue" section in <!-- ... --> as a "do-not-pre-create"
# note; real RESEARCH-STATE files do NOT have HTML comments, so we must skip them when they appear
# (e.g. if someone copies from the template literally).
#
# R3-comment-skip-overreach (round 1): comment markers only count at the START of a line (optionally
# after whitespace) — matching how the template actually writes them. A table row's Seed/Convergence
# cell may legitimately contain a literal "-->" or an unclosed "<!--"; since a table row always starts
# with "|", it never matches these start-anchored patterns, so such a cell can no longer falsely
# open/close comment mode and drop or hide rows.
#
# R3/B2-comment-trailing-text (round 2): round 1's closing check required "-->" to be the LAST thing
# on the line (`/-->[[:space:]]*$/`), so a real closing line with trailing prose — the retro/audit
# templates' own `<!-- review-status: pending --> see note` shape, or `line --> (end)` — never closed
# the comment, silently swallowing every row after it (pending=1 became "campaign: none"). The state
# machine below closes on "-->" ANYWHERE once inside a comment, and only ENTERS multi-line comment
# mode when the opening line does NOT also contain a closing "-->" (so a genuine one-line comment like
# `<!-- a -> b -->` — broken before this PR too, since `[^>]*` could not cross the embedded ">" in
# "->" — is consumed whole without ever setting in_c).
_CQ_COMMENT_SKIP_AWK='
      if (in_c) {
        if ($0 ~ /-->/) { in_c = 0 }  # CQ-COMMENT-CLOSE-ANCHOR — closes on --> ANYWHERE, not just at EOL
        next
      }
      if ($0 ~ /^[[:space:]]*<!--/) {  # CQ-COMMENT-OPEN-STARTANCHOR — only a LINE-START <!-- opens a comment
        if ($0 !~ /-->/) { in_c = 1 }  # CQ-COMMENT-OPEN-ANCHOR — only multi-line when not also closed here
        next
      }
'

# campaign_section: body of "## Campaign queue", skipping HTML comment blocks (shared state machine
# above). A file that ends while still inside a comment WARNs loudly instead of silently discarding
# the rest of the section (anti-silent-zero, kit §7).
campaign_section() {
  awk '
    {
'"$_CQ_COMMENT_SKIP_AWK"'
      if (index($0, "## Campaign queue") == 1) { f = 1; next }
      if ($0 ~ /^## /) { f = 0 }
      if (f) print
    }
    END {
      if (in_c) print "WARN: campaign queue: file ends while still inside an HTML comment (unclosed <!--)" > "/dev/stderr"  # CQ-COMMENT-EOF-WARN-ANCHOR
    }
  ' "$state"
}

# campaign_queue_present: exits 0 when ## Campaign queue exists outside HTML comments. Same
# comment-detection state machine as campaign_section() — literally the same shared string, not a
# hand-copied twin (R2 round 3).
campaign_queue_present() {
  awk '
    {
'"$_CQ_COMMENT_SKIP_AWK"'
      if (index($0, "## Campaign queue") == 1) { found = 1; exit }
    }
    END { exit !found }
  ' "$state"
}

# _campaign_age_min <ISO8601-ts>: prints age in minutes as integer, or "unknown" on parse fail.
# Respects _RSDD_NOW_EPOCH test-hook (injected by tests for deterministic stall computation).
#
# R3/R4 bsd-date-tz + bsd-date-utc-skew: on hosts without GNU `date -d`, the BSD/macOS fallback
# `date -j -f "%Y-%m-%dT%H:%M:%SZ" ...` treats the trailing Z as a literal character, not a UTC
# marker, so without an explicit TZ it parses the timestamp as LOCAL wall-clock time — the computed
# age is then off by the host's UTC offset (negative west of UTC, inflated east of UTC). Forcing
# TZ=UTC on that call makes it interpret the (already-UTC) fields correctly regardless of the host's
# local timezone, matching what GNU `date -d` already does for a Z-suffixed timestamp.
#
# A resulting negative or otherwise unparseable age is never printed as a raw number — every
# downstream numeric guard is `^[0-9]+$`, so a silent negative would just look like "no stall" with
# no indication anything was wrong. Report it loudly instead: WARN to stderr and return "unknown".
_campaign_age_min() {
  local ts="$1" ts_epoch now_epoch age
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null) \
    || ts_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) || true
  if [ -z "$ts_epoch" ] || ! grep -qE '^-?[0-9]+$' <<<"$ts_epoch"; then
    printf 'unknown'
    return
  fi
  now_epoch="${_RSDD_NOW_EPOCH:-$(date +%s)}"
  age=$(( (now_epoch - ts_epoch) / 60 ))
  if [ "$age" -lt 0 ]; then  # CQ-NEG-AGE-ANCHOR
    printf 'WARN: campaign: last_iteration_ts %s is in the future relative to now (age %d min) — reporting unknown\n' \
      "$ts" "$age" >&2
    printf 'unknown'
    return
  fi
  printf '%s' "$age"
}

# _campaign_row_counts <warn-label> <section-text>: reads <section-text> (campaign_section()'s
# output, passed in rather than re-fetched — R2-002: avoid re-running campaign_section() once per
# field, which would also re-emit its unclosed-comment WARN once per field) table rows and prints
# "pending active done bound-stopped rejected row_count" (six space-separated integers) on stdout.
# WARNs to stderr for a malformed Kind/State or an empty table; warn-label (e.g. " [beta]") is
# appended to each WARN so a multi-focus WARN is attributable to the right focus.
_campaign_row_counts() {
  local _wlabel="${1:-}" _section="${2:-}"
  local n_cq_pending=0 n_cq_active=0 n_cq_done=0 n_cq_bstopped=0 n_cq_rejected=0
  local _cq_row_count=0
  local _row_name _row_kind _row_state
  while IFS='|' read -r _ _row_name _ _row_kind _ _ _row_state _; do
    _row_name="${_row_name#"${_row_name%%[! ]*}"}" ; _row_name="${_row_name%"${_row_name##*[! ]}"}"
    _row_kind="${_row_kind#"${_row_kind%%[! ]*}"}" ; _row_kind="${_row_kind%"${_row_kind##*[! ]}"}"
    _row_state="${_row_state#"${_row_state%%[! ]*}"}" ; _row_state="${_row_state%"${_row_state##*[! ]}"}"
    [ "$_row_kind" = "Kind" ] && continue                              # header row
    grep -qE '^-+$' <<<"$_row_kind" && continue            # separator row
    [ -z "$_row_name" ] && continue                                    # truly empty line
    _cq_row_count=$(( _cq_row_count + 1 ))
    # Validate Kind vocabulary: focus | tier | sub-topic
    case "$_row_kind" in
      focus|tier|sub-topic) ;;
      *) printf 'WARN: campaign queue%s: unrecognised Kind '\''%s'\'' in row %s\n' \
           "$_wlabel" "$_row_kind" "$_row_name" >&2 ;;
    esac
    # Count and validate State vocabulary  # CQ-COUNT-PENDING-ANCHOR
    case "$_row_state" in
      pending)       n_cq_pending=$(( n_cq_pending + 1 )) ;;  # CQ-COUNT-PENDING-ANCHOR
      active)        n_cq_active=$(( n_cq_active + 1 )) ;;
      done)          n_cq_done=$(( n_cq_done + 1 )) ;;
      bound-stopped) n_cq_bstopped=$(( n_cq_bstopped + 1 )) ;;
      rejected)      n_cq_rejected=$(( n_cq_rejected + 1 )) ;;
      *) printf 'WARN: campaign queue%s: unrecognised State '\''%s'\'' in row %s\n' \
           "$_wlabel" "$_row_state" "$_row_name" >&2 ;;
    esac
  done < <(printf '%s\n' "$_section" | grep '^|')

  if [ "$_cq_row_count" -eq 0 ]; then
    printf 'WARN: campaign queue table present but empty%s\n' "$_wlabel" >&2
  fi

  printf '%d %d %d %d %d %d\n' \
    "$n_cq_pending" "$n_cq_active" "$n_cq_done" "$n_cq_bstopped" "$n_cq_rejected" "$_cq_row_count"
}

# _campaign_stop_text <pending> <active> <last_audit> <section-text>: prints the campaign_stop text
# (an explicit campaign_stop: field in <section-text>, or the computed STOP condition), or nothing
# when neither applies. Factored out so campaign_status_block can decide per-focus AND aggregate STOP
# correctly (R4-campaign-block-first-focus-only) instead of only ever looking at one focus.
# <section-text> is passed in rather than re-fetched — see _campaign_row_counts above (R2-002).
_campaign_stop_text() {
  local _p="$1" _a="$2" _la="$3" _section="${4:-}" _field
  _field="$(grep -m1 '^campaign_stop:' <<<"$_section" | sed 's/^campaign_stop:[[:space:]]*//')"
  if [ -n "$_field" ]; then
    printf '%s' "$_field"
    return
  fi
  if [ "$_p" -eq 0 ] && [ "$_a" -eq 0 ] && [ -n "$_la" ]; then
    # STOP condition: all entries terminal AND last_audit enqueued=0 (absent last_audit never satisfies)
    local _enq
    _enq="$(printf '%s' "$_la" | grep -oE 'enqueued=[0-9]+' | grep -oE '[0-9]+')"
    [ "${_enq:-}" = "0" ] && printf 'STOP reached — all entries terminal, last_audit enqueued=0'
  fi
}

# campaign_status_block: emit §8c campaign queue lines in the default status report.
#
# R4-campaign-block-first-focus-only (round 1): the original implementation read only the single
# alphabetically-first $state, so in a multi-focus target the queue counts, campaign_stop and the
# stall warning described only that one focus. This mirrors the fix already applied to the "next
# step" block below: iterate every focus, skip only the ones FOCUSES.md declares stopped/paused, and
# never let one focus's terminal state stand in for the whole campaign.
#
# B1 (round 2): when --focus <slug> narrows the report to one focus, the campaign block must report
# exactly that focus — never siblings, and never skip it even when FOCUSES.md declares it stopped or
# paused (that skip exists to keep a MULTI-focus scan from being misled by a terminal sibling; it does
# not apply when the caller explicitly asked for this one focus).
#
# W1 (round 2): a target where NO active focus has started a campaign yet used to print one "none"
# line PER focus (62 lines on a 30-focus corpus). Collapsed to a single summary line, and per-focus
# lines are now printed only for focuses that actually have a queue.
campaign_status_block() {
  local -a _cqb_states=()
  # B1/RDD: shadow the caller's global $state so the loops below never leak their reassignments out
  # to it — but COPY the caller's current value in first ("local state=$state"), not a bare "local
  # state": under `set -u`, a bare local declaration starts unset, and $focus_slug's already-resolved
  # $state (needed immediately below) would then read as an unbound-variable error.
  local state="$state"
  if [ -n "$focus_slug" ]; then  # B1-FOCUS-STATES-ANCHOR
    _cqb_states=("$state")
  else
    mapfile -t _cqb_states < <(list_state_files "$target")
  fi

  local -a _cqb_active=()
  local _cqb_skip=0 _cqb_st _cqb_foc_file _cqb_foc_tok
  if [ -n "$focus_slug" ]; then  # B1-FOCUS-ACTIVE-ANCHOR
    _cqb_active=("${_cqb_states[0]}")
  else
    for _cqb_st in "${_cqb_states[@]}"; do
      _cqb_foc_file="$(dirname "$_cqb_st")/FOCUSES.md"
      _read_focuses_tok_into _cqb_foc_tok "$_cqb_foc_file" "$(basename "$_cqb_st")"
      if [ "$_cqb_foc_tok" = "stopped" ] || [ "$_cqb_foc_tok" = "paused" ]; then
        _cqb_skip=$(( _cqb_skip + 1 ))
        continue
      fi
      _cqb_active+=("$_cqb_st")
    done
  fi
  # CQB-MULTIFOCUS-ANCHOR (R4-campaign-block-first-focus-only: every active focus is evaluated below,
  # not just the alphabetically-first one)

  if [ "${#_cqb_active[@]}" -eq 0 ]; then
    printf '  %-16s: no active focus (%d declared stopped/paused in FOCUSES.md)\n' "campaign" "$_cqb_skip"
    return
  fi

  # --- pass 1: which active focuses actually have a queue? (W1 collapse decision.) ---
  local -a _cqb_queue_states=()
  for state in "${_cqb_active[@]}"; do
    campaign_queue_present && _cqb_queue_states+=("$state")
  done
  local _cqb_n_active="${#_cqb_active[@]}" _cqb_n_queue="${#_cqb_queue_states[@]}"

  if [ "$_cqb_n_queue" -eq 0 ]; then  # W1-COLLAPSE-ANCHOR
    # R2-misleading-preserve-contract-comment (round 3): "focus" is singular when there is exactly
    # one active focus — nave-panccadia (a genuine single-focus corpus) was printing the grammatically
    # wrong "1 active focuses, 0 with a queue" before this.
    local _cqb_focus_word="focuses"
    [ "$_cqb_n_active" -eq 1 ] && _cqb_focus_word="focus"
    printf '  %-16s: none (%d active %s, 0 with a queue)\n' "campaign" "$_cqb_n_active" "$_cqb_focus_word"  # CQ-NONE-ANCHOR
    if [ "$_cqb_n_active" -eq 1 ]; then
      # Single-focus corpus, no campaign started: still prints the original two-line SHAPE (a
      # campaign-status line followed by a last_iteration_ts line) rather than dropping the ts line
      # entirely — it does NOT preserve the original line's exact TEXT, which is the point of this
      # branch (round 3: the previous wording here claimed to "preserve the original two-line
      # contract", which overclaimed byte-for-byte sameness the collapsed line never had).
      local _cqb_ts
      state="${_cqb_active[0]}"
      _cqb_ts="$(env_get last_iteration_ts)"
      if [ -z "$_cqb_ts" ]; then
        printf '  %-16s: absent\n' "last_iteration_ts"
      else
        printf '  %-16s: %s  (age: %s min)\n' "last_iteration_ts" "$_cqb_ts" "$(_campaign_age_min "$_cqb_ts")"
      fi
    fi
    return
  fi

  # Labelling and STOP-aggregation are both keyed on the QUEUE-BEARING count, not the total active
  # count: a focus with no queue at all was never "terminal" in any meaningful sense, so it must not
  # inflate the denominator in "all N ... terminal" (W3) or force labels when only one focus is ever
  # actually reported (a no-queue sibling produces no output at all — W1).
  local _cqb_multi=0
  [ "$_cqb_n_queue" -gt 1 ] && _cqb_multi=1

  local _cqb_slug _cqb_flabel _cqb_wlabel _ts _ts_age_min _cqb_section
  local _cqb_all_stopped=1
  local _p _a _d _b _r _rows _stop_txt _la
  local _cq_bounds_field _bd_token _bd_key _bd_val

  for state in "${_cqb_queue_states[@]}"; do
    _cqb_slug="$(basename "$state" .md)"; _cqb_slug="${_cqb_slug#RESEARCH-STATE-}"
    _cqb_flabel=""; _cqb_wlabel=""
    if [ "$_cqb_multi" -eq 1 ]; then
      _cqb_flabel="[$_cqb_slug]"
      _cqb_wlabel=" [$_cqb_slug]"
    fi

    _ts="$(env_get last_iteration_ts)"
    _cqb_section="$(campaign_section)"

    read -r _p _a _d _b _r _rows < <(_campaign_row_counts "$_cqb_wlabel" "$_cqb_section")
    printf '  %-16s: pending=%d active=%d done=%d bound-stopped=%d rejected=%d\n' \
      "campaign${_cqb_flabel}" "$_p" "$_a" "$_d" "$_b" "$_r"

    # --- last_audit ---
    _la="$(grep -m1 '^last_audit:' <<<"$_cqb_section" | sed 's/^last_audit:[[:space:]]*//')"
    if [ -n "$_la" ]; then
      printf '  %-16s: %s\n' "last_audit${_cqb_flabel}" "$_la"
    else
      printf '  %-16s: not yet audited\n' "last_audit${_cqb_flabel}"
    fi

    # --- campaign_stop field or computed STOP condition, per focus ---
    _stop_txt="$(_campaign_stop_text "$_p" "$_a" "$_la" "$_cqb_section")"
    if [ -n "$_stop_txt" ]; then
      printf '  %-16s: %s\n' "campaign_stop${_cqb_flabel}" "$_stop_txt"
    else
      _cqb_all_stopped=0
    fi

    # --- campaign_bounds ---
    _cq_bounds_field="$(grep -m1 '^campaign_bounds:' <<<"$_cqb_section" | sed 's/^campaign_bounds:[[:space:]]*//')"
    if [ -n "$_cq_bounds_field" ]; then
      printf '  %-16s: %s\n' "campaign_bounds${_cqb_flabel}" "$_cq_bounds_field"
      # Validate each key=value token
      while IFS= read -r _bd_token; do
        [ -z "$_bd_token" ] && continue
        _bd_key="$(printf '%s' "$_bd_token" | cut -d= -f1)"
        _bd_val="$(printf '%s' "$_bd_token" | cut -d= -f2-)"
        case "$_bd_key" in
          max-depth|iterations)
            grep -qE '^[0-9]+$' <<<"$_bd_val" \
              || printf 'WARN: campaign_bounds%s: bad %s value '\''%s'\''\n' "$_cqb_wlabel" "$_bd_key" "$_bd_val" >&2 ;;
          wall-clock)
            grep -qE '^[0-9]+(\.[0-9]+)?h$' <<<"$_bd_val" \
              || printf 'WARN: campaign_bounds%s: bad wall-clock value '\''%s'\''\n' "$_cqb_wlabel" "$_bd_val" >&2 ;;
          *)
            printf 'WARN: campaign_bounds%s: unknown key '\''%s'\''\n' "$_cqb_wlabel" "$_bd_key" >&2 ;;
        esac
      done < <(printf '%s\n' "$_cq_bounds_field" | tr ' ' '\n')
    fi

    # --- last_iteration_ts with age; stall WARN when THIS focus's campaign is active/pending ---
    if [ -z "$_ts" ]; then
      printf '  %-16s: absent\n' "last_iteration_ts${_cqb_flabel}"
    else
      _ts_age_min="$(_campaign_age_min "$_ts")"
      printf '  %-16s: %s  (age: %s min)\n' "last_iteration_ts${_cqb_flabel}" "$_ts" "$_ts_age_min"
      if [ "$_p" -gt 0 ] || [ "$_a" -gt 0 ]; then
        if grep -qE '^[0-9]+$' <<<"$_ts_age_min" && [ "$_ts_age_min" -gt "$stall_minutes" ]; then
          printf 'WARN: campaign stall%s — last_iteration_ts age %s min exceeds threshold %s min\n' "$_cqb_wlabel" "$_ts_age_min" "$stall_minutes" >&2  # CQ-STALL-WARN-ANCHOR
          :  # noop — keeps then-block non-empty after stall-anchor mutation
        fi
      fi
    fi
  done

  # Aggregate STOP: only when EVERY queue-bearing focus independently reached its own STOP condition
  # — never just the first one (R4-campaign-block-first-focus-only). W3: the count in the message is
  # the QUEUE-BEARING count (_cqb_n_queue), never the total active count — a no-queue sibling was
  # never "terminal" and must not be folded into "all N ... terminal".
  if [ "$_cqb_multi" -eq 1 ] && [ "$_cqb_all_stopped" -eq 1 ]; then
    printf '  %-16s: STOP reached — all %d queue-bearing focuses terminal\n' "campaign_stop" "$_cqb_n_queue"  # W3-WORDING-ANCHOR
  fi
}

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
      line = $0; gsub(/\\\|/, "\001", line)
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

# --- default: structured status report ---------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"
metric="$(cov_ratio)"
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
_chk_abs="$(CDPATH="" cd -- "$target" 2>/dev/null && pwd)"  # kit #1150 item 1: name the directory the wiring was checked at
echo "  Stop hook       : $(hook_stop_wiring_state "$target") (checked: ${_chk_abs:-$target})"
echo "  coverage metric : ${metric:-<none>}"
echo "  covered blocks  : ${covered:-<none>} claimed · ${ondisk} on disk"
echo "  pending backlog : $ph"
echo "  stop-control    : investigable=${inv:-?} · requires-execution=${req:-?} · blocked=${blk:-?}"
_rt="$(count_retyped_in_table)"
[ "${_rt:-0}" -gt 0 ] && echo "  re-typed in table : ${_rt} — row(s) carry the literal 're-typed' Status — use 'blocked (requires-<what>)' (METHODOLOGY §8b); counted in no bucket"  # RETYPED-VISIBLE (#1638)
if [ "$_doc_mode" = 1 ]; then outline_summary; outline_line
elif [ "$_doc_noheading" = 1 ]; then echo "  outline         : (no ## Outline section — gap-centric verdicts kept)"; fi
mapfile -t ledgers < <(contra_ledgers)
if [ "${#ledgers[@]}" -eq 0 ]; then
  echo "  contradictions  : (no ledger)"
else
  [ "${#ledgers[@]}" -gt 1 ] && echo "WARN: multiple CONTRADICTIONS*.md ledgers under $corpus — counting all ${#ledgers[@]}" >&2
  nopen="$(count_open_contra "${ledgers[@]}")"
  [ "$nopen" -gt 0 ] && echo "  contradictions  : ${nopen} open" || echo "  contradictions  : (none)"
fi
# remote_visibility_block — read back each git remote's visibility (kit issue #1245). ensure-remote.sh
# verifies PRIVATE only at creation and short-circuits on an existing origin, so a remote made PUBLIC later
# is invisible without this. Surfaces the state; NEVER flips it (visibility is the owner's decision).
#   PUBLIC             -> `WARN public-remote: <remote> ...` (stdout, part of the report)
#   PRIVATE / INTERNAL -> silent;  no .git or no remote -> silent (nothing to read back)
#   gh absent / failing / empty or unrecognised answer -> typed `degraded: remote-visibility: ...`
#   (§7: a read-back that could not run is never a silent pass).
# RSDD_GH_BIN overrides the gh binary (tests stub it; no network). Only the remote NAME is printed and
# only OWNER/REPO reaches gh's argv: a remote URL may embed credentials. Empty / non-github URL,
# or a gh call over RSDD_GH_TIMEOUT seconds (default 10 here, 20 in the shared lib/gh-visibility.sh; later remotes are skipped after the first timeout; GH_PROMPT_DISABLED=1) -> typed degraded.
remote_visibility_block() {
  [ -e "$target/.git" ] || return 0
  local _rv_gh="${RSDD_GH_BIN:-gh}" _rv_arr=() _rv_r _rv_url _rv_slug _rv_vis _rv_stalled=0
  command -v git >/dev/null 2>&1 || { _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: git not found — cannot read the remotes of $target"; return 0; }
  mapfile -t _rv_arr < <(git -C "$target" remote 2>/dev/null)
  [ "${#_rv_arr[@]}" -gt 0 ] || return 0
  # Remotes are enumerated BEFORE the lib check (kit issue #1843): a target with no remote needs no probe, so a
  # missing lib/gh-visibility.sh is only worth a degraded line when there is something to probe.
  # shellcheck source=lib/gh-visibility.sh
  . "$here/lib/gh-visibility.sh" 2>/dev/null && declare -F gh_visibility_probe >/dev/null 2>&1 \
    || { _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: lib/gh-visibility.sh unavailable — cannot probe the visibility of the remotes of $target"; return 0; }
  for _rv_r in "${_rv_arr[@]}"; do
    [ -n "$_rv_r" ] || continue
    if ! command -v "$_rv_gh" >/dev/null 2>&1; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh not found — cannot verify the visibility of remote $_rv_r"; continue
    fi
    _rv_url="$(git -C "$target" remote get-url "$_rv_r" 2>/dev/null)" || _rv_url=""
    if [ -z "$_rv_url" ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: $_rv_r url empty or unreadable — visibility unverified"; continue
    fi
    # Reduce the URL to OWNER/REPO (scheme + userinfo + host stripped) so no credential reaches gh's argv;
    # anything that is not a github.com owner/repo is never handed to gh (it could resolve the cwd repo).
    _rv_slug=""
    if [[ "$_rv_url" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)?([^/]*@)?github\.com[:/]+([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_.-]+)/?$ ]]; then
      _rv_slug="${BASH_REMATCH[3]}/${BASH_REMATCH[4]%.git}"
    fi
    if [ -z "$_rv_slug" ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: $_rv_r not a github owner/repo — visibility unverified"; continue
    fi
    # The bounded probe is the shared one (kit issue #1820, lib/gh-visibility.sh): RSDD_GH_TIMEOUT seconds (default 10 here,
    # 20 in init / ensure-remote), GH_PROMPT_DISABLED=1; `timeout`, else `gtimeout`, else a bash watchdog. Any
    # non-decided result is a typed degraded line — never read as PRIVATE.
    # Latency budget (status runs from the stop/terminal path): historical 10 s default (RSDD_GH_TIMEOUT overrides), and
    # after the FIRST timeout the remaining remotes are not probed — N stalled remotes cost one bound, not N.
    if [ "$_rv_stalled" = 1 ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: skipped after timeout for remote $_rv_r — visibility unverified"; continue
    fi
    GHV_DEFAULT_BOUND=10 gh_visibility_probe "$_rv_gh" "$_rv_slug" || :
    case "$GHV_STATE" in
      TIMEOUT) _rv_stalled=1; _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh timed out for remote $_rv_r — visibility unverified"; continue ;;
      GH_ERROR) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh failed (rc=$GHV_RC) for remote $_rv_r — visibility unverified"; continue ;;
      GH_MISSING|PROBE_FAILED) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh probe could not run ($GHV_STATE) for remote $_rv_r — visibility unverified"; continue ;;
    esac
    _rv_vis="$GHV_RAW"
    case "$_rv_vis" in
      PUBLIC) echo "WARN public-remote: $_rv_r is PUBLIC — METHODOLOGY §15: a corpus remote is NEVER public; audit tracked files (ls-files) for decompiled/proprietary paths before any push. Visibility is the owner's call; this check never changes it." ;;
      PRIVATE|INTERNAL) ;;
      *) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: unrecognised gh answer [$_rv_vis] for remote $_rv_r — visibility unverified" ;;
    esac
  done
}
if [ "$_doc_mode" = 1 ]; then  # DOC-SAT-BRANCH
  echo "  saturation      : n/a (method: document-cycle — gap saturation does not apply; the ## Outline decides)"
else
  saturation_line
fi
campaign_status_block
# W6 (kit issue #1704): when remote_visibility_block prints a typed `degraded:` line, name the registry that
# gives its one continuation. SCOPE: this footer covers the remote-visibility block ONLY; other blocks that
# print a typed state are not covered. The block runs directly (no subshell, no buffering, stdout/stderr order
# untouched) and sets _RC_DEGRADED_PRINTED=1 on the same line as each of its `degraded:` echoes. Printed only
# when the flag is set, so a clean report stays byte-identical. The registry lives in the kit's toolbelt next
# to this script, not under the target.
# RC-WIRE-BEGIN
_RC_DEGRADED_PRINTED=0
remote_visibility_block
if [ "$_RC_DEGRADED_PRINTED" = 1 ]; then  # RC-FOOTER
  echo "  reason codes    : each typed remote-visibility degraded state above has one continuation in $here/reason-codes.v1.md"
fi
# RC-WIRE-END
# next step: aggregate across ALL focuses under $target (not just the alphabetically-first one via $state).
# WARNING 3: the default report was binding resolve_next to $state=head-1, so a stopped alpha printed
# "STOP" while beta had open gaps — the supervisor saw misinformation with a green consistency footer.
# Using a subshell keeps $state (and thus $corpus) unchanged in the parent for the footer below.
# Document mode (kit issue #1152): a NEXT / BOOTSTRAP from the Outline is final. STOP is only reported when the
# gap-centric resolver ALSO has no open work: a fully covered Outline does not hide an open investigable gap.
# _ns_gap_run: gap-centric verdict across every focus (subshell: the loop reassigns $state).
_ns_gap_run() (
  _ns_skip_gaps=0
  mapfile -t _ns_states < <(list_state_files "$target")
  for state in "${_ns_states[@]}"; do
    _ns_foc_slug="$(basename "$state" .md)"; _ns_foc_slug="${_ns_foc_slug#RESEARCH-STATE-}"
    _ns_foc_file="$(dirname "$state")/FOCUSES.md"
    _read_focuses_tok_into _ns_foc_tok "$_ns_foc_file" "$(basename "$state")"
    # shellcheck disable=SC2154 # _ns_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
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
_ns_doc=""
if [ "$_doc_mode" = 1 ]; then _ns_doc="$(outline_next_step)"; fi  # DOC-NEXT-BRANCH
case "$_ns_doc" in
  NEXT*|BOOTSTRAP*) printf '  next step       : %s\n' "$_ns_doc" ;;
  *)
    if [ -z "$_ns_doc" ]; then
      printf '  next step       : '
      _ns_gap_run
    else
      _ns_gap="$(_ns_gap_run)"
      case "$_ns_gap" in STOP*) _ns_gap="$_ns_doc" ;; esac  # DOC-STOP-GUARD: only a gap STOP yields to the Outline STOP; NEXT and any other verdict is kept
      printf '  next step       : %s\n' "$_ns_gap"
    fi
    ;;
esac
echo "  --- consistency (verify-state.sh) ---"
"$here/verify-state.sh" "$corpus" 2>&1 | sed -n '/summary\|FAIL\|WARN\|ok /p' | sed 's/^/  /'
exit 0   # a stale-mirror FAIL is REPORTED in the consistency line above; it must not become our exit code (contract: 0 ok / 2 bad args)
