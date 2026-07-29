# Block 26 — The `gentle-ai` configurator: install/sync/upgrade, scopes, OpenCode SDD profiles, per-phase models

> **WHAT IT DOCUMENTS**: This block documents the `gentle-ai` configurator binary (Go) that distributes the ecosystem (persistent memory + SDD + skills + MCP + persona) to 16 harnesses: what it IS (an ecosystem configurator, NOT an agent installer), its full command surface (`install`, `uninstall`, `sync`, `restore`, `upgrade`, `doctor`, `skill-registry refresh`, `skill-registry list`, the complete `review` family and 6 legacy compatibility commands, `sdd-status`, `sdd-continue`, `sdd-attempt`, `sdd-verify-validate`, `update`, `version`), the scopes (`global` vs `workspace`), the stable / beta / RDD channels, the RDD (Receipt-Driven Development) conceptual model, the OpenCode SDD Profiles with per-phase model assignment, the Codex and Kiro per-phase profiles, the automatic backup system (tar.gz, dedup, prune, pin), the startup hooks that keep the skill-registry fresh, and the `state.json` in `~/.gentle-ai/`.
> **SCOPE**: The configurator binary and its command/configuration surface. It does NOT redefine the delegation models or the per-harness materialization (see [Block 25]); it does NOT develop the persistence contract or the Engram/OpenSpec backends (see [Block 3] and [Block 19-21]); it does NOT document the native SDD status dispatcher in detail (see [Block 15]); it does NOT document the SEMANTICS of model assignments (which model does which job and why — see [Block 18]); it does NOT document the review lifecycle internals (see the ORCHESTRATOR docs). It covers the configurator command surface and the RDD versioning model, not the orchestrator runtime.
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.
> **SOURCES** (read and verified at v2.2.0):
> - `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md` (348 lines — installed authoritative doc) `[CERT]`
> - `gentle-ai --help` (live CLI output, v2.2.0) `[CERT]`
> - `~/.gentle-ai/state.json` (live state file, direct read) `[CERT]`
> - `gentle-ai review mode status --cwd .` (live read-only query) `[CERT]`
> - `gentle-ai skill-registry list` (live read-only query) `[CERT]`
> - `gentle-ai sdd-attempt status --cwd . --change current` (live read-only query) `[CERT]`
> - Docs cited in the v1.43.2 era (`gentle-ai:docs/opencode-profiles.md`, `docs/architecture.md`, `docs/non-interactive.md`, `docs/agents.md`, `docs/pi.md`, `docs/platforms.md`) are NOT re-verified at v2.2.0 from the installed Cellar (only README.md and the binary are distributed there); claims sourced exclusively from those docs are marked `[CERT-a]`.
> **METHOD**: `[CERT]` = verified by reading a primary v2.2.0 source (installed README, live CLI output, or live files), with citation. `[CERT-a]` = asserted in v1.43.2-era docs, not re-verified against the v2.2.0 binary or installed files. `[INFER]` = deduction — basis stated. `[GAP]` = could not determine — what would settle it stated. `[DRIFTED v1.43.2→v2.2.0]` = was true at v1.43.2, now changed; the old fact is kept so readers of a v1.x artifact still have it.

---

## 26.1 — What it is: an ecosystem configurator, not an installer `[CERT]`

The README opens with the explicit negative definition `[CERT]` (`README.md:33`):

> *"Gentle-AI is NOT an AI agent installer. Most agents are easy to install. It is an **ecosystem configurator** that equips the AI coding agent(s) you already use with persistent memory, Spec-Driven Development (SDD), curated skills, MCP servers, model routing, a teaching-oriented persona, and bounded native review."*

The value contrast `[CERT]` (`README.md:35-37`): **Before** — "I installed Claude Code / OpenCode / Cursor but it's just a chatbot that writes code". **After** — the agent now has memory, skills, workflow, MCP tools, and a persona that teaches. The configurator **supersedes** Agent Teams Lite (archived); everything from ATL is included with better installation, automatic updates, and persistent memory `[CERT]` (`README.md:62`).

