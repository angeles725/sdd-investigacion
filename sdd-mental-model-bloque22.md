# Block 22 — Skill-resolver + phase-common + status-contract

> **RDD INSTABILITY NOTICE**: Parts of this block document surfaces on the **Receipt-Driven Development (RDD)** line, which upstream declares unstable since `gentle-ai v1.47.0` (`README.md:21`). Specifically: the `sdd-attempt` command (§22.3 native engine and dependency states), the `remediationState` / `reviewGate` / `reviewTransaction` fields in the status schema, the `review` / `remediate` / `resolve-review` tokens in `nextRecommended`, and the receipt-based `archive` readiness condition. The skill-resolver protocol (§22.1), the phase-common boilerplate (§22.2), and the core status schema fields (§22.3, non-RDD fields) pre-date RDD and are stable. RDD-specific details carry an explicit stability caveat.
>
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.

> **WHAT IT DOCUMENTS**: This block documents three shared contracts that underpin the mechanics of delegation and phase execution: (1) the **Skill Resolver Protocol** — how a delegator resolves relevant skills from the registry and passes `SKILL.md` paths (not summaries) to sub-agents; (2) the **SDD Phase Common Protocol** — the identical boilerplate that every phase loads (skill loading, artifact retrieval, persistence, return envelope, review workload guard); (3) the **SDD Status and Instructions Contract** — the structured status schema that acts as the handoff between orchestrator and phase executor.
> **SCOPE**: The three cross-cutting delegation/execution/status contracts. It does NOT cover the detail of each phase (see the phase blocks) nor the persistence modes (see [Block 19]). The status contract here is the foundation that [Block 15] uses for the dispatcher; here the schema is documented, there its operational routing.
> **SOURCES** (read and verified at v2.2.0):
> - `/home/cristian/.config/opencode/skills/_shared/skill-resolver.md` (full file, 73 lines — unchanged)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (full file, 114 lines)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-status-contract.md` (full file, 160 lines by `wc -l` — [DRIFTED v1.43.2→v2.2.0]: previously documented as 124 lines)
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section` where possible. `[CERT-a]` = asserted by the source but not re-verified in its primary origin. `[INFER]` = my own deduction, not literal in the source. `[DRIFTED v1.43.2→v2.2.0]` = true then, false now — old fact kept visible.

---

## 22.1 — Skill Resolver Protocol `[CERT]`

Any agent that **delegates work to sub-agents** MUST use this protocol to resolve relevant skills and pass them safely `[CERT]` (`skill-resolver.md:1-3`).

**Why it exists** `[CERT]` (`skill-resolver.md:5-7`): sub-agents start with no project skill context. The registry gives delegators a cheap index of available skills WITHOUT rewriting or summarizing those skills.

**When to apply** `[CERT]` (`skill-resolver.md:9-11`): before every sub-agent launch that involves reading, writing, reviewing, testing, documenting, or creating project artifacts. Skip only for purely mechanical commands.

### The four steps of the protocol `[CERT]`

**Step 1 — Obtain the Skill Registry** `[CERT]` (`skill-resolver.md:15-23`). The registry is an **index** of skill names, triggers, scopes, and exact `SKILL.md` paths — NOT a bundle of compacted rules. Resolution order:

1. Use the session cache if present.
2. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` for full content.
3. Fallback: read `.atl/skill-registry.md` from the project root.
4. No registry → proceed without project skills and warn the user to run `gentle-ai skill-registry refresh`.

**Step 2 — Match relevant skills** `[CERT]` (`skill-resolver.md:25-34`) along two dimensions:

| Context | Match against |
|----------|-----------------|
| Code/files | The registry trigger/description mentions the language, framework, tool, or path context |
| Task/action | The trigger/description mentions actions like PR, review, docs, tests, Jira, comments, release |

Prefer the smallest useful set. If more than five skills match, keep the five most relevant and **prioritize code context over task context**.

**Step 3 — Pass skill paths** `[CERT]` (`skill-resolver.md:36-49`). Inject PATHS, NOT summaries:

```markdown
## Skills to load before work

