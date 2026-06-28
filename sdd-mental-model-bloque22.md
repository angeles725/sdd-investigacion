# Bloque 22 — Skill-resolver + phase-common + status-contract

> **QUÉ DOCUMENTA**: Este bloque documenta tres contratos compartidos que sostienen la mecánica de delegación y ejecución de fases: (1) el **Skill Resolver Protocol** — cómo un delegador resuelve skills relevantes del registry y pasa rutas `SKILL.md` (no resúmenes) a los sub-agentes; (2) el **SDD Phase Common Protocol** — el boilerplate idéntico que toda fase carga (skill loading, recuperación de artefactos, persistencia, return envelope, review workload guard); (3) el **SDD Status and Instructions Contract** — el schema estructurado de status que actúa como handoff entre orquestador y ejecutor de fase.
> **ALCANCE**: Los tres contratos transversales de delegación/ejecución/status. NO cubre el detalle de cada fase (ver bloques de fase) ni los modos de persistencia (ver [Bloque 19]). El contrato de status aquí es la base que [Bloque 15] usa para el dispatcher; aquí se documenta el schema, allá su ruteo operativo.
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/skills/_shared/skill-resolver.md` (archivo completo, 73 líneas)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (archivo completo, 110 líneas)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-status-contract.md` (archivo completo, 124 líneas)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por la fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 22.1 — Skill Resolver Protocol `[CERT]`

Cualquier agente que **delega trabajo a sub-agentes** DEBE usar este protocolo para resolver skills relevantes y pasarlas de forma segura `[CERT]` (`skill-resolver.md:1-3`).

**Por qué existe** `[CERT]` (`skill-resolver.md:5-7`): los sub-agentes arrancan sin contexto de skills del proyecto. El registry le da a los delegadores un índice barato de skills disponibles SIN reescribir ni resumir esas skills.

**Cuándo aplicar** `[CERT]` (`skill-resolver.md:9-11`): antes de cada lanzamiento de sub-agente que involucre leer, escribir, revisar, testear, documentar o crear artefactos de proyecto. Saltar solo para comandos puramente mecánicos.

### Los cuatro pasos del protocolo `[CERT]`

**Step 1 — Obtener el Skill Registry** `[CERT]` (`skill-resolver.md:15-23`). El registry es un **índice** de nombres de skill, triggers, scopes y rutas `SKILL.md` exactas — NO un bundle de reglas compactadas. Orden de resolución:

1. Usar el cache de sesión si está presente.
2. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` para contenido completo.
3. Fallback: leer `.atl/skill-registry.md` desde la raíz del proyecto.
4. Sin registry → proceder sin skills de proyecto y advertir al usuario que corra `gentle-ai skill-registry refresh`.

**Step 2 — Matchear skills relevantes** `[CERT]` (`skill-resolver.md:25-34`) en dos dimensiones:

| Contexto | Matchear contra |
|----------|-----------------|
| Código/archivos | El trigger/descripción del registry menciona el lenguaje, framework, herramienta o contexto de ruta |
| Tarea/acción | El trigger/descripción menciona acciones como PR, review, docs, tests, Jira, comments, release |

Preferir el conjunto útil más pequeño. Si matchean más de cinco skills, quedarse con las cinco más relevantes y **priorizar contexto de código sobre contexto de tarea**.

**Step 3 — Pasar rutas de skill** `[CERT]` (`skill-resolver.md:36-49`). Inyectar RUTAS, NO resúmenes:

```markdown
## Skills to load before work

Read these exact files before reading, writing, reviewing, testing, or creating artifacts:

- /absolute/path/to/skills/go-testing/SKILL.md
- /absolute/path/to/skills/typescript/SKILL.md
```

El sub-agente DEBE leer esos archivos antes del trabajo específico. `SKILL.md` es el contrato de runtime y la fuente de verdad.

**Step 4 — Reportar la resolución** `[CERT]` (`skill-resolver.md:51-60`). Los sub-agentes DEBEN reportar `skill_resolution`:

| Valor | Significado |
|-------|-------------|
| `paths-injected` | Recibió rutas exactas del delegador y las cargó |
| `fallback-registry` | No recibió rutas; auto-cargó rutas desde el registry |
| `fallback-path` | Cargó una ruta de fallback explícita fuera del registry |
| `none` | No cargó skills |

Regla de auto-corrección `[CERT]`: si un sub-agente reporta cualquier cosa distinta de `paths-injected`, el orquestador DEBE re-leer el registry antes de la siguiente delegación.

### Seguridad ante compactación e integración `[CERT]`

**Compaction safety** `[CERT]` (`skill-resolver.md:62-66`): el registry persiste en Engram y en `.atl/skill-registry.md`; los delegadores pueden recuperar rutas tras compactación re-leyendo el registry; los sub-agentes reciben archivos exactos a leer, así que el significado de la skill no se degrada por resúmenes generados.

**Puntos de integración** `[CERT]` (`skill-resolver.md:68-72`): el orquestador ATL resuelve rutas para todas las delegaciones SDD y no-SDD; `judgment-day` resuelve rutas antes de Judge A, Judge B y Fix Agent; `pr-review` y futuros delegadores usan este protocolo.

**Punto clave** `[INFER]`: la regla "pasar rutas, no resúmenes" es la decisión arquitectónica central — un resumen generado por el delegador degradaría la intención del autor de la skill. Al pasar la ruta exacta, el sub-agente lee el `SKILL.md` íntegro. Esto es lo que hace el mecanismo "compaction-safe": el delegador puede perder su cache, pero el `SKILL.md` en disco/Engram no cambia.

## 22.2 — SDD Phase Common Protocol `[CERT]`

Boilerplate idéntico a través de todas las skills de fase SDD. Los sub-agentes DEBEN cargarlo junto a su `SKILL.md` específico de fase `[CERT]` (`sdd-phase-common.md:1-3`).

**Frontera de ejecutor** `[CERT]` (`sdd-phase-common.md:5`): cada agente de fase SDD es un EJECUTOR, no un orquestador. Hace el trabajo de la fase él mismo. NO lanza sub-agentes, NO llama `delegate`/`task`, y NO devuelve el trabajo salvo que la skill de fase diga explícitamente que pare y reporte un blocker (ver [Bloque 1] §1.2).

### A. Skill Loading `[CERT]` (`sdd-phase-common.md:7-17`)

1. Chequear si el orquestador inyectó un bloque `## Skills to load before work`. Si sí, leer esos `SKILL.md` exactos antes del trabajo.
2. Si no, chequear instrucciones `SKILL: Load`. Si están presentes, cargar esos archivos.
3. Si ninguno, buscar el skill registry como fallback: `mem_search("skill-registry")` → `mem_get_observation(id)`; fallback a `.atl/skill-registry.md`; matchear triggers a la tarea y leer las rutas listadas.
4. Sin registry → proceder solo con la skill de fase.

El camino preferido es (1) — rutas exactas seleccionadas por el orquestador. (2) y (3) son fallbacks. Buscar el registry es CARGA DE SKILL, no delegación. Si `## Skills to load before work` está presente, IGNORAR instrucciones `SKILL: Load` redundantes `[CERT]`.

### B. Recuperación de artefactos (modo Engram) `[CERT]` (`sdd-phase-common.md:19-35`)

**CRÍTICO**: `mem_search` devuelve PREVIEWS de 300 caracteres, NO contenido completo. Se DEBE llamar `mem_get_observation(id)` para CADA artefacto. **Saltarlo produce salida incorrecta** (coincide con [Bloque 20] §20.4). Correr TODAS las búsquedas en paralelo, luego TODAS las recuperaciones en paralelo. NO usar previews de búsqueda como material fuente.

### C. Persistencia de artefactos `[CERT]` (`sdd-phase-common.md:37-67`)

Toda fase que produce un artefacto DEBE persistirlo — saltarlo ROMPE el pipeline. Por modo:

- **Engram**: `mem_save(title, topic_key, type: "architecture", project, capture_prompt: false, content)`. El `topic_key` habilita upserts. `capture_prompt: false` es obligatorio para artefactos SDD (salidas automatizadas, no saves humanos); setear cuando el schema lo soporte, omitir si no.
- **OpenSpec**: el archivo ya se escribió durante el paso principal de la fase; no hace falta acción adicional.
- **Hybrid**: hacer AMBOS — escribir el archivo Y llamar `mem_save`.
- **None**: devolver inline; no escribir archivos ni llamar `mem_save`.

