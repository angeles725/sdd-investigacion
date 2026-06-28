# Bloque 3 — Backends de artefactos (engram/openspec/hybrid/none) y topic keys

> **QUÉ DOCUMENTA**: Este bloque describe los cuatro backends donde el SDD persiste sus artefactos — `engram`, `openspec`, `hybrid`, `none` — sus roles, capacidades comparadas, cómo se resuelve el modo, el esquema de nombres (topic keys de engram y file paths de openspec), la persistencia de estado del DAG, y los protocolos de recuperación.
> **ALCANCE**: Resolución de modo, tabla comparativa de capacidades, comportamiento read/write por modo, formato de topic keys de engram, estructura de directorios de openspec, persistencia/recuperación de estado, y la limitación de upsert de engram. NO cubre el detalle interno de las convenciones (ver [Bloque 19] persistence-contract, [Bloque 20] engram-convention, [Bloque 21] openspec-convention) ni el DAG de fases (ver [Bloque 2]).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/CLAUDE.md` §"Artifact Store Policy", §"Artifact Store Mode", §"Engram Topic Key Format", §"Recovery Rule"
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` (completo)
> - `/home/cristian/.config/opencode/skills/_shared/engram-convention.md` (completo)
> - `/home/cristian/.config/opencode/skills/_shared/openspec-convention.md` (completo)
> **MÉTODO**: Marcadores de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección`. `[CERT-a]` = afirmado por una fuente, no re-verificado en origen primario. `[INFER]` = deducción propia.

---

## 3.1 — Los cuatro backends y sus roles `[CERT]`

El orquestador pasa `artifact_store.mode` con uno de: `engram | openspec | hybrid | none` `[CERT]` (`persistence-contract.md:5`).

Roles literales `[CERT]` (`persistence-contract.md:12-16`):

| Modo | Rol `[CERT]` |
|------|------|
| `engram` | Memoria de trabajo entre sesiones. Upserts sobreescriben — sin historial de iteración. Local, no compartible. |
| `openspec` | Fuente de verdad. Archivos en repo, historial git, compartible con el equipo, audit trail completo. |
| `hybrid` | Ambos — archivos para el equipo + engram para recuperación. Mayor costo de tokens. |
| `none` | Efímero. Se pierde cuando termina la conversación. |

Descripciones equivalentes desde la política `[CERT]` (`CLAUDE.md` §"Artifact Store Policy" / §"Artifact Store Mode"):
- `engram` — rápido, sin archivos creados; mejor para trabajo solo e iteración rápida; re-correr una fase sobreescribe (sin historial).
- `openspec` — file-based; crea directorio `openspec/` con trail completo; committeable, compartible, historial git.
- `hybrid` — ambos; mayor costo de tokens.
- `none` — devuelve resultados inline solo; recomienda habilitar engram u openspec.

## 3.2 — Resolución del modo `[CERT]`

Quién y cuándo elige el modo `[CERT]` (`persistence-contract.md:7`, `CLAUDE.md` §"Artifact Store Mode"): el orquestador PREGUNTA al usuario qué modo quiere cuando `/sdd-new`, `/sdd-ff` o `/sdd-continue` se invoca por primera vez en la sesión. La elección se cachea para la sesión.

Default si el usuario no especifica `[CERT]` (`persistence-contract.md:9`, `CLAUDE.md` §"Artifact Store Mode"): si Engram está disponible → `engram`. Si no → `none`.

Regla de seguridad `[CERT]` (`persistence-contract.md:74`): *"If unsure which mode to use, default to `none`"* — y NUNCA forzar creación de `openspec/` salvo que el orquestador haya pasado explícitamente `openspec` o `hybrid` (`persistence-contract.md:73`).

El modo se pasa como `artifact_store.mode` a cada lanzamiento de sub-agente `[CERT]` (`CLAUDE.md` §"Artifact Store Mode": "Pass it as `artifact_store.mode` to every sub-agent launch").

## 3.3 — Tabla comparativa de capacidades `[CERT]`

Comparación literal `[CERT]` (`persistence-contract.md:20-27`):

| Capacidad | `engram` | `openspec` | `hybrid` | `none` |
|-----------|----------|------------|----------|--------|
| Recuperación cross-session | ✅ | ❌ (necesita git) | ✅ | ❌ |
| Supervivencia a compactación | ✅ | ❌ | ✅ | ❌ |
| Compartible con equipo | ❌ (DB local) | ✅ (archivos committeados) | ✅ (archivos) | ❌ |
| Historial completo de iteración | ❌ (upsert sobreescribe) | ✅ (historial git) | ✅ (archivos + git) | ❌ |
| Audit trail (archive) | Parcial (solo reporte) | ✅ (carpeta completa) | ✅ (ambos) | ❌ |
| Archivos de proyecto creados | Nunca | Sí | Sí | Nunca |

**Lectura del modelo mental** `[INFER]`: hay un eje de tradeoff claro — `engram` gana en recuperación/compactación (memoria persistente del agente) pero pierde en compartir/historial; `openspec` es lo inverso (compartible y versionable, pero no sobrevive compactación sin git). `hybrid` paga ambos costos para tener ambas garantías. `none` no garantiza nada y es puramente efímero.

## 3.4 — Comportamiento read/write por modo `[CERT]`

De dónde lee y a dónde escribe cada modo `[CERT]` (`persistence-contract.md:35-40`):

| Modo | Lee de | Escribe a | Archivos de proyecto |
|------|--------|-----------|---------------------|
| `engram` | Engram | Engram | Nunca |
| `openspec` | Filesystem | Filesystem | Sí |
| `hybrid` | Engram (primario) + Filesystem (fallback) | Ambos | Sí |
| `none` | Contexto del prompt del orquestador | Ninguno | Nunca |

Detalle de hybrid `[CERT]` (`persistence-contract.md:42-52`): persiste cada artefacto a Engram Y OpenSpec simultáneamente. Prioridad de lectura: Engram primero, fallback a filesystem si Engram no devuelve resultados. Comportamiento de escritura: AMBAS escrituras deben tener éxito para que la operación esté completa. Advertencia de costo: hybrid consume MÁS tokens por operación.

Reglas comunes `[CERT]` (`persistence-contract.md:69-74`):
- `none` → NO crear ni modificar archivos de proyecto; devolver inline.
- `engram` → NO escribir archivos de proyecto; persistir a Engram y devolver IDs de observación.
- `openspec` → escribir archivos SOLO a los paths definidos en `openspec-convention.md`.
- `hybrid` → persistir a AMBOS Engram Y filesystem.

## 3.5 — El esquema de topic keys de engram `[CERT]`

Todo artefacto SDD persistido a Engram sigue un naming determinístico `[CERT]` (`engram-convention.md:9-16`):

```
title:     sdd/{change-name}/{artifact-type}
topic_key: sdd/{change-name}/{artifact-type}
type:      architecture
project:   {nombre de proyecto detectado o actual}
scope:     project
capture_prompt: false
```

El mapa de topic keys por artefacto `[CERT]` (`CLAUDE.md` §"Engram Topic Key Format"):

| Artefacto | Topic Key `[CERT]` | Producido por `[CERT]` (`engram-convention.md:22-32`) |
|-----------|-----------|-------------|
| Project context | `sdd-init/{project}` | sdd-init |
| Exploration | `sdd/{change-name}/explore` | sdd-explore |
| Proposal | `sdd/{change-name}/proposal` | sdd-propose |
| Spec | `sdd/{change-name}/spec` | sdd-spec (todos los dominios concatenados) |
| Design | `sdd/{change-name}/design` | sdd-design |
| Tasks | `sdd/{change-name}/tasks` | sdd-tasks |
| Apply progress | `sdd/{change-name}/apply-progress` | sdd-apply (uno por lote) |
| Verify report | `sdd/{change-name}/verify-report` | sdd-verify |
| Archive report | `sdd/{change-name}/archive-report` | sdd-archive |
| DAG state | `sdd/{change-name}/state` | orquestador |

Nota `[CERT]`: el project context usa el prefijo `sdd-init/{project}` (NO `sdd/`); todos los demás artefactos de un cambio usan `sdd/{change-name}/...`. `[CERT]` (`CLAUDE.md` §"Engram Topic Key Format" vs §"SDD Init Guard").

Por qué esta convención `[CERT]` (`engram-convention.md:138-144`):
- Títulos determinísticos → la recuperación funciona por match exacto.
- `topic_key` → habilita upserts sin duplicados.
- Prefijo `sdd/` → namespacea todos los artefactos SDD.
- Recuperación en dos pasos → los previews de búsqueda siempre están truncados; `mem_get_observation` es la única forma de obtener contenido completo.

## 3.6 — Estructura de archivos de openspec `[CERT]`

Estructura de directorios `[CERT]` (`openspec-convention.md:5-23`):

```
openspec/
├── config.yaml              <- Config SDD del proyecto
├── specs/                   <- Fuente de verdad (specs principales)
│   └── {domain}/spec.md
└── changes/                 <- Cambios activos
    ├── archive/             <- Cambios completados (YYYY-MM-DD-{change-name}/)
    └── {change-name}/       <- Carpeta de cambio activo
        ├── state.yaml       <- Estado del DAG (sobrevive compactación)
        ├── exploration.md   <- (opcional) de sdd-explore
        ├── proposal.md      <- de sdd-propose
        ├── specs/{domain}/spec.md  <- Delta spec, de sdd-spec
        ├── design.md        <- de sdd-design
        ├── tasks.md         <- de sdd-tasks (actualizado por sdd-apply)
        └── verify-report.md <- de sdd-verify
