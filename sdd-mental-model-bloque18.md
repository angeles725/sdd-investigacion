# Block 18 — Delegation model, mandatory triggers, and model assignments

> **WHAT IT DOCUMENTS**: This block consolidates the SDD orchestrator's delegation model: the inline-vs-delegate decision table, the six Mandatory Delegation Triggers (hard gates), the Model Assignments table (phase → model → effort → reason), the per-phase mandatory model gate, the summarized Skill Resolver Protocol, and the sub-agent launch deduplication. From v1.47.0 onward (RDD line), it also covers the five review-lens model assignments introduced by Receipt-Driven Development.
> **SCOPE**: The delegation criterion, the six non-skippable triggers, the cost/context balance, the per-phase SDD/Judgment-Day model table, the mandatory model gate, the review-lens sub-agent assignments (RDD), the summarized Skill Resolver Protocol, and the dedup of launches. It is the cross-cutting layer that governs HOW the orchestrator summons ALL phases. For the detail of each phase, see [Block 5] to [Block 12]. For the structure of `state.json` (key set, types, per-harness assignment maps), see [Block 27]. For judgment-day specifically, see [Block 24]. The 4R native lenses are a DIFFERENT adversarial system from judgment-day, with their own RDD protocol; note the distinction and do not conflate them.
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.
> **SOURCES** (read and verified):
> - `~/.claude/CLAUDE.md` §"Delegation Rules", §"Mandatory Delegation Triggers", §"Cost and Context Balance" — still in CLAUDE.md at v2.2.0
> - `~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Model Assignments", §"Sub-Agent Launch Deduplication (MANDATORY)", §"Sub-Agent Launch Protocol", §"Result Contract" — **these sections moved from CLAUDE.md to sdd-orchestrator-workflow.md** [DRIFTED v1.43.2→v2.2.0]; the old block cited them at CLAUDE.md; they no longer exist there at v2.2.0
> - `~/.claude/skills/_shared/skill-resolver.md` — Skill Resolver Protocol detail
> - `~/.gentle-ai/state.json` — live `model_assignments` map (all five review-lens keys confirmed), `claude_phase_assignments`, `codexOrchestratorAssignment`
> - `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md` — RDD version policy, OpenCode orchestrator profile name
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path §section` or `path:line`. `[CERT-a]` = asserted by a source, not re-verified. `[INFER]` = author's deduction. `[GAP]` = fact that would settle an open question, with the command or file that would answer it.

---

> **Distribution warning** `[CERT]` (`~/.claude/CLAUDE.md` — file path is per-machine): the entire orchestrator contract this block documents lives in `~/.claude/CLAUDE.md`, which is a **machine-local file installed by `gentle-ai install`**. It is NOT checked into any repository and is NOT shared across a team by default. A second developer's machine will have none of this doctrine unless they ran the installer. The delegation model, the six triggers, the model gate, and the review-lens protocol documented here are therefore NOT reliably distributed beyond this machine. `[GAP]`: there is no team-facing verification short of running `gentle-ai doctor` on each developer's machine.

---

## 18.1 — The root criterion: does this inflate my context without need? `[CERT]`

The guiding principle of all delegation is a single question `[CERT]` (`~/.claude/CLAUDE.md` §"Delegation Rules"): *"does this inflate the parent context without need? If yes, use one bounded worker. If no, do it inline."*

The decision table `[CERT]` (`~/.claude/CLAUDE.md` §"Delegation Rules"):

| Action | Direct inline | Delegated direct worker |
|--------|---------------|-------------------------|
| Read to decide/verify (1–3 files) | ✅ | — |
| Read to explore/understand (4+ files) | — | ✅ one narrow mapper |
| Read as preparation for writing | — | ✅ together with the write |
| Write one mechanical, already-understood file | ✅ | — |
| Write 2+ non-trivial files | — | ✅ one writer |
| Bash for state (`git`, `gh`) | ✅ | — |
| Tests, builds, installs, or native review actions | allowed as a bounded action | ✅ fresh per-action worker without changing route |

