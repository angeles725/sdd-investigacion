# SDD de gentle-ai — Mental Model · Índice Maestro

**Actualizado**: 2026-06-28 (Bloques 1-27 — destilación completa del SDD de gentle-ai: filosofía + DAG + 10 fases + orquestación + contratos de persistencia + calidad + distribución multi-agente + arquitectura interna Go)
**Sistema analizado**: gentle-ai (configurador de ecosistema, binario Go v1.43.2) + su capa SDD (Spec-Driven Development) tal como se materializa en Claude Code / OpenCode.
**Método**: Investigación empírica READ-ONLY con 7 sub-agentes en paralelo, contrastando el contrato del orquestador (`~/.claude/CLAUDE.md`) contra las skills canónicas (`~/.config/opencode/skills/sdd-*/SKILL.md`), los agents (`~/.claude/agents/sdd-*.md`), los prompts (`~/.config/opencode/prompts/sdd/*.md`), los contratos compartidos (`_shared/`), el binario `gentle-ai` (verificado vía `--help`), y el repositorio fuente [Gentleman-Programming/gentle-ai](https://github.com/Gentleman-Programming/gentle-ai) (README + `docs/`). Réplica del estilo del corpus `niagara-research`.

Este índice te guía entre los **27 bloques** que documentan el SDD de gentle-ai. Cada bloque es un archivo `.md` independiente que puede leerse aislado, pero las conexiones están explícitamente marcadas entre sí con la forma `[Bloque K]`. El catálogo plano autogenerado vive en [CATALOG.md](CATALOG.md) (regenerar con `python3 tools/gen-catalog.py`).

## Leyenda de marcadores de certeza

Todo el corpus usa el mismo sistema de honestidad epistémica que `niagara-research`:

- **`[CERT]`** = verificado leyendo la fuente primaria, con cita `ruta:línea` o `ruta §sección`.
- **`[CERT-a]`** = afirmado por una fuente (README/docs/prompt) pero **no re-verificado** en su origen primario (ej. código Go, o `--help` del binario).
- **`[INFER]`** = deducción del autor, no literal en la fuente.

---

## Mapa completo

### Capa 1 — Fundamentos (Bloques 1-3)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 1 | Qué es el SDD: filosofía y modelo orquestador-coordinador | [bloque1](sdd-mental-model-bloque1.md) | Ecosystem configurator, hilo orquestador fino, delegación = compresión de contexto + independencia de juicio, frontera persona/artefacto, un solo nivel de delegación |
| 2 | El DAG de fases y el Result Contract | [bloque2](sdd-mental-model-bloque2.md) | `proposal→specs→tasks→apply→verify→archive` + `design`; Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`); ramas paralelas que confluyen en `tasks` |
| 3 | Backends de artefactos y topic keys | [bloque3](sdd-mental-model-bloque3.md) | `engram` / `openspec` / `hybrid` / `none`; tabla de topic keys `sdd/{change}/{artifact}`; recovery rules; tradeoff velocidad vs trazabilidad |

### Capa 2 — Las 10 fases (Bloques 4-13)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 4 | Fase `sdd-init` | [bloque4](sdd-mental-model-bloque4.md) | Detección de stack + testing capabilities, skill-registry scan, resolución de Strict TDD, Decision Gates por modo |
| 5 | Fase `sdd-explore` | [bloque5](sdd-mental-model-bloque5.md) | Read-only, standalone vs atado a cambio, única fase con `WebFetch`/`WebSearch`, escribe `explore` |
| 6 | Fase `sdd-propose` | [bloque6](sdd-mental-model-bloque6.md) | Ronda de preguntas de producto (10 ejes), sección Capabilities como contrato con spec, modelo opus |
| 7 | Fase `sdd-spec` | [bloque7](sdd-mental-model-bloque7.md) | Delta specs, workflow `MODIFIED` copy-full-then-edit, RFC 2119, escenarios testables |
| 8 | Fase `sdd-design` | [bloque8](sdd-mental-model-bloque8.md) | Lee proposal → decisiones ADR con rationale + alternativas rechazadas, Testing Strategy, modelo opus |
| 9 | Fase `sdd-tasks` (+ Review Workload Forecast) | [bloque9](sdd-mental-model-bloque9.md) | Breakdown mecánico, estimación de líneas, recomendación de chained PRs, sin `commands/` propio |
| 10 | Fase `sdd-apply` (+ apply-progress continuity) | [bloque10](sdd-mental-model-bloque10.md) | Implementación, read-merge-write de apply-progress entre batches, strict TDD forwarding |
| 11 | Fase `sdd-verify` (+ report format) | [bloque11](sdd-mental-model-bloque11.md) | Niveles CRITICAL / WARNING / SUGGESTION, veredicto mecánico, Assertion Quality Audit |
| 12 | Fase `sdd-archive` | [bloque12](sdd-mental-model-bloque12.md) | Merge de delta specs en specs principales, cierre del ciclo, modelo haiku, sin `Bash` |
| 13 | Fase `sdd-onboard` | [bloque13](sdd-mental-model-bloque13.md) | Walkthrough guiado pedagógico, ejecuta inline el comportamiento de todas las fases, modelo haiku |

### Capa 3 — Orquestación (Bloques 14-18)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 14 | Meta-comandos: `sdd-new`, `sdd-continue`, `sdd-ff` | [bloque14](sdd-mental-model-bloque14.md) | Meta-comando vs skill, fast-forward de planificación, qué tramo del DAG cubre cada uno |
| 15 | `sdd-status` y el dispatcher nativo `gentle-ai` | [bloque15](sdd-mental-model-bloque15.md) | Dispatcher solo ve OpenSpec (`artifactStore: openspec`), ciego ante engram, ruteo por `nextRecommended`/`blockedReasons`, Action Context Guard |
| 16 | Modos de ejecución (auto/interactive) y el Gatekeeper | [bloque16](sdd-mental-model-bloque16.md) | Auto vs interactive, 5 chequeos del Gatekeeper (conformance/existence/no-hallucination/no-drift/routing), inline vs reviewer fresco, re-run único |
| 17 | Delivery strategy, chain strategy y chained PRs | [bloque17](sdd-mental-model-bloque17.md) | `ask-on-risk`/`auto-chain`/`single-pr`/`exception-ok`, `stacked-to-main`/`feature-branch-chain`, Review Workload Guard, presupuesto 400 líneas |
| 18 | Modelo de delegación, triggers obligatorios y model assignments | [bloque18](sdd-mental-model-bloque18.md) | Tabla inline vs delegar, 6 Mandatory Delegation Triggers, tabla fase→modelo→effort→razón, model gate, dedup de lanzamientos |

### Capa 4 — Contratos y convenciones (Bloques 19-22)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 19 | Contrato de persistencia (`persistence-contract`) | [bloque19](sdd-mental-model-bloque19.md) | Modo es propiedad de sesión, default `none` ante duda, asimetría de captura de prompt, recovery |
| 20 | Convención Engram (`engram-convention`) | [bloque20](sdd-mental-model-bloque20.md) | Formato de topic keys, `mem_save`/`mem_search`/`mem_get_observation`, upsert por `topic_key`, lifecycle `active`/`needs_review` |
| 21 | Convención OpenSpec (`openspec-convention`) | [bloque21](sdd-mental-model-bloque21.md) | `openspec/changes/`, `state.yaml`, specs fuente vs delta, trampa de `MODIFIED`, archive datado inmutable |
| 22 | Skill-resolver + phase-common + status-contract | [bloque22](sdd-mental-model-bloque22.md) | Skill Resolver Protocol (pasar paths no resúmenes), contrato común de fases, schema del status estructurado |

### Capa 5 — Calidad (Bloques 23-24)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 23 | TDD estricto (strict-tdd / strict-tdd-verify) | [bloque23](sdd-mental-model-bloque23.md) | Las Tres Leyes, activación vía init, forwarding obligatorio a apply/verify, ciclo Safety-Net→RED→GREEN→TRIANGULATE→REFACTOR, Assertion Quality Audit |
| 24 | judgment-day y la verificación adversarial | [bloque24](sdd-mental-model-bloque24.md) | Doble juez ciego (jd-judge-a/b) + jd-fix-agent, síntesis en buckets, re-juicio obligatorio, trigger post-design/apply, costo ~4 + 3×findings |

### Capa 6 — Distribución y configurador (Bloques 25-26)

| # | Bloque | Archivo | Key topics |
|---|--------|---------|------------|
| 25 | Distribución multi-agente: los 15 harnesses y los modelos de delegación | [bloque25](sdd-mental-model-bloque25.md) | Tabla de 15 agentes; **Full** vs **Solo-agent** vs **Detect-only**; rutas por harness (`~/.cursor/agents/`, `~/.kiro/agents/`, etc.); fases SDD invariantes, transporte de contexto variable |
| 26 | El configurador `gentle-ai` | [bloque26](sdd-mental-model-bloque26.md) | `install`/`sync`/`upgrade`/`doctor`/`skill-registry refresh`, scopes global vs workspace, OpenCode SDD profiles (`gentle-orchestrator`), per-phase models, backups, startup hooks |
| 27 | Arquitectura interna: `state.json` y adapters por harness | [bloque27](sdd-mental-model-bloque27.md) | Struct `InstallState` (`internal/state/state.go`), 16 adapters reales (`internal/agents/factory.go`), `SystemPromptStrategy`/`MCPStrategy`, solo 4 con `SupportsSubAgents()` (Claude/Cursor/Kimi/Kiro) |

---

## Hallazgos transversales (verificados durante la investigación)

Estos son los descubrimientos no obvios que surgieron al contrastar fuentes. Valen como mapa de las **inconsistencias del sistema**, no como crítica — documentan dónde la fuente de verdad diverge:

1. **El DAG ASCII contradice la tabla de dependencias** `[CERT]` (B2). El diagrama dibuja `design → specs`, pero la tabla de fases dice que `sdd-tasks` lee **spec + design** y `sdd-design` lee **proposal**. Operativamente son ramas paralelas desde `proposal` que confluyen en `tasks`; el ASCII comprime esa confluencia.

2. **Discrepancia de vocabulario en `status`** `[CERT]` (B4-B8). Los prompts de agente declaran `done|blocked|partial`, pero el Return Envelope común (`sdd-phase-common.md §D`) usa `success|partial|blocked`.

3. **Los prompts condensados contradicen sus SKILL.md en `apply` y `verify`** `[CERT]` (B10-B11). El caso más fuerte: `prompts/sdd/sdd-verify.md:33` dice *"Do NOT run tests unless strict_tdd is active"*, lo OPUESTO al SKILL.md (*"static analysis alone is never verification"*). El SKILL.md v3.0 + `references/report-format.md` es la fuente canónica. Para tasks/archive/onboard los prompts son byte-idénticos al SKILL.md.

4. **El dispatcher nativo no expone `--help` por subcomando** `[CERT]` (B15). `gentle-ai sdd-status --help` falla con `unknown sdd-status argument "--help"`. Los flags `--cwd`/`--json`/`--instructions` quedan como `[CERT-a]` (afirmados en docs, no verificables contra el binario v1.43.2).

5. **Hermes: `Detect-only` vs `Full`** `[CERT]` (B25). El README rotula Hermes como `Detect-only`; `docs/agents.md` lo rotula `Full (delegate_task ephemeral)`. Son ejes distintos `[INFER]`: `Detect-only` = modo de instalación; `Full` = modo de delegación en runtime. La tabla del README lista 16 filas; Hermes es la 16ª fuera de los 15 que el configurador instala automáticamente.

6. **Coincidencia opus ↔ alto riesgo del Gatekeeper** `[CERT]` (B16, B18). Las dos únicas fases con modelo **opus** (`sdd-propose`, `sdd-design`) son exactamente las dos fases de alto riesgo que el Gatekeeper valida con reviewer fresco. La asignación de modelo es proporcional al riesgo arquitectónico.

7. **`docs/architecture.md` lista 8 adapters Go pero el código registra 16** `[CERT]` (B27, resuelto). `internal/agents/factory.go:defaultAgentIDs` registra **16 adapters** (claude, opencode, kilocode, gemini, cursor, vscode, codex, antigravity, windsurf, kimi, qwen, kiro, openclaw, pi, trae, hermes), cada uno con `internal/agents/<pkg>/adapter.go` + test. El "8" de `docs/architecture.md` es deuda de doc (snapshot del MVP); el "15" del README es de presentación (Hermes es la 16ª fila, detect-only). La cuenta autoritativa es **16**. Solo 4 declaran `SupportsSubAgents()==true`: Claude, Cursor, Kimi, Kiro.

8. **`state.json` es estado del configurador, no del SDD** `[CERT]` (B27). El struct `InstallState` (`internal/state/state.go`) persiste `installed_agents`, asignaciones de modelo por agente/fase, `persona`, `last_update_check`, `pending_sync` — pero **NO** persiste tareas/specs SDD ni scope/canal. El estado de los cambios SDD vive en los backends de artefactos ([Bloque 3]), no acá.

---

## Pendientes de verificación (gaps honestos)

- Flags del dispatcher nativo (`--cwd`/`--json`/`--instructions`): no verificables vía `--help` del binario v1.43.2 (afirmados en docs, `[CERT-a]`).
- Cuerpo de los injectors (`components/sdd/inject.go`, `filemerge/`): B27 documenta el contrato (paths + estrategias por adapter), no los bytes exactos que cada injector escribe.

---

## Cómo navegar este corpus

- **Si querés entender el SDD desde cero** → empezá por [Bloque 1] (filosofía), seguí con [Bloque 2] (DAG) y [Bloque 3] (backends).
- **Si te interesa una fase concreta** → andá directo a su bloque en la Capa 2 (B4-B13).
- **Si querés saber cómo el orquestador toma decisiones** → Capa 3 (B14-B18), especialmente [Bloque 16] (Gatekeeper) y [Bloque 18] (delegación + modelos).
- **Si vas a tocar persistencia o backends** → Capa 4 (B19-B22).
- **Si te interesa cómo se distribuye a tu agente (Claude/Codex/OpenCode/etc.)** → [Bloque 25] y [Bloque 26].
