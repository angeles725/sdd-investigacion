#!/usr/bin/env bash
# blocked-rows.test.sh — lib/blocked-rows.sh + its two consumers (kit #923, #913).
#
# One definition of "blocked entry" (lib/blocked-rows.sh). The two consumers, verify-state.sh and research-sdd-status.sh,
# are shims over Go commands (kit #2457, #2549); the degraded-state and --next behavior of the status script is pinned in
# internal/status/show. This suite proves (1) the lib's count on frozen fixtures, with the open entry in the
# FIRST / MIDDLE / LAST / SINGLE position, (2) that both consumers AGREE with the lib and with the fixture's expected
# count, (3) that a CLOSED child gap which keeps a `needs:` clause is not counted (#913), and (4) that absent-input is
# distinguishable from a genuine zero (CLAUDE.md §7).
#
# Fixtures: tests/fixtures/blocked-rows/<case>.expect<N>.md — the expected count is IN THE FILENAME, so the
# assertion is never a literal baked into this script. Each fixture is a complete RESEARCH-STATE.md.
#
# Usage: blocked-rows.test.sh                (run the suite)
#        blocked-rows.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = all assertions held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt
LIB="$TOOLBELT/lib/blocked-rows.sh"
VS="$TOOLBELT/verify-state.sh"
ST="$TOOLBELT/research-sdd-status.sh"
FIX="$HERE/fixtures/blocked-rows"

