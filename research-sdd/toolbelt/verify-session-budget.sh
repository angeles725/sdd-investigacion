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
#   Reads <target>/.claude/settings.json ONLY (not settings.local.json, not the user-level file).
#   The hooks are computed PER SESSION SOURCE (startup, resume, clear, compact): the SessionStart entries whose
#   `matcher` selects that source ("", "*" or absent = every source; otherwise the matcher is a regex that must
#   match the whole source name, e.g. `startup|resume`). Within a source identical commands are deduplicated and
#   each distinct hook runs once, with a minimal SessionStart JSON for THAT source on stdin and
#   CLAUDE_PROJECT_DIR=<target>. Prints, per source:
#     hook[N] chars=<n> status=ok|TRUNCATED|timed-out(hook timeout Ns)|degraded(<reason>) cmd=<command>
#     aggregate[<source>]: <n> chars (budget < 8000) OK|OVER BUDGET [(partial: K degraded)]
#   then the WORST source (the one the budget verdict is about) and the typed state:
#     aggregate: <n> chars (budget < 8000) OK|OVER BUDGET [(partial: K degraded)] worst-source=<source>
#     state: ok|degraded|empty-input|absent-input
#   chars: plain stdout length, or, when stdout is a JSON object, hookSpecificOutput.additionalContext length +
#   systemMessage length. Counts are Unicode code points; Claude Code may count UTF-16 units instead (unverified),
#   so text with astral-plane characters (emoji) could read slightly higher there. TRUNCATED = any single field
#   over 10,000.
#   Typed states (never a silent zero): a hook that exits non-zero, cannot be resolved, or outlives this script's cap
#   is `degraded(<reason>)` and is never counted as 0 (its partial output is discarded; the aggregate is marked
#   partial). A hook that outlives ITS OWN `timeout` field (default 600 s, capped here to RSDD_BUDGET_HOOK_TIMEOUT,
#   default 60 s) is killed by Claude Code too, so it contributes nothing: `timed-out(hook timeout Ns)`, counted
#   as 0 with that note. Missing settings = `absent-input`; no SessionStart command hook for any source =
#   `empty-input`; unreadable settings JSON, jq missing, an unusable sandbox, a missing UTF-8 locale for `wc -m`,
#   or an incomplete sandbox copy = degraded, said by name.
#
# READ-ONLY toward the target (propose-never-apply, CLAUDE.md §8). Hooks do write (the protocol hook records a
# session-sha file under <target>/.claude/), so they are NEVER run against the live tree: each runs in a bubblewrap
# sandbox with the whole filesystem read-only, <target>/.claude replaced by a throwaway COPY (minus .claude/worktrees),
# TMPDIR pointed at a throwaway dir, no network (--unshare-net), no inherited IPC namespace, no controlling terminal
# (--new-session, so no TIOCSTI injection), and the usual agent/socket variables (SSH_AUTH_SOCK, ...) removed.
# A hook that needs the network, an agent socket or a path outside TMPDIR therefore shows `degraded` or a lower count:
# acceptable for a budget probe, and said here rather than hidden. At startup `bwrap --ro-bind / / true` is probed;
# a bwrap that is absent or cannot start (unprivileged user namespaces restricted, e.g. some CI images) makes every hook
# `degraded(no-sandbox: <reason>)`: nothing is ever run unprotected.
#
# Env: RSDD_BUDGET_HOOK_TIMEOUT per-hook cap in seconds (default 60; Claude Code's command-hook default is 600 s).
# Exit: 0 always for findings and degraded states (WARN-only) · 2 usage error (no/unknown target dir).
set -uo pipefail

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: verify-session-budget.sh <target-dir>" >&2; exit 2; }
target="$(cd "$1" && pwd -P)"
cap=10000
budget=8000
to_cap="${RSDD_BUDGET_HOOK_TIMEOUT:-60}"
case "$to_cap" in ''|*[!0-9]*|0) to_cap=60;; esac
sources="startup resume clear compact"

