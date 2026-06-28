# Block 15 — `sdd-status` and the native `gentle-ai` dispatcher

> **WHAT IT DOCUMENTS**: This block documents the read-only `/sdd-status` command and the native `gentle-ai` dispatcher (binary). It explains the shared status contract, the `gentle-ai.sdd-status` schema, the central rule that the native dispatcher ONLY sees OpenSpec artifacts and always emits `artifactStore: openspec`, why it is BLIND to the engram backend, and how routing happens via `nextRecommended` and `blockedReasons`.
> **SCOPE**: The `/sdd-status` command, the binary's real flags (`--cwd`, `--json`, `--instructions`), the status schema, the change-selection rules, the dependency and apply states, and the action context guard. It does NOT cover the phase-advancement mechanics (see [Block 14]) nor the detail of each backend (see [Block 3], [Block 21]).
> **SOURCES** (read and verified):
> - `/home/cristian/.config/opencode/commands/sdd-status.md` (lines 1-42)
> - `/home/cristian/.config/opencode/skills/_shared/sdd-status-contract.md` (lines 1-124)
> - Real output of `gentle-ai --help` (binary v1.43.2) — verified at runtime
> - `/home/cristian/.claude/CLAUDE.md` §"Native SDD Dispatcher Guard"
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source or running the binary, with `path:line` or `path §section`. `[CERT-a]` = asserted by a source, not re-verified. `[INFER]` = my own deduction.

---

## 15.1 — `/sdd-status`: read-only status command `[CERT]`

`/sdd-status` shows **read-only structured status** of an active change `[CERT]` (frontmatter `sdd-status.md:2`). The first line of the task makes it unambiguous: *"This command is read-only. Do not launch SDD executors and do not edit files."* `[CERT]` (`sdd-status.md:6`).

Explicit read-only rules `[CERT]` (`sdd-status.md:35-41`):

- Do not create, update, or delete artifacts.
- Do not mark tasks complete.
- Do not launch apply, verify, archive, or continue.
- Do not infer routing from free text. Use `nextRecommended` and dependency states.
- If status cannot be safely resolved, return `status: blocked` with the missing information.

Like the meta-commands, it opens with the same Session Preflight HARD GATE `[CERT]` (`sdd-status.md:8-10`): if it is missing, ask the preflight prompt and STOP — do not inspect status in the same turn.

What the command MUST return `[CERT]` (`sdd-status.md:26-33`):

- The active change selection and `schemaName`.
- `planningHome`, `changeRoot`, `artifactPaths`, and `contextFiles`.
- Artifact states for proposal, specs, design, tasks, apply-progress, and verify-report.
- Task progress: total, completed, pending, allComplete.
- Dependency states for proposal, specs, design, tasks, apply, verify, archive.
- Next recommended action.
- `actionContext` mode, workspace root, and allowed edit roots.

## 15.2 — The `gentle-ai` binary and its real flags `[CERT]`

Verified by running the binary at runtime `[CERT]` (`gentle-ai --help`, version **1.43.2**):

```
gentle-ai — Gentle-AI: Ecosystem, Frameworks, Workflows (1.43.2)

COMMANDS
  sdd-status [change]   Print native SDD phase status for orchestrators
  sdd-continue [change] Print native SDD dispatcher routing output
  ...
```

Relevant subcommands confirmed `[CERT]`:

- `gentle-ai sdd-status [change]` — "Print native SDD phase status for orchestrators".
- `gentle-ai sdd-continue [change]` — "Print native SDD dispatcher routing output".

Verification note on flags `[CERT]`: `gentle-ai sdd-status --help` returned `Error: unknown sdd-status argument "--help"` (exit 1). That is, the subcommand does NOT expose its own `--help`; the only help is the global `gentle-ai --help`. Therefore **the flags `--cwd`, `--json`, and `--instructions` could NOT be confirmed against a subcommand help**; they are documented as `[CERT-a]` because they are consistently asserted across the command prompts and the shared contract:

- `gentle-ai sdd-status [change] --cwd <repo> --json --instructions` `[CERT-a]` (`sdd-status.md:20`, `sdd-status-contract.md:18`).
- `gentle-ai sdd-continue [change] --cwd <repo>` `[CERT-a]` (`sdd-continue.md:13`, `sdd-status-contract.md:18`).

