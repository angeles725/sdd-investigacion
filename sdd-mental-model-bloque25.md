# Block 25 — Multi-agent distribution: the 15 harnesses and the delegation models

> **WHAT IT DOCUMENTS**: This block documents how the Gentle AI ecosystem distributes SDD to 15 distinct agent harnesses: the canonical table of supported agents (Agent / Delegation Model / Key Feature), the three delegation models (**Full**, **Solo-agent**, **Detect-only**), what each one means operationally, where the SDD configuration lives per harness family (config paths, agent directories, prompt files), and what happens to the SDD pipeline when the harness does NOT have native sub-agents (sequential execution in a single thread). It includes the documented Antigravity workaround.
> **SCOPE**: The DISTRIBUTION layer of SDD across harnesses. It does NOT document the `gentle-ai` configurator binary (commands, scopes, backups, hooks — see [Block 26]); it does NOT redefine the SDD phase graph or the Result Contract (see [Block 2]); it does NOT develop the orchestrator's delegation triggers (see [Block 18]). This block takes those phases as given and describes ON WHAT MECHANISM they execute depending on the harness.
> **SOURCES** (read and verified via `gh api` over `Gentleman-Programming/gentle-ai`, `main` branch):
> - `gentle-ai:README.md` (261 lines — "15 Supported Agents", "Delegation Triggers" sections)
> - `gentle-ai:docs/agents.md` (286 lines — Agent Matrix, Delegation Models, SDD Mode Support, Agent Notes)
> - `gentle-ai:docs/antigravity-sdd-workaround.md` (25 lines)
> - `gentle-ai:docs/kiro.md` (167 lines)
> - `gentle-ai:docs/pi.md` (169 lines)
> - `gentle-ai:docs/platforms.md` (50 lines — Windows Config Paths)
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the repo file, with `gentle-ai:<path>` and the cited table/section. `[CERT-a]` = asserted by the README/docs but not verified in the Go source of the configurator. `[INFER]` = my own deduction, not literal in the source.

---

## 25.1 — The canonical table of the 15 agents `[CERT]`

The README publishes the "15 Supported Agents" table with three columns: **Agent**, **Delegation Model**, **Key Feature** `[CERT]` (`gentle-ai:README.md §"15 Supported Agents"`, lines 30-48). Reproduced verbatim:

| Agent | Delegation Model | Key Feature `[CERT]` |
|-------|------------------|----------------------|
| **Claude Code** | Full (Task tool) | Sub-agents, output styles |
| **OpenCode** | Full (multi-mode overlay) | Per-phase model routing |
| **Kilo Code** | Full (multi-mode overlay) | OpenCode-compatible config in `~/.config/kilo` |
| **Gemini CLI** | Full (experimental) | Custom agents in `~/.gemini/agents/` |
| **Cursor** | Full (native subagents) | 10 SDD agents in `~/.cursor/agents/` |
| **VS Code Copilot** | Full (runSubagent) | Parallel execution |
| **Codex** | Solo-agent | CLI-native, TOML config |
| **Windsurf** | Solo-agent | Plan Mode, Code Mode, native workflows |
| **Antigravity** | Solo-agent + Mission Control | Built-in Browser/Terminal sub-agents |
| **Kimi Code** | Full (native custom agents) | Modular prompt templates in `~/.kimi` |
| **Kiro IDE** | Full (native subagents) | Native `~/.kiro/agents/` + steering orchestration |
| **Qwen Code** | Full (native sub-agents) | Slash commands, `~/.qwen/commands/`, `auto_edit` mode |
| **OpenClaw** | Solo-agent | Workspace-first `AGENTS.md` / `SOUL.md` with global MCP |
| **Trae** | Solo-agent | ByteDance desktop app; `~/.trae/skills/` + per-OS rules |
| **Pi** | Full (package-managed subagents) | `gentle-pi` harness with persona/model commands + Engram |
| **Hermes** | Detect-only | YAML MCP config, SOUL.md persona; install manually first |

**Counting note** `[INFER]`: the README list enumerates 16 rows (15 "supported" + Hermes "Detect-only"). Hermes appears as a table entry but its delegation model is `Detect-only`, which distinguishes it from the 15 that the configurator installs automatically. `docs/agents.md` qualifies Hermes's model (see §25.4).