**Key point** `[INFER]`: the "configurator, not installer" distinction is structural — gentle-ai writes configuration files (prompts, skills, SDD agents, MCP, persona) into the config dir of each already-installed harness. Most harnesses install themselves; gentle-ai SUPERCHARGES them. This explains why Hermes/Kiro/Trae/OpenClaw/Pi are detect-only or manual-install: the configurator configures what already exists.

## 26.2 — CLI commands `[CERT]`

Full command surface from `gentle-ai --help` `[CERT]`. Organized by purpose:

### 26.2.1 — Core lifecycle commands

| Command | What it does | Source `[CERT]` |
|---------|----------|------------------|
| `gentle-ai install` | Writes agent-scoped files to each selected agent's global config dir | `--help`, `README.md:139` |
| `gentle-ai install --scope=workspace` | Isolates the stack to a project: writes to the current project root | `--help`, `README.md:142` |
| `gentle-ai install --agent <id>` | Installs/configures a specific harness (e.g. `--agent pi`) | `--help` |
| `gentle-ai uninstall` | Removes Gentle AI managed files from this machine | `--help` |
| `gentle-ai sync` | Re-applies/updates the config; entry point for profiles, migrations, backups | `--help` |
| `gentle-ai upgrade` | Self-update + binary and asset upgrade; respects the active channel | `--help`, `README.md:199-204` |
| `gentle-ai restore` | Restores a config backup (see §26.7) | `--help` |
| `gentle-ai update` | Checks for available updates to managed/community tools | `--help` |
| `gentle-ai doctor` | Read-only health check (tool binaries, `state.json`, Engram reach, disk space) | `--help`, `README.md:114` |
| `gentle-ai version` | Prints version | `--help` |
| `gentle-ai` (no args) | Launches the Bubbletea TUI (welcome screen, OpenCode SDD Profiles, etc.) | `README.md:267` |

### 26.2.2 — Skill registry and SDD status commands

| Command | What it does | Source `[CERT]` |
|---------|----------|------------------|
| `gentle-ai skill-registry refresh` | Scans installed skills and project conventions; rebuilds `.atl/skill-registry.md` with cache-hit fast path | `--help` |
| `gentle-ai skill-registry list` | Lists installed skills (name, scope, path); not shown in main `--help` but runs successfully | verified by running |
| `gentle-ai sdd-status [change]` | Prints native SDD phase status for orchestrators | `--help` |
| `gentle-ai sdd-continue [change]` | Prints native SDD dispatcher routing output | `--help` |
| `gentle-ai sdd-attempt <status\|begin\|finish\|reset> --cwd <repo> --change <change>` | Reads or mutates the artifact-store-agnostic runtime-attempt ledger. `status` is read-only. | `--help`, verified `status` subcommand |
| `gentle-ai sdd-verify-validate --input <path\|-> --requirements <n> --scenarios <n>` | Validates exact verification-report bytes without persistence | `--help` |

### 26.2.3 — Review command family (RDD) `[CERT]`

The RDD review surface introduced in v1.47.0. Semantics of each lens and the review lifecycle are owned by the ORCHESTRATOR docs; this block documents the command surface only.

> **The top-level `--help` under-reports this family by 3× `[CERT]`.** `gentle-ai --help` lists **7**
> review subcommands. `gentle-ai review --help` lists **21**:
>
> `capabilities · start · finalize · validate · status · repair · invalidate · abandon · recover ·
> retry-final-verification · reclaim · inspect-authority · reconcile-authority ·
> reconcile-authority-batch · dispose-result · reopen-results · quarantine-legacy ·
> quarantine-legacy-fix-scope · repair-legacy-alias · schema · bind-sdd`
>
> The **sixteen** absent from the top-level listing are: `capabilities`, `invalidate`, `abandon`,
> `recover`, `retry-final-verification`, `reclaim`, `inspect-authority`, `reconcile-authority`,
> `reconcile-authority-batch`, `dispose-result`, `reopen-results`, `quarantine-legacy`,
> `quarantine-legacy-fix-scope`, `repair-legacy-alias`, `schema`, `bind-sdd`. Verified 2026-07-28 by
> diffing both help outputs. Their shape — recover, reclaim, quarantine, repair-legacy, reopen — reads
> as an authority-recovery and legacy-migration toolkit `[INFER]`, which is consistent with a subsystem
> upstream calls unstable. `[GAP]`: individual semantics not established; each has its own
> `--help` (the `review` family is the only one with real per-subcommand help), but reading 16 of them
> was out of scope for this refresh.
>
> **Methodological note**: the same trap caught `skill-registry list`, which also works but is absent
> from `gentle-ai --help` (§26.2.2). Do not treat a top-level help listing as the command inventory of
> this binary — descend into each family's own `--help`.

