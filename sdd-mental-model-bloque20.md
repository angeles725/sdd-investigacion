# Bloque 20 — Convención Engram (`engram-convention`)

> **QUÉ DOCUMENTA**: Este bloque documenta la convención de artefactos Engram: las reglas de naming determinístico (title, topic_key, type, project, scope, capture_prompt), la tabla de tipos de artefacto SDD, el artefacto de estado del DAG, el protocolo de recuperación en dos pasos (`mem_search` → `mem_get_observation`), la escritura de artefactos (`mem_save` / `mem_update`), la resolución del nombre de proyecto, el comportamiento de upsert por `topic_key`, y las reglas de lifecycle (`active` / `needs_review`).
> **ALCANCE**: La convención específica del backend Engram. NO cubre el contrato de persistencia transversal (resolución de modos, hybrid, plantillas de prompt — ver [Bloque 19]) ni la convención OpenSpec (ver [Bloque 21]). NO documenta el detalle de cada fase que produce los artefactos (ver bloques de fase).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/skills/_shared/engram-convention.md` (archivo completo, 145 líneas)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por la fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 20.1 — Reglas de naming determinístico `[CERT]`

TODOS los artefactos SDD persistidos a Engram DEBEN seguir este naming determinístico `[CERT]` (`engram-convention.md:7-16`):

```
title:     sdd/{change-name}/{artifact-type}
topic_key: sdd/{change-name}/{artifact-type}
type:      architecture
project:   {nombre de proyecto detectado o actual}
scope:     project
capture_prompt: false
```

`capture_prompt: false` se setea cuando el schema de la herramienta Engram lo soporta; si un schema más viejo lo rechaza o no expone el campo, se omite en lugar de fallar `[CERT]` (`engram-convention.md:18`).

**Nota de diseño** `[CERT]` (`engram-convention.md:3`): los llamados críticos de Engram (`mem_search`, `mem_save`, `mem_get_observation`) están inlineados directamente en el `SKILL.md` de cada skill. Este documento es referencia suplementaria — los sub-agentes NO necesitan leerlo para funcionar.

## 20.2 — Tipos de artefacto `[CERT]`

| Artifact Type | Producido por | Descripción `[CERT]` (`engram-convention.md:22-32`) |
|---------------|---------------|-------------|
| `explore` | sdd-explore | Análisis de exploración |
| `proposal` | sdd-propose | Propuesta de cambio |
| `spec` | sdd-spec | Especificaciones delta (todos los dominios concatenados) |
| `design` | sdd-design | Diseño técnico |
| `tasks` | sdd-tasks | Desglose de tareas |
| `apply-progress` | sdd-apply | Progreso de implementación (uno por lote) |
| `verify-report` | sdd-verify | Reporte de verificación |
| `archive-report` | sdd-archive | Cierre de archive con lineage |
| `state` | orquestador | Estado del DAG para recuperación tras compactación |

**Punto clave** `[INFER]`: la nota "spec: todos los dominios concatenados" significa que en Engram el artefacto `spec` es un único blob con todos los dominios juntos, a diferencia de OpenSpec que los separa en subdirectorios por dominio (ver [Bloque 21]). Es la misma información estructurada de dos formas según el backend.

## 20.3 — El artefacto de estado (`state`) `[CERT]`

El estado del DAG se persiste como un artefacto Engram con su propio topic_key `[CERT]` (`engram-convention.md:38-47`):

```
mem_save(
  title: "sdd/{change-name}/state",
  topic_key: "sdd/{change-name}/state",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "change: {change-name}\nphase: {last-phase}\nartifact_store: engram\nartifacts:\n  proposal: true\n  specs: true\n  design: false\n  tasks: false\ntasks_progress:\n  completed: []\n  pending: []\nlast_updated: {ISO date}"
)
```

El `content` es YAML serializado: `change`, `phase` (última fase), `artifact_store`, un mapa `artifacts` con booleanos por fase, `tasks_progress` (completed/pending) y `last_updated` en ISO `[CERT]`.

**Recuperación del estado** `[CERT]` (`engram-convention.md:49`): `mem_search("sdd/{change-name}/state")` → `mem_get_observation(id)` → parsear YAML → restaurar estado.

## 20.4 — Protocolo de recuperación en dos pasos `[CERT]`

La recuperación de cualquier artefacto SDD es SIEMPRE de dos pasos, porque las previews de búsqueda están truncadas `[CERT]` (`engram-convention.md:61-64`):

```
Step 1: mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → preview truncado + ID
Step 2: mem_get_observation(id: {observation-id}) → contenido completo
```

Cuando se recuperan múltiples artefactos, se agrupan TODAS las búsquedas primero y luego TODAS las recuperaciones `[CERT]` (`engram-convention.md:66-78`):

```
STEP A — SEARCH (solo IDs):
  mem_search(query: "sdd/{change-name}/proposal", ...) → guardar ID
  mem_search(query: "sdd/{change-name}/spec", ...)     → guardar ID
  mem_search(query: "sdd/{change-name}/design", ...)   → guardar ID

