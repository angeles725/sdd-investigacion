# Block 11 — `sdd-verify` Phase (+ report format)

> **RDD INSTABILITY NOTICE**: Several surfaces this block documents — the verify-report admission gate, the YAML envelope format, the authority-only preflight denial shape, and the `native bounded transaction` routing in the commands file — are part of the **Receipt-Driven Development (RDD)** line, which upstream declares unstable since `gentle-ai v1.47.0` (`README.md:21`). The core phase contract (purpose, hard rules for tests, severity levels, graceful degradation) pre-dates RDD and is stable. Where RDD-specific surfaces appear below, they carry an explicit stability caveat.
>
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.

> **WHAT**: Documents the `sdd-verify` phase of gentle-ai's SDD system: the quality gate. It proves that the implementation matches specs, design and tasks through source inspection PLUS real execution evidence (tests). It classifies issues into CRITICAL / WARNING / SUGGESTION and emits a PASS / PASS WITH WARNINGS / FAIL verdict.
>
> **SCOPE**: Purpose, activation contract, Hard Rules, Decision Gates, what it reads/writes (artifact + topic key), severity levels, compliance statuses, report format (full template), graceful handling of missing artifacts, assigned model, Result Contract and gotchas. It does NOT cover the `strict-tdd-verify.md` module (that is [Block 23]); only its loading is mentioned. The verify-report admission gate is documented canonically in [Block 19] §19.10; this block summarises it and cross-references.
>
> **EXACT SOURCES** (read and verified at v2.2.0):
> - `/home/cristian/.config/opencode/skills/sdd-verify/SKILL.md` (primary, v3.0, 110 lines — `wc -l`, file ends with a trailing newline)
> - `/home/cristian/.config/opencode/skills/sdd-verify/references/report-format.md` (template + compliance statuses, 102 lines)
> - `/home/cristian/.claude/agents/sdd-verify.md` (tools, model, Result Contract)
> - `/home/cristian/.config/opencode/prompts/sdd/sdd-verify.md` (141 lines) — [DRIFTED v1.43.2→v2.2.0]: previously documented as a "CONDENSED version — diverges from SKILL.md". The SEMANTIC divergence is gone: lines 1-110 are now byte-identical to `SKILL.md`. The files are NOT identical, however — the prompt appends a `<!-- gentle-ai:codegraph-guidance -->` section (lines 111-141) that `SKILL.md` does not carry `[CERT]` (`diff` → `111,141d110`; 11,486 vs 8,389 bytes). Cite `SKILL.md` for phase behaviour; cite this file only for the injected CodeGraph ordering rules.
> - `/home/cristian/.config/opencode/commands/sdd-verify.md` (orchestrator gates — now contains RDD-specific bounded-transaction routing; see §11.11)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-phase-common.md`
> - NOTE: `sdd-verify/strict-tdd-verify.md` is documented in [Block 23], NOT here.
>
> **METHOD**: direct reading. Markers: `[CERT]` = verified (`path:line`); `[CERT-a]` = asserted by source; `[INFER]` = deduction; `[DRIFTED v1.43.2→v2.2.0]` = true then, false now — old fact kept visible.

---

## 11.1 — Purpose and role `[CERT]`

`sdd-verify` runs when the orchestrator launches the verification of an SDD change. It is the **quality gate**: it proves completeness with source inspection PLUS real execution evidence (`SKILL.md:33`). Its central philosophy (`SKILL.md:41`): "Execute relevant tests; static analysis alone is never verification" — a spec scenario is compliant only when a test covering it passed at runtime.

It does NOT fix issues: it reports them for the orchestrator/user (`SKILL.md:44`). Same gate/override pattern as the rest (`SKILL.md:13-21`). Version `3.0`.

## 11.2 — Activation Contract and Hard Rules `[CERT]`

The orchestrator must provide structured status from `_shared/sdd-status-contract.md` ([Block 22]): `schemaName`, `planningHome`, `changeRoot`, `artifactPaths`, `contextFiles`, task progress, dependency states, `actionContext` (`SKILL.md:35`).

Hard Rules (`SKILL.md:37-51`):

- Read ALL available `contextFiles` before judging. Full spec-driven verification reads proposal, specs, design and tasks; partial sets degrade (see 11.7).
- **Run full verification only after ALL tasks are complete. If any task is pending, return `blocked` without running the full suite.** (`SKILL.md:40`) — [DRIFTED v1.43.2→v2.2.0]: v1.43.2 did not have this as an explicit early-exit rule; unchecked tasks triggered CRITICAL findings but the suite still ran.
- Execute relevant tests; static analysis alone is NEVER verification.
- A spec scenario is compliant only when a test covering it passed at runtime.
- Compare specs first, design second, task completion third (`SKILL.md:43`).
- Do NOT fix; report.
- **Build the complete report as exact candidate bytes, then run `gentle-ai sdd-verify-validate` with authoritative spec counts BEFORE any OpenSpec or Engram write.** If the validator is unavailable or denies admission, make ZERO writes and leave the prior report untouched. (`SKILL.md:45`) — [DRIFTED v1.43.2→v2.2.0]: this rule did not exist. For the canonical description of the gate, see [Block 19] §19.10.
- Persist `verify-report` according to the mode.
- If Strict TDD is active, load `strict-tdd-verify.md` ([Block 23]); if inactive, never load it (`SKILL.md:47`).
- Count actual requirements and scenarios from retrieved specs; never invent envelope totals (`SKILL.md:49`).
- Record current test/build commands, exit codes, and `test_output_hash` / `build_output_hash` in the strict envelope (`SKILL.md:50`) — RDD unstable surface; observed 2026-07-28.

## 11.3 — What it READS and what it WRITES `[CERT]`

The SKILL.md delegates retrieval to Section B of the common; the agent concretizes it (`agents/sdd-verify.md:18-25`): it reads `sdd/{change}/spec` (required), `sdd/{change}/tasks` (required), `sdd/{change}/apply-progress` (required), all via `mem_search → mem_get_observation`.

**Artifact produced**: `verify-report` · **topic key**: `sdd/{change-name}/verify-report` · **type**: `architecture` (`agents/sdd-verify.md:28-34`, [Block 3]). It persists according to mode: Engram, openspec file, hybrid (both), or inline-only for `none` (`SKILL.md:46`). The persistence write is now gated — see §11.2 and [Block 19] §19.10.

> [CERT] The verify agent does NOT have project file-writing tools. `agents/sdd-verify.md:7`: tools = `Read, Grep, Glob, Bash, mcp__plugin_engram_engram__mem_search, mcp__plugin_engram_engram__mem_get_observation, mcp__plugin_engram_engram__mem_save, mcp__codegraph__codegraph_explore`. [DRIFTED v1.43.2→v2.2.0]: `mcp__codegraph__codegraph_explore` was added. No `Edit`/`Write` (does not mutate code) nor `mem_update` (does not mark tasks). Only `Bash` to execute tests and `mem_save` for the report.

## 11.4 — Severity levels CRITICAL / WARNING / SUGGESTION `[CERT]`

Issues are grouped into three levels. The Decision Gates define what triggers each one (`SKILL.md:67-81`):

| Condition | Level |
|-----------|-------|
| Incomplete core task | **CRITICAL** |
| Incomplete cleanup task | **WARNING** |
| Test command exits non-zero | **CRITICAL** |
| Spec scenario with no passing covering test | **CRITICAL** (`UNTESTED` or `FAILING`) |
| Design deviation exists | **WARNING** (unless it breaks a spec → CRITICAL) |

[DRIFTED v1.43.2→v2.2.0]: Block 11 previously cited `references/report-format.md:57-60` for severity levels. At v2.2.0, lines 57-60 of report-format.md are inside the Spec Compliance Matrix table rows — not severity definitions. The Decision Gates in SKILL.md remain the authoritative source.

> [CERT] "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:104`). This links with the Task Completion Gate of `sdd-archive` ([Block 12]).

