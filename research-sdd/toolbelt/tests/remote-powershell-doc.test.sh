#!/usr/bin/env bash
# remote-powershell-doc.test.sh — structural guard for REMOTE-POWERSHELL.md §2 (kit issues #1394, #1388).
#
# WHY. §2 once said "Single quotes inside the PowerShell source are now safe". That is false at the LOCAL
# bash layer: a PowerShell source held in a bash single-quoted string cannot contain a single quote — bash
# strips it BEFORE base64/UTF-16LE encoding, so -EncodedCommand faithfully ships the already-damaged text
# (symptom seen live: `Get-CimInstance : Consulta no válida`, 0x80041017). The doc must (1) not carry the
# false sentence, (2) name where quoting breaks and prescribe a heredoc / script file, and (3) name the
# nested `powershell -Command` second hop and its fix. This is a structural (prose) test anchored by
# sentinel comments in the doc; the behavioural demonstration is quoted in the doc itself.
#
# Usage: remote-powershell-doc.test.sh                (run the suite)
#        remote-powershell-doc.test.sh --prove-teeth  (suite + mutation controls)
# Exit: 0 = held · 1 = regression · 2 = harness error or DEGRADED (python3 absent: demo could not run).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="${RPS_DOC:-$HERE/../REMOTE-POWERSHELL.md}"   # RPS_DOC: test seam for the nested degraded-exit control
[ -s "$DOC" ] || { echo "FATAL: doc under test missing or empty: $DOC" >&2; exit 2; }

pass=0; fail=0; DEGRADED=0   # DEGRADED: checks that could not run (missing runtime dependency) — never a pass (§7)
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }   # chk LABEL RC

has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1"; fi; }   # has LABEL HAYSTACK NEEDLE

# check_doc FILE — emits PASS/FAIL lines (and bumps the counters of the calling shell).
check_doc() {
  local f="$1" sec2 flat
  if grep -qF 'Single quotes inside the PowerShell source are now safe' "$f"; then
    bad "false 'now safe' sentence absent"; else ok "false 'now safe' sentence absent"; fi
  # SENTINEL-REMOTE-PS-LOCAL-QUOTING
  grep -qF '<!-- SENTINEL-REMOTE-PS-LOCAL-QUOTING -->' "$f"; chk "local-quoting sentinel present" $?
  sec2="$(sed -n '/^## 2\./,/^## 3\./p' "$f")"
  has "section 2 prescribes the quoted-heredoc form" "$sec2" "<<'EOF'"
  has "section 2 says the break happens before encoding" "${sec2,,}" "before encoding"
  # SENTINEL-REMOTE-PS-NESTED-HOP
  grep -qF '<!-- SENTINEL-REMOTE-PS-NESTED-HOP -->' "$f"; chk "nested-hop sentinel present" $?
  grep -qiE 'nested.*powershell -Command|powershell -Command.*nested' <<<"$sec2"; chk "section 2 names the nested powershell -Command hop" $?
  flat="$(tr '\n`' '  ' <<<"$sec2" | tr -s ' ')"   # join wrapped lines, drop markdown backticks
  has "section 2 prescribes a nested -EncodedCommand" "${flat,,}" "nested -encodedcommand"
  has "section 2 prescribes a remote script file" "${flat,,}" "remote script file"
  # SENTINEL-REMOTE-PS-LENGTH-CAVEAT
  grep -qF '<!-- SENTINEL-REMOTE-PS-LENGTH-CAVEAT -->' "$f"; chk "length-caveat sentinel present" $?
  has "length caveat names the cmd.exe 8191 limit" "$flat" "8191"
  has "length caveat names the 2.67x ratio" "$flat" "2.67x"
  has "length caveat gives the ~3 KB source budget" "$flat" "3 KB"
  has "length caveat prescribes scp + powershell -File" "$flat" "powershell -File <path>"
}

