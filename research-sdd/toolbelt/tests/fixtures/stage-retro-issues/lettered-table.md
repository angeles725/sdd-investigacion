<!-- review-status: pending -->
# Retro — lettered table ids (shape of a real fleet retro)

## Proposed kit deltas (human review — NOT applied)

| # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| SPKI-A | Fix the canonical_encode helper to preserve element text so it verifies certificate files | `tools/license-tool.py` | B395 | tooling | MEDIUM |
| SPKI-B | Record the sha256 of an embedded key extracted from a decompiled byte array in SOURCES.md | `METHODOLOGY.md` · §5 | B113 | doctrine | LOW |
| SPKI-C | Add a cross-focus note that visible on-disk cert files are leaves and real roots are compiled-in | `METHODOLOGY.md` · §16 | B392 | doctrine | LOW |

- **SPKI-A (MEDIUM, tooling):** a bullet restating the table row; the table wins.
