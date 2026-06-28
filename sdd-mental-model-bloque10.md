# Bloque 10 — Fase `sdd-apply` (+ apply-progress continuity)

> **QUÉ**: Documenta la fase `sdd-apply` del sistema SDD de gentle-ai: la IMPLEMENTACIÓN. Recibe tareas de `tasks.md` y escribe código real siguiendo specs y design estrictamente, marca tareas completas, y persiste un `apply-progress` que sobrevive entre batches mediante un protocolo read-merge-write.
>
> **ALCANCE**: Propósito, qué lee/escribe (artefacto + topic key), el Status & Workspace Guard, el enforcement del Review Workload Decision, la continuidad de apply-progress (read-merge-write, NO overwrite), el forwarding de strict TDD, el chequeo y marcado de tareas, modelo asignado, Result Contract y gotchas. NO cubre el detalle del módulo strict-TDD (eso es [Bloque 23]) ni la verificación (eso es [Bloque 11]).
>
> **FUENTES exactas**:
> - `/home/cristian/.config/opencode/skills/sdd-apply/SKILL.md` (primaria, v3.0)
> - `/home/cristian/.claude/agents/sdd-apply.md` (tools, modelo, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-apply.md` (versión CONDENSADA — diverge del SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-apply.md` (gates del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (Secciones A–E)
> - NOTA: `sdd-apply/strict-tdd.md` se documenta en [Bloque 23], NO aquí; solo se menciona su carga.
>
> **MÉTODO**: lectura directa. Marcadores: `[CERT]` = verificado (`ruta:línea`); `[CERT-a]` = afirmado por fuente; `[INFER]` = deducción.

---

## 10.1 — Propósito y rol `[CERT]`

`sdd-apply` es un sub-agente EJECUTOR (IMPLEMENTER): recibe tareas específicas de `tasks.md` y las implementa escribiendo código real, siguiendo specs y design estrictamente (`skills/sdd-apply/SKILL.md:32-34`). Es la única fase que muta archivos del proyecto fuera de los artefactos SDD.

Mismo patrón ORCHESTRATOR GATE / Executor Override que el resto (`SKILL.md:13-21`). `delegate_only: true`, `disable-model-invocation: true`, `user-invocable: false` (`SKILL.md:4-10`). Versión `3.0` (`SKILL.md:9`).

## 10.2 — Lo que recibe del orquestador `[CERT]`

`SKILL.md:36-43`:

| Entrada | Detalle |
|---------|---------|
| Change name | nombre del cambio |
| Task(s) específicas | ej. "Phase 1, tasks 1.1-1.3" |
| Artifact store mode | `engram` \| `openspec` \| `hybrid` \| `none` |
| Structured status | de `_shared/sdd-status-contract.md` ([Bloque 22]): `schemaName`, `planningHome`, `changeRoot`, `artifactPaths`, `contextFiles`, `applyState`, task progress, dependency states, `actionContext` |
| Delivery strategy + workload decision resuelta | `ask-on-risk`/`auto-chain`/`single-pr`/`exception-ok`, más PR slice o `size:exception` si aplica |

## 10.3 — Qué LEE y qué ESCRIBE `[CERT]`

`SKILL.md:45-52`:

| Modo | Lee (todos requeridos) | Escribe |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `/spec`, `/design`, `/tasks` (guarda el ID de tasks para updates) | `sdd/{change}/apply-progress` + `mem_update` sobre tasks |
| `openspec` | sigue `openspec-convention.md` | actualiza `tasks.md` con marcas `[x]` |
| `hybrid` | ambos | Engram (`mem_update` tasks) + `tasks.md` con `[x]` |
| `none` | retorna solo progreso | nada (no actualiza artefactos) |

**Artefacto producido**: `apply-progress` · **topic key**: `sdd/{change-name}/apply-progress` · **type**: `architecture` (`SKILL.md:179-182`, [Bloque 3]).

Doble escritura clave: `sdd-apply` (a) **persiste `apply-progress`** Y (b) **marca tasks como `[x]`** vía `mem_update` (engram) o edición de archivo (openspec/hybrid) (`SKILL.md:182`). El marcado de tasks es responsabilidad exclusiva de esta fase (`agents/sdd-apply.md:39`).

## 10.4 — Status & Workspace Guard `[CERT]`

Antes de leer archivos de implementación o escribir código, consume el structured status (`SKILL.md:54-64`):

| `applyState` | Acción |
|--------------|--------|
| `blocked` | STOP, retorna `blocked` con artefactos faltantes o contexto inseguro |
| `all_done` | no edita; retorna `success` con `next_recommended: sdd-verify` o `sdd-archive` |
| `ready` | procede solo en las tareas pending asignadas |

Guards de workspace (`SKILL.md:62-64`): si `actionContext.mode` es `workspace-planning` y `allowedEditRoots` está vacío, STOP antes de editar (repos/folders enlazados son read-only). Si `allowedEditRoots` está presente, editar solo bajo esos roots; cualquier edit fuera → STOP y reportar ruta insegura.

## 10.5 — Pasos de ejecución `[CERT]`

`SKILL.md:66-190`:

1. **Step 1 — Load Skills** (Sección A).
2. **Step 2 — Read Context**: confirmar `applyState: ready`; leer cada `contextFiles`; leer specs (QUÉ debe hacer el código), design (CÓMO estructurarlo), código existente (patrones actuales), convenciones de `config.yaml` (`SKILL.md:70-78`).
3. **Step 2a — Enforce Review Workload Decision** (ver 10.6).
4. **Step 2b — Read Previous Apply-Progress** (ver 10.7).
5. **Step 3 — Read Testing Capabilities & Resolve Mode** (ver 10.8).
6. **Step 4 — Implement Tasks (Standard Workflow)** — solo si strict TDD NO está activo.
7. **Step 5 — Mark Tasks Complete**: cambiar `- [ ]` a `- [x]`.
8. **Step 6 — Persist Progress** (MANDATORIO) + Merge Protocol.
9. **Step 7 — Return Summary**: re-leer el artefacto tasks persistido y confirmar `[x]` antes de retornar.

## 10.6 — Step 2a: Enforce Review Workload Decision `[CERT]`

Antes de implementar, inspecciona el `Review Workload Forecast` del artefacto tasks ([Bloque 9]). Si dice cualquiera de (`SKILL.md:80-100`):

- `400-line budget risk: High`
- `Chained PRs recommended: Yes`
- `Decision needed before apply: Yes`

…entonces DEBE confirmar que el orquestador/usuario proveyó un delivery path resuelto:

| Caso | Acción |
|------|--------|
| `auto-chain` / chained/stacked elegido | implementar solo el work-unit slice asignado, scope autónomo, reportar el PR boundary; seguir `Chain strategy` para el targeting de ramas |
| `exception-ok` / single PR con excepción | continuar solo si el prompt dice explícitamente que el maintainer acepta `size:exception` |
| `single-pr` sobre budget | continuar solo tras registrar `size:exception` |

Además chequea `Chain strategy` (`SKILL.md:96-98`): `stacked-to-main` (cada PR apunta al PR previo, o a `main` tras merge) vs `feature-branch-chain` (PR #1 → tracker; siguientes → PR previo inmediato; los diffs hijos nunca apuntan a `main` directo).

> [CERT] Si NI la decisión de entrega NI la chain strategy están presentes, STOP antes de escribir código y retornar `blocked` con: *"Workload decision required before apply: estimated work may exceed 400 changed lines. Ask the user which chain strategy to use..."* (`SKILL.md:100`). El prompt condensado lo reafirma: "If workload forecast says >400 lines or `Chained PRs recommended`, STOP and return `blocked: workload-decision-required`" (`prompts/sdd/sdd-apply.md:25`).

Esto conecta directamente con [Bloque 17] (delivery/chain) y con el Review Workload Guard del orquestador en [Bloque 16].

## 10.7 — Step 2b: Apply-Progress Continuity (read-merge-write) `[CERT]`

El mecanismo distintivo de esta fase. La implementación puede correr en múltiples batches; el progreso NO debe perderse. `SKILL.md:102-112`:

1. `mem_search(query: "sdd/{change-name}/apply-progress", project: "{project}")`.
2. Si se encuentra: `mem_get_observation(id)` → leer contenido completo.
3. Parsear qué tareas ya están marcadas completas.
4. Saltar esas tareas — empezar desde la primera incompleta.
5. Al guardar en Step 6, **MERGE**: incluir todas las tareas previamente completadas MÁS las nuevas en un único artefacto combinado.

> [CERT] **CRITICAL**: "If the orchestrator told you previous progress exists, you MUST read it. If you overwrite without reading, completed work from prior batches is permanently lost" (`SKILL.md:112`).

### Merge Protocol (Step 6) `[CERT]`

`SKILL.md:184-189`: al guardar apply-progress, (1) si se leyó progreso previo en 2b, el artefacto DEBE incluir TODAS las tareas previamente completas (copiar status y evidencia) MÁS las nuevas; (2) el artefacto final muestra el estado acumulado de TODAS las tareas en TODOS los batches; (3) misma estructura, ninguna tarea completa de batches previos se pierde.

> [CERT-a] El orquestador refuerza esto desde su lado (CLAUDE.md §"Apply-Progress Continuity"): cuando lanza un batch de continuación, busca apply-progress existente e instruye al sub-agente: *"You MUST read it first... merge... Do NOT overwrite — MERGE."* El sub-agente es responsable del read-merge-write; el orquestador le avisa que existe progreso previo.

El prompt condensado lo confirma: "If previous apply-progress exists, read it via mem_search + mem_get_observation and MERGE before saving" (`prompts/sdd/sdd-apply.md:26`).

## 10.8 — Step 3: Strict TDD Forwarding `[CERT]`

`SKILL.md:114-145`. Lee las testing capabilities cacheadas para resolver el modo:

```
├── engram: mem_search("sdd/{project}/testing-capabilities") → mem_get_observation
├── openspec: openspec/config.yaml → strict_tdd + testing section
└── Fallback: package.json, go.mod, etc.
```

Resolución de modo:

| Condición | Modo |
|-----------|------|
| `strict_tdd: true` AND existe test runner | **STRICT TDD MODE** → carga y sigue `strict-tdd.md` ([Bloque 23]) |
| `strict_tdd: false` OR no hay runner | **STANDARD MODE** → usa Step 4, sin módulo TDD cargado |

> [CERT] "If Strict TDD Mode is not active, ZERO TDD instructions are loaded. The `strict-tdd.md` module is never read, never processed, never consumes tokens" (`SKILL.md:135`).

### Hard Gate (solo Strict TDD) `[CERT]`

Si Strict TDD está activo (por inyección del orquestador o auto-descubrimiento) (`SKILL.md:137-145`):

- DEBE producir una tabla **TDD Cycle Evidence** en el artefacto apply-progress.
- Cada fila de tarea: RED (test escrito primero) → GREEN (implementación pasa) → REFACTOR.
- Si completa una tarea SIN escribir tests primero, marcarla FAILED en la tabla.
- La fase verify RECHAZA el trabajo si la tabla TDD falta o está incompleta.
- "There is no silent fallback" — si resolviste Strict TDD activo, lo seguís o reportás fallo; NO cambiás silenciosamente a Standard (`SKILL.md:145`).

> [CERT-a] El orquestador hace forwarding obligatorio (CLAUDE.md §"Strict TDD Forwarding"): busca `sdd-init/{project}`, y si `strict_tdd: true` añade al prompt *"STRICT TDD MODE IS ACTIVE. Test runner: {test_command}. You MUST follow strict-tdd.md..."*. NON-NEGOTIABLE. El detalle del cycle (RED→GREEN→TRIANGULATE→REFACTOR) vive en [Bloque 23].

## 10.9 — Steps 4–7: Implementar, marcar, persistir, verificar `[CERT]`

- **Step 4 (Standard)**: por cada tarea — leer descripción, escenarios de spec (criterios de aceptación), decisiones de design (restricciones), patrones de código existente; escribir el código; marcar `[x]` inmediatamente; notar deviaciones (`SKILL.md:147-160`).
- **Step 5**: cambiar `- [ ]` → `- [x]` para tareas completadas (`SKILL.md:162-172`).
- **Step 6**: persistir apply-progress + actualizar tasks con `[x]` + Merge Protocol.
- **Step 7**: ANTES de retornar, **re-leer el artefacto tasks persistido** y confirmar que toda tarea reportada como completa está marcada `[x]` ahí. Si sigue como `- [ ]`, corregir el checkbox. "Do not report `Ready for verify` while completed work is only reflected in internal todos or apply-progress" (`SKILL.md:191-193`). Los internal todos NO son evidencia de completitud (`SKILL.md:245`).

## 10.10 — Modelo asignado y tools `[CERT]`

`agents/sdd-apply.md:7`: `model: sonnet` (Model Assignments [Bloque 18]: "sdd-apply | sonnet | default | Implementation").

**Tools** (`agents/sdd-apply.md:8`): `Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update`. Notar: tiene **Bash** (ejecuta código/tests) y **mem_update** (marca tasks `[x]`) — ambos ausentes en `sdd-tasks` ([Bloque 9]).

## 10.11 — Result Contract `[CERT]`

El **agente** (`agents/sdd-apply.md:42-49`):

| Campo | Valor |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase (tareas hechas / total) |
| `artifacts` | archivos cambiados + topic_keys actualizados |
| `next_recommended` | `sdd-verify` (si todo done) o `sdd-apply` de nuevo (si quedan tareas) |
| `risks` | deviaciones de design, complejidad inesperada, tareas bloqueadas |
| `skill_resolution` | `paths-injected` o `none` |

El **SKILL.md** (`SKILL.md:195-235`) define un "Implementation Progress" markdown más rico: Completed Tasks, Files Changed (tabla), TDD Cycle Evidence (si Strict TDD), Deviations from Design, Issues Found, Remaining Tasks, Workload/PR Boundary, Status. El **prompt condensado** define un envelope JSON minimalista: `{status: ok|blocked|error, completed_tasks, files_changed, notes}` (`prompts/sdd/sdd-apply.md:45-52`).

## 10.12 — Gotchas `[CERT]`

- **Overwrite de apply-progress = pérdida permanente** (`SKILL.md:112`): el read-merge-write de 2b es la salvaguarda; saltearlo borra batches previos.
- **No hay fallback silencioso de TDD** (`SKILL.md:145`): si Strict TDD se resolvió activo, falta de tabla TDD Evidence hace que verify rechace ([Bloque 11], [Bloque 23]).
- **El prompt condensado diverge del SKILL.md** [CERT — comparado]: `prompts/sdd/sdd-apply.md` impone "Read max 3 files at a time", "Load up to 2 SKILL.md paths", envelope JSON, y reduce los 7 steps a 9 líneas. El SKILL.md (v3.0, más completo) es la fuente canónica; el prompt es la variante de bajo presupuesto.
- **Re-lectura obligatoria de tasks antes de retornar** (`SKILL.md:191-193, 245`): internal todos no cuentan como completitud — `sdd-archive` ([Bloque 12]) bloquea si las tasks persistidas tienen `- [ ]` stale.
- **NEVER implement tasks that weren't assigned** (`SKILL.md:251`): scope estricto al batch asignado.
- **STOP en `applyState: blocked` / `all_done` / actionContext inseguro** (`SKILL.md:243`): no edita.

## 10.13 — Conexiones

- **[Bloque 9] (tasks)** → `sdd-apply` lee `tasks` + spec + design + proposal; consume el Review Workload Forecast en Step 2a (`SKILL.md:49, 80-100`).
- **[Bloque 10] → [Bloque 23] (strict-TDD)**: Step 3 carga `strict-tdd.md` solo si Strict TDD activo; Hard Gate exige tabla TDD Evidence (`SKILL.md:114-145`).
- **[Bloque 10] → [Bloque 16] (Gatekeeper / Review Workload Guard)**: el orquestador es gatekeeper antes/después de apply; apply es high-risk → revisión de contexto fresco. Step 2a enforce la decisión cacheada.
- **[Bloque 11] (verify)** → consume `apply-progress`; `next_recommended: sdd-verify`.
- **[Bloque 17] (delivery/chain)**: Chain strategy y PR slices guían el targeting de ramas en Step 2a.
- **[Bloque 3]**: artefacto `apply-progress` → `sdd/{change}/apply-progress`.
- **[Bloque 22] (phase-common + status-contract)**: Secciones A–D + structured status (`applyState`, `actionContext`, `allowedEditRoots`).
- **[Bloque 18] (models)**: sonnet, "Implementation".
