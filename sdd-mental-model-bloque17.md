# Bloque 17 — Delivery strategy, chain strategy y chained PRs

> **QUÉ DOCUMENTA**: Este bloque documenta cómo el SDD decide la **forma de entrega** de una implementación: la `delivery_strategy` (ask-on-risk / auto-chain / single-pr / exception-ok), la `chain_strategy` (stacked-to-main / feature-branch-chain), el **Review Workload Guard** que se dispara entre `sdd-tasks` y `sdd-apply`, el presupuesto de 400 líneas cambiadas, y la skill `chained-pr` que se carga obligatoriamente cuando hay PRs encadenados.
> **ALCANCE**: Las cuatro delivery strategies, las dos chain strategies, el forecast de Review Workload, las condiciones de disparo del guard, y la resolución de la skill `chained-pr` por registry. NO cubre el desglose de tasks en sí (ver [Bloque 9]) ni la implementación de apply (ver [Bloque 10]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Delivery Strategy", §"Chain Strategy", §"Review Workload Guard (MANDATORY)", §"Agent Trigger Rules"
> - `/home/cristian/.config/opencode/commands/sdd-new.md`, `sdd-ff.md`, `sdd-continue.md` (Session Preflight: review budget, chained PR strategy)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta §sección`. `[CERT-a]` = afirmado por fuente, no re-verificado. `[INFER]` = deducción propia.

---

## 17.1 — `delivery_strategy`: cuándo y cómo entregar `[CERT]`

En el primer `/sdd-new`, `/sdd-ff` o `/sdd-continue` de la sesión, el orquestador pregunta UNA vez y cachea la `delivery_strategy` `[CERT]` (`CLAUDE.md` §"Delivery Strategy"). Se pasa como `delivery_strategy` a los prompts de `sdd-tasks` y `sdd-apply`.

Las cuatro estrategias `[CERT]` (`CLAUDE.md` §"Delivery Strategy"):

| Estrategia | Comportamiento `[CERT]` |
|-----------|--------------------------|
| **`ask-on-risk`** (default) | Pregunta al usuario solo cuando el riesgo de workload lo amerita (ver §17.4). |
| **`auto-chain`** | No pregunta sobre splitting; encadena automáticamente PRs cuando hace falta. |
| **`single-pr`** | Fuerza un único PR; requiere registrar `size:exception` si excede el budget. |
| **`exception-ok`** | Continúa con `size:exception` aceptado de antemano. |

Default explícito `[CERT]`: `ask-on-risk` es el default. *"On the first `/sdd-new`, `/sdd-ff`, or `/sdd-continue` ... in a session, ask once for and cache delivery strategy: `ask-on-risk` (default), `auto-chain`, `single-pr`, or `exception-ok`."* `[CERT]` (`CLAUDE.md` §"Delivery Strategy").

**Modelo mental** `[INFER]`: la delivery strategy es una **política de pre-autorización** sobre qué hacer cuando un cambio resulta grande. `ask-on-risk` deja la decisión al humano en el momento; `auto-chain` la pre-autoriza hacia splitting; `single-pr` y `exception-ok` la pre-autorizan hacia un PR grande con excepción registrada. Es el cache que evita re-preguntar lo mismo en cada apply.

## 17.2 — `chain_strategy`: cómo se encadenan los PRs `[CERT]`

Cuando la `delivery_strategy` resulta en PRs encadenados (por elección del usuario vía `ask-on-risk` o automáticamente vía `auto-chain`), el orquestador pregunta qué **chain strategy** usar `[CERT]` (`CLAUDE.md` §"Chain Strategy"):

| Chain strategy | Estructura `[CERT]` (`CLAUDE.md` §"Chain Strategy") |
|----------------|-----------------------------------------------------|
| **`stacked-to-main`** | Cada PR mergea a main en orden. Iteración rápida, fix sobre la marcha. Mejor para equipos speed-first y slices independientes. |
| **`feature-branch-chain`** | La branch feature/tracker acumula la integración final; PR #1 apunta a la tracker branch, los PRs hijos posteriores apuntan a la branch del PR anterior inmediato para mantener los diffs de review enfocados. Solo el tracker mergea a main. Mejor para control de rollback y releases coordinados. |

La chain strategy se cachea para la sesión y se pasa como `chain_strategy` a `sdd-tasks` y `sdd-apply` junto con `delivery_strategy` `[CERT]`. No se vuelve a preguntar salvo que el usuario cambie el scope `[CERT]` (`CLAUDE.md` §"Chain Strategy").

**Diferencia de fondo** `[INFER]`: `stacked-to-main` optimiza VELOCIDAD — cada slice llega a main apenas está listo, asumiendo slices independientes. `feature-branch-chain` optimiza CONTROL — nada toca main hasta que el tracker integra todo, permitiendo rollback de la feature completa como unidad. Es el clásico tradeoff entre integración continua agresiva y release coordinado. La estructura de targets de PR (cada hijo apunta al anterior) es lo que mantiene los diffs de review chicos en feature-branch-chain.

## 17.3 — El Review Workload Forecast `[CERT]`

Tras completar `sdd-tasks` y ANTES de lanzar `sdd-apply`, el orquestador inspecciona el **Review Workload Forecast** `[CERT]` (`CLAUDE.md` §"Review Workload Guard"). Este forecast es producido por la fase `sdd-tasks` y contiene señales que predicen cuánto review demandará la implementación.

Las señales que dispara el guard `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

- `Chained PRs recommended: Yes`
- `400-line budget risk: High`
- líneas cambiadas estimadas exceden 400
- `Decision needed before apply: Yes`

Si CUALQUIERA de estas señales está presente, se aplica la `delivery_strategy` cacheada (ver §17.4).

**Por qué entre tasks y apply** `[INFER]`: es el último punto donde se puede decidir la forma de entrega ANTES de escribir código. `sdd-tasks` ya descompuso el trabajo y puede estimar tamaño; `sdd-apply` todavía no empezó. Decidir el splitting acá evita el escenario peor: implementar todo en un PR gigante y descubrir recién en review que era inrevisable. El forecast es una predicción temprana del costo de review.

## 17.4 — El Review Workload Guard: resolución por delivery_strategy `[CERT]`

Cuando el forecast dispara, el guard resuelve según la `delivery_strategy` cacheada `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

| delivery_strategy | Acción del guard `[CERT]` |
|-------------------|----------------------------|
| **`ask-on-risk`** | DETENERSE y preguntar si splitear en PRs chained/stacked o proceder con `size:exception`. Si elige chained PRs y `chain_strategy` no está cacheada, también preguntar cuál chain strategy. |
| **`auto-chain`** | No preguntar sobre splitting. Si `chain_strategy` no está cacheada, preguntar cuál usar. Luego pasar a `sdd-apply`: implementar solo el siguiente slice autónomo con work-unit commits, con start/finish/verification/rollback boundary claros. |
| **`single-pr`** | DETENERSE y requerir/registrar `size:exception` antes de apply. |
| **`exception-ok`** | Continuar, pero decirle a `sdd-apply` que esta corrida usa `size:exception`. |

Reglas duras del guard `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

- *"Automatic mode does not override this guard."* — el modo auto NO saltea este guard. Siempre se pasa la delivery strategy resuelta a `sdd-apply`.
- Al lanzar `sdd-apply`, SIEMPRE incluir la `delivery_strategy` resuelta, la `chain_strategy`, y cualquier boundary/excepción de PR elegido.

**Modelo mental del guard** `[INFER]`: es un **checkpoint de tamaño** obligatorio entre planificación y ejecución. El Gatekeeper de modo auto valida CALIDAD de cada fase; el Review Workload Guard valida TAMAÑO de entrega. Son ortogonales: el Gatekeeper puede pasar (la tasks está bien hecha) pero el guard puede disparar (las tasks describen 600 líneas de cambio). Y el modo auto, que silencia al Gatekeeper en el camino feliz, NO silencia este guard — porque la decisión de splitting puede requerir input humano que ninguna validación autónoma reemplaza (salvo en `auto-chain`, que la pre-autorizó).

## 17.5 — El presupuesto de 400 líneas `[CERT]`

El número **400 líneas cambiadas** es el umbral central del sistema de review `[CERT]`. Aparece en dos lugares:

1. **Review Workload Guard** `[CERT]` (`CLAUDE.md` §"Review Workload Guard"): el forecast marca `400-line budget risk: High` o `estimated changed lines exceed 400` como disparador.
2. **Agent Trigger Rules** `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"): en pre-pr, cuando el diff toca rutas sensibles (`**/auth/**`, `**/update/**`, `**/security/**`, `**/payments/**`) O cuando el diff **excede 400 líneas cambiadas**, se recomienda FUERTE correr el fan-out 4R completo (`review-risk`, `review-resilience`, `review-readability`, `review-reliability`) en paralelo.

La lógica del trigger 4R `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"): *"full 4R fan-out (~4x) only on hot paths (auth/update/security/payments) or diffs exceeding 400 changed lines"*. Para eventos cotidianos (pre-commit, pre-push) solo se considera UN lens barato (`review-readability`, ~1x); el fan-out 4R completo se reserva para pre-pr en hot paths o diffs grandes.

**Por qué 400** `[INFER]`: 400 líneas es un umbral de revisabilidad humana ampliamente usado en la industria — por encima, la calidad de review cae porque el revisor no puede sostener el cambio completo en la cabeza. El SDD lo usa como frontera dual: por debajo, un PR simple con review liviano; por encima, o splitteás (Review Workload Guard) o pagás review adversarial 4R completo (Agent Trigger Rules). El número conecta el dominio de **tamaño de entrega** con el dominio de **intensidad de review**.

## 17.6 — La skill `chained-pr` `[CERT]`

Cuando la planificación de delivery resulta en PRs encadenados, el SDD trata `chained-pr` (skill de registry `gentle-ai-chained-pr`) como un **match de skill requerido** `[CERT]` (`CLAUDE.md` §"Chain Strategy"):

- Se resuelve por nombre de registry a través del mecanismo de skill-resolution existente del template (el mismo que ya usa para pasar skills a las fases).
- Se asegura que las fases `sdd-tasks` y `sdd-apply` CARGUEN y SIGAN esa skill ANTES de planificar o crear cualquier PR.
- *"Do not hardcode the skill path; defer resolution to that mechanism."* `[CERT]` (`CLAUDE.md` §"Chain Strategy").

La descripción de la skill `chained-pr` (del registro de skills disponibles) `[CERT-a]`: *"Trigger: PRs over 400 lines, stacked PRs, review slices. Split oversized changes into chained PRs that protect review focus."*

**Modelo mental** `[INFER]`: `chained-pr` es el "manual de procedimiento" para ejecutar el splitting que el Review Workload Guard decidió. El guard DECIDE que hay que encadenar; la skill `chained-pr` enseña CÓMO hacerlo bien (cómo armar los slices, cómo apuntar los targets de PR, cómo proteger el foco de review). Que se resuelva por registry (y no por ruta hardcodeada) es coherente con el Skill Resolver Protocol (ver [Bloque 18], [Bloque 22]): el orquestador resuelve la ruta una vez y la inyecta en el prompt del sub-agente.

## 17.7 — Cómo encaja en el Session Preflight `[CERT]`

Dos de los cuatro elementos del HARD GATE de Session Preflight (ver [Bloque 14]) corresponden a este bloque `[CERT]` (`sdd-new.md:9`, `sdd-ff.md:9`, `sdd-continue.md:9`):

- **chained PR strategy** → la `chain_strategy` de §17.2.
- **review budget** → la `delivery_strategy` y el presupuesto de líneas de §17.1 y §17.5.

Esto significa que la forma de entrega NO se improvisa en apply: se resuelve al inicio de la sesión (en el preflight) y se cachea. El Review Workload Guard (§17.4) luego CONSUME ese cache cuando el forecast dispara, en lugar de preguntar de cero.

**Secuencia temporal completa** `[INFER]`:

1. **Session Preflight** (primer meta-comando): se pregunta y cachea `delivery_strategy` + `chain_strategy`.
2. **`sdd-tasks`**: produce el Review Workload Forecast con las señales de tamaño.
3. **Review Workload Guard** (entre tasks y apply): inspecciona el forecast; si dispara, aplica el `delivery_strategy` cacheado.
4. **`sdd-apply`**: recibe `delivery_strategy` + `chain_strategy` + boundary/excepción; si hay chaining, carga la skill `chained-pr` y ejecuta los slices con work-unit commits.

## 17.8 — Conexiones

- **[Bloque 9] — sdd-tasks**: es la fase que PRODUCE el Review Workload Forecast (§17.3) que el guard inspecciona. Las señales de tamaño (`400-line budget risk`, `estimated changed lines`, `Chained PRs recommended`) son output de [Bloque 9].
- **[Bloque 10] — sdd-apply**: es la fase que CONSUME `delivery_strategy` y `chain_strategy`, carga la skill `chained-pr`, y ejecuta los slices con work-unit commits. El boundary de PR (start/finish/verification/rollback) se materializa allí.
- **[Bloque 14] — meta-comandos**: el Session Preflight de los tres meta-comandos incluye chained PR strategy y review budget (§17.7) — exactamente la `chain_strategy` y `delivery_strategy` de este bloque.
- **[Bloque 16] — modos + Gatekeeper**: el Review Workload Guard corre EN ADICIÓN al Gatekeeper y el modo auto NO lo overridea (§17.4). Son guards ortogonales: calidad vs. tamaño.
- **[Bloque 18] — delegación + skill resolution**: la skill `chained-pr` se resuelve vía el Skill Resolver Protocol que [Bloque 18] formaliza; las fases reciben la ruta inyectada, no la hardcodean.
- **[Bloque 22] — skill-resolver**: el mecanismo "defer resolution to that mechanism" para `chained-pr` es el Skill Resolver Protocol de los contratos `_shared/`.
