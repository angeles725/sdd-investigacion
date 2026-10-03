# Block 42 — synthetic

1. [CERT] The vendor.dll exports a handler. R9-ALLMISSING-BAD
2. [CERT-hw] The vendor.dll (sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef) exports a handler at 0x1a2b3c via readelf and objdump.
3. [CERT-live] sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef vendor.so at 0x1a2b3c confirmed with objdump only. R9-ONEINSTR-BAD
4. [CERT] The vendor.exe sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef read with readelf and objdump, no address given. R9-NOANCHOR-BAD
5. [CERT] The vendor.dll sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef at 0x1a2b3c read with readelf and nm output. R9-PLAINNM-BAD
6. [CERT] The vendor.dll sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef at 0x1a2b3c read with readelf and `nm` output.
7. [CERT-doc] The vendor.dll is described by the vendor manual.
8. The vendor.dll exports a handler with no evidence marker at all.
9. [CERT] The javax.baja.sys package loads the handler.
10. [CERT] Waived: the vendor.dll exports a handler <!-- lint-waive: R9 reason=hash recorded in the sibling block -->
11. [CERT] The vendor.dll at 0x1a2b3c read with readelf and objdump. R9-NOSHA-BAD

| claim | evidence |
|---|---|
| [CERT] vendor.dll exports a handler | sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef, 0x1a2b3c, readelf, objdump |
| [CERT] vendor.dll exports a handler | R9-ROW-BAD |