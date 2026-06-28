# Bloque 24 — judgment-day y la verificación adversarial

> **QUÉ DOCUMENTA**: Este bloque establece el modelo mental de **Judgment Day**: el protocolo de verificación adversarial de doble juez ciego (Judge A / Judge B en paralelo), la síntesis de veredictos en buckets (confirmado / sospechoso / contradicción / INFO), el fix-agent quirúrgico, el re-juicio iterativo, cuándo se dispara (post design/apply), su costo, y los modelos asignados a cada agente de juicio.
> **ALCANCE**: La skill `judgment-day` y sus tres agentes (jd-judge-a, jd-judge-b, jd-fix-agent), su contrato de activación, gates de decisión, formatos de prompt/veredicto, el trigger post-sdd-phase, y la fila de Model Assignments. NO cubre la fase formal `sdd-verify` (ver [Bloque 11]) — judgment-day es un protocolo de review adversarial complementario, no una fase del DAG.
> **FUENTES** (leídas y verificadas):
> - `/home/cristian/.claude/skills/judgment-day/SKILL.md` (contrato de activación, hard rules, decision gates, execution steps, output contract)
> - `/home/cristian/.claude/skills/judgment-day/references/prompts-and-formats.md` (judge prompt, fix prompt, verdict table, delegation patterns, language snippets)
> - `/home/cristian/.claude/agents/jd-judge-a.md`, `/home/cristian/.claude/agents/jd-judge-b.md`, `/home/cristian/.claude/agents/jd-fix-agent.md` (definiciones de los sub-agentes)
> - `/home/cristian/.claude/CLAUDE.md` §"Model Assignments" (filas jd-*), §"Agent Trigger Rules" (post-sdd-phase)
> **MÉTODO**: Cada afirmación lleva un marcador de certeza. `[CERT]` = verificado leyendo la fuente, con `ruta:línea` o `ruta §sección`. `[CERT-a]` = afirmado por una fuente pero no re-verificado en su origen primario. `[INFER]` = deducción propia, no literal en la fuente.

---

## 24.1 — Qué es Judgment Day y cuándo se carga `[CERT]`

Judgment Day es un protocolo de **review dual adversarial**: *"Run blind dual review, fix confirmed issues, then re-judge."* `[CERT]` (`SKILL.md:3`, description). Se carga SOLO cuando el usuario lo pide explícitamente — Judgment Day, dual/adversarial review, o el trigger en español (`juzgar`, `que lo juzguen`) — sobre un target específico: archivos, feature, PR, o slice de arquitectura `[CERT]` (`SKILL.md:10-12`, Activation Contract).

El principio rector es la **independencia de juicio**: el orquestador NUNCA revisa el código él mismo. *"Launch two blind judges in parallel with identical target and criteria; never review the code yourself."* `[CERT]` (`SKILL.md:18`).

**Modelo mental** `[INFER]`: es la materialización del valor "reviewers frescos = juicio independiente, NO ahorro de tokens" (ver [Bloque 1] §1.5). Dos jueces ciegos sobre el mismo target reducen el falso negativo de un único revisor: una sola opinión puede pasar por alto un bug; el acuerdo de dos opiniones independientes lo confirma, y el desacuerdo lo marca como sospecha en vez de hecho.

## 24.2 — Los tres agentes de juicio `[CERT]`

| Agente | Rol | Tools `[CERT]` | Modelo `[CERT]` |
|--------|-----|-------|--------|
| `jd-judge-a` | Revisor adversarial ciego A | Read, Glob, Grep, Bash, mem_search, mem_get_observation (solo lectura) | sonnet |
| `jd-judge-b` | Revisor adversarial ciego B | idénticos a A | sonnet |
| `jd-fix-agent` | Fix quirúrgico de issues confirmados | Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update | sonnet |

Reglas comunes a los jueces `[CERT]` (`jd-judge-a.md:14-19`, idéntico en `jd-judge-b.md`):
- NO usar Task/Agent — NO delegar más allá (los jueces son hojas del árbol). `[CERT]`
- NO modificar código — *"your job is ONLY to find problems"*. `[CERT]`
- Ser **adversarial**: *"Assume the code has bugs until proven otherwise."* `[CERT]`
- Terminar con `Skill Resolution: {injected|fallback-registry|fallback-path|none}`. `[CERT]`

