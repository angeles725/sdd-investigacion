# Kit table readers: cell semantics (U0.3, #2273)

Mapped read-only on `origin/main` 18b4b206 (paths relative to `research-sdd/toolbelt/`). All readers share ONE
escape rule: mask every `\|` (left to right, so `\\|` masks only the last backslash plus the pipe), split on the
remaining `|`. They differ in everything around it. Line numbers are the mask site (`gsub(/\\\|/...`).

| Reader (mask site) | Row = | Leading/trailing pipe | Cell trim | `\|` in the cell handed on | Empty cell | Header/separator |
|---|---|---|---|---|---|---|
| lib/gap-rows.sh `gap_rows_parse` (:51) | leading pipe (`^[ \t]*\|`) | strips leading, then trailing `\|[ \t]*$` after masking | `[ \t]` | `|` (unescaped) | kept `""` | no table context; rows keyed by cell 2 = gap id |
| verify-state.sh backlog (:151), deferred (:402) | any line containing `\|` after trim | `^\|` then `\|$` after trim | `[ \t]` | `|` | kept | separator = FIRST cell `^-+$` (`:` not allowed); first cell `priority`/`p` skipped |
| verify-state.sh Block column (:485), research-sdd-status.sh (:853) | any line with `\|` | NONE stripped: `split($0,a,"\|")`, so `a[1]` is the text before the leading pipe and indices shift by 1 | `[ \t]` (header and value only) | masked bytes are NOT restored (only used by `grep -oE B[0-9]+`) | n/a | header = first pipe row containing a cell `block` |
| research-sdd-status.sh backlog (:576), deferred (:520) | any line with `\|` | like verify-state | `[ \t]` | `|` | kept | like verify-state |
| research-sdd-status.sh `count_open_contra` (:310) | any line with `\|` | like verify-state | only cell 4 trimmed | `|` | `n<4` rows skipped | none: status cell must equal `open` (any case) |
| research-sdd-status.sh `iter_gaps_rows` (:336) | any line with `\|` after trim, HTML comments skipped | like verify-state | `[ \t]` | `|`; header line restored before printing (:344) | `(empty)` reported as bad | separator = ALL cells `^:?-+:?$`; first non-separator row = header |
| research-sdd-status.sh `_read_focuses_tok_uncached` (:968) | `index($0,"\|")` on the UNTRIMMED line | `sub(/^\|/)` on the untrimmed line | `[ \t]` | `|` | kept | separator = all cells `^:?-+:?$`; first other row = header |
| research-sdd-status.sh `outline_rows` (:2398) | `^[[:space:]]*\|` | NONE stripped (index shift by 1), trailing empties dropped by hand (`last--`) | `[ \t]` | `|` | `""`, trailing ones dropped | none |
| focus-partition-audit.sh (:241) | `^[ \t]*\|` | `sub(/^\|/)` on the UNTRIMMED line | `trim()` per use, not at split time | `|` | kept; `n<2` or empty identity = unclassifiable | separator = all cells `^:?-+:?$`; `n==0` is a separator by vacuous truth |
| migrate-backlogs.sh `cells()` (:171), DOC (:196) | `^[ \t]*\|` | strips leading, trailing `\|[ \t]*$` into `suf` | NOT trimmed (`raw[i]` keeps padding, `setcell` edits inside it) | KEPT as `\|` (`gsub(/\001/,"\\|")`), so rows rebuild byte-identically; the DOC reader restores `|` | kept | first row of a block = header; `a[1] ~ /^[ \t:-]+$/` skips separators |
| verify-sources.sh (:119, :258, :443 awk; :151, :336, :403 bash) | `^\|` (awk), every line (bash loops) | NONE stripped: `$2` is cell 1 | pre-check none; L4/L6/D2 strip backticks and blanks per use | `|` | kept | separator = `$2 ~ /^[- :]+$/` (cell 1 only, accepts `: :`) |

## Disagreements (not silently resolved: the API exposes each)

1. **Which lines are rows.** Leading-pipe (gap-rows, focus-partition-audit, migrate-backlogs, outline,
   verify-sources awk) vs any-pipe (verify-state, status backlog/deferred/contra/iter/focuses). A prose line
   such as `see a | b` is a row to the second group. API: `Options.Shape` = `ShapeLeadingPipe` (default) or
   `ShapeAnyPipe`.
2. **`\|` in the returned cell.** migrate-backlogs keeps the escape (it rewrites rows); all others unescape.
   API: `Row.Padded` (kept, with padding), `Row.Raw` (trimmed, kept), `Row.Text` (trimmed, unescaped).
3. **Padding.** migrate-backlogs keeps cell padding; the rest trim `[ \t]`. API: `Padded` vs `Raw`/`Text`.
4. **Index base.** Readers that do not strip the leading pipe (Block column, outline, verify-sources) number cells
   from 2. This is an artefact of their awk, not a semantic; `Row` always numbers cells from the first real cell.
5. **Carriage return.** Only gap-rows strips `\r`; the rest leave `\r` in the last cell and, because the closing
   pipe is then not last, add a phantom trailing cell. API: default strips (gap-rows), `Options.KeepCR` reproduces
   the others (the differential test uses it for contra and focuses).
6. **Separator test.** verify-state: first cell `^-+$`; verify-sources: first cell `^[- :]+$`; the rest: every cell
   `^:?-+:?$`. `IsSeparator` implements the GFM-shaped last form. Zero cells: awk readers call it a separator
   (vacuous truth); `IsSeparator(nil)` is false and `||`/`|` rows simply have zero cells.
7. **Bug found, indentation shifts columns in `_read_focuses_tok_uncached`.** `sub(/^\|/,...)` runs on the
   untrimmed line, so an indented row `  | e4 | | planned` keeps its leading pipe and every column moves right by
   one; the status reads empty (observed: bash `e4=` vs Go `e4=planned` before the edge row was un-indented,
   see `TestDifferentialFocusTok`). Not reproduced by Go. focus-partition-audit has the same untrimmed `sub(/^\|/)`.
8. **Truncation.** GitHub pads or drops cells to the header width; the kit readers count cells to flag malformed
   rows, so this package never truncates.

## Edge cases verified with the GFM renderer (`gh api -X POST /markdown -f mode=gfm`, synthetic table)

Empty cell kept; `y\` at the end of a cell keeps the backslash; missing trailing pipe and missing leading pipe both
read; `| e\\| f | g\\\| h |` is two cells; tabs kept inside, trimmed at the edges; `| last\|` is one cell `last|`
padded with an empty one; `| p | r || s |` renders only two cells (extra dropped, see 8).

## Differential coverage

Run against the real bash: `gap_rows_parse` (fixtures + edge file, cell text exact), `count_open_contra`,
`_read_focuses_tok_uncached`, and the `--sync-state` derivations `deferred_open` and `covered_blocks`. Not
differentially run (embedded in large scripts with no observable per-cell output): focus-partition-audit,
migrate-backlogs, verify-sources, outline_rows; they are covered by the golden dumps of their fixtures and by the
semantics table above.
