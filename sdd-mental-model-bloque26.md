# Bloque 26 — El configurador `gentle-ai`: install/sync/upgrade, scopes, OpenCode SDD profiles, per-phase models

> **QUÉ DOCUMENTA**: Este bloque documenta el binario configurador `gentle-ai` (Go) que distribuye el ecosistema (memoria persistente + SDD + skills + MCP + persona) a los 15 harnesses: qué ES (un configurador de ecosistema, NO un instalador de agentes), sus comandos (`install`, `sync`, `upgrade`, `doctor`, `skill-registry refresh`), los scopes (`global` vs `workspace`), los canales stable/beta, los OpenCode SDD Profiles con asignación de modelo per-fase, los Codex y Kiro per-phase profiles, el sistema de backups automáticos (tar.gz, dedup, prune, pin), los startup hooks que mantienen fresco el skill-registry, y el `state.json` en `~/.gentle-ai/`.
> **ALCANCE**: El binario configurador y su superficie de comandos/configuración. NO redefine los modelos de delegación ni la materialización por harness (ver [Bloque 25]); NO desarrolla el contrato de persistencia ni los backends Engram/OpenSpec (ver [Bloque 3] y [Bloque 19-21]); NO documenta el dispatcher nativo de status SDD en detalle (ver [Bloque 15]). Cubre el configurador, no el runtime del orquestador.
> **FUENTES** (leídas y verificadas vía `gh api` sobre `Gentleman-Programming/gentle-ai`, rama `main`):
> - `gentle-ai:README.md` (261 líneas — What It Does, Quick Start, Install, Backups, OpenCode SDD Profiles, Engram)
> - `gentle-ai:docs/opencode-profiles.md` (188 líneas)
> - `gentle-ai:docs/architecture.md` (81 líneas — layout del codebase Go)
> - `gentle-ai:docs/non-interactive.md` (62 líneas — flags, env vars, platform behavior)
> - `gentle-ai:docs/agents.md` (Codex profiles, Kiro assignments, Pi packages)
> - `gentle-ai:docs/pi.md` (169 líneas — `gentle-pi`, packages, session_start hooks)
> - `gentle-ai:docs/platforms.md` (50 líneas)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo el archivo del repo, con `gentle-ai:<ruta>` y la sección/tabla citada. `[CERT-a]` = afirmado por el README/docs pero no verificado en el código fuente Go. `[INFER]` = deducción propia, no literal en la fuente.

---

## 26.1 — Qué es: un configurador de ecosistema, no un instalador `[CERT]`

El README abre con la definición negativa explícita `[CERT]` (`gentle-ai:README.md:22`):

> *"Gentle-AI is NOT an AI agent installer. Most agents are easy to install. It is an **ecosystem configurator** -- it takes whatever AI coding agent(s) you use and supercharges them with persistent memory, Spec-Driven Development workflows, curated coding skills, MCP servers, an AI provider switcher, a teaching-oriented persona with security-first permissions, and per-phase model assignment so each SDD step can run on a different model."*

El contraste de valor `[CERT]` (`gentle-ai:README.md:24-26`): **Antes** — "instalé Claude Code / OpenCode / Cursor pero es solo un chatbot que escribe código". **Después** — el agente ahora tiene memoria, skills, workflow, MCP tools y una persona que enseña. El configurador **supersedes** Agent Teams Lite (archivado); todo lo de ATL está incluido con mejor instalación, updates automáticos y memoria persistente `[CERT]` (`gentle-ai:README.md:49`).

**Punto clave** `[INFER]`: la distinción "configurador, no instalador" es estructural — gentle-ai escribe archivos de configuración (prompts, skills, agentes SDD, MCP, persona) en el config dir de cada harness ya instalado. La mayoría de harnesses se instalan solos; gentle-ai los SUPERCARGA. Esto explica por qué Hermes/Kiro/Trae/OpenClaw/Pi son detect-only o manual-install: el configurador configura lo que ya existe.

## 26.2 — Comandos del CLI `[CERT]`

Superficie de comandos verificable en README + docs `[CERT]`:

