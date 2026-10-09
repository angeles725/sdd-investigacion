#!/usr/bin/env bash
# blocked-rows.test.sh — lib/blocked-rows.sh + its two consumers (kit #923, #913).
#
# One definition of "blocked entry" (lib/blocked-rows.sh) is sourced by research-sdd-status.sh and
# verify-state.sh. This suite proves (1) the lib's count on frozen fixtures, with the open entry in the
# FIRST / MIDDLE / LAST / SINGLE position, (2) that both consumers (and `--sync-state`) AGREE with the lib
# and with the fixture's expected count, (3) that a CLOSED child gap which keeps a `needs:` clause is not
# counted (#913), (4) that a missing or empty lib fails each consumer loudly, and (5) absent-input is
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
# derived_vs DIR: the verify-state derived blocked count (the number after the slash). status_blk DIR: status display.
derived_vs() { bash "$VS" "$1" 2>/dev/null | sed -n 's/.*blocked_open=[^ ·/]*\/\([0-9][0-9]*\).*/\1/p' | head -1; }
status_blk() { bash "$ST" "$1" 2>/dev/null | sed -n 's/.*stop-control .*blocked=\([0-9][0-9]*\).*/\1/p' | head -1; }
synced_blk() { local d="$1"; bash "$ST" "$d" --sync-state >/dev/null 2>&1
  awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^blocked_open:/{print $2; exit}' "$d/RESEARCH-STATE.md"; }

echo "-- 1. lib count + consumer parity on every fixture --"
for f in "${fixtures[@]}"; do
  c="$(case_of "$f")"; want="$(expect_of "$f")"
  got_lib="$(blocked_open_count "$f")"
  [ "$got_lib" = "$want" ] && ok "lib $c = $want" || no "lib $c: got [$got_lib] want $want"
  d="$TMP/par-$c"; mkdir -p "$d"; cp "$f" "$d/RESEARCH-STATE.md"
  got_vs="$(derived_vs "$d")"; got_st="$(status_blk "$d")"; got_sy="$(synced_blk "$d")"
  [ "$got_vs" = "$want" ] && ok "verify-state $c = $want" || no "verify-state $c: got [$got_vs] want $want"
  [ "$got_st" = "$want" ] && ok "status display $c = $want" || no "status display $c: got [$got_st] want $want"
  [ "$got_sy" = "$want" ] && ok "status --sync-state $c writes blocked_open: $want" || no "status --sync-state $c: wrote [$got_sy] want $want"
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
{
  s=verify-state
  d="$TMP/deg-$s"; mkdir -p "$d"; cp "$FIX/child-single-open.expect1.md" "$d/RESEARCH-STATE.md"
  out="$(PATH="$TMP/stub-child:$PATH" bash "$TOOLBELT/$s.sh" "$d" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && grep -q 'blocked_open derivation degraded' <<<"$out"; then ok "$s with a broken awk: non-zero exit + typed degraded FAIL line"
  else no "$s with a broken awk: rc=$rc :: $(grep -m1 -i 'blocked' <<<"$out")"; fi
}

# research-sdd-status.sh (#2017): both call sites of derive_blocked_open must keep the degraded state loud.
{
  d="$TMP/deg-status"; mkdir -p "$d"; cp "$FIX/child-single-open.expect1.md" "$d/RESEARCH-STATE.md"
  out="$(PATH="$TMP/stub-child:$PATH" bash "$ST" "$d" 2>"$TMP/err")"; rc=$?
  if grep -q 'stop-control .*blocked=DEGRADED' <<<"$out" && grep -q 'blocked_open derivation degraded' "$TMP/err" && [ "$rc" = 0 ]; then
    ok "status display with a broken awk: blocked=DEGRADED + typed stderr line (exit 0 by the script contract)"
  else no "status display with a broken awk: rc=$rc :: $(grep -m1 'stop-control' <<<"$out") :: $(head -1 "$TMP/err")"; fi
  if grep -qE 'blocked=(0|\?|[0-9]+)( |$)' <<<"$out"; then no "status display with a broken awk printed a bare count: $(grep -m1 'stop-control' <<<"$out")"; else ok "status display with a broken awk prints no bare count (not 0, not ?)"; fi
  cp "$d/RESEARCH-STATE.md" "$TMP/before-sync.md"
  PATH="$TMP/stub-child:$PATH" bash "$ST" "$d" --sync-state >"$TMP/sync-out" 2>"$TMP/err"; rc=$?
  if [ "$rc" = 1 ] && grep -q 'research-sdd-status: blocked_open derivation degraded' "$TMP/err" && cmp -s "$TMP/before-sync.md" "$d/RESEARCH-STATE.md"; then
    ok "status --sync-state with a broken awk: exit 1, typed line, envelope NOT written"
  else no "status --sync-state with a broken awk: rc=$rc cmp=$(cmp -s "$TMP/before-sync.md" "$d/RESEARCH-STATE.md" && echo same || echo CHANGED) :: $(head -1 "$TMP/err")"; fi
}

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

echo "-- 4. a missing or function-less lib fails each consumer loudly --"
mk_kit() { # DIR [lib-state: ok|missing|empty]
  local k="$1" st="${2:-ok}"; rm -rf "$k"; mkdir -p "$k"
  cp -r "$TOOLBELT/lib" "$k/lib"; cp "$TOOLBELT"/*.sh "$k/"
  case "$st" in missing) rm -f "$k/lib/blocked-rows.sh" ;; empty) : > "$k/lib/blocked-rows.sh" ;; esac
}
cp "$FIX/child-single-open.expect1.md" "$TMP/RESEARCH-STATE.md"; mkdir -p "$TMP/corpus"; cp "$FIX/child-single-open.expect1.md" "$TMP/corpus/RESEARCH-STATE.md"
for state in missing empty; do
  mk_kit "$TMP/kit-$state" "$state"
  for s in verify-state research-sdd-status; do
    out="$(bash "$TMP/kit-$state/$s.sh" "$TMP/corpus" 2>&1)"; rc=$?
    if [ "$rc" = 1 ] && grep -q 'blocked-rows' <<<"$out"; then ok "$s with $state lib: exit 1 + typed message naming blocked-rows"
    else no "$s with $state lib: rc=$rc :: $(head -1 <<<"$out")"; fi
  done
done

echo ""
echo "== $pass passed · $fail failed =="

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== mutation controls =="
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null 2>&1 && declare -F mutant_tooth >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
  t_pass=0; t_fail=0
  mk() { mutant_chain "$@" || { t_fail=$((t_fail+1)); return 1; }; }
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

  # TOOTH-11/12 (#2017): each research-sdd-status.sh call site keeps the derivation rc.
  for site in SYNC DISPLAY; do
    mkdir -p "$MD/g11-$site/mut/lib"; cp "$TOOLBELT"/lib/*.sh "$MD/g11-$site/mut/lib/"; cp "$TOOLBELT"/*.sh "$MD/g11-$site/mut/"
  done
  mk "TOOTH-11 mutant build" "$ST" "$MD/g11-SYNC/mut/research-sdd-status.sh" '/# BO-DEGRADED-SYNC/{n;d}' \
    && tt "TOOTH-11: --sync-state refuses to write on a degraded blocked_open; without the rc check it writes the envelope" 1 0 "$MD/g11-SYNC/mut/research-sdd-status.sh" \
         --orig "$ST" --good-has 'derivation degraded' --bad-lacks 'derivation degraded' \
         -- bash -c 'd="$3/s"; rm -rf "$d"; mkdir -p "$d"; cp "$4" "$d/RESEARCH-STATE.md"; PATH="$2:$PATH" bash "$1" "$d" --sync-state 2>&1' _ @SUT@ "$TMP/stub-child" "$TMP" "$FIX/child-single-open.expect1.md"
  mk "TOOTH-12 mutant build" "$ST" "$MD/g11-DISPLAY/mut/research-sdd-status.sh" 's#^  blk="DEGRADED"$#  blk=""#' \
    && tt "TOOTH-12: the display prints blocked=DEGRADED; without it the count is blank" 0 0 "$MD/g11-DISPLAY/mut/research-sdd-status.sh" \
         --orig "$ST" --good-has 'blocked=DEGRADED' --bad-lacks 'blocked=DEGRADED' \
         -- bash -c 'PATH="$2:$PATH"; bash "$1" "$3" 2>/dev/null' _ @SUT@ "$TMP/stub-child" "$TMP/deg-status"

  # TOOTH-8: the degraded guard -- without it a failing awk collapses into a confident 0 with rc 0.
  mk "TOOTH-8 mutant build" "$LIB" "$MD/t8.sh" '/^  \[ "\$_rc" -eq 0 \] || { echo "blocked-rows: degraded child-gap counter/d; /^  case "\$_d2" in/d' \
    && tt "TOOTH-8: a failing child-gap awk reads as a bare number when the degraded guard is dropped" 3 0 "$MD/t8.sh" --orig "$LIB" \
         --good-lacks '^[0-9]' --bad-has '^[0-9]+$' -- bash -c 'PATH="$2:$PATH"; . "$1"; blocked_open_count "$3"' _ @SUT@ "$TMP/stub-child" "$FIX/child-single-open.expect1.md"

  # TOOTH-9: verify-state names a degraded derivation instead of comparing the declared count to an empty string.
  mkdir -p "$MD/g9/mut/lib"; cp "$TOOLBELT"/lib/*.sh "$MD/g9/mut/lib/"; cp "$TOOLBELT"/*.sh "$MD/g9/mut/"
  mk "TOOTH-9 mutant build" "$TOOLBELT/verify-state.sh" "$MD/g9/mut/verify-state.sh" 's# || d_blocked="DEGRADED"##' \
    && tt "TOOTH-9: a degraded blocked_open derivation is named by verify-state; without the capture it is an unnamed mismatch" 1 1 "$MD/g9/mut/verify-state.sh" \
         --orig "$TOOLBELT/verify-state.sh" --good-has 'derivation degraded' --bad-lacks 'derivation degraded' \
         -- bash -c 'PATH="$2:$PATH"; bash "$1" "$3"' _ @SUT@ "$TMP/stub-child" "$TMP/deg-verify-state"

  # TOOTH-5: the `## Blocked /` family is part of the body (METHODOLOGY §21.1).
  mk "TOOTH-5 mutant build" "$LIB" "$MD/t5.sh" "s|'## Non-investigable gaps' '## Blocked /'|'## Non-investigable gaps'|" \
    && tt "TOOTH-5: without the '## Blocked /' section the mixed fixture loses an entry" 0 0 "$MD/t5.sh" --orig "$LIB" \
         --good-has '^5$' --bad-has '^4$' --bad-lacks "$AWKBAD" -- "${COUNT_ARGV[@]}" "$FIX/standard-and-child-mixed.expect5.md"

  # TOOTH-6: the absent-input guard — without it a missing file is a silent zero.
  mk "TOOTH-6 mutant build" "$LIB" "$MD/t6.sh" '/if \[ ! -r "\$_f" \] || \[ -d "\$_f" \]; then/,/^  fi$/d' \
    && tt "TOOTH-6: dropping the absent-input guard turns rc 2 into the degraded rc 3 (never a bare 0; the stage guard is the backstop)" 2 3 "$MD/t6.sh" --orig "$LIB" \
         --good-lacks '^0$' --bad-lacks '^0$' -- "${COUNT_ARGV[@]}" "$TMP/does-not-exist.md"

  # TOOTH-7: the consumer's fail-closed guard turns a function-less lib into a loud exit 1 at source time.
  # Mutant exit codes differ by consumer: verify-state runs on and FAILs the envelope (rc 1, but WITHOUT the typed
  # message); status runs on and exits 0. The message is what the guard adds, so every tooth also checks it.
  for s in verify-state research-sdd-status; do
    case "$s" in verify-state) _bad_rc=1 ;; *) _bad_rc=0 ;; esac
    mkdir -p "$MD/g-$s/orig/lib" "$MD/g-$s/mut/lib"
    cp "$TOOLBELT"/lib/*.sh "$MD/g-$s/orig/lib/"; : > "$MD/g-$s/orig/lib/blocked-rows.sh"
    cp "$MD/g-$s/orig/lib/"*.sh "$MD/g-$s/mut/lib/"
    cp "$TOOLBELT"/*.sh "$MD/g-$s/orig/"
    cp "$TOOLBELT"/*.sh "$MD/g-$s/mut/"
    mk "TOOTH-7 ($s) mutant build" "$TOOLBELT/$s.sh" "$MD/g-$s/mut/$s.sh" '/declare -F blocked_.*failed to define blocked_/d' \
      && tt "TOOTH-7 ($s): guard exits 1 on a function-less lib; without it the script runs on" 1 "$_bad_rc" "$MD/g-$s/mut/$s.sh" \
           --orig "$MD/g-$s/orig/$s.sh" --good-has 'failed to define blocked_open_count' --bad-lacks 'failed to define blocked_' \
           -- bash @SUT@ "$TMP/corpus"
  done

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
