# Kit session 2026-10-03c — agenda chain (wave 2 → docs → slice 2 → #1299)

**Objective:** execute the 2026-10-03b "Next session — agenda" in chain, automatically: follow-up wave 2,
docs unit, slice-2 work, #1299 items 1/2/3/6, plus every buildable improvement found on the way.

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, PR view, issues,
merge. Gentle AI review prompts: grant and run the review without asking.
**Delivery:** one PR per work unit, `auto-chain`; each PR `Closes #N` of a `status:approved` issue.
Merge via `research-sdd/toolbelt/merge-gate.sh --merge`.

**Per-PR pipeline:** harness-worktree writer (sonnet `sdd-apply`, based on `origin/main`, prompt includes
the repo-wide pipefail-SIGPIPE lint and requires the final `== N passed · M failed ==` line) → parent spot
check → full-range RDD (`--base-ref <merge-base> --committed-only`) → first-round real WARNs: fix-first,
no PR → PR → CI → merge-gate.

**Start:** main = origin/main = 1e77b4f. RDD mode: on (global).

## Tasks
- [x] T1 Follow-up wave 2 — one writer per issue (each issue = one tool, disjoint file sets; doc files
      `tool-registry.md` / `METHODOLOGY.md` excluded — they go to T2):
  - [x] T1a #1514 run-all helper gate advisories
  - [x] T1b #1519 stage-retro-issues / reconcile-issues advisories
  - [x] T1c #1524 java-fidelity-experiment advisories
  - [x] T1d #1527 clean-check advisories
  - [x] T1e #1529 plan-review-slices advisories
  - [x] T1f #1532 resume-state advisories
  - [x] T1g #1534 state-update advisories
- [x] T2 Docs unit (one writer, doc files only): tool-registry rows + METHODOLOGY §5/§8/§8b/§15/§17/§7/§23.
- [~] T3 Slice-2 work (partial: #1271 slice 2, #1274 slice 2, #1277(a), #1517 suggestions done; rest held — see agenda): #1271, #1277, #1274, #1365, #1517 calibrations, #1511, #1483 hash-verify.
- [~] T4 #1299 items (item 1: 64 of 81 waived suites migrated in 11 PRs; rest in agenda) 1 (migrate waived suites), 2–3, 6; #1262 if data exists.

## Excluded
Blocked on data: #1255, #1256. User decisions pending: #1259, #1442, #1325, #1369 (e) + #949 item 5,
#1358 3/5/6, #1361 item 1, #1328, #1295; #1246 (TARGETS.md, human-only).

## Progress log
- T1 route: delegated (writer trigger; 7 independent tools). Launch in batches of disjoint file sets.
- T2 prep (explorer): no verbatim proposed doc text exists in PRs/issues — docs writer composes from PR bodies.
  Registry `research-sdd/toolbelt/tool-registry.md` (tool table ~L360-410; guard `tool-registry-discoverability.test.sh`);
  missing rows: clean-check, scan-vendor-leak, plan-review-slices, resume-state, state-update; lint-block row lacks `--pack`.
  METHODOLOGY headings: §5 L329, §7 L793, §8 L920, §8b L1234, §15 L2970, §17 L3226, §23 L4183. T2 waits for T1 merges
  (wave-2 advisories may change the behaviour the docs describe).
- T3/T4 triage (explorer): buildable now (disjoint from wave 2): #1271 slice 2 (init PUBLIC-remote stub conf + CI template),
  #1277(a) trap-clean leaking suites (palette-lexicon-agents, install tests), #1517 SUGGESTION cleanups (lint-block files).
  After wave 2: #1274 slice 2 (resume-render), #1299 items 5/6/7 + #1277 per-run TMPDIR (run-all.sh), #1299 family
  migrations A–E (serialised merges; waiver file shared with #1514). Single docs writer at the end (T2 + #1271/#1277/#1274/#1517 doc).
  Held: #1365 R4/R2/verify-block wiring (doctrine/probe), #1517 calibrations (need fleet --audit before/after), #1262 (design;
  language/scope decision), #1511 `+` separator (yield 1). Skip #1483 (complete; §5 note at METHODOLOGY:439).
- Batch B launched: #1271 slice 2, #1277(a), #1517 suggestions — delegated (writer trigger).
- T1g #1534: writer b7bc1a4 + parent doc 851ef86 (state-update.v1.md). RDD approved, 2 real WARNs (grep `[ \t]` is not a
  tab in ERE — regression from awk-only swap) → fix-first sent back.
