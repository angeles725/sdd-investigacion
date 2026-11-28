# verify-corrections → rsdd verify corrections (kit issue #2625)
Objective: port toolbelt/verify-corrections.sh to Go, leaving the script as a shim. Branch feat/2625-verify-corrections-go. Delivery: ask-on-risk; one PR, sliced commits. Runner: go test + toolbelt suites.

## Specs
- S1: `rsdd verify corrections <target-dir>` reproduces verify-corrections.sh: the same stdout, stderr, and exit codes (0 / 1 / 2, and degraded+1) on every input a caller sees. This is pinned by a differential test against the frozen legacy script under testdata/legacy.
- S2: block discovery uses the single core/kit block-file discriminator (maxdepth 3, *.md, excluding *.template.md and .git). No second copy.
- S3: the shell script becomes an `rsdd_exec` shim. Its suites are rewritten to the shim contract. discriminator-parity.test.sh and the corpus archive AR-VCORR goldens stay green.
- S4: legacy defects found while porting are fixed in Go, pinned with a test, and documented in tool-registry.d/verify-corrections.md ("port plus improve"). Parity is kept only where a caller depends on it.
- S5: reason-codes.test.sh maps the shim to its Go source (GO_SRC, plus GO_FILES `corrections*.go` if the package is shared).

## Tasks
- T1 (S1-S5) port + shim + tests — route: delegated writer (context backstop: parent is coordinating 4 PRs) — status: done, PR #2634 merged 7ed1f3bb (incl. dbd37818 nodiff archive binary fix)
- T2 (S4) correction batch, 9 items from independent lens reviews — route: same delegated writer — status: done (aae5eccb, 365d7a06, 42a5d188, 7666fb77) + parent fix a5d529b5 (RDD R3-001)

## Log
- L1 (2026-11-03, user campaign directive, verbatim excerpt): "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular"
- L2: s3 lane order — verify-corrections is next after verify-registry (#2602 merged d661c005) and the #2610 item 1 fix (#2620 merged 757ac9f6).
- L3 (2026-11-03): The RDD lineage of 7dec739a stopped at corrupted_or_unverifiable_authority, which needs a maintainer abandon. Two independent lens reviews replaced it and produced a 9-item correction batch.
- L4 (2026-11-03): Decision: keep "unreadable directory = typed degraded" even though `research-sdd-archive` now refuses such a corpus (exit 3). Closing an archive over an unchecked corpus is a §7 silent pass. The two archive goldens were re-recorded. The scan-secrets mismatch is filed as #2633.
- L5 (2026-11-03): Verification:
  - fleet differential: 20/20 SAME;
  - vet and tests clean on both builds; the module-only baseline passes;
  - plain shell suites green;
  - all RDD slices acknowledged (except 7dec739a, see L3).
  The branch merged origin/main, which restores the reason-codes.test.sh exec bit. PR #2634 is open.
- L6 (2026-11-03): CI teeth on internal/corpus failed: under -tags nodiff the archive cases had no RSDD_BIN, so the shims built rsdd into research-sdd/bin. dbd37818 moved the test-binary builder to an untagged file. PR #2634 merged as 7ed1f3bb.