SUGGESTION is the non-blocking level (optional improvements); it appears in the report but does not affect the blocking verdict.

### Final verdict `[CERT]`

`SKILL.md:97` + `references/report-format.md:78-80`: `PASS`, `PASS WITH WARNINGS`, or `FAIL`. A CRITICAL forces `FAIL`; only WARNINGs → `PASS WITH WARNINGS`; clean → `PASS`. [INFER] The verdict derives mechanically from the levels: presence of any CRITICAL ⇒ FAIL.

## 11.5 — Compliance Statuses (spec matrix) `[CERT]`

`references/report-format.md:1-8`. Each spec scenario receives a status in the Spec Compliance Matrix:

| Status | Meaning |
|--------|-------------|
| ✅ `COMPLIANT` | a covering test exists and passed |
| ❌ `FAILING` | a covering test exists but failed |
| ❌ `UNTESTED` | no covering test was found |
| ⚠️ `PARTIAL` | test passes but covers only part of the scenario |

The matrix is built from REAL test results when specs/scenarios exist (`SKILL.md:92`). `FAILING` and `UNTESTED` for required scenarios are CRITICAL.

## 11.6 — Report format `[CERT]`

`references/report-format.md:10-81`. The report now has TWO parts:

**Part 1 — YAML evidence envelope** `[CERT]` (`report-format.md:12-27`) — [DRIFTED v1.43.2→v2.2.0]: this envelope did not exist. It is the first non-empty content and MUST precede the markdown body:

