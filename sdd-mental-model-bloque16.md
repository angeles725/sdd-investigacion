# Bloque 16 — Modos de ejecución (auto/interactive) y el Gatekeeper

> **QUÉ DOCUMENTA**: Este bloque documenta los dos modos de ejecución del pipeline SDD — `auto` e `interactive` — y el **Gatekeeper** del modo automático: el validador autónomo que el orquestador corre entre fases para asegurar que cada fase alcanzó su objetivo antes de lanzar la siguiente.
> **ALCANCE**: La diferencia auto vs. interactive, cuándo se pregunta el modo, la ronda de preguntas de propuesta en modo interactive, los cinco chequeos del Gatekeeper (contract conformance, artifact existence, no hallucination, no drift, routing coherence), el mecanismo híbrido inline vs. reviewer fresco, y el flujo PASS/FAIL con re-run único. NO cubre el Review Workload Guard (ver [Bloque 17]) ni el detalle del Result Contract (ver [Bloque 2]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Execution Mode", §"Automatic Mode Gatekeeper (MANDATORY)", §"Artifact Store Mode", §"Result Contract"
> - `/home/cristian/.config/opencode/commands/sdd-ff.md` (líneas 21-22) — comportamiento auto/interactive
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta §sección`. `[CERT-a]` = afirmado por fuente, no re-verificado. `[INFER]` = deducción propia.

---

## 16.1 — Los dos modos de ejecución `[CERT]`

Cuando el usuario invoca `/sdd-new`, `/sdd-ff` o `/sdd-continue` (o un pedido en lenguaje natural equivalente, ej. "haceme un SDD para X") por primera vez en la sesión, el orquestador PREGUNTA qué modo de ejecución prefiere `[CERT]` (`CLAUDE.md` §"Execution Mode"):

| Modo | Comportamiento `[CERT]` (`CLAUDE.md` §"Execution Mode") |
|------|--------------------------------------------------------|
| **Automatic** (`auto`) | Corre todas las fases back-to-back SIN pausar. Pero el orquestador corre un **Gatekeeper de validación tras cada fase** antes de lanzar la siguiente. El usuario solo ve interrupción cuando el Gatekeeper detecta un problema real. Para velocidad cuando se confía en el proceso. |
| **Interactive** (`interactive`) | Tras cada fase, muestra el resumen y PREGUNTA: "¿Querés ajustar algo o continuar?" antes de proceder. Para cuando se quiere revisar y dirigir cada paso. |

Default `[CERT]` (`CLAUDE.md` §"Execution Mode"): *"If the user doesn't specify, default to **Interactive** (safer, gives the user control)."* El modo se cachea para la sesión; no se vuelve a preguntar salvo que el usuario pida cambiarlo explícitamente.

Aclaración clave `[CERT]`: **auto NO significa "sin validación"**. Significa "sin interrupción al usuario en el camino feliz". El Gatekeeper SIEMPRE corre en auto; lo que cambia es que sus resultados solo llegan al usuario cuando hay un problema. La fuente lo dice: *"Phases still run back-to-back WITHOUT interrupting the user, BUT the orchestrator runs a gatekeeper validation after every phase before launching the next sub-agent — the user only sees an interruption when the gatekeeper catches a real problem."* `[CERT]` (`CLAUDE.md` §"Execution Mode").

## 16.2 — Modo interactive: pausas entre fases `[CERT]`

En modo interactive, entre fases el orquestador `[CERT]` (`CLAUDE.md` §"Execution Mode"):

1. Muestra un resumen conciso de lo que produjo la fase.
2. Lista lo que hará la siguiente fase.
3. Pregunta: "¿Continuamos? / Continue?" — acepta YES/continue, NO/stop, o feedback específico para ajustar.
4. Si el usuario da feedback, lo incorpora ANTES de correr la siguiente fase.

Esto coincide exactamente con el comportamiento de `/sdd-ff` en interactive `[CERT]` (`sdd-ff.md:21`): *"run only the next planning phase, present its summary and artifact path(s), ask whether to adjust or continue, then STOP. Do not launch the following phase until the user confirms."*

Regla de alcance de aprobación `[CERT]` (`CLAUDE.md` §"Execution Mode"): la aprobación interactiva es **phase-scoped**. Palabras como "continue", "dale" o "go on" aprueban SOLO la siguiente fase inmediata, no el resto del pipeline SDD. Un artefacto generado NO se considera aprobado hasta que el usuario tuvo chance de revisarlo o delegó explícitamente esa revisión.

**Modelo mental** `[INFER]`: la aprobación interactiva no es transitiva. Aprobar la fase N no autoriza N+1, N+2... Esto previene que un "sí" casual al inicio se interprete como mandato para correr todo el pipeline sin supervisión. Cada fase es un consentimiento nuevo.

## 16.3 — Ronda de preguntas de propuesta (interactive) `[CERT]`

Antes de la fase `sdd-propose` en modo interactive, el orquestador ofrece una **ronda de preguntas de propuesta** en lugar de decidir silenciosamente si la propuesta está clara `[CERT]` (`CLAUDE.md` §"Execution Mode"):

- Las preguntas buscan mejorar el PRD/propuesta descubriendo: entendimiento del negocio, reglas de negocio, implicaciones, impacto, edge cases, y tradeoffs de producto.
- Preferir **3-5 preguntas de producto concretas por ronda**, luego resumir los supuestos resultantes y preguntar si el usuario quiere corregir algo o correr una segunda ronda.
- Cubrir decisiones de negocio/producto/PRD: problema de negocio, usuarios objetivo y situaciones, reglas de negocio, outcome de producto, gap del estado actual, implicaciones e impacto, edge cases, gaps de decisión, límites de scope del primer slice, non-goals, constraints de producto, y tradeoffs de negocio.

Lo que NO se pregunta en tiempo de propuesta `[CERT]`: *"Do not ask about test commands, PR shape, changed-line budget, or other harness mechanics at proposal time unless the user explicitly asks to discuss delivery."* `[CERT]` (`CLAUDE.md` §"Execution Mode").

**Por qué** `[INFER]`: la ronda de preguntas separa el dominio de **producto/negocio** (qué se construye y por qué) del dominio de **delivery/harness** (cómo se entrega: PRs, budget de líneas, comandos de test). En la propuesta solo se discute lo primero. Las mecánicas de entrega se resuelven más adelante, en el Review Workload Guard (ver [Bloque 17]).

## 16.4 — El Gatekeeper: validador autónomo entre fases `[CERT]`

En modo automático el orquestador ES el gatekeeper entre fases `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"). Corre **después de cada fase**: cuando una fase delegada retorna y ANTES de lanzar el siguiente sub-agente, el orquestador DEBE validar que la fase alcanzó su objetivo con todo en orden.

Distinción crítica `[CERT]`: el Gatekeeper es **validación autónoma — NO le pregunta al usuario** (eso es el modo interactive). Solo aflora al usuario cuando detecta un problema. *"This is autonomous validation — it does NOT ask the user (that is Interactive mode); it only surfaces to the user when it catches a problem."* `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

**Modelo mental** `[INFER]`: el Gatekeeper es el equivalente automático del checkpoint humano del modo interactive. En interactive, el HUMANO valida cada fase. En auto, el ORQUESTADOR valida cada fase con criterios objetivos. Por eso auto no es "modo ciego": es "modo con un revisor autónomo en lugar del humano".

## 16.5 — Los cinco chequeos del Gatekeeper `[CERT]`

El Gatekeeper chequea cada fase contra el Result Contract `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"). Los cinco chequeos:

| # | Chequeo | Qué verifica `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper") |
|---|---------|------------------------------------------------------------------|
| 1 | **Contract conformance** | La fase devolvió `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks` y `skill_resolution`, y `status` indica éxito (no partial, failed ni blocked). |
| 2 | **Artifact existence** | El artefacto declarado existe y es legible en el backend activo — se LEE de vuelta (engram: `mem_search` + `mem_get_observation` sobre el topic key; openspec: leer la ruta del archivo). Una fase que reporta éxito pero no produjo artefacto recuperable FALLA. |
| 3 | **No hallucination** | Toda ruta de archivo, símbolo, comando o artefacto que la fase dice haber creado o referenciado DEBE existir realmente; se spot-checkean las afirmaciones concretas. Una ruta referenciada que no resuelve FALLA. |
| 4 | **No drift from inputs** | La salida es consistente con los inputs requeridos de la fase según el Dependency Graph — spec dentro del scope de la propuesta, design responde a la propuesta, tasks cubren spec y design, apply implementa las tasks. Requisitos inventados, scope creep o requisitos dropeados FALLAN. |
| 5 | **Routing coherence** | `next_recommended` sigue el Dependency Graph y `risks` están dentro de tolerancia (sin CRITICAL no atendido). |

**Lectura del conjunto** `[INFER]`: los cinco chequeos forman una jerarquía de confianza creciente. (1) ¿la fase respondió en el formato esperado? (2) ¿el artefacto que dice haber hecho existe de verdad? (3) ¿lo que cita dentro del artefacto existe? (4) ¿es coherente con lo que recibió? (5) ¿hacia dónde apunta es correcto? Es un embudo: primero la forma, después la sustancia, después la coherencia, después el ruteo. El más sutil es el #4 (drift): captura el fallo más peligroso de los LLMs, inventar o perder requisitos silenciosamente.

## 16.6 — Mecanismo híbrido: inline vs. reviewer fresco `[CERT]`

El Gatekeeper usa un mecanismo de validación **consciente del costo** `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"):

| Tipo de fase | Mecanismo de validación `[CERT]` |
|--------------|----------------------------------|
| **Bajo riesgo** (`sdd-explore`, `sdd-spec`, `sdd-tasks`, `sdd-archive`) | **Inline**: el orquestador corre los chequeos él mismo leyendo el artefacto de vuelta. Sin sub-agente extra. |
| **Alto riesgo** (`sdd-design`, `sdd-apply`) | **Reviewer de contexto fresco**: delegar un sub-agente reviewer fresco para juicio independiente, porque los errores en estas fases compounden downstream. Usar el alias de modelo `sdd-verify` para el gate review, con `model` per el mandatory model gate. |

Escalada por "smell" `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"): si un chequeo inline en una fase de bajo riesgo encuentra cualquier olor (status mismatch, ruta sin resolver, drift sospechado, artefacto faltante), se ESCALA esa fase a un review delegado de contexto fresco antes de decidir.

**Por qué design y apply son alto riesgo** `[INFER]`: son las dos fases donde una decisión equivocada **se propaga**. Un design errado contamina todas las tasks y la implementación. Un apply errado mete bugs en el código. Las fases de bajo riesgo (explore, spec, tasks, archive) producen artefactos más mecánicos o reversibles, donde un error es más local y barato de detectar inline. La asimetría de costo justifica gastar un sub-agente fresco solo en design/apply. Esto enlaza con la regla de trigger de agentes: `judgment-day` se recomienda fuerte tras design o apply (ver [Bloque 24]).

## 16.7 — Flujo PASS/FAIL y el re-run único `[CERT]`

El resultado del Gatekeeper dispara dos caminos `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"):

**On gate PASS**: continuar automáticamente a la siguiente fase. *"Auto stays auto on the happy path."* `[CERT]`

**On gate FAIL** `[CERT]`:

1. **Re-correr la misma fase EXACTAMENTE una vez** con feedback correctivo que nombra las fallas específicas que el gatekeeper encontró (no un blanket-retry).
2. Re-correr el gate sobre el nuevo resultado.
3. Si pasa → continuar la cadena.
4. Si falla de nuevo → **DETENER la cadena automática** y aflorar un reporte al usuario nombrando la fase, qué detectó el gatekeeper, ambos intentos, y el fix recomendado.

Regla de no-avance `[CERT]`: *"Do not advance to dependent phases on a failed gate — a bad artifact compounds downstream."* `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

**Modelo mental del re-run único** `[INFER]`: el sistema da exactamente UNA segunda oportunidad con feedback dirigido, no reintentos infinitos. La lógica es: si una fase falla y un re-run con feedback específico tampoco lo arregla, el problema probablemente excede lo que el reintento automático puede resolver — necesita un humano. El "exactamente una vez" evita loops de gasto de tokens y fuerza escalada temprana al usuario.

Convivencia con otros guards `[CERT]`: el Gatekeeper corre EN ADICIÓN al Review Workload Guard y a los Mandatory Delegation Triggers; nunca los relaja y nunca auto-marca nada como reviewed en engram `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

## 16.8 — Artifact Store Mode: la otra pregunta del primer turno `[CERT]`

Junto con el execution mode, en el primer `/sdd-new`/`/sdd-ff`/`/sdd-continue` de la sesión el orquestador TAMBIÉN pregunta qué artifact store usar `[CERT]` (`CLAUDE.md` §"Artifact Store Mode"):

| Store | Característica `[CERT]` (`CLAUDE.md` §"Artifact Store Mode") |
|-------|------------------------------------------------------------|
| `engram` | Rápido, sin archivos. Artefactos solo en engram. Mejor para solo y iteración rápida. Re-correr una fase sobrescribe la versión previa (sin historia). |
| `openspec` | Basado en archivos. Crea `openspec/` con trail completo. Committeable, compartible, con historia git. |
| `hybrid` | Ambos — archivos para equipo + engram para recuperación cross-session. Mayor costo de tokens. |

Default `[CERT]`: si el usuario no especifica, detectar — si engram está disponible → `engram`; si no → `none`. El store se cachea y se pasa como `artifact_store.mode` a cada lanzamiento de sub-agente `[CERT]`.

**Conexión con el Gatekeeper** `[INFER]`: el chequeo #2 (artifact existence) del Gatekeeper depende de este modo — lee de vuelta vía `mem_get_observation` si es engram, o lee el archivo si es openspec. El store elegido aquí determina CÓMO el Gatekeeper verifica que el artefacto existe.

## 16.9 — Conexiones

- **[Bloque 2] — DAG + Result Contract**: los cinco campos que el Gatekeeper exige (chequeo #1) son exactamente el Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) que [Bloque 2] define. El chequeo #4 (no drift) se valida contra el Dependency Graph de [Bloque 2].
- **[Bloque 8] — sdd-design** y **[Bloque 10] — sdd-apply**: son las dos fases de ALTO RIESGO que el Gatekeeper valida con reviewer fresco (§16.6), porque sus errores compounden downstream.
- **[Bloque 24] — judgment-day**: la regla de trigger recomienda fuerte correr `judgment-day` tras las fases design o apply — el mismo umbral de alto riesgo que usa el Gatekeeper. Ambos mecanismos refuerzan el mismo punto del pipeline.
- **[Bloque 17] — delivery/chain strategy**: el Gatekeeper corre EN ADICIÓN al Review Workload Guard (§16.7), que [Bloque 17] documenta. El Artifact Store Mode (§16.8) y el execution mode son dos de los cuatro elementos del Session Preflight; los otros dos (chain strategy, review budget) están en [Bloque 17].
- **[Bloque 18] — delegación + models**: el reviewer fresco del Gatekeeper usa el alias de modelo `sdd-verify` con el mandatory model gate (§16.6), que [Bloque 18] formaliza en la tabla de Model Assignments.
- **[Bloque 14] — meta-comandos**: el execution mode y artifact store que aquí se preguntan son dos de los cuatro elementos del HARD GATE de Session Preflight que [Bloque 14] describe para los tres meta-comandos.
