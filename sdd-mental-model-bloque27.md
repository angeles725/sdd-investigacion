# Block 27 — Internal architecture of the configurator: `state.json` and the per-harness adapters

> **WHAT IT DOCUMENTS**: This block closes the two gaps that can only be resolved by reading the Go source of `gentle-ai` in `internal/`: (1) the REAL schema of the state file `~/.gentle-ai/state.json` —the `InstallState` struct, fields, types, JSON tags, and back-compat semantics—; and (2) the per-harness adapter layer —the `Adapter` interface, the `Registry`/`factory`, and how each of the 16 adapters materializes the SDD/ecosystem config for its agent (config dir, system prompt file, prompt injection strategy, MCP strategy, sub-agent support)—.
> **SCOPE**: The INTERNAL architecture of the configurator binary (packages `internal/state` and `internal/agents`). It does NOT redefine the `install/sync/upgrade` command surface (see [Block 26]); it does NOT re-develop the Full/Solo-agent/Detect-only delegation models per harness (see [Block 25]); it does NOT document the native SDD status dispatcher (see [Block 15]) nor the Engram/OpenSpec persistence backends (see [Block 3]). It covers the SCHEMA and the ADAPTERS, not the orchestrator runtime.
> **SOURCES** (read and verified via `gh api` over `Gentleman-Programming/gentle-ai`, `main` branch):
> - `gentle-ai:internal/state/state.go` (struct `InstallState`, `Read`/`Write`/`MergeAgents`/`Path`)
> - `gentle-ai:internal/agents/interface.go` (interface `Adapter`)
> - `gentle-ai:internal/agents/registry.go` (`Registry`, `Register`, `SupportedAgents`)
> - `gentle-ai:internal/agents/factory.go` (`defaultAgentIDs`, `NewAdapter`, `NewDefaultRegistry`, `NewMVPRegistry`)
> - `gentle-ai:internal/model/types.go` (constants `AgentID`, `SystemPromptStrategy`, `MCPStrategy`, `SupportTier`)
> - `gentle-ai:internal/agents/{claude,opencode,codex,gemini,cursor,vscode,antigravity,windsurf,kimi,qwen,kiro,openclaw,pi,trae,hermes,kilocode}/adapter.go`
> - `gentle-ai:docs/architecture.md` (codebase layout — source of the "8 adapters" gap)
> - `gentle-ai:README.md` ("15 Supported Agents" table)
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the repo's `.go`, with `gentle-ai:<path>:<symbol>`. `[CERT-a]` = asserted by docs/README but not confirmed in the code. `[INFER]` = my own deduction, not literal in the source.

---

## 27.1 — The `state` package: what `state.json` is and where it lives `[CERT]`

The configurator's persisted state lives in a single JSON file. The path is built by `state.Path` `[CERT]` (`gentle-ai:internal/state/state.go:Path`):

```go
const stateDir = ".gentle-ai"
const stateFile = "state.json"

func Path(homeDir string) string {
    return filepath.Join(homeDir, stateDir, stateFile)
}
```

That is, `~/.gentle-ai/state.json` `[CERT]`. The lifecycle is trivial and without a DB `[CERT]`:

| Function | What it does | Citation `[CERT]` |
|---------|----------|----------------|
| `Read(homeDir)` | `os.ReadFile` + `json.Unmarshal` into `InstallState`; error if it does not exist or does not decode | `state.go:Read` |
| `Write(homeDir, s)` | `os.MkdirAll(.gentle-ai, 0o755)` + `json.MarshalIndent("  ")` + `os.WriteFile(…, 0o644)` with trailing `\n` | `state.go:Write` |
| `MergeAgents(existing, newAgents)` | Returns a new `InstallState` with deduplicated `InstalledAgents`; preserves ALL other fields of `existing` | `state.go:MergeAgents` |

**Key point** `[CERT]`: `MergeAgents` is the correct operation for an incremental install `--agent X` —load the state, merge, rewrite—; the full TUI install uses direct `Write` because "the TUI selection is the source of truth" (comment in `state.go:MergeAgents`). The file is written with `MarshalIndent` (2-space indentation) and `0o644` permissions `[CERT]`.

## 27.2 — Real schema of `state.json`: the `InstallState` struct `[CERT]`

All the content of `state.json` is the serialization of the `InstallState` struct `[CERT]` (`gentle-ai:internal/state/state.go:InstallState`). Every field except `installed_agents` carries `,omitempty` —that is, old state files that lack a field are still valid; the code explicitly documents the per-field back-compat.