**Documented discrepancy `[CERT]`**: the README labels Hermes as `Detect-only` (`gentle-ai:README.md:47`), but the Agent Matrix in `docs/agents.md` labels its **Delegation** as `Full (delegate_task ephemeral)` (`gentle-ai:docs/agents.md:26`). It is not a capability contradiction but an axis one: `Detect-only` describes the INSTALLATION mode (gentle-ai cannot install Hermes, only detect it), while `Full (delegate_task)` describes the runtime DELEGATION mode once configured `[INFER]`. See §25.4 and §25.7.

## 25.2 — The extended Agent Matrix (ID, capabilities, config path) `[CERT]`

`docs/agents.md` expands the README table with the **internal ID**, capabilities (Skills, MCP, Output Styles, Slash Commands) and **Config Path** `[CERT]` (`gentle-ai:docs/agents.md:9-26`):

| Agent | ID | Skills | MCP | Delegation | Slash | Config Path `[CERT]` |
|-------|----|--------|-----|-----------|-------|----------------------|
| Claude Code | `claude-code` | Yes | Yes | Full (Task tool) | No | `~/.claude` |
| OpenCode | `opencode` | Yes | Yes | Full (multi-mode overlay) | Yes | `~/.config/opencode` |
| Kilo Code | `kilocode` | Yes | Yes | Full (multi-mode overlay) | Yes | `~/.config/kilo` |
| Gemini CLI | `gemini-cli` | Yes | Yes | Full (experimental) | No | `~/.gemini` |
| Cursor | `cursor` | Yes | Yes | Full (native subagents) | No | `~/.cursor` |
| VS Code Copilot | `vscode-copilot` | Yes | Yes | Full (runSubagent) | No | `~/.copilot` + VS Code User profile |
| Codex | `codex` | Yes | Yes | Solo-agent (multi-agent opt-in, experimental) | No | `~/.codex` |
| Windsurf | `windsurf` | Yes (native) | Yes | Solo-agent | No | `~/.codeium/windsurf` |
| Antigravity | `antigravity` | Yes (native) | Yes | Solo-agent + Mission Control | No | `~/.gemini/antigravity` |
| Kimi Code | `kimi` | Yes | Yes | Full (native custom agents) | No | `~/.kimi` |
| Qwen Code | `qwen-code` | Yes | Yes | Full (native sub-agents) | Yes | `~/.qwen` |
| Kiro IDE | `kiro-ide` | Yes | Yes | Full (native subagents) | No | `~/.kiro` |
| OpenClaw | `openclaw` | Yes | Yes | Solo-agent | No | `~/.openclaw` |
| Trae | `trae-ide` | Yes | Yes | Solo-agent | No | `~/.trae` |
| Pi | `pi` | Yes | Yes | Full (package-managed subagents) | Yes | `~/.pi` |
| Hermes | `hermes` | Yes | Yes | Full (delegate_task ephemeral) | No | `~/.hermes` |

**Guiding principle of distribution** `[CERT]` (`gentle-ai:docs/agents.md:28`): most agents receive the **full SDD orchestrator policy** plus the skill files written to their skills directory. Most receive it via the system prompt; OpenCode and Kilo Code receive it via the `opencode.json` agents overlay (OpenCode-compatible). **Pi is the exception**: Gentle AI installs Pi packages and `gentle-pi` owns skills, prompts, SDD agents, and chains at runtime. The agent handles SDD automatically when the task is large, or when the user asks explicitly — with no manual setup.

## 25.3 — The three delegation models `[CERT]`

`docs/agents.md` formally defines the models in a "Delegation Models" table `[CERT]` (`gentle-ai:docs/agents.md:36-40`). The conceptual axis is **where each SDD phase runs**: in an isolated context window (a real sub-agent) or inline in the same thread.

### 25.3.1 — Full (sub-agents) `[CERT]`

> *"Each SDD phase runs in an isolated context window via native sub-agent delegation, package-managed subagents, or an OpenCode-compatible overlay. The orchestrator coordinates; sub-agents execute."* `[CERT]` (`gentle-ai:docs/agents.md:38`)

Full agents: **Claude Code, OpenCode, Kilo Code, Gemini CLI, Cursor, VS Code Copilot, Kimi Code, Kiro IDE, Qwen Code, Pi** `[CERT]` (`gentle-ai:docs/agents.md:38`). Each phase of the SDD DAG (see [Block 2]) gets its own fresh context window; the orchestrator coordinates without being contaminated by the execution detail. Concrete mechanisms per family (see §25.5):

