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
# Exit: 0 = held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../REMOTE-POWERSHELL.md"
[ -s "$DOC" ] || { echo "FATAL: doc under test missing or empty: $DOC" >&2; exit 2; }

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }   # chk LABEL RC

# check_doc FILE — emits PASS/FAIL lines (and bumps the counters of the calling shell).
check_doc() {
  local f="$1" sec2
  if grep -qF 'Single quotes inside the PowerShell source are now safe' "$f"; then
    bad "false 'now safe' sentence absent"; else ok "false 'now safe' sentence absent"; fi
  # SENTINEL-REMOTE-PS-LOCAL-QUOTING
  grep -qF '<!-- SENTINEL-REMOTE-PS-LOCAL-QUOTING -->' "$f"; chk "local-quoting sentinel present" $?
  sec2="$(sed -n '/^## 2\./,/^## 3\./p' "$f")"
  [[ "$sec2" == *"<<'EOF'"* ]]; chk "section 2 prescribes the quoted-heredoc form" $?
  [[ "${sec2,,}" == *"before encoding"* ]]; chk "section 2 says the break happens before encoding" $?
  # SENTINEL-REMOTE-PS-NESTED-HOP
  grep -qF '<!-- SENTINEL-REMOTE-PS-NESTED-HOP -->' "$f"; chk "nested-hop sentinel present" $?
  grep -qiE 'nested.*powershell -Command|powershell -Command.*nested' <<<"$sec2"; chk "section 2 names the nested powershell -Command hop" $?
  grep -qiE 'nested -EncodedCommand|remote script file' <<<"$sec2"; chk "section 2 prescribes nested -EncodedCommand or a remote script file" $?
}

echo "-- structural checks on REMOTE-POWERSHELL.md --"
check_doc "$DOC"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- prove-teeth: each mutant of the doc must make check_doc fail --"
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
  tooth drop-nested-fix 's|[Nn]ested -EncodedCommand|nested form|g;s|remote script file|remote thing|g'
fi

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
