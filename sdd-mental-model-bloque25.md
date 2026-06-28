# Bloque 25 — Distribución multi-agente: los 15 harnesses y los modelos de delegación

> **QUÉ DOCUMENTA**: Este bloque documenta cómo el ecosistema Gentle AI distribuye el SDD a 15 harnesses de agentes distintos: la tabla canónica de agentes soportados (Agent / Delegation Model / Key Feature), los tres modelos de delegación (**Full**, **Solo-agent**, **Detect-only**), qué significa cada uno operativamente, dónde vive la configuración SDD por familia de harness (rutas de config, directorios de agentes, archivos de prompt), y qué le pasa al pipeline SDD cuando el harness NO tiene sub-agentes nativos (ejecución secuencial en un solo hilo). Incluye el workaround documentado de Antigravity.
> **ALCANCE**: La capa de DISTRIBUCIÓN del SDD a través de harnesses. NO documenta el binario configurador `gentle-ai` (comandos, scopes, backups, hooks — ver [Bloque 26]); NO redefine el grafo de fases SDD ni el Result Contract (ver [Bloque 2]); NO desarrolla los triggers de delegación del orquestador (ver [Bloque 18]). Este bloque toma esas fases como dadas y describe SOBRE QUÉ MECANISMO se ejecutan según el harness.
> **FUENTES** (leídas y verificadas vía `gh api` sobre `Gentleman-Programming/gentle-ai`, rama `main`):
> - `gentle-ai:README.md` (261 líneas — sección "15 Supported Agents", "Delegation Triggers")
> - `gentle-ai:docs/agents.md` (286 líneas — Agent Matrix, Delegation Models, SDD Mode Support, Agent Notes)
> - `gentle-ai:docs/antigravity-sdd-workaround.md` (25 líneas)
> - `gentle-ai:docs/kiro.md` (167 líneas)
> - `gentle-ai:docs/pi.md` (169 líneas)
> - `gentle-ai:docs/platforms.md` (50 líneas — Windows Config Paths)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo el archivo del repo, con `gentle-ai:<ruta>` y la tabla/sección citada. `[CERT-a]` = afirmado por el README/docs pero no verificado en el código fuente Go del configurador. `[INFER]` = deducción propia, no literal en la fuente.

---

## 25.1 — La tabla canónica de los 15 agentes `[CERT]`

El README publica la tabla de "15 Supported Agents" con tres columnas: **Agent**, **Delegation Model**, **Key Feature** `[CERT]` (`gentle-ai:README.md §"15 Supported Agents"`, líneas 30-48). Reproducida verbatim:

| Agent | Delegation Model | Key Feature `[CERT]` |
|-------|------------------|----------------------|
| **Claude Code** | Full (Task tool) | Sub-agents, output styles |
| **OpenCode** | Full (multi-mode overlay) | Per-phase model routing |
| **Kilo Code** | Full (multi-mode overlay) | OpenCode-compatible config en `~/.config/kilo` |
| **Gemini CLI** | Full (experimental) | Custom agents en `~/.gemini/agents/` |
| **Cursor** | Full (native subagents) | 10 SDD agents en `~/.cursor/agents/` |
| **VS Code Copilot** | Full (runSubagent) | Parallel execution |
| **Codex** | Solo-agent | CLI-native, TOML config |
| **Windsurf** | Solo-agent | Plan Mode, Code Mode, native workflows |
| **Antigravity** | Solo-agent + Mission Control | Built-in Browser/Terminal sub-agents |
| **Kimi Code** | Full (native custom agents) | Modular prompt templates en `~/.kimi` |
| **Kiro IDE** | Full (native subagents) | Native `~/.kiro/agents/` + steering orchestration |
| **Qwen Code** | Full (native sub-agents) | Slash commands, `~/.qwen/commands/`, `auto_edit` mode |
| **OpenClaw** | Solo-agent | Workspace-first `AGENTS.md` / `SOUL.md` con MCP global |
| **Trae** | Solo-agent | Desktop app de ByteDance; `~/.trae/skills/` + reglas por OS |
| **Pi** | Full (package-managed subagents) | Harness `gentle-pi` con persona/model commands + Engram |
| **Hermes** | Detect-only | YAML MCP config, SOUL.md persona; instalar manualmente primero |

