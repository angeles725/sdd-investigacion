# Block 5 — synthetic

## Self-verify

| # | Claim | Marker | Provenance |
|---|---|---|---|
| 1 | durable path | [CERT-hw] | `evidence/probe-1.txt` |
| 2 | mixed: scratch run plus a preserved copy | [CERT-live] | ran in `/tmp/x/out.txt`; preserved at `evidence/out-copy.txt` |
| 3 | file:line cite | [CERT-hw] | Foo.java:42-43 |
| 4 | block ref | [CERT-live] | see bloque28:200-246 |
| 5 | non-hardware marker may cite tmp | [CERT-doc] | `/tmp/doc.html` |
| 6 | no evidence path at all | [CERT-hw] | measured on the bench, this session |