**Primary review commands** (the 7 the top-level help advertises):

| Command | What it does |
|---------|----------|
| `gentle-ai review start [--cwd <repo>] [--base-ref <ref>] [--focus <risk\|resilience\|readability\|reliability>] [--projection staged]` | Starts a new review transaction; freezes the candidate |
| `gentle-ai review capture-result --lineage <id> --target <id> --lens <lens> --order <n> --input <review.json>` | Admits one reviewer result; every selected lens needs one |
| `gentle-ai review finalize [--cwd <repo>] [--captured-results] [--evidence <path>]` | Closes the review transaction and issues a receipt |
| `gentle-ai review validate --gate <gate> [--cwd <repo>]` | Validates an existing receipt at a delivery gate; ordinary authority is compact state plus receipt |
| `gentle-ai review status [--cwd <repo>]` | Read-only inventory of compact-v2 and shipped legacy-v1 authority |
| `gentle-ai review repair --preflight [--cwd <repo>]` | Classifies the complete authority inventory before provider-owned repair |
| `gentle-ai review mode <enable\|disable\|status> [--cwd <repo>] [--scope <global\|clone>]` | User-owned kill switch (see §26.4.3). `status` is read-only, never mutates |

**Legacy compatibility commands** (read-only or rejected surfaces, kept for consumers of the old v1 protocol):

| Command | Status |
|---------|--------|
| `review-start --cwd <repo> --lineage <id> --policy-file <path>` | Read-only legacy v1 surface; rejects new v1 authority, directs to `review start` |
| `review-step --cwd <repo> --lineage <id> --operation <op> --input <json>` | Read-only; rejects mutation, directs to `review finalize` |
| `review-resume --cwd <repo> --lineage <id>` | Reads shipped v1 authority without mutation |
| `review-bundle-export --cwd <repo> --lineage <id> --out <path>` | Exports compact current-state transport or legacy v1 chain transport |
| `review-bundle-import --cwd <repo> --bundle <path> [--receipt <path> --request <path>]` | Imports compact transport; receipt/request extras for legacy v1 only |
| `review-validate --cwd <repo> --receipt <path> (--request <path> \| --lineage <id> --gate <gate>)` | Validates legacy v1 authority; native mode needs lineage/gate and derives authority |

### 26.2.4 — Project-level setup post-install `[CERT]`

After configuring agents, two commands register the project context `[CERT]` (`README.md:107-112`):

| Command | What it does | When to re-run `[CERT]` |
|---------|----------|----------------------------|
| `/sdd-init` | Detects stack, testing capabilities, activates Strict TDD Mode if available | When the project adds/removes test frameworks, or first time in a new project |
| `gentle-ai skill-registry refresh` | Scans installed skills and conventions, builds the registry | After installing/removing skills, or first time in a new project |

Neither is required for basic use: the SDD orchestrator runs `/sdd-init` automatically if it detects there is no context `[CERT]` (`README.md:112`).

### 26.2.5 — Non-interactive mode (CI / scripts) `[CERT-a]`

`go run ./cmd/gentle-ai install [flags]` supports flags for reproducible setup `[CERT-a]` (`gentle-ai:docs/non-interactive.md:7-21`): `--agent`/`--agents` (repeatable CSV), `--component`/`--components`, `--skill`/`--skills`, `--persona`, `--preset`, `--sdd-mode` (`single`|`multi`), `--scope` (`global`|`workspace`), `--dry-run` (renders the plan without executing). Errors: unknown options fail fast with validation; an unsupported platform exits before any install work `[CERT-a]` (`gentle-ai:docs/non-interactive.md:60-62`).

