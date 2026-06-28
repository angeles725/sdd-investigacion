# Bloque 7 — Fase `sdd-spec`

> **Qué documenta:** la fase de especificación del sistema SDD de gentle-ai — toma el proposal y produce delta specs: requisitos con keywords RFC 2119 y escenarios Given/When/Then que describen qué se ADDED/MODIFIED/REMOVED/RENAMED del comportamiento del sistema. Describe el QUÉ, nunca el CÓMO.
> **Alcance:** propósito, qué lee / qué escribe, inputs, los 6 pasos, el workflow crítico de MODIFIED Requirements (copy-full-then-edit), formato delta vs spec completo, Result Contract, modelo `sonnet`, gotchas (budget 650 palabras, RFC 2119).
> **Fuentes exactas leídas:**
> - `/home/cristian/.config/opencode/skills/sdd-spec/SKILL.md` (contrato runtime — primaria)
> - `/home/cristian/.claude/agents/sdd-spec.md` (definición del sub-agente: tools, modelo)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-spec.md` (prompt canónico — idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (protocolo común)
> - (NO existe `commands/sdd-spec.md` — se invoca vía meta-comandos `[CERT]` `ls commands/`)
> **Método + leyenda de marcadores:**
> - `[CERT]` = verificado leyendo el archivo, cita `ruta:línea` o `ruta §sección`.
> - `[CERT-a]` = afirmado por una fuente, no re-verificado.
> - `[INFER]` = deducción propia.

---

## 7.1 — Propósito y posición en el DAG `[CERT]`

`sdd-spec` toma el proposal y produce **delta specs**: requisitos estructurados y escenarios que describen qué se está ADDED, MODIFIED, REMOVED o RENAMED del comportamiento del sistema `[CERT]` `SKILL.md:32-34`. En el DAG depende del proposal y alimenta a tasks: `proposal → spec → tasks` (con design como dependencia paralela de tasks) `[CERT]` `agents/sdd-spec.md:42`.

Principio rector `[CERT]` `SKILL.md:238`: *"DO NOT include implementation details in specs — specs describe WHAT, not HOW."* La separación QUÉ/CÓMO es el límite entre spec (este bloque) y design ([Bloque 8]).

Es EXECUTOR `[CERT]` `agents/sdd-spec.md:10-11`. Mismo gate orquestador/executor `[CERT]` `SKILL.md:13-21`. **No tiene comando directo `[CERT]`** — se orquesta vía meta-comandos.

## 7.2 — Qué lee y qué escribe `[CERT]`

| Acción | Recurso | Topic key / ruta | Obligatoriedad |
|---|---|---|---|
| LEE | Propuesta | `sdd/{change-name}/proposal` | **requerido** `[CERT]` `SKILL.md:46`, `agents/sdd-spec.md:19` |
| LEE | (openspec) specs existentes del dominio | `openspec/specs/{domain}/spec.md` | condicional al modo `[CERT]` `SKILL.md:72-74` |
| ESCRIBE | Delta specs / spec completo | `sdd/{change-name}/spec` (Engram, concatenado) / `openspec/changes/{change-name}/specs/{domain}/spec.md` | **requerido** `[CERT]` `SKILL.md:46,196-202` |

**Input requerido `[CERT]`:** el proposal es dependencia **dura** — `agents/sdd-spec.md:19` instruye `mem_search("sdd/{change-name}/proposal") → mem_get_observation`. Sin proposal no hay spec.

En Engram, si los specs abarcan múltiples dominios, se **concatenan en un único artefacto** con headers por dominio `[CERT]` `SKILL.md:46`. En openspec/hybrid se escriben archivos por dominio `[CERT]` `SKILL.md:48`. Save con `type: architecture` `[CERT]` `SKILL.md:202`.

## 7.3 — Identificar dominios desde Capabilities (Step 2) `[CERT]`

El paso 2 lee la **Capabilities section** del proposal como contrato primario `[CERT]` `SKILL.md:56-70`:

```
FOR EACH "New Capabilities":
├── NEW full spec: openspec/specs/<capability-name>/spec.md
└── spec completo (no delta) — no hay comportamiento previo

