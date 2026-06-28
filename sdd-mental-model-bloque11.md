# Block 11 — `sdd-verify` Phase (+ report format)

> **WHAT**: Documents the `sdd-verify` phase of gentle-ai's SDD system: the quality gate. It proves that the implementation matches specs, design and tasks through source inspection PLUS real execution evidence (tests). It classifies issues into CRITICAL / WARNING / SUGGESTION and emits a PASS / PASS WITH WARNINGS / FAIL verdict.
>
> **SCOPE**: Purpose, activation contract, Hard Rules, Decision Gates, what it reads/writes (artifact + topic key), severity levels, compliance statuses, report format (full template), graceful handling of missing artifacts, assigned model, Result Contract and gotchas. It does NOT cover the `strict-tdd-verify.md` module (that is [Block 23]); only its loading is mentioned.
>
> **EXACT SOURCES**:
> - `/home/cristian/.config/opencode/skills/sdd-verify/SKILL.md` (primary, v3.0)
> - `/home/cristian/.config/opencode/skills/sdd-verify/references/report-format.md` (template + compliance statuses)
> - `/home/cristian/.claude/agents/sdd-verify.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-verify.md` (CONDENSED version — diverges from SKILL.md)
> - `/home/cristian/.config/opencode/commands/sdd-verify.md` (orchestrator gates)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
> - NOTE: `sdd-verify/strict-tdd-verify.md` is documented in [Block 23], NOT here.
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source; `[INFER]` = deduction.

---

## 11.1 — Purpose and role `[CERT]`

`sdd-verify` runs when the orchestrator launches the verification of an SDD change. It is the **quality gate**: it proves completeness with source inspection PLUS real execution evidence (`skills/sdd-verify/SKILL.md:31-33`). Its central philosophy (`SKILL.md:42`): "Execute relevant tests; static analysis alone is never verification" — a spec scenario is compliant only when a test covering it passed at runtime.

It does NOT fix issues: it reports them for the orchestrator/user (`SKILL.md:43`). Same gate/override pattern as the rest (`SKILL.md:13-21`). Version `3.0`.

## 11.2 — Activation Contract and Hard Rules `[CERT]`

The orchestrator must provide structured status from `_shared/sdd-status-contract.md` ([Block 22]): `schemaName`, `planningHome`, `changeRoot`, `artifactPaths`, `contextFiles`, task progress, dependency states, `actionContext` (`SKILL.md:31-35`).

Hard Rules (`SKILL.md:37-46`):

- Read ALL available `contextFiles` before judging. Full spec-driven verification reads proposal, specs, design and tasks; partial sets degrade (see 11.7).
- Execute relevant tests; static analysis alone is NEVER verification.
- A spec scenario is compliant only when a test covering it passed at runtime.
- Compare specs first, design second, task completeness third (`SKILL.md:42`).
- Do NOT fix; report.
- Persist `verify-report` according to the mode.
- If Strict TDD is active, load `strict-tdd-verify.md` ([Block 23]); if inactive, never load it (`SKILL.md:45`).

## 11.3 — What it READS and what it WRITES `[CERT]`

The SKILL.md delegates retrieval to Section B of the common; the agent concretizes it (`agents/sdd-verify.md:18-26`): it reads `sdd/{change}/spec` (required), `sdd/{change}/tasks` (required), `sdd/{change}/apply-progress` (required), all via `mem_search → mem_get_observation`.

**Artifact produced**: `verify-report` · **topic key**: `sdd/{change-name}/verify-report` · **type**: `architecture` (`agents/sdd-verify.md:29-34`, [Block 3]). It persists according to mode: Engram, openspec file, hybrid (both), or inline-only for `none` (`SKILL.md:44`).

> [CERT] Important: the verify agent does NOT have project file-writing tools. `agents/sdd-verify.md:7`: tools = `Read, Grep, Glob, Bash, mem_search, mem_get_observation, mem_save`. No `Edit`/`Write` (does not mutate code) nor `mem_update` (does not mark tasks). Only `Bash` to execute tests and `mem_save` for the report.

## 11.4 — Severity levels CRITICAL / WARNING / SUGGESTION `[CERT]`

Issues are grouped into three levels (`SKILL.md:78`, `references/report-format.md:57-60`). The Decision Gates define what triggers each one (`SKILL.md:48-63`):