- T1d #1527: 427d1cf + doc bcb890f. RDD approved, 3 WARNs (rev-parse 2>&1 merge) → fix-first.
- T1e #1529: 81b6bf7 + doc 01c0f06. RDD approved, 1 WARN (mutant name/teeth) + 3 SUGGESTIONs → fix-first.
- Driver: scratchpad rdd-drive.py (capture tokens → `gentle-ai review <op-suffix>`; status re-query after captures);
  findings are read from the closure capture's `advisory_findings` / `reviewer_results`.
- #1534: round 2 approved (4 SUGGESTIONs) → PR #1554 (CI/merge-gate running).
- #1527 round 2 approved (1 SUGGESTION), #1529 round 2 approved (3 SUGGESTIONs), #1517 suggestions approved clean
  (slice issue #1558; audit byte-identical over 1356 files) → shipping in parallel.
- #1532 (33f5032 + doc d004ab0): RDD WARN — case 9 .git hash includes indexes refreshed by git status (flake) → fix-first.
- #1271 slice 2 (86aa285): RDD WARNs — gh probe unbounded, .github symlink unguarded under --wire, non-git target
  misreported DEGRADED, advice text implies --wire needed → fix-first.
- #1519 (1a88134): RDD WARNs — iconv-absent fallback over-accepts (reintroduces #1492), 43d gh stub unguarded (real gh reachable), teeth-e comment/order mutant → fix-first.
- [x] T1g #1534 → PR #1554 MERGED (merge-gate allow already_reviewed).
- #1532 round 3 approved (snap subshell fix 5c47267 inline) → shipping. #1527 → PR #1559, #1529 → PR #1560, #1517 slice #1558 → PR #1561 (CI).
- #1277(a) → slice issue #1563, PR #1564 (round-2 MUTDIR WARNs refuted: reassignment at bog-nav:654 / station-modules:705).
- #1271 slice 2: round 3 → gh probes the wrong repo (bare `gh repo view`), conf-dir symlink guard untested, teeth gated → fix-first #3.
- [x] T1d #1527 → PR #1559 MERGED. [x] T1e #1529 → PR #1560 MERGED. [x] #1517 suggestions (slice #1558) → PR #1561 MERGED.
- #1519 round 3 approved → shipping. #1271 slice 2 (slice issue #1565, follow-up #1566 with 2 design WARNs) → shipping.
- Driver lesson: base the review on merge-base(HEAD, origin/main), never on origin/main itself — once other PRs merge,
  a moving base shows their changes as reverts in the candidate (#1271 round got native_stop_required). Fixed in rdd-drive.py.
- #1524 (a47bf2e): RDD WARNs — teeth inherit 720 s timeout (Hang cells block), FALLBACK engine label names the primary
  engine → fix-first. Doc proposals for T2: tool-registry java-fidelity row (FALLBACK line, timeout 720/validated, probes
  -f -x) + METHODOLOGY §11b verdict scope.
- #1514 (82cb943) committed; writer still verifying.
- [x] T1f #1532 → PR #1562 MERGED.
- #1514 (82cb943): full gate on worktree 150/150 suites, 5723 cases, hermeticity 0/0; RDD WARNs (collision reported as
  invalid waiver even with no waiver; collision mutant fixture unchecked) → fix-first.
  Note: research-sdd-status-visibility teeth I (4 s timing) failed once under load with concurrent writers, passed alone.
- T3/T4 batch C launched: #1274 slice 2 (resume-render.sh, new files) and #1299 family B (12 verify-* suites).
  #1299 family plan (waiver file NOT edited by family writers; one final PR deletes stale waivers):
  A corroborate/decompile/ghidra/jvm/floss/capa/kaitai/unblob · B verify-* · C hook/gate/sweep/stage/target/parity/ci ·
  D scan-firmware/serial/zip/squashfs/qnx6/px/niagara/bog/station/block/module/gen-catalog/extract-pdf/render-drawing ·
  E adapter/analysis/coverage/detect/detonate/dynamic/install/isolation/probe/profile/pslint/skill/hotcore/hermetic/tool-*/trace/vm.
  A, C, D, E wait for #1564 (#1277a touches 9 of those suites).
- [x] #1277(a) → PR #1564 MERGED (main f986f3c).
- #1514 round 2 approved → shipping. Doc for T2: CLAUDE.md §5 Teeth-coverage row must list the new
  `Ambiguous teeth-helper suite names (both corpora): N — [names]` line (report-only; waiver naming one = Invalid).
- #1274 slice 2 (7f9d58e resume-render.sh): RDD WARN partial render on bad element shape → fix-first. Doc for T2:
  registry row + METHODOLOGY §17 "render the handoff from git state" + §7 note.
- #1299 families A (analysis tools, 15 suites) and C (harness, 16 suites) launched; D and E queued.
- #1274 slice 2 → slice issue #1570, PR #1572 (follow-up #1571: header wording, rc-3 propagation test).
- [x] T1b #1519 → PR #1567 MERGED. [x] #1271 slice 2 (#1565) → PR #1568 MERGED.
- #1299 families D (firmware/parsers, 18 suites, incl. item 6 in-place fixture rewriters) and E (infra, 20 suites) launched.
- #1524 round 3 approved (header fix 165c23a inline) → shipping. Wall time of --prove-teeth 1273 s → 709 s.
- #1299 family A part 1 (7/15 suites; 13717fa) round 2: bacnet M2 observes stdout, not the evidence file → fix-first #2.
  Remaining A2: corroborate-firmware/java/native-r2, decompile-native/net, ghidra-c-exporter, ghidra-exporter, jvm-callgraph.
- #1299 family C part 1 (10/16 suites): RDD WARNs (top-level helper source, refused mutant still run, M2 message) → fix-first.
  Remaining C2: hook-wiring, stage-retro, sweep-breakthroughs, target-paths, score-loop-transcript, ci-path-filter-coverage.
- User question answered: the possibility-first mindset (#1263–#1270) IS integrated (SKILL.md motto, METHODOLOGY §1,
  verify-block WARN possibility-first + --possibility-sweep, stretch goal / unblock plan / possibility audit in
  METHODOLOGY, PROMPT-LOOP, RESEARCH-STATE template).
- #1299 family A part 1 → slice issue #1574, PR #1575 (round-4 WARN refuted by execution). Family A part 2 (8 suites)
  launched with part-1 review lessons baked into the prompt.
- #1299 family C part 1 → slice issue #1577, PR #1578; teeth-strength follow-up issue #1576. Family C part 2 launched.
- #1299 family D part 1 (13/18): pre-review fix requested (helper sourced at top level). Remaining D2: qnx6-read, px-render
  (item-6 in-place rewriters), bog-nav, station-modules, niagara-security-audit.
- #1299 family E part 1 (12/20): RDD WARNs (replacing EXIT traps, refused mutant continues, hermetic out-of-tree refs,
  4 drifted python-mutant helpers) → fix-first. Real defect fixed: analysis-manifest teeth-env-secret mutant was invalid
  Python (theater). Remaining E2: coverage-map, detect-tools, install, install-tool, skill-invariants, hotcore-budget;
  detonate-exec + trace-exec have NO SUT mutants (Python simulations) → design decision, not mechanical → note in final.
