# verify-* performance (kit issues #2635, #2645)
Objective: make `rsdd verify corrections` and `rsdd verify state` fast on the largest real corpora, with byte-identical output. Branches perf/2635-verify-corrections and perf/2645-verify-state, one PR each. Runner: go test plus benchmarks; fleet differential.

## Specs
- S1 (#2635): "Pre-filter each line with `strings.Contains` / `IndexByte` on the literal anchors ... before running any regexp"; "Keep output byte-identical: the fleet differential (20 corpora) and `TestDifferentialGenerated` are the gate"; "Add a benchmark over a fixture with long lines, and record before and after numbers in the PR. Never commit the timings as assertions."
- S2 (#2645): "`rsdd verify state <niagara dir>` under 300 ms warm, without changing its output"; "Before optimizing, take a CPU profile (L53, L58)"; "name the hot spot in the PR"; "reported as min/median/max over 10 runs with the first call separate"; "The changed package clears package-scoped teeth (L56)."
- S3 (L58, s1): time each child on the real corpus before optimizing.

## Tasks
- T1 (S1, S3) corrections extract pre-filter — route: delegated writer — status: done, PR #2668 merged f61ecc5e (niagara 3634→413 ms median, fleet 35/35, local teeth lived=0)
- T2 (S2, S3) verify state per-file cost — route: delegated writer — status: done, PR #2675 merged 61d355b6 (niagara 2236→840 ms, fleet 78/78, teeth lived=0)

- T3 (S2) port check-gap-drift.sh + lib/gap-rows.sh to Go (core/gaprows typed parser + gap-drift command), repoint verify state gapDrift in process — route: delegated writer — status: done, PR #2681 merged 743af41e (Closes #2645)

- T4 (internal/verify test time, #2665 class) TestMain parallelfloor.Raise(8) in verify, block, corrections, gapdrift + t.Parallel on 160/235 tests (14 that swap or chdir, plus the 61 skilldrift/kitclean tests that write and exec stubs: ETXTBSY, CI exit 126; parallel again after testkit/execfile #2697/#2698 package globals stay serial, picked by go/ast) + reGapRows comment; also fixes #2690 (block cases under /tmp) — route: inline — status: committed on test/verify-parallel-floor (heavy-run, lane GOTMPDIR: verify 245.5→84.9 s, block 202 FAIL→47.0 s, corrections 26.2→8.8 s, gapdrift 9.3→4.5 s; -race clean)

- T5 (#2592 repoint, s3-owned teeth-debt packages; one package per change, delete its teeth-debt.txt line in the same commit, kill revealed lived mutants; never touch rsdd-go.test.sh combine_verdicts, s1 #2683): ./internal/verify, then ./internal/core/gfm, then ./internal/corpus — route: inline per package. ./internal/verify: commit 586f2404 (kitroot repoint f9e5d3b5; module-only RED 6 FAIL -> GREEN; teeth 2066 killed / 39 lived -> 18 lived mutants re-applied by hand, all now fail their test; rest removed as equivalents or dead branches), PR pending. Next: ./internal/core/gfm, ./internal/corpus (after s1 unit E)

## Log
- L1 (2026-11-03, user campaign directive, verbatim excerpt): "todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo"
- L2 (2026-11-03): s1 confirmed the order: the repoint slice waits for #2592 slice A, so perf goes first.
- L3 (2026-11-03): T2 profile: countBlocks re-listed the corpus per state file (about 65% of Go CPU), fixed by a per-run memo. The remaining ~650 ms is `bash check-gap-drift.sh` per file, outside Go; porting it belongs to s4 (PORT-QUEUE). Ship T2 as Refs #2645.
- L4 (2026-11-03, s4 → s3, verbatim excerpt): "(1) Put the row parsing in a shared core package (e.g. internal/core/gaprows) and the drift check over it. ... (2) A typed result, with absent, empty, no-match and degraded kept distinct (§7), so status can render it without re-deriving anything."
- L5 (2026-11-03): T3 removes the per-file bash; remaining cost is verify state's own per-line regexps (~30%) and kit.FilterBlockFiles (~10%). Seven divergences D1-D7 are documented in tool-registry.d/check-gap-drift.md. Delivery: PR A = T2 (perf/2645-verify-state), then PR B = T3 stacked on it.
- L6 (2026-11-03): pending on T3 before PR: unexport the gaprows names unused outside the package (Block, Bullet, Count, Rows, Skipped, Unparsed, Words; s1 L68: no speculative entry points), and wrap fs.ErrNotExist for an absent state file so absent and unreadable stay distinct (s4 review, §7).
- L7 (2026-11-03): T3 teeth: first local gremlins 16+20 LIVED (differentials excluded under nodiff); a46f589e added recorded goldens replayed under nodiff plus equivalent-mutant rewrites; second run lived=0 in both packages. RDD acked: fd966247 slice, a46f589e slice (suggestion on lower(): verified pure ASCII fold, no change), range 1b2d7d9a..a46f589e, and the 4-lens high-risk range over the branch. T2 RDD acked with two test-quality warnings (self-referential countBlocks test; mayContainFold pinned to a copy of the regexps); T2 local teeth on internal/verify pending.
- L8 (2026-11-03): session closed on s1 wrap-up. #2681 open with CI running; T4 and T5 unstarted; see go-port-lanes/session-3.md.
- L9 (2026-11-05): T4 baseline found #2690: under a lane GOTMPDIR, go test puts t.TempDir() outside /tmp and 14 block goldens fail; fixed by materializing cases under /tmp. Follow-ups: the serial registry differentials (~140 s) and TestDifferentialBlockFuzz (~70 s) bound the wall time; parallel subtests there need the registry hooks injected per run instead of a package global.
- L10 (2026-11-05): T5 ./internal/verify. Teeth after the kitroot repoint: 2066 killed, 39 lived, 18 timed out. The lived ones were pinned by edge tests (edges_test.go, edges_cmd_test.go) or simplified away. Added cli.Stdio.Environment(); the other 10 sites are #2708. The mktemp failure now names its cause (tool-registry.d/verify-skill-drift.md).
