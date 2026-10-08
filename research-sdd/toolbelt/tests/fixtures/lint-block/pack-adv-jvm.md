# Block 43 — synthetic

1. The decompiled class uses a lambda here (CFR output). ADV-R1-BAD
2. The decompiled class uses a lambda here (javap shows invokedynamic).
3. The build bypasses the cache in the test context. ADV-R5-CLEAR
4. The null Context path is ungated. ADV-R5-BAD
5. The null-context path bypasses the check. ADV-R5-BAD
6. The cx path is ungated. ADV-R5-BAD
7. The CX path is ungated. ADV-R5-CLEAR
8. The Context path is ungated. ADV-R5-BAD
9. The ordinary context path is ungated. ADV-R5-CLEAR
