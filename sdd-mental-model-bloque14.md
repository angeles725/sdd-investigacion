# Block 14 — Meta-commands: `sdd-new`, `sdd-continue`, `sdd-ff`

> **WHAT IT DOCUMENTS**: This block documents the three **meta-commands** of SDD — `/sdd-new`, `/sdd-continue` and `/sdd-ff` — that the orchestrator handles directly instead of invoking them as skills. It explains what each one does, the shared Session Preflight HARD GATE, the delegation flow to sub-agents, and the planning "fast-forward" concept.
> **SCOPE**: The meta-command vs. skill definition, the internal workflow of each, the planning graph they traverse, and how they differ from the phases they orchestrate. It does NOT cover the internal detail of each delegated phase (see [Block 5] to [Block 12]), nor the native `gentle-ai` dispatcher (see [Block 15]), nor the auto/interactive modes (see [Block 16]).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/commands/sdd-new.md` (lines 1-32)
> - `/home/cristian/.config/opencode/commands/sdd-continue.md` (lines 1-40)
> - `/home/cristian/.config/opencode/commands/sdd-ff.md` (lines 1-38)
> - `/home/cristian/.claude/CLAUDE.md` §"Commands", §"Execution Mode", §"Dependency Graph"
> **METHOD**: Each statement carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section` when possible. `[CERT-a]` = asserted by one source but not re-verified at its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 14.1 — Meta-command vs. skill: the underlying distinction `[CERT]`

The SDD system divides its commands into two classes with different dispatch mechanisms `[CERT]` (`CLAUDE.md` §"Commands"):

- **Skills**: appear in autocomplete. They are `/sdd-init`, `/sdd-explore`, `/sdd-status`, `/sdd-apply`, `/sdd-verify`, `/sdd-archive`, `/sdd-onboard`. Each one corresponds to a phase sub-agent with its own `SKILL.md`.
- **Meta-commands**: typed directly, do NOT appear in autocomplete, and are handled by the orchestrator. They are `/sdd-new`, `/sdd-continue` and `/sdd-ff`.

The instruction is explicit `[CERT]` (`CLAUDE.md` §"Commands"): *"`/sdd-new`, `/sdd-continue`, and `/sdd-ff` are meta-commands handled by YOU. Do NOT invoke them as skills."*

**Why the distinction matters** `[INFER]`: a skill is an atomic unit of work (one phase executes and returns). A meta-command is an **orchestration plan**: it does not do phase work, but decides which phases to launch, in what order, and with what gating. The orchestrator is the owner of the meta-command; the phases are the workers the meta-command summons.

An implementation subtlety `[CERT]`: although the three `.md` files exist physically in `/home/cristian/.config/opencode/commands/` with frontmatter `agent: gentle-orchestrator`, their content is NOT an executable skill — it is an orchestration script that the `gentle-orchestrator` reads and obeys. Each file closes with: *"Read the orchestrator instructions to coordinate this workflow. Do NOT execute phase work inline — delegate to sub-agents."* `[CERT]` (`sdd-new.md:31`, `sdd-continue.md:35`, `sdd-ff.md:37`).

## 14.2 — The shared HARD GATE: Session Preflight `[CERT]`

The three meta-commands open with an **identical HARD GATE** that blocks any execution until the Session Preflight is complete `[CERT]` (`sdd-new.md:8-9`, `sdd-continue.md:8-9`, `sdd-ff.md:8-9`):

> *"SDD Session Preflight must already be complete for this session. It must include execution mode, artifact store, chained PR strategy, and review budget. If missing, ask the exact orchestrator preflight prompt and STOP. Do not launch exploration or proposal in the same turn."*

The four elements the preflight MUST have `[CERT]`:

| Element | What it decides | Block that details it |
|----------|-----------|----------------------|
| **Execution mode** | auto vs. interactive | [Block 16] |
| **Artifact store** | engram / openspec / hybrid / none | [Block 3], [Block 15] |
| **Chained PR strategy** | stacked-to-main / feature-branch-chain | [Block 17] |
| **Review budget** | line budget / delivery strategy | [Block 17] |

Critical operative rule `[CERT]`: if the preflight is missing, the orchestrator **asks the exact preflight prompt and STOPS** — it does not launch exploration or proposal in the same turn. This forces a temporal separation: first the preflight is resolved (in its own turn), then the meta-command is executed.

**Implication** `[INFER]`: the preflight is a cached session state (see §"Execution Mode" and §"Artifact Store Mode" in CLAUDE.md, which say "Cache the mode choice for the session"). The meta-commands do not re-ask; they consume that cache. The HARD GATE only fires the first time in the session.

## 14.3 — `/sdd-new <change>`: exploration + proposal `[CERT]`

`/sdd-new` **starts a new change** by running exploration and then creating a proposal `[CERT]` (frontmatter `sdd-new.md:2`: "Start a new SDD change — runs exploration then creates a proposal").

