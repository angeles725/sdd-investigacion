### reconcile-issues

- `shallow-clone: <dir> is a shallow clone and no cited commit resolved locally for N row(s) (e.g. <sha>)`
  (reconcile-issues.sh, kit issue #1773): printed once per run (single-retro and `--all`) when the closure
  evidence of N rows cites no commit that exists locally and the checkout is shallow, so reachability
  cannot be verified. Those rows stay `borderline`, never `shipped`, and the exit code is unchanged.
  Continuation: run `git fetch --unshallow` (or raise the CI fetch-depth), then re-run `reconcile-issues.sh`.

- `note: state_reason for issue #<n> missing from the closed-issue listing after one reload` (reconcile-issues.sh,
  kit issue #1752): on a gh without the `stateReason` field, a closed issue found by the search is absent from
  the batched `state_reason` listing even after one forced reload of it. Its rows are reported `borderline`
  (the issue's evidence is not trusted) and the run is not failed. Continuation: run
  `gh api repos/<owner>/<repo>/issues/<n> --jq .state_reason` by hand, then re-run `reconcile-issues.sh`.

- `regressed-lookup: <reason>` (reconcile-issues.sh, kit issue #1709 slice 2): the `regressed` check for a `shipped`
  row could not look at something and says so on stderr instead of reporting a silent no-match: the shipped retro or
  a sibling has no `YYYY-MM-DD` filename prefix, or a sibling has the same date (retros cannot be ordered), the row title is under 12 characters or a
  bare priority/type token (no cross-retro identity), or a later retro's review-status marker sits outside the
  leading-block scope (open/closed cannot be told). The run is not failed. Continuation: rename the retro with a date
  prefix, give the row a real title, or move the marker into the leading block, then re-run `reconcile-issues.sh`.
