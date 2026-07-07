#!/usr/bin/env bash
# verify-state.test.sh — RED-FIRST harness for verify-state.sh's living-mirror consistency lint.
#
# WHY THIS SHAPE (anti-"test theater"): the load-bearing behaviour is CHECK 1 — the stale-mirror
# FAIL that fires ONLY when the coverage metric reads "X / X" (all gaps claimed closed) AND the
# backlog still lists `pending` gaps. That exact desync (summary said 23/23 closed while gaps were
# still pending) is what let the pruebas-dashboards run-A emit a PREMATURE STOP. The discriminating
# cases feed a KNOWN-STALE state file and assert the linter CATCHES it (exit 1); the boundary cases
# (X != Y, or no metric) assert CHECK 1 stays SILENT so the check is provably gated on X==Y, not on
# "pending exists". --prove-teeth neuters CHECK 1 and asserts the stale fixture stops exiting 1,
# proving case STALE is genuinely load-bearing and not theater.
#
# Usage: verify-state.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-state.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# run <dir> : run the SUT on a target dir, capture stdout (SUT emits a benign
# "integer expression expected" stderr line on the zero-pending grep -c quirk — drop stderr).
run(){ bash "$SUT" "$1" 2>/dev/null; }
# code <dir> : run the SUT and echo only its exit code.
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
# state <dir> <line...> : create <dir> and drop a RESEARCH-STATE.md with the given lines.
state(){ local d="$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/RESEARCH-STATE.md"; }

echo "== verify-state.test.sh (SUT: $(basename "$SUT")) =="

# 1 — no arg / arg is not a directory → exit 2 (bad args).
if [ "$(code "")" = 2 ]; then ok "no/empty arg → exit 2"; else no "empty arg: got $(code '') (want 2)"; fi
if [ "$(code "$TMP/does-not-exist")" = 2 ]; then ok "non-directory arg → exit 2"; else no "non-dir arg: got $(code "$TMP/does-not-exist") (want 2)"; fi

# 2 — target dir with NO RESEARCH-STATE*.md → exit 2 (no state file).
d="$TMP/nostate"; mkdir -p "$d"
if [ "$(code "$d")" = 2 ]; then ok "dir with no RESEARCH-STATE*.md → exit 2"; else no "no-state: got $(code "$d") (want 2)"; fi

# 3 — CONSISTENT: metric 5 / 5, zero pending gaps → exit 0, prints the ok line.
d="$TMP/consistent"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap 1 closed' '- gap 2 closed'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +summary is consistent'; then
  ok "consistent 5/5 · zero pending → exit 0 + ok line"
else no "consistent: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'ok|fail' | head -1)"; fi

# 4 — STALE MIRROR (the core FAIL): metric 23 / 23 WITH pending gap rows → exit 1 + PREMATURE STOP line.
#     Mirrors the real pruebas-dashboards run-A desync (summary 23/23 closed while gaps pending).
d="$TMP/stale"
state "$d" '# Research State' 'coverage metric: 23 / 23 declared gaps closed' \
  '## Backlog' '- gap A pending' '- gap B pending' '- gap C pending'
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL' && printf '%s\n' "$out" | grep -q 'PREMATURE STOP'; then
  ok "STALE 23/23 + pending → exit 1 + FAIL/PREMATURE STOP"
else no "stale: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|premature' | head -1)"; fi

# 5 — NON-EQUAL metric guard: metric 3 / 5 WITH pending gaps → exit 0 (CHECK 1 must NOT fire when X != Y).
#     Key boundary: proves the FAIL is gated on X==Y, not merely on "pending exists".
d="$TMP/unequal"
state "$d" '# Research State' 'coverage metric: 3 / 5 gaps closed' '## Backlog' '- gap A pending' '- gap B pending'
if [ "$(code "$d")" = 0 ]; then ok "3/5 + pending → exit 0 (CHECK 1 gated on X==Y, stays silent)"
else no "unequal-metric: exit $(code "$d") (want 0 — CHECK 1 wrongly fired on X!=Y)"; fi

# 6 — NO parseable metric line at all → exit 0 (cx/cy empty → CHECK 1 cannot fire even with pending).
d="$TMP/nometric"
state "$d" '# Research State' 'No coverage line here at all.' '## Backlog' '- gap A pending'
if [ "$(code "$d")" = 0 ]; then ok "no metric line + pending → exit 0 (empty cx/cy → CHECK 1 inert)"
else no "no-metric: exit $(code "$d") (want 0)"; fi

