# Bloque 8 — Fase `sdd-design`

> **Qué documenta:** la fase de diseño técnico del sistema SDD de gentle-ai — lee el proposal (requerido) y el spec (opcional), lee el codebase real, y produce un `design.md` que captura el CÓMO: decisiones de arquitectura estilo ADR, data flow, file changes, interfaces y testing strategy.
> **Alcance:** propósito, qué lee / qué escribe, inputs, los 5 pasos, el formato del design (decisiones ADR con rationale + alternativas rechazadas), Result Contract, modelo `opus` y por qué, gotchas (budget 800 palabras, leer codebase real, seguir patrones existentes).
> **Fuentes exactas leídas:**
> - `/home/cristian/.config/opencode/skills/sdd-design/SKILL.md` (contrato runtime — primaria)
> - `/home/cristian/.claude/agents/sdd-design.md` (definición del sub-agente: tools, modelo)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-design.md` (prompt canónico — idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (protocolo común)
> - (NO existe `commands/sdd-design.md` — se invoca vía meta-comandos `[CERT]` `ls commands/`)
> **Método + leyenda de marcadores:**
> - `[CERT]` = verificado leyendo el archivo, cita `ruta:línea` o `ruta §sección`.
> - `[CERT-a]` = afirmado por una fuente, no re-verificado.
> - `[INFER]` = deducción propia.

---

## 8.1 — Propósito y posición en el DAG `[CERT]`

`sdd-design` toma el proposal y los specs y produce un `design.md` que captura **HOW the change will be implemented** — decisiones de arquitectura, data flow, file changes y rationale técnico `[CERT]` `SKILL.md:32-34`. En el DAG depende del proposal (requerido) y corre en paralelo con spec; ambos alimentan a tasks: `proposal → design → tasks` `[CERT]` `agents/sdd-design.md:43`.

Frontera con spec `[INFER]`: spec describe el QUÉ (requisitos testables, [Bloque 7]); design describe el CÓMO (arquitectura, archivos, interfaces). El prompt lo formula: *"design is the HOW at architectural level, tasks are the WHAT-to-do steps"* `[CERT]` `agents/sdd-design.md:26`.

Es EXECUTOR `[CERT]` `agents/sdd-design.md:10-11`. Mismo gate orquestador/executor `[CERT]` `SKILL.md:13-21`. **No tiene comando directo `[CERT]`** — se orquesta vía meta-comandos.

## 8.2 — Qué lee y qué escribe `[CERT]`

| Acción | Recurso | Topic key / ruta | Obligatoriedad |
|---|---|---|---|
| LEE | Propuesta | `sdd/{change-name}/proposal` | **requerido** `[CERT]` `SKILL.md:46`, `agents/sdd-design.md:20` |
| LEE | Spec | `sdd/{change-name}/spec` | **opcional** (puede no existir si corre en paralelo con sdd-spec) `[CERT]` `SKILL.md:46` |
| LEE | Código real del codebase | filesystem (entry points, módulos, patrones, interfaces, test infra) | **requerido** `[CERT]` `SKILL.md:56-62,176` |
| ESCRIBE | Diseño técnico | `sdd/{change-name}/design` (Engram) / `openspec/changes/{change-name}/design.md` | **requerido** `[CERT]` `SKILL.md:46,142-149` |

**Input requerido `[CERT]`:** el proposal — `agents/sdd-design.md:20` instruye `mem_search("sdd/{change-name}/proposal") → mem_get_observation`. El spec es **opcional** explícitamente porque design puede correr en paralelo con sdd-spec `[CERT]` `SKILL.md:46` (*"may not exist if running in parallel with sdd-spec"*). Save con `type: architecture` `[CERT]` `SKILL.md:149`.

**Que lee la proposal y produce decisiones de arquitectura `[CERT]`:** este es el núcleo de design. Lee el proposal (intent, scope, approach) y, leyendo además el codebase real, lo traduce en decisiones de arquitectura concretas con rationale y alternativas rechazadas (§8.3).

## 8.3 — Decisiones de arquitectura estilo ADR `[CERT]`

El corazón del `design.md` es la sección **Architecture Decisions**, en formato ADR (Architecture Decision Record) `[CERT]` `SKILL.md:87-99`:

```markdown
### Decision: {Decision Title}

**Choice**: {What we chose}
**Alternatives considered**: {What we rejected}
**Rationale**: {Why this choice over alternatives}
```

Regla dura `[CERT]` `SKILL.md:177`: *"Every decision MUST have a rationale (the 'why')."* El prompt del agente refuerza: capturar decisiones estilo ADR con rationale **y alternativas rechazadas** `[CERT]` `agents/sdd-design.md:23` ("Capture ADR-style decisions with rationale and rejected alternatives").

Esto materializa por qué design corre en `opus`: no transcribe, **decide** — elige patrón, layering y boundaries justificando contra alternativas (§8.6).

## 8.4 — Estructura completa del `design.md` `[CERT]`

`[CERT]` `SKILL.md:79-140`:

- `## Technical Approach` — estrategia técnica general; cómo mapea al approach del proposal; referencia specs.
- `## Architecture Decisions` — bloques ADR (§8.3).
- `## Data Flow` — cómo se mueve la data; diagramas ASCII cuando ayuden.
- `## File Changes` — tabla `File | Action (Create/Modify/Delete) | Description` con paths concretos.
- `## Interfaces / Contracts` — nuevas interfaces, contratos API, type definitions, en el lenguaje del proyecto.
- `## Testing Strategy` — tabla `Layer (Unit/Integration/E2E) | What to Test | Approach`.
- `## Migration / Rollout` — plan si hay migración/feature flags/rollout por fases; si no, "No migration required."
- `## Open Questions` — checklist de preguntas técnicas no resueltas o que necesitan input del equipo.

