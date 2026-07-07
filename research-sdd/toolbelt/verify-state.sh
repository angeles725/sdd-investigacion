#!/usr/bin/env bash
# verify-state.sh — living-mirror consistency lint for a Research-SDD RESEARCH-STATE.md (retro delta #6).
#
# Catches the stale-summary desync that lets the loop emit a PREMATURE STOP: a summary that claims
# "N / N gaps closed" while the backlog still lists `pending` gaps. That exact desync (summary said
# 23/23 closed while 16 gaps were pending) is what let the pruebas-dashboards run-A STOP early; three.js
# hit the same class of drift ("21 md / 3 runs" while the corpus grew to 32 blocks). The PROMPT-LOOP
# living-mirror rule already MANDATES refreshing the row on run close — this mechanizes the check so the
# rule is enforced, not just remembered.
#
# Usage: verify-state.sh <target-dir>
# Exit: 0 = consistent · 1 = inconsistency (stale mirror) · 2 = bad args / no state file.
set -uo pipefail

target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-state.sh <target-dir>" >&2; exit 2; }
# Lint EVERY RESEARCH-STATE*.md under the target (a reopened / multi-focus corpus keeps one per
# focus). Exit 2 only when NONE exists; otherwise aggregate: rc=1 if ANY state file fails CHECK 1.
mapfile -t states < <(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -path '*/.git/*' 2>/dev/null)
[ "${#states[@]}" -gt 0 ] || { echo "verify-state: no RESEARCH-STATE*.md under $target" >&2; exit 2; }

rc=0
for state in "${states[@]}"; do
  echo "== verify-state: $(basename "$state") (target: $target) =="
  frc=0

  # 1. backlog `pending` gap rows (grep -c already prints 0 on no match; keep it a single integer).
  pending="$(grep -icE '\bpending\b' "$state" 2>/dev/null || true)"

  # 2. coverage metric "X / Y ... closed"
  metric="$(grep -iE 'coverage metric|declared gaps closed|gaps? closed' "$state" 2>/dev/null | head -1)"
  xy="$(printf '%s' "$metric" | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
  cx="${xy%%/*}"; cy="${xy##*/}"

  # 3. covered-blocks claim vs on-disk block files (best-effort glob, corpus-relative). Match both
  #    English `*block*.md` and Spanish `*bloque*.md`, case-insensitively; find lists each file once.
  covered_claim="$(grep -iE 'covered blocks' "$state" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  ondisk="$(find "$(dirname "$state")" -maxdepth 1 \( -iname '*block*.md' -o -iname '*bloque*.md' \) 2>/dev/null | wc -l | tr -d ' ')"

  echo "-- summary --"
  echo "   coverage metric : ${xy:-<none>}"
  echo "   covered blocks  : ${covered_claim:-<none>} claimed · ${ondisk} block file(s) on disk"
  echo "   backlog pending : ${pending}"

  # CHECK 1 (FAIL) — summary claims every gap closed, but the backlog still lists pending gaps.
  if [ -n "${cx:-}" ] && [ -n "${cy:-}" ] && [ "$cx" = "$cy" ] && [ "${pending:-0}" -gt 0 ]; then
    echo "   FAIL   summary claims ALL $cy gaps closed, but the backlog lists $pending 'pending' gap(s)."
    echo "          Stale mirror — this desync is what lets the loop emit a PREMATURE STOP. Refresh the"
    echo "          coverage metric (or reopen it) so it matches the backlog before honoring any STOP."
    frc=1; rc=1
  fi

  # CHECK 2 (WARN) — covered-blocks claim drifted from the on-disk block count.
  if [ -n "${covered_claim:-}" ] && [ "${ondisk:-0}" -gt 0 ] && [ "$covered_claim" != "$ondisk" ]; then
    echo "   WARN   'Covered blocks: $covered_claim' disagrees with $ondisk block file(s) on disk — refresh the mirror."
  fi

  # CHECK 3 (WARN) — contradictory CANONICAL coverage numbers. RESEARCH-STATE must carry ONE canonical
  # coverage figure; the real pruebas-dashboards corpus instead ACCRETED 16/16, 22/16, 24/16, then 26/26
  # (the denominator drifted 16→26 with no reconciliation) so no reader could get one true number. The
  # `## Iteration history` table LEGITIMATELY snapshots a different cumulative ratio per row, so strip
  # that section first (awk drops everything from its history header to the next `## ` header). The fence
  # is matched CASE-INSENSITIVELY (tolower) and also accepts the bare `## History` alias: over-recognizing
  # the history fence is cheap (a miss there is low-cost), while a false alarm is the whole risk. Only
  # canonical coverage-metric lines OUTSIDE it are gathered. NOTE: this diffs on distinct DENOMINATORS
  # only — same-denominator/different-numerator drift (22/16 vs 24/16) is intentionally NOT flagged.
  # Two-or-more DISTINCT denominators ⇒ WARN (mirror hygiene, not a STOP hazard — no rc change, like CHECK 2).
  noniter="$(awk '
    tolower($0) ~ /^##[[:space:]]+(iteration )?history/ { inhist=1; next }
    /^##[[:space:]]/ { inhist=0 }
    !inhist { print }
  ' "$state" 2>/dev/null)"
  mapfile -t denoms < <(printf '%s\n' "$noniter" \
    | grep -iE 'coverage metric|declared gaps closed|gaps? closed|coverage \(after' \
    | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' \
    | sed -E 's#.*/[[:space:]]*##' \
    | sort -un)
  if [ "${#denoms[@]}" -ge 2 ]; then
    joined="$(printf '%s vs ' "${denoms[@]}")"; joined="${joined% vs }"
    echo "   WARN   contradictory coverage denominators ($joined) — collapse to one canonical coverage number"
  fi

  [ "$frc" -eq 0 ] && echo "   ok     summary is consistent with the backlog."
done

echo "== exit $rc =="
exit $rc
