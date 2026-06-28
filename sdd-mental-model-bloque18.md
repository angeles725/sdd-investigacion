# Bloque 18 — Modelo de delegación, triggers obligatorios y model assignments

> **QUÉ DOCUMENTA**: Este bloque consolida el modelo de delegación del orquestador SDD: la tabla de decisión inline-vs-delegar, los seis Mandatory Delegation Triggers (hard gates), la tabla de Model Assignments (fase → modelo → effort → razón), el mandatory model gate por fase, y la deduplicación de lanzamientos de sub-agentes.
> **ALCANCE**: El criterio de delegación, los seis triggers no-skippables, el balance costo/contexto, la tabla de modelos por fase SDD/Judgment-Day, el model gate obligatorio, el Skill Resolver Protocol resumido, y la dedup de launches. Es la capa transversal que gobierna CÓMO el orquestador convoca a TODAS las fases. Para el detalle de cada fase, ver [Bloque 5] a [Bloque 12].
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Delegation Rules", §"Mandatory Delegation Triggers", §"Cost and Context Balance", §"Model Assignments", §"Sub-Agent Launch Deduplication (MANDATORY)", §"Sub-Agent Launch Pattern", §"Result Contract"
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta §sección`. `[CERT-a]` = afirmado por fuente, no re-verificado. `[INFER]` = deducción propia.

---

## 18.1 — El criterio raíz: ¿esto infla mi contexto sin necesidad? `[CERT]`

El principio rector de toda la delegación es una sola pregunta `[CERT]` (`CLAUDE.md` §"Delegation Rules"): *"does this inflate my context without need? If yes → delegate. If no → do it inline."*

La tabla de decisión `[CERT]` (`CLAUDE.md` §"Delegation Rules"):

| Acción | Inline | Delegar |
|--------|--------|---------|
| Leer para decidir/verificar (1-3 archivos) | ✅ | — |
| Leer para explorar/entender (4+ archivos) | — | ✅ |
| Leer como preparación para escribir | — | ✅ junto con la escritura |
| Escribir atómico (un archivo, mecánico, ya sabés qué) | ✅ | — |
| Escribir con análisis (múltiples archivos, lógica nueva) | — | ✅ |
| Bash para estado (git, gh) | ✅ | — |
| Bash para ejecución (test, build, install) | — | ✅ |

Anti-patrones que SIEMPRE inflan contexto sin necesidad `[CERT]` (`CLAUDE.md` §"Delegation Rules"):

- Leer 4+ archivos para "entender" el codebase inline → delegar una exploración.
- Escribir una feature a través de múltiples archivos inline → delegar.
- Correr tests o builds inline → delegar.
- Leer archivos como preparación para edits y luego editar → delegar todo junto.

Guard semántico crítico `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers"): **delegar** significa usar el mecanismo nativo de sub-agentes de la plataforma (`Agent`/`Task`/`delegate`). Correr scripts locales, Python o Bash inline es EJECUCIÓN, no delegación.

(Esta sección es la base que [Bloque 1] introduce a nivel filosófico; aquí se trata como la mecánica operativa que gobierna cada launch.)

## 18.2 — Los seis Mandatory Delegation Triggers `[CERT]`

Son **stop rules no-skippables del orquestador padre** — NO recomendaciones `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers": "non-skippable hard gates, not recommendations... TOTALMENTE obligatorio"). La indisponibilidad de tooling NO es waiver: se documenta el bloqueo, se detiene el trabajo delegado bloqueado, y se hace la auditoría de contexto fresco más cercana solo donde la regla lo pida.

| # | Regla | Disparador y acción requerida `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers") |
|---|-------|---------------------------------------------------------------------------------------|
| 1 | **4-file rule** | Si entender requiere leer 4+ archivos → delegar exploración/mapeo acotado. Si no hay tooling de delegación → documentar el bloqueo y DETENER la exploración, no leer todo inline. |
| 2 | **Multi-file write rule** | Si la implementación tocará 2+ archivos no triviales → delegar UN escritor. Sin tooling → documentar y detener; un review fresco es requerido DESPUÉS de la implementación delegada, no sustituto de la delegación. |
| 3 | **PR rule** | Antes de commit/push/PR tras cambios de código → review de contexto fresco, salvo diff trivial de docs/texto. |
| 4 | **Incident rule** | Tras `cwd` equivocado, mutación accidental de repo/worktree, recuperación de merge, comando de test confuso, o workaround de entorno → DETENER y correr auditoría fresca antes de continuar. |
| 5 | **Long-session rule** | Tras ~20 tool calls, 5 lecturas exploratorias, o 2 edits no mecánicos sin delegar y complejidad creciente → pausar y delegar el resto. Sin tooling → documentar y detener el trabajo complejo. |
| 6 | **Fresh review rule** | Usar contexto fresco para review adversarial de diffs/conflictos/PR readiness/incidentes; usar continuidad/fork SOLO para implementación que necesita estado heredado. |