Read these exact files before reading, writing, reviewing, testing, or creating artifacts:

- /absolute/path/to/skills/go-testing/SKILL.md
- /absolute/path/to/skills/typescript/SKILL.md
```

The sub-agent MUST read those files before the specific work. `SKILL.md` is the runtime contract and the source of truth.

**Step 4 — Report the resolution** `[CERT]` (`skill-resolver.md:51-60`). Sub-agents MUST report `skill_resolution`:

| Value | Meaning |
|-------|-------------|
| `paths-injected` | Received exact paths from the delegator and loaded them |
| `fallback-registry` | Did not receive paths; self-loaded paths from the registry |
| `fallback-path` | Loaded an explicit fallback path outside the registry |
| `none` | Loaded no skills |

Self-correction rule `[CERT]`: if a sub-agent reports anything other than `paths-injected`, the orchestrator MUST re-read the registry before the next delegation.

### Compaction safety and integration `[CERT]`

**Compaction safety** `[CERT]` (`skill-resolver.md:62-66`): the registry persists in Engram and in `.atl/skill-registry.md`; delegators can recover paths after compaction by re-reading the registry; sub-agents receive exact files to read, so the skill's meaning is not degraded by generated summaries.

**Integration points** `[CERT]` (`skill-resolver.md:68-72`): the ATL orchestrator resolves paths for all SDD and non-SDD delegations; `judgment-day` resolves paths before Judge A, Judge B, and Fix Agent; `pr-review` and future delegators use this protocol.

**Key point** `[INFER]`: the rule "pass paths, not summaries" is the central architectural decision — a delegator-generated summary would degrade the skill author's intent. By passing the exact path, the sub-agent reads the full `SKILL.md`. This is what makes the mechanism "compaction-safe": the delegator may lose its cache, but the `SKILL.md` on disk/Engram does not change.

## 22.2 — SDD Phase Common Protocol `[CERT]`

Identical boilerplate across all SDD phase skills. Sub-agents MUST load it alongside their phase-specific `SKILL.md` `[CERT]` (`sdd-phase-common.md:1-3`).

**Executor boundary** `[CERT]` (`sdd-phase-common.md:5`): every SDD phase agent is an EXECUTOR, not an orchestrator. It does the phase work itself. It does NOT launch sub-agents, does NOT call `delegate`/`task`, and does NOT hand the work back unless the phase skill explicitly says to stop and report a blocker (see [Block 1] §1.2).

### A. Skill Loading `[CERT]` (`sdd-phase-common.md:7-17`)

1. Check whether the orchestrator injected a `## Skills to load before work` block. If so, read those exact `SKILL.md` files before the work.
2. If not, check for `SKILL: Load` instructions. If present, load those files.
3. If neither, look up the skill registry as a fallback: `mem_search("skill-registry")` → `mem_get_observation(id)`; fallback to `.atl/skill-registry.md`; match triggers to the task and read the listed paths.
4. No registry → proceed with the phase skill alone.

The preferred path is (1) — exact paths selected by the orchestrator. (2) and (3) are fallbacks. Looking up the registry is SKILL LOADING, not delegation. If `## Skills to load before work` is present, IGNORE redundant `SKILL: Load` instructions `[CERT]`.

### B. Artifact retrieval (Engram mode) `[CERT]` (`sdd-phase-common.md:19-35`)

**CRITICAL**: `mem_search` returns 300-character PREVIEWS, NOT full content. You MUST call `mem_get_observation(id)` for EACH artifact. **Skipping it produces incorrect output** (matches [Block 20] §20.4). Run ALL searches in parallel, then ALL retrievals in parallel. Do NOT use search previews as source material.

### C. Artifact persistence `[CERT]` (`sdd-phase-common.md:37-69`)

Every phase that produces an artifact MUST persist it — skipping it BREAKS the pipeline. By mode:

- **Engram**: `mem_save(title, topic_key, type: "architecture", project, capture_prompt: false, content)`. The `topic_key` enables upserts. `capture_prompt: false` is mandatory for SDD artifacts (automated outputs, not human saves); set it when the schema supports it, omit it if not.
- **OpenSpec**: the file was already written during the phase's main step; no additional action needed.
- **Hybrid**: do BOTH — write the file AND call `mem_save`.
- **None**: return inline; do not write files or call `mem_save`.

> **[DRIFTED v1.43.2→v2.2.0] — Verify-report admission gate**: the `verify-report` artifact now requires a pre-write gate that did not exist at v1.43.2. `[CERT]` (`sdd-phase-common.md:41`): "For `verify-report`, first build exact candidate bytes and run `gentle-ai sdd-verify-validate` with authoritative requirement/scenario counts before any OpenSpec or Engram write. If the validator is unavailable or denies admission, make zero writes and leave the prior report untouched; otherwise persist only the same admitted bytes, including a valid `fail`." For the canonical description of the gate — its contract, what it guarantees, what happens on failure, and its RDD stability caveat — see [Block 19] §19.10.

### D. Return Envelope `[CERT]` (`sdd-phase-common.md:71-95`)

**Response ordering** `[CERT]`: the FINAL output MUST be text (the envelope), NOT a tool call. If you must save to Engram, do it BEFORE the final text response. Do NOT call `mem_session_summary` (that is for top-level agents). Reason: if the last action is a tool call, the parent receives only the tool result — the text analysis is lost (matches [Block 19] §19.8).

Every phase returns a structured envelope `[CERT]`:

| Field | Content |
|-------|-----------|
| `status` | `success`, `partial`, or `blocked` |
| `executive_summary` | 1-3 sentence summary of what was done |
| `detailed_report` | (optional) full output, or omit if already inline |
| `artifacts` | List of artifact keys/paths written |
| `next_recommended` | The next SDD phase to run, or "none" |
| `risks` | Risks discovered, or "None" |
| `skill_resolution` | `paths-injected` / `fallback-registry` / `fallback-path` / `none` |

This is the **Result Contract** that every phase returns to the orchestrator (see [Block 2]).

### E. Review Workload Guard `[CERT]` (`sdd-phase-common.md:97-113`)

SDD must protect the reviewer's cognitive load, not just generate tasks `[CERT]`:

- Default PR review budget: **400 changed lines** (`additions + deletions`). Only authored text additions plus deletions count toward this threshold; generated goldens are excluded from the authored risk count but remain in complete snapshot identity.
- The orchestrator MUST cache a delivery strategy at session start: `ask-on-risk` (default), `auto-chain`, `single-pr`, or `exception-ok`. These four are the whole domain; any other value is invalid and must not be recorded or forwarded.
- `sdd-tasks` MUST forecast whether the work may exceed the budget, with EXACT plain-text guard lines: `Decision needed before apply: Yes|No`, `Chained PRs recommended: Yes|No`, `400-line budget risk: Low|Medium|High`.
- If the forecast is high, `sdd-tasks` MUST recommend chained/stacked PRs with deliverable work units.
- `sdd-apply` MUST NOT start oversized work unless the strategy resolves to chained/stacked slices or an explicitly accepted `size:exception`.
- Each chained PR slice: clear start, clear finish, autonomous scope, verification, reasonable rollback.
- In a Feature Branch Chain, PR #1 targets the feature/tracker branch and child PRs target the immediately previous PR branch; if GitHub shows prior slices in a child diff, retarget/rebase until the diff is clean.

(Developed at the orchestration level in [Block 17].)

## 22.3 — SDD Status and Instructions Contract `[CERT]`

Shared OpenSpec-style contract for SDD commands and phase skills. Use it before acting on a change so orchestration does not guess state, paths, or edit scope `[CERT]` (`sdd-status-contract.md:1-8`).

