# Block 18 — Delegation model, mandatory triggers, and model assignments

> **WHAT IT DOCUMENTS**: This block consolidates the SDD orchestrator's delegation model: the inline-vs-delegate decision table, the six Mandatory Delegation Triggers (hard gates), the Model Assignments table (phase → model → effort → reason), the per-phase mandatory model gate, and the deduplication of sub-agent launches.
> **SCOPE**: The delegation criterion, the six non-skippable triggers, the cost/context balance, the per-phase SDD/Judgment-Day model table, the mandatory model gate, the summarized Skill Resolver Protocol, and the dedup of launches. It is the cross-cutting layer that governs HOW the orchestrator summons ALL phases. For the detail of each phase, see [Block 5] to [Block 12].
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Delegation Rules", §"Mandatory Delegation Triggers", §"Cost and Context Balance", §"Model Assignments", §"Sub-Agent Launch Deduplication (MANDATORY)", §"Sub-Agent Launch Pattern", §"Result Contract"
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path §section`. `[CERT-a]` = asserted by a source, not re-verified. `[INFER]` = my own deduction.

---

## 18.1 — The root criterion: does this inflate my context without need? `[CERT]`

The guiding principle of all delegation is a single question `[CERT]` (`CLAUDE.md` §"Delegation Rules"): *"does this inflate my context without need? If yes → delegate. If no → do it inline."*

The decision table `[CERT]` (`CLAUDE.md` §"Delegation Rules"):

| Action | Inline | Delegate |
|--------|--------|---------|
| Read to decide/verify (1-3 files) | ✅ | — |
| Read to explore/understand (4+ files) | — | ✅ |
| Read as preparation for writing | — | ✅ together with the write |
| Write atomic (one file, mechanical, you already know what) | ✅ | — |
| Write with analysis (multiple files, new logic) | — | ✅ |
| Bash for state (git, gh) | ✅ | — |
| Bash for execution (test, build, install) | — | ✅ |

Anti-patterns that ALWAYS inflate context without need `[CERT]` (`CLAUDE.md` §"Delegation Rules"):

- Read 4+ files to "understand" the codebase inline → delegate an exploration.
- Write a feature across multiple files inline → delegate.
- Run tests or builds inline → delegate.
- Read files as preparation for edits and then edit → delegate the whole thing together.

Critical semantic guard `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers"): **delegate** means using the platform's native sub-agent mechanism (`Agent`/`Task`/`delegate`). Running local scripts, Python, or Bash inline is EXECUTION, not delegation.

(This section is the base that [Block 1] introduces at the philosophical level; here it is treated as the operational mechanics that govern each launch.)

## 18.2 — The six Mandatory Delegation Triggers `[CERT]`

They are **non-skippable parent-orchestrator stop rules** — NOT recommendations `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers": "non-skippable hard gates, not recommendations... TOTALMENTE obligatorio"). Tool unavailability is NOT a waiver: the blocker is documented, the blocked delegated work is stopped, and the closest fresh-context audit is performed only where the rule calls for it.

| # | Rule | Trigger and required action `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers") |
|---|-------|---------------------------------------------------------------------------------------|
| 1 | **4-file rule** | If understanding requires reading 4+ files → delegate a narrow exploration/mapping. If there is no delegation tooling → document the blocker and STOP the exploration, do not read everything inline. |
| 2 | **Multi-file write rule** | If the implementation will touch 2+ non-trivial files → delegate ONE writer. Without tooling → document and stop; a fresh review is required AFTER the delegated implementation, not a substitute for delegation. |
| 3 | **PR rule** | Before commit/push/PR after code changes → fresh-context review, except a trivial docs/text diff. |
| 4 | **Incident rule** | After a wrong `cwd`, accidental repo/worktree mutation, merge recovery, confusing test command, or environment workaround → STOP and run a fresh audit before continuing. |
| 5 | **Long-session rule** | After ~20 tool calls, 5 exploratory reads, or 2 non-mechanical edits without delegating and with growing complexity → pause and delegate the rest. Without tooling → document and stop the complex work. |
| 6 | **Fresh review rule** | Use fresh context for adversarial review of diffs/conflicts/PR readiness/incidents; use continuity/fork ONLY for implementation that needs inherited state. |