| Condition | Level |
|-----------|-------|
| Incomplete core task | **CRITICAL** |
| Incomplete cleanup task | **WARNING** |
| Test command exits non-zero | **CRITICAL** |
| Spec scenario with no passing test | **CRITICAL** (`UNTESTED` or `FAILING`) |
| Design deviation exists | **WARNING** (unless it breaks a spec → CRITICAL) |

> [CERT] "Any unchecked implementation task is CRITICAL and blocks archive readiness" (`SKILL.md:69`). "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:85`). This links with the Task Completion Gate of `sdd-archive` ([Block 12]).

SUGGESTION is the non-blocking level (optional improvements); it appears in the report but does not affect the blocking verdict.

### Final verdict `[CERT]`

`SKILL.md:78` + `references/report-format.md:62-64`: `PASS`, `PASS WITH WARNINGS`, or `FAIL`. A CRITICAL forces `FAIL`; only WARNINGs → `PASS WITH WARNINGS`; clean → `PASS`. [INFER] The verdict derives mechanically from the levels: presence of any CRITICAL ⇒ FAIL.

## 11.5 — Compliance Statuses (spec matrix) `[CERT]`

`references/report-format.md:3-9`. Each spec scenario receives a status in the Spec Compliance Matrix:

| Status | Meaning |
|--------|-------------|
| ✅ `COMPLIANT` | a covering test exists and passed |
| ❌ `FAILING` | a covering test exists but failed |
| ❌ `UNTESTED` | no covering test was found |
| ⚠️ `PARTIAL` | test passes but covers only part of the scenario |

The matrix is built from REAL test results when specs/scenarios exist (`SKILL.md:72-78`). `FAILING` and `UNTESTED` for required scenarios are CRITICAL.

## 11.6 — Report format `[CERT]`

`references/report-format.md:10-65`. The full template (`## Verification Report`):

```markdown
## Verification Report
**Change**: {change-name}
**Version**: {spec version or N/A}
**Mode**: {Strict TDD | Standard}

### Completeness        → table: Tasks total / complete / incomplete
### Build & Tests Execution
   **Build**: ✅ Passed / ❌ Failed  (+ command and output)
   **Tests**: ✅ N passed / ❌ N failed / ⚠️ N skipped
   **Coverage**: N% / threshold N% → ✅ Above / ⚠️ Below / ➖ Not available
### Spec Compliance Matrix   → Requirement | Scenario | Test | Result
   **Compliance summary**: N/total scenarios compliant
### Correctness (Static Evidence)  → Requirement | Status | Notes
### Coherence (Design)             → Decision | Followed? | Notes
### Issues Found
   **CRITICAL**: {list or None}
   **WARNING**: {list or None}
   **SUGGESTION**: {list or None}
### Verdict
   {PASS / PASS WITH WARNINGS / FAIL} + one-line reason
```

The SKILL.md's Output Contract (`SKILL.md:76-78`) lists the same sections: change, mode, completeness table, build/tests/coverage evidence, spec compliance matrix, correctness table, design coherence table, issues grouped CRITICAL/WARNING/SUGGESTION, and final verdict.

> [CERT] When Strict TDD is active, the TDD compliance, test layer distribution, changed-file coverage and quality metrics sections are inserted from `strict-tdd-verify.md` ([Block 23]) (`references/report-format.md:67`).

## 11.7 — Graceful Artifact Handling (degradation) `[CERT]`

`SKILL.md:80-85` + Decision Gates. Verification degrades according to which artifacts exist:

| Available artifacts | What it verifies |
|------------------------|--------------|
| Only tasks | only objective task completeness; does NOT claim spec correctness nor design coherence; if all checked and no runtime evidence → verdict may be `PASS WITH WARNINGS` for task completeness only |
| Tasks + specs | completeness + correctness of requirements/scenarios; runtime evidence still required; missing covering tests are CRITICAL for required scenarios unless config allows manual verification |
| Proposal/specs/design/tasks (full) | verifies all dimensions: completeness, correctness, coherence |
| `actionContext.mode: workspace-planning` | STOP; full verification of workspace implementation not supported in this slice (`SKILL.md:55`) |

> [CERT] "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:85`). Unchecked tasks are the hardest block, independent of the rest.

## 11.8 — Execution Steps `[CERT]`

