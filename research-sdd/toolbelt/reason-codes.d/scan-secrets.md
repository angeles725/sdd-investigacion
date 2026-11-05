### scan-secrets

- `DEGRADED: <reason>` (scan-secrets.sh, now `rsdd secrets scan`, engine `internal/core/secretscan`): printed on stderr with
  exit 3 whenever the scan could not look at everything it was asked to, never a clean verdict. States: `--committed` without
  `git` (`git not found`), a target that is not a repository, has no commits, or is a subdirectory of its repository; a
  non-empty `.git/info/grafts` or a set `GIT_GRAFT_FILE` (the history would differ from what a push sends); a failed or malformed
  `rev-list | diff-tree` enumeration, a `cat-file` that cannot read an object, a missing commit object; `--files-from` with an
  empty list or an entry that is outside the target, has a `.`, `..` or empty component, is gone, is unreadable or is reached
  through a symlinked directory; a walk that hits an unreadable directory or file (`grep read error`). An absent list, a
  missing value and every other bad argument are exit 2 (usage), not degraded. Absent-input, empty-input and no-match stay
  distinct: an empty list is degraded, a list whose entries are all out of scope is a typed no-match (`file set: N listed · 0 in
  scope`, exit 0), and a clean corpus says `clean IN SCOPE`. Continuation: install `git`, pass the repository root, remove the
  graft, or fix the named path, then re-run.
