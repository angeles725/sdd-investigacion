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


# 7 bounded: a slow clean-check is cut off and reported, never waited on
mkdir -p "$TMP/kit7"
for f in "$TB"/*; do b="$(basename "$f")"; { [ "$b" = clean-check.sh ] || [ "$b" = tests ]; } || ln -s "$f" "$TMP/kit7/$b"; done
printf '#!/usr/bin/env bash\nsleep 6\n' > "$TMP/kit7/clean-check.sh"
t0=$SECONDS; run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT=1 bash "$TMP/kit7/research-sdd-status.sh" "$TMP/c1" --next; el=$((SECONDS-t0))
[ "$el" -lt 5 ] && [[ "$OUT" == STOP* ]] && [ "$RC" = 0 ] && ok "7a slow clean-check bounded (${el}s), verdict + rc intact" || no "7a ${el}s rc=$RC [$OUT]"
grep -qF 'unverifiable (timed out after 1s)' <<<"$ERR" && ok "7b timeout -> typed unverifiable WARN" || no "7b [$ERR]"

# 8 golden: stdout + rc of every verdict path are identical with the check on and off (the check is additive,
# stderr-only, called after the verdict is printed; the gate function itself is not wrapped or run in a subshell).
mkdir -p "$TMP/c8s" "$TMP/c8b"; sed 's/^investigable_open: 0/investigable_open: 5/' "$TMP/c1/RESEARCH-STATE.md" > "$TMP/c8s/RESEARCH-STATE.md"
g_ok=1
for d in c1 c2 c3 c8s c8b; do
  a="$(bash "$SUT" "$TMP/$d" --next 2>/dev/null; echo "rc=$?")"
  b="$(RSDD_STATUS_NO_CLEAN_CHECK=1 bash "$SUT" "$TMP/$d" --next 2>/dev/null; echo "rc=$?")"
  [ "$a" = "$b" ] || { g_ok=0; no "8 golden $d differs [$a] vs [$b]"; }
done
[ "$g_ok" = 1 ] && ok "8a golden: stdout+rc identical with the check on and off" || true
a="$(bash "$SUT" "$TMP/c8s" --next 2>/dev/null)"; [[ "$a" == STALE* ]] && ok "8b STALE fixture really is STALE" || no "8b [$a]"
a="$(bash "$SUT" "$TMP/c8b" --next 2>/dev/null)"; [[ "$a" == BOOTSTRAP* ]] && ok "8c BOOTSTRAP fixture really is BOOTSTRAP" || no "8c [$a]"


# 9 timeout value validation: 0 (GNU timeout: no limit) and non-numeric fall back to 20 with a typed WARN
mkdir -p "$TMP/kit9"
for f in "$TB"/*; do b="$(basename "$f")"; { [ "$b" = clean-check.sh ] || [ "$b" = tests ]; } || ln -s "$f" "$TMP/kit9/$b"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/kit9/clean-check.sh"
for v in 0 00 000 abc -3 1.5 0x; do
  run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT="$v" bash "$TMP/kit9/research-sdd-status.sh" "$TMP/c1" --next
  grep -qF "invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT=$v (need an integer >= 1) — using 20" <<<"$ERR" && [ "$RC" = 0 ] && ok "9 timeout=$v rejected, falls back to 20" || no "9 timeout=$v [$ERR]"
done
# valid positive integers (first/middle/last shapes of the leading-zero set): accepted, no fallback WARN.
# 007 and 005 were wrongly rejected by the old `0[0]*` glob (it matched any value starting with `00`); 01 / 10 / 7 always passed.
for v in 7 01 10 007 005 0010; do
  run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT="$v" bash "$TMP/kit9/research-sdd-status.sh" "$TMP/c1" --next
  grep -q 'invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT' <<<"$ERR" && no "9 valid timeout=$v wrongly rejected [$ERR]" || ok "9 valid timeout=$v accepted"
done
# empty value is the documented default (${VAR:-20}): no WARN, no fallback message
run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT= bash "$TMP/kit9/research-sdd-status.sh" "$TMP/c1" --next
grep -q 'invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT' <<<"$ERR" && no "9 empty timeout wrongly rejected [$ERR]" || ok "9 empty timeout -> default, no WARN"
# a leading-zero value is honoured numerically (007 -> 7s bound), not just tolerated: slow child cut off at ~1s for 001
run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT=001 bash "$TMP/kit7/research-sdd-status.sh" "$TMP/c1" --next
grep -qF 'unverifiable (timed out after 1s)' <<<"$ERR" && ok "9 timeout=001 honoured as 1s" || no "9 timeout=001 [$ERR]"

# 10 kill-after: a TERM-ignoring clean-check is killed shortly after the timeout, not waited on
mkdir -p "$TMP/kit10"
for f in "$TB"/*; do b="$(basename "$f")"; { [ "$b" = clean-check.sh ] || [ "$b" = tests ]; } || ln -s "$f" "$TMP/kit10/$b"; done
printf '#!/usr/bin/env bash\ntrap "" TERM\nexec sleep 14\n' > "$TMP/kit10/clean-check.sh"
t0=$SECONDS; run env RSDD_STATUS_CLEAN_CHECK_TIMEOUT=1 bash "$TMP/kit10/research-sdd-status.sh" "$TMP/c1" --next; el=$((SECONDS-t0))
[ "$el" -lt 10 ] && grep -qF 'unverifiable (timed out after 1s)' <<<"$ERR" && ok "10 TERM-ignoring child killed (${el}s)" || no "10 ${el}s [$ERR]"

# 11 the warn is tied to the verdict the gate printed: the exhausted STOP line and the INFO line come from the same run
mkcorpus "$TMP/c11" 0; run bash "$SUT" "$TMP/c11" --next
[ "$OUT" = "STOP | read-only-investigable exhausted (0)" ] && grep -q 'clean-check' <<<"$ERR" && ok "11 verbatim exhausted STOP line and the warn co-occur" || no "11 [$OUT] [$ERR]"

# 12 the exhausted-STOP-with-unverified-coverage call site (TC-WARN-CALL-UNVERIFIED): a retro exists, but the reconcile
# timeout binary is forced empty -> issues_due_gate marks coverage unverified and prints the marker STOP. The clean-check
# output must still reach stderr and the verdict/exit must be unchanged.
mkcorpus "$TMP/c12" 0; mkdir -p "$TMP/c12/retros"; printf '# retro\n' > "$TMP/c12/retros/r1.md"
git -C "$TMP/c12" add -A; git -C "$TMP/c12" -c user.name=t -c user.email=t@example.invalid commit -q -m retro
printf 'x\n' > "$TMP/c12/stray.json"
run env _IDG_TIMEOUT_BIN= bash "$SUT" "$TMP/c12" --next
[ "$OUT" = "STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]" ] && [ "$RC" = 0 ] && ok "12a unverified-coverage STOP verdict + exit 0" || no "12a rc=$RC [$OUT]"
grep -qF 'WARN: clean-check: GARBAGE untracked stray.json' <<<"$ERR" && ok "12b findings reach stderr from the unverified-STOP call site" || no "12b [$ERR]"
run env _IDG_TIMEOUT_BIN= RSDD_STATUS_NO_CLEAN_CHECK=1 bash "$SUT" "$TMP/c12" --next
grep -q 'clean-check' <<<"$ERR" && no "12c opt-out ignored at unverified site [$ERR]" || ok "12c opt-out honoured at unverified site"

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
  mt C 's/^  terminal_clean_warn  # TC-WARN-CALL$/  :/' 0 0 --good-has 'GARBAGE untracked' --bad-lacks 'GARBAGE untracked' -- bash '@SUT@' "$TMP/c2x" --next
  # C2: the call after the UNVERIFIED STOP verdict is removed -> findings never reach stderr
  mkcorpus "$TMP/c12x" 0; mkdir -p "$TMP/c12x/retros"; printf '# retro\n' > "$TMP/c12x/retros/r1.md"
  git -C "$TMP/c12x" add -A; git -C "$TMP/c12x" -c user.name=t -c user.email=t@example.invalid commit -q -m retro; printf 'x\n' > "$TMP/c12x/stray.json"
  mt C2 's/^    terminal_clean_warn  # TC-WARN-CALL-UNVERIFIED$/    :/' 0 0 --good-has 'GARBAGE untracked' --bad-lacks 'GARBAGE untracked' -- env _IDG_TIMEOUT_BIN= bash '@SUT@' "$TMP/c12x" --next
  # D: opt-out ignored
  mt D 's/\[ "\${RSDD_STATUS_NO_CLEAN_CHECK:-0}" = "1" \] && return 0//' 0 0 --good-lacks 'clean-check' --bad-has 'clean-check' -- env RSDD_STATUS_NO_CLEAN_CHECK=1 bash '@SUT@' "$TMP/c5" --next
  # E: timeout bound removed -> the slow clean-check runs its full 6s
  m="$MUT/research-sdd-status.sh"; rm -f "$m"
  if mutant_chain E "$SUT" "$m" 's/"\$_cc_to" -k 5 "\$_cc_secs" bash/bash/'; then
    rm -f "$MUT/clean-check.sh"; cp "$TMP/kit7/clean-check.sh" "$MUT/clean-check.sh"
    t0=$SECONDS; RSDD_STATUS_CLEAN_CHECK_TIMEOUT=1 bash "$m" "$TMP/c1" --next >/dev/null 2>&1; el=$((SECONDS-t0))
    if [ "$el" -ge 5 ]; then ok "teeth E: unbounded mutant waited ${el}s -> 7a has teeth"; else no "teeth E: mutant still bounded (${el}s) — THEATER"; fi
    rm -f "$MUT/clean-check.sh"; ln -s "$TB/clean-check.sh" "$MUT/clean-check.sh"
  else fail=$((fail+1)); fi
  # F: the INFO line leaks to stdout -> the golden compare (stdout+rc, check on vs off) goes red
  m="$MUT/research-sdd-status.sh"; rm -f "$m"
  if mutant_chain F "$SUT" "$m" "s/at terminal STOP.n' >&2 ;;/at terminal STOP\\n' ;;/"; then
    a="$(bash "$m" "$TMP/c1" --next 2>/dev/null)"; b="$(RSDD_STATUS_NO_CLEAN_CHECK=1 bash "$m" "$TMP/c1" --next 2>/dev/null)"
    if [ "$a" != "$b" ]; then ok "teeth F: stdout leak -> golden differs -> 8a has teeth"; else no "teeth F: mutant still identical — THEATER"; fi
  else fail=$((fail+1)); fi
  # G: kill-after removed -> a TERM-ignoring child is waited on in full
  m="$MUT/research-sdd-status.sh"; rm -f "$m"
  if mutant_chain G "$SUT" "$m" 's/"\$_cc_to" -k 5 /"$_cc_to" /'; then
    rm -f "$MUT/clean-check.sh"; cp "$TMP/kit10/clean-check.sh" "$MUT/clean-check.sh"
    t0=$SECONDS; RSDD_STATUS_CLEAN_CHECK_TIMEOUT=1 bash "$m" "$TMP/c1" --next >/dev/null 2>&1; el=$((SECONDS-t0))
    if [ "$el" -ge 12 ]; then ok "teeth G: no kill-after -> waited ${el}s -> 10 has teeth"; else no "teeth G: mutant still killed (${el}s) — THEATER"; fi
    rm -f "$MUT/clean-check.sh"; ln -s "$TB/clean-check.sh" "$MUT/clean-check.sh"
  else fail=$((fail+1)); fi
  # H2: leading-zero strip dropped -> '000' is no longer recognised as zero and passes through
  m="$MUT/research-sdd-status.sh"; rm -f "$m"
  if mutant_chain H2 "$SUT" "$m" 's/^    \*) _cc_stripped=.*$/    *) _cc_stripped="$_cc_secs" ;;/'; then
    rm -f "$MUT/clean-check.sh"; cp "$TMP/kit9/clean-check.sh" "$MUT/clean-check.sh"
    e="$(RSDD_STATUS_CLEAN_CHECK_TIMEOUT=000 bash "$m" "$TMP/c1" --next 2>&1 >/dev/null)"
    if grep -q 'invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT' <<<"$e"; then no "teeth H2: mutant still rejects 000 — THEATER"; else ok "teeth H2: no leading-zero strip -> 000 accepted -> 9 has teeth"; fi
    rm -f "$MUT/clean-check.sh"; ln -s "$TB/clean-check.sh" "$MUT/clean-check.sh"
  else fail=$((fail+1)); fi
  # H: zero no longer rejected (empty-check disabled) -> test 9's typed fallback WARN disappears
  m="$MUT/research-sdd-status.sh"; rm -f "$m"
  if mutant_chain H "$SUT" "$m" 's/if \[ -z "\$_cc_stripped" \]; then/if false; then/'; then
    rm -f "$MUT/clean-check.sh"; cp "$TMP/kit9/clean-check.sh" "$MUT/clean-check.sh"
    e="$(RSDD_STATUS_CLEAN_CHECK_TIMEOUT=0 bash "$m" "$TMP/c1" --next 2>&1 >/dev/null)"
    if grep -q 'invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT' <<<"$e"; then no "teeth H: mutant still rejects 0 — THEATER"; else ok "teeth H: zero accepted -> 9 has teeth"; fi
    rm -f "$MUT/clean-check.sh"; ln -s "$TB/clean-check.sh" "$MUT/clean-check.sh"
  else fail=$((fail+1)); fi
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
