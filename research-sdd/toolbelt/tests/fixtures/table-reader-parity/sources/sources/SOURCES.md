# Sources

<!-- Fixture for table-reader-parity.test.sh (kit #2161 / #2178): a backslash, two or three backslashes before a pipe
     are each ONE escaped pipe in GFM. Every data row is a well-formed 6-column row; the escapes sit in the first
     (File), a middle (Origin) and the last (Citing blocks) cell. Rows whose File cell holds an escape are rendered
     as `a|esc.pdf`, `a\|even.pdf`, `a\\|triple.pdf`: those names are what the block cites. The web-snapshot file
     whose name carries a pipe (w|esc.html) is created by the test (a pipe in a committed file name is not portable).
     The `w\|even.html` and `w\\|triple.html` snapshots (names holding a backslash) are created by the test too: GNU
     sha256sum prefixes the digest line of such a name with a backslash (#2182), which LEVEL 6 must not read as a hash. -->

| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |
|---|---|---|---|---|---|
| a\|esc.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| a\\|even.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| a\\\|triple.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| b.pdf | manual | http://x?q=1\|2 | tbd | abc | B1 |
| c.pdf | manual | http://x?q=1\\|2 | tbd | abc | B1 |
| d.pdf | manual | http://x?q=1\\\|2 | tbd | abc | B1 |
| e.pdf | manual | http://x | 2026-01-01 | abc | B1 \| note |
| f.pdf | manual | http://x | 2026-01-01 | abc | B1 \\| note |
| g.pdf | manual | http://x | 2026-01-01 | abc | B1 \\\| note |
| h\|esc.pdf | manual | http://x | 2026-01-01 | abc | B1 |
| j.pdf | manual | note\|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 | tbd | abc | B1 |
| web-snapshots/w\|esc.html | web | http://x | 2026-01-01 | 8b29000c3655ea56688800375b4c83115b947c1533f9ee759069622769c18974 | B1 |
| web-snapshots/w\\|even.html | web | http://x | 2026-01-01 | 8b29000c3655ea56688800375b4c83115b947c1533f9ee759069622769c18974 | B1 |
| web-snapshots/w\\\|triple.html | web | http://x | 2026-01-01 | 8b29000c3655ea56688800375b4c83115b947c1533f9ee759069622769c18974 | B1 |
| web-snapshots/w4.html | web | http://x?q=1\|2 | tbd | 8b29000c3655ea56688800375b4c83115b947c1533f9ee759069622769c18974 | B1 |
| web-snapshots/w5.html | web | http://x?q=1\\|2 | tbd | aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | B1 |
