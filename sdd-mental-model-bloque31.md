# Block 31 — How gentle-ai's components communicate: the review-integration contract, `next_transition`, binding tokens, acknowledge-then-burn, typed envelopes, threat model

> **WHAT IT DOCUMENTS**: The wire-level design by which one Go binary (`gentle-ai`), the host agent (Claude Code, Codex, OpenCode, Pi) and the reviewer roles exchange state during a review: schema-pinned JSON envelopes negotiated by `--contract`, the three-kind `next_transition` state machine (`execute` / `collect` / `stop`), `{name, value, token}` binding arguments, optimistic concurrency, the two-phase approve-then-acknowledge terminal, provider-issued reviewer input, typed failure and consent envelopes, the read-only `assess` verb, hooks, file coordination, the explicit threat model, and a numbered message flow.
> **SCOPE**: The protocol and its design principles. It does NOT document each of the 21 `review` subcommands (a registered gap in RESEARCH-STATE); the defect-report handoff that wraps the consent envelope is [Block 30]; the process (PR/issue) side is [Block 29].
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01. The docs headers still read "track `main` ... v3.7.0" (`docs/review-integration.md:4`), so doc claims are `[CERT-a]` unless a schema or code line is cited. Delta baseline for contract versions: v2.5.0, where the lifecycle was declared stable.
> **SOURCES**: `docs/review-integration.md` (232 lines), `docs/review-authority-threat-model.md` (102 lines), `contracts/review-integration/v2/schemas/*.schema.json`, `contracts/review-integration/v1/FREEZE.md`, `contracts/review-provider-contract/CONTRACT_SEMVER`, `internal/cli/review_status_contract.go`, `internal/consentenvelope/envelope.go`, `internal/reviewtransaction/reviewer_context_markers.go`, `internal/filecoord/lock.go`, `internal/statecoord/statecoord.go`, `internal/providercontractbundle/bundle.go`, `contracts/telemetry/v1/schemas/event.schema.json`, `internal/telemetry/killswitch.go`.
> **METHOD**: schemas and Go constants read directly (`[CERT]`); behavioural statements taken from the docs (`[CERT-a]`). The reviewtransaction state machine, the stop-hook body and the per-runtime adapter wiring were NOT read at code level. `schema` outputs of the live binary were not run. `[INFER]` = deduction.
> **Type:** mixed

---

## 31.1 — One authority, many transports `[CERT]`

`docs/review-integration.md:7`: "Go owns the candidate snapshot, review admission, correction boundary, terminal burn, and all provider-facing bindings... no runtime adapter decides review or delivery." Adapters "transport opaque provider output and never parse bindings, manufacture a verdict, or mutate review authority" (reviewer-transport section, ~line 118). The per-runtime wiring differs `[CERT-a]`: Claude Code uses a tool-free fresh reviewer, OpenCode relays one host Task through its live Go transport, Codex a provider-bound subprocess, Pi a gentle-pi-owned relay. Lifecycle is supported only for Claude Code, Codex, OpenCode and Pi; "unsupported runtimes fail before repository or authority mutation". Per-runtime adapters share one registry and a compile-time capability manifest (`internal/agents/{interface.go,registry.go,capability_manifest.go}`) `[CERT]`.

`[INFER]` Design principle, restated by the orchestrator prompt: provider authority beats prompt prose. The prompt only says "run the returned tokens unchanged, never reconstruct lifecycle selectors from retained prose"; the schema is the contract.

## 31.2 — The wire format: schema-pinned JSON with a negotiated contract `[CERT]`

Every envelope pins its identity with a constant: `"schema": {"const": "gentle-ai.review-integration.status/v9"}` (`contracts/review-integration/v2/schemas/status-v9.schema.json`; Go constant `internal/cli/review_status_contract.go:34`). The caller negotiates: `gentle-ai review status --cwd <repo> --contract gentle-ai.review-integration/v2 --agent claude-code --next-transition` (`docs/review-integration.md:21-26`).

| Envelope | Schema id (current) | Role |
|---|---|---|
| status | `gentle-ai.review-integration.status/v9` | state and next move |
| start | `…start/v4` | freeze a candidate; may be `created`, `replayed` or `closed` |
| consent | `…consent/v3` | blocking human question |
| failure | `…failure/v2` | typed error |
| last-event-closure | `gentle-ai.review-last-event-closure/v1` | result of the final admitted capture |
| assessment | `gentle-ai.review-assessment/v1` | read-only risk and `review_due` |
| acknowledged | `gentle-ai.review-acknowledged/v1` | printed once on burn |

