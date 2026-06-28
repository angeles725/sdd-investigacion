# Block 3 — Artifact backends (engram/openspec/hybrid/none) and topic keys

> **WHAT IT DOCUMENTS**: This block describes the four backends where SDD persists its artifacts — `engram`, `openspec`, `hybrid`, `none` — their roles, compared capabilities, how the mode is resolved, the naming scheme (engram topic keys and openspec file paths), DAG state persistence, and the recovery protocols.
> **SCOPE**: Mode resolution, capability comparison table, per-mode read/write behavior, engram topic key format, openspec directory structure, state persistence/recovery, and the engram upsert limitation. Does NOT cover the internal detail of the conventions (see [Block 19] persistence-contract, [Block 20] engram-convention, [Block 21] openspec-convention) nor the phase DAG (see [Block 2]).
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Artifact Store Policy", §"Artifact Store Mode", §"Engram Topic Key Format", §"Recovery Rule"
> - `/home/cristian/.config/opencode/skills/_shared/persistence-contract.md` (complete)
> - `/home/cristian/.config/opencode/skills/_shared/engram-convention.md` (complete)
> - `/home/cristian/.config/opencode/skills/_shared/openspec-convention.md` (complete)
> **METHOD**: Certainty markers. `[CERT]` = verified by reading the source, with `path:line` or `path §section`. `[CERT-a]` = asserted by a source, not re-verified at primary origin. `[INFER]` = my own deduction.

---

## 3.1 — The four backends and their roles `[CERT]`

The orchestrator passes `artifact_store.mode` with one of: `engram | openspec | hybrid | none` `[CERT]` (`persistence-contract.md:5`).

Literal roles `[CERT]` (`persistence-contract.md:12-16`):

| Mode | Role `[CERT]` |
|------|------|
| `engram` | Working memory across sessions. Upserts overwrite — no iteration history. Local, not shareable. |
| `openspec` | Source of truth. Files in repo, git history, shareable with the team, full audit trail. |
| `hybrid` | Both — files for the team + engram for recovery. Higher token cost. |
| `none` | Ephemeral. Lost when the conversation ends. |

Equivalent descriptions from the policy `[CERT]` (`CLAUDE.md` §"Artifact Store Policy" / §"Artifact Store Mode"):
- `engram` — fast, no files created; best for solo work and quick iteration; re-running a phase overwrites (no history).
- `openspec` — file-based; creates an `openspec/` directory with a full trail; committable, shareable, git history.
- `hybrid` — both; higher token cost.
- `none` — returns results inline only; recommends enabling engram or openspec.

## 3.2 — Mode resolution `[CERT]`

Who and when chooses the mode `[CERT]` (`persistence-contract.md:7`, `CLAUDE.md` §"Artifact Store Mode"): the orchestrator ASKS the user which mode they want when `/sdd-new`, `/sdd-ff` or `/sdd-continue` is invoked for the first time in the session. The choice is cached for the session.

Default if the user does not specify `[CERT]` (`persistence-contract.md:9`, `CLAUDE.md` §"Artifact Store Mode"): if Engram is available → `engram`. Otherwise → `none`.

Safety rule `[CERT]` (`persistence-contract.md:74`): *"If unsure which mode to use, default to `none`"* — and NEVER force creation of `openspec/` unless the orchestrator has explicitly passed `openspec` or `hybrid` (`persistence-contract.md:73`).

The mode is passed as `artifact_store.mode` to every sub-agent launch `[CERT]` (`CLAUDE.md` §"Artifact Store Mode": "Pass it as `artifact_store.mode` to every sub-agent launch").

## 3.3 — Capability comparison table `[CERT]`

Literal comparison `[CERT]` (`persistence-contract.md:20-27`):

| Capability | `engram` | `openspec` | `hybrid` | `none` |
|-----------|----------|------------|----------|--------|
| Cross-session recovery | ✅ | ❌ (needs git) | ✅ | ❌ |
| Survives compaction | ✅ | ❌ | ✅ | ❌ |
| Shareable with team | ❌ (local DB) | ✅ (committed files) | ✅ (files) | ❌ |
| Full iteration history | ❌ (upsert overwrites) | ✅ (git history) | ✅ (files + git) | ❌ |
| Audit trail (archive) | Partial (report only) | ✅ (full folder) | ✅ (both) | ❌ |
| Project files created | Never | Yes | Yes | Never |

