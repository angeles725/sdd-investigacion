# Focuses
<!-- Fixture for table-reader-parity.test.sh (kit #2161): `\|`, `\\|`, `\\\|` are each ONE escaped pipe in GFM.
     Deprecated tokens (`closed`, `reabierto`) sit AFTER an escaped pipe in the first or a middle cell, and a last cell
     carries one too: the proposal must rewrite the Status cell only and keep every escape byte as written. -->

| Focus | Notes | Status | Research-State | Last |
|---|---|---|---|---|
| m1 | n\|esc | closed | RESEARCH-STATE-m1.md | l |
| m2 | n\\|even | reabierto | RESEARCH-STATE-m1.md | l |
| m3 | n\\\|triple | closed | RESEARCH-STATE-m1.md | l\|esc |
| x\|y | n | reabierto | RESEARCH-STATE-m1.md | l |
| x\\|y | n | closed | RESEARCH-STATE-m1.md | l\\|even |
| d1 | n\|esc | document | RESEARCH-STATE-d1.md | l |
