# Block 34 — How gentle-ai makes agents follow instructions: authority moved from prose to binary-issued argv, isolation by harness, and tests that pin prompt text

> **WHAT IT DOCUMENTS**: The layered strategy gentle-ai v4.0.0 uses to get agents to follow instructions exactly: (A) a disciplined prose layer (single-source rendering, fail-closed render, model-tier variants, wording patterns, executor-override line), (B) moving every step that must happen exactly into the Go binary, which issues the literal argv, (C) harness-level isolation and permissions instead of prompt-level prohibitions, (D) Stop/SessionStart hooks, (E) 109 Go tests that pin prompt text including banned-stale-phrase checks, and (F) the honest admission that no live-compliance metric exists. It compares each layer with the kit.
> **SCOPE**: Instruction adherence as a design problem. The review wire protocol is [Block 31]; the ODD prompt content is [Block 28]; the process side is [Block 29]. It does not measure model compliance (nobody upstream does).
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01. Kit side: `origin/main` in the writing worktree, 2026-10-04.
> **SOURCES**: `docs/testing-agents-deterministically.md`, `internal/assets/**` (orchestrators, `*_test.go`, `skills/_shared/review-ledger-contract.md`), `internal/components/{agentguidance,agenthooks,opencodeagents,permissions}`, `internal/cli/{review_next_transition,review_stop_hook}.go`, `internal/reviewerprovider/claude_adapter.go`, `bench/README.md`; issues #3817, #636, #1286, #3411, #262, #1702, #4923, #4703; kit: `CLAUDE.md`, `research-sdd/PROMPT-LOOP.md`, `research-sdd/toolbelt/{render-profile,score-loop-transcript,retro-gate,research-sdd-status}.sh`.
> **METHOD**: `[CERT]` = bytes read (`path:line`) or issue page read; `[CERT-a]` = upstream doc claim whose enforcement was not traced in code; `[INFER]` = deduction. Counts are dated listings (2026-10-04).
> **Type:** mixed

---

## 34.1 — Thesis `[CERT]`

gentle-ai's own statement is that compliance cannot be prompt-engineered: "an agent performs that ceremony slowly and cannot be trusted to perform it honestly. A model asserting 'I verified it, it passes' is prose, not proof" (`docs/testing-agents-deterministically.md:14`). Steps that must be exact live in the binary, which issues the exact argv; prompt text only routes the model to that binary and is pinned by string-level tests whose own comment says they prove "shipped policy text, not live model compliance or context telemetry" (`internal/assets/orchestrator_evidence_budget_test.go:8`).

## 34.2 — Layer A: the prose layer `[CERT]`

