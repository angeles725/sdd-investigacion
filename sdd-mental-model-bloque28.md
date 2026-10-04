# Block 28 — gentle-ai v2.2.0 → v4.0.0 delta: SDD retired, ODD and default-on RDD, signing, telemetry, harness changes, and a staleness map of B1–B27

> **WHAT IT DOCUMENTS**: What changed in gentle-ai between the version this corpus was last verified against (v2.2.0, 2026-07-28) and v4.0.0 (2026-10-01): the retirement of Spec-Driven Development in favour of Organic Driven Development (ODD), receipt-driven review (RDD) becoming on-by-default, the native reviewer-model assignments, harness/runtime changes, opt-out telemetry, Minisign-signed releases and the Go module path moving to `/v4`. It ends with a STALENESS MAP that classifies every one of B1–B27 as STALE, DRIFTED or STILL-VALID against v4.0.0.
> **SCOPE**: The delta, not a re-documentation. It does NOT rewrite B1–B27 (only the map in §28.9 records their status); the issue/PR process, automated issue generation, component communication and the creation/installation surface are blocks [Block 29], [Block 30], [Block 31] and [Block 32]; the kit adoption ranking is [Block 33].
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01. Delta baseline: v2.2.0 (2026-07-28), the newest version the corpus previously verified (METHODOLOGY §3 "delta claims name their baseline"). Where a finding is dated to an intermediate release, that release is named.
> **SOURCES**: gentle-ai source cloned at `~/investigacion/sources/gentle-ai` checked out at tag v4.0.0 (paths below are relative to it); upstream release notes v2.2.1..v4.0.0 (26 stable tags, rc tags skipped because stables promote them), URL pattern `https://github.com/Gentleman-Programming/gentle-ai/releases/tag/vX.Y.Z`; `gentle-ai --help` of the installed 4.0.0 binary (read-only).
> **METHOD**: Static reading of the v4.0.0 tree plus release notes, collected by a delegated sweep and spot-checked by the block author. `[CERT]` = source bytes read, `path:line` cited. `[CERT-a]` = stated by upstream release notes or docs, not checked in code (kit marker: secondary source). `[INFER]` = deduction. No state-mutating subcommand was run. `[DRIFTED v2.2.0→v4.0.0]` marks a fact that changed.
> **Type:** mixed

---

## 28.1 — Range and counting baseline `[CERT-a]`

| Item | Value | Source |
|---|---|---|
| Stable tags read | 26 (v2.2.1 … v4.0.0) | release notes `[CERT-a]` |
| Tags in repo | 293 | local clone `[CERT]` |
| `git log v2.2.0..v4.0.0` | 3725 commits (includes patch-equivalent replays) | local clone `[CERT]` |
| Upstream-stated "real" size of the last window | 157 commits / 56 PRs; a naive `v3.7.0..v4.0.0` range overcounts (2,626) | v4.0.0 release "Numbers" `[CERT-a]` |

Upstream's v4.0.0 notes admit `v3.7.0` is not an ancestor of `v4.0.0` and re-baseline the counts at the replay commit `[CERT-a]` (v4.0.0 notes). Consequence for this corpus: any "N commits since X" figure must name its range expression; 3725 is a raw `git log` count, not an authored-change count `[INFER]`. Release notes also carry a `## Provenance` block (previous stable sha, target sha, workflow run id, CI and Windows Full Suite run ids, reruns disclosed) `[CERT-a]` (v4.0.0 notes); see [Block 32] §32.7.

## 28.2 — SDD retired; ODD is the only workflow `[CERT]`

Timeline `[CERT-a]`:

| Release | Date | Change |
|---|---|---|
| v3.0.0 | 2026-09-16 | ODD becomes the mandatory default protocol on Claude Code, OpenCode, Codex, Pi. SDD becomes "a branch inside ODD entered only by explicit request"; research and verify become optional; archive no longer needs a verification report. RDD removed from the SDD lifecycle and becomes a standalone user-owned switch. |
| v3.1.0 | — | Every ODD task ends with a work-unit commit on a feature branch; delivery strategy and chained PRs (formerly SDD-only) apply to organic work; ~400-line budget. |
| v4.0.0 | 2026-10-01 | SDD and OpenSpec removed entirely. |