```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:{current-evidence-digest}
verdict: pass
blockers: 0
critical_findings: 0
requirements: {complete}/{actual-total}
scenarios: {complete}/{actual-total}
test_command: {exact command}
test_exit_code: 0
test_output_hash: sha256:{exact-output-digest}
build_command: {exact command}
build_exit_code: 0
build_output_hash: sha256:{exact-output-digest}
```

> [CERT-a — RDD unstable surface; observed 2026-07-28] `report-format.md:83`: "Admission rejects malformed, unknown, missing, contradictory, or count-mismatched evidence." The schema name `gentle-ai.verify-result/v1` and the field list are observed on the unstable RDD line; re-verify before treating them as stable.

**Part 2 — Markdown body** `[CERT]` (`report-format.md:28-81`):

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

The SKILL.md Output Contract (`SKILL.md:95-97`) lists the same sections.

> [CERT] When Strict TDD is active, the TDD compliance, test layer distribution, changed-file coverage and quality metrics sections are inserted from `strict-tdd-verify.md` ([Block 23]) (`report-format.md:101`).

## 11.7 — Graceful Artifact Handling (degradation) `[CERT]`

`SKILL.md:99-104`. Verification degrades according to which artifacts exist:

| Available artifacts | What it verifies |
|------------------------|--------------|
| Only tasks | only objective task completeness; does NOT claim spec correctness nor design coherence; if all checked and no runtime evidence → verdict may be `PASS WITH WARNINGS` for task completeness only |
| Tasks + specs | completeness + correctness of requirements/scenarios; runtime evidence still required; missing covering tests are CRITICAL for required scenarios unless config allows manual verification |
| Proposal/specs/design/tasks (full) | verifies all dimensions: completeness, correctness, coherence |
| `actionContext.mode: workspace-planning` | STOP; full verification of workspace implementation not supported in this slice (`SKILL.md:74`) |

> [CERT] "Unchecked tasks: always remain CRITICAL, even when other artifacts are missing or warnings-only" (`SKILL.md:104`). Unchecked tasks are the hardest block, independent of the rest.

## 11.8 — Execution Steps `[CERT]`

`SKILL.md:83-93`:

1. Load relevant skills (Section A).
2. Retrieve artifacts (Section B) or read `contextFiles` from the structured status.
3. Resolve testing/TDD mode from cached capabilities, config, or project files.
4. Count complete and incomplete tasks. Any unchecked implementation task blocks full verification.
5. If specs exist, map each requirement/scenario to implementation and test evidence.
6. If design exists, check decisions against changed code; if missing, skip coherence and record why.
7. Run test, build/type-check and coverage when available. For full spec verification, source inspection alone does NOT prove scenario compliance.
8. Build the behavioral compliance matrix from real test results.
9. **[DRIFTED v1.43.2→v2.2.0]** Previously: "Persist and return the report." Now: build exact candidate bytes, run `gentle-ai sdd-verify-validate` (see [Block 19] §19.10), then — only if admitted — persist and return the report including dimensions skipped due to missing artifacts.

## 11.9 — Assigned model `[CERT]`

`agents/sdd-verify.md:6`: `model: sonnet` (Model Assignments [Block 18]: "sdd-verify | sonnet | default | Validation against spec"). Tools (`agents/sdd-verify.md:7`): `Read, Grep, Glob, Bash, mcp__plugin_engram_engram__mem_search, mcp__plugin_engram_engram__mem_get_observation, mcp__plugin_engram_engram__mem_save, mcp__codegraph__codegraph_explore` — with `Bash` to execute tests, without project-writing tools.

## 11.10 — Result Contract `[CERT]`

The **agent** (`agents/sdd-verify.md:36-44`):

| Field | Value |
|-------|-------|
| `status` | `done` \| `blocked` \| `partial` |
| `executive_summary` | verdict in one sentence (CRITICAL/WARNING/SUGGESTION count) |
| `artifacts` | topic_keys/paths (e.g. `sdd/{change}/verify-report`) |
| `next_recommended` | `sdd-archive` (if clean) or `sdd-apply` (if there is a CRITICAL) |
| `risks` | unresolved CRITICAL issues that block archive |
| `skill_resolution` | `paths-injected` or `none` |

[DRIFTED v1.43.2→v2.2.0]: Block 11 previously documented a separate "condensed prompt" (`prompts/sdd/sdd-verify.md`) with a minimalist JSON result format (`{status: pass|fail|warning, checks: [...], next: ...}`). At v2.2.0, the prompts file is identical to SKILL.md — that minimalist format no longer exists as a separate variant.

## 11.11 — Gotchas `[CERT]`