Reglas del fix-agent `[CERT]` (`jd-fix-agent.md:14-21`):
- Arreglar SOLO los issues confirmados del prompt; NO refactorizar más allá de lo estrictamente necesario; NO tocar código no marcado. `[CERT]`
- **Scope rule**: *"If you fix a pattern in one file, search for the SAME pattern in ALL other files and fix them ALL."* `[CERT]` (`jd-fix-agent.md:19`).
- Devolver `## Fixes Applied - [file:line] — {what was fixed}`. `[CERT]`

**Distinción de herramientas** `[INFER]`: los jueces son read-only por diseño (no pueden tocar código), el fix-agent es el único con Edit/Write/mem_save. Esto hace estructuralmente imposible que un juez "arregle de paso" algo, preservando su rol de detector puro.

## 24.3 — El flujo: doble juez en paralelo, síntesis, fix, re-juicio `[CERT]`

Los pasos de ejecución `[CERT]` (`SKILL.md:38-44`, Execution Steps):

1. Confirmar target y criterios custom opcionales.
2. Resolver paths exactos de skills del registry, o avisar si falta.
3. Lanzar Judge A y Judge B **concurrentemente** vía delegación.
4. Sintetizar findings en buckets: **confirmed, suspect, contradiction, INFO**.
5. **Preguntar antes de los fixes de Round 1**; delegar un fix-agent separado solo para fixes confirmados aprobados.
6. Re-juzgar en paralelo tras los fixes; repetir hasta aprobar, escalar, o que el usuario pida parar.
7. Antes de cualquier acción terminal, verificar que todo Judgment Day activo tenga estado terminal.

Reglas duras de secuencia `[CERT]` (`SKILL.md:20-24`):
- Esperar a AMBOS jueces antes de sintetizar; nunca aceptar veredicto parcial. `[CERT]`
- Tras correr cualquier fix-agent, re-lanzar AMBOS jueces en paralelo antes de commit/push/done/session summary. `[CERT]`
- Estados terminales son SOLO `JUDGMENT: APPROVED` o `JUDGMENT: ESCALATED`. `[CERT]`
- Tras **2 iteraciones de fix** con issues restantes, preguntar al usuario si continuar. `[CERT]` (`SKILL.md:23`).

**Modelo mental del lazo** `[INFER]`: judge → síntesis → (preguntar) → fix → re-judge es un ciclo cerrado que no termina por agotamiento sino por veredicto explícito. El re-juicio obligatorio tras cada fix evita el "arreglé y asumo que quedó bien": cada cambio del fix-agent debe sobrevivir un nuevo juicio doble.

## 24.4 — La síntesis de veredictos: buckets y rúbrica de warnings `[CERT]`

La clasificación se decide cruzando los hallazgos de ambos jueces `[CERT]` (`SKILL.md:26-34`, Decision Gates):

| Condición | Acción / bucket `[CERT]` |
|-----------|-----------------|
| Target poco claro | Pedir scope; NO lanzar jueces |
| Sin skill registry | Avisar, proceder con criterios genéricos, registrar `Skill Resolution: none` |
| Ambos jueces hallan el MISMO CRITICAL / real WARNING | **Confirmed** → preguntar/arreglar según reglas de ronda |
| Un solo juez halla el issue | **Suspect** → reportar y triagear, NO auto-arreglar |
| Los jueces se contradicen | **Escalate** → decisión manual |
| Round 2+ solo tiene warnings teóricos / sugerencias | Reportar como INFO; NO re-juzgar |

La **rúbrica de warnings** es central `[CERT]` (`SKILL.md:19`, `prompts-and-formats.md:32`): un warning es `WARNING (real)` solo si el uso normal e intencionado puede dispararlo; si el path es contrived/malicioso/imposible, se degrada a INFO como `WARNING (theoretical)`. Cada finding del juez se clasifica en severidad: `CRITICAL | WARNING (real) | WARNING (theoretical) | SUGGESTION` `[CERT]` (`prompts-and-formats.md:27`).