Reglas de alcance de los triggers `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers"):

- Son stop rules del orquestador PADRE. NO se pasan a agentes hijos como permiso para spawnear más agentes. Los hijos reciben trabajo concreto de rol y NO deben orquestar.
- Las reglas que dicen **delegate** requieren delegación nativa de sub-agentes. Las que dicen **fresh review/audit** requieren contexto fresco antes de continuar.

**Modelo mental** `[INFER]`: los seis triggers se agrupan en dos familias. Los pares (1, 2, 5) son triggers de **compresión de contexto** — cuando el trabajo crece (4 archivos, 2 escrituras, 20 tool calls), delegar para no inflar el hilo. Los pares (3, 4, 6) son triggers de **independencia de juicio** — cuando hay riesgo (PR, incidente, review), usar contexto FRESCO porque su valor es la objetividad, no el ahorro de tokens. Es la misma dualidad que [Bloque 1] §1.5 establece.

## 18.3 — Balance costo y contexto `[CERT]`

El sistema mantiene conceptualmente separadas dos motivaciones para delegar `[CERT]` (`CLAUDE.md` §"Cost and Context Balance"):

- **Exploración** → comprime lectura amplia del repo en un handoff corto (ahorro de tokens).
- **Escritura** → un único hilo escritor para implementación; NO correr escritores en paralelo salvo worktrees aislados explícitamente aprobados.
- **Reviewers frescos** tras implementación/conflictos/incidentes → su valor es el juicio INDEPENDIENTE, no el ahorro de tokens.
- **NO delegar** para: fixes de un solo archivo verdaderamente locales, chequeos rápidos de estado, edits mecánicos ya entendidos.

Regla de paralelismo de escritura `[CERT]`: un solo hilo escritor para implementación; no escritores paralelos salvo worktrees aislados aprobados explícitamente. Esto previene conflictos de escritura concurrente sobre los mismos archivos.

## 18.4 — La tabla de Model Assignments `[CERT]`

El orquestador lee esta tabla al inicio de sesión, la cachea, y usa el alias mapeado SOLO para agentes de fase SDD/Judgment-Day `[CERT]` (`CLAUDE.md` §"Model Assignments"). La tabla completa `[CERT]`:

| Fase | Modelo default | Effort | Razón `[CERT]` (`CLAUDE.md` §"Model Assignments") |
|------|----------------|--------|---------------------------------------------------|
| `sdd-explore` | sonnet | default | Lee código, estructural — no arquitectónico |
| `sdd-propose` | opus | default | Decisiones arquitectónicas |
| `sdd-spec` | sonnet | default | Escritura estructurada |
| `sdd-design` | opus | default | Decisiones de arquitectura |
| `sdd-tasks` | sonnet | default | Desglose mecánico |
| `sdd-apply` | sonnet | default | Implementación |
| `sdd-verify` | sonnet | default | Validación contra spec |
| `sdd-archive` | haiku | default | Copiar y cerrar |
| `sdd-onboard` | haiku | default | Walkthrough guiado, pedagógico |
| `jd-judge-a` | sonnet | default | Review adversarial — juez ciego A |
| `jd-judge-b` | sonnet | default | Review adversarial — juez ciego B |
| `jd-fix-agent` | sonnet | default | Fixes quirúrgicos de issues confirmados |
| `default` | sonnet | default | Fallback de fase SDD/JD |

Reglas de la tabla `[CERT]` (`CLAUDE.md` §"Model Assignments"):

- Si una fase SDD/JD falta en la tabla → usar la fila `default`.
- Si no se tiene acceso al modelo asignado (ej. sin acceso a Opus) → sustituir por `sonnet` y continuar.
- El modelo de la sesión de Claude Code lo controla Claude Code mismo; Gentle AI NO configura el modelo del orquestador principal. *"This table applies only to Agent tool calls for SDD/Judgment-Day phase sub-agents, not generic delegation."* `[CERT]`.

**Por qué cada modelo** `[INFER]`: la tabla mapea **complejidad cognitiva → capacidad de modelo**. Las dos únicas fases con **opus** son `sdd-propose` y `sdd-design` — las que toman decisiones ARQUITECTÓNICAS, donde un error compounde downstream (las mismas fases de alto riesgo del Gatekeeper en [Bloque 16]). Las fases de escritura estructurada o mecánica (`spec`, `tasks`, `apply`, `verify`) usan **sonnet**: capaces pero no tienen que decidir arquitectura. Las fases de copiar/cerrar y pedagógicas (`archive`, `onboard`) usan **haiku**: trabajo mecánico o de bajo riesgo donde el modelo más barato basta. Es asignación de recurso proporcional al riesgo de la decisión.

## 18.5 — El Mandatory Phase Model Gate `[CERT]`

Regla dura `[CERT]` (`CLAUDE.md` §"Model Assignments"): *"Agent tool calls for SDD/Judgment-Day phase agents MUST include `model`. Generic/non-SDD delegation MUST NOT use this table; omit `model` unless the user explicitly requested an override."*

El pre-flight obligatorio antes de cada Agent call de fase SDD/JD `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Pattern"):

