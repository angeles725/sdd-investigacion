# Block 2 — The phase DAG and the Result Contract

> **WHAT IT DOCUMENTS**: This block describes the dependency graph (DAG) of the SDD phases, what each phase reads and writes, the routing flow between phases, and the Result Contract — the structured envelope every phase returns to the orchestrator. It is the operational skeleton of SDD.
> **SCOPE**: The full DAG (`proposal → specs → tasks → apply → verify → archive`, with `design` feeding `specs`), the per-phase read/write table, the return envelope, the sub-agent response-ordering rules, and the Review Workload Guard. Does NOT cover the internal detail of each individual phase (see blocks B4–B12), nor the auto/interactive modes or the Gatekeeper (see [Block 16]).
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Dependency Graph", §"Result Contract", §"Sub-Agent Context Protocol" (phase reads/writes table), §"Engram Topic Key Format"
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` §D "Return Envelope", §C "Artifact Persistence", §E "Review Workload Guard"
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` §"Sub-Agent Context Rules"
> **METHOD**: Certainty markers. `[CERT]` = verified by reading the source, with `path:line` or `path §section`. `[CERT-a]` = asserted by a source, not re-verified at primary origin. `[INFER]` = my own deduction.

---

## 2.1 — The dependency graph `[CERT]`

The canonical DAG, literal from the source `[CERT]` (`CLAUDE.md` §"Dependency Graph"):

```
proposal -> specs --> tasks -> apply -> verify -> archive
             ^
             |
           design
```

Reading the graph `[CERT]`:
- The main chain is linear: `proposal → specs → tasks → apply → verify → archive`.
- `design` is NOT in the main chain: it feeds `specs` (the `design → specs` arrow). `[CERT]`
- `tasks` depends on `specs` (and, via the confluence, on the work of `design`).

**Important nuance** `[INFER]`: the graph draws `design -> specs`, but the read-dependency table (§2.2) shows that `sdd-tasks` reads **spec + design** and `sdd-design` reads **proposal**. That is, `design` and `specs` are parallel branches that start from `proposal` and converge at `tasks`. The ASCII diagram compresses that confluence by pointing the `design` arrow toward `specs`, but operationally both are inputs to `tasks`.

## 2.2 — What each phase reads and writes `[CERT]`

Literal table of the per-phase context contract `[CERT]` (`CLAUDE.md` §"Sub-Agent Context Protocol" → "SDD Phases"):

| Phase | Reads | Writes |
|------|-----|---------|
| `sdd-explore` | nothing | `explore` |
| `sdd-propose` | exploration (optional) | `proposal` |
| `sdd-spec` | proposal (required) | `spec` |
| `sdd-design` | proposal (required) | `design` |
| `sdd-tasks` | spec + design (required) | `tasks` |
| `sdd-apply` | tasks + spec + design + **apply-progress (if it exists)** | `apply-progress` |
| `sdd-verify` | spec + tasks + **apply-progress** | `verify-report` |
| `sdd-archive` | all artifacts | `archive-report` |

Context access rules `[CERT]` (`CLAUDE.md` §"Sub-Agent Context Protocol"):
- For phases with required dependencies, the **sub-agent reads directly from the backend** — the orchestrator passes artifact *references* (topic keys or file paths), NOT the content. `[CERT]`
- This avoids inflating the orchestrator's prompt: SDD artifacts are large; inlining them would consume the entire context window. `[CERT]` (`persistence-contract.md:87`).

Who reads / who writes, according to task type `[CERT]` (`persistence-contract.md:80-88`):
- Non-SDD (general task): the **orchestrator** searches engram and passes a summary in the prompt; the sub-agent saves discoveries via `mem_save`.
- SDD with dependencies: the **sub-agent** reads artifacts directly from the backend; the sub-agent saves its artifact.
- SDD without dependencies (e.g. explore): nobody reads; the sub-agent saves its artifact. `[CERT]`

## 2.3 — Routing: how the DAG advances `[CERT]`

Advancement is NOT by free-text inference. The system routes by `nextRecommended` and dependency states `[CERT]` (`CLAUDE.md` §"Native SDD Dispatcher Guard": "Route only by `nextRecommended` and dependency states; never infer from free text").

Each phase returns a `next_recommended` field (the next SDD phase to run, or `"none"`) as part of the Result Contract `[CERT]` (`sdd-phase-common.md:79`). The `/sdd-continue` meta-command runs the next **dependency-ready** phase via sub-agent `[CERT]` (`CLAUDE.md` §"Commands").

