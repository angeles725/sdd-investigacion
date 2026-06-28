# Bloque 19 — Contrato de persistencia (`persistence-contract`)

> **QUÉ DOCUMENTA**: Este bloque documenta el contrato de persistencia compartido por TODAS las skills SDD: cómo se resuelve el modo de almacenamiento (`engram | openspec | hybrid | none`), qué rol cumple cada modo, el comportamiento de lectura/escritura por modo, la persistencia y recuperación del estado del DAG, las reglas de quién lee y quién escribe contexto entre orquestador y sub-agentes, y el ordenamiento de respuesta de los sub-agentes.
> **ALCANCE**: El contrato transversal de persistencia. NO desarrolla el detalle de la convención Engram (formato de topic keys, upsert, lifecycle — ver [Bloque 20]) ni la convención OpenSpec (estructura de directorios, state.yaml, delta specs — ver [Bloque 21]); este bloque las referencia y coordina. NO cubre las fases individuales (ver [Bloque 2] y bloques de fase).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` (archivo completo, 159 líneas)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por la fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 19.1 — Resolución del modo de persistencia `[CERT]`

El orquestador pasa `artifact_store.mode` con uno de cuatro valores: `engram | openspec | hybrid | none` `[CERT]` (`persistence-contract.md:5`).

La resolución sigue estas reglas `[CERT]` (`persistence-contract.md:7-9`):

- El orquestador **PREGUNTA** al usuario qué modo quiere cuando se invoca `/sdd-new`, `/sdd-ff` o `/sdd-continue` por primera vez en una sesión. La elección se cachea para la sesión.
- Default (si el usuario no especifica): si Engram está disponible → `engram`; en caso contrario → `none`.

**Modelo mental** `[INFER]`: el modo no es una propiedad del cambio sino de la sesión — se decide una vez y se reenvía a cada sub-agente como `artifact_store.mode`. Es la variable que determina, para todo el pipeline, dónde viven los artefactos.

## 19.2 — Roles de cada modo `[CERT]`

Cada modo tiene un rol conceptual distinto `[CERT]` (`persistence-contract.md:13-16`):

| Modo | Rol | Características `[CERT]` |
|------|-----|------------------------|
| `engram` | Memoria de trabajo entre sesiones | Upserts sobrescriben — sin historial de iteración. Solo local, no compartible |
| `openspec` | Fuente de verdad | Archivos en el repo, historial git, compartible con el equipo, audit trail completo |
| `hybrid` | Ambos | Archivos para el equipo + engram para recuperación. Mayor costo de tokens |
| `none` | Efímero | Se pierde cuando termina la conversación |

### Tabla de comparación de capacidades `[CERT]` (`persistence-contract.md:20-27`)

| Capacidad | `engram` | `openspec` | `hybrid` | `none` |
|-----------|----------|------------|----------|--------|
| Recuperación cross-session | ✅ | ❌ (necesita git) | ✅ | ❌ |
| Supervivencia a compactación | ✅ | ❌ | ✅ | ❌ |
| Compartible con el equipo | ❌ (DB local) | ✅ (archivos commiteados) | ✅ (archivos) | ❌ |
| Historial completo de iteración | ❌ (upsert sobrescribe) | ✅ (historial git) | ✅ (archivos + git) | ❌ |
| Audit trail (archive) | Parcial (solo reporte) | ✅ (carpeta completa) | ✅ (ambos) | ❌ |
| Archivos de proyecto creados | Nunca | Sí | Sí | Nunca |

### Limitación del modo `engram` `[CERT]`

Engram usa upserts basados en `topic_key`. Re-correr una fase para el mismo cambio **sobrescribe** la versión previa — no se guarda historial de revisiones `[CERT]` (`persistence-contract.md:31`). La fase de archive guarda un reporte resumen, NO la carpeta completa de artefactos. Para historial de iteración o colaboración de equipo, usar `openspec` o `hybrid`. Esta limitación es la contraparte funcional del comportamiento de upsert detallado en [Bloque 20].

## 19.3 — Comportamiento de lectura/escritura por modo `[CERT]`

| Modo | Lee de | Escribe a | Archivos de proyecto `[CERT]` (`persistence-contract.md:35-40`) |
|------|--------|-----------|-------------------|
| `engram` | Engram | Engram | Nunca |
| `openspec` | Filesystem | Filesystem | Sí |
| `hybrid` | Engram (primario) + Filesystem (fallback) | Ambos | Sí |
| `none` | Contexto del prompt del orquestador | Ningún lado | Nunca |

### Modo Hybrid en detalle `[CERT]`

Persiste cada artefacto a AMBOS, Engram y OpenSpec, simultáneamente `[CERT]` (`persistence-contract.md:44-52`):

- Engram: recuperación cross-session, supervivencia a compactación, búsqueda determinística.
- OpenSpec: archivos legibles, artefactos versionables.

Se escribe a Engram (según `engram-convention.md`, ver [Bloque 20]) Y a filesystem (según `openspec-convention.md`, ver [Bloque 21]) para cada artefacto. Reglas operativas `[CERT]`:

- **Prioridad de lectura**: Engram primero; fallback a filesystem si Engram no devuelve resultados.
- **Comportamiento de escritura**: AMBAS escrituras DEBEN tener éxito para que la operación se considere completa.
- **Advertencia de costo**: hybrid consume MÁS tokens por operación. Usar solo cuando se necesita tanto persistencia cross-session COMO artefactos de archivo locales.

## 19.4 — Reglas comunes de los modos `[CERT]`

Reglas que aplican transversalmente `[CERT]` (`persistence-contract.md:69-74`):

- `none` → NO crear ni modificar archivos de proyecto; devolver resultados inline solamente.
- `engram` → NO escribir ningún archivo de proyecto; persistir a Engram y devolver IDs de observación.
- `openspec` → escribir archivos SOLO en las rutas definidas en `openspec-convention.md`.
- `hybrid` → persistir a AMBOS, Engram Y filesystem; seguir ambas convenciones.
- NUNCA forzar la creación de `openspec/` salvo que el orquestador haya pasado explícitamente `openspec` o `hybrid`.
- Si hay duda sobre qué modo usar, default a `none`.

**Implicación** `[INFER]`: la regla "default a `none` si hay duda" es un fail-safe conservador — ante la ambigüedad, el sistema prefiere NO tocar el filesystem del proyecto antes que ensuciar el repo con artefactos no solicitados.

## 19.5 — Persistencia del estado del DAG (orquestador) `[CERT]`

El orquestador persiste el estado del DAG tras cada transición de fase para permitir la recuperación SDD después de una compactación `[CERT]` (`persistence-contract.md:54-56`).

| Modo | Persistir estado | Recuperar estado `[CERT]` (`persistence-contract.md:60-63`) |
|------|------------------|-----------------|
| `engram` | `mem_save(topic_key: "sdd/{change-name}/state", capture_prompt: false*)` | `mem_search("sdd/*/state")` → `mem_get_observation(id)` |
| `openspec` | Escribir `openspec/changes/{change-name}/state.yaml` | Leer `openspec/changes/{change-name}/state.yaml` |
| `hybrid` | Ambos: `mem_save` Y escribir `state.yaml` | Engram primero; fallback filesystem |
| `none` | No es posible — advertir al usuario | No es posible |

(*) Para artefactos automatizados de estado, setear `capture_prompt: false` cuando el schema de la herramienta Engram lo soporte; si un schema más viejo lo rechaza o no expone el campo, omitirlo en lugar de fallar `[CERT]` (`persistence-contract.md:65`).

El `topic_key` `sdd/{change-name}/state` y su esquema YAML (change, phase, artifact_store, artifacts, tasks_progress, last_updated) se detallan en [Bloque 20].

## 19.6 — Reglas de contexto de sub-agentes: quién lee, quién escribe `[CERT]`

Los sub-agentes se lanzan con contexto fresco y SIN acceso a las instrucciones del orquestador ni a su protocolo de memoria `[CERT]` (`persistence-contract.md:76-78`). De ahí se deriva el reparto de responsabilidades de lectura/escritura `[CERT]` (`persistence-contract.md:80-83`):

| Tipo de tarea | Quién lee | Quién escribe |
|---------------|-----------|---------------|
| No-SDD (tarea general) | Orquestador busca en engram, pasa resumen en el prompt | Sub-agente guarda descubrimientos vía `mem_save` |
| SDD (fase con dependencias) | Sub-agente lee artefactos directamente del backend | Sub-agente guarda su artefacto |
| SDD (fase sin dependencias, ej. explore) | Nadie lee | Sub-agente guarda su artefacto |

### Por qué este reparto `[CERT]` (`persistence-contract.md:85-88`)

- **El orquestador lee para no-SDD**: sabe qué contexto es relevante; sub-agentes haciendo sus propias búsquedas desperdiciarían tokens en resultados irrelevantes.
- **Los sub-agentes leen para SDD**: los artefactos SDD son grandes; inlinearlos en el prompt del orquestador consumiría toda la ventana de contexto.
- **Los sub-agentes siempre escriben**: tienen el detalle completo de lo que pasó; el matiz se pierde para cuando los resultados vuelven al orquestador.

**Modelo mental** `[INFER]`: es una asimetría deliberada — el contexto pequeño (resúmenes no-SDD) sube por el orquestador; el contexto grande (artefactos SDD) NO sube, se queda en el backend y se referencia por topic_key/ruta. Esto es lo que mantiene el "hilo delgado" del orquestador (ver [Bloque 1]).

## 19.7 — Instrucciones de prompt del orquestador para sub-agentes `[CERT]`

El contrato fija plantillas literales de prompt que el orquestador inyecta en el lanzamiento de cada sub-agente `[CERT]` (`persistence-contract.md:90-138`):

**No-SDD** `[CERT]` (`persistence-contract.md:92-99`): instrucción `PERSISTENCE (MANDATORY)` — si hace descubrimientos/decisiones/fixes, DEBE guardarlos vía `mem_save(title, type: {decision|bugfix|discovery|pattern}, project, content: {What, Why, Where, Learned})` antes de devolver.

**SDD (con dependencias)** `[CERT]` (`persistence-contract.md:101-119`): incluye el modo del store, las instrucciones de lectura (`mem_search` → ID → `mem_get_observation` → contenido completo, REQUERIDO porque la búsqueda devuelve previews truncados) y la persistencia obligatoria con `mem_save(title, topic_key, type: "architecture", project, capture_prompt: false, content)`. Advertencia explícita: *"If you return without calling mem_save, the next phase CANNOT find your artifact and the pipeline BREAKS."*

**SDD (sin dependencias)** `[CERT]` (`persistence-contract.md:121-136`): igual al anterior pero sin el bloque de lectura de artefactos previos.

### `capture_prompt: false` para artefactos SDD `[CERT]`

Para artefactos SDD, `capture_prompt: false` es explícito y obligatorio cuando el schema de Engram lo soporta `[CERT]` (`persistence-contract.md:138`). Engram v1.15.3 hace default a `true` para saves humanos/proactivos, pero los artefactos automatizados de pipeline NO deben capturar el prompt del usuario. NO se infiere esto a partir del `type`, porque tanto los artefactos SDD como las decisiones de arquitectura humanas reales usan `type: "architecture"`. Si un schema más viejo rechaza o no expone `capture_prompt`, se omite en lugar de fallar.

**Punto clave** `[INFER]`: el sistema desacopla deliberadamente "tipo de memoria" de "captura de prompt" — el `type: architecture` es ambiguo (lo usan humanos y pipeline), así que el flag `capture_prompt` es la ÚNICA señal confiable para distinguir un artefacto automatizado de una decisión humana.

## 19.8 — Ordenamiento de respuesta del sub-agente `[CERT]`

Cuando un sub-agente persiste artefactos (vía `mem_save` o escritura de archivos), la llamada de persistencia DEBE ocurrir ANTES de la respuesta de texto final. La última salida absoluta del sub-agente debe ser texto, NUNCA una tool call `[CERT]` (`persistence-contract.md:140-144`).

**Por qué** `[CERT]`: la Task tool devuelve la salida final del sub-agente al padre. Si el sub-agente termina con una tool call, el padre recibe SOLO el resultado de la herramienta (ej. `"Observation saved"`) — el análisis de texto del sub-agente se pierde. Regla: hacer el trabajo → guardar → responder con envelope de texto.

Restricción adicional `[CERT]` (`persistence-contract.md:146`): los sub-agentes NO deben llamar `mem_session_summary` — eso está reservado solo para agentes top-level.

## 19.9 — Skill Registry y detail level `[CERT]`

El contrato también referencia dos mecanismos que se detallan en otros bloques `[CERT]` (`persistence-contract.md:148-158`):

- **Skill Registry**: el orquestador pre-resuelve rutas de skills del registry y las inyecta como `## Skills to load before work` en el prompt de lanzamiento. Los sub-agentes leen esos archivos `SKILL.md` exactos antes del trabajo. Para generar/actualizar: correr la skill `skill-registry` o `sdd-init`. Carga en el sub-agente: chequear el bloque `## Skills to load before work`; si está presente, leer esos archivos; fallback a instrucciones `SKILL: Load`; si no hay ninguno, proceder sin skills (no es error). El protocolo completo se documenta en [Bloque 22].
- **Detail Level**: el orquestador puede pasar `detail_level`: `concise | standard | deep`. Controla la verbosidad de la salida pero NO afecta qué se persiste — siempre se persiste el artefacto completo `[CERT]` (`persistence-contract.md:156-158`).