**Nota de conteo** `[INFER]`: la lista del README enumera 16 filas (15 "supported" + Hermes "Detect-only"). Hermes aparece como entrada de la tabla pero su modelo de delegación es `Detect-only`, lo que lo distingue de los 15 que el configurador instala automáticamente. La `docs/agents.md` matiza el modelo de Hermes (ver §25.4).

**Discrepancia documentada `[CERT]`**: el README rotula Hermes como `Detect-only` (`gentle-ai:README.md:47`), pero la Agent Matrix de `docs/agents.md` rotula su **Delegation** como `Full (delegate_task ephemeral)` (`gentle-ai:docs/agents.md:26`). No es contradicción de capacidad sino de eje: `Detect-only` describe el modo de INSTALACIÓN (gentle-ai no puede instalar Hermes, solo detectarlo), mientras `Full (delegate_task)` describe el modo de DELEGACIÓN en runtime una vez configurado `[INFER]`. Ver §25.4 y §25.7.

## 25.2 — La Agent Matrix extendida (ID, capacidades, config path) `[CERT]`

`docs/agents.md` amplía la tabla del README con el **ID interno**, capacidades (Skills, MCP, Output Styles, Slash Commands) y **Config Path** `[CERT]` (`gentle-ai:docs/agents.md:9-26`):

| Agent | ID | Skills | MCP | Delegation | Slash | Config Path `[CERT]` |
|-------|----|--------|-----|-----------|-------|----------------------|
| Claude Code | `claude-code` | Sí | Sí | Full (Task tool) | No | `~/.claude` |
| OpenCode | `opencode` | Sí | Sí | Full (multi-mode overlay) | Sí | `~/.config/opencode` |
| Kilo Code | `kilocode` | Sí | Sí | Full (multi-mode overlay) | Sí | `~/.config/kilo` |
| Gemini CLI | `gemini-cli` | Sí | Sí | Full (experimental) | No | `~/.gemini` |
| Cursor | `cursor` | Sí | Sí | Full (native subagents) | No | `~/.cursor` |
| VS Code Copilot | `vscode-copilot` | Sí | Sí | Full (runSubagent) | No | `~/.copilot` + VS Code User profile |
| Codex | `codex` | Sí | Sí | Solo-agent (multi-agent opt-in, experimental) | No | `~/.codex` |
| Windsurf | `windsurf` | Sí (native) | Sí | Solo-agent | No | `~/.codeium/windsurf` |
| Antigravity | `antigravity` | Sí (native) | Sí | Solo-agent + Mission Control | No | `~/.gemini/antigravity` |
| Kimi Code | `kimi` | Sí | Sí | Full (native custom agents) | No | `~/.kimi` |
| Qwen Code | `qwen-code` | Sí | Sí | Full (native sub-agents) | Sí | `~/.qwen` |
| Kiro IDE | `kiro-ide` | Sí | Sí | Full (native subagents) | No | `~/.kiro` |
| OpenClaw | `openclaw` | Sí | Sí | Solo-agent | No | `~/.openclaw` |
| Trae | `trae-ide` | Sí | Sí | Solo-agent | No | `~/.trae` |
| Pi | `pi` | Sí | Sí | Full (package-managed subagents) | Sí | `~/.pi` |
| Hermes | `hermes` | Sí | Sí | Full (delegate_task ephemeral) | No | `~/.hermes` |

**Principio rector de distribución** `[CERT]` (`gentle-ai:docs/agents.md:28`): la mayoría de agentes recibe la **política completa del orquestador SDD** más los archivos de skills escritos en su directorio de skills. La mayoría la recibe vía system prompt; OpenCode y Kilo Code la reciben vía el overlay de agentes `opencode.json` (compatible OpenCode). **Pi es la excepción**: Gentle AI instala paquetes Pi y `gentle-pi` posee skills, prompts, SDD agents y chains en runtime. El agente maneja SDD automáticamente cuando la tarea es grande, o cuando el usuario lo pide explícitamente — sin setup manual.

## 25.3 — Los tres modelos de delegación `[CERT]`

