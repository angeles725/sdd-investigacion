# Block 23 — Strict TDD (strict-tdd / strict-tdd-verify)

> **WHAT IT DOCUMENTS**: This block establishes the mental model of the **Strict TDD Mode** in gentle-ai's SDD: what it is, how it is activated (init detects the test runner and sets the `strict_tdd` flag), how the orchestrator does MANDATORY forwarding of the mode to the `apply` and `verify` phases, the red-green-refactor cycle the apply module enforces, the verify module's assertion quality audit, and what it does NOT allow (fallback to Standard Mode).
> **SCOPE**: The two strict TDD modules (apply and verify), the detection of testing capabilities in init, and the orchestrator's forwarding contract. It does NOT cover the general mechanics of `sdd-apply` (see [Block 10]) nor `sdd-verify` (see [Block 11]) nor the full stack detection in init (see [Block 4]).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/sdd-apply/strict-tdd.md` (apply module, 365 lines)
> - `/home/cristian/.config/opencode/skills/sdd-verify/strict-tdd-verify.md` (verify module, 270 lines)
> - `/home/cristian/.config/opencode/skills/sdd-init/references/init-details.md` §"Testing Capability Checklist", §"Testing Capabilities Format", §"Engram Saves"
> - `/home/cristian/.claude/CLAUDE.md` §"Strict TDD Forwarding (MANDATORY)", §"SDD Init Guard (MANDATORY)"
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section`. `[CERT-a]` = asserted by a source but not re-verified in its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 23.1 — What Strict TDD Mode is and what discipline it enforces `[CERT]`

Strict TDD Mode is a pair of **conditional modules** that load ONLY when two conditions are met at the same time: that the mode is enabled AND that a test runner exists `[CERT]` (`strict-tdd.md:3`: "This module is loaded ONLY when Strict TDD Mode is enabled AND a test runner is available"; identical in `strict-tdd-verify.md:3`).

The philosophy is not "testing" but **test-driven software design**: *"TDD is not testing. TDD is software design driven by tests. You write a test that describes what the code SHOULD do, then write the minimum code to make it real... Code is a side effect of tests."* `[CERT]` (`strict-tdd.md:8`).

The mode codifies the **Three Laws** of TDD `[CERT]` (`strict-tdd.md:10-14`):

| # | Law `[CERT]` |
|---|--------------|
| 1 | Do NOT write production code until you have a failing test |
| 2 | Do NOT write more of a test than is needed to fail |
| 3 | Do NOT write more code than is needed to pass the test |

**Mental model** `[INFER]`: unlike Standard Mode (where the test may come after or not come at all), Strict Mode inverts causality — the test is the cause and the code is the effect. This is structurally verifiable: the verify module audits the evidence apply produces, closing the loop.

## 23.2 — How it is activated: init detects the test runner `[CERT]`

The mode does not activate on its own; it depends on `sdd-init` having detected testing capabilities. The detection checklist `[CERT]` (`init-details.md §"Testing Capability Checklist"`):

- **Test runner**: scripts/deps in `package.json`, `pyproject.toml`, `pytest.ini`, `go.mod`, `Cargo.toml`, `Makefile`.
- **Test layers**: unit runner; integration libraries (`testing-library`, `httpx`, `httptest`, `WebApplicationFactory`); E2E (`playwright`, `cypress`, `selenium`, `chromedp`).
- **Coverage**: `vitest --coverage`, `jest --coverage`, `c8`, `pytest-cov`, `go test -cover`, `coverlet`.
- **Quality**: linter, type checker, formatter.

Init persists what it detected in two memories `[CERT]` (`init-details.md §"Engram Saves"`):

| topic_key | type | content `[CERT]` |
|-----------|------|---------|
| `sdd-init/{project}` | architecture | detected project context |
| `sdd/{project}/testing-capabilities` | config | testing capabilities in markdown |
| `skill-registry` | config | skill registry |

The capabilities format includes the explicit flag **`Strict TDD Mode: {enabled/disabled}`**, the runner command, and a table of Unit/Integration/E2E layers with their availability and tool `[CERT]` (`init-details.md §"Testing Capabilities Format"`). That `Command: {command}` is the `test_command` the modules later consume.

> Note `[CERT]` (`CLAUDE.md` §"SDD Init Guard"): before ANY SDD command, the orchestrator verifies that init has run for the project (`mem_search "sdd-init/{project}"`). If not, it runs init FIRST. This guarantees that "Testing capabilities are always detected and cached" and that "Strict TDD Mode is activated when the project supports it". `[CERT]`

## 23.3 — The MANDATORY forwarding to apply and verify `[CERT]`

The orchestrator does NOT trust the sub-agent to discover the mode on its own. The forwarding contract is explicit and non-negotiable `[CERT]` (`CLAUDE.md` §"Strict TDD Forwarding (MANDATORY)"):

1. Search for capabilities: `mem_search(query: "sdd-init/{project}", project: "{project}")`. `[CERT]`
2. If the result contains `strict_tdd: true`, add to the sub-agent's prompt:
   > *"STRICT TDD MODE IS ACTIVE. Test runner: {test_command}. You MUST follow strict-tdd.md. Do NOT fall back to Standard Mode."* `[CERT]`
3. This is **NON-NEGOTIABLE**: *"Do not rely on the sub-agent discovering this independently."* `[CERT]`
4. If the search fails or `strict_tdd` does not appear, the instruction is NOT added → the sub-agent uses Standard Mode. `[CERT]`

The orchestrator resolves the TDD state **once per session** (on the first apply/verify launch) and caches it `[CERT]` (`CLAUDE.md` §"Strict TDD Forwarding").

**Architectural implication** `[INFER]`: the mode lives in THREE coordinated places — (a) detected by init and persisted in engram, (b) forwarded by the orchestrator in the delegation prompt, (c) executed by the `strict-tdd.md` / `strict-tdd-verify.md` modules. The sub-agent receives fresh context with no memory, which is why the forwarding must be explicit: the executor does not search engram on its own for this. The phrase *"the orchestrator already verified both conditions"* (`strict-tdd.md:4`) confirms that the module assumes the gate already passed upstream.

## 23.4 — The TDD implementation cycle that apply enforces `[CERT]`

For EACH assigned task, the apply module enforces a strict cycle with **gates** between phases `[CERT]` (`strict-tdd.md:16-87`):

| Step | Name | What it does `[CERT]` | Gate |
|------|--------|---------|------|
| 0 | SAFETY NET | Only if existing files are modified: run prior tests, capture the baseline "{N} tests passing"; if any fail → STOP and report as "pre-existing failure" (do NOT fix it) | The baseline proves you did not break what already worked |
| 1 | UNDERSTAND | Read the task, the spec's scenarios (= acceptance criteria), the design's decisions (= constraints), existing test patterns; determine the layer | — |
| 2 | RED | Write the failing test(s) FIRST, referencing production code that does NOT exist yet (that guarantees the failure without executing) | Do NOT advance to GREEN until the test is written |
| 3 | GREEN | Write the MINIMUM code to pass; "Fake It" (hardcoded returns) is VALID; RUN tests → they must PASS; if it fails, fix the implementation, NOT the test | Do NOT advance until GREEN is confirmed by execution |
| 4 | TRIANGULATE | Add a second case with DIFFERENT inputs/outputs; if the Fake It breaks → generalize to real logic; MINIMUM 2 cases per behavior | All spec scenarios must have a test before REFACTOR |
| 5 | REFACTOR | Improve without changing behavior (extract constants/functions, eliminate duplication, Boy Scout Rule); RUN tests after EACH step; if it fails → revert that step | Green tests after EACH refactor change |
| 6 | Mark the task `[x]` | — | — |
| 7 | Note deviations or discovered issues | — | — |

Critical detail of RED `[CERT]` (`strict-tdd.md:39-42`): if the production function ALREADY exists, the test must cover the NEW behavior not yet implemented. The reference to nonexistent code is what "guarantees failure — no need to execute to confirm".

**TRIANGULATE is mandatory by default** `[CERT]` (`strict-tdd.md:53-54`): *"DEFAULT: triangulation is REQUIRED. You need a compelling reason to skip it."* It can only be skipped when ALL of this is true: the task is purely structural (config/constant/type export), there is literally ONE possible output (no branching), and "Triangulation skipped: {reason}" is noted in the evidence table `[CERT]` (`strict-tdd.md:68-71`).

The module warns against the **trivial GREEN** `[CERT]` (`strict-tdd.md:63-67`): a test that passes because the component does not render, because a loop iterates 0 times, or because the setup does not trigger the code path → is NOT a real GREEN. A real GREEN means "production code RAN and produced the expected output".

## 23.5 — Choosing test layer, execution, and pure functions `[CERT]`

**Layer choice** `[CERT]` (`strict-tdd.md:89-114`): chosen by WHAT the task does, using the **highest available layer that fits**, degrading gracefully if tooling is missing but NEVER skipping a task:

| Task type | Ideal layer `[CERT]` | Degradation |
|---------------|------------|-------------|
| Pure logic / utility / calculation / transformation | Unit (always available if there is a runner) | — |
| Component render / interaction / state changes | Integration if tools exist | Unit with mocks |
| Multi-component flow / API / context-provider | Integration if tools exist | Unit with mocks |
| Critical business flow / full user journey | E2E if tools exist | Integration; if not, Unit |

**Test execution** `[CERT]` (`strict-tdd.md:117-134`): the command is read from the cached capabilities (`test_runner.command`), with an override in `openspec/config.yaml → rules.apply.test_command`, and fallback to detection from `package.json`/`pyproject.toml`/`go.mod`. During the cycle, **ONLY the relevant test file** is run, not the full suite (that keeps the cycle fast); the full suite runs in `sdd-verify`, not here `[CERT]` (`strict-tdd.md:132-133`).

**Preference for pure functions** `[CERT]` (`strict-tdd.md:136-154`): when writing code in GREEN/TRIANGULATE, pure functions are preferred (deterministic, no side effects, trivial to test). The module gives an explicit exception: "don't force it where it doesn't fit (e.g., React components with state)" (`strict-tdd.md:362`).

**Approval testing** `[CERT]` (`strict-tdd.md:156-176`): for REFACTOR tasks on existing code, BEFORE touching production you write "approval tests" that capture the current behavior (even if it is ugly or incorrect), run them green, refactor, and run them again; if the spec says the behavior MUST change, the approval test is updated to RED and implemented.

## 23.6 — The evidence that apply MUST return `[CERT]`

With Strict TDD active, the return summary MUST include a **TDD Cycle Evidence table** `[CERT]` (`strict-tdd.md:180-203`):

| Column | Meaning `[CERT]` (`strict-tdd.md:198-203`) |
|---------|------------|
| Safety Net | Prior tests run before modifying; "N/A (new)" for new files |
| RED | Test written first, referencing nonexistent code. Always "✅ Written" |
| GREEN | Tests executed and passing after minimal implementation. Must show the execution result |
| TRIANGULATE | Additional cases to force real logic. "➖ Single" if the spec has a single scenario |
| REFACTOR | Code improved with tests still green. "➖ None needed" if it was already clean |

Plus a **Test Summary** with totals: tests written/passing, layers used, approval tests, pure functions created `[CERT]` (`strict-tdd.md:190-196`). This table is the primary artifact the verify phase audits (§23.7).

## 23.7 — What it does NOT allow: trivial assertions and the verify audit `[CERT]`

The apply module prohibits assertions that pass without exercising production — *"A test that passes without exercising production logic is worse than no test — it gives false confidence."* `[CERT]` (`strict-tdd.md:207`). **BANNED** patterns `[CERT]` (`strict-tdd.md:209-246`): tautologies (`expect(true).toBe(true)`), empty-collection without setup context, type-only (`toBeDefined()`/`not.toBeNull()` alone), **ghost loops** (assertions inside a loop that iterates 0 times — dead code), and incomplete TDD cycle (GREEN without TRIANGULATE).

A REAL assertion must meet all three `[CERT]` (`strict-tdd.md:248-262`): (1) it calls production code, (2) it asserts a specific output derived from the spec, (3) it WOULD FAIL if the implementation were wrong. Additional rules: **Mock Hygiene** (≤3 mocks is healthy; 7+ → testing at the wrong layer, `strict-tdd.md:291-302`), **Extract-Before-Mock** (extract the transformation to a pure function before mocking), and **Implementation Detail Coupling** (assertions about CSS classes, internal state, or mock counts are NEVER valid; "CSS class assertions are NEVER valid test assertions", `strict-tdd.md:347`).

The **verify** module closes the loop. Its philosophy: move from "does the code work?" to "was the code built correctly? — meaning: was TDD actually followed?" `[CERT]` (`strict-tdd-verify.md:8`). Key steps:

| Step | What it validates `[CERT]` |
|------|------------|
| 5a — TDD Compliance Check | Reads the evidence table from `apply-progress`; for each row it verifies RED (the test file EXISTS → CRITICAL if not), GREEN (cross-checks with step 5b execution → CRITICAL if it fails now), TRIANGULATE (verifies N cases in the file), SAFETY NET. If there is NO table → CRITICAL: "Strict TDD was enabled but apply did not follow the protocol" (`strict-tdd-verify.md:43-46`) |
| 5 expanded — Test Layer Validation | Classifies each test file as Unit/Integration/E2E by indicators; cross-checks with capabilities; SUGGESTION if critical business logic only has unit tests |
| 5d — Changed File Coverage | If a coverage tool exists: reports % per CHANGED file with uncovered lines; WARNING if <80% |
| 5e — Quality Metrics | Linter / type checker only on changed files, only if tools exist |
| 5f — **Assertion Quality Audit (MANDATORY)** | Scans ALL test files for banned patterns; CRITICAL for tautologies, assertions without a production call, and ghost loops; WARNING for empty without companion, smoke-test-only, implementation coupling, and mock-heavy (mocks > 2× assertions) |

Terminal rules of verify `[CERT]` (`strict-tdd-verify.md:259-269`): coverage and quality metrics are informative, NEVER blocking (only WARNING); tautologies are CRITICAL and MUST be rewritten; **verify fixes nothing — it only reports; the orchestrator decides** ("DO NOT fix issues — only report").

**Mental model of the apply↔verify loop** `[INFER]`: apply produces structured evidence (the table), verify audits it by cross-checking it against reality ("don't trust the report blindly", `strict-tdd-verify.md:262`). It is an assert-and-verify system: apply declares, verify distrusts and re-executes. This makes "TDD was followed" an auditable property, not a promise.

## 23.8 — Connections

- **[Block 4] — sdd-init**: the activation of Strict TDD is born in init, which detects the test runner and persists `testing-capabilities` with the `strict_tdd` flag and the `test_command`. Without that detection, the orchestrator cannot do forwarding (§23.2-23.3). The SDD Init Guard guarantees init ran before any apply/verify.
- **[Block 10] — sdd-apply**: the `strict-tdd.md` module is a conditional EXTENSION of the apply phase. When the mode is active, the red-green-refactor cycle (§23.4) replaces the standard implementation flow and adds the TDD Cycle Evidence table to apply's Result Contract.
- **[Block 11] — sdd-verify**: the `strict-tdd-verify.md` module adds steps 5a/5f to the verify phase, auditing apply's evidence (§23.7). The CRITICAL/WARNING/SUGGESTION severities that verify emits (see [Block 11]) are fed here by the Assertion Quality Audit.
- **[Block 18] — delegation and forwarding**: the mandatory forwarding of §23.3 is a concrete case of the Sub-Agent Context Protocol — the orchestrator (not the sub-agent) searches engram and forwards the mode in the prompt, because the executor receives fresh context with no memory.
- **[Block 3] — backends and topic keys**: the capabilities live in `sdd/{project}/testing-capabilities` and the progress in `sdd/{change-name}/apply-progress`, the artifact verify reads for the TDD Compliance Check.
