# Block 27 — Internal architecture of the configurator: `state.json` and the per-harness adapters

> **WHAT IT DOCUMENTS**: This block covers two areas of the `gentle-ai` internal architecture: (1) the REAL schema of the state file `~/.gentle-ai/state.json` — the `InstallState` struct, all fields and types known at v2.2.0, JSON tags, back-compat semantics, and the 7 new fields added in the RDD era; (2) the per-harness adapter layer — the `Adapter` interface, the `Registry`/factory, and how each of the 16 adapters materializes the SDD/ecosystem config for its agent (config dir, system prompt file, prompt injection strategy, MCP strategy, sub-agent support). It also documents the `~/.gentle-ai/review-contexts/v1/` directory introduced in the RDD era.
> **SCOPE**: The INTERNAL architecture of the configurator binary (packages `internal/state` and `internal/agents`). It does NOT redefine the `install/sync/upgrade` command surface (see [Block 26]); it does NOT re-develop the Full/Solo-agent/Detect-only delegation models per harness (see [Block 25]); it does NOT document the native SDD status dispatcher (see [Block 15]) nor the Engram/OpenSpec persistence backends (see [Block 3]); it does NOT document the SEMANTICS of model assignments (which model does which job and why — see [Block 18]). It covers the SCHEMA and the ADAPTERS, not the orchestrator runtime.
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.
> **SOURCES** (read and verified at v2.2.0):
> - `~/.gentle-ai/state.json` (live state file, direct read) `[CERT]` — primary source for all schema claims in §27.2
> - `~/.gentle-ai/review-contexts/v1/rctx1_*.json` (direct read of one file) `[CERT]` — source for §27.8
> - `ls ~/.gentle-ai/` and `ls ~/.gentle-ai/review-contexts/v1/` (read-only shell) `[CERT]`
> - `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md` (348 lines) `[CERT]` — for architecture cross-references
> - `gentle-ai --help` (live CLI) `[CERT]`
> - Go source files cited in the v1.43.2 era via `gh api` (`gentle-ai:internal/state/state.go`, `internal/agents/interface.go`, `internal/agents/registry.go`, `internal/agents/factory.go`, `internal/model/types.go`, per-harness `adapter.go` files): NOT re-verified at v2.2.0 from the installed Cellar (only README.md and the binary are distributed there). Claims sourced exclusively from those files are marked `[CERT-a]`.
> **METHOD**: `[CERT]` = verified by reading a primary v2.2.0 source (live `state.json`, live directory listing, live JSON file read), with citation. `[CERT-a]` = verified from v1.43.2-era Go source via `gh api`; not re-verified against v2.2.0 source. `[INFER]` = deduction — basis stated. `[GAP]` = could not determine — what would settle it stated. `[DRIFTED v1.43.2→v2.2.0]` = was true at v1.43.2, now changed; the old fact is kept so readers of a v1.x artifact still have it.

---

## 27.1 — The `state` package: what `state.json` is and where it lives `[CERT-a]`

The configurator's persisted state lives in a single JSON file. The path is built by `state.Path` `[CERT-a]` (`gentle-ai:internal/state/state.go:Path`):

```go
const stateDir = ".gentle-ai"
const stateFile = "state.json"

func Path(homeDir string) string {
    return filepath.Join(homeDir, stateDir, stateFile)
}
```

That is, `~/.gentle-ai/state.json` `[CERT]` (verified by direct read). The lifecycle is trivial and without a DB `[CERT-a]`:

| Function | What it does | Citation `[CERT-a]` |
|---------|----------|----------------|
| `Read(homeDir)` | `os.ReadFile` + `json.Unmarshal` into `InstallState`; error if it does not exist or does not decode | `state.go:Read` |
| `Write(homeDir, s)` | `os.MkdirAll(.gentle-ai, 0o755)` + `json.MarshalIndent("  ")` + `os.WriteFile(…, 0o644)` with trailing `\n` | `state.go:Write` |
| `MergeAgents(existing, newAgents)` | Returns a new `InstallState` with deduplicated `InstalledAgents`; preserves ALL other fields of `existing` | `state.go:MergeAgents` |

