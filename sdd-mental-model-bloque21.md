# Block 21 — OpenSpec convention (`openspec-convention`)

> **WHAT IT DOCUMENTS**: This block documents the OpenSpec file convention: the `openspec/` directory structure (config, source specs, active changes, archive), the file paths of each artifact per skill, the read/write rules, the delta spec sections (`ADDED` / `MODIFIED` / `REMOVED` / `RENAMED`), the `config.yaml` format, and the archive structure with ISO dating.
> **SCOPE**: The OpenSpec-backend-specific convention (file-based). It does NOT cover the cross-cutting persistence contract (see [Block 19]) nor the Engram convention (see [Block 20]). It does NOT document the internal content of each artifact (what goes inside a proposal, a design, etc. — see the phase blocks).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/_shared/openspec-convention.md` (full file, 120 lines)
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section` when possible. `[CERT-a]` = asserted by the source but not re-verified at its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 21.1 — Directory structure `[CERT]`

The convention sets a canonical directory structure `[CERT]` (`openspec-convention.md:5-23`):

```
openspec/
├── config.yaml              <- Project-specific SDD config
├── specs/                   <- Source of truth (main specs)
│   └── {domain}/
│       └── spec.md
└── changes/                 <- Active changes
    ├── archive/             <- Completed changes (YYYY-MM-DD-{change-name}/)
    └── {change-name}/       <- Active change folder
        ├── state.yaml       <- DAG state (survives compaction)
        ├── exploration.md   <- (optional) from sdd-explore
        ├── proposal.md      <- from sdd-propose
        ├── specs/           <- from sdd-spec
        │   └── {domain}/
        │       └── spec.md  <- Delta spec
        ├── design.md        <- from sdd-design
        ├── tasks.md         <- from sdd-tasks (updated by sdd-apply)
        └── verify-report.md <- from sdd-verify
```

**Key architectural distinction** `[CERT]`: there are TWO levels of specs `[INFER]` — `openspec/specs/{domain}/spec.md` is the **source of truth** (accumulated main specs), while `openspec/changes/{change-name}/specs/{domain}/spec.md` is the **delta spec** of the in-progress change. Archive merges the delta into the source of truth (see §21.5-§21.6).

## 21.2 — Artifact file paths per skill `[CERT]`

| Skill | Creates / Reads | Path `[CERT]` (`openspec-convention.md:27-39`) |
|-------|-----------|------|
| orchestrator | Creates/Updates | `openspec/changes/{change-name}/state.yaml` |
| sdd-init | Creates | `openspec/config.yaml`, `openspec/specs/`, `openspec/changes/`, `openspec/changes/archive/` |
| sdd-explore | Creates (optional) | `openspec/changes/{change-name}/exploration.md` |
| sdd-propose | Creates | `openspec/changes/{change-name}/proposal.md` |
| sdd-spec | Creates | `openspec/changes/{change-name}/specs/{domain}/spec.md` |
| sdd-design | Creates | `openspec/changes/{change-name}/design.md` |
| sdd-tasks | Creates | `openspec/changes/{change-name}/tasks.md` |
| sdd-apply | Updates | `openspec/changes/{change-name}/tasks.md` (marks `[x]`) |
| sdd-verify | Creates | `openspec/changes/{change-name}/verify-report.md` |
| sdd-archive | Moves | `openspec/changes/{change-name}/` → `openspec/changes/archive/YYYY-MM-DD-{change-name}/` |
| sdd-archive | Updates | `openspec/specs/{domain}/spec.md` (merges deltas into main specs) |

**Reading artifacts** `[CERT]` (`openspec-convention.md:43-51`): proposal, specs (all domain subdirectories), design, tasks, verify-report under `openspec/changes/{change-name}/`; config in `openspec/config.yaml`; main specs in `openspec/specs/{domain}/spec.md`.

## 21.3 — Write rules `[CERT]`

Operational write rules `[CERT]` (`openspec-convention.md:53-58`):

- Always create the change directory BEFORE writing artifacts.
- If a file already exists, READ it first and UPDATE it (do not blindly overwrite).
- If the change directory already exists with artifacts, the change is being CONTINUED.
- Use the `rules` section of `openspec/config.yaml` for project-specific per-phase constraints.

