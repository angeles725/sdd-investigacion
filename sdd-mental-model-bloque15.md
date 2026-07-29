# Block 15 — `sdd-status` and the native `gentle-ai` dispatcher

> **WHAT IT DOCUMENTS**: This block documents the read-only `/sdd-status` command and the native `gentle-ai` dispatcher (binary). It explains the shared status contract, the `gentle-ai.sdd-status` schema, the central rule that the native dispatcher ONLY sees OpenSpec artifacts and always emits `artifactStore: openspec`, why it is BLIND to the engram backend, and how routing happens via `nextRecommended` and `blockedReasons`. It also documents the `sdd-attempt` ledger as a second, store-agnostic routing authority that must be queried separately before runtime-bearing continuations (new in v2.2.0).
> **SCOPE**: The `/sdd-status` command, the binary's real flags (`--cwd`, `--json`, `--instructions`), the status schema, the change-selection rules, the dependency and apply states, the action context guard, and the `sdd-attempt` ledger. It does NOT cover the phase-advancement mechanics (see [Block 14]) nor the detail of each backend (see [Block 3], [Block 21]).
>
> **SUBJECT VERSION**: verified against gentle-ai v2.2.0 · 2026-07-28. Previously documented: v1.43.2 · 2026-06-28.
>
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/skills/_shared/sdd-status-contract.md` (160 lines by `wc -l`, v2.2.0) — read in full
> - Real output of `gentle-ai --help` (binary v2.2.0) — verified at runtime 2026-07-28
> - `gentle-ai sdd-status --help` output — verified at runtime 2026-07-28
> - `gentle-ai sdd-verify-validate --help` output — verified at runtime 2026-07-28
> - `gentle-ai sdd-attempt status --help` output — verified at runtime 2026-07-28
> - `/home/linuxbrew/.linuxbrew/Cellar/gentle-ai/2.2.0/README.md:21,159` — RDD stability warning (read in full)
> - `/home/cristian/.config/opencode/commands/sdd-status.md` (lines 1-42) — path not re-read in this refresh; citations carry `[CERT-a]`
> - `/home/cristian/.claude/CLAUDE.md` §"Native SDD Dispatcher Guard" — not re-read; citations carry `[CERT-a]`
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source or running the binary, with `path:line` or runtime confirmation. `[CERT-a]` = asserted by a source, not re-verified in this refresh. `[INFER]` = my own deduction. `[DRIFTED v1.43.2→v2.2.0]` = was true at v1.43.2, changed in v2.2.0.

---

## 15.1 — `/sdd-status`: read-only status command `[CERT-a]`

`/sdd-status` shows **read-only structured status** of an active change `[CERT-a]` (frontmatter `sdd-status.md:2`). The first line of the task makes it unambiguous: *"This command is read-only. Do not launch SDD executors and do not edit files."* `[CERT-a]` (`sdd-status.md:6`).

Explicit read-only rules `[CERT-a]` (`sdd-status.md:35-41`):

- Do not create, update, or delete artifacts.
- Do not mark tasks complete.
- Do not launch apply, verify, archive, or continue.
- Do not infer routing from free text. Use `nextRecommended` and dependency states.
- If status cannot be safely resolved, return `status: blocked` with the missing information.

Like the meta-commands, it opens with the same Session Preflight HARD GATE `[CERT-a]` (`sdd-status.md:8-10`): if it is missing, ask the preflight prompt and STOP — do not inspect status in the same turn.

What the command MUST return `[CERT-a]` (`sdd-status.md:26-33`):

- The active change selection and `schemaName`.
- `planningHome`, `changeRoot`, `artifactPaths`, and `contextFiles`.
- Artifact states for proposal, specs, design, tasks, apply-progress, and verify-report.
- Task progress: total, completed, pending, allComplete.
- Dependency states for proposal, specs, design, tasks, apply, verify, archive.
- Next recommended action.
- `actionContext` mode, workspace root, and allowed edit roots.

## 15.2 — The `gentle-ai` binary and its real flags `[CERT]`

> **Snapshot notice**: This section reproduces the `gentle-ai --help` output. Help text is inherently perishable. The snapshot below was captured at runtime against **v2.2.0 · 2026-07-28**. It becomes stale on upgrade.

`[DRIFTED v1.43.2→v2.2.0]` The previous snapshot (v1.43.2) showed a minimal COMMANDS list with `sdd-status` and `sdd-continue` as the primary SDD subcommands. v2.2.0 exposes significantly more subcommands, including the full RDD review pipeline, `sdd-attempt`, `sdd-verify-validate`, compatibility commands, and the `review mode` family.

Verified by running the binary at runtime `[CERT]` (`gentle-ai --help`, version **v2.2.0**, 2026-07-28):

```
gentle-ai — Gentle-AI: Ecosystem, Frameworks, Workflows (2.2.0)

