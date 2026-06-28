# Bloque 2 — El DAG de fases y el Result Contract

> **QUÉ DOCUMENTA**: Este bloque describe el grafo de dependencias (DAG) de las fases SDD, qué lee y qué escribe cada fase, el flujo de routing entre fases, y el Result Contract — el sobre estructurado que toda fase devuelve al orquestador. Es el esqueleto operativo del SDD.
> **ALCANCE**: El DAG completo (`proposal → specs → tasks → apply → verify → archive`, con `design` alimentando `specs`), la tabla read/write por fase, el envelope de retorno, las reglas de ordenamiento de respuesta del sub-agente, y el Review Workload Guard. NO cubre el detalle interno de cada fase individual (ver bloques B4–B12), ni los modos auto/interactive ni el Gatekeeper (ver [Bloque 16]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Dependency Graph", §"Result Contract", §"Sub-Agent Context Protocol" (tabla de fases reads/writes), §"Engram Topic Key Format"
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` §D "Return Envelope", §C "Artifact Persistence", §E "Review Workload Guard"
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` §"Sub-Agent Context Rules"
> **MÉTODO**: Marcadores de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección`. `[CERT-a]` = afirmado por una fuente, no re-verificado en origen primario. `[INFER]` = deducción propia.

---

## 2.1 — El grafo de dependencias `[CERT]`

El DAG canónico, literal de la fuente `[CERT]` (`CLAUDE.md` §"Dependency Graph"):

```
proposal -> specs --> tasks -> apply -> verify -> archive
             ^
             |
           design
```

Lectura del grafo `[CERT]`:
- La cadena principal es lineal: `proposal → specs → tasks → apply → verify → archive`.
- `design` NO está en la cadena principal: alimenta `specs` (la flecha `design → specs`). `[CERT]`
- `tasks` depende de `specs` (y, vía la confluencia, del trabajo de `design`).

**Matiz importante** `[INFER]`: el grafo dibuja `design -> specs`, pero la tabla de dependencias de lectura (§2.2) muestra que `sdd-tasks` lee **spec + design** y `sdd-design` lee **proposal**. Es decir, `design` y `specs` son ramas paralelas que parten de `proposal` y confluyen en `tasks`. El diagrama ASCII comprime esa confluencia poniendo la flecha de `design` hacia `specs`, pero operativamente ambos son insumos de `tasks`.

## 2.2 — Qué lee y qué escribe cada fase `[CERT]`

Tabla literal del contrato de contexto por fase `[CERT]` (`CLAUDE.md` §"Sub-Agent Context Protocol" → "SDD Phases"):

| Fase | Lee | Escribe |
|------|-----|---------|
| `sdd-explore` | nada | `explore` |
| `sdd-propose` | exploration (opcional) | `proposal` |
| `sdd-spec` | proposal (requerido) | `spec` |
| `sdd-design` | proposal (requerido) | `design` |
| `sdd-tasks` | spec + design (requeridos) | `tasks` |
| `sdd-apply` | tasks + spec + design + **apply-progress (si existe)** | `apply-progress` |
| `sdd-verify` | spec + tasks + **apply-progress** | `verify-report` |
| `sdd-archive` | todos los artefactos | `archive-report` |

Reglas de acceso a contexto `[CERT]` (`CLAUDE.md` §"Sub-Agent Context Protocol"):
- Para fases con dependencias requeridas, el **sub-agente lee directamente del backend** — el orquestador pasa *referencias* de artefacto (topic keys o file paths), NO el contenido. `[CERT]`
- Esto evita inflar el prompt del orquestador: los artefactos SDD son grandes; inlinearlos consumiría toda la ventana de contexto. `[CERT]` (`persistence-contract.md:87`).

Quién lee / quién escribe, según tipo de tarea `[CERT]` (`persistence-contract.md:80-88`):
- No-SDD (tarea general): el **orquestador** busca en engram y pasa resumen en el prompt; el sub-agente guarda descubrimientos vía `mem_save`.
- SDD con dependencias: el **sub-agente** lee artefactos directo del backend; el sub-agente guarda su artefacto.
- SDD sin dependencias (ej. explore): nadie lee; el sub-agente guarda su artefacto. `[CERT]`

## 2.3 — Routing: cómo se avanza por el DAG `[CERT]`

El avance NO es por inferencia de texto libre. El sistema enrolla por `nextRecommended` y estados de dependencia `[CERT]` (`CLAUDE.md` §"Native SDD Dispatcher Guard": "Route only by `nextRecommended` and dependency states; never infer from free text").

Cada fase devuelve un campo `next_recommended` (la siguiente fase SDD a correr, o `"none"`) como parte del Result Contract `[CERT]` (`sdd-phase-common.md:79`). El meta-comando `/sdd-continue` corre la siguiente fase **dependency-ready** vía sub-agente `[CERT]` (`CLAUDE.md` §"Commands").

Reglas de routing del dispatcher `[CERT]` (`CLAUDE.md` §"Native SDD Dispatcher Guard"):
- Si `blockedReasons` no está vacío → NO proceder a apply/archive/trabajo terminal.
- Si `nextRecommended` es `verify` → verificación/remediación solo para refrescar evidencia.
- Si `nextRecommended` es `resolve-blockers` → reportar `blockedReasons` y parar.
- Si `nextRecommended` es un token de planificación (`propose`, `spec`, `design`, `tasks`) → lanzar la fase de planificación correspondiente.

> El detalle del dispatcher nativo `gentle-ai` y su scoping por backend se trata en [Bloque 15]. Aquí basta saber: el routing es por estado y dependencia, nunca por interpretación de prosa. `[INFER]`

## 2.4 — El Result Contract (sobre de retorno) `[CERT]`

Cada fase devuelve un sobre estructurado al orquestador. Resumen literal `[CERT]` (`CLAUDE.md` §"Result Contract"): *"Each phase returns: `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`."*

La definición completa de cada campo `[CERT]` (`sdd-phase-common.md:73-81`):

| Campo | Valores / Contenido `[CERT]` |
|-------|-------------------|
| `status` | `success`, `partial`, o `blocked` |
| `executive_summary` | Resumen de 1-3 frases de lo hecho |
| `detailed_report` | (opcional) salida completa de la fase, u omitir si ya está inline |
| `artifacts` | Lista de keys/paths de artefactos escritos |
| `next_recommended` | La siguiente fase SDD a correr, o `"none"` |
| `risks` | Riesgos descubiertos, o `"None"` |
| `skill_resolution` | Cómo se cargaron skills: `paths-injected`, `fallback-registry`, `fallback-path`, o `none` |

Ejemplo de envelope `[CERT]` (`sdd-phase-common.md:85-92`):

```markdown
**Status**: success
**Summary**: Proposal created for `{change-name}`. Defined scope, approach, and rollback plan.
**Artifacts**: Engram `sdd/{change-name}/proposal` | `openspec/changes/{change-name}/proposal.md`
**Next**: sdd-spec or sdd-design
**Risks**: None
**Skill Resolution**: paths-injected — 3 skills (react-19, typescript, tailwind-4)
```

Detalle de `skill_resolution` `[CERT]` (`sdd-phase-common.md:81`):
- `paths-injected` → recibió paths exactos de skills del orquestador (preferido).
- `fallback-registry` → se auto-cargó paths desde el registry.
- `fallback-path` → cargó vía instrucción `SKILL: Load`.
- `none` → no se cargaron skills.

Este campo es un **mecanismo de auto-corrección** `[CERT]` (`CLAUDE.md` §"Skill Resolution Feedback"): si el orquestador ve `fallback-*` o `none`, significa que el cache de skills se perdió (probable compactación) y debe re-leer el registry antes de la próxima delegación.

## 2.5 — Ordenamiento de respuesta: el último output debe ser texto `[CERT]`

Regla CRÍTICA de ordenamiento `[CERT]` (`sdd-phase-common.md:71`, `persistence-contract.md:140-146`): *"Your FINAL output MUST be text (the return envelope), NOT a tool call. If you need to save to Engram (`mem_save`), do it BEFORE your final text response."*

El **porqué** `[CERT]` (`persistence-contract.md:144`): la herramienta Task devuelve al padre el output final del sub-agente. Si el sub-agente termina con un tool call, el padre recibe SOLO el resultado de la herramienta (ej. `"Observation saved"`) — el análisis en texto del sub-agente se PIERDE.

Secuencia correcta siempre `[CERT]` (`persistence-contract.md:144`): *hacer el trabajo → guardar → responder con el envelope de texto*.

Restricción adicional `[CERT]` (`sdd-phase-common.md:71`, `persistence-contract.md:146`): los sub-agentes NO deben llamar `mem_session_summary` — eso queda reservado para agentes de nivel superior (orquestador).

## 2.6 — Persistencia obligatoria de artefactos `[CERT]`

Toda fase que produce un artefacto DEBE persistirlo. Saltearlo ROMPE el pipeline — las fases downstream no encontrarán el output `[CERT]` (`sdd-phase-common.md:37-39`).

El cómo de la persistencia depende del backend (detallado en [Bloque 3]). Resumen por modo `[CERT]` (`sdd-phase-common.md:41-67`):

| Modo | Acción de persistencia `[CERT]` |
|------|----------------------|
| `engram` | `mem_save(title, topic_key: "sdd/{change-name}/{artifact-type}", type: "architecture", project, capture_prompt: false, content)` |
| `openspec` | El archivo ya se escribió en el paso principal de la fase; sin acción adicional |
| `hybrid` | AMBOS: escribir el archivo Y llamar `mem_save` |
| `none` | Devolver resultado inline; NO escribir archivos ni `mem_save` |

`topic_key` habilita upserts — guardar de nuevo actualiza, no duplica `[CERT]` (`sdd-phase-common.md:54`). `capture_prompt: false` es obligatorio para artefactos SDD porque son salidas automatizadas del pipeline, no memoria humana/proactiva `[CERT]` (`sdd-phase-common.md:55`).

## 2.7 — Recuperación de artefactos por el sub-agente (engram) `[CERT]`

Para fases con dependencias, el sub-agente recupera el insumo en DOS pasos `[CERT]` (`sdd-phase-common.md:19-35`):

```
mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → save ID
mem_get_observation(id: {saved_id}) → full content (REQUIRED)
```

ADVERTENCIA crítica `[CERT]` (`sdd-phase-common.md:21`): *"`mem_search` returns 300-char PREVIEWS, not full content. You MUST call `mem_get_observation(id)` for EVERY artifact. Skipping this produces wrong output."*

Optimización `[CERT]` (`sdd-phase-common.md:23,29`): correr todas las búsquedas en paralelo primero, luego todas las recuperaciones en paralelo — NO secuencial.

## 2.8 — Continuidad de apply-progress entre lotes `[CERT]`

`sdd-apply` implementa en lotes y produce un artefacto `apply-progress` por lote `[CERT]` (`engram-convention.md:29`: "`apply-progress` ... Implementation progress (one per batch)").

Para lotes de continuación (no el primero), el orquestador DEBE indicarle al sub-agente que existe progreso previo `[CERT]` (`CLAUDE.md` §"Apply-Progress Continuity"):
- Buscar: `mem_search(query: "sdd/{change-name}/apply-progress", ...)`.
- Si existe → instruir: *"You MUST read it first ... merge your new progress with the existing progress, and save the combined result. Do NOT overwrite — MERGE."* `[CERT]`

Esto previene pérdida de progreso entre lotes; el sub-agente es responsable del read-merge-write, pero el orquestador DEBE avisarle que hay progreso previo `[CERT]`.

## 2.9 — Review Workload Guard `[CERT]`

El SDD debe proteger la carga cognitiva del reviewer, no solo generar tareas `[CERT]` (`sdd-phase-common.md:95-97`). Reglas clave:

- Presupuesto default de review por PR: **400 líneas cambiadas** (`additions + deletions`). `[CERT]` (`sdd-phase-common.md:99`).
- El orquestador DEBE cachear una `delivery_strategy` al inicio de sesión: `ask-on-risk` (default), `auto-chain`, `single-pr`, o `exception-ok`. `[CERT]` (`sdd-phase-common.md:100`).
- `sdd-tasks` DEBE pronosticar si el trabajo planeado puede exceder el presupuesto, con líneas guard de texto plano exactas: `Decision needed before apply: Yes|No`, `Chained PRs recommended: Yes|No`, `400-line budget risk: Low|Medium|High`. `[CERT]` (`sdd-phase-common.md:103`).
- `sdd-apply` NO debe arrancar trabajo oversized salvo que la estrategia resuelva a slices de PR chained/stacked o un `size:exception` explícitamente aceptado. `[CERT]` (`sdd-phase-common.md:105`).

> El detalle de delivery strategy, chain strategy y chained-PR se trata en [Bloque 17]; el Review Workload Guard del orquestador (cuándo parar y preguntar) en [Bloque 16].

## 2.10 — Conexiones

- **[Bloque 1] — Qué es SDD**: el DAG aquí descrito es el "trabajo real" que el orquestador-coordinador delega. La frontera EXECUTOR del [Bloque 1] §1.2 es lo que cada nodo del DAG ejecuta.
- **[Bloque 4 a Bloque 12]** — fases individuales: cada fila de la tabla §2.2 corresponde a un bloque dedicado: B4 `sdd-init`, B5 `sdd-explore`, B6 `sdd-propose`, B7 `sdd-spec`, B8 `sdd-design`, B9 `sdd-tasks`, B10 `sdd-apply`, B11 `sdd-verify`, B12 `sdd-archive`. Esos bloques detallan el "cómo" interno de cada lectura/escritura listada aquí.
- **[Bloque 3] — Backends de artefactos**: §2.6 y §2.7 dependen del modo de backend resuelto; el [Bloque 3] explica `engram`/`openspec`/`hybrid`/`none` y el formato de topic keys (`sdd/{change-name}/{artifact-type}`).
- **[Bloque 15] — sdd-status y dispatcher nativo**: el routing por `nextRecommended` de §2.3 lo materializa el dispatcher nativo `gentle-ai`, scopeado por backend.
- **[Bloque 16] — modos auto/interactive y Gatekeeper**: el Gatekeeper valida el Result Contract (§2.4) entre fase y fase en modo automático.
- **[Bloque 19] — persistence-contract**: formaliza el "quién lee/quién escribe" de §2.2 y las reglas de ordenamiento de §2.5.