`docs/agents.md` define formalmente los modelos en una tabla de "Delegation Models" `[CERT]` (`gentle-ai:docs/agents.md:36-40`). El eje conceptual es **dónde corre cada fase SDD**: en una ventana de contexto aislada (sub-agente real) o inline en el mismo hilo.

### 25.3.1 — Full (sub-agents) `[CERT]`

> *"Each SDD phase runs in an isolated context window via native sub-agent delegation, package-managed subagents, or an OpenCode-compatible overlay. The orchestrator coordinates; sub-agents execute."* `[CERT]` (`gentle-ai:docs/agents.md:38`)

Agentes Full: **Claude Code, OpenCode, Kilo Code, Gemini CLI, Cursor, VS Code Copilot, Kimi Code, Kiro IDE, Qwen Code, Pi** `[CERT]` (`gentle-ai:docs/agents.md:38`). Cada fase del DAG SDD (ver [Bloque 2]) obtiene su propia ventana de contexto fresca; el orquestador coordina sin contaminarse con el detalle de ejecución. Mecanismos concretos por familia (ver §25.5):

- **Task tool nativo** — Claude Code `[CERT]` (`gentle-ai:docs/agents.md:11,93`)
- **Overlay multi-modo OpenCode-compatible** (`opencode.json`) — OpenCode, Kilo Code `[CERT]` (`gentle-ai:docs/agents.md:12-13,38`)
- **Native subagents** (directorio `agents/`) — Cursor, Kiro IDE, Qwen Code, Kimi Code, Gemini CLI (experimental) `[CERT]` (`gentle-ai:docs/agents.md:14-22`)
- **`runSubagent` tool con ejecución paralela** — VS Code Copilot `[CERT]` (`gentle-ai:docs/agents.md:16,131`)
- **Package-managed subagents** (`pi-subagents-j0k3r` descubre `.pi/agents/`) — Pi `[CERT]` (`gentle-ai:docs/agents.md:25,244`)

### 25.3.2 — Solo-agent `[CERT]`

> *"All SDD phases run inline in the same conversation. The orchestrator IS the executor. Engram provides cross-phase persistence."* `[CERT]` (`gentle-ai:docs/agents.md:40`)

Agentes Solo-agent: **Codex, Windsurf, Antigravity, OpenClaw, Trae** `[CERT]` (`gentle-ai:docs/agents.md:40`). No hay sub-agentes: las fases SDD se ejecutan secuencialmente en el mismo hilo de conversación, y el orquestador y el ejecutor son la misma entidad. La persistencia cross-fase la provee **Engram** (no la ventana de contexto, que es única) `[CERT]`. Esto es lo que evita que el contexto colapse: el artefacto de cada fase se persiste fuera del hilo y la fase siguiente lo relee.

**Caso especial Codex** `[CERT]`: aunque rotulado Solo-agent, soporta delegación multi-agente como **opt-in experimental** (default off). gentle-ai escribe `features.multi_agent = false`, `agents.max_threads = 4` y `agents.max_depth = 2` en `~/.codex/config.toml`. Al activar `multi_agent = true`, el `sdd-orchestrator` usa los tools nativos `spawn_agent` / `wait_agent` / `close_agent` para delegar fases; si no, cae a ejecución inline solo-agent `[CERT]` (`gentle-ai:docs/agents.md:151-152`).

### 25.3.3 — Detect-only `[CERT]`

Aplica a **Hermes** `[CERT]` (`gentle-ai:README.md:47`). gentle-ai **no puede instalar** Hermes; solo detecta su presencia. El usuario instala Hermes manualmente primero y luego corre `gentle-ai install --agent hermes` `[CERT]` (`gentle-ai:docs/agents.md:278`). La detección se hace por el binario `hermes` en `PATH` y el config root `~/.hermes`, pero es el **directorio de config** el que dispara la detección de instalación — el binario puede estar ausente y Hermes sigue detectado como configurado `[CERT]` (`gentle-ai:docs/agents.md:277`).

**Detect-only describe instalación, no delegación** `[INFER]`: una vez configurado, Hermes delega en runtime vía `delegate_task` (Full ephemeral, ver §25.4). `Detect-only` es la frontera de lo que el configurador puede automatizar.

