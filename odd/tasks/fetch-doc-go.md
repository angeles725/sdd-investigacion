# fetch-doc-go: port toolbelt/fetch-doc.sh to `rsdd sources fetch-doc`
Branch feat/fetch-doc-go · delivery: local commits, no push · test runner: go test (default + -tags nodiff), bash suites under toolbelt/tests
Epic #2270 · lane s1 · shim keeps every caller working; verify-sources port (s3) calls internal/core/srcregistry in process.

## Specs
S1. Usage contract, verbatim from the script header:
    `fetch-doc.sh doc <url> <target-dir> [datasheets|manuals] [name]`
    `fetch-doc.sh web <url> <target-dir>          # page/forum -> markdown (pandoc); long URLs get a hash-suffixed name (web_slug)`
    `fetch-doc.sh ocr <pdf>                        # OCR of a scanned PDF (tesseract); --replace is ignored`
    `fetch-doc.sh --replace doc|web ...            # --replace may appear anywhere in the argument list`
S2. `Exit codes: 1 failure, 2 usage, 3 missing dependency, 4 destination exists (no --replace), 5 symlinked destination.`
S3. Overwrite policy: doc and web mode REFUSE (exit 4, before any download) when the destination exists; with --replace the old bytes are kept under `<stem>.<first 12 hex of its sha256>.<ext>`, the old row is retargeted (sha-scoped), identical bytes add no row; a symlinked destination is REFUSED (exit 5).
S4. Cancellation: INT/TERM cancel the tracked download (its whole process group), exit 130/143, never replace a registered file, leave no part file (`<dest>.fetchdoc-part.<pid>`) and no row; signals are ignored from install until the row is written; stale part files of dead pids are swept, registered files never.
S5. Redirects: only PERMANENT (301/308) redirects are followed for the registered URL, bounded (10 hops), non-http(s) targets refused, `|` in a Location percent-encoded; download falls back to wget against the typed URL; empty bodies register nothing.
S6. Registry: rows land at the end of the FIRST markdown table of SOURCES.md; full 64-hex sha256; values byte-identical (backslashes).
S7. Parity with the legacy script except the declared divergences (tool-registry.d/fetch-doc.md); new reason codes only in reason-codes.d/fetch-doc.md.
S8. Modular Go: one package per responsibility under internal/sources/, shared registry/sha helpers exported from internal/core/srcregistry for the verify-sources port (s3).
S9. `fetch-doc.sh` is an rsdd_exec shim; toolbelt/tests/fetch-doc.test.sh passes with --prove-teeth (bash-internal mutants become typed SKIPs naming Go tests).
S10. Go packages reach teeth Lived 0 (`make teeth TEETH_PKG=./internal/sources/...`).

## Tasks
- [x] T1 S6,S8 core/srcregistry (rows, insert, retarget, sha helpers) — inline — commit: 3212305b
- [x] T2 S1-S5,S7 download core (slug, redirect, download, place, fetchdoc) + differential oracle — inline — commit: b916f554, 524790f1
- [x] T3 S7 divergence fixes + reason codes + registry docs — inline — commit: 524790f1 (fixes), c09d49ef (docs)
- [x] T4 S9 shim + suite conversion — inline — commit: ee1998df
- [x] T5 S10 teeth, gates — inline — commit: teeth slice (see log L3)

## Log
L1 (2026-11-05, s1 orchestrator): Port fetch-doc.sh to Go (rsdd sources fetch-doc), improve and modularize, keep a shim; parity except declared divergences.
L2 (2026-11-05, s1 orchestrator): extra requirement from s3: export from internal/sources/... (or internal/core when another domain needs it) a small documented API for verify-sources: parse SOURCES.md rows, document identity/sha256 helpers; name the exported functions in tool-registry.d/fetch-doc.md and the final reply. Decision: core tier, because archtest forbids domain->domain imports.
L3 (2026-11-05): teeth per package, make teeth TEETH_PKG=./internal/sources/<pkg> via heavy-run (gremlins takes one directory, not a ... pattern): slug 0 lived, redirect 0, download 0, place 0, runner 0, fetchdoc 0, core/srcregistry 0. Equivalent mutants removed by simplifying code (Alive is signal-0 only, runner drops the fallback signal and the ExitCode guard, slug uses a safe() helper).