USAGE
  gentle-ai                     Launch interactive TUI
  gentle-ai <command> [flags]

COMMANDS
  install      Configure AI coding agents on this machine
  uninstall    Remove Gentle AI managed files from this machine
  sync         Sync agent configs and skills to current version
  skill-registry refresh
               Refresh .atl/skill-registry.md with cache-hit fast path
  sdd-status [change]
               Print native SDD phase status for orchestrators
  sdd-continue [change]
               Print native SDD dispatcher routing output
  sdd-attempt <status|begin|finish|reset> --cwd <repo> --change <change>
               Read or mutate the artifact-store-agnostic runtime-attempt ledger
  sdd-verify-validate --input <path|-> --requirements <n> --scenarios <n>
               Validate exact verification-report bytes without persistence
  review start [--cwd <repo>] [--base-ref <ref>] [--focus <risk|resilience|readability|reliability>]
  review capture-result --lineage <id> --target <id> --lens <lens> --order <n> --input <review.json>
               Admit one reviewer result; every selected lens needs one
  review finalize [--cwd <repo>] [--captured-results] [--evidence <path>]
  review validate --gate <gate> [--cwd <repo>]
               Normal review path; ordinary authority is compact state plus receipt
  review status [--cwd <repo>]
               Read-only inventory of compact-v2 and shipped legacy-v1 authority
  review repair --preflight [--cwd <repo>]
               Classify the complete authority inventory before provider-owned repair
  review mode <enable|disable|status> [--cwd <repo>] [--scope <global|clone>]
               User-owned kill switch; [...]

COMPATIBILITY COMMANDS
  review-start, review-step, review-resume, review-bundle-export,
  review-bundle-import, review-validate
               Legacy v1 surfaces; reject new authority or direct users to v2 commands

  update, upgrade, restore, doctor, version

FLAGS
  --help, -h    Show global help; every review subcommand also supports help
