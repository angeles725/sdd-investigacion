<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — sdd-investigacion · doctrine-lane 7-units + teeth/design/basing deltas · 2026-08-28 · Research-SDD self-retrospective

> Run reviewed: 2026-08-28 doctrine lane for the research-sdd kit — one leg of an autonomous 3-session
> team (investigador2 = doctrine, investigador = scripts, colaborador = verify-only). Seven additive
> doctrine units shipped and merged to main (db5ed3f). Trigger: session-close equivalent — the lane
> exhausted its high-value backlog and the kit's own §18 requires a retrospective.
>
> Method: METHODOLOGY.md §18 and the retro template were read FIRST; the sibling retro
> `retros/2026-07-29-kit-maintenance-marathon.md` was read for house style. Primary evidence sources:
> engram observations #7781 (session-complete summary) and #7783 (final verification state), plus
> FABLE-lesson feedback #7768 and colaborador lesson #7771. PR bodies and merged kit text confirmed
> specific incidents. READ-ONLY on the kit — this report only PROPOSES; kit changes are
> human-reviewed and human-committed (§18).

---

## What was shipped (7 units merged · main = db5ed3f · verified CLEAN)

All seven doctrine units were additive, coupling-free, double-gated (FABLE review + quiet-tree suite),
and archived. Final quiet-tree verification on the merged main: **100 suites / 1932 cases / 0 failed /
6 skipped; shellcheck 162 files / 0 warnings / exit 0**.

| PR | Change name | What was added |
|---|---|---|
| #384 | define-targets-maturity-schema | `TARGETS.md` legend: `/`-delimiter, out-of-parenthetical placement, legend↔checker alignment |
| #385 | research-sdd-final-attempt-gate | `METHODOLOGY §21.5` — prescribe-first, 3-constraint bound; colaborador caught a §8 miscite pre-merge |
| #386 | consolidate-section13-sweep-doctrine | `§13`: 8 sweep rules; C3 merge/split → one independence+depth test; numeric-estimate anchor |
| #387 | research-sdd-sweep-caveats-doctrine | `PROMPT-LOOP VERIFY-BEFORE-ACTING`: systematic-offset + hidden-flag Go-CLI caveats |
| #389 | research-sdd-section12-live-install-doctrine | `§12` static-install boundary: installed≠running; `NIAGARA_HOME=mutation` canonical test |
| #390 | research-sdd-section5-version-tag-pinning | `§5`: exact-tag pinning, driver re-verify, `.go=[CERT]` per §3, `sources/go-src/<tag>/` |
| #391 | research-sdd-runtime-path-and-own-surface-doctrine | `§12` module-loaded≠path-taken + `§21.2` own-surface-first pre-check; §21 wall now one escalation |

The §21 wall protocol now reads as one escalation sequence:
own-surface → chain → provision (§21.4) → §21.5 final-attempt → typed block.

---

## Discipline held (worth recording)

- **§7 already-done recheck** ranked out the §14 back-pointer as a false positive (already applied).
  No delta proposed for something the kit already covers.
- **§6 incidence-gating** ranked out signing-pki-live D2 (1 incident + murky compound origin) and two
  `REMITTANCE`/`RETURN-CONTRACT` 0-incidence lines. Zero observed occurrences is verifier discipline,
  not a backlog item (CLAUDE.md §7 last paragraph).
- **DELIBERATELY STOPPED at 7 units.** High-value backlog exhausted; no Unit 8 was manufactured to
  sustain speed optics. Solidity over speed-theater.

---

## Proposed kit deltas

> Only genuinely NEW items — anything the kit already encodes is listed under "Already covered", not here.
> Each delta: the concrete change · the target file/section · evidence · priority.

| # | Proposed change | Target (file · §/section) | Evidence (block / commit / § / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | `sdd-design` phase agents must NOT edit source files; a design phase produces the design artifact only. Delegation prompts must include "artifact only, no file edits" or the agent must run worktree-isolated | `CLAUDE.md §3` (Parallel Writers / delegation guidance) | Unit 7 sdd-design agent stray-edited live `METHODOLOGY.md` on the shared checkout during the 2026-08-28 session; discarded via `git restore`; apply re-ran from scratch | new | HIGH |
| 2 | Red-before-fix must be EXECUTED against the pre-fix SUT before any test-bearing change is accepted; a "RED before fix" comment in code is NOT verified teeth | `CLAUDE.md §4` (Strict TDD) and `§5` (Quality Gates) | FABLE blocked PR #388 because tests 52–56 passed on the pre-fix SUT (targets inside kit sandbox → nc-contradiction unresolved++ suppressed the clean line regardless of the attention gate under test); a two-layer review missed it; FABLE caught it in one run (#7768, #7771) | new | HIGH |
| 3 | Worktree branches must be based on `origin/main` EXPLICITLY (`git fetch` + `git checkout -B <branch> origin/main`); never on the shared checkout's local HEAD, which can be many merges stale | `CLAUDE.md §3` (Parallel Writers / worktree guidance) | 2026-08-28: local HEAD was `ec9c2a2`; `origin/main` was `f53c0f8`→`db5ed3f`; 3-way merges stayed clean only because the overlapping sections were non-overlapping — verified, not guaranteed | new | MEDIUM |

For each delta above, one line of rationale (WHY it matters, what it costs, expected impact):

- **#1** — A design-phase agent with live tool access can silently overwrite production files, discarding
  previous work and breaking invariants. Saying "artifact only, no file edits" in the delegation prompt
  is zero cost; worktree isolation adds a branch but is self-contained. Impact: design phases never
  corrupt the shared checkout again.
