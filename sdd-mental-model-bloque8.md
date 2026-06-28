# Block 8 — `sdd-design` Phase

> **What it documents:** the technical design phase of gentle-ai's SDD system — it reads the proposal (required) and the spec (optional), reads the real codebase, and produces a `design.md` that captures the HOW: ADR-style architecture decisions, data flow, file changes, interfaces and testing strategy.
> **Scope:** purpose, what it reads / what it writes, inputs, the 5 steps, the design format (ADR decisions with rationale + rejected alternatives), Result Contract, the `opus` model and why, gotchas (800-word budget, read the real codebase, follow existing patterns).
> **Exact sources read:**
> - `/home/cristian/.config/opencode/skills/sdd-design/SKILL.md` (runtime contract — primary)
> - `/home/cristian/.claude/agents/sdd-design.md` (sub-agent definition: tools, model)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-design.md` (canonical prompt — identical to SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (common protocol)
> - (There is NO `commands/sdd-design.md` — it is invoked via meta-commands `[CERT]` `ls commands/`)
> **Method + marker legend:**
> - `[CERT]` = verified by reading the file, cites `path:line` or `path §section`.
> - `[CERT-a]` = asserted by one source, not re-verified.
> - `[INFER]` = my own deduction.

---

## 8.1 — Purpose and position in the DAG `[CERT]`

`sdd-design` takes the proposal and the specs and produces a `design.md` that captures **HOW the change will be implemented** — architecture decisions, data flow, file changes and technical rationale `[CERT]` `SKILL.md:32-34`. In the DAG it depends on the proposal (required) and runs in parallel with spec; both feed into tasks: `proposal → design → tasks` `[CERT]` `agents/sdd-design.md:43`.

Boundary with spec `[INFER]`: spec describes the WHAT (testable requirements, [Block 7]); design describes the HOW (architecture, files, interfaces). The prompt phrases it: *"design is the HOW at architectural level, tasks are the WHAT-to-do steps"* `[CERT]` `agents/sdd-design.md:26`.

It is an EXECUTOR `[CERT]` `agents/sdd-design.md:10-11`. Same orchestrator/executor gate `[CERT]` `SKILL.md:13-21`. **It has no direct command `[CERT]`** — it is orchestrated via meta-commands.

## 8.2 — What it reads and what it writes `[CERT]`

| Action | Resource | Topic key / path | Requirement |
|---|---|---|---|
| READS | Proposal | `sdd/{change-name}/proposal` | **required** `[CERT]` `SKILL.md:46`, `agents/sdd-design.md:20` |
| READS | Spec | `sdd/{change-name}/spec` | **optional** (may not exist if running in parallel with sdd-spec) `[CERT]` `SKILL.md:46` |
| READS | Real codebase code | filesystem (entry points, modules, patterns, interfaces, test infra) | **required** `[CERT]` `SKILL.md:56-62,176` |
| WRITES | Technical design | `sdd/{change-name}/design` (Engram) / `openspec/changes/{change-name}/design.md` | **required** `[CERT]` `SKILL.md:46,142-149` |

**Required input `[CERT]`:** the proposal — `agents/sdd-design.md:20` instructs `mem_search("sdd/{change-name}/proposal") → mem_get_observation`. The spec is **optional** explicitly because design may run in parallel with sdd-spec `[CERT]` `SKILL.md:46` (*"may not exist if running in parallel with sdd-spec"*). Save with `type: architecture` `[CERT]` `SKILL.md:149`.

**That it reads the proposal and produces architecture decisions `[CERT]`:** this is the core of design. It reads the proposal (intent, scope, approach) and, by also reading the real codebase, translates it into concrete architecture decisions with rationale and rejected alternatives (§8.3).

## 8.3 — ADR-style architecture decisions `[CERT]`

The heart of `design.md` is the **Architecture Decisions** section, in ADR (Architecture Decision Record) format `[CERT]` `SKILL.md:87-99`:

```markdown
### Decision: {Decision Title}

**Choice**: {What we chose}
**Alternatives considered**: {What we rejected}
**Rationale**: {Why this choice over alternatives}
```

Hard rule `[CERT]` `SKILL.md:177`: *"Every decision MUST have a rationale (the 'why')."* The agent prompt reinforces it: capture ADR-style decisions with rationale **and rejected alternatives** `[CERT]` `agents/sdd-design.md:23` ("Capture ADR-style decisions with rationale and rejected alternatives").

This materializes why design runs on `opus`: it does not transcribe, it **decides** — it chooses pattern, layering and boundaries, justifying against alternatives (§8.6).

## 8.4 — Full structure of `design.md` `[CERT]`

`[CERT]` `SKILL.md:79-140`:

- `## Technical Approach` — general technical strategy; how it maps to the proposal's approach; references specs.
- `## Architecture Decisions` — ADR blocks (§8.3).
- `## Data Flow` — how data moves; ASCII diagrams when they help.
- `## File Changes` — `File | Action (Create/Modify/Delete) | Description` table with concrete paths.
- `## Interfaces / Contracts` — new interfaces, API contracts, type definitions, in the project's language.
- `## Testing Strategy` — `Layer (Unit/Integration/E2E) | What to Test | Approach` table.
- `## Migration / Rollout` — plan if there is migration/feature flags/phased rollout; if not, "No migration required."
- `## Open Questions` — checklist of unresolved technical questions or ones that need team input.