**Key point** `[CERT-a]`: `MergeAgents` is the correct operation for an incremental install `--agent X` — load the state, merge, rewrite; the full TUI install uses direct `Write` because "the TUI selection is the source of truth". The file is written with `MarshalIndent` (2-space indentation) and `0o644` permissions.

## 27.2 — Real schema of `state.json`: the `InstallState` struct

All the content of `state.json` is the serialization of the `InstallState` struct. Fields verified at v2.2.0 directly from the live `~/.gentle-ai/state.json` `[CERT]` are marked accordingly; fields verified at v1.43.2 from Go source but absent from the live file (likely omitempty-empty) are marked `[CERT-a]`.

The live state.json uses 2-space indentation `[CERT]` and `0o644` permissions `[CERT-a]` (`state.go:Write`).

### 27.2.1 — Core identity and component fields (v2.2.0 complete set)

| JSON key | Go field (inferred) | Type | Purpose | v2.2.0 status |
|----------|---------------------|------|---------|----------------|
| `installed_agents` | `InstalledAgents` | `[]string` | List of installed harnesses (e.g. `"opencode"`, `"claude-code"`, `"codex"`). The ONLY field WITHOUT `omitempty` `[CERT-a]` | `[CERT]` present: `["opencode","claude-code","codex"]` |
| `selection_configured` | `SelectionConfigured` | `bool` | `true` when the initial selection TUI has completed; gate for incremental vs fresh install `[INFER]` | `[CERT]` present: `true` — **NEW in RDD era; absent from v1.43.2 schema** |
| `components` | `Components` | `[]string` | List of installed component names (e.g. `"engram"`, `"sdd"`, `"skills"`, `"context7"`, `"permissions"`, `"gga"`, `"claude-theme"`, `"opencode-gentle-logo"`, `"persona"`) | `[CERT]` present — **NEW in RDD era; absent from v1.43.2 schema** |
| `preset` | `Preset` | `string` | Active preset name (e.g. `"full-gentleman"`). Empty = no preset selected `[INFER]` | `[CERT]` present: `"full-gentleman"` — **NEW in RDD era; absent from v1.43.2 schema** |
| `sdd_mode` | `SDDMode` | `string` | Active SDD mode: `"single"` or `"multi"` `[INFER]` | `[CERT]` present: `"multi"` — **NEW in RDD era; absent from v1.43.2 schema** |
| `community_tools` | `CommunityTools` | `[]string` | List of installed community tools (e.g. `"codegraph"`) | `[CERT]` present: `["codegraph"]` — **NEW in RDD era; absent from v1.43.2 schema** |
| `community_tools_configured` | `CommunityToolsConfigured` | `bool` | `true` when community tools selection has completed `[INFER]` | `[CERT]` present: `true` — **NEW in RDD era; absent from v1.43.2 schema** |

> `[DRIFTED v1.43.2→v2.2.0]` — **v1.43.2** documented `InstallState` as having 9 fields. **v2.2.0** has at least 7 additional fields confirmed in the live state file: `selection_configured`, `components`, `preset`, `sdd_mode`, `community_tools`, `community_tools_configured`, and `codexOrchestratorAssignment` (see §27.2.2). The `omitempty` convention means a freshly updated state.json may still lack new fields until `sync` writes them.

### 27.2.2 — Model assignment fields