```

Paths por skill `[CERT]` (`openspec-convention.md:27-40`): cada fase escribe a su path canónico. Notas operativas:
- `sdd-apply` ACTUALIZA `tasks.md` marcando `[x]` (no crea archivo nuevo). `[CERT]`
- `sdd-archive` MUEVE la carpeta del cambio a `openspec/changes/archive/YYYY-MM-DD-{change-name}/` Y mergea los deltas en `openspec/specs/{domain}/spec.md`. `[CERT]`

Diferencia conceptual engram vs openspec `[INFER]`: en engram el spec es UN artefacto (`sdd/{change-name}/spec`, "todos los dominios concatenados", `engram-convention.md:26`); en openspec el spec se desglosa por dominio en subdirectorios (`specs/{domain}/spec.md`). Es la misma información con distinta granularidad de almacenamiento.

Regla de escritura `[CERT]` (`openspec-convention.md:54-58`): siempre crear el directorio del cambio antes de escribir; si un archivo ya existe, LEERLO primero y ACTUALIZARLO (no sobreescribir a ciegas); si la carpeta ya tiene artefactos, el cambio está siendo CONTINUADO.

## 3.7 — Persistencia y recuperación del estado del DAG `[CERT]`

El orquestador persiste el estado del DAG tras cada transición de fase para habilitar recuperación tras compactación `[CERT]` (`persistence-contract.md:54-63`):

| Modo | Persistir estado | Recuperar estado `[CERT]` |
|------|------------------|------------------|
| `engram` | `mem_save(topic_key: "sdd/{change-name}/state", capture_prompt: false)` | `mem_search("sdd/*/state")` → `mem_get_observation(id)` |
| `openspec` | Escribir `openspec/changes/{change-name}/state.yaml` | Leer `state.yaml` |
| `hybrid` | Ambos: `mem_save` Y escribir `state.yaml` | Engram primero; fallback filesystem |
| `none` | No es posible — avisar al usuario | No es posible |

Contenido del artefacto `state` en engram `[CERT]` (`engram-convention.md:38-46`): incluye `change`, `phase`, `artifact_store`, flags de `artifacts` (proposal/specs/design/tasks), `tasks_progress` (completed/pending) y `last_updated` (fecha ISO).

Recovery Rule global `[CERT]` (`CLAUDE.md` §"Recovery Rule"):
- `engram` → `mem_search(...)` → `mem_get_observation(...)`
- `openspec` → leer `openspec/changes/*/state.yaml`
- `none` → estado no persistido — explicar al usuario.

## 3.8 — La limitación de upsert de engram `[CERT]`

Engram usa upserts basados en `topic_key`. Re-correr una fase para el mismo cambio **SOBREESCRIBE** la versión previa — no se mantiene historial de revisiones `[CERT]` (`persistence-contract.md:29-31`).

Detalle `[CERT]` (`engram-convention.md:136`): mismo `topic_key` + `project` + `scope` → UPDATE (overwrite), no INSERT. El contenido previo se PIERDE — `revision_count` incrementa pero el contenido viejo NO se guarda. Es por diseño: engram es memoria de trabajo, no audit trail. Para historial de iteración o colaboración de equipo → usar `openspec` o `hybrid`.

La fase de archive en engram guarda un reporte resumen, NO la carpeta completa de artefactos `[CERT]` (`persistence-contract.md:31`).

**Consecuencia práctica** `[INFER]`: si necesitás trazabilidad de cómo evolucionó una propuesta o un spec a través de iteraciones, `engram` no sirve — sobreescribe. La elección de backend en §3.2 es, en el fondo, una decisión sobre cuánto historial y compartibilidad necesitás versus cuánto costo de tokens y archivos de proyecto estás dispuesto a pagar.

## 3.9 — Resolución del nombre de proyecto `[CERT]`

Engram auto-detecta el nombre de proyecto desde el git remote al arranque del MCP `[CERT]` (`engram-convention.md:128-132`). El flag `--project` y la env var `ENGRAM_PROJECT` pueden sobreescribir la detección. Todos los nombres se normalizan a lowercase y trimmed. Si se guarda bajo un nombre que no matchea observaciones existentes, engram avisa de posible "name drift"; se consolida con `mem_merge_projects` (MCP) o `engram projects consolidate` (CLI).

## 3.10 — Conexiones

- **[Bloque 2] — DAG de fases y Result Contract**: los topic keys de §3.5 y los file paths de §3.6 son los destinos donde cada fase del DAG (§2.2) persiste su artefacto. La persistencia obligatoria de §2.6 es backend-dependiente y aquí se detalla por modo.
- **[Bloque 19] — persistence-contract**: este bloque resume `persistence-contract.md`; el [Bloque 19] lo trata en profundidad, incluyendo las "Sub-Agent Context Rules" y las instrucciones de prompt del orquestador para sub-agentes.
- **[Bloque 20] — engram-convention**: profundiza el esquema de naming, el protocolo de recuperación en dos pasos, el comportamiento de upsert y la resolución de nombre de proyecto que aquí se resumen.
- **[Bloque 21] — openspec-convention**: detalla la estructura de directorios, las secciones de delta spec (`ADDED`/`MODIFIED`/`REMOVED`/`RENAMED`), y el `config.yaml` que aquí solo se mencionan.
- **[Bloque 1] — Qué es SDD**: la decisión de quién lee y quién escribe contexto (orquestador vs sub-agente, SDD vs no-SDD) introducida filosóficamente en §1.2 se materializa en el comportamiento read/write de §3.4.
