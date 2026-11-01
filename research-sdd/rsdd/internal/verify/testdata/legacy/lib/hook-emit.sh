#!/usr/bin/env bash
# hook-emit.sh — shared helper: emit a SessionStart hook's additionalContext envelope (kit issue #1877).
#
# WHY: eight *-hook.sh wrappers each carried their own copy of the same 4-6 line block —
#   if command -v jq ...; then jq -n --arg ... '{hookSpecificOutput:{hookEventName:"SessionStart",...}}'
#   else printf '%s\n%s\n' ...; fi
# — about 17 sites in all, and the envelope shape is a contract with the harness. One definition means a
# future change to the envelope (or to the jq-missing fallback) is made once.
#
#   rsdd_hook_emit [HDR] BODY
#     With jq on PATH: prints {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":C}}
#     where C is "HDR\nBODY" (two args) or BODY alone (one arg).
#     Without jq: prints the same text as plain stdout — `printf '%s\n%s\n' HDR BODY` (two args) or
#     `printf '%s\n' BODY` (one arg) — which still shows in the transcript. Never fails (returns 0).
#
# Sourced by the hooks as "$here/lib/hook-emit.sh", so a hook COPY under test needs lib/hook-emit.sh
# beside it. research-sdd/templates/hook-sessionstart.sh is deliberately NOT a consumer: it is copied into
# target repos and must stay self-contained.
#
# Idempotent: safe to source more than once.
if ! declare -F rsdd_hook_emit >/dev/null 2>&1; then
  rsdd_hook_emit() {
    local ctx
    if [ "$#" -ge 2 ]; then
      ctx="$1"$'\n'"$2"
    else
      ctx="$1"
    fi
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg c "$ctx" \
        '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
    elif [ "$#" -ge 2 ]; then
      printf '%s\n%s\n' "$1" "$2"
    else
      printf '%s\n' "$1"
    fi
    return 0
  }
fi
