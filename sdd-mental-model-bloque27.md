# Bloque 27 — Arquitectura interna del configurador: `state.json` y los adapters por harness

> **QUÉ DOCUMENTA**: Este bloque cierra los dos gaps que solo se resuelven leyendo el código fuente Go de `gentle-ai` en `internal/`: (1) el esquema REAL del archivo de estado `~/.gentle-ai/state.json` —struct `InstallState`, campos, tipos, tags JSON y semántica de back-compat—; y (2) la capa de adapters por harness —la interfaz `Adapter`, el `Registry`/`factory`, y cómo cada uno de los 16 adapters materializa la config SDD/ecosistema para su agente (config dir, archivo de system prompt, estrategia de inyección de prompt, estrategia MCP, soporte de sub-agentes)—.
> **ALCANCE**: La arquitectura INTERNA del binario configurador (paquetes `internal/state` e `internal/agents`). NO redefine la superficie de comandos `install/sync/upgrade` (ver [Bloque 26]); NO redesarrolla los modelos de delegación Full/Solo-agent/Detect-only por harness (ver [Bloque 25]); NO documenta el dispatcher nativo de status SDD (ver [Bloque 15]) ni los backends de persistencia Engram/OpenSpec (ver [Bloque 3]). Cubre el ESQUEMA y los ADAPTERS, no el runtime del orquestador.
> **FUENTES** (leídas y verificadas vía `gh api` sobre `Gentleman-Programming/gentle-ai`, rama `main`):
> - `gentle-ai:internal/state/state.go` (struct `InstallState`, `Read`/`Write`/`MergeAgents`/`Path`)
> - `gentle-ai:internal/agents/interface.go` (interfaz `Adapter`)
> - `gentle-ai:internal/agents/registry.go` (`Registry`, `Register`, `SupportedAgents`)
> - `gentle-ai:internal/agents/factory.go` (`defaultAgentIDs`, `NewAdapter`, `NewDefaultRegistry`, `NewMVPRegistry`)
> - `gentle-ai:internal/model/types.go` (constantes `AgentID`, `SystemPromptStrategy`, `MCPStrategy`, `SupportTier`)
> - `gentle-ai:internal/agents/{claude,opencode,codex,gemini,cursor,vscode,antigravity,windsurf,kimi,qwen,kiro,openclaw,pi,trae,hermes,kilocode}/adapter.go`
> - `gentle-ai:docs/architecture.md` (layout del codebase — fuente del gap "8 adapters")
> - `gentle-ai:README.md` (tabla "15 Supported Agents")
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo el `.go` del repo, con `gentle-ai:<ruta>:<símbolo>`. `[CERT-a]` = afirmado por docs/README pero no confirmado en el código. `[INFER]` = deducción propia, no literal en la fuente.

---

## 27.1 — El paquete `state`: qué es `state.json` y dónde vive `[CERT]`

El estado persistido del configurador vive en un único archivo JSON. La ruta es construida por `state.Path` `[CERT]` (`gentle-ai:internal/state/state.go:Path`):

```go
const stateDir = ".gentle-ai"
const stateFile = "state.json"

func Path(homeDir string) string {
    return filepath.Join(homeDir, stateDir, stateFile)
}
```

Es decir, `~/.gentle-ai/state.json` `[CERT]`. El ciclo de vida es trivial y sin BD `[CERT]`:

| Función | Qué hace | Cita `[CERT]` |
|---------|----------|----------------|
| `Read(homeDir)` | `os.ReadFile` + `json.Unmarshal` en `InstallState`; error si no existe o no decodifica | `state.go:Read` |
| `Write(homeDir, s)` | `os.MkdirAll(.gentle-ai, 0o755)` + `json.MarshalIndent("  ")` + `os.WriteFile(…, 0o644)` con `\n` final | `state.go:Write` |
| `MergeAgents(existing, newAgents)` | Devuelve un `InstallState` nuevo con `InstalledAgents` deduplicados; preserva TODOS los demás campos de `existing` | `state.go:MergeAgents` |

**Punto clave** `[CERT]`: `MergeAgents` es la operación correcta para un install incremental `--agent X` —carga el estado, mergea, reescribe—; el install completo por TUI usa `Write` directo porque "the TUI selection is the source of truth" (comentario en `state.go:MergeAgents`). El archivo se escribe con `MarshalIndent` (indentado de 2 espacios) y permisos `0o644` `[CERT]`.