1. Identificar la fase SDD/JD (`sdd-apply`, `sdd-verify`, `jd-judge-a`, etc.) o usar `default` solo como fallback de fase.
2. Buscar el alias en la tabla de Model Assignments.
3. Incluir `model: "<alias>"` en la Agent tool call SDD/JD.
4. Para delegación genérica/no-SDD: NO usar esta tabla; omitir `model` salvo override explícito del usuario.

**La frontera del gate** `[INFER]`: hay DOS clases de delegación con reglas opuestas sobre `model`. Las Agent calls de FASE SDD/JD DEBEN llevar `model` (resuelto de la tabla). La delegación GENÉRICA (exploraciones ad-hoc, reviewers no-fase, búsquedas) NO debe llevar `model` salvo que el usuario lo pida. Mezclarlas es un error: poner `model` en una delegación genérica fuerza un modelo que el usuario no eligió; omitirlo en una fase SDD viola el gate. El gate existe para que cada fase corra en el modelo correcto SIN que el costo de Opus se derrame a tareas que no lo necesitan.

## 18.6 — Skill Resolver Protocol (resumen operativo) `[CERT]`

Todo prompt de launch de sub-agente que involucre leer/escribir/revisar código DEBE incluir **rutas de skill pre-resueltas** del registry `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Pattern"). El orquestador resuelve skills del registry UNA vez (al inicio de sesión o primera delegación), cachea el índice, y pasa las rutas de `SKILL.md` matcheantes en cada prompt de sub-agente.

Resolución del orquestador (una vez por sesión) `[CERT]`:

1. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` para el contenido completo.
2. Fallback: leer `.atl/skill-registry.md` si engram no está disponible.
3. Cachear el índice: nombre de skill, trigger/descripción, scope, ruta exacta.
4. Si no hay registry → advertir al usuario y proceder sin estándares específicos del proyecto.

Por cada launch `[CERT]`: matchear skills por **contexto de código** (extensiones/rutas que el sub-agente tocará) Y **contexto de tarea** (qué acciones hará — review, PR, testing). Copiar las rutas `SKILL.md` matcheantes en el prompt como `## Skills to load before work`. Instruir al sub-agente a leer esos archivos exactos ANTES del trabajo.

Regla clave `[CERT]`: *"pass paths, not generated summaries."* Los sub-agentes leen los `SKILL.md` completos para preservar la intención del autor. Es compaction-safe: cada delegación puede re-leer el registry si el cache se pierde `[CERT]`.

Feedback de resolución `[CERT]` (`CLAUDE.md` §"Skill Resolution Feedback"): tras cada delegación, chequear el campo `skill_resolution` del Result Contract — `paths-injected` (ok), o `fallback-registry`/`fallback-path`/`none` (cache perdido, probablemente por compaction → re-leer el registry inmediatamente).

