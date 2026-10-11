#!/usr/bin/env bash
# verify-registry-wired-exec.test.sh — kit issue #2141: verify-registry.sh reports a hook wired in a
# target's .claude/settings.json whose script lacks the execute bit (Claude Code runs a bare command,
# so a mode-644 script exits 126 and never loads), whose script is absent, or whose command could not
# be resolved at all (typed, never silent: CLAUDE.md section 7).
#
# Kinds pinned (json-envelope.v1.md): wired-hook-not-executable, wired-hook-missing,
# wired-hook-unverifiable. WARN-only, read-only toward targets. A command run through an interpreter
# (`bash <path>`) needs only to exist. Two layers: the lib function (hook_wired_exec_report, a table of
# command shapes against a sandbox target) and the verify-registry integration (report, json, dedup).
# The integration fixture is tests/fixtures/wired-hook-exec/ (settings.json + hooks/), copied into a
# sandbox target as .claude/ so the suite never writes into the kit tree.
#
# Usage: verify-registry-wired-exec.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-registry.sh"
LIB="$HERE/../lib/hook-wiring.sh"
FIX="$HERE/fixtures/wired-hook-exec"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
[ -f "$SUT" ] && [ -f "$LIB" ] && [ -f "$FIX/settings.json" ] || { echo "FATAL: SUT, lib or fixture missing" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"; export RSDD_HOOK_WIRING_CEILING
export RESEARCH_HOME="$ROOT/home"
unset RSDD_REGISTRY_TOL RSDD_ROW_MAXLEN _json_items
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-60s %s\n' "$1" "${2:-}"; }
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
TB=$'\t'

# ---------------------------------------------------------------- lib layer
LT="$ROOT/lt"                      # sandbox target for the command-shape table
mkdir -p "$LT/.claude/hooks/dir-noexec" "$LT/home/h"
for f in "$LT/.claude/hooks/ok-exec" "$LT/.claude/hooks/noexec" "$LT/home/h/noexec"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$f"; done
chmod +x "$LT/.claude/hooks/ok-exec"; chmod 644 "$LT/.claude/hooks/noexec" "$LT/home/h/noexec"; chmod 600 "$LT/.claude/hooks/dir-noexec"
P='$CLAUDE_PROJECT_DIR/.claude/hooks'

# lt_settings <command> : settings.json carrying one Stop hook command (jq encodes the string).
lt_settings() { jq -n --arg c "$1" '{hooks:{Stop:[{hooks:[{type:"command",command:$c}]}]}}' > "$LT/.claude/settings.json"; }
# lt_run <lib> : report for the current settings, HOME pointed into the sandbox.
# shellcheck disable=SC1090
lt_run() { ( HOME="$LT/home"; . "$1"; hook_wired_exec_report "$LT" ); }
# check <lib> <command> <glob-pattern> : output must match the pattern ("" = no output); @T@ = sandbox target.
check() {
  local lib="$1" cmd="$2" pat="${3//@T@/"$LT"}" out
  lt_settings "$cmd"; out="$(lt_run "$lib")"
  # shellcheck disable=SC2053
  if [ -z "$pat" ]; then [ -z "$out" ]; else [[ "$out" == $pat ]]; fi
}
NE="not-executable${TB}@T@/.claude/hooks/noexec"
MI="missing${TB}@T@/.claude/hooks/absent"
UNV() { printf 'unverifiable%s*%s*%s*' "$TB" "$TB" "$1"; }

tc_ops() { local l="$1"
  check "$l" "$P/ok-exec;echo ok" "" && check "$l" "$P/ok-exec&&true" "" && check "$l" "$P/ok-exec|tee log" "" \
    && check "$l" "$P/ok-exec>/dev/null" "" && check "$l" "$P/noexec;echo ok" "$NE" && check "$l" "$P/absent;echo" "$MI"; }
tc_nameval() { local l="$1"; check "$l" "FOO=bar $P/absent" "$MI" && check "$l" "A=1 B=2 $P/noexec" "$NE"; }
tc_exec() { local l="$1"; check "$l" "exec $P/noexec" "$NE" && check "$l" "nohup $P/absent" "$MI"; }
tc_env() { local l="$1"; check "$l" "env FOO=1 $P/noexec" "$NE" && check "$l" "env -u X $P/absent" "$MI"; }
tc_nice() { local l="$1"; check "$l" "nice -n 5 $P/noexec" "$NE" && check "$l" "nice $P/absent" "$MI"; }
tc_timeout() { local l="$1"; check "$l" "timeout 5 $P/noexec" "$NE" && check "$l" "timeout -s KILL 5 $P/absent" "$MI"; }
tc_interp() { local l="$1"; check "$l" "bash $P/absent" "$MI" && check "$l" "bash $P/noexec" "" && check "$l" "/bin/sh -x $P/noexec" "" \
    && check "$l" "env bash $P/noexec" ""; }
tc_interp_c() { local l="$1"; check "$l" "bash -c 'x'" "$(UNV '*-c payload*')"; }
tc_unv_misc() { local l="$1"
  check "$l" "\"$P/ok-exec" "$(UNV '*unterminated*')" && check "$l" "$P/ok\\ exec" "$(UNV '*backslash*')" \
    && check "$l" '$UNSETVAR/x' "$(UNV '*unresolved*')" && check "$l" ';x' "$(UNV '*no command word*')"; }
tc_squote() { local l="$1"; check "$l" "'\$HOME/h/noexec'" "$(UNV '*single-quoted*')"; }
tc_dqtilde() { local l="$1"; check "$l" '"~/h/noexec"' "$(UNV '*double quotes*')"; }
tc_home_brace() { local l="$1"; check "$l" '${HOME}/h/noexec' "not-executable${TB}@T@/home/h/noexec"; }
tc_home_plain() { local l="$1"; check "$l" '$HOME/h/noexec' "not-executable${TB}@T@/home/h/noexec"; }
# shellcheck disable=SC2088
tc_home_tilde() { local l="$1"; check "$l" '~/h/noexec' "not-executable${TB}@T@/home/h/noexec"; }
tc_bare() { local l="$1"; check "$l" "bash run.sh" "$(UNV '*relative script name*')" && check "$l" "jq -r .x" ""; }
tc_dir() { local l="$1"; check "$l" "$P/dir-noexec" ""; }
tc_splitquote() { local l="$1"; check "$l" "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/noexec" "$NE" && check "$l" "\"\${CLAUDE_PROJECT_DIR}/.claude/hooks/noexec\"" "$NE"; }
tc_scope() { local l="$1" out   # statusLine / mcpServers commands are not hooks
  printf '%s' '{"statusLine":{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/absent"},"mcpServers":{"x":{"command":"/nonexistent/server"}},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/ok-exec"}]}]}}' > "$LT/.claude/settings.json"
  out="$(lt_run "$l")"; [ -z "$out" ]; }
tc_nextline() { local l="$1" out
  printf '{\n "hooks": {"Stop": [{"hooks": [{"type": "command",\n  "command":\n   "$CLAUDE_PROJECT_DIR/.claude/hooks/noexec"}]}]}}\n' > "$LT/.claude/settings.json"
  out="$(lt_run "$l")"; [[ "$out" == "not-executable${TB}$LT/.claude/hooks/noexec" ]]; }
tc_invalid() { local l="$1" out; printf '{ not json' > "$LT/.claude/settings.json"; out="$(lt_run "$l")"; [[ "$out" == "unverifiable${TB}"*"not valid JSON"* ]]; }
tc_absent() { local l="$1" out; rm -f "$LT/.claude/settings.json"; out="$(lt_run "$l")"; [ -z "$out" ]; }
tc_unreadable() { local l="$1" out; lt_settings "$P/noexec"; chmod 000 "$LT/.claude/settings.json"; out="$(lt_run "$l")"; chmod 644 "$LT/.claude/settings.json"
  [[ "$out" == "unverifiable${TB}"*"not a readable file"* ]]; }
# shellcheck disable=SC1090
tc_nojq() { local l="$1" out nb="$ROOT/nojq-bin" t   # jq absent from PATH: typed note + the text-match fallback still finds the file
  if [ ! -d "$nb" ]; then mkdir -p "$nb"; for t in grep sed; do ln -sf "$(command -v "$t")" "$nb/$t"; done; fi
  lt_settings "$P/noexec"; out="$( ( PATH="$nb"; HOME="$LT/home"; . "$l"; hook_wired_exec_report "$LT" ) )"
  [[ "$out" == "unverifiable${TB}"*"jq not on PATH"*"not-executable${TB}$LT/.claude/hooks/noexec" ]]; }
tc_force_fallback() { tc_nextline "$1"; }   # next-line values are read by jq only: the text fallback (and its note) must not be taken when jq exists

echo "== verify-registry-wired-exec.test.sh =="
if [ "$HAVE_JQ" = 1 ]; then
  tc_ops "$LIB"        && ok "L1 a glued ; && | > operator ends the command word (no bogus missing)" || no "L1 operator-glued commands"
  tc_nameval "$LIB"    && ok "L2 NAME=value prefixes are skipped to the real command"               || no "L2 NAME=value"
  tc_exec "$LIB"       && ok "L3 exec / nohup prefixes are skipped"                                  || no "L3 exec"
  tc_env "$LIB"        && ok "L4 env (with -u and NAME=value) prefix is skipped"                     || no "L4 env"
  tc_nice "$LIB"       && ok "L5 nice (with -n) prefix is skipped"                                   || no "L5 nice"
  tc_timeout "$LIB"    && ok "L6 timeout (with -s SIG and DURATION) prefix is skipped"               || no "L6 timeout"
  tc_interp "$LIB"     && ok "L7 interpreter-run script: existence only (missing reported, no +x needed)" || no "L7 interpreter"
  tc_interp_c "$LIB"   && ok "L8 interpreter -c payload is typed unverifiable"                       || no "L8 -c payload"
  tc_unv_misc "$LIB"   && ok "L9 unterminated quote / backslash / unresolved variable / no word -> unverifiable" || no "L9 unverifiable shapes"
  tc_squote "$LIB"     && ok "L10 single-quoted \$HOME is unverifiable (shell would not expand it)"   || no "L10 single quote"
  tc_dqtilde "$LIB"    && ok "L11 \"~/x\" is unverifiable (no tilde expansion inside double quotes)"   || no "L11 dq tilde"
  tc_home_brace "$LIB" && ok "L12 \${HOME}/x expands"                                                || no "L12 HOME brace"
  tc_home_plain "$LIB" && ok "L13 \$HOME/x expands"                                                  || no "L13 HOME plain"
  tc_home_tilde "$LIB" && ok "L14 unquoted ~/x expands"                                              || no "L14 HOME tilde"
  tc_bare "$LIB"       && ok "L15 bare names: PATH command silent, interpreter script name unverifiable" || no "L15 bare names"
  tc_dir "$LIB"        && ok "L16 a directory at the path is skipped"                                || no "L16 directory"
  tc_splitquote "$LIB" && ok "L17 \"\$CLAUDE_PROJECT_DIR\"/x and \"\${...}/x\" quote forms resolve"      || no "L17 quote forms"
  tc_scope "$LIB"      && ok "L18 only commands under hooks are read (statusLine / mcpServers are not)" || no "L18 scope"
  tc_nextline "$LIB"   && ok "L19 a value on the line after \"command\": is read"                    || no "L19 next-line value"
  tc_invalid "$LIB"    && ok "L20 invalid settings.json is typed unverifiable"                       || no "L20 invalid json"
  tc_absent "$LIB"     && ok "L21 absent settings.json prints nothing (nothing wired)"               || no "L21 absent settings"
  if [ "$(id -u)" = 0 ]; then skip "L22 unreadable settings.json" "(running as root: chmod 000 is still readable)"
  else tc_unreadable "$LIB" && ok "L22 unreadable settings.json is typed unverifiable"                 || no "L22 unreadable"; fi
  tc_nojq "$LIB"       && ok "L23 no jq: typed note + text-match fallback still reports"             || no "L23 no-jq fallback"
else
  skip "L1-L23 lib command-shape table" "(jq not on PATH: the table writes settings.json with jq)"
fi

# ---------------------------------------------------------------- verify-registry integration
# mkkit <name> [<sut> [<lib>]] : a runnable COPY of the SUT and its helpers (KIT = dirname/..).
mkkit() {
  local kit="$ROOT/$1" l sut="${2:-$SUT}" lib="${3:-$LIB}"
  mkdir -p "$kit/toolbelt/lib"
  cp "$sut" "$kit/toolbelt/verify-registry.sh"
  for l in retro-status target-paths block-files state-files corpus-markers; do cp "$HERE/../lib/$l.sh" "$kit/toolbelt/lib/$l.sh"; done
  cp "$lib" "$kit/toolbelt/lib/hook-wiring.sh"
  printf '%s' "$kit"
}
# mktarget <dir> : a corpus-bearing target carrying the fixture as .claude/. The execute bit is set
# ONLY on plain-exec; every other hook stays mode 644.
mktarget() {
  local t="$1"
  mkdir -p "$t"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 1\n<!-- /research-state.v1 -->\n' > "$t/RESEARCH-STATE.md"
  printf '# Block 1\n' > "$t/a-block1.md"
  mkdir -p "$t/.claude"
  cp -R "$FIX/hooks" "$t/.claude/hooks"; cp "$FIX/settings.json" "$t/.claude/settings.json"
  chmod 644 "$t/.claude/hooks/"*
  chmod +x "$t/.claude/hooks/plain-exec"
}
write_targets() {   # <kit> <target> [<maturity claims>]
  local kit="$1" t="$2" claim="${3:-1 md / git yes}"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
    printf '| 1 | t1 | mature (%s) | `%s` |\n' "$claim" "$t"
  } > "$kit/TARGETS.md"
}
run() { OUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" 2>&1)"; RC=$?; }

