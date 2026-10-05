#!/usr/bin/env bash
# research-sdd-status-clean-warn.test.sh — terminal no-garbage WARN in `research-sdd-status.sh --next`
# (kit issue #1277, slice 2). When --next resolves to an exhausted STOP, the status script runs clean-check.sh
# over the target and echoes findings to STDERR as `WARN: clean-check: ...`. Report-only: stdout and exit code
# are unchanged. Three states: clean -> INFO line, findings -> WARN lines, unverifiable -> typed WARN.
# Everything runs in trap-cleaned temp dirs; nothing real is touched.
# Usage: research-sdd-status-clean-warn.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
SUT="$TB/research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
TMP="$(mktemp -d)"
# clean-check scans $TMPDIR (default /tmp) for stale tmp.* entries: point it at an empty dir so the suite is hermetic.
mkdir -p "$TMP/tmpd"; export TMPDIR="$TMP/tmpd"
MUT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUT"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
echo "== research-sdd-status-clean-warn.test.sh =="

# mkcorpus DIR IO — a git-tracked corpus; IO=0 is an exhausted STOP, IO=1 a NEXT.
mkcorpus() {
  local d="$1" io="$2"; mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n' "$io"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    [ "$io" = 1 ] && echo "| high | the gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $io"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$d/RESEARCH-STATE.md"
  git -C "$d" init -q; git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m init
}
OUT=""; ERR=""; RC=0
run() { OUT="$("$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }

# 1 clean exhausted STOP: INFO clean, verdict on stdout, no WARN
mkcorpus "$TMP/c1" 0; run bash "$SUT" "$TMP/c1" --next
[[ "$OUT" == STOP\ \|\ read-only-investigable\ exhausted* ]] && [ "$RC" = 0 ] && ok "1a verdict + exit 0 unchanged" || no "1a got rc=$RC [$OUT]"
grep -qF 'INFO: clean-check: clean at terminal STOP' <<<"$ERR" && ! grep -q 'WARN: clean-check' <<<"$ERR" && ok "1b clean target -> INFO, no WARN" || no "1b stderr [$ERR]"

# 2 untracked garbage: loud WARN naming the file, verdict + exit unchanged, nothing written/deleted
mkcorpus "$TMP/c2" 0; printf 'x\n' > "$TMP/c2/stray.json"; run bash "$SUT" "$TMP/c2" --next
[ "$RC" = 0 ] && [[ "$OUT" == STOP* ]] && ok "2a report-only: exit 0 and STOP verdict despite findings" || no "2a rc=$RC [$OUT]"
grep -qF 'WARN: clean-check: findings at terminal STOP' <<<"$ERR" && grep -qF 'WARN: clean-check: GARBAGE untracked stray.json' <<<"$ERR" && ok "2b findings echoed as WARN" || no "2b stderr [$ERR]"
[ -f "$TMP/c2/stray.json" ] && ok "2c read-only: stray file untouched" || no "2c stray file deleted"
mkdir -p "$TMP/c2/.research-sdd"; printf 'stray.json # fixture\n' > "$TMP/c2/.research-sdd/keep.txt"; run bash "$SUT" "$TMP/c2" --next
grep -q 'GARBAGE untracked' <<<"$ERR" && no "2d keep-list did not silence [$ERR]" || ok "2d keep.txt entry silences the finding"

# 3 NEXT verdict: clean-check is NOT run (terminal only)
mkcorpus "$TMP/c3" 1; printf 'x\n' > "$TMP/c3/stray.json"; run bash "$SUT" "$TMP/c3" --next
[[ "$OUT" == NEXT* ]] && ! grep -q 'clean-check' <<<"$ERR" && ok "3 NEXT verdict -> no clean-check output" || no "3 [$OUT] [$ERR]"

# 4 non-git target: unverifiable typed WARN, never silent
mkdir -p "$TMP/c4"; cp "$TMP/c1/RESEARCH-STATE.md" "$TMP/c4/"; run bash "$SUT" "$TMP/c4" --next
[[ "$OUT" == STOP* ]] && grep -qF 'WARN: clean-check: unverifiable (exit 2' <<<"$ERR" && ok "4 non-git target -> typed unverifiable WARN" || no "4 [$OUT] [$ERR]"

# 5 opt-out env
mkcorpus "$TMP/c5" 0; printf 'x\n' > "$TMP/c5/stray.json"; run env RSDD_STATUS_NO_CLEAN_CHECK=1 bash "$SUT" "$TMP/c5" --next
grep -q 'clean-check' <<<"$ERR" && no "5 opt-out ignored [$ERR]" || ok "5 RSDD_STATUS_NO_CLEAN_CHECK=1 skips the check"

# 6 missing clean-check.sh beside the script: typed unverifiable WARN
mkdir -p "$TMP/kit6"
for f in "$TB"/*; do b="$(basename "$f")"; { [ "$b" = clean-check.sh ] || [ "$b" = tests ]; } || ln -s "$f" "$TMP/kit6/$b"; done
run bash "$TMP/kit6/research-sdd-status.sh" "$TMP/c1" --next
grep -qF 'unverifiable (clean-check.sh not found' <<<"$ERR" && ok "6 missing clean-check.sh -> typed unverifiable WARN" || no "6 [$ERR]"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"; mkcorpus "$TMP/c2x" 0; printf "x\n" > "$TMP/c2x/stray.json"
  for f in "$TB"/*; do b="$(basename "$f")"; { [ "$b" = research-sdd-status.sh ] || [ "$b" = tests ]; } || ln -s "$f" "$MUT/$b"; done
  mt() { # LABEL SED-EXPR GOOD-RC BAD-RC [tooth flags] -- ARGV
    local label="$1" expr="$2" grc="$3" brc="$4"; shift 4
    local m="$MUT/research-sdd-status.sh"
    rm -f "$m"; mutant_chain "$label" "$SUT" "$m" "$expr" || { fail=$((fail+1)); return; }
    if mutant_tooth "teeth: $label" "$grc" "$brc" "$m" "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  }
  # A: findings branch no longer echoes the finding lines
  mt A 's/printf .WARN: clean-check: %s\\n. "\$_cc_ln"/:/' 0 0 --good-has 'GARBAGE untracked' --bad-lacks 'GARBAGE untracked' -- bash '@SUT@' "$TMP/c2x" --next
  # B: unverifiable branch silenced
  mt B 's/WARN: clean-check: unverifiable (exit/DEGRADED-OFF (exit/' 0 0 --good-has 'unverifiable [(]exit' --bad-lacks 'unverifiable [(]exit' -- bash '@SUT@' "$TMP/c4" --next
  # C: the call after the STOP verdict is removed -> findings never reach stderr
  mt C 's/^  terminal_clean_warn "\$_tc_out"  # TC-WARN-CALL$/  :/' 0 0 --good-has 'GARBAGE untracked' --bad-lacks 'GARBAGE untracked' -- bash '@SUT@' "$TMP/c2x" --next
  # D: opt-out ignored
  mt D 's/\[ "\${RSDD_STATUS_NO_CLEAN_CHECK:-0}" = "1" \] && return 0//' 0 0 --good-lacks 'clean-check' --bad-has 'clean-check' -- env RSDD_STATUS_NO_CLEAN_CHECK=1 bash '@SUT@' "$TMP/c5" --next
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