La **tabla de veredicto** consolida ambas opiniones `[CERT]` (`prompts-and-formats.md:62-68`):

```
| Finding                          | Judge A | Judge B | Severity              | Status    |
|----------------------------------|---------|---------|-----------------------|-----------|
| Missing null check in auth.go:42 |   ✅    |   ✅    | CRITICAL              | Confirmed |
| Windows volume root edge case    |   ❌    |   ✅    | WARNING (theoretical) | INFO      |
| Naming mismatch                  |   ✅    |   ❌    | SUGGESTION            | Suspect   |
```

**Criterio de aprobación** tras Round 1 `[CERT]` (`prompts-and-formats.md:70`): cero CRITICALs confirmados y cero real WARNINGs confirmados. Los warnings teóricos y las sugerencias pueden quedar.

## 24.5 — El fix-agent quirúrgico y el prompt de los jueces `[CERT]`

El **judge prompt** (`prompts-and-formats.md:5-37`) instruye: *"Your ONLY job is to find problems"*, da los criterios de review (Correctness, Edge cases, Error handling, Performance, Security, Naming/conventions), inyecta los skill paths como `Skills to load before work`, exige "Findings only. No praise.", y si está limpio retorna `VERDICT: CLEAN — No issues found.` `[CERT]`.

El **fix prompt** (`prompts-and-formats.md:41-58`) recibe la tabla de issues confirmados y manda: arreglar solo confirmados, no refactorizar más allá del fix necesario, no tocar código no marcado, y arreglar TODAS las ocurrencias del mismo patrón en archivos tocados `[CERT]`.

Antes de los fixes de Round 1 el orquestador **DEBE preguntar** (`SKILL.md:21`, "Ask before fixing Round 1 confirmed issues") `[CERT]`. El fix-agent se delega por separado y solo para "confirmed approved fixes only" `[CERT]` (`SKILL.md:42`).

**Patrones de delegación** `[CERT]` (`prompts-and-formats.md:72-93`): cuando los agentes JD están configurados como sub-agentes nombrados (overlay multi-mode de OpenCode) se usa `delegate(agent="jd-judge-a", ...)` y cada agente usa su modelo configurado en Model Assignments. Cuando NO están disponibles como nombrados (Claude Code, Cursor, Windsurf, Gemini, Codex) se usa el `delegate` genérico sin parámetro `agent` y el modelo lo controla el mecanismo nativo del adapter (sentinels de modelo en los `.md`). `[CERT]`

## 24.6 — Cuándo se dispara: trigger post-sdd-phase y el costo `[CERT]`

Judgment Day se recomienda orgánicamente tras fases SDD de alto riesgo `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"):

> *"At post-sdd-phase, after the design or apply phase completes, strongly recommend running judgment-day. (adversarial verification (~4 + 3*findings cost) only at high-stakes SDD phases (design and apply))"* `[CERT]`

Dos lecturas clave `[CERT]`:
- **Cuándo**: tras `design` o tras `apply` — las dos fases donde *"errors in these phases compound downstream"* (esto coincide con el Gatekeeper de modo automático, que ya usa reviewers de contexto fresco para design y apply, ver [Bloque 16]). `[CERT-a]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").
- **Costo**: **~4 + 3×findings**. `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules").

**Desglose del costo** `[INFER]`: el `4` base corresponde aproximadamente a los dos jueces iniciales más el ciclo (re-juicio de dos jueces tras fix); el `3×findings` modela el trabajo incremental por hallazgo confirmado (fix + re-verificación). Por eso el protocolo se reserva para fases de alto riesgo: no es gratis, y su valor (juicio independiente doble) solo justifica el costo cuando un error se propaga aguas abajo.

Las reglas de trigger son *"organic recommendations, not enforced checkpoints"* `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules": gentle-ai solo renderiza el texto; el orquestador decide cuándo actuar).

## 24.7 — Los modelos asignados a los agentes de juicio `[CERT]`

De la tabla Model Assignments `[CERT]` (`CLAUDE.md` §"Model Assignments"):

