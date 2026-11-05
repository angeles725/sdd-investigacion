### kit-size-check (#2214)

| Tool | Description |
|---|---|
| `rsdd maint size-check` (shim `maint/kit-size-check.sh`) | Go port of the pre-RDD size guard (kit issue #2212, Go port of the maint batch), package `rsdd/internal/maint/sizecheck` (args, numstat, classify, hotspots, split, report, json: one responsibility each). Pinned by a differential test against the frozen legacy script under `internal/maint/sizecheck/testdata/legacy` (stdout, stderr and exit code over every state, flag and edge of the suite) and by `tests/kit-size-check.test.sh` against the shim. Registered `PlainExit3`: exit 3 is a verdict (`refuse`, or `over-budget` under `--strict`), not a degraded state. |

Intended divergences from the bash tool (each pinned by a Go test; everything else is byte-identical):

| Divergence | Why |
|---|---|
| awk and mktemp are no longer dependencies: a PATH without awk is not a degraded state (`TestAwkAndMktempAreNoLongerDependencies`) | the hotspot reader and the numstat buffer are Go now |
| a numstat count that is neither digits nor `-` is a typed degraded state (`malformed numstat record for <path>`) | the bash did arithmetic on the text |
| git runs as `git -C <cwd>` | no process-wide working directory |
| control characters are the bytes below space and DEL | the C locale the legacy tests run in; a UTF-8 `[[:cntrl:]]` also matched U+0080..U+009F |
| a degraded exit is 2 with `degraded: kit-size-check: <why>` on stderr, as before | unchanged: listed so the contract (never a zero) is stated next to the divergences |
