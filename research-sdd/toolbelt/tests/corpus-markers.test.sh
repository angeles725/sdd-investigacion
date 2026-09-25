#!/usr/bin/env bash
# corpus-markers.test.sh — regression harness for lib/corpus-markers.sh (kit issue #1108):
# the single source of truth for "does this directory carry a recognised corpus marker?",
# shared by research-sdd-init.sh's --wire anti-implicit-scaffold guard and verify-registry.sh's
# registered-path marker check.
#
# Usage: corpus-markers.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/corpus-markers.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== corpus-markers.test.sh =="

# shellcheck source=../lib/corpus-markers.sh
. "$LIB"
declare -F corpus_has_marker >/dev/null 2>&1 || { echo "FATAL: $LIB did not define corpus_has_marker" >&2; exit 2; }
declare -F corpus_marker_present >/dev/null 2>&1 || { echo "FATAL: $LIB did not define corpus_marker_present" >&2; exit 2; }

# 1 — RESEARCH-STATE.md at root → marker present.
d="$ROOT/t1"; mkdir -p "$d"; : > "$d/RESEARCH-STATE.md"
if corpus_has_marker "$d"; then ok "1 RESEARCH-STATE.md at root → marker present"; else no "1 RESEARCH-STATE.md at root → marker present"; fi

# 2 — INDEX.md at root → marker present.
d="$ROOT/t2"; mkdir -p "$d"; : > "$d/INDEX.md"
if corpus_has_marker "$d"; then ok "2 INDEX.md at root → marker present"; else no "2 INDEX.md at root → marker present"; fi

# 3 — CATALOG.md at root → marker present.
d="$ROOT/t3"; mkdir -p "$d"; : > "$d/CATALOG.md"
if corpus_has_marker "$d"; then ok "3 CATALOG.md at root → marker present"; else no "3 CATALOG.md at root → marker present"; fi

# 4 — §16 multi-focus RESEARCH-STATE-<focus>.md → marker present.
d="$ROOT/t4"; mkdir -p "$d"; : > "$d/RESEARCH-STATE-alpha.md"
if corpus_has_marker "$d"; then ok "4 RESEARCH-STATE-<focus>.md → marker present"; else no "4 RESEARCH-STATE-<focus>.md → marker present"; fi

# 5 — ONLY a *.template.md → no marker (a stray copied template never counts).
d="$ROOT/t5"; mkdir -p "$d"; : > "$d/RESEARCH-STATE.template.md"
if corpus_has_marker "$d"; then no "5 only *.template.md → no marker (stray template must not count)"; else ok "5 only *.template.md → no marker (stray template must not count)"; fi

# 6 — empty directory → no marker.
d="$ROOT/t6"; mkdir -p "$d"
if corpus_has_marker "$d"; then no "6 empty dir → no marker"; else ok "6 empty dir → no marker"; fi

# 7 — non-existent directory → no marker (never a crash/false-true).
d="$ROOT/t7-absent"
if corpus_has_marker "$d"; then no "7 absent dir → no marker"; else ok "7 absent dir → no marker"; fi

# 8 — marker present only at DEPTH (e.g. <dir>/research/RESEARCH-STATE.md) → root check is
#     false; corpus_has_marker must NOT descend (that is the whole point — deliberately
#     narrower than the maxdepth-3 resolver elsewhere in the toolbelt).
d="$ROOT/t8"; mkdir -p "$d/research"; : > "$d/research/RESEARCH-STATE.md"
if corpus_has_marker "$d"; then no "8 marker only nested (research/) → root check false (no descent)"; else ok "8 marker only nested (research/) → root check false (no descent)"; fi

# 9 — corpus_marker_present: marker at the SECOND candidate root (e.g. <dir>/corpus) → true.
d="$ROOT/t9"; mkdir -p "$d/corpus"; : > "$d/corpus/RESEARCH-STATE.md"
if corpus_marker_present "$d" "$d/corpus"; then ok "9 corpus_marker_present: marker at 2nd candidate → true"; else no "9 corpus_marker_present: marker at 2nd candidate → true"; fi

# 10 — corpus_marker_present: marker at NEITHER candidate → false.
d="$ROOT/t10"; mkdir -p "$d" "$d/corpus"
if corpus_marker_present "$d" "$d/corpus"; then no "10 corpus_marker_present: no marker at either → false"; else ok "10 corpus_marker_present: no marker at either → false"; fi

echo ""
echo "Summary: ${pass} passed / $((pass+fail)) total."

# --- mutation teeth ("--prove-teeth") --------------------------------------------------------------
# Each mutant is a COPY of the real lib file with ONE line changed, sourced fresh in a subshell,
# and exercised through the REAL case 1 / case 6 fixtures via the REAL function name — never a
# hand-redefined stand-in called directly (RDD finding, kit issue #1108 round 2: the prior teeth
# here redefined corpus_has_marker() as a constant and called it, which is circular — it could
# not have caught a real regression in the sourced lib; it only proved this test file's own
# inline logic runs). The outer script already sourced the REAL lib above, so
# `unset -f corpus_has_marker corpus_marker_present` is required before re-sourcing the mutant —
# otherwise the mutant's own idempotency guard (`if ! declare -F ...`) sees the names already
# defined (subshells inherit the parent's functions) and silently skips its redefinition.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force the RESEARCH-STATE branch's return 0 to return 1 — case 1 must go RED --"
  mut_false="$ROOT/corpus-markers.MUTANT-always-false.sh"
  if ! grep -qE '^      return 0$' "$LIB"; then
    no "teeth: locate the RESEARCH-STATE branch's 'return 0' anchor in lib — drifted?"
  else
    sed '0,/^      return 0$/{s/^      return 0$/      return 1  # MUTANT: RESEARCH-STATE branch never matches/}' "$LIB" > "$mut_false"
    (
      unset -f corpus_has_marker corpus_marker_present
      # shellcheck disable=SC1090
      . "$mut_false"
      d="$ROOT/t1"
      if corpus_has_marker "$d"; then
        echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else
        echo "  PASS  teeth: mutant correctly makes case 1 fail (marker never detected)"; exit 0
      fi
    )
    if [ $? -eq 0 ]; then ok "teeth: RESEARCH-STATE-branch mutation caught (real sourced lib)"; else no "teeth: RESEARCH-STATE-branch mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: force corpus_has_marker's final 'no marker' return 1 to return 0 — case 6 must go RED --"
  mut_true="$ROOT/corpus-markers.MUTANT-always-true.sh"
  if ! grep -qE '^  corpus_has_marker\(\) \{$' "$LIB"; then
    no "teeth: locate corpus_has_marker() function header in lib — drifted?"
  else
    sed '/^  corpus_has_marker() {/,/^  }/{s/^    return 1$/    return 0  # MUTANT: always marker-present/}' "$LIB" > "$mut_true"
    if ! grep -qF 'MUTANT: always marker-present' "$mut_true"; then
      no "teeth: could not build always-true mutant (final return 1 anchor not found — did the lib change?)"
    else
      (
        unset -f corpus_has_marker corpus_marker_present
        # shellcheck disable=SC1090
        . "$mut_true"
        d="$ROOT/t6"
        if corpus_has_marker "$d"; then
          echo "  PASS  teeth: mutant correctly makes case 6 fail (empty dir wrongly reports a marker)"; exit 0
        else
          echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
        fi
      )
      if [ $? -eq 0 ]; then ok "teeth: always-marker-present mutation caught (real sourced lib)"; else no "teeth: always-marker-present mutation NOT caught (theater)"; fi
    fi
  fi
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
