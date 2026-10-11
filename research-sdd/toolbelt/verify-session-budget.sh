#!/usr/bin/env bash
# verify-session-budget.sh — measure what a target's SessionStart hooks actually hand to Claude (kit issue #2129).
#
# Why: Claude Code caps each hook's additionalContext / systemMessage / plain stdout at 10,000 characters;
# the excess is saved to a file and replaced by its path plus a 2,000-char preview Claude is not told to
# read (https://code.claude.com/docs/en/hooks). The kit budget for SessionStart is < 8,000 characters in
# total (openspec/specs/kit-session-cost/spec.md). A hook that "works" but is silently truncated is the
# §7 false-confidence shape (kit issue #2128: two 11-12 k corpus cards).
#
# Usage: verify-session-budget.sh <target-dir>
#   Reads <target>/.claude/settings.json ONLY (not settings.local.json, not the user-level file), runs every
#   command under hooks.SessionStart (all matchers) with a minimal SessionStart JSON on stdin and
#   CLAUDE_PROJECT_DIR=<target>, each under a per-hook timeout, and prints:
#     hook[N] chars=<n> status=ok|TRUNCATED|degraded(<reason>) cmd=<command>
#     aggregate: <n> chars (budget < 8000) OK|OVER BUDGET [(partial: K degraded)]
#     state: ok|degraded|empty-input|absent-input
#   chars: plain stdout length, or, when stdout is a JSON object, hookSpecificOutput.additionalContext
#   length + systemMessage length. TRUNCATED when any single field is over 10,000.
#   A hook that times out, exits non-zero, or cannot be resolved is `degraded` for that hook and is never
#   counted as 0 (its partial output is discarded); the aggregate is then marked partial.
#   absent-input = no settings.json; empty-input = settings.json with no SessionStart command hook.
#
# READ-ONLY toward the target (propose-never-apply, CLAUDE.md §8). Hooks do write (the protocol hook records
# a session-sha file under <target>/.claude/), so they are NEVER run against the live tree: each run happens
# in a bubblewrap sandbox with the whole filesystem read-only, <target>/.claude replaced by a throwaway COPY
# (minus .claude/worktrees), and TMPDIR pointed at a throwaway dir. Without `bwrap` (or `timeout`) nothing is
# executed: every hook is reported degraded(no-sandbox) rather than run unprotected.
#
# Env: RSDD_BUDGET_HOOK_TIMEOUT per-hook seconds (default 30; command hooks default to 600 s in Claude Code).
# Exit: 0 always for findings and degraded states (WARN-only) · 2 usage error (no/unknown target dir).
set -uo pipefail

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: verify-session-budget.sh <target-dir>" >&2; exit 2; }
target="$(cd "$1" && pwd -P)"
cap=10000
budget=8000
to="${RSDD_BUDGET_HOOK_TIMEOUT:-30}"
case "$to" in ''|*[!0-9]*|0) to=30;; esac

echo "verify-session-budget: $target"
settings="$target/.claude/settings.json"
if [ ! -f "$settings" ]; then echo "state: absent-input (no $settings)"; exit 0; fi
if ! command -v jq >/dev/null 2>&1; then echo "state: degraded (jq unavailable; no hook was run)"; exit 0; fi
cmds="$(jq -r '[.hooks.SessionStart[]?.hooks[]? | select(.type == "command") | .command] | .[]' "$settings" 2>/dev/null)" || { echo "state: degraded (settings.json is not readable JSON)"; exit 0; }
if [ -z "$cmds" ]; then echo "state: empty-input (no SessionStart command hooks in $settings)"; exit 0; fi

sandbox_ok=1
command -v bwrap >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || sandbox_ok=0

work="$(mktemp -d)" || { echo "state: degraded (cannot create a temp dir)"; exit 0; }
trap 'rm -rf "$work"' EXIT
_sb_dotclaude="$work/dotclaude"; _sb_tmp="$work/tmp"; mkdir -p "$_sb_dotclaude" "$_sb_tmp"
if [ -d "$target/.claude" ]; then
  for e in "$target/.claude"/* "$target/.claude"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "$(basename "$e")" = worktrees ] && continue
    cp -a "$e" "$_sb_dotclaude/" 2>/dev/null
  done
fi
stdin_json="$(printf '{"session_id":"budget-probe","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$target")"

n=0; total=0; ndeg=0; ntrunc=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  n=$((n+1)); out="$work/out.$n"; : > "$out"
  if [ "$sandbox_ok" = 0 ]; then
    echo "hook[$n] chars=n/a status=degraded(no-sandbox) cmd=$cmd"; ndeg=$((ndeg+1)); continue
  fi
  printf '%s' "$stdin_json" | timeout -k 2 "$to" bwrap --ro-bind / / --dev /dev --proc /proc \
    --bind "$_sb_dotclaude" "$target/.claude" --bind "$_sb_tmp" "$_sb_tmp" \
    --setenv TMPDIR "$_sb_tmp" --setenv CLAUDE_PROJECT_DIR "$target" \
    --unshare-pid --die-with-parent --chdir "$target" \
    bash -c "$cmd" >"$out" 2>/dev/null
  rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    echo "hook[$n] chars=n/a status=degraded(timeout ${to}s) cmd=$cmd"; ndeg=$((ndeg+1)); continue
  elif [ "$rc" != 0 ]; then
    echo "hook[$n] chars=n/a status=degraded(exit $rc) cmd=$cmd"; ndeg=$((ndeg+1)); continue
  fi
  first=0; second=0
  if jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
    first="$(jq -r '((.hookSpecificOutput.additionalContext // "") | tostring | length)' "$out" 2>/dev/null)"
    second="$(jq -r '((.systemMessage // "") | tostring | length)' "$out" 2>/dev/null)"
  else
    first="$(LC_ALL=C.UTF-8 wc -m < "$out" | tr -d ' ')"
  fi
  chars=$((first + second)); total=$((total + chars))
  if [ "$first" -gt "$cap" ] || [ "$second" -gt "$cap" ]; then st=TRUNCATED; ntrunc=$((ntrunc+1)); else st=ok; fi
  echo "hook[$n] chars=$chars status=$st cmd=$cmd"
done <<<"$cmds"

verdict=OK; [ "$total" -ge "$budget" ] && verdict="OVER BUDGET"
partial=""; [ "$ndeg" -gt 0 ] && partial=" (partial: $ndeg degraded)"
echo "aggregate: $total chars (budget < $budget) $verdict$partial"
if [ "$ndeg" -gt 0 ]; then echo "state: degraded ($ndeg of $n hooks could not be measured)"; else echo "state: ok ($n hooks, $ntrunc truncated)"; fi
exit 0
