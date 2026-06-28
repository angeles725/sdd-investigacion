# Block 1 — What SDD is: philosophy and the orchestrator-coordinator model

> **WHAT IT DOCUMENTS**: This block establishes the mental model of gentle-ai's SDD (Spec-Driven Development) system: what problem it solves, its philosophy of structured planning for substantial changes, and the "orchestrator-coordinator" execution model where the main agent coordinates and delegates instead of executing.
> **SCOPE**: General philosophy, the orchestrator's role as COORDINATOR, delegation rules, mandatory delegation triggers, cost/context balance, and the persona-vs-artifact boundary. Does NOT cover the detail of each phase (see [Block 2]) nor the persistence backends (see [Block 3]).
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Agent Teams Lite — Orchestrator Instructions", §"SDD Workflow (Spec-Driven Development)", §"Delegation Rules", §"Mandatory Delegation Triggers", §"Cost and Context Balance", §"Language Domain Contract", §"Model Assignments"
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` §"Executor boundary"
> **METHOD**: Each statement carries a certainty marker. `[CERT]` = verified by reading the source, with `path §section` when possible. `[CERT-a]` = asserted by a source but not re-verified at its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 1.1 — What SDD is and what problem it solves `[CERT]`

SDD (Spec-Driven Development) is **the structured planning layer for substantial changes** `[CERT]` (`CLAUDE.md` §"SDD Workflow": "SDD is the structured planning layer for substantial changes"). It is not a code framework or a runtime; it is a workflow that imposes specification discipline before implementing.

The core idea is to separate the "what/why" from the "how": first a change is explored, proposed, and specified, and only afterward is it implemented, verified, and archived. This materializes in a dependency graph between phases (see [Block 2]) `[INFER]`.

The system is invoked through commands (skills and meta-commands):

| Command | Type | Function `[CERT]` (`CLAUDE.md` §"Commands") |
|---------|------|--------|
| `/sdd-init` | skill | Initializes SDD context; detects stack, bootstraps persistence |
| `/sdd-explore <topic>` | skill | Investigates an idea; reads codebase, compares approaches; creates no files |
| `/sdd-status [change]` | skill | Read-only structured status of the active change |
| `/sdd-apply [change]` | skill | Implements tasks in batches; checks off items |
| `/sdd-verify [change]` | skill | Validates implementation against specs; reports CRITICAL/WARNING/SUGGESTION |
| `/sdd-archive [change]` | skill | Closes a change and persists final state |
| `/sdd-onboard` | skill | Guided end-to-end walkthrough using the real codebase |
| `/sdd-new <change>` | meta-command | Starts a change by delegating exploration + proposal to sub-agents |
| `/sdd-continue [change]` | meta-command | Runs the next dependency-ready phase via sub-agent(s) |
| `/sdd-ff <name>` | meta-command | Fast-forward: proposal → specs → design → tasks |

Key distinction `[CERT]` (`CLAUDE.md` §"Commands"): **skills** appear in autocomplete; **meta-commands** (`/sdd-new`, `/sdd-continue`, `/sdd-ff`) are typed directly and the orchestrator handles them — they are NOT invoked as skills.

## 1.2 — The orchestrator is a COORDINATOR, not an executor `[CERT]`

The model's guiding principle: *"You are a COORDINATOR, not an executor. Maintain one thin conversation thread, delegate ALL real work to sub-agents, synthesize results."* `[CERT]` (`CLAUDE.md` §"Agent Teams Orchestrator").

There are two clearly separated levels:

1. **Orchestrator** (main conversation thread): maintains a thin thread, delegates the real work, and synthesizes results. `[CERT]`
2. **Sub-agents / phases** (fresh context, no memory): EXECUTE the phase work. `[CERT]`

This boundary is reinforced from the executor side: *"every SDD phase agent is an EXECUTOR, not an orchestrator. Do the phase work yourself. Do NOT launch sub-agents, do NOT call `delegate`/`task`, and do NOT bounce work back unless the phase skill explicitly says to stop and report a blocker."* `[CERT]` (`sdd-phase-common.md:5`).

**Architectural implication** `[INFER]`: it is a single-level delegation pattern. The orchestrator delegates to phases; phases do NOT delegate again. This avoids recursive explosion of sub-agents and keeps the execution tree flat and predictable.

> Scope note `[CERT]` (`CLAUDE.md` §"Agent Teams Lite"): these orchestrator instructions bind ONLY to the Claude Code orchestrator rule. They do NOT apply to executor phase agents such as `sdd-apply` or `sdd-verify`.

## 1.3 — Delegation criterion: does this inflate my context without need? `[CERT]`

The central criterion for deciding between doing something inline or delegating is a single question: *"does this inflate my context without need? If yes → delegate. If no → do it inline."* `[CERT]` (`CLAUDE.md` §"Delegation Rules").

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
- Reading 4+ files to "understand" the codebase inline → delegate an exploration.
- Writing a feature across multiple files inline → delegate.
- Running tests or builds inline → delegate.
- Reading files as preparation for edits and then editing → delegate the whole thing together.

## 1.4 — Mandatory delegation triggers (hard gates) `[CERT]`

Unlike recommendations, these are **non-skippable stop rules** of the parent orchestrator `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers": "non-skippable hard gates, not recommendations... TOTALMENTE obligatorio"). Tool unavailability is NOT an exception: the blocker is documented and the delegated work is stopped.

