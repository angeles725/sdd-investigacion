#!/usr/bin/env bash
# verify-block.sh — mechanical self-verify aid for a Research-SDD block (METHODOLOGY §11).
#
# The SUB-AGENT runs this INSIDE its own iteration and pastes the output into its §11 self-report.
# It does the MECHANICAL parts of the gate — marker tally, [INFER]/[CERT] ratio, and [CERT] `file:line`
# citation-resolution — so the counts are EXACT (computed, not remembered). This is NOT an orchestrator
# post-hoc Bash gate (§11 rejects those — they cost permission prompts and caught nothing on protocols);
# it is the agent's own calculator, run by the agent, reported by the agent.
#
# It does not judge block TYPE or escalate markers — those need reading. It hardens the COUNTING, which is
# where a from-memory self-report drifts. The token-check (does each [CERT] token appear in its source) still
# needs the agent; this resolves the CITATION (does the cited file:line exist) mechanically.
#
# Usage: verify-block.sh <block.md> [target-dir]
#   target-dir defaults to the block's own directory (file:line citations are target-relative).
# Exit: 0 = no verifiable contradiction · 1 = a cited file EXISTS but the line is out of range · 2 = bad args.

set -uo pipefail
block="${1:-}"
[ -f "$block" ] || { echo "usage: verify-block.sh <block.md> [target-dir]" >&2; exit 2; }
target="${2:-$(dirname "$block")}"

echo "== verify-block: $(basename "$block") (target: $target) =="

# 1. Marker tally — exact. `grep -oE '\[CERT\]'` does NOT match the hyphenated variants, so each counts once.
declare -A tally
for m in CERT-hw CERT-live CERT CERT-doc CERT-web CERT-a INFER; do
  tally[$m]=$(grep -oE "\[$m\]" "$block" | wc -l | tr -d ' ')
done
echo "-- marker tally --"
for m in CERT-hw CERT-live CERT CERT-doc CERT-web CERT-a INFER; do
  printf "   [%s] %s\n" "$m" "${tally[$m]}"
done

# 2. [INFER]/[CERT] ratio — INFER over ALL cert-family markers.
cert_total=$(( tally[CERT-hw] + tally[CERT-live] + tally[CERT] + tally[CERT-doc] + tally[CERT-web] + tally[CERT-a] ))
infer=${tally[INFER]}
if [ "$cert_total" -gt 0 ]; then
  ratio=$(awk "BEGIN{printf \"%.2f\", $infer/$cert_total}")
else
  ratio="n/a (no CERT markers)"
fi
echo "-- ratio -- [INFER]/[CERT*] = $infer/$cert_total = $ratio"
echo "   (>~0.5 in an EVIDENCE block signals investigable evidence nearly exhausted; EXPECTED and healthy in a"
echo "    DESIGN/synthesis block — DECLARE the block TYPE so the ratio is read right, §11)"

# 3. Citation resolution — `file:line` tokens (target-relative). Captures backticked paths with an extension.
echo "-- [CERT] file:line citation resolution --"
rc=0
cites=$(grep -oE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+`' "$block" | tr -d '`' | sort -u)
if [ -z "$cites" ]; then
  echo "   (no file:line citations found)"
else
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    f="${c%:*}"; ln="${c##*:}"
    if [ -f "$target/$f" ]; then
      total=$(wc -l < "$target/$f")
      if [ "$ln" -le "$total" ]; then
        echo "   ok      $c"
      else
        echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1
      fi
    else
      echo "   extern  $c  (not in target: beautified-temp / decompiled / snapshot — not script-verifiable)"
    fi
  done <<< "$cites"
fi

echo "== exit $rc =="
exit $rc