## 27.2 — Esquema real de `state.json`: el struct `InstallState` `[CERT]`

Todo el contenido de `state.json` es la serialización del struct `InstallState` `[CERT]` (`gentle-ai:internal/state/state.go:InstallState`). Cada campo salvo `installed_agents` lleva `,omitempty` —es decir, los state files viejos que no tienen un campo siguen siendo válidos; el código documenta explícitamente la back-compat por campo.

| Campo Go | Tag JSON | Tipo | Propósito | Cita `[CERT]` |
|----------|----------|------|-----------|----------------|
| `InstalledAgents` | `installed_agents` | `[]string` | Lista de harnesses instalados (AgentIDs como `"claude-code"`, `"opencode"`). Único campo SIN `omitempty` | `state.go:InstallState` |
| `ClaudeModelAssignments` | `claude_model_assignments` | `map[string]string` | Mapea fase SDD (`"sdd-explore"`) → alias de modelo Claude (`"fable"`/`"opus"`/`"sonnet"`/`"haiku"`). Preservado para que `sync` no caiga al preset "balanced" | `state.go` |
| `ClaudePhaseAssignments` | `claude_phase_assignments` | `map[string]ClaudePhaseAssignmentState` | Mapea fase SDD → `{model, effort}`. **Supersede** a `ClaudeModelAssignments` manteniendo back-compat | `state.go` |
| `KiroModelAssignments` | `kiro_model_assignments` | `map[string]string` | Fase SDD → alias de modelo nativo Kiro | `state.go` |
| `CodexModelAssignments` | `codexModelAssignments` | `map[string]string` | Fase SDD → `reasoning_effort` de Codex (`low\|medium\|high\|xhigh`) | `state.go` |
| `CodexCarrilModelAssignments` | `codexCarrilModelAssignments` | `map[string]string` | Perfil de carril (`sdd-strong\|sdd-mid\|sdd-cheap`) → model id OpenAI (`"gpt-5.5"`). Vacío = resuelve a `DefaultCarrilModels` en runtime | `state.go` |
| `CodexPhaseModelAssignments` | `codexPhaseModelAssignments` | `map[string]string` | Las 13 fases SDD → model id por fase (override del nivel carril). `nil` = no usa per-phase custom | `state.go` |
| `ModelAssignments` | `model_assignments` | `map[string]ModelAssignmentState` | Sub-agente → par provider/model (estilo OpenCode) | `state.go` |
| `Persona` | `persona` | `string` | Persona instalada (`"gentleman"`/`"neutral"`/`"custom"`). Vacío → fallback a `PersonaGentleman` | `state.go` |
| `LastUpdateCheck` | `last_update_check` | `*time.Time` | Último check remoto OK; gate de cooldown (`UpdateCheckTTL = 6h`). `nil` = nunca chequeado | `state.go` |
| `PendingSync` | `pending_sync` | `bool` | `true` cuando un self-upgrade terminó y falta correr `sync` en el próximo launch; idempotente ante fallo | `state.go` |

Structs anidados `[CERT]` (`gentle-ai:internal/state/state.go`):

- `ModelAssignmentState{ ProviderID string \`json:"provider_id"\`; ModelID string \`json:"model_id"\`; Effort string \`json:"effort,omitempty"\` }` — espejo JSON de `model.ModelAssignment`, vive en `state` para evitar import cycle.
- `ClaudePhaseAssignmentState{ Model string \`json:"model"\`; Effort string \`json:"effort,omitempty"\` }` — `Effort` vacío = default de Claude Code.

**Observación clave** `[INFER]`: `state.json` NO almacena tareas SDD, specs ni progreso de cambios. Es estado del CONFIGURADOR (qué instalé, con qué persona, qué modelo por fase, cuándo chequeé updates), no estado de los cambios SDD. Eso confirma la separación de [Bloque 3]: los artefactos SDD viven en Engram/OpenSpec, NO en `~/.gentle-ai/state.json`. La granularidad per-fase del estado (Claude/Kiro/Codex con mapas distintos) es lo que permite a `sync` regenerar la config de cada harness preservando las decisiones de modelo del usuario.