[ -f "$LIB" ] || { echo "FATAL: lib/blocked-rows.sh not found" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixtures/blocked-rows not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# shellcheck source=../lib/blocked-rows.sh
. "$LIB"
declare -F blocked_open_count >/dev/null 2>&1 && declare -F blocked_rows_body >/dev/null 2>&1 \
  || { echo "FATAL: lib/blocked-rows.sh did not define its functions" >&2; exit 2; }

echo "== blocked-rows.test.sh (shared blocked-rows lib, kit #923 #913) =="

# Every fixture, with the count its filename promises. The glob is counted so a skipped traversal cannot pass.
shopt -s nullglob
fixtures=("$FIX"/*.expect*.md)
shopt -u nullglob
if [ "${#fixtures[@]}" -ge 10 ]; then ok "fixtures: ${#fixtures[@]} traversed (>= 10; an empty glob would be a silent zero)"
else no "fixtures: only ${#fixtures[@]} found under $FIX"; fi

expect_of() { local b="${1##*/}"; b="${b#*.expect}"; echo "${b%.md}"; }
case_of()   { local b="${1##*/}"; echo "${b%%.expect*}"; }
# derived_vs DIR: the verify-state derived blocked count (the number after the slash). status_blk DIR: status display
# (both consumers are Go commands behind shims now; the parity line below keeps them agreeing with the lib).
derived_vs() { bash "$VS" "$1" 2>/dev/null | sed -n 's/.*blocked_open=[^ ·/]*\/\([0-9][0-9]*\).*/\1/p' | head -1; }
status_blk() { bash "$ST" "$1" 2>/dev/null | sed -n 's/.*stop-control .*blocked=\([0-9][0-9]*\).*/\1/p' | head -1; }

echo "-- 1. lib count + consumer parity on every fixture --"
for f in "${fixtures[@]}"; do
  c="$(case_of "$f")"; want="$(expect_of "$f")"
  got_lib="$(blocked_open_count "$f")"
  [ "$got_lib" = "$want" ] && ok "lib $c = $want" || no "lib $c: got [$got_lib] want $want"
  d="$TMP/par-$c"; mkdir -p "$d"; cp "$f" "$d/RESEARCH-STATE.md"
  got_vs="$(derived_vs "$d")"; got_st="$(status_blk "$d")"
  [ "$got_vs" = "$want" ] && ok "verify-state $c = $want" || no "verify-state $c: got [$got_vs] want $want"
  [ "$got_vs" = "$got_st" ] && [ "$got_st" = "$got_lib" ] || no "PARITY $c: verify-state=[$got_vs] status=[$got_st] lib=[$got_lib]"
done

echo "-- 2. edge positions are covered (FIRST / MIDDLE / LAST / SINGLE open entry) --"
for need in child-first-open child-middle-open child-last-open child-single-open child-closed-first-then-open child-closed-last-after-open; do
  if compgen -G "$FIX/$need.expect*.md" >/dev/null; then ok "edge fixture present: $need"; else no "edge fixture MISSING: $need"; fi
done

echo "-- 3. absent-input is not a zero (CLAUDE.md §7) --"
out="$(blocked_open_count "$TMP/does-not-exist.md" 2>"$TMP/err")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'absent or unreadable' "$TMP/err"; then ok "absent file: rc 2, empty stdout, typed stderr"
else no "absent file: rc=$rc out=[$out] err=[$(cat "$TMP/err")]"; fi
out="$(blocked_open_count "$TMP" 2>/dev/null)"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok "directory passed as the state file: rc 2, empty stdout"; else no "directory: rc=$rc out=[$out]"; fi
out="$(blocked_open_count "$FIX/no-sections.expect0.md" 2>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = 0 ]; then ok "present state file with no blocked entries: rc 0, prints 0 (genuine zero)"; else no "genuine zero: rc=$rc out=[$out]"; fi

echo "-- 3b. a broken awk/grep is a typed degraded state, never a confident 0 (CLAUDE.md §7) --"
REAL_AWK="$(command -v awk)"
mk_stub() { # DIR MODE: awk stub on PATH. all = always exits 2; child = exits 2 only for the child-gap program
  mkdir -p "$1"
  if [ "$2" = all ]; then printf '#!/bin/sh\necho "awk: stub failure" >&2\nexit 2\n' > "$1/awk"
  else printf '#!/bin/sh\ncase "$*" in *is_closed*) echo "awk: syntax error" >&2; exit 2;; esac\nexec %s "$@"\n' "$REAL_AWK" > "$1/awk"; fi
  chmod +x "$1/awk"
}
mk_stub "$TMP/stub-all" all; mk_stub "$TMP/stub-child" child
for mode in all child; do
  out="$(PATH="$TMP/stub-$mode:$PATH" blocked_open_count "$FIX/child-single-open.expect1.md" 2>"$TMP/err")"; rc=$?
  if [ "$rc" = 3 ] && [ -z "$out" ] && grep -q '^blocked-rows: degraded ' "$TMP/err"; then ok "broken awk ($mode): rc 3, empty stdout, typed degraded stderr"
  else no "broken awk ($mode): rc=$rc out=[$out] err=[$(cat "$TMP/err")]"; fi
done

# The status-script cases of this section (broken awk through the display and --sync-state, the two-focus and --focus b
# sync, the W1 investigable/next-step degrade) moved to Go with the script (kit #2549): internal/status/show goldens
# k-state-file-unreadable (s6), unreadable-state and unreadable-sibling-focus (s3), s8a-br-128-two-focus-sync-with-an-
# unreadable-file-writes-nothing, and TestResolveDegradedIsFatal.

echo "-- 3c. blocked_rows_body reports the first failing extractor, not only the last (#2018 item 3) --"
mk_body_stub() { # DIR HEADING: awk stub that fails only for the extractor of HEADING
  mkdir -p "$1"; printf '#!/bin/sh\ncase "$*" in *"h=%s"*) echo "awk: stub failure" >&2; exit 2;; esac\nexec %s "$@"\n' "$2" "$REAL_AWK" > "$1/awk"; chmod +x "$1/awk"
}
mk_body_stub "$TMP/stub-body1" '## Blocked gaps'; mk_body_stub "$TMP/stub-body2" '## Non-investigable gaps'; mk_body_stub "$TMP/stub-body3" '## Blocked /'
for n in 1 2 3; do
  PATH="$TMP/stub-body$n:$PATH" blocked_rows_body "$FIX/standard-and-child-mixed.expect5.md" >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && ok "blocked_rows_body: extractor $n of 3 failing surfaces a non-zero rc ($rc)" || no "blocked_rows_body: extractor $n of 3 failing was lost (rc 0)"
  out="$(PATH="$TMP/stub-body$n:$PATH" blocked_open_count "$FIX/standard-and-child-mixed.expect5.md" 2>/dev/null)"; rc=$?
  if [ "$rc" = 3 ] && [ -z "$out" ]; then ok "blocked_open_count: extractor $n of 3 failing is degraded rc 3, empty stdout"; else no "blocked_open_count: extractor $n failing: rc=$rc out=[$out]"; fi
done


echo "-- 3d. registry and CHECK H controls for the degraded blocked-rows derivation (#2024) --"
# The --next and multi-focus display refusals of #2024 (DEGRADED answer, exit 3, scoping by --focus, the paused-focus
# and queue backups, the non-head probe and its reason-codes footer) are Go behavior now (kit #2549), pinned in
# internal/status/show: TestResolveDegradedIsFatal and TestNextDegradedRefusals (s4_unit_test.go), the n-* and k-*
# scenarios of s6, TestS8aNextDegradedNonHeadAndScoped and TestS8aDisplayDegradedNonHead (s8a_blocked_test.go).
# #2024 item 5: the registry continuation names BOTH typed stderr forms of the lib
_rc_row="$(grep -F 'degraded: blocked_open: blocked_open_count rc' "$TOOLBELT/reason-codes.v1.md")"
if grep -qF 'state file absent or unreadable' <<<"$_rc_row"; then ok "reason-codes row continuation names the rc-2 'state file absent or unreadable' form too"
else no "reason-codes blocked_open row does not name the rc-2 stderr line"; fi
# #2024 item 3: verify-state CHECK H must not sum with a degraded body (no spurious 'stale denominator' next to 'unverifiable')
mkdir -p "$TMP/chkh"; sed 's/^known_gaps: 1$/known_gaps: 7/' "$FIX/next-blocked-gap.md" > "$TMP/chkh/RESEARCH-STATE.md"
out="$(bash "$VS" "$TMP/chkh" 2>&1)"
if grep -q 'stale denominator' <<<"$out"; then ok "CHECK H control: a healthy read with a wrong known_gaps does WARN 'stale denominator'"; else no "CHECK H control lost its stale-denominator WARN: $(grep -m2 'known_gaps' <<<"$out")"; fi

# (kit issue #2457) verify-state.sh is a shim to `rsdd verify state`: it has no awk and no blocked-rows lib to sabotage, so
# its sabotage cases (broken awk, failing extractor, missing or empty lib, CHECK H with a failing read) and TOOTH-7/9/14/23
# for it are gone. Its healthy behaviour is pinned by TestDifferentialState and TestDifferentialStateRandom (internal/verify).
echo ""
echo "== $pass passed · $fail failed =="

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== mutation controls =="
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  t_pass=0; t_fail=0
  mk() { mutant_chain_or_count t_fail "$@" || return 1; }
  tt() { if mutant_tooth "$@"; then t_pass=$((t_pass+1)); else t_fail=$((t_fail+1)); fi; }
  MD="$TMP/mutants"; mkdir -p "$MD"
  AWKBAD='awk: |syntax error|fatal:'   # a mutant that does not compile / dies at runtime is theater, not a bite
  COUNT_ARGV=(bash -c '. "$1"; blocked_open_count "$2"' _ @SUT@)

  # TOOTH-1 (#913): the bullet-line closed check is what stops a closed entry's own `needs:` counting.
  mk "TOOTH-1 mutant build" "$LIB" "$MD/t1.sh" 's/if (!cl \&\& tolower(\$0) ~ \/needs:\/)/if (tolower($0) ~ \/needs:\/)/' \
    && tt "TOOTH-1: closed entry with needs: on its bullet line counted when the closed check is dropped" 0 0 "$MD/t1.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^1$' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$FIX/child-closed-bullet-keeps-needs.expect0.md"

  # TOOTH-2 (#913): the continuation-line closed check.
  mk "TOOTH-2 mutant build" "$LIB" "$MD/t2.sh" 's/if (ib \&\& !done \&\& !cl \&\&/if (ib \&\& !done \&\&/' \
    && tt "TOOTH-2: closed entry with needs: on a continuation line counted when the closed check is dropped" 0 0 "$MD/t2.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^1$' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$FIX/child-closed-single-keeps-needs.expect0.md"

  # TOOTH-3: the closed flag is per ENTRY — each bullet re-derives it. A sticky flag lets a closed entry swallow
  # the open entry after it.
  mk "TOOTH-3 mutant build" "$LIB" "$MD/t3.sh" 's/cl=is_closed(\$0)/cl=(cl||is_closed($0))/' \
    && tt "TOOTH-3: a sticky closed flag hides the open entry that follows a closed one" 0 0 "$MD/t3.sh" --orig "$LIB" \
         --good-has '^1$' --bad-has '^0$' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$FIX/child-closed-first-then-open.expect1.md"

  # TOOTH-4a..4e: each closed-marker branch is load-bearing -- delete ONE branch and a fixture relying on it counts.
  # Marker lines in the lib carry a CLOSED-* sentinel; the bracket branch is the function's final return.
  tb4() { # LABEL SENTINEL|BRACKET FIXTURE
    if [ "$2" = BRACKET ]; then
      mk "$1 mutant build" "$LIB" "$MD/$1.sh" 's/return (tolower(s) ~ .*CLOSED-BRACKET$/return 0/'
    else
      mk "$1 mutant build" "$LIB" "$MD/$1.sh" "/# $2\$/d"
    fi && tt "$1: dropping the $2 branch makes a closed entry count" 0 0 "$MD/$1.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^[1-9]' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$3"
  }
  tb4 TOOTH-4a CLOSED-STRIKE  "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4b CLOSED-TICK    "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4c CLOSED-CERRADO "$FIX/child-closed-single-keeps-needs.expect0.md"
  tb4 TOOTH-4d CLOSED-WORD    "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4e BRACKET        "$FIX/child-closed-markers-all.expect0.md"
  # TOOTH-4f..4k: the word guard has independent parts; each gets its own mutant and its own fixture(s), and the
  # boundary check is paired (closed-loop AND enclosed) so neither side of it is covered by a single case.
  # (sed uses '#' delimiters; '&' is escaped.)
  tg() { # LABEL SED-EXPR WHAT GOOD-RE BAD-RE FIXTURE
    mk "$1 mutant build" "$LIB" "$MD/$1.sh" "$2" \
      && tt "$1: $3" 0 0 "$MD/$1.sh" --orig "$LIB" --good-has "$4" --bad-has "$5" --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$6"
  }
  BND='s#if (bef !~ /\[A-Za-z0-9_-\]/ \&\& aft !~ /\[A-Za-z0-9_-\]/ \&\& #if (#'
  tg TOOTH-4f1 "$BND" "without the boundary check CLOSED-LOOP falsely closes an open entry" '^1$' '^0$' "$FIX/child-open-closed-loop.expect1.md"
  tg TOOTH-4f2 "$BND" "without the boundary check ENCLOSED falsely closes an open entry" '^1$' '^0$' "$FIX/child-open-enclosed.expect1.md"
  tg TOOTH-4g 's# \&\& !negated(substr(s, 1, pos - 1))##' "without the negation check NOT CLOSED falsely closes an open entry" '^1$' '^0$' "$FIX/child-open-not-closed.expect1.md"
  tg TOOTH-4h 's#while (k < 2)#while (k < 1)#' "a negation window of one word lets NOT YET CLOSED close" '^1$' '^0$' "$FIX/child-open-not-yet-closed.expect1.md"
  tg TOOTH-4i 's#u == "NO" ||#u ~ /NO$/ ||#' "a suffix match on NO makes X-NO CLOSED negate (whole-word token lost)" '^0$' '^1$' "$FIX/child-closed-id-ending-no.expect0.md"
  tg TOOTH-4j 's# || u == "NEVER"##' "without NEVER in the negation set NEVER CLOSED closes" '^1$' '^0$' "$FIX/child-open-never-closed.expect1.md"
  tg TOOTH-4l 's#off = pos + rl - 1; t = substr(s, off + 1)#break#' "breaking out of the rescan loop on the first rejection loses ENCLOSED CLOSED" '^0$' '^1$' "$FIX/child-closed-after-rejected-match.expect0.md"
  tg TOOTH-4k 's#bef = (pos > 1) ? substr(s, pos - 1, 1)#bef = (RSTART > 1) ? substr(t, RSTART - 1, 1)#' "re-anchoring the preceding char at RSTART==1 after a rejected match makes CLOSEDCLOSED close" '^1$' '^0$' "$FIX/child-open-repeated-closedclosed.expect1.md"
  tg TOOTH-4m 's#while (k < 2)#while (k < 9)#' "a negation window of nine words lets a distant NOT negate CLOSED" '^0$' '^1$' "$FIX/child-closed-far-negation.expect0.md"
  tg TOOTH-4n '/# DASH-SKIP/d' "without the dash skip a bare - consumes a window slot and NOT YET - CLOSED closes" '^1$' '^0$' "$FIX/child-open-dash-in-window.expect1.md"
  tg TOOTH-4o 's#u = toupper(w) #u = w #' "a case-sensitive negation word lets Not CLOSED close" '^1$' '^0$' "$FIX/child-open-mixed-case-not.expect1.md"

  # TOOTH-4p: the compile guard itself. A mutant that does not compile makes the lib return the degraded rc 3 with
  # EMPTY stdout; that rc check is the MECHANISM that rejects it (--bad-has '^1$' cannot match an empty stdout, and
  # the twin below proves it with no --bad-lacks at all). --bad-lacks "$AWKBAD" is defense in depth on top of it.
  mk "TOOTH-4p mutant build" "$LIB" "$MD/t4p.sh" 's#while (k < 2)#while (k < 2 \&\& )#' \
    && if mutant_tooth "TOOTH-4p-probe" 0 0 "$MD/t4p.sh" --orig "$LIB" --good-has '^0$' --bad-has '^1$' --bad-lacks "$AWKBAD" \
         -- "${COUNT_ARGV[@]}" "$FIX/child-closed-far-negation.expect0.md" >/dev/null 2>&1; then
         t_fail=$((t_fail+1)); echo "  FAIL  TOOTH-4p: a non-compiling awk mutant was counted as a bite"
       else t_pass=$((t_pass+1)); echo "  PASS  TOOTH-4p: a non-compiling awk mutant is rejected, not counted as a bite"; fi

  # TOOTH-4p-twin (#2018 item 2): the same probe WITHOUT --bad-lacks. The rc-3 degraded path alone (the mutant prints
  # nothing on stdout, so --bad-has '^1$' cannot match) rejects a non-compiling mutant; --bad-lacks above is defense in depth.
  if mutant_tooth "TOOTH-4p-twin-probe" 0 0 "$MD/t4p.sh" --orig "$LIB" --good-has '^0$' --bad-has '^1$' \
       -- "${COUNT_ARGV[@]}" "$FIX/child-closed-far-negation.expect0.md" >/dev/null 2>&1; then
       t_fail=$((t_fail+1)); echo "  FAIL  TOOTH-4p-twin: without --bad-lacks a non-compiling awk mutant was counted as a bite"
     else t_pass=$((t_pass+1)); echo "  PASS  TOOTH-4p-twin: the rc-3 degraded path alone rejects a non-compiling awk mutant (no --bad-lacks)"; fi

  # TOOTH-4q/4r (#2018 item 1): lowercase negation counts only when adjacent to the marker or separated by a filler.
  tg TOOTH-4q 's#if (fill || w == u) return 1#return 1#' "any-case negation anywhere in the window makes lowercase 'no repro — CLOSED' read as negated" '^0$' '^1$' "$FIX/child-closed-lowercase-no-repro.expect0.md"
  tg TOOTH-4q2 's#if (fill || w == u) return 1#return 1#' "any-case negation anywhere in the window makes 'not needed, CLOSED' read as negated" '^0$' '^1$' "$FIX/child-closed-lowercase-not-needed.expect0.md"
  tg TOOTH-4q3 's#if (fill || w == u) return 1#return 1#' "any-case negation anywhere in the window makes 'no reproducible — CLOSED' read as negated" '^0$' '^1$' "$FIX/child-closed-lowercase-no-reproducible.expect0.md"
  tg TOOTH-4r 's#if (u != "YET" \&\& u != "LONGER") fill = 0#fill = 0#' "without the YET/LONGER fillers lowercase 'no longer CLOSED' stops negating" '^1$' '^0$' "$FIX/child-open-lowercase-no-longer-closed.expect1.md"
  tg TOOTH-4s 's#if (fill || w == u) return 1#if (w == u) return 1#' "uppercase-only negation drops the adjacent any-case rule so 'Not CLOSED' closes" '^1$' '^0$' "$FIX/child-open-mixed-case-not.expect1.md"

  # TOOTH-10 (#2018 item 3): blocked_rows_body must keep the FIRST failing extractor, not just the last one's rc.
  mk "TOOTH-10 mutant build" "$LIB" "$MD/t10.sh" 's#\[ "\$_br_r" -eq 0 \] || \[ "\$_br_rc" -ne 0 \] || _br_rc=\$_br_r#_br_rc=$_br_r#' \
    && tt "TOOTH-10: a failure in a non-last section extractor is lost when only the last rc is kept" 3 0 "$MD/t10.sh" --orig "$LIB" \
         --good-lacks '^[0-9]' --bad-has '^[0-9]+$' -- bash -c 'PATH="$2:$PATH"; . "$1"; blocked_open_count "$3"' _ @SUT@ "$TMP/stub-body1" "$FIX/standard-and-child-mixed.expect5.md"

  # TOOTH-11/12/13, 15-22 and 24-28 (#2017, #2024) mutated copies of research-sdd-status.sh: the script is a shim over
  # `rsdd status show` (kit #2549), so they are retired. Their Go pins are internal/status/show: TestReplayS6 (every
  # report scenario carries blocked=DEGRADED, investigable=DEGRADED, the degraded: line after the header and the one
  # reason-codes footer), TestReplayS3 unreadable-state (no envelope written), TestResolveDegradedIsFatal and
  # TestNextDegradedRefusals (the exit-3 DEGRADED refusals, queue and paused-focus backups, --focus scoping), and the
  # s8a_blocked_test.go non-head and relative-path cases.

  # TOOTH-8: the degraded guard -- without it a failing awk collapses into a confident 0 with rc 0.
  mk "TOOTH-8 mutant build" "$LIB" "$MD/t8.sh" '/^  \[ "\$_rc" -eq 0 \] || { echo "blocked-rows: degraded child-gap counter/d; /^  case "\$_d2" in/d' \
    && tt "TOOTH-8: a failing child-gap awk reads as a bare number when the degraded guard is dropped" 3 0 "$MD/t8.sh" --orig "$LIB" \
         --good-lacks '^[0-9]' --bad-has '^[0-9]+$' -- bash -c 'PATH="$2:$PATH"; . "$1"; blocked_open_count "$3"' _ @SUT@ "$TMP/stub-child" "$FIX/child-single-open.expect1.md"


  # TOOTH-5: the `## Blocked /` family is part of the body (METHODOLOGY §21.1).
  mk "TOOTH-5 mutant build" "$LIB" "$MD/t5.sh" "s|'## Non-investigable gaps' '## Blocked /'|'## Non-investigable gaps'|" \
    && tt "TOOTH-5: without the '## Blocked /' section the mixed fixture loses an entry" 0 0 "$MD/t5.sh" --orig "$LIB" \
         --good-has '^5$' --bad-has '^4$' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$FIX/standard-and-child-mixed.expect5.md"

  # TOOTH-6: the absent-input guard — without it a missing file is a silent zero.
  mk "TOOTH-6 mutant build" "$LIB" "$MD/t6.sh" '/if \[ ! -r "\$_f" \] || \[ -d "\$_f" \]; then/,/^  fi$/d' \
    && tt "TOOTH-6: dropping the absent-input guard turns rc 2 into the degraded rc 3 (never a bare 0; the stage guard is the backstop)" 2 3 "$MD/t6.sh" --orig "$LIB" \
         --good-lacks '^0$' --bad-lacks '^0$' -- "${COUNT_ARGV[@]}" "$TMP/does-not-exist.md"

  # TOOTH-7 (the consumer's function-less lib guard) is retired with the status body that sourced the lib (kit #2549): the
  # Go port has no lib to source, and the mutant had already stopped biting (rc 2 on the original).

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