## 25.4 — Hermes: Full (delegate_task ephemeral) `[CERT]`

`docs/agents.md` añade una tercera fila a la tabla de modelos de delegación específica para Hermes `[CERT]` (`gentle-ai:docs/agents.md:39`):

> *"The orchestrator uses Hermes's native `delegate_task` primitive to spawn ephemeral workers in fresh context windows. Workers receive only a self-contained mission; the parent receives only their final summary. Toolsets, MCP, and skills must be passed explicitly (not inherited by default)."*

Reglas operativas de la delegación efímera `[CERT]` (`gentle-ai:docs/agents.md:254-260`):

- Delegar cuando el trabajo requiere exploración amplia (4+ archivos), implementación multi-archivo, ejecución de test/build, o review adversarial fresco — los mismos triggers del [Bloque 18].
- Cada misión del worker debe ser **autocontenida**: goal exacto, rutas/targets, contexto previo relevante, constraints, evidencia esperada y los toolsets/MCP/skills permitidos.
- Toolsets, MCP servers y skills **NO se heredan** del padre automáticamente; hay que pasarlos explícitos cuando `inherit_mcp_toolsets` es false (el default).
- Tratar la salida del worker como auto-reporte: verificar writes, pass/fail de tests, URLs y side effects antes de reportar éxito.

Knobs de tuning en `~/.hermes/config.yaml` bajo `delegation` `[CERT]` (`gentle-ai:docs/agents.md:264-271`): `max_spawn_depth` (2), `max_concurrent_children` (4), `max_iterations`, `child_timeout_seconds`, `inherit_mcp_toolsets` (false), `subagent_auto_approve` (false). La tabla de decisión completa vive en `~/.hermes/skills/hermes-ephemeral-delegation/SKILL.md`, instalada por gentle-ai y referenciada desde el orquestador SDD en `~/.hermes/SOUL.md` `[CERT]` (`gentle-ai:docs/agents.md:273`).

## 25.5 — Materialización del SDD por familia de harness `[CERT]`

El SDD se materializa con artefactos físicos distintos según el harness. Mapa de dónde viven los agentes/config SDD `[CERT]` (consolidado de `gentle-ai:docs/agents.md §Agent Notes`, `gentle-ai:docs/kiro.md`, `gentle-ai:docs/pi.md`):

