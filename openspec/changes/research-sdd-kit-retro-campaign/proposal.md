# Proposal: research-sdd Kit Retro Campaign (Wave 1)

Store: hybrid (Engram twin `sdd/research-sdd-kit-retro-campaign/proposal`) · Evidence base:
`openspec/changes/research-sdd-kit-retro-campaign/exploration.md` (273 lines, every number measured on `4c100d8`)
and Engram `#8169` `#8173` `#8176` `#8179` `#8180`.

## Intent

Thirty pending §18 retros and one independent kit diagnosis have produced a backlog of measured defects and
harvested doctrine deltas. This change converts that backlog into a chain of small, issue-first PRs whose purpose
is to make the kit's instruments **honest** (CLAUDE.md §7), its doctrine **consistent** (a closed grammar before
every checker), and its tests **bite** — without adding bloat.

Why now: several instruments currently report confident numbers that are wrong, and the mutation gate reports
green over suites that have no mutation controls at all. Trust in the toolbelt output is the asset at risk.

Measured problem statement (exploration §9, §2):

| Fact | Measurement |
|---|---|
| Suites that silently ignore `--prove-teeth` | 22 of 100 — exit 0 under the flag; `run-all.sh:106` forwards and never accounts |
| `sweep-retros.sh` confident `~0` | 4 retros, **all four false negatives** (`deltas=0` branch, `:191`); 9 real heading forms unmatched; 5/30 retros carry no review-status marker |
| Saturation parser blind | 35 of 50 iteration-history tables (issue #420); 8 header shapes, cells `N new`, `none net-new …`, `G12` |
| `verify-state.sh` under `block_scope: shared-global` | FAILs 6/6 sampled focuses (`covered_blocks=19 != 758`); `--sync-state` would write the wrong number (#423) |
| Block `Type` field | template says verify-block reads it, §4 says it does not, `verify-block.sh:80/:151` tells authors to declare it and parses nothing; adoption 8/763 with out-of-domain values (#422) |
| Coverage over the subject | not a kit metric; niagara: 148 of 318 modules (47 %) never cited — direct AUDIT-FIRST gap seed (#421) |
| Unguarded `\|\| true` after a real producer | 11 sites / 7 production files, while 3 sibling files carry written refusals to do exactly this |
| SessionStart cost | 31.3 s / 26,979 chars per session; `sweep-retros-hook.sh` alone 27.08 s / 19,799 chars |
| Installed launcher drift | `~/.claude/skills/research-sdd/SKILL.md` is 5 hunks / 15 lines behind the kit copy; **no instrument looks at the installed copy** |
| Block-file discriminator | hand-rolled at 15 sites / 8 scripts; `lib/` owns no helper; `research-sdd-archive.sh:284` hand-rolls a second retro-marker parser divergent from `lib/retro-status.sh` |

Success looks like: every one of those numbers either fixed or explicitly accounted for, with the fix accepted
against the REAL fleet — never against fixtures alone (CLAUDE.md §7, issue #128).

## Scope

### In Scope — 18 work units, two disjoint owners

Work-unit contract (every row): one approved GitHub issue (`status:approved` + `type:*`) + one PR `Closes #N`,
**≤~300 authored lines**, strict TDD with `--prove-teeth` mutants for any instrument change, and fleet acceptance
diffed against `main` with every new WARN and every exit-code flip hand-classified true or false.

**mejorador — toolbelt scripts, their tests, templates**

| # | Unit | Depends on | Est. lines | Acceptance shape |
|---|---|---|---|---|
| U1 | #420 `research-sdd-status.sh` saturation parser: header-shape + cell-form recognition | — (in flight) | ~250 | BLIND 35→0 or named residue; fleet diff over 50 tables |
| U2 | #423 `verify-state.sh` shared-global `covered_blocks` = blocks attributed to the focus; corpus total → INFO | **D4** | ~200 | 6/6 sampled niagara focuses stop FAILing; non-shared targets unchanged |
| U3 | #421 `coverage-map.sh` (new instrument): coverage over the subject | D6 (§8 para) | ~300 | Runs on 2 targets; reproduces 148 uncited modules; tool-registry row |
| U4 | #424 `research-sdd-status.sh` bold `**pending**` Status cell + WARN on unrecognised tokens | **U1** (same file) | ~120 | §8b "strip at most one leading `**`" honoured; fixture high=0/medium=1 |
| U5 | #422 `verify-block.sh` parses the `Type:` token; ZERO-citation WARN → INFO for synthesis/capture/absence-centred | **D6** (§4 line) | ~200 | Mutant ignoring the token re-raises the WARN on a declared-synthesis fixture |
| U6 | `run-all.sh` teeth accounting: report `Suites without teeth: N — [names]`; opt-in `--require-teeth` fails the run | — | ~150 | 22 named today; never silently green; default behaviour unchanged |
| U7 | `sweep-retros.sh`: distinct "no delta section found" state; surface missing review-status markers; recognise the **enumerated** heading forms | **D6** (§18 line) | ~200 | 4 confident-zero false negatives → typed state; 5 unmarked retros surfaced; no prose regex |
| U8 | SessionStart cost: `sweep-retros-hook.sh` summary mode + profile the 27 s; `verify-tool-catalog-hook.sh` declared-clean sentinel | — | ~200 | <3 k chars from 19.8 k; absent-input targets collapsed to one counted line; #380 precedent |
| U9 | Hygiene bundle: `.gitignore` `.claude/worktrees/`; `verify-kit-clean.sh:30-32` counters + hook companion test; `verify-doc-consistency.sh` exec bit; `templates/hook-sessionstart.sh` path resolution | — | ~200 | Hook stops reporting permanent NOT-clean; counters asserted; no absolute path in a copied artifact |
| U10 | Installed-skill drift: compare kit `SKILL.md` against the installed copy and the OpenCode twin, WARN by hunk | — | ~200 | 15 stale lines detected today; **suite-only, not a new SessionStart hook** (operator decision 2026-08-31) |
| U11 | `lib/block-files.sh`: one block-file discriminator; route `research-sdd-archive.sh:284` through `lib/retro-status.sh` | — | ~300 | Byte-identical output on real corpora before/after at all 15 call sites |
| U12 | The 8 remaining unguarded `\|\| true` after real producers | — | ~250 | Each converted to a typed absent / empty / no-match state with a test that bites |

**explorador — doctrine-only files** (`METHODOLOGY.md`, `PROMPT-LOOP.md`, `DYNAMIC-SETUP.md`, new
`toolbelt/*.md`, kit `CLAUDE.md`). Acceptance = structural readback + probador's quiet-tree gate.

| # | Unit | Content | Est. lines |
|---|---|---|---|
| D1 | §20 + §7 | FREEZE THE LIVE SUBJECT FIRST (md5 drift measured 3×); engram unregistered-target fallback; quick/document-mode items | ~60 |
| D2 | DYNAMIC-SETUP + new doc | §1c raw-image a physical disk when `wsl --mount` fails; headless-Chromium additions; new `toolbelt/DEPLOY-WINDOWS-MINIPC.md`; tool-registry rows for the 15 unregistered operator tools | ~120 |
| D3 | PROMPT-LOOP | SYNTHESIS-GUIDE FOCUS pattern; SECRETS cluster (raw disk image is secret-bearing; inline-over-delegate for secrets-sensitive artifacts; redacted-mask verification; structure-only binary inspection) | ~70 |
| D4 | §16 | FOCUSES.md status grammar (closed vocabulary, §8b style); `covered_blocks` under shared-global; GLOBAL block-number allocation for concurrent lanes; peer-owned dirty tree is read-only; shared-checkout guard (families F1+F3) | ~90 |
| D5 | §3 | Marker-taxonomy DECISION: `[CERT-a]` stays "secondary source"; an agent-gathered citation is `[CERT]` once source-verified and carries no marker until then; coordination notes are not evidence; `[CERT-live]` = running remote service vs `[CERT-hw]` = physical device or offline media image you hold | ~50 |
| D6 | §18 + §4 + §8 | Machine-countable delta declaration MANDATORY; retro trigger extended to applied sessions and post-close addenda; `Type` grammar line; "coverage over the subject" paragraph; New-gaps cell grammar sentence (the **template file itself is mejorador's**) | ~80 |

### Out of Scope — measured dismissals, do not re-propose

- Bayesian saturation model — loses to the naive rule (Brier 0.089 naive-3-zeros vs 0.199–0.299 for every Bayesian variant, 349 transitions).
- Delta-counter prose-regex widening — marginal fleet yield 2 retros; the fix is a negative check, not a wider parser.
- Journal mode; `build-n4-module` kit items (other repo); `corpus-nav.py` items (target tooling).
- D-VB-1 `[BNNN]` / `jar!entry` citation classes — **re-probe only**, no writer (issue #128 trap: 3.6 h closed unmerged).
- Archive close-gate advisory → blocking — maintainer decision, deferred.
- FOCUSES.md drift checker — wave 2, after D4; yield capped at 2 corpora.
- Shared test harness extraction (A15, 2.01× bloat) → separate change `research-sdd-test-harness`.
- HOT-CORE slimming of §11 / §8 → separate follow-up change; needs its own readback design.
- Operator-only, propose-never-apply (listed for the record, nobody edits): `TARGETS.md` / `FOCUSES.md` /
  `BREAKTHROUGHS.md` refreshes, retro renumbering, stale worktrees, the orphan openspec change, running the skill
  installer to refresh the stale installed SKILL.md.

## Capabilities

### New Capabilities
- `kit-instrument-honesty`: typed absent / empty / no-match states, teeth accounting, parser coverage over enumerated real-fleet forms (U1, U2, U4, U6, U7, U12).
- `kit-doctrine-grammar`: closed vocabularies declared in doctrine BEFORE any checker reads them — block `Type`, FOCUSES status, countable delta declaration, New-gaps cell (D4, D6, U5, U7).
- `kit-subject-coverage`: coverage over the research subject as a metric distinct from "gaps closed / known gaps" (U3, D6).
- `kit-session-cost`: SessionStart output budget and declared-clean sentinels (U8).
- `kit-hygiene-portability`: exec bits, gitignore, path resolution in copied artifacts, installed-skill drift, shared `lib/` discriminators (U9, U10, U11).

### Modified Capabilities
- None. `openspec/specs/` does not exist in this repo; there are no published capability specs to delta.

## Approach

**Doctrine first, checker second.** Family F3 (free-form declaration cells no instrument can read) is the single
cause behind five substrates. Every instrument unit that reads a declaration is gated on its doctrine line landing
first: U2←D4, U5←D6, U7←D6, U3←D6.

**Two writers with disjoint file sets** (CLAUDE.md §3): mejorador owns toolbelt scripts + tests + templates,
explorador owns doctrine-only files. Neither touches the other's set; a needed change is reported, not made.
Same-file units are strictly serial (U4 after U1). probador gates every PR on a **quiet tree**: `run-all.sh`,
`--prove-teeth`, `shellcheck` with `globstar`, and the fleet diff — no gate run during a writer window proves
anything.

**Delivery**: auto-chain, issue-first. Doctrine units D1–D6 and independent instrument units run concurrently;
one gate run after the last writer finishes.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `research-sdd/toolbelt/*.sh` | Modified | U1, U2, U4–U9, U11, U12 |
| `research-sdd/toolbelt/coverage-map.sh` | New | U3 |
| `research-sdd/toolbelt/lib/block-files.sh` | New | U11 |
| `research-sdd/toolbelt/tests/**` | New/Modified | Companion suite + teeth for every unit above |
| `research-sdd/templates/` | Modified | New-gaps cell, `Type` domain, countable delta declaration |
| `research-sdd/METHODOLOGY.md`, `PROMPT-LOOP.md`, `DYNAMIC-SETUP.md` | Modified | D1, D3, D4, D5, D6 |
| `research-sdd/toolbelt/DEPLOY-WINDOWS-MINIPC.md` | New | D2 |
| `research-sdd/toolbelt/tool-registry.md` | Modified | D2 rows + U3 row |
| `.gitignore`, `.claude/settings.json` consumers | Modified | U8, U9 |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Writer collision on the same file | Med | Ownership table above; disjoint sets; same-file units serial (U4 after U1) |
| Fleet acceptance flips a WARN or exit code the wrong way | High | Every unit diffs against `main` on the real corpora; each new WARN and each exit-code flip hand-classified true or false before merge |
| U8 changes what **every** session sees | Med | Full output stays available behind a flag; only the default view is summarised |
| U11 touches 8 scripts / 15 call sites | Med | Byte-identical outputs on real corpora before and after; extraction merges only when the diff is empty |
| U10 reads a machine-local path (`~/.claude/skills/…`) | Med | WARN-only, absent-input is a distinct reported state, suite-only — never a hard failure and never a new hook |
| U6 `--require-teeth` breaks an existing workflow | Low | Opt-in flag; default run reports the count and stays green |
| Doctrine unit lands late and blocks its instrument | Med | Doctrine units are small and doc-only; they can be merged ahead of any instrument writer |

## Rollback Plan

Every unit is exactly one PR closing exactly one issue, so rollback is `git revert` of that merge commit alone.
Doctrine units are text-only with no runtime consumer until their paired instrument lands, so reverting one is
inert. New instruments (U3, U11 lib) are additive: reverting removes the file and its registry row. Behaviour
changes in existing instruments (U1, U2, U4, U5, U7, U12) revert to the prior parser with their suites intact.
`--require-teeth` (U6) is opt-in, so a revert cannot un-break a pipeline that never used it.

## Dependencies

- GitHub issues #420 (in flight), #421, #422, #423, #424 already open; the remaining units need issues opened and
  labelled `status:approved` + `type:*` before their PR.
- D4 must merge before U2; D6 must merge before U5, U7, and U3's doctrine sentence.
- Real corpora reachable for fleet acceptance: `niagara-research` (763 blocks) and `panccadia-3d-viewer`.
- The 30 pending retros stay pending until their deltas land; sweeping them closed is operator work.

## Success Criteria

- [ ] Suites without mutation teeth: **22 → 0, or every remaining one named in `run-all.sh` output**.
- [ ] `sweep-retros.sh` confident-zero false negatives: **4 → 0** (typed "no delta section found" state).
- [ ] Saturation parser BLIND tables: **35 → 0**, with any residue named rather than silently skipped.
- [ ] SessionStart output: **26,979 chars → <8,000**; `sweep-retros-hook.sh` <3 k.
- [ ] Installed-skill drift is **detectable by an instrument** (15 stale lines today reported by hunk).
- [ ] Unguarded `|| true` after a real producer: **11 → 0**, each with a test that bites.
- [ ] `coverage-map.sh` runs on **2 targets** and reproduces the 148-uncited-module measurement.
- [ ] `verify-state.sh` shared-global FAIL noise: **6/6 sampled focuses → 0**, non-shared targets unchanged.
- [ ] Every merged PR: ≤~300 authored lines, `Closes #N`, and one quiet-tree gate report with the full aggregate line.
