# bridge-file-shard — shard rsdd-go-bridge teeth by changed file (issue #2573)
Objective: a one-package change spreads its gremlins teeth across the bridge jobs. Branch: ci/bridge-teeth-file-shard, based on
origin/ci/bridge-teeth-shard (PR #2570) until #2570 merges, then rebased onto origin/main. Delivery: single PR. Runner: bash suites + go.

## Specs
- S1 (s1 decision, verbatim): "generalise #2570's shard unit from "changed package" to "(changed package, changed-file group)": list the changed non-test .go files per package, sort LC_ALL=C, keep p mod N == I-1 over that flat file list, and run gremlins per package restricted to the shard's files (check `gremlins unleash --help` for the include/exclude-files flags in the pinned version; exclude = the package's other files)."
- S2 (verbatim): "Keep every #2570 invariant: typed FAIL on bad selector or shard without base, "0 files in shard I/N" as a typed ok line, make test only in shard 1, nightly unsharded."
- S3 (verbatim): "Add mutation controls for the file split (offset, a file dropped)."
- S4: docs — the rsdd-go.test.sh header, `--shard-select` help and the CLAUDE.md Tier/teeth prose describe the file-level unit ("CLAUDE.md Tier row too if the prose changes").
- S5: evidence that motivates it (#2477, head f6f2ce0d, job 125653793021): "teeth scope: changed vs origin/main — 1 package(s): ./internal/verify", gremlins killed at the 25-min cap.

## Tasks
- T1 · S1-S5 · delegated writer (kit §1: 2+ non-trivial files; risk item 5) · status: pending · commit: —
- T2 · S1-S3 · parent: RDD review, impacted gate via heavy-run, then s1 runs the independent verifier · pending
- T3 · — · parent: after #2570 merges, rebase onto origin/main, push, PR, strict watcher · pending

## Log
- L1 (2026-11-03, s1 to s3, verbatim): "s1 decision on #2477 bridge: (a), and you take it as a unit — you know internal/verify best. Not (b): a per-file -run map is a guess that silently drops kills when a test lives elsewhere (§7). Not (c): a longer cap only moves the wall. Contract: generalise #2570's shard unit from "changed package" to "(changed package, changed-file group)": list the changed non-test .go files per package, sort LC_ALL=C, keep p mod N == I-1 over that flat file list, and run gremlins per package restricted to the shard's files (check `gremlins unleash --help` for the include/exclude-files flags in the pinned version; exclude = the package's other files). Keep every #2570 invariant: typed FAIL on bad selector or shard without base, "0 files in shard I/N" as a typed ok line, make test only in shard 1, nightly unsharded. Add mutation controls for the file split (offset, a file dropped). LOCK HANDOFF: base your branch on ci/bridge-teeth-shard (PR #2570) now; I RELEASE .github/workflows/rsdd-go.yml and research-sdd/toolbelt/tests/rsdd-go.test.sh to you when #2570 merges (sha follows), then rebase onto main. CLAUDE.md Tier row too if the prose changes. File it as a new issue (status:approved). Risk item 5: I will run the independent verifier before merge — ping me when RDD is done."
- L2: user's campaign directive: ODD + RDD granted, no questions, commit/push/PR/merge authorized; WSL2 safety (heavy runs via heavy-run only).
- L3: issue #2573 opened (status:approved, type:bug).