Meaning of each flag according to the sources `[CERT-a]`:

| Flag | Asserted function |
|------|-----------------|
| `--cwd <repo>` | Indicate the authoritative repo (resolved via `git rev-parse --show-toplevel`) |
| `--json` | Emit the status as parseable JSON instead of markdown |
| `--instructions` | Include `phaseInstructions` (execution keys only: apply/verify/archive) |

**Observation** `[INFER]`: that the subcommand rejects `--help` but the prompts' README insists on `--cwd/--json/--instructions` suggests the binary accepts those flags positionally/silently without a per-subcommand help parser. The hard verification was limited to the existence of the `sdd-status` and `sdd-continue` subcommands, which ARE confirmed in the global help.

## 15.3 — The central rule: the native dispatcher ONLY sees OpenSpec `[CERT]`

This is the most important rule of the block, and it is repeated across all three sources `[CERT]`:

> *"The native engine reads only OpenSpec file artifacts and always emits `artifactStore: openspec`; it cannot observe Engram-backed changes."* `[CERT]` (`sdd-status-contract.md:19`).

The mechanism `[CERT]` (`sdd-status-contract.md:18-20`, `sdd-status.md:20`, `CLAUDE.md` §"Native SDD Dispatcher Guard"):

1. The native dispatcher reads ONLY OpenSpec file artifacts under `openspec/changes/`.
2. It ALWAYS emits `artifactStore: openspec`, regardless of the session's real backend.
3. Therefore, it is authoritative **only** when the session's artifact store is `openspec` or `hybrid`.