**Purpose** `[CERT]`: commands that select, continue, apply, verify, or archive an SDD change MUST first produce or consume structured status. Status is the **handoff** between orchestrator and phase executor.

### Change selection `[CERT]` (`sdd-status-contract.md:10-15`)

- If a change name is given, use that exact one after confirming it exists in the selected store.
- If no name is given, infer ONLY if the active change is unambiguous or there is exactly one active change.
- If multiple changes match or it is ambiguous, ask the user. Do not guess.
- If there are no active changes, report it and suggest `/sdd-new <change>`.

### Native Engine `[CERT]` (`sdd-status-contract.md:17-25`)

Critical points of this contract `[CERT]`:

- When the store is `openspec` or `hybrid` AND the `gentle-ai` binary is available, prefer `gentle-ai sdd-status [change] --cwd <repo> --json --instructions` (read-only status) and `gentle-ai sdd-continue [change] --cwd <repo>` (dispatcher).
- The native engine reads ONLY OpenSpec file artifacts and ALWAYS emits `artifactStore: openspec`; it CANNOT observe Engram-backed changes. Treat native status as authoritative only when the store is `openspec` or `hybrid`.
- **When the store is `engram`, do NOT invoke the native dispatcher at all** — resolve status from Engram (`mem_search` + `mem_get_observation` over the change's topic keys) using the manual schema, and ignore any `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` it emits for an Engram change that exists.
- **[DRIFTED v1.43.2→v2.2.0 — RDD addition]** `[CERT]` (`sdd-status-contract.md:20-21`): runtime-attempt authority is separate from artifact dispatch. `gentle-ai sdd-attempt status|begin|finish|reset --cwd <repo> --change <change>` is artifact-store agnostic and MUST be used for runtime-bearing OpenSpec and Engram continuations. Its Git-common-dir immutable chain is the sole authority for ordinals, cumulative attempt/line budgets, runtime evidence, and an atomic bound-remediation successor. Its payload is separate and MUST NOT be embedded in the SDD v1 status document. Never create OpenSpec attempt-ledger files or Engram attempt-ledger topics.
- Non-empty `blockedReasons` → do not proceed to terminal/archive/apply work; report and stop (except `nextRecommended: verify`, where verify may run only to remediate/refresh evidence). `nextRecommended: resolve-blockers` → report and stop. A planning token (`propose`, `spec`, `design`, `tasks`) → launch that planning phase.
- `nextRecommended` is a **bounded machine token for routing**, not human prose. The human-readable explanation goes in `blockedReasons`, not in `nextRecommended`.
- If the binary is not available, fall back to the prompt contract and the manual schema. The manual fallback MUST be shape-compatible with the native JSON of `gentle-ai.sdd-status`.

### Status Schema `[CERT]` (`sdd-status-contract.md:26-124`)

Status is returned as markdown with these fields, or equivalent JSON. [DRIFTED v1.43.2→v2.2.0]: the schema has grown significantly. New fields added in v2.2.0 are marked. Main fields:

| Field | Content `[CERT]` | New in v2.2.0? |
|-------|---------|---|
| `schemaName` / `schemaVersion` | `gentle-ai.sdd-status` / `1` | No |
| `changeName` | Change name or `null` | No |
| `artifactStore` | `openspec | engram | none` | No |
| `planningHome` | `mode: repo-local`, `path` to openspec | No |
| `changeRoot` | Absolute path to `openspec/changes/<change>` or `null` | No |
| `artifactPaths` | Absolute paths per artifact (proposal, specs, design, tasks, applyProgress, verifyReport, **reviewPolicy, reviewLedger, reviewReceipt, reviewBundle, reviewContext, reviewState**) | Partial — review-related paths are new |
| `contextFiles` | Absolute readable files per artifact (same keys as `artifactPaths`) | Partial |
| `artifacts` | State per artifact: `missing | done | partial` | No |
| `taskProgress` | `total`, `completed`, `pending`, `allComplete` | No |
| `dependencies` | Per phase: `blocked | ready | all_done` | No |
| `applyState` | `blocked | all_done | ready` | No |
| `actionContext` | `mode`, `workspaceRoot`, `allowedEditRoots` | No |
| `relationships` | `dependsOn`, `supersedes`, `amends`, `conflictsWith`, `sameDomainActiveChanges` | No |
| `remediationState` | `required`, `complete`, `failedEvidenceRevision`, `lineageId`, `generation`, `fixBatch`, `reason` | **Yes — RDD unstable** |
| `reviewGate` | `result: allow | scope-changed | invalidated | escalated`, `reason` | **Yes — RDD unstable** |
| `reviewTransaction` | Optional exact `gentle-ai.review-transaction/v1` object | **Yes — RDD unstable** |
| `phaseInstructions` | Optional; execution keys: `apply`, `verify`, **`remediate`**, `archive` | Partial — `remediate` is new |
| `nextRecommended` | `propose | spec | design | tasks | apply | **review** | verify | **remediate** | archive | sdd-new | select-change | resolve-blockers | **resolve-review**` | Partial — `review`, `remediate`, `resolve-review` are new RDD tokens |
| `blockedReasons` | List of readable reasons | No |

Shape rules `[CERT]` (`sdd-status-contract.md:124`): `phaseInstructions` carries only execution-phase keys. Empty path fields MUST be arrays, not null. `changeName` and `changeRoot` are nullable. `reviewGate` is omitted until final archive gating runs. `reviewTransaction` is omitted until the review owner supplies the exact object; manual fallback MUST NOT reconstruct it. A hybrid session projects as `artifactStore: openspec`; `hybrid` is not an SDD v1 wire token.

### Apply State and Dependency States `[CERT]`

**Apply State** `[CERT]` (`sdd-status-contract.md:128-131`): `blocked` (missing artifacts, ambiguous selection, unsafe edits) | `all_done` (tasks exists and everything is `[x]`) | `ready` (tasks exists, at least one remains unchecked, safe scope).

**Dependency States** `[CERT]` (`sdd-status-contract.md:133-142`):

- `proposal`/`specs`/`design`/`tasks` report whether the prerequisites are `blocked`/`ready`/`all_done`.
- `apply` is `ready` only when specs, design, and tasks are available and task progress is not all_done.
- **[DRIFTED v1.43.2→v2.2.0]** `verify` readiness. Old: "`verify` is `ready` when tasks exists and either apply-progress exists or the tasks artifact shows all implementation work complete. Incomplete tasks remain blockers for full verification." New `[CERT]` (`sdd-status-contract.md:136-138`): "`verify` is `ready` only after every task is complete and the persisted bounded transaction reaches `ready_final_verification` (or has begun `final_verifying`). Missing or active review state routes to `review`; apply-progress and focused work-unit checks never make final verification ready." — The bar is now higher and RDD-dependent (unstable surface, observed 2026-07-28).
- **[DRIFTED v1.43.2→v2.2.0]** `archive` readiness. Old: "ready when verify-report exists, is clearly passing, and tasks are complete (PASS/SUCCESS signal, no negation signal)." New `[CERT]` (`sdd-status-contract.md:139`): "`archive` is `ready` only when tasks are complete, strict verification passes, and **an approved receipt exactly matches the final candidate tree, paths, policy, frozen ledger, and current evidence**. Missing, pending, or invalid receipts block archive." — Receipt matching is a new hard requirement introduced with RDD (unstable, observed 2026-07-28).
- **New — `remediate` route** `[CERT — RDD unstable; observed 2026-07-28]` (`sdd-status-contract.md:138`): failed evidence may route to `remediate` only when an exact persisted transaction lineage/generation has remaining mode-specific fix budget and names the same failed evidence revision. Remediation completion requires concrete focused-test, runtime-harness (or justified N/A), and rollback evidence bound to that transaction; a bare envelope never passes. This routing did not exist at v1.43.2.
- **New — `sdd-attempt` gate before runtime-bearing continuations** `[CERT — RDD unstable; observed 2026-07-28]` (`sdd-status-contract.md:141`): "Before a runtime-bearing continuation, query `gentle-ai sdd-attempt status --cwd <repo> --change <change>` separately. A populated active attempt or decision-required result blocks apply, verify, remediation, and archive routing with `nextRecommended: resolve-blockers`; finish the already-charged attempt or obtain explicit maintainer authorization for reset. A completed result preserves the successful objective without relaunching it." Orchestrators must query this separately — it is artifact-store agnostic and its payload must NOT be embedded in the SDD v1 status document.

### Action Context Guard and Status Output `[CERT]`

**Action Context Guard** `[CERT]` (`sdd-status-contract.md:144-150`): the orchestrator MUST carry `actionContext` to any phase launch. If the manually reconstructed context cannot prove edit ownership or allowed edit roots, stop before editing. If `allowedEditRoots` is present, only edit within those roots. If a command cannot prove a file is within the authoritative workspace or the allowed edit roots, stop and ask for clarification.

**Status Output** `[CERT]` (`sdd-status-contract.md:152-160`): every command that acts on a change MUST show status before launching an executor or doing archive: active change selection and how it was resolved; artifact states and the paths/topics used; task progress and the list of unchecked tasks; the next recommended action; `blockedReasons` when `nextRecommended` is not `verify`, plus any edit-root blocker.

**Mental model** `[INFER]`: the status contract is the "machine language" of SDD. The `nextRecommended` field is deliberately a bounded token (not prose) so the orchestrator can route deterministically without interpreting free text — this is what enables the dispatcher routing of [Block 15]. And the rule "fallback shape-compatible with the native JSON" means a consumer parses native and manual status the same way, regardless of the backend.

## 22.4 — Connections

- **[Block 18] — Delegation and model assignments**: the Skill Resolver Protocol (§22.1) is the mechanism that [Block 18] references when it requires "pre-resolved skill paths from the skill registry" at every sub-agent launch. The `skill_resolution` report (§22.1 Step 4) is the self-correction feedback the orchestrator uses to detect cache loss from compaction.
- **All SDD phases ([Block 5]-[Block 12])**: the Phase Common Protocol (§22.2) is the boilerplate that EVERY phase loads alongside its `SKILL.md`. Sections A-E (skill loading, retrieval, persistence, envelope, review guard) are identical in every phase.
- **[Block 2] — DAG and Result Contract**: the Return Envelope of §22.2-D is exactly the Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) that [Block 2] documents.
- **[Block 15] — Status and dispatcher**: §22.3 documents the status SCHEMA; [Block 15] documents its operational ROUTING (how the orchestrator decides the next action based on `nextRecommended` and the dependency states). The rule "engram → do not invoke native dispatcher" from §22.3 is the key piece that [Block 15] applies.
- **[Block 19] — Persistence contract**: §22.2-C (artifact persistence) carries the phase-level reminder of the verify-report admission gate. [Block 19] §19.10 is the canonical description. §22.2-B/C (artifact retrieval and persistence) inlines what [Block 19] formalizes; the response ordering of §22.2-D matches [Block 19] §19.8.
- **[Block 20] — Engram convention**: the two-step retrieval of §22.2-B and the `mem_save` with `capture_prompt: false` of §22.2-C consume the naming convention of [Block 20].
- **[Block 17] — Delivery/chain**: the Review Workload Guard of §22.2-E is the source of the forecast (`400-line budget risk`, `Chained PRs recommended`) that [Block 17] develops at the delivery strategy and chain strategy level.
- **[Block 23] — Strict-TDD**: the `apply.tdd` flag and the forwarding of strict TDD to `sdd-apply`/`sdd-verify` connect with the skill loading and review guard of §22.2.
- **[Block 11] — sdd-verify phase**: §22.2-C gate reminder and §22.3 `verify` dependency state both directly affect what `sdd-verify` can do and when.