case_all() {  # <kit> : every expected finding present, no false one; rc 0
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"; write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] || return 1
  grep -qF "wired-hook-not-executable: $t/.claude/hooks/plain-noexec" <<<"$OUT" || return 1
  grep -qF "wired-hook-not-executable: $t/.claude/hooks/quoted-noexec" <<<"$OUT" || return 1
  grep -qF "wired-hook-missing: $t/.claude/hooks/absent-hook" <<<"$OUT" || return 1
  grep -qE '^WARN  ' <<<"$(grep -F 'wired-hook-' <<<"$OUT")" || return 1
  ! grep -qF "bashwrapped-noexec" <<<"$OUT" || return 1   # interpreter-run: fine
  ! grep -qF "plain-exec" <<<"$OUT" || return 1            # +x: fine
  return 0
}
case_interp() { # <kit> : only the interpreter-run and +x hooks are wired -> no wired-hook finding
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash $CLAUDE_PROJECT_DIR/.claude/hooks/bashwrapped-noexec"},{"type":"command","command":"sh .claude/hooks/bashwrapped-noexec"},{"type":"command","command":"/bin/bash $CLAUDE_PROJECT_DIR/.claude/hooks/bashwrapped-noexec"},{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/plain-exec"}]}]}}' > "$t/.claude/settings.json"
  write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] && ! grep -qF 'wired-hook-' <<<"$OUT"
}
case_chmod_clears() { # <kit> : after chmod +x the not-executable finding is gone (the check reads the live mode)
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"; chmod +x "$t/.claude/hooks/plain-noexec" "$t/.claude/hooks/quoted-noexec"
  write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] && ! grep -qF 'wired-hook-not-executable' <<<"$OUT" && grep -qF "wired-hook-missing: $t/.claude/hooks/absent-hook" <<<"$OUT"
}
case_readonly() { # <kit> : the check never changes the target (tree listing + modes + mtimes identical)
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM" b a
  mktarget "$t"; write_targets "$kit" "$t"
  b="$(find "$t" -printf '%p %m %T@\n' | sort)"
  run "$kit"
  a="$(find "$t" -printf '%p %m %T@\n' | sort)"
  [ "$b" = "$a" ] && grep -qF 'wired-hook-' <<<"$OUT"
}
case_json() { # <kit> : the --json envelope carries the kinds as WARN items
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM" j
  mktarget "$t"; write_targets "$kit" "$t"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/plain-noexec"},{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/absent-hook"},{"type":"command","command":"\"~/x\""}]}]}}' > "$t/.claude/settings.json"
  j="$("$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json 2>/dev/null)"
  [ "$(jq -r '[.items[] | select(.kind=="wired-hook-not-executable" and .severity=="WARN")] | length' <<<"$j")" = 1 ] \
    && [ "$(jq -r '[.items[] | select(.kind=="wired-hook-missing" and .severity=="WARN")] | length' <<<"$j")" = 1 ] \
    && [ "$(jq -r '[.items[] | select(.kind=="wired-hook-unverifiable" and .severity=="WARN")] | length' <<<"$j")" = 1 ]
}
case_unv() { # <kit> : an unresolvable wired command is reported as wired-hook-unverifiable
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"~/hooks/x.sh\""}]}]}}' > "$t/.claude/settings.json"
  write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] && grep -qF 'wired-hook-unverifiable: "~/hooks/x.sh"' <<<"$OUT" && ! grep -qF 'wired-hook-missing' <<<"$OUT"
}
case_dedup() { # <kit> : a missing Stop retro-gate script already reported as never-loaded is not reported twice; other missing hooks still are
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/retro-gate-stop.sh"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/absent-hook"}]}]}}' > "$t/.claude/settings.json"
  write_targets "$kit" "$t" "1 md / git yes / hook yes"; run "$kit"
  [ "$RC" = 0 ] && grep -qF 'registered-never-loaded' <<<"$OUT" \
    && ! grep -qF 'wired-hook-missing: '"$t"'/.claude/hooks/retro-gate-stop.sh' <<<"$OUT" \
    && grep -qF "wired-hook-missing: $t/.claude/hooks/absent-hook" <<<"$OUT"
}

