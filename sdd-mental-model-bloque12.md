# Block 12 — `sdd-archive` Phase

> **WHAT**: Documents the `sdd-archive` phase of gentle-ai's SDD system: the closing of the cycle. It merges the delta specs into the main specs (source of truth), moves the change folder to the archive with a date prefix, and persists an archive-report with traceability. In v2.2.0 it has three hard gates in sequence: the Native Review Receipt Gate (new), the Task Completion Gate, and the CRITICAL verify block — plus a known inconsistency between the skill contract and the native product for the first gate (§12.5b).
>
> **SCOPE**: Purpose, what it reads/writes (artifact + topic key), the Native Review Receipt Gate, the Task Completion Gate, the Strict-vs-OpenSpec Archive Policy, the known inconsistency (skill contract vs native gate), the delta spec merge (ADDED/MODIFIED/REMOVED/RENAMED), the move to archive, verification, assigned model, Result Contract, and gotchas.
>
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.
>
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/sdd-archive/SKILL.md` (primary — v2.0 skill, 236 lines by `wc -l`; read in full)
> - `/home/cristian/.claude/agents/sdd-archive.md` (tools, model, Result Contract — 81 lines; read in full)
> - `/home/cristian/.config/opencode/commands/sdd-archive.md` (orchestrator gates — 34 lines; read in full)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-archive.md` — `[DRIFTED v1.43.2→v2.2.0]` no longer byte-identical to SKILL.md; diff shows a trailing CodeGraph guidance section appended (verified by diff, 2026-07-28)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md` — path confirmed present; not re-read in this refresh
> - `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md:218` — upstream admission of skill/product inconsistency (read in full)
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source, not re-verified; `[INFER]` = deduction; `[DRIFTED v1.43.2→v2.2.0]` = was true at v1.43.2, changed in v2.2.0; `[GAP]` = fact requires a forbidden command.

---

## 12.1 — Purpose and role `[CERT]`

`sdd-archive` is the EXECUTOR sub-agent responsible for ARCHIVING. It merges the delta specs into the main specs (source of truth), then moves the change folder to the archive. It completes the SDD cycle (`SKILL.md:32-34`). Same gate/override pattern (`SKILL.md:13-17`). Version `2.0`.

The archive closes the DAG ([Block 2]): `proposal → specs → tasks → apply → verify → archive`. After archive, "Ready for the next change" (`SKILL.md:219-220`).

**v2.2.0 addition — Final-State Authority** `[CERT]`: A hierarchy governs how the archive REPORTS facts (`SKILL.md:45-66`), ranking sources from most to least authoritative: native review authority (structured status `reviewGate`, terminal receipt, post-apply gate context) → persisted tasks artifact → explicit final-state facts in the orchestrator's launch prompt → `verify-report`/`apply-progress` intermediate snapshots. Stale snapshot claims must not be echoed as current facts; contradictions that cannot be ranked must be recorded explicitly (`SKILL.md:60-61`). This hierarchy governs reporting only — it does not weaken gates.

## 12.2 — What it receives from the orchestrator `[CERT]`

`SKILL.md:36-43`: Change name; Artifact store mode (`engram | openspec | hybrid | none`); Structured status from `sdd-status-contract.md` (artifact paths, task progress, dependency states, actionContext); explicit final-state facts for work completed after intermediate artifacts were persisted (e.g., verify warnings fixed in later commits, blockers resolved, updated test counts); and any explicit intentional archive override text from the user/orchestrator.

`[DRIFTED v1.43.2→v2.2.0]` The "explicit final-state facts" input is new — it allows the orchestrator to report post-snapshot completions. These outrank `verify-report`/`apply-progress` snapshots in the final-state hierarchy (`SKILL.md:55`), but NOT native review authority.

## 12.3 — What it READS and what it WRITES `[CERT]`

`SKILL.md:68-75`:

| Mode | Reads (all required) | Writes |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `/spec`, `/design`, `/tasks`, `/verify-report`, and exact `sdd/{change}/review/{transaction,ledger,receipt,gate-context}` topics | `sdd/{change}/archive-report` |
| `openspec` | follows `openspec-convention.md` | spec merge + folder move to archive |
| `hybrid` | both | Engram (report with IDs) + filesystem merge + folder move |
| `none` | returns closure summary only | nothing (no archive operations) |

**Artifact produced**: `archive-report` · **topic key**: `sdd/{change-name}/archive-report` · **type**: `architecture` (`SKILL.md:185-191`, [Block 3]).

`[DRIFTED v1.43.2→v2.2.0]` The engram read list now explicitly includes `sdd/{change}/review/{transaction,ledger,receipt,gate-context}` topics (`SKILL.md:72`). These did not exist in v1.43.2 because the review artifact layer did not exist.

> [CERT] It is the only phase that READS the `verify-report` (`SKILL.md:72`): it needs to confirm that verification passed before closing. In engram it records the observation IDs of the artifacts in the report so that the archive is a navigable audit trail.

## 12.4 — Task Completion Gate `[CERT]`

`sdd-apply` ([Block 10]) is responsible for marking tasks complete; `sdd-archive` VALIDATES that the persisted artifact reflects the final state before closing (`SKILL.md:81-84`).

Before syncing specs or moving any folder, it inspects the tasks artifact (engram: reads the `sdd/{change}/tasks` observation; openspec/hybrid: reads `tasks.md`). If any implementation task is still unchecked (`- [ ]`) (`SKILL.md:90-96`):

1. STOP and return `blocked`; do NOT sync specs, do NOT move the folder, do NOT claim cycle complete.
2. Report that `sdd-apply` must re-run or be corrected to mark the tasks.
3. Only proceed if the orchestrator EXPLICITLY instructs reconciling stale checkboxes AND `apply-progress`/`verify-report` prove that every unchecked task is complete. If this exceptional repair is done, record the exact reason in the archive report.

> [CERT] "The archived audit trail MUST NOT contain stale unchecked tasks for completed work. Internal todo state is not enough; the persisted SDD task artifact is the source of truth for completion visibility" (`SKILL.md:96`).

## 12.5 — Strict-vs-OpenSpec Archive Policy `[CERT]`

OpenSpec allows archiving with incomplete artifacts/tasks after a user confirmation. gentle-ai is MORE STRICT by default (`SKILL.md:98-105`):

- Incomplete implementation tasks BLOCK the archive, unless they are stale checkboxes and apply-progress/verify-report prove completeness.
- **CRITICAL issues in `verify-report` ALWAYS block the archive. NO override is accepted for CRITICAL verification issues** (`SKILL.md:103`).
- `sdd-archive` is NOT the owner of normal task completeness: `sdd-apply` owns checkbox marking; archive only does exceptional mechanical reconciliation with proof from apply-progress and verify-report.
- Missing proposal/spec/design artifacts must be reported. The archive only continues if the user explicitly chooses an intentional partial archive AND the report records what was missing.

This is reinforced in the Rules (`SKILL.md:223-236`): "NEVER archive a change that has CRITICAL issues in its verification report" (`SKILL.md:224`); "NEVER archive completed work while `tasks.md` / the tasks observation still shows stale unchecked implementation tasks". The orchestrator's command duplicates it: "If verify-report contains CRITICAL issues, do NOT archive. There is no CRITICAL override" (`commands/sdd-archive.md:28`).

## 12.5a — Native Review Receipt Gate `[CERT]`

**New in v2.2.0.** Before any task reconciliation, spec sync, or archive move, the executor must require structured status with `reviewGate.result: allow` (`SKILL.md:77-79`). The gate reads the exact transaction, frozen ledger, approved terminal receipt, and post-apply gate context referenced by status. Missing, pending, malformed, `scope-changed`, `invalidated`, or `escalated` review state blocks archive with no override and no automatic reviewer launch. The receipt must match final candidate tree, paths digest, policy, ledger, fix delta, current independent verification evidence, mode counters, and base relationship (`SKILL.md:79`).

In practice this means archive requires a completed review cycle producing an approved receipt, in addition to passing the Task Completion Gate (§12.4) and the CRITICAL verify block (§12.5). This gate runs first, before either of those.

> [CERT] The orchestrator command mirrors this: "Native `reviewGate.result` must be exactly `allow`; missing, pending, scope-changed, invalidated, or escalated review state blocks archive and never auto-launches a reviewer" (`commands/sdd-archive.md:23`).

## 12.5b — Known Inconsistency: Skill Contract vs Native Archive Gate

> **This section documents an admitted divergence between two authoritative layers, not a resolved behaviour. Do not present either side as "how archive works" — the vendor has not yet reconciled them.**

### What the native product does

The native archive gate (the Go binary/product layer) "now defers correctly" when review mode is disabled (`README.md:218`). That is: when a user has run `gentle-ai review mode disable`, the native product does NOT require `reviewGate.result: allow` to proceed with archive operations.

### What the `sdd-archive` skill contract requires

The `sdd-archive` skill (§12.5a above, `SKILL.md:79`) still explicitly requires `reviewGate.result: allow` before any archive work. This is an unconditional requirement in the skill text — there is no branch for disabled review mode. When the review state is missing, pending, or in any state other than `allow`, the skill blocks archive with no override.

### The disagreement

These two are in conflict: the native product defers (allows) when review is disabled; the skill contract blocks regardless. An orchestrator running the `sdd-archive` skill with review mode disabled will receive a `blocked` result even though the native product would permit archiving.

### Upstream admission and citation

This is not an inference — it is explicitly documented by the vendor:

> "The native archive gate now defers correctly, but the `sdd-archive` skill's own contract still requires `reviewGate.result: allow`, so the agent-facing rule blocks where the product no longer does."
> — `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md:218`, observed 2026-07-28

The same sentence is introduced as a "limitation" of "the current unstable RDD line" and references `docs/architecture/organic-rdd.md#9-known-open` as the tracking location for the open item.

