# Bloque 11 — Fase `sdd-verify` (+ report format)

> **QUÉ**: Documenta la fase `sdd-verify` del sistema SDD de gentle-ai: el quality gate. Prueba que la implementación coincide con specs, design y tasks mediante inspección de fuente MÁS evidencia de ejecución real (tests). Clasifica issues en CRITICAL / WARNING / SUGGESTION y emite un veredicto PASS / PASS WITH WARNINGS / FAIL.
>
> **ALCANCE**: Propósito, contrato de activación, Hard Rules, Decision Gates, qué lee/escribe (artefacto + topic key), niveles de severidad, compliance statuses, formato del report (template completo), manejo gracioso de artefactos faltantes, modelo asignado, Result Contract y gotchas. NO cubre el módulo `strict-tdd-verify.md` (eso es [Bloque 23]); solo se menciona su carga.
>
> **FUENTES exactas**:
> - `/home/cristian/.config/opencode/skills/sdd-verify/SKILL.md` (primaria, v3.0)
> - `/home/cristian/.config/opencode/skills/sdd-verify/references/report-format.md` (template + compliance statuses)
> - `/home/cristian/.claude/agents/sdd-verify.md` (tools, modelo, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-verify.md` (versión CONDENSADA — diverge del SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-verify.md` (gates del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
> - NOTA: `sdd-verify/strict-tdd-verify.md` se documenta en [Bloque 23], NO aquí.
>
> **MÉTODO**: lectura directa. Marcadores: `[CERT]` = verificado (`ruta:línea`); `[CERT-a]` = afirmado por fuente; `[INFER]` = deducción.

---

## 11.1 — Propósito y rol `[CERT]`

`sdd-verify` corre cuando el orquestador lanza la verificación de un cambio SDD. Es el **quality gate**: prueba la completitud con inspección de fuente MÁS evidencia de ejecución real (`skills/sdd-verify/SKILL.md:31-33`). Su filosofía central (`SKILL.md:42`): "Execute relevant tests; static analysis alone is never verification" — un escenario de spec es compliant solo cuando un test que lo cubre pasó en runtime.

NO arregla issues: los reporta para el orquestador/usuario (`SKILL.md:43`). Mismo patrón gate/override que el resto (`SKILL.md:13-21`). Versión `3.0`.

## 11.2 — Activation Contract y Hard Rules `[CERT]`

El orquestador debe proveer structured status de `_shared/sdd-status-contract.md` ([Bloque 22]): `schemaName`, `planningHome`, `changeRoot`, `artifactPaths`, `contextFiles`, task progress, dependency states, `actionContext` (`SKILL.md:31-35`).

Hard Rules (`SKILL.md:37-46`):

- Leer TODOS los `contextFiles` disponibles antes de juzgar. Verificación full spec-driven lee proposal, specs, design y tasks; sets parciales degradan (ver 11.7).
- Ejecutar tests relevantes; análisis estático solo NUNCA es verificación.
- Un escenario de spec es compliant solo cuando un test que lo cubre pasó en runtime.
- Comparar specs primero, design segundo, completitud de tasks tercero (`SKILL.md:42`).
- NO arreglar; reportar.
- Persistir `verify-report` según el modo.
- Si Strict TDD activo, cargar `strict-tdd-verify.md` ([Bloque 23]); si inactivo, nunca cargarlo (`SKILL.md:45`).

## 11.3 — Qué LEE y qué ESCRIBE `[CERT]`

El SKILL.md delega retrieval a la Sección B del common; el agente concreta (`agents/sdd-verify.md:18-26`): lee `sdd/{change}/spec` (requerido), `sdd/{change}/tasks` (requerido), `sdd/{change}/apply-progress` (requerido), todos vía `mem_search → mem_get_observation`.

**Artefacto producido**: `verify-report` · **topic key**: `sdd/{change-name}/verify-report` · **type**: `architecture` (`agents/sdd-verify.md:29-34`, [Bloque 3]). Persiste según modo: Engram, archivo openspec, hybrid (ambos), o inline-only para `none` (`SKILL.md:44`).

> [CERT] Importante: el agente verify NO tiene tools de escritura de archivos del proyecto. `agents/sdd-verify.md:7`: tools = `Read, Grep, Glob, Bash, mem_search, mem_get_observation, mem_save`. Sin `Edit`/`Write` (no muta código) ni `mem_update` (no marca tasks). Solo `Bash` para ejecutar tests y `mem_save` para el report.

## 11.4 — Niveles de severidad CRITICAL / WARNING / SUGGESTION `[CERT]`

Los issues se agrupan en tres niveles (`SKILL.md:78`, `references/report-format.md:57-60`). Las Decision Gates definen qué dispara cada uno (`SKILL.md:48-63`):

| Condición | Nivel |
|-----------|-------|
| Tarea core incompleta | **CRITICAL** |
| Tarea de cleanup incompleta | **WARNING** |
| Test command exits non-zero | **CRITICAL** |
| Escenario de spec sin test que pase | **CRITICAL** (`UNTESTED` o `FAILING`) |
| Deviación de design existe | **WARNING** (a menos que rompa una spec → CRITICAL) |

> [CERT] "Any unchecked implementation task is CRITICAL and blocks archive readiness" (`SKILL.md:69`). "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:85`). Esto enlaza con la Task Completion Gate de `sdd-archive` ([Bloque 12]).

SUGGESTION es el nivel no bloqueante (mejoras opcionales); aparece en el report pero no afecta el veredicto bloqueante.

### Veredicto final `[CERT]`

`SKILL.md:78` + `references/report-format.md:62-64`: `PASS`, `PASS WITH WARNINGS`, o `FAIL`. Un CRITICAL fuerza `FAIL`; solo WARNINGs → `PASS WITH WARNINGS`; limpio → `PASS`. [INFER] El veredicto deriva mecánicamente de los niveles: presencia de cualquier CRITICAL ⇒ FAIL.

## 11.5 — Compliance Statuses (matriz de spec) `[CERT]`

`references/report-format.md:3-9`. Cada escenario de spec recibe un status en la Spec Compliance Matrix:

| Status | Significado |
|--------|-------------|
| ✅ `COMPLIANT` | test que lo cubre existe y pasó |
| ❌ `FAILING` | test que lo cubre existe pero falló |
| ❌ `UNTESTED` | no se encontró test que lo cubra |
| ⚠️ `PARTIAL` | test pasa pero cubre solo parte del escenario |

La matriz se construye desde resultados de test REALES cuando existen specs/scenarios (`SKILL.md:72-78`). `FAILING` y `UNTESTED` para escenarios requeridos son CRITICAL.

## 11.6 — Formato del report `[CERT]`

`references/report-format.md:10-65`. El template completo (`## Verification Report`):

```markdown
## Verification Report
**Change**: {change-name}
**Version**: {spec version o N/A}
**Mode**: {Strict TDD | Standard}

### Completeness        → tabla: Tasks total / complete / incomplete
### Build & Tests Execution
   **Build**: ✅ Passed / ❌ Failed  (+ comando y output)
   **Tests**: ✅ N passed / ❌ N failed / ⚠️ N skipped
   **Coverage**: N% / threshold N% → ✅ Above / ⚠️ Below / ➖ Not available
### Spec Compliance Matrix   → Requirement | Scenario | Test | Result
   **Compliance summary**: N/total scenarios compliant
### Correctness (Static Evidence)  → Requirement | Status | Notes
### Coherence (Design)             → Decision | Followed? | Notes
### Issues Found
   **CRITICAL**: {list o None}
   **WARNING**: {list o None}
   **SUGGESTION**: {list o None}
### Verdict
   {PASS / PASS WITH WARNINGS / FAIL} + razón en una línea
```

El Output Contract del SKILL.md (`SKILL.md:76-78`) lista las mismas secciones: change, mode, completeness table, build/tests/coverage evidence, spec compliance matrix, correctness table, design coherence table, issues agrupados CRITICAL/WARNING/SUGGESTION, y veredicto final.

> [CERT] Cuando Strict TDD está activo, se insertan las secciones de TDD compliance, test layer distribution, changed-file coverage y quality metrics desde `strict-tdd-verify.md` ([Bloque 23]) (`references/report-format.md:67`).

## 11.7 — Graceful Artifact Handling (degradación) `[CERT]`

`SKILL.md:80-85` + Decision Gates. La verificación degrada según qué artefactos existan:

| Artefactos disponibles | Qué verifica |
|------------------------|--------------|
| Solo tasks | solo completitud objetiva de tareas; NO reclama spec correctness ni design coherence; si todas checked y sin runtime evidence → veredicto puede ser `PASS WITH WARNINGS` para completitud de tasks únicamente |
| Tasks + specs | completitud + correctness de requisitos/escenarios; evidencia runtime aún requerida; tests cubrientes faltantes son CRITICAL para escenarios requeridos salvo que config permita verificación manual |
| Proposal/specs/design/tasks (full) | verifica todas las dimensiones: completeness, correctness, coherence |
| `actionContext.mode: workspace-planning` | STOP; verificación full de implementación de workspace no soportada en este slice (`SKILL.md:55`) |

> [CERT] "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:85`). Las tareas sin marcar son el bloqueo más duro, independiente del resto.

## 11.8 — Execution Steps `[CERT]`

`SKILL.md:64-74`:

1. Cargar skills relevantes (Sección A).
2. Recuperar artefactos (Sección B) o leer `contextFiles` del structured status.
3. Resolver modo testing/TDD desde capabilities cacheadas, config, o archivos del proyecto.
4. Contar tareas completas e incompletas. Cualquier tarea de implementación sin marcar es CRITICAL y bloquea archive readiness.
5. Si existen specs, mapear cada requisito/escenario a evidencia de implementación y tests.
6. Si existe design, chequear decisiones contra código cambiado; si falta, saltar coherence y registrar por qué.
7. Correr test, build/type-check y coverage cuando estén disponibles. Para verificación full de spec, preservar la evidencia runtime más estricta de gentle-ai: la inspección de fuente sola NO prueba compliance de escenarios.
8. Construir la behavioral compliance matrix desde resultados de test reales.
9. Persistir y retornar el report, incluyendo dimensiones saltadas por artefactos faltantes.

## 11.9 — Modelo asignado `[CERT]`

`agents/sdd-verify.md:6`: `model: sonnet` (Model Assignments [Bloque 18]: "sdd-verify | sonnet | default | Validation against spec"). Tools (`agents/sdd-verify.md:7`): `Read, Grep, Glob, Bash, mem_search, mem_get_observation, mem_save` — con `Bash` para ejecutar tests, sin tools de escritura de proyecto.

## 11.10 — Result Contract `[CERT]`

El **agente** (`agents/sdd-verify.md:37-44`):

| Campo | Valor |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | veredicto en una frase (conteo CRITICAL/WARNING/SUGGESTION) |
| `artifacts` | topic_keys/paths (ej. `sdd/{change}/verify-report`) |
| `next_recommended` | `sdd-archive` (si limpio) o `sdd-apply` (si hay CRITICAL) |
| `risks` | issues CRITICAL no resueltos que bloquean archive |
| `skill_resolution` | `paths-injected` o `none` |

El **prompt condensado** (`prompts/sdd/sdd-verify.md:38-45`) usa un JSON minimalista: `{status: pass|fail|warning, checks: [{criterion, result, evidence}], next: ready-for-archive|fixes-required}`.

## 11.11 — Gotchas `[CERT]`

- **Static analysis ≠ verification** (`SKILL.md:42, 71`): el SKILL.md exige ejecución runtime de tests para compliance de escenarios. Es la regla más fuerte de la fase.
- **DIVERGENCIA CRÍTICA entre SKILL.md y prompt condensado** [CERT — comparado]: `prompts/sdd/sdd-verify.md:33` dice *"Do NOT run tests unless `strict_tdd` is active and test runner is explicitly provided"* — lo OPUESTO al SKILL.md, que exige ejecutar tests siempre ("static analysis alone is never verification"). El prompt condensado además limita a "Inspect changed files listed in apply-progress (or tasks)". El SKILL.md (v3.0, con report-format) es la fuente canónica completa; el prompt es la variante de bajo presupuesto que sacrifica la ejecución de tests. [INFER] Quien implemente debe seguir el SKILL.md salvo restricción explícita de tokens.
- **Unchecked task = CRITICAL siempre** (`SKILL.md:69, 85`): aun con todo lo demás en verde, una tarea `- [ ]` bloquea archive.
- **`workspace-planning` ⇒ STOP** (`SKILL.md:55`): no soporta verificación full de implementación de workspace.
- **No marca tasks ni arregla código**: sin `mem_update`, `Edit` ni `Write`; solo reporta (`agents/sdd-verify.md:7`, `SKILL.md:43`).

## 11.12 — Conexiones

- **[Bloque 10] (apply)** → `sdd-verify` lee `apply-progress` + spec + tasks; valida que el código coincida con el contrato (`agents/sdd-verify.md:21`).
- **[Bloque 11] → [Bloque 23] (strict-TDD)**: carga `strict-tdd-verify.md` solo si Strict TDD activo; verifica la tabla TDD Cycle Evidence que produjo apply (`SKILL.md:45`).
- **[Bloque 12] (archive)** → `next_recommended: sdd-archive` si limpio. Verify es el guardia que precede al cierre: CRITICAL bloquea archive sin override (la Strict-vs-OpenSpec Archive Policy de [Bloque 12] hereda esto).
- **[Bloque 9] (tasks)**: cuenta y valida la completitud de las tasks.
- **[Bloque 16] (Gatekeeper)**: verify es el alias de modelo usado por el gatekeeper para revisiones de contexto fresco en fases high-risk.
- **[Bloque 3]**: artefacto `verify-report` → `sdd/{change}/verify-report`.
- **[Bloque 22] (phase-common + status-contract)**: Secciones A–D + structured status + Decision Gates de `actionContext`.
- **[Bloque 18] (models)**: sonnet, "Validation against spec".