| JSON key | Go field (inferred) | Type | Purpose | v2.2.0 status |
|----------|---------------------|------|---------|----------------|
| `claude_model_assignments` | `ClaudeModelAssignments` | `map[string]string` | SDD phase → Claude model alias (`"fable"`/`"opus"`/`"sonnet"`/`"haiku"`). Superseded by `claude_phase_assignments` `[CERT-a]` | `[CERT-a]` omitempty-absent (this user uses `claude_phase_assignments`) |
| `claude_phase_assignments` | `ClaudePhaseAssignments` | `map[string]ClaudePhaseAssignmentState` | SDD phase → `{model, effort}`. Supersedes `claude_model_assignments` while keeping back-compat `[CERT-a]`. Empty `effort` = Claude Code default | `[CERT]` present with 13 phase entries |
| `kiro_model_assignments` | `KiroModelAssignments` | `map[string]string` | SDD phase → Kiro-native model alias | `[CERT-a]` omitempty-absent (Kiro not installed) |
| `codexModelAssignments` | `CodexModelAssignments` | `map[string]string` | SDD phase → Codex `reasoning_effort` (`low`/`medium`/`high`/`xhigh`) `[CERT-a]` | `[CERT]` present with 13 phase entries |
| `codexCarrilModelAssignments` | `CodexCarrilModelAssignments` | `map[string]string` | Lane profile (`sdd-strong`/`sdd-mid`/`sdd-cheap`) → OpenAI model ID. Empty = resolves to `DefaultCarrilModels` at runtime `[CERT-a]` | `[CERT]` present: 3 entries |
| `codexPhaseModelAssignments` | `CodexPhaseModelAssignments` | `map[string]string` | 13 SDD phases → model ID per phase (override of the lane level). `nil` = no per-phase custom `[CERT-a]` | `[CERT-a]` omitempty-absent (no per-phase custom) |
| `codexOrchestratorAssignment` | `CodexOrchestratorAssignment` | object `{model string, effort string}` | Orchestrator-role assignment for Codex, separate from the per-phase map. Type shape inferred from JSON `[INFER]` | `[CERT]` present: `{"model":"gpt-5.6-sol","effort":"medium"}` — **NEW in RDD era; absent from v1.43.2 schema** |
| `model_assignments` | `ModelAssignments` | `map[string]ModelAssignmentState` | Sub-agent key → `{provider_id, model_id, effort?}` (OpenCode style). See §27.2.3 for the full key set | `[CERT]` present with 19 entries |
| `persona` | `Persona` | `string` | Installed persona (`"gentleman"`/`"neutral"`/`"custom"`). Empty → fallback to `PersonaGentleman` `[CERT-a]` | `[CERT]` present: `"gentleman"` |
| `last_update_check` | `LastUpdateCheck` | `*time.Time` | Last OK remote check; cooldown gate (`UpdateCheckTTL = 6h`). `nil` = never checked `[CERT-a]` | `[CERT]` present: `"2026-07-28T18:47:23.397651123-06:00"` |
| `pending_sync` | `PendingSync` | `bool` | `true` when a self-upgrade finished and `sync` still needs to run on the next launch; idempotent under failure `[CERT-a]` | `[CERT-a]` omitempty-absent (false/zero) |

Nested structs `[CERT-a]` (`gentle-ai:internal/state/state.go`):
- `ModelAssignmentState{ ProviderID string \`json:"provider_id"\`; ModelID string \`json:"model_id"\`; Effort string \`json:"effort,omitempty"\` }` — JSON mirror of `model.ModelAssignment`
- `ClaudePhaseAssignmentState{ Model string \`json:"model"\`; Effort string \`json:"effort,omitempty"\` }` — empty `Effort` = Claude Code default

### 27.2.3 — `model_assignments` key set (v2.2.0) `[CERT]`

The full key set observed in the live `model_assignments` map `[CERT]` (`~/.gentle-ai/state.json`):

| Key | Category | New in RDD era? |
|-----|----------|-----------------|
| `gentle-orchestrator` | OpenCode conductor | No |
| `sdd-apply` | SDD phase | No |
| `sdd-archive` | SDD phase | No |
| `sdd-design` | SDD phase | No |
| `sdd-explore` | SDD phase | No |
| `sdd-init` | SDD phase | No |
| `sdd-onboard` | SDD phase | No |
| `sdd-propose` | SDD phase | No |
| `sdd-spec` | SDD phase | No |
| `sdd-tasks` | SDD phase | No |
| `sdd-verify` | SDD phase | No |
| `jd-fix-agent` | Judgment Day | No |
| `jd-judge-a` | Judgment Day | No |
| `jd-judge-b` | Judgment Day | No |
| `review-readability` | RDD review lens | **YES — new in RDD era** |
| `review-refuter` | RDD review lens | **YES — new in RDD era** |
| `review-reliability` | RDD review lens | **YES — new in RDD era** |
| `review-resilience` | RDD review lens | **YES — new in RDD era** |
| `review-risk` | RDD review lens | **YES — new in RDD era** |