| Comando | Qué hace | Fuente `[CERT]` |
|---------|----------|------------------|
| `gentle-ai install` | Escribe archivos agent-scoped al config dir global de cada agente seleccionado | `gentle-ai:README.md:151` |
| `gentle-ai install --scope=workspace` | Aísla la stack a un proyecto: escribe archivos agent-scoped en el root del proyecto actual | `gentle-ai:README.md:154`, `docs/non-interactive.md:19` |
| `gentle-ai sync` | Re-aplica/actualiza la config; punto de entrada de profiles, migraciones y backups | `gentle-ai:README.md:177-179`, `docs/opencode-profiles.md` |
| `gentle-ai upgrade` | Self-update + upgrade del binario y assets; respeta el canal activo | `gentle-ai:README.md:99` |
| `gentle-ai doctor` | Health check read-only del ecosistema (binarios, `state.json`, alcance de Engram, espacio en disco) | `gentle-ai:README.md:112` |
| `gentle-ai skill-registry refresh` | Escanea skills instaladas + convenciones del proyecto y reconstruye el registry | `gentle-ai:README.md:108` |
| `gentle-ai install --agent <id>` | Instala/configura un harness específico (ej. `--agent pi`, `--agent hermes`, `--agent openclaw`) | `gentle-ai:docs/agents.md:204`, `docs/pi.md:14` |
| `gentle-ai update` | Compara versiones de plugins materializados con releases de GitHub (community plugins) | `gentle-ai:README.md:237` |
| `gentle-ai` (sin args) | Lanza la TUI Bubbletea (welcome screen, OpenCode SDD Profiles, etc.) | `gentle-ai:README.md:180`, `docs/opencode-profiles.md:34` |

### 26.2.1 — Setup project-level post-install `[CERT]`

Tras configurar agentes, dos comandos registran el contexto del proyecto `[CERT]` (`gentle-ai:README.md:105-110`):

| Comando | Qué hace | Cuándo re-correr `[CERT]` |
|---------|----------|----------------------------|
| `/sdd-init` | Detecta stack, capacidades de testing, activa Strict TDD Mode si está disponible | Cuando el proyecto agrega/quita test frameworks, o primera vez en un proyecto nuevo |
| `gentle-ai skill-registry refresh` | Escanea skills instaladas y convenciones, construye el registry | Tras instalar/quitar skills, o primera vez en un proyecto nuevo |

Ninguno es requerido para uso básico: el orquestador SDD corre `/sdd-init` automáticamente si detecta que no hay contexto `[CERT]` (`gentle-ai:README.md:110`).

### 26.2.2 — Modo no-interactivo (CI / scripts) `[CERT]`

`go run ./cmd/gentle-ai install [flags]` soporta flags para setup reproducible `[CERT]` (`gentle-ai:docs/non-interactive.md:7-21`): `--agent`/`--agents` (CSV repetible), `--component`/`--components`, `--skill`/`--skills`, `--persona`, `--preset`, `--sdd-mode` (`single`|`multi`), `--scope` (`global`|`workspace`), `--dry-run` (renderiza el plan sin ejecutar). Errores: opciones desconocidas fallan fast con validación; plataforma no soportada sale antes de cualquier trabajo de install `[CERT]` (`gentle-ai:docs/non-interactive.md:60-62`).

## 26.3 — Scopes: global vs workspace `[CERT]`

Por default, `gentle-ai install` escribe archivos agent-scoped al **config dir global** de cada agente seleccionado `[CERT]` (`gentle-ai:README.md:151`). Para aislar la stack Gentleman a un proyecto:

```bash
gentle-ai install --scope=workspace
```

**Workspace scope NO es solo-Claude** `[CERT]` (`gentle-ai:README.md:157`, `docs/agents.md:30`): aplica a los agentes seleccionados para archivos agent-scoped — system prompts, skills, SDD agents y persona files — escritos en el root del proyecto (`./`). Las integraciones global-only (package installs, settings que el agente solo lee de su config global) **permanecen globales by design** `[CERT]` (`gentle-ai:docs/non-interactive.md:28`).

Variable de entorno equivalente `[CERT]` (`gentle-ai:docs/non-interactive.md:24-26`): `GENTLE_AI_INSTALL_SCOPE` con valores `global` (default) | `workspace`. Útil en CI; equivalente a `--scope`.

**Modelo mental** `[INFER]`: el scope es una decisión de DÓNDE viven los archivos agent-scoped (global config dir vs project root), no de QUÉ se instala. Lo global-only (paquetes, MCP que el agente lee de su config global) ignora el scope porque el harness no lo leería desde el proyecto.

## 26.4 — Canales stable / beta `[CERT]`

El instalador soporta dos canales `[CERT]` (`gentle-ai:README.md:83-99`):

