<!-- review-status: pending -->
# Retro — backslash runs before a pipe in delta-table cells (kit issue #2135)

## Proposed kit deltas

| # | Kind\\| tag | Proposed change | Evidence | Target | Type | Priority |
|---|---|---|---|---|---|---|
| 1\\|k | k | First cell with a\\| b pipe, long enough | EVA1 | `a.sh` | feature | LOW |
| 2 | k | Middle cell ends in a path C:\\| still one cell | EVA2 | `b.sh` | feature | LOW |
| 3 | k | Last cell title ends in C:\\|
| 4 | k | Odd run C:\\\| stays in one cell | EVA4 | `d.sh` | feature | LOW |

| # | Kind\\\| tag | Proposed change | Evidence | Target | Type | Priority |
|---|---|---|---|---|---|---|
| 5 | k | Table B title long enough | EVB5 | `e.sh` | feature | LOW |
| 6\ | k | Backslash id title long enough | EVB6 | `f.sh` | feature | LOW |
| 7\\\|z | k | Odd first a\\\| b pipe, long enough | EVB7 | `g.sh` | feature | LOW |
