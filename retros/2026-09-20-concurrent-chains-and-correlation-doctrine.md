<!-- review-status: pending — PROPOSE-NEVER-APPLY, human review before any METHODOLOGY/PROMPT-LOOP edit -->
# Retro — sdd-investigacion (the kit itself) · concurrent chains + correlation-first doctrine · 2026-09-20 · Research-SDD self-retrospective

**Session**: niagara-research, driving multiple heavy chained focuses (`wb-vendor-ux` B1054–B1061, `our-dashboard-audit` B1062–B1065) in parallel with a live client module build (Apillm), commit+push enabled, RDD toggled.

## What happened
Ran several heavy/automatic/chained research runs concurrently while also building a module. Surfaced five process-level frictions that are research-sdd doctrine gaps, not corpus findings. Proposed as deltas for human review — this retro does NOT edit the kit.

## Proposed kit deltas (propose-never-apply) — 6 deltas
| Δ | Delta | Target | Evidence |
|---|---|---|---|
| 1 | **One committing chain per git repo at a time.** Two heavy chains that `gen-catalog` + `git add/commit/push` the SAME repo race on CATALOG.md and non-fast-forward pushes. Doctrine: serialize committing chains per repo (or broaden one chain's backlog) instead of parallel chains on one corpus. | `PROMPT-LOOP.md` (execution modes / chaining) | this session: 2 chains on niagara-research |
| 2 | **MCP `mem_save` fails under concurrent sessions** (`multiple active runtime sessions match`); the engram CLI (`engram save … --project … --topic …`) is the working fallback. Document the CLI fallback in the loop's CLOSE step so agents don't drop the mirror. | `METHODOLOGY.md` §7 state/memory | agent reports: "MCP mem_save had multiple-session conflict → delivered via CLI" (B1061, B1065) |
| 3 | **Executing-delegate contract.** A delegated worker can return a narrated plan with **0 tool calls** (looks done, changed nothing). Brief workers to EXECUTE with real tool calls, and treat `tool_uses == 0` as a failed run to relaunch. | `PROMPT-LOOP.md` DELEGATION | this session: a fork returned 0 tool_uses on the picker/importer task; relaunched as an executing general-purpose agent |
| 4 | **Bulk-commit vs RDD.** When a chain commits per block under receipt-driven development, every commit trips the review stop-hook (non-blocking but noisy, and races produce `unrelated target status is inconsistent`). Doctrine: for bulk autonomous research commits, the operator disables RDD clone-local (`gentle-ai review mode disable --scope clone`) for that repo; re-enable for deliberate work. | `PROMPT-LOOP.md` (commit/push + gates) | this session: RDD churn on niagara-research → disabled clone-local |
| 5 | **Correlation-first exploration doctrine (§22, UNCONFIRMED).** Elevate the B1061 §1061.6 draft: a four-lens survey (congruences / correlations / divergences / absences) + a variable taxonomy (`PATTERN-<n>` / `EXCEPTION-<module>` / `DEPENDENCY-<a>-<b>` / `SIMILARITY-<a>-<b>`) for multi-module focuses. Human review before it becomes a rule — user said "todavía no hay que asegurarlo". | `METHODOLOGY.md` new §22 | corpus B1061 §1061.6 |
| 6 | **Blocker-scoped focus pays off fastest.** In a combined build+research session, a focus scoped to an ACTIVE bug/gap in the module under construction unblocks the build immediately — `wb-field-editors` (opened for the live `targetOrd` File-Chooser bug) surfaced the zero-code `@BFacets(targetType)` fix in one run (B1085), which the running build agent then applied. Doctrine: when a build hits a WB/framework wall, spin a focused research block on that exact wall before hand-coding a workaround, and hand the finding to the in-flight build via a teammate message. | `PROMPT-LOOP.md` (focus selection / build↔research handoff) | this session: wb-field-editors B1085 → Apillm targetOrd facet fix |

## Lessons
- Heavy + automatic + chained scales, but the CONSTRAINT is the single shared git repo + single-candidate RDD + single-session engram — coordinate those, don't parallelize blindly.
- The correlation-first doctrine (Δ5) came out of a real multi-module focus (wb-vendor-ux); it earned a proposal, not yet a rule.

---
**Status**: PENDING — human review. Does not edit METHODOLOGY.md / PROMPT-LOOP.md.