- **stable** — vía Homebrew/Scoop, artefactos de release de CI.
- **beta** — buildea Gentle AI directo desde `main`, por eso requiere **Go 1.24+** instalado primero. Para probar cambios no-released y reportar issues temprano.

```bash
# macOS/Linux beta
curl -fsSL .../install.sh | bash -s -- --channel beta
# Windows beta
$env:GENTLE_AI_CHANNEL="beta"; irm .../install.ps1 | iex
# Seguir upgradeando en beta
GENTLE_AI_CHANNEL=beta gentle-ai upgrade
```

Para volver a stable: reinstalar vía Homebrew o Scoop `[CERT]` (`gentle-ai:README.md:99`). Plataformas soportadas `[CERT]` (`gentle-ai:docs/platforms.md:7-13`): macOS (Homebrew), Ubuntu/Debian (apt), Arch (pacman), Fedora/RHEL (dnf), Windows 10/11 (Scoop). Derivados detectados vía `ID_LIKE` en `/etc/os-release` `[CERT]` (`gentle-ai:docs/platforms.md:15`).

## 26.5 — OpenCode SDD Profiles: asignación de modelo per-fase `[CERT]`

El feature insignia del configurador: asignar **modelos distintos a fases SDD distintas** — un modelo potente para design, uno rápido para implementación, uno barato para exploración `[CERT]` (`gentle-ai:README.md:171-173`). OpenCode usa `gentle-orchestrator` como conductor SDD base; los profiles nombrados generan entradas `sdd-orchestrator-{name}` `[CERT]`.

### 26.5.1 — Dos estrategias de profile `[CERT]`

`docs/opencode-profiles.md` define dos modos `[CERT]` (`gentle-ai:docs/opencode-profiles.md:11-12,179-182`):

1. **`generated-multi`** (Generated multi-profile mode) — el flujo clásico. Base = `gentle-orchestrator`. Cada profile nombrado genera su `sdd-orchestrator-{name}` + 10 sub-agentes de fase sufijados en `opencode.json`; se cicla con **Tab** dentro de OpenCode.
2. **`external-single-active`** (External single-active mode) — para tools de comunidad que mantienen archivos de profile FUERA de `opencode.json` y activan un profile runtime a la vez. Auto-detectado si existen archivos bajo `~/.config/opencode/profiles/*.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:102-108`).

Override manual de estrategia `[CERT]` (`gentle-ai:docs/opencode-profiles.md:114-122`):
```bash
gentle-ai sync --agent opencode --sdd-profile-strategy external-single-active
gentle-ai sync --agent opencode --sdd-profile-strategy generated-multi
```

### 26.5.2 — CLI de profiles `[CERT]`

Crear/configurar profiles durante sync `[CERT]` (`gentle-ai:README.md:175-181`, `docs/opencode-profiles.md:72-94`):

```bash
# Profile uniforme: todo en un modelo
gentle-ai sync --profile cheap:openrouter/qwen/qwen3-30b-a3b:free

# Override de una fase específica: name:phase:provider/model
gentle-ai sync --profile-phase cheap:sdd-design:anthropic/claude-sonnet-4-20250514

# Combinado: todo en Haiku excepto sdd-apply en Sonnet
gentle-ai sync \
  --profile cheap:anthropic/claude-haiku-3.5-20241022 \
  --profile-phase cheap:sdd-apply:anthropic/claude-sonnet-4-20250514
```

`--profile name:provider/model` setea todas las fases; `--profile-phase name:phase:provider/model` sobreescribe una fase puntual `[CERT]`. También vía TUI: `gentle-ai` → "OpenCode SDD Profiles" → Create `[CERT]` (`gentle-ai:README.md:180`).

### 26.5.3 — Tabla de key names `[CERT]`

Claves de agente en `opencode.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:62-68`):

| Clave | Significado | ¿Renombrar a mano? |
|-------|-------------|---------------------|
| `gentle-orchestrator` | Conductor SDD base canónico de OpenCode. Todos los `/sdd-*` apuntan acá por default | No |
| `sdd-orchestrator` | Clave legacy del conductor base. Sync la migra a `gentle-orchestrator` | No; dejar que sync migre |
| `sdd-orchestrator-{name}` | Conductor de profile nombrado (ej. `sdd-orchestrator-cheap`) | No; usar TUI o CLI |
| `sdd-{phase}` | Sub-agente default de una fase (ej. `sdd-apply`) | No |
| `sdd-{phase}-{name}` | Sub-agente de profile nombrado (ej. `sdd-apply-cheap`) | No |

