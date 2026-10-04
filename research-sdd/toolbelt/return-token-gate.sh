#!/usr/bin/env bash
# return-token-gate.sh — Stop-hook body: blocks ONCE when the final report's continuation token is missing or differs
# from the provider-issued one (kit issue #1706, slice 2; slice 1 added `research-sdd-status.sh --next --emit-token`).
#
# WHY: PROMPT-LOOP's RETURN CONTRACT says "copy the `return-token:` line, never compose it", but a prompt rule alone
# is what already failed (corpus evidence: sdd-mental-model-bloque31.md §31.11, bloque34.md §34.5 — gentle-ai's Stop
# hook re-states the exact provider-issued command and reminds ONCE per session and candidate; it never runs the
# command itself). This hook is the same shape: it states the exact line to copy, once, and gets out of the way.
#
# Usage: return-token-gate.sh [<target>]
#   <target> defaults to the hook JSON's `cwd`. Reads Claude Code Stop-hook JSON on stdin
#   (session_id, transcript_path, cwd, stop_hook_active). Always exits 0 (hook contract).
#   BLOCK = stdout {"decision":"block","reason":"<actionable text>"}      ALLOW = no stdout.
#   Every decision except "not a corpus target" prints ONE typed stderr line (kit CLAUDE.md section 7 — never silent):
#     return-token-gate: state=allow|block branch=<branch> ...
#   branches: match · override · unavailable · loop-safety · block-once · degraded (<reason>) · mismatch · missing.
#
# DECISION, in order:
#   1. no jq / unreadable hook JSON / no target                  -> allow, branch=degraded (<reason>)
#   2. stop_hook_active=true                                     -> allow, branch=loop-safety
#   3. no RESEARCH-STATE under the target (not a corpus)         -> allow, NOTHING printed (not this hook's business)
#   4. final report unreadable (no file, no assistant text)      -> allow, branch=degraded (transcript unreadable|no assistant text)
#   5. report has a `return-token-override: <reason>` line       -> allow, branch=override (the reason is printed)
#   6. run `research-sdd-status.sh <target> --next --emit-token`; no `return-token:` line at all
#                                                                -> allow, branch=degraded (status produced no return-token line)
#   7. emitted token is `return-token: unavailable (<reason>)`   -> allow, branch=unavailable (the reason is printed): that
#                                                                   line is NOT a token, so there is nothing to compare
#   8. this (session, emitted token) was already blocked         -> allow, branch=block-once
#   9. report token == emitted token                             -> allow, branch=match
#  10. report carries no token / a different token               -> BLOCK once, branch=missing | mismatch; the reason quotes the
#                                                                   exact emitted line on its own line, to copy verbatim
#
# TOKEN GRAMMAR (PROMPT-LOOP RETURN CONTRACT "CONTINUATION TOKEN"). The REPORT is the text blocks of the LAST
# main-thread (non-isSidechain) assistant message that has any text. Within it a line is a token line when, after
# trimming leading whitespace, an optional markdown list marker (`- ` `* ` `> `) and an optional opening backtick,
# and after an optional `return-token: ` prefix, it starts with one of
#     next: <non-space...>             next-entry: <non-space...>
#     STOP: campaign <...>             (covers `STOP: campaign — <reason>` and `STOP: campaign-bound-reached: <which>`)
# The LAST token line of the report wins. The reported token is that line with the `return-token: ` prefix removed
# and trailing whitespace/backticks trimmed; it is compared BYTE FOR BYTE with the emitted line minus its
# `return-token: ` prefix. `return-token: unavailable (...)` is deliberately not a token line.
# OVERRIDE: a line `return-token-override: <reason>` (non-empty reason) anywhere in the report allows.
#
# BLOCK-ONCE: marker file <target>/.claude/.rsdd-return-token-blocked-<session> lists each emitted token line already
# blocked in that session; the same session is blocked at most once PER emitted token (the gentle-ai "once per session
# and candidate" shape: when the corpus moves on and the expected token changes, a stale copy is caught again).
#
# propose-never-apply: the only write is that marker, under <target>/.claude, never the corpus content. A failed marker
# write is a typed stderr WARN and the block still goes out (stop_hook_active stops the loop on the next Stop).
# Out of scope here: wiring this hook into settings / research-sdd-init.sh (follow-up).

