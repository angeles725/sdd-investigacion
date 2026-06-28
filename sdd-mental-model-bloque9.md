# Bloque 9 — Fase `sdd-tasks` (+ Review Workload Forecast)

> **QUÉ**: Documenta la fase `sdd-tasks` del sistema SDD de gentle-ai: el desglose de un cambio en una checklist de tareas de implementación ordenadas por fase, más el `Review Workload Forecast` que protege el presupuesto de revisión de 400 líneas.
>
> **ALCANCE**: Propósito, contrato de entrada/salida, qué lee y qué escribe (artefacto + topic key), formato del `tasks.md`, reglas de escritura de tareas, el Review Workload Forecast (estimación de líneas, recomendación de chained PRs, líneas-guarda de texto plano), modelo asignado, Result Contract y gotchas. NO cubre la ejecución de las tareas (eso es `sdd-apply`, [Bloque 10]) ni la estrategia de entrega/chain en detalle ([Bloque 17]).
>
> **FUENTES exactas**:
> - `/home/cristian/.config/opencode/skills/sdd-tasks/SKILL.md` (primaria)
> - `/home/cristian/.claude/agents/sdd-tasks.md` (tools, modelo, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-tasks.md` (idéntico a SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (Secciones A–E)
> - NOTA: no existe `commands/sdd-tasks.md`; la fase se dispara vía `/sdd-continue` o `/sdd-ff` (orquestador), no como comando directo.
>
> **MÉTODO**: lectura directa de los archivos citados. Marcadores:
> - `[CERT]` = verificado leyendo el archivo (cita `ruta:línea` o `ruta §sección`).
> - `[CERT-a]` = afirmado por una fuente, no re-verificado en el origen último.
> - `[INFER]` = deducción propia.

---

## 9.1 — Propósito y rol `[CERT]`

`sdd-tasks` es un sub-agente EJECUTOR responsable de crear el TASK BREAKDOWN. Toma proposal, specs y design y produce un `tasks.md` con pasos de implementación concretos y accionables organizados por fase (`skills/sdd-tasks/SKILL.md:32-34`). No implementa: produce solo la checklist (`agents/sdd-tasks.md:23` — "Do NOT implement — produce the checklist only").

El SKILL abre con el **ORCHESTRATOR GATE** estándar de todas las fases SDD: si cargaste el skill vía `skill()` sos el ORQUESTADOR y debés DELEGAR al sub-agente, no ejecutar inline (`SKILL.md:13-17`). El **Executor Override** invierte la regla: si SOS el sub-agente, ejecutás directamente, no delegás ni llamás al Skill tool (`SKILL.md:19-21`). Esta dualidad gate/override es común a todas las fases ([Bloque 22], `_shared/sdd-phase-common.md` §boundary).

Es un sub-agente `delegate_only: true` (`SKILL.md:10`), `disable-model-invocation: true`, `user-invocable: false` (`SKILL.md:4-5`): nunca lo invoca el modelo ni el usuario directamente, solo el orquestador.

## 9.2 — Lo que recibe del orquestador `[CERT]`

`SKILL.md:36-41`:

| Entrada | Valores |
|---------|---------|
| Change name | nombre del cambio |
| Artifact store mode | `engram` \| `openspec` \| `hybrid` \| `none` ([Bloque 3]) |
| Delivery strategy | `ask-on-risk` \| `auto-chain` \| `single-pr` \| `exception-ok` ([Bloque 17]) |

La `delivery strategy` es el insumo clave que conecta esta fase con la estrategia de entrega ([Bloque 17]): determina si el Review Workload Forecast exige una decisión antes de `sdd-apply`.

## 9.3 — Qué LEE y qué ESCRIBE `[CERT]`

Contrato de ejecución y persistencia (`SKILL.md:43-50`), que delega a las Secciones B (retrieval) y C (persistence) de `_shared/sdd-phase-common.md`:

| Modo | Lee (todos requeridos) | Escribe |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `sdd/{change}/spec`, `sdd/{change}/design` | `sdd/{change}/tasks` |
| `openspec` | sigue `_shared/openspec-convention.md` | `openspec/changes/{change}/tasks.md` |
| `hybrid` | Engram (primario) + filesystem fallback | AMBOS: Engram + `tasks.md` |
| `none` | retorna inline | nada (nunca crea/modifica archivos) |

**Artefacto producido**: `tasks` · **topic key**: `sdd/{change-name}/tasks` · **type**: `architecture` (`SKILL.md:206-208`, [Bloque 3]).

DEPENDENCIA CLAVE: lee **proposal + spec + design** (`SKILL.md:47`). El `agents/sdd-tasks.md:18-25` lista explícitamente spec y design como requeridos vía `mem_search → mem_get_observation`; el SKILL.md añade proposal. Esto cierra el grafo de dependencias: tasks es el confluente de spec ([Bloque 7]) y design ([Bloque 8]) en el DAG ([Bloque 2]).

> [CERT] Sección B advierte: `mem_search` devuelve PREVIEWS de 300 chars, NO contenido completo. Hay que llamar `mem_get_observation(id)` por CADA artefacto, en paralelo (`_shared/sdd-phase-common.md:21-35`). Saltarlo "produce wrong output".

## 9.4 — Pasos de ejecución `[CERT]`

`SKILL.md:54-209`:

1. **Step 1 — Load Skills**: Sección A del common (skills inyectados por el orquestador, o fallback a registry) (`SKILL.md:54-55`).
2. **Step 2 — Analyze the Design**: identificar todos los archivos a crear/modificar/borrar, el orden de dependencia y los requisitos de testing por componente (`SKILL.md:57-63`).
3. **Step 3 — Write tasks.md**: en `openspec`/`hybrid` crea el archivo físico; en `engram`/`none` compone el contenido en memoria, sin crear directorios `openspec/` (`SKILL.md:64-76`).
4. **Step 4 — Persist Artifact** (MANDATORIO): Sección C, artifact `tasks`, topic_key `sdd/{change}/tasks`, type `architecture` (`SKILL.md:201-208`).
5. **Step 5 — Return Summary**: envelope con breakdown por fase + Review Workload Forecast (`SKILL.md:210-241`).

## 9.5 — Formato del `tasks.md` `[CERT]`

`SKILL.md:78-129`. Estructura:

```markdown
# Tasks: {Change Title}

## Review Workload Forecast
   (tabla + líneas-guarda de texto plano — ver 9.6)

### Suggested Work Units
   (tabla: Unit | Goal | Likely PR | Notes)

## Phase 1: Foundation / Infrastructure
- [ ] 1.1 {acción concreta — qué archivo, qué cambio}
## Phase 2: Core Implementation
## Phase 3: Testing / Verification
## Phase 4: Cleanup / Documentation
```

Numeración jerárquica `1.1, 1.2, 2.1...` (`SKILL.md:249`). Organización por fases (`SKILL.md:178-199`): Foundation → Core → Integration/Wiring → Testing → Cleanup. Las tareas DEBEN estar ordenadas por dependencia: las de Phase 1 no pueden depender de Phase 2 (`SKILL.md:246`).

### Reglas de escritura de tareas `[CERT]`

Cada tarea debe ser (`SKILL.md:131-140`):

| Criterio | Ejemplo ✅ | Anti-ejemplo ❌ |
|----------|-----------|-----------------|
| **Specific** | "Create `internal/auth/middleware.go` with JWT validation" | "Add auth" |
| **Actionable** | "Add `ValidateToken()` method to `AuthService`" | "Handle tokens" |
| **Verifiable** | "Test: `POST /login` returns 401 without token" | "Make sure it works" |
| **Small** | un archivo o una unidad lógica de trabajo | "Implement the feature" |

Reglas adicionales (`SKILL.md:243-254`): siempre referenciar rutas concretas; las tareas de testing referencian escenarios específicos de las specs; cada tarea completable en UNA sesión; NUNCA tareas vagas como "implement feature". Si el proyecto usa TDD, integrar tareas test-first: RED (test que falla) → GREEN (hacerlo pasar) → REFACTOR (`SKILL.md:252`, ver [Bloque 23]).

> [CERT] **Size budget**: el artefacto tasks DEBE quedar bajo **530 words**; cada tarea 1–2 líneas máx; formato checklist, no párrafos (`SKILL.md:253`).

## 9.6 — Review Workload Forecast `[CERT]`

El corazón distintivo de esta fase. Antes de finalizar, `sdd-tasks` estima si la implementación excederá el **presupuesto de revisión de 400 líneas cambiadas** (`additions + deletions`) — es una guarda de planificación, no un conteo exacto de diff (`SKILL.md:142-146`).

Señales a usar (`SKILL.md:146`): número de archivos, fases, puntos de integración, tests, docs, artefactos generados, migraciones y cuántas preocupaciones cruza el cambio.

### Tabla del forecast `[CERT]`

`SKILL.md:83-97`:

| Field | Value |
|-------|-------|
| Estimated changed lines | estimación o rango |
| 400-line budget risk | Low / Medium / High |
| Chained PRs recommended | Yes / No |
| Suggested split | single PR o PR 1 → PR 2 → PR 3 |
| Delivery strategy | ask-on-risk / auto-chain / single-pr / exception-ok |
| Chain strategy | stacked-to-main / feature-branch-chain / size-exception / pending |

### Líneas-guarda de texto plano (contrato literal) `[CERT]`

CRÍTICO: el forecast DEBE incluir estas líneas EXACTAS en texto plano para que las guardas downstream las matcheen literalmente (`SKILL.md:165-174`):

```text
Decision needed before apply: Yes|No
Chained PRs recommended: Yes|No
Chain strategy: stacked-to-main|feature-branch-chain|size-exception|pending
400-line budget risk: Low|Medium|High
```

La tabla es para legibilidad, pero **las líneas de texto plano son el contrato de guarda** (`SKILL.md:174`). El orquestador las matchea literalmente en el "Review Workload Guard" antes de lanzar `sdd-apply` ([Bloque 16]/[Bloque 17]). Esto se confirma en `_shared/sdd-phase-common.md:102-103` (Sección E): "The forecast MUST include exact plain-text guard lines".

### Lógica del forecast cuando el riesgo es High `[CERT]`

Si la estimación es **High** o probablemente >400 líneas (`SKILL.md:148-161`):

1. Marcar `Chained PRs recommended: Yes`.
2. Partir las tareas en **work units** que puedan volverse chained o stacked PRs.
3. Cada PR sugerido debe tener inicio claro, fin claro, verificación y alcance autónomo.
4. **Preguntar al usuario qué chain strategy usar** (decisión de equipo):
   - **Stacked PRs to main** — cada PR mergea a main en orden; iteración rápida.
   - **Feature Branch Chain** — la rama tracker acumula la integración final; PR #1 apunta a la tracker, los siguientes a la rama del PR previo inmediato; solo la tracker mergea a main.
   - **size:exception** — un solo PR con aprobación del maintainer (código generado, migraciones, vendor diffs).
5. Cachear la elección y setear `Decision needed before apply` según delivery strategy:

| Delivery strategy | Decision needed before apply |
|-------------------|------------------------------|
| `ask-on-risk` | `Yes` — orquestador pregunta antes de apply |
| `auto-chain` | `No` — orquestador procede con el primer slice |
| `single-pr` | `Yes` — orquestador debe exigir `size:exception` antes de apply |
| `exception-ok` | `No` — maintainer ya aceptó `size:exception` |

Para `feature-branch-chain`, los work units DEBERÍAN nombrar el base boundary: PR #1 base = rama tracker; PR #2 base = rama PR #1; PR #3 base = rama PR #2. Si un PR hijo mostrara cambios del PR previo, la base está mal y hay que re-targetear/rebasear antes de revisar (`SKILL.md:176`).

> [CERT] "Do not bury this in prose. Put the forecast near the top of the tasks artifact so the user sees it before implementation starts" (`SKILL.md:163`).

## 9.7 — Modelo asignado `[CERT]`

`agents/sdd-tasks.md:6`: `model: sonnet`. Coincide con la Model Assignments table del orquestador ([Bloque 18]): "sdd-tasks | sonnet | default | Mechanical breakdown". El razonamiento: el desglose es mecánico, no arquitectónico (a diferencia de propose/design que usan opus).

**Tools** (`agents/sdd-tasks.md:7`): `Read, Edit, Write, Grep, Glob, mem_search, mem_get_observation, mem_save`. Notar: NO tiene `mem_update` (no marca tareas completas — eso es trabajo de `sdd-apply`) ni `Bash` (no ejecuta nada).

## 9.8 — Result Contract `[CERT]`

Dos formatos conviven. El **agente** (`agents/sdd-tasks.md:37-46`) define el envelope estructurado:

| Campo | Valor |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase (total de tareas, paralelo vs secuencial) |
| `artifacts` | topic_keys/paths (ej. `sdd/{change}/tasks`) |
| `next_recommended` | `sdd-apply` |
| `risks` | dependencias de tareas que generan cuellos de botella |
| `skill_resolution` | `paths-injected` o `none` |

El **SKILL.md** (`SKILL.md:210-241`) define además un "Return Summary" markdown con tabla de breakdown por fase + sección "Review Workload Forecast" repetida en el envelope. Ambos refieren a la Sección D del common ([Bloque 2], [Bloque 22]). `next_recommended` es siempre `sdd-apply` ([Bloque 10]).

## 9.9 — Gotchas `[CERT]`

- **Las líneas de texto plano del forecast son load-bearing**: si faltan o cambian de wording, el Review Workload Guard del orquestador no matchea y la guarda de 400 líneas se rompe silenciosamente (`SKILL.md:165-174`).
- **530 words es un techo duro** para el artefacto tasks (`SKILL.md:253`): forecasts verbosos compiten con las tareas por ese presupuesto.
- **No marca `[x]`**: tasks crea todo como `- [ ]`; el marcado de completitud es responsabilidad exclusiva de `sdd-apply` ([Bloque 10]) y validado por `sdd-archive` ([Bloque 12]).
- **No existe comando `/sdd-tasks`** [CERT — verificado: `ls commands/` no lo lista]: la fase corre solo dentro de `/sdd-continue` o `/sdd-ff` orquestados.
- **El prompt `prompts/sdd/sdd-tasks.md` es byte-idéntico al SKILL.md** [CERT — comparado]: a diferencia de apply/verify, tasks no tiene versión condensada divergente.

## 9.10 — Conexiones

- **[Bloque 7] (spec) y [Bloque 8] (design)** → `sdd-tasks` los lee como dependencias requeridas (`SKILL.md:47`, `agents/sdd-tasks.md:19-20`). Confluencia del DAG ([Bloque 2]).
- **[Bloque 9] → [Bloque 17] (delivery/chain)**: el Review Workload Forecast produce `Chained PRs recommended`, `Chain strategy` y `Decision needed before apply`, que [Bloque 17] consume. La delivery strategy entra como insumo (`SKILL.md:41`).
- **[Bloque 10] (apply)** → consume el forecast vía Step 2a "Enforce Review Workload Decision"; `next_recommended: sdd-apply`.
- **[Bloque 16] (Gatekeeper / Review Workload Guard)**: el orquestador inspecciona el forecast tras tasks y antes de apply.
- **[Bloque 23] (strict-TDD)**: si TDD está activo, las tareas se integran como RED→GREEN→REFACTOR (`SKILL.md:252`).
- **[Bloque 3] (backends + topic keys)**: artefacto `tasks` → `sdd/{change}/tasks`.
- **[Bloque 22] (phase-common)**: Secciones A (skills), B (retrieval), C (persistence), D (envelope), E (Review Workload Guard).
