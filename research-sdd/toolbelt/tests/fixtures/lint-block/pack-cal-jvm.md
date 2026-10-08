# Block 47 — synthetic

1. The codec uses a var-length prefix for each record. CAL-R1-CLEAR
2. N5 rewrites the loop to iterate for each pingable. CAL-R1-CLEAR
3. The vendor replaces the sealed envelope with a stamped one. CAL-R1-CLEAR
4. The parser uses `var` declarations throughout. CAL-R1-BAD
5. The parser adopts the var keyword for locals. CAL-R1-BAD
6. The class adopts sealed interfaces. CAL-R1-BAD
7. The loop is rewritten as a for-each. CAL-R1-BAD
8. The authored notes say the build bypasses the cache. CAL-R5-CLEAR
9. The authentication layer bypasses the check. CAL-R5-BAD
10. The authorization step is ungated. CAL-R5-BAD
11. The auth filter fails open. CAL-R5-BAD
12. The authz gate is a no-op. CAL-R5-BAD
13. The census shows records/sealed adoption across the corpus. CAL-R1-BAD
14. The unauthenticated endpoint bypasses the check. CAL-R5-BAD
15. The OAuth flow is ungated. CAL-R5-BAD
16. The deauthorize step is a no-op. CAL-R5-BAD
17. The Access policy action Bypass disables enforcement for the matched security rule. CAL-R5-CLEAR
18. Service Auth is evaluated before Bypass when the policy decides who is authorized. CAL-R5-CLEAR
19. A `bypass` policy lets the credentials check be skipped for the path. CAL-R5-CLEAR
20. The Bypass action also fails open when authorization errors out. CAL-R5-BAD
21. A caller can bypass authorization when the header is absent. CAL-R5-BAD
22. The authentication filter bypasses the policy entirely. CAL-R5-BAD
23. Bypassed requests reach the authorization layer unchecked. CAL-R5-BAD
