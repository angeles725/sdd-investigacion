# Block 4 — `sdd-init` Phase

> **What it documents:** the initialization phase of gentle-ai's SDD system — the bootstrap that detects the stack, builds the skill-registry, resolves Strict TDD and persists the project context before any other phase.
> **Scope:** purpose, what it reads / what it writes (artifacts + topic keys), required vs optional inputs, the 7 execution steps, Result Contract, assigned model, gotchas. Stack detection, skill-registry and Strict TDD activation are covered in detail.
> **Exact sources read:**
> - `/home/cristian/.config/opencode/skills/sdd-init/SKILL.md` (runtime contract — primary)
> - `/home/cristian/.config/opencode/skills/sdd-init/references/init-details.md` (detection checklist, Engram payloads, config skeleton, templates)
> - `/home/cristian/.claude/agents/sdd-init.md` (sub-agent definition: tools, model)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-init.md` (canonical prompt — identical to SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-init.md` (orchestrator command)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (common protocol)
> **Method + marker legend:**
> - `[CERT]` = verified by reading the file, with `path:line` or `path §section` citation.
> - `[CERT-a]` = asserted by a source, not re-verified against the primary origin that source describes.
> - `[INFER]` = my own deduction from the evidence.

---

## 4.1 — Purpose and position in the DAG `[CERT]`

`sdd-init` initializes a project's SDD context: it detects stack/conventions/architecture, detects testing capabilities, resolves Strict TDD, builds the skill-registry and initializes the persistence backend `[CERT]` `skills/sdd-init/SKILL.md:3` (description) and `:58-66` (Execution Steps).

It is the **zero** phase: it does not appear in the linear dependency graph `proposal → specs → tasks → apply → verify → archive`, but is a cross-cutting prerequisite required before any SDD command. The orchestrator runs it silently if it does not exist (see Connections with [Block 18]). Its `next_recommended` points to `sdd-explore` or `sdd-new` `[CERT]` `agents/sdd-init.md:40` and `SKILL.md:70`.

The sub-agent is a pure EXECUTOR: it does the work itself, does not delegate, does not act as an orchestrator `[CERT]` `agents/sdd-init.md:11-12` ("Do NOT call the Task tool. Do NOT launch sub-agents.") and `SKILL.md:32-33`.

### Dual orchestrator/executor gate `[CERT]`

The SKILL.md opens with an **ORCHESTRATOR GATE**: if loaded via the `skill()` tool, the reader IS the orchestrator and must STOP and delegate to the dedicated sub-agent `[CERT]` `SKILL.md:13-17`. The immediate **Executor Override** clarifies: if you are already the `sdd-init` sub-agent, the gate does not apply — execute `[CERT]` `SKILL.md:19-21`. This gate+override pattern repeats identically in the 5 planning phases (init/explore/propose/spec/design).

## 4.2 — What it reads and what it writes `[CERT]`

| Action | Resource | Topic key / path | Obligation |
|---|---|---|---|
| READS | Project files (`package.json`, `go.mod`, `pyproject.toml`, CI, lint/test config) | filesystem | required `[CERT]` `SKILL.md:60` |
| READS | Agent's Strict TDD marker / `openspec/config.yaml` | filesystem | optional `[CERT]` `SKILL.md:62` |
| READS | User + project skill directories (scan) | multiple paths | required `[CERT]` `init-details.md:11-19` |
| WRITES | Detected project context | `sdd-init/{project}` | required `[CERT]` `init-details.md:33-35`, `agents/sdd-init.md:28-32` |
| WRITES | Testing capabilities | `sdd/{project}/testing-capabilities` (Engram) or `openspec/config.yaml` `testing:` | required `[CERT]` `SKILL.md:41`, `init-details.md:38-40` |
| WRITES | Skill registry (index) | `.atl/skill-registry.md` + Engram `skill-registry` | required `[CERT]` `SKILL.md:42`, `init-details.md:43-46` |
| WRITES | (openspec/hybrid) file skeleton | `openspec/config.yaml`, `specs/`, `changes/archive/` | conditional on the mode `[CERT]` `init-details.md:50-59` |

**Required inputs from the orchestrator** `[CERT]`: the artifact store mode (`engram | openspec | hybrid | none`) resolved in the Session Preflight; the command prohibits hardcoding Engram `[CERT]` `commands/sdd-init.md:18` ("Use the resolved artifact store... do not hardcode Engram").

