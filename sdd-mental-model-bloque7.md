# Block 7 — `sdd-spec` Phase

> **What it documents:** the specification phase of gentle-ai's SDD system — it takes the proposal and produces delta specs: requirements with RFC 2119 keywords and Given/When/Then scenarios that describe what is ADDED/MODIFIED/REMOVED/RENAMED from the system behavior. It describes the WHAT, never the HOW.
> **Scope:** purpose, what it reads / what it writes, inputs, the 6 steps, the critical MODIFIED Requirements workflow (copy-full-then-edit), delta vs full spec format, Result Contract, `sonnet` model, gotchas (650-word budget, RFC 2119).
> **Exact sources read:**
> - `/home/cristian/.config/opencode/skills/sdd-spec/SKILL.md` (runtime contract — primary)
> - `/home/cristian/.claude/agents/sdd-spec.md` (sub-agent definition: tools, model)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-spec.md` (canonical prompt — identical to SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (common protocol)
> - (NO `commands/sdd-spec.md` exists — it is invoked via meta-commands `[CERT]` `ls commands/`)
> **Method + marker legend:**
> - `[CERT]` = verified by reading the file, `path:line` or `path §section` citation.
> - `[CERT-a]` = asserted by a source, not re-verified.
> - `[INFER]` = my own deduction.

---

## 7.1 — Purpose and position in the DAG `[CERT]`

`sdd-spec` takes the proposal and produces **delta specs**: structured requirements and scenarios that describe what is being ADDED, MODIFIED, REMOVED or RENAMED from the system behavior `[CERT]` `SKILL.md:32-34`. In the DAG it depends on the proposal and feeds tasks: `proposal → spec → tasks` (with design as a parallel dependency of tasks) `[CERT]` `agents/sdd-spec.md:42`.

Guiding principle `[CERT]` `SKILL.md:238`: *"DO NOT include implementation details in specs — specs describe WHAT, not HOW."* The WHAT/HOW separation is the boundary between spec (this block) and design ([Block 8]).

It is an EXECUTOR `[CERT]` `agents/sdd-spec.md:10-11`. Same orchestrator/executor gate `[CERT]` `SKILL.md:13-21`. **It has no direct command `[CERT]`** — it is orchestrated via meta-commands.

## 7.2 — What it reads and what it writes `[CERT]`

| Action | Resource | Topic key / path | Obligation |
|---|---|---|---|
| READS | Proposal | `sdd/{change-name}/proposal` | **required** `[CERT]` `SKILL.md:46`, `agents/sdd-spec.md:19` |
| READS | (openspec) existing domain specs | `openspec/specs/{domain}/spec.md` | conditional on the mode `[CERT]` `SKILL.md:72-74` |
| WRITES | Delta specs / full spec | `sdd/{change-name}/spec` (Engram, concatenated) / `openspec/changes/{change-name}/specs/{domain}/spec.md` | **required** `[CERT]` `SKILL.md:46,196-202` |

**Required input `[CERT]`:** the proposal is a **hard** dependency — `agents/sdd-spec.md:19` instructs `mem_search("sdd/{change-name}/proposal") → mem_get_observation`. Without a proposal there is no spec.

In Engram, if the specs span multiple domains, they are **concatenated into a single artifact** with per-domain headers `[CERT]` `SKILL.md:46`. In openspec/hybrid, per-domain files are written `[CERT]` `SKILL.md:48`. Save with `type: architecture` `[CERT]` `SKILL.md:202`.

## 7.3 — Identify domains from Capabilities (Step 2) `[CERT]`

Step 2 reads the proposal's **Capabilities section** as the primary contract `[CERT]` `SKILL.md:56-70`:

```
FOR EACH "New Capabilities":
├── NEW full spec: openspec/specs/<capability-name>/spec.md
└── full spec (not delta) — there is no previous behavior

FOR EACH "Modified Capabilities":
├── DELTA spec: openspec/changes/{change-name}/specs/<capability-name>/spec.md
└── read openspec/specs/<capability-name>/spec.md first — the delta modifies it
```

Fallback `[CERT]` `SKILL.md:70`: if the proposal has no Capabilities (old format), infer from "Affected Areas" — but always prefer the explicit Capabilities mapping. This closes the proposal→spec contract described in [Block 6 §6.4].

## 7.4 — Critical MODIFIED Requirements workflow `[CERT]`

The most important gotcha of spec. When writing a `## MODIFIED Requirements` section, follow EXACTLY `[CERT]` `SKILL.md:94-110`:

```
1. Locate the requirement in openspec/specs/{domain}/spec.md
2. COPY the ENTIRE block — from `### Requirement:` to ALL its scenarios
3. PASTE under `## MODIFIED Requirements`
4. EDIT the copy to reflect the new behavior
5. Add "(Previously: {one-line summary of what changed})"
```

**Why copy-full-then-edit `[CERT]` `SKILL.md:105-109`:** the archive step REPLACES the requirement in the main specs with your MODIFIED block. If your block is partial, the archive **loses the scenarios you did not copy**. Common pitfall: writing only the scenario that changed and losing the rest. If you ADD NEW behavior without changing the existing → use ADDED, not MODIFIED.

This rule connects directly with [Block 12] (archive): the integrity of the MODIFIED spec determines that the archive does not destroy behavior. Reinforced in Rules `[CERT]` `SKILL.md:239` (*"Partial MODIFIED blocks lose content at archive time"*).

## 7.5 — Delta vs full spec format `[CERT]`

**Delta spec** (existing domain) `[CERT]` `SKILL.md:112-170` — four sections:

- `## ADDED Requirements` — new requirements with happy path + edge case scenarios.
- `## MODIFIED Requirements` — full edited block + `(Previously: ...)`.
- `## REMOVED Requirements` — with `(Reason: ...)` and `(Migration: ...)`.
- `## RENAMED Requirements` — `{Old Name} → {New Name}` + Reason + Migration.