### 26.5.4 — Cómo funciona internamente `[CERT]`

En `generated-multi`, cada profile nombrado genera **11 entradas** en `opencode.json` `[CERT]` (`gentle-ai:docs/opencode-profiles.md:175-177`): un orquestador (`sdd-orchestrator-{name}`, mode `primary`) + 10 sub-agentes de fase (`sdd-{phase}-{name}`, mode `subagent`, hidden). Los prompts de sub-agente se **comparten** entre profiles como archivos en `~/.config/opencode/prompts/sdd/` (ej. `sdd-apply.md`); cada entrada referencia el archivo compartido vía `{file:~/.config/opencode/prompts/sdd/sdd-apply.md}` — **solo difiere el campo `model`**. Los prompts de orquestador se inlinean per-profile porque contienen tablas de asignación de modelo y referencias a sub-agentes profile-específicas `[CERT]`.

**Profile `default`** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:158`): `gentle-orchestrator` puede editarse pero NO borrarse — siempre existe cuando SDD está configurado. Reglas de nombre `[CERT]` (`gentle-ai:docs/opencode-profiles.md:162-168`): slug lowercase, hyphens ok, sin espacios, `default` reservado, `LOUD` → `loud` (auto-lowercase).

**Reasoning effort per-modelo** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:44-56`): para modelos con variantes de esfuerzo (ej. OpenAI `gpt-5` con `low`/`medium`/`high`/`xhigh`), el picker muestra un paso extra. Las opciones se pueblan desde un cache `~/.gentle-ai/cache/model-variants.json` escrito por el plugin `model-variants` la primera vez que OpenCode arranca tras `gentle-ai sync` y refrescado en cada arranque subsiguiente.

**Native background subagents** `[CERT]` (`gentle-ai:docs/opencode-profiles.md:19-30`): OpenCode SDD usa subagentes nativos vía el permiso `task`. El plugin legacy `background-agents.ts` ya NO se instala por default. Para opt-in al modo background experimental: `export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` antes de lanzar OpenCode (gentle-ai no escribe env vars de proceso en `opencode.json`).

## 26.6 — Per-phase models en otros harnesses `[CERT]`

OpenCode no es el único con asignación per-fase. El configurador la materializa distinto en tres harnesses más (ver [Bloque 25] §25.7):

### 26.6.1 — Codex profiles (separate-file) `[CERT]`

gentle-ai escribe profiles de selección de modelo como archivos separados `~/.codex/<name>.config.toml` (mecanismo separate-file de Codex >= 0.134.0), seleccionados en runtime vía `codex --profile <name>` `[CERT]` (`gentle-ai:docs/agents.md:143-149`):

| Profile | `model_reasoning_effort` | Fases SDD `[CERT]` |
|---------|--------------------------|---------------------|
| `sdd-strong` | `xhigh` | propose, design, verify, judge |
| `sdd-mid` | `high` | spec, tasks, apply |
| `sdd-cheap` | `low` | explore, archive, onboard |

### 26.6.2 — Kiro model assignments `[CERT]`

gentle-ai resuelve el campo `model:` durante la inyección desde Kiro model assignments (`auto|opus|sonnet|haiku|minimax|glm|deepseek|qwen`) a model IDs Kiro-nativos, estampándolo en cada `~/.kiro/agents/sdd-{phase}.md` en sync time `[CERT]` (`gentle-ai:docs/agents.md:65,83`, `docs/kiro.md:99`).

### 26.6.3 — Pi model assignments `[CERT]`

Owned por `gentle-pi`, no por el installer. Vía `/gentleman:models` (alias `/gentle-ai:models`): modal Pi-nativo para project/user/built-in agents, prioriza SDD agents, guarda `.pi/gentle-ai/models.json` y aplica overrides en `.pi/agents/*.md` o `.pi/settings.json` `[CERT]` (`gentle-ai:docs/agents.md:241`, `docs/pi.md:104-135`).

## 26.7 — Backups automáticos `[CERT]`

Cada `install`, `sync` y `upgrade` snapshotea automáticamente los archivos de config `[CERT]` (`gentle-ai:README.md:163`). Propiedades:

| Propiedad | Comportamiento `[CERT]` |
|-----------|--------------------------|
| Compresión | tar.gz |
| Deduplicación | configs idénticas NO se re-backupean |
| Auto-prune | mantiene los **5 más recientes** |
| Pin | vía TUI (tecla `p`) para proteger backups del prune |

