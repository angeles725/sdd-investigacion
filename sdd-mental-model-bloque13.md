# Bloque 13 — Fase `sdd-onboard`

> **QUÉ**: Documenta la fase `sdd-onboard` del sistema SDD de gentle-ai: el walkthrough guiado pedagógico. Lleva al usuario por un ciclo SDD completo — de explore a archive — usando su codebase REAL (no un ejemplo de juguete), narrando cada fase para enseñar "teach by doing".
>
> **ALCANCE**: Propósito, modo de ejecución inline (no delegado), las 10 fases del walkthrough, criterios para elegir el cambio de onboarding, narración pedagógica, qué escribe (artefacto + topic key), modelo asignado, Result Contract y gotchas. Es una fase META que orquesta el comportamiento de las otras fases inline, no las delega.
>
> **FUENTES exactas**:
> - `/home/cristian/.config/opencode/skills/sdd-onboard/SKILL.md` (primaria)
> - `/home/cristian/.claude/agents/sdd-onboard.md` (tools, modelo, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-onboard.md` (idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-onboard.md` (gates del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
>
> **MÉTODO**: lectura directa. Marcadores: `[CERT]` = verificado (`ruta:línea`); `[CERT-a]` = afirmado por fuente; `[INFER]` = deducción.

---

## 13.1 — Propósito y rol `[CERT]`

`sdd-onboard` guía al usuario por un ciclo SDD completo — de exploración a archive — usando su codebase real. "This is a real change with real artifacts, not a toy example. The goal is to teach by doing" (`skills/sdd-onboard/SKILL.md:30-32`).

Es la ÚNICA fase con un boundary distinto: el ORCHESTRATOR NOTE dice "This skill is designed to be executed INLINE by the orchestrator. It is an interactive walkthrough — no sub-agent delegation needed" (`SKILL.md:13-15`). El frontmatter lo refleja: `delegate_only: false` (`SKILL.md:10`) — el único `false` entre las fases documentadas. Igual existe el agente `sdd-onboard` para cuando SÍ se delega (`agents/sdd-onboard.md`), con su Executor Override estándar (`SKILL.md:17-19`).

Versión `1.0` (`SKILL.md:9`) — la más nueva/inmadura del set.

## 13.2 — Lo que recibe del orquestador `[CERT]`

`SKILL.md:34-38`: Artifact store mode (`engram | openspec | hybrid | none`); y opcionalmente una mejora sugerida o área de foco.

El comando del orquestador (`commands/sdd-onboard.md:14-20`) tiene gates mínimos: solo exige que el SDD Session Preflight esté completo (execution mode, artifact store, chained PR strategy, review budget) y usar el artifact store resuelto. Mantiene pausas user-facing en modo interactivo y enforce el review budget antes de apply.

## 13.3 — Las 10 fases del walkthrough `[CERT]`

`SKILL.md:42-220`. El onboard ejecuta INLINE el comportamiento de cada fase SDD, narrándolo:

| Fase | Qué hace | Narración (enseñanza) |
|------|----------|------------------------|
| **1. Welcome & Codebase Analysis** | saluda, escanea el codebase por una mejora real pequeña | "Let me scan your codebase for opportunities..." |
| **2. Explore** (narrado) | corre comportamiento `sdd-explore` inline; investiga el área elegida | "Before we commit to any change, we investigate" |
| **3. Propose** (narrado) | crea la carpeta del cambio + `proposal.md` formato `sdd-propose` | "We write down WHAT we're building and WHY... the contract" |
| **4. Specs** (narrado) | escribe delta specs formato `sdd-spec` | "Given/When/Then... each scenario is a potential test case" |
| **5. Design** (narrado) | escribe `design.md` formato `sdd-design` | "We decide HOW... document WHY over alternatives" |
| **6. Tasks** (narrado) | escribe `tasks.md` formato `sdd-tasks` | "'Implement feature' is not a task" |
| **7. Apply** (narrado) | implementa siguiendo `sdd-apply`; narra cada tarea | si Strict TDD: "RED → GREEN → TRIANGULATE → REFACTOR" |
| **8. Verify** (narrado) | corre `sdd-verify`; explica la compliance matrix | "Each scenario: COMPLIANT, FAILING, or UNTESTED" |
| **9. Archive** (narrado) | corre `sdd-archive`; mergea delta specs en main specs | "The change becomes the audit trail" |
| **10. Summary** | recap del ciclo + cuándo usar SDD + next steps | "explore → propose → spec → design → tasks → apply → verify → archive" |

> [CERT] La Fase 7 menciona el cycle de strict TDD con un paso extra TRIANGULATE: "RED → GREEN → TRIANGULATE → REFACTOR" (`SKILL.md:160-162`), narrado solo si Strict TDD está activo. El detalle del cycle vive en [Bloque 23].

## 13.4 — Criterios para elegir el cambio de onboarding `[CERT]`

`SKILL.md:56-68`. Un buen cambio de onboarding cumple:

```
├── Small scope — completable en una sesión (30-60 min)
├── Low risk — sin breaking changes, sin data migrations
├── Real value — algo genuinamente útil, no un juguete
├── Spec-worthy — al menos 1 requisito claro y 2 escenarios
└── Ejemplos:
    ├── Validación de input faltante en un form o API endpoint
    ├── Mensajes de error inconsistentes en un flujo de auth
    ├── Una utility function extraíble y reusable
    ├── Estado loading/error faltante en un componente async
    └── Un comentario TODO/FIXME con intención clara
```

Presenta 2-3 opciones al usuario; lo deja elegir o sugerir la suya (`SKILL.md:70`). Si el usuario elige la suya, validar que cumpla "small and safe" antes de proceder (`SKILL.md:227`).

## 13.5 — Qué ESCRIBE (artefacto + topic key) `[CERT]`

A diferencia de las otras fases (que escriben un artefacto por fase), onboard PRODUCE el conjunto completo de artefactos del ciclo inline: proposal, specs, design, tasks, código, verify, archive. Pero su artefacto de persistencia propio es distinto.

`agents/sdd-onboard.md:27-32`: tras completar, `mem_save` con:

- **title / topic_key**: `sdd-onboard/{project}` (NO `sdd/{change}/...` — usa el patrón `{project}`, igual que `sdd-init/{project}`)
- **type**: `architecture`
- **capture_prompt**: `false`

> [CERT] El topic key `sdd-onboard/{project}` ([Bloque 3]) es project-scoped, no change-scoped: registra que el proyecto pasó por onboarding, resumible entre sesiones (`agents/sdd-onboard.md:24` — "Save progress at each phase so the session is resumable").

## 13.6 — Narración pedagógica (reglas de tono) `[CERT]`

`SKILL.md:222-231`:

- Es un cambio REAL, no demo: artefactos y código deben ser production-quality (`SKILL.md:224`).
- Narración de cada fase CORTA — 1-3 frases. "Teach, don't lecture" (`SKILL.md:225`).
- SIEMPRE preguntar antes de pasar de la Fase 3 (proposal) — dejar al usuario revisar y ajustar (`SKILL.md:226`).
- Si el usuario elige su propia mejora, validar "small and safe" (`SKILL.md:227`).
- Si algo bloquea el ciclo (tests fallan, design poco claro, codebase muy complejo), STOP y explicar — no empujar (`SKILL.md:228`).
- Adaptar el tono: si el usuario es experimentado, saltar básicos; si es nuevo, explicar más (`SKILL.md:229`).
- Seguir TODAS las reglas de formato de los skills individuales (propose, spec, design, tasks, apply, verify, archive) (`SKILL.md:230`).

## 13.7 — La Fase 10: Summary `[CERT]`

`SKILL.md:191-220`. Cierra con un recap markdown ("Onboarding Complete! 🎉") que lista: change name, artefactos creados (proposal=WHY, specs=WHAT, design=HOW, tasks=STEPS), código cambiado, "the SDD cycle in one line", cuándo usar SDD ("Small tweaks? Just code. Features, APIs, architecture decisions? SDD first") y next steps (`/sdd-new`, revisar `openspec/specs/`).

> [CERT] El mantra pedagógico mapea cada artefacto a una pregunta: proposal→WHY, specs→WHAT, design→HOW, tasks→STEPS (`SKILL.md:202-205`). Es la síntesis didáctica de todo el ciclo SDD.

## 13.8 — Modelo asignado y tools `[CERT]`

`agents/sdd-onboard.md:7`: `model: haiku` (Model Assignments [Bloque 18]: "sdd-onboard | haiku | default | Guided walkthrough, pedagogical"). [INFER] Modelo barato porque la tarea es guía/copy pedagógico, no decisión arquitectónica — aunque ejecuta inline el comportamiento de fases que normalmente usan sonnet/opus.

**Tools** (`agents/sdd-onboard.md:8`): `Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update` — el set MÁS amplio de todas las fases (incluye Bash, Edit, Write, mem_update), [INFER] porque debe ejecutar el comportamiento de TODAS las fases inline (explorar, escribir artefactos, implementar código, correr tests, marcar tasks).

## 13.9 — Result Contract `[CERT]`

`agents/sdd-onboard.md:34-42`:

| Campo | Valor |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase de qué se onboardeó |
| `artifacts` | paths o topic_keys escritos |
| `next_recommended` | `sdd-new` (para arrancar un cambio real de forma independiente) |
| `risks` | warnings de la sesión de onboarding |
| `skill_resolution` | `paths-injected` o `none` |

`next_recommended: sdd-new` ([Bloque 14]): tras el walkthrough guiado, el usuario está listo para arrancar cambios reales por su cuenta.

## 13.10 — Gotchas `[CERT]`

- **`delegate_only: false` — única fase inline** (`SKILL.md:10-15`): se ejecuta dentro del orquestador como walkthrough interactivo, no como sub-agente delegado. Esto rompe el patrón "el orquestador delega todo" de las demás fases.
- **Cambio REAL, no demo** (`SKILL.md:224`): los artefactos y código son production-quality; el onboard no es un sandbox.
- **Pausa obligatoria tras Fase 3** (`SKILL.md:226`): a diferencia del flujo automático, onboard siempre pausa para revisión del proposal — es pedagógico por diseño.
- **Topic key project-scoped** (`agents/sdd-onboard.md:30`): `sdd-onboard/{project}`, no `sdd/{change}/...`; convive con el cambio real que también genera sus propios artefactos `sdd/{change}/*`.
- **STOP si algo bloquea** (`SKILL.md:228`): no empuja a través de tests que fallan o codebase complejo — prioriza la experiencia de aprendizaje sobre completar el ciclo.
- **El prompt `prompts/sdd/sdd-onboard.md` es byte-idéntico al SKILL.md** [CERT — comparado].
- **Versión 1.0** (`SKILL.md:9`): la más reciente; [INFER] menos endurecida que las fases core (apply/verify v3.0).

## 13.11 — Conexiones

- **[Bloque 5]–[Bloque 12]**: onboard ejecuta inline el comportamiento de explore ([Bloque 5]), propose ([Bloque 6]), spec ([Bloque 7]), design ([Bloque 8]), tasks ([Bloque 9]), apply ([Bloque 10]), verify ([Bloque 11]) y archive ([Bloque 12]) — es el recorrido completo del DAG ([Bloque 2]) en modo enseñanza.
- **[Bloque 13] → [Bloque 14] (meta-comandos)**: `next_recommended: sdd-new`; cierra apuntando a que el usuario arranque cambios reales con `/sdd-new`.
- **[Bloque 23] (strict-TDD)**: la Fase 7 narra RED→GREEN→TRIANGULATE→REFACTOR si Strict TDD está activo.
- **[Bloque 3] (backends + topic keys)**: artefacto `sdd-onboard/{project}` (project-scoped); produce además los artefactos `sdd/{change}/*` del ciclo real.
- **[Bloque 16] (modos)**: el comando mantiene pausas user-facing en modo interactivo y enforce el review budget antes de apply.
- **[Bloque 22] (phase-common)**: Return envelope per Sección D; el resto de fases inline siguen sus propias Secciones A–C.
- **[Bloque 18] (models)**: haiku, "Guided walkthrough, pedagogical".
