<!-- review-status: pending -->
# Audit — <BLOCK or CORPUS> · Research-SDD certainty audit

> What was audited: <block(s) / corpus>.
> **SOURCE_ROOT** (real primary code — often NOT under the corpus): `<path>`.
> **Decompiler variant** certifying this audit: `<vineflower | procyon | raw | n/a>` (line numbers differ
> between variants — pin the one the block was authored against; see METHODOLOGY §13).
> Method: re-read the cited code/source per claim and assign a verdict. READ-ONLY on the audited
> corpus (this report is the only thing written). Verdicts: ESCALATED · CONFIRMED · DOWNGRADED · REFUTED
> (see METHODOLOGY §13). A strong ESCALATION may cite 2-3 coordinated lines (a constant def + its use
> site) — a multi-line citation is expected, not a smell.

## Audited claims

| # | Claim (short) | Original marker | Verdict | Real evidence (`file:line`) or why refuted/downgraded |
|---|---|---|---|---|
| 1 | <claim> | `[CERT-a]` | **ESCALATED** | `<file:line>` confirms it |
| 2 | <claim> | `[CERT]` | CONFIRMED | `<file:line>` |
| 3 | <claim> | `[CERT-a]` | DOWNGRADED | unverifiable from available source → `[INFER]` |
| 4 | <claim> | `[CERT]` | **REFUTED** | code says `<X>` at `<file:line>`, not `<claimed>` |

## Metrics

- **Claims audited**: <N>
- **ESCALATED**: <x>  ·  **CONFIRMED**: <x>  ·  **DOWNGRADED**: <x>  ·  **REFUTED**: <x>

## Honest verdict

<Did the engine extract more than the original author — and of what kind (more certainty via
escalations? caught errors via refutations)? Or did the original corpus already hold up? Be specific.>

## Corrections to apply (optional, METHODOLOGY §14)

- <REFUTED/DOWNGRADED claim> → fix in `<block>` transparently ("corrected per audit"), cite `<file:line>`.