## 19.10 — Conexiones

- **[Bloque 3] — Backends y topic keys**: el [Bloque 3] introduce a nivel filosófico los cuatro backends; este bloque formaliza el contrato operativo (lectura/escritura por modo, recovery rules, plantillas de prompt). La frase de [Bloque 1] §1.2 sobre "quién lee, quién escribe" se materializa aquí en §19.6.
- **[Bloque 20] — Convención Engram**: §19.5 (estado del DAG) y §19.7 (`mem_save` con topic_key) dependen del formato de naming y del comportamiento de upsert que detalla el [Bloque 20]. La limitación "upsert sobrescribe sin historial" de §19.2 es la convención Engram vista desde el contrato.
- **[Bloque 21] — Convención OpenSpec**: las rutas a las que escribe el modo `openspec`/`hybrid` (§19.4) y el `state.yaml` (§19.5) se definen en el [Bloque 21]. El contrato delega la estructura concreta de directorios a esa convención.
- **[Bloque 15] — Status y dispatcher**: la recuperación de estado (§19.5) alimenta el contrato de status estructurado; el dispatcher nativo solo observa el modo `openspec`/`hybrid` (ver [Bloque 22] §22.3).
- **[Bloque 22] — Skill-resolver + phase-common**: §19.9 (Skill Registry) y §19.8 (ordenamiento de respuesta) se desarrollan en `skill-resolver.md` y `sdd-phase-common.md`, documentados en el [Bloque 22].
- **[Bloque 1] — Filosofía orquestador**: §19.6 es la contraparte concreta del "Sub-Agent Context Protocol" introducido filosóficamente en [Bloque 1] §1.2.