K="$(mkkit k1)"
case_all "$K"          && ok "1 not-executable (plain + quoted \$CLAUDE_PROJECT_DIR) and missing hooks are reported" || no "1 wired-hook findings" "[$OUT]"
case_interp "$K"       && ok "2 'bash <path>' / 'sh <path>' / +x wired hooks are NOT reported"                       || no "2 interpreter/+x hooks must be silent" "[$OUT]"
case_chmod_clears "$K" && ok "3 chmod +x clears the finding (live mode read); missing stays"                          || no "3 chmod clears" "[$OUT]"
case_readonly "$K"     && ok "4 read-only toward the target (modes/mtimes/tree unchanged)"                            || no "4 read-only" "[$OUT]"
case_unv "$K"          && ok "6 an unresolvable wired command is reported as wired-hook-unverifiable"                 || no "6 unverifiable finding" "[$OUT]"
case_dedup "$K"        && ok "7 a missing retro-gate script is not double-reported next to hook-registered-never-loaded" || no "7 dedup" "[$OUT]"
if [ "$HAVE_JQ" = 1 ]; then
  case_json "$K"       && ok "5 --json envelope carries all three kinds as WARN items"                                 || no "5 json items"
else
  skip "5 --json envelope carries all three kinds" "(jq not on PATH)"
