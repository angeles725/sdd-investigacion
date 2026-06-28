# Bloque 4 — Fase `sdd-init`

> **Qué documenta:** la fase de inicialización del sistema SDD de gentle-ai — el bootstrap que detecta el stack, construye el skill-registry, resuelve Strict TDD y persiste el contexto del proyecto antes de cualquier otra fase.
> **Alcance:** propósito, qué lee / qué escribe (artefactos + topic keys), inputs requeridos vs opcionales, los 7 pasos de ejecución, Result Contract, modelo asignado, gotchas. Detección de stack, skill-registry y activación de Strict TDD están cubiertos en detalle.
> **Fuentes exactas leídas:**
> - `/home/cristian/.config/opencode/skills/sdd-init/SKILL.md` (contrato runtime — primaria)
> - `/home/cristian/.config/opencode/skills/sdd-init/references/init-details.md` (checklist de detección, payloads Engram, skeleton config, templates)
> - `/home/cristian/.claude/agents/sdd-init.md` (definición del sub-agente: tools, modelo)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-init.md` (prompt canónico — idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-init.md` (comando del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (protocolo común)
> **Método + leyenda de marcadores:**
> - `[CERT]` = verificado leyendo el archivo, con cita `ruta:línea` o `ruta §sección`.
> - `[CERT-a]` = afirmado por una fuente, no re-verificado contra el origen primario que esa fuente describe.
> - `[INFER]` = deducción propia a partir de la evidencia.

---

## 4.1 — Propósito y posición en el DAG `[CERT]`

`sdd-init` inicializa el contexto SDD de un proyecto: detecta stack/convenciones/arquitectura, detecta capacidades de testing, resuelve Strict TDD, construye el skill-registry e inicializa el backend de persistencia `[CERT]` `skills/sdd-init/SKILL.md:3` (description) y `:58-66` (Execution Steps).

Es la fase **cero**: no aparece en el grafo de dependencias lineal `proposal → specs → tasks → apply → verify → archive`, sino que es un prerrequisito transversal exigido antes de cualquier comando SDD. El orquestador la corre silenciosamente si no existe (ver Conexiones con [Bloque 18]). Su `next_recommended` apunta a `sdd-explore` o `sdd-new` `[CERT]` `agents/sdd-init.md:40` y `SKILL.md:70`.

El sub-agente es un EXECUTOR puro: hace el trabajo él mismo, no delega, no actúa como orquestador `[CERT]` `agents/sdd-init.md:11-12` ("Do NOT call the Task tool. Do NOT launch sub-agents.") y `SKILL.md:32-33`.

### Doble gate orquestador/executor `[CERT]`

El SKILL.md abre con un **ORCHESTRATOR GATE**: si se cargó vía el tool `skill()`, el lector ES el orquestador y debe DETENERSE y delegar al sub-agente dedicado `[CERT]` `SKILL.md:13-17`. El **Executor Override** inmediato aclara: si ya sos el sub-agente `sdd-init`, el gate no aplica — ejecutá `[CERT]` `SKILL.md:19-21`. Este patrón gate+override se repite idéntico en las 5 fases de planificación (init/explore/propose/spec/design).

## 4.2 — Qué lee y qué escribe `[CERT]`

| Acción | Recurso | Topic key / ruta | Obligatoriedad |
|---|---|---|---|
| LEE | Archivos de proyecto (`package.json`, `go.mod`, `pyproject.toml`, CI, lint/test config) | filesystem | requerido `[CERT]` `SKILL.md:60` |
| LEE | Marcador de Strict TDD del agente / `openspec/config.yaml` | filesystem | opcional `[CERT]` `SKILL.md:62` |
| LEE | Directorios de skills user + project (scan) | múltiples rutas | requerido `[CERT]` `init-details.md:11-19` |
| ESCRIBE | Contexto del proyecto detectado | `sdd-init/{project}` | requerido `[CERT]` `init-details.md:33-35`, `agents/sdd-init.md:28-32` |
| ESCRIBE | Capacidades de testing | `sdd/{project}/testing-capabilities` (Engram) o `openspec/config.yaml` `testing:` | requerido `[CERT]` `SKILL.md:41`, `init-details.md:38-40` |
| ESCRIBE | Skill registry (índice) | `.atl/skill-registry.md` + Engram `skill-registry` | requerido `[CERT]` `SKILL.md:42`, `init-details.md:43-46` |
| ESCRIBE | (openspec/hybrid) skeleton de archivos | `openspec/config.yaml`, `specs/`, `changes/archive/` | condicional al modo `[CERT]` `init-details.md:50-59` |

**Inputs requeridos del orquestador** `[CERT]`: el modo de artifact store (`engram | openspec | hybrid | none`) resuelto en el Session Preflight; el comando prohíbe hardcodear Engram `[CERT]` `commands/sdd-init.md:18` ("Use the resolved artifact store... do not hardcode Engram").

**Inputs opcionales** `[INFER]`: convenciones del proyecto (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`) son escaneadas si existen pero su ausencia no bloquea.

Los tres saves de Engram declaran `type` distinto: `sdd-init/{project}` → `architecture`; `testing-capabilities` → `config`; `skill-registry` → `config`, todos con `capture_prompt: false` cuando el schema lo soporta `[CERT]` `init-details.md:33-46`.

## 4.3 — Detección de stack y capacidades de testing `[CERT]`

El checklist de detección (paso 1-2) cubre `[CERT]` `init-details.md:3-8`:

- **Test runner:** scripts/deps de `package.json`, `pyproject.toml`, `pytest.ini`, `go.mod`, `Cargo.toml`, `Makefile`.
- **Test layers:** unit (runner); integración (`testing-library`, `httpx`, `httptest`, `WebApplicationFactory`); E2E (`playwright`, `cypress`, `selenium`, `chromedp`).
- **Coverage:** `vitest --coverage`, `jest --coverage`, `c8`, `pytest-cov`, `go test -cover`, `coverlet`.
- **Quality:** linter, type checker, formatter.

El resultado se persiste con el formato tabular de `init-details.md:62-94` `[CERT]`: una tabla **Test Layers** (Unit/Integration/E2E × Available × Tool), una sección **Coverage** y una tabla **Quality Tools** (Linter/Type checker/Formatter). El encabezado declara `**Strict TDD Mode**: {enabled/disabled}` y la fecha de detección.

Hard rule: *"Detect the real stack... never guess"* `[CERT]` `SKILL.md:37`. La detección nunca es presuntiva.

## 4.4 — Resolución de Strict TDD `[CERT]`

El paso 3 resuelve Strict TDD con una jerarquía de fuentes precisa `[CERT]` `SKILL.md:62` y la tabla de Decision Gates `SKILL.md:54-56`:

| Input | Acción |
|---|---|
| marcador/config de Strict TDD encontrado | usar ESE valor |
| sin marcador pero existe test runner | default `strict_tdd: true` |
| sin test runner | `strict_tdd: false` + explicar que no está disponible |

Orden de precedencia `[CERT]` `SKILL.md:62`: (1) marcador del agente → (2) `openspec/config.yaml` → (3) fallback por runner detectado → (4) fallback sin runner. La consecuencia práctica: **un proyecto con runner pero sin configuración explícita activa Strict TDD por defecto** `[INFER]` — esto luego es leído por `sdd-apply`/`sdd-verify` vía el topic key de testing-capabilities (ver [Bloque 23]).

## 4.5 — Skill Registry: scan e indexación `[CERT]`

El paso 5 construye `.atl/skill-registry.md` siguiendo las Skill Registry Scan Rules `[CERT]` `init-details.md:10-19`:

- **Scan de skills de usuario:** `~/.config/opencode/skills/`, `~/.claude/skills/`, `~/.gemini/skills/`, `~/.cursor/skills/`, `~/.codex/skills/`, y ~15 rutas más por agente `[CERT]` `init-details.md:12`.
- **Scan de skills de proyecto:** `{root}/skills/`, `.opencode/skills/`, `.claude/skills/`, `.agent/skills/`, `.atl/skills/`, etc. `[CERT]` `init-details.md:13`.
- **Filtrado:** se saltan `sdd-*`, `_shared` y `skill-registry`; se deduplica por nombre **prefiriendo project-level sobre user-level** `[CERT]` `init-details.md:14`.
- **Extracción por skill:** `name`, texto de trigger del `description`, ruta completa del `SKILL.md`, y scope `[CERT]` `init-details.md:16`.
- **Convenciones de proyecto:** escanea `agents.md`/`AGENTS.md`, `CLAUDE.md` de proyecto, `.cursorrules`, `GEMINI.md`, `copilot-instructions.md`; para índices como `AGENTS.md` extrae las rutas referenciadas e incluye índice + archivos `[CERT]` `init-details.md:18-19`.

Principio clave `[CERT]` `init-details.md:17`: *"Treat the registry as an index, not a generated summary; subagents receive exact paths and read the full skill source of truth."* — esto es la base del Skill Resolver Protocol del orquestador (ver [Bloque 22]): se pasan RUTAS, no resúmenes.

El registry también se guarda en Engram como `skill-registry` cuando está disponible `[CERT]` `SKILL.md:42`.

## 4.6 — Decision Gates por modo de persistencia `[CERT]`

La tabla de Decision Gates gobierna qué se escribe según el modo `[CERT]` `SKILL.md:48-56`:

| Modo | Acción |
|---|---|
| `engram` | guardar contexto y capabilities solo en Engram; **NO** crear `openspec/` |
| `openspec` | crear/actualizar archivos bootstrap de openspec siguiendo `_shared/openspec-convention.md` |
| `hybrid` | hacer ambos (Engram + openspec) |
| `none` | devolver contexto detectado; no escribir artefactos SDD excepto registry si se requiere |

Hard rules de refuerzo `[CERT]` `SKILL.md:38-44`: en `engram` **no** crear `openspec/`; testing-capabilities siempre se persiste por separado; siempre construir `.atl/skill-registry.md`; **si `openspec/` ya existe, reportar y preguntar antes de actualizar** `[CERT]` `SKILL.md:44`.

El OpenSpec skeleton `[CERT]` `init-details.md:50-59`: `openspec/config.yaml` + `specs/` + `changes/archive/`. El `config.yaml` lleva contexto conciso (`context:` bajo 10 líneas), `strict_tdd`, testing capabilities y reglas de fase para proposal/spec/design/tasks/apply/verify/archive.

## 4.7 — Los 7 pasos de ejecución `[CERT]`

`[CERT]` `SKILL.md:58-66`:

1. Inspeccionar archivos del proyecto y resumir stack/convenciones.
2. Detectar test runner, layers, coverage, linter, type checker, formatter.
3. Resolver Strict TDD (marcador → config → runner → sin-runner).
4. Inicializar persistencia para el modo resuelto.
5. Construir `.atl/skill-registry.md` con las scan rules.
6. Persistir testing capabilities y contexto del proyecto.
7. Devolver el envelope estructurado de inicialización.

El prompt canónico (`agents/sdd-init.md`) comprime esto a 4 pasos operativos `[CERT]` `agents/sdd-init.md:19-24` (detectar stack → inicializar backend → construir registry → guardar contexto), delegando el detalle al SKILL.md que ordena leer y seguir `~/.claude/skills/sdd-init/SKILL.md` exactamente `[CERT]` `agents/sdd-init.md:16`.

## 4.8 — Result Contract `[CERT]`

El Output Contract del SKILL pide devolver `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, e incluir: proyecto, stack, modo de persistencia, estado de Strict TDD, tabla de testing capabilities, IDs/paths de observaciones guardadas, ruta del registry y el siguiente paso `/sdd-explore` o `/sdd-new` `[CERT]` `SKILL.md:68-70`.

El prompt del agente formaliza los campos `[CERT]` `agents/sdd-init.md:36-42`:

| Campo | Valores / contenido |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase de qué se inicializó |
| `artifacts` | paths/topic_keys (`.atl/skill-registry.md`, `sdd-init/{project}`) |
| `next_recommended` | `sdd-explore` o `sdd-new` |
| `risks` | warnings sobre stack o backend detectado |
| `skill_resolution` | `paths-injected` si se pasaron rutas exactas, si no `none` |

**Gotcha de discrepancia `[CERT]`:** el `status` del agente usa `done | blocked | partial` `agents/sdd-init.md:37`, pero el Return Envelope común (`sdd-phase-common.md §D`) define `success | partial | blocked` `[CERT]` `sdd-phase-common.md:76`. Las fases declaran `done` en su prompt pero el contrato compartido dice `success`. `[INFER]` el orquestador trata ambos como éxito.

## 4.9 — Modelo asignado `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-init.md:7`. La tabla de Model Assignments del orquestador no lista `sdd-init` explícitamente, por lo que cae en el row `default → sonnet` `[CERT-a]` (CLAUDE.md, Model Assignments). El razonamiento `[INFER]`: init es trabajo estructural-mecánico (detección por patrones, scan de directorios, escritura de un índice), no decisiones de arquitectura — coherente con la justificación que la tabla da para fases sonnet ("Reads code, structural - not architectural").

Tools del agente `[CERT]` `agents/sdd-init.md:8`: `Read, Edit, Write, Glob, Grep, Bash` + `mem_search, mem_get_observation, mem_save, mem_update`. Es la fase de planificación con **más tools** porque necesita Bash (inspeccionar archivos del proyecto, ejecutar detección) y Write (escribir `.atl/skill-registry.md` y skeleton openspec).

## 4.10 — Gotchas y reglas especiales `[CERT]`

- **Lanzamiento silencioso:** el orquestador corre init automáticamente si no existe, sin preguntar al usuario `[CERT-a]` (CLAUDE.md, SDD Init Guard: *"just run init silently if needed"*).
- **Gate de Session Preflight:** el comando exige que el preflight (execution mode, artifact store, chained PR strategy, review budget) esté completo antes de lanzar init; si falta, pregunta y DETIENE en el mismo turno `[CERT]` `commands/sdd-init.md:16`.
- **`openspec/` preexistente:** no se sobreescribe a ciegas — reportar y preguntar `[CERT]` `SKILL.md:44`.
- **`capture_prompt: false`:** obligatorio en todos los saves automatizados de init/config; omitir el campo si el schema viejo no lo soporta, nunca fallar por eso `[CERT]` `SKILL.md:43`, `agents/sdd-init.md:32`.
- **Workspace authority:** el comando resuelve el workspace con `git rev-parse --show-toplevel || pwd` porque en OpenCode Desktop (Electron) la interpolación en parse-time apunta al app data dir, no al proyecto `[CERT]` `commands/sdd-init.md:11`.

---

## 4.11 — Conexiones

- **[Bloque 5] (`sdd-explore`):** sucesor recomendado por defecto. init produce `sdd-init/{project}`, que explore lee opcionalmente como contexto de proyecto `[CERT]` `skills/sdd-explore/SKILL.md:46,55`.
- **[Bloque 2] (DAG + Result Contract):** init devuelve el mismo envelope de 6 campos que toda fase, aunque con la discrepancia `status` documentada en §4.8.
- **[Bloque 3 / Bloque 19] (backends + topic keys / persistence-contract):** init es quien materializa el backend elegido (engram/openspec/hybrid/none) y siembra los topic keys raíz `sdd-init/{project}`, `sdd/{project}/testing-capabilities`, `skill-registry`.
- **[Bloque 18] (delegación + triggers + models):** el SDD Init Guard del orquestador fuerza la corrida de init antes de cualquier otro comando SDD; el modelo `sonnet` sale del row `default` de la tabla de Model Assignments.
- **[Bloque 22] (skill-resolver + phase-common):** el `.atl/skill-registry.md` que init construye es la fuente que el Skill Resolver Protocol consulta para inyectar rutas exactas en cada delegación. init implementa el principio "índice, no resumen".
- **[Bloque 23] (strict-TDD):** la resolución de Strict TDD en §4.4 produce el `strict_tdd: true/false` que el orquestador propaga (Strict TDD Forwarding) a `sdd-apply`/`sdd-verify`.