Consequence for the `engram` backend `[CERT]`: when the store is `engram`, **the dispatcher is NOT invoked at all** `[CERT]` (`sdd-status.md:20`: "do NOT invoke the native dispatcher at all — it cannot see the change"). Status is resolved entirely from Engram (`mem_search` + `mem_get_observation` over the change's topic keys) using the manual schema.

CLAUDE.md reinforces it with unusual force `[CERT]` (§"Native SDD Dispatcher Guard"): *"it is blind to the change and its `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` output is meaningless"*. That is, if an orchestrator with the engram backend ran the dispatcher by mistake, it would report that the change does not exist — and THAT output must be **discarded**, not obeyed `[CERT]` (`sdd-status-contract.md:19`: "disregard any `blocked`, `Active OpenSpec change not found`, or `nextRecommended: sdd-new` it emits for an Engram change that exists").

**Mental model** `[INFER]`: the native dispatcher is an **OpenSpec filesystem reader**, not a backend-agnostic status service. Talking to it when your truth lives in Engram is like asking a librarian for a book that is in your head: it will tell you "I don't have it", and it would be right from its world and wrong about yours. That is why the rule is not "interpret its output carefully" but "don't call it".

Backend → status source decision matrix `[CERT]` (synthesis of `sdd-status-contract.md:18-24`):

| Session artifact store | Invoke dispatcher? | Authoritative status source |
|--------------------------|----------------------|-------------------------------|
| `openspec` | Yes | Native JSON from `gentle-ai sdd-status` |
| `hybrid` | Yes | Native JSON from `gentle-ai sdd-status` |
| `engram` | **No** | Engram (`mem_search` + `mem_get_observation` over topic keys) |
| binary unavailable | No (does not exist) | Fallback to the contract's manual schema |

## 15.4 — The `gentle-ai.sdd-status` schema `[CERT]`

The contract defines a canonical YAML/JSON schema `[CERT]` (`sdd-status-contract.md:30-90`). Main fields:

| Field | Values / shape `[CERT]` (`sdd-status-contract.md`) |
|-------|------------------------------------------------------|
| `schemaName` | `gentle-ai.sdd-status` |
| `schemaVersion` | `1` |
| `changeName` | name or `null` (nullable) |
| `artifactStore` | `openspec` \| `engram` \| `hybrid` |
| `planningHome` | `{ mode: repo-local, path: <abs openspec> }` |
| `changeRoot` | abs path to `openspec/changes/<change>` or `null` |
| `artifactPaths` | arrays of paths per artifact (proposal, specs, design, tasks, applyProgress, verifyReport) |
| `contextFiles` | arrays of readable files per artifact |
| `artifacts` | per artifact: `missing` \| `done` \| `partial` |
| `taskProgress` | `{ total, completed, pending, allComplete }` |
| `dependencies` | per phase: `blocked` \| `ready` \| `all_done` |
| `applyState` | `blocked` \| `all_done` \| `ready` |
| `actionContext` | `{ mode, workspaceRoot, allowedEditRoots[] }` |
| `relationships` | dependsOn / supersedes / amends / conflictsWith / sameDomainActiveChanges |
| `phaseInstructions` | optional; execution keys only (apply/verify/archive) |
| `nextRecommended` | bounded token (see §15.5) |
| `blockedReasons` | array (see §15.5) |

Critical shape rules `[CERT]` (`sdd-status-contract.md:92`):

- `phaseInstructions` appears ONLY when instructions are requested, and it loads only execution keys (`apply`, `verify`, `archive`). Planning instructions (`propose`, `spec`, `design`, `tasks`) go in the dispatcher markdown, NOT in this JSON map.
- Empty path fields MUST be arrays, not `null`.
- `changeName` and `changeRoot` are nullable; the rest must be present in the fallback so consumers parse native and manual the same way.
- **The native status emits `artifactStore: openspec`**; the manual fallback MUST set `artifactStore` to the session's real store (`openspec`, `engram`, or `hybrid`), **not blindly mirror the native token** `[CERT]` (`sdd-status-contract.md:92`).

Shape compatibility `[CERT]` (`sdd-status-contract.md:24`): *"Manual fallback status MUST stay shape-compatible with native `gentle-ai.sdd-status` JSON even when values are reconstructed manually."* That is, whatever the source (binary or Engram), the consumer parses the SAME shape.

## 15.5 — Routing via `nextRecommended` and `blockedReasons` `[CERT]`

`nextRecommended` is a **bounded machine token for routing, NOT human prose** `[CERT]` (`sdd-status-contract.md:22`). Possible values `[CERT]` (`sdd-status-contract.md:88`):

```
propose | spec | design | tasks | apply | verify | archive
| sdd-new | select-change | resolve-blockers
```

Golden rule `[CERT]` (`sdd-status-contract.md:22`, `sdd-status.md:40`, `CLAUDE.md` §"Native SDD Dispatcher Guard"): *"Route only by `nextRecommended` and dependency states; never infer from free text."* The human explanation goes in `blockedReasons`, not in `nextRecommended` `[CERT]` (`sdd-status-contract.md:23`).

Routing table `[CERT]` (`sdd-status-contract.md:21`, `sdd-status.md:40`):

| Condition | Orchestrator action |
|-----------|------------------------|
| `blockedReasons` non-empty | Do not proceed to terminal/archive/apply. Report and stop... |
| ...except `nextRecommended: verify` | verify may run alone to remediate/refresh evidence of the blockers |
| `nextRecommended: resolve-blockers` | ALWAYS report `blockedReasons` and stop |
| `nextRecommended` = planning token (`propose`/`spec`/`design`/`tasks`) | Launch the corresponding planning phase |

Important subtlety `[CERT]` (`sdd-status-contract.md:21`): when `nextRecommended` is a planning token, the missing planning artifacts are the EXPECTED OUTPUT of those phases, **not genuine blockers**. One must not confuse "the spec is missing" (normal state before `sdd-spec`) with a blocker.

The CLAUDE.md guard adds a layer of severity scale `[CERT]` (§"Native SDD Dispatcher Guard"): *"never infer from free text. If `blockedReasons` is non-empty, do not proceed to apply, archive, or terminal work."* And for the engram backend it repeats that the binary should NOT be invoked because its `nextRecommended: sdd-new` would be "meaningless".

## 15.6 — Change selection, dependency states, and apply `[CERT]`

**Change selection** `[CERT]` (`sdd-status-contract.md:9-14`, `sdd-status.md:21-24`):

- If a name is given → use that exact change after confirming it exists in the selected store.
- If none is given and the active change is unambiguous (or there is exactly one) → select it and state how it was selected.
- If there are multiple or it is ambiguous → **ask the user and STOP. Do not guess.**
- If there are no active changes → report that none is active and suggest `/sdd-new <change>`.

**Apply states** `[CERT]` (`sdd-status-contract.md:95-98`):

| applyState | Condition |
|-----------|-----------|
| `blocked` | apply artifacts are missing, task selection is ambiguous, or the action context makes edits unsafe |
| `all_done` | the tasks artifact exists and every implementation task is marked `[x]` |
| `ready` | tasks exists, at least one task remains unchecked, and the edit scope is safe |

**Dependency states** `[CERT]` (`sdd-status-contract.md:100-105`):

- `proposal`, `specs`, `design`, `tasks`: report whether prerequisites are blocked/ready/all_done.
- `apply` is `ready` only when specs, design, and tasks are available and progress is not all done.
- `verify` is `ready` when tasks exists AND (apply-progress exists OR tasks shows all implementation work complete). Incomplete tasks remain blockers for full verification.
- `archive` is `ready` only when verify-report exists, is clearly passing, and tasks are complete. A clearly-passing report needs an explicit PASS/SUCCESS signal and **no** blocking/negation signal (FAIL, FAILURE, BLOCKED, CRITICAL, PENDING, TODO, "not passed", "pass: no"). **CRITICAL verification issues have no override** `[CERT]` (`sdd-status-contract.md:105`).

## 15.7 — Action Context Guard `[CERT]`

The orchestrator MUST load `actionContext` on any phase launch `[CERT]` (`sdd-status-contract.md:107-113`):

- If the manually reconstructed context cannot prove edit ownership or the allowed edit roots → stop before editing.
- If there are `allowedEditRoots` → edit only files within those roots.
- If a command cannot prove a file is inside the authoritative workspace or the allowed roots → stop and ask for clarification.

This links to the closing of `/sdd-continue` `[CERT]` (`sdd-continue.md:39`): if status reports `workspace-planning` without allowed edit roots, do not launch apply/verify/archive that infers repo-local ownership.

**Why it exists** `[INFER]`: the guard is the safety net against the cwd-in-Electron problem described in the meta-commands (§14.3 of [Block 14]). If the workspace could not be resolved with certainty, the system prefers to STOP rather than edit the wrong directory. The ownership proof is a hard prerequisite for touching files.

## 15.8 — Mandatory status output `[CERT]`

Every command that acts on a change MUST show status before launching an executor or doing archive `[CERT]` (`sdd-status-contract.md:117-123`):

- The active change selection and how it was resolved.
- States and paths/topics of artifacts used as context.
- Task progress and the list of unchecked tasks (when tasks exist).
- Next recommended action.
- `blockedReasons` when `nextRecommended` is not `verify`, plus any edit-root blocker.

**Purpose of the contract** `[CERT]` (`sdd-status-contract.md:6-8`): *"Commands that select, continue, apply, verify, or archive an SDD change MUST first produce or consume structured status. The status is the handoff between orchestrator and phase executor."* The status is NOT a cosmetic report; it is the **formal handoff** between orchestrator and executor, so that orchestration does not guess state, paths, or edit scope `[CERT]` (`sdd-status-contract.md:4`).

## 15.9 — Connections

- **[Block 3] — backends + topic keys**: the openspec/engram/hybrid dichotomy that determines whether the dispatcher is invoked (§15.3) is the same one [Block 3] establishes. The topic keys `sdd/{change}/{type}` read via `mem_search`/`mem_get_observation` when the backend is engram come from there.
- **[Block 21] — openspec-convention**: the native dispatcher reads `openspec/changes/`; the structure of that tree and the OpenSpec convention are documented in [Block 21]. The claim "reads only OpenSpec file artifacts" can only be understood against that convention.
- **[Block 14] — meta-commands**: `/sdd-continue` (§14.4) consumes this status contract as step 1. The routing via `nextRecommended`/`blockedReasons` of §15.5 is what `/sdd-continue` uses to decide which phase to launch.
- **[Block 22] — skill-resolver + phase-common + status-contract**: the file `sdd-status-contract.md` is one of the shared `_shared/` contracts; [Block 22] places it in the set of cross-cutting conventions.
- **[Block 16] — Gatekeeper**: the auto-mode Gatekeeper validates "routing coherence" by reading `nextRecommended` and `risks` — exactly the fields this contract defines.