| Go field | JSON tag | Type | Purpose | Citation `[CERT]` |
|----------|----------|------|-----------|----------------|
| `InstalledAgents` | `installed_agents` | `[]string` | List of installed harnesses (AgentIDs like `"claude-code"`, `"opencode"`). The only field WITHOUT `omitempty` | `state.go:InstallState` |
| `ClaudeModelAssignments` | `claude_model_assignments` | `map[string]string` | Maps SDD phase (`"sdd-explore"`) → Claude model alias (`"fable"`/`"opus"`/`"sonnet"`/`"haiku"`). Preserved so `sync` does not fall back to the "balanced" preset | `state.go` |
| `ClaudePhaseAssignments` | `claude_phase_assignments` | `map[string]ClaudePhaseAssignmentState` | Maps SDD phase → `{model, effort}`. **Supersedes** `ClaudeModelAssignments` while keeping back-compat | `state.go` |
| `KiroModelAssignments` | `kiro_model_assignments` | `map[string]string` | SDD phase → Kiro-native model alias | `state.go` |
| `CodexModelAssignments` | `codexModelAssignments` | `map[string]string` | SDD phase → Codex `reasoning_effort` (`low\|medium\|high\|xhigh`) | `state.go` |
| `CodexCarrilModelAssignments` | `codexCarrilModelAssignments` | `map[string]string` | Lane profile (`sdd-strong\|sdd-mid\|sdd-cheap`) → OpenAI model id (`"gpt-5.5"`). Empty = resolves to `DefaultCarrilModels` at runtime | `state.go` |
| `CodexPhaseModelAssignments` | `codexPhaseModelAssignments` | `map[string]string` | The 13 SDD phases → model id per phase (override of the lane level). `nil` = no per-phase custom | `state.go` |
| `ModelAssignments` | `model_assignments` | `map[string]ModelAssignmentState` | Sub-agent → provider/model pair (OpenCode style) | `state.go` |
| `Persona` | `persona` | `string` | Installed persona (`"gentleman"`/`"neutral"`/`"custom"`). Empty → fallback to `PersonaGentleman` | `state.go` |
| `LastUpdateCheck` | `last_update_check` | `*time.Time` | Last OK remote check; cooldown gate (`UpdateCheckTTL = 6h`). `nil` = never checked | `state.go` |
| `PendingSync` | `pending_sync` | `bool` | `true` when a self-upgrade finished and `sync` still needs to run on the next launch; idempotent under failure | `state.go` |

Nested structs `[CERT]` (`gentle-ai:internal/state/state.go`):

- `ModelAssignmentState{ ProviderID string \`json:"provider_id"\`; ModelID string \`json:"model_id"\`; Effort string \`json:"effort,omitempty"\` }` — JSON mirror of `model.ModelAssignment`, lives in `state` to avoid an import cycle.
- `ClaudePhaseAssignmentState{ Model string \`json:"model"\`; Effort string \`json:"effort,omitempty"\` }` — empty `Effort` = Claude Code default.

**Key observation** `[INFER]`: `state.json` does NOT store SDD tasks, specs, or change progress. It is CONFIGURATOR state (what I installed, with which persona, which model per phase, when I checked for updates), not SDD change state. This confirms the separation of [Block 3]: SDD artifacts live in Engram/OpenSpec, NOT in `~/.gentle-ai/state.json`. The per-phase granularity of the state (Claude/Kiro/Codex with distinct maps) is what allows `sync` to regenerate each harness's config while preserving the user's model decisions.

## 27.3 — The `Adapter` interface: the central per-harness abstraction `[CERT]`

The interface's header comment says it literally `[CERT]` (`gentle-ai:internal/agents/interface.go`):

> *"Adapter is the core abstraction for AI agent integration. Components use adapter methods instead of switch statements on AgentID, making it trivial to add new agents without modifying component code."*

That is: the components (`internal/components/{sdd,skills,mcp,persona,…}`) do NOT do `switch agent {…}`; they ask the adapter WHERE and HOW to write. The interface groups the methods into blocks `[CERT]` (`interface.go`):

