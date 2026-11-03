#!/usr/bin/env bash
# verify-block-possibility.test.sh — the SHIM contract of the POSSIBILITY-FIRST lint of verify-block.sh
# (METHODOLOGY section 1 trait · kit issues #1263-#1266, port #2456).
#
# Contract: a defeatist feasibility verdict ("not possible", "cannot be determined", "no way to", "out of reach",
# "no se puede" ...) must sit in a section that carries a ROUTE LADDER (>= 3 `route` items and a `cheapest` step), or the
# report prints a `WARN    possibility-first` line (advisory: exit code unchanged). `--possibility-sweep <dir>` lists
# every bare verdict of a corpus, read-only, exit 0. The verdict phrases, the ladder rule, the measurement-language and
# fence exemptions and the byte-wise 120-character excerpt are pinned in Go against the frozen bash script
# (internal/verify, testdata/block-cases.txt); here only what crosses the shim.
#
# Usage: verify-block-possibility.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== verify-block-possibility.test.sh =="
stage(){ mkdir -p "$1"; rsdd_stage_libs "$1"; cp "${2:-$SUT}" "$1/verify-block.sh"; }
stage "$TMP/tb"
mk(){ local f="$1"; shift; { echo "# Block 1 — t"; echo; echo "> Type: evidence. Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }

mk "$TMP/bare.md" "## 1.1 Feasibility" "It is not possible to recover the key from the firmware."
o="$(bash "$TMP/tb/verify-block.sh" "$TMP/bare.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE "^   WARN    possibility-first line 8: bare verdict 'not possible' " <<<"$o"; then ok "PF-1 a bare verdict → WARN possibility-first, exit unchanged (0)"
else no "PF-1 rc=$rc :: $(grep -i possib <<<"$o")"; fi

mk "$TMP/ladder.md" "## 1.1 Feasibility" "Cannot be determined from static code alone." "" \
  "- Route 1: grep the sibling module." "- Route 2: read the live slot." "- Route 3: split the goal." "Cheapest viable next step: Route 1."
o="$(bash "$TMP/tb/verify-block.sh" "$TMP/ladder.md" 2>&1)"
if grep -q '^   (none — no bare feasibility verdict)$' <<<"$o"; then ok "PF-2 a 3-route ladder with a cheapest step → no WARN"
else no "PF-2 :: $(grep -i possib <<<"$o")"; fi

mkdir -p "$TMP/corpus/sub"; cp "$TMP/bare.md" "$TMP/corpus/a.md"; cp "$TMP/ladder.md" "$TMP/corpus/sub/b.md"; printf 'no way to know\n' > "$TMP/corpus/sub/c.txt"
sum_corpus(){ (cd "$TMP/corpus" && find . -type f -exec cksum {} + | LC_ALL=C sort); }
before="$(sum_corpus)"
o="$(bash "$TMP/tb/verify-block.sh" --possibility-sweep "$TMP/corpus" 2>"$TMP/e3")"; rc=$?
after="$(sum_corpus)"
if [ "$rc" = 0 ] && [ -n "$before" ] && [ "$before" = "$after" ] && [ ! -s "$TMP/e3" ] && grep -q "^$TMP/corpus/a.md:8: not possible — It is not possible to recover the key from the firmware.$" <<<"$o" \
   && grep -q '^== possibility-sweep: bare verdicts: 1 ==$' <<<"$o" && grep -q '^   Reopen each as a child gap ' <<<"$o"; then ok "PF-3 --possibility-sweep lists the bare verdicts of the corpus, read-only, exit 0"
else no "PF-3 rc=$rc :: $o"; fi

o="$(bash "$TMP/tb/verify-block.sh" --possibility-sweep "$TMP/corpus/sub" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '^== possibility-sweep: bare verdicts: 0 ==$' <<<"$o" && ! grep -q 'Reopen each' <<<"$o"; then ok "PF-4 a clean corpus → count 0 and no hint line"
else no "PF-4 rc=$rc :: $o"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"
  if mk_mut "teeth A: arguments dropped" "$SUT" "$TMP/vmutA.sh" 's/rsdd_exec verify block "\$@"/rsdd_exec verify block/'; then
    stage "$TMP/vmA" "$TMP/vmutA.sh"
    mo="$(bash "$TMP/vmA/verify-block.sh" --possibility-sweep "$TMP/corpus" 2>&1)"; mrc=$?
    if [ "$mrc" = 2 ] && grep -q "^usage: verify-block.sh " <<<"$mo" && ! grep -q 'possibility-sweep: bare verdicts' <<<"$mo"; then ok "teeth A: arguments dropped → no sweep, PF-3 would go RED"; else no "teeth A: mutant still sweeps"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