### D. Return Envelope `[CERT]` (`sdd-phase-common.md:69-93`)

**Ordenamiento de respuesta** `[CERT]`: la salida FINAL DEBE ser texto (el envelope), NO una tool call. Si hay que guardar a Engram, hacerlo ANTES de la respuesta de texto final. NO llamar `mem_session_summary` (es para agentes top-level). Razón: si la última acción es una tool call, el padre recibe solo el resultado de la herramienta — el análisis de texto se pierde (coincide con [Bloque 19] §19.8).

Toda fase devuelve un envelope estructurado `[CERT]`:

| Campo | Contenido |
|-------|-----------|
| `status` | `success`, `partial` o `blocked` |
| `executive_summary` | Resumen de 1-3 oraciones de lo hecho |
| `detailed_report` | (opcional) salida completa, u omitir si ya está inline |
| `artifacts` | Lista de claves/rutas de artefacto escritas |
| `next_recommended` | La siguiente fase SDD a correr, o "none" |
| `risks` | Riesgos descubiertos, o "None" |
| `skill_resolution` | `paths-injected` / `fallback-registry` / `fallback-path` / `none` |

Este es el **Result Contract** que toda fase devuelve al orquestador (ver [Bloque 2]).

### E. Review Workload Guard `[CERT]` (`sdd-phase-common.md:95-109`)

SDD debe proteger la carga cognitiva del reviewer, no solo generar tareas `[CERT]`:

- Budget default de review de PR: **400 líneas cambiadas** (`additions + deletions`).
- El orquestador DEBE cachear una delivery strategy al inicio de sesión: `ask-on-risk` (default), `auto-chain`, `single-pr` o `exception-ok`, y pasarla a `sdd-tasks` y `sdd-apply`.
- `sdd-tasks` DEBE pronosticar si el trabajo puede exceder el budget, con líneas guard de texto plano EXACTAS: `Decision needed before apply: Yes|No`, `Chained PRs recommended: Yes|No`, `400-line budget risk: Low|Medium|High`.
- Si el pronóstico es alto, `sdd-tasks` DEBE recomendar PRs encadenados/apilados con work units entregables.
- `sdd-apply` NO DEBE empezar trabajo sobredimensionado salvo que la estrategia resuelva a slices encadenados/apilados o un `size:exception` explícitamente aceptado.
- Cada slice de PR encadenado: start claro, finish claro, scope autónomo, verificación, rollback razonable.
- En Feature Branch Chain, PR #1 apunta a la branch feature/tracker y los PR hijos a la branch del PR previo inmediato; si GitHub muestra slices previos en un diff hijo, retarget/rebase hasta que el diff esté limpio.

(Desarrollado a nivel de orquestación en [Bloque 17].)

## 22.3 — SDD Status and Instructions Contract `[CERT]`

Contrato compartido estilo OpenSpec para comandos SDD y skills de fase. Usar antes de actuar sobre un cambio para que la orquestación no adivine estado, rutas ni scope de edición `[CERT]` (`sdd-status-contract.md:1-8`).

**Propósito** `[CERT]`: los comandos que seleccionan, continúan, aplican, verifican o archivan un cambio SDD DEBEN primero producir o consumir status estructurado. El status es el **handoff** entre orquestador y ejecutor de fase.

### Selección de cambio `[CERT]` (`sdd-status-contract.md:10-15`)

- Si se da un nombre de cambio, usar ese exacto tras confirmar que existe en el store seleccionado.
- Si no se da nombre, inferir SOLO si el cambio activo es inequívoco o hay exactamente un cambio activo.
- Si múltiples cambios matchean o es ambiguo, preguntar al usuario. No adivinar.
- Si no hay cambios activos, reportarlo y sugerir `/sdd-new <change>`.

### Native Engine `[CERT]` (`sdd-status-contract.md:17-24`)

Punto crítico de este contrato `[CERT]`:

- Cuando el store es `openspec` o `hybrid` Y el binario `gentle-ai` está disponible, preferir `gentle-ai sdd-status [change] --cwd <repo> --json --instructions` (status read-only) y `gentle-ai sdd-continue [change] --cwd <repo>` (dispatcher).
- El native engine lee SOLO artefactos de archivo OpenSpec y SIEMPRE emite `artifactStore: openspec`; NO puede observar cambios respaldados por Engram. Tratar el status nativo como autoritativo solo cuando el store es `openspec` o `hybrid`.
- **Cuando el store es `engram`, NO invocar el dispatcher nativo en absoluto** — resolver status desde Engram (`mem_search` + `mem_get_observation` sobre los topic keys del cambio) usando el schema manual, e ignorar cualquier `blocked`, `Active OpenSpec change not found` o `nextRecommended: sdd-new` que emita para un cambio Engram que existe.
- `blockedReasons` no vacío → no proceder a trabajo terminal/archive/apply; reportar y parar (salvo `nextRecommended: verify`, donde verify puede correr solo para remediar/refrescar evidencia). `nextRecommended: resolve-blockers` → reportar y parar. Token de planning (`propose`, `spec`, `design`, `tasks`) → lanzar esa fase de planning (artefactos de planning faltantes son la salida esperada, no blockers reales).
- `nextRecommended` es un **token máquina acotado para ruteo**, no prosa humana. La explicación legible va en `blockedReasons`, no en `nextRecommended`.
- Si el binario no está disponible, fallback al contrato de prompt y al schema manual. El fallback manual DEBE ser shape-compatible con el JSON nativo de `gentle-ai.sdd-status`.

### Status Schema `[CERT]` (`sdd-status-contract.md:26-92`)

El status se devuelve como markdown con estos campos, o JSON equivalente. Campos principales:

| Campo | Contenido `[CERT]` |
|-------|---------|
| `schemaName` / `schemaVersion` | `gentle-ai.sdd-status` / `1` |
| `changeName` | Nombre del cambio o `null` |
| `artifactStore` | `openspec | engram | hybrid` |
| `planningHome` | `mode: repo-local`, `path` a openspec |
| `changeRoot` | Ruta absoluta a `openspec/changes/<change>` o `null` |
| `artifactPaths` | Rutas absolutas por artefacto (proposal, specs, design, tasks, applyProgress, verifyReport) |
| `contextFiles` | Archivos legibles absolutos por artefacto |
| `artifacts` | Estado por artefacto: `missing | done | partial` |
| `taskProgress` | `total`, `completed`, `pending`, `allComplete` |
| `dependencies` | Por fase: `blocked | ready | all_done` |
| `applyState` | `blocked | all_done | ready` |
| `actionContext` | `mode`, `workspaceRoot`, `allowedEditRoots` |
| `relationships` | `dependsOn`, `supersedes`, `amends`, `conflictsWith`, `sameDomainActiveChanges` |
| `phaseInstructions` | Opcional; solo claves de ejecución (`apply`, `verify`, `archive`) |
| `nextRecommended` | `propose | spec | design | tasks | apply | verify | archive | sdd-new | select-change | resolve-blockers` |
| `blockedReasons` | Lista de razones legibles |

Reglas de shape `[CERT]` (`sdd-status-contract.md:92`): `phaseInstructions` solo lleva claves de fase de ejecución (las de planning van en el markdown del dispatcher, no en el mapa JSON). Los campos de ruta vacíos DEBEN ser arrays, no null. `changeName` y `changeRoot` son nullables; el resto debe estar presente en el fallback. El nativo emite `artifactStore: openspec`; el fallback manual DEBE setear el store real de la sesión, no espejar ciegamente el token nativo.

### Apply State y Dependency States `[CERT]`

**Apply State** `[CERT]` (`sdd-status-contract.md:94-98`): `blocked` (artefactos faltantes, selección ambigua, edits inseguros) | `all_done` (tasks existe y todo está `[x]`) | `ready` (tasks existe, queda al menos una sin marcar, scope seguro).

**Dependency States** `[CERT]` (`sdd-status-contract.md:100-105`):