| Block | Methods | What it resolves |
|--------|---------|--------------|
| Identity | `Agent() model.AgentID`, `Tier() model.SupportTier` | Identity + support level |
| Detection | `Detect(ctx, homeDir) (installed, binaryPath, configPath, configFound, err)` | Is the harness installed? |
| Installation | `SupportsAutoInstall() bool`, `InstallCommand(profile) ([][]string, error)` | Installation command per platform |
| Config paths (WHERE) | `GlobalConfigDir`, `SystemPromptDir`, `SystemPromptFile`, `SkillsDir`, `SettingsPath` | Config paths; the components do NOT hardcode paths |
| Config strategies (HOW) | `SystemPromptStrategy() model.SystemPromptStrategy`, `MCPStrategy() model.MCPStrategy` | How to inject, not where |
| MCP | `MCPConfigPath(homeDir, serverName)` | MCP path resolution |
| Capabilities | `SupportsOutputStyles/OutputStyleDir`, `SupportsSlashCommands/CommandsDir`, `SupportsSubAgents/SubAgentsDir/EmbeddedSubAgentsDir`, `SupportsSkills`, `SupportsSystemPrompt`, `SupportsMCP` | Each agent DECLARES what it supports |

The WHERE (paths) vs HOW (strategies) separation is explicit in the code: the `Config strategies` comment says *"HOW to inject content, not WHERE (that's paths above)"* `[CERT]` (`interface.go`). All adapters report `Tier() = TierFull` `[CERT]` —and `model.types` documents that `TierFull` is the ONLY tier: *"All current agents receive the full SDD orchestrator, skill files, MCP config, and system prompt injection"* (`gentle-ai:internal/model/types.go:SupportTier`). The tier remained as a display metadata, not a functional gate `[INFER]`.

## 27.4 — `Registry` and `factory`: how many adapters there are and how they load `[CERT]`

The `Registry` is a `map[model.AgentID]Adapter` with `Register` (rejects nil and duplicates via `ErrDuplicateAdapter`), `Get`, and `SupportedAgents()` (ordered ids) `[CERT]` (`gentle-ai:internal/agents/registry.go`).

The `factory` defines the canonical list `defaultAgentIDs` with **16 AgentIDs** and a `NewAdapter(agent)` with a 16-case `switch` `[CERT]` (`gentle-ai:internal/agents/factory.go`). `NewDefaultRegistry()` instantiates all 16; `NewMVPRegistry()` instantiates only Claude+OpenCode "kept for backward compatibility" `[CERT]`.

The 16 AgentIDs `[CERT]` (`gentle-ai:internal/model/types.go:AgentID` + `factory.go:defaultAgentIDs`):

`claude-code`, `opencode`, `kilocode`, `gemini-cli`, `cursor`, `vscode-copilot`, `codex`, `antigravity`, `windsurf`, `kimi`, `qwen-code`, `kiro-ide`, `openclaw`, `pi`, `trae-ide`, `hermes`.

Each one has its package `internal/agents/<name>/adapter.go` + `adapter_test.go` `[CERT]` (verified in the repo tree: 16 adapter directories, all with a test).

## 27.5 — Master table: what each adapter materializes `[CERT]`

The five decisive columns per harness, read directly from each `adapter.go` `[CERT]`. `Prompt strat.` and `MCP strat.` reference the constants of `model.types` (§27.6).

| # | Package / AgentID | GlobalConfigDir | SystemPromptFile | Prompt strat. | MCP strat. | SubAgents |
|---|-------------------|-----------------|------------------|---------------|------------|-----------|
| 1 | `claude` / `claude-code` | `~/.claude` | `~/.claude/CLAUDE.md` | MarkdownSections | SeparateMCPFiles | ✅ `~/.claude/agents` |
| 2 | `opencode` / `opencode` | `~/.config/opencode` | `~/.config/opencode/AGENTS.md` | FileReplace | MergeIntoSettings | ❌ |
| 3 | `kilocode` / `kilocode` | `~/.config/kilo` | `~/.config/kilo/AGENTS.md` | FileReplace | MergeIntoSettings | ❌ |
| 4 | `gemini` / `gemini-cli` | `~/.gemini` | `~/.gemini/GEMINI.md` | FileReplace | MergeIntoSettings | ❌ |
| 5 | `cursor` / `cursor` | `~/.cursor` | `~/.cursor/rules/gentle-ai.mdc` | FileReplace | MCPConfigFile | ✅ `~/.cursor/agents` |
| 6 | `vscode` / `vscode-copilot` | `~/.copilot` | `…/gentle-ai.instructions.md` | InstructionsFile | MCPConfigFile | ❌ |
| 7 | `codex` / `codex` | `~/.codex` | `~/.codex/AGENTS.md` | FileReplace | TOMLFile (`config.toml`) | ❌ |
| 8 | `antigravity` / `antigravity` | variant dir | `~/.gemini/GEMINI.md` | AppendToFile | MCPConfigFile | ❌ |
| 9 | `windsurf` / `windsurf` | `~/.codeium/windsurf` | `…/global_rules.md` | AppendToFile | MCPConfigFile | ❌ |
| 10 | `kimi` / `kimi` | `~/.kimi` | `~/.kimi/KIMI.md` | JinjaModules | MCPConfigFile | ✅ `~/.kimi/agents` |
| 11 | `qwen` / `qwen-code` | `~/.qwen` | `~/.qwen/QWEN.md` | FileReplace | MergeIntoSettings | ❌ |
| 12 | `kiro` / `kiro-ide` | kiro config dir | `…/gentle-ai.md` (steering) | SteeringFile | MCPConfigFile | ✅ `~/.kiro/agents` |
| 13 | `openclaw` / `openclaw` | config path | `~/AGENTS.md` | MarkdownSections | MergeIntoSettings | ❌ |
| 14 | `pi` / `pi` | config path | append system file | AppendToFile | MCPConfigFile | ❌ |
| 15 | `trae` / `trae-ide` | `~/.trae` | `…/user_rules.md` | MarkdownSections | MCPConfigFile | ❌ |
| 16 | `hermes` / `hermes` | config path | `~/.hermes/SOUL.md` | MarkdownSections | MergeIntoYAML (`config.yaml`) | ❌ |

