### clean-check (kit #1277, the NO-GARBAGE rule)

| Tool | Description |
|---|---|
| `rsdd hygiene clean-check [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]` | Go port of `clean-check.sh` (epic #2270); the row `clean-check.sh [--target DIR] ...` above and `clean-check.v1.md` still describe the finding classes, the retention WARNs, the typed lines, the summary line and the exit contract (0 clean, 1 findings, 2 refused input or failed scan, 3 degraded), and `clean-check.sh` is now a compatibility shim over it, so `research-sdd-status.sh --next` and every other caller run unchanged. Read-only: it runs only `git`, and only to read. The engine is `internal/core/cleancheck` (core tier, so `internal/status/show` can call it in process); the command line, which only parses flags, calls the engine and writes its lines, is `internal/hygiene/cleancheck`. The only runtime dependency is `git` (the script also needed find, sort, date, id and stat). |

The in-process entry point is `cleancheck.Check(ctx, Options) Result` (package `internal/core/cleancheck`). `Options` carries what the flags
and the environment said (target, tmp, scratchpad, base, evidence, stale hours, backup days, the owner uid) and the three ambient
inputs a process would otherwise read: the working directory (`Cwd`, required and absolute), the environment (`Env`) and the clock
(`Now`, required). A field left at its zero value is "not given", exactly as the flag absent from `clean-check --target X`. There is ONE
layer for the environment: whenever `Tmp`, `Scratchpad` or `UID` is empty, `Check` reads `TMPDIR`, `CLEAN_CHECK_SCRATCHPAD` and
`CLEAN_CHECK_UID` from `Options.Env` (an explicit field wins; an empty variable is "not given"), and the command passes its whole
environment and reads none of them itself, so the same environment gives the same `Result` through the command and through a bare
`Check` call (`TestBareCheckBehavesLikeTheBareCommand`). The two ages are `cleancheck.Age` values: unset means the defaults (24 h and 14 d,
declared once in the engine), `cleancheck.AgeOf(0)` is the explicit `0` the script accepted (every owned `tmp.*` entry, every matching
backup is already stale). The only reads from the process are the owner uid (`os.Getuid`, only when `UID`, `CLEAN_CHECK_UID` and `Self` are all
empty), the file system and the `git` children (whose whole environment is `Options.Env` without the repository selectors `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, and with `GIT_OPTIONAL_LOCKS=0`, so no call refreshes an index in the target). The context bounds the run: cancellation or a deadline
stops the walks at the next entry and a running git is stopped when the context has a deadline (its timeout is cut to it, process
group included); a context that can only be cancelled ends the wait at once but cannot stop the child (`core/proc` has no cancel), which then
ends at its own ten-minute ceiling. The `Result` is typed: `Verdict` (`Clean`, `Findings`, `Refused`, `Degraded`, `TimedOut`), `Exit` (0, 1, 2,
3, and 124 for `TimedOut`), `Lines` (every line the script printed,
each tagged stdout or stderr, in print order; `Stdout()`, `Stderr()` and `Merged()` render them), `Findings` and `Warnings` counts,
`Absent` (one `{Kind, What}` per input that was not there: `ABSENT-KEEPLIST`, `ABSENT-SCRATCHPAD`, `ABSENT-BASE`, `ABSENT-EVIDENCE`),
`Degraded` (one kind per check that could not run: `git`, `DEGRADED-WORKTREE-SCAN`, `DEGRADED-BRANCH-SCAN`, `DEGRADED-EVIDENCE-SCAN`,
`DEGRADED-STALE-TMP-OWNERSHIP`) and the final `Summary` line (empty when the run stopped before one: a refused run, git missing, a timed-out
run). `TimedOut` is the whole answer of a run the context ended: one stderr line (`clean-check: ERROR: timed out: <context error>; ...`),
no findings, no typed kinds, no summary, never a clean or a partial list. Absent-input, empty-input, no-match, degraded and timed-out stay
different values, as the contract requires.

Intended divergences from the retired script (each pinned by a declared scenario of the differential in
`internal/core/cleancheck/scenarios_*_test.go` and its goldens, or by a unit test, and each makes a state more explicit or removes a
dependency):

- **An explicit empty value is refused.** `--target ''`, `--tmp ''`, `--scratchpad ''`, `--base ''` and `--evidence ''` are exit 2
  (`clean-check: ERROR: --target needs a non-empty value`, after the usage line). The script read an empty value as "not given" and
  quietly scanned the working directory, the default tmp, the environment's scratchpad, no base or every `_evidence` directory.
  Pinned by `TestParseRefuses` and `TestRunRefusesAnEmptyValue`. An unset `CLEAN_CHECK_SCRATCHPAD` or `CLEAN_CHECK_UID` is still "not
  given".
- **Only `git` is a dependency.** `REQUIRED_TOOLS` was `git find date sort id stat`; the walks, the sort, the clock, the uid and the
  mtimes are Go now, so a PATH holding only git works (`TestOnlyGitIsADependency`). A missing git is still exit 3 with the same
  stderr line and no summary (scenario `degraded-git-missing`). `DEGRADED-NO-SHA256` no longer exists: the hash is computed in
  process, so a missing `sha256sum` or `shasum` can never skip the preserved-copy check.
- **No bash helper is loaded.** The SCRIPTS-MANIFEST rows are read by the Go port of `lib/scripts-manifest.sh`
  (`core/kit.ScriptsManifestRows`), so "cannot find helper lib/scripts-manifest.sh" (exit 2) cannot happen. A manifest that cannot be
  parsed is still `clean-check: ERROR: cannot parse manifest <path>` and exit 2, without the helper's extra `scripts-manifest:` line
  (`TestUnreadableManifestAndProbesRefuse`).
- **Bytewise order.** Every sorted list (stale `tmp.*` entries, scratchpad files, stale backups, discovered `_evidence` directories) is
  sorted bytewise, the C locale: the script's `sort -z` followed the caller's locale, and its `_evidence` discovery printed in
  readdir order, which differs between filesystems and hosts. The differential runs the script under `LC_ALL=C` and compares the one
  scenario whose legacy order is the filesystem's (`evidence-discovered-below-the-target`) as a set of lines; its golden pins the
  engine's sorted order.
- **A script named with a newline is not "manifested".** `grep -qxF` read such a basename as several patterns and matched the
  manifest's name on one of them; the Go lookup is an exact set membership (`TestNewlineNamedScriptIsNotManifested`).
- **A symlinked `--evidence` directory is read through.** GNU find does not follow a command-line symlink, so the script reported
  `0 dir(s) scanned` for it, a quiet zero; the paths are still printed under the name that was given
  (`TestSymlinkedEvidenceDirIsReadThrough`).
- **A scratchpad of `/` is configured.** The script cut one trailing slash, was left with an empty string and reported
  `scratchpad: not set` (`TestSettleScratchpad`, `TestRootScratchpadIsConfigured`).
- **The keep-list glob is a Go matcher.** `[[ path == glob ]]` is reimplemented (`*` and `?` match `/`, bracket expressions with `!`/`^`,
  ranges and the POSIX classes, backslash quoting, an unterminated `[` literal), checked case by case against bash 5
  (`TestGlobMatch`). Characters are runes, so `?` is one UTF-8 character in any locale; an unknown class such as `[[:nope:]]`
  matches nothing, as in bash. One rule differs from bash on purpose: an unterminated `[` is literal text in EVERY shape, and
  `[[:]` is the set of `[` and `:`. Bash answers no-match when the unterminated bracket ends in a range dash (`[a-`, `[!a-`) or in a
  lone backslash (`[\`, `[a\`, `[]\`), even against the identical string, and for `[[:]` against `[`; the matcher answers match
  (`TestGlobMatchUnterminatedBracketIsLiteral` lists both answers per case). A keep-list line of that shape keeps the path it names.
  Extglob operators are literal text in the Go matcher: `@(one|two).txt` keeps the file named `@(one|two).txt` and nothing else, whereas
  bash honours `?(...)`, `*(...)`, `+(...)`, `@(...)` and `!(...)` inside `[[ ]]` even though the script never enabled `extglob`, so the script
  kept `one.txt` and `two.txt` with that line (found by the differential: scenario `keeplist-extglob-operators-are-literal`, table cases in
  `TestGlobMatch`). A keep-list that relied on them must spell the alternatives as separate lines.
- **Diagnostics of the walks are Go's, in the same shape.** An unreadable directory prints `find: '<path>': Permission denied`, an
  unreadable block `grep: <path>: Permission denied`; any other error text is Go's. Git's own stderr (an unreadable directory under
  `ls-files`) is forwarded exactly as before.
- **Bounded children.** Every git run has a ten-minute ceiling and a 64 MiB output cap; the script had neither.
- **Hashing is streamed.** The script's `sha256sum < file` read any size in constant memory; the engine does the same
  (`io.Copy` into a hash), pinned by `TestFileSumStreamsLargeFiles`.
- **A git listing cut at the output cap is a refused scan** (`git ls-files failed or was truncated ...`, exit 2), the
  guarantee the script's RC marker gave; pinned by `TestOutputCapIsNotACompleteListing`.
- **One probes walk, one message.** The script walked `sources/probes` twice (the manifests, then the preserved copies) and said so with two
  lines, `manifest scan failed under ...` and `probes scan failed ...; preserved copies not evaluated`. The engine reads the manifests and hashes
  the files in ONE walk (`readProbes`), so a failure prints only `clean-check: ERROR: manifest scan failed under <target>/sources/probes;
  UNMANIFESTED-SCRIPT not evaluated` (exit 2) followed by the walker's `find: '<dir>': <reason>` line; a caller that grepped for the second text
  must look for the first. As before, no scratchpad file is judged (neither UNMANIFESTED-SCRIPT nor a preserved copy) and no summary is printed
  (`TestFailedProbesWalkRefusesAndEvaluatesNothing`).
- **A symlinked `sources/probes` is not followed**, as `find <dir> -type f` did not (`TestSymlinkedProbesAreNotFollowed`).
- **A symlinked `sources` is not followed either** (stricter than the script, which followed it): every component between the
  target and `probes` is checked with `lstat`, so a manifest or copy reached through a link, outside or inside the target,
  cannot exempt a scratchpad file (`TestSymlinkedSourcesIsNotFollowed`, `TestSymlinkedSourcesInsideTargetIsNotFollowed`).
- **In-process contract.** Every relative path is resolved against `Options.Cwd` (`TestRelativePathsUseOptionsCwd`);
  a nil `Options.Now` is a typed refusal, never a panic (`TestZeroNowIsATypedRefusal`), and so is an empty
  `Options.Cwd` (`TestEmptyCwdIsATypedRefusal`), a relative one (`.`, `corpus`; `TestRelativeCwdIsATypedRefusal`: it would be
  resolved against the process working directory) and a nil context (`TestNilContextIsATypedRefusal`). The scratchpad, the owner uid
  and the tmp directory all come from `Options.Env` when their field is empty (`TestEnvironmentFeedsTheScratchpad`,
  `TestEnvironmentFeedsTheOwnerUID`); an `Options` literal that sets no age behaves as the bare command line
  (`TestBareCheckBehavesLikeTheBareCommand`, `TestAgeDefaults`).
- **A context ends the run with a typed state.** The script had no deadline of its own (the consumer wrapped it in `timeout 20`);
  `Check(ctx, ...)` returns `TimedOut` (exit 124, one stderr line, nothing else) for a cancelled context or a passed deadline,
  at the next entry of a walk or the next git call, and cuts a running git to the deadline
  (`TestCancelledContextIsTimedOut`, `TestExpiredDeadlineIsTimedOut`, `TestContextEndingMidRunIsTimedOut`,
  `TestDeadlineStopsABlockedGit`, `TestWalkTreeStops`). A context that is cancelled with no deadline ends the wait at once, but
  its running git is left to the ten-minute ceiling until `core/proc` gains a cancel (`TestCancelWithoutDeadlineEndsTheRunPromptly`).
  The command passes a context that never ends, so its behaviour is unchanged.
- **A scratchpad without search permission is a refusal.** `cd -P` failed inside the script's assignment (the shell printed its own
  `cd: ... Permission denied` line) and the scratchpad silently became `not set`, exit 0; the engine keeps the configured
  scratchpad and fails its walk with `find: '<dir>': Permission denied` and `clean-check: ERROR: find failed or was truncated in
  scratchpad <dir>`, exit 2. Pinned by scenario `scratchpad-without-search-permission` (skipped for root).
- **A directory that can be listed but not entered is refused like `cd -P` refused it.** An empty `--tmp` of mode 0444 was read as
  clean by a plain listing; `physical` now also needs the search permission (stat of `dir/.`), so it is `clean-check: ERROR: cannot enter
  tmp dir: <dir>`, exit 2, as the script said, without the shell's own `cd:` line. The same check applies to the target. Pinned by
  scenario `empty-tmp-dir-readable-but-not-searchable` (skipped for root); `TestStaleTmpListingFailureRefuses` now uses a directory
  that can be entered but not listed (mode 0100), the case the listing error is still reachable for.
- **File owners unknown is a typed degraded state.** Where the platform reports no owner of a file (no Unix `Stat_t`, so not Linux
  or macOS) the stale-tmp check cannot tell whose entries are whose; instead of an empty list that reads as "nothing stale" it prints
  `DEGRADED-STALE-TMP-OWNERSHIP the owner of tmp.* entries cannot be determined on this platform; stale-tmp not evaluated`, records
  `DegradedOwnership`, and the run is exit 3 unless a finding wins (`TestUnknownOwnershipDegradesTheStaleTmpCheck`,
  `TestUnknownOwnershipDoesNotHideAFinding`, through the `ownershipKnown` seam, so Linux covers the branch).
- **A vanished entry is left out, on purpose.** An entry that disappears between the listing and its `lstat` is skipped as
  `find -ignore_readdir_race` did; any other `lstat` error ends the listing (`TestListDirLeavesOutAVanishedEntry`,
  `TestListDirFailsOnAnotherInfoError`, through the `readDir` seam).