Dispatcher routing rules `[CERT]` (`CLAUDE.md` §"Native SDD Dispatcher Guard"):
- If `blockedReasons` is not empty → do NOT proceed to apply/archive/terminal work.
- If `nextRecommended` is `verify` → verification/remediation only to refresh evidence.
- If `nextRecommended` is `resolve-blockers` → report `blockedReasons` and stop.
- If `nextRecommended` is a planning token (`propose`, `spec`, `design`, `tasks`) → launch the corresponding planning phase.

> The detail of the native `gentle-ai` dispatcher and its per-backend scoping is covered in [Block 15]. Here it is enough to know: routing is by state and dependency, never by prose interpretation. `[INFER]`

## 2.4 — The Result Contract (return envelope) `[CERT]`

Each phase returns a structured envelope to the orchestrator. Literal summary `[CERT]` (`CLAUDE.md` §"Result Contract"): *"Each phase returns: `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`."*

The full definition of each field `[CERT]` (`sdd-phase-common.md:73-81`):

| Field | Values / Content `[CERT]` |
|-------|-------------------|
| `status` | `success`, `partial`, or `blocked` |
| `executive_summary` | 1-3 sentence summary of what was done |
| `detailed_report` | (optional) full phase output, or omit if already inline |
| `artifacts` | List of keys/paths of written artifacts |
| `next_recommended` | The next SDD phase to run, or `"none"` |
| `risks` | Discovered risks, or `"None"` |
| `skill_resolution` | How skills were loaded: `paths-injected`, `fallback-registry`, `fallback-path`, or `none` |

Example envelope `[CERT]` (`sdd-phase-common.md:85-92`):

```markdown
**Status**: success
**Summary**: Proposal created for `{change-name}`. Defined scope, approach, and rollback plan.
**Artifacts**: Engram `sdd/{change-name}/proposal` | `openspec/changes/{change-name}/proposal.md`
**Next**: sdd-spec or sdd-design
**Risks**: None
**Skill Resolution**: paths-injected — 3 skills (react-19, typescript, tailwind-4)
```

Detail of `skill_resolution` `[CERT]` (`sdd-phase-common.md:81`):
- `paths-injected` → received exact skill paths from the orchestrator (preferred).
- `fallback-registry` → self-loaded paths from the registry.
- `fallback-path` → loaded via `SKILL: Load` instruction.
- `none` → no skills loaded.

This field is a **self-correction mechanism** `[CERT]` (`CLAUDE.md` §"Skill Resolution Feedback"): if the orchestrator sees `fallback-*` or `none`, it means the skill cache was lost (likely compaction) and it must re-read the registry before the next delegation.

## 2.5 — Response ordering: the last output must be text `[CERT]`

CRITICAL ordering rule `[CERT]` (`sdd-phase-common.md:71`, `persistence-contract.md:140-146`): *"Your FINAL output MUST be text (the return envelope), NOT a tool call. If you need to save to Engram (`mem_save`), do it BEFORE your final text response."*

The **why** `[CERT]` (`persistence-contract.md:144`): the Task tool returns the sub-agent's final output to the parent. If the sub-agent ends with a tool call, the parent receives ONLY the tool result (e.g. `"Observation saved"`) — the sub-agent's text analysis is LOST.

Correct sequence always `[CERT]` (`persistence-contract.md:144`): *do the work → save → respond with the text envelope*.

Additional constraint `[CERT]` (`sdd-phase-common.md:71`, `persistence-contract.md:146`): sub-agents must NOT call `mem_session_summary` — that is reserved for higher-level agents (orchestrator).

## 2.6 — Mandatory artifact persistence `[CERT]`

Every phase that produces an artifact MUST persist it. Skipping it BREAKS the pipeline — downstream phases will not find the output `[CERT]` (`sdd-phase-common.md:37-39`).

The how of persistence depends on the backend (detailed in [Block 3]). Summary by mode `[CERT]` (`sdd-phase-common.md:41-67`):

| Mode | Persistence action `[CERT]` |
|------|----------------------|
| `engram` | `mem_save(title, topic_key: "sdd/{change-name}/{artifact-type}", type: "architecture", project, capture_prompt: false, content)` |
| `openspec` | The file was already written in the main phase step; no additional action |
| `hybrid` | BOTH: write the file AND call `mem_save` |
| `none` | Return result inline; do NOT write files or `mem_save` |

