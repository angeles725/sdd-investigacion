#!/usr/bin/env bash
# FROZEN LEGACY COPY - do not edit. Lines 417-455 and 489-618 of research-sdd/toolbelt/lib/hook-wiring.sh as of
# feat/rsdd-hook-wiring-2356 b6b8c8a9 (kit issue #2357, U2.3b): hook_stop_launch_state(_var), _hw_split_cmd, _hw_unv,
# _hw_check_command and hook_wired_exec_report. It needs _hw_abspath from hook-wiring-half1.sh (driver.sh sources both).
# internal/hook/differential_test.go runs it as the oracle for the Go port (its sha256 is pinned in oracle_test.go); the live
# lib no longer carries this code (it is a shim over `rsdd hook ...`).
if ! declare -F hook_stop_launch_state_var >/dev/null 2>&1; then
  hook_stop_launch_state_var() {
    local root enc d
    root="${RSDD_CLAUDE_PROJECTS_DIR:-}"
    if [ -z "$root" ]; then
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then root="$CLAUDE_CONFIG_DIR/projects"
      elif [ -n "${HOME:-}" ]; then root="$HOME/.claude/projects"
      else HOOK_LAUNCH_STATE="unknown"; return 0; fi
    fi
    if [ ! -d "$root" ] || [ ! -r "$root" ]; then
      HOOK_LAUNCH_STATE="unknown"; return 0
    fi
    _hw_abspath "$1"; d="$HW_ABS_PATH"
    case "$d" in *[!\ -~]*) HOOK_LAUNCH_STATE="unknown"; return 0 ;; esac   # HOOK-LAUNCH-NONASCII-GUARD
    # SYMLINK GUARD: Claude Code records the RESOLVED cwd; any symlinked component of the registered
    # path would make the encoded name point at the wrong directory. Builtins only (no pwd -P fork).
    local _hw_c="$d"
    while [ -n "$_hw_c" ] && [ "$_hw_c" != "/" ]; do
      if [ -L "$_hw_c" ]; then HOOK_LAUNCH_STATE="unknown"; return 0; fi  # HOOK-LAUNCH-SYMLINK-GUARD
      _hw_c="${_hw_c%/*}"
    done
    enc="${d//[^A-Za-z0-9]/-}"
    if [ "${#enc}" -gt 200 ]; then HOOK_LAUNCH_STATE="unknown"; return 0; fi   # HOOK-LAUNCH-LONGNAME-GUARD
    if compgen -G "$root/$enc/*.jsonl" >/dev/null 2>&1; then  # HOOK-LAUNCH-HISTORY-CHECK
      HOOK_LAUNCH_STATE="launched"
    else
      HOOK_LAUNCH_STATE="no-sessions"
    fi
    return 0
  }
fi

if ! declare -F hook_stop_launch_state >/dev/null 2>&1; then
  hook_stop_launch_state() {
    hook_stop_launch_state_var "$1"
    printf '%s' "$HOOK_LAUNCH_STATE"
    return 0
  }
fi

