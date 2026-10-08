# Block 48 — synthetic

1. Whether the module is new in N5 is not yet known. CAL-R8-CLEAR
2. The API is not new in N5; an earlier release already shipped it. CAL-R8-CLEAR
3. Is the jar N5-only? CAL-R8-CLEAR
4. The jar is N5-only. CAL-R8-BAD
5. The module is new in N5 and was not shipped before. CAL-R8-BAD
6. The feature, which is absent from N4, is a new capability. CAL-R8-BAD
7. Confirm whether the package is genuinely N5-only or simply missing from the corpus. CAL-R8-CLEAR
8. The classes are genuinely new in N5, but a child gap left open whether the client side is too. CAL-R8-BAD
9. CAL-R8-BAD The `foo.jar` module is new in N5; why was it missed?
10. CAL-R8-BAD Is this a regression? no, the `foo` package is new in N5.
11. CAL-R8-BAD The `foo` package is not only new in N5 but also renamed.
12. CAL-R8-BAD Whether or not covered the `foo` package is new in N5.
13. Is the `foo` jar new in N5? CAL-R8-CLEAR
14. CAL-R8-BAD Whether CI ships it is unclear, the `foo` package is new in N5.
15. CAL-R8-BAD Whether the jar ships is unclear; the `foo` package is new in N5.
16. CAL-R8-BAD The `foo` module is new in N5 (did 4.14 ship it?).
17. CAL-R8-BAD The `foo.jar` package is new in N5, isn't it?
18. CAL-R8-BAD The `foo` jar is new in N5, right?
19. Is the `foo` jar new in N5 (or is it older)? CAL-R8-CLEAR
