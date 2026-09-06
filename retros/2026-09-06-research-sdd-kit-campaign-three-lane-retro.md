<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — sdd-investigacion (the kit itself) · three-lane kit-maintenance campaign · 2026-09-06 · Research-SDD self-retrospective

> Run reviewed: the `research-sdd-kit-retro-campaign` — 2026-09-05 → 2026-09-06, three concurrent
> sessions (explorador = lead / doctrine / adversarial cross-read; mejorador = single instrument writer;
> probador = quiet-tree gate), 31 work units (15 instruments + 16 doctrine) plus verify and remediation,
> **43 PRs merged since 2026-09-05T00:00Z** (`gh pr list --state merged`, #427 → #504). Run type:
> kit-maintenance campaign, not a corpus research run — there are no blocks, so §18's block-based
> trigger does not apply; the trigger here is "the session changed how the next one should run"
> (METHODOLOGY §18, sessions-that-wrote-no-block clause) and corpus-level close of the SDD change.
> Trigger: change-completion (verify → remediation → retro → archive).
>
> Method: a FRESH-CONTEXT agent read the current kit FIRST on a worktree of `origin/main` (`ec3d8e4`) —
> `METHODOLOGY.md` §1/§3/§7/§8/§11/§11b/§16/§18/§21, `PROMPT-LOOP.md` (RETRO CHECKPOINT + RETURN
> CONTRACT), kit `CLAUDE.md` §3–§7 and §12, `templates/retro.template.md`, `lib/retro-grammar.sh` —
> and only then the run evidence: the three lanes' closeout inputs, the merged-PR ledger, the
> `openspec/changes/research-sdd-kit-retro-campaign/` chain (proposal · design · tasks · verify-report),
> and Engram `sdd-investigacion` (#8162 #8169 #8173 #8176 #8179 #8180 #8182 #8183 #8185 #8187 #8190
> #8193 #8197 #8200 #8201 #8222 #8225 #8263 #8316). The shared checkout was deliberately never read —
> it is stale at `4c100d8` (CLAUDE.md §12.4). READ-ONLY on the kit: this report only PROPOSES; kit
> changes are human-reviewed and human-committed (METHODOLOGY §18).

---

## Proposed kit deltas

Ten genuinely new items. Everything this campaign re-confirmed but the kit already encodes is under
**Already covered** below and is NOT re-proposed (§18 dedupe + honesty clause).

| # | Proposed change | Target (file · §/section) | Evidence (PR / sha / issue / measurement) | Type | Priority |
|---|---|---|---|---|---|
| 1 | **Degraded-environment axis in acceptance.** Every instrument with a runtime dependency must be exercised with that dependency ABSENT, and must probe for it and emit a loud typed `degraded` state — never allow/pass silently. Add to the three-state table's neighbourhood as a fourth question: "could the instrument RUN at all?" | kit `CLAUDE.md §7` (new paragraph after "Acceptance is a fleet sweep") + `§5` gate note | `retro-gate.sh` (#492, `1e9a0a2`) silently ALLOWED with `jq` absent — empty stdout, exit 0. The writer's real-target dry-run and the gate's synthetic-JSON dry-run both ran on machines that had `jq`; found only by post-merge adversarial cross-read. Fixed U20 #496 (`af83e7a`) with a probe + bash JSON emitter; Engram #8193 | new | HIGH |
| 2 | **One worktree per writer, and VERIFY the isolation before trusting it.** A writer launched by the same session is not isolated by default; pass `isolation: "worktree"` on every delegated writer and read back the worktree path before the first edit. Same-session launch ≠ isolation. | kit `CLAUDE.md §3` (refines the existing "use the harness's own worktree isolation for delegated work" sentence) | mejorador's post-compaction Agent writers inherited the orchestrator's worktree; three units piled onto one branch; detected only when one writer's `run-all.sh` picked up another unit's uncommitted file. Recovered by freezing writers + single-actor extraction (`git add` explicit paths, `git diff --cached` readback) | refinement | HIGH |
| 3 | **An enumerator's coverage is a snapshot, not a closure — re-run it at every NEW instrument's gate.** A closed enumeration of a defect family (e.g. unguarded `\|\| true` after a producer) certifies the files it walked on the day it walked them; any instrument merged afterwards can re-open the family. Make the re-run part of a new instrument's acceptance, not a once-per-campaign sweep. | kit `CLAUDE.md §7` (extends "An audit instrument must prove the coverage of its own enumerator") | U12 (#463, `2f83114`) closed 8 enumerated sites across 7 files; `coverage-map.sh` (#451, `0c90262`) landed independently and carried two more at `:79`/`:84`, outside that enumeration. Surfaced by the sdd-verify toolbelt sweep as WARN-3, not by any gate; closed U21 #500 / PR #503 | refinement | HIGH |
| 4 | **A budget is a fleet property: after trimming one hook, re-measure ALL registered hooks.** A per-hook target is not a session budget; state the aggregate, measure every registered hook after each trim, and keep the aggregate in the instrument's output, not in prose. | kit `CLAUDE.md §5` (new gate row or note) · `kit-session-cost` capability spec | #437 (`58bed7e`) cut `sweep-retros-hook` 19,799 → 1,855 chars; the sdd-verify aggregate over all 7 registered hooks still measured **9,398 chars vs the 8,000 the capability Purpose pins** (WARN-1), because two sibling sweeps each still printed 17 absent-input lines. Closed U22 #501 / PR #504 | new | MEDIUM |
| 5 | **A sampling-rule change is its own work unit — never inside a bug fix.** When a fix would alter which rows an instrument samples or how it orders them, split it out: the fleet gate anchors on that output, so a widened rule inside a bugfix shows up as unexplained fleet churn. | kit `CLAUDE.md §6` (work-unit budget — the inverse of "silent scope compression") | #449/#474 (`1c90f59`): the lead's "file order over all rows" ruling re-sampled ~14 focuses that had no structural rows at all (sullair, apis, modbus, platform-native, jace8000-*, module-authoring*, interactive-composition, protocols) and broke probador's sullair-unchanged guard. Corrected to ruling B' (index order, file-position tie-break); flips stayed exactly 3. Engram #8225 | new | HIGH |
| 6 | **Two samples with different scopes get two names.** When an instrument prints a sample drawn from a different population than a sibling sample, they need distinct labels; one label over two populations is an unfalsifiable output. | kit `CLAUDE.md §7` (instrument-output honesty, next to "Report only what you measured") | #476/#486 (`a5d3876`): the saturation partial-WARN printed one `forms:` sample sourced from the whole iteration window while the sibling reading counted numbered rows only. U16 split it into `wforms` (window) and `forms` (numbered-only), sourced from `iter_window` | new | MEDIUM |
| 7 | **A gate's calibration corpus must be a FROZEN fixture; a live-fleet count is a hand-verified snapshot, never an assertion.** Complementary to §11b R2 (teeth come from the live module, not the fixture) — different axis: R2 governs where the tooth BITES, this governs what the gate COMPARES against. Never pin a byte-diff to a mutating corpus or a volatile rendered field. | `METHODOLOGY.md §11b` (new rule beside R2) + kit `CLAUDE.md §5` | `verify-retro.sh`'s 12-retro live calibration corpus mutated mid-campaign — the campaign itself added retros — so the "5 PASS / 7 FAIL" reading was a dated snapshot, not a gate. Separately, a `sweep-retros.sh` byte-diff pinned to the rendered `age: Nd` field produced a day-rollover false positive; the fix was main-vs-main compare first, then age-normalisation (#491, `e973341`) | new | HIGH |
| 8 | **A spec pins RULES and a dated measurement, never a live fleet number.** Extend the existing "live telemetry belongs to the instrument that produces it" rule from doctrine files to SDD spec artifacts: a spec scenario may cite `measured 148 on 2026-09-05 at 4c100d8`, never a bare `148` as an acceptance literal. | kit `CLAUDE.md §5` (extend the no-persisted-counts paragraph to `openspec/**/spec.md`) | sdd-verify at `af83e7a`: uncited niagara modules spec 148 / measured 144; `no delta section found` spec 4 / measured 5; `no review-status marker` spec 5 / measured 22; node suites spec 1 / measured 2. Seven of eight scenarios that went PARTIAL were pinned-number drift, not behaviour drift (WARN-4, WARN-7, SUGG-3) | refinement | HIGH |
| 9 | **Order parallel work by FILE SET, not by unit name.** §3 already requires a writer prompt to list the other writer's files; extend it to the cross-session ordering MESSAGES: "U13 before U16" is ambiguous when the recipient tracks files, and two such messages crossing produce contradictory orders. State the files being locked and released. | kit `CLAUDE.md §3` (extends the parallel-writer prompt requirement to inter-session ordering) | Two briefs crossed between explorador and mejorador ordering the same wave by unit name and produced contradictory sequencing; resolved only by restating the file sets. Same root cause as §12.7 (same-file units serialise), which names files while the messages named units | refinement | MEDIUM |
| 10 | **Surface targets whose §18 Stop hook is not wired.** `retro-gate.sh` is inert until an operator pastes the snippet into each target's `.claude/settings.json`, and nothing measures how many targets did. Add a wiring column to `sweep-retros.sh`'s fleet pass — WARN-only, propose-never-apply. **Measure first:** count wired vs unwired targets across the TARGETS.md rows before any writer is launched (§6, "probe viability before the writer"); a low unwired count means this is verifier discipline, not a work unit | `METHODOLOGY.md §18` (Enforcement paragraph) · `toolbelt/sweep-retros.sh` | U17-PR2 (#492, `1e9a0a2`) shipped the hook and `research-sdd-init.sh` prints the wiring, but the operator applies it per target; the fleet's wired count is currently unmeasured. The gap it guards is real and measured: 12 retros written on 2026-09-05, 5 conforming; 3 targets advanced with no retro (Engram #8263) | new | MEDIUM |

For each delta above, one line of rationale (WHY it matters, what it costs, expected impact):

- **#1** — The kit's whole §7 doctrine asks "did the instrument look?" and "could it SEE?"; the jq miss adds a third question nobody had asked: "could it RUN?". Cost: one extra acceptance case per dependency-bearing instrument. Impact: closes a silent-allow channel in the very gate that exists to stop silent passes.
- **#2** — Shared-checkout contamination cost a recovery session and nearly landed three units on one branch; §12.4 already knows the shared tree is dangerous to READ, this closes the WRITE side. Cost: one flag and one readback per delegated writer. Impact: removes the campaign's single worst near-miss.
- **#3** — U12 was a textbook §7 closure and was already stale the day it merged. Cost: one enumerator re-run inside each new instrument's gate. Impact: keeps a closed defect family closed instead of re-opening it one instrument at a time.
- **#4** — A per-hook win that leaves the aggregate over budget is a measurement that flatters itself; the verify caught it only because it measured all seven hooks. Cost: one aggregate line. Impact: the budget stops being a number nobody owns.
- **#5** — The fleet gate is the kit's most expensive instrument; churn it cannot explain destroys its value. Cost: one extra PR when a fix touches sampling. Impact: preserves the byte-identical-diff acceptance shape.
- **#6** — A sample nobody can trace to a population cannot be checked at all — a false negative in the §7 sense. Cost: one label. Impact: the partial-WARN becomes falsifiable.
- **#7** — A gate whose baseline moves under it produces failures that teach the operator to ignore the gate. Cost: freezing a fixture corpus once. Impact: deterministic gate + an honest, dated live reading, instead of one reading pretending to be both.
- **#8** — Seven PARTIAL verify verdicts out of eight were the spec being stale, not the kit being wrong; that ratio makes the verify report harder to read than it should be. Cost: a date next to each number. Impact: PARTIAL starts meaning "behaviour diverged" again.
- **#9** — Two lanes editing by unit name have no way to detect a conflict; two lanes editing by file set do. Cost: naming files in ordering messages. Impact: removes an entire class of cross-session contradiction.
- **#10** — An enforcement gate that ships disabled is doctrine, not enforcement — and the measured non-compliance it targets (5 of 12 conforming) is exactly why it was built. Cost: a measurement first, then possibly a small WARN column. Impact: the §18 exit condition stops depending on whether anyone remembered to paste a snippet.

## Already covered (dedupe — proof the retro read the kit first)

Seventeen lessons this campaign re-confirmed that the kit ALREADY encodes. None of these is proposed
above. Eight of them are the campaign's own first-day harvest, already merged as `CLAUDE.md §12`
(D11, #461 `e042726`) — re-proposing them would be exactly the noise §18's honesty clause forbids.

- Doctrine describes the instrument as it IS, plus the next PR's contract; the "until #N lands" note is owned by whichever side merges SECOND → already covered by kit `CLAUDE.md §12.1` (caught 3× pre-merge by doc↔code readback: #427 first draft, #430 alias list, #445 Type wording).
- Stacked PRs after a squash-merge need `git rebase --onto origin/main <old-base-tip>` plus a `gh api -X PATCH … -f base=main` retarget → already covered by `CLAUDE.md §12.2` (#434 went `dirty`).
- Registry and interface rows get a FULL row-by-row readback, never a sample → already covered by `CLAUDE.md §12.3` (5-of-17 sample found 1 defect; the ordered full pass found 4 more, #446). Re-confirmed at remediation: the verify CRIT-1 orphan row (`DEPLOY-WINDOWS-MINIPC.md`, created by D2 #446, never registered) was closed by another full pass in #502.
- The shared checkout's local `main` never advances; read "current" kit content only from a worktree on `origin/main` → already covered by `CLAUDE.md §12.4`. This retro's own setup obeys it (`ec3d8e4` worktree; shared tree stale at `4c100d8`), as did the sdd-verify run.
- Retro markers carry MERGE shas, not branch shas → already covered by `CLAUDE.md §12.5`.
- Measure the yield BEFORE the writer → already covered by `CLAUDE.md §12.6` and `§6` ("probe viability before the writer"). Four measured dismissals this campaign, all recorded, none built — see **Measured dismissals** below.
- Same-file units serialise even between disjoint-set writers, and a lib extraction locks every consumer → already covered by `CLAUDE.md §12.7` (#435 `f470656` `lib/block-files.sh`, 16 sites; #495 `dd2de6b` `lib/retro-grammar.sh`, 2 consumers — both accepted on a byte-identical real-corpus diff).
- Two reviews in parallel, catching different defect classes → already covered by `CLAUDE.md §12.8`. Held again: the adversarial cross-read caught the jq silent-allow post-merge; the quiet-tree gate caught the #440 v1 §7 `diff` return-code hole and the U16 v1 SC2034 dead code before merge.
- The §18 retro is an EXIT CONDITION of a run, not an advisory question → already covered by `METHODOLOGY.md §18` ("Enforcement — the retro gate") and `PROMPT-LOOP.md` RETRO CHECKPOINT / RETURN CONTRACT (`retro: written <path>` is mandatory on the final return). Shipped this campaign as D14 (#481) + U17 (#490, #492).
- The delta declaration must be machine-countable under `## Proposed kit deltas` → already covered by `METHODOLOGY.md §18` (D6 #430; instrument U7 #436 `a26253e`, which also added the typed `no delta section found (empty-input)` state and the missing-marker WARN).
- A researcher-profile axis (`technical-excavator`) and the limits/layer axis → already covered by `METHODOLOGY.md §1` and `§13` (D16, #485 `24069c3`).
- Only a quiet-tree gate report is authoritative, and a merged CI-green PR is not a verified PR → already covered by `CLAUDE.md §3`. Proved twice more here: the sdd-verify sweep found WARN-3 and CRIT-1 in code merged hours earlier.
- Volatile line-number citations in doctrine must be replaced by a stable search anchor → already covered by `CLAUDE.md §8` and, since D13 (#472 `a6e62eb`), by the `SENTINEL-NO-TEETH-BANNER` anchor named in `§5` itself (Engram #8222).
- Acceptance is a fleet sweep, not the fixtures → already covered by `CLAUDE.md §7`. Every instrument PR in this campaign was diffed against `main` on the real fleet with each new WARN and exit-code flip hand-classified.
- The three-state anti-silent-zero model and "test the list edges" → already covered by `CLAUDE.md §7`; this campaign applied it rather than extended it (U12's 8 sites, U7's typed no-delta state, the `--require-teeth` accounting).
- Do not persist live suite/case counts in doctrine — run the gate → already covered by `CLAUDE.md §5`. Honoured here: the numbers in **Metrics** below are dated single-execution measurements, not tracked figures.
- Group a delta backlog by DESTINATION FILE, not by source retro → already covered by `CLAUDE.md §3`. The exploration phase harvested ~70 deduped deltas from 30 pending retros grouped by destination file, which is what made two disjoint writers possible at all (Engram #8169).

## Measured dismissals (do NOT re-propose)

Recorded so a future retro does not spend the measurement again. Each was probed before a writer was
launched and none was built — `CLAUDE.md §12.6` / `§6` in practice.

| Candidate | Measurement | Verdict |
|---|---|---|
| Bayesian discovery-rate saturation (Gamma-Poisson / exponentially-weighted) over "New gaps uncovered" | 35 readable fleet series, 349 transitions, base rate 0.10. Brier: naive-3-zeros **0.089** ≈ base rate 0.090 < EW-0.5 0.199 < GP-W3 0.203 < GP-W6 0.244 < GP-all 0.299; GP over-confident (0.8–1.0 bin observed 0.02). The series is ~90 % zeros with one bootstrap burst, and STOP is already deterministic | Do not build (Engram #8173) |
| Shared test-harness extraction across the suites | ~214 net LOC ≈ **1 %** of test LOC; 54 one-arg bash + 21 bespoke two-arg (11 distinct widths) + 23 python-heredoc reporters; would make `run-all.sh`'s summary line a single point of failure | Do not build; runtime was the real lever (Engram #8200) |
| Prose regex for the delta counter | Yield 2 retros fleet-wide; a parser over free-form prose inherits the prose's ambiguity (`CLAUDE.md §6` corollary: doctrine first) | Do not build |
| PageRank dependency-centrality over `module.xml` | Only 2 `module.xml` present under `organized/` — the input does not exist. Ranked by class count instead | Not feasible (Engram #8173) |

## Anti-patterns observed

- A gate shipped with a runtime dependency that was present on every machine that tested it → **#1**.
- Delegated writers assumed isolated because they were launched from one session → **#2**.
- A defect-family enumeration treated as permanently closed → **#3**.
- A per-hook budget win reported as a session-budget win → **#4**.
- A bugfix that quietly widened the sampling rule the fleet gate anchors on → **#5**.
- One label printed over two different populations → **#6**.
- A gate calibrated against a corpus the campaign itself was mutating; a byte-diff pinned to a rendered `age: Nd` field → **#7**.
- Specs pinning live fleet numbers as acceptance literals; 7 of 8 PARTIAL verdicts were number drift → **#8**.
- Cross-session ordering by unit name → **#9**.
- An enforcement hook that ships disabled and unmeasured → **#10**.
- `tasks.md` materially stale at verification time (12 wave-2 units with no entry; merged work still `[ ]`) — process debt corrected in #498; no delta proposed because the fix is discipline already named by "apply and close are the same work unit" (`METHODOLOGY §18`).

## Tools built, adapted, or outgrown

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | `research-sdd/toolbelt/coverage-map.sh` · coverage over the SUBJECT's own structure | — | — | `coverage-map.sh` · SEEs which of the subject's 318 modules were never cited by any block, instead of recomputing block/citation counts from the corpus — the unknown-unknowns metric §8 lacked | `promote` · already in `toolbelt/` with a companion suite (#451 `0c90262`); Engram #8173/#8197 |
| T2 | `research-sdd/toolbelt/verify-retro.sh` + `retro-gate.sh` · typed §18 conformance check + per-target Stop hook | — | — | — | `promote` · shipped (#490 `6ea74c0`, #492 `1e9a0a2`); hook still needs per-target wiring → delta **#10** |
| T3 | `RSDD_PROFILE` per-phase wall-time mode in `sweep-retros.sh` · measurement-only instrument | — | — | — | `promote` · shipped #488 `91e5572`; it is what located the 85 % block-newest phase that U19 (#491 `e973341`) turned into 56 s → 8.9 s with byte-identical verdicts |
| T4 | — | `run-all.sh` teeth accounting · the kit version forwarded `--prove-teeth` and never accounted for suites that accepted the flag and ran no mutant (22 of 100 silently green) | — | `--require-teeth` · SEEs the absence of a mutation control rather than trusting a green exit code | `absorb` · landed #462 `055d604`; `CLAUDE.md §5` gate row added by D12 #470 |
| T5 | probador's gate recipe · main-vs-main drift-immune fleet compare, `age: Nd` normalisation, file-set-match intake, integrated-tree gating for stale-base PRs (no file — a procedure) | — | — | main-vs-main compare · SEEs whether an instrument's fleet output actually changed, independent of corpus drift between the two runs | `absorb` · the frozen-baseline half is delta **#7**; the rest is recorded here as gate practice |
| T6 | — | — | Hand-rolled block-file discriminator at 16 sites / 8 scripts → `lib/block-files.sh`; `research-sdd-archive.sh`'s second retro-marker parser → `lib/retro-status.sh` / `lib/retro-grammar.sh` | — | `absorb` · #464 `f470656`, #495 `dd2de6b`; both accepted on byte-identical real-corpus output |

## Metrics

- **Work units**: 31 (15 instruments + 16 doctrine) · **PRs merged 2026-09-05 → 09-06**: 43 (#427–#504) · **Sessions**: 3 concurrent
- **SDD chain**: exploration (~70 deduped deltas from 30 pending retros, grouped by destination file) → proposal (18 units, two disjoint writers) → 5 capability specs → design (7 corrections) → tasks (56 items) → apply → verify (47/55 scenarios PASS, 1 CRITICAL) → remediation → this retro → archive
- **Rules skipped or bent in practice**: 6 — three `#409`-shape doctrine claims about code that did not exist yet (caught by readback pre-merge); writers sharing one worktree; a bugfix widening a sampling rule; a spec pinning live fleet numbers
- **Measured wins**: saturation parser BLIND 35 → **0** (35 of 50 iteration tables unreadable by position-based column pick) · subject coverage newly measurable: **148 of 318** niagara modules never cited at proposal time (144 at verify) · `run-all.sh` **471.5 s → 212.9 s** (−55 %; non-hermetic PATH probed real java/ghidra ×15) · SessionStart **26,979 → 6,100** chars · `sweep-retros.sh` **65 s → 56 s → 8.9 s** (one `git log --name-only` walk per target) · HOT-CORE `METHODOLOGY §11` **823 → 664** lines (§11b split) · 22 teeth-less suites made visible (21 shell + 1 n/a) behind `--require-teeth` · 11 unguarded `|| true` → typed states (+2 found later) · `covered_blocks` under `shared-global` 61/61 FAIL → attributed count · block `Type` grammar closed (adoption 8/763, none template-valued) · `FOCUSES.md` status grammar closed (61 rows, 4 words + 4 stray tokens)
- **Gate aggregate at verify time** (`af83e7a`, single execution, this machine — not a tracked figure, `CLAUDE.md §5`): shellcheck 173 files / 0 warnings / exit 0; `run-all.sh` 106/106 suites · 2142 cases · 0 failed; `--prove-teeth` 106/106 · 2589 cases · 0 failed. Cross-checked against probador's independent gate record: **zero discrepancies**
- **Deltas proposed (new)**: 10 (6 new, 4 refinement · 6 HIGH, 4 MEDIUM, 0 LOW) · **Already-covered lessons**: 17 · **Measured dismissals recorded**: 4

## Operator-only items (not kit deltas — no code or doctrine change proposed)

These need a human hand, not a kit change; recorded here so they are not lost between sessions.

- Wire the `retro-gate.sh` Stop hook into each target's `.claude/settings.json` (`research-sdd-init.sh` prints the snippet; propose-never-apply means the kit will not do it).
- Reinstall the `research-sdd` skill — the installed copy is stale; #440 (`2f8dfec`) now detects the drift as a third twin, but detection is not installation.
- Push the local marker commits in `niagara-research` and `nave-panccadia` (merge-sha re-stamps from this campaign, `CLAUDE.md §12.5`).
- Refresh `TARGETS.md`, `FOCUSES.md` and the BREAKTHROUGHS ledger by hand (§8 operator-directed; `TARGETS.md` is never auto-edited).
- Clean up 21 stale `agent-*` worktrees.
- Resolve the orphan openspec change `improve-research-sdd-target-onboarding` (untracked, unarchived).

## Honest verdict

This run genuinely surfaced new material, and the split is worth stating precisely: the campaign's
first day produced eight lessons that are **already doctrine** (`CLAUDE.md §12`, merged mid-campaign as
D11) and this retro re-proposes none of them. What is new comes almost entirely from the campaign's
second half — the verify pass, the remediation, and the two units filed after it (U21, U22) — because
that is where the kit was measured against itself rather than against its own fixtures. Three of the
ten deltas (#1, #3, #7) are the same shape: an instrument that passed every gate it was given while a
question nobody had asked went unanswered — could it RUN, is its enumeration still closed, is its
baseline still the same baseline. Two more (#5, #8) are about numbers that were true when written and quietly
stopped being true. That is a coherent finding, not a list: the kit's §7 doctrine is strong on
"did it look?" and weak on "is what it looked at still the same thing?".

The honest counterweight: #9 and #2 are refinements of rules the kit already has and would not
justify a PR on their own — they are one sentence each on an existing paragraph. And #10 asks for a
measurement before it asks for code, deliberately. A maintainer who applies only #1, #3, #5, #7 and #8
has taken everything this campaign actually paid for.
