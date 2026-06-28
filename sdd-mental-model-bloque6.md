# Block 6 — `sdd-propose` Phase

> **What it documents:** the proposal phase of gentle-ai's SDD system — it turns the exploration (or direct user input) into a structured `proposal.md`: intent, scope, capabilities, approach, risks, rollback and success criteria. Includes the product question round that precedes the proposal in interactive mode.
> **Scope:** purpose, what it reads / what it writes, inputs, the question round (Step 0), the 6 steps, the Capabilities section as a contract with spec, Result Contract, the `opus` model and why, gotchas (450-word budget, mandatory rollback).
> **Exact sources read:**
> - `/home/cristian/.config/opencode/skills/sdd-propose/SKILL.md` (runtime contract — primary)
> - `/home/cristian/.claude/agents/sdd-propose.md` (sub-agent definition: tools, model)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-propose.md` (canonical prompt — identical to SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (common protocol)
> - (NO `commands/sdd-propose.md` exists — propose is invoked via meta-commands, not a direct command `[CERT]` `ls commands/`)
> **Method + marker legend:**
> - `[CERT]` = verified by reading the file, `path:line` or `path §section` citation.
> - `[CERT-a]` = asserted by a source, not re-verified.
> - `[INFER]` = my own deduction.

---

## 6.1 — Purpose and position in the DAG `[CERT]`

`sdd-propose` takes the exploration analysis (or direct user input) and produces a structured `proposal.md` inside the change folder `[CERT]` `SKILL.md:32-34`. In the DAG it is the node that follows explore and precedes spec **and** design (both depend on the proposal): `explore → proposal → {spec, design}` `[CERT]` `agents/sdd-propose.md:56` (*"next_recommended: sdd-spec and sdd-design (can run in parallel)"*).

It is the **first architectural phase**: unlike explore (which only investigates), propose commits intent, scope and approach. That is why it runs on `opus` (see §6.7).

It is an EXECUTOR `[CERT]` `agents/sdd-propose.md:10-11`. Same orchestrator/executor gate as the rest `[CERT]` `SKILL.md:13-21`.

**It has no direct command `[CERT]`:** `commands/sdd-propose.md` does not exist. It is launched via the orchestrator's meta-commands (`/sdd-new`, `/sdd-ff`, `/sdd-continue`) — see [Block 14].

## 6.2 — What it reads and what it writes `[CERT]`

| Action | Resource | Topic key / path | Obligation |
|---|---|---|---|
| READS | Previous exploration | `sdd/{change-name}/explore` | **optional** `[CERT]` `SKILL.md:47` |
| READS | Project context | `sdd-init/{project}` | optional `[CERT]` `SKILL.md:47` |
| READS | (openspec) existing specs | `openspec/specs/` | conditional on the mode `[CERT]` `SKILL.md:86-87` |
| WRITES | Proposal | `sdd/{change-name}/proposal` (Engram) / `openspec/changes/{change-name}/proposal.md` | **required** `[CERT]` `SKILL.md:47,163-170` |

**Required inputs from the orchestrator** `[CERT]` `SKILL.md:36-41`: change name (e.g. `add-dark-mode`); the exploration analysis (from sdd-explore) **OR** direct user description; the artifact store mode.

**Optional inputs** `[CERT]`: explore and project context — both optional, their absence does not block (propose can start from direct input).

Save with `type: architecture` `[CERT]` `SKILL.md:170`, `agents/sdd-propose.md:46`. Rule: never force creation of `openspec/` unless the user requests file-based persistence or the mode is hybrid `[CERT]` `SKILL.md:51`.

## 6.3 — The product question round (Step 0) `[CERT]`

This is propose's distinctive piece. In interactive SDD mode, the executor must **NOT** silently decide whether the proposal is "clear enough": it must offer the user a *proposal question round* before finalizing `[CERT]` `SKILL.md:55-69`, `agents/sdd-propose.md:15-27`.

Explicit purpose `[CERT]` `SKILL.md:57`: the questions improve the PRD/proposal by uncovering business rules, implications, impact, edge cases and product tradeoffs. The user can answer, skip, correct the framing or request a second round.

The questions cover **business/product/PRD understanding, not harness mechanics** `[CERT]` `SKILL.md:58`. The smallest useful subset of 10 axes `[CERT]` `SKILL.md:58-68`:

1. **business problem** — what pain, opportunity, user confusion or operational cost justifies it now.
2. **target users and situations** — who is affected, in what workflow, at what moment, with what urgency.
3. **business rules** — policies, permissions, thresholds, lifecycle rules, compliance/security, domain invariants.
4. **product outcome** — what should feel, work or become possible.
5. **current-state gap** — what is wrong, inconsistent, ad hoc or hard to explain today.
6. **implications and impact** — what teams, workflows, data, UX, support or processes are affected.
7. **edge cases** — empty states, partial data, failures, permissions, slow paths, unusual clients, migrations, conflicting needs.
8. **decision gaps** — what product unknowns make the proposal ambiguous or easy to over-build.
9. **scope boundaries and non-goals** — what goes in the first slice, what is later refinement, what must stay untouched.
10. **business risk or tradeoff** — what downside matters most if the wrong direction is chosen.

Cadence `[CERT]` `SKILL.md:69`: **3–5 concrete questions per round**. After the first answers, summarize the resulting assumptions and ask if the user wants to correct anything or run a second round. Do **NOT** ask about test commands, PR shape, line budget or other harness decisions unless the user asks for it.

**Fallback if blocked from asking `[CERT]` `SKILL.md:69`:** write a `## Proposal question round` section in the proposal result with the proposed questions and the assumptions that need user review. This preserves the intent even in non-interactive mode `[INFER]`.