## 27.3 — La interfaz `Adapter`: la abstracción central por harness `[CERT]`

El comentario de cabecera de la interfaz lo dice literal `[CERT]` (`gentle-ai:internal/agents/interface.go`):

> *"Adapter is the core abstraction for AI agent integration. Components use adapter methods instead of switch statements on AgentID, making it trivial to add new agents without modifying component code."*

Es decir: los componentes (`internal/components/{sdd,skills,mcp,persona,…}`) NO hacen `switch agent {…}`; le preguntan al adapter DÓNDE y CÓMO escribir. La interfaz agrupa los métodos en bloques `[CERT]` (`interface.go`):

| Bloque | Métodos | Qué resuelve |
|--------|---------|--------------|
| Identity | `Agent() model.AgentID`, `Tier() model.SupportTier` | Identidad + nivel de soporte |
| Detection | `Detect(ctx, homeDir) (installed, binaryPath, configPath, configFound, err)` | ¿Está instalado el harness? |
| Installation | `SupportsAutoInstall() bool`, `InstallCommand(profile) ([][]string, error)` | Comando de instalación por plataforma |
| Config paths (DÓNDE) | `GlobalConfigDir`, `SystemPromptDir`, `SystemPromptFile`, `SkillsDir`, `SettingsPath` | Rutas de config; los componentes NO hardcodean paths |
| Config strategies (CÓMO) | `SystemPromptStrategy() model.SystemPromptStrategy`, `MCPStrategy() model.MCPStrategy` | Cómo inyectar, no dónde |
| MCP | `MCPConfigPath(homeDir, serverName)` | Resolución de path MCP |
| Capabilities | `SupportsOutputStyles/OutputStyleDir`, `SupportsSlashCommands/CommandsDir`, `SupportsSubAgents/SubAgentsDir/EmbeddedSubAgentsDir`, `SupportsSkills`, `SupportsSystemPrompt`, `SupportsMCP` | Cada agente DECLARA qué soporta |

La separación DÓNDE (paths) vs CÓMO (strategies) es explícita en el código: el comentario de `Config strategies` dice *"HOW to inject content, not WHERE (that's paths above)"* `[CERT]` (`interface.go`). Todos los adapters reportan `Tier() = TierFull` `[CERT]` —y `model.types` documenta que `TierFull` es el ÚNICO tier: *"All current agents receive the full SDD orchestrator, skill files, MCP config, and system prompt injection"* (`gentle-ai:internal/model/types.go:SupportTier`). El tier quedó como metadato de display, no como gate funcional `[INFER]`.

## 27.4 — `Registry` y `factory`: cuántos adapters hay y cómo se cargan `[CERT]`

El `Registry` es un `map[model.AgentID]Adapter` con `Register` (rechaza nil y duplicados vía `ErrDuplicateAdapter`), `Get` y `SupportedAgents()` (ids ordenados) `[CERT]` (`gentle-ai:internal/agents/registry.go`).

El `factory` define la lista canónica `defaultAgentIDs` con **16 AgentIDs** y un `NewAdapter(agent)` con un `switch` de 16 casos `[CERT]` (`gentle-ai:internal/agents/factory.go`). `NewDefaultRegistry()` instancia los 16; `NewMVPRegistry()` instancia solo Claude+OpenCode "kept for backward compatibility" `[CERT]`.

Los 16 AgentIDs `[CERT]` (`gentle-ai:internal/model/types.go:AgentID` + `factory.go:defaultAgentIDs`):

`claude-code`, `opencode`, `kilocode`, `gemini-cli`, `cursor`, `vscode-copilot`, `codex`, `antigravity`, `windsurf`, `kimi`, `qwen-code`, `kiro-ide`, `openclaw`, `pi`, `trae-ide`, `hermes`.

Cada uno tiene su paquete `internal/agents/<nombre>/adapter.go` + `adapter_test.go` `[CERT]` (verificado en el árbol del repo: 16 directorios de adapter, todos con test).

## 27.5 — Tabla maestra: qué materializa cada adapter `[CERT]`

Las cinco columnas decisivas por harness, leídas directamente de cada `adapter.go` `[CERT]`. `Prompt strat.` y `MCP strat.` referencian las constantes de `model.types` (§27.6).