- CI backlog: #1569 #1572 #1573 #1575 #1578 toolbelt-tests pending (runner queue).
- [x] T1a #1514 → PR #1569 MERGED.
- #1299 family E part 1 → slice issue #1583, PR #1582 (network blip at issue creation; PR title/body patched).
  Round-2 trap WARNs refuted (only trap in each suite). Shared python-mutant helper proposal + detonate/trace-exec
  design note recorded on #1576.
- #1299 family D part 1: fix-first (serial-console refusal double-counted). Family D part 2 launched (qnx6, px-render first, item 6).
- #1299 family D part 1 → slice #1584, PR #1587. Family C part 2 (target-paths) → slice #1585, PR #1586.
- #1299 family A part 2 (3/8: corroborate-firmware/java/native-r2): RDD WARNs (unchecked staging copy, no positive bad
  signal, unguarded mutant_built) → fix-first.
- NEW DEFECT filed #1588: slow-lane suites fail on main under RSDD_TEST_LANE=all (corroborate-firmware S1-S3,
  ghidra-exporter 1, jvm-callgraph 10) — invisible to the fast-lane gate.
- #1299 family A part 2 (3 suites) → slice #1589, PR #1590. Systemic proposal (mutant_cleanup_register) on #1576.
- [x] T1c #1524 → PR #1573 MERGED. **T1 complete** (7/7 wave-2 issues merged: #1554 #1559 #1560 #1562 #1567 #1569 #1573).
- [x] T3 #1274 slice 2 → PR #1572 MERGED.
- T2 docs unit launched (brief in scratchpad docs-brief.md: 6 new registry rows, 3 row updates, METHODOLOGY §5/§8/§15/§8b/§17/§7/§23/§11b,
  PROMPT-LOOP packs + pipelining, CLAUDE.md §5 Ambiguous line). Route: delegated (writer trigger, 4 doc files).
