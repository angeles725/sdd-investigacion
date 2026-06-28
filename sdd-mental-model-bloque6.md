# Bloque 6 — Fase `sdd-propose`

> **Qué documenta:** la fase de propuesta del sistema SDD de gentle-ai — convierte la exploración (o input directo del usuario) en un `proposal.md` estructurado: intent, scope, capabilities, approach, risks, rollback y success criteria. Incluye la ronda de preguntas de producto que precede a la propuesta en modo interactivo.
> **Alcance:** propósito, qué lee / qué escribe, inputs, la ronda de preguntas (Step 0), los 6 pasos, la sección Capabilities como contrato con spec, Result Contract, modelo `opus` y por qué, gotchas (budget 450 palabras, rollback obligatorio).
> **Fuentes exactas leídas:**
> - `/home/cristian/.config/opencode/skills/sdd-propose/SKILL.md` (contrato runtime — primaria)
> - `/home/cristian/.claude/agents/sdd-propose.md` (definición del sub-agente: tools, modelo)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-propose.md` (prompt canónico — idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` (protocolo común)
> - (NO existe `commands/sdd-propose.md` — propose se invoca vía meta-comandos, no comando directo `[CERT]` `ls commands/`)
> **Método + leyenda de marcadores:**
> - `[CERT]` = verificado leyendo el archivo, cita `ruta:línea` o `ruta §sección`.
> - `[CERT-a]` = afirmado por una fuente, no re-verificado.
> - `[INFER]` = deducción propia.

---

## 6.1 — Propósito y posición en el DAG `[CERT]`

`sdd-propose` toma el análisis de exploración (o input directo del usuario) y produce un `proposal.md` estructurado dentro de la carpeta del cambio `[CERT]` `SKILL.md:32-34`. En el DAG es el nodo que sigue a explore y precede a spec **y** design (ambos dependen del proposal): `explore → proposal → {spec, design}` `[CERT]` `agents/sdd-propose.md:56` (*"next_recommended: sdd-spec and sdd-design (can run in parallel)"*).

Es la **primera fase arquitectónica**: a diferencia de explore (que solo investiga), propose compromete intent, scope y approach. Por eso corre en `opus` (ver §6.7).

Es EXECUTOR `[CERT]` `agents/sdd-propose.md:10-11`. Mismo gate orquestador/executor que el resto `[CERT]` `SKILL.md:13-21`.

**No tiene comando directo `[CERT]`:** no existe `commands/sdd-propose.md`. Se lanza vía meta-comandos del orquestador (`/sdd-new`, `/sdd-ff`, `/sdd-continue`) — ver [Bloque 14].

## 6.2 — Qué lee y qué escribe `[CERT]`

| Acción | Recurso | Topic key / ruta | Obligatoriedad |
|---|---|---|---|
| LEE | Exploración previa | `sdd/{change-name}/explore` | **opcional** `[CERT]` `SKILL.md:47` |
| LEE | Contexto de proyecto | `sdd-init/{project}` | opcional `[CERT]` `SKILL.md:47` |
| LEE | (openspec) specs existentes | `openspec/specs/` | condicional al modo `[CERT]` `SKILL.md:86-87` |
| ESCRIBE | Propuesta | `sdd/{change-name}/proposal` (Engram) / `openspec/changes/{change-name}/proposal.md` | **requerido** `[CERT]` `SKILL.md:47,163-170` |

**Inputs requeridos del orquestador** `[CERT]` `SKILL.md:36-41`: nombre del cambio (ej. `add-dark-mode`); el análisis de exploración (de sdd-explore) **O** descripción directa del usuario; el modo de artifact store.

**Inputs opcionales** `[CERT]`: explore y contexto de proyecto — ambos opcionales, su ausencia no bloquea (propose puede partir de input directo).

Save con `type: architecture` `[CERT]` `SKILL.md:170`, `agents/sdd-propose.md:46`. Regla: nunca forzar creación de `openspec/` salvo que el usuario pida persistencia file-based o el modo sea hybrid `[CERT]` `SKILL.md:51`.

## 6.3 — La ronda de preguntas de producto (Step 0) `[CERT]`

Esta es la pieza distintiva de propose. En modo SDD interactivo, el executor **NO** debe decidir en silencio si la propuesta está "lo suficientemente clara": debe ofrecer al usuario una *proposal question round* antes de finalizar `[CERT]` `SKILL.md:55-69`, `agents/sdd-propose.md:15-27`.

