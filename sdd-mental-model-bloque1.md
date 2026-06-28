# Bloque 1 — Qué es el SDD: filosofía y modelo orquestador-coordinador

> **QUÉ DOCUMENTA**: Este bloque establece el modelo mental del sistema SDD (Spec-Driven Development) de gentle-ai: qué problema resuelve, su filosofía de planificación estructurada para cambios sustanciales, y el modelo de ejecución "orquestador-coordinador" donde el agente principal coordina y delega en lugar de ejecutar.
> **ALCANCE**: Filosofía general, rol del orquestador como COORDINADOR, reglas de delegación, triggers de delegación obligatoria, balance de costo/contexto, y la frontera persona-vs-artefacto. NO cubre el detalle de cada fase (ver [Bloque 2]) ni los backends de persistencia (ver [Bloque 3]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Agent Teams Lite — Orchestrator Instructions", §"SDD Workflow (Spec-Driven Development)", §"Delegation Rules", §"Mandatory Delegation Triggers", §"Cost and Context Balance", §"Language Domain Contract", §"Model Assignments"
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` §"Executor boundary"
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por una fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 1.1 — Qué es el SDD y qué problema resuelve `[CERT]`

El SDD (Spec-Driven Development) es **la capa de planificación estructurada para cambios sustanciales** `[CERT]` (`CLAUDE.md` §"SDD Workflow": "SDD is the structured planning layer for substantial changes"). No es un framework de código ni un runtime; es un flujo de trabajo que impone disciplina de especificación antes de implementar.

La idea central es separar el "qué/por qué" del "cómo": primero se explora, se propone y se especifica un cambio, y solo después se implementa, se verifica y se archiva. Esto se materializa en un grafo de dependencias entre fases (ver [Bloque 2]) `[INFER]`.

El sistema se invoca mediante comandos (skills y meta-comandos):

| Comando | Tipo | Función `[CERT]` (`CLAUDE.md` §"Commands") |
|---------|------|--------|
| `/sdd-init` | skill | Inicializa contexto SDD; detecta stack, bootstrapea persistencia |
| `/sdd-explore <topic>` | skill | Investiga una idea; lee codebase, compara enfoques; no crea archivos |
| `/sdd-status [change]` | skill | Estado estructurado read-only del cambio activo |
| `/sdd-apply [change]` | skill | Implementa tareas en lotes; marca ítems |
| `/sdd-verify [change]` | skill | Valida implementación contra specs; reporta CRITICAL/WARNING/SUGGESTION |
| `/sdd-archive [change]` | skill | Cierra un cambio y persiste estado final |
| `/sdd-onboard` | skill | Recorrido guiado end-to-end usando el codebase real |
| `/sdd-new <change>` | meta-comando | Inicia cambio delegando exploración + propuesta a sub-agentes |
| `/sdd-continue [change]` | meta-comando | Corre la siguiente fase dependency-ready vía sub-agente(s) |
| `/sdd-ff <name>` | meta-comando | Fast-forward: proposal → specs → design → tasks |

Distinción clave `[CERT]` (`CLAUDE.md` §"Commands"): los **skills** aparecen en autocomplete; los **meta-comandos** (`/sdd-new`, `/sdd-continue`, `/sdd-ff`) se tipean directamente y los maneja el orquestador — NO se invocan como skills.

## 1.2 — El orquestador es un COORDINADOR, no un ejecutor `[CERT]`

El principio rector del modelo: *"You are a COORDINATOR, not an executor. Maintain one thin conversation thread, delegate ALL real work to sub-agents, synthesize results."* `[CERT]` (`CLAUDE.md` §"Agent Teams Orchestrator").

Hay dos niveles claramente separados:

1. **Orquestador** (hilo principal de conversación): mantiene un hilo delgado, delega el trabajo real, y sintetiza resultados. `[CERT]`
2. **Sub-agentes / fases** (contexto fresco, sin memoria): EJECUTAN el trabajo de la fase. `[CERT]`

Esta frontera se refuerza desde el lado del ejecutor: *"every SDD phase agent is an EXECUTOR, not an orchestrator. Do the phase work yourself. Do NOT launch sub-agents, do NOT call `delegate`/`task`, and do NOT bounce work back unless the phase skill explicitly says to stop and report a blocker."* `[CERT]` (`sdd-phase-common.md:5`).

**Implicación arquitectónica** `[INFER]`: es un patrón de un único nivel de delegación. El orquestador delega a fases; las fases NO vuelven a delegar. Esto evita explosión recursiva de sub-agentes y mantiene el árbol de ejecución plano y predecible.

> Nota de alcance `[CERT]` (`CLAUDE.md` §"Agent Teams Lite"): estas instrucciones de orquestador se atan SOLO a la regla del orquestador de Claude Code. NO se aplican a agentes de fase ejecutora como `sdd-apply` o `sdd-verify`.

## 1.3 — Criterio de delegación: ¿esto infla mi contexto sin necesidad? `[CERT]`

El criterio central para decidir entre hacer algo inline o delegar es una sola pregunta: *"does this inflate my context without need? If yes → delegate. If no → do it inline."* `[CERT]` (`CLAUDE.md` §"Delegation Rules").

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

## 1.4 — Triggers de delegación obligatoria (hard gates) `[CERT]`

A diferencia de las recomendaciones, estos son **stop rules no-skippables** del orquestador padre `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers": "non-skippable hard gates, not recommendations... TOTALMENTE obligatorio"). La indisponibilidad de tooling NO es una excepción: se documenta el bloqueo y se detiene el trabajo delegado.

Guard semántico `[CERT]`: **delegar** significa usar el mecanismo nativo de sub-agentes de la plataforma (`Agent`/`Task`/`delegate`). Correr scripts locales, Python o Bash inline es ejecución, NO delegación.

| # | Regla | Disparador `[CERT]` (`CLAUDE.md` §"Mandatory Delegation Triggers") |
|---|-------|-----------|
| 1 | **4-file rule** | Si entender requiere leer 4+ archivos → delegar exploración acotada |
| 2 | **Multi-file write rule** | Si la implementación tocará 2+ archivos no triviales → delegar un escritor |
| 3 | **PR rule** | Antes de commit/push/PR tras cambios de código → review de contexto fresco (salvo diff trivial de docs) |
| 4 | **Incident rule** | Tras `cwd` equivocado, mutación accidental de repo, recuperación de merge, etc. → auditoría fresca antes de continuar |
| 5 | **Long-session rule** | Tras ~20 tool calls, 5 lecturas exploratorias, o 2 edits no mecánicos sin delegar → pausar y delegar el resto |
| 6 | **Fresh review rule** | Usar contexto fresco para review adversarial de diffs/conflictos/PR/incidentes; continuidad/fork solo para implementación que necesita estado heredado |

Regla crítica de alcance `[CERT]`: estas reglas son stop rules del orquestador padre. NO se pasan a agentes hijos como permiso para spawnear más agentes; los hijos reciben trabajo concreto de rol y NO deben orquestar.

## 1.5 — Balance de costo y contexto `[CERT]`

El sistema distingue dos motivaciones diferentes para delegar `[CERT]` (`CLAUDE.md` §"Cost and Context Balance"):

- **Exploración** → comprime lectura amplia del repo en un handoff corto (ahorro de tokens).
- **Escritura** → un único hilo escritor para implementación; NO correr escritores en paralelo salvo worktrees aislados explícitamente aprobados.
- **Reviewers frescos** tras implementación/conflictos/incidentes → su valor es el **juicio independiente, NO el ahorro de tokens**. `[CERT]`

Cuándo NO delegar `[CERT]`: fixes de un solo archivo verdaderamente locales, chequeos rápidos de estado, y edits mecánicos ya entendidos.

**Modelo mental resultante** `[INFER]`: la delegación cumple DOS funciones que el sistema mantiene conceptualmente separadas — (a) compresión de contexto (exploración/escritura grande) y (b) independencia de juicio (review adversarial). Confundirlas lleva a sub-utilizar el review fresco o a sobre-delegar tareas triviales.

## 1.6 — La frontera persona vs. artefacto `[CERT]`

El sistema impone un **Language Domain Contract** que separa la voz de la persona del contenido técnico `[CERT]` (`CLAUDE.md` §"Language Domain Contract"):

- La persona activa controla **solo** la conversación directa con el usuario/orquestador: respuestas directas, prompts de clarificación, status de orquestación. `[CERT]`
- Los **artefactos técnicos generados** son en **inglés por defecto**, sin importar la persona ni el idioma de conversación: archivos OpenSpec, specs, designs, tasks, comentarios de código, copy de UI, tests, fixtures, y salidas de fases delegadas. `[CERT]`
- Si se piden artefactos técnicos en español explícitamente → español neutral/profesional, salvo que el usuario pida una variante regional. `[CERT]`

Regla de forwarding `[CERT]`: al delegar, el orquestador DEBE reenviar este contrato al ejecutor para que la voz de la persona nunca se convierta en el default del artefacto o de comentarios públicos.

**Por qué importa** `[INFER]`: el orquestador puede hablarle al usuario con tono cálido y directo (la persona), pero lo que el pipeline SDD *produce* es neutro y profesional. Es la misma separación que un arquitecto que explica con pasión pero documenta con rigor.

## 1.7 — Conexiones

- **[Bloque 2] — DAG de fases y Result Contract**: el "trabajo real" que el orquestador delega son las fases del DAG (`proposal → specs → tasks → apply → verify → archive`, con `design` alimentando `specs`). El [Bloque 2] detalla cada fase, sus dependencias, y el Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) que toda fase devuelve al orquestador. La frontera EXECUTOR descrita en §1.2 es la contraparte de cada fase del DAG.
- **[Bloque 3] — Backends de artefactos y topic keys**: cuando el orquestador delega, los sub-agentes leen y escriben artefactos en un backend (`engram`/`openspec`/`hybrid`/`none`). El [Bloque 3] explica cómo el modelo coordinador-ejecutor decide quién lee y quién escribe contexto según el tipo de tarea (SDD vs. no-SDD), elaborando el "Sub-Agent Context Protocol".
- **[Bloque 18] — Delegación, triggers y model assignments**: profundiza los hard gates de §1.4 y la tabla de asignación de modelos por fase (cada fase SDD/Judgment-Day mapea a un alias de modelo; las Agent calls de fase DEBEN incluir `model`, la delegación genérica NO). `[CERT]` (`CLAUDE.md` §"Model Assignments").
- **[Bloque 19] — persistence-contract**: formaliza el "Sub-Agent Context Rules" (quién lee, quién escribe) que aquí se introduce a nivel filosófico en §1.2.
