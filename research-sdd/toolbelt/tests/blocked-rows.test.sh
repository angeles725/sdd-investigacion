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
  COUNT_ARGV=(bash -c '. "$1"; blocked_open_count "$2"' _ @SUT@)

  # TOOTH-1 (#913): the bullet-line closed check is what stops a closed entry's own `needs:` counting.
  mk "TOOTH-1 mutant build" "$LIB" "$MD/t1.sh" 's/if (!cl \&\& tolower(\$0) ~ \/needs:\/)/if (tolower($0) ~ \/needs:\/)/' \
    && tt "TOOTH-1: closed entry with needs: on its bullet line counted when the closed check is dropped" 0 0 "$MD/t1.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^1$' -- "${COUNT_ARGV[@]}" "$FIX/child-closed-bullet-keeps-needs.expect0.md"

  # TOOTH-2 (#913): the continuation-line closed check.
  mk "TOOTH-2 mutant build" "$LIB" "$MD/t2.sh" 's/if (ib \&\& !done \&\& !cl \&\&/if (ib \&\& !done \&\&/' \
    && tt "TOOTH-2: closed entry with needs: on a continuation line counted when the closed check is dropped" 0 0 "$MD/t2.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^1$' -- "${COUNT_ARGV[@]}" "$FIX/child-closed-single-keeps-needs.expect0.md"

  # TOOTH-3: the closed flag is per ENTRY — each bullet re-derives it. A sticky flag lets a closed entry swallow
  # the open entry after it.
  mk "TOOTH-3 mutant build" "$LIB" "$MD/t3.sh" 's/cl=is_closed(\$0)/cl=(cl||is_closed($0))/' \
    && tt "TOOTH-3: a sticky closed flag hides the open entry that follows a closed one" 0 0 "$MD/t3.sh" --orig "$LIB" \
         --good-has '^1$' --bad-has '^0$' -- "${COUNT_ARGV[@]}" "$FIX/child-closed-first-then-open.expect1.md"

  # TOOTH-4a..4e: each closed-marker branch is load-bearing -- delete ONE branch and a fixture relying on it counts.
  # Marker lines in the lib carry a CLOSED-* sentinel; the bracket branch is the function's final return.
  tb4() { # LABEL SENTINEL|BRACKET FIXTURE
    if [ "$2" = BRACKET ]; then
      mk "$1 mutant build" "$LIB" "$MD/$1.sh" 's/return (tolower(s) ~ .*CLOSED-BRACKET$/return 0/'
    else
      mk "$1 mutant build" "$LIB" "$MD/$1.sh" "/# $2\$/d"
    fi && tt "$1: dropping the $2 branch makes a closed entry count" 0 0 "$MD/$1.sh" --orig "$LIB" \
         --good-has '^0$' --bad-has '^[1-9]' -- "${COUNT_ARGV[@]}" "$3"
  }
  tb4 TOOTH-4a CLOSED-STRIKE  "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4b CLOSED-TICK    "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4c CLOSED-CERRADO "$FIX/child-closed-single-keeps-needs.expect0.md"
  tb4 TOOTH-4d CLOSED-WORD    "$FIX/child-closed-markers-all.expect0.md"
  tb4 TOOTH-4e BRACKET        "$FIX/child-closed-markers-all.expect0.md"
  # TOOTH-4f: the whole-word/negation guard -- without it NOT CLOSED falsely closes an open entry.
  mk "TOOTH-4f mutant build" "$LIB" "$MD/t4f.sh" 's/if (bef !~ .* return 1$/return 1/' \
    && tt "TOOTH-4f: without the boundary/negation guard a false closure hides an open entry" 0 0 "$MD/t4f.sh" --orig "$LIB" \
         --good-has '^1$' --bad-has '^0$' -- "${COUNT_ARGV[@]}" "$FIX/child-open-not-closed.expect1.md"

  # TOOTH-5: the `## Blocked /` family is part of the body (METHODOLOGY §21.1).
  mk "TOOTH-5 mutant build" "$LIB" "$MD/t5.sh" "/blocked_rows_section \"\\\$1\" '## Blocked \\/'/d" \
    && tt "TOOTH-5: without the '## Blocked /' section the mixed fixture loses an entry" 0 0 "$MD/t5.sh" --orig "$LIB" \
         --good-has '^5$' --bad-has '^4$' -- "${COUNT_ARGV[@]}" "$FIX/standard-and-child-mixed.expect5.md"

  # TOOTH-6: the absent-input guard — without it a missing file is a silent zero.
  mk "TOOTH-6 mutant build" "$LIB" "$MD/t6.sh" '/if \[ ! -r "\$_f" \] || \[ -d "\$_f" \]; then/,/^  fi$/d' \
    && tt "TOOTH-6: absent state file reads as a confident 0 when the guard is dropped" 2 0 "$MD/t6.sh" --orig "$LIB" \
         --good-lacks '^0$' --bad-has '^0$' -- "${COUNT_ARGV[@]}" "$TMP/does-not-exist.md"

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
