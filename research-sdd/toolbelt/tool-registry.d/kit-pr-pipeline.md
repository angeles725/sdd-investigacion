### kit-pr-pipeline (#2212)

| Tool | Description |
|---|---|
| `rsdd maint pr-pipeline` / `rsdd maint gate` / `rsdd maint wait-merge` (shims `maint/kit-pr-pipeline.sh`, `maint/kit-gate.sh`, `maint/kit-wait-merge.sh`) | Go port of the pipeline and its two standalone steps (kit issue #2212, Go port of the maint batch). Packages `rsdd/internal/maint/{prpipeline,gate,waitmerge}`; the engines of the gate and of the CI wait live once in `rsdd/internal/core/{kitgate,kitwait,kitmaint}` and are shared with `rsdd gate merge-train`, which calls them in process. Every command has its own strict parser (an unknown word is exit 2). Each is pinned by a differential test against the frozen legacy script under `internal/maint/<tool>/testdata/legacy` (stdout, stderr, exit code, the ordered call log and the state directory) and by `tests/kit-pr-pipeline.test.sh` against the shims. |

Intended divergences from the bash tools (each pinned by a Go test; everything else is byte-identical):

| Tool | Divergence | Why |
|---|---|---|
| all four | a degraded exit 3 also writes `DEGRADED: <why>` to stderr | the rsdd process contract: every exit 3 names its reason on stderr |
| all four | stdout appears when the command returns, not line by line | rsdd buffers stdout so a panic never leaves a fragment that reads as a result |
| gate, pipeline | the gate lock is taken in process (`flock(2)` on `<state-dir>/gate.lock`), no `flock` child runs; `flock` stays a probed dependency | one less process to lose a signal in; a held lock is tested for real (`TestGateLockTimeoutIsNotAGateFailure`) |
| gate, pipeline | INT and TERM are forwarded to the gate's process group and the run ends `kit-pr-pipeline: interrupted: #<pr>: the gate was stopped by a signal; CI and merge were not attempted` (the standalone `rsdd maint gate` prints `kit-gate: interrupted: the gate was stopped by a signal`), exit 16 | the bash left the gate command running after the tool died |
| gate | an overflowing `--lock-timeout` is clamped instead of failing; `--cmd ''` runs `:` and passes | the bash handed both to `flock -w` / `bash -c` with undefined results |
| gate, pipeline | git runs as `git -C <worktree>` instead of after a `cd` | no process-wide working directory; the differential tests drop the `-C` from the call log |
| pipeline | python3 is no longer a probed dependency | nothing in the pipeline runs it any more |
| pipeline | a failing `git status` is a typed `restack-error` (25), not an empty (clean) tree | a silent clean read of a failed instrument (CLAUDE.md section 7) |
| pipeline, wait-merge | without `KIT_MERGE_GATE` the merge gate is the rsdd binary's own `gate merge`, not a sibling `merge-gate.sh` | no bash hop; `KIT_MERGE_GATE` still names a script and a missing one is the same typed degraded exit |
| pipeline, wait-merge | a non-numeric `KIT_POLL_MAX`, `KIT_POLL_SLEEP`, `KIT_MERGE_TRIES`, `KIT_MERGE_SLEEP` or `KIT_RETRY_SLEEP` is a usage error (exit 2) naming the knob | the bash printed a shell arithmetic error and either ended the poll early or crashed (`unbound variable`) |
| wait-merge | a relative `<worktree>` is made absolute once | the bash passed the relative path on to the merge gate, which no longer resolved it |
| pipeline | the review output lines (`rdd-drive` tail) are cut at 300 characters, never inside a character | the bash `cut -c1-300` counted bytes and could split a multi-byte character (`TestDriveLinesAreCutAtCharacters`) |
| pipeline, wait-merge | the merge gate is checked up front, as before, and so is the rsdd binary when no `KIT_MERGE_GATE` is set: a binary that cannot be located is the same typed degraded exit, `merge-gate.sh not found: ...` | the bash looked for `merge-gate.sh` next to itself; the default gate is the binary now (`TestMissingMergeGateIsDegradedBeforePolling`, `TestUnknownBinaryIsDegradedBeforePolling`) |
| merge train | none: `rsdd gate merge-train` runs the same engines in process and prints what it printed before the extraction (retry notes with the elided jq expression, no line for a missing bash, a lock timeout too long for an int tried once); each is an option of the shared engine (`HeadReadWords`, `SilentNoBash`, `OverflowTriesOnce`) pinned by `TestMergeTrainWaitRetryNotes`, `TestMergeTrainGateWithoutBashIsSilent`, `TestMergeTrainHugeLockTimeoutTriesOnce` | the extraction must not change the train's observable output |