- **Native Task tool** — Claude Code `[CERT]` (`gentle-ai:docs/agents.md:11,93`)
- **OpenCode-compatible multi-mode overlay** (`opencode.json`) — OpenCode, Kilo Code `[CERT]` (`gentle-ai:docs/agents.md:12-13,38`)
- **Native subagents** (`agents/` directory) — Cursor, Kiro IDE, Qwen Code, Kimi Code, Gemini CLI (experimental) `[CERT]` (`gentle-ai:docs/agents.md:14-22`)
- **`runSubagent` tool with parallel execution** — VS Code Copilot `[CERT]` (`gentle-ai:docs/agents.md:16,131`)
- **Package-managed subagents** (`pi-subagents-j0k3r` discovers `.pi/agents/`) — Pi `[CERT]` (`gentle-ai:docs/agents.md:25,244`)

### 25.3.2 — Solo-agent `[CERT]`

> *"All SDD phases run inline in the same conversation. The orchestrator IS the executor. Engram provides cross-phase persistence."* `[CERT]` (`gentle-ai:docs/agents.md:40`)

Solo-agent agents: **Codex, Windsurf, Antigravity, OpenClaw, Trae** `[CERT]` (`gentle-ai:docs/agents.md:40`). There are no sub-agents: the SDD phases execute sequentially in the same conversation thread, and the orchestrator and the executor are the same entity. Cross-phase persistence is provided by **Engram** (not the context window, which is unique) `[CERT]`. This is what prevents the context from collapsing: each phase's artifact is persisted outside the thread and the next phase re-reads it.

**Codex special case** `[CERT]`: although labeled Solo-agent, it supports multi-agent delegation as an **experimental opt-in** (default off). gentle-ai writes `features.multi_agent = false`, `agents.max_threads = 4` and `agents.max_depth = 2` to `~/.codex/config.toml`. When `multi_agent = true` is activated, the `sdd-orchestrator` uses the native tools `spawn_agent` / `wait_agent` / `close_agent` to delegate phases; if not, it falls back to solo-agent inline execution `[CERT]` (`gentle-ai:docs/agents.md:151-152`).

### 25.3.3 — Detect-only `[CERT]`

Applies to **Hermes** `[CERT]` (`gentle-ai:README.md:47`). gentle-ai **cannot install** Hermes; it only detects its presence. The user installs Hermes manually first and then runs `gentle-ai install --agent hermes` `[CERT]` (`gentle-ai:docs/agents.md:278`). Detection is done by the `hermes` binary on `PATH` and the config root `~/.hermes`, but it is the **config directory** that triggers the installation detection — the binary may be absent and Hermes is still detected as configured `[CERT]` (`gentle-ai:docs/agents.md:277`).

**Detect-only describes installation, not delegation** `[INFER]`: once configured, Hermes delegates at runtime via `delegate_task` (Full ephemeral, see §25.4). `Detect-only` is the boundary of what the configurator can automate.

## 25.4 — Hermes: Full (delegate_task ephemeral) `[CERT]`

`docs/agents.md` adds a third row to the delegation models table specific to Hermes `[CERT]` (`gentle-ai:docs/agents.md:39`):

> *"The orchestrator uses Hermes's native `delegate_task` primitive to spawn ephemeral workers in fresh context windows. Workers receive only a self-contained mission; the parent receives only their final summary. Toolsets, MCP, and skills must be passed explicitly (not inherited by default)."*

Operational rules of ephemeral delegation `[CERT]` (`gentle-ai:docs/agents.md:254-260`):

- Delegate when the work requires broad exploration (4+ files), multi-file implementation, test/build execution, or fresh adversarial review — the same triggers as [Block 18].
- Each worker mission must be **self-contained**: exact goal, paths/targets, relevant prior context, constraints, expected evidence, and the allowed toolsets/MCP/skills.
- Toolsets, MCP servers, and skills are **NOT inherited** from the parent automatically; they must be passed explicitly when `inherit_mcp_toolsets` is false (the default).
- Treat the worker's output as a self-report: verify writes, test pass/fail, URLs, and side effects before reporting success.

Tuning knobs in `~/.hermes/config.yaml` under `delegation` `[CERT]` (`gentle-ai:docs/agents.md:264-271`): `max_spawn_depth` (2), `max_concurrent_children` (4), `max_iterations`, `child_timeout_seconds`, `inherit_mcp_toolsets` (false), `subagent_auto_approve` (false). The full decision table lives in `~/.hermes/skills/hermes-ephemeral-delegation/SKILL.md`, installed by gentle-ai and referenced from the SDD orchestrator in `~/.hermes/SOUL.md` `[CERT]` (`gentle-ai:docs/agents.md:273`).