Evidence notes for non-obvious rows `[CERT]`:

- **Antigravity** shares the system prompt with Gemini (`~/.gemini/GEMINI.md`) but uses `antigravityVariantDir` as the config dir and the `AppendToFile` strategy `[CERT]` (`antigravity/adapter.go`). This explains the separately documented SDD workaround (`docs/antigravity-sdd-workaround.md`).
- **Codex** installs via `npm install -g --ignore-scripts @openai/codex@<versions.Codex>` (postinstall blocked due to supply-chain) and has NO `settings.json` (`SettingsPath` returns `""`) `[CERT]` (`codex/adapter.go`).
- **Cursor** and **Kiro** declare native sub-agents (`SubAgentsDir` not empty) — consistent with the README "10 SDD agents in `~/.cursor/agents/`" and "Native `~/.kiro/agents/`" `[CERT]`.
- **Hermes** is the only one with `MergeIntoYAML` and persona in `SOUL.md`; **OpenClaw** also uses `AGENTS.md` in the workspace root `[CERT]`.

Only **4 of 16** adapters declare `SupportsSubAgents()==true`: Claude, Cursor, Kimi, Kiro `[CERT]`. The rest materialize SDD delegation via orchestrator-in-prompt (a single `sdd-orchestrator.md` / overlay), which connects with the Full/Solo-agent/Detect-only models of [Block 25] `[INFER]`.

## 27.6 — The strategies: `SystemPromptStrategy` and `MCPStrategy` `[CERT]`

The strategies are closed enums in `model.types`, with the semantics documented in their comments `[CERT]` (`gentle-ai:internal/model/types.go`):

**`SystemPromptStrategy`** (6 values):

| Constant | What it does | Example harness |
|-----------|----------|------------------|
| `StrategyMarkdownSections` | Injects sections with `<!-- gentle-ai:ID -->` markers WITHOUT clobbering user content | Claude (`CLAUDE.md`), OpenClaw, Trae, Hermes |
| `StrategyFileReplace` | Replaces the entire prompt file | OpenCode (`AGENTS.md`), Gemini, Codex, Qwen, Kilocode, Cursor |
| `StrategyAppendToFile` | Appends content to an existing file | Antigravity, Windsurf, Pi |
| `StrategyInstructionsFile` | Writes a dedicated `.instructions.md` file | VS Code Copilot |
| `StrategyJinjaModules` | Writes separate modules included in a thin Jinja2 template | Kimi (`KIMI.md`) |
| `StrategySteeringFile` | Writes a Kiro steering file with `inclusion: always` frontmatter | Kiro |

**`MCPStrategy`** (5 values): `StrategySeparateMCPFiles` (one JSON per server, e.g. `~/.claude/mcp/context7.json`), `StrategyMergeIntoSettings` (merges `mcpServers` into settings.json — OpenCode/Gemini/Qwen/Kilocode/OpenClaw), `StrategyMCPConfigFile` (dedicated `mcp.json` file — Cursor/VSCode/Antigravity/Windsurf/Kimi/Kiro/Pi/Trae), `StrategyTOMLFile` (Codex `config.toml`), `StrategyMergeIntoYAML` (Hermes `config.yaml`, comment-preserving merge) `[CERT]` (`model/types.go`).

