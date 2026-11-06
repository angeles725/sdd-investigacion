### consumers

- `consumers: absent-input: no file under research-sdd/toolbelt/, research-sdd/templates/ or research-sdd/install/ in <repository>` (`rsdd maint consumers`, package
  `internal/maint/consumers`, issue #2758): the repository has no file under any of the three script directories, so a list of
  scripts could not even start; exit 1, nothing on stdout. Continuation: run it in a repository that holds the kit, or pass `--repo`.
- `consumers: empty-input: <N> files under the three directories, none is a live script (excluded from the script list: ...)` (same tool): the directories
  hold files and none is a live script (no script extension, or all removed by an exclusion, whose counts the line prints); exit 1,
  nothing on stdout. It is not a report of zero consumers. Continuation: read the exclusion counts, then fix the tree or the exclusions.
- `DEGRADED: git is not installed; nothing was counted` and `DEGRADED: <dir> is not inside a git work tree; nothing was counted` (same tool): the file list
  could not be read, so no count is printed; exit 3, stdout `consumers: degraded`. Continuation: install git, or point `--repo` at a work tree.
- `consumers: error: git ls-files failed (exit code <N>) in <repository>` (same tool): git ran and failed; exit 1. A file git lists that cannot
  be read is also an error (exit 1, one `consumers: error: cannot read <path>: <why>` line per file), never a zero.
