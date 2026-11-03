#!/usr/bin/env bash
# verify-block-backpointer.test.sh — the SHIM contract of the section-14 back-pointer check of verify-block.sh.
#
# Contract (kit issue #1962): a block that CORRECTS an earlier block (refut* / corrig* / correg* / correcci* / supersed* /
# corrects|corrected|correcting|correction) in a sentence that cites it (`[Block N]`, `Block N`, `Bloque N`, `BN`, and
# `RN` in an R-numbered corpus) gets a candidate `BACKPTR?` when the cited block holds no pointer back; ADVISORY, the exit
# code never changes; --backptr=high (default) | all | off. The sentence scan, the filters (neg, self, passive, noun,
# corrector, far, list, forward), the two block-number series and the typed non-verdicts are pinned in Go: the frozen
# bash script is run on every fixture of the old suite (internal/verify, testdata/block-cases.txt) and on hand-written
# ones, and must print the same bytes. What stays here: the flag and the exit code cross the shim unchanged, and the
# canonical-name rule reaches the command.
#
# Usage: verify-block-backpointer.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
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
echo "== verify-block-backpointer.test.sh =="
stage(){ mkdir -p "$1"; rsdd_stage_libs "$1"; cp "${2:-$SUT}" "$1/verify-block.sh"; }
stage "$TMP/tb"
c="$TMP/c"; mkdir -p "$c"
printf '# Block 1 — old\n\nNothing points forward.\n' > "$c/x-block1.md"
printf '# Block 2 — new\n\nThis corrects [Block 1] and the sentence names it.\n' > "$c/x-block2.md"
run(){ bash "$TMP/tb/verify-block.sh" "$@" 2>&1; }

o="$(run "$c/x-block2.md")"; rc=$?
if [ "$rc" = 0 ] && grep -qE '^   BACKPTR\?  line 3: possible correction of block 1 \(x-block1.md\)' <<<"$o" && grep -q 'to B2 in x-block1.md' <<<"$o"; then ok "BP-1 a correction of an uncovered earlier block → BACKPTR? candidate, exit unchanged (0)"
else no "BP-1 rc=$rc :: $(grep -i backptr <<<"$o")"; fi

printf '# Block 1 — old\n\nCorrected in B2.\n' > "$c/x-block1.md"
o="$(run "$c/x-block2.md")"
if grep -qE '^   backptr-ok  line 3: block 1 \(x-block1.md\) points back to B2$' <<<"$o"; then ok "BP-2 a pointer in the old block → backptr-ok"
else no "BP-2 :: $(grep -i backptr <<<"$o")"; fi

o="$(run --backptr=off "$c/x-block2.md")"; rc=$?
if [ "$rc" = 0 ] && grep -q 'back-pointer check off — --backptr=off' <<<"$o" && ! grep -q 'backptr-ok' <<<"$o"; then ok "BP-3 --backptr=off crosses the shim and skips the section"
else no "BP-3 rc=$rc"; fi

printf '# Block 3\n\nSee [Block 1] for context.\n\nThis refutes the earlier view somewhere in the old paragraph of Block 1 after a long distance %s.\n' "$(printf 'x%.0s' $(seq 1 90))" > "$c/x-block3.md"
o="$(run --backptr=all "$c/x-block3.md")"
if grep -q '^-- back-pointer: ' <<<"$o" || grep -q '^   (none — no correction sentence' <<<"$o"; then ok "BP-4 --backptr=all is accepted and ends in a summary line"
else no "BP-4 :: $(grep -i back-pointer <<<"$o")"; fi

printf '# t\n\nThis corrects Block 1.\n' > "$c/notes.md"
o="$(run "$c/notes.md")"
if grep -q "back-pointer check skipped — 'notes.md' is not a canonical block file name" <<<"$o"; then ok "BP-5 a non-canonical file name skips the check, with the reason"
else no "BP-5 :: $(grep -i back-pointer <<<"$o")"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"
  printf '# Block 1 — old\n\nNothing points forward.\n' > "$c/x-block1.md"
  if mk_mut "teeth A: arguments dropped" "$SUT" "$TMP/vmutA.sh" 's/rsdd_exec verify block "\$@"/rsdd_exec verify block/'; then
    stage "$TMP/vmA" "$TMP/vmutA.sh"
    mo="$(bash "$TMP/vmA/verify-block.sh" "$c/x-block2.md" 2>&1)"
    if ! grep -q 'BACKPTR?' <<<"$mo"; then ok "teeth A: arguments dropped → no candidate, BP-1 would go RED"; else no "teeth A: mutant still reports"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
