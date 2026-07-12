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
mapfile -t states < <(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null)
[ "${#states[@]}" -gt 0 ] || { echo "verify-state: no RESEARCH-STATE*.md under $target" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------
# research-state.v1 ENVELOPE — the machine-validated contract (retro delta: port of gentle-ai's
# verify-result/v1 envelope discipline). The envelope is a marker-fenced block of `key: <int>` lines
# (dead-simple grep/awk, NO nested YAML — same idiom as the rest of the toolbelt). It DECLARES the
# load-bearing counts; verify-state RECOMPUTES the disk-anchored ones and FAILs on ANY drift, so a stale
# envelope can never hand out a premature STOP. Field names use UNDERSCORES (covered_blocks, NOT the prose
# "covered blocks") precisely so envelope lines never collide with the CHECK 1/2/3 prose greps below.
has_env()   { grep -q '<!-- research-state.v1 -->' "$1"; }
env_field() { awk -v k="$2" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{print $2; exit}' "$1"; }
is_int()    { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# Ground-truth derivations. These MIRROR research-sdd-status.sh (section / backlog_rows / blocked_names /
# is_blocked) EXACTLY: verify-state stays STANDALONE (no shared lib — status.sh's mutation harness copies
# only verify-state.sh into a temp dir, so a sourced lib there would break it), which makes this a
# DELIBERATE mirror that MUST stay in lockstep with status.sh and with what `--sync-state` writes.
_section()      { awk -v h="$2" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$1"; }
_backlog_rows() {                                   # emits "priority<TAB>gap<TAB>status" for real 4-col rows
  awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); for(k=1;k<=n;k++) gsub(/^[ \t]+|[ \t]+$/,"",a[k])
      p=tolower(a[1]); if (p!="high" && p!="medium" && p!="low") next
      if (n!=4) next                                # a pipe INSIDE a cell → skip (mirrors status.sh; not counted)
      print p "\t" a[2] "\t" tolower(a[4]) }' "$1"
}
_blocked_names() {                                  # one exact blocked gap NAME per "- <name> — needs: ..." line
  _section "$1" '## Blocked gaps' | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
    | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}
# derived investigable_open = pending (LEADING-TOKEN) backlog rows whose gap is NOT blocked. This is
# resolve_next's NEXT-eligibility set by construction — the STOP-CRITICAL number that closes the
# premature-STOP class: if the envelope under-declares it, verify-state FAILs → --next returns STALE.
derive_investigable() {
  local sf="$1" blk gap st n=0 b hit
  blk="$(_blocked_names "$sf")"
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    [ "${st%% *}" = "pending" ] || continue         # bare `pending` or decorated `pending (...)`; NOT "blocked (pending review)"
    hit=0; while IFS= read -r b; do [ -n "$b" ] && [ "$b" = "$gap" ] && { hit=1; break; }; done <<<"$blk"
    [ "$hit" = 1 ] && continue                       # exact-name blocked exclusion (mirrors is_blocked)
    n=$((n+1))
  done < <(_backlog_rows "$sf")
  echo "$n"
}
# derived blocked_open = count of "- <name> — needs: ..." entries under ## Blocked gaps (needs:-anchored,
# so a bare "- none" placeholder never inflates the count).
derive_blocked() { _section "$1" '## Blocked gaps' | grep -icE '^[[:space:]]*-[[:space:]].*needs:'; }

rc=0
for state in "${states[@]}"; do
  echo "== verify-state: $(basename "$state") (target: $target) =="
  frc=0

  # ENVELOPE GATE (STALE-gate, NOT a soft fallback) — an un-migrated state with NO research-state.v1
  # envelope is a hard FAIL: its counts are not machine-validated, so the loop must not trust the prose.
  # This makes research-sdd-status.sh --next return STALE (its verify-state gate), blocking the loop until
  # the envelope is seeded. Distinct, actionable message so the fix is obvious.
  if ! has_env "$state"; then
    echo "   FAIL   no research-state.v1 envelope — run: research-sdd-status.sh $target --sync-state to seed it"
    echo "          Unmigrated state: the counts are not machine-validated, so --next returns STALE until seeded."
    rc=1
    continue
  fi

  # 1. backlog `pending` gap rows (grep -c already prints 0 on no match; keep it a single integer).
  pending="$(grep -icE '\bpending\b' "$state" 2>/dev/null || true)"

  # 2. coverage metric "X / Y ... closed"
  metric="$(grep -iE 'coverage metric|declared gaps closed|gaps? closed' "$state" 2>/dev/null | head -1)"
  xy="$(printf '%s' "$metric" | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
  cx="${xy%%/*}"; cy="${xy##*/}"

  # 3. covered-blocks claim vs on-disk block files. Use the SAME STRICT discriminator as gen-catalog.py
  #    (BLOCK_RE) and research-sdd-archive.sh: `<prefix>-(block|bloque)<N>[-suffix].md`. A loose `*block*`
  #    glob wrongly counts decoys like `blocked-notes.md`; keeping ONE definition of "a block file" across
  #    verify-state / --sync-state / archive / catalog kills the dual-authority drift on this count.
  covered_claim="$(grep -iE 'covered blocks' "$state" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  ondisk="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -iE '/[^/]*-(block|bloque)[0-9]+(-[a-z0-9_-]+)?\.md$' | wc -l | tr -d ' ')"

  # --- envelope contract: recompute ground truth, compare to declared ints ---------------------
  d_inv="$(derive_investigable "$state")"
  d_blocked="$(derive_blocked "$state")"
  e_covered="$(env_field "$state" covered_blocks)"
  e_inv="$(env_field "$state" investigable_open)"
  e_blocked="$(env_field "$state" blocked_open)"
  e_gc="$(env_field "$state" gaps_closed)"
  e_kg="$(env_field "$state" known_gaps)"

  echo "-- summary --"
  echo "   coverage metric : ${xy:-<none>}"
  echo "   covered blocks  : ${covered_claim:-<none>} claimed · ${ondisk} block file(s) on disk"
  echo "   backlog pending : ${pending}"
  echo "   envelope        : covered_blocks=${e_covered:-<none>}/${ondisk} · investigable_open=${e_inv:-<none>}/${d_inv} · blocked_open=${e_blocked:-<none>}/${d_blocked}  (declared/derived)"

  # ENVELOPE CHECK A (FAIL) — declared covered_blocks must equal on-disk block files (reuse `ondisk`).
  if ! is_int "$e_covered" || [ "$e_covered" != "$ondisk" ]; then
    echo "   FAIL   envelope covered_blocks=${e_covered:-<missing>} != ${ondisk} block file(s) on disk — re-seed: --sync-state"
    frc=1; rc=1
  fi
  # ENVELOPE CHECK B (FAIL, STOP-CRITICAL) — declared investigable_open must equal the NEXT-eligible set.
  # This is the check that closes the premature-STOP class BY CONSTRUCTION: an under-declared count here
  # (e.g. investigable_open: 0 while 2 pending non-blocked gaps remain) FAILs → --next returns STALE, not STOP.
  if ! is_int "$e_inv" || [ "$e_inv" != "$d_inv" ]; then
    echo "   FAIL   envelope investigable_open=${e_inv:-<missing>} != ${d_inv} NEXT-eligible pending gap(s) — re-seed: --sync-state"
    echo "          A stale investigable_open is the premature-STOP hazard; verify-state refuses to certify it."
    frc=1; rc=1
  fi
  # ENVELOPE CHECK C (FAIL) — declared blocked_open must equal the on-disk "## Blocked gaps" entry count.
  if ! is_int "$e_blocked" || [ "$e_blocked" != "$d_blocked" ]; then
    echo "   FAIL   envelope blocked_open=${e_blocked:-<missing>} != ${d_blocked} blocked entr(y/ies) — re-seed: --sync-state"
    frc=1; rc=1
  fi
  # ENVELOPE CHECK D (FAIL) — envelope-side of CHECK 1: declared FULL coverage (gaps_closed == known_gaps,
  # denominator > 0) while investigable gaps still remain. gaps_closed/known_gaps are declared-only (not
  # disk-derivable), so this is a consistency check against the DERIVED investigable count, not a mismatch.
  if is_int "$e_gc" && is_int "$e_kg" && [ "$e_kg" -gt 0 ] && [ "$e_gc" = "$e_kg" ] && [ "$d_inv" -gt 0 ]; then
    echo "   FAIL   envelope gaps_closed=$e_gc == known_gaps=$e_kg while $d_inv investigable gap(s) remain — premature-STOP hazard."
    frc=1; rc=1
  fi

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

  [ "$frc" -eq 0 ] && echo "   ok     envelope validated + summary consistent with the backlog."
done

echo "== exit $rc =="
exit $rc