Detalle completo en `docs/rollback.md` `[CERT]` (`gentle-ai:README.md:165`). En el layout del codebase, el paquete responsable es `internal/backup/` (Config snapshot + restore) `[CERT]` (`gentle-ai:docs/architecture.md:21`).

**Modelo mental** `[INFER]`: el backup es un seguro transaccional alrededor de cada operación mutante. El dedup evita ruido (configs sin cambios no generan snapshot), el prune-a-5 acota el crecimiento, y el pin es el escape hatch para retener un snapshot importante fuera de la ventana rotativa.

## 26.8 — Startup hooks: mantener fresco el skill-registry `[CERT]`

Los startup hooks mantienen el skill-registry fresco para agentes que soportan hooks `[CERT]` (`gentle-ai:README.md:110`):

> *"Startup hooks normally keep the skill registry fresh for agents that support hooks, including **Codex, Claude Code, OpenCode, and Pi through `gentle-pi`**."*

**Excepción Pi `-ns`** `[CERT]` (`gentle-ai:README.md:110`, `docs/pi.md:150`, `docs/agents.md:238`): si arrancás Pi con `pi -ns`, el startup skill loading/hooks se **saltea**, así que el trabajo de `gentle-pi` en `session_start` (asset checks, skill-registry refresh) no corre automáticamente — hay que correr el registry refresh manualmente.

Para Pi, el hook concreto es `gentle-pi session_start` `[CERT]` (`gentle-ai:docs/pi.md:139-148`): copia assets project-local SIN sobreescribir ediciones locales — `.pi/agents/sdd-*.md`, `.pi/chains/sdd-*.chain.md`, `.pi/gentle-ai/support/strict-tdd.md`, `.pi/gentle-ai/support/strict-tdd-verify.md`. Para reemplazar copias locales con la versión del package: `/gentle-ai:install-sdd --force`.

**Implicación** `[INFER]`: el skill-registry es un artefacto que se degrada (skills nuevas, convenciones de proyecto cambiantes). Los hooks lo mantienen fresco sin intervención; cuando el hook no corre (`pi -ns`, harness sin hooks), el refresh manual (`gentle-ai skill-registry refresh`) es el fallback. Esto conecta con el Skill Resolver del [Bloque 22]: el registry que los hooks refrescan es la fuente que el orquestador resuelve para inyectar paths de skill a los sub-agentes.

## 26.9 — `state.json` en `~/.gentle-ai/` `[CERT]`

El configurador trackea el estado de instalación. `gentle-ai doctor` lo lee como parte del health check read-only, junto a binarios de tools, alcance de Engram y espacio en disco `[CERT]` (`gentle-ai:README.md:112`). En el layout del codebase, el paquete responsable es `internal/state/` (Installation state tracking) `[CERT]` (`gentle-ai:docs/architecture.md:29`).

El directorio `~/.gentle-ai/` aloja también `~/.gentle-ai/cache/model-variants.json` (cache de variantes de reasoning effort, ver §26.5.4) `[CERT]` (`gentle-ai:docs/opencode-profiles.md:48`). **El `state.json` exacto (esquema, campos) NO está documentado en las fuentes leídas** `[CERT-a]` — el README lo menciona como objeto de `doctor` pero no publica su estructura; quedaría por verificar en el código Go (`internal/state/`).

## 26.10 — Arquitectura del codebase Go `[CERT]`

`docs/architecture.md` publica el layout `[CERT]` (`gentle-ai:docs/architecture.md:9-36`). Paquetes relevantes a la configuración:

| Paquete | Responsabilidad `[CERT]` |
|---------|---------------------------|
| `cmd/gentle-ai/` | CLI entrypoint |
| `internal/app/` | Command dispatch + runtime wiring |
| `internal/catalog/` | Registry definitions (agents, skills, components) |
| `internal/cli/` | Install flags, validation, orchestration, dry-run |
| `internal/installcmd/` | Resolver de comando por perfil (brew/apt/pacman/dnf/winget/go install) |
| `internal/pipeline/` | Ejecución por etapas + orquestación de rollback |
| `internal/backup/` | Config snapshot + restore (ver §26.7) |
| `internal/assets/` | Skill files embebidos + persona templates |
| `internal/components/` | Lógica de install/inject por componente: `engram/ sdd/ skills/ mcp/ persona/ theme/ permissions/ gga/` + `filemerge/` (merge marker-based sin clobber) |
| `internal/agents/` | Adapters por agente (config strategy per agente): `claude/ opencode/ gemini/ cursor/ vscode/ codex/ windsurf/ antigravity/` |
| `internal/opencode/` | Utilidades de parsing de modelo/config OpenCode |
| `internal/state/` | Installation state tracking (ver §26.9) |
| `internal/update/` | Self-update + upgrade logic |
| `internal/verify/` | Post-apply health checks + reporting |
| `internal/tui/` | TUI Bubbletea (tema Rose Pine) |

