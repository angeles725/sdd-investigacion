### kit-pr-pipeline

- `kit-pr-pipeline: <state>` (maint/kit-pr-pipeline.sh, kit-gate.sh, kit-wait-merge.sh, kit issue #2212): the PR
  pipeline ends in one typed state, each with its own exit code and exactly one continuation. It relays the RDD
  states in `reason-codes.d/kit-rdd.md` (`rdd-not-approved` 13, `rdd-start-error` 14, `consent-required` 15, `degraded` 3).
  `tests/kit-pr-pipeline.test.sh` pins them; `maint/` is not a scanned directory, so they are listed here and not
  as table rows.

  | state | exit | continuation |
  |---|---|---|
  | `merged` | 0 | nothing to repair |
  | `restack-conflict` | 11 | resolve the conflict with the base by hand (the merge was aborted), then re-run |
  | `push-failed` | 12 | check network and credentials, then re-run |
  | `fetch-failed` | 21 | check network and the remote name, then re-run |
  | `bad-base-ref` | 23 | fix `--base-ref` / `--remote` (the base does not resolve), then re-run |
  | `dirty-tree` | 24 | commit or stash the tracked changes, then re-run |
  | `restack-error` | 25 | read the git error above (the merge failed without a conflict), fix by hand, then re-run |
  | `gate-failed` | 16 | read `<state-dir>/gate-pr<N>.log`, fix, then re-run (`--serial` for the section 5 reference run) |
  | `gate-lock-timeout` | 22 | another gate holds the lock; re-run when it finishes, or raise `--lock-timeout` on `kit-gate.sh` |
  | `ci-failed` | 17 | read the printed failing check, fix, push, then re-run |
  | `merge-degraded` | 18 | fix the failure merge-gate printed (`merge-gate: degraded: ...`), then re-run `kit-wait-merge.sh` |
  | `not-merged` | 19 | read the printed merge-gate refusal, then re-run |
  | `size-check-failed` | 20 | fix what the `--size-check` command reported, then re-run |
