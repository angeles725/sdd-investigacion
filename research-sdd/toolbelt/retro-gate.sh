#!/usr/bin/env bash
# retro-gate.sh — §18 Stop-hook body: blocks once when research files advanced
# without a conforming retro (U17 / #479 — PR 2 of 2).
#
# Usage: retro-gate.sh <target>
#   Reads Claude Code Stop-hook JSON on stdin. Always exits 0 (hook contract).
#   BLOCK = stdout {"decision":"block","reason":"<actionable text>"}
#   ALLOW = exit 0, no JSON on stdout.
#
# §7: always prints a one-line state summary to STDERR (never silent).
# propose-never-apply: never writes to the target corpus; state files go under .claude/.

set -uo pipefail

# -P/pwd -P: see research-sdd/toolbelt/verify-cd-physical.sh's own header for why (kit issue #1024).
SELF_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
KIT="$(cd -P "$SELF_DIR/.." && pwd -P)"

_usage() { printf 'Usage: %s <target>\n' "$(basename "$0")" >&2; }
if [ $# -ne 1 ]; then
  _usage; printf 'retro-gate: ERROR: missing <target>\n' >&2; exit 0
fi
TARGET="$(cd "$1" 2>/dev/null && pwd)" || {
  printf 'retro-gate: ERROR: target not found: %s\n' "$1" >&2; exit 0
}

# SENTINEL-STOP-LOG-START
# ── Stop-branch log (kit issue #1258) ─────────────────────────────────────────
# Every Stop appends ONE line (UTC timestamp, target, session, branch taken, seeding evidence) to
# $TARGET/.claude/.rsdd-retro-gate-stops.log — the state dir this gate already owns, never the
# corpus content — so an operator can answer "what did the hook do?" without reading transcripts.
# The name follows the `.rsdd-*` state-file convention so a target's existing `.claude/.rsdd-*`
# ignore rule covers it: a tracked .claude/ must not turn dirty on every Stop.
# Written from an EXIT trap installed as soon as TARGET resolves, so every exit path after it is
# covered (a helper-load failure is logged as branch=error-helper); the trap never calls `exit`, so
# the verdict and exit code are untouched. Bounded: past _STOP_LOG_MAX lines the file is cut to its
# last _STOP_LOG_KEEP through a per-process temp name (concurrent Stops must not share one).
# A failed write is a typed stderr WARN (§7), never a changed verdict.
_STOP_BRANCH="error-helper"  # until the helper libs load; each exit site then sets its own branch
_STOP_SEED=""     # seeding evidence: skip reason, per-retro summary: lines, aggregate counters
_STOP_LOG_MAX=400
_STOP_LOG_KEEP=200
_seed_note() { _STOP_SEED="${_STOP_SEED:+$_STOP_SEED; }$1"; }
_stop_log_write() {
  local _mode=""
  [ "${_degraded:-0}" -eq 1 ] && _mode=" mode=degraded"
  local d="$TARGET/.claude" f line n
  f="$d/.rsdd-retro-gate-stops.log"
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) target=${TARGET##*/} session=${_session_id//[^A-Za-z0-9._-]/_} branch=${_STOP_BRANCH:-unclassified}$_mode"
  [ -z "$_STOP_SEED" ] || line="$line seeding=$_STOP_SEED"
  line="${line//$'\n'/ }"
  if mkdir -p "$d" 2>/dev/null && printf '%s\n' "$line" >> "$f" 2>/dev/null; then
    n="$(wc -l < "$f" 2>/dev/null)" || n=0
    if [ "${n:-0}" -gt "$_STOP_LOG_MAX" ]; then
      if tail -n "$_STOP_LOG_KEEP" "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null; then :; else
        rm -f "$f.tmp.$$" 2>/dev/null
        printf 'retro-gate: WARN: stop-log rotation failed (%s) — log may grow; verdict unaffected\n' "$f" >&2
      fi
    fi
  else
    printf 'retro-gate: WARN: stop-log write failed (%s) — Stop not recorded; verdict unaffected\n' "$f" >&2
  fi
}
_session_id=""
# Part C scratch files (kit issue #1404): removed on EVERY exit path, including a SIGTERM/SIGINT from
# a Stop timeout. The signal traps tag the stop-log line branch=killed (kit issue #1421 item 2) and
# `exit`, which runs the EXIT handler; SIGKILL stays untrappable. bash runs the EXIT trap on a fatal
# SIGTERM/SIGINT even without these traps, so what they add is the branch=killed tag (pinned by S16d/e).
_dl_f1=""; _dl_f2=""; _dl_of=""
_dl_cleanup() {
  [ -z "$_dl_f1" ] || rm -f -- "$_dl_f1"
  [ -z "$_dl_f2" ] || rm -f -- "$_dl_f2"
  [ -z "$_dl_of" ] || rm -f -- "$_dl_of"
}
_exit_handler() {
  _stop_log_write
  _dl_cleanup   # SENTINEL-DIRLINK-CLEANUP
}
trap _exit_handler EXIT
trap '_STOP_BRANCH=killed; exit 143' TERM
trap '_STOP_BRANCH=killed; exit 130' INT
# SENTINEL-STOP-LOG-END

# ── Load helpers ──────────────────────────────────────────────────────────────
_bf_lib="$SELF_DIR/lib/block-files.sh"
_rs_lib="$SELF_DIR/lib/retro-status.sh"
for _lib in "$_bf_lib" "$_rs_lib"; do
  [ -f "$_lib" ] || { printf 'retro-gate: ERROR: missing helper %s\n' "$_lib" >&2; exit 0; }
done
# shellcheck source=lib/block-files.sh
. "$_bf_lib"
# shellcheck source=lib/retro-status.sh
. "$_rs_lib"
declare -F block_file_filter >/dev/null 2>&1 || { printf 'retro-gate: block_file_filter not defined\n' >&2; exit 0; }
declare -F block_files_nested_worktree_roots >/dev/null 2>&1 || { printf 'retro-gate: block_files_nested_worktree_roots not defined\n' >&2; exit 0; }
declare -F block_files_path_in_nested_worktree >/dev/null 2>&1 || { printf 'retro-gate: block_files_path_in_nested_worktree not defined\n' >&2; exit 0; }
declare -F retro_is_excluded >/dev/null 2>&1 || { printf 'retro-gate: retro_is_excluded not defined\n' >&2; exit 0; }
declare -F retro_marker_scope_line >/dev/null 2>&1 || { printf 'retro-gate: retro_marker_scope_line not defined\n' >&2; exit 0; }
declare -F retro_status_from_marker_line >/dev/null 2>&1 || { printf 'retro-gate: retro_status_from_marker_line not defined\n' >&2; exit 0; }
declare -F retro_marker_is_partial >/dev/null 2>&1 || { printf 'retro-gate: retro_marker_is_partial not defined\n' >&2; exit 0; }
declare -F retro_marker_out_of_scope >/dev/null 2>&1 || { printf 'retro-gate: retro_marker_out_of_scope not defined\n' >&2; exit 0; }

# ── Nested worktree copies (kit issue #1223) ──────────────────────────────────
# _nw_roots: newline-separated nested-worktree roots under $TARGET, probed ONCE below (after the
# early loop-safety / block-once exits, so those cheap paths never pay for the find). A path under
# one of them is a copy of the corpus, never a research file or a retro of this target.
_nw_roots=""
_STOP_BRANCH=""   # helpers loaded: from here an exit with no branch set is typed 'unclassified'
_in_nested_worktree() { block_files_path_in_nested_worktree "$1" "$_nw_roots"; }

# ── §18-EN3: auto issue-seeding on session close ──────────────────────────────

# _retro_is_seedable <path>: returns 0 when the retro has open deltas
# (review-status is pending/none/absent, or PARTIAL applied with unshipped rows).
#
# RETRO_GATE_SEEDABLE_SHARED_LIB (kit issues #945, #1093 item 3): this used to be its own
# unanchored 'grep -m1 review-status' over the WHOLE file — over-permissive in the same way
# stage-retro-issues.sh's pre-#945 whole-file scan was (a marker anywhere in the body, including
# a quoted example, would gate seeding) — and its own bare 'case ... *PARTIAL*)' glob check never
# recognised the 'shipped:'-without-PARTIAL marker shape lib/retro-status.sh's
# retro_marker_is_partial already handles (kit issue #949): a marker like
# "applied · sha · shipped: row 1" (no literal PARTIAL token) made the seeder treat the retro as
# PARTIAL (some rows still open) while retro-gate's old glob check said "applied, not seedable" —
# unshipped rows in that shape were never auto-seeded by the Stop hook. Routing through the same
# retro_marker_scope_line + retro_status_from_marker_line + retro_marker_is_partial calls the
# other three instruments use closes both gaps: one scope, one PARTIAL definition, shared here.
_retro_is_seedable() {
  local rf="$1" sline status
  sline="$(retro_marker_scope_line "$rf")"
  # RETRO_GATE_OUT_OF_SCOPE_GUARD (kit issue #1099): an empty scope-scan result does not mean
  # "no marker" when a whole-file scan still finds one outside the shared #945 scope (YAML
  # frontmatter, a multi-line comment run before it, a marker after a second heading, …).
  # Conflating that with "genuinely absent" was the #1048-#1089 fail-open shape — status read as
  # "" (pending/open) and every row got auto-seeded. Fail CLOSED instead: refuse to seed and say
  # why, same as stage-retro-issues.sh's own guard.
  if [ -z "$sline" ] && retro_marker_out_of_scope "$rf"; then
    # kit issue #1125 item 5: 'out-of-scope-marker:' is the SAME typed token every consumer
    # (sweep-retros.sh, stage-retro-issues.sh, reconcile-issues.sh) leads with, right after this
    # tool's own retro-gate: WARN: wrapper — keeps the finding greppable across all four.
    printf 'retro-gate: WARN: out-of-scope-marker: %s — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n' \
      "$(basename "$rf")" >&2
    return 1
  fi
  status="$(retro_status_from_marker_line "$sline")"
  case "$status" in
    dismissed) return 1 ;;  # dismissed always wins — never reopened by a stray PARTIAL token
    applied)
      # PARTIAL applied (word token, or a structured 'shipped:' field) = some rows still open
      retro_marker_is_partial "$sline" && return 0 || return 1 ;;
    *) return 0 ;;  # pending / no marker = seedable
  esac
}