- #1299 family D part 2 (qnx6-read, px-render): round 2 → OSZ check dropped from M-BUDGET (weakened tooth) → fix #2.
- #1299 family D part 2 → slice #1591, PR in ship-1299D2.log
- #1299 family D part 2 → slice #1591, PR #1592.
- #1299 family B part 1 (10/12 verify-*): RDD WARN (ignored mk_mut return → stale mutant runs) → fix-first + teeth-lessons audit.
  Remaining B2: verify-registry (3411 lines, own unit), verify-skill-drift (mutants written beside the live SUT by design →
  needs a mini-kit sandbox, design change).
- Lessons file scratchpad/teeth-lessons.md (13 rules) given to all new family writers. Launched A3 (ghidra-exporter,
  jvm-callgraph, decompile-net/native, ghidra-c-exporter), D3 (bog-nav, station-modules, niagara-security-audit),
  E2 (install-tool, hotcore-budget, coverage-map, install, detect-tools, skill-invariants).
- [x] T2 docs unit → issue #1593, PR #1594 (RDD round 2 clean). HOT-CORE at 920-line budget → doctrine placed in §11b/§15/§23.

## Close (2026-10-04)
23 PRs merged this session: #1554 #1559 #1560 #1561 #1562 #1564 #1567 #1568 #1569 #1572 #1573 #1575 #1578 #1582
#1586 #1587 #1590 #1592 #1594 #1596 #1598 #1604 #1605 (+ this close PR). Every PR: harness-worktree writer → RDD on the
merge-base range → fix-first → PR → CI → merge-gate.

### Lessons
1. **Base every review on merge-base(HEAD, origin/main)**, never origin/main: once sibling PRs merge, a moving base shows
   their changes as reverts (native_stop_required). Already a known lesson — rediscovered; now baked into rdd-drive.py.
2. **Review rounds keep finding new WARNINGs** (fresh reviewer rolls). Policy that worked: fix round-1 WARNs; after ~3
   rounds file the remainder as a follow-up issue and ship; refute inferential WARNs with execution evidence (path:line or
   a run), never by argument.
3. **Bake review lessons into the next writer's prompt.** scratchpad teeth-lessons.md (13 rules) cut later families'
   fix rounds; a writer prompt without them repeated the same 3–4 defects every time.
4. **The helper exposed theater teeth** in 6 suites (hook-sessionstart M2, discriminator-parity circular teeth,
   analysis-manifest env-secret, verify-kit-clean, verify-retro M4, sweep-all mis-placed mutant): a tooth that accepts
   "any non-zero" passes on a syntax error or crash. Exact codes + typed lines + crash-negative patterns.