**Key point** `[INFER]`: the pair (PromptStrategy, MCPStrategy) IS each harness's "materialization fingerprint". It is what makes adding a new harness a matter of declaring paths + choosing two strategies from the enum, without touching the components —exactly the promise of the interface comment (§27.3).

## 27.7 — Resolving the "8 adapters vs 16 harnesses" gap `[CERT]`

[Block 26] left a discrepancy open: `docs/architecture.md` talks about **8 adapters** while the README lists ~15 harnesses. Resolution with evidence:

1. **`docs/architecture.md` is OUTDATED** `[CERT]`. It lists only 8 adapter directories —`claude/ opencode/ gemini/ cursor/ vscode/ codex/ windsurf/ antigravity/`— and states *"All 8 agent adapters have unit tests"* (`gentle-ai:docs/architecture.md`). It is a snapshot of the MVP era.
2. **The CODE has 16 adapters** `[CERT]`. `factory.go:defaultAgentIDs` enumerates 16 AgentIDs and `NewAdapter` instantiates all 16; the repo tree confirms 16 directories `internal/agents/<name>/` each with `adapter.go` + `adapter_test.go` (`gentle-ai:internal/agents/factory.go`). The 8 missing from the doc —`kilocode, kimi, qwen, kiro, openclaw, pi, trae, hermes`— DO exist, are registered, and are tested.
3. **The README's "15"** `[CERT-a]`: the header says "15 Supported Agents" but the table lists **16 rows** (`gentle-ai:README.md:28-47`). Row #16 is **Hermes**, marked *"Detect-only — install manually first"*. The most coherent reading `[INFER]`: the "15" counts the harnesses gentle-ai can auto-configure/install, treating Hermes (detect-only, no auto-install) as a separate case; the code does not distinguish —all 16 are full-fledged adapters with `Tier()==TierFull`.

**Verdict** `[CERT]`: the authoritative count is **16 adapters = 16 AgentIDs registered in `factory.go`**. The "8" figure in `docs/architecture.md` is documentation debt (stale doc), NOT a code limit. The "15" figure in the README is presentational (it excludes Hermes detect-only from the "supported" count). Honest recommendation: any claim about "N adapters" should be anchored to `factory.go:defaultAgentIDs`, which is the only source the binary actually executes.

## 27.8 — Honest gaps and limits of this reading

- `[INFER]` The CONCRETE materialization of the SDD content (which bytes each strategy writes) lives in `internal/components/sdd/inject.go` and `filemerge/`, not read exhaustively here; this block documents the CONTRACT (paths + adapter strategies), not the body of each injector. The connection to the embedded assets (`internal/assets/<harness>/sdd-orchestrator.md`, OpenCode single/multi overlays) remains in [Block 25].
- `[INFER]` Some config dirs are resolved by a helper with variant/OS logic (`antigravityVariantDir`, `kiroConfigDir`, `vscodeUserDir`, `windsurfUserDir`, `traeUserDir`, `pi.AgentConfigPath`); the §27.5 table cites the logical result, not each per-platform branch.
- `[CERT]` No fields were found in `InstallState` for scope (`global`/`workspace`) or channel (`stable`/`beta`): those are not persisted in `state.json` —they are invocation flags of [Block 26]. The `state.json` is RESULT state (what ended up installed), not invocation-configuration state `[INFER]`.

## 27.9 — Connections

- **[Block 26]** — `state.json` is the substrate that `sync`/`upgrade`/`doctor` read and rewrite; this block opens the struct that B26 mentioned as a black box. `PendingSync` is the upgrade→sync handshake of B26.
- **[Block 25]** — the 16 adapters are the Go implementation of the harnesses and their delegation models (Full/Solo-agent/Detect-only); §27.5 shows that only 4 declare native sub-agents, the rest materialize orchestrator-in-prompt.
- **[Block 15]** — the native dispatcher `gentle-ai sdd-status` (package `internal/sddstatus`) reads OpenSpec artifacts, NOT `state.json`; it confirms the configurator-state vs change-state separation.
- **[Block 3]** — the SDD artifacts (proposal/spec/tasks…) live in Engram/OpenSpec by topic key, never in `state.json`; §27.2 proves it by the absence of task fields.
- **[Block 18]** — the `*ModelAssignments` maps of `InstallState` persist the per-phase model assignments that B18 defines at the orchestrator level; here you see where they are stored on disk.