> `[DRIFTED v1.43.2→v2.2.0]` — **v1.43.2** had no `review-*` keys in `model_assignments`. **v2.2.0** adds 5 keys corresponding to the 4 RDD review lenses (R1 risk, R2 readability, R3 reliability, R4 resilience) plus a separate refuter role. The value type for all 5 is `ModelAssignmentState` (same as other entries). **Semantics of each lens** — which model is assigned and why — are owned by [Block 18]; this block documents only the structure (that these 5 keys now exist as `model_assignments` entries in `state.json`).

**Key observation** `[INFER]`: `state.json` does NOT store SDD tasks, specs, or change progress. It is CONFIGURATOR state (what is installed, with which persona, which model per phase, when updates were checked), not SDD change state. This confirms the separation of [Block 3]: SDD artifacts live in Engram/OpenSpec, NOT in `~/.gentle-ai/state.json`. The per-phase granularity of the state (Claude/Kiro/Codex with distinct maps) is what allows `sync` to regenerate each harness's config while preserving the user's model decisions.

**Back-compat** `[CERT-a]`: every field except `installed_agents` carries `,omitempty` — old state files that lack a field are still valid; the code documents per-field back-compat. A file from v1.43.2 lacking the 7 new fields remains loadable; they will be zero-valued until `sync` writes them.

## 27.3 — The `Adapter` interface: the central per-harness abstraction `[CERT-a]`

The interface's header comment says it literally `[CERT-a]` (`gentle-ai:internal/agents/interface.go`):

> *"Adapter is the core abstraction for AI agent integration. Components use adapter methods instead of switch statements on AgentID, making it trivial to add new agents without modifying component code."*

That is: the components (`internal/components/{sdd,skills,mcp,persona,…}`) do NOT do `switch agent {…}`; they ask the adapter WHERE and HOW to write. The interface groups the methods into blocks `[CERT-a]` (`interface.go`):

| Block | Methods | What it resolves |
|--------|---------|--------------|
| Identity | `Agent() model.AgentID`, `Tier() model.SupportTier` | Identity + support level |
| Detection | `Detect(ctx, homeDir) (installed, binaryPath, configPath, configFound, err)` | Is the harness installed? |
| Installation | `SupportsAutoInstall() bool`, `InstallCommand(profile) ([][]string, error)` | Installation command per platform |
| Config paths (WHERE) | `GlobalConfigDir`, `SystemPromptDir`, `SystemPromptFile`, `SkillsDir`, `SettingsPath` | Config paths; the components do NOT hardcode paths |
| Config strategies (HOW) | `SystemPromptStrategy() model.SystemPromptStrategy`, `MCPStrategy() model.MCPStrategy` | How to inject, not where |
| MCP | `MCPConfigPath(homeDir, serverName)` | MCP path resolution |
| Capabilities | `SupportsOutputStyles/OutputStyleDir`, `SupportsSlashCommands/CommandsDir`, `SupportsSubAgents/SubAgentsDir/EmbeddedSubAgentsDir`, `SupportsSkills`, `SupportsSystemPrompt`, `SupportsMCP` | Each agent DECLARES what it supports |

The WHERE (paths) vs HOW (strategies) separation is explicit in the code: the `Config strategies` comment says *"HOW to inject content, not WHERE (that's paths above)"* `[CERT-a]` (`interface.go`). All adapters report `Tier() = TierFull` — and `model.types` documents that `TierFull` is the ONLY tier: *"All current agents receive the full SDD orchestrator, skill files, MCP config, and system prompt injection"* `[CERT-a]` (`gentle-ai:internal/model/types.go:SupportTier`). The tier remained as display metadata, not a functional gate `[INFER]`.

**Note on re-verification** `[GAP]`: the v1.43.2 `Adapter` interface was read from `internal/agents/interface.go`. The RDD era may have added methods (e.g. for review context, staging projection). The interface above cannot be confirmed as complete for v2.2.0 without reading the v2.x Go source. What would settle it: read `internal/agents/interface.go` from the v2.2.0 tag.

