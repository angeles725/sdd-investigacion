# Block 10 — `sdd-apply` Phase (+ apply-progress continuity)

> **WHAT**: Documents the `sdd-apply` phase of gentle-ai's SDD system: the IMPLEMENTATION. It receives tasks from `tasks.md` and writes real code following specs and design strictly, marks tasks complete, and persists an `apply-progress` that survives across batches through a read-merge-write protocol.
>
> **SCOPE**: Purpose, what it reads/writes (artifact + topic key), the Status & Workspace Guard, the enforcement of the Review Workload Decision, apply-progress continuity (read-merge-write, NOT overwrite), strict TDD forwarding, task checking and marking, assigned model, Result Contract and gotchas. It does NOT cover the detail of the strict-TDD module (that is [Block 23]) nor verification (that is [Block 11]).
>
> **EXACT SOURCES**:
> - `/home/cristian/.config/opencode/skills/sdd-apply/SKILL.md` (primary, v3.0)
> - `/home/cristian/.claude/agents/sdd-apply.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-apply.md` (CONDENSED version — diverges from SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-apply.md` (orchestrator gates)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (Sections A–E)
> - NOTE: `sdd-apply/strict-tdd.md` is documented in [Block 23], NOT here; only its loading is mentioned.
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source; `[INFER]` = deduction.

---

## 10.1 — Purpose and role `[CERT]`

`sdd-apply` is an EXECUTOR sub-agent (IMPLEMENTER): it receives specific tasks from `tasks.md` and implements them by writing real code, following specs and design strictly (`skills/sdd-apply/SKILL.md:32-34`). It is the only phase that mutates project files outside the SDD artifacts.

Same ORCHESTRATOR GATE / Executor Override pattern as the rest (`SKILL.md:13-21`). `delegate_only: true`, `disable-model-invocation: true`, `user-invocable: false` (`SKILL.md:4-10`). Version `3.0` (`SKILL.md:9`).

## 10.2 — What it receives from the orchestrator `[CERT]`

`SKILL.md:36-43`:

| Input | Detail |
|---------|---------|
| Change name | name of the change |
| Specific task(s) | e.g. "Phase 1, tasks 1.1-1.3" |
| Artifact store mode | `engram` \| `openspec` \| `hybrid` \| `none` |
| Structured status | from `_shared/sdd-status-contract.md` ([Block 22]): `schemaName`, `planningHome`, `changeRoot`, `artifactPaths`, `contextFiles`, `applyState`, task progress, dependency states, `actionContext` |
| Delivery strategy + resolved workload decision | `ask-on-risk`/`auto-chain`/`single-pr`/`exception-ok`, plus PR slice or `size:exception` if applicable |

## 10.3 — What it READS and what it WRITES `[CERT]`

`SKILL.md:45-52`:

| Mode | Reads (all required) | Writes |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `/spec`, `/design`, `/tasks` (saves the tasks ID for updates) | `sdd/{change}/apply-progress` + `mem_update` on tasks |
| `openspec` | follows `openspec-convention.md` | updates `tasks.md` with `[x]` marks |
| `hybrid` | both | Engram (`mem_update` tasks) + `tasks.md` with `[x]` |
| `none` | returns progress only | nothing (does not update artifacts) |

**Artifact produced**: `apply-progress` · **topic key**: `sdd/{change-name}/apply-progress` · **type**: `architecture` (`SKILL.md:179-182`, [Block 3]).

Key double write: `sdd-apply` (a) **persists `apply-progress`** AND (b) **marks tasks as `[x]`** via `mem_update` (engram) or file editing (openspec/hybrid) (`SKILL.md:182`). Marking tasks is the exclusive responsibility of this phase (`agents/sdd-apply.md:39`).

## 10.4 — Status & Workspace Guard `[CERT]`

Before reading implementation files or writing code, it consumes the structured status (`SKILL.md:54-64`):

| `applyState` | Action |
|--------------|--------|
| `blocked` | STOP, returns `blocked` with missing artifacts or unsafe context |
| `all_done` | does not edit; returns `success` with `next_recommended: sdd-verify` or `sdd-archive` |
| `ready` | proceeds only on the assigned pending tasks |

Workspace guards (`SKILL.md:62-64`): if `actionContext.mode` is `workspace-planning` and `allowedEditRoots` is empty, STOP before editing (linked repos/folders are read-only). If `allowedEditRoots` is present, edit only under those roots; any edit outside → STOP and report unsafe path.

## 10.5 — Execution steps `[CERT]`

`SKILL.md:66-190`:

1. **Step 1 — Load Skills** (Section A).
2. **Step 2 — Read Context**: confirm `applyState: ready`; read each `contextFiles`; read specs (WHAT the code must do), design (HOW to structure it), existing code (current patterns), conventions from `config.yaml` (`SKILL.md:70-78`).
3. **Step 2a — Enforce Review Workload Decision** (see 10.6).
4. **Step 2b — Read Previous Apply-Progress** (see 10.7).
5. **Step 3 — Read Testing Capabilities & Resolve Mode** (see 10.8).
6. **Step 4 — Implement Tasks (Standard Workflow)** — only if strict TDD is NOT active.
7. **Step 5 — Mark Tasks Complete**: change `- [ ]` to `- [x]`.
8. **Step 6 — Persist Progress** (MANDATORY) + Merge Protocol.
9. **Step 7 — Return Summary**: re-read the persisted tasks artifact and confirm `[x]` before returning.

## 10.6 — Step 2a: Enforce Review Workload Decision `[CERT]`

Before implementing, it inspects the `Review Workload Forecast` of the tasks artifact ([Block 9]). If it says any of (`SKILL.md:80-100`):

- `400-line budget risk: High`
- `Chained PRs recommended: Yes`
- `Decision needed before apply: Yes`

…then it MUST confirm that the orchestrator/user provided a resolved delivery path:

| Case | Action |
|------|--------|
| `auto-chain` / chained/stacked chosen | implement only the assigned work-unit slice, autonomous scope, report the PR boundary; follow `Chain strategy` for branch targeting |
| `exception-ok` / single PR with exception | continue only if the prompt explicitly says the maintainer accepts `size:exception` |
| `single-pr` over budget | continue only after recording `size:exception` |

It also checks `Chain strategy` (`SKILL.md:96-98`): `stacked-to-main` (each PR targets the previous PR, or `main` after merge) vs `feature-branch-chain` (PR #1 → tracker; following ones → immediately previous PR; child diffs never target `main` directly).

> [CERT] If NEITHER the delivery decision NOR the chain strategy are present, STOP before writing code and return `blocked` with: *"Workload decision required before apply: estimated work may exceed 400 changed lines. Ask the user which chain strategy to use..."* (`SKILL.md:100`). The condensed prompt reaffirms it: "If workload forecast says >400 lines or `Chained PRs recommended`, STOP and return `blocked: workload-decision-required`" (`prompts/sdd/sdd-apply.md:25`).

This connects directly with [Block 17] (delivery/chain) and with the orchestrator's Review Workload Guard in [Block 16].

## 10.7 — Step 2b: Apply-Progress Continuity (read-merge-write) `[CERT]`

The distinctive mechanism of this phase. Implementation may run across multiple batches; progress MUST NOT be lost. `SKILL.md:102-112`:

1. `mem_search(query: "sdd/{change-name}/apply-progress", project: "{project}")`.
2. If found: `mem_get_observation(id)` → read full content.
3. Parse which tasks are already marked complete.
4. Skip those tasks — start from the first incomplete one.
5. When saving in Step 6, **MERGE**: include all previously completed tasks PLUS the new ones in a single combined artifact.

> [CERT] **CRITICAL**: "If the orchestrator told you previous progress exists, you MUST read it. If you overwrite without reading, completed work from prior batches is permanently lost" (`SKILL.md:112`).

### Merge Protocol (Step 6) `[CERT]`

`SKILL.md:184-189`: when saving apply-progress, (1) if previous progress was read in 2b, the artifact MUST include ALL previously completed tasks (copying status and evidence) PLUS the new ones; (2) the final artifact shows the accumulated state of ALL tasks across ALL batches; (3) same structure, no completed task from prior batches is lost.

> [CERT-a] The orchestrator reinforces this from its side (CLAUDE.md §"Apply-Progress Continuity"): when it launches a continuation batch, it searches for existing apply-progress and instructs the sub-agent: *"You MUST read it first... merge... Do NOT overwrite — MERGE."* The sub-agent is responsible for the read-merge-write; the orchestrator tells it that previous progress exists.

The condensed prompt confirms it: "If previous apply-progress exists, read it via mem_search + mem_get_observation and MERGE before saving" (`prompts/sdd/sdd-apply.md:26`).

## 10.8 — Step 3: Strict TDD Forwarding `[CERT]`

`SKILL.md:114-145`. It reads the cached testing capabilities to resolve the mode:

```
├── engram: mem_search("sdd/{project}/testing-capabilities") → mem_get_observation
├── openspec: openspec/config.yaml → strict_tdd + testing section
└── Fallback: package.json, go.mod, etc.
```

Mode resolution:

| Condition | Mode |
|-----------|------|
| `strict_tdd: true` AND a test runner exists | **STRICT TDD MODE** → loads and follows `strict-tdd.md` ([Block 23]) |
| `strict_tdd: false` OR no runner | **STANDARD MODE** → uses Step 4, no TDD module loaded |

> [CERT] "If Strict TDD Mode is not active, ZERO TDD instructions are loaded. The `strict-tdd.md` module is never read, never processed, never consumes tokens" (`SKILL.md:135`).

### Hard Gate (Strict TDD only) `[CERT]`

If Strict TDD is active (by orchestrator injection or auto-discovery) (`SKILL.md:137-145`):

- It MUST produce a **TDD Cycle Evidence** table in the apply-progress artifact.
- Each task row: RED (test written first) → GREEN (implementation passes) → REFACTOR.
- If it completes a task WITHOUT writing tests first, mark it FAILED in the table.
- The verify phase REJECTS the work if the TDD table is missing or incomplete.
- "There is no silent fallback" — if you resolved Strict TDD as active, you follow it or report failure; you do NOT silently switch to Standard (`SKILL.md:145`).

> [CERT-a] The orchestrator performs mandatory forwarding (CLAUDE.md §"Strict TDD Forwarding"): it searches `sdd-init/{project}`, and if `strict_tdd: true` it adds to the prompt *"STRICT TDD MODE IS ACTIVE. Test runner: {test_command}. You MUST follow strict-tdd.md..."*. NON-NEGOTIABLE. The cycle detail (RED→GREEN→TRIANGULATE→REFACTOR) lives in [Block 23].

## 10.9 — Steps 4–7: Implement, mark, persist, verify `[CERT]`

- **Step 4 (Standard)**: for each task — read description, spec scenarios (acceptance criteria), design decisions (constraints), existing code patterns; write the code; mark `[x]` immediately; note deviations (`SKILL.md:147-160`).
- **Step 5**: change `- [ ]` → `- [x]` for completed tasks (`SKILL.md:162-172`).
- **Step 6**: persist apply-progress + update tasks with `[x]` + Merge Protocol.
- **Step 7**: BEFORE returning, **re-read the persisted tasks artifact** and confirm that every task reported as complete is marked `[x]` there. If it is still `- [ ]`, fix the checkbox. "Do not report `Ready for verify` while completed work is only reflected in internal todos or apply-progress" (`SKILL.md:191-193`). Internal todos are NOT evidence of completion (`SKILL.md:245`).

## 10.10 — Assigned model and tools `[CERT]`

`agents/sdd-apply.md:7`: `model: sonnet` (Model Assignments [Block 18]: "sdd-apply | sonnet | default | Implementation").

**Tools** (`agents/sdd-apply.md:8`): `Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update`. Note: it has **Bash** (executes code/tests) and **mem_update** (marks tasks `[x]`) — both absent in `sdd-tasks` ([Block 9]).

## 10.11 — Result Contract `[CERT]`

The **agent** (`agents/sdd-apply.md:42-49`):

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence (tasks done / total) |
| `artifacts` | changed files + updated topic_keys |
| `next_recommended` | `sdd-verify` (if all done) or `sdd-apply` again (if tasks remain) |
| `risks` | design deviations, unexpected complexity, blocked tasks |
| `skill_resolution` | `paths-injected` or `none` |

The **SKILL.md** (`SKILL.md:195-235`) defines a richer "Implementation Progress" markdown: Completed Tasks, Files Changed (table), TDD Cycle Evidence (if Strict TDD), Deviations from Design, Issues Found, Remaining Tasks, Workload/PR Boundary, Status. The **condensed prompt** defines a minimalist JSON envelope: `{status: ok|blocked|error, completed_tasks, files_changed, notes}` (`prompts/sdd/sdd-apply.md:45-52`).

## 10.12 — Gotchas `[CERT]`

- **Overwriting apply-progress = permanent loss** (`SKILL.md:112`): the read-merge-write of 2b is the safeguard; skipping it erases prior batches.
- **There is no silent TDD fallback** (`SKILL.md:145`): if Strict TDD was resolved as active, a missing TDD Evidence table makes verify reject ([Block 11], [Block 23]).
- **The condensed prompt diverges from SKILL.md** [CERT — compared]: `prompts/sdd/sdd-apply.md` imposes "Read max 3 files at a time", "Load up to 2 SKILL.md paths", JSON envelope, and reduces the 7 steps to 9 lines. The SKILL.md (v3.0, more complete) is the canonical source; the prompt is the low-budget variant.
- **Mandatory re-reading of tasks before returning** (`SKILL.md:191-193, 245`): internal todos do not count as completion — `sdd-archive` ([Block 12]) blocks if the persisted tasks have stale `- [ ]`.
- **NEVER implement tasks that weren't assigned** (`SKILL.md:251`): strict scope to the assigned batch.
- **STOP on `applyState: blocked` / `all_done` / unsafe actionContext** (`SKILL.md:243`): does not edit.

## 10.13 — Connections

- **[Block 9] (tasks)** → `sdd-apply` reads `tasks` + spec + design + proposal; consumes the Review Workload Forecast in Step 2a (`SKILL.md:49, 80-100`).
- **[Block 10] → [Block 23] (strict-TDD)**: Step 3 loads `strict-tdd.md` only if Strict TDD is active; the Hard Gate requires a TDD Evidence table (`SKILL.md:114-145`).
- **[Block 10] → [Block 16] (Gatekeeper / Review Workload Guard)**: the orchestrator is gatekeeper before/after apply; apply is high-risk → fresh-context review. Step 2a enforces the cached decision.
- **[Block 11] (verify)** → consumes `apply-progress`; `next_recommended: sdd-verify`.
- **[Block 17] (delivery/chain)**: Chain strategy and PR slices guide branch targeting in Step 2a.
- **[Block 3]**: artifact `apply-progress` → `sdd/{change}/apply-progress`.
- **[Block 22] (phase-common + status-contract)**: Sections A–D + structured status (`applyState`, `actionContext`, `allowedEditRoots`).
- **[Block 18] (models)**: sonnet, "Implementation".
