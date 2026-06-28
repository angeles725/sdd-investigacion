# Block 26 — The `gentle-ai` configurator: install/sync/upgrade, scopes, OpenCode SDD profiles, per-phase models

> **WHAT IT DOCUMENTS**: This block documents the `gentle-ai` configurator binary (Go) that distributes the ecosystem (persistent memory + SDD + skills + MCP + persona) to the 15 harnesses: what it IS (an ecosystem configurator, NOT an agent installer), its commands (`install`, `sync`, `upgrade`, `doctor`, `skill-registry refresh`), the scopes (`global` vs `workspace`), the stable/beta channels, the OpenCode SDD Profiles with per-phase model assignment, the Codex and Kiro per-phase profiles, the automatic backup system (tar.gz, dedup, prune, pin), the startup hooks that keep the skill-registry fresh, and the `state.json` in `~/.gentle-ai/`.
> **SCOPE**: The configurator binary and its command/configuration surface. It does NOT redefine the delegation models or the per-harness materialization (see [Block 25]); it does NOT develop the persistence contract or the Engram/OpenSpec backends (see [Block 3] and [Block 19-21]); it does NOT document the native SDD status dispatcher in detail (see [Block 15]). It covers the configurator, not the orchestrator runtime.
> **SOURCES** (read and verified via `gh api` over `Gentleman-Programming/gentle-ai`, `main` branch):
> - `gentle-ai:README.md` (261 lines — What It Does, Quick Start, Install, Backups, OpenCode SDD Profiles, Engram)
> - `gentle-ai:docs/opencode-profiles.md` (188 lines)
> - `gentle-ai:docs/architecture.md` (81 lines — Go codebase layout)
> - `gentle-ai:docs/non-interactive.md` (62 lines — flags, env vars, platform behavior)
> - `gentle-ai:docs/agents.md` (Codex profiles, Kiro assignments, Pi packages)
> - `gentle-ai:docs/pi.md` (169 lines — `gentle-pi`, packages, session_start hooks)
> - `gentle-ai:docs/platforms.md` (50 lines)
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the repo file, with `gentle-ai:<path>` and the cited section/table. `[CERT-a]` = asserted by the README/docs but not verified in the Go source. `[INFER]` = my own deduction, not literal in the source.

---

## 26.1 — What it is: an ecosystem configurator, not an installer `[CERT]`

The README opens with the explicit negative definition `[CERT]` (`gentle-ai:README.md:22`):

> *"Gentle-AI is NOT an AI agent installer. Most agents are easy to install. It is an **ecosystem configurator** -- it takes whatever AI coding agent(s) you use and supercharges them with persistent memory, Spec-Driven Development workflows, curated coding skills, MCP servers, an AI provider switcher, a teaching-oriented persona with security-first permissions, and per-phase model assignment so each SDD step can run on a different model."*

The value contrast `[CERT]` (`gentle-ai:README.md:24-26`): **Before** — "I installed Claude Code / OpenCode / Cursor but it's just a chatbot that writes code". **After** — the agent now has memory, skills, workflow, MCP tools, and a persona that teaches. The configurator **supersedes** Agent Teams Lite (archived); everything from ATL is included with better installation, automatic updates, and persistent memory `[CERT]` (`gentle-ai:README.md:49`).

**Key point** `[INFER]`: the "configurator, not installer" distinction is structural — gentle-ai writes configuration files (prompts, skills, SDD agents, MCP, persona) into the config dir of each already-installed harness. Most harnesses install themselves; gentle-ai SUPERCHARGES them. This explains why Hermes/Kiro/Trae/OpenClaw/Pi are detect-only or manual-install: the configurator configures what already exists.

## 26.2 — CLI commands `[CERT]`

Command surface verifiable in README + docs `[CERT]`:

| Command | What it does | Source `[CERT]` |
|---------|----------|------------------|
| `gentle-ai install` | Writes agent-scoped files to each selected agent's global config dir | `gentle-ai:README.md:151` |
| `gentle-ai install --scope=workspace` | Isolates the stack to a project: writes agent-scoped files to the current project root | `gentle-ai:README.md:154`, `docs/non-interactive.md:19` |
| `gentle-ai sync` | Re-applies/updates the config; entry point for profiles, migrations, and backups | `gentle-ai:README.md:177-179`, `docs/opencode-profiles.md` |
| `gentle-ai upgrade` | Self-update + binary and asset upgrade; respects the active channel | `gentle-ai:README.md:99` |
| `gentle-ai doctor` | Read-only health check of the ecosystem (binaries, `state.json`, Engram reach, disk space) | `gentle-ai:README.md:112` |
| `gentle-ai skill-registry refresh` | Scans installed skills + project conventions and rebuilds the registry | `gentle-ai:README.md:108` |
| `gentle-ai install --agent <id>` | Installs/configures a specific harness (e.g. `--agent pi`, `--agent hermes`, `--agent openclaw`) | `gentle-ai:docs/agents.md:204`, `docs/pi.md:14` |
| `gentle-ai update` | Compares versions of materialized plugins with GitHub releases (community plugins) | `gentle-ai:README.md:237` |
| `gentle-ai` (no args) | Launches the Bubbletea TUI (welcome screen, OpenCode SDD Profiles, etc.) | `gentle-ai:README.md:180`, `docs/opencode-profiles.md:34` |

### 26.2.1 — Project-level setup post-install `[CERT]`

After configuring agents, two commands register the project context `[CERT]` (`gentle-ai:README.md:105-110`):

| Command | What it does | When to re-run `[CERT]` |
|---------|----------|----------------------------|
| `/sdd-init` | Detects stack, testing capabilities, activates Strict TDD Mode if available | When the project adds/removes test frameworks, or first time in a new project |
| `gentle-ai skill-registry refresh` | Scans installed skills and conventions, builds the registry | After installing/removing skills, or first time in a new project |

Neither is required for basic use: the SDD orchestrator runs `/sdd-init` automatically if it detects there is no context `[CERT]` (`gentle-ai:README.md:110`).

### 26.2.2 — Non-interactive mode (CI / scripts) `[CERT]`

`go run ./cmd/gentle-ai install [flags]` supports flags for reproducible setup `[CERT]` (`gentle-ai:docs/non-interactive.md:7-21`): `--agent`/`--agents` (repeatable CSV), `--component`/`--components`, `--skill`/`--skills`, `--persona`, `--preset`, `--sdd-mode` (`single`|`multi`), `--scope` (`global`|`workspace`), `--dry-run` (renders the plan without executing). Errors: unknown options fail fast with validation; an unsupported platform exits before any install work `[CERT]` (`gentle-ai:docs/non-interactive.md:60-62`).

## 26.3 — Scopes: global vs workspace `[CERT]`

By default, `gentle-ai install` writes agent-scoped files to each selected agent's **global config dir** `[CERT]` (`gentle-ai:README.md:151`). To isolate the Gentleman stack to a project:

```bash
gentle-ai install --scope=workspace
```

**Workspace scope is NOT Claude-only** `[CERT]` (`gentle-ai:README.md:157`, `docs/agents.md:30`): it applies to the selected agents for agent-scoped files — system prompts, skills, SDD agents, and persona files — written to the project root (`./`). The global-only integrations (package installs, settings the agent only reads from its global config) **remain global by design** `[CERT]` (`gentle-ai:docs/non-interactive.md:28`).

Equivalent environment variable `[CERT]` (`gentle-ai:docs/non-interactive.md:24-26`): `GENTLE_AI_INSTALL_SCOPE` with values `global` (default) | `workspace`. Useful in CI; equivalent to `--scope`.

**Mental model** `[INFER]`: scope is a decision about WHERE the agent-scoped files live (global config dir vs project root), not about WHAT is installed. The global-only stuff (packages, MCP the agent reads from its global config) ignores scope because the harness would not read it from the project.

## 26.4 — Stable / beta channels `[CERT]`

The installer supports two channels `[CERT]` (`gentle-ai:README.md:83-99`):

