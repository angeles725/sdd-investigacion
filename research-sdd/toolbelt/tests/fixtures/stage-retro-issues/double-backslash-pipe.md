<!-- review-status: pending -->
# Retro — backslash runs before a pipe in delta-table cells (kit issue #2135)

## Proposed kit deltas

| # | Kind\\| Proposed change | Evidence | Target | Type | Priority |
|---|---|---|---|---|---|---|
| 1\\| k | First cell break, title long enough | EVFIRST | `a.sh` | feature | LOW |
| 2 | k | Middle cell ends in a path C:\\| EVMIDDLE | `b.sh` | feature | LOW |
| 3 | k | Last cell title ends in C:\\|
| 4 | k | Odd run C:\\\| stays in one cell | EVODD | `d.sh` | feature | LOW |