## 26.3 — Scopes: global vs workspace `[CERT]`

By default, `gentle-ai install` writes agent-scoped files to each selected agent's **global config dir** `[CERT]` (`README.md:139`). To isolate the Gentleman stack to a project:

```bash
gentle-ai install --scope=workspace
```

**Workspace scope is NOT Claude-only** `[CERT]` (`README.md:142-145`): it applies to the selected agents for agent-scoped files — system prompts, skills, SDD agents, and persona files — written to the project root (`./`). The global-only integrations (package installs, settings the agent only reads from its global config) **remain global by design** `[CERT-a]` (`gentle-ai:docs/non-interactive.md:28`).

Equivalent environment variable `[CERT-a]` (`gentle-ai:docs/non-interactive.md:24-26`): `GENTLE_AI_INSTALL_SCOPE` with values `global` (default) | `workspace`. Useful in CI; equivalent to `--scope`.

**Mental model** `[INFER]`: scope is a decision about WHERE the agent-scoped files live (global config dir vs project root), not about WHAT is installed. The global-only stuff (packages, MCP the agent reads from its global config) ignores scope because the harness would not read it from the project.

## 26.4 — Channels, version policy, and RDD

### 26.4.1 — Stable and beta channels `[CERT]`

The installer supports multiple channels `[CERT]` (`README.md:119-184`):

**Stable** — via Homebrew (macOS/Linux) or `go install` (all platforms). Go minimum version:

> `[DRIFTED v1.43.2→v2.2.0]` — **v1.43.2** documented `Go 1.24+` as required. **v2.2.0** requires **Go 1.25.10+** `[CERT]` (`README.md:13` badge: `Go-1.25.10+`; `README.md:129`).

**Scoop (Windows)**:

> `[DRIFTED v1.43.2→v2.2.0]` — **v1.43.2** described Scoop as a supported Windows channel. **v2.2.0** README states: *"Scoop (Windows) — temporarily unavailable while official Windows binary distribution is held for public-trust Authenticode signing. Use the Windows `go install` command above."* `[CERT]` (`README.md:137`). Windows source builds and CI/runtime tests remain supported; Windows installation and upgrades require Go 1.25.10+ and fail closed to source-install guidance, never downloading an unsigned executable `[CERT]` (`README.md:101-102`).

**Go module path change** `[CERT]` (`README.md:97-98`, `131-135`): v2.x releases moved to the `/v2` import path (Go module major-version convention). The v1.46.0 stable pin uses the unsuffixed path; v2.x installs use the suffixed path:
```bash
# Stable pre-RDD pin (v1.46.0 — unsuffixed, predates /v2)
go install github.com/gentleman-programming/gentle-ai/cmd/gentle-ai@v1.46.0

# v2.x releases (including latest RDD build)
go install github.com/gentleman-programming/gentle-ai/v2/cmd/gentle-ai@latest
```

**Beta channel** — builds from `main`; requires Go 1.25.10+ `[CERT]` (`README.md:147-155`):
```bash
# macOS/Linux beta
curl -fsSL .../install.sh | bash -s -- --channel beta

# Windows beta (PowerShell) — go install, requires Go 1.25.10+
$env:GENTLE_AI_CHANNEL="beta"; go install github.com/gentleman-programming/gentle-ai/v2/cmd/gentle-ai@main
```

Supported platforms `[CERT-a]` (`gentle-ai:docs/platforms.md:7-13`): macOS (Homebrew), Ubuntu/Debian (apt), Arch (pacman), Fedora/RHEL (dnf), Windows 10/11 (Go install, Scoop temporarily unavailable). Linux derivatives detected via `ID_LIKE` in `/etc/os-release` `[CERT-a]` (`gentle-ai:docs/platforms.md:15`).

### 26.4.2 — RDD version policy `[CERT]`

Receipt-Driven Development (RDD) started in v1.47.0 on 2026-07-10 `[CERT]` (`README.md:158-162`). Every release from v1.47.0 onward is part of the **unstable RDD development line**. The last stable pre-RDD release is **v1.46.0**. The README states explicitly:

> *"RDD is unstable. Every release from `v1.47.0` onward is part of the RDD development line and may change while remaining issues are fixed."* `[CERT]` (`README.md:21-28`)

Channel guide:
- `@v1.46.0` — stable, no RDD
- `@latest` — latest released RDD build (unstable)
- `@main` — unreleased RDD development changes only

The managed installer tracks the channel's latest version and does not accept an arbitrary release pin; use `go install` for reproducibility `[CERT]` (`README.md:184`).

**Known open limitations of the RDD line** `[CERT]` (`README.md:218-219`): Two limitations apply while review mode is disabled: (1) the SDD pre-verify status path can still require review; (2) the native archive gate defers correctly, but the `sdd-archive` skill's own contract still requires `reviewGate.result: allow`, so the agent-facing rule blocks where the product no longer does. These are flagged in the README as known open.

### 26.4.3 — Review mode: user-owned kill switch `[CERT]`

Review-driven development is independently controllable by the user `[CERT]` (`README.md:209-218`):

```bash
gentle-ai review mode status --cwd .    # read-only; current mode: on (decided by default)
gentle-ai review mode disable --cwd .
gentle-ai review mode enable --cwd .
```

Default mode at v2.2.0: **on (decided by default)** `[CERT]` (verified by running `gentle-ai review mode status`). Rules:
- `status` is read-only and changes nothing.
- Any global or clone-local disabled source wins; a clone can opt out with `--scope clone` but cannot force review on.
- `disable` applies to future candidates; existing receipts remain authoritative.
- When disabled, native review gates report `disabled/unmanaged` and defer to ordinary repository policy without fabricating approval.

### 26.4.4 — Release verification `[CERT]`

Official macOS and Linux release archives require an authenticated `checksums.txt` verified with a Minisign signature before replacing the installed binary `[CERT]` (`README.md:222-234`). Archives are capped at 128 MiB. Missing, oversized, malformed, untrusted, or placeholder key material fails closed. Windows archives and Scoop are omitted until publicly trusted RSA Authenticode signing is provisioned `[CERT]` (`README.md:234`).

## 26.5 — OpenCode SDD Profiles: per-phase model assignment `[CERT]`

The configurator's flagship feature: assigning **different models to different SDD phases** — a powerful model for design, a fast one for implementation, a cheap one for exploration `[CERT]` (`README.md:259-261`). OpenCode uses `gentle-orchestrator` as the base SDD conductor; named profiles generate `sdd-orchestrator-{name}` entries `[CERT]`.

### 26.5.1 — Two profile strategies `[CERT-a]`

`docs/opencode-profiles.md` defines two modes `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:11-12,179-182`):

1. **`generated-multi`** (Generated multi-profile mode) — the classic flow. Base = `gentle-orchestrator`. Each named profile generates its `sdd-orchestrator-{name}` + 10 suffixed phase sub-agents in `opencode.json`; cycled with **Tab** inside OpenCode.
2. **`external-single-active`** (External single-active mode) — for community tools that keep profile files OUTSIDE `opencode.json` and activate one runtime profile at a time. Auto-detected if files exist under `~/.config/opencode/profiles/*.json` `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:102-108`).

Manual strategy override `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:114-122`):
```bash
gentle-ai sync --agent opencode --sdd-profile-strategy external-single-active
gentle-ai sync --agent opencode --sdd-profile-strategy generated-multi
```

### 26.5.2 — Profiles CLI `[CERT]`

Create/configure profiles during sync `[CERT]` (`README.md:263-268`):

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

`--profile name:provider/model` sets all phases; `--profile-phase name:phase:provider/model` overrides a single phase `[CERT]`. Also via TUI: `gentle-ai` → "OpenCode SDD Profiles" → Create `[CERT]` (`README.md:267`).

### 26.5.3 — Key names table `[CERT]`

Agent keys in `opencode.json` `[CERT]` (`README.md:272-276`):

