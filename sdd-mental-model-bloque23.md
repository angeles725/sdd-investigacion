# Bloque 23 — TDD estricto (strict-tdd / strict-tdd-verify)

> **QUÉ DOCUMENTA**: Este bloque establece el modelo mental del **Strict TDD Mode** del SDD de gentle-ai: qué es, cómo se activa (init detecta el test runner y setea el flag `strict_tdd`), cómo el orquestador hace forwarding OBLIGATORIO del modo a las fases `apply` y `verify`, el ciclo red-green-refactor que impone módulo de apply, la auditoría de calidad de aserciones del módulo de verify, y qué NO permite (fallback a Standard Mode).
> **ALCANCE**: Los dos módulos de TDD estricto (apply y verify), la detección de capacidades de testing en init, y el contrato de forwarding del orquestador. NO cubre la mecánica general de `sdd-apply` (ver [Bloque 10]) ni de `sdd-verify` (ver [Bloque 11]) ni la detección completa de stack en init (ver [Bloque 4]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/skills/sdd-apply/strict-tdd.md` (módulo apply, 365 líneas)
> - `/home/cristian/.config/opencode/skills/sdd-verify/strict-tdd-verify.md` (módulo verify, 270 líneas)
> - `/home/cristian/.config/opencode/skills/sdd-init/references/init-details.md` §"Testing Capability Checklist", §"Testing Capabilities Format", §"Engram Saves"
> - `/home/cristian/.claude/CLAUDE.md` §"Strict TDD Forwarding (MANDATORY)", §"SDD Init Guard (MANDATORY)"
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección`. `[CERT-a]` = afirmado por una fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 23.1 — Qué es Strict TDD Mode y qué disciplina impone `[CERT]`

Strict TDD Mode es un par de **módulos condicionales** que se cargan SOLO cuando dos condiciones se cumplen a la vez: que el modo esté habilitado Y que exista un test runner `[CERT]` (`strict-tdd.md:3`: "This module is loaded ONLY when Strict TDD Mode is enabled AND a test runner is available"; idéntico en `strict-tdd-verify.md:3`).

La filosofía no es "testing" sino **diseño de software dirigido por tests**: *"TDD is not testing. TDD is software design driven by tests. You write a test that describes what the code SHOULD do, then write the minimum code to make it real... Code is a side effect of tests."* `[CERT]` (`strict-tdd.md:8`).

El modo codifica las **Tres Leyes** de TDD `[CERT]` (`strict-tdd.md:10-14`):

| # | Ley `[CERT]` |
|---|--------------|
| 1 | NO escribir código de producción hasta tener un test que falla |
| 2 | NO escribir más test del necesario para fallar |
| 3 | NO escribir más código del necesario para pasar el test |

**Modelo mental** `[INFER]`: a diferencia del Standard Mode (donde el test puede venir después o no venir), el Strict Mode invierte la causalidad — el test es la causa y el código es el efecto. Esto es estructuralmente verificable: el módulo de verify audita la evidencia que apply produce, cerrando el lazo.

## 23.2 — Cómo se activa: init detecta el test runner `[CERT]`

El modo no se activa solo; depende de que `sdd-init` haya detectado capacidades de testing. El checklist de detección `[CERT]` (`init-details.md §"Testing Capability Checklist"`):

- **Test runner**: scripts/deps de `package.json`, `pyproject.toml`, `pytest.ini`, `go.mod`, `Cargo.toml`, `Makefile`.
- **Test layers**: unit runner; librerías de integración (`testing-library`, `httpx`, `httptest`, `WebApplicationFactory`); E2E (`playwright`, `cypress`, `selenium`, `chromedp`).
- **Coverage**: `vitest --coverage`, `jest --coverage`, `c8`, `pytest-cov`, `go test -cover`, `coverlet`.
- **Quality**: linter, type checker, formatter.

Init persiste lo detectado en dos memorias `[CERT]` (`init-details.md §"Engram Saves"`):

| topic_key | type | contenido `[CERT]` |
|-----------|------|---------|
| `sdd-init/{project}` | architecture | contexto del proyecto detectado |
| `sdd/{project}/testing-capabilities` | config | capacidades de testing en markdown |
| `skill-registry` | config | registry de skills |

El formato de capacidades incluye el flag explícito **`Strict TDD Mode: {enabled/disabled}`**, el comando del runner, y una tabla de layers Unit/Integration/E2E con su disponibilidad y tool `[CERT]` (`init-details.md §"Testing Capabilities Format"`). Ese `Command: {command}` es el `test_command` que luego consumen los módulos.

> Nota `[CERT]` (`CLAUDE.md` §"SDD Init Guard"): antes de CUALQUIER comando SDD, el orquestador verifica que init haya corrido para el proyecto (`mem_search "sdd-init/{project}"`). Si no, corre init PRIMERO. Esto garantiza que "Testing capabilities are always detected and cached" y que "Strict TDD Mode is activated when the project supports it". `[CERT]`

## 23.3 — El forwarding OBLIGATORIO a apply y verify `[CERT]`

El orquestador NO confía en que el sub-agente descubra el modo por su cuenta. El contrato de forwarding es explícito y no negociable `[CERT]` (`CLAUDE.md` §"Strict TDD Forwarding (MANDATORY)"):

1. Buscar capacidades: `mem_search(query: "sdd-init/{project}", project: "{project}")`. `[CERT]`
2. Si el resultado contiene `strict_tdd: true`, agregar al prompt del sub-agente:
   > *"STRICT TDD MODE IS ACTIVE. Test runner: {test_command}. You MUST follow strict-tdd.md. Do NOT fall back to Standard Mode."* `[CERT]`
3. Esto es **NON-NEGOTIABLE**: *"Do not rely on the sub-agent discovering this independently."* `[CERT]`
4. Si la búsqueda falla o `strict_tdd` no aparece, NO se agrega la instrucción → el sub-agente usa Standard Mode. `[CERT]`

El orquestador resuelve el estado TDD **una vez por sesión** (en el primer launch de apply/verify) y lo cachea `[CERT]` (`CLAUDE.md` §"Strict TDD Forwarding").

**Implicación arquitectónica** `[INFER]`: el modo vive en TRES lugares coordinados — (a) detectado por init y persistido en engram, (b) reenviado por el orquestador en el prompt de delegación, (c) ejecutado por los módulos `strict-tdd.md` / `strict-tdd-verify.md`. El sub-agente recibe contexto fresco sin memoria, por eso el forwarding debe ser explícito: el ejecutor no busca engram por su cuenta para esto. La frase *"the orchestrator already verified both conditions"* (`strict-tdd.md:4`) confirma que el módulo asume que el gate ya pasó aguas arriba.

## 23.4 — El ciclo de implementación TDD que impone apply `[CERT]`

Para CADA tarea asignada, el módulo de apply impone un ciclo estricto con **gates** entre fases `[CERT]` (`strict-tdd.md:16-87`):

| Paso | Nombre | Qué hace `[CERT]` | Gate |
|------|--------|---------|------|
| 0 | SAFETY NET | Solo si se modifican archivos existentes: correr tests previos, capturar baseline "{N} tests passing"; si alguno falla → STOP y reportar como "pre-existing failure" (NO arreglarlo) | El baseline prueba que no rompiste lo que ya funcionaba |
| 1 | UNDERSTAND | Leer tarea, escenarios del spec (= criterios de aceptación), decisiones del design (= constraints), patrones de test existentes; determinar layer | — |
| 2 | RED | Escribir test(s) que fallan PRIMERO, referenciando código de producción que NO existe aún (eso garantiza el fallo sin ejecutar) | NO avanzar a GREEN hasta que el test esté escrito |
| 3 | GREEN | Escribir el MÍNIMO código para pasar; "Fake It" (retornos hardcodeados) es VÁLIDO; EJECUTAR tests → deben PASAR; si falla, arreglar la implementación, NO el test | NO avanzar hasta confirmar GREEN por ejecución |
| 4 | TRIANGULATE | Agregar un segundo caso con inputs/outputs DIFERENTES; si el Fake It se rompe → generalizar a lógica real; MÍNIMO 2 casos por comportamiento | Todos los escenarios del spec deben tener test antes de REFACTOR |
| 5 | REFACTOR | Mejorar sin cambiar comportamiento (extraer constantes/funciones, eliminar duplicación, Boy Scout Rule); EJECUTAR tests tras CADA paso; si falla → revertir ese paso | Tests verdes tras CADA cambio de refactor |
| 6 | Marcar tarea `[x]` | — | — |
| 7 | Anotar desviaciones o issues descubiertos | — | — |

Detalle crítico de RED `[CERT]` (`strict-tdd.md:39-42`): si la función de producción YA existe, el test debe cubrir el NUEVO comportamiento aún no implementado. La referencia a código inexistente es lo que "guarantees failure — no need to execute to confirm".

**TRIANGULATE es obligatorio por defecto** `[CERT]` (`strict-tdd.md:53-54`): *"DEFAULT: triangulation is REQUIRED. You need a compelling reason to skip it."* Solo se puede saltar cuando TODO esto es cierto: la tarea es puramente estructural (config/constante/type export), hay literalmente UNA salida posible (sin branching), y se anota "Triangulation skipped: {reason}" en la tabla de evidencia `[CERT]` (`strict-tdd.md:68-71`).

El módulo advierte contra el **GREEN trivial** `[CERT]` (`strict-tdd.md:63-67`): un test que pasa porque el componente no se renderiza, porque un loop itera 0 veces, o porque el setup no dispara el code path → NO es un GREEN real. Un GREEN real significa "production code RAN and produced the expected output".

## 23.5 — Choosing test layer, ejecución y pure functions `[CERT]`

**Elección de layer** `[CERT]` (`strict-tdd.md:89-114`): se elige por QUÉ hace la tarea, usando el **layer más alto disponible que encaje**, degradando con gracia si falta tooling pero NUNCA saltando una tarea:

| Tipo de tarea | Layer ideal `[CERT]` | Degradación |
|---------------|------------|-------------|
| Lógica pura / utilidad / cálculo / transformación | Unit (siempre disponible si hay runner) | — |
| Render de componente / interacción / cambios de estado | Integration si hay tools | Unit con mocks |
| Flujo multi-componente / API / context-provider | Integration si hay tools | Unit con mocks |
| Flujo de negocio crítico / user journey completo | E2E si hay tools | Integration; si no, Unit |

**Ejecución de tests** `[CERT]` (`strict-tdd.md:117-134`): el comando se lee de las capacidades cacheadas (`test_runner.command`), con override en `openspec/config.yaml → rules.apply.test_command`, y fallback a detección desde `package.json`/`pyproject.toml`/`go.mod`. Durante el ciclo se corre **SOLO el archivo de test relevante**, no la suite completa (eso mantiene el ciclo rápido); la suite completa corre en `sdd-verify`, no aquí `[CERT]` (`strict-tdd.md:132-133`).

**Preferencia por funciones puras** `[CERT]` (`strict-tdd.md:136-154`): al escribir código en GREEN/TRIANGULATE se prefieren funciones puras (determinísticas, sin side effects, triviales de testear). El módulo da una excepción explícita: "don't force it where it doesn't fit (e.g., React components with state)" (`strict-tdd.md:362`).

**Approval testing** `[CERT]` (`strict-tdd.md:156-176`): para tareas de REFACTOR de código existente, ANTES de tocar producción se escriben "approval tests" que capturan el comportamiento actual (incluso si es feo o incorrecto), se corren en verde, se refactoriza, y se vuelven a correr; si el spec dice que el comportamiento DEBE cambiar, se actualiza el approval test a RED y se implementa.

## 23.6 — La evidencia que apply DEBE devolver `[CERT]`

Con Strict TDD activo, el summary de retorno DEBE incluir una **tabla de TDD Cycle Evidence** `[CERT]` (`strict-tdd.md:180-203`):

| Columna | Significado `[CERT]` (`strict-tdd.md:198-203`) |
|---------|------------|
| Safety Net | Tests previos corridos antes de modificar; "N/A (new)" para archivos nuevos |
| RED | Test escrito primero, referenciando código inexistente. Siempre "✅ Written" |
| GREEN | Tests ejecutados y pasando tras implementación mínima. Debe mostrar resultado de ejecución |
| TRIANGULATE | Casos adicionales para forzar lógica real. "➖ Single" si el spec tiene un solo escenario |
| REFACTOR | Código mejorado con tests aún verdes. "➖ None needed" si ya estaba limpio |

Más un **Test Summary** con totales: tests escritos/pasando, layers usados, approval tests, funciones puras creadas `[CERT]` (`strict-tdd.md:190-196`). Esta tabla es el artefacto primario que la fase de verify audita (§23.7).

## 23.7 — Lo que NO permite: aserciones triviales y el audit de verify `[CERT]`

El módulo de apply prohíbe aserciones que pasan sin ejercitar producción — *"A test that passes without exercising production logic is worse than no test — it gives false confidence."* `[CERT]` (`strict-tdd.md:207`). Patrones **BANEADOS** `[CERT]` (`strict-tdd.md:209-246`): tautologías (`expect(true).toBe(true)`), empty-collection sin contexto de setup, type-only (`toBeDefined()`/`not.toBeNull()` solas), **ghost loops** (aserciones dentro de un loop que itera 0 veces — código muerto), y ciclo TDD incompleto (GREEN sin TRIANGULATE).

Una aserción REAL debe cumplir las tres `[CERT]` (`strict-tdd.md:248-262`): (1) llama código de producción, (2) asevera un output específico derivado del spec, (3) FALLARÍA si la implementación estuviera mal. Reglas adicionales: **Mock Hygiene** (≤3 mocks sano; 7+ → testeando en el layer equivocado, `strict-tdd.md:291-302`), **Extract-Before-Mock** (extraer transformación a función pura antes de mockear), y **Implementation Detail Coupling** (las aserciones sobre clases CSS, estado interno o conteo de mocks NUNCA son válidas; "CSS class assertions are NEVER valid test assertions", `strict-tdd.md:347`).

El módulo de **verify** cierra el lazo. Su filosofía: pasar de "does the code work?" a "was the code built correctly? — meaning: was TDD actually followed?" `[CERT]` (`strict-tdd-verify.md:8`). Pasos clave:

| Paso | Qué valida `[CERT]` |
|------|------------|
| 5a — TDD Compliance Check | Lee la tabla de evidencia del `apply-progress`; por cada fila verifica RED (el test file EXISTE → CRITICAL si no), GREEN (cruza con ejecución del paso 5b → CRITICAL si falla ahora), TRIANGULATE (verifica N casos en el archivo), SAFETY NET. Si NO hay tabla → CRITICAL: "Strict TDD was enabled but apply did not follow the protocol" (`strict-tdd-verify.md:43-46`) |
| 5 expandido — Test Layer Validation | Clasifica cada test file en Unit/Integration/E2E por indicadores; cruza con capacidades; SUGGESTION si lógica de negocio crítica solo tiene unit tests |
| 5d — Changed File Coverage | Si hay tool de coverage: reporta % por archivo CAMBIADO con líneas no cubiertas; WARNING si <80% |
| 5e — Quality Metrics | Linter / type checker solo en archivos cambiados, solo si hay tools |
| 5f — **Assertion Quality Audit (MANDATORY)** | Escanea TODOS los test files por patrones baneados; CRITICAL para tautologías, aserciones sin llamada a producción, y ghost loops; WARNING para empty sin companion, smoke-test-only, coupling a implementación, y mock-heavy (mocks > 2× aserciones) |

Reglas terminales de verify `[CERT]` (`strict-tdd-verify.md:259-269`): coverage y quality metrics son informativas, NUNCA bloqueantes (solo WARNING); las tautologías son CRITICAL y DEBEN reescribirse; **el verify NO arregla nada — solo reporta; el orquestador decide** ("DO NOT fix issues — only report").

**Modelo mental del lazo apply↔verify** `[INFER]`: apply produce evidencia estructurada (la tabla), verify la audita cruzándola contra la realidad ("don't trust the report blindly", `strict-tdd-verify.md:262`). Es un sistema de afirmación-y-verificación: apply declara, verify desconfía y re-ejecuta. Esto vuelve el "se siguió TDD" una propiedad auditable, no una promesa.

## 23.8 — Conexiones

- **[Bloque 4] — sdd-init**: la activación de Strict TDD nace en init, que detecta el test runner y persiste `testing-capabilities` con el flag `strict_tdd` y el `test_command`. Sin esa detección, el orquestador no puede hacer forwarding (§23.2-23.3). El SDD Init Guard garantiza que init corrió antes de cualquier apply/verify.
- **[Bloque 10] — sdd-apply**: el módulo `strict-tdd.md` es una EXTENSIÓN condicional de la fase apply. Cuando el modo está activo, el ciclo red-green-refactor (§23.4) reemplaza al flujo de implementación estándar y agrega la tabla de TDD Cycle Evidence al Result Contract de apply.
- **[Bloque 11] — sdd-verify**: el módulo `strict-tdd-verify.md` agrega a la fase verify los pasos 5a/5f que auditan la evidencia de apply (§23.7). Las severidades CRITICAL/WARNING/SUGGESTION que verify emite (ver [Bloque 11]) se nutren aquí del Assertion Quality Audit.
- **[Bloque 18] — delegación y forwarding**: el forwarding obligatorio de §23.3 es un caso concreto del Sub-Agent Context Protocol — el orquestador (no el sub-agente) busca engram y reenvía el modo en el prompt, porque el ejecutor recibe contexto fresco sin memoria.
- **[Bloque 3] — backends y topic keys**: las capacidades viven en `sdd/{project}/testing-capabilities` y el progreso en `sdd/{change-name}/apply-progress`, el artefacto que verify lee para el TDD Compliance Check.