echo "verify-session-budget: $target"
settings="$target/.claude/settings.json"
if [ ! -f "$settings" ]; then echo "state: absent-input (no $settings)"; exit 0; fi
if ! command -v jq >/dev/null 2>&1; then echo "state: degraded (jq unavailable; no hook was run)"; exit 0; fi
if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then echo "state: degraded (settings.json is not a readable JSON object; no hook was run)"; exit 0; fi

work="$(mktemp -d)" || { echo "state: degraded (cannot create a temp dir)"; exit 0; }
trap 'rm -rf "$work"' EXIT

# Per-source records, NUL-delimited (a command may contain newlines): <command> \x01 <timeout-or-empty> \0
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
sel='[.hooks.SessionStart[]? | select((.matcher // "") as $m | ($m == "" or $m == "*" or ($src | test("^(?:" + $m + ")$"))))
      | .hooks[]? | select(.type == "command" and (.command | type) == "string")
      | [.command, ((.timeout // "") | tostring)]] | .[] | .[0] + "\u0001" + .[1] + "\u0000"'
anyrec=0
for src in $sources; do
  if ! jq -j --arg src "$src" "$sel" "$settings" > "$work/recs.$src" 2>"$work/jqerr"; then
    echo "state: degraded (cannot select SessionStart hooks for source $src: $(head -1 "$work/jqerr")); no hook was run"; exit 0
  fi
  [ -s "$work/recs.$src" ] && anyrec=1
done
if [ "$anyrec" = 0 ]; then echo "state: empty-input (no SessionStart command hook matches startup, resume, clear or compact in $settings)"; exit 0; fi

# --- sandbox probe: bwrap present AND able to start -------------------------------------------------------
sandbox_reason=""
if ! command -v bwrap >/dev/null 2>&1; then sandbox_reason="bwrap not installed"
elif ! command -v timeout >/dev/null 2>&1; then sandbox_reason="timeout not installed"
elif ! perr="$(bwrap --ro-bind / / true 2>&1)"; then sandbox_reason="bwrap cannot start: $(printf '%s' "$perr" | head -1 | cut -c1-120)"
fi
# --- locale probe: `wc -m` must count characters, not bytes -------------------------------------------------
utf8_ok=1
[ "$(printf 'é' | LC_ALL=C.UTF-8 wc -m 2>/dev/null | tr -d ' ')" = 1 ] || utf8_ok=0

# --- throwaway copy of <target>/.claude ---------------------------------------------------------------------
_sb_dotclaude="$work/dotclaude"; _sb_tmp="$work/tmp"; mkdir -p "$_sb_dotclaude" "$_sb_tmp"
copy_fail=""
if [ -d "$target/.claude" ]; then
  for e in "$target/.claude"/* "$target/.claude"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "$(basename "$e")" = worktrees ] && continue
    cp -a "$e" "$_sb_dotclaude/" 2>"$work/cperr" || copy_fail="$(head -1 "$work/cperr" | cut -c1-120)"
  done
fi

# run_hook <source> <command> <declared-timeout-or-empty> : sets H_LINE (status text), H_CHARS, H_KIND (ok|trunc|zero|deg)
run_hook() {
  local src="$1" cmd="$2" decl="$3" eff out rc first=0 second=0 stdin_json
  H_CHARS=0; H_KIND=deg
  if [ -n "$sandbox_reason" ]; then H_LINE="degraded(no-sandbox: $sandbox_reason)"; return; fi
  if [ -n "$copy_fail" ]; then H_LINE="degraded(incomplete-sandbox-copy: $copy_fail)"; return; fi
  case "$decl" in ''|*[!0-9]*) decl="";; esac
  eff="${decl:-600}"; [ "$eff" -gt "$to_cap" ] && eff="$to_cap"; [ "$eff" -lt 1 ] && eff=1
  out="$work/out"; : > "$out"
  stdin_json="$(printf '{"session_id":"budget-probe","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$src" "$target")"
  printf '%s' "$stdin_json" | timeout -k 2 "$eff" bwrap --ro-bind / / --dev /dev --proc /proc \
    --bind "$_sb_dotclaude" "$target/.claude" --bind "$_sb_tmp" "$_sb_tmp" \
    --setenv TMPDIR "$_sb_tmp" --setenv CLAUDE_PROJECT_DIR "$target" \
    --unsetenv SSH_AUTH_SOCK --unsetenv SSH_AGENT_PID --unsetenv GPG_AGENT_INFO \
    --unsetenv DBUS_SESSION_BUS_ADDRESS --unsetenv XDG_RUNTIME_DIR \
    --unshare-pid --unshare-net --unshare-ipc --new-session --die-with-parent --chdir "$target" \
    bash -c "$cmd" >"$out" 2>/dev/null
  rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    if [ -n "$decl" ] && [ "$decl" -le "$to_cap" ]; then
      H_LINE="timed-out(hook timeout ${decl}s)"; H_KIND=zero; return
    fi
    H_LINE="degraded(timeout ${eff}s: this script's cap; the hook allows ${decl:-600}s)"; return
  elif [ "$rc" != 0 ]; then
    H_LINE="degraded(exit $rc)"; return
  fi
  if jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
    first="$(jq -r '((.hookSpecificOutput.additionalContext // "") | tostring | length)' "$out" 2>/dev/null)"
    second="$(jq -r '((.systemMessage // "") | tostring | length)' "$out" 2>/dev/null)"
  else
    if [ "$utf8_ok" = 0 ]; then H_LINE="degraded(no-utf8-locale: wc -m would count bytes)"; return; fi
    first="$(LC_ALL=C.UTF-8 wc -m < "$out" | tr -d ' ')"
  fi
  H_CHARS=$((first + second)); H_KIND=ok; H_LINE=ok
  if [ "$first" -gt "$cap" ] || [ "$second" -gt "$cap" ]; then H_LINE=TRUNCATED; H_KIND=trunc; fi
}

verdict_of() { if [ "$1" -ge "$budget" ]; then echo "OVER BUDGET"; else echo OK; fi; }

wtotal=-1; wsrc=""; wdeg=0; ndeg_all=0; nhooks_all=0; ntrunc_all=0
for src in $sources; do
  if [ ! -s "$work/recs.$src" ]; then echo "source $src: (no matching SessionStart hooks)"; continue; fi
  echo "source $src:"
  n=0; total=0; ndeg=0; seen=()
  while IFS= read -r -d '' rec; do
    cmd="${rec%%$'\x01'*}"; decl="${rec#*$'\x01'}"
    dup=0; for s in "${seen[@]+"${seen[@]}"}"; do [ "$s" = "$cmd" ] && dup=1 && break; done
    [ "$dup" = 1 ] && continue
    seen+=("$cmd"); n=$((n+1)); nhooks_all=$((nhooks_all+1))
    run_hook "$src" "$cmd" "$decl"
    shown="${cmd//$'\n'/ \\n }"
    if [ "$H_KIND" = deg ]; then
      echo "hook[$n] chars=n/a status=$H_LINE cmd=$shown"; ndeg=$((ndeg+1))
    else
      echo "hook[$n] chars=$H_CHARS status=$H_LINE cmd=$shown"; total=$((total + H_CHARS))
      [ "$H_KIND" = trunc ] && ntrunc_all=$((ntrunc_all+1))
    fi
  done < "$work/recs.$src"
  partial=""; [ "$ndeg" -gt 0 ] && partial=" (partial: $ndeg degraded)"
  echo "aggregate[$src]: $total chars (budget < $budget) $(verdict_of "$total")$partial"
  ndeg_all=$((ndeg_all+ndeg))
  if [ "$total" -gt "$wtotal" ]; then wtotal=$total; wsrc=$src; wdeg=$ndeg; fi
done

partial=""; [ "$wdeg" -gt 0 ] && partial=" (partial: $wdeg degraded)"
echo "aggregate: $wtotal chars (budget < $budget) $(verdict_of "$wtotal")$partial worst-source=$wsrc"
if [ "$ndeg_all" -gt 0 ]; then
  echo "state: degraded ($ndeg_all of $nhooks_all hook runs could not be measured)"
else
  echo "state: ok ($nhooks_all hook runs, $ntrunc_all truncated)"
fi
exit 0