Declared workflow `[CERT]` (`sdd-new.md:11-16`):

1. Launch the **`sdd-explore`** sub-agent to investigate the codebase for this change.
2. Present the exploration summary to the user.
3. Launch the **`sdd-propose`** sub-agent to create a proposal based on the exploration.
4. Present the proposal summary and ask the user if they want to continue with specs and design.

Context details that the meta-command injects into the sub-agents `[CERT]` (`sdd-new.md:18-26`):

- **Working directory**: before anything, run `git rev-parse --show-toplevel 2>/dev/null || pwd` and use that path as the authoritative workspace. The note explains why: *"In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project."* `[CERT]` (`sdd-new.md:20`). That is, `$ARGUMENTS` and template interpolation are NOT reliable for the cwd; it must be resolved at runtime with bash.
- **Current project**: the `basename` of the detected workspace.
- **Change name**: `$ARGUMENTS`.
- Execution mode, artifact store, delivery strategy and review budget: "ask/cache per orchestrator; do not hardcode Engram" `[CERT]`.

Persistence note `[CERT]` (`sdd-new.md:28-29`): the sub-agents handle persistence automatically according to the chosen artifact store. In engram/hybrid, each phase saves with `topic_key "sdd/$ARGUMENTS/{type}"`.

**Mental model** `[INFER]`: `/sdd-new` covers the start of the DAG (`explore → propose`) and stops at a human decision point (step 4). It does not advance to specs/design on its own; it leaves the user to decide whether to continue. It is the most conservative meta-command: two phases and stop.

## 14.4 — `/sdd-continue [change]`: the next dependency-ready phase `[CERT]`

`/sdd-continue` **advances the active change by one phase** in the dependency chain `[CERT]` (frontmatter `sdd-continue.md:2`: "Continue the next SDD phase in the dependency chain").

Declared workflow `[CERT]` (`sdd-continue.md:11-19`):

1. **Resolve authoritative status first**. If the `gentle-ai` binary is available AND the artifact store is `openspec` or `hybrid`, run `gentle-ai sdd-continue [change] --cwd <repo>` and treat its output as authoritative. If the store is `engram`, **do NOT invoke the native dispatcher at all** — it cannot see the change (it reads only `openspec/changes/`); resolve status from Engram (`mem_search` + `mem_get_observation` on the topic keys). The full detail of this routing is in [Block 15]. `[CERT]`
2. Produce or consume structured status before acting: `schemaName`, `planningHome/changeRoot`, `artifactPaths/contextFiles`, task progress, dependency states, next recommended action, blocked reasons and `actionContext`. `[CERT]`
3. Check which artifacts already exist for the active change (proposal, specs, design, tasks). `[CERT]`
4. Determine the next phase according to the graph: `proposal → [specs ∥ design] → tasks → apply → verify → archive`. `[CERT]` (`sdd-continue.md:17`).
5. Launch the next phase's sub-agent(s) **only if the authoritative status says the dependency is ready**. Route only by `nextRecommended` and dependency states; never infer from free text. `[CERT]`
6. Present the result and ask the user to proceed. `[CERT]`

Routing rules embedded in step 5 `[CERT]` (`sdd-continue.md:18`):

- If `blockedReasons` is not empty → do not proceed to apply, archive or terminal work.
- If `nextRecommended` is `verify` → verification/remediation may run only to refresh evidence.
- If `nextRecommended` is `resolve-blockers` → report `blockedReasons` and stop.
- If `nextRecommended` is a planning token (`propose`, `spec`, `design`, `tasks`) → launch the corresponding planning phase.

Ambiguous change resolution `[CERT]` (`sdd-continue.md:13`): if `$ARGUMENTS` is missing and more than one active change exists, **ask the user and STOP. Do not guess.**

Closing status contract `[CERT]` (`sdd-continue.md:37-39`): the meta-command explicitly references the shared contract `~/.config/opencode/skills/_shared/sdd-status-contract.md` (see [Block 15], [Block 22]), and warns against using a workspace-relative `skills/_shared/...` path. Also: *"Carry `actionContext` and allowed edit roots into any sub-agent launch. If status reports `workspace-planning` with no allowed edit roots, do not launch apply/verify/archive work that would infer repo-local ownership."* `[CERT]`.

**Mental model** `[INFER]`: `/sdd-continue` is the incremental advancement engine of the DAG. Unlike `/sdd-new` (which starts two fixed phases) or `/sdd-ff` (which traverses all of planning), `/sdd-continue` advances **exactly one phase**, the one the authoritative status declares ready. It is idempotent with respect to state: if you run it twice, the second run reads the updated status and advances the next phase.

## 14.5 — `/sdd-ff <name>`: planning fast-forward `[CERT]`