- **#2** — "RED before fix" written as a comment satisfies a reader but proves nothing. The FABLE
  incident showed that two independent review layers missed vacuous teeth that a single pre-fix-SUT run
  caught immediately. Cost: one standing rule in §4/§5 (one sentence each) + a concrete procedure
  (swap SUT bytes, run new tests, require each to fail). Impact: vacuous teeth are caught at acceptance
  time, not at FABLE review time.
- **#3** — A stale local HEAD produces 3-way merges whose cleanliness depends on which sections were
  edited. A clean merge does not prove correct basing. Cost: two git commands in the worktree setup
  checklist. Impact: no session's worktree silently diverges from the canonical state of `origin/main`.

---

## Already covered (dedupe — proof the retro read the kit first)

- **Solidity over speed: stop when the high-value backlog is exhausted** → already in `METHODOLOGY.md §18`
  (honesty clause: "A retro that always finds something is noise, not signal").
- **Strict TDD: a test that never goes red is theater** → already in `CLAUDE.md §2`. Delta #2 does not
  replace this; it adds the concrete EXECUTION step (swap SUT, run, require red) that makes the
  principle verifiable in practice.
- **Worktrees must have their own `.codegraph/` index** → already in `CLAUDE.md §3`. Delta #3 is about
  branch basing, not index isolation.
- **Parallel writers on disjoint file sets only** → already in `CLAUDE.md §3`. Delta #1 addresses the
  design-agent case (which is not a parallel-writer scenario; it is a single delegated agent with
  tool-accessible live files).
- **Instruments: findings (WARN) vs. operational failures (exit 1)** → already in `CLAUDE.md §8`.
  Not touched by any delta above.
- **Incidence-gating before scheduling remediation** → already in `CLAUDE.md §7` (last paragraph).
  Confirmed correct application in the discipline-held section above.
- **Re-verify the merged result (§5 quiet-tree discipline)** → already in `CLAUDE.md §5`. Applied
  correctly this session; confirmed CLEAN at db5ed3f. No new delta needed.

---

## Anti-patterns observed

- **sdd-design agent editing live source files.** Unit 7's design delegation had no "artifact only"
  guard; the agent wrote directly to `METHODOLOGY.md` on the shared checkout. Caught via `git status`,
  discarded via `git restore`. → delta #1.
- **Vacuous teeth hidden behind a "RED before fix" comment.** PR #388's tests 52–56 had the assertion
  direction correct but placed fixtures inside the kit sandbox, so the nc-contradiction path fired
  regardless of the gate under test. The tests were green on the pre-fix SUT too. Two review layers
  (a runtime harness + a conversion-integrity audit) missed it; FABLE caught it in one run. → delta #2.
- **Branch based on stale local HEAD.** All seven unit branches started from local `ec9c2a2` while
  `origin/main` advanced to `db5ed3f` (seven merges ahead). The 3-way merges were clean because the
  edited sections did not overlap — but this is luck, not design. → delta #3.

---

## Tools built, adapted, or outgrown

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | colaborador built `acid-prefix-sut.sh` (assembles pre-fix SUT + new test files, runs them, requires each named gate test RED on pre-fix) | — | — | `acid-prefix-sut.sh` · SEEs whether a named test actually fails on old code rather than recomputing the logic under test | `promote` · corpus-agnostic pre-fix-SUT teeth prover; first iteration keyed on keyword "ABSENT" (false positive on test 25, false negative on test 60) — re-cut to enumerate gate-test numbers per suite (#7771); needs test under `toolbelt/tests/` before promotion |
| T2 | — | — | — | — | `no` · no other throwaway probes this lane |

---

## Metrics

- **Blocks reviewed**: 0 (no knowledge blocks against an external target; kit-maintenance lane)
- **PRs merged this session**: 7 (#384, #385, #386, #387, #389, #390, #391)
- **PR blocked and re-audited**: 1 (#388 — FABLE blocked for vacuous teeth; resolved and re-audited
  by investigador2's independent flip-prover, 64 passed / 0 failed on corrected branch 76d0ba9)
- **Doctrine units ranked out by §6/§7**: 3 (signing-pki-live D2 + 2 zero-incidence lines)
- **Test suite final state**: 100 suites / 1932 cases / 0 failed / 6 skipped
- **Shellcheck final state**: 162 files / 0 warnings
- **Deltas proposed (new)**: 3 · **Already-covered lessons**: 7

---

## Honest verdict

Three deltas are genuinely new and warrant adding. They are not restatements of existing doctrine:

- Delta 1 (design-agent file-edit guard) is not covered by §3's parallel-writer disjoint-files rule,
  which addresses concurrent writers, not a single delegated design agent with live tool access.
- Delta 2 (executed RED-before-fix) extends §4's "test must go red" principle into a concrete
  operational step that two review layers provably cannot substitute for; the gap was demonstrated, not
  hypothesized.
- Delta 3 (explicit origin/main basing) is not covered by the worktree `.codegraph/` isolation rule;
  it addresses branch basing, which is a separate concern.

The session produced exactly seven doctrine improvements and stopped there. No coverage was manufactured
to inflate the yield. The discipline-held section records three deliberate non-proposals (false
positive, two zero-incidence), which is the expected output of incidence-gating applied correctly.

One caveat: the stale-HEAD risk (delta #3) was verified-not-assumed — all seven merges were confirmed
clean on the merged tree. The retroactive finding is real; the harm was averted by the section-
non-overlap coincidence, not by process.
