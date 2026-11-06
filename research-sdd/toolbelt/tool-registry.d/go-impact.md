### go-impact (#2613)

| Tool | Description |
|---|---|
| `rsdd maint go-impact [--repo DIR] [--wide N] FILE...` (no shim; called by `suite-impact.sh` in a later change) | Maps changed repo-relative files to the toolbelt bash files that reach the rsdd commands built from them. Package `rsdd/internal/maint/goimpact` (module, parse, closure, bashlex, bashscan, bashtree, classify, paths, exempt, run: one responsibility each). Parses `DIR/research-sdd/rsdd` with `go/parser` only (no `go list`, no build, no generated manifest) and the bash tree with a small quote-aware lexer. One block per FILE in input order, tab-separated: `NONE FILE go-test-only`, `SHIM FILE BASH GROUP NAME` (one per reaching bash file) closed by `CLOSURE FILE PACKAGES COMMANDS`, or `FULL FILE REASON`. Exit 0 when classification ran, 2 on a usage error or an unreadable module (`degraded: go-impact: <reason>` on stderr); an empty result for a non-empty input is never printed. |

How it decides (fail closed: whatever it cannot place is `FULL` with a typed reason):

| Input | Output |
|---|---|
| `*_test.go`, a file under `testdata/`, or a non-test file whose package no command imports (only test importers, e.g. `internal/testkit/*`) | `NONE ... go-test-only` |
| testdata whose module path (or `testdata/...` tail) a bash file names | `FULL ... testdata named by bash: <script>` |
| `go.mod`, `go.sum`, `Makefile`, `teeth-debt.txt` (the bridge suite reads it), `cmd/**`, `internal/cli/**`, `internal/commands/**` | `FULL` with the path class as reason |
| any other non-Go file of the module (e.g. an embedded `help.txt`) | `FULL ... unclassified module file`: a non-Go file is never a member of its package |
| any path outside `research-sdd/rsdd/` | `FULL ... outside the rsdd module` |
| a package file whose closure holds commands none of which has a bash caller | `UNREACHED FILE GROUP NAME` per command, then `NONE FILE no-bash-caller` and `CLOSURE` (no toolbelt suite can reach it; the Go jobs gate it; distinct from `go-test-only`) |
| a package file | reverse import closure over non-test edges, the commands defined in it (`cli.Command` literals with constant `Group` and `Name`), then the bash files that call them: `SHIM` per caller, plus one informational `UNREACHED FILE GROUP NAME` per command with no caller |
| a bash file that names `RSDD_BIN` in code without resolving any call (a Go blind spot, C9), a parse error, an unresolved command literal, an unclassifiable bash caller, or a closure of more than `--wide` (default 12) distinct bash files | `FULL` with the reason; the size is in the reason and in the `CLOSURE` line |

Recognised ways bash reaches a command (real-tree survey; the enumerator test fails when a form goes unseen): `rsdd_exec <group> <name>`, `rsdd_exec_hook <kind> <group> <name>`, `"$RSDD_BIN" <group> <name>` (also `${RSDD_BIN}`), `"$RSDD_REAL_BIN" <group> <name>`, and a literal `rsdd <group> <name>` (or `.../bin/rsdd`; recognised and unit-tested, unused by any script today). Only words in command position count. Scope: every `*.sh` and extensionless shebang file under `research-sdd/` outside the `rsdd/` module (its scripts are frozen fixtures). A suite that calls the binary directly is a caller exactly like a shim. A file that names `RSDD_BIN`/`RSDD_REAL_BIN` in code (not a comment) yet resolves no call is unclassifiable (`names RSDD_BIN outside a recognised call form`); the exact list is `internal/maint/goimpact/testdata/unclassifiable.txt` and the real-tree test fails when it drifts. Deliberately, testdata -> `go-test-only` drops today's basename edges from module testdata to live scripts.

Pinned by (`internal/maint/goimpact`): `TestParserMatchesAssembledRegistry` (the commands recovered from `cli.Command` literals equal the commands of `internal/commands.Table`), `TestBashEnumeratorMatchesRegistryOnTheRealTree` (every bash file that execs rsdd resolves to a recovered command, or is on the declared exemption list `exempt.go`; a stale exemption fails), synthetic-module unit tests for every classification and every list edge, and a real-tree smoke test (`retro stage-issues` reaches `toolbelt/stage-retro-issues.sh`).

Declared exemption (`exempt.go`): `toolbelt/tests/rsdd-exec.test.sh` writes generic `rsdd_exec "$@"` shim templates into a fixture kit and runs them against stub binaries; its unresolved forms do not make a Go change `FULL`, because the commands it really reaches are named explicitly in the same file. The traced-run check (static reach must contain traced reach) is what proves that exemption hides no edge.

Known limits (each fails closed or over-selects, never under-selects silently): the `version` command lives in the registry package, which is in every closure, so it is attributed to no file change; the freshness hash that `rsdd_exec` compares changes with every non-test Go file, which this tool does not model.