## 6.4 — The Capabilities section: the contract with spec `[CERT]`

The `proposal.md` (Step 4) has a **Capabilities** section that is literally *"the CONTRACT between proposal and specs phases"* `[CERT]` `SKILL.md:114-118`. The sdd-spec agent reads it to know exactly which spec files to create or update.

Two sub-sections `[CERT]` `SKILL.md:120-130`:

- **New Capabilities** — introduced capabilities; each becomes a new `openspec/specs/<name>/spec.md` (full spec). Names in kebab-case (`user-auth`, `data-export`).
- **Modified Capabilities** — existing capabilities whose REQUIREMENTS change (not just implementation); each needs a delta spec.

Reinforcing rules `[CERT]` `SKILL.md:201-204`: ALWAYS fill Capabilities by first investigating `openspec/specs/` to use correct names; if nothing changes at the spec level (pure refactor, config change) explicitly write "None" in both sub-sections — leave no placeholders.

## 6.5 — Full structure of `proposal.md` `[CERT]`

`[CERT]` `SKILL.md:95-161`:

- `## Intent` — what problem, why now.
- `## Scope` → `### In Scope` / `### Out of Scope` (explicit what is NOT done).
- `## Capabilities` → New / Modified (the contract §6.4).
- `## Approach` — high-level technical approach, referencing the exploration recommendation.
- `## Affected Areas` — table `Area | Impact (New/Modified/Removed) | Description`.
- `## Risks` — table `Risk | Likelihood | Mitigation`.
- `## Rollback Plan` — how to revert; **mandatory** `[CERT]` `SKILL.md:197`.
- `## Dependencies` — external prerequisites.
- `## Success Criteria` — measurable checklist; **mandatory** `[CERT]` `SKILL.md:198`.

## 6.6 — The 6 steps + Result Contract `[CERT]`

Steps `[CERT]` `SKILL.md:55-172`: Step 0 (question round) → Step 1 (load skills) → Step 2 (create change directory only in openspec/hybrid) → Step 3 (read existing specs) → Step 4 (write `proposal.md`) → Step 5 (persist, MANDATORY) → Step 6 (return summary).