What v4.0.0 removed `[CERT-a]` (v4.0.0 "Breaking changes"): the `/sdd-*` commands, SDD profiles and phases, OpenSpec integration; subcommands `sdd-status`, `sdd-continue`, `sdd-attempt`, `sdd-archive-compose`, `sdd-task-result`, `sdd-preflight-hook`; flags `--sdd-mode`, `--sdd-profile-strategy`.

Code confirmation `[CERT]`:

- `ls internal | grep -ci sdd` returns 0: no `sddstatus` or `sdd` package remains.
- `internal/assets/skills/` holds `_shared, branch-pr, chained-pr, cognitive-doc-design, comment-writer, gentle-ai-bench, go-testing, hermes-ephemeral-delegation, issue-creation, judgment-day, rdd-defect-workflow, skill-creator, skill-improver, skill-registry, systemic-issue-triage, work-unit-commits` — no `sdd-*` entry.
- `gentle-ai --help` (4.0.0) lists install/uninstall/sync/skill-registry/review/... and no `sdd` command.
- Strict TDD is no longer a choice: the flag survives only to be rejected — `internal/cli/sync.go:187` declares `"strict-tdd"` as `"retired: ODD uses applicable test-first development by default"` (error text at `:227` asks to rerun without it). `[DRIFTED v2.2.0→v4.0.0]` ([Block 23] described it as a selectable mode).
- A stale string survives: `internal/cli/telemetry.go:63` still mentions `sdd-attempt` in host guidance although the command is gone `[CERT]`. `[INFER]` the retirement was a delete-sweep, not a rewrite of every string.
- Machine-side residue: on the machine this corpus runs on, `~/.claude/agents` still holds `sdd-*` agent files while the v4.0.0 asset tree ships only 8 Claude agents (see [Block 32] §32.2). Whether `sync` prunes them is unverified `[INFER]`.

## 28.3 — The ODD protocol and the delegation rule `[CERT]`

ODD is a 7-step protocol rendered from a shared template into each runtime's orchestrator prompt: Authorize, Explore, Resolve uncertainty, Classify, Track before first write, Implement task by task, Close. Template placeholders `{{GENTLE_AI_ODD_SECTION:...}}` at `internal/assets/claude/orchestrator.md:9-11`; the same template ships to codex, cursor, hermes, kiro, qwen, windsurf, generic and antigravity `[CERT]`. Feature tracking: `odd/tasks/<feature>.md` plus an Engram mirror under topic `odd/<feature>/tasks` (introduced v3.0.0 `[CERT-a]`; the topic is verified only through prompt text, not code — [Block 32] §32.5). `[DRIFTED v2.2.0→v4.0.0]` the SDD topic keys `sdd/{change}/{artifact}` ([Block 3], [Block 20]) are replaced.

Delegation rule changed twice `[CERT-a]`:

| Version | Rule |
|---|---|
| v2.2.0 (B18 baseline) | file-count triggers and a phase→model table |
| v3.2.1 | mapping at 4+ files, writer at 2+ non-trivial files, backstop after ~20 tool calls / 5 exploratory reads / 2 non-mechanical edits |
| v4.0.0 | **evidence budget**: inline only for one parallel batch, at most 3 calls and ~10k tokens; otherwise one explorer returns a bounded `path:line` handoff of ~2k tokens |

The v4.0.0 wording sits at `internal/assets/claude/orchestrator.md:65,81` and is pinned by `internal/assets/orchestrator_evidence_budget_test.go` `[CERT]`. Prompt wording is pinned as text by ratchet tests (`internal/assets/orchestrator_drift_ratchet_test.go`) — the product behaviour and the prompt contract are the same artifact `[CERT]`.