| # | Paquete / AgentID | GlobalConfigDir | SystemPromptFile | Prompt strat. | MCP strat. | SubAgents |
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

Notas de evidencia por filas no obvias `[CERT]`:

- **Antigravity** comparte el system prompt con Gemini (`~/.gemini/GEMINI.md`) pero usa `antigravityVariantDir` como config dir y estrategia `AppendToFile` `[CERT]` (`antigravity/adapter.go`). Esto explica el workaround SDD documentado aparte (`docs/antigravity-sdd-workaround.md`).
- **Codex** instala vía `npm install -g --ignore-scripts @openai/codex@<versions.Codex>` (postinstall bloqueado por supply-chain) y NO tiene `settings.json` (`SettingsPath` devuelve `""`) `[CERT]` (`codex/adapter.go`).
- **Cursor** y **Kiro** declaran sub-agentes nativos (`SubAgentsDir` no vacío) — coherente con el README "10 SDD agents in `~/.cursor/agents/`" y "Native `~/.kiro/agents/`" `[CERT]`.
- **Hermes** es el único con `MergeIntoYAML` y persona en `SOUL.md`; **OpenClaw** también usa `AGENTS.md` en el root del workspace `[CERT]`.

Solo **4 de 16** adapters declaran `SupportsSubAgents()==true`: Claude, Cursor, Kimi, Kiro `[CERT]`. El resto materializa la delegación SDD vía orchestrator-en-prompt (un solo `sdd-orchestrator.md` / overlay), lo que conecta con los modelos Full/Solo-agent/Detect-only de [Bloque 25] `[INFER]`.

## 27.6 — Las estrategias: `SystemPromptStrategy` y `MCPStrategy` `[CERT]`

Las estrategias son enums cerrados en `model.types`, con la semántica documentada en sus comentarios `[CERT]` (`gentle-ai:internal/model/types.go`):

**`SystemPromptStrategy`** (6 valores):

| Constante | Qué hace | Harness ejemplo |
|-----------|----------|------------------|
| `StrategyMarkdownSections` | Inyecta secciones con marcadores `<!-- gentle-ai:ID -->` SIN clobberar contenido del usuario | Claude (`CLAUDE.md`), OpenClaw, Trae, Hermes |
| `StrategyFileReplace` | Reemplaza el archivo de prompt completo | OpenCode (`AGENTS.md`), Gemini, Codex, Qwen, Kilocode, Cursor |
| `StrategyAppendToFile` | Anexa contenido a un archivo existente | Antigravity, Windsurf, Pi |
| `StrategyInstructionsFile` | Escribe un archivo `.instructions.md` dedicado | VS Code Copilot |
| `StrategyJinjaModules` | Escribe módulos separados incluidos en un template Jinja2 fino | Kimi (`KIMI.md`) |
| `StrategySteeringFile` | Escribe un steering file Kiro con frontmatter `inclusion: always` | Kiro |

**`MCPStrategy`** (5 valores): `StrategySeparateMCPFiles` (un JSON por server, ej. `~/.claude/mcp/context7.json`), `StrategyMergeIntoSettings` (mergea `mcpServers` en settings.json — OpenCode/Gemini/Qwen/Kilocode/OpenClaw), `StrategyMCPConfigFile` (archivo `mcp.json` dedicado — Cursor/VSCode/Antigravity/Windsurf/Kimi/Kiro/Pi/Trae), `StrategyTOMLFile` (Codex `config.toml`), `StrategyMergeIntoYAML` (Hermes `config.yaml`, merge comment-preserving) `[CERT]` (`model/types.go`).

**Punto clave** `[INFER]`: el par (PromptStrategy, MCPStrategy) ES la "huella de materialización" de cada harness. Es lo que hace que añadir un harness nuevo sea declarar paths + elegir dos estrategias del enum, sin tocar los componentes —exactamente la promesa del comentario de la interfaz (§27.3).

## 27.7 — Resolución del gap "8 adapters vs 16 harnesses" `[CERT]`

[Bloque 26] dejó abierta una discrepancia: `docs/architecture.md` habla de **8 adapters** mientras el README lista ~15 harnesses. Resolución con evidencia:

1. **`docs/architecture.md` está DESACTUALIZADO** `[CERT]`. Lista solo 8 directorios de adapter —`claude/ opencode/ gemini/ cursor/ vscode/ codex/ windsurf/ antigravity/`— y afirma *"All 8 agent adapters have unit tests"* (`gentle-ai:docs/architecture.md`). Es un snapshot de la era MVP.
2. **El CÓDIGO tiene 16 adapters** `[CERT]`. `factory.go:defaultAgentIDs` enumera 16 AgentIDs y `NewAdapter` los instancia los 16; el árbol del repo confirma 16 directorios `internal/agents/<nombre>/` cada uno con `adapter.go` + `adapter_test.go` (`gentle-ai:internal/agents/factory.go`). Los 8 que faltan en la doc —`kilocode, kimi, qwen, kiro, openclaw, pi, trae, hermes`— SÍ existen, están registrados y testeados.
3. **El "15" del README** `[CERT-a]`: el encabezado dice "15 Supported Agents" pero la tabla lista **16 filas** (`gentle-ai:README.md:28-47`). La fila #16 es **Hermes**, marcada *"Detect-only — install manually first"*. La lectura más coherente `[INFER]`: el "15" cuenta los harnesses que gentle-ai puede auto-configurar/instalar, tratando a Hermes (detect-only, sin auto-install) como caso aparte; el código no distingue —los 16 son adapters de pleno derecho con `Tier()==TierFull`.

**Veredicto** `[CERT]`: la cuenta autoritativa es **16 adapters = 16 AgentIDs registrados en `factory.go`**. La cifra "8" de `docs/architecture.md` es deuda de documentación (doc stale), NO un límite del código. La cifra "15" del README es de presentación (excluye Hermes detect-only del conteo de "supported"). Recomendación honesta: cualquier afirmación sobre "N adapters" debe anclarse a `factory.go:defaultAgentIDs`, que es la única fuente que el binario realmente ejecuta.

## 27.8 — Gaps honestos y límites de esta lectura

- `[INFER]` La materialización CONCRETA del contenido SDD (qué bytes escribe cada estrategia) vive en `internal/components/sdd/inject.go` y `filemerge/`, no leídos exhaustivamente aquí; este bloque documenta el CONTRATO (paths + estrategias del adapter), no el cuerpo de cada injector. La conexión a los assets embebidos (`internal/assets/<harness>/sdd-orchestrator.md`, overlays OpenCode single/multi) queda en [Bloque 25].
- `[INFER]` Algunos config dirs se resuelven por helper con lógica de variante/OS (`antigravityVariantDir`, `kiroConfigDir`, `vscodeUserDir`, `windsurfUserDir`, `traeUserDir`, `pi.AgentConfigPath`); la tabla §27.5 cita el resultado lógico, no cada rama por plataforma.
- `[CERT]` No se hallaron campos en `InstallState` para scope (`global`/`workspace`) ni canal (`stable`/`beta`): esos no se persisten en `state.json` —son flags de invocación de [Bloque 26]. El `state.json` es estado de RESULTADO (qué quedó instalado), no de configuración de invocación `[INFER]`.

## 27.9 — Conexiones

- **[Bloque 26]** — `state.json` es el sustrato que `sync`/`upgrade`/`doctor` leen y reescriben; este bloque abre el struct que B26 mencionó como caja negra. `PendingSync` es el handshake upgrade→sync de B26.
- **[Bloque 25]** — los 16 adapters son la implementación Go de los harnesses y sus modelos de delegación (Full/Solo-agent/Detect-only); §27.5 muestra que solo 4 declaran sub-agentes nativos, el resto materializa orchestrator-en-prompt.
- **[Bloque 15]** — el dispatcher nativo `gentle-ai sdd-status` (paquete `internal/sddstatus`) lee artefactos OpenSpec, NO `state.json`; confirma la separación estado-de-configurador vs estado-de-cambio.
- **[Bloque 3]** — los artefactos SDD (proposal/spec/tasks…) viven en Engram/OpenSpec por topic key, jamás en `state.json`; §27.2 lo prueba por ausencia de campos de tareas.
- **[Bloque 18]** — los mapas `*ModelAssignments` de `InstallState` persisten las asignaciones de modelo per-fase que B18 define a nivel orquestador; aquí se ve dónde se guardan en disco.