| Key | Meaning | Rename by hand? |
|-------|-------------|---------------------|
| `gentle-orchestrator` | OpenCode's canonical base SDD conductor. All `/sdd-*` point here by default | No |
| `sdd-orchestrator` | Legacy key of the base conductor. Sync migrates it to `gentle-orchestrator` | No; let sync migrate |
| `sdd-orchestrator-{name}` | Named profile conductor (e.g. `sdd-orchestrator-cheap`) | No; use TUI or CLI |
| `sdd-{phase}` | Default sub-agent of a phase (e.g. `sdd-apply`) | No |
| `sdd-{phase}-{name}` | Named profile sub-agent (e.g. `sdd-apply-cheap`) | No |

### 26.5.4 — How it works internally `[CERT-a]`

In `generated-multi`, each named profile generates **11 entries** in `opencode.json` `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:175-177`): one orchestrator (`sdd-orchestrator-{name}`, mode `primary`) + 10 phase sub-agents (`sdd-{phase}-{name}`, mode `subagent`, hidden). The sub-agent prompts are **shared** across profiles as files in `~/.config/opencode/prompts/sdd/`; each entry references the shared file via `{file:~/.config/opencode/prompts/sdd/sdd-apply.md}` — **only the `model` field differs**. The orchestrator prompts are inlined per-profile because they contain model assignment tables and profile-specific sub-agent references `[CERT-a]`.

**`default` profile** `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:158`): `gentle-orchestrator` can be edited but NOT deleted — it always exists when SDD is configured. Naming rules `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:162-168`): lowercase slug, hyphens ok, no spaces, `default` reserved, `LOUD` → `loud` (auto-lowercase).

**Per-model reasoning effort** `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:44-56`): for models with effort variants (e.g. OpenAI models with `low`/`medium`/`high`/`xhigh`), the picker shows an extra step. The options are populated from a cache `~/.gentle-ai/cache/model-variants.json` written by the `model-variants` plugin the first time OpenCode starts after `gentle-ai sync` and refreshed on each subsequent start.

**Native background subagents** `[CERT-a]` (`gentle-ai:docs/opencode-profiles.md:19-30`): OpenCode SDD uses native subagents via the `task` permission. The legacy `background-agents.ts` plugin is NO longer installed by default. To opt in to experimental background mode: `export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` before launching OpenCode.

## 26.6 — Per-phase models in other harnesses `[CERT-a]`

OpenCode is not the only one with per-phase assignment. The configurator materializes it differently in three more harnesses (see [Block 25] §25.7):

### 26.6.1 — Codex profiles (separate-file) `[CERT-a]`

gentle-ai writes model-selection profiles as separate files `~/.codex/<name>.config.toml` (Codex >= 0.134.0 separate-file mechanism), selected at runtime via `codex --profile <name>` `[CERT-a]` (`gentle-ai:docs/agents.md:143-149`):

| Profile | `model_reasoning_effort` | SDD phases `[CERT-a]` |
|---------|--------------------------|---------------------|
| `sdd-strong` | `xhigh` | propose, design, verify, judge |
| `sdd-mid` | `high` | spec, tasks, apply |
| `sdd-cheap` | `low` | explore, archive, onboard |

### 26.6.2 — Kiro model assignments `[CERT-a]`

gentle-ai resolves the `model:` field during injection from Kiro model assignments (`auto|opus|sonnet|haiku|minimax|glm|deepseek|qwen`) to Kiro-native model IDs, stamping it into each `~/.kiro/agents/sdd-{phase}.md` at sync time `[CERT-a]` (`gentle-ai:docs/agents.md:65,83`).

### 26.6.3 — Pi model assignments `[CERT-a]`

Owned by `gentle-pi`, not by the installer. Via `/gentleman:models` (alias `/gentle-ai:models`): a Pi-native modal for project/user/built-in agents, prioritizes SDD agents, saves `.pi/gentle-ai/models.json` and applies overrides in `.pi/agents/*.md` or `.pi/settings.json` `[CERT-a]` (`gentle-ai:docs/agents.md:241`, `docs/pi.md:104-135`).

## 26.7 — Automatic backups `[CERT]`

Every `install`, `sync`, and `upgrade` automatically snapshots the config files `[CERT]` (`README.md:248`). Properties:

| Property | Behavior `[CERT]` |
|-----------|--------------------------|
| Compression | tar.gz |
| Deduplication | identical configs are NOT re-backed up |
| Auto-prune | keeps the **5 most recent** |
| Pin | via TUI (key `p`) to protect backups from the prune |

The `restore` command restores a config backup `[CERT]` (`--help`). Full detail in `docs/rollback.md` `[CERT]` (`README.md:252`). In the codebase layout, the responsible package is `internal/backup/` (Config snapshot + restore) `[CERT-a]` (`gentle-ai:docs/architecture.md:21`).

**Mental model** `[INFER]`: the backup is a transactional safeguard around each mutating operation. The dedup avoids noise (unchanged configs do not generate a snapshot), the prune-to-5 bounds the growth, and the pin is the escape hatch to retain an important snapshot outside the rotating window.

## 26.8 — Startup hooks: keeping the skill-registry fresh `[CERT]`

The startup hooks keep the skill-registry fresh for agents that support hooks `[CERT]` (`README.md:112`):

> *"Startup hooks normally keep the skill registry fresh for agents that support hooks, including **Codex, Claude Code, OpenCode, and Pi through `gentle-pi`**."*

**Pi `-ns` exception** `[CERT]` (`README.md:112-113`): if you start Pi with `pi -ns`, the startup skill loading/hooks are **skipped**, so the `gentle-pi` work on `session_start` does not run automatically — run the registry refresh manually.

For Pi, the concrete hook is `gentle-pi session_start` `[CERT-a]` (`gentle-ai:docs/pi.md:139-148`): it copies project-local assets WITHOUT overwriting local edits. To replace local copies with the package version: `/gentle-ai:install-sdd --force`.

**Implication** `[INFER]`: the skill-registry is an artifact that degrades (new skills, changing project conventions). The hooks keep it fresh without intervention; when the hook does not run (`pi -ns`, harness without hooks), `gentle-ai skill-registry refresh` is the fallback. This connects with the Skill Resolver of [Block 22]: the registry the hooks refresh is the source the orchestrator resolves to inject skill paths to sub-agents.

## 26.9 — `state.json` in `~/.gentle-ai/` `[CERT]`

The configurator tracks the installation state. `gentle-ai doctor` reads it as part of the read-only health check, along with tool binaries, Engram reach, and disk space `[CERT]` (`README.md:114`). The `~/.gentle-ai/` directory structure at v2.2.0 `[CERT]` (verified by `ls`):

```
~/.gentle-ai/
  state.json           — configurator state (see [Block 27] for the full schema)
  backups/             — config snapshots (see §26.7)
  cache/
    model-variants.json  — reasoning effort variants cache (see §26.5.4)
  review-contexts/
    v1/                — per-review repository context records (see [Block 27] §27.8)
```

The `~/.gentle-ai/review-contexts/v1/` directory is new in the RDD era and is NOT documented in the v1.43.2 corpus `[CERT]` (verified by `ls`). Its purpose and schema are documented in [Block 27] §27.8. In the codebase layout, the state tracking package is `internal/state/` `[CERT-a]` (`gentle-ai:docs/architecture.md:29`).

## 26.10 — Go codebase architecture `[CERT-a]`

`docs/architecture.md` publishes the layout `[CERT-a]` (`gentle-ai:docs/architecture.md:9-36`). Packages relevant to configuration:

| Package | Responsibility `[CERT-a]` |
|---------|---------------------------|
| `cmd/gentle-ai/` | CLI entrypoint |
| `internal/app/` | Command dispatch + runtime wiring |
| `internal/catalog/` | Registry definitions (agents, skills, components) |
| `internal/cli/` | Install flags, validation, orchestration, dry-run |
| `internal/installcmd/` | Per-profile command resolver (brew/apt/pacman/dnf/winget/go install) |
| `internal/pipeline/` | Staged execution + rollback orchestration |
| `internal/backup/` | Config snapshot + restore |
| `internal/assets/` | Embedded skill files + persona templates |
| `internal/components/` | Per-component install/inject logic: `engram/ sdd/ skills/ mcp/ persona/ theme/ permissions/ gga/` + `filemerge/` (marker-based merge without clobber) |
| `internal/agents/` | Per-agent adapters (config strategy per agent): 16 adapters as of v2.2.0 (see [Block 27]) |
| `internal/opencode/` | OpenCode model/config parsing utilities |
| `internal/state/` | Installation state tracking |
| `internal/update/` | Self-update + upgrade logic |
| `internal/verify/` | Post-apply health checks + reporting |
| `internal/tui/` | Bubbletea TUI (Rose Pine theme) |