**Implication** `[INFER]`: the rule "if the directory exists → it is being continued" is how OpenSpec derives the continuation state WITHOUT a central registry — the presence of files IS the state. This contrasts with `engram` where the state lives in the `state` artifact (see [Block 20] §20.3).

## 21.4 — Delta spec sections `[CERT]`

Delta specs MAY include these sections `[CERT]` (`openspec-convention.md:62-74`):

```markdown
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

Merge semantics `[CERT]`:

| Section | Effect when merging into the main spec |
|---------|------------------------------------------|
| `ADDED` | Adds new requirements to the main spec |
| `MODIFIED` | Replaces the entire block of the matching requirement. The delta MUST contain the whole updated requirement, including unchanged scenarios that must be preserved |
| `REMOVED` | Deletes the matching requirement. Each one MUST include `(Reason: ...)` and SHOULD include `(Migration: ...)` when it affects consumers or persisted behavior |
| `RENAMED` | Changes the heading/name without changing behavior (unless the delta also includes a `MODIFIED` block for the new requirement). Each rename MUST declare old and new names explicitly |

**Key point** `[INFER]`: the delta spec is a declarative diff of requirements, not a monolithic file. The `MODIFIED` rule ("contain the whole requirement, including unchanged scenarios") is critical — the merge REPLACES the entire block, so omitting an unchanged scenario would delete it. It is the most subtle trap of the convention.

## 21.5 — Configuration file `config.yaml` `[CERT]`

The `config.yaml` defines context and per-phase rules `[CERT]` (`openspec-convention.md:78-110`):

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

Notable elements `[CERT]`:

- `schema: spec-driven` identifies the config type.
- `context` carries detected stack/architecture/testing/style (populated by `sdd-init`).
- `rules` has a sub-key per phase. The rules are project-specific constraints that each phase consumes.
- `apply.tdd: false` is the flag that activates RED-GREEN-REFACTOR when set to `true` (see [Block 23]), with an associated `test_command`.
- `verify` carries `test_command`, `build_command`, and `coverage_threshold`.

## 21.6 — Archive structure `[CERT]`

On archiving, the change folder is moved to `[CERT]` (`openspec-convention.md:113-119`):

```
openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Rules `[CERT]`:

- Use today's date in ISO format.
- The archive is an **AUDIT TRAIL** — NEVER delete or modify archived changes.

**Mental model** `[INFER]`: the dated archive is what gives `openspec` its full audit trail capability (the "Audit trail" row of the table in [Block 19] §19.2). `engram` only keeps a summary report; here the whole folder remains, immutable, dated. That immutability is the difference between "working memory" and "historical record".

## 21.7 — Connections

- **[Block 3] — Backends**: [Block 3] introduces `openspec` as one of the four backends; this block details its concrete file structure. The source-specs vs. delta-specs distinction (§21.1) is specific to this backend.
- **[Block 19] — Persistence contract**: §19.4 establishes that the `openspec`/`hybrid` mode writes "ONLY in the paths defined in `openspec-convention.md`" — those paths are §21.2 of this block. The `state.yaml` of §21.1 is the file-based equivalent of Engram's `state` artifact.
- **[Block 15] — Status and native dispatcher**: the native dispatcher (`gentle-ai sdd-status`/`sdd-continue`) reads ONLY the OpenSpec file artifacts under `openspec/changes/` — the structure of §21.1 is exactly what the dispatcher observes. That is why the dispatcher is blind to `engram` changes (see [Block 22] §22.3).
- **[Block 20] — Engram convention**: the mirror of this convention in the memory backend. The note of [Block 20] §20.2 (concatenated spec in Engram vs. per-domain spec in files) marks the structural difference: here each domain has its own `specs/{domain}/spec.md`.
- **[Block 23] — Strict-TDD**: the `apply.tdd` flag of §21.5 is the file-based switch that activates the strict TDD mode detailed in [Block 23].
- **[Block 12] — Archive**: §21.6 (archive structure) and the sdd-archive row of §21.2 (merging deltas into main specs) are the archive mechanics that [Block 12] develops at the phase level.
