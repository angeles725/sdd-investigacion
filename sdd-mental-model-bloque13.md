# Block 13 — `sdd-onboard` Phase

> **WHAT**: Documents the `sdd-onboard` phase of gentle-ai's SDD system: the pedagogical guided walkthrough. It takes the user through a complete SDD cycle — from explore to archive — using their REAL codebase (not a toy example), narrating each phase to teach "teach by doing".
>
> **SCOPE**: Purpose, inline execution mode (not delegated), the 10 walkthrough phases, criteria for choosing the onboarding change, pedagogical narration, what it writes (artifact + topic key), assigned model, Result Contract and gotchas. It is a META phase that orchestrates the behavior of the other phases inline, it does not delegate them.
>
> **EXACT SOURCES**:
> - `/home/cristian/.config/opencode/skills/sdd-onboard/SKILL.md` (primary)
> - `/home/cristian/.claude/agents/sdd-onboard.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-onboard.md` (identical to SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-onboard.md` (orchestrator gates)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source; `[INFER]` = deduction.

---

## 13.1 — Purpose and role `[CERT]`

`sdd-onboard` guides the user through a complete SDD cycle — from exploration to archive — using their real codebase. "This is a real change with real artifacts, not a toy example. The goal is to teach by doing" (`skills/sdd-onboard/SKILL.md:30-32`).

It is the ONLY phase with a distinct boundary: the ORCHESTRATOR NOTE says "This skill is designed to be executed INLINE by the orchestrator. It is an interactive walkthrough — no sub-agent delegation needed" (`SKILL.md:13-15`). The frontmatter reflects it: `delegate_only: false` (`SKILL.md:10`) — the only `false` among the documented phases. An `sdd-onboard` agent still exists for when it IS delegated (`agents/sdd-onboard.md`), with its standard Executor Override (`SKILL.md:17-19`).

Version `1.0` (`SKILL.md:9`) — the newest/most immature of the set.

## 13.2 — What it receives from the orchestrator `[CERT]`

`SKILL.md:34-38`: Artifact store mode (`engram | openspec | hybrid | none`); and optionally a suggested improvement or focus area.

The orchestrator's command (`commands/sdd-onboard.md:14-20`) has minimal gates: it only requires that the SDD Session Preflight be complete (execution mode, artifact store, chained PR strategy, review budget) and to use the resolved artifact store. It keeps user-facing pauses in interactive mode and enforces the review budget before apply.

## 13.3 — The 10 walkthrough phases `[CERT]`

`SKILL.md:42-220`. The onboard executes INLINE the behavior of each SDD phase, narrating it:

| Phase | What it does | Narration (teaching) |
|------|----------|------------------------|
| **1. Welcome & Codebase Analysis** | greets, scans the codebase for a small real improvement | "Let me scan your codebase for opportunities..." |
| **2. Explore** (narrated) | runs `sdd-explore` behavior inline; investigates the chosen area | "Before we commit to any change, we investigate" |
| **3. Propose** (narrated) | creates the change folder + `proposal.md` in `sdd-propose` format | "We write down WHAT we're building and WHY... the contract" |
| **4. Specs** (narrated) | writes delta specs in `sdd-spec` format | "Given/When/Then... each scenario is a potential test case" |
| **5. Design** (narrated) | writes `design.md` in `sdd-design` format | "We decide HOW... document WHY over alternatives" |
| **6. Tasks** (narrated) | writes `tasks.md` in `sdd-tasks` format | "'Implement feature' is not a task" |
| **7. Apply** (narrated) | implements following `sdd-apply`; narrates each task | if Strict TDD: "RED → GREEN → TRIANGULATE → REFACTOR" |
| **8. Verify** (narrated) | runs `sdd-verify`; explains the compliance matrix | "Each scenario: COMPLIANT, FAILING, or UNTESTED" |
| **9. Archive** (narrated) | runs `sdd-archive`; merges delta specs into main specs | "The change becomes the audit trail" |
| **10. Summary** | recap of the cycle + when to use SDD + next steps | "explore → propose → spec → design → tasks → apply → verify → archive" |

> [CERT] Phase 7 mentions the strict TDD cycle with an extra TRIANGULATE step: "RED → GREEN → TRIANGULATE → REFACTOR" (`SKILL.md:160-162`), narrated only if Strict TDD is active. The cycle detail lives in [Block 23].

## 13.4 — Criteria for choosing the onboarding change `[CERT]`

`SKILL.md:56-68`. A good onboarding change meets:

```
├── Small scope — completable in one session (30-60 min)
├── Low risk — no breaking changes, no data migrations
├── Real value — something genuinely useful, not a toy
├── Spec-worthy — at least 1 clear requirement and 2 scenarios
└── Examples:
    ├── Missing input validation in a form or API endpoint
    ├── Inconsistent error messages in an auth flow
    ├── An extractable and reusable utility function
    ├── Missing loading/error state in an async component
    └── A TODO/FIXME comment with clear intent
```

It presents 2-3 options to the user; it lets them choose or suggest their own (`SKILL.md:70`). If the user chooses their own, validate that it meets "small and safe" before proceeding (`SKILL.md:227`).

## 13.5 — What it WRITES (artifact + topic key) `[CERT]`

Unlike the other phases (which write one artifact per phase), onboard PRODUCES the complete set of cycle artifacts inline: proposal, specs, design, tasks, code, verify, archive. But its own persistence artifact is different.

`agents/sdd-onboard.md:27-32`: after completing, `mem_save` with:

- **title / topic_key**: `sdd-onboard/{project}` (NOT `sdd/{change}/...` — it uses the `{project}` pattern, same as `sdd-init/{project}`)
- **type**: `architecture`
- **capture_prompt**: `false`

> [CERT] The topic key `sdd-onboard/{project}` ([Block 3]) is project-scoped, not change-scoped: it records that the project went through onboarding, resumable across sessions (`agents/sdd-onboard.md:24` — "Save progress at each phase so the session is resumable").

## 13.6 — Pedagogical narration (tone rules) `[CERT]`

`SKILL.md:222-231`:

- It is a REAL change, not a demo: artifacts and code must be production-quality (`SKILL.md:224`).
- Narration of each phase SHORT — 1-3 sentences. "Teach, don't lecture" (`SKILL.md:225`).
- ALWAYS ask before moving past Phase 3 (proposal) — let the user review and adjust (`SKILL.md:226`).
- If the user chooses their own improvement, validate "small and safe" (`SKILL.md:227`).
- If something blocks the cycle (tests fail, unclear design, too-complex codebase), STOP and explain — don't push (`SKILL.md:228`).
- Adapt the tone: if the user is experienced, skip the basics; if new, explain more (`SKILL.md:229`).
- Follow ALL the format rules of the individual skills (propose, spec, design, tasks, apply, verify, archive) (`SKILL.md:230`).

## 13.7 — Phase 10: Summary `[CERT]`

`SKILL.md:191-220`. It closes with a markdown recap ("Onboarding Complete! 🎉") that lists: change name, artifacts created (proposal=WHY, specs=WHAT, design=HOW, tasks=STEPS), changed code, "the SDD cycle in one line", when to use SDD ("Small tweaks? Just code. Features, APIs, architecture decisions? SDD first") and next steps (`/sdd-new`, review `openspec/specs/`).

> [CERT] The pedagogical mantra maps each artifact to a question: proposal→WHY, specs→WHAT, design→HOW, tasks→STEPS (`SKILL.md:202-205`). It is the didactic synthesis of the whole SDD cycle.

## 13.8 — Assigned model and tools `[CERT]`

`agents/sdd-onboard.md:7`: `model: haiku` (Model Assignments [Block 18]: "sdd-onboard | haiku | default | Guided walkthrough, pedagogical"). [INFER] Cheap model because the task is pedagogical guidance/copy, not architectural decision — even though it executes inline the behavior of phases that normally use sonnet/opus.

**Tools** (`agents/sdd-onboard.md:8`): `Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update` — the WIDEST set of all phases (includes Bash, Edit, Write, mem_update), [INFER] because it must execute the behavior of ALL phases inline (explore, write artifacts, implement code, run tests, mark tasks).

## 13.9 — Result Contract `[CERT]`

`agents/sdd-onboard.md:34-42`:

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | one sentence of what was onboarded |
| `artifacts` | paths or topic_keys written |
| `next_recommended` | `sdd-new` (to start a real change independently) |
| `risks` | warnings from the onboarding session |
| `skill_resolution` | `paths-injected` or `none` |

`next_recommended: sdd-new` ([Block 14]): after the guided walkthrough, the user is ready to start real changes on their own.

## 13.10 — Gotchas `[CERT]`

- **`delegate_only: false` — the only inline phase** (`SKILL.md:10-15`): it executes inside the orchestrator as an interactive walkthrough, not as a delegated sub-agent. This breaks the "the orchestrator delegates everything" pattern of the other phases.
- **REAL change, not a demo** (`SKILL.md:224`): the artifacts and code are production-quality; the onboard is not a sandbox.
- **Mandatory pause after Phase 3** (`SKILL.md:226`): unlike the automatic flow, onboard always pauses for proposal review — it is pedagogical by design.
- **Project-scoped topic key** (`agents/sdd-onboard.md:30`): `sdd-onboard/{project}`, not `sdd/{change}/...`; it coexists with the real change that also generates its own `sdd/{change}/*` artifacts.
- **STOP if something blocks** (`SKILL.md:228`): it does not push through failing tests or a complex codebase — it prioritizes the learning experience over completing the cycle.
- **The prompt `prompts/sdd/sdd-onboard.md` is byte-identical to SKILL.md** [CERT — compared].
- **Version 1.0** (`SKILL.md:9`): the most recent; [INFER] less hardened than the core phases (apply/verify v3.0).

## 13.11 — Connections

- **[Block 5]–[Block 12]**: onboard executes inline the behavior of explore ([Block 5]), propose ([Block 6]), spec ([Block 7]), design ([Block 8]), tasks ([Block 9]), apply ([Block 10]), verify ([Block 11]) and archive ([Block 12]) — it is the complete traversal of the DAG ([Block 2]) in teaching mode.
- **[Block 13] → [Block 14] (meta-commands)**: `next_recommended: sdd-new`; it closes by pointing the user to start real changes with `/sdd-new`.
- **[Block 23] (strict-TDD)**: Phase 7 narrates RED→GREEN→TRIANGULATE→REFACTOR if Strict TDD is active.
- **[Block 3] (backends + topic keys)**: artifact `sdd-onboard/{project}` (project-scoped); it also produces the `sdd/{change}/*` artifacts of the real cycle.
- **[Block 16] (modes)**: the command keeps user-facing pauses in interactive mode and enforces the review budget before apply.
- **[Block 22] (phase-common)**: Return envelope per Section D; the rest of the inline phases follow their own Sections A–C.
- **[Block 18] (models)**: haiku, "Guided walkthrough, pedagogical".
