# Bloque 12 — Fase `sdd-archive`

> **QUÉ**: Documenta la fase `sdd-archive` del sistema SDD de gentle-ai: el cierre del ciclo. Mergea los delta specs en las specs principales (source of truth), mueve la carpeta del cambio al archivo con prefijo de fecha, y persiste un archive-report con trazabilidad. Es estricto: bloquea ante tareas sin completar o issues CRITICAL en verify.
>
> **ALCANCE**: Propósito, qué lee/escribe (artefacto + topic key), la Task Completion Gate, la Strict-vs-OpenSpec Archive Policy, el merge de delta specs (ADDED/MODIFIED/REMOVED/RENAMED), el movimiento a archive, verificación, modelo asignado, Result Contract y gotchas.
>
> **FUENTES exactas**:
> - `/home/cristian/.config/opencode/skills/sdd-archive/SKILL.md` (primaria)
> - `/home/cristian/.claude/agents/sdd-archive.md` (tools, modelo, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-archive.md` (idéntico al SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-archive.md` (gates del orquestador)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
>
> **MÉTODO**: lectura directa. Marcadores: `[CERT]` = verificado (`ruta:línea`); `[CERT-a]` = afirmado por fuente; `[INFER]` = deducción.

---

## 12.1 — Propósito y rol `[CERT]`

`sdd-archive` es el sub-agente EJECUTOR responsable de ARCHIVAR. Mergea los delta specs en las main specs (source of truth), luego mueve la carpeta del cambio al archivo. Completa el ciclo SDD (`skills/sdd-archive/SKILL.md:32-34`). Mismo patrón gate/override (`SKILL.md:13-21`). Versión `2.0`.

El archive cierra el DAG ([Bloque 2]): `proposal → specs → tasks → apply → verify → archive`. Tras archive, "Ready for the next change" (`SKILL.md:191-192`).

## 12.2 — Lo que recibe del orquestador `[CERT]`

`SKILL.md:36-42`: Change name; Artifact store mode; Structured status de `sdd-status-contract.md` (artifact paths, task progress, dependency states, actionContext); y cualquier texto explícito de override de archivo intencional del usuario/orquestador.

## 12.3 — Qué LEE y qué ESCRIBE `[CERT]`

`SKILL.md:44-51`:

| Modo | Lee (todos requeridos) | Escribe |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `/spec`, `/design`, `/tasks`, `/verify-report` (registra TODOS los observation IDs para trazabilidad) | `sdd/{change}/archive-report` |
| `openspec` | sigue `openspec-convention.md` | merge de specs + movimiento de carpeta a archive |
| `hybrid` | ambos | Engram (report con IDs) + merge filesystem + movimiento de carpeta |
| `none` | retorna solo closure summary | nada (sin operaciones de archivo) |

**Artefacto producido**: `archive-report` · **topic key**: `sdd/{change-name}/archive-report` · **type**: `architecture` (`SKILL.md:160-163`, [Bloque 3]).

> [CERT] Es la única fase que LEE el `verify-report` (`agents/sdd-archive.md:25`): necesita confirmar que la verificación pasó antes de cerrar. En engram registra los observation IDs de los 5 artefactos en el report para que el archive sea un audit trail navegable.

## 12.4 — Task Completion Gate `[CERT]`

La guarda de entrada más importante. `sdd-apply` ([Bloque 10]) es responsable de marcar tareas completas; `sdd-archive` VALIDA que el artefacto persistido refleje el estado final antes de cerrar (`SKILL.md:53-56`).

Antes de sincronizar specs o mover cualquier carpeta, inspecciona el artefacto tasks (engram: lee la observación `sdd/{change}/tasks`; openspec/hybrid: lee `tasks.md`). Si alguna tarea de implementación sigue sin marcar (`- [ ]`) (`SKILL.md:62-68`):

1. STOP y retornar `blocked`; NO sincronizar specs, NO mover la carpeta, NO reclamar ciclo completo.
2. Reportar que `sdd-apply` debe re-correr o corregirse para marcar las tareas.
3. Solo proceder si el orquestador instruye EXPLÍCITAMENTE reconciliar checkboxes stale Y `apply-progress`/`verify-report` prueban que cada tarea sin marcar está completa. Si se hace esta reparación excepcional, registrar la razón exacta en el archive report.

> [CERT] "The archived audit trail MUST NOT contain stale unchecked tasks for completed work. Internal todo state is not enough; the persisted SDD task artifact is the source of truth for completion visibility" (`SKILL.md:68`).

## 12.5 — Strict-vs-OpenSpec Archive Policy `[CERT]`

OpenSpec permite archivar con artefactos/tareas incompletas tras una confirmación del usuario. gentle-ai es MÁS ESTRICTO por defecto (`SKILL.md:70-77`):

- Tareas de implementación incompletas BLOQUEAN el archivo, salvo que sean checkboxes stale y apply-progress/verify-report prueben completitud.
- **Issues CRITICAL en `verify-report` SIEMPRE bloquean el archivo. NO se acepta override para issues CRITICAL de verificación** (`SKILL.md:75`).
- `sdd-archive` NO es dueño de la completitud normal de tasks: `sdd-apply` posee el marcado de checkboxes; archive solo hace reconciliación mecánica excepcional con prueba de apply-progress y verify-report.
- Artefactos proposal/spec/design faltantes deben reportarse. El archivo continúa solo si el usuario elige explícitamente un partial archive intencional Y el report registra qué faltaba.

Esto se refuerza en las Rules (`SKILL.md:196-205`): "NEVER archive a change that has CRITICAL issues in its verification report"; "NEVER archive completed work while `tasks.md` / the tasks observation still shows stale unchecked implementation tasks". El comando del orquestador lo duplica como hard gate: "If verify-report contains CRITICAL issues, do NOT archive. There is no CRITICAL override" (`commands/sdd-archive.md:28`).

## 12.6 — Step 2: Sync Delta Specs to Main Specs `[CERT]`

El paso distintivo del archive — la consolidación del source of truth. NO empieza hasta que pase la Task Completion Gate (`SKILL.md:89-91`).

- **`engram`**: skip filesystem sync — los artefactos viven solo en Engram; el archive report registra los observation IDs (`SKILL.md:93`).
- **`none`**: skip — no hay artefactos que sincronizar.
- **`openspec`/`hybrid`**: por cada delta spec en `openspec/changes/{change}/specs/` (`SKILL.md:97-126`):

### Si la main spec existe (`openspec/specs/{domain}/spec.md`) `[CERT]`

Lee la main spec existente y aplica el delta (`SKILL.md:103-116`):

| Sección del delta | Acción sobre la main spec |
|-------------------|---------------------------|
| **ADDED** Requirements | Append a la sección Requirements |
| **MODIFIED** Requirements | Replace el requisito que matchea |
| **REMOVED** Requirements | Delete tras registrar Reason/Migration |
| **RENAMED** Requirements | Rename preservando scenarios salvo que el delta los modifique |

Merge cuidadoso (`SKILL.md:111-116`): matchear requisitos por nombre (ej. "### Requirement: Session Expiration"); **PRESERVAR todos los OTROS requisitos que no estén en el delta**; mantener formato Markdown y jerarquía de headings; para REMOVED exigir notas `(Reason: ...)` y `(Migration: ...)` antes de borrar; para RENAMED exigir nombres viejo y nuevo explícitos.

### Si la main spec NO existe `[CERT]`

El delta spec ES una spec completa (no un delta). Se copia directo: `openspec/changes/{change}/specs/{domain}/spec.md → openspec/specs/{domain}/spec.md` (`SKILL.md:118-126`).

> [CERT] "ALWAYS sync delta specs BEFORE moving to archive" (`SKILL.md:200`). "When merging into existing specs, PRESERVE requirements not mentioned in the delta" (`SKILL.md:201`). Si el merge fuera destructivo (remover secciones grandes), WARN al orquestador y pedir confirmación (`SKILL.md:203`).

## 12.7 — Step 3: Move to Archive `[CERT]`

`SKILL.md:128-141`. En `engram`/`none` se saltea (no hay directorios `openspec/`; el report en Engram es el audit trail). En `openspec`/`hybrid` mueve la carpeta entera con prefijo de fecha ISO:

```
openspec/changes/{change-name}/
  → openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Fecha ISO de hoy (ej. `2026-02-16`) (`SKILL.md:141, 202`). Si `openspec/changes/archive/` no existe, crearla (`SKILL.md:205`).

## 12.8 — Step 4: Verify Archive `[CERT]`

`SKILL.md:143-154`. En `openspec`/`hybrid` confirma: main specs actualizadas; carpeta movida a archive; archive contiene todos los artefactos (proposal, specs, design, tasks); `tasks.md` archivado sin tareas de implementación sin marcar (salvo reconciliación aprobada); el directorio de changes activos ya no tiene este cambio. En `engram` confirma que todos los observation IDs están registrados y la observación tasks no tiene tareas sin marcar (salvo reconciliación aprobada).

> [CERT] "The archive is an AUDIT TRAIL — never delete or modify archived changes" (`SKILL.md:204`).

## 12.9 — Action Context Guard `[CERT]`

`SKILL.md:79-82`: si el structured status reporta `actionContext.mode: workspace-planning`, STOP — no mover cambios de workspace a archivos repo-locales ni editar repos enlazados. Si `allowedEditRoots` está presente, las operaciones de archive deben quedar dentro de esos roots.

## 12.10 — Modelo asignado y tools `[CERT]`

`agents/sdd-archive.md:7`: `model: haiku` (Model Assignments [Bloque 18]: "sdd-archive | haiku | default | Copy and close"). Es la fase más barata junto con onboard — el trabajo es mecánico (copiar, mover, registrar).

**Tools** (`agents/sdd-archive.md:8`): `Read, Edit, Write, Glob, mem_search, mem_get_observation, mem_save`. Notar: tiene `Edit`/`Write` (para el merge de specs y mover archivos vía edición), pero NO `Bash` (no ejecuta comandos shell para el `mv` — [INFER] usa Read+Write para reconstruir/mover), NO `Grep`, NO `mem_update`.

## 12.11 — Result Contract `[CERT]`

El **agente** (`agents/sdd-archive.md:40-48`):

| Campo | Valor |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | una frase confirmando que el cambio está archivado y cerrado |
| `artifacts` | topic_keys/paths (ej. `sdd/{change}/archive-report`, ruta de carpeta archivada) |
| `next_recommended` | `none` (cambio completo) o un nuevo `/sdd-new` si hay follow-up |
| `risks` | artefactos que no se pudieron mergear o archivar limpiamente |
| `skill_resolution` | `paths-injected` o `none` |

El **SKILL.md** (`SKILL.md:165-193`) define un "Change Archived" markdown más rico: Specs Synced (tabla domain/action/details), Archive Contents (checklist), Source of Truth Updated, "SDD Cycle Complete". `next_recommended: none` cierra el ciclo.

## 12.12 — Gotchas `[CERT]`

- **CRITICAL en verify-report = bloqueo sin override** (`SKILL.md:75, 197`): a diferencia de otras condiciones, no hay forma de saltar un CRITICAL de verificación. Es el cierre del contrato de calidad de [Bloque 11].
- **Tareas `- [ ]` stale bloquean** (`SKILL.md:62-68`): el archive valida pero NO marca; el marcado es de `sdd-apply` ([Bloque 10]). La reconciliación mecánica es excepcional y requiere prueba + razón registrada.
- **PRESERVE requirements no mencionados en el delta** (`SKILL.md:201`): el merge es aditivo/selectivo, no un overwrite de la main spec. REMOVED exige Reason+Migration; RENAMED exige nombres explícitos.
- **gentle-ai > OpenSpec en estrictez** (`SKILL.md:70-77`): OpenSpec permite archivar incompleto tras confirmación; gentle-ai bloquea por defecto.
- **El prompt `prompts/sdd/sdd-archive.md` es byte-idéntico al SKILL.md** [CERT — comparado]: sin versión condensada divergente (a diferencia de apply/verify).
- **haiku como modelo** (`agents/sdd-archive.md:7`): el merge de specs es delicado pero mecánico; [INFER] el riesgo de un merge destructivo se mitiga con la regla "WARN si destructivo" (`SKILL.md:203`) más que con un modelo más potente.

## 12.13 — Conexiones

- **[Bloque 11] (verify)** → `sdd-archive` lee `verify-report`; CRITICAL bloquea sin override (`SKILL.md:75`, `agents/sdd-archive.md:25`). Hereda la Task Completion Gate de la verificación.
- **[Bloque 12] → [Bloque 3] (backends + topic keys)**: en engram registra observation IDs de los 5 artefactos; en openspec mueve carpetas. Artefacto `archive-report` → `sdd/{change}/archive-report`.
- **[Bloque 12] → [Bloque 21] (openspec-convention)**: el merge de delta specs (ADDED/MODIFIED/REMOVED/RENAMED) y el movimiento a `archive/YYYY-MM-DD-{change}/` siguen la convención OpenSpec.
- **[Bloque 10] (apply)** → es el dueño del marcado de tasks; archive solo valida. Reconciliación stale requiere apply-progress como prueba.
- **[Bloque 2] (DAG)**: archive es el nodo terminal; `next_recommended: none`.
- **[Bloque 22] (phase-common + status-contract)**: Secciones A–D + Action Context Guard (`workspace-planning`, `allowedEditRoots`).
- **[Bloque 18] (models)**: haiku, "Copy and close".