**[DRIFTED v1.43.2→v2.2.0] — Decision table:** at v1.43.2 the column headers were "Inline" and "Delegate"; they are now "Direct inline" and "Delegated direct worker". At v1.43.2 the last row read `"Bash for execution (test, build, install) | — | ✅"` (delegate-only). At v2.2.0 it reads `"Tests, builds, installs, or native review actions | allowed as a bounded action | ✅ fresh per-action worker without changing route"` — tests/builds are now explicitly allowed as bounded inline actions; native review actions are added to this row.

**[DRIFTED v1.43.2→v2.2.0] — Anti-patterns list:** the old block documented an explicit list of "anti-patterns that ALWAYS inflate context without need" (read 4+ files inline, write across files inline, run tests inline, read+edit inline). That list is no longer present as an explicit block in CLAUDE.md at v2.2.0. The substance is now implied by the decision table and the triggers in §18.2.

Three implementation routes `[CERT]` (`~/.claude/CLAUDE.md` §"Delegation Rules"): every change takes exactly one route — **direct inline**, **delegated direct**, or **optional SDD**. Size, file count, or risk alone never selects SDD. SDD phase workers are reserved for an explicit request or an accepted proposal.

Critical semantic guard `[CERT]` (`~/.claude/CLAUDE.md` §"Delegation Rules"): *"Use Claude Code's native Agent/Task mechanism for delegated-direct work; reserve `sdd-*` agents for a selected SDD route."* Running local scripts or Bash inline is EXECUTION, not delegation.

(This section is the base that [Block 1] introduces at the philosophical level; here it is treated as the operational mechanics that govern each launch.)

## 18.2 — The six Mandatory Delegation Triggers `[CERT]`

They are **parent-orchestrator routing boundaries** — NOT recommendations `[CERT]` (`~/.claude/CLAUDE.md` §"Mandatory Delegation Triggers"). Do not pass these rules to child agents as permission to orchestrate; children receive concrete role work.

**[DRIFTED v1.43.2→v2.2.0] — The trigger set was rebuilt, not amended.** The v1.43.2 triggers were: (1) 4-file rule, (2) Multi-file write rule, (3) PR rule, (4) Incident rule, (5) Long-session rule, (6) Fresh review rule. Two survive in recognisable form — the 4-file rule keeps its name and meaning, and the Multi-file write rule is now simply the Write rule. Four are gone outright (PR, Incident, Long-session, Fresh review) and four are new (Bounded read, Context, Per-action, Optional SDD). The set is still six, but that is arithmetic coincidence, not continuity — do not read the unchanged count as an unchanged model. Triggers 3–6 (PR, Incident, Long-session, Fresh review) are entirely removed; the native RDD review system (`gentle-ai review start/finalize/validate`, introduced in v1.47.0) now handles candidate review and delivery safety via a separate mechanism (see §18.4a and [Block 27]). The "context-compression vs judgment-independence" mental model that described the old two-family grouping is therefore no longer accurate. The new six triggers follow.

| # | Rule | Trigger and required action `[CERT]` (`~/.claude/CLAUDE.md` §"Mandatory Delegation Triggers") |
|---|------|-------------------------------------------------------------------------------------------------|
| 1 | **Bounded read rule** | Read 1–3 files inline to decide or verify. |
| 2 | **4-file rule** | When understanding requires 4+ files, delegate one narrow exploration/mapping task. |
| 3 | **Write rule** | Keep one mechanical, already-understood file inline only when it needs no research or unresolved design work; delegate one writer for 2+ non-trivial files. |
| 4 | **Context rule** | Delegate reading that prepares a write and broad research/context compression. |
| 5 | **Per-action rule** | Tests, builds, installs, and native review actors may use fresh workers without changing the implementation route or creating SDD state. |
| 6 | **Optional SDD rule** | Propose SDD only when durable proposal/spec/design/tasks materially reduce substantial ambiguity. Select SDD only after an explicit request or accepted proposal; risk alone never forces SDD. |

**Mental model** `[INFER]`: the new six triggers are all **context/topology rules**, not review-safety rules. Review safety has moved out of this trigger set and into the native RDD review protocol (the `gentle-ai review *` CLI). Triggers 1–4 govern read/write scope; trigger 5 isolates per-action workers; trigger 6 gates SDD entry. The old judgment-independence family (PR/Incident/Fresh-review) is replaced by the machine-native review authority system.