**Note** `[GAP]`: the `docs/architecture.md` cited here was verified at v1.43.2. The RDD era likely added packages (e.g. for the review command family). The layout above may be incomplete for v2.2.0. Running `ls` on the Go source (not distributed in the Cellar) would settle this.

**Injection pattern** `[CERT-a]` (`gentle-ai:docs/architecture.md:24`): `internal/components/filemerge/` does "marker-based file merging (inject without clobbering)" — it is what allows writing gentle-ai sections into shared files (CLAUDE.md, SOUL.md, GEMINI.md) without destroying user content, using markers like `<!-- gentle-ai:sdd-orchestrator -->` (see [Block 25] §25.5).

## 26.11 — Community components and plugins `[CERT]`

The configurator installs selectable **components** (Engram, SDD, skills, MCP, persona, theme, permissions, GGA) `[CERT-a]` (`gentle-ai:docs/architecture.md:23`). For OpenCode, it offers to register community plugins `[CERT]` (`README.md:319-323`): `sub-agent-statusline` and `sdd-engram-plugin`. gentle-ai only ensures that `~/.config/opencode/tui.json` exists and adds the package names to the `plugin` array; OpenCode installs/loads those packages on the next start. Once materialized under `~/.config/opencode/node_modules/`, `gentle-ai update` compares the local `package.json` version with the plugin's GitHub releases `[CERT]`.

## 26.12 — Connections

- **[Block 25] — Multi-agent distribution**: this block is the counterpart of [Block 25]. [Block 25] documents WHAT is distributed to each harness and on what delegation mechanism it runs; this block documents the BINARY that distributes it (install/sync/upgrade) and the per-phase model assignment. The `internal/agents/` adapters (§26.10) are what materializes the "config strategy per agent" of [Block 25] §25.5.
- **[Block 3] — Backends + topic keys**: the `internal/components/engram/` component provisions the Engram backend that [Block 3] introduces philosophically. The configurator is what installs/wires Engram (MCP, instructions); [Block 3] describes how the runtime uses it.
- **[Block 15] — Status + native dispatcher**: the native SDD status dispatcher (`gentle-ai sdd-status`/`sdd-continue`) that [Block 15] documents is a command of the SAME binary described here. The `state.json` (§26.9) and `internal/state/` are the tracking substrate that feeds that status.
- **[Block 18] — Model assignment semantics**: the `--profile` / `--profile-phase` flags (§26.5.2) and the `*ModelAssignments` maps of `state.json` are the MECHANISM; [Block 18] documents the semantics of which model does which job and why. The RDD review model assignments (`review-readability`, `review-refuter`, `review-reliability`, `review-resilience`, `review-risk`) likewise have their semantics in [Block 18].
- **[Block 19] — Persistence contract**: the `--sdd-mode single|multi` assignment (§26.2.5) and the profiles (§26.5) determine which mode the orchestrator runs in, which connects with how the persistence contract resolves `artifact_store.mode` ([Block 19] §19.1).
- **[Block 22] — Skill-resolver + phase-common**: the startup hooks (§26.8) and `gentle-ai skill-registry refresh` keep fresh the registry that the Skill Resolver of [Block 22] consumes. The configurator produces the artifact; the resolver reads it to inject paths to sub-agents.
- **[Block 23] — Strict-TDD**: `/sdd-init` (§26.2.4) detects testing capabilities and activates Strict TDD Mode, whose protocol is documented in [Block 23]. The configurator is the point where that detection is wired.
- **[Block 27] — Internal architecture**: this block's §26.9 references `state.json` as a black box; [Block 27] opens the full schema (InstallState struct, all fields including v2.2.0 additions, the review-contexts directory).
