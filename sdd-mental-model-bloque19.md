# Block 19 — Persistence contract (`persistence-contract`)

> **RDD INSTABILITY NOTICE**: This block documents the persistence contract for the SDD pipeline. The `verify-report` admission gate introduced in §19.10 is part of the **Receipt-Driven Development (RDD)** line, which upstream declares unstable since `gentle-ai v1.47.0` (`README.md:21`). The persistence contract itself (modes, rules, sub-agent context) pre-dates RDD and is stable. §19.10 is the exception: treat its surface details as observable at 2026-07-28 but subject to change without notice. Re-verify before relying on it.
>
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.

> **WHAT IT DOCUMENTS**: This block documents the persistence contract shared by ALL SDD skills: how the storage mode is resolved (`engram | openspec | hybrid | none`), what role each mode plays, the read/write behavior per mode, the persistence and recovery of the DAG state, the rules of who reads and who writes context between orchestrator and sub-agents, and the sub-agents' response ordering.
> **SCOPE**: The cross-cutting persistence contract. It does NOT develop the detail of the Engram convention (topic key format, upsert, lifecycle — see [Block 20]) nor the OpenSpec convention (directory structure, state.yaml, delta specs — see [Block 21]); this block references and coordinates them. It does NOT cover the individual phases (see [Block 2] and the phase blocks).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` (full file, 164 lines by `wc -l` — [DRIFTED v1.43.2→v2.2.0]: previously documented as 159 lines)
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section` when possible. `[CERT-a]` = asserted by the source but not re-verified at its primary origin. `[INFER]` = my own deduction, not literal in the source. `[DRIFTED v1.43.2→v2.2.0]` = true at v1.43.2, false now — old fact kept visible beside the new one.

---

## 19.1 — Resolving the persistence mode `[CERT]`

The orchestrator passes `artifact_store.mode` with one of four values: `engram | openspec | hybrid | none` `[CERT]` (`persistence-contract.md:5`).

Resolution follows these rules `[CERT]` (`persistence-contract.md:7-9`):

- The orchestrator **ASKS** the user which mode they want when `/sdd-new`, `/sdd-ff`, or `/sdd-continue` is invoked for the first time in a session. The choice is cached for the session.
- Default (if the user does not specify): if Engram is available → `engram`; otherwise → `none`.

**Mental model** `[INFER]`: the mode is not a property of the change but of the session — it is decided once and forwarded to each sub-agent as `artifact_store.mode`. It is the variable that determines, for the whole pipeline, where the artifacts live.

## 19.2 — Roles of each mode `[CERT]`

Each mode has a distinct conceptual role `[CERT]` (`persistence-contract.md:12-15`):

| Mode | Role | Characteristics `[CERT]` |
|------|-----|------------------------|
| `engram` | Working memory across sessions | Upserts overwrite — no iteration history. Local only, not shareable |
| `openspec` | Source of truth | Files in the repo, git history, shareable with the team, full audit trail |
| `hybrid` | Both | Files for the team + engram for recovery. Higher token cost |
| `none` | Ephemeral | Lost when the conversation ends |

### Capability comparison table `[CERT]` (`persistence-contract.md:19-26`)

| Capability | `engram` | `openspec` | `hybrid` | `none` |
|-----------|----------|------------|----------|--------|
| Cross-session recovery | ✅ | ❌ (needs git) | ✅ | ❌ |
| Survives compaction | ✅ | ❌ | ✅ | ❌ |
| Shareable with the team | ❌ (local DB) | ✅ (committed files) | ✅ (files) | ❌ |
| Full iteration history | ❌ (upsert overwrites) | ✅ (git history) | ✅ (files + git) | ❌ |
| Audit trail (archive) | Partial (report only) | ✅ (full folder) | ✅ (both) | ❌ |
| Project files created | Never | Yes | Yes | Never |

### Limitation of `engram` mode `[CERT]`

Engram uses `topic_key`-based upserts. Re-running a phase for the same change **overwrites** the previous version — no revision history is kept `[CERT]` (`persistence-contract.md:30`). The archive phase saves a summary report, NOT the full folder of artifacts. For iteration history or team collaboration, use `openspec` or `hybrid`. This limitation is the functional counterpart of the upsert behavior detailed in [Block 20].

