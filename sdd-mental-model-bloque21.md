# Bloque 21 — Convención OpenSpec (`openspec-convention`)

> **QUÉ DOCUMENTA**: Este bloque documenta la convención de archivos OpenSpec: la estructura de directorios `openspec/` (config, specs fuente, changes activos, archive), las rutas de archivo de cada artefacto por skill, las reglas de lectura/escritura, las secciones de delta spec (`ADDED` / `MODIFIED` / `REMOVED` / `RENAMED`), el formato del `config.yaml`, y la estructura de archive con datado ISO.
> **ALCANCE**: La convención específica del backend OpenSpec (file-based). NO cubre el contrato de persistencia transversal (ver [Bloque 19]) ni la convención Engram (ver [Bloque 20]). NO documenta el contenido interno de cada artefacto (qué va dentro de una proposal, de un design, etc. — ver bloques de fase).
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.config/opencode/skills/_shared/openspec-convention.md` (archivo completo, 120 líneas)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección` cuando es posible. `[CERT-a]` = afirmado por la fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 21.1 — Estructura de directorios `[CERT]`

La convención fija una estructura de directorios canónica `[CERT]` (`openspec-convention.md:5-23`):

```
openspec/
├── config.yaml              <- Config SDD específica del proyecto
├── specs/                   <- Source of truth (specs principales)
│   └── {domain}/
│       └── spec.md
└── changes/                 <- Cambios activos
    ├── archive/             <- Cambios completados (YYYY-MM-DD-{change-name}/)
    └── {change-name}/       <- Carpeta del cambio activo
        ├── state.yaml       <- Estado del DAG (sobrevive compactación)
        ├── exploration.md   <- (opcional) de sdd-explore
        ├── proposal.md      <- de sdd-propose
        ├── specs/           <- de sdd-spec
        │   └── {domain}/
        │       └── spec.md  <- Delta spec
        ├── design.md        <- de sdd-design
        ├── tasks.md         <- de sdd-tasks (actualizado por sdd-apply)
        └── verify-report.md <- de sdd-verify
```

**Distinción arquitectónica clave** `[CERT]`: hay DOS niveles de specs `[INFER]` — `openspec/specs/{domain}/spec.md` es la **fuente de verdad** (specs principales acumulados), mientras que `openspec/changes/{change-name}/specs/{domain}/spec.md` es el **delta spec** del cambio en curso. El archive fusiona el delta en la fuente de verdad (ver §21.5-§21.6).

## 21.2 — Rutas de archivo de artefactos por skill `[CERT]`

| Skill | Crea / Lee | Ruta `[CERT]` (`openspec-convention.md:27-39`) |
|-------|-----------|------|
| orquestador | Crea/Actualiza | `openspec/changes/{change-name}/state.yaml` |
| sdd-init | Crea | `openspec/config.yaml`, `openspec/specs/`, `openspec/changes/`, `openspec/changes/archive/` |
| sdd-explore | Crea (opcional) | `openspec/changes/{change-name}/exploration.md` |
| sdd-propose | Crea | `openspec/changes/{change-name}/proposal.md` |
| sdd-spec | Crea | `openspec/changes/{change-name}/specs/{domain}/spec.md` |
| sdd-design | Crea | `openspec/changes/{change-name}/design.md` |
| sdd-tasks | Crea | `openspec/changes/{change-name}/tasks.md` |
| sdd-apply | Actualiza | `openspec/changes/{change-name}/tasks.md` (marca `[x]`) |
| sdd-verify | Crea | `openspec/changes/{change-name}/verify-report.md` |
| sdd-archive | Mueve | `openspec/changes/{change-name}/` → `openspec/changes/archive/YYYY-MM-DD-{change-name}/` |
| sdd-archive | Actualiza | `openspec/specs/{domain}/spec.md` (fusiona deltas en specs principales) |

**Lectura de artefactos** `[CERT]` (`openspec-convention.md:43-51`): proposal, specs (todos los subdirectorios de dominio), design, tasks, verify-report bajo `openspec/changes/{change-name}/`; config en `openspec/config.yaml`; specs principales en `openspec/specs/{domain}/spec.md`.

## 21.3 — Reglas de escritura `[CERT]`

Reglas operativas de escritura `[CERT]` (`openspec-convention.md:53-58`):

- Siempre crear el directorio del cambio ANTES de escribir artefactos.
- Si un archivo ya existe, LEERLO primero y ACTUALIZARLO (no sobrescribir a ciegas).
- Si el directorio del cambio ya existe con artefactos, el cambio se está CONTINUANDO.
- Usar la sección `rules` de `openspec/config.yaml` para restricciones específicas del proyecto por fase.

**Implicación** `[INFER]`: la regla "si existe el directorio → se está continuando" es cómo OpenSpec deriva el estado de continuación SIN un registro central — la presencia de archivos ES el estado. Esto contrasta con `engram` donde el estado vive en el artefacto `state` (ver [Bloque 20] §20.3).

## 21.4 — Secciones de delta spec `[CERT]`

Los delta specs PUEDEN incluir estas secciones `[CERT]` (`openspec-convention.md:62-74`):