**Reading the mental model** `[INFER]`: there is a clear tradeoff axis — `engram` wins on recovery/compaction (the agent's persistent memory) but loses on sharing/history; `openspec` is the inverse (shareable and versionable, but does not survive compaction without git). `hybrid` pays both costs to get both guarantees. `none` guarantees nothing and is purely ephemeral.

## 3.4 — Per-mode read/write behavior `[CERT]`

Where each mode reads from and writes to `[CERT]` (`persistence-contract.md:35-40`):

| Mode | Reads from | Writes to | Project files |
|------|--------|-----------|---------------------|
| `engram` | Engram | Engram | Never |
| `openspec` | Filesystem | Filesystem | Yes |
| `hybrid` | Engram (primary) + Filesystem (fallback) | Both | Yes |
| `none` | Orchestrator's prompt context | None | Never |

Hybrid detail `[CERT]` (`persistence-contract.md:42-52`): persists each artifact to Engram AND OpenSpec simultaneously. Read priority: Engram first, fallback to filesystem if Engram returns no results. Write behavior: BOTH writes must succeed for the operation to be complete. Cost warning: hybrid consumes MORE tokens per operation.

Common rules `[CERT]` (`persistence-contract.md:69-74`):
- `none` → do NOT create or modify project files; return inline.
- `engram` → do NOT write project files; persist to Engram and return observation IDs.
- `openspec` → write files ONLY to the paths defined in `openspec-convention.md`.
- `hybrid` → persist to BOTH Engram AND filesystem.

## 3.5 — The engram topic key scheme `[CERT]`

Every SDD artifact persisted to Engram follows a deterministic naming `[CERT]` (`engram-convention.md:9-16`):

```
title:     sdd/{change-name}/{artifact-type}
topic_key: sdd/{change-name}/{artifact-type}
type:      architecture
project:   {detected or current project name}
scope:     project
capture_prompt: false
```

The per-artifact topic key map `[CERT]` (`CLAUDE.md` §"Engram Topic Key Format"):

| Artifact | Topic Key `[CERT]` | Produced by `[CERT]` (`engram-convention.md:22-32`) |
|-----------|-----------|-------------|
| Project context | `sdd-init/{project}` | sdd-init |
| Exploration | `sdd/{change-name}/explore` | sdd-explore |
| Proposal | `sdd/{change-name}/proposal` | sdd-propose |
| Spec | `sdd/{change-name}/spec` | sdd-spec (all domains concatenated) |
| Design | `sdd/{change-name}/design` | sdd-design |
| Tasks | `sdd/{change-name}/tasks` | sdd-tasks |
| Apply progress | `sdd/{change-name}/apply-progress` | sdd-apply (one per batch) |
| Verify report | `sdd/{change-name}/verify-report` | sdd-verify |
| Archive report | `sdd/{change-name}/archive-report` | sdd-archive |
| DAG state | `sdd/{change-name}/state` | orchestrator |

Note `[CERT]`: the project context uses the prefix `sdd-init/{project}` (NOT `sdd/`); all other artifacts of a change use `sdd/{change-name}/...`. `[CERT]` (`CLAUDE.md` §"Engram Topic Key Format" vs §"SDD Init Guard").

Why this convention `[CERT]` (`engram-convention.md:138-144`):
- Deterministic titles → retrieval works by exact match.
- `topic_key` → enables upserts without duplicates.
- `sdd/` prefix → namespaces all SDD artifacts.
- Two-step retrieval → search previews are always truncated; `mem_get_observation` is the only way to get full content.

## 3.6 — openspec file structure `[CERT]`

Directory structure `[CERT]` (`openspec-convention.md:5-23`):

```
openspec/
├── config.yaml              <- Project SDD config
├── specs/                   <- Source of truth (main specs)
│   └── {domain}/spec.md
└── changes/                 <- Active changes
    ├── archive/             <- Completed changes (YYYY-MM-DD-{change-name}/)
    └── {change-name}/       <- Active change folder
        ├── state.yaml       <- DAG state (survives compaction)
        ├── exploration.md   <- (optional) from sdd-explore
        ├── proposal.md      <- from sdd-propose
        ├── specs/{domain}/spec.md  <- Delta spec, from sdd-spec
        ├── design.md        <- from sdd-design
        ├── tasks.md         <- from sdd-tasks (updated by sdd-apply)
        └── verify-report.md <- from sdd-verify
```

Paths by skill `[CERT]` (`openspec-convention.md:27-40`): each phase writes to its canonical path. Operational notes:
- `sdd-apply` UPDATES `tasks.md` by checking `[x]` (does not create a new file). `[CERT]`
- `sdd-archive` MOVES the change folder to `openspec/changes/archive/YYYY-MM-DD-{change-name}/` AND merges the deltas into `openspec/specs/{domain}/spec.md`. `[CERT]`

Conceptual difference engram vs openspec `[INFER]`: in engram the spec is ONE artifact (`sdd/{change-name}/spec`, "all domains concatenated", `engram-convention.md:26`); in openspec the spec is broken down by domain into subdirectories (`specs/{domain}/spec.md`). It is the same information with different storage granularity.

Write rule `[CERT]` (`openspec-convention.md:54-58`): always create the change directory before writing; if a file already exists, READ it first and UPDATE it (do not blindly overwrite); if the folder already has artifacts, the change is being CONTINUED.

## 3.7 — DAG state persistence and recovery `[CERT]`

The orchestrator persists the DAG state after each phase transition to enable recovery after compaction `[CERT]` (`persistence-contract.md:54-63`):

| Mode | Persist state | Recover state `[CERT]` |
|------|------------------|------------------|
| `engram` | `mem_save(topic_key: "sdd/{change-name}/state", capture_prompt: false)` | `mem_search("sdd/*/state")` → `mem_get_observation(id)` |
| `openspec` | Write `openspec/changes/{change-name}/state.yaml` | Read `state.yaml` |
| `hybrid` | Both: `mem_save` AND write `state.yaml` | Engram first; filesystem fallback |
| `none` | Not possible — warn the user | Not possible |

Content of the `state` artifact in engram `[CERT]` (`engram-convention.md:38-46`): includes `change`, `phase`, `artifact_store`, `artifacts` flags (proposal/specs/design/tasks), `tasks_progress` (completed/pending) and `last_updated` (ISO date).

Global Recovery Rule `[CERT]` (`CLAUDE.md` §"Recovery Rule"):
- `engram` → `mem_search(...)` → `mem_get_observation(...)`
- `openspec` → read `openspec/changes/*/state.yaml`
- `none` → state not persisted — explain to the user.

## 3.8 — The engram upsert limitation `[CERT]`

Engram uses `topic_key`-based upserts. Re-running a phase for the same change **OVERWRITES** the previous version — no revision history is kept `[CERT]` (`persistence-contract.md:29-31`).

Detail `[CERT]` (`engram-convention.md:136`): same `topic_key` + `project` + `scope` → UPDATE (overwrite), not INSERT. The previous content is LOST — `revision_count` increments but the old content is NOT saved. It is by design: engram is working memory, not an audit trail. For iteration history or team collaboration → use `openspec` or `hybrid`.

The archive phase in engram saves a summary report, NOT the full folder of artifacts `[CERT]` (`persistence-contract.md:31`).

**Practical consequence** `[INFER]`: if you need traceability of how a proposal or a spec evolved across iterations, `engram` does not serve — it overwrites. The backend choice in §3.2 is, at bottom, a decision about how much history and shareability you need versus how much token cost and project files you are willing to pay.

## 3.9 — Project name resolution `[CERT]`

Engram auto-detects the project name from the git remote at MCP startup `[CERT]` (`engram-convention.md:128-132`). The `--project` flag and the `ENGRAM_PROJECT` env var can override the detection. All names are normalized to lowercase and trimmed. If saved under a name that does not match existing observations, engram warns of possible "name drift"; it is consolidated with `mem_merge_projects` (MCP) or `engram projects consolidate` (CLI).

## 3.10 — Connections

- **[Block 2] — Phase DAG and Result Contract**: the topic keys of §3.5 and the file paths of §3.6 are the destinations where each DAG phase (§2.2) persists its artifact. The mandatory persistence of §2.6 is backend-dependent and is detailed here by mode.
- **[Block 19] — persistence-contract**: this block summarizes `persistence-contract.md`; [Block 19] covers it in depth, including the "Sub-Agent Context Rules" and the orchestrator's prompt instructions for sub-agents.
- **[Block 20] — engram-convention**: deepens the naming scheme, the two-step retrieval protocol, the upsert behavior and the project name resolution summarized here.
- **[Block 21] — openspec-convention**: details the directory structure, the delta spec sections (`ADDED`/`MODIFIED`/`REMOVED`/`RENAMED`), and the `config.yaml` only mentioned here.
- **[Block 1] — What SDD is**: the decision of who reads and who writes context (orchestrator vs sub-agent, SDD vs non-SDD) introduced philosophically in §1.2 materializes in the read/write behavior of §3.4.