FOR EACH "Modified Capabilities":
├── DELTA spec: openspec/changes/{change-name}/specs/<capability-name>/spec.md
└── leer openspec/specs/<capability-name>/spec.md primero — el delta lo modifica
```

Fallback `[CERT]` `SKILL.md:70`: si el proposal no tiene Capabilities (formato viejo), inferir desde "Affected Areas" — pero siempre preferir el mapeo explícito de Capabilities. Esto cierra el contrato proposal→spec descrito en [Bloque 6 §6.4].

## 7.4 — Workflow crítico de MODIFIED Requirements `[CERT]`

El gotcha más importante de spec. Al escribir una sección `## MODIFIED Requirements`, seguir EXACTAMENTE `[CERT]` `SKILL.md:94-110`:

```
1. Localizar el requirement en openspec/specs/{domain}/spec.md
2. COPIAR el bloque ENTERO — desde `### Requirement:` a TODOS sus scenarios
3. PEGAR bajo `## MODIFIED Requirements`
4. EDITAR la copia para reflejar el nuevo comportamiento
5. Agregar "(Previously: {resumen de una línea de lo que cambió})"
```

**Por qué copy-full-then-edit `[CERT]` `SKILL.md:105-109`:** el archive step REEMPLAZA el requirement en los main specs con tu bloque MODIFIED. Si tu bloque es parcial, el archive **pierde los scenarios que no copiaste**. Pitfall común: escribir solo el scenario que cambió y perder el resto. Si agregás comportamiento NUEVO sin cambiar el existente → usar ADDED, no MODIFIED.

Esta regla conecta directamente con [Bloque 12] (archive): la integridad del spec MODIFIED determina que el archive no destruya comportamiento. Reforzado en Rules `[CERT]` `SKILL.md:239` (*"Partial MODIFIED blocks lose content at archive time"*).

## 7.5 — Formato delta vs spec completo `[CERT]`

**Delta spec** (dominio existente) `[CERT]` `SKILL.md:112-170` — cuatro secciones:

- `## ADDED Requirements` — requisitos nuevos con scenarios happy path + edge case.
- `## MODIFIED Requirements` — bloque completo editado + `(Previously: ...)`.
- `## REMOVED Requirements` — con `(Reason: ...)` y `(Migration: ...)`.
- `## RENAMED Requirements` — `{Old Name} → {New Name}` + Reason + Migration.

**Spec completo** (dominio nuevo, sin spec previo) `[CERT]` `SKILL.md:172-194`: `# {Domain} Specification` con `## Purpose` y `## Requirements`.

Estructura de cada requirement `[CERT]` `SKILL.md:119-136`: descripción con keyword RFC 2119, seguida de uno o más `#### Scenario:` en formato Given/When/Then/And.

## 7.6 — RFC 2119 y testabilidad `[CERT]`

Reglas duras de estilo `[CERT]` `SKILL.md:230-237`:

- SIEMPRE usar Given/When/Then para scenarios.
- SIEMPRE usar keywords RFC 2119 (MUST/SHALL/SHOULD/MAY) para la fuerza del requisito.
- Cada requirement DEBE tener al menos UN scenario.
- Incluir happy path **Y** edge case.
- Scenarios TESTABLES — alguien debería poder escribir un test automatizado de cada uno.

Quick reference RFC 2119 `[CERT]` `SKILL.md:247-255`: MUST/SHALL = requisito absoluto; MUST NOT/SHALL NOT = prohibición absoluta; SHOULD/SHOULD NOT = recomendado/no recomendado con justificación; MAY = opcional.

La exigencia de testabilidad es el puente hacia Strict TDD: si cada scenario es testable, `sdd-apply`/`sdd-verify` pueden derivar tests de ellos `[INFER]` (ver [Bloque 23]).

## 7.7 — Los 6 pasos + Result Contract `[CERT]`

