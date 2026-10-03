#!/usr/bin/env bash
# hook-pretool-pkill-guard.test.sh — suite for templates/hook-pretool-pkill-guard.sh (kit issue #1244).
#
# The hook reads Claude Code PreToolUse JSON on stdin and DENIES a Bash command that runs `pkill -f` /
# `pgrep -f` with a pattern that is not bracket-escaped (`[p]attern`): such a pattern also matches the
# enclosing `bash -c` wrapper's own argv and signals the session shell (exit 144). DENY = exit 0 + stdout
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",...}}; ALLOW = exit 0, no
# stdout. Without jq it cannot parse the input: typed `degraded:` on stderr, and a pkill/pgrep-looking
# payload gets permissionDecision "ask" (never a silent allow).
#
# Usage: hook-pretool-pkill-guard.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../../templates/hook-pretool-pkill-guard.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== hook-pretool-pkill-guard.test.sh =="

# payload TOOL CMD -> PreToolUse JSON
payload() { jq -n --arg t "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c}}'; }
# run CMD [TOOL] -> OUT, ERR, RC
run() { payload "${2:-Bash}" "$1" | bash "${SUT_UNDER_TEST:-$SUT}" >"$TMP/o" 2>"$TMP/e"; RC=$?; OUT="$(cat "$TMP/o")"; }
deny() { # label cmd
  run "$2"
  if [ "$RC" = 0 ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$OUT" 2>/dev/null)" = deny ] \
     && [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT")" = PreToolUse ]; then ok "deny: $1"; else no "deny: $1 — rc=$RC out=[$OUT]"; fi
}
allow() {
  run "$2" "${3:-Bash}"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "allow: $1"; else no "allow: $1 — rc=$RC out=[$OUT]"; fi
}

# 1. refused: unescaped -f patterns, every command-position shape (first / middle / last / single)
deny "single bare 'pkill -f foo'" 'pkill -f foo'
deny "pgrep -f foo" 'pgrep -f foo'
deny "clustered flags -fl" 'pkill -fl foo'
deny "signal before flag" 'pkill -9 -f foo'
deny "--full long form" 'pkill --full foo'
deny "quoted unescaped pattern" "pkill -f 'my server'"
deny "variable pattern (cannot prove escaped)" 'pkill -f "$PAT"'
deny "FIRST in a chain" 'pkill -f foo; echo done'
deny "MIDDLE of a chain" 'echo a && pkill -f foo && echo b'
deny "LAST of a chain" 'echo a; echo b; pkill -f foo'
deny "after a pipe" 'ps aux | pgrep -f foo'
deny "inside \$( )" 'kill $(pgrep -f foo)'
deny "inside backticks" 'kill `pgrep -f foo`'
deny "under sudo" 'sudo pkill -f foo'
deny "inside bash -c" "bash -c 'pkill -f foo'"
deny "second line of a multi-line command" $'echo hi\npkill -f foo'
deny "full path to pkill" '/usr/bin/pkill -f foo'
# a bad pattern behind a good one in the same command is still refused
deny "escaped pkill then unescaped pgrep" 'pkill -f [f]oo; pgrep -f bar'
# 1b. compound keywords / wrappers before the command word do not hide it (#1244 review)
deny "if pgrep -f" 'if pgrep -f foo >/dev/null; then echo up; fi'
deny "elif pgrep -f" 'if true; then :; elif pgrep -f foo; then :; fi'
deny "while pkill -f" 'while pkill -f foo; do sleep 1; done'
deny "until pgrep -f" 'until pgrep -f foo; do sleep 1; done'
deny "command pkill -f" 'command pkill -f foo'
deny "nice pkill -f" 'nice -n 5 pkill -f foo'
deny "if ! pgrep -f" 'if ! pgrep -f foo; then :; fi'
# 1c. bracket proviso: safe ONLY when the plain pattern appears nowhere else in the command
deny "bracket + plain pattern in a cd path" "cd /srv/foo && pkill -f '[f]oo'"
deny "bracket + plain pattern spawned earlier" "./foo & sleep 1; pkill -f '[f]oo'"
deny "bracket + plain multi-word pattern elsewhere" "echo foo --serve; pkill -f '[f]oo --serve'"
# documented false denial (header limits): quoted prose with a separator then pkill -f is refused
deny "quoted prose with a separator before pkill -f (documented false denial)" 'git commit -m "x; pkill -f foo"'

# 2. allowed
allow "bracket-escaped pattern" 'pkill -f [f]oo'
allow "bracket-escaped, quoted" "pkill -f '[f]oo --serve'"
allow "bracket-escaped with a signal" 'pkill -9 -f "[s]erver"'
allow "pgrep bracket-escaped" 'pgrep -f [f]oo'
allow "if + bracket-escaped pgrep, plain pattern absent" 'if pgrep -f [f]oo; then echo up; fi'
allow "bracket-escaped, unrelated command around it" 'cd /srv/app && pkill -f [f]oo'
allow "-x exact name" 'pkill -x foo'
allow "-f with -x (exact full match cannot hit the wrapper)" 'pkill -fx foo'
allow "pkill without -f" 'pkill foo'
allow "pgrep -l without -f" 'pgrep -l foo'
allow "PID-file kill" 'kill "$(cat /tmp/foo.pid)"'
allow "prose mentioning pkill -f inside a commit message" 'git commit -m "docs: never run pkill -f foo"'
allow "grep for the phrase" 'grep -rn "pkill -f" docs/'
allow "echo of the phrase" 'echo use pkill -f carefully'
allow "unrelated command" 'ls -la'
allow "non-Bash tool carrying the same text" 'pkill -f foo' Write
allow "empty command" ''

# 3. the refusal names the safe alternatives
run 'pkill -f foo'
if grep -q 'PID file' <<<"$OUT" && grep -q -- '-x' <<<"$OUT" && grep -q '\[p\]attern' <<<"$OUT"; then ok "deny reason names PID file, -x and [p]attern"; else no "deny reason incomplete: $OUT"; fi

# 4. degraded: jq absent / malformed stdin — typed, never a silent allow of a pkill/pgrep payload
mkdir -p "$TMP/nojq"; for b in bash cat grep sed tr; do ln -s "$(command -v $b)" "$TMP/nojq/$b"; done
PATH="$TMP/nojq" bash "$SUT" <<<"$(payload Bash 'pkill -f foo')" >"$TMP/o" 2>"$TMP/e"; RC=$?
if [ "$RC" = 0 ] && grep -q '^degraded: pkill-guard: jq' "$TMP/e" && grep -q '"permissionDecision":"ask"' "$TMP/o"; then ok "no jq + pkill payload -> degraded on stderr + ask"; else no "no-jq pkill: rc=$RC err=[$(cat "$TMP/e")] out=[$(cat "$TMP/o")]"; fi
PATH="$TMP/nojq" bash "$SUT" <<<"$(payload Bash 'ls -la')" >"$TMP/o" 2>"$TMP/e"; RC=$?
if [ "$RC" = 0 ] && grep -q '^degraded: pkill-guard: jq' "$TMP/e" && [ ! -s "$TMP/o" ]; then ok "no jq + unrelated payload -> degraded on stderr, allow"; else no "no-jq unrelated: rc=$RC out=[$(cat "$TMP/o")]"; fi
printf '{not json pkill -f foo' | bash "$SUT" >"$TMP/o" 2>"$TMP/e"; RC=$?
if [ "$RC" = 0 ] && grep -q '^degraded: pkill-guard:' "$TMP/e" && grep -q '"permissionDecision":"ask"' "$TMP/o"; then ok "malformed JSON + pkill text -> degraded + ask"; else no "malformed: rc=$RC err=[$(cat "$TMP/e")] out=[$(cat "$TMP/o")]"; fi
printf '' | bash "$SUT" >"$TMP/o" 2>"$TMP/e"; RC=$?
if [ "$RC" = 0 ] && [ ! -s "$TMP/o" ]; then ok "empty stdin -> allow (nothing to inspect)"; else no "empty stdin: rc=$RC out=[$(cat "$TMP/o")]"; fi

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for hook-pretool-pkill-guard.sh --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  M="$TMP/mt"; mkdir -p "$M"
  # tooth NAME SEDEXPR PROBE-KIND(deny|allow) CMD
  tooth() {
    local name="$1" expr="$2" kind="$3" cmd="$4" mo
    if ! mutant_sed "$SUT" "$M/$name.sh" "$expr" >/dev/null 2>&1; then no "teeth $name: mutant could not be built (pattern absent / refused)"; return; fi
    mo="$(payload Bash "$cmd" | bash "$M/$name.sh" 2>/dev/null)"
    if [ "$kind" = deny ]; then
      grep -q '"deny"' <<<"$mo" && no "teeth $name: mutant still denies — THEATER" || ok "teeth $name: mutant false-allows [$cmd]"
    else
      grep -q '"deny"' <<<"$mo" && ok "teeth $name: mutant false-denies [$cmd]" || no "teeth $name: mutant still allows — THEATER"
    fi
  }
  tooth A "s/^_bracket_re=.*/_bracket_re='NEVER-MATCHES-ANYTHING'/"  allow 'pkill -f [f]oo'
  tooth B 's/_has_bracket=1/_has_bracket=0/'                          allow 'pkill -f [f]oo'
  tooth C 's/\*f\*) _f=1/*Z*) _f=1/'                                  deny  'pkill -f foo'
  tooth D 's/--full) _f=1/--NOPE) _f=1/'                              deny  'pkill --full foo'
  tooth E 's/\*x\*) _x=1/*f*) _x=1/'                                  deny  'pkill -f foo'
  tooth F 's/\*x\*) _x=1/*x*) _x=0/'                                  allow 'pkill -fx foo'
  tooth G 's/pkill|pgrep) ;;/pkill) ;;/'                              deny  'pgrep -f foo'
  tooth H 's/^_flat=.*/_flat="$_cmd"/'                                deny  'echo a; pkill -f foo'
  tooth I 's/tr -d "[^|]*|/cat |/'                                    deny  "bash -c 'pkill -f foo'"
  tooth K 's/|if|elif|while|until|command|nice//'                     deny  'if pgrep -f foo'
  tooth L 's/_plain_elsewhere=1/_plain_elsewhere=0/'                  deny  "cd /srv/foo && pkill -f '[f]oo'"
  # J: the degraded "ask" branch removed -> a pkill payload with unparseable stdin is silently allowed
  if mutant_sed "$SUT" "$M/J.sh" 's/grep -Eq .pkill|pgrep./false/' >/dev/null 2>&1; then
    mo="$(printf '{not json pkill -f foo' | bash "$M/J.sh" 2>/dev/null)"
    grep -q '"ask"' <<<"$mo" && no "teeth J: mutant still asks — THEATER" || ok "teeth J: degraded-ask removed -> silent allow, malformed-JSON case has teeth"
  else no "teeth J: mutant could not be built"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
