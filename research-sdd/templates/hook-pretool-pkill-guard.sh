#!/usr/bin/env bash
# hook-pretool-pkill-guard.sh — PreToolUse (Bash) guard against self-matching `pkill -f` / `pgrep -f`
# (kit issue #1244; replaces the prose PKILL -F WRAPPER-SHELL MATCH rule in PROMPT-LOOP).
#
# WHY: `pkill -f <pattern>` matches the FULL command line of every process, including the `zsh -c` /
# `bash -c` wrapper the harness runs this very Bash call in — the pattern text sits in that wrapper's
# own argv, so pkill signals the session shell (exit 144). `kill $(pgrep -f <pattern>)` returns the same
# wrapper PIDs. A bracket-escaped pattern (`[p]attern`) does not match its own text, so it is safe.
#
# Install: copy to <TARGET>/.claude/hooks/pkill-guard.sh and register under hooks.PreToolUse with
# matcher "Bash" in <TARGET>/.claude/settings.json (propose-never-apply: the operator installs it).
#
# Contract (Claude Code PreToolUse): reads the hook JSON on stdin; ALWAYS exits 0.
#   DENY  = stdout {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#           "permissionDecisionReason":"..."}}
#   ALLOW = no stdout.
# Refused: a command-position `pkill`/`pgrep` carrying -f / --full (and not -x / --exact) whose
# positional pattern has no bracket expression `[x]`. A variable or empty pattern cannot be proven
# escaped, so it is refused too. Prose that merely MENTIONS pkill -f (a commit message, a grep) is not
# at command position and is allowed. Known limit: a heredoc body line that starts with `pkill -f`
# is read as a command and refused — rephrase or use the alternatives below.
# Degraded (§7: could the instrument run at all?): without jq, or with unparseable stdin, the command
# cannot be extracted — a typed `degraded: pkill-guard: ...` line goes to stderr and, when the raw
# payload contains pkill/pgrep, the decision is "ask" (never a silent allow).
set -uo pipefail

_ALTERNATIVES='Safe alternatives: (a) record the PID at spawn ($! or a PID file) and kill that PID; (b) match by exact process name: pkill -x <name> / pgrep -x <name>; (c) bracket-escape the pattern so it cannot match its own text: pkill -f "[p]attern". See PROMPT-LOOP "PKILL -F WRAPPER-SHELL MATCH".'

_input="$(cat)"
[ -n "$_input" ] || exit 0

_emit() { # <decision> <reason>
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg d "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  fi
}

_cmd=""
if command -v jq >/dev/null 2>&1 && _cmd="$(printf '%s' "$_input" | jq -er 'if (.tool_name // "") == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)"; then
  :
else
  if command -v jq >/dev/null 2>&1; then _why="stdin is not parseable PreToolUse JSON"; else _why="jq missing"; fi
  printf 'degraded: pkill-guard: %s — cannot inspect the command\n' "$_why" >&2
  if printf '%s' "$_input" | grep -Eq 'pkill|pgrep'; then
    _emit ask "pkill-guard degraded ($_why): this payload mentions pkill/pgrep and could not be checked for a self-matching -f pattern. Confirm the pattern is bracket-escaped or use -x / a PID file."
  fi
  exit 0
fi
[ -n "$_cmd" ] || exit 0

# Flatten: drop quotes (so `bash -c 'pkill -f x'` and `pkill -f '[p]x'` both become plain words) and
# turn every command separator into a newline, leaving [ ] intact for the bracket test.
_bracket_re='\[[^]]+\]'
_flat="$(printf '%s' "$_cmd" | tr -d "'\"" | tr ';&|(){}`$' '\n\n\n\n\n\n\n\n\n')"

_bad=""
while IFS= read -r _seg; do
  read -ra _tok <<<"$_seg"
  _i=0
  # skip wrappers / flags / env assignments / numeric args (timeout 5) before the command word
  while [ "$_i" -lt "${#_tok[@]}" ]; do
    case "${_tok[$_i]}" in
      sudo|exec|env|nohup|xargs|time|timeout|bash|sh|zsh|dash|then|do|else|'!') _i=$((_i+1)) ;;
      -*|*=*|[0-9]*) _i=$((_i+1)) ;;
      *) break ;;
    esac
  done
  [ "$_i" -lt "${#_tok[@]}" ] || continue
  case "${_tok[$_i]##*/}" in
    pkill|pgrep) ;;
    *) continue ;;
  esac
  _name="${_tok[$_i]##*/}"
  _f=0; _x=0; _pat=""
  for ((_j=_i+1; _j<${#_tok[@]}; _j++)); do
    case "${_tok[$_j]}" in
      --full) _f=1 ;;
      --exact) _x=1 ;;
      --*) ;;
      -*)
        case "${_tok[$_j]}" in *f*) _f=1 ;; esac
        case "${_tok[$_j]}" in *x*) _x=1 ;; esac ;;
      *) _pat="$_pat ${_tok[$_j]}" ;;
    esac
  done
  [ "$_f" = 1 ] && [ "$_x" = 0 ] || continue
  _has_bracket=0
  [[ "$_pat" =~ $_bracket_re ]] && _has_bracket=1
  if [ "$_has_bracket" = 0 ]; then _bad="$_name -f${_pat:+ }${_pat# }"; break; fi
done <<<"$_flat"

[ -n "$_bad" ] || exit 0
_emit deny "Refused \`$_bad\`: an unescaped -f pattern also matches this shell's own wrapper command line and kills the session (exit 144). $_ALTERNATIVES"
exit 0
