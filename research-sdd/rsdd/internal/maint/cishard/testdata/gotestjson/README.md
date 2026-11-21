# Recorded `go test -json` streams

Produced on 2026-11-06 by really running `go test` in a throwaway module (`example.com/fx`, `go 1.21` directive), never
written by hand. Toolchain, from `go version`:

    go version go1.27.2 linux/amd64

Command, one invocation per package (`<pkg>.json`) and one for all of them (`all.json`); stdout is the stream, the
exit status is the one `make test` would see (stderr was empty in every run):

    CGO_ENABLED=0 GOFLAGS=-p=2 GOMAXPROCS=2 go test -json -count=1 ./<pkg> > <pkg>.json
    CGO_ENABLED=0 GOFLAGS=-p=2 GOMAXPROCS=2 go test -json -count=1 ./...   > all.json

| file | package | exit | what the stream shows |
|---|---|---|---|
| `buildfail.json` | `b.go`: `func F() int { return undefinedSymbol }` | 1 | `build-output` x2 and `build-fail` carry only `ImportPath` (no `Package`); then `start`, an `output` `FAIL ... [build failed]` and a package-level `fail` with `FailedBuild` |
| `crash.json` | `c_test.go`: `func TestMain(m *testing.M) { os.Exit(3) }` | 1 | no test event; `output` `exit status 3`, then a package-level `fail` |
| `passes.json` | one test that passes | 0 | package-level `pass` |
| `allskip.json` | two tests, each `t.Skip(...)` | 0 | two test-level `skip` events and a package-level `pass` |
| `failing.json` | one test passes, one `t.Fatal` | 1 | a test-level `fail` and a package-level `fail` |
| `all.json` | the five packages together | 1 | all of the above interleaved |

The pinned facts (see `manifest_fixture_test.go`): a build failure and a crashed test binary both end in a
package-level `fail` for their `Package`; a package whose tests all skip ends in a package-level `pass`, which is why the
writer counts test-level skips from the stream itself. Re-record with the commands above after a toolchain change.
