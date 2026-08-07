<!-- review-status: pending -->
# Retro - sdd-investigacion / DOCUMENT new-target bootstrap incident / 2026-08-03 / Research-SDD self-retrospective

> Run reviewed: the failed first attempt and successful second attempt to document TradingView MCP capability hardening. Trigger: user-requested incident feedback after DOCUMENT completion.
> Method: current `research-sdd/skills/research-sdd/SKILL.md`, `research-sdd/PROMPT-LOOP.md`, and `research-sdd/METHODOLOGY.md` were read first; the failed response and successful target #23 bootstrap were then compared against those contracts. This report only PROPOSES changes. It does not modify the kit rules or either target.

## Incident summary

DOCUMENT mode received the arbitrary project path `/home/cristian/TRADINGVIEW`, which was not yet present in `TARGETS.md`. The first actor treated missing registration as a prerequisite, stopped, and asked the user to choose a registered corpus or register `tradingview-mcp` manually.

That was the wrong state transition. The user had already requested Research-SDD documentation of the completed TradingView work, so the path was an ad-hoc NEW-target candidate with explicit creation/document intent. Missing registration meant BOOTSTRAP, not BLOCKED.

The corrected execution classified the path as a new target, ran profile/census/tool detection, let `research-sdd-init.sh --corpus auto` choose a nested corpus, registered target #23 `tradingview-mcp`, and completed the three-block DOCUMENT outline. The successful registry row is visible at `research-sdd/TARGETS.md:109`.

## Root cause

1. The actor interpreted `TARGETS.md` as an admission allowlist instead of a registry that BOOTSTRAP extends.
2. The actor ignored established user intent to create and document the TradingView corpus.
3. The relevant rules are distributed across three documents rather than expressed as one executable decision gate.
4. `SKILL.md` also says heavy is "the ONLY mode that bootstraps" even though a new DOCUMENT target must run the mechanical bootstrap before capture. That wording creates avoidable conflict with the ad-hoc-path and DOCUMENT contracts.

## Correct behavior

| Condition | Required action | Forbidden action |
|---|---|---|
| Path absent from `TARGETS.md` plus explicit `new`, create, exhaustive-documentation, or DOCUMENT/CAPTURE intent | Classify as ad-hoc NEW target; announce BOOTSTRAP; run profile, tool detection, census, `research-sdd-init.sh`, and automatic `TARGETS.md` registration; then continue the selected mode | Asking the user to choose an existing corpus merely because no row exists |
| Path absent from `TARGETS.md` without creation intent or depth signal | Run cheap triage and select quick/light unless depth promotes it | Bootstrapping by guesswork |
| Mature/large target with a genuinely ambiguous, expensive investigation angle | Ask one focused angle question | Asking about corpus destination when the subject path is already explicit |

## Proposed kit deltas

> These are refinements to make existing intent executable and internally consistent, not a new target policy.

| # | Proposed change | Target (file / section) | Evidence (block / commit / section / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | Add the decision-table row: `unregistered path + explicit create/document request => BOOTSTRAP; never ask the user to choose a corpus merely because TARGETS lacks a row` | `research-sdd/skills/research-sdd/SKILL.md`, immediately before or inside `Target vs ad-hoc / live-install`; mirror to the installed OpenCode twin through the existing adapter parity path | Failed first response: `Status: BLOCKED` and manual corpus-choice prompt; corrected run registered `TARGETS.md:109` and completed B1-B3 | refinement | HIGH |
| 2 | Change "heavy is the ONLY mode that bootstraps" to "heavy is the only DISCOVERY mode that bootstraps; DOCUMENT may run mechanical new-target bootstrap before its outline cycle" and add a DOCUMENT preflight pointer to BOOTSTRAP steps a-c/b registration while explicitly skipping gap seeding | `research-sdd/skills/research-sdd/SKILL.md` Modes table and `research-sdd/PROMPT-LOOP.md` DOCUMENT CYCLE entry | `SKILL.md:119-123` permits user-requested NEW targets; `PROMPT-LOOP.md:80-128` defines registration/scaffolding; `METHODOLOGY.md:1790-1835` requires target-corpus routing | conflict clarification | HIGH |

- **#1** - The cost is one compact decision row. The impact is large: registration absence can no longer be mistaken for a user decision when explicit intent already resolves the destination.
- **#2** - The cost is one wording correction and one cross-reference. It removes a literal mode conflict and makes clear that DOCUMENT skips discovery backlog seeding, not target scaffolding or registration.

## Already covered (dedupe - proof the retro read the kit first)

- Arbitrary paths may bootstrap a NEW target when depth signals fire or the user asks -> already covered by `research-sdd/skills/research-sdd/SKILL.md:119-123`.
- Questions are allowed only for a genuinely 50/50 expensive choice -> already covered by `research-sdd/skills/research-sdd/SKILL.md:116-117`.
- BOOTSTRAP profiles, detects tools, runs census, registers the target, scaffolds, and adapts the hook -> already covered by `research-sdd/PROMPT-LOOP.md:80-128`.
- DOCUMENT mode routes subject knowledge to the target corpus and mirrors it to Engram -> already covered by `research-sdd/METHODOLOGY.md:1815-1829`.
- The corrected execution successfully registered target #23 with a nested corpus -> evidenced by `research-sdd/TARGETS.md:109` and the completed TradingView B1-B3 corpus.

## Anti-patterns observed

- **Registry-as-allowlist:** treating a missing row as proof that no destination exists, even though BOOTSTRAP owns row creation -> delta #1.
- **Re-asking settled intent:** asking the user to choose/register after the user explicitly requested exhaustive Research-SDD documentation -> delta #1.
- **Mode wording conflict:** interpreting "heavy only" literally and failing to run mechanical bootstrap for a new DOCUMENT target -> delta #2.

## Tools built, adapted, or outgrown

| # | CREATED (path / purpose) | ADAPTED (kit tool / limitation) | OUTGREW (kit tool / reason) | ORACLE (tool / what it sees) | VERDICT (decision / evidence) |
|---|---|---|---|---|---|
| T1 | - | - | - | - | `no` - no tool was created, adapted, or abandoned while recording this incident |

## Metrics

- **Blocks reviewed**: 3 (TradingView B1-B3) / **Section 14 corrections**: 0 / **Rules skipped in practice**: 3
- **Deltas proposed (new/refinement)**: 2 / **Already-covered lessons**: 5

## Honest verdict

The semantic policy already existed, so repeating it as more prose would be noise. The run nevertheless surfaced a genuine instruction-design defect: the decisive branches are scattered, and the heavy-only sentence conflicts with new-target DOCUMENT bootstrap. A compact decision row plus one mode clarification is justified because it converts correct but distributed intent into an executable guard against the exact observed failure.