Result Contract `[CERT]` `agents/sdd-propose.md:51-58`:

| Field | Values / content |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence of the proposal |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/proposal`) |
| `next_recommended` | `sdd-spec` **and** `sdd-design` (can run in parallel) |
| `risks` | open questions, unresolved tradeoffs, blocking dependencies |
| `skill_resolution` | `paths-injected` or `none` |

The SKILL's return summary (Step 6) additionally reports `Risk Level: {Low/Medium/High}` and *"Ready for specs (sdd-spec) or design (sdd-design)"* `[CERT]` `SKILL.md:176-190`. Same `status` discrepancy (`done` vs common `success`) as in init/explore.

## 6.7 — Assigned model: `opus` `[CERT]`

`model: opus` `[CERT]` `agents/sdd-propose.md:6`. The orchestrator's table justifies it: *"sdd-propose | opus | Architectural decisions"* `[CERT-a]` (CLAUDE.md, Model Assignments). Reasoning `[INFER]`: propose is the first point where a product and architecture direction is committed (intent, scope boundaries, approach, tradeoffs) — decisions that propagate to spec, design, tasks and apply. An error here compounds downstream, which is why it uses the highest reasoning-capacity model.

Tools `[CERT]` `agents/sdd-propose.md:7`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`. Unlike explore, propose DOES have `mem_search`/`mem_get_observation` (it must retrieve the exploration and project context from Engram).

## 6.8 — Gotchas and special rules `[CERT]`

- **450-word size budget `[CERT]` `SKILL.md:205`:** the proposal artifact MUST be under 450 words. Bullets and tables over prose. *"Headers organize, not explain."* It is the phase with the tightest budget of the five.
- **Mandatory Rollback + Success Criteria `[CERT]` `SKILL.md:197-198`:** every proposal MUST have a rollback plan and success criteria.
- **Update if it already exists `[CERT]` `SKILL.md:195`:** if the change folder already has a proposal, READ it first and UPDATE it (do not duplicate).
- **Explicit "None" Capabilities `[CERT]` `SKILL.md:204`:** pure refactor/config must write "None", never leave the template placeholder.
- **`rules.proposal` `[CERT]` `SKILL.md:200`:** apply rules from `openspec/config.yaml` if they exist.
- **Concise `[CERT]` `SKILL.md:196`:** the proposal is *"a thinking tool, not a novel"*.

---

## 6.9 — Connections

- **[Block 5] (`sdd-explore`):** predecessor. propose optionally reads `sdd/{change-name}/explore` and references its recommendation in the Approach section `[CERT]` `SKILL.md:47,134`.
- **[Block 7] (`sdd-spec`):** direct successor. The proposal's **Capabilities** section is the contract spec consumes to decide which specs to create/modify (`SKILL.md:114-118`). spec reads `sdd/{change-name}/proposal` as a **required** dependency.
- **[Block 8] (`sdd-design`):** parallel successor to spec. design reads `sdd/{change-name}/proposal` (required) and `sdd/{change-name}/spec` (optional). The `next_recommended` declares that spec and design can run in parallel `[CERT]` `agents/sdd-propose.md:56`.
- **[Block 2] (DAG + Result Contract):** propose is the fan-out node (one parent, two children spec/design).
- **[Block 3 / Block 19] (backends + persistence):** topic key `sdd/{change-name}/proposal`, `type: architecture`.
- **[Block 18] (delegation + models):** `opus` model for architectural decisions; first phase of the table that scales up to opus.
- **[Block 16] (modes + Gatekeeper):** the question round (Step 0) is what the orchestrator in Interactive mode exposes before propose; the Gatekeeper validates the proposal inline as a low-risk phase unless there is a "smell".
- **[Block 14] (meta-commands):** propose has no direct command; it is orchestrated via `/sdd-new`, `/sdd-ff`, `/sdd-continue`.