# 7 — CHECK 2 WARN: 'Covered blocks: 21' claim vs a different on-disk *block*.md count → WARN printed,
#     but exit code UNAFFECTED (still 0 because CHECK 1 does not fire — metric equal, zero pending).
d="$TMP/warn"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 21' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'WARN.*disagrees with 2 block file'; then
  ok "CHECK 2: claim 21 vs 2 on-disk → WARN printed, exit still 0"
else no "warn: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 8 — NESTED state: RESEARCH-STATE.md under a corpus/ subdir (within maxdepth 3) is found and linted.
#     Reuse the stale desync so we can assert the nested file is genuinely parsed (exit 1, not skipped).
d="$TMP/nested"; mkdir -p "$d/corpus"
state "$d/corpus" '# Research State' 'coverage metric: 23 / 23 gaps closed' '## Backlog' '- gap A pending'
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -q 'PREMATURE STOP'; then
  ok "nested corpus/RESEARCH-STATE.md found + linted (stale caught, exit 1)"
else no "nested: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'no research-state|premature' | head -1)"; fi

# 9 — CHECK 2 quiet: covered-blocks claim MATCHES the on-disk count → NO warn (and exit 0).
d="$TMP/nowarn"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 2' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: claim 2 == 2 on-disk → no WARN, exit 0"
else no "no-warn: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 10 — CHECK 2 on-disk guard: 'Covered blocks: 5' claim but ZERO *block*.md on disk → NO warn (exit 0).
#      Pins the `[ "${ondisk:-0}" -gt 0 ]` guard at verify-state.sh:49 — CHECK 2 is SUPPRESSED when nothing
#      is on disk (you cannot 'disagree' with an empty glob). Load-bearing: flip the guard to `-ge 0` in a
#      mutant and the WARN WOULD fire (5 != 0), so this "no WARN" assertion pins that guard. See --prove-teeth.
d="$TMP/warn-zero-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 5' '## Backlog' '- gap done'
# NOTE: no *block*.md files created → ondisk == 0.
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: claim 5 vs 0 on-disk → guard -gt 0 suppresses WARN, exit 0"
else no "warn-zero-ondisk: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 11 — CHECK 2 empty-claim guard IN ISOLATION: NO 'Covered blocks' line, but block files DO exist on disk
#      (ondisk > 0). CHECK 2 stays silent specifically because `covered_claim` is empty (the
#      `-n "${covered_claim:-}"` guard), independent of the on-disk count. Earlier cases always had
#      ondisk==0 too, so only this fixture (ondisk>0) isolates the empty-claim guard.
d="$TMP/nocovered-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"   # ondisk == 2, but no covered-blocks claim
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: no covered-blocks line + 2 on-disk → empty-claim guard keeps it silent, exit 0"
else no "nocovered-ondisk: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 12 — BUG 1 (Spanish block glob): blocks named bloqueNN.md must be counted by CHECK 2's on-disk
#      glob. The niagara corpus names its blocks `bloque125.md`; the old `-name '*block*.md'` glob is
#      case-sensitive AND blind to `bloque`, so it counted them as 0 and CHECK 2 could never fire on
#      that corpus. Fixture mixes Spanish/English/mixed-case + one name matching BOTH patterns to pin
#      case-insensitivity AND no-double-count: 4 DISTINCT files → summary must read "4 block file(s)".
d="$TMP/bloque-glob"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 21' '## Backlog' '- gap done'
printf 'x\n' > "$d/bloque125.md"          # Spanish, lowercase — invisible to the old '*block*.md' glob
printf 'x\n' > "$d/Bloque126.md"          # mixed case — needs a case-insensitive match
printf 'x\n' > "$d/block-99.md"           # English — the old glob already counted this one
printf 'x\n' > "$d/block-bloque-1.md"     # matches BOTH patterns — must be counted exactly ONCE
out="$(run "$d")"
if printf '%s\n' "$out" | grep -qE '4 block file\(s\) on disk'; then
  ok "BUG1: bloqueNN.md counted (4 distinct, no double-count) → '4 block file(s) on disk'"
else no "bloque-glob: on-disk count :: $(printf '%s\n' "$out" | grep -iE 'block file' | head -1)"; fi