fi

# --- TEETH ---
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # lteeth <label> <case-fn> <sed-expr>... : mutate the LIB; the case (given a lib path) passes on the real one, must fail on the mutant.
  lteeth() {
    local label="$1" fn="$2" mut="$ROOT/mutlib-$RANDOM"; shift 2
    "$fn" "$LIB" || { no "teeth $label: case FAILS on the unmutated lib — tooth is vacuous"; return; }
    mutant_chain_or_count fail "teeth $label" "$LIB" "$mut" "$@" || return 0
    if "$fn" "$mut"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  # steeth <label> <case-fn> <lib|sut> <sed-expr>... : mutate verify-registry (or the lib behind it); the case (given a kit) must fail.
  steeth() {
    local label="$1" fn="$2" which="$3" mut="$ROOT/mut-$RANDOM" mk; shift 3
    "$fn" "$K" || { no "teeth $label: case FAILS on the unmutated SUT — tooth is vacuous"; return; }
    if [ "$which" = lib ]; then
      mutant_chain_or_count fail "teeth $label" "$LIB" "$mut" "$@" || return 0
      mk="$(mkkit "m-$RANDOM" "$SUT" "$mut")"
    else
      mutant_chain_or_count fail "teeth $label" "$SUT" "$mut" "$@" || return 0
      mk="$(mkkit "m-$RANDOM" "$mut" "$LIB")"
    fi
    if "$fn" "$mk"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  if [ "$HAVE_JQ" = 1 ]; then
    lteeth OPERATOR-STOP-DROPPED tc_ops '/# HW-OPERATOR-STOP$/d'
    lteeth NAMEVAL-NOT-SKIPPED tc_nameval '/# HW-NAMEVAL$/d'
    lteeth WRAP-EXEC-NOT-SKIPPED tc_exec 's/^        exec|nohup|command)/        NOEXEC)/'
    lteeth WRAP-ENV-NOT-SKIPPED tc_env 's/^        env)   # HW-WRAP-ENV$/        NOENV)/'
    lteeth WRAP-NICE-NOT-SKIPPED tc_nice 's/^        nice)   # HW-WRAP-NICE$/        NONICE)/'
    lteeth WRAP-TIMEOUT-NOT-SKIPPED tc_timeout 's/^        timeout)   # HW-WRAP-TIMEOUT$/        NOTIMEOUT)/'
    lteeth INTERP-REQUIRES-EXEC tc_interp 's/mode=interp; j=/mode=direct; j=/'
    lteeth SQUOTE-EXPANDED tc_squote '/# HW-SQUOTE$/d'
    lteeth DQ-TILDE-EXPANDED tc_dqtilde '/# HW-DQ-TILDE$/d'
    lteeth HOME-BRACE-UNEXPANDED tc_home_brace '/# HW-HOME-BRACE$/d'
    lteeth HOME-PLAIN-UNEXPANDED tc_home_plain '/# HW-HOME-PLAIN$/d'
    lteeth HOME-TILDE-UNEXPANDED tc_home_tilde '/# HW-HOME-TILDE$/d'
    lteeth BARE-INTERP-SILENT tc_bare 's/if \[ "\$mode" = interp \]; then printf/if false; then printf/'
    lteeth DIR-NOT-SKIPPED tc_dir 's/if \[ -d "\$arg" \]; then return 0/if false; then return 0/'
    lteeth NOJQ-NOTE-DROPPED tc_nojq '/# HW-NOJQ-NOTE$/d'
    lteeth JQ-NOT-USED tc_force_fallback 's/command -v jq >\/dev\/null 2>&1/false/'
    lteeth HOOKS-SCOPE-WIDENED tc_scope 's/(\.hooks? \/\/ {}) | objects | \.\[\] | arrays | \.\[\] | objects | \.hooks | arrays | \.\[\] | objects | \.command | strings/.. | objects | .command? | strings/'
    if [ "$(id -u)" != 0 ]; then lteeth UNREADABLE-NOT-TYPED tc_unreadable 's/\[ ! -r "\$settings" \]/false/'; fi
  fi
  steeth NOEXEC-TEST-DROPPED case_all lib 's/if \[ "\$mode" = direct \] && \[ ! -x "\$arg" \]; then/if false; then/'
  steeth MISSING-NOT-REPORTED case_all lib 's/printf .missing[^"]*"\$arg"/:/'
  steeth PROJECT-DIR-UNEXPANDED case_all lib 's/\${CLAUDE_PROJECT_DIR}/\${NOT_THE_VAR}/g'
  steeth CALLSITE-REMOVED case_all sut 's/hook_wired_exec_report "\$p"/true/'
  steeth UNVERIFIABLE-NOT-REPORTED case_unv sut 's/"\$_vr_we_kind" = "unverifiable"/"$_vr_we_kind" = "nope"/'
  steeth DEDUP-DROPPED case_dedup sut 's/\[ "\$_vr_nl_emitted" = 1 \]/[ "$_vr_nl_emitted" = 7 ]/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