## 25.5 — Materialization of SDD per harness family `[CERT]`

SDD materializes with distinct physical artifacts depending on the harness. Map of where the SDD agents/config live `[CERT]` (consolidated from `gentle-ai:docs/agents.md §Agent Notes`, `gentle-ai:docs/kiro.md`, `gentle-ai:docs/pi.md`):

| Harness | Where SDD / orchestrator lives | Phase sub-agents | Source `[CERT]` |
|---------|----------------------------------|---------------------|------------------|
| Claude Code | `~/.claude/CLAUDE.md` (markdown sections); MCP in `~/.claude/mcp/`; output styles in `~/.claude/output-styles/` | Native Task tool (isolated context) | `docs/agents.md:91-96` |
| OpenCode | Overlay of 11 agents in `opencode.json` (`gentle-orchestrator` + 10 phases); shared prompts in `~/.config/opencode/prompts/sdd/`; slash commands `/sdd-*` | Native `task` subagents | `docs/agents.md:98-107` |
| Kilo Code | `AGENTS.md`, `skills/`, `commands/`, `opencode.json` under `~/.config/kilo` (OpenCode-compatible adapter) | Multi-agent overlay merged into `~/.config/kilo/opencode.json` | `docs/agents.md:109-115` |
| Gemini CLI | `~/.gemini`; sub-agents in `~/.gemini/agents/` (markdown) | Requires `experimental.enableAgents: true` in `settings.json` | `docs/agents.md:118-121` |
| Cursor | System prompt in `~/.cursor/rules/gentle-ai.mdc`; skills `~/.cursor/skills/`; MCP `~/.cursor/mcp.json` | 10 files `~/.cursor/agents/sdd-{phase}.md` | `docs/agents.md:123-127` |
| VS Code Copilot | Prompt in `Code/User/prompts/gentle-ai.instructions.md`; skills `~/.copilot/skills/`; MCP `Code/User/mcp.json` | `runSubagent` tool (parallel execution) | `docs/agents.md:129-134` |
| Codex | Prompt in `~/.codex/AGENTS.md`; skills `~/.codex/skills/`; TOML config `~/.codex/config.toml`; Engram instructions `~/.codex/engram-instructions.md` | Inline (opt-in `spawn_agent`/`wait_agent`/`close_agent`) | `docs/agents.md:137-152` |
| Windsurf | Global rules `~/.codeium/windsurf/memories/global_rules.md`; skills `~/.codeium/windsurf/skills/`; MCP `mcp_config.json` | Inline; workflows in `.windsurf/workflows/` (workspace) | `docs/agents.md:154-159` |
| Antigravity | Prompt appended to `~/.gemini/GEMINI.md` (shared with Gemini CLI); skills `~/.gemini/antigravity/skills/`; MCP `mcp_config.json` | Inline + Mission Control (built-in Browser/Terminal) | `docs/agents.md:161-167` |
| Kimi Code | Root agent `~/.kimi/agents/gentleman.yaml` with `system_prompt_path: ../KIMI.md`; `KIMI.md` = Jinja template that includes `persona.md`, `output-style.md`, `engram-protocol.md`, `sdd-orchestrator.md` | Native custom agents | `docs/agents.md:169-175` |
| Kiro IDE | Steering `~/.kiro/steering/gentle-ai.md` (`inclusion: always`); skills `~/.kiro/skills/`; MCP **always** in `~/.kiro/settings/mcp.json` | 10 files `~/.kiro/agents/sdd-{phase}.md` | `docs/agents.md:177-186`, `docs/kiro.md` |
| Qwen Code | Prompt `~/.qwen/QWEN.md`; skills `~/.qwen/skills/`; MCP in `~/.qwen/settings.json` (`mcpServers`); slash commands `~/.qwen/commands/*.md` (namespaced, e.g. `/sdd:init`); `auto_edit` mode | Native sub-agents | `docs/agents.md:188-199` |
| OpenClaw | Engram+SDD instructions in workspace `AGENTS.md`; persona in `SOUL.md`; global MCP `~/.openclaw/openclaw.json`; workspace SDD skills `<workspace>/.openclaw/skills/sdd-*` | Inline (solo-agent) | `docs/agents.md:201-208` |
| Trae | Rules in OS-specific `user_rules.md` (`StrategyMarkdownSections`); skills `~/.trae/skills/`; OS-specific MCP `mcp.json` | Inline (solo-agent) | `docs/agents.md:210-220` |
| Pi | `gentle-pi` owns everything at runtime: `.pi/agents/sdd-*.md`, `.pi/chains/sdd-*.chain.md`, `.pi/gentle-ai/support/`; copied on `session_start` | `pi-subagents-j0k3r` discovers and runs `.pi/agents/` | `docs/agents.md:222-248`, `docs/pi.md` |
| Hermes | SDD prompt + persona in `~/.hermes/SOUL.md` (`<!-- gentle-ai:* -->` markers); skills `~/.hermes/skills/`; MCP YAML in `~/.hermes/config.yaml` | Ephemeral `delegate_task` (fresh context) | `docs/agents.md:250-286` |