### What a practitioner should expect in the meantime

- **Running `sdd-archive` with review mode disabled**: the skill will return `blocked` because `reviewGate.result` is not satisfied, even though the binary's native gate would allow it. Archive via the skill executor cannot complete without an approved receipt.
- **Running archive directly via the native product** (not via the skill): would defer correctly. Agents using the skill-loaded executor hit the skill-level block regardless.
- **Resolution**: the vendor intends to align the skill contract with the native gate's deferred behaviour. Until that happens, the agent-facing behaviour (block) and the product-level behaviour (defer) are in a documented open inconsistency.

`[GAP]` Exact timing of reconciliation: would require reading the upstream issue tracker or an unreleased release note. Not attempted.

## 12.6 — Step 2: Sync Delta Specs to Main Specs `[CERT]`

The distinctive step of archive — the consolidation of the source of truth. It does NOT start until BOTH the Native Review Receipt Gate (§12.5a) AND the Task Completion Gate (§12.4) pass (`SKILL.md:117-119`).

- **`engram`**: skip filesystem sync — the artifacts live only in Engram; the archive report records the observation IDs (`SKILL.md:121`).
- **`none`**: skip — there are no artifacts to sync.
- **`openspec`/`hybrid`**: for each delta spec in `openspec/changes/{change}/specs/` (`SKILL.md:125`):

