# Sources

<!-- Fixture for table-reader-parity.test.sh (kit #2161): `\|`, `\\|`, `\\\|` are each ONE escaped pipe in GFM.
     Every data row is a well-formed 6-column row: the escapes sit in the first, a middle and the last cell. -->

| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |
|---|---|---|---|---|---|
| a\|esc.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| a\\|even.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| a\\\|triple.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| b.pdf | manual | http://x?q=1\|2 | 2026-01-01 | abc | B1 |
| c.pdf | manual | http://x?q=1\\|2 | 2026-01-01 | abc | B1 |
| d.pdf | manual | http://x?q=1\\\|2 | 2026-01-01 | abc | B1 |
| e.pdf | manual | http://x | 2026-01-01 | abc | B1 \| note |
| f.pdf | manual | http://x | 2026-01-01 | abc | B1 \\| note |
| g.pdf | manual | http://x | 2026-01-01 | abc | B1 \\\| note |