# Behavioural demonstration quoted in the doc, run locally: bash + python3 UTF-16LE base64 + decode.
# DEMO_MUTANT=1 (teeth only) feeds the heredoc case the damaged text, which must turn an assertion red.
demo_quoting() {
  local ps_bad ps_good dec_bad dec_good ratio
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  quoting demonstration: DEGRADED — python3 absent (not a pass)"
    DEGRADED=$((DEGRADED+1)); return 0
  fi
  enc() { python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
  dec() { python3 -c "import sys,base64;print(base64.b64decode(sys.stdin.read()).decode('utf-16-le'),end='')"; }
  ps_bad='Write-Output ((Get-Date).ToString('s'))'
  ps_good=$(cat <<'EOF'
Write-Output ((Get-Date).ToString('s'))
EOF
)
  [ "${DEMO_MUTANT:-0}" = 1 ] && ps_good="$ps_bad"
  ratio="$(python3 -c "import sys,base64;s='x'*3000;print(round(len(base64.b64encode(s.encode('utf-16-le')))/len(s),2))")"
  if [ "$ratio" = 2.67 ]; then ok "demo: UTF-16LE+base64 ratio is 2.67x (measured $ratio)"; else bad "demo: UTF-16LE+base64 ratio is 2.67x (measured $ratio)"; fi
  dec_bad="$(enc "$ps_bad" | dec)"; dec_good="$(enc "$ps_good" | dec)"
  [ "$dec_bad" = 'Write-Output ((Get-Date).ToString(s))' ]; chk "demo: single-quoted assignment drops inner quotes before encoding" $?
  [ "$dec_good" = "Write-Output ((Get-Date).ToString('s'))" ]; chk "demo: quoted heredoc decodes intact" $?
}

# degraded_control SCRIPT — runs SCRIPT (this suite, or a mutant copy) as a nested process with python3
# absent from a hermetic PATH and asserts the exit contract: DEGRADED alone -> exit 2 + DEGRADED stderr
# line; DEGRADED plus a real failure -> exit 1. RPS_NESTED=1 stops the nested run from recursing.
# DEGRADED is only ever incremented in the main shell (the demo's python3 probe runs un-subshelled).
degraded_control() {
  local script="$1" stub tmp rc cmd badreg
  stub="$(mktemp -d)"; tmp="$(mktemp -d)"
  for cmd in dirname cat sed grep tr mktemp rm; do
    command -v "$cmd" >/dev/null 2>&1 && ln -s "$(command -v "$cmd")" "$stub/$cmd"
  done
  PATH="$stub" command -v python3 >/dev/null 2>&1 && { bad "degraded control: stub PATH still resolves python3"; rm -rf "$stub" "$tmp"; return; }
  RPS_NESTED=1 PATH="$stub" "$BASH" "$script" >"$tmp/o1" 2>"$tmp/e1"; rc=$?
  [ "$rc" -eq 2 ]; chk "degraded control: python3 absent, nothing failed -> exit 2 (got $rc)" $?
  grep -q '^DEGRADED: ' "$tmp/e1"; chk "degraded control: DEGRADED line on stderr" $?
  badreg="$tmp/bad.md"; { cat "$DOC"; echo 'Single quotes inside the PowerShell source are now safe.'; } >"$badreg"
  RPS_NESTED=1 RPS_DOC="$badreg" PATH="$stub" "$BASH" "$script" >"$tmp/o2" 2>"$tmp/e2"; rc=$?
  [ "$rc" -eq 1 ]; chk "degraded control: python3 absent AND a failure -> exit 1 (got $rc)" $?
  rm -rf "$stub" "$tmp"
}

echo "-- structural checks on REMOTE-POWERSHELL.md --"
check_doc "$DOC"
demo_quoting
[ -n "${RPS_NESTED:-}" ] || degraded_control "$HERE/$(basename "$0")"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant of the doc must make check_doc fail --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh missing mutant_chain" >&2; exit 2; }
  export MUTANT_SYNTAX=none   # mutants are markdown, not bash
  MDIR="$(mktemp -d)"; mutant_cleanup_register "$MDIR"
  tooth() { # tooth LABEL SED_EXPR
    local m="$MDIR/$1.md" out n
    if ! mutant_chain "$1" "$DOC" "$m" "$2"; then bad "tooth $1: mutant refused"; return; fi
    out="$(check_doc "$m")"            # subshell: the mutant's FAILs do not pollute our counters
    n="$(printf '%s\n' "$out" | grep -c '^  FAIL  ')"
    if [ "$n" -gt 0 ]; then ok "tooth $1 bites ($n assertion(s) red)"; else bad "tooth $1: mutant stayed green"; fi
  }
  tooth reintroduce-false-claim 's|^<!-- SENTINEL-REMOTE-PS-LOCAL-QUOTING -->$|Single quotes inside the PowerShell source are now safe.|'
  tooth drop-heredoc-form "s|<<'EOF'|<<EOF|g"
  tooth drop-nested-sentinel 's|^<!-- SENTINEL-REMOTE-PS-NESTED-HOP -->$||'
  tooth drop-nested-encodedcommand 's|^`-EncodedCommand` (encode|`-EncodedCmd` (encode|'
  tooth drop-length-caveat 's|8191|N|g'
  tooth wrong-ratio 's|2\.67x|3x|g'
  tooth drop-length-sentinel 's|^<!-- SENTINEL-REMOTE-PS-LENGTH-CAVEAT -->$||'
  tooth drop-remote-script-file 's|remote script file|remote thing|g'
  # Mutants of THIS script: each must make degraded_control go red (nested runs read the real doc via RPS_DOC).
  export RPS_DOC="$DOC"
  stooth() { # stooth LABEL SED_EXPR
    local m="$MDIR/$1.sh" out n
    if ! mutant_chain "$1" "$HERE/$(basename "$0")" "$m" "$2"; then bad "tooth $1: mutant refused"; return; fi
    out="$(degraded_control "$m")"
    n="$(printf '%s\n' "$out" | grep -c '^  FAIL  ')"
    if [ "$n" -gt 0 ]; then ok "tooth $1 bites ($n assertion(s) red)"; else bad "tooth $1: mutant stayed green"; fi
  }
  stooth degraded-exit-2-to-0 's|^  exit 2$|  exit 0|'
  stooth degraded-failure-exit-1-dropped 's|^  \[ "\$fail" -eq 0 \] \|\| exit 1$|  [ "$fail" -eq 0 ] \|\| exit 2|'
  stooth degraded-counter-never-bumped 's|DEGRADED=\$((DEGRADED+1)); return 0|return 0|'
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  tooth demo-damaged-heredoc: DEGRADED — python3 absent (not a pass)"; DEGRADED=$((DEGRADED+1))
  else
  out="$(DEMO_MUTANT=1 demo_quoting)"
  if grep -q '^  FAIL  demo' <<<"$out"; then ok "tooth demo-damaged-heredoc bites"; else bad "tooth demo-damaged-heredoc: stayed green"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
if [ "$DEGRADED" -gt 0 ]; then
  echo "DEGRADED: $DEGRADED check(s) could not run (python3 absent) — the doc's measured claims are unverified; exit 2, not a pass" >&2
  [ "$fail" -eq 0 ] || exit 1
  exit 2
fi
[ "$fail" -eq 0 ]
