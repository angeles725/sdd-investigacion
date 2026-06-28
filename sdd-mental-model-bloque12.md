# Block 12 — `sdd-archive` Phase

> **WHAT**: Documents the `sdd-archive` phase of gentle-ai's SDD system: the closing of the cycle. It merges the delta specs into the main specs (source of truth), moves the change folder to the archive with a date prefix, and persists an archive-report with traceability. It is strict: it blocks on uncompleted tasks or CRITICAL issues in verify.
>
> **SCOPE**: Purpose, what it reads/writes (artifact + topic key), the Task Completion Gate, the Strict-vs-OpenSpec Archive Policy, the delta spec merge (ADDED/MODIFIED/REMOVED/RENAMED), the move to archive, verification, assigned model, Result Contract and gotchas.
>
> **EXACT SOURCES**:
> - `/home/cristian/.config/opencode/skills/sdd-archive/SKILL.md` (primary)
> - `/home/cristian/.claude/agents/sdd-archive.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-archive.md` (identical to SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-archive.md` (orchestrator gates)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source; `[INFER]` = deduction.

---

## 12.1 — Purpose and role `[CERT]`

`sdd-archive` is the EXECUTOR sub-agent responsible for ARCHIVING. It merges the delta specs into the main specs (source of truth), then moves the change folder to the archive. It completes the SDD cycle (`skills/sdd-archive/SKILL.md:32-34`). Same gate/override pattern (`SKILL.md:13-21`). Version `2.0`.

The archive closes the DAG ([Block 2]): `proposal → specs → tasks → apply → verify → archive`. After archive, "Ready for the next change" (`SKILL.md:191-192`).

## 12.2 — What it receives from the orchestrator `[CERT]`

`SKILL.md:36-42`: Change name; Artifact store mode; Structured status from `sdd-status-contract.md` (artifact paths, task progress, dependency states, actionContext); and any explicit text for an intentional archive override from the user/orchestrator.

## 12.3 — What it READS and what it WRITES `[CERT]`

`SKILL.md:44-51`:

| Mode | Reads (all required) | Writes |
|------|------------------------|---------|
| `engram` | `sdd/{change}/proposal`, `/spec`, `/design`, `/tasks`, `/verify-report` (records ALL observation IDs for traceability) | `sdd/{change}/archive-report` |
| `openspec` | follows `openspec-convention.md` | spec merge + folder move to archive |
| `hybrid` | both | Engram (report with IDs) + filesystem merge + folder move |
| `none` | returns closure summary only | nothing (no archive operations) |

**Artifact produced**: `archive-report` · **topic key**: `sdd/{change-name}/archive-report` · **type**: `architecture` (`SKILL.md:160-163`, [Block 3]).

> [CERT] It is the only phase that READS the `verify-report` (`agents/sdd-archive.md:25`): it needs to confirm that verification passed before closing. In engram it records the observation IDs of the 5 artifacts in the report so that the archive is a navigable audit trail.

## 12.4 — Task Completion Gate `[CERT]`

The most important entry guard. `sdd-apply` ([Block 10]) is responsible for marking tasks complete; `sdd-archive` VALIDATES that the persisted artifact reflects the final state before closing (`SKILL.md:53-56`).

Before syncing specs or moving any folder, it inspects the tasks artifact (engram: reads the `sdd/{change}/tasks` observation; openspec/hybrid: reads `tasks.md`). If any implementation task is still unchecked (`- [ ]`) (`SKILL.md:62-68`):

1. STOP and return `blocked`; do NOT sync specs, do NOT move the folder, do NOT claim cycle complete.
2. Report that `sdd-apply` must re-run or be corrected to mark the tasks.
3. Only proceed if the orchestrator EXPLICITLY instructs reconciling stale checkboxes AND `apply-progress`/`verify-report` prove that every unchecked task is complete. If this exceptional repair is done, record the exact reason in the archive report.

> [CERT] "The archived audit trail MUST NOT contain stale unchecked tasks for completed work. Internal todo state is not enough; the persisted SDD task artifact is the source of truth for completion visibility" (`SKILL.md:68`).

## 12.5 — Strict-vs-OpenSpec Archive Policy `[CERT]`

OpenSpec allows archiving with incomplete artifacts/tasks after a user confirmation. gentle-ai is MORE STRICT by default (`SKILL.md:70-77`):

- Incomplete implementation tasks BLOCK the archive, unless they are stale checkboxes and apply-progress/verify-report prove completeness.
- **CRITICAL issues in `verify-report` ALWAYS block the archive. NO override is accepted for CRITICAL verification issues** (`SKILL.md:75`).
- `sdd-archive` is NOT the owner of normal task completeness: `sdd-apply` owns checkbox marking; archive only does exceptional mechanical reconciliation with proof from apply-progress and verify-report.
- Missing proposal/spec/design artifacts must be reported. The archive only continues if the user explicitly chooses an intentional partial archive AND the report records what was missing.

This is reinforced in the Rules (`SKILL.md:196-205`): "NEVER archive a change that has CRITICAL issues in its verification report"; "NEVER archive completed work while `tasks.md` / the tasks observation still shows stale unchecked implementation tasks". The orchestrator's command duplicates it as a hard gate: "If verify-report contains CRITICAL issues, do NOT archive. There is no CRITICAL override" (`commands/sdd-archive.md:28`).

## 12.6 — Step 2: Sync Delta Specs to Main Specs `[CERT]`

The distinctive step of archive — the consolidation of the source of truth. It does NOT start until the Task Completion Gate passes (`SKILL.md:89-91`).

- **`engram`**: skip filesystem sync — the artifacts live only in Engram; the archive report records the observation IDs (`SKILL.md:93`).
- **`none`**: skip — there are no artifacts to sync.
- **`openspec`/`hybrid`**: for each delta spec in `openspec/changes/{change}/specs/` (`SKILL.md:97-126`):

### If the main spec exists (`openspec/specs/{domain}/spec.md`) `[CERT]`

It reads the existing main spec and applies the delta (`SKILL.md:103-116`):

| Delta section | Action on the main spec |
|-------------------|---------------------------|
| **ADDED** Requirements | Append to the Requirements section |
| **MODIFIED** Requirements | Replace the matching requirement |
| **REMOVED** Requirements | Delete after recording Reason/Migration |
| **RENAMED** Requirements | Rename preserving scenarios unless the delta modifies them |

Careful merge (`SKILL.md:111-116`): match requirements by name (e.g. "### Requirement: Session Expiration"); **PRESERVE all OTHER requirements not in the delta**; keep Markdown format and heading hierarchy; for REMOVED require `(Reason: ...)` and `(Migration: ...)` notes before deleting; for RENAMED require explicit old and new names.

### If the main spec does NOT exist `[CERT]`

The delta spec IS a complete spec (not a delta). It is copied directly: `openspec/changes/{change}/specs/{domain}/spec.md → openspec/specs/{domain}/spec.md` (`SKILL.md:118-126`).

> [CERT] "ALWAYS sync delta specs BEFORE moving to archive" (`SKILL.md:200`). "When merging into existing specs, PRESERVE requirements not mentioned in the delta" (`SKILL.md:201`). If the merge would be destructive (removing large sections), WARN the orchestrator and ask for confirmation (`SKILL.md:203`).

## 12.7 — Step 3: Move to Archive `[CERT]`

`SKILL.md:128-141`. In `engram`/`none` it is skipped (there are no `openspec/` directories; the report in Engram is the audit trail). In `openspec`/`hybrid` it moves the entire folder with an ISO date prefix:

```
openspec/changes/{change-name}/
  → openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Today's ISO date (e.g. `2026-02-16`) (`SKILL.md:141, 202`). If `openspec/changes/archive/` does not exist, create it (`SKILL.md:205`).

## 12.8 — Step 4: Verify Archive `[CERT]`

`SKILL.md:143-154`. In `openspec`/`hybrid` it confirms: main specs updated; folder moved to archive; archive contains all artifacts (proposal, specs, design, tasks); archived `tasks.md` with no unchecked implementation tasks (except approved reconciliation); the active changes directory no longer has this change. In `engram` it confirms that all observation IDs are recorded and the tasks observation has no unchecked tasks (except approved reconciliation).

> [CERT] "The archive is an AUDIT TRAIL — never delete or modify archived changes" (`SKILL.md:204`).

## 12.9 — Action Context Guard `[CERT]`

`SKILL.md:79-82`: if the structured status reports `actionContext.mode: workspace-planning`, STOP — do not move workspace changes to repo-local archives nor edit linked repos. If `allowedEditRoots` is present, archive operations must stay within those roots.

## 12.10 — Assigned model and tools `[CERT]`

`agents/sdd-archive.md:7`: `model: haiku` (Model Assignments [Block 18]: "sdd-archive | haiku | default | Copy and close"). It is the cheapest phase along with onboard — the work is mechanical (copy, move, record).

**Tools** (`agents/sdd-archive.md:8`): `Read, Edit, Write, Glob, mem_search, mem_get_observation, mem_save`. Note: it has `Edit`/`Write` (for the spec merge and moving files via editing), but NO `Bash` (it does not run shell commands for the `mv` — [INFER] it uses Read+Write to reconstruct/move), NO `Grep`, NO `mem_update`.

## 12.11 — Result Contract `[CERT]`

The **agent** (`agents/sdd-archive.md:40-48`):

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence confirming the change is archived and closed |
| `artifacts` | topic_keys/paths (e.g. `sdd/{change}/archive-report`, archived folder path) |
| `next_recommended` | `none` (change complete) or a new `/sdd-new` if there is follow-up |
| `risks` | artifacts that could not be merged or archived cleanly |
| `skill_resolution` | `paths-injected` or `none` |

The **SKILL.md** (`SKILL.md:165-193`) defines a richer "Change Archived" markdown: Specs Synced (domain/action/details table), Archive Contents (checklist), Source of Truth Updated, "SDD Cycle Complete". `next_recommended: none` closes the cycle.

## 12.12 — Gotchas `[CERT]`

- **CRITICAL in verify-report = block without override** (`SKILL.md:75, 197`): unlike other conditions, there is no way to skip a verification CRITICAL. It is the closing of the quality contract of [Block 11].
- **Stale `- [ ]` tasks block** (`SKILL.md:62-68`): archive validates but does NOT mark; marking belongs to `sdd-apply` ([Block 10]). Mechanical reconciliation is exceptional and requires proof + a recorded reason.
- **PRESERVE requirements not mentioned in the delta** (`SKILL.md:201`): the merge is additive/selective, not an overwrite of the main spec. REMOVED requires Reason+Migration; RENAMED requires explicit names.
- **gentle-ai > OpenSpec in strictness** (`SKILL.md:70-77`): OpenSpec allows archiving incomplete after confirmation; gentle-ai blocks by default.
- **The prompt `prompts/sdd/sdd-archive.md` is byte-identical to SKILL.md** [CERT — compared]: no divergent condensed version (unlike apply/verify).
- **haiku as model** (`agents/sdd-archive.md:7`): the spec merge is delicate but mechanical; [INFER] the risk of a destructive merge is mitigated by the "WARN if destructive" rule (`SKILL.md:203`) rather than by a more powerful model.

## 12.13 — Connections

- **[Block 11] (verify)** → `sdd-archive` reads `verify-report`; CRITICAL blocks without override (`SKILL.md:75`, `agents/sdd-archive.md:25`). It inherits the Task Completion Gate from verification.
- **[Block 12] → [Block 3] (backends + topic keys)**: in engram it records observation IDs of the 5 artifacts; in openspec it moves folders. Artifact `archive-report` → `sdd/{change}/archive-report`.
- **[Block 12] → [Block 21] (openspec-convention)**: the delta spec merge (ADDED/MODIFIED/REMOVED/RENAMED) and the move to `archive/YYYY-MM-DD-{change}/` follow the OpenSpec convention.
- **[Block 10] (apply)** → it is the owner of task marking; archive only validates. Stale reconciliation requires apply-progress as proof.
- **[Block 2] (DAG)**: archive is the terminal node; `next_recommended: none`.
- **[Block 22] (phase-common + status-contract)**: Sections A–D + Action Context Guard (`workspace-planning`, `allowedEditRoots`).
- **[Block 18] (models)**: haiku, "Copy and close".
