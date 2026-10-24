# core/kit: findings and deferred work (U1.4, #2284)

Ported here: `lib/target-paths.sh` (`target_paths_all`, `target_paths_pairs`, `target_name_for_retro`) and
`lib/state-files.sh` (`list_state_files`, `resolve_state_file`). Every function is differentially tested against
the real bash (`testdata/diff-driver.sh`, LC_ALL=C), including over the real `research-sdd/TARGETS.md`.

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

Other parity notes: a symlinked start directory is not descended unless `-H` (`ResolveOptions.FollowDir`);
`--focus <slug>` is a glob in bash (`find -name`), so a slug with `*`, `?` or `[` is a pattern (Go uses `path.Match`);
`target_name_for_retro` compares physical paths (`cd -P`), Go uses `EvalSymlinks`.

## Deferred (stopped at the size rule: the full unit is clearly over about 1,000 lines)

- `lib/block-files.sh`: `block_file_filter [-v] [prefix]` (grep -E status passed through verbatim, prefix interpolated
  unescaped into the ERE: use `regexp.CompilePOSIX`, return grep's 0/1/2), `block_files_nested_worktree_roots`
  (find -H, `.git` file probe with commondir and back-pointer `-ef` checks, rc 2/3, readdir order so compare sorted),
  `block_files_path_in_nested_worktree`.
- `lib/focus-prefix.sh`: `derive_focus_prefix` (note the newline asymmetry: the suffixed form uses `printf '%s'`, the
  FOCUSES.md form uses awk `print`, so a differential must compare through `$(...)`; the table is read with
  `awk -F'|'` on lines that start with `|` at column 0, not `^\s*\|`), `derive_focus_range`, `block_range_filter`,
  `focus_range_stat`/`_scan`, `focus_range_report`, plus `inplace_gap_id` / `inplace_blocked_count`.
- Kit resolution order of `templates/hook-kit-run.sh`: `$RESEARCH_SDD_KIT`, then the `Kit checkout:` / `Kit path:` line
  of `AGENTS.md` under `$GENTLE_PI_AGENT_HOME`, `$PI_CODING_AGENT_DIR`, `~/.gentle-shell/agent`, `~/.pi/agent`, then
  `~/.claude/CLAUDE.md` (backticks stripped, leading `~` expanded), then `$HOME/investigacion/sdd-investigacion/research-sdd`;
  first candidate with a `toolbelt/` directory wins; a set-but-invalid `$RESEARCH_SDD_KIT` is reported before falling
  through; none resolves is a typed `DEGRADED` (exit 1, or fail-closed `ask` for the pkill guard).