# SENTINEL-SEEDING-FUNC-START
_run_issue_seeding() {
  local target="$1" kit="$2"
  local seeder="$kit/toolbelt/stage-retro-issues.sh"

  # SENTINEL-GH-PROBE-START
  if ! command -v gh >/dev/null 2>&1; then
    printf 'retro-gate: WARN: gh not found — issue-seeding skipped (run %s <retro> --apply manually)\n' \
      "$seeder" >&2
    _seed_note "skipped:gh-absent"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'retro-gate: WARN: gh not authenticated — issue-seeding skipped (run gh auth login, then %s <retro> --apply manually)\n' \
      "$seeder" >&2
    _seed_note "skipped:gh-not-authenticated"
    return 0
  fi
  # SENTINEL-GH-PROBE-END

  if [ ! -f "$seeder" ]; then
    printf 'retro-gate: WARN: stage-retro-issues.sh not found at %s — seeding skipped\n' "$seeder" >&2
    _seed_note "skipped:seeder-missing"
    return 0
  fi

  local created=0 skipped=0 failed=0 failed_issues=0 empty=0 absent=0 ran=0 unclassifiable=0
  local rf seed_out seed_rc _c _s _f _summary _seed_reason _seed_failed _absent_typed
  local failed_list=""
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    _in_nested_worktree "$rf" && continue   # NW-RETRO-GUARD-SEED
    retro_is_excluded "$rf" && continue
    _retro_is_seedable "$rf" || continue
    ran=$((ran + 1))
    # SENTINEL-SEEDER-RC-START
    seed_out="$(bash "$seeder" "$rf" --apply 2>&1)"
    seed_rc=$?
    _seed_failed=0   # per-issue failure count from summary: line (exit-2 path)
    # Classify absent-input ONCE before the if-chain — no pipe in boolean context (e727cde)
    _absent_typed=0
    case $'\n'"$seed_out" in *$'\n'absent-input:*) _absent_typed=1 ;; esac
    # Parse counts from the authoritative summary: line emitted by the seeder at end of --apply
    _summary="$(printf '%s' "$seed_out" | grep '^summary:' | tail -1)"
    if [ -n "$_summary" ]; then
      # Surface the seeder's own evidence line on the hook output and in the Stop log (#1258).
      printf 'retro-gate: seeder %s: %s\n' "$(basename "$rf")" "$_summary" >&2
      _seed_note "$(basename "$rf") $_summary"
      _c="$(printf '%s' "$_summary" | grep -oE 'created=[0-9]+' | cut -d= -f2)"
      _s="$(printf '%s' "$_summary" | grep -oE 'skipped-duplicate=[0-9]+' | cut -d= -f2)"
      _f="$(printf '%s' "$_summary" | grep -oE 'failed=[0-9]+' | cut -d= -f2)"
      created=$((created + ${_c:-0}))
      skipped=$((skipped + ${_s:-0}))
      _seed_failed="${_f:-0}"
      # no-match: may accompany summary: (real seeder: search absent-input: retro not found)
      # — all rows shipped; count as empty (no open deltas)
      case $'\n'"$seed_out" in *$'\n'no-match:*) empty=$((empty + 1)) ;; esac
    # SENTINEL-TYPED-OUTCOME-START
    # Typed-outcome scope: absent-input (any rc, §7 distinct from empty/no-match),
    # empty-input (no delta section), no-match (all rows shipped, exit-0 only).
    # Scope name is correct: covers all recognised typed outcomes regardless of rc.
    elif [ "$_absent_typed" -eq 1 ]; then
      absent=$((absent + 1))
      printf 'retro-gate: WARN: seeder: absent-input for %s (retro not found — verify path)\n' \
        "$(basename "$rf")" >&2
    elif [ "$seed_rc" -eq 0 ]; then
      # Seeder exited 0 with no summary: empty-input (no delta section), no-match (all shipped),
      # or unclassifiable (kit issue #1111/#1129: the shared grammar found a proposal-like
      # heading or a canonical section it cannot auto-stage issues from — e.g. numbered-list
      # entries instead of a table, or a heading the parser cannot classify — needs manual
      # review, not a failure). Before this branch, an unclassifiable retro fell through to the
      # generic "no summary: line" WARN below and was silently uncounted.
      case $'\n'"$seed_out" in
        *$'\n'empty-input:*|*$'\n'no-match:*)
          empty=$((empty + 1)) ;;
        *$'\n'unclassifiable:*)
          unclassifiable=$((unclassifiable + 1))
          printf 'retro-gate: WARN: seeder: unclassifiable for %s — needs manual review, no issue auto-staged (kit issue #1111/#1129)\n' \
            "$(basename "$rf")" >&2 ;;
        *)
          # Seeder exited 0 with no recognised typed outcome and no summary: line
          printf 'retro-gate: WARN: seeder exited 0 but no summary: line for %s\n' \
            "$(basename "$rf")" >&2 ;;
      esac
    # SENTINEL-TYPED-OUTCOME-END
    else
      # No summary: and seeder failed — count ^created: progress lines as fallback (§7)
      _c="$(printf '%s' "$seed_out" | grep -c '^created: ')" || _c=0
      created=$((created + ${_c:-0}))
      printf 'retro-gate: WARN: seeder exited %d for %s: no summary: line — counted %d partial-progress line(s)\n' \
        "$seed_rc" "$(basename "$rf")" "${_c:-0}" >&2
    fi
    # SENTINEL-ABSENT-NOT-FAILED-START
    # absent-input: exits non-zero but is already counted in absent — skip failed accounting
    if [ "$seed_rc" -ne 0 ] && [ "$_absent_typed" -eq 0 ]; then
      failed=$((failed + 1))
      failed_issues=$((failed_issues + ${_seed_failed:-0}))
      failed_list="${failed_list:+$failed_list, }$(basename "$rf")"
      # Last non-progress line of seeder output as reason (bounded to 80 chars)
      _seed_reason="$(printf '%s' "$seed_out" | \
        grep -vE '^(created|skipped-duplicate|skipped-shipped|skipped-wrong-kit|planned-issue|summary|no-match):' | \
        tail -1 | cut -c1-80)"
      if [ -z "$_seed_reason" ]; then _seed_reason="(no output)"; fi
      printf 'retro-gate: WARN: seeder failed (exit %d) for %s: %s\n' \
        "$seed_rc" "$(basename "$rf")" "$_seed_reason" >&2
      case $'\n'"$seed_out" in
        *$'\n'degraded:*) _seed_note "seeder-degraded:$(basename "$rf"):$_seed_reason" ;;
        *) _seed_note "seeder-failed:rc=$seed_rc:$(basename "$rf"):$_seed_reason" ;;
      esac
    fi
    # SENTINEL-ABSENT-NOT-FAILED-END
    # SENTINEL-SEEDER-RC-END
  # SENTINEL-FIND-STDERR-START
  # stderr not suppressed — traversal errors (permission denied, missing dir) are §7 signals
  done < <(find -H "$target" -maxdepth 4 -path '*/retros/*.md' \
           -not -path '*/.git/*' -not -iname '*index*.md')
  # SENTINEL-FIND-STDERR-END

  # SENTINEL-AGGREGATE-WARN-START
  if [ "$failed" -gt 0 ]; then
    printf 'retro-gate: WARN: %d issue create(s) failed across %d retro(s): %s\n' \
      "$failed_issues" "$failed" "$failed_list" >&2
  fi
  # SENTINEL-AGGREGATE-WARN-END
  printf 'retro-gate: issue-seeding: ran=%d created=%d skipped-dedup=%d empty=%d unclassifiable=%d absent=%d failed=%d failed-issues=%d target=%s\n' \
    "$ran" "$created" "$skipped" "$empty" "$unclassifiable" "$absent" "$failed" "$failed_issues" "$(basename "$target")" >&2
  _seed_note "ran=$ran created=$created skipped-dedup=$skipped empty=$empty unclassifiable=$unclassifiable absent=$absent failed=$failed"
}
# SENTINEL-SEEDING-FUNC-END

