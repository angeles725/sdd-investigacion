### clean-check

- `ABSENT-KEEPLIST <path>`, `ABSENT-SCRATCHPAD <path>`, `ABSENT-BASE <reason>`, `ABSENT-EVIDENCE <path>` (clean-check.sh, now `rsdd hygiene clean-check`,
  engine `internal/core/cleancheck`): absent-input lines on stdout. They are information, never a finding, and never change the
  exit code; the summary names the same state (`scratchpad: absent`, `branches: no base`, `evidence: absent`, `keep-list entries: 0`).
  The engine also returns each one as a typed value (`Result.Absent`: kind and what was looked for), so `internal/status/show`
  never parses text to learn that an input was missing. Continuation: create the keep-list or the directory, pass `--base`, or accept
  that the scan was skipped.
- `DEGRADED-WORKTREE-SCAN <reason>`, `DEGRADED-BRANCH-SCAN <reason>`, `DEGRADED-EVIDENCE-SCAN <reason>` (same tool): a retention scan that could
  not run. The run completes, the summary reads `CLEAN-CHECK: degraded (...)` with `degraded: <reasons>`, and the exit is 3 when
  there are no findings (a real finding still wins with 1). `Result.Degraded` carries one kind per scan that failed. A git that is
  not on PATH is the separate `clean-check: DEGRADED: git not found on PATH; nothing was measured` line on stderr (exit 3, no
  summary, `Degraded` holds `git`). `DEGRADED-NO-SHA256` is retired: the preserved-copy hash is computed in process, so no
  environment can skip it. Continuation: install git, fix the permission or the git failure the line names, and re-run.
- `clean-check: ERROR: --<flag> needs a non-empty value` (same tool): exit 2 for an explicit empty `--target`, `--tmp`, `--scratchpad`,
  `--base` or `--evidence`, which the script read as "not given". It is a refused command line, not a degraded state.