## 27.4 — `Registry` and `factory`: how many adapters there are and how they load `[CERT-a]`

The `Registry` is a `map[model.AgentID]Adapter` with `Register` (rejects nil and duplicates via `ErrDuplicateAdapter`), `Get`, and `SupportedAgents()` (ordered ids) `[CERT-a]` (`gentle-ai:internal/agents/registry.go`).

The `factory` defines the canonical list `defaultAgentIDs` with **16 AgentIDs** and a `NewAdapter(agent)` with a 16-case `switch` `[CERT-a]` (`gentle-ai:internal/agents/factory.go`). `NewDefaultRegistry()` instantiates all 16; `NewMVPRegistry()` instantiates only Claude+OpenCode "kept for backward compatibility" `[CERT-a]`.

The 16 AgentIDs `[CERT-a]` (`gentle-ai:internal/model/types.go:AgentID` + `factory.go:defaultAgentIDs`):

`claude-code`, `opencode`, `kilocode`, `gemini-cli`, `cursor`, `vscode-copilot`, `codex`, `antigravity`, `windsurf`, `kimi`, `qwen-code`, `kiro-ide`, `openclaw`, `pi`, `trae-ide`, `hermes`.

Each one has its package `internal/agents/<name>/adapter.go` + `adapter_test.go` `[CERT-a]` (verified in the v1.43.2 repo tree: 16 adapter directories).

**Note on re-verification** `[GAP]`: the count of 16 was verified at v1.43.2. If new harnesses were added in the RDD era, the count and the `defaultAgentIDs` list may have grown. What would settle it: read `internal/agents/factory.go` from the v2.2.0 tag.

## 27.5 — Master table: what each adapter materializes `[CERT-a]`

The five decisive columns per harness, read from each `adapter.go` at v1.43.2 `[CERT-a]`. `Prompt strat.` and `MCP strat.` reference the constants of `model.types` (§27.6).

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

Evidence notes for non-obvious rows `[CERT-a]`:

- **Antigravity** shares the system prompt with Gemini (`~/.gemini/GEMINI.md`) but uses `antigravityVariantDir` as the config dir and the `AppendToFile` strategy. This explains the separately documented SDD workaround.
- **Codex** installs via `npm install -g --ignore-scripts @openai/codex@<versions.Codex>` (postinstall blocked due to supply-chain) and has NO `settings.json` (`SettingsPath` returns `""`).
- **Cursor** and **Kiro** declare native sub-agents (`SubAgentsDir` not empty) — consistent with the README "10 SDD agents in `~/.cursor/agents/`" and "Native `~/.kiro/agents/`" `[CERT]`.
- **Hermes** is the only one with `MergeIntoYAML` and persona in `SOUL.md`; **OpenClaw** uses `AGENTS.md` in the workspace root.

Only **4 of 16** adapters declare `SupportsSubAgents()==true`: Claude, Cursor, Kimi, Kiro `[CERT-a]`. The rest materialize SDD delegation via orchestrator-in-prompt, which connects with the Full/Solo-agent/Detect-only models of [Block 25] `[INFER]`.

**Note on re-verification**: the table above was verified from v1.43.2 Go source. Paths for rows with "config path" / "variant dir" entries (Antigravity, OpenClaw, Pi, Kiro) are resolved by per-OS helper functions `[CERT-a]`; the table cites the logical result, not each per-platform branch.

## 27.6 — The strategies: `SystemPromptStrategy` and `MCPStrategy` `[CERT-a]`

The strategies are closed enums in `model.types`, with semantics documented in their comments `[CERT-a]` (`gentle-ai:internal/model/types.go`):

**`SystemPromptStrategy`** (6 values):