`SKILL.md:64-74`:

1. Load relevant skills (Section A).
2. Retrieve artifacts (Section B) or read `contextFiles` from the structured status.
3. Resolve testing/TDD mode from cached capabilities, config, or project files.
4. Count complete and incomplete tasks. Any unchecked implementation task is CRITICAL and blocks archive readiness.
5. If specs exist, map each requirement/scenario to implementation and test evidence.
6. If design exists, check decisions against changed code; if missing, skip coherence and record why.
7. Run test, build/type-check and coverage when available. For full spec verification, preserve gentle-ai's strictest runtime evidence: source inspection alone does NOT prove scenario compliance.
8. Build the behavioral compliance matrix from real test results.
9. Persist and return the report, including dimensions skipped due to missing artifacts.

## 11.9 — Assigned model `[CERT]`

`agents/sdd-verify.md:6`: `model: sonnet` (Model Assignments [Block 18]: "sdd-verify | sonnet | default | Validation against spec"). Tools (`agents/sdd-verify.md:7`): `Read, Grep, Glob, Bash, mem_search, mem_get_observation, mem_save` — with `Bash` to execute tests, without project-writing tools.

## 11.10 — Result Contract `[CERT]`

The **agent** (`agents/sdd-verify.md:37-44`):

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | verdict in one sentence (CRITICAL/WARNING/SUGGESTION count) |
| `artifacts` | topic_keys/paths (e.g. `sdd/{change}/verify-report`) |
| `next_recommended` | `sdd-archive` (if clean) or `sdd-apply` (if there is a CRITICAL) |
| `risks` | unresolved CRITICAL issues that block archive |
| `skill_resolution` | `paths-injected` or `none` |

The **condensed prompt** (`prompts/sdd/sdd-verify.md:38-45`) uses a minimalist JSON: `{status: pass|fail|warning, checks: [{criterion, result, evidence}], next: ready-for-archive|fixes-required}`.

## 11.11 — Gotchas `[CERT]`

- **Static analysis ≠ verification** (`SKILL.md:42, 71`): the SKILL.md requires runtime execution of tests for scenario compliance. It is the strongest rule of the phase.
- **CRITICAL DIVERGENCE between SKILL.md and the condensed prompt** [CERT — compared]: `prompts/sdd/sdd-verify.md:33` says *"Do NOT run tests unless `strict_tdd` is active and test runner is explicitly provided"* — the OPPOSITE of SKILL.md, which requires always executing tests ("static analysis alone is never verification"). The condensed prompt also limits to "Inspect changed files listed in apply-progress (or tasks)". The SKILL.md (v3.0, with report-format) is the complete canonical source; the prompt is the low-budget variant that sacrifices test execution. [INFER] Whoever implements should follow the SKILL.md unless there is an explicit token restriction.
- **Unchecked task = always CRITICAL** (`SKILL.md:69, 85`): even with everything else green, a `- [ ]` task blocks archive.
- **`workspace-planning` ⇒ STOP** (`SKILL.md:55`): does not support full verification of workspace implementation.
- **Does not mark tasks nor fix code**: no `mem_update`, `Edit` nor `Write`; only reports (`agents/sdd-verify.md:7`, `SKILL.md:43`).

## 11.12 — Connections

- **[Block 10] (apply)** → `sdd-verify` reads `apply-progress` + spec + tasks; validates that the code matches the contract (`agents/sdd-verify.md:21`).
- **[Block 11] → [Block 23] (strict-TDD)**: loads `strict-tdd-verify.md` only if Strict TDD is active; verifies the TDD Cycle Evidence table that apply produced (`SKILL.md:45`).
- **[Block 12] (archive)** → `next_recommended: sdd-archive` if clean. Verify is the guard that precedes closure: CRITICAL blocks archive without override (the Strict-vs-OpenSpec Archive Policy of [Block 12] inherits this).
- **[Block 9] (tasks)**: counts and validates task completeness.
- **[Block 16] (Gatekeeper)**: verify is the model alias used by the gatekeeper for fresh-context reviews in high-risk phases.
- **[Block 3]**: artifact `verify-report` → `sdd/{change}/verify-report`.
- **[Block 22] (phase-common + status-contract)**: Sections A–D + structured status + `actionContext` Decision Gates.
- **[Block 18] (models)**: sonnet, "Validation against spec".