`topic_key` enables upserts — saving again updates, does not duplicate `[CERT]` (`sdd-phase-common.md:54`). `capture_prompt: false` is mandatory for SDD artifacts because they are automated pipeline outputs, not human/proactive memory `[CERT]` (`sdd-phase-common.md:55`).

## 2.7 — Artifact retrieval by the sub-agent (engram) `[CERT]`

For phases with dependencies, the sub-agent retrieves the input in TWO steps `[CERT]` (`sdd-phase-common.md:19-35`):

```
mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → save ID
mem_get_observation(id: {saved_id}) → full content (REQUIRED)
```

Critical WARNING `[CERT]` (`sdd-phase-common.md:21`): *"`mem_search` returns 300-char PREVIEWS, not full content. You MUST call `mem_get_observation(id)` for EVERY artifact. Skipping this produces wrong output."*

Optimization `[CERT]` (`sdd-phase-common.md:23,29`): run all searches in parallel first, then all retrievals in parallel — NOT sequential.

## 2.8 — apply-progress continuity across batches `[CERT]`

`sdd-apply` implements in batches and produces one `apply-progress` artifact per batch `[CERT]` (`engram-convention.md:29`: "`apply-progress` ... Implementation progress (one per batch)").

For continuation batches (not the first), the orchestrator MUST tell the sub-agent that previous progress exists `[CERT]` (`CLAUDE.md` §"Apply-Progress Continuity"):
- Search: `mem_search(query: "sdd/{change-name}/apply-progress", ...)`.
- If it exists → instruct: *"You MUST read it first ... merge your new progress with the existing progress, and save the combined result. Do NOT overwrite — MERGE."* `[CERT]`

This prevents progress loss across batches; the sub-agent is responsible for read-merge-write, but the orchestrator MUST warn it that previous progress exists `[CERT]`.

## 2.9 — Review Workload Guard `[CERT]`

SDD must protect the reviewer's cognitive load, not just generate tasks `[CERT]` (`sdd-phase-common.md:95-97`). Key rules:

- Default review budget per PR: **400 changed lines** (`additions + deletions`). `[CERT]` (`sdd-phase-common.md:99`).
- The orchestrator MUST cache a `delivery_strategy` at session start: `ask-on-risk` (default), `auto-chain`, `single-pr`, or `exception-ok`. `[CERT]` (`sdd-phase-common.md:100`).
- `sdd-tasks` MUST forecast whether the planned work may exceed the budget, with exact plain-text guard lines: `Decision needed before apply: Yes|No`, `Chained PRs recommended: Yes|No`, `400-line budget risk: Low|Medium|High`. `[CERT]` (`sdd-phase-common.md:103`).
- `sdd-apply` must NOT start oversized work unless the strategy resolves to chained/stacked PR slices or an explicitly accepted `size:exception`. `[CERT]` (`sdd-phase-common.md:105`).

> The detail of delivery strategy, chain strategy and chained-PR is covered in [Block 17]; the orchestrator's Review Workload Guard (when to stop and ask) in [Block 16].

## 2.10 — Connections

- **[Block 1] — What SDD is**: the DAG described here is the "real work" the orchestrator-coordinator delegates. The EXECUTOR boundary of [Block 1] §1.2 is what each DAG node executes.
- **[Block 4 to Block 12]** — individual phases: each row of table §2.2 corresponds to a dedicated block: B4 `sdd-init`, B5 `sdd-explore`, B6 `sdd-propose`, B7 `sdd-spec`, B8 `sdd-design`, B9 `sdd-tasks`, B10 `sdd-apply`, B11 `sdd-verify`, B12 `sdd-archive`. Those blocks detail the internal "how" of each read/write listed here.
- **[Block 3] — Artifact backends**: §2.6 and §2.7 depend on the resolved backend mode; [Block 3] explains `engram`/`openspec`/`hybrid`/`none` and the topic key format (`sdd/{change-name}/{artifact-type}`).
- **[Block 15] — sdd-status and native dispatcher**: the `nextRecommended` routing of §2.3 is materialized by the native `gentle-ai` dispatcher, scoped by backend.
- **[Block 16] — auto/interactive modes and Gatekeeper**: the Gatekeeper validates the Result Contract (§2.4) between phases in automatic mode.
- **[Block 19] — persistence-contract**: formalizes the "who reads/who writes" of §2.2 and the ordering rules of §2.5.