The `Testing Strategy` by layers connects design with the testing capabilities detected at init `[INFER]` (see [Block 4 §4.3]).

## 8.5 — The 5 steps + Result Contract `[CERT]`

Steps `[CERT]` `SKILL.md:51-172`: Step 1 (load skills) → Step 2 (**read the real codebase** — entry points, patterns, dependencies, test infra) → Step 3 (write `design.md`) → Step 4 (persist, MANDATORY) → Step 5 (return summary).

The agent prompt expands Step 2-3 to `[CERT]` `agents/sdd-design.md:19-24`: choose the architecture approach (pattern, layering, boundaries) → map components, data flow, integration points → capture ADR decisions → persist.

Result Contract `[CERT]` `agents/sdd-design.md:38-45`:

| Field | Values / content |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence of the chosen approach |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/design`) |
| `next_recommended` | `sdd-tasks` (after spec is also ready) |
| `risks` | architectural risks, unresolved decisions, assumptions to validate |
| `skill_resolution` | `paths-injected` or `none` |

The SKILL's return summary additionally reports Key Decisions (N), Files Affected (N new/M modified/K deleted), Testing Strategy and Open Questions `[CERT]` `SKILL.md:160-168`. Same `status` discrepancy (`done` vs `success` common).

`next_recommended: sdd-tasks` conditioned on spec also being ready `[CERT]` `agents/sdd-design.md:43` — tasks needs spec **and** design.

## 8.6 — Assigned model: `opus` `[CERT]`

`model: opus` `[CERT]` `agents/sdd-design.md:7`. Justification from the table: *"sdd-design | opus | Architecture decisions"* `[CERT-a]` (CLAUDE.md, Model Assignments). Reasoning `[INFER]`: together with propose, design is the other **architectural decision** phase — it chooses patterns, evaluates alternatives and produces rationale that propagates to tasks and apply. Errors here compound downstream, hence the higher-reasoning model. That is why design (and apply) are **high-risk** phases that the orchestrator's Gatekeeper validates with a fresh-context reviewer, not inline (see [Block 16]).

Tools `[CERT]` `agents/sdd-design.md:8`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`. It has Read/Grep/Glob to fulfill the hard rule of reading the real codebase.

## 8.7 — Gotchas and special rules `[CERT]`

- **Read the real codebase, never guess `[CERT]` `SKILL.md:176`:** *"ALWAYS read the actual codebase before designing — never guess."* It is the first hard rule.
- **Follow existing patterns `[CERT]` `SKILL.md:179-180`:** use the project's REAL patterns, not generic best practices; if the codebase uses a pattern different from the one you would recommend, note it but FOLLOW the existing one unless the change specifically addresses it.
- **Concrete paths `[CERT]` `SKILL.md:178`:** concrete file paths, not abstract descriptions.
- **Blocking open questions `[CERT]` `SKILL.md:183`:** if there are questions that BLOCK the design, say so clearly — don't guess.
- **800-word size budget `[CERT]` `SKILL.md:184`:** the widest budget of the five phases; decisions as tables (option | tradeoff | decision); code snippets only for non-obvious patterns.
- **Simple ASCII diagrams `[CERT]` `SKILL.md:181`:** clarity over beauty.
- **`rules.design` `[CERT]` `SKILL.md:182`:** apply rules from `openspec/config.yaml`.

---

## 8.8 — Connections

- **[Block 6] (`sdd-propose`):** predecessor and **required** dependency. design reads `sdd/{change-name}/proposal` and translates its approach/scope into ADR architecture decisions. propose's `next_recommended` lists design and spec as parallel.
- **[Block 7] (`sdd-spec`):** parallel pair. design reads the spec **optionally** (may not exist if they run in parallel, `SKILL.md:46`). spec = WHAT, design = HOW.
- **[Block 9] (`sdd-tasks`):** successor. design **feeds** tasks: tasks reads spec + design (both required) and decomposes the design into actionable implementation steps. `next_recommended: sdd-tasks` conditioned on spec being ready `[CERT]` `agents/sdd-design.md:43`.
- **[Block 2] (DAG + Result Contract):** design is the second fan-in node toward tasks (alongside spec); standard envelope with `status` discrepancy.
- **[Block 3 / Block 19] (backends + persistence):** topic key `sdd/{change-name}/design`, `type: architecture`.
- **[Block 18] (delegation + models):** `opus` for architecture decisions — the second (and last) opus of the five planning phases.
- **[Block 16] (modes + Gatekeeper):** design is a **high-risk** phase; in Automatic mode the Gatekeeper validates it with a delegated fresh-context reviewer, not inline, because its errors compound downstream. It is also a recommended trigger for `judgment-day` post-design.
- **[Block 24] (judgment-day):** the Agent Trigger rule strongly recommends running `judgment-day` after the design phase completes (high-risk adversarial verification).