if ! declare -F hook_wired_exec_report >/dev/null 2>&1; then
  # _hw_split_cmd <command> : sets HW_WORDS (quote-aware first simple command), HW_OP=1 when an operator
  # follows it, and HW_SPLIT_ERR; rc 1 = unsplittable.
  _hw_split_cmd() {
    local s="$1" i=0 n c q="" w="" has=0
    HW_WORDS=(); HW_SPLIT_ERR=""; HW_OP=0
    n=${#s}
    while [ "$i" -lt "$n" ]; do
      c="${s:i:1}"
      if [ -n "$q" ]; then
        w+="$c"; has=1
        [ "$c" != "$q" ] || q=""
      else
        case "$c" in
          ' '|$'\t') if [ "$has" = 1 ]; then HW_WORDS+=("$w"); w=""; has=0; fi ;;
          ';'|'&'|'|'|'<'|'>'|'('|')') HW_OP=1; break ;;   # HW-OPERATOR-STOP
          '"'|"'") q="$c"; w+="$c"; has=1 ;;
          '\') HW_SPLIT_ERR="backslash escape in the command"; return 1 ;;   # HW-BACKSLASH
          *) w+="$c"; has=1 ;;
        esac
      fi
      i=$((i + 1))
    done
    [ -z "$q" ] || { HW_SPLIT_ERR="unterminated quote in the command"; return 1; }   # HW-UNTERM
    if [ "$has" = 1 ]; then HW_WORDS+=("$w"); fi
    return 0
  }
  # _hw_unv <head> <reason>
  _hw_unv() { printf 'unverifiable\t%s\t%s\n' "$1" "$2"; }
  # _hw_check_command <target> <event> <command> : prints the findings for ONE wired command.
  _hw_check_command() {
    local target="$1" ev="$2" cmd="$3" head i=0 n w cw base arg raw mode=direct viaenv=0 d
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    [ -n "$cmd" ] || return 0
    head="${cmd:0:60}"; head="${head//$'\t'/ }"
    if ! _hw_split_cmd "$cmd"; then _hw_unv "$head" "$HW_SPLIT_ERR"; return 0; fi
    n=${#HW_WORDS[@]}
    if [ "$n" -eq 0 ]; then _hw_unv "$head" "no command word before the first shell operator"; return 0; fi   # HW-NOWORD
    while [ "$i" -lt "$n" ]; do   # option-free prefixes only
      w="${HW_WORDS[$i]}"
      case "$w" in
        [A-Za-z_]*=*) case "${w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac; i=$((i + 1)) ;;   # HW-NAMEVAL
        exec|nohup|command)   # HW-WRAP-EXEC
          i=$((i + 1))
          case "${HW_WORDS[$i]:-}" in -*) _hw_unv "$head" "$w followed by an option"; return 0 ;; esac ;;
        timeout)   # HW-WRAP-TIMEOUT
          d="${HW_WORDS[$((i + 1))]:-}"
          if [[ ! "$d" =~ ^[0-9]+[smh]?$ ]]; then _hw_unv "$head" "timeout with options or a duration that is not N[smh]"; return 0; fi
          i=$((i + 2)) ;;
        *) break ;;
      esac
    done
    if [ "$i" -ge "$n" ]; then _hw_unv "$head" "no command word after the prefix"; return 0; fi
    cw="${HW_WORDS[$i]}"
    if [ "${cw##*/}" = env ]; then   # HW-ENV
      i=$((i + 1)); cw="${HW_WORDS[$i]:-}"; viaenv=1
      case "$cw" in ''|-*|*=*) _hw_unv "$head" "env with options or assignments, or without a command"; return 0 ;; esac
    fi
    base="${cw//[\"\']/}"; base="${base##*/}"
    case "$base" in
      bash|sh|zsh|python|python3|node|perl)
        case "$cw" in *[\"\']*) _hw_unv "$head" "quoted interpreter word"; return 0 ;; esac   # HW-QUOTED-INTERP
        d="${HW_WORDS[$((i + 1))]:-}"
        case "$d" in
          '') _hw_unv "$head" "interpreter without a script argument"; return 0 ;;
          -*) _hw_unv "$head" "interpreter followed by an option: a payload or an option argument could be taken for the script"; return 0 ;;   # HW-INTERP-OPT
        esac
        mode=interp; arg="$d" ;;   # HW-INTERP
      *)
        if [ "$viaenv" = 1 ]; then _hw_unv "$head" "env form that does not run an interpreter script"; return 0; fi
        arg="$cw" ;;
    esac
    raw="$arg"
    case "$raw" in
      *\'*) case "$raw" in *'$'*|*'~'*) _hw_unv "$head" "single-quoted word: the shell would not expand it"; return 0 ;; esac ;;   # HW-SQUOTE
      '"~'*) _hw_unv "$head" "~ inside double quotes: the shell would not expand it"; return 0 ;;   # HW-DQ-TILDE
    esac
    arg="${raw//\"/}"; arg="${arg//\'/}"
    case "$arg" in
      '${CLAUDE_PROJECT_DIR}'/*) arg="$target/${arg#'${CLAUDE_PROJECT_DIR}'/}" ;;
      '$CLAUDE_PROJECT_DIR'/*) arg="$target/${arg#'$CLAUDE_PROJECT_DIR'/}" ;;
      '${HOME}'/*) if [ -n "${HOME:-}" ]; then arg="$HOME/${arg#'${HOME}'/}"; fi ;;   # HW-HOME-BRACE
      '$HOME'/*) if [ -n "${HOME:-}" ]; then arg="$HOME/${arg#'$HOME'/}"; fi ;;   # HW-HOME-PLAIN
      '~'/*) if [ -n "${HOME:-}" ]; then arg="$HOME/${arg#'~'/}"; fi ;;   # HW-HOME-TILDE
    esac
    case "$arg" in
      *'$'*|*'`'*|*'*'*|*'?'*|*'['*) _hw_unv "$head" "unresolved variable, glob or substitution in the command path"; return 0 ;;   # HW-VARGLOB
      '~'*) _hw_unv "$head" "~ form that cannot be expanded here"; return 0 ;;
    esac
    if [ "$mode" = interp ]; then
      case "$arg" in /*) ;; *) _hw_unv "$head" "relative script path for an interpreter (resolved against the launch directory)"; return 0 ;; esac   # HW-INTERP-ABS
    else
      case "$arg" in
        */*) ;;
        *) if [ "$n" -eq 1 ] && [ "$i" -eq 0 ] && [ "$HW_OP" = 0 ]; then return 0; fi   # HW-BARE-ALONE: `true` alone makes no claim
           _hw_unv "$head" "bare command name with arguments, a prefix or a command chain (cd ...; a path command after an operator): not analysed"; return 0 ;;   # HW-CHAIN
      esac
      case "$arg" in /*) ;; *) arg="$target/$arg" ;; esac
    fi
    if [ -d "$arg" ]; then return 0   # HW-DIRSKIP
    elif [ -e "$arg" ]; then
      if [ "$mode" = direct ] && [ ! -x "$arg" ]; then printf 'not-executable\t%s\t%s\n' "$arg" "$ev"; fi   # WIRED-EXEC-BIT-TEST
    else
      printf 'missing\t%s\t%s\n' "$arg" "$ev"                  # absent, or a dangling symlink
    fi
    return 0
  }
  hook_wired_exec_report() {
    local target="$1" settings cmds raw rc line
    settings="$target/.claude/settings.json"
    [ -e "$settings" ] || [ -L "$settings" ] || return 0
    if [ ! -f "$settings" ] || [ ! -r "$settings" ]; then
      _hw_unv "$settings" "settings.json is not a readable file"; return 0
    fi
    if command -v jq >/dev/null 2>&1; then
      cmds="$(jq -r '(.hooks? // {}) | objects | to_entries[] | .key as $e | .value | arrays | .[] | objects | .hooks | arrays | .[] | objects | .command | strings | $e + "\t" + gsub("\n"; " ")' "$settings" 2>/dev/null)" \
        || { _hw_unv "$settings" "settings.json is not valid JSON (or jq failed)"; return 0; }
    else
      _hw_unv "$settings" "jq not on PATH: commands read by text match over every \"command\" key (may include non-hook commands, misses a value on the next line)"   # HW-NOJQ-NOTE
      raw="$(grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' "$settings" 2>/dev/null)"; rc=$?
      if [ "$rc" -gt 1 ]; then _hw_unv "$settings" "grep failed (rc $rc) reading settings.json"; return 0; fi
      cmds="$(while IFS= read -r line; do printf '?\t%s\n' "$line"; done < <(printf '%s\n' "$raw" | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g; s/\\\\/\\/g'))"
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _hw_check_command "$target" "${line%%$'\t'*}" "${line#*$'\t'}"
    done < <(printf '%s\n' "$cmds")
    return 0
  }
fi
