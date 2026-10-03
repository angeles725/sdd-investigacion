# Block 41 — synthetic

1. The security jar is N5-only. R8-BAD
2. The module is new in N5 (absent from 4.15 and PowerB, checked).
3. The N5-only setting value changed.
4. Checked the 4.15 baseline here. The package is added in N5. R8-CLAUSE-BAD
5. The API feature is absent from N4. R8-BAD2
6. Waived: the class is introduced in N5 <!-- lint-waive: R8 reason=baseline cited in the block header -->
7. The class is N5-only. R8-CLASS-BAD

| claim | note |
|---|---|
| The module is N5-only. | R8-ROW-BAD |

The jar is N5-only. R8-LAST-BAD