| Harness | Dónde vive el SDD / orquestador | Sub-agentes de fase | Fuente `[CERT]` |
|---------|----------------------------------|---------------------|------------------|
| Claude Code | `~/.claude/CLAUDE.md` (markdown sections); MCP en `~/.claude/mcp/`; output styles en `~/.claude/output-styles/` | Task tool nativo (contexto aislado) | `docs/agents.md:91-96` |
| OpenCode | Overlay de 11 agentes en `opencode.json` (`gentle-orchestrator` + 10 fases); prompts compartidos en `~/.config/opencode/prompts/sdd/`; slash commands `/sdd-*` | `task` subagents nativos | `docs/agents.md:98-107` |
| Kilo Code | `AGENTS.md`, `skills/`, `commands/`, `opencode.json` bajo `~/.config/kilo` (adapter OpenCode-compatible) | Overlay multi-agente fusionado en `~/.config/kilo/opencode.json` | `docs/agents.md:109-115` |
| Gemini CLI | `~/.gemini`; sub-agentes en `~/.gemini/agents/` (markdown) | Requiere `experimental.enableAgents: true` en `settings.json` | `docs/agents.md:118-121` |
| Cursor | System prompt en `~/.cursor/rules/gentle-ai.mdc`; skills `~/.cursor/skills/`; MCP `~/.cursor/mcp.json` | 10 archivos `~/.cursor/agents/sdd-{phase}.md` | `docs/agents.md:123-127` |
| VS Code Copilot | Prompt en `Code/User/prompts/gentle-ai.instructions.md`; skills `~/.copilot/skills/`; MCP `Code/User/mcp.json` | Tool `runSubagent` (ejecución paralela) | `docs/agents.md:129-134` |
| Codex | Prompt en `~/.codex/AGENTS.md`; skills `~/.codex/skills/`; config TOML `~/.codex/config.toml`; Engram instructions `~/.codex/engram-instructions.md` | Inline (opt-in `spawn_agent`/`wait_agent`/`close_agent`) | `docs/agents.md:137-152` |
| Windsurf | Global rules `~/.codeium/windsurf/memories/global_rules.md`; skills `~/.codeium/windsurf/skills/`; MCP `mcp_config.json` | Inline; workflows en `.windsurf/workflows/` (workspace) | `docs/agents.md:154-159` |
| Antigravity | Prompt appendado a `~/.gemini/GEMINI.md` (compartido con Gemini CLI); skills `~/.gemini/antigravity/skills/`; MCP `mcp_config.json` | Inline + Mission Control (Browser/Terminal built-in) | `docs/agents.md:161-167` |
| Kimi Code | Root agent `~/.kimi/agents/gentleman.yaml` con `system_prompt_path: ../KIMI.md`; `KIMI.md` = template Jinja que incluye `persona.md`, `output-style.md`, `engram-protocol.md`, `sdd-orchestrator.md` | Native custom agents | `docs/agents.md:169-175` |
| Kiro IDE | Steering `~/.kiro/steering/gentle-ai.md` (`inclusion: always`); skills `~/.kiro/skills/`; MCP **siempre** en `~/.kiro/settings/mcp.json` | 10 archivos `~/.kiro/agents/sdd-{phase}.md` | `docs/agents.md:177-186`, `docs/kiro.md` |
| Qwen Code | Prompt `~/.qwen/QWEN.md`; skills `~/.qwen/skills/`; MCP en `~/.qwen/settings.json` (`mcpServers`); slash commands `~/.qwen/commands/*.md` (namespaced, ej. `/sdd:init`); modo `auto_edit` | Native sub-agents | `docs/agents.md:188-199` |
| OpenClaw | Instrucciones Engram+SDD en workspace `AGENTS.md`; persona en `SOUL.md`; MCP global `~/.openclaw/openclaw.json`; SDD skills workspace `<workspace>/.openclaw/skills/sdd-*` | Inline (solo-agent) | `docs/agents.md:201-208` |
| Trae | Rules en `user_rules.md` OS-específico (`StrategyMarkdownSections`); skills `~/.trae/skills/`; MCP `mcp.json` OS-específico | Inline (solo-agent) | `docs/agents.md:210-220` |
| Pi | `gentle-pi` posee todo en runtime: `.pi/agents/sdd-*.md`, `.pi/chains/sdd-*.chain.md`, `.pi/gentle-ai/support/`; copiado en `session_start` | `pi-subagents-j0k3r` descubre y corre `.pi/agents/` | `docs/agents.md:222-248`, `docs/pi.md` |
| Hermes | Prompt SDD + persona en `~/.hermes/SOUL.md` (marcadores `<!-- gentle-ai:* -->`); skills `~/.hermes/skills/`; MCP YAML en `~/.hermes/config.yaml` | `delegate_task` efímero (fresh context) | `docs/agents.md:250-286` |

**Patrón transversal** `[INFER]`: en TODOS los harnesses el orquestador vive en el "prompt persistente" del agente (CLAUDE.md, steering, SOUL.md, QWEN.md, global_rules.md, opencode.json) y las fases viven en archivos de agente separados (cuando hay sub-agentes) o se ejecutan como roles secuenciales en el mismo prompt (cuando no los hay). El nombre del archivo cambia; el rol "orquestador coordina / fase ejecuta" no.

## 25.6 — SDD sin sub-agentes: simulación de un solo hilo `[CERT]`

Cuando el harness es Solo-agent, **las fases SDD son las mismas pero el mecanismo de delegación cambia**: en vez de spawn de un sub-agente con contexto fresco, el orquestador cambia de rol secuencialmente dentro del mismo hilo `[CERT]` (`gentle-ai:docs/agents.md:40`). El riesgo es la **degradación de contexto**: el LLM empieza a mezclar instrucciones de skills anteriores y pierde el hilo de la arquitectura `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:4-5`).

### 25.6.1 — Antigravity + Mission Control `[CERT]`