Pasos `[CERT]` `SKILL.md:51-226`: Step 1 (load skills) → Step 2 (identificar dominios desde Capabilities) → Step 3 (leer specs existentes) → Step 4 (escribir delta specs / spec completo) → Step 5 (persistir, MANDATORIO) → Step 6 (return summary con tabla Domain/Type/Requirements/Scenarios + Coverage).

Result Contract `[CERT]` `agents/sdd-spec.md:38-44`:

| Campo | Valores / contenido |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase del alcance del spec |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/spec`) |
| `next_recommended` | `sdd-tasks` (después de que design también esté listo) |
| `risks` | ambigüedades del proposal que forzaron assumptions a nivel spec |
| `skill_resolution` | `paths-injected` o `none` |

El return summary del SKILL adicionalmente reporta Coverage (happy/edge/error) `[CERT]` `SKILL.md:218-222`. Misma discrepancia `status` (`done` vs `success` común).

`next_recommended: sdd-tasks` está condicionado a que design también esté listo `[CERT]` `agents/sdd-spec.md:42` — tasks necesita spec **y** design.

## 7.8 — Modelo asignado: `sonnet` `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-spec.md:6`. Justificación de la tabla: *"sdd-spec | sonnet | Structured writing"* `[CERT-a]` (CLAUDE.md, Model Assignments). Razonamiento `[INFER]`: spec es **escritura estructurada**, no decisión arquitectónica — las decisiones ya las tomó propose (opus) y las tomará design (opus). spec traduce el QUÉ del proposal a requisitos formales testables siguiendo plantillas estrictas (RFC 2119, Given/When/Then), tarea que sonnet ejecuta con fidelidad.

Tools `[CERT]` `agents/sdd-spec.md:7`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`.

## 7.9 — Gotchas y reglas especiales `[CERT]`

- **Size budget 650 palabras `[CERT]` `SKILL.md:244`:** preferir tablas de requisitos sobre narrativa; cada scenario 3-5 líneas máx.
- **MODIFIED = bloque completo `[CERT]` `SKILL.md:239`:** la regla copy-full-then-edit de §7.4; bloques MODIFIED parciales pierden contenido en archive.
- **ADDED vs MODIFIED `[CERT]` `SKILL.md:240`:** comportamiento nuevo sin cambiar lo existente → ADDED, no MODIFIED.
- **REMOVED/RENAMED `[CERT]` `SKILL.md:241-242`:** REMOVED debe incluir Reason y debería incluir Migration cuando hay consumers/docs/tests afectados; RENAMED debe declarar ambos nombres.
- **`rules.specs` `[CERT]` `SKILL.md:243`:** aplicar reglas de `openspec/config.yaml`.
- **WHAT no HOW `[CERT]` `SKILL.md:238`:** sin detalles de implementación.

---

## 7.10 — Conexiones

- **[Bloque 6] (`sdd-propose`):** predecesor y dependencia **requerida**. spec lee `sdd/{change-name}/proposal` y consume su sección Capabilities como contrato para decidir qué specs crear (`SKILL.md:56-70`).
- **[Bloque 8] (`sdd-design`):** par paralelo. Ambos dependen del proposal; design lee el spec opcionalmente (`sdd/{change-name}/spec`). spec describe el QUÉ, design el CÓMO — frontera explícita en `SKILL.md:238`.
- **[Bloque 9] (`sdd-tasks`):** sucesor. tasks requiere spec **y** design listos; `next_recommended: sdd-tasks` condicionado a design `[CERT]` `agents/sdd-spec.md:42`.
- **[Bloque 12] (`sdd-archive`):** el archive REEMPLAZA requirements en main specs con los bloques MODIFIED del spec — de ahí la criticidad del workflow copy-full-then-edit (§7.4).
- **[Bloque 2] (DAG + Result Contract):** envelope estándar con discrepancia `status`.
- **[Bloque 3 / Bloque 19] (backends + persistencia):** topic key `sdd/{change-name}/spec`; en Engram un único artefacto concatenado multi-dominio.
- **[Bloque 18] (delegación + models):** `sonnet` por escritura estructurada.
- **[Bloque 23] (strict-TDD):** los scenarios testables Given/When/Then son la base que apply/verify usan para derivar y validar tests.
