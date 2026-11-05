### scan-secrets (kit-audit #4)

| Tool | Description |
|---|---|
| `rsdd secrets scan [--committed \| --files-from <list\|->] <target-dir>` | Go port of `scan-secrets.sh` (epic #2270); the row `scan-secrets.sh [--committed \| --files-from <list\|->] <target-dir>` above still describes the patterns, the advisory tier and the exit contract (0 clean in scope or advisory only, 1 a high-confidence value leaked, 2 usage, 3 degraded), and `scan-secrets.sh` is now a compatibility shim over it. The engine is `internal/core/secretscan` (core tier, so `rsdd corpus archive` calls it in process; its report is discarded there, only the exit code feeds the gate); the command line is `internal/secretscan`. The only runtime dependency is `git`, and only for `--committed` (the script also needed grep, awk, tr, sort and mktemp). |

Intended divergences from the retired script (each pinned by a declared case of the differential in
`internal/core/secretscan/cases_*_test.go`, or by a unit test, and each makes detection stricter or a state more explicit):

- **Strict parser.** An unknown flag, a repeated flag and a second target are exit 2 with the usage line. `--committed` is
  honoured wherever it appears: the script read it only as the first word, so `scan-secrets.sh dir --committed` silently
  scanned the working tree instead of the history. `-h` / `--help` are unknown arguments (the script treated them as a
  target that is not a directory: same exit 2). `--toolbelt <dir>` is the shim's own directory (its parent is the kit root
  that holds `TARGETS.md`). `--` ends the options.
- **The target is never excluded by its own name.** `grep --exclude-dir` also matched the command-line directory, so a target
  named `cfr`, `jadx`, `venv`, `decompiled`, ... was reported clean while holding a leak.
- **NUL-bearing files are scanned.** `grep -I` skipped such a file whole (reported only as binary-skipped), so a token in it, or in
  a UTF-16/UTF-32 `.env` of the working tree, was missed. The high-confidence rules now run over the raw bytes and the
  NUL-stripped bytes (as committed blobs always were); the advisory tier still skips them and the count line is unchanged.
- **Invalid UTF-8 never hides a match.** A line with a token and a byte that is invalid in the locale is scanned as bytes.
- **Caps are announced.** A rule with more than 50 hits, more than 200 advisory warnings or more than 20 commit-message hits prints a
  `(N more ... not shown: capped at M)` line. The advisory cap now counts printed warnings: the script applied `head -200` to the
  keyword lines BEFORE the placeholder filters, so a credential past the 200th keyword line was never judged.
- **Advisory keywords fold like PCRE caseless UTF mode:** a keyword spelt with U+017F or U+212A (`toKen`) is matched.
- **Locations are exact.** A path with a newline is printed on one line with the newline as `\n` (the script printed an empty
  location and a stray fragment); a committed path with a leading blank keeps it (the `read` loop trimmed it); a hit on a line
  that also holds a NUL is reported once (the raw and the NUL-stripped scan each reported it).
- **Order is C-locale.** History entries are sorted bytewise (the script's `sort -u` followed the caller's locale), a working-tree walk
  reports in path order (the script: directory order), `--files-from` in list order.
- **Corpus-root selection is bytewise.** Default mode narrows to the shallowest directory holding a `*block*.md` file; among equally
  deep candidates the legacy script chose with `sort -k2,2` in the caller's locale, so `b` or `B` won depending on `LC_ALL`. The
  engine picks the bytewise smallest (`B` before `a-` before `a_` before `b`), the same on every machine. Pinned by
  `TestNarrowRootTieBreakIsByteOrder`; the differential runs the legacy script under `LC_ALL=C`.
- **Committed scope is not a copy of the walk scope (no divergence, pinned).** The history scan matches the whole path, as the legacy
  awk did: a `config.`-prefixed directory component puts everything under it in scope (`config.d/x.txt`, `app/config.old/x.txt`),
  while the working-tree walk and `--files-from` test the base name only and so never look inside such a directory (legacy
  behaviour, kept). The history scan excludes only the vendored names, not `.git`: a hand-built tree holding `sub/.git/notes.md` is
  scanned, never skipped. Pinned by the `hist-scope-*`, `scope-wt-*` and `ff-config-*` cases and `TestCommittedScopeMatchesWholePath`.
- **The live-install reminder matches the target name literally** (a name with a regex metacharacter matched other lines), and `.` / `..`
  use the physical directory name.
- **No temporary files, no per-blob processes.** One `git cat-file --batch` streams every unique blob (the script started one `git`
  per blob and wrote temp files), so the mktemp, awk, tr and grep degraded states cannot occur; every other degraded state keeps its
  text. The test that proves it: `TestCommittedScanNeedsOnlyGit`.

Retained, documented gap: the default mode still narrows to the shallowest block directory (pinned by suite case FF1); a
secret outside that subtree is not looked at there. `--files-from` (the archive gate) and `--committed` never narrow.