```

> Full output verbatim from runtime; the COMPATIBILITY COMMANDS group is abbreviated here. The `review` subcommands accept `--help` (exit 0); the SDD-facing subcommands (`sdd-status`, `sdd-continue`, `sdd-attempt`) do not — see §15.2a.

**RDD surface caveat** `[CERT]`: Most new subcommands (`review start/finalize/capture-result/validate`, `sdd-attempt`, `sdd-verify-validate`) belong to the Receipt-Driven Development line, which upstream declares UNSTABLE (`README.md:21`: "RDD is unstable... may change while remaining issues are fixed"). RDD started in `v1.47.0` (`README.md:159`). The presence of these subcommands is confirmed; their flag spellings and ledger formats should not be treated as durable facts until the line is declared stable.

Relevant subcommands confirmed present at v2.2.0 `[CERT]` (`gentle-ai --help`, 2026-07-28):

- `gentle-ai sdd-status [change]` — "Print native SDD phase status for orchestrators" (unchanged from v1.43.2).
- `gentle-ai sdd-continue [change]` — "Print native SDD dispatcher routing output" (unchanged from v1.43.2).
- `gentle-ai sdd-attempt <status|begin|finish|reset> ...` — NEW in v2.2.0; store-agnostic runtime-attempt ledger.
- `gentle-ai sdd-verify-validate ...` — NEW in v2.2.0; validate verify-report bytes without persistence.
- `gentle-ai review` family — NEW in v2.2.0; full RDD pipeline (unstable).

Flags for `sdd-status` and `sdd-continue` `[CERT-a]` (consistently asserted across sources; could not be confirmed via `--help` — see §15.2a):

- `gentle-ai sdd-status [change] --cwd <repo> --json --instructions` `[CERT-a]` (`sdd-status.md:20`, `sdd-status-contract.md:18`).
- `gentle-ai sdd-continue [change] --cwd <repo>` `[CERT-a]` (`sdd-continue.md:13`, `sdd-status-contract.md:18`).

## 15.2a — Dispatcher `--help` behaviour: re-confirmed and extended `[CERT]`

**The claim from v1.43.2 that the native dispatcher does NOT expose per-subcommand `--help` is STILL TRUE in v2.2.0** — re-confirmed at runtime 2026-07-28. It extends to new subcommands with a diagnostic nuance.

| Subcommand | `--help` result | Exit code | Parser |
|---|---|---|---|
| `sdd-status --help` | `Error: unknown sdd-status argument "--help"` | 1 | Custom hand-rolled (unchanged from v1.43.2) |
| `sdd-verify-validate --help` | `Error: flag: help requested` | 1 | Go standard `flag` package |
| `sdd-attempt --help` | `Error: unknown sdd-attempt operation "--help"; want one of status, begin, finish, or reset` | 1 | operation-dispatch parser — rejects `--help` as an unknown OPERATION, not as an unknown flag |
| `review status --help` | Full flags output | 0 | pflag with `--help` support |

> [CERT] `sdd-status --help` output: `Error: unknown sdd-status argument "--help"` (exit 1), observed 2026-07-28. Re-confirmed unchanged.

The variation across parsers is a useful diagnostic for orchestrator guard logic. The `sdd-status`/`sdd-continue` subcommands use the same custom hand-rolled argument parser from v1.43.2, treating `--help` as an unknown argument. `sdd-verify-validate` uses Go's standard `flag` package, which exits with the library sentinel `flag: help requested`. `sdd-attempt` uses a third variant — an operation dispatcher that rejects `--help` as an unknown OPERATION rather than an unknown flag, and helpfully enumerates the valid ones (`status, begin, finish, reset`). Only the `review` subcommands have proper `--help` support with exit 0 `[CERT]` (`gentle-ai review status --help` → `Usage: gentle-ai review status [flags]`, verified 2026-07-28).

`[INFER]` The inconsistency in parsers suggests `sdd-status`/`sdd-continue` predate any standardisation effort, while the RDD-era subcommands (`sdd-verify-validate`, `sdd-attempt`, `review`) used different libraries at different points in development.

## 15.3 — The central rule: the native dispatcher ONLY sees OpenSpec `[CERT]`

This is the most important rule of the block, repeated across sources `[CERT]`:

> *"The native engine reads only OpenSpec file artifacts and always emits `artifactStore: openspec`; it cannot observe Engram-backed changes."* `[CERT]` (`sdd-status-contract.md:19`).

The mechanism `[CERT]` (`sdd-status-contract.md:18-20`):

1. The native dispatcher reads ONLY OpenSpec file artifacts under `openspec/changes/`.
2. It ALWAYS emits `artifactStore: openspec`, regardless of the session's real backend.
3. Therefore, it is authoritative **only** when the session's artifact store is `openspec` or `hybrid`.

Consequence for the `engram` backend `[CERT]`: when the store is `engram`, **the dispatcher is NOT invoked at all** (`sdd-status-contract.md:19`): "do NOT invoke those OpenSpec dispatcher commands". Status is resolved entirely from Engram (`mem_search` + `mem_get_observation` over the change's topic keys) using the manual schema.

> [CERT] If an orchestrator with the engram backend ran the dispatcher by mistake, its output must be **discarded**: "disregard any `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` it emits for an Engram change that exists" (`sdd-status-contract.md:19`).

**Mental model** `[INFER]`: the native dispatcher is an **OpenSpec filesystem reader**, not a backend-agnostic status service. Talking to it when your truth lives in Engram is like asking a librarian for a book that is in your head — it will tell you "I don't have it", and that answer is correct from its world and wrong about yours. The rule is not "interpret its output carefully" but "don't call it".

Backend → status source decision matrix `[CERT]` (`sdd-status-contract.md:18-20`):

| Session artifact store | Invoke dispatcher? | Authoritative status source |
|--------------------------|----------------------|-------------------------------|
| `openspec` | Yes | Native JSON from `gentle-ai sdd-status` |
| `hybrid` | Yes | Native JSON from `gentle-ai sdd-status` |
| `engram` | **No** | Engram (`mem_search` + `mem_get_observation` over topic keys) |
| binary unavailable | No (does not exist) | Fallback to the contract's manual schema |

## 15.4 — The `gentle-ai.sdd-status` schema `[CERT]`

The contract defines a canonical YAML/JSON schema `[CERT]` (`sdd-status-contract.md:27-122`). The schema changed significantly in v2.2.0 due to the RDD layer. Main fields, with drift annotations where applicable:

| Field | Values / shape | Source `[CERT]` |
|-------|----------------|-----------------|
| `schemaName` | `gentle-ai.sdd-status` | `sdd-status-contract.md:32` |
| `schemaVersion` | `1` | `sdd-status-contract.md:33` |
| `changeName` | name or `null` (nullable) | `sdd-status-contract.md:34` |
| `artifactStore` | `openspec` \| `engram` \| `none` | `sdd-status-contract.md:35` |
| `planningHome` | `{ mode: repo-local, path: <abs openspec> }` | `sdd-status-contract.md:36-38` |
| `changeRoot` | abs path to `openspec/changes/<change>` or `null` | `sdd-status-contract.md:39` |
| `artifactPaths` | arrays per artifact — see note | `sdd-status-contract.md:40-52` |
| `contextFiles` | arrays of readable files per artifact | `sdd-status-contract.md:53-65` |
| `artifacts` | per artifact: `missing` \| `done` \| `partial` | `sdd-status-contract.md:66-78` |
| `taskProgress` | `{ total, completed, pending, allComplete }` | `sdd-status-contract.md:79-83` |
| `dependencies` | per phase: `blocked` \| `ready` \| `all_done` | `sdd-status-contract.md:84-91` |
| `applyState` | `blocked` \| `all_done` \| `ready` | `sdd-status-contract.md:92` |
| `actionContext` | `{ mode, workspaceRoot, allowedEditRoots[] }` | `sdd-status-contract.md:93-96` |
| `relationships` | dependsOn / supersedes / amends / conflictsWith / sameDomainActiveChanges | `sdd-status-contract.md:97-102` |
| `remediationState` | `{ required, complete, failedEvidenceRevision, lineageId, generation, fixBatch, reason }` | `sdd-status-contract.md:103-110` — **NEW in v2.2.0** |
| `reviewGate` | `{ result: allow \| scope-changed \| invalidated \| escalated, reason }` | `sdd-status-contract.md:111-112` — **NEW in v2.2.0** |
| `reviewTransaction` | optional exact `gentle-ai.review-transaction/v1` object | `sdd-status-contract.md:113` — **NEW in v2.2.0** |
| `phaseInstructions` | optional; keys: `apply`, `verify`, `remediate`, `archive` | `sdd-status-contract.md:114-119` — `remediate` key is **NEW in v2.2.0** |
| `nextRecommended` | bounded token — see §15.5 | `sdd-status-contract.md:120` |
| `blockedReasons` | array | `sdd-status-contract.md:121` |

`[DRIFTED v1.43.2→v2.2.0]` The `artifactPaths` and `contextFiles` sections now include review-specific artifact keys: `reviewPolicy`, `reviewLedger`, `reviewReceipt`, `reviewBundle`, `reviewContext`, `reviewState` (`sdd-status-contract.md:47-52`, `60-65`). These did not exist in the v1.43.2 schema.

`[DRIFTED v1.43.2→v2.2.0]` `nextRecommended` now includes `review`, `remediate`, and `resolve-review` tokens (`sdd-status-contract.md:120`). The old set was `propose | spec | design | tasks | apply | verify | archive | sdd-new | select-change | resolve-blockers`.

Critical shape rules `[CERT]` (`sdd-status-contract.md:124`):

- `phaseInstructions` appears ONLY when instructions are requested, and loads only execution keys (`apply`, `verify`, `remediate`, `archive`). Planning instructions (`propose`, `spec`, `design`, `tasks`) go in the dispatcher markdown.
- Empty path fields MUST be arrays, not `null`.
- `changeName` and `changeRoot` are nullable; the rest must be present in the fallback.
- **The native status emits `artifactStore: openspec`**; the manual fallback MUST set `artifactStore` to the session's real store, not blindly mirror the native token.
- `reviewGate` is omitted until final archive gating runs; when present, its result uses only the four listed values (`sdd-status-contract.md:124`).
- `reviewTransaction` is omitted until the review owner supplies the exact `gentle-ai.review-transaction/v1` object; manual fallback MUST NOT reconstruct it (`sdd-status-contract.md:124`).

Shape compatibility `[CERT]` (`sdd-status-contract.md:25`): native and manual consumers parse the SAME shape.

## 15.5 — Routing via `nextRecommended` and `blockedReasons` `[CERT]`

`nextRecommended` is a **bounded machine token for routing, NOT human prose** `[CERT]` (`sdd-status-contract.md:23`).

`[DRIFTED v1.43.2→v2.2.0]` Possible values in v2.2.0 `[CERT]` (`sdd-status-contract.md:120`):

```
propose | spec | design | tasks | apply | review | verify | remediate | archive
| sdd-new | select-change | resolve-blockers | resolve-review
```

Added since v1.43.2: `review`, `remediate`, `resolve-review`.

Golden rule `[CERT]` (`sdd-status-contract.md:23`): *"Route only by `nextRecommended` and dependency states; never infer from free text."* Human explanation belongs in `blockedReasons` `[CERT]` (`sdd-status-contract.md:24`).

Routing table `[CERT]` (`sdd-status-contract.md:22`):

| Condition | Orchestrator action |
|-----------|------------------------|
| `blockedReasons` non-empty | Do not proceed to terminal/archive/apply. Report and stop... |
| ...except `nextRecommended: verify` | verify may run alone to remediate/refresh evidence of the blockers |
| `nextRecommended: resolve-blockers` | ALWAYS report `blockedReasons` and stop |
| `nextRecommended` = planning token (`propose`/`spec`/`design`/`tasks`) | Launch the corresponding planning phase |
| `nextRecommended: review` | NEW v2.2.0 — route to the RDD review start |
| `nextRecommended: remediate` | NEW v2.2.0 — route to remediation (failed evidence, within fix budget) |
| `nextRecommended: resolve-review` | NEW v2.2.0 — review state requires attention before proceeding |

Important subtlety `[CERT]` (`sdd-status-contract.md:22`): when `nextRecommended` is a planning token, the missing planning artifacts are the EXPECTED OUTPUT of those phases, **not genuine blockers**. One must not confuse "the spec is missing" (normal state before `sdd-spec`) with a blocker.

## 15.5a — `sdd-attempt`: the second routing authority `[CERT]`

**New in v2.2.0.** The `sdd-attempt` ledger is a second, artifact-store-agnostic routing authority that MUST be queried separately before runtime-bearing continuations. It is distinct from the artifact dispatch authority covered in §15.3.

> [CERT] `sdd-status-contract.md:20`: "Runtime-attempt authority is different from artifact dispatch: `gentle-ai sdd-attempt status|begin|finish|reset --cwd <repo> --change <change>` is artifact-store agnostic and MUST be used for runtime-bearing OpenSpec and Engram continuations. Its Git-common-dir immutable chain is the sole authority for ordinals, cumulative attempt/line budgets, runtime evidence, and an atomic bound-remediation successor. Its payload is separate and MUST NOT be embedded in the SDD v1 status document."

> [CERT] `sdd-status-contract.md:141`: "Before a runtime-bearing continuation, query `gentle-ai sdd-attempt status --cwd <repo> --change <change>` separately. A populated active attempt or decision-required result blocks apply, verify, remediation, and archive routing with `nextRecommended: resolve-blockers`; finish the already-charged attempt or obtain explicit maintainer authorization for reset. A completed result preserves the successful objective without relaunching it."

Key properties `[CERT]` (`sdd-status-contract.md:20`):

- **Store-agnostic**: unlike the main dispatcher, `sdd-attempt` works for both `openspec` and `engram` backends.
- **Separate query**: its payload must not be embedded in the SDD v1 status document.
- **Authority**: Git-common-dir immutable chain — cannot be fabricated by prompt narration.
- **Blocking**: a populated active attempt or decision-required result blocks apply, verify, remediation, and archive routing.

`[INFER]` The separation mirrors the broader RDD pattern: native authority derives from immutable Git CAS, not agent narration. An orchestrator that skips `sdd-attempt status` before a continuation cannot know whether a charged attempt is still running.

**RDD caveat** `[CERT]`: `sdd-attempt` belongs to the RDD line (unstable, `README.md:21`). The subcommand is confirmed present in v2.2.0 (`gentle-ai --help`, 2026-07-28). Flag spellings and ledger format may change while the line remains unstable.

## 15.6 — Change selection, dependency states, and apply `[CERT]`

**Change selection** `[CERT]` (`sdd-status-contract.md:9-14`):

- If a name is given → use that exact change after confirming it exists in the selected store.
- If none is given and the active change is unambiguous (or there is exactly one) → select it and state how it was selected.
- If there are multiple or it is ambiguous → **ask the user and STOP. Do not guess.**
- If there are no active changes → report that none is active and suggest `/sdd-new <change>`.

**Apply states** `[CERT]` (`sdd-status-contract.md:126-130`):

| applyState | Condition |
|-----------|-----------|
| `blocked` | apply artifacts are missing, task selection is ambiguous, or the action context makes edits unsafe |
| `all_done` | the tasks artifact exists and every implementation task is marked `[x]` |
| `ready` | tasks exists, at least one task remains unchecked, and the edit scope is safe |

**Dependency states** `[CERT]` (`sdd-status-contract.md:132-142`):

`[DRIFTED v1.43.2→v2.2.0]` The `verify` and `archive` dependency states changed substantially:

- `proposal`, `specs`, `design`, `tasks`: unchanged — report whether prerequisites are blocked/ready/all_done.
- `apply` is `ready` only when specs, design, and tasks are available and task progress is not all done.
- `verify` is `ready` only after every task is complete **and the persisted bounded transaction reaches `ready_final_verification`** (`sdd-status-contract.md:136`). Missing or active review state routes to `review`. Apply-progress and focused work-unit checks alone never make final verification ready. `[DRIFTED v1.43.2→v2.2.0]`
- `remediate` state is new: routes to remediation only when an exact persisted transaction lineage/generation has remaining budget and names the same failed evidence revision (`sdd-status-contract.md:138`). **NEW in v2.2.0.**
- `archive` is `ready` only when tasks are complete, strict verification passes, AND **an approved receipt exactly matches the final candidate tree, paths, policy, frozen ledger, and current evidence** (`sdd-status-contract.md:139`). Missing, pending, or invalid receipts block archive. `[DRIFTED v1.43.2→v2.2.0]`

> [CERT] CRITICAL verification issues still have no override (`sdd-status-contract.md:139`).

## 15.7 — Action Context Guard `[CERT-a]`

The orchestrator MUST load `actionContext` on any phase launch `[CERT-a]` (`sdd-status-contract.md:144-150`):

- If the manually reconstructed context cannot prove edit ownership or the allowed edit roots → stop before editing.
- If there are `allowedEditRoots` → edit only files within those roots.
- If a command cannot prove a file is inside the authoritative workspace or the allowed roots → stop and ask for clarification.

**Why it exists** `[INFER]`: the guard is the safety net against the cwd-in-Electron problem described in the meta-commands (§14.3 of [Block 14]). If the workspace could not be resolved with certainty, the system prefers to STOP rather than edit the wrong directory. The ownership proof is a hard prerequisite for touching files.

## 15.8 — Mandatory status output `[CERT]`

Every command that acts on a change MUST show status before launching an executor or doing archive `[CERT]` (`sdd-status-contract.md:152-160`):

- The active change selection and how it was resolved.
- States and paths/topics of artifacts used as context.
- Task progress and the list of unchecked tasks (when tasks exist).
- Next recommended action.
- `blockedReasons` when `nextRecommended` is not `verify`, plus any edit-root blocker.

**Purpose of the contract** `[CERT]` (`sdd-status-contract.md:6-8`): *"Commands that select, continue, apply, verify, or archive an SDD change MUST first produce or consume structured status. The status is the handoff between orchestrator and phase executor."* The status is NOT a cosmetic report; it is the **formal handoff** between orchestrator and executor so that orchestration does not guess state, paths, or edit scope.

## 15.9 — Connections

- **[Block 3] — backends + topic keys**: the openspec/engram/hybrid dichotomy that determines whether the dispatcher is invoked (§15.3) is the same one [Block 3] establishes. The topic keys `sdd/{change}/{type}` read via `mem_search`/`mem_get_observation` when the backend is engram come from there.
- **[Block 21] — openspec-convention**: the native dispatcher reads `openspec/changes/`; the structure of that tree and the OpenSpec convention are documented in [Block 21].
- **[Block 14] — meta-commands**: `/sdd-continue` (§14.4) consumes this status contract as step 1. The routing via `nextRecommended`/`blockedReasons` of §15.5 is what `/sdd-continue` uses to decide which phase to launch.
- **[Block 22] — skill-resolver + phase-common + status-contract**: `sdd-status-contract.md` is one of the shared `_shared/` contracts; [Block 22] places it in the set of cross-cutting conventions.
- **[Block 16] — Gatekeeper**: the auto-mode Gatekeeper validates "routing coherence" by reading `nextRecommended` and `risks` — exactly the fields this contract defines.
- **[Block 12] — archive**: the `reviewGate` field (§15.4) is now required by `sdd-archive` before any archive operations (§12.5a of [Block 12]). The known inconsistency between the skill contract and the native gate is documented there.