## 19.3 — Read/write behavior per mode `[CERT]`

| Mode | Reads from | Writes to | Project files `[CERT]` (`persistence-contract.md:33-40`) |
|------|--------|-----------|-------------------|
| `engram` | Engram | Engram | Never |
| `openspec` | Filesystem | Filesystem | Yes |
| `hybrid` | Engram (primary) + Filesystem (fallback) | Both | Yes |
| `none` | Orchestrator prompt context | Neither | Never |

### Hybrid mode in detail `[CERT]`

Persists each artifact to BOTH Engram and OpenSpec simultaneously `[CERT]` (`persistence-contract.md:43-52`):

- Engram: cross-session recovery, compaction survival, deterministic search.
- OpenSpec: readable files, versionable artifacts.

It writes to Engram (per `engram-convention.md`, see [Block 20]) AND to filesystem (per `openspec-convention.md`, see [Block 21]) for each artifact. Operational rules `[CERT]`:

- **Read priority**: Engram first; fallback to filesystem if Engram returns no results.
- **Write behavior**: BOTH writes MUST succeed for the operation to be considered complete.
- **Cost warning**: hybrid consumes MORE tokens per operation. Use only when both cross-session persistence AND local file artifacts are needed.

## 19.4 — Common mode rules `[CERT]`

Rules that apply cross-cuttingly `[CERT]` (`persistence-contract.md:67-74`):

- `none` → do NOT create or modify project files; return results inline only.
- `engram` → do NOT write any project file; persist to Engram and return observation IDs.
- `openspec` → write files ONLY in the paths defined in `openspec-convention.md`.
- `hybrid` → persist to BOTH Engram AND filesystem; follow both conventions.
- NEVER force the creation of `openspec/` unless the orchestrator explicitly passed `openspec` or `hybrid`.
- If in doubt about which mode to use, default to `none`.

**Implication** `[INFER]`: the rule "default to `none` if in doubt" is a conservative fail-safe — faced with ambiguity, the system prefers NOT to touch the project filesystem rather than dirty the repo with unrequested artifacts.

## 19.5 — DAG state persistence (orchestrator) `[CERT]`

The orchestrator persists the DAG state after each phase transition to allow SDD recovery after a compaction `[CERT]` (`persistence-contract.md:54-56`).

| Mode | Persist state | Recover state `[CERT]` (`persistence-contract.md:59-63`) |
|------|------------------|-----------------|
| `engram` | `mem_save(topic_key: "sdd/{change-name}/state", capture_prompt: false*)` | `mem_search("sdd/*/state")` → `mem_get_observation(id)` |
| `openspec` | Write `openspec/changes/{change-name}/state.yaml` | Read `openspec/changes/{change-name}/state.yaml` |
| `hybrid` | Both: `mem_save` AND write `state.yaml` | Engram first; fallback filesystem |
| `none` | Not possible — warn the user | Not possible |

(*) For automated state artifacts, set `capture_prompt: false` when the Engram tool schema supports it; if an older schema rejects it or does not expose the field, omit it rather than fail `[CERT]` (`persistence-contract.md:65`).

The `topic_key` `sdd/{change-name}/state` and its YAML schema (change, phase, artifact_store, artifacts, tasks_progress, last_updated) are detailed in [Block 20].

## 19.6 — Sub-agent context rules: who reads, who writes `[CERT]`

Sub-agents are launched with fresh context and WITHOUT access to the orchestrator's instructions or its memory protocol `[CERT]` (`persistence-contract.md:82-84`). From there the read/write division of responsibilities derives `[CERT]` (`persistence-contract.md:85-89`):

| Task type | Who reads | Who writes |
|---------------|-----------|---------------|
| Non-SDD (general task) | Orchestrator searches engram, passes a summary in the prompt | Sub-agent saves discoveries via `mem_save` |
| SDD (phase with dependencies) | Sub-agent reads artifacts directly from the backend | Sub-agent saves its artifact |
| SDD (phase without dependencies, e.g. explore) | Nobody reads | Sub-agent saves its artifact |

### Why this division `[CERT]` (`persistence-contract.md:90-94`)