**Full spec** (new domain, no previous spec) `[CERT]` `SKILL.md:172-194`: `# {Domain} Specification` with `## Purpose` and `## Requirements`.

Structure of each requirement `[CERT]` `SKILL.md:119-136`: description with an RFC 2119 keyword, followed by one or more `#### Scenario:` in Given/When/Then/And format.

## 7.6 — RFC 2119 and testability `[CERT]`

Hard style rules `[CERT]` `SKILL.md:230-237`:

- ALWAYS use Given/When/Then for scenarios.
- ALWAYS use RFC 2119 keywords (MUST/SHALL/SHOULD/MAY) for the requirement's strength.
- Each requirement MUST have at least ONE scenario.
- Include happy path **AND** edge case.
- TESTABLE scenarios — someone should be able to write an automated test of each one.

RFC 2119 quick reference `[CERT]` `SKILL.md:247-255`: MUST/SHALL = absolute requirement; MUST NOT/SHALL NOT = absolute prohibition; SHOULD/SHOULD NOT = recommended/not recommended with justification; MAY = optional.

The testability requirement is the bridge to Strict TDD: if each scenario is testable, `sdd-apply`/`sdd-verify` can derive tests from them `[INFER]` (see [Block 23]).

## 7.7 — The 6 steps + Result Contract `[CERT]`

Steps `[CERT]` `SKILL.md:51-226`: Step 1 (load skills) → Step 2 (identify domains from Capabilities) → Step 3 (read existing specs) → Step 4 (write delta specs / full spec) → Step 5 (persist, MANDATORY) → Step 6 (return summary with Domain/Type/Requirements/Scenarios table + Coverage).

Result Contract `[CERT]` `agents/sdd-spec.md:38-44`:

| Field | Values / content |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence of the spec's scope |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/spec`) |
| `next_recommended` | `sdd-tasks` (after design is also ready) |
| `risks` | proposal ambiguities that forced spec-level assumptions |
| `skill_resolution` | `paths-injected` or `none` |

The SKILL's return summary additionally reports Coverage (happy/edge/error) `[CERT]` `SKILL.md:218-222`. Same `status` discrepancy (`done` vs common `success`).

`next_recommended: sdd-tasks` is conditioned on design also being ready `[CERT]` `agents/sdd-spec.md:42` — tasks needs spec **and** design.

## 7.8 — Assigned model: `sonnet` `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-spec.md:6`. Table justification: *"sdd-spec | sonnet | Structured writing"* `[CERT-a]` (CLAUDE.md, Model Assignments). Reasoning `[INFER]`: spec is **structured writing**, not an architectural decision — the decisions were already made by propose (opus) and will be made by design (opus). spec translates the proposal's WHAT into formal testable requirements following strict templates (RFC 2119, Given/When/Then), a task sonnet executes faithfully.

Tools `[CERT]` `agents/sdd-spec.md:7`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`.

## 7.9 — Gotchas and special rules `[CERT]`

- **650-word size budget `[CERT]` `SKILL.md:244`:** prefer requirement tables over narrative; each scenario 3-5 lines max.
- **MODIFIED = full block `[CERT]` `SKILL.md:239`:** the copy-full-then-edit rule of §7.4; partial MODIFIED blocks lose content at archive.
- **ADDED vs MODIFIED `[CERT]` `SKILL.md:240`:** new behavior without changing the existing → ADDED, not MODIFIED.
- **REMOVED/RENAMED `[CERT]` `SKILL.md:241-242`:** REMOVED must include Reason and should include Migration when there are affected consumers/docs/tests; RENAMED must declare both names.
- **`rules.specs` `[CERT]` `SKILL.md:243`:** apply rules from `openspec/config.yaml`.
- **WHAT not HOW `[CERT]` `SKILL.md:238`:** no implementation details.

---

## 7.10 — Connections

- **[Block 6] (`sdd-propose`):** predecessor and **required** dependency. spec reads `sdd/{change-name}/proposal` and consumes its Capabilities section as a contract to decide which specs to create (`SKILL.md:56-70`).
- **[Block 8] (`sdd-design`):** parallel pair. Both depend on the proposal; design reads the spec optionally (`sdd/{change-name}/spec`). spec describes the WHAT, design the HOW — explicit boundary in `SKILL.md:238`.
- **[Block 9] (`sdd-tasks`):** successor. tasks requires spec **and** design ready; `next_recommended: sdd-tasks` conditioned on design `[CERT]` `agents/sdd-spec.md:42`.
- **[Block 12] (`sdd-archive`):** the archive REPLACES requirements in the main specs with the spec's MODIFIED blocks — hence the criticality of the copy-full-then-edit workflow (§7.4).
- **[Block 2] (DAG + Result Contract):** standard envelope with `status` discrepancy.
- **[Block 3 / Block 19] (backends + persistence):** topic key `sdd/{change-name}/spec`; in Engram a single concatenated multi-domain artifact.
- **[Block 18] (delegation + models):** `sonnet` for structured writing.
- **[Block 23] (strict-TDD):** the testable Given/When/Then scenarios are the basis apply/verify use to derive and validate tests.
