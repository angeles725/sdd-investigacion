R1-FIRST-BAD The new loader uses pattern-matching for instanceof checks.

# Block 40 — synthetic

## Findings

1. The handler rewrites its loop to an enhanced for loop. R1-ITEM-BAD
2. The handler uses a lambda here (javap shows invokedynamic).
3. Uses `javap` output to confirm. The parser adopts text blocks for the template. R1-CLAUSE-BAD
4. A var declaration is just a keyword in this file.
5. Waived: the class uses var everywhere <!-- lint-waive: R1 reason=quoted from the vendor changelog -->
6. Reason-less waiver: the class adopts sealed hierarchies. R1-NOREASON-BAD <!-- lint-waive: R1 -->

| claim | note |
|---|---|
| The filter fails open when the permission lookup is null. | R5-ROW-BAD |
| The filter bypasses permission checks (dispatch: Foo.getPermissions resolves to the override). | clean |
| The build flag bypasses the cache. | no relevant scope |

The check drops cx, so the null Context path is ungated. R5-PARA-BAD

The dead constant DEFAULT_PORT is never read anywhere. R7-BAD

The unused constant is a compile-time constant.

Waived: the shadow literal remains <!-- lint-waive: R7 reason=quoted from upstream issue -->

```
fenced quote: the dead constant is flagged by the old tool and the filter fails open on a null permission.
```

Waiver for the wrong rule: the hardcoded port instead of the constant. R7-WRONGRULE-BAD <!-- lint-waive: R5 reason=wrong rule -->

Last line: the old duplicate constant is flagged. R7-LAST-BAD