Semantic guard `[CERT]`: **delegate** means using the platform's native sub-agent mechanism (`Agent`/`Task`/`delegate`). Running local scripts, Python, or Bash inline is execution, NOT delegation.

| # | Rule | Trigger `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers") |
|---|-------|-----------|
| 1 | **4-file rule** | If understanding requires reading 4+ files → delegate a narrow exploration |
| 2 | **Multi-file write rule** | If the implementation will touch 2+ non-trivial files → delegate one writer |
| 3 | **PR rule** | Before commit/push/PR after code changes → fresh-context review (except trivial docs diff) |
| 4 | **Incident rule** | After wrong `cwd`, accidental repo mutation, merge recovery, etc. → fresh audit before continuing |
| 5 | **Long-session rule** | After ~20 tool calls, 5 exploratory reads, or 2 non-mechanical edits without delegating → pause and delegate the rest |
| 6 | **Fresh review rule** | Use fresh context for adversarial review of diffs/conflicts/PR/incidents; continuity/fork only for implementation that needs inherited state |

Critical scope rule `[CERT]`: these rules are parent-orchestrator stop rules. They are NOT passed to child agents as permission to spawn more agents; children receive concrete role work and must NOT orchestrate.

## 1.5 — Cost and context balance `[CERT]`

The system distinguishes two different motivations for delegating `[CERT]` (`CLAUDE.md` §"Cost and Context Balance"):

- **Exploration** → compresses broad repo reading into a short handoff (token saving).
- **Writing** → a single writer thread for implementation; do NOT run parallel writers unless isolated worktrees are explicitly approved.
- **Fresh reviewers** after implementation/conflicts/incidents → their value is **independent judgment, NOT token saving**. `[CERT]`

When NOT to delegate `[CERT]`: truly local one-file fixes, quick state checks, and already-understood mechanical edits.

**Resulting mental model** `[INFER]`: delegation serves TWO functions the system keeps conceptually separate — (a) context compression (exploration/large writing) and (b) judgment independence (adversarial review). Confusing them leads to under-using fresh review or over-delegating trivial tasks.

## 1.6 — The persona vs. artifact boundary `[CERT]`

The system imposes a **Language Domain Contract** that separates the persona's voice from technical content `[CERT]` (`CLAUDE.md` §"Language Domain Contract"):

- The active persona controls **only** the direct conversation with the user/orchestrator: direct replies, clarification prompts, orchestration status. `[CERT]`
- The **generated technical artifacts** default to **English**, regardless of the persona or the conversation language: OpenSpec files, specs, designs, tasks, code comments, UI copy, tests, fixtures, and delegated phase outputs. `[CERT]`
- If technical artifacts are explicitly requested in Spanish → neutral/professional Spanish, unless the user requests a regional variant. `[CERT]`

Forwarding rule `[CERT]`: when delegating, the orchestrator MUST forward this contract to the executor so the persona voice never becomes the default of the artifact or of public comments.

**Why it matters** `[INFER]`: the orchestrator can speak to the user with a warm and direct tone (the persona), but what the SDD pipeline *produces* is neutral and professional. It is the same separation as an architect who explains with passion but documents with rigor.

## 1.7 — Connections

- **[Block 2] — Phase DAG and Result Contract**: the "real work" the orchestrator delegates is the DAG phases (`proposal → specs → tasks → apply → verify → archive`, with `design` feeding `specs`). [Block 2] details each phase, its dependencies, and the Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) that every phase returns to the orchestrator. The EXECUTOR boundary described in §1.2 is the counterpart of each DAG phase.
- **[Block 3] — Artifact backends and topic keys**: when the orchestrator delegates, the sub-agents read and write artifacts in a backend (`engram`/`openspec`/`hybrid`/`none`). [Block 3] explains how the coordinator-executor model decides who reads and who writes context according to the task type (SDD vs. non-SDD), elaborating the "Sub-Agent Context Protocol".
- **[Block 18] — Delegation, triggers and model assignments**: deepens the hard gates of §1.4 and the per-phase model assignment table (each SDD/Judgment-Day phase maps to a model alias; phase Agent calls MUST include `model`, generic delegation does NOT). `[CERT]` (`CLAUDE.md` §"Model Assignments").
- **[Block 19] — persistence-contract**: formalizes the "Sub-Agent Context Rules" (who reads, who writes) introduced here at a philosophical level in §1.2.
