### merge-gate

- `merge-gate: refuse: <verdict> (head=<sha>) — CI for this exact head must be green before merging` (`rsdd gate merge --merge`, kit issue #1426; `merge-gate.sh` is a shim over it). The CI `<verdict>` is one of `ci_failed (names)`, `ci_pending (names)`, `ci_skipped (names)` and `ci_missing (names)`, in that precedence. `ci_skipped` is new in phase 8 slice 8.0 and a declared divergence from the frozen bash original, which allowed it: a REQUIRED check whose latest run concluded `skipped` or `neutral`. Exit 1 (refuse), like the other three.

  | state | exit | continuation |
  |---|---|---|
  | `ci_skipped` | 1 | a required check did not run to success: find why the job was skipped (its `if:`, an upstream job) and re-run it; do not remove the name from `--required-checks` to get past it unless the check is genuinely not required for this PR |