```markdown
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

Semántica de fusión `[CERT]`:

| Sección | Efecto al fusionar en el spec principal |
|---------|------------------------------------------|
| `ADDED` | Agrega nuevos requirements al spec principal |
| `MODIFIED` | Reemplaza el bloque completo del requirement coincidente. El delta DEBE contener el requirement actualizado entero, incluyendo escenarios sin cambios que deben preservarse |
| `REMOVED` | Borra el requirement coincidente. Cada uno DEBE incluir `(Reason: ...)` y DEBERÍA incluir `(Migration: ...)` cuando afecta consumidores o comportamiento persistido |
| `RENAMED` | Cambia el heading/nombre sin cambiar comportamiento (salvo que el delta incluya también un bloque `MODIFIED` para el nuevo requirement). Cada rename DEBE declarar nombres viejo y nuevo explícitamente |

**Punto clave** `[INFER]`: el delta spec es un diff declarativo de requirements, no un archivo monolítico. La regla de `MODIFIED` ("contener el requirement entero, incluyendo escenarios sin cambios") es crítica — la fusión REEMPLAZA el bloque completo, así que omitir un escenario sin cambios lo borraría. Es la trampa más sutil de la convención.

## 21.5 — Archivo de configuración `config.yaml` `[CERT]`

El `config.yaml` define contexto y reglas por fase `[CERT]` (`openspec-convention.md:78-110`):

```yaml
# openspec/config.yaml
schema: spec-driven

context: |
  Tech stack: {detected}
  Architecture: {detected}
  Testing: {detected}
  Style: {detected}

rules:
  proposal:
    - Include rollback plan for risky changes
  specs:
    - Use Given/When/Then for scenarios
    - Use RFC 2119 keywords (MUST, SHALL, SHOULD, MAY)
  design:
    - Include sequence diagrams for complex flows
    - Document architecture decisions with rationale
  tasks:
    - Group by phase, use hierarchical numbering
    - Keep tasks completable in one session
  apply:
    - Follow existing code patterns
    tdd: false           # Set to true to enable RED-GREEN-REFACTOR
    test_command: ""
  verify:
    test_command: ""
    build_command: ""
    coverage_threshold: 0
  archive:
    - Warn before merging destructive deltas
```

Elementos notables `[CERT]`:

- `schema: spec-driven` identifica el tipo de config.
- `context` lleva stack/arquitectura/testing/style detectados (poblado por `sdd-init`).
- `rules` tiene una sub-clave por fase. Las reglas son constraints específicas del proyecto que cada fase consume.
- `apply.tdd: false` es el flag que activa RED-GREEN-REFACTOR cuando se setea a `true` (ver [Bloque 23]), con `test_command` asociado.
- `verify` lleva `test_command`, `build_command` y `coverage_threshold`.

## 21.6 — Estructura de archive `[CERT]`

Al archivar, la carpeta del cambio se mueve a `[CERT]` (`openspec-convention.md:113-119`):

```
openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Reglas `[CERT]`:

- Usar la fecha de hoy en formato ISO.
- El archive es un **AUDIT TRAIL** — NUNCA borrar ni modificar cambios archivados.

**Modelo mental** `[INFER]`: el archive datado es lo que le da a `openspec` su capacidad de audit trail completo (la fila "Audit trail" de la tabla de [Bloque 19] §19.2). El `engram` solo guarda un reporte resumen; aquí queda la carpeta entera, inmutable, datada. Esa inmutabilidad es la diferencia entre "memoria de trabajo" y "registro histórico".

## 21.7 — Conexiones

- **[Bloque 3] — Backends**: el [Bloque 3] introduce `openspec` como uno de los cuatro backends; este bloque detalla su estructura de archivos concreta. La distinción specs-fuente vs. delta-specs (§21.1) es propia de este backend.
- **[Bloque 19] — Contrato de persistencia**: §19.4 fija que el modo `openspec`/`hybrid` escribe "SOLO en las rutas definidas en `openspec-convention.md`" — esas rutas son §21.2 de este bloque. El `state.yaml` de §21.1 es el equivalente file-based del artefacto `state` de Engram.
- **[Bloque 15] — Status y dispatcher nativo**: el dispatcher nativo (`gentle-ai sdd-status`/`sdd-continue`) lee ÚNICAMENTE los artefactos de archivo OpenSpec bajo `openspec/changes/` — la estructura de §21.1 es exactamente lo que el dispatcher observa. Por eso el dispatcher es ciego a cambios `engram` (ver [Bloque 22] §22.3).
- **[Bloque 20] — Convención Engram**: el espejo de esta convención en el backend de memoria. La nota de [Bloque 20] §20.2 (spec concatenado en Engram vs. spec por dominio en archivos) marca la diferencia estructural: aquí cada dominio tiene su propio `specs/{domain}/spec.md`.
- **[Bloque 23] — Strict-TDD**: el flag `apply.tdd` de §21.5 es el switch file-based que activa el modo TDD estricto detallado en el [Bloque 23].
- **[Bloque 12] — Archive**: §21.6 (estructura de archive) y la fila sdd-archive de §21.2 (fusión de deltas en specs principales) son la mecánica de archivo que el [Bloque 12] desarrolla a nivel de fase.
