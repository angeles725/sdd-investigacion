# Block 5 — `sdd-explore` Phase

> **What it documents:** the exploration phase of gentle-ai's SDD system — the investigation prior to committing to a change: it reads the codebase, compares approaches and returns a structured analysis. It is the first phase of the planning DAG.
> **Scope:** purpose, what it reads / what it writes, required vs optional inputs, the 6 steps of the process, mandatory output format, Result Contract, assigned model, special rules (read-only).
> **Exact sources read:**
> - `/home/cristian/.config/opencode/skills/sdd-explore/SKILL.md` (runtime contract — primary)
> - `/home/cristian/.claude/agents/sdd-explore.md` (sub-agent definition: tools, model)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-explore.md` (canonical prompt — identical to SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-explore.md` (orchestrator command)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (common protocol)
> **Method + marker legend:**
> - `[CERT]` = verified by reading the file, with `path:line` or `path §section` citation.
> - `[CERT-a]` = asserted by a source, not re-verified against its primary origin.
> - `[INFER]` = my own deduction.

---

## 5.1 — Purpose and position in the DAG `[CERT]`

`sdd-explore` is the sub-agent responsible for EXPLORATION: it investigates the codebase, thinks through the problem, compares approaches and returns a structured analysis `[CERT]` `SKILL.md:32-34`. It is the entry of the planning DAG: `explore → propose → spec → design → tasks` (see [Block 2]).

Distinctive feature `[CERT]` `SKILL.md:34`: *"By default you only research and report back; only create `exploration.md` when this exploration is tied to a named change."* — explore is **optionally artifact-free**. If standalone (no change name) it only returns the analysis inline; if tied to a named change, it persists `exploration.md` / `sdd/{change-name}/explore`.

It is an EXECUTOR: it investigates and reports, does not delegate `[CERT]` `agents/sdd-explore.md:11-12`.

### Orchestrator/executor gate `[CERT]`

Same pattern as init: ORCHESTRATOR GATE (`SKILL.md:13-17`) + Executor Override (`SKILL.md:19-21`) `[CERT]`.

## 5.2 — What it reads and what it writes `[CERT]`

| Action | Resource | Topic key / path | Obligation |
|---|---|---|---|
| READS | Project context | `sdd-init/{project}` (Engram) | **optional** `[CERT]` `SKILL.md:46,55` |
| READS | Existing SDD artifacts | `sdd/` (Engram) | optional `[CERT]` `SKILL.md:55` |
| READS | (openspec) config + specs | `openspec/config.yaml`, `openspec/specs/` | conditional on the mode `[CERT]` `SKILL.md:56` |
| READS | Real codebase code | filesystem | required `[CERT]` `SKILL.md:70-85` |
| WRITES | Exploration analysis | `sdd/{change-name}/explore` or `sdd/explore/{topic-slug}` (standalone) | **conditional** (only if tied to a change) `[CERT]` `SKILL.md:46,102` |

**Required inputs from the orchestrator** `[CERT]` `SKILL.md:36-40`: a topic/feature to explore + the artifact store mode. The command additionally injects `$ARGUMENTS` (the topic) `[CERT]` `commands/sdd-explore.md:13,22`.

**Optional inputs** `[CERT]`: `sdd-init/{project}` for project context — its absence does not block. Notably, explore **reads** via Engram but its agent frontmatter does NOT include `mem_search`/`mem_get_observation` (see §5.6) — Engram context reading is done with whatever the orchestrator passed in the prompt `[CERT]` `SKILL.md:57` ("Use whatever context the orchestrator passed in the prompt").

The save uses `type: architecture` `[CERT]` `SKILL.md:103`, `agents/sdd-explore.md:33`.

## 5.3 — The 6 steps of the process `[CERT]`

`[CERT]` `SKILL.md:59-139`:

1. **Load Skills** — follow Section A of `sdd-phase-common.md` `SKILL.md:61-62`.
2. **Understand the Request** — new feature? bugfix? refactor? which domain does it touch? `SKILL.md:64-67`.
3. **Investigate the Codebase** — read entry points and key files; search for related functionality; review existing tests; look at patterns in use; identify dependencies and coupling `SKILL.md:70-85`.
4. **Analyze Options** — if there are multiple approaches, compare them in a table `Approach | Pros | Cons | Complexity` `SKILL.md:87-94`.
5. **Persist Artifact** — MANDATORY if tied to a named change; artifact `explore`, `type: architecture` `SKILL.md:96-103`.
6. **Return Structured Analysis** — return EXACTLY the format of `SKILL.md:109-139` `SKILL.md:105-139`.

The ASCII investigation block (step 3) lists the sweep method `[CERT]` `SKILL.md:78-85`:
```
INVESTIGATE:
├── Read entry points and key files
├── Search for related functionality
├── Check existing tests (if any)
├── Look for patterns already in use
└── Identify dependencies and coupling
```

## 5.4 — Mandatory output format `[CERT]`

Step 6 requires returning EXACTLY this structure (and writing the same to `exploration.md` if persisted) `[CERT]` `SKILL.md:107-139`:

- `## Exploration: {topic}`
- `### Current State` — how the system works today regarding the topic.
- `### Affected Areas` — list of `path/to/file.ext — {why it is affected}`.
- `### Approaches` — numbered approaches with **Pros / Cons / Effort (Low/Medium/High)**.
- `### Recommendation` — recommended approach and why.
- `### Risks` — risks.
- `### Ready for Proposal` — `Yes/No` + what the orchestrator should tell the user.

The `Ready for Proposal` field is the explicit handoff toward [Block 6]: explore decides whether the material is mature enough to be formalized into a proposal `[INFER]`.

## 5.5 — Result Contract `[CERT]`

Double layer: the `Section D` (common) envelope plus the agent prompt's fields `[CERT]` `agents/sdd-explore.md:38-45`:

| Field | Values / content |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence with what was explored + key recommendation |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/explore`) |
| `next_recommended` | `sdd-propose` (if tied to a change) or `none` (standalone) |
| `risks` | risks or blockers discovered |
| `skill_resolution` | `paths-injected` or `none` |

Same `status` discrepancy as init: the agent declares `done` but the common Return Envelope uses `success` `[CERT]` `sdd-phase-common.md:76` vs `agents/sdd-explore.md:40`.

The `next_recommended` encodes the standalone vs. tied-to-change fork: standalone → `none` (ends the flow); tied → `sdd-propose` `[CERT]` `agents/sdd-explore.md:43`.

## 5.6 — Assigned model and tools `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-explore.md:7`. The orchestrator's Model Assignments table justifies it explicitly: *"sdd-explore | sonnet | Reads code, structural - not architectural"* `[CERT-a]` (CLAUDE.md, Model Assignments). Reasoning `[INFER]`: explore reads and compares but does NOT make committed architecture decisions — that is the work of propose/design (opus).

Tools `[CERT]` `agents/sdd-explore.md:8`: `Read, Grep, Glob, WebFetch, WebSearch, mcp__plugin_engram_engram__mem_save`.

**Tools gotcha `[CERT]`:** explore is the **only** planning phase with `WebFetch` + `WebSearch` (it can investigate external sources) and the only one that has `mem_save` but does **NOT** have `mem_search` nor `mem_get_observation`. Consequence: explore cannot retrieve Engram artifacts by itself `[INFER]` — it depends on the orchestrator passing the context in the prompt (`SKILL.md:57`). It also has no Edit/Write of code, consistent with its read-only nature.

## 5.7 — Special rules and gotchas `[CERT]`

Explicit rules `[CERT]` `SKILL.md:141-149`:

- The ONLY file it CAN create is `exploration.md` inside the change folder (if there is a change name) `SKILL.md:143`.
- It does **NOT** modify code or existing files `SKILL.md:144` (reinforced in `agents/sdd-explore.md:26`).
- It ALWAYS reads real code, never guesses about the codebase `SKILL.md:145`.
- Keep the analysis CONCISE — the orchestrator needs a summary, not a novel `SKILL.md:146`.
- If there is not enough info, say so clearly `SKILL.md:147`.
- If the request is too vague to explore, say what clarification is missing `SKILL.md:148`.

Command gates `[CERT]` `commands/sdd-explore.md:15-19`: (1) Session Preflight complete; (2) `sdd-init` must exist or be run after the preflight (init guard); (3) use the resolved artifact store, do not hardcode Engram. The task is "exploration only: no file edits and no implementation" `[CERT]` `commands/sdd-explore.md:22`.

Persistence by mode `[CERT]` `SKILL.md:46-49`: engram → saves `sdd/{change-name}/explore`; openspec → follows `openspec-convention.md`; hybrid → both; none → inline only.

---

## 5.8 — Connections

- **[Block 4] (`sdd-init`):** predecessor. explore reads `sdd-init/{project}` as optional context; the init guard requires init to exist before explore `[CERT]` `commands/sdd-explore.md:18`.
- **[Block 6] (`sdd-propose`):** successor. The `Ready for Proposal: Yes/No` and `next_recommended: sdd-propose` are the handoff. propose optionally reads `sdd/{change-name}/explore` as input `[CERT]` `skills/sdd-propose/SKILL.md:47`.
- **[Block 2] (DAG + Result Contract):** explore is the root node of the planning subgraph; it returns the standard envelope with the `status` caveat.
- **[Block 3 / Block 19] (backends + topic keys):** topic key `sdd/{change-name}/explore` (or `sdd/explore/{topic-slug}` standalone); persistence mode inherited from the Session Preflight.
- **[Block 18] (delegation + models):** `sonnet` model per the table (structural, not architectural). It is the low-risk phase the Gatekeeper validates inline (see [Block 16]).
- **[Block 22] (skill-resolver + phase-common):** explore follows Section A (skill loading), B (retrieval) and C (persistence) of the common protocol; `skill_resolution` reports how skills were loaded.
- **[Block 14] (meta-commands):** `/sdd-new` chains explore → propose; `/sdd-explore <topic>` launches only this phase in standalone mode.