- **The orchestrator reads for non-SDD**: it knows what context is relevant; sub-agents doing their own searches would waste tokens on irrelevant results.
- **Sub-agents read for SDD**: SDD artifacts are large; inlining them in the orchestrator's prompt would consume the whole context window.
- **Sub-agents always write**: they have the full detail of what happened; the nuance is lost by the time the results return to the orchestrator.

**Mental model** `[INFER]`: it is a deliberate asymmetry — small context (non-SDD summaries) goes up through the orchestrator; large context (SDD artifacts) does NOT go up, it stays in the backend and is referenced by topic_key/path. This is what keeps the orchestrator's "thin thread" (see [Block 1]).

## 19.7 — Orchestrator prompt instructions for sub-agents `[CERT]`

The contract sets literal prompt templates the orchestrator injects into each sub-agent launch `[CERT]` (`persistence-contract.md:96-144`):

**Non-SDD** `[CERT]` (`persistence-contract.md:98-105`): `PERSISTENCE (MANDATORY)` instruction — if it makes discoveries/decisions/fixes, it MUST save them via `mem_save(title, type: {decision|bugfix|discovery|pattern}, project, content: {What, Why, Where, Learned})` before returning.

**SDD (with dependencies)** `[CERT]` (`persistence-contract.md:107-125`): includes the store mode, the read instructions (`mem_search` → ID → `mem_get_observation` → full content, REQUIRED because search returns truncated previews) and the mandatory persistence with `mem_save(title, topic_key, type: "architecture", project, capture_prompt: false, content)`. Explicit warning: *"If you return without calling mem_save, the next phase CANNOT find your artifact and the pipeline BREAKS."*

**SDD (without dependencies)** `[CERT]` (`persistence-contract.md:127-142`): same as the previous one but without the block for reading prior artifacts.

### `capture_prompt: false` for SDD artifacts `[CERT]`

For SDD artifacts, `capture_prompt: false` is explicit and mandatory when the Engram schema supports it `[CERT]` (`persistence-contract.md:144`). Engram v1.15.3 defaults to `true` for human/proactive saves, but automated pipeline artifacts must NOT capture the user's prompt. This is NOT inferred from the `type`, because both SDD artifacts and real human architecture decisions use `type: "architecture"`. If an older schema rejects or does not expose `capture_prompt`, it is omitted rather than failed.

**Key point** `[INFER]`: the system deliberately decouples "memory type" from "prompt capture" — the `type: architecture` is ambiguous (both humans and the pipeline use it), so the `capture_prompt` flag is the ONLY reliable signal to distinguish an automated artifact from a human decision.

## 19.8 — Sub-agent response ordering `[CERT]`

When a sub-agent persists artifacts (via `mem_save` or file writes), the persistence call MUST happen BEFORE the final text response. The sub-agent's absolute last output must be text, NEVER a tool call `[CERT]` (`persistence-contract.md:146-150`).

**Why** `[CERT]`: the Task tool returns the sub-agent's final output to the parent. If the sub-agent ends with a tool call, the parent receives ONLY the tool result (e.g. `"Observation saved"`) — the sub-agent's text analysis is lost. Rule: do the work → save → respond with a text envelope.

Additional constraint `[CERT]` (`persistence-contract.md:152`): sub-agents must NOT call `mem_session_summary` — that is reserved only for top-level agents.

## 19.9 — Skill Registry and detail level `[CERT]`

The contract also references two mechanisms detailed in other blocks `[CERT]` (`persistence-contract.md:154-165`):

- **Skill Registry**: the orchestrator pre-resolves skill paths from the registry and injects them as `## Skills to load before work` in the launch prompt. The sub-agents read those exact `SKILL.md` files before the work. To generate/update: run the `skill-registry` skill or `sdd-init`. Loading in the sub-agent: check the `## Skills to load before work` block; if present, read those files; fallback to `SKILL: Load` instructions; if there are none, proceed without skills (it is not an error). The full protocol is documented in [Block 22].
- **Detail Level**: the orchestrator can pass `detail_level`: `concise | standard | deep`. It controls the verbosity of the output but does NOT affect what is persisted — the full artifact is always persisted `[CERT]` (`persistence-contract.md:164-165`).

## 19.10 — Verify-report admission gate (canonical) `[CERT]` — RDD unstable surface