**Optional inputs** `[INFER]`: project conventions (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`) are scanned if they exist but their absence does not block.

The three Engram saves declare a different `type`: `sdd-init/{project}` → `architecture`; `testing-capabilities` → `config`; `skill-registry` → `config`, all with `capture_prompt: false` when the schema supports it `[CERT]` `init-details.md:33-46`.

## 4.3 — Stack and testing capability detection `[CERT]`

The detection checklist (step 1-2) covers `[CERT]` `init-details.md:3-8`:

- **Test runner:** scripts/deps of `package.json`, `pyproject.toml`, `pytest.ini`, `go.mod`, `Cargo.toml`, `Makefile`.
- **Test layers:** unit (runner); integration (`testing-library`, `httpx`, `httptest`, `WebApplicationFactory`); E2E (`playwright`, `cypress`, `selenium`, `chromedp`).
- **Coverage:** `vitest --coverage`, `jest --coverage`, `c8`, `pytest-cov`, `go test -cover`, `coverlet`.
- **Quality:** linter, type checker, formatter.

The result is persisted with the tabular format of `init-details.md:62-94` `[CERT]`: a **Test Layers** table (Unit/Integration/E2E × Available × Tool), a **Coverage** section and a **Quality Tools** table (Linter/Type checker/Formatter). The header declares `**Strict TDD Mode**: {enabled/disabled}` and the detection date.

Hard rule: *"Detect the real stack... never guess"* `[CERT]` `SKILL.md:37`. Detection is never presumptive.

## 4.4 — Strict TDD resolution `[CERT]`

Step 3 resolves Strict TDD with a precise source hierarchy `[CERT]` `SKILL.md:62` and the Decision Gates table `SKILL.md:54-56`:

| Input | Action |
|---|---|
| Strict TDD marker/config found | use THAT value |
| no marker but a test runner exists | default `strict_tdd: true` |
| no test runner | `strict_tdd: false` + explain that it is not available |

Precedence order `[CERT]` `SKILL.md:62`: (1) agent marker → (2) `openspec/config.yaml` → (3) fallback by detected runner → (4) fallback with no runner. The practical consequence: **a project with a runner but without explicit configuration activates Strict TDD by default** `[INFER]` — this is later read by `sdd-apply`/`sdd-verify` via the testing-capabilities topic key (see [Block 23]).

## 4.5 — Skill Registry: scan and indexing `[CERT]`

Step 5 builds `.atl/skill-registry.md` following the Skill Registry Scan Rules `[CERT]` `init-details.md:10-19`:

- **User skills scan:** `~/.config/opencode/skills/`, `~/.claude/skills/`, `~/.gemini/skills/`, `~/.cursor/skills/`, `~/.codex/skills/`, and ~15 more paths per agent `[CERT]` `init-details.md:12`.
- **Project skills scan:** `{root}/skills/`, `.opencode/skills/`, `.claude/skills/`, `.agent/skills/`, `.atl/skills/`, etc. `[CERT]` `init-details.md:13`.
- **Filtering:** `sdd-*`, `_shared` and `skill-registry` are skipped; deduplicated by name **preferring project-level over user-level** `[CERT]` `init-details.md:14`.
- **Per-skill extraction:** `name`, trigger text of the `description`, full path of the `SKILL.md`, and scope `[CERT]` `init-details.md:16`.
- **Project conventions:** scans `agents.md`/`AGENTS.md`, project `CLAUDE.md`, `.cursorrules`, `GEMINI.md`, `copilot-instructions.md`; for indexes like `AGENTS.md` it extracts the referenced paths and includes index + files `[CERT]` `init-details.md:18-19`.

Key principle `[CERT]` `init-details.md:17`: *"Treat the registry as an index, not a generated summary; subagents receive exact paths and read the full skill source of truth."* — this is the basis of the orchestrator's Skill Resolver Protocol (see [Block 22]): PATHS are passed, not summaries.

The registry is also saved in Engram as `skill-registry` when available `[CERT]` `SKILL.md:42`.

## 4.6 — Decision Gates by persistence mode `[CERT]`

The Decision Gates table governs what is written according to the mode `[CERT]` `SKILL.md:48-56`:

| Mode | Action |
|---|---|
| `engram` | save context and capabilities only in Engram; do **NOT** create `openspec/` |
| `openspec` | create/update openspec bootstrap files following `_shared/openspec-convention.md` |
| `hybrid` | do both (Engram + openspec) |
| `none` | return detected context; do not write SDD artifacts except registry if required |

Reinforcing hard rules `[CERT]` `SKILL.md:38-44`: in `engram` do **not** create `openspec/`; testing-capabilities is always persisted separately; always build `.atl/skill-registry.md`; **if `openspec/` already exists, report and ask before updating** `[CERT]` `SKILL.md:44`.

The OpenSpec skeleton `[CERT]` `init-details.md:50-59`: `openspec/config.yaml` + `specs/` + `changes/archive/`. The `config.yaml` carries concise context (`context:` under 10 lines), `strict_tdd`, testing capabilities and phase rules for proposal/spec/design/tasks/apply/verify/archive.

## 4.7 — The 7 execution steps `[CERT]`

`[CERT]` `SKILL.md:58-66`:

1. Inspect project files and summarize stack/conventions.
2. Detect test runner, layers, coverage, linter, type checker, formatter.
3. Resolve Strict TDD (marker → config → runner → no-runner).
4. Initialize persistence for the resolved mode.
5. Build `.atl/skill-registry.md` with the scan rules.
6. Persist testing capabilities and project context.
7. Return the structured initialization envelope.

The canonical prompt (`agents/sdd-init.md`) compresses this to 4 operational steps `[CERT]` `agents/sdd-init.md:19-24` (detect stack → initialize backend → build registry → save context), delegating the detail to the SKILL.md which orders to read and follow `~/.claude/skills/sdd-init/SKILL.md` exactly `[CERT]` `agents/sdd-init.md:16`.

## 4.8 — Result Contract `[CERT]`

The SKILL's Output Contract asks to return `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, and to include: project, stack, persistence mode, Strict TDD status, testing capabilities table, IDs/paths of saved observations, registry path and the next step `/sdd-explore` or `/sdd-new` `[CERT]` `SKILL.md:68-70`.

The agent prompt formalizes the fields `[CERT]` `agents/sdd-init.md:36-42`:

| Field | Values / content |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence of what was initialized |
| `artifacts` | paths/topic_keys (`.atl/skill-registry.md`, `sdd-init/{project}`) |
| `next_recommended` | `sdd-explore` or `sdd-new` |
| `risks` | warnings about detected stack or backend |
| `skill_resolution` | `paths-injected` if exact paths were passed, otherwise `none` |

**Discrepancy gotcha `[CERT]`:** the agent's `status` uses `done | blocked | partial` `agents/sdd-init.md:37`, but the common Return Envelope (`sdd-phase-common.md §D`) defines `success | partial | blocked` `[CERT]` `sdd-phase-common.md:76`. The phases declare `done` in their prompt but the shared contract says `success`. `[INFER]` the orchestrator treats both as success.

## 4.9 — Assigned model `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-init.md:7`. The orchestrator's Model Assignments table does not list `sdd-init` explicitly, so it falls into the `default → sonnet` row `[CERT-a]` (CLAUDE.md, Model Assignments). The reasoning `[INFER]`: init is structural-mechanical work (pattern-based detection, directory scan, writing an index), not architecture decisions — consistent with the justification the table gives for sonnet phases ("Reads code, structural - not architectural").

Agent tools `[CERT]` `agents/sdd-init.md:8`: `Read, Edit, Write, Glob, Grep, Bash` + `mem_search, mem_get_observation, mem_save, mem_update`. It is the planning phase with the **most tools** because it needs Bash (inspect project files, run detection) and Write (write `.atl/skill-registry.md` and the openspec skeleton).

## 4.10 — Gotchas and special rules `[CERT]`

- **Silent launch:** the orchestrator runs init automatically if it does not exist, without asking the user `[CERT-a]` (CLAUDE.md, SDD Init Guard: *"just run init silently if needed"*).
- **Session Preflight gate:** the command requires that the preflight (execution mode, artifact store, chained PR strategy, review budget) be complete before launching init; if missing, it asks and STOPS in the same turn `[CERT]` `commands/sdd-init.md:16`.
- **Pre-existing `openspec/`:** it is not blindly overwritten — report and ask `[CERT]` `SKILL.md:44`.
- **`capture_prompt: false`:** mandatory in all automated init/config saves; omit the field if the old schema does not support it, never fail because of that `[CERT]` `SKILL.md:43`, `agents/sdd-init.md:32`.
- **Workspace authority:** the command resolves the workspace with `git rev-parse --show-toplevel || pwd` because in OpenCode Desktop (Electron) the parse-time interpolation points to the app data dir, not the project `[CERT]` `commands/sdd-init.md:11`.

---

## 4.11 — Connections

- **[Block 5] (`sdd-explore`):** recommended successor by default. init produces `sdd-init/{project}`, which explore optionally reads as project context `[CERT]` `skills/sdd-explore/SKILL.md:46,55`.
- **[Block 2] (DAG + Result Contract):** init returns the same 6-field envelope as every phase, although with the `status` discrepancy documented in §4.8.
- **[Block 3 / Block 19] (backends + topic keys / persistence-contract):** init is the one that materializes the chosen backend (engram/openspec/hybrid/none) and seeds the root topic keys `sdd-init/{project}`, `sdd/{project}/testing-capabilities`, `skill-registry`.
- **[Block 18] (delegation + triggers + models):** the orchestrator's SDD Init Guard forces init to run before any other SDD command; the `sonnet` model comes from the `default` row of the Model Assignments table.
- **[Block 22] (skill-resolver + phase-common):** the `.atl/skill-registry.md` that init builds is the source the Skill Resolver Protocol consults to inject exact paths into each delegation. init implements the "index, not summary" principle.
- **[Block 23] (strict-TDD):** the Strict TDD resolution in §4.4 produces the `strict_tdd: true/false` that the orchestrator propagates (Strict TDD Forwarding) to `sdd-apply`/`sdd-verify`.
