# Block 61 — synthetic

## 61.11 — Findings

- **B61-G90** (low) — outside any child-gap section, so it needs no clause: 12 jars.

## 61.12 — Child gaps opened

Prose before the bullets is not a bullet and is never judged: 40 words.

- **B61-G1** (low, investigable) — R4-BAD first bullet with no clause at all.
- **B61-G2** (medium, investigable) — arrow form with a stated figure of 12 jars. coverage-check: `rg -il "jar" block*.md` → [Block 4] only. measured-by: jars counted by `unzip -l` (baseline 0).
- **B61-G3** (low) — code span plus prose result, the form real blocks use. coverage-check: `rg -il "wire format" block*.md` (single hit outside this lineage: block18.md). 
- **B61-G4** (low) — R4-BAD placeholder clause. coverage-check: TBD
- **B61-G5** (low) — R4-BAD query with no result. coverage-check: `rg -il "frame" block*.md`.
- **B61-G6** (low) — R4-BAD arrow with an empty result. coverage-check: `rg -il "frame" block*.md` → .
- **B61-G7** (low) — a zero-hit result is a legitimate result. coverage-check: `rg -il "kotlinc" block*.md` → none.
- **B61-G8** (low) — R4-BAD states 247 classes but names no tool. coverage-check: `rg -il "class" block*.md` → [Block 9].
- **B61-G9** (low) — R4-BAD measured-by is a stub. About 30% of rows. coverage-check: `rg -il "row" block*.md` → none. measured-by: TODO
- **B61-G10** (low) — waived. <!-- lint-waive: R4 reason=restated from an upstream block that predates the convention -->
- **B61-G11** (low) — clause on a continuation line, number stated once
  with a tool. coverage-check: `rg -il "decode" block*.md` → [Block 7]
  only. measured-by: methods decoded (baseline 3).
- **B61-G12** (low) — no figures: BNumericPoint:79 read on 2026-09-21 in [Block 12] under v2 of N5 and 4.15, section §61.3, B60-G2.
  coverage-check: `rg -il "numeric" block*.md` → [Block 3] only.
- **B61-G13** (low) — prose-only clause naming a doc reference. coverage-check: T10 state in odd/tasks/x.md says unresolved today.

```text
- B61-G91 (low) — a fenced bullet is quoted material and is never judged.
```

- **B61-G14** (low) — last bullet, clause absent. R4-LAST-BAD