# ── Pure-bash JSON string escaper (decision channel must not depend on jq) ────
_json_escape_reason() {
  local s="$1"
  local _dq='"'
  local _esc_dq='\"'         # the two characters \ and " — assigned once, single-quoted
  s="${s//\\/\\\\}"          # \ → \\  (must be first)
  s=${s//$_dq/"$_esc_dq"}   # " → \"  (kit issue #1167 item 2: the replacement comes from a
                             # variable, and the substitution sits in an UNQUOTED assignment
                             # (no word splitting there) with the operand itself quoted — the
                             # lint-substitution rule. That previous inline form inside an
                             # outer "${…}" kept the operand's quotes literal on bash < 4.3;
                             # outside outer double quotes they are removed on every bash.
                             # $_esc_dq is a fixed constant with no '&', so bash 5.2's
                             # patsub_replacement has nothing to expand; output is
                             # byte-identical to the previous form on bash 5.)
  s="${s//$'\n'/\\n}"       # newline → \n
  # SENTINEL-ESC-CTRL-START
  # kit issue #1301 item 6: RFC 8259 forbids any raw C0 control (0x00-0x1f) inside a JSON string;
  # a retro finding with a tab, CR or ESC byte made the whole decision unparseable. \t and \r get
  # their short forms, every other one (except the \n handled above) becomes \u00XX. The
  # replacement comes from a variable for the same reason as the quote above (#1167 item 2).
  local _i _ch _rep
  for _i in 1 2 3 4 5 6 7 8 9 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v _ch "\\x$(printf '%02x' "$_i")"
    case "$_i" in
      9)  _rep='\t' ;;
      13) _rep='\r' ;;
      *)  printf -v _rep '\\u%04x' "$_i" ;;
    esac
    s=${s//"$_ch"/"$_rep"}
  done
  # SENTINEL-ESC-CTRL-END
  printf '%s' "$s"
}