1. **Single source plus renderer.** Per-runtime `orchestrator.md` carry `{{GENTLE_AI_ODD_SECTION:<name>}}` placeholders (`internal/assets/claude/orchestrator.md:7,11,55,91,116,120`) expanded from one shared asset by `internal/components/agentguidance/orchestrator.go:114-115,268-298`. Motivation was measured drift: 12 copies of one contract ranged 123 to 501 lines (issue #3817, closed 2026-08-28).
2. **Fail-closed render.** An unknown section name errors (`orchestrator.go:291-293`); a leftover literal `{{GENTLE_AI_` errors (`:236-238`); a malformed or overlapping model section in the generic asset errors instead of falling back to full text (`:150-183`).
3. **Capability withheld when unrunnable.** For runtimes without RDD the review section is removed, leak markers re-scanned, any survivor an error (`orchestrator.go:220-232,247-265`). `[INFER]` this removes the class "model follows an instruction for which it has no tool".
4. **Model-tier variants.** The generic orchestrator has `model-capable` and `model-small` sections; the small one is a short numbered list and "load only up to 3 relevant SKILL.md paths" (`internal/assets/generic/orchestrator.md:1,118,120-136`; selector `orchestrator.go:152-183`; `internal/components/skills/inject.go:196-201`). Issue #636: missing sections made `extractModelSection` fall back to the full file with an ambiguous gate.
5. **Wording patterns** (`claude/orchestrator.md:17,20`; `skills/_shared/review-ledger-contract.md:3,5,30`): absolutes with full enumeration ("Never summarize, abbreviate, reorder, relabel, merge, or omit choices"); an explicit allowed-answer domain (exact-one case-insensitive match, ordinal aliases, reject zero and multiple matches); fail-closed defaults ("`unknown` never lowers a tier", "never invent PASS"); authority disclaimers ("Prompt prose never creates authority or decides delivery"); ordered procedures as numbered steps and tables; reason-code to continuation tables.
6. **Executor-override line.** A delegated skill's gate ("do NOT execute inline, delegate") must be paired with "If you ARE the executor, this gate does NOT apply ... Do NOT delegate", or subagents delegated to themselves, returned empty or ignored instructions (issue #636, closed 2026-05-26).
7. **Persona, style, language separated.** The "Language Domain Contract" says persona governs conversation only and artifacts default to English (`language_contract_test.go:77,132,363,386`); driven by voseo leaking into artifacts (#1702, #4923 closed; #4703 open).
8. **"Self-check BEFORE every response"** skill-match line is repeated in persona assets (`claude/persona-gentleman.md:23`) but its effect is not code-verified: issue #1286 (open) records `skill_resolution: paths-injected` as a subagent self-report with no runtime evidence.

## 34.3 — Layer B: authority moved into the binary `[CERT]`

- **Provider-issued transitions.** `ReviewNextTransition` is "the sole negotiated routing decision": `execute` carries `Operation`, a literally runnable `Command`, ordered `Arguments`, `Preconditions`, `Binding`; `collect` names one external input; `stop` carries no command-shaped data (`internal/cli/review_next_transition.go:22-90`). The prompt's whole job is "execute its operation and ordered argument tokens unchanged" (`review-ledger-contract.md:3`). Refusal of wrong, stale or replayed acknowledgement tokens is `[CERT-a]` (path not traced). Protocol detail: [Block 31].
- **Typed consent.** Machine answer tokens must not be translated and the decline invocation is provider-owned; "Never synthesize the decline command ... from prose" (`claude/orchestrator.md`, Provider Defect Handoff section) `[CERT]`; envelope enforcement by Go `[CERT-a]`.

## 34.4 — Layer C: isolation and permissions by harness `[CERT]`

- The Claude reviewer runs as `--print --tools "" --permission-mode dontAsk --no-session-persistence --setting-sources "" --system-prompt "You are an isolated code reviewer process…"` in an empty temp dir with material on stdin (`internal/reviewerprovider/claude_adapter.go:27-41,46-60`); the prompt then forbids the parent from assembling reviewer prompts.
- OpenCode role agents: `gentle-ai-explore` denies write/edit/bash/task, `gentle-ai-verify` denies write/edit/task, `gentle-ai-worker` denies task (`internal/components/opencodeagents/agents.go:21-23`). Claude judge agents carry a Read/Glob/Grep-only `tools:` allowlist (frontmatter of `internal/assets/claude/agents/jd-judge-*.md`). Global deny/ask rules cover `rm -rf /`, `git push/commit/rebase/reset --hard`, ssh/scp/rsync, `.env`, `secrets/**` (`internal/components/permissions/inject.go:33-90`).
- **What stays prose, openly.** "Do not run tests/builds/edits inline" for the orchestrator is still prose. Issue #3411 (open; last comment 2026-09-30) measured the orchestrator at 72% of tokens (594M cache-read) against 28% for all subagents over 10 days; the remedy under study is permission-level deny on the orchestrator agent, not stronger wording. Issue #262 (closed not_planned with SDD): subagents reported "done" while Strict TDD was ignored and verify skipped, "because it relies entirely on sub-agent self-reporting".

## 34.5 — Layer D: hooks `[CERT]`

`internal/components/agenthooks/claude.go:49-58`: `Stop` and `SessionStart` (`startup|resume|clear|compact`) run `gentle-ai review stop-hook`; async telemetry on `Stop` and `SubagentStop`; the skill registry refreshes on `UserPromptSubmit` for Claude and `SessionStart` for Codex (`skill_registry.go:80-88`). Stop-hook design (`internal/cli/review_stop_hook.go:20-75,166,217-218`): SessionStart records a **baseline** of existing unreviewed candidates; Stop emits one `{"decision":"block","reason":…}` per candidate identity; the reason embeds the exact `next_transition.execute.command`; silent when `stop_hook_active`; a quiet window while a writer is still changing the candidate (#4494); it never runs `review start`. This body was unread in [Block 31] §31.11; this block supersedes that gap.

## 34.6 — Layer E: tests that pin prompt text `[CERT]`

Volume: 26 `*_test.go` files in `internal/assets/` (5,698 lines, 109 `func Test` by `grep -c '^func Test'`), plus more in `internal/components/agentguidance/` and `reviewassets/`.

| Style | Example |
|---|---|
| required-marker lists | `orchestrator_evidence_budget_test.go:12-22` |
| **banned stale phrases** | `"1–3 files", "4+ files", "4-file rule", "up to 3 files inline", "20 tool calls", "5 exploratory reads", "2 non-mechanical edits"` (`orchestrator_evidence_budget_test.go:24-30`); `"Refs #N does NOT satisfy", "git stash", "gh pr create --title"` (`skill_friction_contract_test.go:35-41`) |
| corpus-wide absence walk | `store_branching_absence_test.go:18-40`: fails if any `.md` asset still tells actors to bypass the dispatcher; its comment notes the first prose fix reached one runtime and left ten carrying the contradicted text |
| drift ratchet | `orchestrator_drift_ratchet_test.go:17-26,83`: hashes each heading body across 12 runtimes, caps distinct variants per section (Delegation Rules ≤ 11, Lossless ≤ 6, Language Domain Contract ≤ 2), asserts the inventory is exactly 12; lowering a ceiling is deliberate |
| tests on the rendered, installed prompt | `orchestrator_parity_test.go:109-140`: real `InjectRoutingWithOptions`, each parity heading exactly once (count==1 catches loss and duplication), `paths-injected` contract present, Pi-only content absent elsewhere |
| authority identity | `issue_creation_authority_test.go:11-70`: duplicate skill file must not exist; AGENTS.md carries the exact registry row |
| no literal runtime identity in shared assets | `runtime_identity_test.go:26` |

## 34.7 — Layer F: behavioural evaluation, and its limits

- **Scripted-model E2E** `[CERT-a]`: `TestRealAgentOrganicJourneys` keeps everything real except reasoning (pinned OpenCode binary, shipped prompt asset, built gentle-ai binary, real git and TLS); a local HTTP server plays the model with a switch on call number; the fixture is adversarial and fails on, e.g., "work-advance was requested before actor commit evidence" (`docs/testing-agents-deterministically.md:46-75,140-170`). The doc says it does not prove a live model emits those calls: "a product question, answered by usage, not by CI" (`:250-262`).
- **gentle-ai-bench** `[CERT]` (`bench/README.md:43-127`): measures the binary's friction (human_prompts, manual_tokens, commands_to_completion, five block buckets, recovery_round_trips, model_runs, human_surface_bytes), driven or observed (PATH shim); `unsupported` is never scored 0; the only recorded measurement is a 14-journey run on an old build (`:409-445`). Details: [Block 32] §32.6.
- `[INFER]` No live-model adherence metric exists upstream; adherence is managed by shrinking what the model must decide, not measured.

## 34.8 — Kit comparison

| Aspect | Kit today | Reading |
|---|---|---|
| RETURN CONTRACT continuation token | model-authored `next:`/`next-entry:`/`STOP:`; `research-sdd-status.sh --next` computes the answer deterministically (`toolbelt/research-sdd-status.sh:2-13`); no check found that the emitted token matches it `[CERT]` files, `[INFER]` missing check | the largest gap versus layer B |
| Single-source plus tiers | `render-profile.sh` slots, per-family profiles, fails on orphan or missing slot (`toolbelt/render-profile.sh:53-56,319-320`); `profile-invariants.test.sh` re-runs invariants per rendered copy | already equivalent to A1/A4 `[CERT]` |
| Absent/required anchors | skill-invariants, hotcore-budget, verify-doc-consistency | per-suite, SKILL-focused `[CERT]` |
| Stop hook | `retro-gate.sh:2-11` block-once with `{"decision":"block"}`; no SessionStart baseline found | same shape as D, minus baseline |
| Live adherence metric | `score-loop-transcript.sh:2-30` scores transcripts on C1 continuation, C2 questions asked, C3 compaction | **kit is ahead**: upstream has none |
| Routing rule | `CLAUDE.md:23-24` says "Read 1–3 files" / "Understand 4+ files"; upstream's test bans exactly these strings as stale triggers replaced by an evidence budget; the user-global instructions inject that budget, so two contradictory rules coexist in one session `[CERT]` | kit delta (retro) |

## 34.9 — Open questions

- `[GAP]` Refusal paths for wrong/stale/replayed ack tokens and consent validation (`internal/reviewtransaction/*`) not traced.
- `[GAP]` `e2e/organicruntime/organic_runtime_test.go` not opened; §34.7 rests on the doc.
- `[GAP]` Kit: whether profile-invariants counts headings and whether sweep templates carry executor-override text (greps before scoping candidates in [Block 33]).
- `[GAP]` Per-runtime differences in codex/opencode/pi orchestrators beyond the renderer; Pi's prompt is owned by Gentle Shell (`orchestrator.go:191-193`).

## 34.10 — Connections

- **[Block 28]** — the evidence-budget rule (§28.3) is the text whose stale predecessor is banned here (§34.6).
- **[Block 31]** — layer B is the protocol of §31.3-§31.6; §34.5 fills the stop-hook gap of §31.11/§31.17.
- **[Block 32]** — bench (§32.6) and drift-pinned managed prompt block (§32.4).
- **[Block 29]** — the "comment and wait" agent-addressed gate text is layer A applied to CI.
- **[Block 30]** — the Provider Defect Handoff is the largest prose-only protocol; tests pin its text (§30.2).
- **[Block 33]** — candidates 2, 4, 7, 20-24, 27 and 32 merge this block's adoption list.
- **[Block 24]** — the jd-judge tool allowlists (§34.4).