| Fase | Modelo default | Effort | Razón `[CERT]` |
|------|---------------|--------|------|
| `jd-judge-a` | sonnet | default | Adversarial review — blind judge A |
| `jd-judge-b` | sonnet | default | Adversarial review — blind judge B |
| `jd-fix-agent` | sonnet | default | Surgical fixes from confirmed issues |

Esto coincide con el `model: sonnet` declarado en el frontmatter de cada agente (`jd-judge-a.md:7`, `jd-judge-b.md:7`, `jd-fix-agent.md:6`) `[CERT]`. El **gate de modelo obligatorio** aplica: las Agent calls de fases SDD/Judgment-Day DEBEN incluir `model`, resolviendo el alias de esta tabla `[CERT]` (`CLAUDE.md` §"Model Assignments": "Mandatory phase model gate"). Si no hay acceso a Opus, se sustituye por `sonnet` — pero aquí los tres ya son sonnet `[CERT]`.

**Observación** `[INFER]`: los tres agentes usan el mismo modelo (sonnet). La independencia de juicio NO viene de modelos distintos sino de **contextos frescos paralelos con el mismo target y criterios** — dos instancias ciegas del mismo modelo, sin ver la salida de la otra. El acuerdo entre ambas es señal precisamente porque ninguna influyó a la otra.

## 24.8 — Output Contract y estados terminales `[CERT]`

El retorno es `## Judgment Day — {target}` con: número de ronda, tabla de veredicto, conteos confirmed/suspect/contradiction, fixes aplicados, resultado del re-juicio, `Skill Resolution`, y el veredicto final `JUDGMENT: APPROVED ✅` o `JUDGMENT: ESCALATED ⚠️` `[CERT]` (`SKILL.md:46-48`, Output Contract).

Los snippets de lenguaje confirman el tono bilingüe del protocolo `[CERT]` (`prompts-and-formats.md:95-98`): español ("Juicio iniciado", "Los jueces trabajan en paralelo", "Los jueces coinciden", "Escalado — necesita revisión humana") e inglés equivalente.

**Modelo mental terminal** `[INFER]`: Judgment Day no admite un final ambiguo. O converge a APPROVED (cero CRITICAL/real WARNING confirmados) o ESCALATED (contradicción entre jueces, o issues que persisten tras iteraciones). Esto fuerza una decisión explícita en vez de un "parece que está bien", que es la patología que el protocolo adversarial existe para evitar.

## 24.9 — Conexiones

- **[Bloque 8] — sdd-design** y **[Bloque 10] — sdd-apply**: son los dos puntos de disparo de Judgment Day (post-sdd-phase). El protocolo agrega una capa de verificación adversarial sobre la salida de estas fases de alto riesgo, donde los errores se propagan aguas abajo.
- **[Bloque 16] — modos y Gatekeeper**: el Gatekeeper de modo automático ya delega reviewers de contexto fresco para design y apply; Judgment Day es la versión explícita y dual de ese mismo principio (juicio independiente sobre fases que compounden). Ambos comparten el "fresh-context reviewer" como mecanismo.
- **[Bloque 18] — delegación y model assignments**: las filas jd-judge-a / jd-judge-b / jd-fix-agent (todas sonnet) viven en la misma tabla de Model Assignments que las fases SDD, y el gate de modelo obligatorio (incluir `model` en la Agent call) aplica a los agentes de juicio igual que a las fases.
- **[Bloque 11] — sdd-verify**: judgment-day es complementario, NO sustituto. `sdd-verify` valida contra el spec/design/tasks (contrato formal del DAG); judgment-day hace review adversarial libre con criterios de Correctness/Security/Performance. Uno verifica conformidad; el otro caza bugs.
- **[Bloque 22] — skill-resolver**: tanto los jueces como el fix-agent reciben skill paths inyectados (`Skills to load before work`) por el mismo mecanismo de resolución del registry, y reportan `Skill Resolution` en su salida.
- **[Bloque 1] — filosofía**: Judgment Day encarna la separación de §1.5 entre delegación-por-compresión y delegación-por-independencia-de-juicio: aquí el valor es exclusivamente el juicio independiente, nunca el ahorro de tokens (de hecho cuesta ~4 + 3×findings).