- **stable** — via Homebrew/Scoop, CI release artifacts.
- **beta** — builds Gentle AI directly from `main`, which is why it requires **Go 1.24+** installed first. To try unreleased changes and report issues early.

```bash
# macOS/Linux beta
curl -fsSL .../install.sh | bash -s -- --channel beta
# Windows beta
$env:GENTLE_AI_CHANNEL="beta"; irm .../install.ps1 | iex
# Keep upgrading on beta
GENTLE_AI_CHANNEL=beta gentle-ai upgrade
```

To go back to stable: reinstall via Homebrew or Scoop `[CERT]` (`gentle-ai:README.md:99`). Supported platforms `[CERT]` (`gentle-ai:docs/platforms.md:7-13`): macOS (Homebrew), Ubuntu/Debian (apt), Arch (pacman), Fedora/RHEL (dnf), Windows 10/11 (Scoop). Derivatives detected via `ID_LIKE` in `/etc/os-release` `[CERT]` (`gentle-ai:docs/platforms.md:15`).

## 26.5 — OpenCode SDD Profiles: per-phase model assignment `[CERT]`

The configurator's flagship feature: assigning **different models to different SDD phases** — a powerful model for design, a fast one for implementation, a cheap one for exploration `[CERT]` (`gentle-ai:README.md:171-173`). OpenCode uses `gentle-orchestrator` as the base SDD conductor; named profiles generate `sdd-orchestrator-{name}` entries `[CERT]`.

### 26.5.1 — Two profile strategies `[CERT]`

`docs/opencode-profiles.md` defines two modes `[CERT]` (`gentle-ai:docs/opencode-profiles.md:11-12,179-182`):

1. **`generated-multi`** (Generated multi-profile mode) — the classic flow. Base = `gentle-orchestrator`. Each named profile generates its `sdd-orchestrator-{name}` + 10 suffixed phase sub-agents in `opencode.json`; cycled with **Tab** inside OpenCode.
2. **`external-single-active`** (External single-active mode) — for community tools that keep profile files OUTSIDE `opencode.json` and activate one runtime profile at a time. Auto-detected if files exist under `~/.config/opencode/profiles/*.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:102-108`).

Manual strategy override `[CERT]` (`gentle-ai:docs/opencode-profiles.md:114-122`):
```bash
gentle-ai sync --agent opencode --sdd-profile-strategy external-single-active
gentle-ai sync --agent opencode --sdd-profile-strategy generated-multi
```

### 26.5.2 — Profiles CLI `[CERT]`

Create/configure profiles during sync `[CERT]` (`gentle-ai:README.md:175-181`, `docs/opencode-profiles.md:72-94`):

```bash
# Uniform profile: everything on one model
gentle-ai sync --profile cheap:openrouter/qwen/qwen3-30b-a3b:free

# Override of a specific phase: name:phase:provider/model
gentle-ai sync --profile-phase cheap:sdd-design:anthropic/claude-sonnet-4-20250514

# Combined: everything on Haiku except sdd-apply on Sonnet
gentle-ai sync \
  --profile cheap:anthropic/claude-haiku-3.5-20241022 \
  --profile-phase cheap:sdd-apply:anthropic/claude-sonnet-4-20250514
```

`--profile name:provider/model` sets all phases; `--profile-phase name:phase:provider/model` overrides a single phase `[CERT]`. Also via TUI: `gentle-ai` → "OpenCode SDD Profiles" → Create `[CERT]` (`gentle-ai:README.md:180`).

### 26.5.3 — Key names table `[CERT]`

Agent keys in `opencode.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:62-68`):

| Key | Meaning | Rename by hand? |
|-------|-------------|---------------------|
| `gentle-orchestrator` | OpenCode's canonical base SDD conductor. All `/sdd-*` point here by default | No |
| `sdd-orchestrator` | Legacy key of the base conductor. Sync migrates it to `gentle-orchestrator` | No; let sync migrate |
| `sdd-orchestrator-{name}` | Named profile conductor (e.g. `sdd-orchestrator-cheap`) | No; use TUI or CLI |
| `sdd-{phase}` | Default sub-agent of a phase (e.g. `sdd-apply`) | No |
| `sdd-{phase}-{name}` | Named profile sub-agent (e.g. `sdd-apply-cheap`) | No |

