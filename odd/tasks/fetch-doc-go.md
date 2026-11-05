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
- [x] T1 S6,S8 core/srcregistry (rows, insert, retarget, sha helpers) — inline — commit: 6864f446
- [x] T2 S1-S5,S7 download core (slug, redirect, download, place, fetchdoc) + differential oracle — inline — commit: e17bc712, 9e3c4379, 8d8de8c0, 4cdd9282, 6d4fdbd5, 227d14d2, 7dcca564, 258c47ea
- [x] T3 S7 divergence fixes + reason codes + registry docs — inline — commit: 7dcca564 (divergence fixes in the engine), a0dc8753 (docs and typed states)
- [x] T4 S9 shim + suite conversion — inline — commit: c7cb5013, 2440d63a, 71cd0802
- [x] T5 S10 teeth, gates — inline — commit: a845d219, eac0fb76 (verifier correction batch), plus the teeth edits folded into 6864f446..258c47ea

## Log
L1 (2026-11-05, s1 orchestrator): Port fetch-doc.sh to Go (rsdd sources fetch-doc), improve and modularize, keep a shim; parity except declared divergences.
L2 (2026-11-05, s1 orchestrator): extra requirement from s3: export from internal/sources/... (or internal/core when another domain needs it) a small documented API for verify-sources: parse SOURCES.md rows, document identity/sha256 helpers; name the exported functions in tool-registry.d/fetch-doc.md and the final reply. Decision: core tier, because archtest forbids domain->domain imports.
L3 (2026-11-05): history split for the RDD lens budget (every commit under 1200 changed lines; final tree byte-identical to the earlier tip 554f8ebf, saved as branch backup-fetch-doc-554f8ebf). Teeth per package (make teeth TEETH_PKG=./internal/sources/<pkg> via heavy-run; gremlins takes one directory, not a ... pattern) reached Lived 0 for slug, redirect, download, place, runner, fetchdoc and core/srcregistry; equivalent mutants were removed by simplifying code (Alive signal-0 only, runner without the fallback signal and ExitCode guard, slug safe() helper).
L4 (2026-11-05, s1 verifier BLOCK): a845d219 fixes make cross (unix-only process groups and kill(0) moved to *_unix.go with !unix stubs; the stale sweep keeps every pid off unix). eac0fb76 hashes the staged file before the install with a streaming sha256 (works on every OS, a hash failure leaves nothing placed), and settles queued signals at Block so one that arrived before the point of no return is honoured. Divergences and the .sources-md-* temp file are declared in tool-registry.d/fetch-doc.md.