| Constant | What it does | Example harness |
|-----------|----------|------------------|
| `StrategyMarkdownSections` | Injects sections with `<!-- gentle-ai:ID -->` markers WITHOUT clobbering user content | Claude (`CLAUDE.md`), OpenClaw, Trae, Hermes |
| `StrategyFileReplace` | Replaces the entire prompt file | OpenCode (`AGENTS.md`), Gemini, Codex, Qwen, Kilocode, Cursor |
| `StrategyAppendToFile` | Appends content to an existing file | Antigravity, Windsurf, Pi |
| `StrategyInstructionsFile` | Writes a dedicated `.instructions.md` file | VS Code Copilot |
| `StrategyJinjaModules` | Writes separate modules included in a thin Jinja2 template | Kimi (`KIMI.md`) |
| `StrategySteeringFile` | Writes a Kiro steering file with `inclusion: always` frontmatter | Kiro |

**`MCPStrategy`** (5 values): `StrategySeparateMCPFiles` (one JSON per server, e.g. `~/.claude/mcp/context7.json`), `StrategyMergeIntoSettings` (merges `mcpServers` into settings.json — OpenCode/Gemini/Qwen/Kilocode/OpenClaw), `StrategyMCPConfigFile` (dedicated `mcp.json` file — Cursor/VSCode/Antigravity/Windsurf/Kimi/Kiro/Pi/Trae), `StrategyTOMLFile` (Codex `config.toml`), `StrategyMergeIntoYAML` (Hermes `config.yaml`, comment-preserving merge) `[CERT-a]` (`model/types.go`).

**Key point** `[INFER]`: the pair (PromptStrategy, MCPStrategy) IS each harness's "materialization fingerprint". It is what makes adding a new harness a matter of declaring paths + choosing two strategies from the enum, without touching the components — exactly the promise of the interface comment (§27.3).

**Note on re-verification** `[GAP]`: the strategy enums were verified at v1.43.2. The RDD era may have added new strategies (e.g. for review integration). What would settle it: read `internal/model/types.go` from the v2.2.0 tag.

## 27.7 — Resolving the "8 adapters vs 16 harnesses" gap `[CERT-a]`

[Block 26] left a discrepancy open: `docs/architecture.md` talks about **8 adapters** while the README lists 16 harnesses. Resolution with evidence:

1. **`docs/architecture.md` is OUTDATED** `[CERT-a]`. It lists only 8 adapter directories (`claude/ opencode/ gemini/ cursor/ vscode/ codex/ windsurf/ antigravity/`) and states *"All 8 agent adapters have unit tests"*. It is a snapshot of the MVP era.
2. **The CODE has 16 adapters** `[CERT-a]`. `factory.go:defaultAgentIDs` enumerates 16 AgentIDs and `NewAdapter` instantiates all 16; the v1.43.2 repo tree confirmed 16 directories. The 8 missing from the doc — `kilocode, kimi, qwen, kiro, openclaw, pi, trae, hermes` — DO exist, are registered, and are tested.
3. **The README's agent count** `[CERT]`: the v2.2.0 README (`README.md:40-59`) lists exactly 16 rows in the supported agents table, including Hermes (Detect-only).

**Verdict** `[CERT-a]`: the authoritative count is **16 adapters = 16 AgentIDs registered in `factory.go`**. The "8" figure in `docs/architecture.md` is documentation debt (stale doc), NOT a code limit. Honest recommendation: any claim about "N adapters" should be anchored to `factory.go:defaultAgentIDs`.

## 27.8 — `~/.gentle-ai/review-contexts/v1/`: the RDD review context store `[CERT]`

A new top-level directory in `~/.gentle-ai/` introduced in the RDD era `[CERT]` (verified by `ls ~/.gentle-ai/`):

```
~/.gentle-ai/review-contexts/
  v1/
    rctx1_<sha256-hash>.json   (one file per review session, content-addressed by hash)
```

At v2.2.0 on this machine, 5 files are present `[CERT]` (verified by `ls ~/.gentle-ai/review-contexts/v1/`). Schema of one file `[CERT]` (direct read):

```json
{
  "schema":              "gentle-ai.review-repository-context/v1",
  "handle":              "rctx1_<sha256-hash>",
  "lineage_id":          "review-<hex>",
  "target_identity":     "sha256:<hex>",
  "revision":            "sha256:<hex>",
  "repository_identity": "sha256:<hex>",
  "repository_root":     "/absolute/path/to/repo",
  "git_common_dir":      "/absolute/path/to/repo/.git",
  "git_dir":             "/absolute/path/to/repo/.git"
}
```