### 26.5.4 — How it works internally `[CERT]`

In `generated-multi`, each named profile generates **11 entries** in `opencode.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:175-177`): one orchestrator (`sdd-orchestrator-{name}`, mode `primary`) + 10 phase sub-agents (`sdd-{phase}-{name}`, mode `subagent`, hidden). The sub-agent prompts are **shared** across profiles as files in `~/.config/opencode/prompts/sdd/` (e.g. `sdd-apply.md`); each entry references the shared file via `{file:~/.config/opencode/prompts/sdd/sdd-apply.md}` — **only the `model` field differs**. The orchestrator prompts are inlined per-profile because they contain model assignment tables and profile-specific sub-agent references `[CERT]`.

**`default` profile** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:158`): `gentle-orchestrator` can be edited but NOT deleted — it always exists when SDD is configured. Naming rules `[CERT]` (`gentle-ai:docs/opencode-profiles.md:162-168`): lowercase slug, hyphens ok, no spaces, `default` reserved, `LOUD` → `loud` (auto-lowercase).

**Per-model reasoning effort** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:44-56`): for models with effort variants (e.g. OpenAI `gpt-5` with `low`/`medium`/`high`/`xhigh`), the picker shows an extra step. The options are populated from a cache `~/.gentle-ai/cache/model-variants.json` written by the `model-variants` plugin the first time OpenCode starts after `gentle-ai sync` and refreshed on each subsequent start.