STEP B — RETRIEVE FULL CONTENT (obligatorio):
  mem_get_observation(id: {proposal_id})
  mem_get_observation(id: {spec_id})
  mem_get_observation(id: {design_id})
```

Cargar el contexto de proyecto `[CERT]` (`engram-convention.md:80-84`):

```
mem_search(query: "sdd-init/{project}", project: "{project}") → ID
mem_get_observation(id) → contexto completo del proyecto
```

**Por qué dos pasos** `[CERT]` (`engram-convention.md:143`): las previews de búsqueda están SIEMPRE truncadas; `mem_get_observation` es la ÚNICA forma de obtener contenido completo. Saltarse el paso 2 produce salida incorrecta (ver también [Bloque 22] §22.2-B).

## 20.5 — Escritura de artefactos `[CERT]`

Escritura estándar `[CERT]` (`engram-convention.md:88-98`):

```
mem_save(
  title: "sdd/{change-name}/{artifact-type}",
  topic_key: "sdd/{change-name}/{artifact-type}",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "{contenido markdown completo}"
)
```

Ejemplo concreto — guardar una proposal para `add-dark-mode` `[CERT]` (`engram-convention.md:100-110`): `title`/`topic_key` = `"sdd/add-dark-mode/proposal"`, `project: "my-app"`.

`capture_prompt: false` es REQUERIDO para artefactos SDD cuando el schema lo soporta `[CERT]` (`engram-convention.md:112`). Engram v1.15.3 captura prompts de usuario por default para saves humanos/proactivos, pero los artefactos SDD son salidas automatizadas de pipeline. NO se infiere del `type`, porque tanto SDD como decisiones de arquitectura humanas usan `architecture`. Schema viejo → omitir en lugar de fallar.

**Update vs. save** `[CERT]` (`engram-convention.md:114-119`):

- `mem_update(id, content)` → cuando se tiene el ID exacto de la observación.
- `mem_save` con el mismo `topic_key` → para upserts.

**Browsing de todos los artefactos de un cambio** `[CERT]` (`engram-convention.md:121-126`): `mem_search(query: "sdd/{change-name}/", project: "{project}")` devuelve todos los artefactos de ese cambio.

## 20.6 — Resolución del nombre de proyecto (engram v1.11.0+) `[CERT]`

Engram auto-detecta el nombre de proyecto desde el git remote al arranque del MCP `[CERT]` (`engram-convention.md:128-132`). El flag `--project` y la env var `ENGRAM_PROJECT` pueden sobreescribir la detección. Todos los nombres se normalizan a lowercase y trimmed.

Si el agente guarda una memoria bajo un nombre de proyecto que no coincide con observaciones existentes, Engram advierte sobre potencial "name drift". Para fusionar variantes: `mem_merge_projects` (MCP tool) o `engram projects consolidate` (CLI) `[CERT]`.

## 20.7 — Comportamiento de upsert `[CERT]`

Mismo `topic_key` + `project` + `scope` → UPDATE (sobrescribe), NO INSERT `[CERT]` (`engram-convention.md:134-136`). El contenido previo se PIERDE — `revision_count` incrementa pero el contenido viejo NO se guarda.

Esto es **por diseño**: Engram es memoria de trabajo, NO un audit trail. Para historial de iteración o colaboración de equipo, usar `openspec` o `hybrid` (ver [Bloque 19] §19.2, [Bloque 21]).

**Modelo mental** `[INFER]`: la terna `topic_key + project + scope` es la clave primaria efectiva. Re-correr una fase SDD no acumula versiones — pisa la anterior. Esto es lo que hace que `engram` sea barato (sin explosión de duplicados) pero "amnésico" respecto al historial. La decisión de usar `topic_key` idéntico al `title` (§20.1) es lo que habilita el upsert sin duplicados.

## 20.8 — Reglas de lifecycle (`active` / `needs_review`) `[CERT]`

La convención fija un protocolo de lifecycle de memoria cuando Engram expone metadata/tooling de lifecycle `[CERT]` (`engram-convention.md:53-59`):

- Al inicio de sesión o antes de trabajo sensible a arquitectura, llamar `mem_review` con action `list` para el proyecto actual cuando la herramienta esté disponible.
- Si `mem_review` no está disponible, NO fallar la tarea. Continuar con `mem_context`/`mem_search` normal, y aún aplicar metadata de lifecycle de observaciones devueltas cuando esté presente.
- Las memorias `active` pueden usarse normalmente.
- Las memorias `needs_review` son **contexto stale, NO hechos confiables**.
- Surfacing: exponer el contexto `needs_review` y verificarlo contra evidencia actual antes de confiar en él.
- NO llamar `mem_review` con action `mark_reviewed` automáticamente. Solo llamar `mark_reviewed` tras confirmación explícita del usuario o vía un comando dedicado de mantenimiento de memoria.

**Punto clave** `[INFER]`: el lifecycle introduce una distinción de confianza dentro de la memoria — no toda observación recuperada es un hecho. `needs_review` es una señal de "esto puede estar desactualizado, verificalo antes de actuar". Y `mark_reviewed` está protegido contra automatización justamente para que el sistema no se auto-certifique memoria stale como confiable.

## 20.9 — Por qué esta convención `[CERT]`

La convención justifica sus decisiones `[CERT]` (`engram-convention.md:138-144`):

- Títulos determinísticos → la recuperación funciona por match exacto.
- `topic_key` → habilita upserts sin duplicados.
- Prefijo `sdd/` → namespacea todos los artefactos SDD.
- Recuperación en dos pasos → las previews de búsqueda siempre están truncadas; `mem_get_observation` es la única vía al contenido completo.
- Lineage → el `archive-report` incluye todos los IDs de observación para trazabilidad completa.

## 20.10 — Conexiones

- **[Bloque 3] — Backends y topic keys**: el [Bloque 3] introduce la tabla de topic keys a nivel conceptual; este bloque la detalla con el naming completo, el comportamiento de upsert y el lifecycle. El formato `sdd/{change-name}/{artifact-type}` es la pieza central compartida.
- **[Bloque 19] — Contrato de persistencia**: §19.5 (estado del DAG) y §19.7 (plantillas de `mem_save`) consumen esta convención. La limitación "upsert sobrescribe sin historial" de [Bloque 19] §19.2 es exactamente §20.7 de este bloque.
- **[Bloque 15] — Status (engram)**: el artefacto `state` de §20.3 alimenta la reconstrucción manual de status cuando el store es `engram` (el dispatcher nativo no observa Engram — ver [Bloque 22] §22.3). La recuperación de status engram usa el protocolo de dos pasos de §20.4.
- **[Bloque 21] — Convención OpenSpec**: el equivalente file-based de esta convención. La nota de §20.2 (spec concatenado vs. spec por dominio) marca la diferencia estructural entre ambos backends.
- **[Bloque 22] — phase-common**: el `sdd-phase-common.md` inlinea el protocolo de recuperación (§20.4) y persistencia (§20.5) que aquí se documenta como referencia.