**Cross-cutting pattern** `[INFER]`: in ALL harnesses the orchestrator lives in the agent's "persistent prompt" (CLAUDE.md, steering, SOUL.md, QWEN.md, global_rules.md, opencode.json) and the phases live in separate agent files (when there are sub-agents) or execute as sequential roles in the same prompt (when there are none). The file name changes; the role "orchestrator coordinates / phase executes" does not.

## 25.6 — SDD without sub-agents: single-thread simulation `[CERT]`

When the harness is Solo-agent, **the SDD phases are the same but the delegation mechanism changes**: instead of spawning a sub-agent with fresh context, the orchestrator switches roles sequentially within the same thread `[CERT]` (`gentle-ai:docs/agents.md:40`). The risk is **context degradation**: the LLM begins to mix instructions from earlier skills and loses the architectural thread `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:4-5`).

### 25.6.1 — Antigravity + Mission Control `[CERT]`

Antigravity is an agent-first platform with built-in sub-agents (Browser, Terminal) managed by **Mission Control**, but **custom sub-agent creation is not yet available** `[CERT]` (`gentle-ai:docs/agents.md:61`). The SDD phases run inline; Mission Control delegates automatically to the built-in sub-agents when specialized tooling is needed (e.g. Browser for research during `sdd-explore`) `[CERT]`.

### 25.6.2 — The "Artifact-Driven State Machine" workaround `[CERT]`

`docs/antigravity-sdd-workaround.md` documents the pattern to make SDD functional on Antigravity today, in "Single-Threaded Simulation" mode, **without affecting the original multi-agent architecture of Cursor or OpenCode** `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:8,24-25`). It is a state machine resting strictly on the local filesystem. Four injected rules `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:10-22`):

1. **Strict Role Switching** — the orchestrator announces the phase change and loads the corresponding `SKILL.md` into its context, **temporarily ignoring** previous directives.
2. **File-System as memory (Save State)** — when finishing a phase (e.g. `sdd-propose`), Antigravity is PROHIBITED from advancing without saving the full output to a physical file (e.g. `.sdd/propuesta.md`). The chat is NOT reliable storage.
3. **Controlled amnesia (Load State)** — when starting the next phase (e.g. `sdd-spec`), it must NOT trust its chat history. Its first mandatory action is to `Read` the file generated in the previous step, refreshing the exact context the phase needs.
4. **Correct use of Engram** — `mem_save` is reserved ONLY for global architectural decisions, conventions, and bugfixes; NOT for the intermediate state of the in-progress SDD (that is what the `.sdd/*.md` files are for).

**Mental model** `[INFER]`: the workaround replicates with the filesystem what Full harnesses obtain with isolated context windows. The "Save State / Load State / Controlled amnesia" is exactly the context asymmetry of [Block 19] §19.6 (the large context does not go up the thread; it is persisted and re-read by reference), but implemented by hand over `.sdd/*.md` instead of native delegation. It is the operational proof that **the phases are invariant and only the context transport changes**.

## 25.7 — SDD mode support: single-mode vs multi-mode `[CERT]`

`docs/agents.md` publishes an SDD Mode Support matrix `[CERT]` (`gentle-ai:docs/agents.md:75-85`). The 15+1 harnesses support **SDD orchestrator** and **Single-mode SDD** (`Yes` across all 16 columns). The differentiator is **Multi-mode SDD** (assigning a different model to each phase):

| Capability | Who supports it `[CERT]` |
|-----------|----------------------------|
| SDD orchestrator | All 16 (all) |
| Single-mode SDD | All 16 (all) |
| Multi-mode SDD | **OpenCode**, **Kilo Code** (via OpenCode-compatible multi-mode overlay), **Kiro IDE** (via `model:` in the native subagent frontmatter), **Pi** (owned by the Pi packages) |

