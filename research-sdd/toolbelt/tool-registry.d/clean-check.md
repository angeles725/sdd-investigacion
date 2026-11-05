### clean-check (kit #1277, the NO-GARBAGE rule)

| Tool | Description |
|---|---|
| `rsdd hygiene clean-check [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]` | Go port of `clean-check.sh` (epic #2270); the row `clean-check.sh [--target DIR] ...` above and `clean-check.v1.md` still describe the finding classes, the retention WARNs, the typed lines, the summary line and the exit contract (0 clean, 1 findings, 2 refused input or failed scan, 3 degraded), and `clean-check.sh` is now a compatibility shim over it, so `research-sdd-status.sh --next` and every other caller run unchanged. Read-only: it runs only `git`, and only to read. The engine is `internal/core/cleancheck` (core tier, so `internal/status/show` can call it in process); the command line, which only parses flags, calls the engine and writes its lines, is `internal/hygiene/cleancheck`. The only runtime dependency is `git` (the script also needed find, sort, date, id and stat). |

The in-process entry point is `cleancheck.Check(Options) Result` (package `internal/core/cleancheck`). `Options` carries what the flags
and the environment said (target, tmp, scratchpad, base, evidence, stale hours, backup days, the `CLEAN_CHECK_UID` override) and
the three ambient inputs a process would otherwise read: the working directory, the environment (git, `TMPDIR`) and the clock. The
`Result` is typed: `Verdict` (`Clean`, `Findings`, `Refused`, `Degraded`), `Exit` (0, 1, 2, 3), `Lines` (every line the script printed,
each tagged stdout or stderr, in print order; `Stdout()`, `Stderr()` and `Merged()` render them), `Findings` and `Warnings` counts,
`Absent` (one `{Kind, What}` per input that was not there: `ABSENT-KEEPLIST`, `ABSENT-SCRATCHPAD`, `ABSENT-BASE`, `ABSENT-EVIDENCE`),
`Degraded` (one kind per check that could not run: `git`, `DEGRADED-WORKTREE-SCAN`, `DEGRADED-BRANCH-SCAN`, `DEGRADED-EVIDENCE-SCAN`)
and the final `Summary` line (empty when the run stopped before one: a refused run, or git missing). Absent-input, empty-input,
no-match and degraded stay four different values, as the contract requires.

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
  matches nothing, as in bash.
- **Diagnostics of the walks are Go's, in the same shape.** An unreadable directory prints `find: '<path>': Permission denied`, an
  unreadable block `grep: <path>: Permission denied`; any other error text is Go's. Git's own stderr (an unreadable directory under
  `ls-files`) is forwarded exactly as before.
- **Bounded children.** Every git run has a ten-minute ceiling and a 64 MiB output cap; the script had neither.
