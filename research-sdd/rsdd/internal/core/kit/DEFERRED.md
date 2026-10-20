# core/kit: findings and deferred work (U1.4, #2284)

Ported: `lib/target-paths.sh`, `lib/state-files.sh`, `lib/block-files.sh`, `lib/focus-prefix.sh` (including `inplace_*`)
and the kit-resolution order of `templates/hook-kit-run.sh`. Every function is differentially tested against the
real bash (`testdata/diff-driver.sh`, LC_ALL=C; the driver exits 97 on any harness failure), including over the
real `research-sdd/TARGETS.md`.

## Port rules (#2291)

- **Silent zeros are never replicated.** The only divergences from bash are the two cases listed in
  `testdata/intended.json` (reason "legacy silent zero, #2291"): F2 and F6. `expectSame` enforces: a divergence is
  allowed only for a listed case, a listed case that stops diverging is an error (stale), every other case is
  byte-identical, and an entry no executed case uses is an error.
- **Accidents are named quirks.** F1, F5, F7 live in `Quirks` (`LegacyBash` is the default, `GFMShaped` removes them).
  Each has its own pinned test (`TestQuirkF1RowBlanks`, `TestQuirkF5EscapedPipeInNameCell`,
  `TestQuirkF7FindWithoutTypeFilter`). Measured caller dependency of all three: none (no `\|` in any TARGETS.md
  row, no `\v \f \r`-led row, no directory named `RESEARCH-STATE*.md` under the fleet). Proposal: drop all three and
  make `GFMShaped` the only behaviour once the bash libs are retired.
- **F4 and return codes.** The Go side has no `pipefail`, so `RC(err)` is the function's own contract, never the
  accident of the caller's shell: 0 nil; 1 operational failure (usage, absent or unreadable input, no target
  parsed, wrong `RESEARCH_HOME`, kit degraded); 2 `ErrNoAncestor`, `ErrStateAmbiguous`, `ErrNotDir`; 3
  `ErrStateUsage`, `ErrIncompleteWalk`. Under `pipefail` bash additionally returns 1 from `target_paths_all` whenever
  no row has a `$RESEARCH_HOME` token; Go never does.

## Findings (each is pinned by a named test)

| # | Finding | Evidence | Go behaviour |
|---|---|---|---|
| F1 | Row test differs from core/gfm: bash `^\s*\|` counts `\v \f \r` as leading blanks, gfm trims only space and tab. | `TestQuirkF1RowBlanks`, `TestFindingGfmRowShapeDiffersFromBash` | Named quirk `Quirks.RowBlanks`. |
| F2 | `target_paths_all/pairs` on an unreadable (mode 000) file: exit 0, empty list. A silent zero. | `TestDifferentialIntendedDivergences` | `ErrUnreadable`; intended divergence. |
| F3 | The libs call plain `sort -u` / `sort`, so order depends on the caller's locale; only LC_ALL=C is bytewise. Not demonstrable here (only C/C.utf8/POSIX installed); read from the source. Also `focus_range_report` sorts the family list with a plain `sort`. | lib sources | Bytewise. |
| F4 | `target_paths_all` exit code depends on the caller's `pipefail` (see Port rules). | `TestDifferentialFindingPipefailMakesRCContentDependent` | No pipefail rc. |
| F5 | `target_name_for_retro` splits rows on EVERY pipe (`awk -F'|'`); gfm honours `\|`. | `TestQuirkF5EscapedPipeInNameCell`, differential scenario `escaped-pipe-name` | Named quirk `Quirks.SplitEscapedPipes`. |
| F6 | `list_state_files` on a directory that does not exist: exit 0, no output, identical to an empty corpus. | `TestDifferentialIntendedDivergences` | `ErrAbsentInput`; intended divergence. |
| F7 | `find` has no `-type` filter (a DIRECTORY named `RESEARCH-STATE-x.md` is listed) and `-not -path '*/.git/*'` tests the whole printed path (a corpus under a `.git` directory is excluded). | `TestQuirkF7FindWithoutTypeFilter`, `TestDifferentialStateFilesFilesystemQuirks` | Named quirk `Quirks.FindNoTypeFilter`. |
| F8 | `block_file_filter` interpolates the prefix UNESCAPED into a GNU ERE; Go uses `regexp.CompilePOSIX`, so GNU-only constructs (back-references) are an error (status 2) instead of a match. A bad regex is grep's status 2 on both sides. | `TestBlockFileFilterPrefixAndBadRegex`, `TestDifferentialBlockFileFilter` | Status passed through verbatim. |
| F9 | `inplace_blocked_count` reads rows with `while read`: a final row without a trailing newline is silently dropped (section 7 list edge). | `TestInplaceBlockedCountLastRowWithoutNewline`, `TestDifferentialInplace` (premise check) | Counts it. NOT in intended.json: no differential case feeds an unterminated row to the Go side; the premise test pins the bash bug. |
| F10 | `IFS=$'\t' read -r _ gap st`: tab is IFS whitespace, so an EMPTY priority cell shifts the columns left (gap becomes the status). | differential `ipcount empty-priority-collapse` | Reproduced (`readTab3`). |
| F11 | `focus_range_stat/_scan` on a missing or unreadable directory report counts of 0 (find errors go to /dev/null); `derive_focus_prefix/range` on an unreadable FOCUSES.md print "". | `TestScanRange`, `TestUnreadableFocusesAndScanDirAreTyped` | `ErrAbsentInput` / `ErrUnreadable`, `PrefixUnreadable`, `RangeUnreadable`, Diag `DEGRADED`. Not differentially run, so not in intended.json. |
| F12 | `derive_focus_prefix` ends with `printf '%s'` for `RESEARCH-STATE-<focus>.md` but awk `print` for the FOCUSES.md form: the newline differs. Every consumer calls it through `$(...)`. | driver mode `fprefix` | No newline; the differential compares through `$(...)`. |
| F13 | `block_files_nested_worktree_roots` emits roots in find's readdir order. | `TestDifferentialNestedWorktrees` | Sorted after the always-first `<root>/.claude/worktrees`; the differential sorts the bash side. |
| F14 | A launcher value `~user/x` expands to `$HOME` + `user/x` (`${line/#\~/$HOME}`), not to user's home. | lib source | Same. |

Other parity notes: a symlinked start directory is not descended unless `-H` (`ResolveOptions.FollowDir`);
`--focus <slug>` is a glob in bash (`find -name`), so a slug with `*`, `?` or `[` is a pattern (Go uses `path.Match`);
`target_name_for_retro` compares physical paths (`cd -P`), Go uses `EvalSymlinks`; block numbers beyond int64 are not
supported by `norm`.

## Deferred

- The PreToolUse pkill guard of `hook-kit-run.sh` (fail-CLOSED `permissionDecision: "ask"` JSON when the kit is
  unresolvable and the command mentions pkill/pgrep, built with `jq`, with a fixed fallback string): `ResolveKitScript`
  returns the typed `ErrKitDegraded`; mapping it to the guard's `ask` answer belongs to the hook-runner port, where
  stdin is available.
- Verification still pending a quiet machine: the `-race` run of the package and `FuzzDerive` (the quiet window forbids
  both); see the unit report.
