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
#        (either STOP form, kit #1959) ... [backlog-unreadable: N rows] — N backlog rows were UNCOUNTED by the parser (near-miss heading,
#              no-Priority-header table, non-tier priority, malformed row); the exhaustion is NOT confirmed. Appended last, after any
#              [issue-coverage: unverified]; non-terminal — --emit-token answers `unavailable` for it instead of a STOP: campaign token.
#              Counted over the files the verdict covers (picked file under --root/--focus, else EVERY state file, stopped/paused included); an
#              uncountable file gives `[backlog-unreadable: unverified]` (never 0). The default report's `next step` line carries it too.
#        ISSUES-DUE | <count> untracked delta(s) in <retro> — first retro with untracked deltas found (early-exit:
#              remaining retros NOT probed); seed: stage-retro-issues.sh <retro> --apply
#        (aggregate probing budget: _IDG_AGGREGATE_BUDGET_SECS env var, default 60s — exceeded before all-clean confirmed → unverified marker)
#        RETRO-DUE | <count> ...       — §18 cadence: too many blocks without a retro; write one before resuming
#        STALE | <reason>              — RESEARCH-STATE is internally inconsistent; run --sync-state, reconcile, retry
#        BOOTSTRAP | <reason>          — no RESEARCH-STATE yet → run research-sdd-init.sh
#        DEGRADED | <reason>           — (kit #2024, exit 3) BACKUP gate for a blocked-rows failure that appears AFTER the STALE gate passed
#              (a transient extractor failure): the verdict probes every state file it reads (the picked file under --root/--focus,
#              else EVERY state file, stopped/paused included) and resolve_next, queue_next (--queue) and the paused-focus count treat an is_blocked read failure as fatal, so --next
#              REFUSES to answer instead of handing out a blocked gap or an inflated paused-focus count. A REPEATABLE failure is
#              answered first by `STALE | ... blocked_open derivation degraded` (verify-state CHECK C fails on the same read, same
#              file set). Fix the failure named on stderr and re-run; --emit-token answers `unavailable` for it.
#   --queue (with --next; kit #1614) honours the operator-declared lane: a `next_session_queue: G1, G2` line in the
#        state file's header (before its first `## ` heading) names gap ids in order, and --next returns the FIRST one that is
#        still pending and not blocked (`NEXT | <priority> | <gap>`, same line shape). It only chooses AMONG eligible
#        gaps: STALE and RETRO-DUE precede it, and ISSUES-DUE still fires at the terminal STOP. One queue per state file
#        (per focus). Typed stderr notes, never a silent zero: `INFO: queue-absent`, `INFO: queue-empty` (declared, no ids),
#        `INFO: queue-exhausted` (every id done/blocked -> normal priority order), `WARN: queue-unknown-gap <id>` (not in
#        the backlog, skipped loudly), `WARN: queue-malformed` (field ignored -> priority order), `INFO: queue-prose-only`
#        (a prose `NEXT SESSION QUEUE` header without the field). Without --queue the output is byte-identical.
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
# Exit: 0 ok · 1 --emit-token with no token available (`return-token: unavailable`) · 2 bad args · 3 --next refused: DEGRADED blocked-rows derivation (kit #2024). (malformed backlog rows are WARNed to stderr, never silently dropped.)
set -uo pipefail

_orig_args=("$@")   # --emit-token re-runs this script with the same argv minus the flag (kit #1706)
target="${1:-}"
[ -d "$target" ] || { echo "usage: research-sdd-status.sh <target-dir> [--next|--sync-state] [--focus <slug>]" >&2; exit 2; }
shift
mode="status"
focus_slug=""
emit_token=0       # --emit-token: with --next, append the literal RETURN CONTRACT token line (kit #1706)
all_flag=0         # --all: explicit corpus-wide --next (kit #1543); same as the default when no --focus/--root is given
queue_flag=0       # --queue: with --next, serve the first pending gap of the state file's declared next_session_queue (kit #1614)
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
    --queue) queue_flag=1; shift ;;
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
    *) echo "usage: research-sdd-status.sh <target-dir> [--next [--all] [--queue] [--emit-token]|--sync-state [--only <counters>]] [--focus <slug>|--root] [--stall-minutes N]" >&2; exit 2 ;;
  esac
done
# only_has <counter>: true when this counter WILL be written (no --only, or named in it).
only_has() { [ "$only_set" = 0 ] && return 0; case ",$only_list," in *",$1,"*) return 0 ;; esac; return 1; }
[ "$only_set" = 1 ] && [ "$mode" != "--sync-state" ] && { echo "usage: --only requires --sync-state" >&2; exit 2; }
[ "$root_flag" = 1 ] && [ -n "$focus_slug" ] && { echo "usage: --root and --focus are mutually exclusive" >&2; exit 2; }
[ "$all_flag" = 1 ] && [ "$mode" != "--next" ] && { echo "usage: --all requires --next" >&2; exit 2; }
[ "$all_flag" = 1 ] && { [ "$root_flag" = 1 ] || [ -n "$focus_slug" ]; } && { echo "usage: --all is corpus-wide and excludes --focus/--root" >&2; exit 2; }
[ "$emit_token" = 1 ] && [ "$mode" != "--next" ] && { echo "usage: --emit-token requires --next" >&2; exit 2; }
[ "$queue_flag" = 1 ] && [ "$mode" != "--next" ] && { echo "usage: --queue requires --next" >&2; exit 2; }

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
      case "$_et_verdict" in *"[backlog-unreadable: "*) _et_unavail "STOP carries [backlog-unreadable: N rows] — unread backlog rows must be reconciled before any STOP: campaign token" ;; esac  # ET-BU-NONTERMINAL
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
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
_SFLIB="$_RSDD_SELF/lib/state-files.sh"
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
here="$_RSDD_SELF"

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
declare -F focus_range_block_count >/dev/null 2>&1 || { echo "research-sdd-status: helper $_FPLIB failed to define focus_range_block_count" >&2; exit 1; }

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

# Shared blocked-entry derivation (kit #923): ONE definition of the blocked sections and of the awk that
# counts `## Child gaps surfaced at close` entries, sourced by verify-state.sh too. Fail closed: this
# script does not use `set -e`, so a partial source would otherwise yield an empty blocked count.
_BRLIB="$here/lib/blocked-rows.sh"
if [ ! -f "$_BRLIB" ]; then echo "research-sdd-status: cannot find helper $_BRLIB" >&2; exit 1; fi
# shellcheck source=lib/blocked-rows.sh
. "$_BRLIB"
declare -F blocked_open_count >/dev/null 2>&1 || { echo "research-sdd-status: helper $_BRLIB failed to define blocked_open_count" >&2; exit 1; }
declare -F blocked_rows_body >/dev/null 2>&1 || { echo "research-sdd-status: helper $_BRLIB failed to define blocked_rows_body" >&2; exit 1; }
unset _BRLIB