### If the main spec exists (`openspec/specs/{domain}/spec.md`) `[CERT]`

It reads the existing main spec and applies the delta (`SKILL.md:128-145`):

| Delta section | Action on the main spec |
|-------------------|---------------------------|
| **ADDED** Requirements | Append to the Requirements section |
| **MODIFIED** Requirements | Replace the matching requirement |
| **REMOVED** Requirements | Delete after recording Reason/Migration |
| **RENAMED** Requirements | Rename preserving scenarios unless the delta modifies them |

Careful merge (`SKILL.md:139-145`): match requirements by name (e.g. "### Requirement: Session Expiration"); **PRESERVE all OTHER requirements not in the delta**; keep Markdown format and heading hierarchy; for REMOVED require `(Reason: ...)` and `(Migration: ...)` notes before deleting; for RENAMED require explicit old and new names.

### If the main spec does NOT exist `[CERT]`

The delta spec IS a complete spec (not a delta). It is copied directly: `openspec/changes/{change}/specs/{domain}/spec.md → openspec/specs/{domain}/spec.md` (`SKILL.md:146-152`).

> [CERT] "ALWAYS sync delta specs BEFORE moving to archive" (`SKILL.md:228`). "When merging into existing specs, PRESERVE requirements not mentioned in the delta" (`SKILL.md:229`). If the merge would be destructive (removing large sections), WARN the orchestrator and ask for confirmation (`SKILL.md:232`).

## 12.7 — Step 3: Move to Archive `[CERT]`

`SKILL.md:155-169`. In `engram`/`none` it is skipped (there are no `openspec/` directories; the report in Engram is the audit trail). In `openspec`/`hybrid` it moves the entire folder with an ISO date prefix:

```
openspec/changes/{change-name}/
  → openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Today's ISO date (e.g. `2026-07-28`) (`SKILL.md:169, 231`). If `openspec/changes/archive/` does not exist, create it (`SKILL.md:234`).

## 12.8 — Step 4: Verify Archive `[CERT]`

`SKILL.md:171-183`. In `openspec`/`hybrid` it confirms: main specs updated; folder moved to archive; archive contains all artifacts (proposal, specs, design, tasks); archived `tasks.md` with no unchecked implementation tasks (except approved reconciliation); the active changes directory no longer has this change. In `engram` it confirms that all observation IDs are recorded and the tasks observation has no unchecked tasks (except approved reconciliation).

> [CERT] "The archive is an AUDIT TRAIL — never delete or modify archived changes" (`SKILL.md:233`).

## 12.9 — Action Context Guard `[CERT]`

`SKILL.md:107-110`: if the structured status reports `actionContext.mode: workspace-planning`, STOP — do not move workspace changes to repo-local archives nor edit linked repos. If `allowedEditRoots` is present, archive operations must stay within those roots.

## 12.10 — Assigned model and tools `[CERT]`

`agents/sdd-archive.md:7`: `model: haiku` (Model Assignments [Block 18]: "sdd-archive | haiku | default | Copy and close"). It is the cheapest phase along with onboard — the work is mechanical (copy, move, record).

**Tools** (`agents/sdd-archive.md:8`): `Read, Edit, Write, Glob, mem_search, mem_get_observation, mem_save, codegraph_explore`. Note: it has `Edit`/`Write` (for the spec merge and moving files via editing), but NO `Bash`, NO `Grep`, NO `mem_update`.

`[DRIFTED v1.43.2→v2.2.0]` `codegraph_explore` was added to the tool list. The v1.43.2 block listed 7 tools; v2.2.0 has 8.

## 12.11 — Result Contract `[CERT]`

The **agent** (`agents/sdd-archive.md:42-50`):

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence confirming the change is archived and closed |
| `artifacts` | topic_keys/paths (e.g. `sdd/{change}/archive-report`, archived folder path) |
| `next_recommended` | `none` (change complete) or a new `/sdd-new` if there is follow-up |
| `risks` | artifacts that could not be merged or archived cleanly |
| `skill_resolution` | `paths-injected` or `none` |

The **SKILL.md** (`SKILL.md:193-221`) defines a richer "Change Archived" markdown: Specs Synced (domain/action/details table), Archive Contents (checklist), Source of Truth Updated, "SDD Cycle Complete". `next_recommended: none` closes the cycle.

## 12.12 — Gotchas `[CERT]`

- **Native Review Receipt Gate blocks first** (`SKILL.md:77-79`, `commands/sdd-archive.md:23`): new in v2.2.0. Before task gates or spec sync, archive requires `reviewGate.result: allow`. This gate has no override. See §12.5b for the known inconsistency with disabled review mode.
- **CRITICAL in verify-report = block without override** (`SKILL.md:103, 224`): there is no way to skip a verification CRITICAL. It is the closing of the quality contract of [Block 11].
- **Stale `- [ ]` tasks block** (`SKILL.md:90-96`): archive validates but does NOT mark; marking belongs to `sdd-apply` ([Block 10]). Mechanical reconciliation is exceptional and requires proof + a recorded reason.
- **PRESERVE requirements not mentioned in the delta** (`SKILL.md:229`): the merge is additive/selective, not an overwrite of the main spec. REMOVED requires Reason+Migration; RENAMED requires explicit names.
- **gentle-ai > OpenSpec in strictness** (`SKILL.md:98-105`): OpenSpec allows archiving incomplete after confirmation; gentle-ai blocks by default.
- **`prompts/sdd/sdd-archive.md` is NO LONGER byte-identical to SKILL.md** `[DRIFTED v1.43.2→v2.2.0]`: as of v2.2.0, the prompts file has a trailing CodeGraph guidance section not in SKILL.md. Verified via diff, 2026-07-28.
- **haiku as model** (`agents/sdd-archive.md:7`): the spec merge is delicate but mechanical; `[INFER]` the risk of a destructive merge is mitigated by the "WARN if destructive" rule (`SKILL.md:232`) rather than by a more powerful model.
- **Final-State Authority hierarchy** (`SKILL.md:45-66`): new in v2.2.0. Snapshot claims from `verify-report`/`apply-progress` are lowest rank. They must be attributed to source and time, never restated in bare present tense as current facts. Unrankable contradictions are recorded explicitly, not resolved silently.

## 12.13 — Connections

- **[Block 11] (verify)** → `sdd-archive` reads `verify-report`; CRITICAL blocks without override (`SKILL.md:103`). It inherits the Task Completion Gate from verification.
- **[Block 12] → [Block 3] (backends + topic keys)**: in engram it records observation IDs of the 5 phase artifacts plus the 4 review artifacts; in openspec it moves folders. Artifact `archive-report` → `sdd/{change}/archive-report`.
- **[Block 12] → [Block 21] (openspec-convention)**: the delta spec merge (ADDED/MODIFIED/REMOVED/RENAMED) and the move to `archive/YYYY-MM-DD-{change}/` follow the OpenSpec convention.
- **[Block 10] (apply)** → it is the owner of task marking; archive only validates. Stale reconciliation requires apply-progress as proof.
- **[Block 2] (DAG)**: archive is the terminal node; `next_recommended: none`.
- **[Block 22] (phase-common + status-contract)**: Sections A–D + Action Context Guard (`workspace-planning`, `allowedEditRoots`).
- **[Block 18] (models)**: haiku, "Copy and close".
- **[Block 15] (sdd-status)**: the `reviewGate` field in structured status is now required by archive; §15.4 of [Block 15] documents the schema that carries it.
