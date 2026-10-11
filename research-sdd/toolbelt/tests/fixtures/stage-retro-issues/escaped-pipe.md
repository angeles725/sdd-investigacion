<!-- review-status: pending -->
# Retro — GFM-escaped pipes inside delta-table cells (kit issue #2118)

## Proposed kit deltas

| # | Kind \| tag | Proposed change \| gist | Target | Evidence | Type | Priority |
|---|---|---|---|---|---|---|
| E\|1 | k | First-cell escaped a\|b pipe delta, long enough | `a.sh` | EVFIRST | feature | LOW |
| 2 | k | Middle cell quotes the header `\| ID \| Delta \| Target \| Evidence \| Priority \|` verbatim | `b.sh` | EVMIDDLE | feature | LOW |
| 3 | k | Last cell escaped pipe delta, long enough | `c.sh` | EVLAST | feature | HIGH\|MEDIUM |
| 4 | k | Only\|two\|cells here, no target |
