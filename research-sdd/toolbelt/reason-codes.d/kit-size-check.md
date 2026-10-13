### kit-size-check

- `size: <state>` and `degraded: kit-size-check: <reason>` (maint/kit-size-check.sh, kit issue #2214): the pre-RDD size
  guard prints one verdict line `size: ok|over-budget|refuse|empty-input|all-excluded|unmeasured|degraded`. `empty-input` (the diff
  lists no file), `all-excluded` (files changed, none measured, every one excluded data or binary) and `unmeasured`
  (only binaries and/or pure renames) are the distinct non-measurements: none is a small diff. A hotspot candidate
  whose diff failed prints `hotspot: unchecked <file>`, which is not a clean no-churn. `degraded` (exit 2, reason on stderr: no git or awk, not a work tree, unresolved base or head
  ref, no merge base, mktemp failed, diff failed, malformed rename record, bad flag or value, a control
  character in a path) is never a zero.
  The degraded-code scan above traverses only `toolbelt/*.sh` and `toolbelt/lib/*.sh`, so `maint/` is outside it and these states
  are listed here, not in the degraded table; the INPUT-class scan does traverse `maint/*.sh`, which is why `maint/kit-size-check.sh` is an emitter of the `empty-input` input row.
  Continuation: fix the ref or flag named on stderr and re-run; for `refuse` or
  `over-budget` split the change as the printed suggestion shows, then re-run `kit-size-check.sh`.
