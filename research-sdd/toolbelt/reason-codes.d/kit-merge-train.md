### kit-merge-train

- `kit-merge-train: <state>` (maint/kit-merge-train.sh, kit issue #2213): one gate on a combined local train head,
  then an ordered merge. It reuses `merged` 0, `usage` 2, `degraded` 3, `fetch-failed` 21 and `gate-lock-timeout` 22
  from the table above and relays `ci-failed` 17, `merge-degraded` 18 and `not-merged` 19 from `kit-wait-merge.sh`
  (the PRs after the one that stopped the train are `pending` in the receipt). Per-PR lines `train-refused #N:
  <reason>` (`not-open`, `draft`, `rdd-unconfirmed`, `rdd-head-mismatch`, `head-moved`, `gh-view-failed`) and
  `train-conflict #N` drop that PR and are not exits. `tests/kit-merge-train.test.sh` pins them.

  | state | exit | continuation |
  |---|---|---|
  | `train-gate-failed` | 26 | read the printed gate log; re-run with `--bisect` to name the first PR whose inclusion turns it red; nothing was merged |
  | `train-partial` | 27 | everything left in the train merged; fix the refused / conflicting PRs listed in the receipt and train them again |
  | `train-empty` | 28 | no PR survived the checks and merges; read the `train-refused` / `train-conflict` lines |
  | `train-error` | 29 | read the git or gate error above (not a conflict, or the run was interrupted), fix by hand, then re-run |
  | `base-moved` | 30 | the base branch moved during the gate; nothing was merged; re-run the train on the new base |
  | `main-raced` | 31 | a commit landed on the base between two merges (the merged PRs are `merged` in the receipt, the rest `pending`); inspect main, then re-train the rest |
  | `tree-mismatch` | 32 | the tree on the base differs from the train tree (or the base+merged-prefix tree); inspect main before anything else is merged |
  | `merged-out-of-band` | 33 | GitHub shows the PR MERGED at a head other than the gated one (`kit-wait-merge.sh --expect-head`); inspect it, the train stopped and the PR is `out-of-band` in the receipt |

  Also: `pr-cwd-mismatch` (a per-PR refusal: the `--pr-cwd` directory is not a worktree of the repo, or its HEAD is not the
  pinned head); without `--pr-cwd`, merge-gate in the train's own worktree typically stops the train at `not-merged`
  with `refuse: review_due`, because RDD authority is bound to the worktree where the review ran;
  `base-not-<branch>` (a per-PR refusal: the PR does not target the train's base branch, e.g. a stacked PR) and
  `bisect-incomplete: gate-lock-timeout` (a `train-gate-failed` whose `--bisect` could not finish; the receipt keeps the
  full gate's rc and log).
