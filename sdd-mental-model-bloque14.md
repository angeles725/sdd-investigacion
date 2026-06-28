# Bloque 14 — Meta-comandos: `sdd-new`, `sdd-continue`, `sdd-ff`

> **QUÉ DOCUMENTA**: Este bloque documenta los tres **meta-comandos** del SDD — `/sdd-new`, `/sdd-continue` y `/sdd-ff` — que el orquestador maneja directamente en lugar de invocarlos como skills. Explica qué hace cada uno, el HARD GATE de Session Preflight compartido, el flujo de delegación a sub-agentes, y el concepto de "fast-forward" de planificación.
> **ALCANCE**: La definición de meta-comando vs. skill, el workflow interno de cada uno, el grafo de planificación que recorren, y cómo se diferencian de las fases que orquestan. NO cubre el detalle interno de cada fase delegada (ver [Bloque 5] a [Bloque 12]), ni el dispatcher nativo `gentle-ai` (ver [Bloque 15]), ni los modos auto/interactive (ver [Bloque 16]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/commands/sdd-new.md` (líneas 1-32)
> - `/home/cristian/.config/opencode/commands/sdd-continue.md` (líneas 1-40)
> - `/home/cristian/.config/opencode/commands/sdd-ff.md` (líneas 1-38)
> - `/home/cristian/.claude/CLAUDE.md` §"Commands", §"Execution Mode", §"Dependency Graph"
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por una fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 14.1 — Meta-comando vs. skill: la distinción de fondo `[CERT]`

El sistema SDD divide sus comandos en dos clases con mecanismos de despacho diferentes `[CERT]` (`CLAUDE.md` §"Commands"):

- **Skills**: aparecen en autocomplete. Son `/sdd-init`, `/sdd-explore`, `/sdd-status`, `/sdd-apply`, `/sdd-verify`, `/sdd-archive`, `/sdd-onboard`. Cada uno corresponde a un sub-agente de fase con su propio `SKILL.md`.
- **Meta-comandos**: se tipean directamente, NO aparecen en autocomplete, y los maneja el orquestador. Son `/sdd-new`, `/sdd-continue` y `/sdd-ff`.

La instrucción es explícita `[CERT]` (`CLAUDE.md` §"Commands"): *"`/sdd-new`, `/sdd-continue`, and `/sdd-ff` are meta-commands handled by YOU. Do NOT invoke them as skills."*

**Por qué la distinción importa** `[INFER]`: un skill es una unidad de trabajo atómica (una fase ejecuta y devuelve). Un meta-comando es un **plan de orquestación**: no hace trabajo de fase, sino que decide qué fases lanzar, en qué orden, y con qué gating. El orquestador es el dueño del meta-comando; las fases son los obreros que el meta-comando convoca.

Una sutileza de implementación `[CERT]`: aunque los tres archivos `.md` existen físicamente en `/home/cristian/.config/opencode/commands/` con frontmatter `agent: gentle-orchestrator`, su contenido NO es un skill ejecutable — es un guion de orquestación que el `gentle-orchestrator` lee y obedece. Cada archivo cierra con: *"Read the orchestrator instructions to coordinate this workflow. Do NOT execute phase work inline — delegate to sub-agents."* `[CERT]` (`sdd-new.md:31`, `sdd-continue.md:35`, `sdd-ff.md:37`).

## 14.2 — El HARD GATE compartido: Session Preflight `[CERT]`

Los tres meta-comandos abren con un **HARD GATE idéntico** que bloquea cualquier ejecución hasta que el Session Preflight esté completo `[CERT]` (`sdd-new.md:8-9`, `sdd-continue.md:8-9`, `sdd-ff.md:8-9`):

> *"SDD Session Preflight must already be complete for this session. It must include execution mode, artifact store, chained PR strategy, and review budget. If missing, ask the exact orchestrator preflight prompt and STOP. Do not launch exploration or proposal in the same turn."*

Los cuatro elementos que el preflight DEBE tener `[CERT]`:

| Elemento | Qué decide | Bloque que lo detalla |
|----------|-----------|----------------------|
| **Execution mode** | auto vs. interactive | [Bloque 16] |
| **Artifact store** | engram / openspec / hybrid / none | [Bloque 3], [Bloque 15] |
| **Chained PR strategy** | stacked-to-main / feature-branch-chain | [Bloque 17] |
| **Review budget** | presupuesto de líneas / delivery strategy | [Bloque 17] |

Regla operativa crítica `[CERT]`: si falta el preflight, el orquestador **pregunta el prompt exacto de preflight y SE DETIENE** — no lanza exploración ni propuesta en el mismo turno. Esto fuerza una separación temporal: primero se resuelve el preflight (en su propio turno), después se ejecuta el meta-comando.

**Implicación** `[INFER]`: el preflight es un estado de sesión cacheado (ver §"Execution Mode" y §"Artifact Store Mode" en CLAUDE.md, que dicen "Cache the mode choice for the session"). Los meta-comandos no re-preguntan; consumen ese cache. El HARD GATE solo dispara la primera vez en la sesión.

## 14.3 — `/sdd-new <change>`: exploración + propuesta `[CERT]`

`/sdd-new` **inicia un cambio nuevo** corriendo exploración y luego creando una propuesta `[CERT]` (frontmatter `sdd-new.md:2`: "Start a new SDD change — runs exploration then creates a proposal").

Workflow declarado `[CERT]` (`sdd-new.md:11-16`):

1. Lanzar el sub-agente **`sdd-explore`** para investigar el codebase para este cambio.
2. Presentar el resumen de exploración al usuario.
3. Lanzar el sub-agente **`sdd-propose`** para crear una propuesta basada en la exploración.
4. Presentar el resumen de la propuesta y preguntar al usuario si quiere continuar con specs y design.

Detalles de contexto que el meta-comando inyecta a los sub-agentes `[CERT]` (`sdd-new.md:18-26`):

- **Working directory**: antes de nada, correr `git rev-parse --show-toplevel 2>/dev/null || pwd` y usar esa ruta como workspace autoritativo. La nota explica el porqué: *"In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project."* `[CERT]` (`sdd-new.md:20`). Es decir, `$ARGUMENTS` y la interpolación de plantilla NO son confiables para el cwd; hay que resolverlo en runtime con bash.
- **Current project**: el `basename` del workspace detectado.
- **Change name**: `$ARGUMENTS`.
- Execution mode, artifact store, delivery strategy y review budget: "ask/cache per orchestrator; do not hardcode Engram" `[CERT]`.

Nota de persistencia `[CERT]` (`sdd-new.md:28-29`): los sub-agentes manejan la persistencia automáticamente según el artifact store elegido. En engram/hybrid, cada fase guarda con `topic_key "sdd/$ARGUMENTS/{type}"`.

**Modelo mental** `[INFER]`: `/sdd-new` cubre el arranque del DAG (`explore → propose`) y se detiene en un punto de decisión humano (paso 4). No avanza a specs/design por su cuenta; deja al usuario decidir si continúa. Es el meta-comando más conservador: dos fases y para.

## 14.4 — `/sdd-continue [change]`: la siguiente fase dependency-ready `[CERT]`

`/sdd-continue` **avanza el cambio activo una fase** en la cadena de dependencias `[CERT]` (frontmatter `sdd-continue.md:2`: "Continue the next SDD phase in the dependency chain").

Workflow declarado `[CERT]` (`sdd-continue.md:11-19`):

1. **Resolver status autoritativo primero**. Si el binario `gentle-ai` está disponible Y el artifact store es `openspec` o `hybrid`, correr `gentle-ai sdd-continue [change] --cwd <repo>` y tratar su salida como autoritativa. Si el store es `engram`, **NO invocar el dispatcher nativo en absoluto** — no puede ver el cambio (lee solo `openspec/changes/`); resolver status desde Engram (`mem_search` + `mem_get_observation` sobre los topic keys). El detalle completo de este ruteo está en [Bloque 15]. `[CERT]`
2. Producir o consumir status estructurado antes de actuar: `schemaName`, `planningHome/changeRoot`, `artifactPaths/contextFiles`, progreso de tareas, estados de dependencias, next recommended action, blocked reasons y `actionContext`. `[CERT]`
3. Chequear qué artefactos ya existen para el cambio activo (proposal, specs, design, tasks). `[CERT]`
4. Determinar la siguiente fase según el grafo: `proposal → [specs ∥ design] → tasks → apply → verify → archive`. `[CERT]` (`sdd-continue.md:17`).
5. Lanzar el/los sub-agente(s) de la siguiente fase **solo si el status autoritativo dice que la dependencia está lista**. Rutear solo por `nextRecommended` y estados de dependencia; nunca inferir desde texto libre. `[CERT]`
6. Presentar el resultado y pedir al usuario que proceda. `[CERT]`

Reglas de ruteo embebidas en el paso 5 `[CERT]` (`sdd-continue.md:18`):

- Si `blockedReasons` no está vacío → no proceder a apply, archive o trabajo terminal.
- Si `nextRecommended` es `verify` → verificación/remediación puede correr solo para refrescar evidencia.
- Si `nextRecommended` es `resolve-blockers` → reportar `blockedReasons` y detenerse.
- Si `nextRecommended` es un token de planificación (`propose`, `spec`, `design`, `tasks`) → lanzar la fase de planificación correspondiente.

Resolución de cambio ambiguo `[CERT]` (`sdd-continue.md:13`): si `$ARGUMENTS` falta y existe más de un cambio activo, **preguntar al usuario y DETENERSE. No adivinar.**

Status contract de cierre `[CERT]` (`sdd-continue.md:37-39`): el meta-comando referencia explícitamente el contrato compartido `~/.config/opencode/skills/_shared/sdd-status-contract.md` (ver [Bloque 15], [Bloque 22]), y advierte no usar una ruta workspace-relativa `skills/_shared/...`. Además: *"Carry `actionContext` and allowed edit roots into any sub-agent launch. If status reports `workspace-planning` with no allowed edit roots, do not launch apply/verify/archive work that would infer repo-local ownership."* `[CERT]`.

**Modelo mental** `[INFER]`: `/sdd-continue` es el motor de avance incremental del DAG. A diferencia de `/sdd-new` (que arranca dos fases fijas) o `/sdd-ff` (que recorre toda la planificación), `/sdd-continue` avanza **exactamente una fase**, la que el status autoritativo declare ready. Es idempotente respecto al estado: si lo corrés dos veces, la segunda lee el status actualizado y avanza la fase siguiente.

## 14.5 — `/sdd-ff <name>`: fast-forward de planificación `[CERT]`

`/sdd-ff` **adelanta TODAS las fases de planificación** — de propuesta hasta tareas `[CERT]` (frontmatter `sdd-ff.md:2`: "Fast-forward all SDD planning phases — proposal through tasks").

Las cuatro fases de planificación que recorre `[CERT]` (`sdd-ff.md:14-19`):

1. **`sdd-propose`** — crear la propuesta.
2. **`sdd-spec`** — escribir las especificaciones.
3. **`sdd-design`** — crear el diseño técnico.
4. **`sdd-tasks`** — descomponer en tareas de implementación.

Comportamiento según modo de ejecución `[CERT]` (`sdd-ff.md:21-22`):

- En modo **`interactive`**: correr SOLO la siguiente fase de planificación, presentar su resumen y ruta(s) de artefacto, preguntar si ajustar o continuar, luego DETENERSE. No lanzar la fase siguiente hasta que el usuario confirme.
- En modo **`auto`**: correr todas las fases de planificación back-to-back y presentar un resumen combinado al final.

El meta-comando honra el execution mode cacheado del Session Preflight `[CERT]` (`sdd-ff.md:12`: "Honor the cached execution mode from SDD Session Preflight").

Persistencia `[CERT]` (`sdd-ff.md:34-35`): en engram/hybrid cada fase guarda con `topic_key "sdd/$ARGUMENTS/{type}"` donde type es: `proposal`, `spec`, `design`, `tasks`.

**Por qué se llama "fast-forward"** `[INFER]`: el término viene del paralelo con un reproductor — `/sdd-ff` "adelanta" la cinta a través de toda la fase de planificación sin parar en cada paso (en modo auto). Cubre el tramo `proposal → specs → design → tasks` del DAG, que es exactamente la planificación completa ANTES de tocar código. Se detiene justo antes de `apply` — nunca implementa. Esto es coherente con la filosofía SDD: planificar completo, después ejecutar.

## 14.6 — Los tres meta-comandos comparados `[CERT]`

Síntesis del recorrido de cada meta-comando sobre el DAG `[CERT]` (cruzando los tres archivos de comando con `CLAUDE.md` §"Dependency Graph"):

| Meta-comando | Tramo del DAG que cubre | Punto de parada | Granularidad |
|--------------|-------------------------|-----------------|--------------|
| `/sdd-new <change>` | `explore → propose` | Tras la propuesta, pregunta si seguir | 2 fases fijas |
| `/sdd-ff <name>` | `propose → spec → design → tasks` | Tras tasks (auto) o tras cada fase (interactive) | Toda la planificación |
| `/sdd-continue [change]` | la siguiente fase ready del DAG completo | Tras una fase, pregunta proceder | 1 fase, dirigida por status |

Observaciones `[INFER]`:

- `/sdd-new` y `/sdd-ff` tienen un **recorrido fijo conocido de antemano** (no consultan status del dispatcher para decidir qué fase sigue; saben su secuencia). `/sdd-continue` es el único **dirigido por status**: pregunta al dispatcher/Engram qué fase corresponde.
- Hay solapamiento intencional en `propose`: `/sdd-new` la corre, `/sdd-ff` también. El uso típico `[INFER]` es elegir uno u otro según cuánto se quiera avanzar de una: `/sdd-new` para arrancar con cautela, `/sdd-ff` para planificar todo de un saque, `/sdd-continue` para avanzar paso a paso desde cualquier estado.
- Ninguno de los tres llega a `apply`/`verify`/`archive` por su recorrido fijo. `/sdd-continue` SÍ puede llegar a esas fases de ejecución, pero solo cuando el status autoritativo lo declare ready y sin `blockedReasons` `[CERT]` (`sdd-continue.md:18`).

## 14.7 — Conexiones

- **[Bloque 5] a [Bloque 9] — Fases de planificación**: los meta-comandos NO ejecutan trabajo; delegan a estas fases. `/sdd-new` convoca `sdd-explore` ([Bloque 5]) y `sdd-propose` ([Bloque 6]). `/sdd-ff` convoca `sdd-propose` ([Bloque 6]), `sdd-spec` ([Bloque 7]), `sdd-design` ([Bloque 8]) y `sdd-tasks` ([Bloque 9]). El detalle de qué produce cada fase está en esos bloques.
- **[Bloque 10] a [Bloque 12] — Fases de ejecución**: `/sdd-continue` puede llegar a `sdd-apply` ([Bloque 10]), `sdd-verify` ([Bloque 11]) y `sdd-archive` ([Bloque 12]) cuando el status las declare ready.
- **[Bloque 15] — status + dispatcher nativo**: el paso 1 de `/sdd-continue` (y todo su ruteo por `nextRecommended`/`blockedReasons`) depende del contrato de status y del dispatcher `gentle-ai`, que [Bloque 15] documenta en detalle, incluida la ceguera del dispatcher ante backend engram.
- **[Bloque 16] — modos de ejecución + Gatekeeper**: el comportamiento auto vs. interactive que `/sdd-ff` describe en §14.5, y el Session Preflight del HARD GATE (§14.2), se elaboran en [Bloque 16].
- **[Bloque 17] — delivery/chain strategy**: dos de los cuatro elementos del Session Preflight (chained PR strategy, review budget) se detallan en [Bloque 17].
- **[Bloque 18] — delegación + triggers + models**: el "Do NOT execute phase work inline — delegate to sub-agents" que cierra los tres meta-comandos es la materialización del modelo de delegación que [Bloque 18] formaliza, incluido el model gate por fase.
