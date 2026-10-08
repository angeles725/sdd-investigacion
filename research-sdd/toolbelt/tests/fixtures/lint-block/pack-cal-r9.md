# Block 49 — synthetic

## 3.1 — [CERT] vendor.dll is Authenticode-signed CAL-R9-HEADING-BAD

Confirmed during triage.

## 3.2 — [CERT] vendor.dll header analysis CAL-R9-HEADING-CLEAR

Evidence: sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef, read with readelf and objdump at offset 1a2b3c.

[CERT] The vendor.dll header analysis shows a stripped import table. CAL-R9-BAD

| claim | note |
|---|---|
| [CERT] The vendor.dll export table is empty. | CAL-R9-ROW-BAD |

## 3.3 — [CERT] other.so is an ELF shared object CAL-R9-EMPTY-BAD
## 3.4 — Notes without any binary claim

## 4.1 — [CERT] a.dll is Authenticode-signed CAL-R9-PARENT-BAD

### 4.1.1 — b.dll details

Evidence for b.dll only: sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef, read with readelf and objdump at offset 1a2b3c.