## 18.3 — Cost and context balance `[CERT]`

The system keeps two motivations for delegating conceptually separate `[CERT]` (`~/.claude/CLAUDE.md` §"Cost and Context Balance"):

- **Exploration** → compresses broad repo reading into a short handoff (token saving).
- **Writing** → a single writer thread for implementation; do NOT run parallel writers except explicitly approved isolated worktrees.
- **Do NOT delegate** for: truly local single-file fixes, quick state checks, already-understood mechanical edits.
- Let the native review and delivery providers select checking and delivery actions; repeated gates reuse exact authority and never reopen review for unchanged content.

Write-parallelism rule `[CERT]` (`~/.claude/CLAUDE.md` §"Cost and Context Balance"): a single writer thread for implementation; no parallel writers except explicitly approved isolated worktrees.

## 18.4 — The Model Assignments table (Claude Code canonical defaults) `[CERT]`

**[DRIFTED v1.43.2→v2.2.0] — Source location:** at v1.43.2 this table lived inline in `~/.claude/CLAUDE.md` §"Model Assignments". At v2.2.0, CLAUDE.md §"SDD Workflow (lazy-loaded)" redirects to `~/.claude/skills/_shared/sdd-orchestrator-workflow.md`, which now hosts the table. The table **content** for Claude Code canonical defaults is unchanged between versions; only its location drifted.

