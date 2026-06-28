# Block 9 — `sdd-tasks` Phase (+ Review Workload Forecast)

> **WHAT**: Documents the `sdd-tasks` phase of gentle-ai's SDD system: the breakdown of a change into a checklist of implementation tasks ordered by phase, plus the `Review Workload Forecast` that protects the 400-line review budget.
>
> **SCOPE**: Purpose, input/output contract, what it reads and what it writes (artifact + topic key), the `tasks.md` format, task-writing rules, the Review Workload Forecast (line estimation, chained PRs recommendation, plain-text guard lines), assigned model, Result Contract and gotchas. It does NOT cover task execution (that is `sdd-apply`, [Block 10]) nor the delivery/chain strategy in detail ([Block 17]).
>
> **EXACT SOURCES**:
> - `/home/cristian/.config/opencode/skills/sdd-tasks/SKILL.md` (primary)
> - `/home/cristian/.claude/agents/sdd-tasks.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-tasks.md` (identical to SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (Sections A–E)
> - NOTE: there is no `commands/sdd-tasks.md`; the phase is triggered via `/sdd-continue` or `/sdd-ff` (orchestrator), not as a direct command.
>
> **METHOD**: direct reading of the cited files. Markers:
> - `[CERT]` = verified by reading the file (cites `path:line` or `path §section`).
> - `[CERT-a]` = asserted by one source, not re-verified at the ultimate origin.
> - `[INFER]` = my own deduction.

---

## 9.1 — Purpose and role `[CERT]`

`sdd-tasks` is an EXECUTOR sub-agent responsible for creating the TASK BREAKDOWN. It takes proposal, specs and design and produces a `tasks.md` with concrete, actionable implementation steps organized by phase (`skills/sdd-tasks/SKILL.md:32-34`). It does not implement: it produces only the checklist (`agents/sdd-tasks.md:23` — "Do NOT implement — produce the checklist only").

The SKILL opens with the standard **ORCHESTRATOR GATE** of all SDD phases: if you loaded the skill via `skill()` you are the ORCHESTRATOR and you must DELEGATE to the sub-agent, not run inline (`SKILL.md:13-17`). The **Executor Override** flips the rule: if you ARE the sub-agent, you execute directly, you don't delegate or call the Skill tool (`SKILL.md:19-21`). This gate/override duality is common to all phases ([Block 22], `_shared/sdd-phase-common.md` §boundary).

It is a `delegate_only: true` sub-agent (`SKILL.md:10`), `disable-model-invocation: true`, `user-invocable: false` (`SKILL.md:4-5`): it is never invoked by the model or the user directly, only by the orchestrator.

## 9.2 — What it receives from the orchestrator `[CERT]`

`SKILL.md:36-41`:

| Input | Values |
|---------|---------|
| Change name | name of the change |
| Artifact store mode | `engram` \| `openspec` \| `hybrid` \| `none` ([Block 3]) |
| Delivery strategy | `ask-on-risk` \| `auto-chain` \| `single-pr` \| `exception-ok` ([Block 17]) |

The `delivery strategy` is the key input that connects this phase with the delivery strategy ([Block 17]): it determines whether the Review Workload Forecast requires a decision before `sdd-apply`.

## 9.3 — What it READS and what it WRITES `[CERT]`

Execution and persistence contract (`SKILL.md:43-50`), which delegates to Sections B (retrieval) and C (persistence) of `_shared/sdd-phase-common.md`:

| Mode | Reads (all required) | Writes |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `sdd/{change}/spec`, `sdd/{change}/design` | `sdd/{change}/tasks` |
| `openspec` | follows `_shared/openspec-convention.md` | `openspec/changes/{change}/tasks.md` |
| `hybrid` | Engram (primary) + filesystem fallback | BOTH: Engram + `tasks.md` |
| `none` | returns inline | nothing (never creates/modifies files) |

**Artifact produced**: `tasks` · **topic key**: `sdd/{change-name}/tasks` · **type**: `architecture` (`SKILL.md:206-208`, [Block 3]).

KEY DEPENDENCY: it reads **proposal + spec + design** (`SKILL.md:47`). `agents/sdd-tasks.md:18-25` explicitly lists spec and design as required via `mem_search → mem_get_observation`; SKILL.md adds proposal. This closes the dependency graph: tasks is the confluence of spec ([Block 7]) and design ([Block 8]) in the DAG ([Block 2]).

> [CERT] Section B warns: `mem_search` returns 300-char PREVIEWS, NOT full content. You must call `mem_get_observation(id)` for EACH artifact, in parallel (`_shared/sdd-phase-common.md:21-35`). Skipping it "produces wrong output".

## 9.4 — Execution steps `[CERT]`

`SKILL.md:54-209`:

1. **Step 1 — Load Skills**: Section A of the common (skills injected by the orchestrator, or fallback to registry) (`SKILL.md:54-55`).
2. **Step 2 — Analyze the Design**: identify all files to create/modify/delete, the dependency order, and the testing requirements per component (`SKILL.md:57-63`).
3. **Step 3 — Write tasks.md**: in `openspec`/`hybrid` it creates the physical file; in `engram`/`none` it composes the content in memory, without creating `openspec/` directories (`SKILL.md:64-76`).
4. **Step 4 — Persist Artifact** (MANDATORY): Section C, artifact `tasks`, topic_key `sdd/{change}/tasks`, type `architecture` (`SKILL.md:201-208`).
5. **Step 5 — Return Summary**: envelope with per-phase breakdown + Review Workload Forecast (`SKILL.md:210-241`).

## 9.5 — `tasks.md` format `[CERT]`

`SKILL.md:78-129`. Structure:

```markdown
# Tasks: {Change Title}

## Review Workload Forecast
   (table + plain-text guard lines — see 9.6)

### Suggested Work Units
   (table: Unit | Goal | Likely PR | Notes)

## Phase 1: Foundation / Infrastructure
- [ ] 1.1 {concrete action — which file, what change}
## Phase 2: Core Implementation
## Phase 3: Testing / Verification
## Phase 4: Cleanup / Documentation
```

Hierarchical numbering `1.1, 1.2, 2.1...` (`SKILL.md:249`). Organization by phases (`SKILL.md:178-199`): Foundation → Core → Integration/Wiring → Testing → Cleanup. Tasks MUST be ordered by dependency: Phase 1 tasks cannot depend on Phase 2 (`SKILL.md:246`).

### Task-writing rules `[CERT]`

Each task must be (`SKILL.md:131-140`):

| Criterion | Example ✅ | Anti-example ❌ |
|----------|-----------|-----------------|
| **Specific** | "Create `internal/auth/middleware.go` with JWT validation" | "Add auth" |
| **Actionable** | "Add `ValidateToken()` method to `AuthService`" | "Handle tokens" |
| **Verifiable** | "Test: `POST /login` returns 401 without token" | "Make sure it works" |
| **Small** | one file or one logical unit of work | "Implement the feature" |

Additional rules (`SKILL.md:243-254`): always reference concrete paths; testing tasks reference specific scenarios from the specs; each task completable in ONE session; NEVER vague tasks like "implement feature". If the project uses TDD, integrate test-first tasks: RED (failing test) → GREEN (make it pass) → REFACTOR (`SKILL.md:252`, see [Block 23]).

> [CERT] **Size budget**: the tasks artifact MUST stay under **530 words**; each task 1–2 lines max; checklist format, not paragraphs (`SKILL.md:253`).

## 9.6 — Review Workload Forecast `[CERT]`

The distinctive heart of this phase. Before finishing, `sdd-tasks` estimates whether the implementation will exceed the **400-changed-line review budget** (`additions + deletions`) — it is a planning guard, not an exact diff count (`SKILL.md:142-146`).

Signals to use (`SKILL.md:146`): number of files, phases, integration points, tests, docs, generated artifacts, migrations and how many concerns the change crosses.

### Forecast table `[CERT]`

`SKILL.md:83-97`:

| Field | Value |
|-------|-------|
| Estimated changed lines | estimate or range |
| 400-line budget risk | Low / Medium / High |
| Chained PRs recommended | Yes / No |
| Suggested split | single PR or PR 1 → PR 2 → PR 3 |
| Delivery strategy | ask-on-risk / auto-chain / single-pr / exception-ok |
| Chain strategy | stacked-to-main / feature-branch-chain / size-exception / pending |

### Plain-text guard lines (literal contract) `[CERT]`

CRITICAL: the forecast MUST include these EXACT plain-text lines so the downstream guards match them literally (`SKILL.md:165-174`):

```text
Decision needed before apply: Yes|No
Chained PRs recommended: Yes|No
Chain strategy: stacked-to-main|feature-branch-chain|size-exception|pending
400-line budget risk: Low|Medium|High
```

The table is for readability, but **the plain-text lines are the guard contract** (`SKILL.md:174`). The orchestrator matches them literally in the "Review Workload Guard" before launching `sdd-apply` ([Block 16]/[Block 17]). This is confirmed in `_shared/sdd-phase-common.md:102-103` (Section E): "The forecast MUST include exact plain-text guard lines".

### Forecast logic when risk is High `[CERT]`

If the estimate is **High** or likely >400 lines (`SKILL.md:148-161`):

1. Mark `Chained PRs recommended: Yes`.
2. Split the tasks into **work units** that can become chained or stacked PRs.
3. Each suggested PR must have a clear start, clear end, verification and autonomous scope.
4. **Ask the user which chain strategy to use** (team decision):
   - **Stacked PRs to main** — each PR merges to main in order; fast iteration.
   - **Feature Branch Chain** — the tracker branch accumulates the final integration; PR #1 targets the tracker, the following ones target the immediately previous PR branch; only the tracker merges to main.
   - **size:exception** — a single PR with maintainer approval (generated code, migrations, vendor diffs).
5. Cache the choice and set `Decision needed before apply` according to delivery strategy:

| Delivery strategy | Decision needed before apply |
|-------------------|------------------------------|
| `ask-on-risk` | `Yes` — orchestrator asks before apply |
| `auto-chain` | `No` — orchestrator proceeds with the first slice |
| `single-pr` | `Yes` — orchestrator must require `size:exception` before apply |
| `exception-ok` | `No` — maintainer already accepted `size:exception` |

For `feature-branch-chain`, the work units SHOULD name the base boundary: PR #1 base = tracker branch; PR #2 base = PR #1 branch; PR #3 base = PR #2 branch. If a child PR were to show changes from the previous PR, the base is wrong and you must re-target/rebase before reviewing (`SKILL.md:176`).

> [CERT] "Do not bury this in prose. Put the forecast near the top of the tasks artifact so the user sees it before implementation starts" (`SKILL.md:163`).

## 9.7 — Assigned model `[CERT]`

`agents/sdd-tasks.md:6`: `model: sonnet`. Matches the orchestrator's Model Assignments table ([Block 18]): "sdd-tasks | sonnet | default | Mechanical breakdown". The reasoning: the breakdown is mechanical, not architectural (unlike propose/design, which use opus).

**Tools** (`agents/sdd-tasks.md:7`): `Read, Edit, Write, Grep, Glob, mem_search, mem_get_observation, mem_save`. Note: it does NOT have `mem_update` (it does not mark tasks complete — that is `sdd-apply`'s job) nor `Bash` (it does not execute anything).

## 9.8 — Result Contract `[CERT]`

Two formats coexist. The **agent** (`agents/sdd-tasks.md:37-46`) defines the structured envelope:

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence (total tasks, parallel vs sequential) |
| `artifacts` | topic_keys/paths (e.g. `sdd/{change}/tasks`) |
| `next_recommended` | `sdd-apply` |
| `risks` | task dependencies that create bottlenecks |
| `skill_resolution` | `paths-injected` or `none` |

The **SKILL.md** (`SKILL.md:210-241`) also defines a markdown "Return Summary" with a per-phase breakdown table + a "Review Workload Forecast" section repeated in the envelope. Both refer to Section D of the common ([Block 2], [Block 22]). `next_recommended` is always `sdd-apply` ([Block 10]).

## 9.9 — Gotchas `[CERT]`

- **The plain-text forecast lines are load-bearing**: if they are missing or change wording, the orchestrator's Review Workload Guard does not match and the 400-line guard breaks silently (`SKILL.md:165-174`).
- **530 words is a hard ceiling** for the tasks artifact (`SKILL.md:253`): verbose forecasts compete with the tasks for that budget.
- **It does not mark `[x]`**: tasks creates everything as `- [ ]`; marking completion is the exclusive responsibility of `sdd-apply` ([Block 10]) and validated by `sdd-archive` ([Block 12]).
- **There is no `/sdd-tasks` command** [CERT — verified: `ls commands/` does not list it]: the phase runs only inside orchestrated `/sdd-continue` or `/sdd-ff`.
- **The prompt `prompts/sdd/sdd-tasks.md` is byte-identical to SKILL.md** [CERT — compared]: unlike apply/verify, tasks has no divergent condensed version.

## 9.10 — Connections

- **[Block 7] (spec) and [Block 8] (design)** → `sdd-tasks` reads them as required dependencies (`SKILL.md:47`, `agents/sdd-tasks.md:19-20`). DAG confluence ([Block 2]).
- **[Block 9] → [Block 17] (delivery/chain)**: the Review Workload Forecast produces `Chained PRs recommended`, `Chain strategy` and `Decision needed before apply`, which [Block 17] consumes. The delivery strategy enters as input (`SKILL.md:41`).
- **[Block 10] (apply)** → consumes the forecast via Step 2a "Enforce Review Workload Decision"; `next_recommended: sdd-apply`.
- **[Block 16] (Gatekeeper / Review Workload Guard)**: the orchestrator inspects the forecast after tasks and before apply.
- **[Block 23] (strict-TDD)**: if TDD is active, the tasks are integrated as RED→GREEN→REFACTOR (`SKILL.md:252`).
- **[Block 3] (backends + topic keys)**: artifact `tasks` → `sdd/{change}/tasks`.
- **[Block 22] (phase-common)**: Sections A (skills), B (retrieval), C (persistence), D (envelope), E (Review Workload Guard).