- **Static analysis ≠ verification** (`SKILL.md:41, 91`): the SKILL.md requires runtime execution of tests for scenario compliance. It is the strongest rule of the phase.
- **[DRIFTED v1.43.2→v2.2.0] The CRITICAL DIVERGENCE is resolved — but the two files are still not the same file**: Block 11 previously documented a critical divergence between `SKILL.md` and `prompts/sdd/sdd-verify.md`, the latter saying "Do NOT run tests unless strict_tdd is active." At v2.2.0 the condensed prompt was replaced by the full skill, so the contradiction is gone `[CERT]`. Do NOT simplify this to "the files are identical": `diff` reports `111,141d110` — the prompt is `SKILL.md` verbatim (lines 1-110) **plus** an appended `<!-- gentle-ai:codegraph-guidance -->` section (lines 111-141, 3,097 extra bytes) that the skill does not carry `[CERT]`. That marker name is itself the finding: the distribution layer INJECTS harness-wide guidance into the prompt copy, which is why the two artifacts can never be assumed equal even when their SDD content agrees. `[INFER]` — the injection is almost certainly performed by `gentle-ai install`/`sync`, but that was not verified because both commands mutate state; `[GAP]`, settled by inspecting the installer's template handling in the v2.x source.
- **Validate gate fires before every write** (`SKILL.md:45`, `sdd-phase-common.md:41`, `report-format.md:83-85`): an unavailable or denying validator means ZERO persistence calls. See [Block 19] §19.10 for the canonical gate description.
- **Blocked early when tasks are incomplete** (`SKILL.md:40`): if ANY task is pending, `sdd-verify` returns `blocked` without running the full suite. [DRIFTED v1.43.2→v2.2.0]: previously, incomplete tasks caused CRITICAL findings but the suite still ran.
- **Unchecked task = always CRITICAL** (`SKILL.md:104`): even with everything else green, a `- [ ]` task blocks archive.
- **`workspace-planning` ⇒ STOP** (`SKILL.md:74`): does not support full verification of workspace implementation.
- **Does not mark tasks nor fix code**: no `mem_update`, `Edit` nor `Write`; only reports (`agents/sdd-verify.md:7`, `SKILL.md:44`).
- **Commands file now carries RDD routing** `[CERT-a — RDD unstable surface; observed 2026-07-28]` (`commands/sdd-verify.md:29`): the orchestrator gate now reads "If all gates pass and **the native bounded transaction is `ready_final_verification` or `final_verifying`**, launch the hidden `sdd-verify` sub-agent." This is a new RDD-line dependency; at v1.43.2, verification had no such transaction prerequisite. [GAP] The exact semantics of the transaction states (`ready_final_verification`, `final_verifying`) require running `gentle-ai sdd-attempt status` — see [Block 22] §22.3 for the `sdd-attempt` guidance.
- **Authority-only preflight denial** `[CERT-a — RDD unstable surface; observed 2026-07-28]` (`SKILL.md:55-65`, `report-format.md:87-100`): when review authority is missing at preflight, the skill emits a failed envelope with five specific recovery fields (`authority_only_failure: true`, `missing_review_authority: true`, `substantive_failure: false`, `command_failed: false`, `observed_authority_revision: sha256:{...}`) and records exit 125 for both commands without executing them. This shape applies ONLY to authority-denial, not substantive verification failures.

## 11.12 — Connections

- **[Block 10] (apply)** → `sdd-verify` reads `apply-progress` + spec + tasks; validates that the code matches the contract (`agents/sdd-verify.md:21`).
- **[Block 11] → [Block 23] (strict-TDD)**: loads `strict-tdd-verify.md` only if Strict TDD is active; verifies the TDD Cycle Evidence table that apply produced (`SKILL.md:47`).
- **[Block 12] (archive)** → `next_recommended: sdd-archive` if clean. Verify is the guard that precedes closure: CRITICAL blocks archive without override (the Strict-vs-OpenSpec Archive Policy of [Block 12] inherits this). At v2.2.0, archive also requires an approved receipt — see [Block 22] §22.3.
- **[Block 9] (tasks)**: counts and validates task completeness.
- **[Block 16] (Gatekeeper)**: verify is the model alias used by the gatekeeper for fresh-context reviews in high-risk phases.
- **[Block 3]**: artifact `verify-report` → `sdd/{change}/verify-report`.
- **[Block 19] §19.10 (persistence contract — gate)**: the canonical description of the verify-report admission gate. §11.2 and §11.8 summarise it; §19.10 is the single source of truth for gate behaviour, failure handling, and the RDD instability caveat.
- **[Block 22] (phase-common + status-contract)**: Sections A–D + structured status + `actionContext` Decision Gates. §22.2-C carries the phase-level reminder of the validate gate.
- **[Block 18] (models)**: sonnet, "Validation against spec".
