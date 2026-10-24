# core/kit: findings and deferred work (U1.4, #2284)

Ported (slice 1): `lib/target-paths.sh` (`target_paths_all`, `target_paths_pairs`, `target_name_for_retro`) and
`lib/state-files.sh` (`list_state_files`, `resolve_state_file`).
Ported (slice 2): `lib/block-files.sh` (`block_file_filter`, `block_files_nested_worktree_roots`,
`block_files_path_in_nested_worktree`), `lib/focus-prefix.sh` (`derive_focus_prefix`, `derive_focus_range`,
`focus_range_stat` / `focus_range_block_count` via `ScanFocusRange`, `focus_range_report`, `inplace_gap_id`,
`inplace_blocked_count`) and the kit resolution of `templates/hook-kit-run.sh` (`ResolveKitScript`).
Every function is differentially tested against the real bash (`testdata/diff-driver.sh`, LC_ALL=C), including over
the real `research-sdd/TARGETS.md`. `InputReason` maps the typed input states to the reason-codes.v1.md input class.

## Findings (each is pinned by a named test)

| # | Finding | Evidence | Go behaviour |
|---|---|---|---|
| F1 | Row test differs from core/gfm: bash `^\s*\|` counts `\v \f \r` as leading blanks, gfm trims only space and tab. | `TestFindingGfmRowShapeDiffersFromBash` | Bash wins (own predicate `isRowLine`). |
| F2 | `target_paths_all/pairs` on an unreadable (mode 000) file: exit 0, empty list (grep errors are sent to `/dev/null`). A silent zero (CLAUDE.md section 7). | `TestDifferentialFindingUnreadableFileIsASilentZeroInBash` | `ErrUnreadable`. |
| F3 | The libs call plain `sort -u`, so order depends on the caller's locale; only LC_ALL=C is bytewise. Not demonstrable here (only C/C.utf8/POSIX installed); read from the source. | lib/target-paths.sh `sort -u` | Bytewise. Differential runs pin LC_ALL=C. |
| F4 | `target_paths_all` exit code depends on the caller's `pipefail`: its last pipeline (the `$RESEARCH_HOME` form) exits 1 when no row has such a token, though the output is complete. | `TestDifferentialFindingPipefailMakesRCContentDependent` | No rc; errors are typed. |
| F5 | `target_name_for_retro` splits rows on EVERY pipe (`awk -F'|'`); gfm honours `\|`. A `\|` in the name cell shifts the columns and the name falls back to the basename. | `TestFindingNameLookupSplitsOnEscapedPipes`, differential scenario `escaped-pipe-name` | Bash split kept. |
| F6 | `list_state_files` on a directory that does not exist: exit 0, no output, identical to an empty corpus. | `TestDifferentialFindingListStateFilesAbsentDirIsASilentZeroInBash` | `ErrAbsentInput` vs empty list. |
| F7 | `find` has no `-type` filter: a DIRECTORY named `RESEARCH-STATE-x.md` is listed; `-not -path '*/.git/*'` tests the whole printed path, so a corpus that lives under a `.git` directory has every result excluded. | `TestDirectoriesAndGitAncestorQuirks`, `TestDifferentialStateFilesFilesystemQuirks` | Reproduced. |
| F8 | `block_file_filter` interpolates the prefix into a GNU `grep -E` ERE; GNU accepts `\d`, `\w`, a lone `\` or `)` where Go POSIX syntax rejects them. Kit-derived prefixes (`[A-Za-z]…-`) never hit this. | `TestDifferentialFindingPrefixDialectGaps` | `ErrBadPattern` (grep rc 2) for those. |
| F9 | `derive_focus_prefix` / `derive_focus_range` on an unreadable FOCUSES.md: awk complains on stderr and nothing is printed, so callers see "no prefix" / "no range" (rc 2 and 0 respectively, though both document "always returns 0"). | `TestDifferentialFindingUnreadableFocusesIsSilentInBash` | `ErrUnreadable`. |
| F10 | `focus_range_stat` on a missing or unlistable directory counts a confident 0 (find errors go to `/dev/null`); a symlinked directory is not followed (find -P), so it also counts 0 unless the path ends with `/`. | `TestDifferentialFindingRangeStatAbsentDirIsASilentZeroInBash`, `TestDifferentialFocusRangeScanSymlinkedDir` | `ErrAbsentInput` / `ErrUnreadable`; the symlink zero is kept for parity. |

Other parity notes: a symlinked start directory is not descended unless `-H` (`ResolveOptions.FollowDir`);
`--focus <slug>` is a glob in bash (`find -name`), so a slug with `*`, `?` or `[` is a pattern (Go uses `path.Match`);
`target_name_for_retro` compares physical paths (`cd -P`), Go uses `EvalSymlinks`.

Slice 2 parity notes (kept for parity, listed so a later unit can decide):
- `block_files_nested_worktree_roots` prints nested roots in find's readdir order; Go sorts them bytewise (the
  differential compares sorted). Its `-path "$root/.claude/worktrees"` prune is a glob; Go compares the path exactly,
  so a root containing `*`, `?` or `[` prunes differently.
- `focus_range_stat` passes the claims to awk with `-v`, which processes backslash escapes; a FOCUSES.md prefix
  holding a backslash is read differently by bash (not reproduced). A prefix holding a tab is cut at the tab (kept).
- `focus_range_report` sorts the family list with plain `sort` (finding F3); the Go order is bytewise.
- The range numbers are awk doubles; Go keeps float64 and gawk's printing (`+inf` past the range). mawk prints
  differently; the kit's hosts run gawk.
- `derive_focus_prefix` runs its awk in the caller's locale (no `LC_ALL=C`), so `[[:blank:]]` may widen under UTF-8.
- `inplace_blocked_count` reads the rows with `IFS=$'\t' read`: tab runs collapse and an unterminated last row is
  never read (both kept). The `[-–—]` bracket of its sed holds BYTES under LC_ALL=C (kept).
- The kit resolution reads launcher files with `sed` in the caller's locale; Go trims the C-locale `[[:space:]]`. An
  unreadable launcher file is skipped silently in both (resolution then falls through to the next candidate, and
  "nothing resolved" is still the typed DEGRADED failure). `HOME` unset aborts the bash under `set -u`; Go treats it
  as empty.
- `block_file_filter`'s `[ -t 0 ]` interactive-stdin refusal (rc 2) belongs to the CLI boundary: the Go function
  takes lines already read.

## Not ported, by design

- `block_range_filter` (lib/focus-prefix.sh): no production caller (go-port.md section 4.9).
- The pkill-guard `ask` answer and the `exec` of `templates/hook-kit-run.sh`: hook-boundary behaviour for the unit
  that adopts the Go resolver in the shim (the reason text it prints comes from `ResolveKitScript`).
