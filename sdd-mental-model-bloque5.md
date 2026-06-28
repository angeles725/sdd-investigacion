# Bloque 5 — Fase `sdd-explore`

> **Qué documenta:** la fase de exploración del sistema SDD de gentle-ai — la investigación previa a comprometer un cambio: lee el codebase, compara enfoques y devuelve un análisis estructurado. Es la primera fase del DAG de planificación.
> **Alcance:** propósito, qué lee / qué escribe, inputs requeridos vs opcionales, los 6 pasos del proceso, formato de salida obligatorio, Result Contract, modelo asignado, reglas especiales (read-only).
> **Fuentes exactas leídas:**
> - `/home/cristian/.config/opencode/skills/sdd-explore/SKILL.md` (contrato runtime — primaria)
> - `/home/cristian/.claude/agents/sdd-explore.md` (definición del sub-agente: tools, modelo)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-explore.md` (prompt canónico — idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-explore.md` (comando del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (protocolo común)
> **Método + leyenda de marcadores:**
> - `[CERT]` = verificado leyendo el archivo, con cita `ruta:línea` o `ruta §sección`.
> - `[CERT-a]` = afirmado por una fuente, no re-verificado contra su origen primario.
> - `[INFER]` = deducción propia.

---

## 5.1 — Propósito y posición en el DAG `[CERT]`

`sdd-explore` es el sub-agente responsable de EXPLORACIÓN: investiga el codebase, piensa el problema, compara enfoques y devuelve un análisis estructurado `[CERT]` `SKILL.md:32-34`. Es la entrada del DAG de planificación: `explore → propose → spec → design → tasks` (ver [Bloque 2]).

Característica distintiva `[CERT]` `SKILL.md:34`: *"By default you only research and report back; only create `exploration.md` when this exploration is tied to a named change."* — explore es **opcionalmente sin artefacto**. Si es standalone (sin nombre de cambio) solo devuelve el análisis inline; si está atado a un cambio nombrado, persiste `exploration.md` / `sdd/{change-name}/explore`.

Es EXECUTOR: investiga y reporta, no delega `[CERT]` `agents/sdd-explore.md:11-12`.

### Gate orquestador/executor `[CERT]`

Mismo patrón que init: ORCHESTRATOR GATE (`SKILL.md:13-17`) + Executor Override (`SKILL.md:19-21`) `[CERT]`.

## 5.2 — Qué lee y qué escribe `[CERT]`

| Acción | Recurso | Topic key / ruta | Obligatoriedad |
|---|---|---|---|
| LEE | Contexto del proyecto | `sdd-init/{project}` (Engram) | **opcional** `[CERT]` `SKILL.md:46,55` |
| LEE | Artefactos SDD existentes | `sdd/` (Engram) | opcional `[CERT]` `SKILL.md:55` |
| LEE | (openspec) config + specs | `openspec/config.yaml`, `openspec/specs/` | condicional al modo `[CERT]` `SKILL.md:56` |
| LEE | Código real del codebase | filesystem | requerido `[CERT]` `SKILL.md:70-85` |
| ESCRIBE | Análisis de exploración | `sdd/{change-name}/explore` o `sdd/explore/{topic-slug}` (standalone) | **condicional** (solo si atado a cambio) `[CERT]` `SKILL.md:46,102` |

**Inputs requeridos del orquestador** `[CERT]` `SKILL.md:36-40`: un tópico/feature a explorar + el modo de artifact store. El comando además inyecta `$ARGUMENTS` (el tópico) `[CERT]` `commands/sdd-explore.md:13,22`.

**Inputs opcionales** `[CERT]`: `sdd-init/{project}` para contexto de proyecto — su ausencia no bloquea. Notablemente, explore **lee** vía Engram pero su frontmatter de agente NO incluye `mem_search`/`mem_get_observation` (ver §5.6) — la lectura de contexto Engram se hace con lo que el orquestador pasó en el prompt `[CERT]` `SKILL.md:57` ("Use whatever context the orchestrator passed in the prompt").

El save usa `type: architecture` `[CERT]` `SKILL.md:103`, `agents/sdd-explore.md:33`.

## 5.3 — Los 6 pasos del proceso `[CERT]`

`[CERT]` `SKILL.md:59-139`:

1. **Load Skills** — seguir Section A de `sdd-phase-common.md` `SKILL.md:61-62`.
2. **Understand the Request** — ¿feature nuevo? ¿bugfix? ¿refactor? ¿qué dominio toca? `SKILL.md:64-67`.
3. **Investigate the Codebase** — leer entry points y archivos clave; buscar funcionalidad relacionada; revisar tests existentes; mirar patrones en uso; identificar dependencias y acoplamiento `SKILL.md:70-85`.
4. **Analyze Options** — si hay múltiples enfoques, compararlos en tabla `Approach | Pros | Cons | Complexity` `SKILL.md:87-94`.
5. **Persist Artifact** — MANDATORIO si está atado a un cambio nombrado; artifact `explore`, `type: architecture` `SKILL.md:96-103`.
6. **Return Structured Analysis** — devolver EXACTAMENTE el formato de `SKILL.md:109-139` `SKILL.md:105-139`.

El bloque ASCII de investigación (paso 3) lista el método de barrido `[CERT]` `SKILL.md:78-85`:
```
INVESTIGATE:
├── Read entry points and key files
├── Search for related functionality
├── Check existing tests (if any)
├── Look for patterns already in use
└── Identify dependencies and coupling
```

## 5.4 — Formato de salida obligatorio `[CERT]`

El paso 6 exige devolver EXACTAMENTE esta estructura (y escribir lo mismo a `exploration.md` si se persiste) `[CERT]` `SKILL.md:107-139`:

- `## Exploration: {topic}`
- `### Current State` — cómo funciona el sistema hoy respecto al tópico.
- `### Affected Areas` — lista de `path/to/file.ext — {por qué afecta}`.
- `### Approaches` — enfoques numerados con **Pros / Cons / Effort (Low/Medium/High)**.
- `### Recommendation` — enfoque recomendado y por qué.
- `### Risks` — riesgos.
- `### Ready for Proposal` — `Yes/No` + qué debe decir el orquestador al usuario.

El campo `Ready for Proposal` es el handoff explícito hacia [Bloque 6]: explore decide si el material está maduro para formalizarse en propuesta `[INFER]`.

## 5.5 — Result Contract `[CERT]`

Doble capa: el envelope de `Section D` (común) más los campos del prompt del agente `[CERT]` `agents/sdd-explore.md:38-45`:

| Campo | Valores / contenido |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase con lo explorado + recomendación clave |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/explore`) |
| `next_recommended` | `sdd-propose` (si atado a cambio) o `none` (standalone) |
| `risks` | riesgos o bloqueos descubiertos |
| `skill_resolution` | `paths-injected` o `none` |

Misma discrepancia `status` que init: el agente declara `done` pero el Return Envelope común usa `success` `[CERT]` `sdd-phase-common.md:76` vs `agents/sdd-explore.md:40`.

El `next_recommended` codifica la bifurcación standalone vs. atado a cambio: standalone → `none` (termina el flujo); atado → `sdd-propose` `[CERT]` `agents/sdd-explore.md:43`.

## 5.6 — Modelo asignado y tools `[CERT]`

`model: sonnet` `[CERT]` `agents/sdd-explore.md:7`. La tabla de Model Assignments del orquestador lo justifica explícitamente: *"sdd-explore | sonnet | Reads code, structural - not architectural"* `[CERT-a]` (CLAUDE.md, Model Assignments). Razonamiento `[INFER]`: explore lee y compara pero NO toma decisiones de arquitectura comprometidas — eso es trabajo de propose/design (opus).

Tools `[CERT]` `agents/sdd-explore.md:8`: `Read, Grep, Glob, WebFetch, WebSearch, mcp__plugin_engram_engram__mem_save`.

**Gotcha de tools `[CERT]`:** explore es la **única** fase de planificación con `WebFetch` + `WebSearch` (puede investigar fuentes externas) y la única que tiene `mem_save` pero **NO** tiene `mem_search` ni `mem_get_observation`. Consecuencia: explore no puede recuperar artefactos Engram por sí mismo `[INFER]` — depende de que el orquestador le pase el contexto en el prompt (`SKILL.md:57`). Tampoco tiene Edit/Write de código, coherente con su naturaleza read-only.

## 5.7 — Reglas especiales y gotchas `[CERT]`

Reglas explícitas `[CERT]` `SKILL.md:141-149`:

- El ÚNICO archivo que PUEDE crear es `exploration.md` dentro de la carpeta del cambio (si hay nombre de cambio) `SKILL.md:143`.
- **NO** modifica código ni archivos existentes `SKILL.md:144` (reforzado en `agents/sdd-explore.md:26`).
- SIEMPRE lee código real, nunca adivina sobre el codebase `SKILL.md:145`.
- Mantener el análisis CONCISO — el orquestador necesita un resumen, no una novela `SKILL.md:146`.
- Si no hay info suficiente, decirlo claramente `SKILL.md:147`.
- Si el request es demasiado vago para explorar, decir qué clarificación falta `SKILL.md:148`.

Gates del comando `[CERT]` `commands/sdd-explore.md:15-19`: (1) Session Preflight completo; (2) `sdd-init` debe existir o correrse después del preflight (init guard); (3) usar el artifact store resuelto, no hardcodear Engram. La tarea es "exploración solamente: sin edits de archivos y sin implementación" `[CERT]` `commands/sdd-explore.md:22`.

Persistencia por modo `[CERT]` `SKILL.md:46-49`: engram → guarda `sdd/{change-name}/explore`; openspec → sigue `openspec-convention.md`; hybrid → ambos; none → solo inline.

---

## 5.8 — Conexiones

- **[Bloque 4] (`sdd-init`):** predecesor. explore lee `sdd-init/{project}` como contexto opcional; el init guard exige que init exista antes de explore `[CERT]` `commands/sdd-explore.md:18`.
- **[Bloque 6] (`sdd-propose`):** sucesor. El `Ready for Proposal: Yes/No` y `next_recommended: sdd-propose` son el handoff. propose lee opcionalmente `sdd/{change-name}/explore` como insumo `[CERT]` `skills/sdd-propose/SKILL.md:47`.
- **[Bloque 2] (DAG + Result Contract):** explore es el nodo raíz del subgrafo de planificación; devuelve el envelope estándar con la salvedad de `status`.
- **[Bloque 3 / Bloque 19] (backends + topic keys):** topic key `sdd/{change-name}/explore` (o `sdd/explore/{topic-slug}` standalone); modo de persistencia heredado del Session Preflight.
- **[Bloque 18] (delegación + models):** modelo `sonnet` por la tabla (structural, no architectural). Es la fase low-risk que el Gatekeeper valida inline (ver [Bloque 16]).
- **[Bloque 22] (skill-resolver + phase-common):** explore sigue Section A (skill loading), B (retrieval) y C (persistence) del protocolo común; `skill_resolution` reporta cómo se cargaron las skills.
- **[Bloque 14] (meta-comandos):** `/sdd-new` encadena explore → propose; `/sdd-explore <topic>` lanza solo esta fase en modo standalone.