> **CANONICAL**: Blocks 11 and 22 both reference the validate gate. This section is the single authoritative description. When the gate description appears elsewhere, it cross-references here rather than restating.
>
> **RDD INSTABILITY**: The `gentle-ai sdd-verify-validate` command is part of the RDD development line (`README.md:21`). The contract (a gate exists, where it sits, what happens on failure) is stable. The command surface (exact flags, argument names, output schema) was observed on 2026-07-28 and may change without notice on the unstable line. Record the flags below only as an observation, not as a durable specification.

`[CERT]` (`persistence-contract.md:76-81`, `sdd-phase-common.md:41`, `sdd-verify/SKILL.md:45`, `sdd-verify/references/report-format.md:83-85`):

**Where it sits in the phase order**: AFTER the complete report is built in memory AND BEFORE any OpenSpec or Engram persistence write. This ordering is non-negotiable — it is a gate on write admission, not a post-write check.

**What the gate does**: the `sdd-verify` skill builds the complete verification report as exact candidate bytes in memory. It counts authoritative requirements and scenarios from the retrieved specs (never inventing totals). It then submits those bytes to `gentle-ai sdd-verify-validate` before writing anything.

**What it guarantees**: only structurally valid reports that count requirements/scenarios consistently with the actual specs reach storage. The gate accepts both PASS and FAIL verdicts — a valid `fail` report MUST be persisted because validity and archive readiness are separate decisions.

**What happens when denied or unavailable**: STOP with zero persistence calls. Do not create, truncate, delete, or overwrite any prior `verify-report`. Leave the previous report untouched. The same rule applies whether the validator is absent from the path or explicitly rejects the candidate.

**Hybrid mode behaviour** `[CERT]` (`persistence-contract.md:80`): hybrid runs the preflight once before BOTH writes, not once per write. The gate is not per-mode — it fires once and the same admitted bytes go to both destinations.

**Command surface** `[CERT-a — RDD unstable surface; observed 2026-07-28, may change]` (`report-format.md:85`): `gentle-ai sdd-verify-validate --input <path|-> --requirements <n> --scenarios <n>`. This is the form documented in the source at the observation date. Because the RDD line is unstable (`README.md:21`), treat flag names and argument shapes as observed behaviour, not a stable contract.

**Why it was introduced** `[INFER]`: before v1.47.0, a sub-agent could persist any text as a verify-report and downstream routing would read it as authoritative. The gate prevents count mismatches (claimed requirements/scenarios different from actual spec contents), missing mandatory fields, and truncated or malformed reports from poisoning the `archive` dependency state.

## 19.11 — Connections

- **[Block 3] — Backends and topic keys**: [Block 3] introduces the four backends at the philosophical level; this block formalizes the operational contract (read/write per mode, recovery rules, prompt templates). The phrase from [Block 1] §1.2 about "who reads, who writes" materializes here in §19.6.
- **[Block 20] — Engram convention**: §19.5 (DAG state) and §19.7 (`mem_save` with topic_key) depend on the naming format and the upsert behavior that [Block 20] details. The "upsert overwrites without history" limitation of §19.2 is the Engram convention seen from the contract.
- **[Block 21] — OpenSpec convention**: the paths the `openspec`/`hybrid` mode writes to (§19.4) and the `state.yaml` (§19.5) are defined in [Block 21]. The contract delegates the concrete directory structure to that convention.
- **[Block 15] — Status and dispatcher**: state recovery (§19.5) feeds the structured status contract; the native dispatcher only observes the `openspec`/`hybrid` mode (see [Block 22] §22.3).
- **[Block 22] — Skill-resolver + phase-common**: §19.9 (Skill Registry) and §19.8 (response ordering) are developed in `skill-resolver.md` and `sdd-phase-common.md`, documented in [Block 22]. §22.2-C carries the phase-level reminder of the verify-report gate, which cross-references this section as canonical.
- **[Block 11] — sdd-verify phase**: the verify-report admission gate (§19.10) constrains exactly what `sdd-verify` may write; [Block 11] documents the full verify phase and cross-references §19.10 for gate details.
- **[Block 1] — Orchestrator philosophy**: §19.6 is the concrete counterpart of the "Sub-Agent Context Protocol" introduced philosophically in [Block 1] §1.2.
