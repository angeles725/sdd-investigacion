# Block 20 — Engram convention (`engram-convention`)

> **WHAT IT DOCUMENTS**: This block documents the Engram artifact convention: the deterministic naming rules (title, topic_key, type, project, scope, capture_prompt), the SDD artifact type table, the DAG state artifact, the two-step recovery protocol (`mem_search` → `mem_get_observation`), artifact writing (`mem_save` / `mem_update`), project name resolution, the upsert behavior by `topic_key`, and the lifecycle rules (`active` / `needs_review`).
> **SCOPE**: The Engram-backend-specific convention. It does NOT cover the cross-cutting persistence contract (mode resolution, hybrid, prompt templates — see [Block 19]) nor the OpenSpec convention (see [Block 21]). It does NOT document the detail of each phase that produces the artifacts (see the phase blocks).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/_shared/engram-convention.md` (full file, 145 lines)
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section` when possible. `[CERT-a]` = asserted by the source but not re-verified at its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 20.1 — Deterministic naming rules `[CERT]`

ALL SDD artifacts persisted to Engram MUST follow this deterministic naming `[CERT]` (`engram-convention.md:7-16`):

```
title:     sdd/{change-name}/{artifact-type}
topic_key: sdd/{change-name}/{artifact-type}
type:      architecture
project:   {detected or current project name}
scope:     project
capture_prompt: false
```

`capture_prompt: false` is set when the Engram tool schema supports it; if an older schema rejects it or does not expose the field, it is omitted rather than failed `[CERT]` (`engram-convention.md:18`).

**Design note** `[CERT]` (`engram-convention.md:3`): the critical Engram calls (`mem_search`, `mem_save`, `mem_get_observation`) are inlined directly into each skill's `SKILL.md`. This document is supplementary reference — sub-agents do NOT need to read it to function.

## 20.2 — Artifact types `[CERT]`

| Artifact Type | Produced by | Description `[CERT]` (`engram-convention.md:22-32`) |
|---------------|---------------|-------------|
| `explore` | sdd-explore | Exploration analysis |
| `proposal` | sdd-propose | Change proposal |
| `spec` | sdd-spec | Delta specifications (all domains concatenated) |
| `design` | sdd-design | Technical design |
| `tasks` | sdd-tasks | Task breakdown |
| `apply-progress` | sdd-apply | Implementation progress (one per batch) |
| `verify-report` | sdd-verify | Verification report |
| `archive-report` | sdd-archive | Archive closure with lineage |
| `state` | orchestrator | DAG state for recovery after compaction |

**Key point** `[INFER]`: the note "spec: all domains concatenated" means that in Engram the `spec` artifact is a single blob with all domains together, unlike OpenSpec which separates them into per-domain subdirectories (see [Block 21]). It is the same structured information in two forms depending on the backend.

## 20.3 — The state artifact (`state`) `[CERT]`

The DAG state is persisted as an Engram artifact with its own topic_key `[CERT]` (`engram-convention.md:38-47`):

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

The `content` is serialized YAML: `change`, `phase` (last phase), `artifact_store`, an `artifacts` map with booleans per phase, `tasks_progress` (completed/pending), and `last_updated` in ISO `[CERT]`.

**State recovery** `[CERT]` (`engram-convention.md:49`): `mem_search("sdd/{change-name}/state")` → `mem_get_observation(id)` → parse YAML → restore state.

## 20.4 — Two-step recovery protocol `[CERT]`

The recovery of any SDD artifact is ALWAYS two-step, because search previews are truncated `[CERT]` (`engram-convention.md:61-64`):

```
Step 1: mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → truncated preview + ID
Step 2: mem_get_observation(id: {observation-id}) → full content
```

When recovering multiple artifacts, ALL searches are grouped first and then ALL retrievals `[CERT]` (`engram-convention.md:66-78`):

```
STEP A — SEARCH (IDs only):
  mem_search(query: "sdd/{change-name}/proposal", ...) → save ID
  mem_search(query: "sdd/{change-name}/spec", ...)     → save ID
  mem_search(query: "sdd/{change-name}/design", ...)   → save ID

STEP B — RETRIEVE FULL CONTENT (mandatory):
  mem_get_observation(id: {proposal_id})
  mem_get_observation(id: {spec_id})
  mem_get_observation(id: {design_id})
```

Load the project context `[CERT]` (`engram-convention.md:80-84`):

```
mem_search(query: "sdd-init/{project}", project: "{project}") → ID
mem_get_observation(id) → full project context
```

**Why two steps** `[CERT]` (`engram-convention.md:143`): search previews are ALWAYS truncated; `mem_get_observation` is the ONLY way to obtain full content. Skipping step 2 produces incorrect output (see also [Block 22] §22.2-B).

## 20.5 — Writing artifacts `[CERT]`

Standard write `[CERT]` (`engram-convention.md:88-98`):

```
mem_save(
  title: "sdd/{change-name}/{artifact-type}",
  topic_key: "sdd/{change-name}/{artifact-type}",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "{full markdown content}"
)
```

