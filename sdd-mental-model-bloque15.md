# Bloque 15 — `sdd-status` y el dispatcher nativo `gentle-ai`

> **QUÉ DOCUMENTA**: Este bloque documenta el comando read-only `/sdd-status` y el dispatcher nativo `gentle-ai` (binario). Explica el contrato de status compartido, el schema `gentle-ai.sdd-status`, la regla central de que el dispatcher nativo SOLO ve artefactos OpenSpec y siempre emite `artifactStore: openspec`, por qué queda CIEGO ante backend engram, y cómo se rutea por `nextRecommended` y `blockedReasons`.
> **ALCANCE**: El comando `/sdd-status`, los flags reales del binario (`--cwd`, `--json`, `--instructions`), el schema de status, las reglas de selección de cambio, los estados de dependencia y apply, y el guard de action context. NO cubre la mecánica de avance de fases (ver [Bloque 14]) ni el detalle de cada backend (ver [Bloque 3], [Bloque 21]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/commands/sdd-status.md` (líneas 1-42)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-status-contract.md` (líneas 1-124)
> - Salida real de `gentle-ai --help` (binario v1.43.2) — verificada en runtime
> - `/home/cristian/.claude/CLAUDE.md` §"Native SDD Dispatcher Guard"
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente o ejecutando el binario, con `ruta:línea` o `ruta §sección`. `[CERT-a]` = afirmado por una fuente, no re-verificado. `[INFER]` = deducción propia.

---

## 15.1 — `/sdd-status`: comando read-only de estado `[CERT]`

`/sdd-status` muestra **status estructurado read-only** de un cambio activo `[CERT]` (frontmatter `sdd-status.md:2`). La primera línea de la tarea lo deja inequívoco: *"This command is read-only. Do not launch SDD executors and do not edit files."* `[CERT]` (`sdd-status.md:6`).

Reglas read-only explícitas `[CERT]` (`sdd-status.md:35-41`):

- No crear, actualizar ni borrar artefactos.
- No marcar tareas completas.
- No lanzar apply, verify, archive ni continue.
- No inferir ruteo desde texto libre. Usar `nextRecommended` y estados de dependencia.
- Si el status no se puede resolver con seguridad, devolver `status: blocked` con la información faltante.

Como los meta-comandos, abre con el mismo HARD GATE de Session Preflight `[CERT]` (`sdd-status.md:8-10`): si falta, preguntar el prompt de preflight y DETENERSE — no inspeccionar status en el mismo turno.

Lo que el comando DEBE devolver `[CERT]` (`sdd-status.md:26-33`):

- Selección del cambio activo y `schemaName`.
- `planningHome`, `changeRoot`, `artifactPaths` y `contextFiles`.
- Estados de artefacto para proposal, specs, design, tasks, apply-progress y verify-report.
- Progreso de tareas: total, completed, pending, allComplete.
- Estados de dependencia para proposal, specs, design, tasks, apply, verify, archive.
- Next recommended action.
- `actionContext` mode, workspace root y allowed edit roots.

## 15.2 — El binario `gentle-ai` y sus flags reales `[CERT]`

Verificado ejecutando el binario en runtime `[CERT]` (`gentle-ai --help`, versión **1.43.2**):

```
gentle-ai — Gentle-AI: Ecosystem, Frameworks, Workflows (1.43.2)

COMMANDS
  sdd-status [change]   Print native SDD phase status for orchestrators
  sdd-continue [change] Print native SDD dispatcher routing output
  ...
```

Subcomandos relevantes confirmados `[CERT]`:

- `gentle-ai sdd-status [change]` — "Print native SDD phase status for orchestrators".
- `gentle-ai sdd-continue [change]` — "Print native SDD dispatcher routing output".

Nota de verificación sobre flags `[CERT]`: `gentle-ai sdd-status --help` devolvió `Error: unknown sdd-status argument "--help"` (exit 1). Es decir, el subcomando NO expone su propio `--help`; la única ayuda es la global `gentle-ai --help`. Por lo tanto **los flags `--cwd`, `--json` e `--instructions` NO se pudieron confirmar contra una ayuda del subcomando**; se documentan como `[CERT-a]` por estar afirmados consistentemente en los prompts de comando y el contrato compartido:

- `gentle-ai sdd-status [change] --cwd <repo> --json --instructions` `[CERT-a]` (`sdd-status.md:20`, `sdd-status-contract.md:18`).
- `gentle-ai sdd-continue [change] --cwd <repo>` `[CERT-a]` (`sdd-continue.md:13`, `sdd-status-contract.md:18`).

Significado de cada flag según las fuentes `[CERT-a]`:

| Flag | Función afirmada |
|------|-----------------|
| `--cwd <repo>` | Indicar el repo autoritativo (resuelto vía `git rev-parse --show-toplevel`) |
| `--json` | Emitir el status como JSON parseable en lugar de markdown |
| `--instructions` | Incluir `phaseInstructions` (solo claves de ejecución: apply/verify/archive) |

**Observación** `[INFER]`: que el subcomando rechace `--help` pero el README de los prompts insista en `--cwd/--json/--instructions` sugiere que el binario acepta esos flags posicionalmente/silenciosamente sin un parser de ayuda por subcomando. La verificación dura quedó limitada a la existencia de los subcomandos `sdd-status` y `sdd-continue`, que SÍ están confirmados en la ayuda global.

## 15.3 — La regla central: el dispatcher nativo SOLO ve OpenSpec `[CERT]`

Esta es la regla más importante del bloque, y se repite en las tres fuentes `[CERT]`:

> *"The native engine reads only OpenSpec file artifacts and always emits `artifactStore: openspec`; it cannot observe Engram-backed changes."* `[CERT]` (`sdd-status-contract.md:19`).

El mecanismo `[CERT]` (`sdd-status-contract.md:18-20`, `sdd-status.md:20`, `CLAUDE.md` §"Native SDD Dispatcher Guard"):

1. El dispatcher nativo lee ÚNICAMENTE artefactos de archivo OpenSpec bajo `openspec/changes/`.
2. SIEMPRE emite `artifactStore: openspec`, sin importar el backend real de la sesión.
3. Por lo tanto, es autoritativo **solo** cuando el artifact store de la sesión es `openspec` o `hybrid`.

Consecuencia para backend `engram` `[CERT]`: cuando el store es `engram`, **NO se invoca el dispatcher en absoluto** `[CERT]` (`sdd-status.md:20`: "do NOT invoke the native dispatcher at all — it cannot see the change"). El status se resuelve enteramente desde Engram (`mem_search` + `mem_get_observation` sobre los topic keys del cambio) usando el schema manual.

CLAUDE.md lo refuerza con fuerza inusual `[CERT]` (§"Native SDD Dispatcher Guard"): *"it is blind to the change and its `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` output is meaningless"*. Es decir, si un orquestador con backend engram corriera el dispatcher por error, este reportaría que el cambio no existe — y ESA salida hay que **descartarla**, no obedecerla `[CERT]` (`sdd-status-contract.md:19`: "disregard any `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` it emits for an Engram change that exists").

**Modelo mental** `[INFER]`: el dispatcher nativo es un **lector de filesystem OpenSpec**, no un servicio de status agnóstico de backend. Hablar con él cuando tu verdad vive en Engram es como preguntarle a un bibliotecario por un libro que está en tu cabeza: te dirá "no lo tengo", y tendría razón desde su mundo y estaría equivocado respecto al tuyo. Por eso la regla no es "interpretá su salida con cuidado" sino "no lo llames".

Matriz de decisión backend → fuente de status `[CERT]` (síntesis de `sdd-status-contract.md:18-24`):

| Artifact store de sesión | ¿Invocar dispatcher? | Fuente autoritativa de status |
|--------------------------|----------------------|-------------------------------|
| `openspec` | Sí | JSON nativo de `gentle-ai sdd-status` |
| `hybrid` | Sí | JSON nativo de `gentle-ai sdd-status` |
| `engram` | **No** | Engram (`mem_search` + `mem_get_observation` sobre topic keys) |
| binario no disponible | No (no existe) | Fallback al schema manual del contrato |

## 15.4 — El schema `gentle-ai.sdd-status` `[CERT]`

El contrato define un schema YAML/JSON canónico `[CERT]` (`sdd-status-contract.md:30-90`). Campos principales:

| Campo | Valores / forma `[CERT]` (`sdd-status-contract.md`) |
|-------|------------------------------------------------------|
| `schemaName` | `gentle-ai.sdd-status` |
| `schemaVersion` | `1` |
| `changeName` | nombre o `null` (nullable) |
| `artifactStore` | `openspec` \| `engram` \| `hybrid` |
| `planningHome` | `{ mode: repo-local, path: <abs openspec> }` |
| `changeRoot` | ruta abs a `openspec/changes/<change>` o `null` |
| `artifactPaths` | arrays de rutas por artefacto (proposal, specs, design, tasks, applyProgress, verifyReport) |
| `contextFiles` | arrays de archivos legibles por artefacto |
| `artifacts` | por artefacto: `missing` \| `done` \| `partial` |
| `taskProgress` | `{ total, completed, pending, allComplete }` |
| `dependencies` | por fase: `blocked` \| `ready` \| `all_done` |
| `applyState` | `blocked` \| `all_done` \| `ready` |
| `actionContext` | `{ mode, workspaceRoot, allowedEditRoots[] }` |
| `relationships` | dependsOn / supersedes / amends / conflictsWith / sameDomainActiveChanges |
| `phaseInstructions` | opcional; solo claves de ejecución (apply/verify/archive) |
| `nextRecommended` | token acotado (ver §15.5) |
| `blockedReasons` | array (ver §15.5) |

Reglas de forma críticas `[CERT]` (`sdd-status-contract.md:92`):

- `phaseInstructions` aparece SOLO cuando se piden instrucciones, y carga únicamente claves de ejecución (`apply`, `verify`, `archive`). Las instrucciones de planificación (`propose`, `spec`, `design`, `tasks`) van en el markdown del dispatcher, NO en este map JSON.
- Los campos de path vacíos DEBEN ser arrays, no `null`.
- `changeName` y `changeRoot` son nullable; el resto debe estar presente en el fallback para que consumidores parseen native y manual igual.
- **El status nativo emite `artifactStore: openspec`**; el fallback manual DEBE setear `artifactStore` al store real de la sesión (`openspec`, `engram` o `hybrid`), **no espejar ciegamente el token nativo** `[CERT]` (`sdd-status-contract.md:92`).

Compatibilidad de forma `[CERT]` (`sdd-status-contract.md:24`): *"Manual fallback status MUST stay shape-compatible with native `gentle-ai.sdd-status` JSON even when values are reconstructed manually."* Es decir, sea cual sea la fuente (binario o Engram), el consumidor parsea la MISMA forma.

## 15.5 — Ruteo por `nextRecommended` y `blockedReasons` `[CERT]`

`nextRecommended` es un **token de máquina acotado para ruteo, NO prosa humana** `[CERT]` (`sdd-status-contract.md:22`). Valores posibles `[CERT]` (`sdd-status-contract.md:88`):

```
propose | spec | design | tasks | apply | verify | archive
| sdd-new | select-change | resolve-blockers
```

Regla de oro `[CERT]` (`sdd-status-contract.md:22`, `sdd-status.md:40`, `CLAUDE.md` §"Native SDD Dispatcher Guard"): *"Route only by `nextRecommended` and dependency states; never infer from free text."* La explicación humana va en `blockedReasons`, no en `nextRecommended` `[CERT]` (`sdd-status-contract.md:23`).

Tabla de ruteo `[CERT]` (`sdd-status-contract.md:21`, `sdd-status.md:40`):

| Condición | Acción del orquestador |
|-----------|------------------------|
| `blockedReasons` no vacío | No proceder a terminal/archive/apply. Reportar y detenerse... |
| ...salvo `nextRecommended: verify` | verify puede correr solo para remediar/refrescar evidencia de los bloqueos |
| `nextRecommended: resolve-blockers` | SIEMPRE reportar `blockedReasons` y detenerse |
| `nextRecommended` = token de planificación (`propose`/`spec`/`design`/`tasks`) | Lanzar la fase de planificación correspondiente |

Sutileza importante `[CERT]` (`sdd-status-contract.md:21`): cuando `nextRecommended` es un token de planificación, los artefactos de planificación faltantes son la SALIDA ESPERADA de esas fases, **no bloqueos genuinos**. No hay que confundir "falta la spec" (estado normal antes de `sdd-spec`) con un blocker.

El guard del CLAUDE.md añade una capa de escala de severidad `[CERT]` (§"Native SDD Dispatcher Guard"): *"never infer from free text. If `blockedReasons` is non-empty, do not proceed to apply, archive, or terminal work."* Y para backend engram repite que NO se invoque el binario porque su `nextRecommended: sdd-new` sería "meaningless".

## 15.6 — Selección de cambio, estados de dependencia y apply `[CERT]`

**Selección de cambio** `[CERT]` (`sdd-status-contract.md:9-14`, `sdd-status.md:21-24`):

- Si se da un nombre → usar ese cambio exacto tras confirmar que existe en el store seleccionado.
- Si no se da y el cambio activo es inequívoco (o hay exactamente uno) → seleccionarlo y decir cómo se seleccionó.
- Si hay múltiples o es ambiguo → **preguntar al usuario y DETENERSE. No adivinar.**
- Si no hay cambios activos → reportar que ninguno está activo y sugerir `/sdd-new <change>`.

**Estados de apply** `[CERT]` (`sdd-status-contract.md:95-98`):

| applyState | Condición |
|-----------|-----------|
| `blocked` | faltan artefactos de apply, selección de tarea ambigua, o el action context hace inseguros los edits |
| `all_done` | el artefacto tasks existe y toda tarea de implementación está marcada `[x]` |
| `ready` | tasks existe, al menos una tarea sigue sin marcar, y el edit scope es seguro |

**Estados de dependencia** `[CERT]` (`sdd-status-contract.md:100-105`):

- `proposal`, `specs`, `design`, `tasks`: reportan si los prerrequisitos están blocked/ready/all_done.
- `apply` es `ready` solo cuando specs, design y tasks están disponibles y el progreso no está all done.
- `verify` es `ready` cuando tasks existe Y (apply-progress existe O el tasks muestra todo el trabajo de implementación completo). Tareas incompletas siguen siendo bloqueos para verificación completa.
- `archive` es `ready` solo cuando verify-report existe, está claramente passing, y las tareas están completas. Un reporte claramente passing necesita señal explícita PASS/SUCCESS y **ninguna** señal de bloqueo/negación (FAIL, FAILURE, BLOCKED, CRITICAL, PENDING, TODO, "not passed", "pass: no"). **Los issues CRITICAL de verificación no tienen override** `[CERT]` (`sdd-status-contract.md:105`).

## 15.7 — Action Context Guard `[CERT]`

El orquestador DEBE cargar `actionContext` en cualquier lanzamiento de fase `[CERT]` (`sdd-status-contract.md:107-113`):

- Si el contexto reconstruido manualmente no puede probar la ownership de edición o los allowed edit roots → detenerse antes de editar.
- Si hay `allowedEditRoots` → editar solo archivos dentro de esas raíces.
- Si un comando no puede probar que un archivo está dentro del workspace autoritativo o de las raíces permitidas → detenerse y pedir clarificación.

Esto enlaza con el cierre de `/sdd-continue` `[CERT]` (`sdd-continue.md:39`): si el status reporta `workspace-planning` sin allowed edit roots, no lanzar apply/verify/archive que infiera ownership repo-local.

**Por qué existe** `[INFER]`: el guard es la red de seguridad contra el problema del cwd-en-Electron descrito en los meta-comandos (§14.3 de [Bloque 14]). Si el workspace no se pudo resolver con certeza, el sistema prefiere DETENERSE antes que editar el directorio equivocado. La prueba de ownership es un prerequisito duro para tocar archivos.

## 15.8 — Output obligatorio de status `[CERT]`

Todo comando que actúe sobre un cambio DEBE mostrar status antes de lanzar un ejecutor o hacer archive `[CERT]` (`sdd-status-contract.md:117-123`):

- Selección del cambio activo y cómo se resolvió.
- Estados y rutas/topics de artefactos usados como contexto.
- Progreso de tareas y lista de tareas sin marcar (cuando existen tasks).
- Next recommended action.
- `blockedReasons` cuando `nextRecommended` no es `verify`, más cualquier bloqueo de edit-root.

**Propósito del contrato** `[CERT]` (`sdd-status-contract.md:6-8`): *"Commands that select, continue, apply, verify, or archive an SDD change MUST first produce or consume structured status. The status is the handoff between orchestrator and phase executor."* El status NO es un reporte cosmético; es el **handoff formal** entre orquestador y ejecutor, para que la orquestación no adivine estado, rutas ni scope de edición `[CERT]` (`sdd-status-contract.md:4`).

## 15.9 — Conexiones

- **[Bloque 3] — backends + topic keys**: la dicotomía openspec/engram/hybrid que determina si el dispatcher se invoca (§15.3) es la misma que [Bloque 3] establece. Los topic keys `sdd/{change}/{type}` que se leen vía `mem_search`/`mem_get_observation` cuando el backend es engram vienen de allí.
- **[Bloque 21] — openspec-convention**: el dispatcher nativo lee `openspec/changes/`; la estructura de ese árbol y la convención OpenSpec la documenta [Bloque 21]. La afirmación "reads only OpenSpec file artifacts" solo se entiende contra esa convención.
- **[Bloque 14] — meta-comandos**: `/sdd-continue` (§14.4) consume este contrato de status como paso 1. El ruteo por `nextRecommended`/`blockedReasons` de §15.5 es lo que `/sdd-continue` usa para decidir qué fase lanzar.
- **[Bloque 22] — skill-resolver + phase-common + status-contract**: el archivo `sdd-status-contract.md` es uno de los contratos compartidos `_shared/`; [Bloque 22] lo ubica en el conjunto de convenciones transversales.
- **[Bloque 16] — Gatekeeper**: el Gatekeeper de modo auto valida "routing coherence" leyendo `nextRecommended` y `risks` — exactamente los campos que este contrato define.