# SENTINEL-JQ-PROBE-START
# ── Probe: jq required for JSON parsing ──────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  _STOP_BRANCH="degraded"
  printf 'retro-gate: state=allow branch=degraded (jq missing — cannot read hook JSON) target=%s\n' \
    "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-JQ-PROBE-END

# ── Read stdin JSON ───────────────────────────────────────────────────────────
_json=$(cat)
_session_id=$(printf '%s' "$_json" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
_stop_hook_active=$(printf '%s' "$_json" | jq -r '.stop_hook_active // false' 2>/dev/null) || _stop_hook_active="false"

# SENTINEL-STOP-HOOK-ACTIVE-START
# ── (1) Loop-safety: check stop_hook_active FIRST ────────────────────────────
if [ "$_stop_hook_active" = "true" ]; then
  _STOP_BRANCH="loop-safety"
  printf 'retro-gate: state=allow branch=loop-safety stop_hook_active=true target=%s\n' \
    "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-STOP-HOOK-ACTIVE-END

_state_dir="$TARGET/.claude"
_blocked_file="$_state_dir/.rsdd-retro-blocked-${_session_id}"

# SENTINEL-BLOCK-ONCE-START
# ── (2) Block-once: allow if already blocked this session ─────────────────────
if [ -n "$_session_id" ] && [ -f "$_blocked_file" ]; then
  _STOP_BRANCH="block-once"
  printf 'retro-gate: state=allow branch=block-once session=%s target=%s\n' \
    "$_session_id" "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-BLOCK-ONCE-END

# SENTINEL-NESTED-WORKTREE-PROBE-START
# ── Probe nested worktree roots once (kit issue #1223) ───────────────────────
# A failed or incomplete probe must not hide the gate and must not be silent (§7): the roots
# found so far are kept (rc 3 still prints them) and one WARN names the gap.
_nw_roots="$(block_files_nested_worktree_roots "$TARGET")"
_nw_rc=$?
# rc 3 (incomplete traversal) already printed its own typed WARN from the lib — say nothing twice.
# FAIL SAFE (kit issue #1301 item 3): any other rc keeps the gate running with whatever roots were
# printed (possibly none), so worktree copies may be COUNTED — a false BLOCK, recoverable — and
# never skipped; the probe's failure can never turn into an allow.
# SENTINEL-NW-PROBE-FAIL-START
if [ "$_nw_rc" -ne 0 ] && [ "$_nw_rc" -ne 3 ]; then
  printf 'retro-gate: WARN: nested-worktree probe failed (rc=%s) for %s — worktree copies may be counted\n' \
    "$_nw_rc" "$(basename "$TARGET")" >&2
fi
# SENTINEL-NW-PROBE-FAIL-END
# SENTINEL-NESTED-WORKTREE-PROBE-END

# ── Helper: check if a path is a research file (block/state/catalog/index) ───
_is_research_file() {
  local p="$1" base
  # SENTINEL-NESTED-WORKTREE-GUARD-START
  # A copy inside a nested worktree is not a change to THIS target (kit issue #1223).
  if _in_nested_worktree "$p"; then return 1; fi
  # SENTINEL-NESTED-WORKTREE-GUARD-END
  # block file (uses block_file_filter regex)
  if printf '%s\n' "$p" | block_file_filter >/dev/null 2>&1; then return 0; fi
  base="$(basename "$p")"
  case "$base" in
    RESEARCH-STATE*.md|CATALOG.md|INDEX.md) return 0 ;;
  esac
  return 1
}

# ── Session-start sha / file detection ───────────────────────────────────────
_session_file="$_state_dir/.rsdd-session-${_session_id}"
_session_sha=""
_degraded=0
if [ -n "$_session_id" ] && [ -f "$_session_file" ]; then
  _session_sha="$(cat "$_session_file" 2>/dev/null || echo '')"