Propósito explícito `[CERT]` `SKILL.md:57`: las preguntas mejoran el PRD/propuesta descubriendo reglas de negocio, implicaciones, impacto, edge cases y tradeoffs de producto. El usuario puede responder, saltear, corregir el encuadre o pedir una segunda ronda.

Las preguntas cubren entendimiento de **negocio/producto/PRD, no mecánica del harness** `[CERT]` `SKILL.md:58`. El subconjunto útil más pequeño de 10 ejes `[CERT]` `SKILL.md:58-68`:

1. **business problem** — qué dolor, oportunidad, confusión de usuario o costo operativo lo justifica ahora.
2. **target users and situations** — quién es afectado, en qué workflow, en qué momento, con qué urgencia.
3. **business rules** — políticas, permisos, thresholds, reglas de ciclo de vida, compliance/seguridad, invariantes del dominio.
4. **product outcome** — qué debería sentirse, funcionar o volverse posible.
5. **current-state gap** — qué está mal, inconsistente, ad hoc o difícil de explicar hoy.
6. **implications and impact** — qué equipos, workflows, data, UX, soporte o procesos se ven afectados.
7. **edge cases** — empty states, datos parciales, fallos, permisos, slow paths, clientes inusuales, migraciones, necesidades en conflicto.
8. **decision gaps** — qué incógnitas de producto vuelven la propuesta ambigua o fácil de sobre-construir.
9. **scope boundaries and non-goals** — qué entra en el primer slice, qué es refinamiento posterior, qué debe quedar intacto.
10. **business risk or tradeoff** — qué downside importa más si se elige la dirección equivocada.

Cadencia `[CERT]` `SKILL.md:69`: **3–5 preguntas concretas por ronda**. Tras las primeras respuestas, resumir las assumptions resultantes y preguntar si el usuario quiere corregir algo o correr una segunda ronda. **NO** preguntar por test commands, forma del PR, budget de líneas u otras decisiones del harness salvo que el usuario lo pida.

**Fallback si está bloqueado de preguntar `[CERT]` `SKILL.md:69`:** escribir una sección `## Proposal question round` en el resultado de la propuesta con las preguntas propuestas y las assumptions que necesitan revisión del usuario. Esto preserva la intención incluso en modo no interactivo `[INFER]`.

## 6.4 — La sección Capabilities: el contrato con spec `[CERT]`

El `proposal.md` (Step 4) tiene una sección **Capabilities** que es literalmente *"the CONTRACT between proposal and specs phases"* `[CERT]` `SKILL.md:114-118`. El agente sdd-spec la lee para saber exactamente qué archivos de spec crear o actualizar.

Dos sub-secciones `[CERT]` `SKILL.md:120-130`:

- **New Capabilities** — capabilities introducidas; cada una se vuelve un nuevo `openspec/specs/<name>/spec.md` (spec completo). Nombres en kebab-case (`user-auth`, `data-export`).
- **Modified Capabilities** — capabilities existentes cuyos REQUISITOS cambian (no solo implementación); cada una necesita un delta spec.

Reglas de refuerzo `[CERT]` `SKILL.md:201-204`: SIEMPRE llenar Capabilities investigando primero `openspec/specs/` para usar nombres correctos; si nada cambia a nivel spec (refactor puro, cambio de config) escribir explícitamente "None" en ambas sub-secciones — no dejar placeholders.

## 6.5 — Estructura completa del `proposal.md` `[CERT]`

`[CERT]` `SKILL.md:95-161`:

- `## Intent` — qué problema, por qué ahora.
- `## Scope` → `### In Scope` / `### Out of Scope` (explícito qué NO se hace).
- `## Capabilities` → New / Modified (el contrato §6.4).
- `## Approach` — approach técnico de alto nivel, referenciando la recomendación de exploración.
- `## Affected Areas` — tabla `Area | Impact (New/Modified/Removed) | Description`.
- `## Risks` — tabla `Risk | Likelihood | Mitigation`.
- `## Rollback Plan` — cómo revertir; **obligatorio** `[CERT]` `SKILL.md:197`.
- `## Dependencies` — prerequisitos externos.
- `## Success Criteria` — checklist medible; **obligatorio** `[CERT]` `SKILL.md:198`.

## 6.6 — Los 6 pasos + Result Contract `[CERT]`

Pasos `[CERT]` `SKILL.md:55-172`: Step 0 (ronda de preguntas) → Step 1 (load skills) → Step 2 (crear directorio del cambio solo en openspec/hybrid) → Step 3 (leer specs existentes) → Step 4 (escribir `proposal.md`) → Step 5 (persistir, MANDATORIO) → Step 6 (return summary).