- `proposal`/`specs`/`design`/`tasks` reportan si los prerequisitos están `blocked`/`ready`/`all_done`.
- `apply` es `ready` solo cuando specs, design y tasks están disponibles y el progreso de tareas no está all_done.
- `verify` es `ready` cuando tasks existe y o bien apply-progress existe o el artefacto tasks muestra todo el trabajo de implementación completo. Tareas incompletas siguen siendo blockers para verificación completa.
- `archive` es `ready` solo cuando verify-report existe, está claramente passing, y las tareas están completas. Un reporte claramente passing necesita una señal explícita PASS/SUCCESS y NINGUNA señal de blocker/negación (FAIL, FAILURE, BLOCKED, CRITICAL, PENDING, TODO, `not passed`, `pass: no`). Los issues CRITICAL de verificación NO tienen override.

### Action Context Guard y Status Output `[CERT]`

**Action Context Guard** `[CERT]` (`sdd-status-contract.md:107-113`): el orquestador DEBE llevar `actionContext` a cualquier lanzamiento de fase. Si el contexto reconstruido manualmente no puede probar ownership de edición o allowed edit roots, parar antes de editar. Si `allowedEditRoots` está presente, solo editar dentro de esos roots. Si un comando no puede probar que un archivo está dentro del workspace autoritativo o los allowed edit roots, parar y pedir clarificación.

**Status Output** `[CERT]` (`sdd-status-contract.md:115-123`): todo comando que actúa sobre un cambio DEBE mostrar status antes de lanzar un ejecutor o hacer archive: selección de cambio activo y cómo se resolvió; estados de artefacto y rutas/topics usados; progreso de tareas y lista de tareas sin marcar; siguiente acción recomendada; `blockedReasons` cuando `nextRecommended` no es `verify`, más cualquier blocker de edit-root.

**Modelo mental** `[INFER]`: el contrato de status es el "lenguaje de máquina" del SDD. El campo `nextRecommended` es deliberadamente un token acotado (no prosa) para que el orquestador rutee determinísticamente sin interpretar texto libre — esto es lo que permite el ruteo del dispatcher de [Bloque 15]. Y la regla "fallback shape-compatible con el JSON nativo" significa que un consumidor parsea status nativo y manual de la misma forma, sin importar el backend.

## 22.4 — Conexiones

- **[Bloque 18] — Delegación y model assignments**: el Skill Resolver Protocol (§22.1) es el mecanismo que el [Bloque 18] referencia cuando exige "pre-resolved skill paths from the skill registry" en cada lanzamiento de sub-agente. El reporte `skill_resolution` (§22.1 Step 4) es el feedback de auto-corrección que el orquestador usa para detectar pérdida de cache por compactación.
- **Todas las fases SDD ([Bloque 5]-[Bloque 12])**: el Phase Common Protocol (§22.2) es el boilerplate que TODA fase carga junto a su `SKILL.md`. Las secciones A-E (skill loading, recuperación, persistencia, envelope, review guard) son idénticas en cada fase.
- **[Bloque 2] — DAG y Result Contract**: el Return Envelope de §22.2-D es exactamente el Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) que el [Bloque 2] documenta.
- **[Bloque 15] — Status y dispatcher**: §22.3 documenta el SCHEMA de status; el [Bloque 15] documenta su RUTEO operativo (cómo el orquestador decide la siguiente acción según `nextRecommended` y los dependency states). La regla "engram → no invocar dispatcher nativo" de §22.3 es la pieza clave que [Bloque 15] aplica.
- **[Bloque 19] — Contrato de persistencia**: §22.2-B/C (recuperación y persistencia de artefactos) inlinea lo que [Bloque 19] formaliza; el ordenamiento de respuesta de §22.2-D coincide con [Bloque 19] §19.8.
- **[Bloque 20] — Convención Engram**: la recuperación de dos pasos de §22.2-B y el `mem_save` con `capture_prompt: false` de §22.2-C consumen la convención de naming del [Bloque 20].
- **[Bloque 17] — Delivery/chain**: el Review Workload Guard de §22.2-E es la fuente del forecast (`400-line budget risk`, `Chained PRs recommended`) que el [Bloque 17] desarrolla a nivel de delivery strategy y chain strategy.
- **[Bloque 23] — Strict-TDD**: el flag `apply.tdd` y el forwarding de TDD estricto a `sdd-apply`/`sdd-verify` se conectan con el skill loading y el review guard de §22.2.