Schemas are draft 2020-12, `additionalProperties: false`, carry `$id` URLs. Versions are additive files side by side (`status-v4` … `status-v9`, `capabilities-v2.1` … `v2.6`); v1 is kept read-only as compatibility (`contracts/review-integration/v1/FREEZE.md`). Fixtures ship beside the schemas (`contracts/review-integration/v2/fixtures/`). Status v9 reuses v8 via `$ref` and overrides only `next_transition` (`status-v9.schema.json`, ~lines 26-90): schema inheritance by reference, not by copy. `[DRIFTED v2.2.0→v4.0.0]` the v2.5.0 notes list status/v6 and start/v4; v4.0.0 carries status/v9 `[CERT-a]` (version history between them is a gap).

## 31.3 — `next_transition`: execute, collect, stop `[CERT]`

| Kind | Meaning | Schema evidence |
|---|---|---|
| `execute` | run the exact operation with the ordered arguments returned | start/v4 allows only `kind: execute`, `reason_code: review_status_required` |
| `collect` | satisfy only the named inputs via their capture operation, then ask STATUS again | `kind` const `collect`; `reason_code` enum `provider_refuter_required`, `targeted_validation_required`, `targeted_validation_inconclusive_recapture_required`; `collect.inputs` min/max 1 (`status-v9.schema.json`, ~30-70) |
| `stop` | run nothing; never infer recovery | one reason code from a closed table (§31.4) |

A `forecast` is explicitly non-routing: `"dependentRequired": {"forecast": ["next_transition"]}` (`status-v9.schema.json`, ~25) and the docs say "A forecast is descriptive, not a route" `[CERT]`/`[CERT-a]`.

## 31.4 — Closed stop-code table `[CERT]`

`docs/review-integration.md`, "Continue after a stop reason code" (about lines 192-212): 16 reason codes, each mapped to exactly one continuation; "Terminal" means no in-lineage continuation and "never authorizes delivery".