Result Contract `[CERT]` `agents/sdd-propose.md:51-58`:

| Campo | Valores / contenido |
|---|---|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase de la propuesta |
| `artifacts` | topic_keys/paths (`sdd/{change-name}/proposal`) |
| `next_recommended` | `sdd-spec` **y** `sdd-design` (pueden correr en paralelo) |
| `risks` | preguntas abiertas, tradeoffs no resueltos, dependencias bloqueantes |
| `skill_resolution` | `paths-injected` o `none` |

El return summary del SKILL (Step 6) adicionalmente reporta `Risk Level: {Low/Medium/High}` y *"Ready for specs (sdd-spec) or design (sdd-design)"* `[CERT]` `SKILL.md:176-190`. Misma discrepancia `status` (`done` vs `success` común) que en init/explore.

## 6.7 — Modelo asignado: `opus` `[CERT]`

`model: opus` `[CERT]` `agents/sdd-propose.md:6`. La tabla del orquestador lo justifica: *"sdd-propose | opus | Architectural decisions"* `[CERT-a]` (CLAUDE.md, Model Assignments). Razonamiento `[INFER]`: propose es el primer punto donde se compromete una dirección de producto y arquitectura (intent, scope boundaries, approach, tradeoffs) — decisiones que se propagan a spec, design, tasks y apply. Un error aquí compone downstream, por eso usa el modelo de mayor capacidad de razonamiento.

Tools `[CERT]` `agents/sdd-propose.md:7`: `Read, Edit, Write, Grep, Glob` + `mem_search, mem_get_observation, mem_save`. A diferencia de explore, propose SÍ tiene `mem_search`/`mem_get_observation` (debe recuperar la exploración y el contexto de proyecto desde Engram).

## 6.8 — Gotchas y reglas especiales `[CERT]`

- **Size budget de 450 palabras `[CERT]` `SKILL.md:205`:** el artefacto de propuesta DEBE estar bajo 450 palabras. Bullets y tablas sobre prosa. *"Headers organize, not explain."* Es la fase con el budget más ajustado de las cinco.
- **Rollback + Success Criteria obligatorios `[CERT]` `SKILL.md:197-198`:** toda propuesta DEBE tener plan de rollback y criterios de éxito.
- **Update si ya existe `[CERT]` `SKILL.md:195`:** si la carpeta del cambio ya tiene un proposal, LEERLO primero y ACTUALIZARLO (no duplicar).
- **Capabilities = "None" explícito `[CERT]` `SKILL.md:204`:** refactor/config puro debe escribir "None", nunca dejar el placeholder del template.
- **`rules.proposal` `[CERT]` `SKILL.md:200`:** aplicar reglas de `openspec/config.yaml` si existen.
- **Conciso `[CERT]` `SKILL.md:196`:** la propuesta es *"a thinking tool, not a novel"*.

---

## 6.9 — Conexiones

- **[Bloque 5] (`sdd-explore`):** predecesor. propose lee opcionalmente `sdd/{change-name}/explore` y referencia su recomendación en la sección Approach `[CERT]` `SKILL.md:47,134`.
- **[Bloque 7] (`sdd-spec`):** sucesor directo. La sección **Capabilities** del proposal es el contrato que spec consume para decidir qué specs crear/modificar (`SKILL.md:114-118`). spec lee `sdd/{change-name}/proposal` como dependencia **requerida**.
- **[Bloque 8] (`sdd-design`):** sucesor paralelo a spec. design lee `sdd/{change-name}/proposal` (requerido) y `sdd/{change-name}/spec` (opcional). El `next_recommended` declara que spec y design pueden correr en paralelo `[CERT]` `agents/sdd-propose.md:56`.
- **[Bloque 2] (DAG + Result Contract):** propose es el nodo de fan-out (un padre, dos hijos spec/design).
- **[Bloque 3 / Bloque 19] (backends + persistencia):** topic key `sdd/{change-name}/proposal`, `type: architecture`.
- **[Bloque 18] (delegación + models):** modelo `opus` por decisiones arquitectónicas; primera fase de la tabla que escala a opus.
- **[Bloque 16] (modos + Gatekeeper):** la ronda de preguntas (Step 0) es lo que el orquestador en modo Interactive expone antes de propose; el Gatekeeper valida la propuesta inline como fase low-risk salvo "smell".
- **[Bloque 14] (meta-comandos):** propose no tiene comando directo; se orquesta vía `/sdd-new`, `/sdd-ff`, `/sdd-continue`.