**Patrón de inyección** `[CERT]` (`gentle-ai:docs/architecture.md:24`): `internal/components/filemerge/` hace "marker-based file merging (inject without clobbering)" — es lo que permite escribir secciones gentle-ai en archivos compartidos (CLAUDE.md, SOUL.md, GEMINI.md) sin destruir contenido del usuario, usando marcadores como `<!-- gentle-ai:sdd-orchestrator -->` (ver [Bloque 25] §25.5, Hermes SOUL.md).

**Nota de cobertura** `[CERT-a]`: el doc de architecture lista 8 adapters de agente bajo `internal/agents/` (claude, opencode, gemini, cursor, vscode, codex, windsurf, antigravity) y afirma "All 8 agent adapters have unit tests" (`gentle-ai:docs/architecture.md:63`). Pero la Agent Matrix soporta 16 harnesses (ver [Bloque 25]) — los harnesses más nuevos (Kilo, Kimi, Kiro, Qwen, OpenClaw, Trae, Pi, Hermes) usan adapters/estrategias no listadas en este layout, probablemente porque el doc no se actualizó o porque reusan el adapter OpenCode-compatible (Kilo) y estrategias genéricas `[INFER]`.

## 26.11 — Componentes y plugins de comunidad `[CERT]`

El configurador instala **componentes** seleccionables (Engram, SDD, skills, MCP, persona, theme, permissions, GGA) `[CERT]` (`gentle-ai:docs/architecture.md:23`, `docs/non-interactive.md:48`). Para OpenCode, ofrece registrar plugins de comunidad `[CERT]` (`gentle-ai:README.md:234-237`): `sub-agent-statusline` y `sdd-engram-plugin`. gentle-ai solo asegura que `~/.config/opencode/tui.json` exista y agrega los nombres de package al array `plugin`; OpenCode instala/carga esos packages en el siguiente arranque. Una vez materializado bajo `~/.config/opencode/node_modules/`, `gentle-ai update` compara la versión local del `package.json` con los releases de GitHub del plugin `[CERT]`.

## 26.12 — Conexiones

- **[Bloque 25] — Distribución multi-agente**: este bloque es la contraparte del [Bloque 25]. [Bloque 25] documenta QUÉ se distribuye a cada harness y sobre qué mecanismo de delegación corre; este bloque documenta el BINARIO que distribuye (install/sync/upgrade) y la asignación per-phase de modelo. Los adapters de `internal/agents/` (§26.10) son lo que materializa la "config strategy per agente" del [Bloque 25] §25.5.
- **[Bloque 3] — Backends + topic keys**: el componente `internal/components/engram/` (§26.10) provisiona el backend Engram que el [Bloque 3] introduce filosóficamente. El configurador es quien instala/wirea Engram (MCP, instrucciones); el [Bloque 3] describe cómo el runtime lo usa.
- **[Bloque 15] — Status + dispatcher nativo**: el dispatcher nativo de status SDD (`gentle-ai sdd-status`/`sdd-continue`) que [Bloque 15] documenta es un comando del MISMO binario descrito acá. El `state.json` (§26.9) y el `internal/state/` son el sustrato de tracking que alimenta ese status.
- **[Bloque 19] — Contrato de persistencia**: la asignación de `--sdd-mode single|multi` (§26.2.2) y los profiles (§26.5) determinan en qué modo corre el orquestador, lo que conecta con cómo el contrato de persistencia resuelve `artifact_store.mode` ([Bloque 19] §19.1).
- **[Bloque 22] — Skill-resolver + phase-common**: los startup hooks (§26.8) y `gentle-ai skill-registry refresh` mantienen fresco el registry que el Skill Resolver del [Bloque 22] consume. El configurador produce el artefacto; el resolver lo lee para inyectar paths a sub-agentes.
- **[Bloque 23] — Strict-TDD**: `/sdd-init` (§26.2.1) detecta capacidades de testing y activa Strict TDD Mode, cuyo protocolo se documenta en [Bloque 23]. El configurador es el punto donde esa detección se cablea.
</content>
</invoke>