| Class | Codes | Continuation |
|---|---|---|
| Terminal, inspect or disable | `captured_artifacts_unverifiable`, `captured_result_selection_unavailable`, `corrupted_or_unverifiable_authority`, `manual_intervention_required`, `native_stop_required`, `missing_authority_binding` | maintainer inspects authority/lineage, or clone-scoped `gentle-ai review mode disable` |
| Terminal, scope | `empty_base_diff_bootstrap_required`, `lens_context_budget_exceeded`, `staged_workspace_overlay_recovery_unavailable` | bootstrap, reduce scope and restart, or recover by lineage |
| Release authority | `correction_context_budget_exceeded` | `gentle-ai review abandon`; `invalidate` refuses here |
| Repair then re-query | `managed_assets_outdated` (run the `sync` command carried in the stop's `continuation`), `corrected_candidate_unavailable`, `recovery_scope_unchanged`, `rdd_disabled` | change the candidate or enable, then re-run the exact STATUS |
| Host slot | `unachievable_lens_slot` | `review capture-unachievable … --withdraw=true` so the slot is re-offered, or reduce scope |
| Consumed | `target_already_acknowledged` | terminal; delivery follows ordinary policy; a changed target stays eligible |

## 31.5 — Binding tokens `[CERT]`

Every argument in a returned invocation is `{name, value, token}` (`contracts/review-integration/v2/schemas/transition-execution.schema.json:162-166`): `cwd`, `lineage`, `target`, `expected-revision`, `token`, each requiring a `token`; `target` and `expected-revision` are sha256, the token matches `^[0-9a-f]{64}$`, lineage matches `^[a-z0-9]+(?:-[a-z0-9]+)*$`. The agent replays the argv unchanged and never builds one. `transition-binding.schema.json` requires `target_identity`, optionally `lineage_id`, `revision`, `repository_context`. Cross-repository: the same lineage text in repositories A and B is independent; the host keeps process cwd = B (`docs/review-integration.md`, ~35-45) `[CERT-a]`.

## 31.6 — Optimistic concurrency, idempotent replay, acknowledge-then-burn `[CERT-a]`

- `docs/review-authority-threat-model.md:18`: "A lock plus expected revision rejects stale transitions; an exact retry is idempotent." START `replayed` is the example; a wrong or stale acknowledgement fails validation before any mutation and STATUS re-offers the same acknowledgement.
- Terminal is two-phase: the final admitted capture returns `approved` plus a pending acknowledgement token (`last-event-closure.schema.json` has `status_continuation` and `acknowledgement` `[CERT]`); only the exact provider-issued acknowledgement invocation burns authority and prints `gentle-ai.review-acknowledged/v1`; afterwards "no receipt, tombstone, witness, mirror, or delivery authority survives" (docs, ~103). A pending acknowledgement is replayable after a STATUS restart: a crash-safe handshake `[INFER]`.
- Uncertain outcome: re-query STATUS; never replay an invented command.

## 31.7 — Provider-issued reviewer input, not prompt prose `[CERT]`

`internal/reviewtransaction/reviewer_context_markers.go:19` defines `ReviewerBindingMarker = "GENTLE_AI_REVIEW_BINDING"`; the reviewer prompt starts with it plus one-line binding JSON, and results must echo `subject_hash` and report `inspection.status`; free text in evidence "is never read" for completeness (`internal/assets/skills/_shared/review-ledger-contract.md:39`). Reviewers read only immutable git trees of the frozen candidate, never the live worktree or `/tmp`. Role schemas are published: `gentle-ai review schema reviewer|refuter|validator` (`docs/review-authority-threat-model.md:49`, `[CERT-a]`; the command was not run here). Compiled runtimes capture in process (no `--input`); relay runtimes pass `--input` (docs ~115-118).

## 31.8 — Typed failure and typed consent `[CERT]`

- **Failure** (`failure.schema.json`): required `phase, code, message, mutation_outcome, authority_applicability, retry_safe, replayability, required_inputs, next_action`; optional `continuation`, `cause_category`. `mutation_outcome` takes `not_started | unknown | committed` (docs, v1 reference). The caller learns "did anything change, may I retry" without parsing prose.
- **Consent** (`consent-v3.schema.json`): required `blocking, headline, reason, value, risk_evidence, choices, off_path`. Generic core `internal/consentenvelope/envelope.go:1-50`: `Choice{answer,label,effect,invocation}`, `OffPath{note,command}`, "Evidence ... never nil: encode as [] rather than null"; completeness validation at `:57-77`. Exactly two token choices `granted` / `declined`, each carrying its own runnable invocation; the orchestrator prompt requires lossless relay and ordinal-alias answer validation. The defect-report handoff of [Block 30] stacks a three-token layer on top.

## 31.9 — Read-only risk assessment `[CERT-a]`

`gentle-ai review assess --json` → `gentle-ai.review-assessment/v1` with `risk`, `reasons[{code,path}]`, `review_due`, `review_due_reason` and — only when due — a runnable `next_transition.command` plus structured `arguments` (docs ~140-165; `assess.schema.json`). Fail-closed: an unresolvable base-ref is treated exactly as `high`. Vocabulary in code: `internal/cli/review_assess.go:39-61` `[CERT]` (see [Block 28] §28.4).

## 31.10 — Delivery is deliberately decoupled `[CERT-a]`

`review validate` and the gates return `invalidated/unmanaged` or `disabled/unmanaged` and "never allow, approve, block, commit, push"; review authority governs the review lifecycle only (`docs/review-authority-threat-model.md:10`). A `stop` ends its transition and never approves delivery. This is a conscious reversal of the v2.2.0-era receipt gate ([Block 11], [Block 12]).

## 31.11 — Hooks `[CERT]` / `[CERT-a]`

Claude Code registers `SessionStart` and `Stop` hooks backed by `review stop-hook` (`internal/cli/review_stop_hook.go`, `internal/components/agenthooks/claude.go`) `[CERT]` (files exist; bodies unread). Per the docs (~line 28) `[CERT-a]`: SessionStart records the session's baseline candidate; Stop reminds only about candidates that session produced; neither starts a review. Compare the kit's Stop-hook `retro-gate.sh` (same role: reminder, always exits 0).

## 31.12 — File coordination `[CERT]`

`internal/filecoord/lock.go:1-60`: typed errors (Busy, Unsupported, InvalidRoot, InvalidTarget, Operational); `Lease.Release` idempotent via `sync.Once`; backend uses flock/LockFileEx (`lock_backend.go:14-19`). `internal/statecoord/statecoord.go:25-42` `WithLock` serializes every install-state read-modify-write behind one lock derived from the symlink-resolved home. State writes use `filemerge.WriteFileAtomic` (`internal/state/state.go:293`, `manifest.go:118`) = stage + fsync + rename. The review store takes a shared `REVIEW-MAINTENANCE.lock` in the git common dir before the lineage lock (`docs/review-authority-threat-model.md:31`). Locks are "cooperative ... not a defense against a malicious same-user actor".

## 31.13 — The threat model states what it does not defend `[CERT]`

`docs/review-authority-threat-model.md:8,23`: it "does not claim to authenticate state against a malicious local actor with the same user"; checksums exist "only where useful for detecting accidental corruption; they are not authentication" (`:35`). A hash chain "presented as protection from the out-of-scope actor" was deleted (`:58`). Controls kept (`:27-34`): schema and semantic validation before accept, legal-transition validation, atomic replace, lock plus expected revision, live-git re-derivation instead of persisted mirrors. `[INFER]` Value for any tool: scope the defence to accidental corruption and concurrent writers, and write down what is out of scope so no one later adds a decorative hash chain.

## 31.14 — Release-level contract bundle `[CERT]`

`contracts/review-provider-contract/CONTRACT_SEMVER` = `1.2.0`; `internal/providercontractbundle/bundle.go:30-32` defines `gentle-ai.review-provider-contract-bundle/v1` with caps (8 MiB archive, 4 MiB per file, 64 KiB manifest) and schema/vector pairs per role; bump history in comments (`:52,60`). Conformance vectors travel with schemas so third-party hosts (gentle-pi) can self-test.

## 31.15 — Telemetry is a second, minimal channel `[CERT]`

`contracts/telemetry/v1/schemas/event.schema.json`: `gentle-ai.telemetry-event/v1`, `additionalProperties: false`, only enums plus a random `install_id` and counts ("never a path, hostname, username, prompt, diff, or IP"); kill-switch precedence DO_NOT_TRACK > GENTLE_AI_TELEMETRY=0 > CI > persisted state > default (`internal/telemetry/killswitch.go:1-30`).

## 31.16 — Numbered message flow (review lifecycle)

1. Host finishes an authorized edit and runs selectorless `review status … --next-transition` (preflight). `[CERT-a]` (`docs/review-integration.md:21-26`)
2. Go returns status/v9 with `next_transition{kind: execute}` = the exact START argv. `[CERT]` (`status-v9.schema.json`)
3. Host runs START; Go freezes the candidate (lineage, worktree, target, risk, lenses). Medium/high risk returns consent/v3 instead. `[CERT]`
4. Consent: the host relays the envelope losslessly; the human answers `granted|declined`; the host runs that choice's `invocation`. `[CERT]` (`envelope.go`)
5. START/v4 carries `next_transition.execute(review.status)` bound to lineage/target/revision tokens. `[CERT]` (`start-v4.schema.json`)
6. Host runs the bound STATUS and receives `collect` with N `review.capture-result` inputs, launched concurrently. `[CERT]`
7. Each capture: Go materializes the immutable reviewer context (`GENTLE_AI_REVIEW_BINDING {json}`), runs a locked-down reviewer, validates the schema and admits the result. `[CERT]` (`reviewer_context_markers.go:19`)
8. Final admitted capture returns last-event-closure/v1: `approved` + acknowledgement token, or `correction_required` + `status_continuation`. `[CERT]`
9. Correction: STATUS → `collect` refuter/validator input; at most one bounded correction. `[CERT]` (`status-v9.schema.json`)
10. Host runs the exact acknowledgement once → `review-acknowledged/v1`; authority is burned. `[CERT-a]`
11. `stop` or failure: closed reason codes (§31.4); `failure/v2` with `mutation_outcome` and `retry_safe`. `[CERT]`
12. Delivery (commit, push, PR) lies outside the lifecycle. `[CERT-a]`

## 31.17 — Open questions

- `[GAP]` The reviewtransaction state-machine implementation (`compact.go`, `compact_store.go` revision/CAS) and the stop-hook body were not read.
- `[GAP]` `gentle-ai review schema …` was not run and fixtures were not validated against schemas.
- `[GAP]` When status v5→v9 arrived and what each added: needs `git log v2.2.0..v4.0.0 -- contracts/`.
- `[GAP]` The MCP (Engram) wire protocol, collector internals (`internal/telemetrycollector`) and `contracts/telemetry/runtime/v1` were not examined.

## 31.18 — Connections

- **[Block 28]** — contract version history (stable v2.5.0, default-on v3.5.0) and the `assess` additions; §31.10 reverses what [Block 12] §12.5b described as the native receipt gate.
- **[Block 26]** — §26.2.3 named the `review` family a `[GAP]`; this block documents its protocol, not each subcommand.
- **[Block 27]** — `~/.gentle-ai/review-contexts/v1/` index records and the state coordination of §31.12.
- **[Block 29]** — "comment and wait" gate text is the same provider-authority principle in CI.
- **[Block 30]** — the three-token handoff is layered on consent/v3 (§31.8); `mutation_outcome: unknown` is what triggers the local defect report.
- **[Block 24]** — judgment-day is a separate blind-dual-review skill; the 4R lens agents ([Block 28] §28.5) are the contract's reviewers.
- **[Block 33]** — adoption candidates: JSON envelopes with a `schema` const, typed failure, `next_action`, expected-revision on state writes, closed reason-code table, threat-model note.