- **Kiro multi-mode** `[CERT]` (`gentle-ai:docs/agents.md:83`): assigns models per phase via `KiroModelAssignments` (TUI: *Configure Models → Configure Kiro models*). The Kiro alias (`auto|opus|sonnet|haiku|minimax|glm|deepseek|qwen`) resolves to a Kiro-native model ID and is stamped into each `~/.kiro/agents/sdd-{phase}.md` at sync time.
- **Pi multi-mode** `[CERT]` (`gentle-ai:docs/agents.md:85`): owned by the Pi packages. `gentle-pi` installs SDD agent and chain assets in `.pi/agents/` and `.pi/chains/`; model overrides live in those Pi-managed files or in chain steps.

All the others run **single-mode**: the orchestrator handles everything with the model the agent is already running `[CERT]` (`gentle-ai:docs/agents.md:81`). The configurator's per-phase assignment (OpenCode profiles, Codex profiles, Kiro assignments) is detailed in [Block 26].

## 25.8 — Key implication: the phases are invariant, the transport changes `[CERT-a]`

The central claim of this block, supported by all sources: **the SDD phase graph (`proposal → specs/design → tasks → apply → verify → archive`, see [Block 2]) is identical across the 15 harnesses; the only thing that changes is the delegation MECHANISM** `[INFER]` (derived from `gentle-ai:docs/agents.md:38-40,77-78` + `gentle-ai:docs/kiro.md:48`).

Textual evidence from Kiro `[CERT]` (`gentle-ai:docs/kiro.md:48`): *"This follows the same SDD architecture used in gentle-ai: orchestrator coordinates, phase agents execute, Engram persists artifacts across phases."* The SDD Mode Support matrix confirms that the `SDD orchestrator` is `Yes` for all 16 `[CERT]` (`gentle-ai:docs/agents.md:77`).

Three incarnations of the SAME contract depending on the transport `[INFER]`:

| Transport | Phase runs in | Cross-phase persistence | Example |
|-----------|----------------|--------------------------|---------|
| Real sub-agent (Full) | Isolated context window, spawned by the orchestrator | Backend (Engram/OpenSpec) + reference by topic_key/path | Claude Code Task, Cursor agents, Kiro agents |
| Sequential thread (Solo-agent) | The same thread, role-switching | Engram (the thread is unique, the context is reused) | Codex inline, Windsurf, OpenClaw, Trae |
| Thread + filesystem state machine (reinforced Solo-agent) | The same thread + mandatory Save/Load State | `.sdd/*.md` files + Engram only for decisions | Antigravity workaround |

The Result Contract of [Block 2] (status, executive_summary, artifacts, next_recommended, risks, skill_resolution) is what each phase returns **independently of the transport** — it is the interface that makes it possible for the orchestrator not to distinguish, at the coordination level, between a real sub-agent and an inline role-switch `[INFER]`.

## 25.9 — Connections

- **[Block 1] — Philosophy + orchestrator**: the "orchestrator coordinates / phase executes" model that [Block 1] establishes philosophically materializes here in 15 distinct transports. The orchestrator's "thin thread" (§1.x) is trivial in Full (the sub-agent absorbs the heavy context) but requires explicit discipline in Solo-agent (hence the Antigravity workaround, §25.6.2).
- **[Block 2] — DAG + Result Contract**: §25.8 is the thesis of this block — the phase DAG and the Result Contract of [Block 2] are INVARIANT with respect to the harness. The contract is the interface that decouples "which phase" from "on what mechanism it runs".
- **[Block 18] — Delegation + triggers + models**: the README's Delegation Triggers (§25 mentions reading 4+ files, touching 2+ files, etc.) are the same as [Block 18]'s; here you see how each harness implements them (real sub-agent vs role-switch). Hermes reuses those triggers literally (§25.4).
- **[Block 19] — Persistence contract**: the context asymmetry of [Block 19] §19.6 (large context does not go up the thread) is what the Antigravity workaround (§25.6.2) replicates by hand with `.sdd/*.md`. In Solo-agent, Engram IS the cross-phase persistence mechanism that replaces the isolated window.
- **[Block 26] — The `gentle-ai` configurator**: this block describes WHAT is distributed to each harness; [Block 26] describes the binary that distributes it (install/sync/upgrade, scopes, per-agent adapters, per-phase models). The multi-mode assignment of §25.7 (OpenCode/Kilo/Kiro/Pi) is detailed operationally in [Block 26].