Antigravity es una plataforma agent-first con sub-agentes built-in (Browser, Terminal) gestionados por **Mission Control**, pero la **creación de sub-agentes custom aún no está disponible** `[CERT]` (`gentle-ai:docs/agents.md:61`). Las fases SDD corren inline; Mission Control delega automáticamente a los sub-agentes built-in cuando se necesita tooling especializado (ej. Browser para research durante `sdd-explore`) `[CERT]`.

### 25.6.2 — El workaround "Artifact-Driven State Machine" `[CERT]`

`docs/antigravity-sdd-workaround.md` documenta el patrón para hacer SDD funcional en Antigravity hoy, en modo "Single-Threaded Simulation", **sin afectar la arquitectura multi-agente original de Cursor u OpenCode** `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:8,24-25`). Es una máquina de estados apoyada estrictamente en el filesystem local. Cuatro reglas inyectadas `[CERT]` (`gentle-ai:docs/antigravity-sdd-workaround.md:10-22`):

1. **Role Switching estricto** — el orquestador anuncia el cambio de fase y carga el `SKILL.md` correspondiente en su contexto, **ignorando temporalmente** directivas previas.
2. **File-System como memoria (Save State)** — al terminar una fase (ej. `sdd-propose`), Antigravity tiene PROHIBIDO avanzar sin guardar el output completo en un archivo físico (ej. `.sdd/propuesta.md`). El chat NO es almacenamiento confiable.
3. **Amnesia controlada (Load State)** — al iniciar la fase siguiente (ej. `sdd-spec`), NO debe confiar en su historial de chat. Su primera acción obligatoria es `Read` del archivo generado en el paso anterior, refrescando el contexto exacto que la fase necesita.
4. **Uso correcto de Engram** — `mem_save` se reserva SOLO para decisiones arquitectónicas globales, convenciones y bugfixes; NO para el estado intermedio del SDD en curso (para eso están los `.sdd/*.md`).

**Modelo mental** `[INFER]`: el workaround replica con el filesystem lo que los harnesses Full obtienen con ventanas de contexto aisladas. El "Save State / Load State / Amnesia controlada" es exactamente la asimetría de contexto del [Bloque 19] §19.6 (el contexto grande no sube por el hilo; se persiste y se relee por referencia), pero implementada a mano sobre `.sdd/*.md` en lugar de delegación nativa. Es la prueba operativa de que **las fases son invariantes y solo cambia el transporte de contexto**.

## 25.7 — Soporte de modo SDD: single-mode vs multi-mode `[CERT]`

`docs/agents.md` publica una matriz de SDD Mode Support `[CERT]` (`gentle-ai:docs/agents.md:75-85`). Los 15+1 harnesses soportan **SDD orchestrator** y **Single-mode SDD** (`Yes` en las 16 columnas). El diferenciador es **Multi-mode SDD** (asignar un modelo distinto a cada fase):

| Capacidad | Quién la soporta `[CERT]` |
|-----------|----------------------------|
| SDD orchestrator | Los 16 (todos) |
| Single-mode SDD | Los 16 (todos) |
| Multi-mode SDD | **OpenCode**, **Kilo Code** (vía overlay multi-modo OpenCode-compatible), **Kiro IDE** (vía `model:` en frontmatter de subagente nativo), **Pi** (owned por los paquetes Pi) |

- **Kiro multi-mode** `[CERT]` (`gentle-ai:docs/agents.md:83`): asigna modelos por fase vía `KiroModelAssignments` (TUI: *Configure Models → Configure Kiro models*). El alias Kiro (`auto|opus|sonnet|haiku|minimax|glm|deepseek|qwen`) se resuelve a un model ID Kiro-nativo y se estampa en cada `~/.kiro/agents/sdd-{phase}.md` en sync time.
- **Pi multi-mode** `[CERT]` (`gentle-ai:docs/agents.md:85`): owned por los paquetes Pi. `gentle-pi` instala assets de SDD agent y chain en `.pi/agents/` y `.pi/chains/`; los overrides de modelo viven en esos archivos Pi-managed o en pasos de chain.