Scope rules of the triggers `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers"):

- They are PARENT orchestrator stop rules. They are NOT passed to child agents as permission to spawn more agents. Children receive concrete role work and must NOT orchestrate.
- The rules that say **delegate** require native sub-agent delegation. Those that say **fresh review/audit** require fresh context before continuing.

**Mental model** `[INFER]`: the six triggers group into two families. The trio (1, 2, 5) are **context-compression** triggers — when the work grows (4 files, 2 writes, 20 tool calls), delegate so as not to inflate the thread. The trio (3, 4, 6) are **judgment-independence** triggers — when there is risk (PR, incident, review), use FRESH context because its value is objectivity, not token saving. It is the same duality that [Block 1] §1.5 establishes.

## 18.3 — Cost and context balance `[CERT]`

The system keeps two motivations for delegating conceptually separate `[CERT]` (`CLAUDE.md` §"Cost and Context Balance"):

- **Exploration** → compresses broad repo reading into a short handoff (token saving).
- **Writing** → a single writer thread for implementation; do NOT run parallel writers except explicitly approved isolated worktrees.
- **Fresh reviewers** after implementation/conflicts/incidents → their value is INDEPENDENT judgment, not token saving.
- **Do NOT delegate** for: truly local single-file fixes, quick state checks, already-understood mechanical edits.

Write-parallelism rule `[CERT]`: a single writer thread for implementation; no parallel writers except explicitly approved isolated worktrees. This prevents concurrent-write conflicts over the same files.

## 18.4 — The Model Assignments table `[CERT]`

The orchestrator reads this table at session start, caches it, and uses the mapped alias ONLY for SDD/Judgment-Day phase agents `[CERT]` (`CLAUDE.md` §"Model Assignments"). The full table `[CERT]`:

| Phase | Default Model | Effort | Reason `[CERT]` (`CLAUDE.md` §"Model Assignments") |
|------|----------------|--------|---------------------------------------------------|
| `sdd-explore` | sonnet | default | Reads code, structural — not architectural |
| `sdd-propose` | opus | default | Architectural decisions |
| `sdd-spec` | sonnet | default | Structured writing |
| `sdd-design` | opus | default | Architecture decisions |
| `sdd-tasks` | sonnet | default | Mechanical breakdown |
| `sdd-apply` | sonnet | default | Implementation |
| `sdd-verify` | sonnet | default | Validation against spec |
| `sdd-archive` | haiku | default | Copy and close |
| `sdd-onboard` | haiku | default | Guided walkthrough, pedagogical |
| `jd-judge-a` | sonnet | default | Adversarial review — blind judge A |
| `jd-judge-b` | sonnet | default | Adversarial review — blind judge B |
| `jd-fix-agent` | sonnet | default | Surgical fixes from confirmed issues |
| `default` | sonnet | default | SDD/JD phase fallback |

Table rules `[CERT]` (`CLAUDE.md` §"Model Assignments"):

- If an SDD/JD phase is missing from the table → use the `default` row.
- If you do not have access to the assigned model (e.g. no Opus access) → substitute `sonnet` and continue.
- The Claude Code session model is controlled by Claude Code itself; Gentle AI does NOT configure the main orchestrator model. *"This table applies only to Agent tool calls for SDD/Judgment-Day phase sub-agents, not generic delegation."* `[CERT]`.

**Why each model** `[INFER]`: the table maps **cognitive complexity → model capacity**. The only two phases with **opus** are `sdd-propose` and `sdd-design` — the ones that make ARCHITECTURAL decisions, where an error compounds downstream (the same high-risk phases of the Gatekeeper in [Block 16]). The structured-or-mechanical writing phases (`spec`, `tasks`, `apply`, `verify`) use **sonnet**: capable but they do not have to decide architecture. The copy/close and pedagogical phases (`archive`, `onboard`) use **haiku**: mechanical or low-risk work where the cheapest model suffices. It is resource allocation proportional to the risk of the decision.

## 18.5 — The Mandatory Phase Model Gate `[CERT]`

Hard rule `[CERT]` (`CLAUDE.md` §"Model Assignments"): *"Agent tool calls for SDD/Judgment-Day phase agents MUST include `model`. Generic/non-SDD delegation MUST NOT use this table; omit `model` unless the user explicitly requested an override."*

The mandatory pre-flight before each SDD/JD phase Agent call `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Pattern"):

1. Identify the SDD/JD phase (`sdd-apply`, `sdd-verify`, `jd-judge-a`, etc.) or use `default` only as a phase fallback.
2. Look up the alias in the Model Assignments table.
3. Include `model: "<alias>"` in the SDD/JD Agent tool call.
4. For generic/non-SDD delegation: do NOT use this table; omit `model` unless the user explicitly requests an override.

**The boundary of the gate** `[INFER]`: there are TWO classes of delegation with opposite rules about `model`. SDD/JD PHASE Agent calls MUST carry `model` (resolved from the table). GENERIC delegation (ad-hoc explorations, non-phase reviewers, searches) MUST NOT carry `model` unless the user asks for it. Mixing them is an error: putting `model` on a generic delegation forces a model the user did not choose; omitting it on an SDD phase violates the gate. The gate exists so that each phase runs on the correct model WITHOUT the cost of Opus spilling over to tasks that do not need it.

## 18.6 — Skill Resolver Protocol (operational summary) `[CERT]`

