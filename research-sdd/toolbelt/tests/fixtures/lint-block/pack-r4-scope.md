# Block 64 — synthetic

## 64.12 — Child gaps opened

### Medium priority

- **B64-G1** (medium) — R4-BAD under a sub-heading with no clause.
- **B64-G2** (medium) — conforming under a sub-heading. coverage-check: `rg -il "x" block*.md` -> none.

#### Deeper level

- **B64-G3** (low) — R4-BAD a deeper sub-heading is still inside the section.

## 64.13 — Next section

- **B64-G4** (low) — outside every judged section (unscoped, not judged).

## 64.14 — Closed child gaps

- **B64-G5** (low) — an excluded heading is not judged (unscoped).

**Child gaps opened**

- **B64-G6** (low) — R4-BAD a bold-line label starts a judged section.

## 64.15 — Notes

- **B64-G7** (low) — the label section ended at the next heading (unscoped).

## 64.16 — Open child gaps

### Resolved child gaps

- **B64-G8** (low) — an excluded sub-heading inside a judged section (unscoped).

### Still open

- **B64-G9** (low) — R4-BAD the judged section resumes after the excluded sub-heading.
