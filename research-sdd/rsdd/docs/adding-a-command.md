# Adding a command to rsdd

Adding a command = one file in its domain package + one registry line + one golden case directory.
`archtest` enforces the layering that keeps this true.

## 1. Write the command

Put the logic in its domain package, `internal/<domain>/`, and expose it as a function with the
**Main contract**:

```go
func Run(args []string, s cli.Stdio) int
```

- Read input only through `s` (`s.In`, `s.Env("KEY")`, `s.Clock()`, `s.Cwd`); write only to `s.Out` / `s.Err`.
  Never call `os.Getenv`, `time.Now`, `os.Getwd` or touch `os.Stdout` in a package: only `cli.OSStdio()` does.
  That is what makes every test hermetic and parallel.
- Parse flags with the stdlib `flag` package (`flag.NewFlagSet`, output set to `s.Err`). No CLI framework.
- Return an exit code from the contract in `research-sdd/toolbelt/json-envelope.v1.md`:

| Code | Constant | Meaning |
|---|---|---|
| 0 | `cli.ExitOK` | any state except degraded; findings are advisory and never change the code (CLAUDE.md section 8) |
| 1 | `cli.ExitOperational` | operational failure (unreadable input, internal error) |
| 2 | `cli.ExitUsage` | usage error: unknown command, bad flags, no arguments |
| 3 | `cli.ExitDegraded` | degraded (a runtime dependency is missing): print a `DEGRADED:` line on stderr and a valid envelope on stdout; `cli.Run` appends a generic `DEGRADED:` line if you forgot |

A legacy instrument whose contract differs (e.g. `verify-state`: 1 = stale; `status`: 1 = no token)
declares a per-command mapping in its table entry. `Run` returns its own code and `ExitMap`
translates it to the process exit code; codes absent from the map pass through:

```go
{Name: "state", Group: "verify", Summary: "...", Run: verifystate.Run,
	ExitMap: map[int]int{verifystate.Stale: 1}},
```

Stdout of a command is buffered and written only when it returns. A panic is recovered, the buffered
stdout is **discarded** (a partial report must not look complete), and the process exits 1 with the
typed stderr line `rsdd: internal-error: <panic value>` - an operational failure, not a degraded state,
and never a stack trace. The consequence for streaming: a command's stdout appears when it finishes;
progress belongs on stderr, which is written through immediately.

Distinguish absent-input / empty-input / no-match / degraded (CLAUDE.md section 7); a bare `0`
that could mean any of them is a bug.

## 2. Register it

Add the entry to **your own domain's** `Commands` var, in `internal/<domain>/commands.go`
(every domain from plan section 4.3 has a stub: `verify`, `sweep`, `hook`, `gate`, `status`, `corpus`, ...):

```go
var Commands = []cli.Command{
	{Name: "block", Group: "verify", Summary: "verify a block", Run: Run},
}
```

Never edit `internal/commands/commands.go`: it concatenates `version` plus every domain's `Commands` into
`Table`, and refuses the table (a start-up panic, plus a test) on a duplicate `(group, name)` across domains
or a group that shares a name with an ungrouped command. `internal/commands` is the only package allowed to
import domains. `rsdd --help` and `rsdd <group> --help` are generated from the table; there is no other
place to list a command. `Group` may be empty for a top-level command (`rsdd version`).

## 3. Golden case

Create `testdata/golden/<case>/` next to the package test that calls
`golden.Run(t, "testdata/golden", commands.Main)`. A case holds exactly:

| File | Content |
|---|---|
| `cmd.json` | `{"args":["verify","block"],"env":{"KEY":"v"}}` (`env` optional) |
| `stdin` | bytes fed to `s.In` (may be empty) |
| `stdout`, `stderr` | expected output, byte for byte |
| `exit` | expected exit code |
| `intended.json` | `[]`, or `[{"field":"stdout","reason":"..."}]` - one entry per deliberate divergence from the legacy script, `field` in `stdout\|stderr\|exit`, `reason` never blank |

Clock, cwd (`/work`) and env are fixed by the kit. A case missing any file, or a golden directory with
no cases, FAILS (it is never skipped). Create the case with empty expectation files, run
`go test ./internal/commands -update`, **read the diff**, then rerun without `-update`.

## 4. Respect the import rule

`internal/testkit/archtest` fails the build when layering is broken:

- core tier (`cli`, `core/...`, `testkit/...`) imports only other core-tier packages;
- `commands` (the registry) may import any domain;
- a domain package (`internal/<domain>/...`) imports only the core tier - never another domain, never `commands`.

Shared logic two domains need belongs in `internal/core/<name>`.

Packages also never read ambient state: `os.Getenv`, `os.LookupEnv`, `os.Getwd` and `time.Now` are
forbidden outside `internal/cli/stdio.go` (test files excepted), and `cmd/` is scanned too. Take them
from `cli.Stdio`. `cli.Validate` (run on every dispatch, and by a test on the shipped table) rejects a
duplicate `(group, name)`, a group that shares a name with an ungrouped command, an empty name and a nil
`Run`, so nothing is silently shadowed.

## 5. Keep the bash entry point as a shim

Callers (hooks, CI, installed target corpora) invoke `toolbelt/<name>.sh`, so a ported script stays as a
three-line shim until the retirement phase (plan section 4.4):

```bash
#!/usr/bin/env bash
# Ported to Go: `rsdd verify block`. Compatibility shim (removed in phase 8, kit issue <N>).
. "$(dirname "$0")/lib/rsdd-exec.sh" && rsdd_exec verify block "$@"
```

`lib/rsdd-exec.sh` (unit U0.5) resolves `$RSDD_BIN`, then `<kit>/bin/rsdd`, rebuilds when sources are
newer, and emits a typed `degraded: rsdd-unavailable` instead of passing silently when no binary and no Go
toolchain exist. Hook contracts (stdout JSON, exit codes, stderr tokens) are preserved verbatim.

## 6. Gates

From `research-sdd/rsdd`: `make check` (gofmt, vet, tests), `make race`, `make lint` (pinned
staticcheck), `make teeth` (pinned gremlins), `make cross`. `make parity` is a placeholder until the
differential runner lands. The bash gate sees the Go result through
`research-sdd/toolbelt/tests/rsdd-go.test.sh`.

## 7. The source hash

`make build` stamps the binary with a fingerprint of its Go sources, so a stale binary is detectable:
`rsdd version --source-hash` prints `sha256:<hex>` and a newline (`sha256:unknown` when the binary was built
without the stamp, e.g. a plain `go build`). The value comes from `go run ./cmd/rsdd-srchash .` and is linked in
with `-ldflags "-X .../internal/commands.sourceHash=<value>"` (see the Makefile).

The set is every `*.go` except `*_test.go`, `go.mod`/`go.sum` at the root, everything under `vendor/` and under
any `embed/` directory, minus any path with a `testdata` segment; regular files only (symlinks are neither
hashed nor followed), judged on paths relative to the root. A path containing a newline or NUL, or an empty
set, is a hard error. The exact manifest format and an independent shell pipeline that reproduces the value
for the test fixture are in `internal/commands/testdata/source-hash/README.md`. Adding a command file changes
the hash by design; no registration is needed.