Every sub-agent launch prompt that involves reading/writing/reviewing code MUST include **pre-resolved skill paths** from the registry `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Pattern"). The orchestrator resolves skills from the registry ONCE (at session start or first delegation), caches the index, and passes the matching `SKILL.md` paths into each sub-agent prompt.

Orchestrator resolution (once per session) `[CERT]`:

1. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` for the full content.
2. Fallback: read `.atl/skill-registry.md` if engram is not available.
3. Cache the index: skill name, trigger/description, scope, exact path.
4. If there is no registry → warn the user and proceed without project-specific standards.

For each launch `[CERT]`: match skills by **code context** (extensions/paths the sub-agent will touch) AND **task context** (what actions it will perform — review, PR, testing). Copy the matching `SKILL.md` paths into the prompt as `## Skills to load before work`. Instruct the sub-agent to read those exact files BEFORE the work.

Key rule `[CERT]`: *"pass paths, not generated summaries."* The sub-agents read the full `SKILL.md` files to preserve the author's intent. It is compaction-safe: each delegation can re-read the registry if the cache is lost `[CERT]`.

Resolution feedback `[CERT]` (`CLAUDE.md` §"Skill Resolution Feedback"): after each delegation, check the `skill_resolution` field of the Result Contract — `paths-injected` (ok), or `fallback-registry`/`fallback-path`/`none` (cache lost, probably from compaction → re-read the registry immediately).

## 18.7 — Sub-Agent Launch Deduplication `[CERT]`

Before emitting any Agent tool call, the orchestrator checks its session launch log `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Deduplication"):

- Maintain a session-scoped list of `(phase, task-fingerprint)` pairs already launched this turn.
- The task fingerprint is a short hash or normalized summary of the instruction text (phase name + key artifact references).
- If the same `(phase, task-fingerprint)` already appears → **do NOT launch again**. Emit exactly ONE launch per distinct task.
- After launching, append the pair to the list.

Purpose `[CERT]`: *"This prevents duplicate sub-agent launches that cause 'File X has been modified since it was last read' conflicts and waste tokens."* `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Deduplication").

**Mental model** `[INFER]`: the dedup attacks a concrete failure of LLM orchestrators — relaunching the same phase twice (from state confusion or compaction), producing two sub-agents that edit the same file and collide ("modified since last read"). The `(phase + artifact)` fingerprint is the idempotency key: two launches with the same key are the same work, and the second is suppressed.

## 18.8 — How all this wraps each phase `[CERT]`

Every SDD/JD phase launch goes through a sequence of gates `[INFER]` (synthesis of §18.5, §18.6, §18.7):

1. **Dedup check** (§18.7): have I already launched this `(phase, fingerprint)`? If so, abort the launch.
2. **Model gate** (§18.5): resolve the alias from the table and set `model: "<alias>"`.
3. **Skill resolution** (§18.6): match skills by code+task and inject `SKILL.md` paths as `## Skills to load before work`.
4. **Context protocol**: for SDD phases, pass artifact references (topic keys or paths), not content (see [Block 3]).
5. The sub-agent executes and returns the **Result Contract** (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) — see [Block 2].
6. The orchestrator checks `skill_resolution` (§18.6) and, in auto mode, runs the Gatekeeper (see [Block 16]).

**Synthesis** `[INFER]`: this block is the SDD's "transport protocol layer". The phases ([Block 5]-[Block 12]) are the WHAT; this block is the HOW they are summoned: with which model, with which skills, without duplicating, compressing or isolating context according to the type of work. Every phase launch traverses these gates before existing.

## 18.9 — Connections

- **[Block 1] — philosophy**: introduces the delegation criterion (§18.1) and the six triggers (§18.2) at the philosophical level. This block treats them as the operational mechanics of each launch.
- **[Block 2] — DAG + Result Contract**: the `model` the gate injects (§18.5) and the `skill_resolution` that is checked (§18.6) operate over the DAG phases; the Result Contract every phase returns is that of [Block 2].
- **[Block 3] — backends + topic keys**: step 4 of the wrapper (§18.8) — passing artifact references, not content — is the Sub-Agent Context Protocol of [Block 3].
- **[Block 5] to [Block 12] — all the phases**: the Model Assignments table (§18.4) maps exactly these phases to their model. Each one is summoned with the gates of §18.8.
- **[Block 16] — Gatekeeper**: the Gatekeeper's fresh reviewer for high-risk phases uses the `sdd-verify` alias with the model gate of §18.5. The two opus models (`propose`, `design`) are the high-risk phases of the Gatekeeper.
- **[Block 22] — skill-resolver**: the Skill Resolver Protocol summarized in §18.6 lives in detail in the `_shared/` contracts that [Block 22] documents (`~/.claude/skills/_shared/skill-resolver.md`).
- **[Block 24] — judgment-day**: the `jd-judge-a`, `jd-judge-b`, `jd-fix-agent` phases of the model table (§18.4) belong to the judgment-day protocol of [Block 24].