**What it is** `[INFER]`: a user-global index record that links a review transaction (by `lineage_id`) to its repository (by `repository_root`, `repository_identity`). The transaction CAS itself lives in `<repo>/.git/gentle-ai/review-transactions/v2/` (per-repo, not per-user). The review context in `~/.gentle-ai/` bridges the binary's user-level authority knowledge with the per-repo CAS, enabling commands like `review status` and `review validate` to locate authority across multiple repositories without scanning all git trees `[INFER]`.

**File naming**: `rctx1_<sha256-hash>.json` — the `rctx1` prefix denotes schema version 1; the hash is content-addressing `[INFER]` (consistent with the `revision` field being a sha256 of state).

**Not a mutating operation target**: the files are written by `review start` and similar review commands (mutating, not run here). Their content was verified by reading one file directly `[CERT]`.

## 27.9 — Honest gaps and limits of this reading

- `[CERT-a]` The Go source files cited in this block (`internal/state/state.go`, `internal/agents/interface.go`, etc.) were verified at v1.43.2 via `gh api`. They are NOT re-verified at v2.2.0 from the installed Cellar, which distributes only the binary and README. The live `state.json` provides direct evidence for the schema at v2.2.0; the Go source details (lifecycle functions, interface method signatures) remain `[CERT-a]`.
- `[GAP]` Whether the `Adapter` interface gained new methods in the RDD era (e.g. for review-context participation or staged projection) is unknown. What would settle it: read `internal/agents/interface.go` from the v2.x tag.
- `[GAP]` Whether `defaultAgentIDs` in `factory.go` has grown beyond 16 in the v2.x era is unknown. What would settle it: read `internal/agents/factory.go` from the v2.x tag.
- `[INFER]` The CONCRETE materialization of the SDD content (which bytes each strategy writes) lives in `internal/components/sdd/inject.go` and `filemerge/`, not read exhaustively here; this block documents the CONTRACT (paths + adapter strategies), not the body of each injector.
- `[CERT]` The live `state.json` confirms: no fields for scope (`global`/`workspace`) or channel (`stable`/`beta`) are persisted — those are invocation flags of [Block 26]. The `state.json` is RESULT state (what ended up installed), not invocation-configuration state `[INFER]`.
- `[CERT]` The live `state.json` confirms: no fields for SDD task progress, change IDs, or spec content — those live in Engram/OpenSpec by topic key (see [Block 3]).

## 27.10 — Connections

- **[Block 26]** — `state.json` is the substrate that `sync`/`upgrade`/`doctor` read and rewrite; this block opens the struct that B26 mentioned as a black box. `PendingSync` is the upgrade→sync handshake of B26. The `sdd_mode`, `preset`, and `components` fields are the persisted results of the TUI selections documented in B26.
- **[Block 18]** — The `*ModelAssignments` maps of `InstallState` (§27.2.2) and the `model_assignments` map (§27.2.3) persist the per-phase model assignments that B18 defines at the orchestrator level. This block owns the STRUCTURE (key names, types, JSON tags); B18 owns the SEMANTICS (which model does which job). The 5 new `review-*` keys in `model_assignments` correspond to the 4 RDD lenses and the refuter role whose semantics B18 defines.
- **[Block 25]** — the 16 adapters are the Go implementation of the harnesses and their delegation models (Full/Solo-agent/Detect-only); §27.5 shows that only 4 declare native sub-agents, the rest materialize orchestrator-in-prompt.
- **[Block 15]** — the native dispatcher `gentle-ai sdd-status` (package `internal/sddstatus`) reads OpenSpec artifacts, NOT `state.json`; it confirms the configurator-state vs change-state separation.
- **[Block 3]** — the SDD artifacts (proposal/spec/tasks…) live in Engram/OpenSpec by topic key, never in `state.json`; §27.2 proves it by the absence of task fields.