Todos los demás corren **single-mode**: el orquestador gestiona todo con el modelo que el agente ya está corriendo `[CERT]` (`gentle-ai:docs/agents.md:81`). La asignación per-phase del configurador (OpenCode profiles, Codex profiles, Kiro assignments) se detalla en [Bloque 26].

## 25.8 — Implicación clave: las fases son invariantes, el transporte cambia `[CERT-a]`

La afirmación central de este bloque, soportada por todas las fuentes: **el grafo de fases SDD (`proposal → specs/design → tasks → apply → verify → archive`, ver [Bloque 2]) es idéntico en los 15 harnesses; lo único que cambia es el MECANISMO de delegación** `[INFER]` (derivado de `gentle-ai:docs/agents.md:38-40,77-78` + `gentle-ai:docs/kiro.md:48`).

Evidencia textual de Kiro `[CERT]` (`gentle-ai:docs/kiro.md:48`): *"This follows the same SDD architecture used in gentle-ai: orchestrator coordinates, phase agents execute, Engram persists artifacts across phases."* La matriz de SDD Mode Support confirma que el `SDD orchestrator` está en `Yes` para los 16 `[CERT]` (`gentle-ai:docs/agents.md:77`).

Tres encarnaciones del MISMO contrato según el transporte `[INFER]`:

| Transporte | Fase corre en | Persistencia cross-fase | Ejemplo |
|-----------|----------------|--------------------------|---------|
| Sub-agente real (Full) | Ventana de contexto aislada, spawneada por el orquestador | Backend (Engram/OpenSpec) + referencia por topic_key/ruta | Claude Code Task, Cursor agents, Kiro agents |
| Hilo secuencial (Solo-agent) | El mismo hilo, role-switching | Engram (el hilo es único, el contexto se reusa) | Codex inline, Windsurf, OpenClaw, Trae |
| Hilo + filesystem state machine (Solo-agent reforzado) | El mismo hilo + Save/Load State obligatorio | Archivos `.sdd/*.md` + Engram solo para decisiones | Antigravity workaround |

El Result Contract del [Bloque 2] (status, executive_summary, artifacts, next_recommended, risks, skill_resolution) es lo que cada fase devuelve **independientemente del transporte** — es la interfaz que hace posible que el orquestador no distinga, a nivel de coordinación, entre un sub-agente real y un role-switch inline `[INFER]`.

## 25.9 — Conexiones

- **[Bloque 1] — Filosofía + orquestador**: el modelo "orquestador coordina / fase ejecuta" que [Bloque 1] establece filosóficamente se materializa aquí en 15 transportes distintos. El "hilo delgado" del orquestador (§1.x) es trivial en Full (el sub-agente absorbe el contexto pesado) pero requiere disciplina explícita en Solo-agent (de ahí el workaround de Antigravity, §25.6.2).
- **[Bloque 2] — DAG + Result Contract**: §25.8 es la tesis de este bloque — el DAG de fases y el Result Contract de [Bloque 2] son INVARIANTES respecto del harness. El contrato es la interfaz que desacopla "qué fase" de "sobre qué mecanismo corre".
- **[Bloque 18] — Delegación + triggers + models**: los Delegation Triggers del README (§25 menciona reading 4+ files, touching 2+ files, etc.) son los mismos del [Bloque 18]; aquí se ve cómo cada harness los implementa (sub-agente real vs role-switch). Hermes reusa esos triggers literalmente (§25.4).
- **[Bloque 19] — Contrato de persistencia**: la asimetría de contexto de [Bloque 19] §19.6 (contexto grande no sube por el hilo) es lo que el workaround de Antigravity (§25.6.2) replica a mano con `.sdd/*.md`. En Solo-agent, Engram ES el mecanismo de persistencia cross-fase que reemplaza la ventana aislada.
- **[Bloque 26] — El configurador `gentle-ai`**: este bloque describe QUÉ se distribuye a cada harness; [Bloque 26] describe el binario que lo distribuye (install/sync/upgrade, scopes, adapters por agente, per-phase models). La asignación multi-mode de §25.7 (OpenCode/Kilo/Kiro/Pi) se detalla operativamente en [Bloque 26].
</content>
</invoke>
