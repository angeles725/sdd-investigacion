# Block 65 — synthetic

## 65.3 — Child gaps opened

- **B65-G1** (low) — ASCII arrow form, no figures. coverage-check: `rg -il "x" block*.md` -> [Block 4].
- **B65-G2** (low) — R4-BAD a placeholder padded with words. coverage-check: n/a for this gap
- **B65-G3** (low) — R4-BAD another padded placeholder. coverage-check: TODO will run later
- **B65-G4** (low) — a real prose clause. coverage-check: the index lists nothing for this topic
- **B65-G5** (low) — R4-BAD a number in trailing prose. coverage-check: `rg -il "x" block*.md` → none. Then recount the 247 classes.
- **B65-G6** (low) — R4-BAD trailing prose is not the result. coverage-check: `rg -il "x" block*.md`. Then we compare things.
- **B65-G7** (low) — R4-BAD hit rate 12.5% today. coverage-check: `rg -il "x" block*.md` → none.
- **B65-G8** (low) — R4-BAD about 2.5x faster. coverage-check: `rg -il "x" block*.md` → none.
- **B65-G9** (low) — R4-BAD roughly 3k files. coverage-check: `rg -il "x" block*.md` → none.
- **B65-G10** (low) — R4-BAD see [Block 4, 247 classes]. coverage-check: `rg -il "x" block*.md` → none.
- **B65-G11** (low) — versions and refs are not figures: 4.15, 1.2.3, N5, v2, [Block 4], §65.3, B64-G2, File:79. coverage-check: `rg -il "x" block*.md` → none.
- **B65-G12** (low) — R4-BAD a pending result. coverage-check: `rg -il "x" block*.md` → pending
- **B65-G13** (low) — R4-BAD a missing result. coverage-check: `rg -il "x" block*.md` → missing
- **B65-G14** (low) — R4-BAD a tbd result. coverage-check: `rg -il "x" block*.md` -> tbd
- **B65-G15** (low) — nested clauses belong to the bullet, 12 jars.
  - coverage-check: `rg -il "x" block*.md` → none.
  - measured-by: jars counted by `unzip -l`.
- **B65-G16** (low) — R4-BAD a nested placeholder clause.
  - coverage-check: TBD