## 28.4 — RDD: from opt-in to default-on `[CERT]`

History `[CERT-a]` (release notes):

- v1.47.0: RDD introduced (per this corpus's [Block 26]); v2.5.0: declared stable. Contract `gentle-ai.review-integration/v2`, schemas start/v4, status/v6, consent/v3, provider bundle 1.1.0. FINALIZE, compact receipts and the delivery gate were removed: "approval is terminal and acknowledged", delivery follows ordinary repository policy. At that point RDD "stays opt-in".
- v2.6.0 .. v4.0.0: provider contract 1.2.0, called "byte-frozen" in every note since v2.8.0. `contracts/review-provider-contract/CONTRACT_SEMVER` reads `1.2.0` `[CERT]`.
- v3.0.0: RDD leaves the SDD lifecycle; user-owned switch `gentle-ai review mode enable|disable|status`.
- **v3.5.0: on by default (opt-out).** Code: `internal/reviewtransaction/rdd_mode.go:700-701` — comment "An unset installation permits review without recording a user decision" and `status.Effective, status.Source = RDDModeOn, RDDModeSourceDefault`; explicit clone-local or global OFF keeps precedence (`:692-695`) `[CERT]`. README.md:151 states "on by default and opt-out" `[CERT]`. `[DRIFTED v2.2.0→v4.0.0]` [Block 26] documented RDD as unstable and opt-in.

Other RDD-era additions:

| Release | Addition | Evidence |
|---|---|---|
| v2.7.0 | `gentle-ai review assess --json`: read-only risk tier passive/medium/high | `[CERT-a]` |
| v3.4.0 | `candidate.consumed`, `review_due`, `review_due_reason` (`high_risk`, `slice_budget_reached`, `passive`, `under_budget`, `already_reviewed`) and a verbatim `next_transition` command; vocabulary at `internal/cli/review_assess.go:39-61` | `[CERT]` |
| v4.0.0 | assess judges added lines, not unchanged source (#4971) | `[CERT-a]` |
| v4.0.0 | negotiated STATUS returns a runnable native `review recover` (predecessor/successor lineage, expected revision); v2.2.x stores classified "historical"; typed refusal on filesystems that cannot hold mode 0700 (WSL DrvFS, exFAT, SMB) | `[CERT-a]` |

Consent stays per candidate: accept covers one candidate, "not now" persists nothing (`gentle-ai --help` 4.0.0 text: "'review start' asks per candidate ... a session without a terminal reviews the change and says so instead of asking") `[CERT]`; shared envelope core `internal/consentenvelope/envelope.go:1-3`. The v4.0.0 recovery fixes matter for WSL2 hosts like this corpus's `[INFER]`. The full protocol is [Block 31].

## 28.5 — Reviewer agents and native model assignments `[CERT]`

The lens model is unchanged: 4R (risk, resilience, readability, reliability) plus refuter plus targeted validator. Agents ship per runtime, e.g. `internal/assets/kimi/agents/review-risk.md` and `internal/assets/cursor/agents/review-risk.md`; the Claude set is `review-risk/resilience/readability/reliability/refuter` plus `jd-judge-a`, `jd-judge-b`, `jd-fix-agent` `[CERT]` (`internal/assets/claude/agents/`).

v3.7.0 (2026-09-23, PR #4912) `[CERT-a]`: Claude Code saves and applies six native reviewer model assignments; OpenCode exposes editable `general` and `explore` models; Codex supports custom ODD agent and reviewer models with fallback to supported defaults if a saved assignment is unavailable; isolation unchanged. v4.0.0 Codex presets recommend `gpt-6.1-{astra,sol,luna}` (#5154) `[CERT-a]`. `[GAP]` the storage of the six assignments was not located in code (`internal/model/model_assignment.go` exists; no reviewer-specific keys found) — settle by reading `internal/model/*` and the TUI screens.

## 28.6 — Harness and runtime changes `[CERT-a]` unless noted

- **OpenCode**: v3.3.0 version-aware (V1 vs V2 beta, fail closed on unknown). v4.0.0: V2 gets four managed plugins (telemetry, model catalog, skill registry, review transport), optional SDK 2.0.4 provisioning with separate consent, native review admitted only with an exact relay declaration, `sync` exits non-zero when the OpenCode version is undetectable. Proven only on OpenCode 2.0.19 / macOS with a scripted provider (limits quoted from `docs/opencode-compatibility.md`).
- **Pi**: v2.6.0 review contract via provider bundle; v3.4.0 refuter/validator roles host-mediated by gentle-pi (`--materialize=true` + `--input`), Go-owned pi adapter deleted; v3.6.0 honours `PI_CODING_AGENT_DIR`; v3.6.1 prunes a third-party `ask_user_question` package; v4.0.0 retires `pi-mcp-adapter` for Pi >= 0.99.0 built-in MCP. Code: `internal/agents/pi/adapter.go:22-27` (`retiredPiMCPAdapterPackage = "npm:pi-mcp-adapter"`) `[CERT]`.
- **Scoping (v4.0.0, #5005)**: RDD guidance ships only to runtimes with native review transport (Claude Code, Codex, OpenCode; Pi's prompt is owned by Gentle Shell); every other runtime gets ODD-only prompts. New: Conductor (thin), Kimi `~/.kimi-code`, Antigravity Engram as plugin, `sync --scope=workspace`.
- **Removed**: the RTK community tool (added v2.9.0, retired v3.4.0 as "the release's one breaking change").
- Adapter directories under `internal/agents/` now include `antigravity, claude, codex, conductor, cursor, gemini, hermes, kilocode, kimi, kiro, openclaw, opencode, pi, qwen, trae, vscode, windsurf` plus `capability_manifest.go` `[CERT]` (`ls`). `[DRIFTED v2.2.0→v4.0.0]` [Block 27] counted 16 adapters; whether `defaultAgentIDs` grew is a re-typed gap (see RESEARCH-STATE).

## 28.7 — Telemetry `[CERT]`

v2.7.0 added the first opt-in-notice, opt-out anonymous telemetry: one install event plus at most one daily heartbeat, fixed-enum fields only `[CERT-a]`. Kill switches `DO_NOT_TRACK`, `GENTLE_AI_TELEMETRY=0`, `CI=true` — `internal/telemetry/killswitch.go:10-12`; heartbeat decision `internal/telemetry/opportunistic.go:35` `[CERT]`. The collector and Grafana dashboard live in-repo (`cmd/gentle-telemetry`, `deploy/telemetry/`) `[CERT-a]`. Later releases `[CERT-a]`: v2.8.1/2.8.2 model attribution and idempotent Claude Stop telemetry; v3.2.1 runtime store moved to VictoriaMetrics after SQLite single-writer trouble; v3.4.0 fixed a scrape-size ceiling that silently zeroed the dashboard; v4.0.0 reports effort and classifies Claude Code built-in subagents.

`[INFER]` the v3.4.0 scrape-size fix is an external instance of the kit's anti-silent-zero doctrine (a reading of 0 that could not prove it had looked); candidate corroboration in [Block 33].

## 28.8 — Module path, signing, provenance and install correctness

- **Module path** `[CERT]`: `go.mod:1` = `module github.com/gentleman-programming/gentle-ai/v4`, `go 1.25.10`. History `[CERT-a]`: v2.x was `/v2`; v3.0.0 shipped as tag v3 while go.mod stayed `/v2` so `go install` was rejected and Windows locked out; v3.0.1 moved to `/v3`; v3.0.2 fixed install scripts still on `/v2`; v4.0.0 moved to `/v4`. `[DRIFTED v2.2.0→v4.0.0]` [Block 26]/[Block 27] cite `/v2`.
- **Signing** `[CERT]`: `checksums.txt` is signed with Minisign; the signed identity string must equal `repo=Gentleman-Programming/gentle-ai;tag=vX.Y.Z`; trust anchors are injected by linker variable `.../v4/internal/update/upgrade.releaseMinisignPublicKeys`, default `UNSET`, so source builds refuse network self-update; archive cap 128 MiB (`docs/release-signing.md`, `internal/update/upgrade/download.go:53-57`). Details in [Block 32] §32.7.
- **Upgrade path** `[CERT-a]`: v3.7.0 binaries hardcode `/v3` and cannot self-upgrade to v4 on Go installs (read from v3.7.0 source; live run not observed). Windows: no binary archives, fail closed to Go-based guidance.
- **Install/sync correctness fixed in v4.0.0** `[CERT-a]`: `sync` applied components in stored order so the persona overwrote the Engram protocol on 7 runtimes; `WriteFileAtomic` forced mode 0644 (making 0600 configs world-readable); TOML edits mis-parsed `[section]` inside multiline strings. `[INFER]` same family as the kit's "instrument false confidence": a writer that reports success while having changed the wrong thing.

## 28.9 — STALENESS MAP of B1–B27 against v4.0.0

Status vocabulary: **STALE** = documents machinery removed or replaced at v4.0.0 (valid only as v<=3.x history); **DRIFTED** = concept survives but facts changed; **STILL-VALID** = no contradiction found. The INDEX.md header (written 2026-07-28 at v2.2.0) is itself outdated. Basis: block topic columns in INDEX.md compared with the findings above; block bodies were NOT re-read `[INFER]`.

| Block · title | Status | Reason | Citation |
|---|---|---|---|
| B1 · What SDD is | DRIFTED | thin-coordinator philosophy survives; SDD is no longer the product workflow, ODD is | `internal/assets/claude/orchestrator.md:9-11`; v3.0.0 notes |
| B2 · Phase DAG and Result Contract | STALE | all `sdd-*` phases removed | `ls internal/assets/skills` (no `sdd-*`); v4.0.0 "Breaking changes" |
| B3 · Artifact backends and topic keys | STALE | engram/openspec/hybrid/none and `sdd/{change}/{artifact}` replaced by `odd/<feature>/tasks`; OpenSpec removed | v4.0.0 "Breaking changes"; §28.3 |
| B4 · `sdd-init` | STALE | skill and command removed | `ls internal/assets/skills` |
| B5 · `sdd-explore` | STALE | skill removed; ODD step 2 "Explore" replaces it | `orchestrator.md:9-11` |
| B6 · `sdd-propose` | STALE | skill removed | `ls internal/assets/skills` |
| B7 · `sdd-spec` | STALE | skill removed | `ls internal/assets/skills` |
| B8 · `sdd-design` | STALE | skill removed | `ls internal/assets/skills` |
| B9 · `sdd-tasks` | STALE | replaced by `odd/tasks/<feature>.md` checklist with route/evidence fields | `odd/tasks/` (30 `.md` files); [Block 32] §32.5 |
| B10 · `sdd-apply` | STALE | skill removed; ODD step 6 "Implement task by task" | `orchestrator.md:9-11` |
| B11 · `sdd-verify` | STALE | verify optional since v3.0.0, `sdd-verify-validate` retired, phase gone | v3.0.0 notes; v4.0.0 "Breaking changes" |
| B12 · `sdd-archive` | STALE | archive ungated since v3.0.0, phase gone | v3.0.0 notes |
| B13 · `sdd-onboard` | STALE | skill removed | `ls internal/assets/skills` |
| B14 · `sdd-new/continue/ff` | STALE | meta-commands removed | v4.0.0 "Breaking changes" |
| B15 · `sdd-status` dispatcher | STALE | `sdd-status`, `sdd-attempt` subcommands removed; `internal/` has no sdd package | `ls internal` (0 matches) |
| B16 · Execution modes and Gatekeeper | STALE | no execution-mode switch in ODD; `--sdd-mode` removed | v4.0.0 "Breaking changes" |
| B17 · Delivery strategy and chained PRs | DRIFTED | concept survives, re-homed in ODD (v3.1.0); strategy names unchanged | `internal/components/agentguidance/routing_test.go:348`; v3.1.0 notes |
| B18 · Delegation, triggers, model assignments | STALE | file-count triggers replaced by an evidence budget; phase→model table gone; native reviewer model assignments added | `orchestrator.md:65,81`; v3.7.0 notes |
| B19 · Persistence contract | STALE | persistence modes engram/openspec/hybrid gone | v4.0.0 "Breaking changes" |
| B20 · Engram convention | DRIFTED | Engram and `mem_*` tools survive; topic-key scheme changed to `odd/<feature>/tasks` | §28.3 |
| B21 · OpenSpec convention | STALE | OpenSpec removed entirely | v4.0.0 "Breaking changes" |
| B22 · Skill-resolver + phase-common + status-contract | DRIFTED | skill-registry (paths, not digests) survives; phase-common and status-contract gone | `docs/skill-registry.md`; `internal/skillregistry/guard.go:3-30` |
| B23 · Strict TDD | STALE | flag retired; test-first is the ODD default | `internal/cli/sync.go:187` |
| B24 · judgment-day | STILL-VALID | skill and `jd-judge-a/b`, `jd-fix-agent` still ship; presence verified, body not re-read | `internal/assets/skills/judgment-day`; `internal/assets/claude/agents/` |
| B25 · 15 harnesses and delegation models | DRIFTED | harness set changed (Conductor, Kimi, Antigravity plugin, Pi MCP, OpenCode V2); RDD guidance scoped to 3 runtimes | `ls internal/agents`; v4.0.0 #5005 |
| B26 · Configurator | DRIFTED | `sync --scope=workspace`, removed flags, `review` family, telemetry command, `/v4` module, signed upgrade | `go.mod:1`; `internal/cli/sync.go:187` |
| B27 · `state.json` and adapters | DRIFTED | SDD-related state fields inert; adapter set grew; model assignment fields changed | `ls internal/agents`; §28.5 |

Totals (computed from the table): STALE 19 · DRIFTED 7 · STILL-VALID 1 = 27. `[INFER]` Matches the sweep's estimate that ~19 blocks describe machinery that no longer exists. The review command family, flagged `[GAP]` in [Block 26] §26.2.3, remains uncovered by any block until a dedicated one is written; [Block 31] documents its communication contract but not each subcommand.

## 28.10 — Open questions

- `[GAP]` Reviewer model assignment storage and schema (§28.5).
- `[GAP]` v2.2.1..v2.9.1 were read at heading level only; per-release detail (about 200 review commits in v2.4) would be needed for a review-lifecycle history block.
- `[GAP]` Release-note numbers (157 commits / 56 PRs; 48,378 additions / 123,473 deletions) are upstream-stated, not recomputed.
- `[GAP]` The staleness map is based on topic columns, not a re-read of each block file.
- No live `review` subcommand was run; recovery and consent behaviour is `[CERT-a]`.

## 28.11 — Connections

- **[Block 1]–[Block 27]** — classified in §28.9; none rewritten here.
- **[Block 26]** — declared RDD unstable and opt-in and the `review` family a `[GAP]`; §28.4 supersedes the first, [Block 31] covers the contract of the second.
- **[Block 29]** — the process side: how the 400-line heuristic (§28.3) is enforced in CI.
- **[Block 30]** — the automated defect-report flow that appeared in the same orchestrator prompt as ODD (commit lineage in §30.2).
- **[Block 31]** — the review-integration contract introduced in outline in §28.4.
- **[Block 32]** — creation/installation surface, the ODD working method and release provenance expanded from §28.2 and §28.8.
- **[Block 33]** — adoption candidates for the kit derived from this delta (e.g. evidence-budget delegation rule, provenance block).
- **[Block 34]** — how the prompt-pinning tests (e.g. the banned stale phrases "1–3 files" / "4+ files" that §28.3 replaced) and hook/permission design enforce instruction adherence.
