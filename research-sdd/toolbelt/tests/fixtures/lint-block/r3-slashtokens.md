# Block 21 — synthetic

## Self-verify

| # | Claim | Marker | Provenance |
|---|---|---|---|
| 1 | slash word ROW-BAD | [CERT-hw] | scratch `/tmp/x/out.txt`, same binary/sha256 |
| 2 | ratio ROW-BAD | [CERT-live] | `/tmp/y/run.log`, 3/3 runs |
| 3 | n/a and and/or ROW-BAD | [CERT-hw] | `/tmp/z/o.txt` N/A and/or similar |
| 4 | bare file:line ROW-BAD | [CERT-hw] | `/tmp/w/q.txt`, out.txt:12 |
| 5 | loose block ref ROW-BAD | [CERT-live] | `/tmp/v/q.txt`, see [Block 12] and B12 |
| 6 | two-segment non-path ROW-BAD | [CERT-hw] | `/tmp/u/q.txt`, binary/sha256 |
