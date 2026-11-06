### consumers

- `consumers: absent-input: no file under research-sdd/toolbelt/, research-sdd/templates/ or research-sdd/install/ in <repository>` (`rsdd maint consumers`, package
  `internal/maint/consumers`, issue #2758): the repository has no file under any of the three script directories, so a list of
  scripts could not even start; exit 1, nothing on stdout. Continuation: run it in a repository that holds the kit, or pass `--repo`.
- `consumers: empty-input: <N> files under the three directories, none is a live script (excluded from the script list: ...)` (same tool): the directories
  hold files and none is a live script (no script extension, or all removed by an exclusion, whose counts the line prints); exit 1,
  nothing on stdout. It is not a report of zero consumers. Continuation: read the exclusion counts, then fix the tree or the exclusions.
- `DEGRADED: git is not installed; nothing was counted` and `DEGRADED: <dir> is not inside a git work tree; nothing was counted` (same tool): the file list
  could not be read, so no count is printed; exit 3, stdout `consumers: degraded`. Continuation: install git, or point `--repo` at a work tree.
- `consumers: absent-input: --repo <dir> is not a directory (missing, a file, or unreachable)` (same tool): the directory named by `--repo` cannot be
  entered; exit 1, nothing on stdout. Continuation: fix the path.
- `DEGRADED: git ls-files wrote to stderr, so the file list may be incomplete: <first line> (and <N> more stderr lines); nothing was counted` (same tool):
  git listed the files, exited 0 and still wrote on stderr (an unreadable directory under `--others` is the known case), so files may be missing;
  exit 3, stdout `consumers: degraded`, no `files:` or `scripts:` line. Continuation: read git's line, fix the cause (permissions), run again.
- `consumers: error: git ls-files failed (exit code <N>) in <repository>` (same tool): git ran and failed; exit 1.
- `consumers: error: git <rev-parse|ls-files> timed out after <duration> in <dir>`, `consumers: error: git <rev-parse|ls-files> produced more than <N> bytes of output in <dir>`
  and `consumers: error: git <rev-parse|ls-files> could not run: <why> (in <dir>)` (same tool): a git child that was stopped by its time bound, by its
  output cap, or that could not be started; exit 1, nothing on stdout. Never read as a zero.
