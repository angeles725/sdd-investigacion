# Design: Reframe research-sdd-init.sh JUDGMENT follow-ups by ordering

## Technical Approach

A text-only reframe of the JUDGMENT follow-up block in `research-sdd-init.sh`
(currently lines 154-166) plus matching test assertions. Option A: split the
single "do these next" header into two ordered group markers — a CONFIRM group
(items 1-2, doctrinally PRE-scaffold per PROMPT-LOOP §b/§b2) and a THEN group
(items 3-5, genuine post-scaffold). Item 1's existing consequence line is
reworded to mirror §b concisely. Every unit-1 cross-ref signal is preserved
verbatim. `PROMPT-LOOP.md` stays frozen — the fix strengthens the signal at the
point of use (the emitted report), not the doctrine.

## Current lines (exact, before)

```
154  echo "-- JUDGMENT follow-ups (NOT mechanizable — do these next) --"
155  echo "  1. REGISTER the target row in $KIT/TARGETS.md (name·path·maturity·artifact·wrapper·language) (PROMPT-LOOP §b)"
156  echo "     — else sweep-retros.sh cannot see its retros/ (§18)."
157  echo "  2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2); run profile-target.sh + detect-tools.sh."
158  echo "  3. SEED 5-15 real gaps into $corpus/RESEARCH-STATE.md (audit-first for a mature corpus) (§e)."
159  echo "  4. REGISTER + ADAPT the hook (§c follow-up): put research-protocol.sh in $target/.claude/settings.json"
160  echo "     (matcher startup|resume|clear); replace <SUBJECT> + real source paths."
161  [ "$rel" != "(target root, flat)" ] && echo "     For this NESTED corpus, PREFIX the hook's block/INDEX/CATALOG paths with corpus/."
162  if [ -n "$prefix" ]; then
163    echo "  5. Block files use the prefix: ${prefix}-blockN.md"
164  else
165    echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"
166  fi
```

Lines 167-169 (`echo`, `NEXT:`, `mental model:`) are untouched.

## Architecture Decisions

### Decision: Two group markers, keep the 1-5 numbering

**Choice**: Replace line 154 with a CONFIRM header over items 1-2, then insert a
`-- THEN do next (post-scaffold) --` marker before item 3. Keep the numbered
list intact.
**Alternatives considered**: (a) renumber into two lists (1-2 / 1-3) — breaks the
step-5 conditional and NEXT references, larger diff; (b) move items 1-2 to a
separate pre-scaffold banner earlier in the script — changes control flow and
output ordering, out of proportion for report-wording.
**Rationale**: Scannable dividers give the ordering signal with the smallest,
lowest-risk diff. Stable numbering keeps every downstream reference valid.

### Decision: Reword item-1 consequence, do not add the three.js lesson

**Choice**: Line 156 `— else sweep-retros.sh cannot see its retros/ (§18).` →
`— else its retros/ is invisible to the §18 sweep.`
**Alternatives considered**: paste the full §b three.js failure narrative.
**Rationale**: §7 anti-silent-zero ergonomics call for one loud clause at the
point of use, not a duplicated lesson. `invisible`/`§18 sweep` mirror §b and give
the test a stable, non-false-matching grep.

## After (exact target)

```
echo "-- CONFIRM these are done — they belong at PROMPT-LOOP §b/§b2, BEFORE this scaffold (do them NOW if skipped) --"
echo "  1. REGISTER the target row in $KIT/TARGETS.md (name·path·maturity·artifact·wrapper·language) (PROMPT-LOOP §b)"
echo "     — else its retros/ is invisible to the §18 sweep."
echo "  2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2); run profile-target.sh + detect-tools.sh."
echo "-- THEN do next (post-scaffold) --"
echo "  3. SEED 5-15 real gaps into $corpus/RESEARCH-STATE.md (audit-first for a mature corpus) (§e)."
echo "  4. REGISTER + ADAPT the hook (§c follow-up): put research-protocol.sh in $target/.claude/settings.json"
echo "     (matcher startup|resume|clear); replace <SUBJECT> + real source paths."
[ "$rel" != "(target root, flat)" ] && echo "     For this NESTED corpus, PREFIX the hook's block/INDEX/CATALOG paths with corpus/."
if [ -n "$prefix" ]; then
  echo "  5. Block files use the prefix: ${prefix}-blockN.md"
else
  echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"
fi
```

Preserved verbatim: `(PROMPT-LOOP §b)` on 1, `(PROMPT-LOOP §b/§b2)` on 2, `(§e)`
on 3, `(§c follow-up)` on 4, the nested-corpus line, the step-5 if/else, and
lines 167-169.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/research-sdd-init.sh` | Modify | Split header into CONFIRM + THEN markers; reword item-1 consequence |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | Modify | New reframe assertion block + 3 `--prove-teeth` mutants |

## Testing Strategy

New assertion block (reuse the stdout-capture-to-`$TMP` pattern, no-prefix run):

| # | Assertion | grep |
|---|-----------|------|
| a | CONFIRM pre-scaffold marker present | `CONFIRM these are done` and `BEFORE this scaffold` |
| b | THEN post-scaffold marker present | `THEN do next (post-scaffold)` |
| c | item-1 §18-sweep consequence present | `invisible to the §18 sweep` |
| guard | item-2 §b/§b2 signal survives reframe | `PROMPT-LOOP §b/§b2)` |

Regression of the other unit-1 signals is already pinned by the existing xref
(`§b)`, `§e)`, `§c follow-up)`), step-5 conditional, and NEXT/BOOTSTRAP blocks —
those stay as-is and act as the non-regression net.

`--prove-teeth` mutants (awk delete-line, matching the suite's negative-control
convention + loud "could not build mutant" build-check), one per NEW assertion:

- **M5** `/CONFIRM these are done/ { next }` → build-check greps mutant no longer
  contains `CONFIRM these are done`; assert stdout lacks it → assertion (a) has teeth.
- **M6** `/THEN do next \(post-scaffold\)/ { next }` → assert stdout lacks
  `THEN do next (post-scaffold)` → assertion (b) has teeth.
- **M7** `/invisible to the §18 sweep/ { next }` → assert stdout lacks
  `invisible to the §18 sweep` → assertion (c) has teeth.

All three grep forms are new, unique strings (old text said "cannot see its
retros/") so no mutant false-matches surviving text.

## Threat Matrix

N/A — no routing, shell-command construction, subprocess, VCS/PR automation,
executable-file classification, or process-integration boundary is changed. This
is emitted-report wording plus test assertions inside two already-frozen files.

## Migration / Rollout

No migration. Single-file text revert of both files rolls back cleanly; no state,
corpus, or contract to unwind.

## Open Questions

- None. PROMPT-LOOP.md frozen; scope limited to the two named files.