set -uo pipefail

# -P/pwd -P: see research-sdd/toolbelt/verify-cd-physical.sh's own header for why (kit issue #1024).
SELF_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
_TGT_LABEL="?"

_log() { printf 'return-token-gate: %s target=%s\n' "$1" "$_TGT_LABEL" >&2; }
_degraded_allow() { _log "state=allow branch=degraded ($1)"; exit 0; }

# ── Probe: jq is required to read the hook JSON and the transcript ───────────
if ! command -v jq >/dev/null 2>&1; then  # RTG-JQ-PROBE
  _degraded_allow "jq missing — cannot read hook JSON"
fi

# ── Hook JSON ────────────────────────────────────────────────────────────────
_json="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$_json"; then
  _degraded_allow "hook JSON unreadable"
fi
_session_id="$(jq -r '.session_id // empty' <<<"$_json" 2>/dev/null)" || _session_id=""
_stop_active="$(jq -r '.stop_hook_active // false' <<<"$_json" 2>/dev/null)" || _stop_active="false"
_transcript="$(jq -r '.transcript_path // empty' <<<"$_json" 2>/dev/null)" || _transcript=""
_cwd="$(jq -r '.cwd // empty' <<<"$_json" 2>/dev/null)" || _cwd=""

_target_arg="${1:-$_cwd}"
if [ -z "$_target_arg" ]; then _degraded_allow "no target — neither an argument nor a hook cwd"; fi
TARGET="$(cd "$_target_arg" 2>/dev/null && pwd)" || _degraded_allow "no target — not a directory: $_target_arg"
_TGT_LABEL="$(basename "$TARGET")"

# ── (2) Loop safety ──────────────────────────────────────────────────────────
if [ "$_stop_active" = "true" ]; then  # RTG-LOOP-SAFETY
  _log "state=allow branch=loop-safety stop_hook_active=true"
  exit 0
fi

# ── (3) Not a corpus target: allow silently ──────────────────────────────────
# shellcheck source=lib/state-files.sh
. "$SELF_DIR/lib/state-files.sh" 2>/dev/null
declare -F list_state_files >/dev/null 2>&1 || _degraded_allow "lib/state-files.sh unavailable — cannot tell whether the target is a corpus"
_states="$(list_state_files "$TARGET")"
if [ -z "$_states" ]; then exit 0; fi  # RTG-NOT-TARGET

# ── (4) The final report ─────────────────────────────────────────────────────
if [ -z "$_transcript" ] || [ ! -r "$_transcript" ]; then  # RTG-TRANSCRIPT-DEGRADED
  _degraded_allow "transcript unreadable: ${_transcript:-no transcript_path in the hook JSON}"