fi
if [ -z "$_session_sha" ]; then
  printf 'retro-gate: WARN: no session-start sha (session file absent/empty); degraded check\n' >&2
  _degraded=1
fi
# Validate the sha is reachable in this repository (handles cloned / amended / bad sha)
if [ "$_degraded" -eq 0 ]; then
  if ! git -C "$TARGET" rev-parse -q --verify "${_session_sha}^{commit}" >/dev/null 2>&1; then
    printf 'retro-gate: WARN: session-start sha %s unresolvable; degraded check\n' \
      "${_session_sha:0:12}" >&2
    _degraded=1
  fi
fi

# ── Detect changed research files ────────────────────────────────────────────
_has_changed=0

# Part A: committed/staged changes relative to session-start sha (--cached covers both)
# --relative gives paths relative to $TARGET so they work for subdirectory targets.
# This loop tracks _has_changed only — the "newest changed block mtime" (_nb_mtime) is defined
# and read exclusively by the degraded staleness check further below, so there is nothing for
# the non-degraded path to track here.
if [ "$_degraded" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    full="$TARGET/$f"
    _is_research_file "$full" && _has_changed=1
    # SENTINEL-DIRLINK-ADDED-START
    # A directory symlink changed since the session start (kit issue #1311): git tracks it as a
    # blob with no .md suffix, so it can never look like research — but it may expose a research
    # tree. Count it as a change (a false BLOCK is recoverable, a false ALLOW is not).
    if [ -L "$full" ] && [ -d "$full" ] && ! _in_nested_worktree "$full"; then _has_changed=1; fi
    # SENTINEL-DIRLINK-ADDED-END
  done < <(git -C "$TARGET" diff --cached --relative --name-only "$_session_sha" 2>/dev/null)
fi

# Part B: uncommitted research files newer than the session-start state file. Same scope as
# Part A above — _has_changed only.
# Every `find` over $TARGET in this script is `find -H` (kit issue #1301): TARGET is the LOGICAL path
# the hook was registered with, so a symlinked target must be followed — plain `find <symlink>`
# lists only the link itself and the scan sees an empty tree (false ALLOW: branch=no-change).
# -H follows symlinks given on the command line only, never ones met while descending.
if [ -f "$_session_file" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _is_research_file "$f" && _has_changed=1
  done < <(find -H "$TARGET" -newer "$_session_file" -type f -name '*.md' \
           -not -path '*/.git/*' 2>/dev/null)
fi

# SENTINEL-DIRLINK-SCAN-START
# Part C (kit issue #1311): a research directory that is a SYMLINK inside the target is invisible
# to Part A (git tracks the link as a blob) and to Part B (`find -H` follows only command-line
# links). Each such link is followed ONE hop — `find -H <link>` never descends into links met while
# walking, so a link loop terminates — and Part B's rule is applied behind it.
#
# CANDIDATES come from git, not from a walk: tracked mode-120000 entries (`ls-files -s`) plus
# untracked non-ignored paths (`ls-files -o --exclude-standard`), each filtered with [ -L ] && [ -d ].
# That costs ~10 ms where `find -H $TARGET -type l -xtype d` cost 12-16 s per Stop on a 66k-symlink
# corpus, and this runs before the no-change exit (every Stop pays it).
# TRADEOFF (deliberate): a GITIGNORED directory link is never enumerated, so research changed only
# through such a link is not seen. When git cannot enumerate (ls-files fails) the candidate list
# falls back to the old find, bounded by RETRO_GATE_DIRLINK_TIMEOUT seconds (default 5); a timeout
# or any other find failure is a typed WARN, never a silent "no links".
# OUT OF SCOPE: a SINGLE-FILE link (e.g. RESEARCH-STATE.md -> elsewhere) and a two-hop chain (a link
# inside a linked directory), neither of which -H follows. Only a non-degraded run reaches here, as
# for Part A (a degraded run has no session sha to compare against).
# SKIPPED links: one that resolves INSIDE the target (Parts A/B already cover it) or inside a nested
# worktree; one that resolves to /, $HOME or an ancestor of the target (typed WARN: it would walk
# the whole parent tree). A self-referential link therefore is never walked at all; no mutant can
# bite on S3 (termination is a property of find -H and the skip), so S3 stays a regression case.
# LIMITS (documented, no fleet incidence): `ls-files` does not recurse into a SUBMODULE and does not
# list the contents of an untracked NESTED CLONE, so a directory link that lives inside either one is
# never enumerated, exactly like the gitignored case above (kit issue #1352). Candidates stay
# NUL-delimited end to end (a bash array here, `-print0` in the walks), so a link NAME containing a
# newline is one path, not two.
# RETRO_GATE_DIRLINK_TIMEOUT must be a positive number (integer or decimal, e.g. 5 or 2.5). 0 would
# disable GNU timeout (an unbounded walk on a Stop hook) and a non-number would fail every walk with
# rc 125, so anything else is a typed WARN and the 5 s default is used (never a silent disable).
# NOT bounded: the TOTAL Part C time (N links x timeout worst case); deferred (kit issues #1352,
# #1404 — a cumulative budget needs a decision on its own variable/semantics; bash has no float
# arithmetic, so a decimal RETRO_GATE_DIRLINK_TIMEOUT cannot simply be subtracted from).
# SCRATCH FILES: _dl_f1/_dl_f2/_dl_of are removed by the EXIT handler (also reached from the
# TERM/INT traps), so a Stop timeout that kills the hook does not leak them. If `mktemp` fails, Part C
# is skipped with one typed WARN (no scratch file = no walk), never a per-link rc=126 report.
_dl_timeout="${RETRO_GATE_DIRLINK_TIMEOUT:-5}"
# SENTINEL-DIRLINK-TIMEOUT-START
if ! [[ "$_dl_timeout" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$_dl_timeout" =~ ^0+(\.0+)?$ ]]; then
  printf "retro-gate: WARN: RETRO_GATE_DIRLINK_TIMEOUT='%s' is not a positive number — using the default 5 s\n" \
    "$_dl_timeout" >&2
  _dl_timeout=5
fi
# SENTINEL-DIRLINK-TIMEOUT-END
# _dl_find <find-args…>: bounded find; NUL-delimited stdout (callers pass -print0) lands in the file
# _dl_of and the status in _dl_rc (124 = timed out, 127 = no `timeout` binary, 126 = defensive guard
# for a missing scratch file; the scan itself is skipped with its own typed WARN before that can
# happen, so a real 126 here is find/timeout's "cannot execute"). Never fails the caller. (A file, not a command substitution: bash drops NUL bytes there,
# and the subshell would lose _dl_rc.)
_dl_find() {
  if [ -z "$_dl_of" ]; then _dl_rc=126; return 0; fi
  : > "$_dl_of"
  if ! command -v timeout >/dev/null 2>&1; then _dl_rc=127; return 0; fi
  timeout "$_dl_timeout" find "$@" > "$_dl_of" 2>/dev/null; _dl_rc=$?
  return 0
}
if [ "$_degraded" -eq 0 ] && [ -f "$_session_file" ]; then
  _dl_tgt="$(realpath -- "$TARGET" 2>/dev/null)" || _dl_tgt="$TARGET"
  _dl_home="$(realpath -- "${HOME:-/nonexistent}" 2>/dev/null)" || _dl_home=""
  _dl_cands=(); _dl_skip=0
  _dl_f1="$(mktemp 2>/dev/null)" || _dl_f1=""
  _dl_f2="$(mktemp 2>/dev/null)" || _dl_f2=""
  _dl_of="$(mktemp 2>/dev/null)" || _dl_of=""
  # SENTINEL-DIRLINK-SCRATCH-START
  # No scratch file for the walks → Part C cannot run at all: say so ONCE, with the real cause (it is
  # not a find/timeout failure), instead of one "walk incomplete (rc=126)" per link.
  if [ -z "$_dl_of" ]; then
    printf 'retro-gate: WARN: directory-symlink scan skipped: cannot create a scratch file (mktemp failed) for %s — symlinked research directories not scanned\n' \
      "$(basename "$TARGET")" >&2
    _dl_cands=(); _dl_skip=1
  fi
  # SENTINEL-DIRLINK-SCRATCH-END
  if [ "$_dl_skip" -eq 1 ]; then :
  elif [ -n "$_dl_f1" ] && [ -n "$_dl_f2" ] \
     && git -C "$TARGET" ls-files -s -z > "$_dl_f1" 2>/dev/null \
     && git -C "$TARGET" ls-files -o --exclude-standard -z > "$_dl_f2" 2>/dev/null; then
    while IFS= read -r -d '' _p; do
      if [ -L "$TARGET/$_p" ] && [ -d "$TARGET/$_p" ]; then _dl_cands+=("${TARGET%/}/${_p}"); fi
    done < <(grep -z '^120000 ' "$_dl_f1" | sed -z 's/^[^\t]*\t//'; cat "$_dl_f2")
  else
    _dl_find -H "$TARGET" -path '*/.git' -prune -o -type l -xtype d -print0
    if [ "$_dl_rc" -eq 124 ]; then
      printf 'retro-gate: WARN: directory-symlink scan timed out after %ss for %s — symlinked research directories not scanned\n' \
        "$_dl_timeout" "$(basename "$TARGET")" >&2
    elif [ "$_dl_rc" -ne 0 ]; then
      printf 'retro-gate: WARN: directory-symlink scan incomplete (rc=%s) for %s — symlinked research directories may be missed\n' \
        "$_dl_rc" "$(basename "$TARGET")" >&2
    fi
    if [ -n "$_dl_of" ]; then
      while IFS= read -r -d '' _p; do _dl_cands+=("$_p"); done < "$_dl_of"
    fi
  fi
  rm -f "$_dl_f1" "$_dl_f2"
  for _lnk in ${_dl_cands[@]+"${_dl_cands[@]}"}; do
    [ -n "$_lnk" ] || continue
    _lr="$(realpath -- "$_lnk" 2>/dev/null)" || continue
    # SENTINEL-DIRLINK-ANCESTOR-START
    if [ "$_lr" = "/" ] || [ "$_lr" = "$_dl_home" ] || { [ "$_lr" != "$_dl_tgt" ] && [ "${_dl_tgt#"$_lr"/}" != "$_dl_tgt" ]; }; then
      printf 'retro-gate: WARN: directory symlink %s resolves to %s (/, $HOME or an ancestor of the target) — not scanned\n' \
        "${_lnk#"$TARGET"/}" "$_lr" >&2
      continue
    fi
    # SENTINEL-DIRLINK-ANCESTOR-END
    # SENTINEL-DIRLINK-INSIDE-START
    # Resolving inside the target also covers a nested worktree: those roots live under $TARGET
    # (block_files_nested_worktree_roots), so a separate _in_nested_worktree "$_lr" test is redundant.
    if [ "$_lr" = "$_dl_tgt" ] || [ "${_lr#"$_dl_tgt"/}" != "$_lr" ]; then continue; fi
    # SENTINEL-DIRLINK-INSIDE-END
    _in_nested_worktree "$_lnk" && continue
    _dl_find -H "$_lnk" -newer "$_session_file" -type f -name '*.md' -not -path '*/.git/*' -print0
    # SENTINEL-DIRLINK-WALK-WARN-START
    if [ "$_dl_rc" -ne 0 ]; then
      printf 'retro-gate: WARN: directory-symlink walk incomplete (rc=%s) under %s — research behind it may be missed\n' \
        "$_dl_rc" "${_lnk#"$TARGET"/}" >&2
    fi
    # SENTINEL-DIRLINK-WALK-WARN-END
    if [ -n "$_dl_of" ]; then
      while IFS= read -r -d '' f; do
        _is_research_file "$f" && _has_changed=1
      done < "$_dl_of"
    fi
  done
  rm -f "$_dl_of"
fi
# SENTINEL-DIRLINK-SCAN-END

# SENTINEL-ALLOW-NO-CHANGE-START
# ── (3) No changed research files and not degraded → allow ───────────────────
if [ "$_degraded" -eq 0 ] && [ "$_has_changed" -eq 0 ]; then
  _STOP_BRANCH="no-change"
  printf 'retro-gate: state=allow branch=no-change target=%s\n' "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-ALLOW-NO-CHANGE-END

# In degraded mode: scan all research files for the block mtime reference. _nb_mtime is defined
# ONLY here — it is read exactly once, by the degraded staleness check at the `elif` below,
# which only runs when $_degraded is 1.
_nb_mtime=0   # newest changed block mtime; degraded-mode only, see elif below
if [ "$_degraded" -eq 1 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _is_research_file "$f" || continue
    # SENTINEL-GENERATED-CATALOG-START
    # CATALOG.md is GENERATED (gen-catalog.py rewrites it seconds after the retro): counting it
    # as the newest "block" made every fresh retro look stale (kit issue #1229). Matched by
    # BASENAME anywhere under the target (not just $TARGET/CATALOG.md) on purpose: gen-catalog
    # writes at the corpus root, which may be a subdirectory of the target (e.g. corpus/).
    [ "$(basename "$f")" = "CATALOG.md" ] && continue
    # SENTINEL-GENERATED-CATALOG-END
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "${m:-0}" -gt "$_nb_mtime" ] && _nb_mtime="$m"
  done < <(find -H "$TARGET" -type f -name '*.md' -not -path '*/.git/*' 2>/dev/null)
fi

# ── Find newest qualifying retro (session-sha scope or mtime fallback) ────────
# SENTINEL-RETRO-SESSION-START
# Non-degraded (has session sha): a retro qualifies iff it was ADDED since
# the session-start sha (committed or staged, via --cached) or is a file
# in a retros/ directory that is newer than the session file (covers
# untracked, gitignored, and staged retros uniformly).
# Depth here is UNBOUNDED: paths (a) and (b) below use `git diff`/`git ls-files` with NO
# pathspec and no maxdepth at all, so a retros/ directory nested arbitrarily deep still
# qualifies. Only the DEGRADED mtime fallback (the `else` branch below) and the separate
# issue-seeder scan (_run_issue_seeding above) are `find -maxdepth 4`; that bound does not
# apply here.
# Renames (diff-filter R) do NOT qualify. Rename detection is forced via -M/--find-renames so
# this holds regardless of the repo's diff.renames config — see the (a) path below for why.
# No pathspec — matches corpus/retros/, examinacion-*/retros/, etc.
# --relative gives TARGET-relative paths so subdirectory targets work.
#
# Accepted tradeoffs (documented, not bugs):
#  A-fixup: a block edited AFTER a conforming retro (post-retro fix-up) re-opens
#    the gate on the NEXT session because the block mtime exceeds the retro's.
#    Degraded mtime path has the same behaviour; non-degraded allows.
#  BR-switch: switching to a branch that carries an old retro may false-allow
#    because --cached sees the retro as "added relative to session sha on main".
#    This matches the intended semantics (retro IS there for this branch) and
#    is acceptable.
#  untracked-old-retro: an untracked retro whose mtime predates the session file
#    is NOT found by path (b) (older than the session file → not -newer).
#    To qualify it must be committed or re-touched after session start.
_newest_retro=""
_nr_mtime=0
if [ "$_degraded" -eq 0 ]; then
  # (a) Committed/staged retros added since session start — ONE git call.
  # --cached compares index (HEAD + staged) against session sha.
  # --relative: paths relative to $TARGET (works when $TARGET is a git subdir).
  # --diff-filter=A: only Added entries; renames (R) excluded.
  # -M/--find-renames: forces rename detection ON regardless of the repo's diff.renames config,
  # so the outcome is the same whether or not that config is set. Without -M, a `git mv`-ed old
  # retro under diff.renames=false shows as a plain D+A pair (no R — rename detection never
  # ran), and the Added half then qualifies here as a false "new retro".
  # No pathspec: matches retros/ at any location under $TARGET.
  while IFS= read -r _rpath; do
    [ -n "$_rpath" ] || continue
    # Accept only paths under a retros/ directory (any depth)
    printf '%s\n' "$_rpath" | grep -qE '(^|/)retros/[^/].*\.md$' || continue
    # Case-insensitive index-file guard matching main's -iname '*index*.md'
    case "$(basename "$_rpath")" in *[Ii][Nn][Dd][Ee][Xx]*) continue ;; esac
    _rfull="$TARGET/$_rpath"
    [ -f "$_rfull" ] || continue
    _in_nested_worktree "$_rfull" && continue   # NW-RETRO-GUARD-COMMITTED
    retro_is_excluded "$_rfull" && continue
    m="$(stat -c %Y "$_rfull" 2>/dev/null || echo 0)"
    [ "${m:-0}" -gt "$_nr_mtime" ] && { _nr_mtime="$m"; _newest_retro="$_rfull"; }
  done < <(git -C "$TARGET" diff --cached --relative --name-only --diff-filter=A -M \
           "$_session_sha" 2>/dev/null)
  # (b) Untracked/gitignored retros newer than session file.
  # git ls-files --others (no --exclude-standard) returns all untracked files
  # INCLUDING gitignored ones, but NOT tracked (committed/staged) files.
  # This avoids false ALLOW on git-mv'd retros (tracked → excluded from --others).
  # Paths are relative to $TARGET since we use git -C "$TARGET".
  # Deliberately un-pathspec'd and unbounded: git must walk the tree to know what is untracked
  # regardless of any pathspec, so restricting this call to e.g. `*/retros/*.md` buys no
  # speedup. `git ls-files --others` scales roughly linearly with the untracked-file count and
  # stays well within Stop-hook-tolerable latency even against a large gitignored dependency-
  # style tree (hundreds of thousands of untracked files) — see PR body for the measured
  # baseline (kit convention: live-instrument timings are not persisted as doctrine here).
  if [ -f "$_session_file" ]; then
    while IFS= read -r _rpath; do
      [ -n "$_rpath" ] || continue
      printf '%s\n' "$_rpath" | grep -qE '(^|/)retros/[^/].*\.md$' || continue
      case "$(basename "$_rpath")" in *[Ii][Nn][Dd][Ee][Xx]*) continue ;; esac
      _rfull="$TARGET/$_rpath"
      [ -f "$_rfull" ] || continue
      [ "$_rfull" -nt "$_session_file" ] || continue
      _in_nested_worktree "$_rfull" && continue   # NW-RETRO-GUARD-UNTRACKED
      retro_is_excluded "$_rfull" && continue
      m="$(stat -c %Y "$_rfull" 2>/dev/null || echo 0)"
      [ "${m:-0}" -gt "$_nr_mtime" ] && { _nr_mtime="$m"; _newest_retro="$_rfull"; }
    done < <(git -C "$TARGET" ls-files --others 2>/dev/null)
  fi
else
  # DEGRADED: no session sha — fall back to mtime comparison (origin/main behaviour).
  # Degraded WARN already emitted above.
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    _in_nested_worktree "$rf" && continue   # NW-RETRO-GUARD-DEGRADED
    retro_is_excluded "$rf" && continue
    m="$(stat -c %Y "$rf" 2>/dev/null || echo 0)"
    [ "${m:-0}" -gt "$_nr_mtime" ] && { _nr_mtime="$m"; _newest_retro="$rf"; }
  done < <(find -H "$TARGET" -maxdepth 4 -path '*/retros/*.md' \
           -not -path '*/.git/*' -not -iname '*index*.md' 2>/dev/null)
fi
# SENTINEL-RETRO-SESSION-END

_retro_label="${_newest_retro:-(none)}"
_n_changed="$([ "$_degraded" -eq 0 ] && printf '%s changed' "$_has_changed" || printf 'unknown (degraded)')"

# ── Block/allow decision ──────────────────────────────────────────────────────
VERIFY_RETRO="$SELF_DIR/verify-retro.sh"
_block_reason=""
_suggest_path="$TARGET/retros/$(date +%Y-%m-%d)-<focus>.md"

# SENTINEL-BLOCK-START
if [ "$_degraded" -eq 0 ] && [ -z "$_newest_retro" ]; then
  # Session-sha mode: no retro added since session start
  # SENTINEL-ACTIONABLE-REASON-START
  _block_reason="§18 retro pending for $(basename "$TARGET"): run the SELF-RETROSPECTIVE (fresh-context retro agent) from $KIT/templates/retro.template.md → $_suggest_path, then stop. Checked: research file(s) changed, newest retro: none added this session. Template: $KIT/templates/retro.template.md"
  # SENTINEL-ACTIONABLE-REASON-END
elif [ "$_degraded" -eq 1 ] && [ "$_nr_mtime" -eq 0 ]; then
  # Degraded (mtime): no retro at all
  # SENTINEL-ACTIONABLE-REASON-START
  _block_reason="§18 retro pending for $(basename "$TARGET"): run the SELF-RETROSPECTIVE (fresh-context retro agent) from $KIT/templates/retro.template.md → $_suggest_path, then stop. Checked: research file(s) changed, newest retro: none. Template: $KIT/templates/retro.template.md"
  # SENTINEL-ACTIONABLE-REASON-END
elif [ "$_degraded" -eq 1 ] && [ "$_nb_mtime" -gt "$_nr_mtime" ]; then
  # Degraded (mtime): newest block is newer than newest retro → retro is stale
  # SENTINEL-ACTIONABLE-REASON-START
  _block_reason="§18 retro pending for $(basename "$TARGET"): newest retro $(basename "$_newest_retro") is OLDER than newest changed block. Run the SELF-RETROSPECTIVE from $KIT/templates/retro.template.md → $_suggest_path, then stop. Template: $KIT/templates/retro.template.md"
  # SENTINEL-ACTIONABLE-REASON-END
else
  # Qualifying retro found (session-sha: ADDED since session; or degraded: newer than block)
  # SENTINEL-VERIFY-RETRO-START
  if [ -f "$VERIFY_RETRO" ]; then
    _vr_out="$(bash "$VERIFY_RETRO" "$_newest_retro" 2>/dev/null)"
    _vr_rc=$?
    if [ "$_vr_rc" -eq 0 ]; then
      _STOP_BRANCH="retro-conforming"
      printf 'retro-gate: state=allow branch=retro-conforming retro=%s target=%s\n' \
        "$(basename "$_newest_retro")" "$(basename "$TARGET")" >&2
      # SENTINEL-SEEDING-CALL-START
      _run_issue_seeding "$TARGET" "$KIT"
      # SENTINEL-SEEDING-CALL-END
      exit 0
    fi
    # Non-conforming: embed verify-retro findings as actionable context
    _block_reason="§18 retro pending for $(basename "$TARGET"): $(basename "$_newest_retro") is non-conforming. Fix it (from $KIT/templates/retro.template.md) — missing elements: $_vr_out"
  else
    # verify-retro.sh absent → allow (cannot verify; log degraded)
    _STOP_BRANCH="no-verifier"
    printf 'retro-gate: state=allow branch=no-verifier (verify-retro.sh absent) target=%s\n' \
      "$(basename "$TARGET")" >&2
    exit 0
  fi
  # SENTINEL-VERIFY-RETRO-END
fi

if [ -n "$_block_reason" ]; then
  # Write block-once state file
  if [ -n "$_session_id" ]; then
    mkdir -p "$_state_dir" 2>/dev/null || true
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_blocked_file" 2>/dev/null || true
  fi
  _STOP_BRANCH="retro-pending"
  printf 'retro-gate: state=block branch=retro-pending changed=%s retro=%s target=%s\n' \
    "$_n_changed" "$(basename "$_retro_label")" "$(basename "$TARGET")" >&2
  # SENTINEL-PURE-BASH-EMITTER-START
  _reason_esc="$(_json_escape_reason "$_block_reason")"
  printf '{"decision":"block","reason":"%s"}\n' "$_reason_esc"
  # SENTINEL-PURE-BASH-EMITTER-END
fi
# SENTINEL-BLOCK-END