Concrete example — save a proposal for `add-dark-mode` `[CERT]` (`engram-convention.md:100-110`): `title`/`topic_key` = `"sdd/add-dark-mode/proposal"`, `project: "my-app"`.

`capture_prompt: false` is REQUIRED for SDD artifacts when the schema supports it `[CERT]` (`engram-convention.md:112`). Engram v1.15.3 captures user prompts by default for human/proactive saves, but SDD artifacts are automated pipeline outputs. It is NOT inferred from the `type`, because both SDD and human architecture decisions use `architecture`. Older schema → omit rather than fail.

**Update vs. save** `[CERT]` (`engram-convention.md:114-119`):

- `mem_update(id, content)` → when you have the exact observation ID.
- `mem_save` with the same `topic_key` → for upserts.

**Browsing all artifacts of a change** `[CERT]` (`engram-convention.md:121-126`): `mem_search(query: "sdd/{change-name}/", project: "{project}")` returns all artifacts of that change.

## 20.6 — Project name resolution (engram v1.11.0+) `[CERT]`

Engram auto-detects the project name from the git remote at MCP startup `[CERT]` (`engram-convention.md:128-132`). The `--project` flag and the `ENGRAM_PROJECT` env var can override the detection. All names are normalized to lowercase and trimmed.

If the agent saves a memory under a project name that does not match existing observations, Engram warns about potential "name drift". To merge variants: `mem_merge_projects` (MCP tool) or `engram projects consolidate` (CLI) `[CERT]`.

## 20.7 — Upsert behavior `[CERT]`

Same `topic_key` + `project` + `scope` → UPDATE (overwrite), NOT INSERT `[CERT]` (`engram-convention.md:134-136`). The previous content is LOST — `revision_count` increments but the old content is NOT saved.

This is **by design**: Engram is working memory, NOT an audit trail. For iteration history or team collaboration, use `openspec` or `hybrid` (see [Block 19] §19.2, [Block 21]).

**Mental model** `[INFER]`: the triple `topic_key + project + scope` is the effective primary key. Re-running an SDD phase does not accumulate versions — it overwrites the previous one. This is what makes `engram` cheap (no explosion of duplicates) but "amnesic" regarding history. The decision to use a `topic_key` identical to the `title` (§20.1) is what enables the upsert without duplicates.

## 20.8 — Lifecycle rules (`active` / `needs_review`) `[CERT]`

The convention sets a memory lifecycle protocol when Engram exposes lifecycle metadata/tooling `[CERT]` (`engram-convention.md:53-59`):

- At session start or before architecture-sensitive work, call `mem_review` with action `list` for the current project when the tool is available.
- If `mem_review` is not available, do NOT fail the task. Continue with normal `mem_context`/`mem_search`, and still apply lifecycle metadata from returned observations when present.
- `active` memories may be used normally.
- `needs_review` memories are **stale context, NOT trusted facts**.
- Surfacing: expose the `needs_review` context and verify it against current evidence before relying on it.
- Do NOT call `mem_review` with action `mark_reviewed` automatically. Only call `mark_reviewed` after explicit user confirmation or through a dedicated memory maintenance command.

**Key point** `[INFER]`: the lifecycle introduces a trust distinction within the memory — not every retrieved observation is a fact. `needs_review` is a signal of "this may be out of date, verify it before acting". And `mark_reviewed` is protected against automation precisely so that the system does not self-certify stale memory as trustworthy.

## 20.9 — Why this convention `[CERT]`

The convention justifies its decisions `[CERT]` (`engram-convention.md:138-144`):

- Deterministic titles → recovery works by exact match.
- `topic_key` → enables upserts without duplicates.
- `sdd/` prefix → namespaces all SDD artifacts.
- Two-step recovery → search previews are always truncated; `mem_get_observation` is the only path to full content.
- Lineage → the `archive-report` includes all observation IDs for full traceability.

## 20.10 — Connections

- **[Block 3] — Backends and topic keys**: [Block 3] introduces the topic keys table at the conceptual level; this block details it with the full naming, the upsert behavior, and the lifecycle. The format `sdd/{change-name}/{artifact-type}` is the shared centerpiece.
- **[Block 19] — Persistence contract**: §19.5 (DAG state) and §19.7 (`mem_save` templates) consume this convention. The "upsert overwrites without history" limitation of [Block 19] §19.2 is exactly §20.7 of this block.
- **[Block 15] — Status (engram)**: the `state` artifact of §20.3 feeds the manual status reconstruction when the store is `engram` (the native dispatcher does not observe Engram — see [Block 22] §22.3). Engram status recovery uses the two-step protocol of §20.4.
- **[Block 21] — OpenSpec convention**: the file-based equivalent of this convention. The note of §20.2 (concatenated spec vs. per-domain spec) marks the structural difference between both backends.
- **[Block 22] — phase-common**: `sdd-phase-common.md` inlines the recovery protocol (§20.4) and persistence (§20.5) documented here as reference.
