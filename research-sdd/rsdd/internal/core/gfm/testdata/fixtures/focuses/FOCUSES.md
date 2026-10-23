# Focuses
<!-- Fixture for table-reader-parity.test.sh (kit #2161): a backslash, two or three backslashes before a pipe are each
     ONE escaped pipe in GFM. Every escape sits in a cell BEFORE the Status / Research-State cells (first or middle),
     or after them (last). This comment carries no pipe character: the status reader treats any line with one as a row. -->

| Focus | Notes | Status | Research-State | Last |
|---|---|---|---|---|
| f1 | n\|esc | stopped | RESEARCH-STATE-f1.md | l |
| f2 | n\\|even | paused | RESEARCH-STATE-f2.md | l |
| f3 | n\\\|triple | planned | RESEARCH-STATE-f3.md | l |
| f4 | ok | document | RESEARCH-STATE-f4.md | l\|esc |
| f5 | ok | active | RESEARCH-STATE-f5.md | l\\|even |
| x\|y | n | stopped | RESEARCH-STATE-f6.md | l |
| x\\|y | n | paused | RESEARCH-STATE-f7.md | l |
| x\\\|y | n | planned | RESEARCH-STATE-f8.md | l |
| f9 | n | stopped \| why | RESEARCH-STATE-f9.md | l |
