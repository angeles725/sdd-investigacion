# clean-check-go
Objective: port toolbelt/clean-check.sh (contract clean-check.v1.md) to `rsdd hygiene clean-check`; keep the script as an `rsdd_exec` shim.
Branch: feat/clean-check-go. Delivery: work-unit commits, no push, no PR. Test runner: go test (default tags and -tags nodiff), bash suites under toolbelt/tests.

## Specs
- S1: Usage, verbatim: `clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]`; the same flags on `rsdd hygiene clean-check`.
- S2: Finding kinds, verbatim from the script header:
  - (a) `GARBAGE untracked <path>` untracked, non-ignored file in the target repo that no `<TARGET>/.research-sdd/keep.txt` glob keeps
  - (b) `GARBAGE stale-tmp <path> age=<h>h` `tmp.*` entry directly under --tmp, older than the stale age (default 24 h) and owned by the current user
  - (c) `UNPRESERVED-ARTIFACT <file> cited by <block>` (kit #1207) scratchpad file whose basename is mentioned as a whole path component by an .md block of the target (SCRIPTS-MANIFEST.md excluded; skipped when a byte-identical copy sits under sources/probes/)
  - (d) `UNMANIFESTED-SCRIPT <file>` (kit #1207) scratchpad script (sh ps1 py java js rb pl bat cmd groovy kts) whose basename is not the FIRST table cell of any VALID row (2nd cell = 64-hex sha256) of `<TARGET>/sources/probes/**/SCRIPTS-MANIFEST.md`
  - Scratchpad state is never a silent zero: unset -> `scratchpad: not set`; configured but missing -> typed `ABSENT-SCRATCHPAD <path>` + `scratchpad: absent`; otherwise `scratchpad: N file(s)`.
  - (e) `WARN stale-worktree <path> missing|prunable`
  - (f) `WARN merged-branch <name> merged into <base>` / `WARN merged-remote-branch <remote/name> merged into <base>`; base = --base REF, else origin/HEAD, else local main, else master; none -> typed ABSENT-BASE.
  - (g) `WARN stale-backup <path> age=<d>d retention=<D>d` (name contains rollback|backup, up to 2 levels under an `_evidence` dir, older than --backup-days, default 14)
  - (h)-(n) typed lines: `ABSENT-KEEPLIST`, `ABSENT-SCRATCHPAD`, `ABSENT-BASE`, `ABSENT-EVIDENCE`, `DEGRADED-NO-SHA256`, `DEGRADED-WORKTREE-SCAN`, `DEGRADED-BRANCH-SCAN`, `DEGRADED-EVIDENCE-SCAN`, `INFO evidence-discovery skipped unreadable directory`, `INFO merged-branch scan of local branches skipped`.
- S3: Exit contract, verbatim: `Exit: 0 clean (retention WARNs never change it) · 1 findings · 2 usage (an unresolvable --base included; checked before any scan prints) / not a git work tree / absent dir / scan failure ... · 3 DEGRADED`. Last line is `CLEAN-CHECK: clean|degraded|N finding(s) (...)`.
- S4: Read-only (propose-never-apply): the instrument never writes into the target.
- S5: One exported engine entry `cleancheck.Check(Options) Result` in internal/core/cleancheck returning verdict, ordered stdout/stderr lines and exit code, with typed absent/degraded states (for internal/status/show, session s4). The command only parses flags, calls it and writes its lines.
- S6: clean-check.sh becomes an `rsdd_exec hygiene clean-check` shim; every caller works unchanged.
- S7: Defects fixed in Go are pinned by tests and declared in tool-registry.d/clean-check.md; new reason codes only in reason-codes.d/clean-check.md.
- S8: Teeth: Lived 0 for ./internal/hygiene/... and ./internal/core/cleancheck.

## Tasks
- T1 (S5,S7) RED tests + frozen legacy oracle: inline, done, 52ed70a4 (RED: 86 differential cases fail against the stub, exit 70)
- T2 (S1-S5) engine core/cleancheck: inline, done, 155766d1 + 776267c0 (tests 4a4dd261, 00b61339)
- T3 (S1,S3,S6) command, shim, suite conversion: inline, done, 3a714105 + 16fafbf1
- T4 (S7,S8) docs, reason codes, teeth: inline, done, 16fafbf1; verifier corrections: inline, f0d307e6 + the close-out commit

## Log
- L1: Port clean-check.sh to Go (rsdd hygiene clean-check), improve and modularize, keep a shim; parity except declared divergences.
- L2: (s1 coordinator) the engine exports ONE entry taking options and returning a typed result (verdict, ordered stdout/stderr lines, exit code, typed absent and degraded states); the command only parses flags, calls it and writes the lines.
- L3: teeth (heavy-run, GOTMPDIR gotmp-cc): core/cleancheck first run Killed 439, Lived 0, Not covered 26, Timed out 2 (log /home/cristian/.cache/rsdd-logs/s1/cc/teeth-core.log); hygiene/cleancheck Killed 25, Lived 0 (teeth-hyg2.log). After the verifier corrections a run under load (race running alongside) showed Lived 54, 46 in glob.go (teeth-core2.log); a quiet rerun is teeth-core3.log.
- L4: verifier BLOCK corrections, RED then GREEN in f0d307e6: TestFileSumStreamsLargeFiles RED "allocated 300 MiB"; TestRelativePathsUseOptionsCwd RED (stale-backup warn missing, evidence walked against the process cwd); TestZeroNowIsATypedRefusal RED (nil pointer panic in scanStaleTmp); TestSymlinkedProbesAreNotFollowed RED ("manifest outside the target was read"); TestOutputCapIsNotACompleteListing RED ("exit 0 cut at the cap: rc 0, want 125"). GREEN: go test default and nodiff, -race, make lint, make cross, clean-check.test.sh --prove-teeth 133/0.