fi
# Last main-thread assistant message with any text; content may be a string or a list of blocks; lines that are not
# JSON are skipped (fromjson?) so one torn line cannot hide the report.
_report="$(jq -Rrs '
  split("\n") | map(fromjson? // empty) | map(select(type == "object" and .type == "assistant" and (.isSidechain != true)))  # RTG-SIDECHAIN
  | map(.message.content
        | if type == "string" then .
          elif type == "array" then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
          else "" end)
  | map(select(length > 0)) | last // empty' "$_transcript" 2>/dev/null)" || _report=""
if [ -z "$_report" ]; then _degraded_allow "no assistant text in the transcript: $(basename "$_transcript")"; fi

# ── token extraction (grammar in the header) ─────────────────────────────────
_reported=""; _override=""
while IFS= read -r _line || [ -n "$_line" ]; do
  _l="${_line#"${_line%%[![:space:]]*}"}"
  case "$_l" in
    "return-token-override:"*)
      _why="${_l#return-token-override:}"; _why="${_why#"${_why%%[![:space:]]*}"}"
      [ -z "$_why" ] || _override="$_why"  # RTG-OVERRIDE-REASON
      continue ;;
  esac
  case "$_l" in "- "*|"* "*|"> "*) _l="${_l:2}" ;; esac  # RTG-BULLET
  _l="${_l#\`}"  # RTG-BACKTICK
  _l="${_l#return-token: }"  # RTG-PREFIX
  case "$_l" in
    "next: "[![:space:]]*|"next-entry: "[![:space:]]*|"STOP: campaign"*)  # RTG-TOKEN-PATTERN
      _l="${_l%"${_l##*[![:space:]\`]}"}"  # RTG-TRIM trailing whitespace and backticks
      _reported="$_l" ;;  # RTG-LAST-WINS
  esac
done <<<"$_report"

# ── (5) Explicit override ────────────────────────────────────────────────────
if [ -n "$_override" ]; then  # RTG-OVERRIDE
  _log "state=allow branch=override reason=$_override"
  exit 0
fi

# ── (6) The provider-issued token ────────────────────────────────────────────
_status="$SELF_DIR/research-sdd-status.sh"
# Keep well under Claude Code's default per-hook budget (currently 60s): a slow status run must
# return a typed degraded allow, never let the hook runner kill us mid-write. Override with
# RETURN_TOKEN_GATE_TIMEOUT_SECS. When `timeout` is absent (e.g. stock macOS), we degrade rather
# than run the status call unbounded.
_to_secs="${RETURN_TOKEN_GATE_TIMEOUT_SECS:-20}"
if command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC2086 # intentional word-split of the timeout invocation
  _st_out="$(timeout "$_to_secs" bash "$_status" "$TARGET" --next --emit-token 2>/dev/null)"; _st_rc=$?
  [ "$_st_rc" = 124 ] && _degraded_allow "status --next timed out after ${_to_secs}s"  # RTG-STATUS-TIMEOUT
else
  _degraded_allow "no 'timeout' command — cannot bound the status call within the hook budget"  # RTG-NO-TIMEOUT
fi
_emitted=""
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in "return-token: "*) _emitted="$_line" ;; esac
done <<<"$_st_out"
if [ -z "$_emitted" ]; then  # RTG-STATUS-DEGRADED
  _degraded_allow "status produced no return-token line (rc=$_st_rc)"
fi

# ── (7) unavailable is not a token: never block ──────────────────────────────
case "$_emitted" in
  "return-token: unavailable"*)  # RTG-UNAVAILABLE-ALLOW
    _log "state=allow branch=unavailable ${_emitted#return-token: }"
    exit 0 ;;
esac

# ── (8) block-once, per session and emitted token ────────────────────────────
_state_dir="$TARGET/.claude"
_sid_safe="${_session_id//[^A-Za-z0-9._-]/_}"
_marker="$_state_dir/.rsdd-return-token-blocked-${_sid_safe}"
if [ -n "$_sid_safe" ] && [ -f "$_marker" ] && grep -qxF -- "$_emitted" "$_marker" 2>/dev/null; then  # RTG-BLOCK-ONCE
  _log "state=allow branch=block-once session=$_sid_safe"
  exit 0
fi

# ── (9) compare ──────────────────────────────────────────────────────────────
_expected="${_emitted#return-token: }"
if [ -n "$_reported" ] && [ "$_reported" = "$_expected" ]; then  # RTG-COMPARE
  _log "state=allow branch=match"
  exit 0
fi

# ── (10) block once ──────────────────────────────────────────────────────────
if [ -z "$_reported" ]; then  # RTG-MISSING-BRANCH
  _branch="missing"
  _reason="The final report carries no continuation token (PROMPT-LOOP RETURN CONTRACT: end every report with exactly one). Do not compose it; copy this provider-issued line verbatim as the last line of your report:

$_emitted

If ending without the token is deliberate, add a line 'return-token-override: <reason>'. This gate blocks once per session and token."  # RTG-NOTOKEN-BLOCK
else
  _branch="mismatch"
  _reason="The final report's continuation token does not match the provider-issued one (reported: '$_reported'). Do not compose the token; replace it with this line, copied verbatim:

$_emitted

If the difference is deliberate, add a line 'return-token-override: <reason>'. This gate blocks once per session and token."
fi
if [ -n "$_sid_safe" ]; then
  if mkdir -p "$_state_dir" 2>/dev/null && printf '%s\n' "$_emitted" >> "$_marker" 2>/dev/null; then :; else
    printf 'return-token-gate: WARN: block-once marker write failed (%s) — the block is still issued\n' "$_marker" >&2
  fi
fi
_log "state=block branch=$_branch"
jq -nc --arg r "$_reason" '{decision:"block",reason:$r}'
exit 0
