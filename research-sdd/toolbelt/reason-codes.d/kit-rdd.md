### kit-rdd

- `kit-rdd-start: <state>` / `kit-rdd-drive: <state>` (maint/kit-rdd-start.py, maint/kit-rdd-drive.py, kit issue
  #2212): the RDD drivers end in one typed state, each with its own exit code and exactly one continuation.
  `maint/` is not a scanned directory, so these are listed here and not as table rows;
  `tests/kit-rdd-start.test.sh` and `tests/kit-rdd-drive.test.sh` pin them. The one `degraded:` line they print,
  `degraded: missing runtime dependency: gentle-ai`, is probed at startup (exit 3). The reason codes after
  `rdd-stop:` are the provider's own, printed only when the provider supplied them.

  | state | exit | continuation |
  |---|---|---|
  | `started` | 0 | nothing to repair; run `kit-rdd-drive.py` on the output file |
  | `rdd-not-due` | 10 | nothing to repair (assess exited 0 and said review_due is false) |
  | `rdd-start-error` | 14 | run `gentle-ai review assess --cwd <worktree> --json` by hand, fix the cause (failed assessment, malformed or refused provider answer), then re-run |
  | `consent-required` | 15 | read the printed consent envelope, then re-run `kit-rdd-start.py` with `--consent granted` to record the standing grant |
  | `rdd-not-approved` | 13 | read the printed `rdd-stop: <reason_code>` (or `non-capture-collect (<op>)`); recover by hand, there is no automatic recovery, then re-run |
  | `rdd-protocol-error` | 14 | the provider answered with a shape the driver does not accept (detail printed); check the gentle-ai version, then re-run |