The orchestrator reads this table before first SDD/Judgment-Day delegation, caches it, and uses the mapped alias ONLY for SDD/Judgment-Day phase agents `[CERT]` (`~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Model Assignments"). The table `[CERT]`:

| Phase | Default Model | Effort | Reason `[CERT]` (`sdd-orchestrator-workflow.md` §"Model Assignments") |
|-------|---------------|--------|-----------------------------------------------------------------------|
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

Table rules `[CERT]` (`sdd-orchestrator-workflow.md` §"Model Assignments"):

- If an SDD/JD phase is missing from the table → use the `default` row.
- If you do not have access to the assigned model (e.g. no Opus access) → substitute `sonnet` and continue.
- The Claude Code session model is controlled by Claude Code itself; Gentle AI does NOT configure the main orchestrator model. *"This table applies only to Agent tool calls for SDD/Judgment-Day phase sub-agents, not generic delegation."* `[CERT]`.

**Note on `sdd-init`** `[CERT]` (`~/.gentle-ai/state.json` `model_assignments` key): `sdd-init` is present in the live `model_assignments` map (OpenCode harness assignment: MiniMax-M3, thinking effort) but is absent from the canonical Claude Code table in sdd-orchestrator-workflow.md. For Claude Code, `sdd-init` falls through to the `default` row (sonnet). Whether the table omission is intentional or doc debt is `[INFER]` — the Claude Code sdd-init skill runs inline or as a delegated agent; the model assignment for it is not surfaced in the canonical Claude Code table.

**Multi-harness reality** `[CERT]` (`~/.gentle-ai/state.json`): `state.json` contains MULTIPLE per-harness assignment maps. This table is the Claude Code canonical table (`claude_phase_assignments`). OpenCode uses `model_assignments` (provider+model_id+effort triples; different providers and models per phase). Codex uses `codexModelAssignments` (effort-level strings) and a separate `codexOrchestratorAssignment` key (`{model, effort}`) for its main orchestrator. See [Block 27] for the full structural map of these keys. This block documents SEMANTICS; [Block 27] owns the key-set and type schema.

**`codexOrchestratorAssignment`** `[CERT]` (`~/.gentle-ai/state.json`): `{model: "gpt-5.6-sol", effort: "medium"}`. This controls the Codex orchestrator (main agent) model, analogous to how OpenCode uses the `gentle-orchestrator` profile. It is a SEPARATE key from `model_assignments`. The CLAUDE.md claim that "Gentle AI does NOT configure the main orchestrator model" applies to the Claude Code orchestrator specifically; for Codex and OpenCode, gentle-ai DOES configure the orchestrator-level model via `codexOrchestratorAssignment` and `model_assignments["gentle-orchestrator"]` respectively. **Decision on placement**: `codexOrchestratorAssignment` belongs structurally in [Block 27] (state.json architecture); semantically it is a harness-specific orchestrator assignment outside the SDD/JD phase gate documented in §18.5. This block notes it here for completeness and cross-refers to [Block 27].

**Why each model** `[INFER]`: the Claude Code canonical table maps **cognitive complexity → model capacity**. The only two phases with **opus** are `sdd-propose` and `sdd-design` — the ones that make ARCHITECTURAL decisions. Structured or mechanical writing phases use **sonnet**. Copy/close and pedagogical phases (`archive`, `onboard`) use **haiku**. Resource allocation is proportional to the risk of the decision. This same two-opus pairing is the high-risk tier for the Gatekeeper (see [Block 16]).

## 18.4a — Review-lens model assignments (RDD, v1.47.0+) `[CERT]`

Receipt-Driven Development (RDD) introduced a native bounded review system starting in v1.47.0 `[CERT]` (`/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md`: "RDD started in `gentle-ai` `v1.47.0` on 2026-07-10"). This system added five review-lens sub-agents to the Claude Code agent roster. They are present in `~/.gentle-ai/state.json` `model_assignments` but are NOT in the canonical SDD/JD phase table (§18.4).

The five review-lens sub-agents `[CERT]` (agent roster and `~/.gentle-ai/state.json` `model_assignments`):

| Lens key | Role | Model (OpenCode) | Effort |
|----------|------|------------------|--------|
| `review-risk` | R1 — security, privilege boundaries, data exposure, dependency risks, merge-blocking vulnerabilities | gpt-5.6-sol | medium |
| `review-readability` | R2 — naming, complexity, intention, maintainability, review size, context clarity | MiniMax-M3 | thinking |
| `review-reliability` | R3 — behavior-first tests, coverage value, edge cases, determinism, contracts, regressions | gpt-5.6-sol | medium |
| `review-resilience` | R4 — fallbacks, retry/backoff, graceful degradation, observability, load, rollback, SLO risks | gpt-5.6-sol | medium |
| `review-refuter` | Detached read-only refuter for inferential severe findings — one transaction-wide batch | MiniMax-M3 | thinking |

**Lens selection** `[CERT]` (`~/.claude/CLAUDE.md` §"Review Execution Contract"): zero lenses for low risk, one focus lens for standard risk, canonical 4R (all four R lenses) for high risk. The `review-refuter` runs ONLY for inferential blockers from the selected lenses; deterministic blockers do not need a refuter.

**Relationship to judgment-day** `[INFER]`: the 4R native lenses and judgment-day are two distinct adversarial systems. 4R lenses run under the native receipt-driven review (`gentle-ai review start/capture-result/finalize`), produce content-bound receipts, and run once per candidate. judgment-day (jd-judge-a, jd-judge-b, jd-fix-agent — see [Block 24]) is a SDD-specific blind-dual-judge protocol with a separate budget and correction round. Do NOT conflate them.

**Model assignment for Claude Code** `[GAP]`: the `claude_phase_assignments` in `~/.gentle-ai/state.json` does NOT contain the review-lens keys. The canonical sdd-orchestrator-workflow.md table also omits them. The CLAUDE.md model gate (§18.5) applies only to SDD/JD phase agents, not generic delegation. Therefore, for Claude Code, review-lens agents run without an explicit `model:` override from the model assignments table — their model follows session defaults unless the user explicitly requests otherwise. To verify: check whether `claude_phase_assignments` ever acquires these keys after a future `gentle-ai sync`.

**Why the role-to-model mapping** `[INFER]` (for OpenCode harness): R1/R3/R4 use gpt-5.6-sol at medium effort — straightforward reasoning about security, tests, and resilience patterns. R2 (readability) and the refuter use MiniMax-M3 at thinking effort — readability analysis may benefit from slower, more deliberate reasoning about naming and intention; the refuter must carefully re-evaluate inferential findings under adversarial scrutiny. This is a user-configured assignment in state.json, not a documented design decision in any source file I found.

## 18.5 — The Mandatory Phase Model Gate `[CERT]`

Hard rule `[CERT]` (`~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Model Assignments"): *"Agent tool calls for SDD/Judgment-Day phase agents MUST include `model`. Generic/non-SDD delegation MUST NOT use this table; omit `model` unless the user explicitly requested an override."*

**[DRIFTED v1.43.2→v2.2.0] — Source location:** this gate was previously cited from `~/.claude/CLAUDE.md` §"Model Assignments". At v2.2.0 the gate lives in `~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Sub-Agent Launch Protocol" and §"Model Assignments".

The mandatory pre-flight before each SDD/JD phase Agent call `[CERT]` (`sdd-orchestrator-workflow.md` §"Sub-Agent Launch Protocol"):

1. Identify the SDD/JD phase (`sdd-apply`, `sdd-verify`, `jd-judge-a`, etc.) or use `default` only as a phase fallback.
2. Look up the alias in the Model Assignments table (§18.4).
3. Include `model: "<alias>"` in the SDD/JD Agent tool call.
4. For generic/non-SDD delegation: do NOT use this table; omit `model` unless the user explicitly requests an override.

**The boundary of the gate** `[INFER]`: there are TWO classes of delegation with opposite rules about `model`. SDD/JD PHASE Agent calls MUST carry `model` (resolved from the table). Generic delegation (ad-hoc explorations, non-phase reviewers including the 4R lenses for Claude Code, searches) MUST NOT carry `model` unless the user asks. Review-lens agents (§18.4a) are NOT SDD/JD phase agents and therefore fall in the generic class — the gate does not apply to them. Mixing these classes is an error: putting `model` on a generic delegation forces a model the user did not choose; omitting it on an SDD phase violates the gate.

## 18.6 — Skill Resolver Protocol (operational summary) `[CERT]`

**[DRIFTED v1.43.2→v2.2.0] — Source location:** the old block cited `~/.claude/CLAUDE.md` §"Sub-Agent Launch Pattern". At v2.2.0 this lives in `~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Sub-Agent Launch Protocol" and `~/.claude/skills/_shared/skill-resolver.md`.

Every sub-agent launch prompt that involves reading, writing, reviewing, testing, documenting, or creating project artifacts MUST include pre-resolved skill paths from the registry `[CERT]` (`skill-resolver.md`). Skip only for purely mechanical commands.

Orchestrator resolution order `[CERT]` (`~/.claude/skills/_shared/skill-resolver.md` §"Step 1"):

1. Use the session cache if present.
2. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` for full content.
3. Fallback: read `.atl/skill-registry.md` from the project root.
4. No registry found → warn the user to run `gentle-ai skill-registry refresh` and proceed without project skills.

For each launch `[CERT]` (`skill-resolver.md` §"Step 2", §"Step 3"): match skills by **code context** (language, framework, tool, or path the sub-agent will touch) AND **task context** (actions like PR, review, docs, tests). Prefer the smallest useful set — if more than five match, keep the five most relevant, prioritizing code over task context. Inject matching `SKILL.md` paths (not summaries) into the prompt as `## Skills to load before work`.

Key rule `[CERT]` (`skill-resolver.md` §"Step 3"): *"pass paths, not summaries."* Sub-agents read the full `SKILL.md` files to preserve the author's intent. It is compaction-safe: each delegation can re-read the registry if the cache is lost.

Resolution feedback `[CERT]` (`skill-resolver.md` §"Step 4"): after each delegation, check the `skill_resolution` field — `paths-injected` (ok), or `fallback-registry` / `fallback-path` / `none` (cache lost → re-read the registry immediately before the next delegation).

## 18.7 — Sub-Agent Launch Deduplication `[CERT]`

**[DRIFTED v1.43.2→v2.2.0] — Source location:** previously cited from `~/.claude/CLAUDE.md` §"Sub-Agent Launch Deduplication (MANDATORY)". At v2.2.0 this lives in `~/.claude/skills/_shared/sdd-orchestrator-workflow.md` §"Sub-Agent Launch Deduplication (MANDATORY)".

Before emitting any Agent tool call, the orchestrator checks its session launch log `[CERT]` (`sdd-orchestrator-workflow.md` §"Sub-Agent Launch Deduplication"):

- Maintain a session-scoped list of `(phase, task-fingerprint)` pairs already launched this turn.
- The task fingerprint is a short hash or normalized summary of the instruction text (phase name + key artifact references).
- If the same `(phase, task-fingerprint)` already appears → **do NOT launch again**. Emit exactly ONE launch per distinct task.
- After launching, append the pair to the list.

Purpose `[CERT]`: prevents duplicate sub-agent launches that cause "File X has been modified since it was last read" conflicts and waste tokens.

**Mental model** `[INFER]`: the dedup attacks a concrete failure of LLM orchestrators — relaunching the same phase twice from state confusion or compaction, producing two sub-agents that edit the same file and collide. The `(phase + artifact)` fingerprint is the idempotency key: two launches with the same key are the same work, and the second is suppressed.

## 18.8 — How all this wraps each phase `[CERT]`

Every SDD/JD phase launch goes through a sequence of gates `[INFER]` (synthesis of §18.5, §18.6, §18.7 and `sdd-orchestrator-workflow.md` §"Sub-Agent Launch Protocol"):

1. **Dedup check** (§18.7): have I already launched this `(phase, fingerprint)`? If so, abort the launch.
2. **Model gate** (§18.5): resolve the alias from the SDD/JD table and set `model: "<alias>"`. Skip for generic delegation and review-lens agents.
3. **Skill resolution** (§18.6): match skills by code+task context and inject `SKILL.md` paths as `## Skills to load before work`.
4. **Context protocol**: for SDD phases, pass artifact references (topic keys or paths), not content (see [Block 3]).
5. The sub-agent executes and returns the **Result Contract** (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) `[CERT]` (`sdd-orchestrator-workflow.md` §"Result Contract") — see [Block 2].
6. The orchestrator checks `skill_resolution` (§18.6) and, in auto mode, runs the Gatekeeper (see [Block 16]).

For the **4R review-lens pipeline** (§18.4a), the wrapper is different: the native RDD protocol drives the launch via `GENTLE_AI_REVIEW_BINDING` prefix and `gentle-ai review capture-result`, not via the SDD dedup/model-gate sequence `[CERT]` (`~/.claude/CLAUDE.md` §"Review Execution Contract").

**Synthesis** `[INFER]`: this block is the SDD's "transport protocol layer". The phases ([Block 5]–[Block 12]) are the WHAT; this block is the HOW they are summoned: with which model, with which skills, without duplicating, compressing or isolating context according to the type of work. Every SDD/JD phase launch traverses the gates in §18.8 before it exits. Review-lens launches follow the separate native RDD protocol and are governed by the `gentle-ai` CLI, not by the SDD model gate.

## 18.9 — Connections

- **[Block 1] — philosophy**: introduces the delegation criterion (§18.1) and the three implementation routes at the philosophical level. This block treats them as operational mechanics.
- **[Block 2] — DAG + Result Contract**: the `model` the gate injects (§18.5) and the `skill_resolution` that is checked (§18.6) operate over the DAG phases; the Result Contract every phase returns is that of [Block 2].
- **[Block 3] — backends + topic keys**: step 4 of the wrapper (§18.8) — passing artifact references, not content — is the Sub-Agent Context Protocol of [Block 3].
- **[Block 5] to [Block 12] — all the phases**: the Model Assignments table (§18.4) maps exactly these phases to their model. Each one is summoned with the gates of §18.8.
- **[Block 16] — Gatekeeper**: the Gatekeeper's fresh reviewer for high-risk phases uses the `sdd-verify` alias with the model gate of §18.5. The two opus models (`propose`, `design`) are the high-risk phases of the Gatekeeper.
- **[Block 22] — skill-resolver**: the Skill Resolver Protocol summarized in §18.6 lives in detail in `~/.claude/skills/_shared/skill-resolver.md` and is referenced by `~/.config/opencode/skills/_shared/skill-resolver.md`.
- **[Block 24] — judgment-day**: the `jd-judge-a`, `jd-judge-b`, `jd-fix-agent` phases of the model table (§18.4) belong to the judgment-day protocol of [Block 24]. The 4R review lenses (§18.4a) are a SEPARATE system — do not conflate.
- **[Block 27] — state.json architecture**: `model_assignments` (per-provider phase triples), `claude_phase_assignments` (Claude Code defaults), `codexModelAssignments`, `codexOrchestratorAssignment`, and `codexCarrilModelAssignments` are all keys in state.json whose STRUCTURE belongs to [Block 27]. This block documents only the SEMANTICS of what each assignment controls within the delegation model.