La `Testing Strategy` por layers conecta design con las capacidades de testing detectadas en init `[INFER]` (ver [Bloque 4 §4.3]).

## 8.5 — Los 5 pasos + Result Contract `[CERT]`

Pasos `[CERT]` `SKILL.md:51-172`: Step 1 (load skills) → Step 2 (**leer el codebase real** — entry points, patrones, dependencias, test infra) → Step 3 (escribir `design.md`) → Step 4 (persistir, MANDATORIO) → Step 5 (return summary).

El prompt del agente expande Step 2-3 a `[CERT]` `agents/sdd-design.md:19-24`: elegir el approach de arquitectura (pattern, layering, boundaries) → mapear componentes, data flow, integration points → capturar decisiones ADR → persistir.

Result Contract `[CERT]` `agents/sdd-design.md:38-45`:

| Campo | Valores / contenido |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase del approach elegido |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/design`) |
| `next_recommended` | `sdd-tasks` (después de que spec también esté listo) |
| `risks` | riesgos arquitectónicos, decisiones no resueltas, assumptions a validar |
| `skill_resolution` | `paths-injected` o `none` |

El return summary del SKILL adicionalmente reporta Key Decisions (N), Files Affected (N new/M modified/K deleted), Testing Strategy y Open Questions `[CERT]` `SKILL.md:160-168`. Misma discrepancia `status` (`done` vs `success` común).

`next_recommended: sdd-tasks` condicionado a que spec también esté listo `[CERT]` `agents/sdd-design.md:43` — tasks necesita spec **y** design.

## 8.6 — Modelo asignado: `opus` `[CERT]`

`model: opus` `[CERT]` `agents/sdd-design.md:7`. Justificación de la tabla: *"sdd-design | opus | Architecture decisions"* `[CERT-a]` (CLAUDE.md, Model Assignments). Razonamiento `[INFER]`: junto con propose, design es la otra fase de **decisiones arquitectónicas** — elige patrones, evalúa alternativas y produce rationale que se propaga a tasks y apply. Errores aquí componen downstream, de ahí el modelo de mayor razonamiento. Por eso design (y apply) son fases **high-risk** que el Gatekeeper del orquestador valida con un reviewer de contexto fresco, no inline (ver [Bloque 16]).

Tools `[CERT]` `agents/sdd-design.md:8`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`. Tiene Read/Grep/Glob para cumplir la regla dura de leer el codebase real.

## 8.7 — Gotchas y reglas especiales `[CERT]`

- **Leer codebase real, nunca adivinar `[CERT]` `SKILL.md:176`:** *"ALWAYS read the actual codebase before designing — never guess."* Es la primera regla dura.
- **Seguir patrones existentes `[CERT]` `SKILL.md:179-180`:** usar los patrones REALES del proyecto, no best practices genéricas; si el codebase usa un patrón distinto al que recomendarías, anotarlo pero SEGUIR el existente salvo que el cambio lo aborde específicamente.
- **Paths concretos `[CERT]` `SKILL.md:178`:** file paths concretos, no descripciones abstractas.
- **Open questions que bloquean `[CERT]` `SKILL.md:183`:** si hay preguntas que BLOQUEAN el diseño, decirlo claramente — no adivinar.
- **Size budget 800 palabras `[CERT]` `SKILL.md:184`:** el budget más amplio de las cinco fases; decisiones como tablas (option | tradeoff | decision); snippets de código solo para patrones no obvios.
- **Diagramas ASCII simples `[CERT]` `SKILL.md:181`:** claridad sobre belleza.
- **`rules.design` `[CERT]` `SKILL.md:182`:** aplicar reglas de `openspec/config.yaml`.

---

## 8.8 — Conexiones

- **[Bloque 6] (`sdd-propose`):** predecesor y dependencia **requerida**. design lee `sdd/{change-name}/proposal` y traduce su approach/scope en decisiones de arquitectura ADR. El `next_recommended` de propose lista design y spec como paralelos.
- **[Bloque 7] (`sdd-spec`):** par paralelo. design lee el spec **opcionalmente** (puede no existir si corren en paralelo, `SKILL.md:46`). spec = QUÉ, design = CÓMO.
- **[Bloque 9] (`sdd-tasks`):** sucesor. design **alimenta** tasks: tasks lee spec + design (ambos requeridos) y descompone el design en pasos de implementación accionables. `next_recommended: sdd-tasks` condicionado a spec listo `[CERT]` `agents/sdd-design.md:43`.
- **[Bloque 2] (DAG + Result Contract):** design es el segundo nodo de fan-in hacia tasks (junto a spec); envelope estándar con discrepancia `status`.
- **[Bloque 3 / Bloque 19] (backends + persistencia):** topic key `sdd/{change-name}/design`, `type: architecture`.
- **[Bloque 18] (delegación + models):** `opus` por decisiones de arquitectura — el segundo (y último) opus de las cinco fases de planificación.
- **[Bloque 16] (modos + Gatekeeper):** design es fase **high-risk**; en modo Automatic el Gatekeeper la valida con un reviewer de contexto fresco delegado, no inline, porque sus errores componen downstream. Es también gatillo recomendado de `judgment-day` post-design.
- **[Bloque 24] (judgment-day):** la regla de Agent Trigger recomienda fuertemente correr `judgment-day` tras completar la fase design (verificación adversarial de alto riesgo).
