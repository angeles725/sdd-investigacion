<!-- review-status: applied 2026-07-29 · kit 07338c6 · all 4 deltas applied to CLAUDE.md §3 and §7 in the same work unit -->
# Retro — sdd-investigacion · kit maintenance marathon · 2026-07-29 · Research-SDD self-retrospective

> Run reviewed: a full-day kit-maintenance session that unblocked a red `main` and applied the accumulated
> retro backlog across nine merged PRs (#107–#115). Trigger: corpus-STOP equivalent — the session closed
> enough open work that the kit's own §18 requires a retrospective. No knowledge blocks authored against
> an external target; this run produced instruments, doctrine, and 3 new test suites.
>
> Method: METHODOLOGY.md §18 and the retro template were read FIRST; the sibling retro
> `retros/2026-07-28-kit-supervision-and-gentle-ai-triage.md` was read for house style. PR bodies
> (#107–#115) were the primary evidence source — commit messages where PR bodies were insufficient.
> The five driver hypotheses (H1–H5) were treated as unverified claims and checked against the merged
> artifacts before acceptance. READ-ONLY on the kit — this report only PROPOSES; kit changes are
> human-reviewed and human-committed (§18).

## What the retro cannot see

This retro reads nine PR bodies and their commits. It cannot see what was tried and abandoned,
how long individual delegation rounds took, which intermediate gate runs produced false confidence
before the quiet-tree run, or which writer prompts produced the first-pass results. Where that gap
matters — particularly for H5 — it is noted rather than papered over.

---

## Proposed kit deltas

> Only genuinely NEW items — anything the kit already encodes is listed under "Already covered", not here.
> Each delta: the concrete change · the target file/section · evidence · priority.

| # | Proposed change | Target (file · §/section) | Evidence (block / commit / § / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | Extend §7 to the false-negative direction: an instrument that resolves a low count must prove it can see ALL forms in the data, not only that it looked | `CLAUDE.md §7` (Anti-Silent-Zero Doctrine) | PR #113 (bare `:NNN` invisible — 52 cites → 0 resolved); PR #115 (`NNN-MMM` range form invisible — 95 cites → 6 resolved, `exit 0`, no warning) | extension | HIGH |
| 2 | Instruments must not imply claims beyond what they measure: a count that tracks a review-status MARKER must say so, not imply it represents open work | `CLAUDE.md §7` | PR #110 (sweep-retros.sh line 172; "stop implying a claim it cannot support"; 20 % delta-count inflation) | extension | MEDIUM |
| 3 | Apply a large delta backlog by DESTINATION FILE rather than by source retro: retro-by-retro application leaves doctrine/code contradictions and interface-declaration errors latent | `CLAUDE.md §3` (Parallel Writers) or new `METHODOLOGY.md §18` guidance | PR #110 "Findings that only parallel work could surface": three specific defects invisible until all files were assembled | new | MEDIUM |
| 4 | Only the quiet-tree gate report is authoritative during concurrent writing: intermediate reports from individual writers are not acceptable evidence of integration correctness | `CLAUDE.md §3` or `§5` (Quality Gates) | PR #110 gates section: "Intermediate gate reports from individual writers were **not** accepted: several reported 'no failures among suites that completed within the timeout', which does not prove what it asserts" | new | MEDIUM |

For each delta above, one line of rationale (WHY it matters, what it costs, expected impact):

- **#1** — §7's existing three-state model (absent/empty/no-match) asks "did you look?"; the false-negative case asks "can you see what you are looking for?" Both directions destroy instrument trust equally (PR #113: "A false negative erodes trust exactly the way a false positive does"). Cost: one additional bullet in §7, referencing the two PRs as concrete cases. Impact: the next parser change cannot hide a form-gap behind a confident zero.
- **#2** — `sweep-retros.sh` tracking a marker while implying it tracked open work inflated the pending backlog by ~20% and cost one re-audit of five retros whose deltas were already applied. Cost: a clarifying rule and a precedent (the inline disclaimer already added to line 172 can be cited as the implementation). Impact: instruments in the WARN-only tier must state what their output represents, not only what they observed.
- **#3** — PR #110 found three cross-file defects only because it applied by destination: (a) a doctrine/code contradiction between `METHODOLOGY.md` (seed `tools/`) and `research-sdd-init.sh` (deliberately not scaffolding it); (b) a registry row declaring a script's second argument as an output directory while the script takes an output file; (c) a DRIFTED verdict in the audit prompt with no field for it in the report template. Each half looked coherent alone. Cost: one paragraph in §18 or §3. Impact: future maintainers applying a large backlog know to assemble the whole picture before declaring done.
- **#4** — "No failures among suites that completed within the timeout" is a category of technically-true false claim — it excludes timed-out suites and says nothing about concurrent failures that resolve standalone. CLAUDE.md §5 already says "skipped ≠ passed" (for the suite-skip case); this is a different escape. Cost: one sentence added to §3 (parallel writers) or §5. Impact: gate reports during concurrent work carry a warning label, and the quiet-tree run is identified as the authoritative close.

---

## Already covered (dedupe — proof the retro read the kit first)

- **Apply a retro delta and flip its marker in the same commit** → already in `METHODOLOGY.md §18` ("Apply and close are the SAME work unit", added by PR #110 `b2ce854` this session — a delta that closed itself on landing).
- **Control-positive for fixture oracles** → already in `METHODOLOGY.md §11` (config-file keyword-poison bullet, "A fixture oracle without a control-positive proves nothing", added by PR #111 `70e362b` this session).
- **Skipped suites ≠ passed suites (basic case)** → already in `CLAUDE.md §5` quality-gate table.
- **Anti-silent-zero, zero-count direction** → already in `CLAUDE.md §7` (absent/empty/no-match three-state model). Deltas 1–2 are extensions, not replacements.
- **Parallel writers on disjoint files only** → already in `CLAUDE.md §3`. Delta 3 proposes guidance on HOW to apply, not WHETHER.
- **Instruments: findings (WARN) vs. operational failures (exit 1)** → already in `CLAUDE.md §8`. That distinction is about error level; delta 2 is about output-claim accuracy.
- **Engram `#id` is not a `[CERT]` citation** → already in `METHODOLOGY.md` (added by PR #111 `70e362b`).
- **Subject version stamping in block headers** → already in `METHODOLOGY.md §4` (added by PR #110 `b2ce854`).
- **DRIFTED vs. REFUTED vocabulary** → already in `METHODOLOGY.md §13` and `PROMPT-AUDIT.md` (added by PR #107 era and this session).
- **MISSING-RETRO and ESCALATED retro lifecycle** → already in `METHODOLOGY.md §18`. PR #111 clarified that MISSING-RETRO overstates loss when the informal channel delivered the content — that nuance is new in prose but the sweeper behavior was not changed; no kit-doc rule needed beyond the existing §18 honesty clause.
- **The kit self-registering in TARGETS.md** → already closed by PR #107; kit is now target 22. No new delta.

---

## Anti-patterns observed (optional)

- **Gate report caveated with a timeout escape.** Writers reporting "no failures among suites that completed within the timeout" claimed a result they could not prove. The caveat sounds responsible but is actually an anti-pattern: it withholds completeness while implying success. → delta #4.
- **Two defects introduced and shipped in the same session that found them.** The self-registration gate false positive (from PR #107's `$KIT` path comparison) and the `render-drawing.sh` interface declaration (wrong second argument) both came from code merged hours earlier. Neither was caught by CI. The quiet-tree run at the close of PR #110 surfaced both. → This argues for delta #4 (quiet-tree authority) but also suggests a LIGHTWEIGHT integration check after each PR merge during a marathon session. Not proposing a new delta because the PR-merge frequency was unusual (9 PRs in one day) and the session did catch both defects before the day ended. Noting here so the pattern is visible.
- **Retro-by-retro application hiding doctrine/code contradictions.** PR #110's explicit finding: three defects were invisible to per-retro application and visible only when the destination files were assembled. → delta #3.

---

## Tools built, adapted, or outgrown

> The session spanned PRs #107–#115. PR #107's tools (sweep-tools.sh, target-paths.sh) are credited to the
> sibling retro. This table covers #108–#115.

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | `tests/harness-sweep-parity.test.sh` · CI path-filter coverage validator with `--list-inputs` derived from the parity test itself | — | — | — | `promote` · already in kit; PR #109 |
| T2 | — | `toolbelt/verify-block.sh` (bt_cites) · could not see bare `:NNN` table-cell form or `:NNN-MMM` range form; 52 cites resolved as 0, 95 resolved as 6 | — | — | `keep + extend` · two citation forms now visible; PR #113, #115 |
| T3 | — | `toolbelt/tests/run-all.sh` · suite-level `^SKIP:` classifier did not recognize the per-test indented output format; skipped suites reported as passed; skipped CASES never counted | — | — | `keep + extend` · PR #115 |
| T4 | — | — | — | — | `no` · no throwaway probes written this session |

---

## Hypothesis verdicts

**H1 — One defect family appeared five times, in different disguises.**

PARTLY CONFIRMED, and the family needs reframing.

The five instances split into two distinct phenomena that share a surface shape but not a mechanism:

- **(a/b/c)** — instruments implying claims they cannot support: `pending` counting markers while read as open work; the delta-count inflated ~20%; MISSING-RETRO overstating knowledge loss when the informal channel had delivered it. PR #111: "a third instance of the same measurement gap this session keeps finding." These are the OUTPUT-CLAIM side of §7 — the instrument did look, but its output implied a claim about reality it could not support. **Not currently in §7.** → delta #2.
- **(d)** — citation parser resolving 0 for a well-cited block because it cannot see the citation form. This is the INPUT-PARSE side: the instrument looked at the right file; it just couldn't see what was there. **Not currently in §7.** → delta #1.
- **(e)** — the `[CERT]` on a catalog number right only by timing — NOT VERIFIABLE from the merged PRs. No PR body mentions it; no kit doc records it; no commit message references it. Discarded.

§7's existing three-state model covers the absent/empty/no-match distinction (input presence), not the output-claim or parser-form dimensions. The generalization is real; it belongs in §7 as two extension bullets rather than a replacement.

**H2 — Two defects fixed today were introduced today.**

CONFIRMED.

PR #112 explicitly: "Two came from code merged hours earlier, in this same session." The self-registration gate false positive (from PR #107's `$KIT` path) and the `render-drawing.sh` interface-declaration error (from a writer in PR #110) both shipped on main before being caught. The quiet-tree gate run at PR #110's close found the second; PR #112 addressed both.

Is there a kit rule that would have caught them earlier? CLAUDE.md §3 requires disjoint file sets for parallel writers, but does not require post-merge verification of gate results. "Verify after merge on a quiet tree" is described in PR #110 as a practice but not as a named rule. → delta #4.

**H3 — Three writer gate reports claimed success without proving it.**

CONFIRMED with direct PR evidence.

PR #110 gates section: "Intermediate gate reports from individual writers were **not** accepted: several reported 'no failures among suites that completed within the timeout', which does not prove what it asserts. Concurrent writers also produced transient suite failures that passed standalone. Only the quiet-tree run above counts."

CLAUDE.md §5's "skipped ≠ passed" covers the SKIP case but not the timeout-escape. The reporting anti-pattern has a different mechanism: the caveat looks responsible but converts a partial result into an implied success. → delta #4.

**H4 — Parallel writers on disjoint files exposed a doctrine/code contradiction.**

CONFIRMED.

PR #110 body: "Findings that only parallel work could surface" lists three specific defects invisible to retro-by-retro application: (a) a doctrine/code contradiction in the `tools/` scaffolding decision; (b) a registry row declaring a script interface that did not exist as described; (c) the DRIFTED audit verdict having no field in the report template. The kit has a rule about parallel writers being on disjoint files; it has no guidance on HOW to sequence application when the destination files overlap across retros. → delta #3.

**H5 — Declared asymmetric bias produced better judgement.**

UNVERIFIABLE from the merged PRs.

The orchestrator describes agents told "marking applied when work remains ERASES that work; marking PARTIAL costs a re-read; when unsure choose PARTIAL" choosing PARTIAL on 2 of 15 and catching 3 orchestrator errors. This phrasing appears in no PR body, no commit message, and no kit doc in the current HEAD. It is plausible as a delegation technique and worth a future experiment, but this retro cannot confirm it from the committed artifacts. Not proposing a delta on unverifiable evidence.

---

## Metrics

- **Blocks reviewed**: 0 (no knowledge blocks authored against an external target)
- **PRs merged this session**: 9 (#107–#115)
- **Retros applied (backfill)**: 9 (written and applied in one session; markers closed)
- **Deltas applied (from 13 pending retros)**: ~74 from backlog + 15 from backfill = ~89 total applied
- **Deltas dismissed with evidence**: 7 (named in PR #110 and #111 bodies)
- **Test suite growth**: 75 suites / 1488 cases → **78 suites / 1548 cases** · 0 failed · 0 skipped
- **Shellcheck**: 128 files, zero warnings (PR #115 final state)
- **Deltas proposed (new)**: 4 · **Already-covered lessons**: 10

---

## Honest verdict

Four deltas are genuinely new and worth adding. They are not the same lesson with different labels:

- Delta 1 closes a gap §7 structurally cannot cover: the parser-form blind spot asks a different question from "did you look."
- Delta 2 closes the output-claim gap §7 also cannot cover: "what does your count represent" is different from "did you look."
- Deltas 3 and 4 are maintenance-practice rules that do not belong to any existing section.

The session spent most of its energy confirming existing doctrine rather than generating new signals. Apply-and-close atomicity, control-positive for oracles, skipped ≠ passed, and seven other rules all fired correctly and would have been correct proposals if the kit did not already carry them. That is the expected outcome of a maintenance session: the infrastructure holds, and the marginal signal is small.

Two caveats on the evidence base: (1) this retro reads merged artifacts, not the intermediate session. It cannot say what was tried and reverted, which delegation prompts produced bad first-pass results, or how much of the session's output came from the orchestrator's in-flight course-corrections rather than the delegation prompts. (2) H5 (asymmetric bias as a delegation technique) was not verifiable and is not proposed — if the technique was used and worked, the evidence did not survive into the merged PRs.

The honest assessment: a maintenance session that applied 89 deltas, added 3 suites, and fixed 5 instrument defects in one day is unusual in scale. The kit's doctrine held under that load. Four extension bullets are the correct yield.