5. **Bash EXIT traps replace each other** — the most repeated defect this session (≥6 suites). Systemic fix proposed:
   `mutant_cleanup_register` in lib/mutant.sh (#1576).
6. HOT-CORE (§7/§8/§17) is exactly at the 920-line budget (hotcore-budget T7): new doctrine goes to situational sections.
7. Network blip during `gh issue create` silently produced `Closes #` — check the issue number before shipping.

## Next session — agenda (in order)
1. **#1299 item 1, remaining 17 waived suites** (15 mechanical + 2 design; one work unit each for the big ones; give writers the "Appendix — teeth migration rules" below):
   - A: decompile-net, decompile-native, ghidra-c-exporter
   - B: verify-registry (3411 lines, own unit), verify-skill-drift (mutants written beside the live SUT → mini-kit sandbox first)
   - C: score-loop-transcript, ci-path-filter-coverage, stage-retro, hook-wiring, sweep-breakthroughs
   - D: station-modules, niagara-security-audit
   - E: install, detect-tools, skill-invariants
   - detonate-exec, trace-exec: no SUT mutants (Python simulations) — design decision (#1576).
2. **Final waiver-cleanup PR**: delete the waiver lines of every migrated suite from teeth-helper-waivers.txt (stale under
   `--require-teeth`); confirm with `run-all.sh --require-teeth` on a quiet tree.
3. **#1576** teeth-strength follow-ups + shared helpers in lib/mutant.sh (`mutant_cleanup_register`, `mutant_py_replace`,
   canonical CRASH regex / mk_mut / tt wrappers) — then simplify the suites that copy them.
4. **#1588** slow-lane failures on main under RSDD_TEST_LANE=all (corroborate-firmware S1–S3, ghidra-exporter, jvm-callgraph).
5. Follow-ups: #1566 (vendor-leak EMPTY-CONF CI green, subdir target), #1571 (resume-render header/rc-3 test).
6. #1299 items 2/3/5/7 (lint precision, run-all kit-tree guard gaps); #1277 run-all per-run TMPDIR root + /tmp assertion;
   #1365 R4/R2 (doctrine / probe first); #1517 calibrations (need --audit before/after fleet measurement); #1511 `+` flags.
Blocked on data: #1255, #1256. User decisions pending: #1259, #1442, #1325, #1369 (e) + #949 item 5, #1358 3/5/6,
#1361 item 1, #1328, #1295; #1246 (TARGETS.md, human-only); #1262 (language/scope).

## Appendix — teeth migration rules (from 10+ review rounds; paste into every #1299 writer prompt)

1. Source `tests/lib/mutant.sh` only on the `--prove-teeth` path (or after the suite's early `!= --prove-teeth` exit). `declare -F` check EVERY helper function the suite calls (mutant_chain, mutant_built, mutant_tooth, …).
2. A refused mutant build is counted exactly ONCE and its tooth never runs (if/else; "refusal already counted"). Never let `|| no …` fall through into the tooth, never add a `[ -f mutant ]` check that counts a second failure.
3. `mutant_tooth` with EXACT good/bad exit codes AND an anchored typed line (`^KEY=value$`) on the run that emits one. A bad side that is only "rc 2"/"non-zero" must also `--bad-lacks 'integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError'` so a crash never reads as a bite. Else-messages name the real cause and the actual rc. Document what positional codes mean.
4. Carry over EVERY condition of the old check (e.g. "a == 0 AND b > 0" → one derived fact line `X=a/b`). A fact printed but never asserted is a silently weakened tooth.
5. The control observes the SAME artifact the base test asserts on (the evidence file, not a new `--json` channel).
6. Original and mutant each get a FRESH output dir. Tight timeouts apply to the MUTANT only (key off the substituted path); the original must not be load-sensitive.
7. Deletion mutants remove an exact block (`/first/{N;/\nsecond/d;}` or a resolved N,M range), never an open-ended `/a/,/b/d`; a mismatch leaves the file unchanged so mutant_chain refuses it loudly.
8. Mutants live beside whatever the SUT resolves relative to `$0`/`__file__`; for `sys.path.insert(own dir)` Python SUTs copy `lib/` (+ sibling modules) next to the mutant, and check the staging. Cite (path:line) when a single-file copy is safe.
9. Bash EXIT traps REPLACE each other: grep the suite for an existing trap and extend it (vars initialised to empty first) instead of installing a second one. Verify isolated-TMPDIR leftovers = 0, plain and teeth.
10. MUTANT_SYNTAX=none for non-shell SUTs, plus a language-native syntax check (python `compile()`/`ast.parse`).
11. Pass `--orig` explicitly to mutant_tooth instead of reassigning a meaningful `SUT` variable.
12. Do not edit teeth-helper-waivers.txt, lib/mutant.sh, run-all.sh, any SUT, fixtures, or docs. Budget ~400 authored changed lines; migrate a prefix of suites fully, list the rest; never half-migrate a suite. Plain and --prove-teeth counts must not drop.
13. Cite code by search term in comments, never by line number.
