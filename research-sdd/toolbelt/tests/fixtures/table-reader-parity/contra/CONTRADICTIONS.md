# Contradictions ledger
<!-- Fixture for table-reader-parity.test.sh (kit #2161): `\|`, `\\|`, `\\\|` are each ONE escaped pipe in GFM.
     Open rows: C1-C5 (escapes before the STATUS cell, and in the last cell). C6/C7 are resolved: C7 would
     read as open only if the bare-pipe split shifted its "open" claim cell into the STATUS slot. -->

| id | claim A | claim B | status | note |
|---|---|---|---|---|
| C1 | a\|esc | b | open | n |
| C2 | a\\|even | b | open | n |
| C3 | a\\\|triple | b | open | n |
| C4 | a | b\|esc | open | n |
| C5 | a | b | open | last\|esc |
| C6 | a | b | resolved | x\|open |
| C7 | p\|q | open | resolved | n |