# 13 — BUG 2 (only the FIRST state file is linted): a corpus with several RESEARCH-STATE-*.md (niagara
#      keeps ~12, one per focus) must lint EVERY one, not just `head -1`. Fixture: two consistent
#      focuses + one STALE focus (23/23 while gaps pending). The old `head -1` linted a single file,
#      printing ONE header and silently skipping the other focuses. Assert ALL THREE basenames appear
#      (every file linted) AND exit 1 (the stale focus is caught). The all-headers check is
#      order-independent, so this stays deterministic regardless of find's traversal order.
d="$TMP/multistate"; mkdir -p "$d"
printf '%s\n' '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-alpha.md"
printf '%s\n' '# Research State' 'coverage metric: 7 / 7 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-beta.md"
printf '%s\n' '# Research State' 'coverage metric: 23 / 23 declared gaps closed' '## Backlog' '- gap A pending' '- gap B pending' > "$d/RESEARCH-STATE-gamma.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-alpha.md' \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-beta.md' \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-gamma.md'; then
  ok "BUG2: every RESEARCH-STATE-*.md linted (3 headers) + stale focus caught → exit 1"
else no "multistate: exit $(code "$d") · headers seen: $(printf '%s\n' "$out" | grep -c 'verify-state:')"; fi

# 14 — BUG 3 (zero-pending corpus crashes CHECK 1): a corpus with a metric like '3 / 3 closed' and NO
#      `pending` rows. `grep -c` already prints 0 on no match, so the old `|| echo 0` APPENDED a second
#      line → `pending` became the two-line string "0\n0" → `[ "0\n0" -gt 0 ]` threw
#      "integer expression expected" on stderr (seen live on the three.js corpus). Assert a CLEAN run:
#      exit 0 AND no integer-expression error on stderr.
d="$TMP/zero-pending"
state "$d" '# Research State' 'coverage metric: 3 / 3 gaps closed' '## Backlog' '- gap 1 closed' '- gap 2 closed' '- gap 3 closed'
err="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$err" | grep -qiE 'integer expression'; then
  ok "BUG3: zero-pending metric 3/3 → exit 0, no 'integer expression expected' on stderr"
else no "zero-pending: exit $(code "$d") · stderr: $(printf '%s\n' "$err" | grep -iE 'integer expression' | head -1)"; fi

# NEGATIVE CONTROL — prove CHECK 1 (the STALE detection) has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter CHECK 1's condition; expect the STALE fixture to stop exiting 1 --"
  mutant="$TMP/verify-state.MUTANT.sh"
  # Force CHECK 1's guard false so the stale-mirror FAIL can never fire.
  sed 's/^\( *\)if \[ -n "${cx:-}".*then$/\1if false; then  # MUTANT: CHECK 1 neutered/' "$SUT" > "$mutant"
  if ! grep -q 'MUTANT: CHECK 1 neutered' "$mutant"; then
    no "teeth: could not build mutant (CHECK 1 guard line not found — did the SUT change?)"
  else
    d="$TMP/stale"   # reuse the flagship stale fixture (case 4)
    bash "$mutant" "$d" >/dev/null 2>&1; mgot=$?
    if [ "$mgot" = 0 ]; then
      ok "teeth: neutered mutant false-passes (exit 0) → STALE assertion has teeth"
    else no "teeth: mutant exit $mgot (want 0) — STALE case does NOT depend on CHECK 1 (THEATER)"; fi
  fi

  # Teeth for case 10 — flip CHECK 2's on-disk guard `-gt 0` → `-ge 0`; the zero-on-disk fixture must
  # then EMIT a WARN (5 != 0), proving case 10's "no WARN" assertion genuinely pins that guard.
  echo "-- teeth: flip CHECK 2 guard -gt 0 → -ge 0; expect the zero-on-disk fixture to now WARN --"
  mutant2="$TMP/verify-state.CHECK2.MUTANT.sh"
  sed 's/\[ "${ondisk:-0}" -gt 0 \]/[ "${ondisk:-0}" -ge 0 ]/' "$SUT" > "$mutant2"
  if ! grep -q '"${ondisk:-0}" -ge 0' "$mutant2"; then
    no "teeth(check2): could not build mutant (guard line not found — did the SUT change?)"
  else
    d="$TMP/warn-zero-ondisk"   # reuse case 10 fixture: claim 5, zero *block*.md on disk
    m2out="$(bash "$mutant2" "$d" 2>/dev/null)"
    if printf '%s\n' "$m2out" | grep -qE 'WARN.*disagrees with 0 block file'; then
      ok "teeth: -ge 0 mutant WARNs on zero on-disk → case 10 'no WARN' pins the -gt 0 guard"
    else no "teeth(check2): mutant did NOT warn — case 10 does NOT depend on the guard (THEATER)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