**Native background subagents** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:19-30`): OpenCode SDD uses native subagents via the `task` permission. The legacy `background-agents.ts` plugin is NO longer installed by default. To opt in to experimental background mode: `export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` before launching OpenCode (gentle-ai does not write process env vars into `opencode.json`).

## 26.6 — Per-phase models in other harnesses `[CERT]`

OpenCode is not the only one with per-phase assignment. The configurator materializes it differently in three more harnesses (see [Block 25] §25.7):

### 26.6.1 — Codex profiles (separate-file) `[CERT]`

gentle-ai writes model-selection profiles as separate files `~/.codex/<name>.config.toml` (Codex >= 0.134.0 separate-file mechanism), selected at runtime via `codex --profile <name>` `[CERT]` (`gentle-ai:docs/agents.md:143-149`):

| Profile | `model_reasoning_effort` | SDD phases `[CERT]` |
|---------|--------------------------|---------------------|
| `sdd-strong` | `xhigh` | propose, design, verify, judge |
| `sdd-mid` | `high` | spec, tasks, apply |
| `sdd-cheap` | `low` | explore, archive, onboard |

### 26.6.2 — Kiro model assignments `[CERT]`

gentle-ai resolves the `model:` field during injection from Kiro model assignments (`auto|opus|sonnet|haiku|minimax|glm|deepseek|qwen`) to Kiro-native model IDs, stamping it into each `~/.kiro/agents/sdd-{phase}.md` at sync time `[CERT]` (`gentle-ai:docs/agents.md:65,83`, `docs/kiro.md:99`).

### 26.6.3 — Pi model assignments `[CERT]`

Owned by `gentle-pi`, not by the installer. Via `/gentleman:models` (alias `/gentle-ai:models`): a Pi-native modal for project/user/built-in agents, prioritizes SDD agents, saves `.pi/gentle-ai/models.json` and applies overrides in `.pi/agents/*.md` or `.pi/settings.json` `[CERT]` (`gentle-ai:docs/agents.md:241`, `docs/pi.md:104-135`).

## 26.7 — Automatic backups `[CERT]`

Every `install`, `sync`, and `upgrade` automatically snapshots the config files `[CERT]` (`gentle-ai:README.md:163`). Properties:

| Property | Behavior `[CERT]` |
|-----------|--------------------------|
| Compression | tar.gz |
| Deduplication | identical configs are NOT re-backed up |
| Auto-prune | keeps the **5 most recent** |
| Pin | via TUI (key `p`) to protect backups from the prune |

Full detail in `docs/rollback.md` `[CERT]` (`gentle-ai:README.md:165`). In the codebase layout, the responsible package is `internal/backup/` (Config snapshot + restore) `[CERT]` (`gentle-ai:docs/architecture.md:21`).

**Mental model** `[INFER]`: the backup is a transactional safeguard around each mutating operation. The dedup avoids noise (unchanged configs do not generate a snapshot), the prune-to-5 bounds the growth, and the pin is the escape hatch to retain an important snapshot outside the rotating window.

## 26.8 — Startup hooks: keeping the skill-registry fresh `[CERT]`

The startup hooks keep the skill-registry fresh for agents that support hooks `[CERT]` (`gentle-ai:README.md:110`):

> *"Startup hooks normally keep the skill registry fresh for agents that support hooks, including **Codex, Claude Code, OpenCode, and Pi through `gentle-pi`**."*

**Pi `-ns` exception** `[CERT]` (`gentle-ai:README.md:110`, `docs/pi.md:150`, `docs/agents.md:238`): if you start Pi with `pi -ns`, the startup skill loading/hooks are **skipped**, so the `gentle-pi` work on `session_start` (asset checks, skill-registry refresh) does not run automatically — you must run the registry refresh manually.

For Pi, the concrete hook is `gentle-pi session_start` `[CERT]` (`gentle-ai:docs/pi.md:139-148`): it copies project-local assets WITHOUT overwriting local edits — `.pi/agents/sdd-*.md`, `.pi/chains/sdd-*.chain.md`, `.pi/gentle-ai/support/strict-tdd.md`, `.pi/gentle-ai/support/strict-tdd-verify.md`. To replace local copies with the package version: `/gentle-ai:install-sdd --force`.

**Implication** `[INFER]`: the skill-registry is an artifact that degrades (new skills, changing project conventions). The hooks keep it fresh without intervention; when the hook does not run (`pi -ns`, harness without hooks), the manual refresh (`gentle-ai skill-registry refresh`) is the fallback. This connects with the Skill Resolver of [Block 22]: the registry the hooks refresh is the source the orchestrator resolves to inject skill paths to sub-agents.

## 26.9 — `state.json` in `~/.gentle-ai/` `[CERT]`

The configurator tracks the installation state. `gentle-ai doctor` reads it as part of the read-only health check, along with tool binaries, Engram reach, and disk space `[CERT]` (`gentle-ai:README.md:112`). In the codebase layout, the responsible package is `internal/state/` (Installation state tracking) `[CERT]` (`gentle-ai:docs/architecture.md:29`).

The `~/.gentle-ai/` directory also hosts `~/.gentle-ai/cache/model-variants.json` (cache of reasoning effort variants, see §26.5.4) `[CERT]` (`gentle-ai:docs/opencode-profiles.md:48`). **The exact `state.json` (schema, fields) is NOT documented in the sources read** `[CERT-a]` — the README mentions it as an object of `doctor` but does not publish its structure; it remains to be verified in the Go code (`internal/state/`).

## 26.10 — Go codebase architecture `[CERT]`

`docs/architecture.md` publishes the layout `[CERT]` (`gentle-ai:docs/architecture.md:9-36`). Packages relevant to configuration:

| Package | Responsibility `[CERT]` |
|---------|---------------------------|
| `cmd/gentle-ai/` | CLI entrypoint |
| `internal/app/` | Command dispatch + runtime wiring |
| `internal/catalog/` | Registry definitions (agents, skills, components) |
| `internal/cli/` | Install flags, validation, orchestration, dry-run |
| `internal/installcmd/` | Per-profile command resolver (brew/apt/pacman/dnf/winget/go install) |
| `internal/pipeline/` | Staged execution + rollback orchestration |
| `internal/backup/` | Config snapshot + restore (see §26.7) |
| `internal/assets/` | Embedded skill files + persona templates |
| `internal/components/` | Per-component install/inject logic: `engram/ sdd/ skills/ mcp/ persona/ theme/ permissions/ gga/` + `filemerge/` (marker-based merge without clobber) |
| `internal/agents/` | Per-agent adapters (config strategy per agent): `claude/ opencode/ gemini/ cursor/ vscode/ codex/ windsurf/ antigravity/` |
| `internal/opencode/` | OpenCode model/config parsing utilities |
| `internal/state/` | Installation state tracking (see §26.9) |
| `internal/update/` | Self-update + upgrade logic |
| `internal/verify/` | Post-apply health checks + reporting |
| `internal/tui/` | Bubbletea TUI (Rose Pine theme) |

**Injection pattern** `[CERT]` (`gentle-ai:docs/architecture.md:24`): `internal/components/filemerge/` does "marker-based file merging (inject without clobbering)" — it is what allows writing gentle-ai sections into shared files (CLAUDE.md, SOUL.md, GEMINI.md) without destroying user content, using markers like `<!-- gentle-ai:sdd-orchestrator -->` (see [Block 25] §25.5, Hermes SOUL.md).

**Coverage note** `[CERT-a]`: the architecture doc lists 8 agent adapters under `internal/agents/` (claude, opencode, gemini, cursor, vscode, codex, windsurf, antigravity) and states "All 8 agent adapters have unit tests" (`gentle-ai:docs/architecture.md:63`). But the Agent Matrix supports 16 harnesses (see [Block 25]) — the newer harnesses (Kilo, Kimi, Kiro, Qwen, OpenClaw, Trae, Pi, Hermes) use adapters/strategies not listed in this layout, probably because the doc was not updated or because they reuse the OpenCode-compatible adapter (Kilo) and generic strategies `[INFER]`.

## 26.11 — Community components and plugins `[CERT]`

The configurator installs selectable **components** (Engram, SDD, skills, MCP, persona, theme, permissions, GGA) `[CERT]` (`gentle-ai:docs/architecture.md:23`, `docs/non-interactive.md:48`). For OpenCode, it offers to register community plugins `[CERT]` (`gentle-ai:README.md:234-237`): `sub-agent-statusline` and `sdd-engram-plugin`. gentle-ai only ensures that `~/.config/opencode/tui.json` exists and adds the package names to the `plugin` array; OpenCode installs/loads those packages on the next start. Once materialized under `~/.config/opencode/node_modules/`, `gentle-ai update` compares the local `package.json` version with the plugin's GitHub releases `[CERT]`.

## 26.12 — Connections

- **[Block 25] — Multi-agent distribution**: this block is the counterpart of [Block 25]. [Block 25] documents WHAT is distributed to each harness and on what delegation mechanism it runs; this block documents the BINARY that distributes it (install/sync/upgrade) and the per-phase model assignment. The `internal/agents/` adapters (§26.10) are what materializes the "config strategy per agent" of [Block 25] §25.5.
- **[Block 3] — Backends + topic keys**: the `internal/components/engram/` component (§26.10) provisions the Engram backend that [Block 3] introduces philosophically. The configurator is what installs/wires Engram (MCP, instructions); [Block 3] describes how the runtime uses it.
- **[Block 15] — Status + native dispatcher**: the native SDD status dispatcher (`gentle-ai sdd-status`/`sdd-continue`) that [Block 15] documents is a command of the SAME binary described here. The `state.json` (§26.9) and `internal/state/` are the tracking substrate that feeds that status.
- **[Block 19] — Persistence contract**: the `--sdd-mode single|multi` assignment (§26.2.2) and the profiles (§26.5) determine which mode the orchestrator runs in, which connects with how the persistence contract resolves `artifact_store.mode` ([Block 19] §19.1).
- **[Block 22] — Skill-resolver + phase-common**: the startup hooks (§26.8) and `gentle-ai skill-registry refresh` keep fresh the registry that the Skill Resolver of [Block 22] consumes. The configurator produces the artifact; the resolver reads it to inject paths to sub-agents.
- **[Block 23] — Strict-TDD**: `/sdd-init` (§26.2.1) detects testing capabilities and activates Strict TDD Mode, whose protocol is documented in [Block 23]. The configurator is the point where that detection is wired.