## 18.7 — Sub-Agent Launch Deduplication `[CERT]`

Antes de emitir cualquier Agent tool call, el orquestador chequea su log de launches de la sesión `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Deduplication"):

- Mantener una lista session-scoped de pares `(phase, task-fingerprint)` ya lanzados este turno.
- El task fingerprint es un hash corto o resumen normalizado del texto de instrucción (nombre de fase + referencias clave de artefacto).
- Si el mismo `(phase, task-fingerprint)` ya aparece → **NO lanzar de nuevo**. Emitir exactamente UN launch por tarea distinta.
- Tras lanzar, agregar el par a la lista.

Propósito `[CERT]`: *"This prevents duplicate sub-agent launches that cause 'File X has been modified since it was last read' conflicts and waste tokens."* `[CERT]` (`CLAUDE.md` §"Sub-Agent Launch Deduplication").

**Modelo mental** `[INFER]`: la dedup ataca un fallo concreto de los orquestadores LLM — relanzar la misma fase dos veces (por confusión de estado o compaction), produciendo dos sub-agentes que editan el mismo archivo y colisionan ("modified since last read"). El fingerprint `(phase + artefacto)` es la clave de idempotencia: dos launches con la misma clave son el mismo trabajo, y el segundo se suprime.

## 18.8 — Cómo todo esto envuelve a cada fase `[CERT]`

Cada launch de fase SDD/JD pasa por una secuencia de gates `[INFER]` (síntesis de §18.5, §18.6, §18.7):

1. **Dedup check** (§18.7): ¿ya lancé este `(phase, fingerprint)`? Si sí, abortar el launch.
2. **Model gate** (§18.5): resolver el alias de la tabla y poner `model: "<alias>"`.
3. **Skill resolution** (§18.6): matchear skills por código+tarea e inyectar rutas `SKILL.md` como `## Skills to load before work`.
4. **Context protocol**: para fases SDD, pasar referencias de artefacto (topic keys o rutas), no contenido (ver [Bloque 3]).
5. El sub-agente ejecuta y devuelve el **Result Contract** (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) — ver [Bloque 2].
6. El orquestador chequea `skill_resolution` (§18.6) y, en modo auto, corre el Gatekeeper (ver [Bloque 16]).

**Síntesis** `[INFER]`: este bloque es la "capa de protocolo de transporte" del SDD. Las fases ([Bloque 5]-[Bloque 12]) son el QUÉ; este bloque es el CÓMO se las convoca: con qué modelo, con qué skills, sin duplicar, comprimiendo o aislando contexto según el tipo de trabajo. Todo launch de fase atraviesa estos gates antes de existir.

## 18.9 — Conexiones

- **[Bloque 1] — filosofía**: introduce el criterio de delegación (§18.1) y los seis triggers (§18.2) a nivel filosófico. Este bloque los trata como mecánica operativa de cada launch.
- **[Bloque 2] — DAG + Result Contract**: el `model` que el gate inyecta (§18.5) y el `skill_resolution` que se chequea (§18.6) operan sobre las fases del DAG; el Result Contract que toda fase devuelve es el de [Bloque 2].
- **[Bloque 3] — backends + topic keys**: el paso 4 del envoltorio (§18.8) — pasar referencias de artefacto, no contenido — es el Sub-Agent Context Protocol de [Bloque 3].
- **[Bloque 5] a [Bloque 12] — todas las fases**: la tabla de Model Assignments (§18.4) mapea exactamente estas fases a su modelo. Cada una se convoca con los gates de §18.8.
- **[Bloque 16] — Gatekeeper**: el reviewer fresco del Gatekeeper para fases de alto riesgo usa el alias `sdd-verify` con el model gate de §18.5. Los dos modelos opus (`propose`, `design`) son las fases de alto riesgo del Gatekeeper.
- **[Bloque 22] — skill-resolver**: el Skill Resolver Protocol resumido en §18.6 vive en detalle en los contratos `_shared/` que [Bloque 22] documenta (`~/.claude/skills/_shared/skill-resolver.md`).
- **[Bloque 24] — judgment-day**: las fases `jd-judge-a`, `jd-judge-b`, `jd-fix-agent` de la tabla de modelos (§18.4) pertenecen al protocolo judgment-day de [Bloque 24].