`/sdd-ff` **advances ALL the planning phases** — from proposal through tasks `[CERT]` (frontmatter `sdd-ff.md:2`: "Fast-forward all SDD planning phases — proposal through tasks").

The four planning phases it traverses `[CERT]` (`sdd-ff.md:14-19`):

1. **`sdd-propose`** — create the proposal.
2. **`sdd-spec`** — write the specifications.
3. **`sdd-design`** — create the technical design.
4. **`sdd-tasks`** — decompose into implementation tasks.

Behavior according to execution mode `[CERT]` (`sdd-ff.md:21-22`):

- In **`interactive`** mode: run ONLY the next planning phase, present its summary and artifact path(s), ask whether to adjust or continue, then STOP. Do not launch the following phase until the user confirms.
- In **`auto`** mode: run all the planning phases back-to-back and present a combined summary at the end.

The meta-command honors the cached execution mode from the Session Preflight `[CERT]` (`sdd-ff.md:12`: "Honor the cached execution mode from SDD Session Preflight").

Persistence `[CERT]` (`sdd-ff.md:34-35`): in engram/hybrid each phase saves with `topic_key "sdd/$ARGUMENTS/{type}"` where type is: `proposal`, `spec`, `design`, `tasks`.

**Why it is called "fast-forward"** `[INFER]`: the term comes from the analogy with a player — `/sdd-ff` "fast-forwards" the tape through the entire planning phase without stopping at each step (in auto mode). It covers the `proposal → specs → design → tasks` stretch of the DAG, which is exactly the complete planning BEFORE touching code. It stops just before `apply` — it never implements. This is consistent with the SDD philosophy: plan completely, then execute.

## 14.6 — The three meta-commands compared `[CERT]`

Synthesis of each meta-command's traversal over the DAG `[CERT]` (cross-referencing the three command files with `CLAUDE.md` §"Dependency Graph"):

| Meta-command | DAG stretch it covers | Stopping point | Granularity |
|--------------|-------------------------|-----------------|--------------|
| `/sdd-new <change>` | `explore → propose` | After the proposal, asks whether to continue | 2 fixed phases |
| `/sdd-ff <name>` | `propose → spec → design → tasks` | After tasks (auto) or after each phase (interactive) | All of planning |
| `/sdd-continue [change]` | the next ready phase of the full DAG | After one phase, asks to proceed | 1 phase, status-driven |

Observations `[INFER]`:

- `/sdd-new` and `/sdd-ff` have a **fixed traversal known in advance** (they do not consult the dispatcher's status to decide which phase comes next; they know their sequence). `/sdd-continue` is the only **status-driven** one: it asks the dispatcher/Engram which phase corresponds.
- There is intentional overlap on `propose`: `/sdd-new` runs it, `/sdd-ff` does too. The typical use `[INFER]` is to choose one or the other depending on how much you want to advance at once: `/sdd-new` to start cautiously, `/sdd-ff` to plan everything in one go, `/sdd-continue` to advance step by step from any state.
- None of the three reaches `apply`/`verify`/`archive` by its fixed traversal. `/sdd-continue` CAN reach those execution phases, but only when the authoritative status declares them ready and without `blockedReasons` `[CERT]` (`sdd-continue.md:18`).

## 14.7 — Connections

- **[Block 5] to [Block 9] — Planning phases**: the meta-commands do NOT execute work; they delegate to these phases. `/sdd-new` summons `sdd-explore` ([Block 5]) and `sdd-propose` ([Block 6]). `/sdd-ff` summons `sdd-propose` ([Block 6]), `sdd-spec` ([Block 7]), `sdd-design` ([Block 8]) and `sdd-tasks` ([Block 9]). The detail of what each phase produces is in those blocks.
- **[Block 10] to [Block 12] — Execution phases**: `/sdd-continue` can reach `sdd-apply` ([Block 10]), `sdd-verify` ([Block 11]) and `sdd-archive` ([Block 12]) when the status declares them ready.
- **[Block 15] — status + native dispatcher**: step 1 of `/sdd-continue` (and all its routing by `nextRecommended`/`blockedReasons`) depends on the status contract and the `gentle-ai` dispatcher, which [Block 15] documents in detail, including the dispatcher's blindness to the engram backend.
- **[Block 16] — execution modes + Gatekeeper**: the auto vs. interactive behavior that `/sdd-ff` describes in §14.5, and the Session Preflight of the HARD GATE (§14.2), are elaborated in [Block 16].
- **[Block 17] — delivery/chain strategy**: two of the four Session Preflight elements (chained PR strategy, review budget) are detailed in [Block 17].
- **[Block 18] — delegation + triggers + models**: the "Do NOT execute phase work inline — delegate to sub-agents" that closes the three meta-commands is the materialization of the delegation model that [Block 18] formalizes, including the per-phase model gate.
