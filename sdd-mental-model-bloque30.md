# Block 30 — Automated issue generation in gentle-ai: the Provider Defect Handoff, its prompt-only nature, the local scrubbed report, and what the tracker shows

> **WHAT IT DOCUMENTS**: How gentle-ai v4.0.0 lets an agent file defect reports about gentle-ai itself: the "Gentle AI Provider Defect Handoff" protocol embedded in each runtime's orchestrator prompt (admissibility gate, three-token consent, privacy scan, definitive lookup, canonical tracker with occurrence comments, evidence channel, failure ladder), the one piece of Go that writes a local scrubbed report, the `issue-creation` skill that actually runs `gh`, the unimplemented label-versus-marker decision, and measured tracker figures including report quality.
> **SCOPE**: Issues produced by agents about the product. The human issue/PR process is [Block 29]; the typed consent envelope and the review lifecycle are [Block 31]. It does NOT document the kit's own issue staging except as comparison.
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01. Tracker counts: `gh api search/issues`, 2026-10-04 (a snapshot; one comments fetch failed on a network blip, so comment counts are lower bounds). Introduced in this form by commit `e219644b` (2026-09-25, "retire SDD in favor of ODD"); earlier lineage `463f1f1a` "report blocked provider defects safely" (2026-07-30).
> **SOURCES**: `internal/assets/claude/orchestrator.md` (and the 11 sibling orchestrators), `internal/assets/skills/issue-creation/SKILL.md`, `internal/cli/review_defect_report.go`, `internal/consentenvelope/envelope.go`, `internal/releaseprovenance/provenance.go`, the pinning tests under `internal/assets/` and `internal/components/agentguidance/`, `skills/systemic-issue-triage`, `skills/issue-root-resolution`; GitHub search over `Gentleman-Programming/gentle-ai`. Kit side: `research-sdd/toolbelt/stage-retro-issues.sh`, `reconcile-issues.sh`.
> **METHOD**: `[CERT]` = source bytes read with `path:line`; `[CERT-a]` = GitHub counts or upstream statements not recomputed in code (a tracker snapshot cannot be re-read from a tag); `[INFER]` = deduction. Counts are dated measurements, not constants.
> **Type:** mixed

---

## 30.1 — Issue creation is prompt-only `[CERT]`

A grep of `internal/`, `cmd/`, `scripts/` and `.github/` for `gh issue`, `/issues` and `CreateIssue` finds only release/commit fetchers (`internal/update/github.go:75,96,187`, `internal/telemetrycollector/downloads.go:44`) and a static "new issue" URL (`internal/cli/review_defect_report.go:23`). No Go code calls the GitHub API to file an issue. The create/comment/search logic is natural-language text installed into every agent's orchestrator prompt, plus the `issue-creation` skill, which tells the agent to run `gh issue create` and `gh issue comment` (`internal/assets/skills/issue-creation/SKILL.md:94-95`). Test files under `internal/assets/*_test.go` assert skill text containing `gh issue create`; they are the only other Go mention. Consequence: the dedup judgment, the privacy scan and the evidence-channel reasoning depend on the LLM following prose; only the pinning of that prose is machine-checked `[INFER]`.

## 30.2 — Where the protocol lives, and how it is pinned `[CERT]`

The section "Gentle AI Provider Defect Handoff (MANDATORY)" is at `internal/assets/claude/orchestrator.md:22-46` and replicated in the orchestrators of codex, opencode, cursor, gemini, kiro, kimi, qwen, hermes, windsurf, antigravity and generic. Drift is blocked by tests: the heading and the terminal sentence "Never resume against unpublished code..." are asserted in `internal/assets/blocking_prompt_contract_test.go:441-461`, `orchestrator_drift_ratchet_test.go:46`, `assets_test.go:158` and `internal/components/agentguidance/rdd_gating_test.go:14,26`. `[INFER]` Contract-as-pinned-text: the product behaviour is the sentence, the test is a string match.

## 30.3 — The protocol as a six-step state machine `[CERT]`

All of `orchestrator.md:22-46`.

| # | Step | Rule |
|---|---|---|
| 1 | Admissibility gate | Offer the handoff only when a Gentle AI invocation produced the failure (non-zero exit, typed envelope, refusal, or its own documented contract refusal). Failures from the model provider, client runtime, environment or the user's repository state are out of scope: "Do not name the component you believe is responsible... do not ask". |
| 2 | Consent | One single-select envelope, exactly three tokens in order: `report_and_continue`, `continue_without_reporting`, `stop_here`. Labels are localized; machine tokens are never shown. |
| 3 | Privacy scan | Immediately before the first GitHub operation. Exclude raw argv, absolute paths, private project names, usernames, hostnames, credentials, diffs, source contents, environment values. |
| 4 | Definitive lookup | Search open AND closed issues. "Definitive" = a completed lookup with a classifiable result; incomplete, error or unknown never branches to mutation. "Equivalent" = same observable defect and affected contract backed by concrete evidence, not title similarity; a canonical tracker owns the causal class. |
| 5 | Branch | see §30.4 |
| 6 | Failure ladder | Any search, create or comment failure, ambiguity, timeout, permission lack or unknown outcome means NO further GitHub mutation and NO blind retry; run the captured provider-owned decline invocation exactly once and resume. Creation counts as confirmed only when the create call returns a new issue identity or URL; output text never proves it. |

Both "continue" choices execute the captured `choices[answer="declined"].invocation` from the `gentle-ai.review-integration.consent/v3` envelope exactly once; if that invocation or the target identity is unavailable the handoff fails closed (`orchestrator.md:22-46`). The handoff envelope sits ON TOP of the provider's two-token consent: the typed Go piece `internal/consentenvelope/envelope.go:57-77` validates only completeness (headline, reason, value, non-nil evidence, exactly two choices `granted`/`declined` in that order, each with label, effect and runnable invocation, plus an off-path) and knows nothing about the three defect tokens `[CERT]`.

## 30.4 — Branches on the equivalent issue `[CERT]`

| Situation | Action |
|---|---|
| No equivalent found | create a new automated report |
| Equivalent, no verifiable published fix | add exactly one occurrence comment with observed evidence on that issue; change no labels |
| Fix published only to the OTHER evidence channel | one occurrence comment noting where the fix is published; no advice to switch channels |
| Installed build predates the published fix | recommend installing it and reproducing; create nothing yet |
| Build demonstrably contains the fix and still reproduces | treat as regression: comment on a suitable tracker or create a linked regression issue; never reopen automatically |

A "published fix" is a fix identified AND verifiably contained in a published release of the installed build's evidence channel; a main-only commit, local/source build, unmerged PR or unsupported assertion is not evidence (`orchestrator.md:22-46`).

## 30.5 — Evidence channel is derived by the model, not by code `[CERT]`

`orchestrator.md:35` states the recognized prerelease tags are `-rc.` and `-main.`; every other build is stable. No Go code computes this: `internal/releaseprovenance/provenance.go:33` only validates release-manifest tags of the form `vX.Y.Z[-rc.N]`. `[INFER]` The channel and published-fix reasoning is performed by the agent at report time from release notes; quality depends on its reading. Related: the prompt requires the report to carry sanitized version/build, OS/arch/client, operation shape, bounded attempts, failure envelopes, mutation outcome, expected versus actual behaviour, a minimal reproduction and opaque identifiers, and to "report observed evidence, not an unconfirmed root cause".

## 30.6 — The two concrete writers

**(a) The `issue-creation` skill** (`internal/assets/skills/issue-creation/SKILL.md:60-100`) `[CERT]`: owner-only temp files (0700/0600) cleaned on every exit path; `gh issue list --state all --search ... --limit 1000` where a saturated result counts as unknown discovery and stops with no write; candidate bodies are read and checked against the YAML issue form; a "practical privacy scan" replaces findings with `<project-name>`, `<user>`, `<hostname>`, `<token>` (step 7); create or comment, then read back from the target host (a comment's `issue_url` must match its parent); exactly one outcome `confirmed | no_write | unknown`, with no retries on unknown (step 9); labels zero or only explicitly permitted.

**(b) `internal/cli/review_defect_report.go`** writes a LOCAL report and never files it `[CERT]`:

- Input (`:30-43`): Operation (command plus flag shape, never raw argv), ReasonCode, ErrorMessage, TerminalPrecondition, StateIdentifiers.
- Scrubbing (`:105-150`): multi-line input truncated to its first line; env assignments `KEY=VAL`, any email and any absolute POSIX or Windows path redacted unconditionally; public identifiers matching `gentle-(ai|pi).<x>/vN` are placeholder-protected because hiding them once told readers to run a nonexistent command (#3443); identifier values containing a space are fully redacted (`:157-163`).
- Rendering (`:170-190`): sections mirror `.github/ISSUE_TEMPLATE/bug_report.yml`.
- Dedup by filename (`:200-216`): `<reason-slug>-<sha256[:12]>.md` under `<GitCommonDir>/gentle-ai/defect-reports/`, mode 0600, outside the worktree.
- Trigger (`:260-330`): only mutating operations whose failure code is still `operation_outcome_unknown` after the typed cascade; typed refusals are never reported; a persistence failure degrades to an empty clause so it cannot mask the real error.
- The agent is told the file path plus the new-issue URL; it does not post the file.

## 30.7 — Labeling moved out of the reporter, but the move is unfinished `[CERT-a]`

Issue #3083 (open) proposes an invisible versioned body marker `<!-- gentle-ai-provider-report:v1 -->` instead of the `gentle-report` label, because reporter credentials may lack triage rights and labels add write permission and post-creation failure modes for what is informational provenance. A grep of the v4.0.0 tree finds that marker nowhere `[CERT]`, and sampled bodies #5088 and #5195 contain none. The `gentle-report` label is on only 4 issues, all human-authored; `source:guided-report` has 0. Results are therefore found only by the title prefix `[Automated provider defect]` (see §30.8).

## 30.8 — Measured volume and quality (2026-10-04) `[CERT-a]`

| Measure | Value | Re-checked here |
|---|---|---|
| Issues with "Automated provider defect" in the title | 61 (36 open, 25 closed) | yes, from the saved listing |
| By month created | Aug 10, Sep 47, Oct 4 (to day 3); earliest 2026-08-01, latest 2026-10-03 | yes |
| Distinct authors | 59 | yes |
| Closure outcomes | 12 completed, 13 not_planned; ~10 of the 13 closed 2026-09-25 in one sweep, comment "SDD has been removed"; others duplicate (#3349 → #3326) or superseded (#2211) | from sweep |
| Issues carrying an "occurrence" comment | 37 of 61; ~204 occurrence comments | from sweep (lower bound) |
| Sum of all comment counts in the listing | 260 over 49 issues with at least one comment | yes |

The dedup path fires in practice: typical occurrence comments hold environment (build, OS, client), "stable evidence channel", operation shape and the closing line "Automated occurrence report, filed with the operator's explicit consent. Observed evidence only; no root cause asserted; no labels touched" (#5195 comments). Body quality: #5195 — filed by this corpus owner's own agent in an earlier session — has summary, numbered observed steps, expected, impact, minimal reproduction, environment, attempts and a "related but distinct: #5088" cross-link; scrub artefacts are `<lineage>`/`<ref>`-style placeholders. Many reports are true bugs (validator vocabulary mismatch, lineage minted despite failure).

Weaknesses observed `[CERT-a]`:

1. Title formats are inconsistent: `[Automated provider defect]`, `[Automated provider defect]:`, `[provider defect]`, `Automated provider defect:`.
2. Near-duplicates: #5058/#5059 share a title; at least four "Claude Code granted START ... candidate_context" reports (#5195, #5088, #5044, #5055). The dedup key is the model's judgment; no machine key exists.
3. No body marker (§30.7), so the set cannot be queried exactly.
4. Reports against retired features (SDD) pile up and are cleaned in bulk by hand.
5. Many remain open; about 4 of 10 of the first sampled page have no maintainer comment.

`[INFER]` Automated reports are ~9% of recent title volume and arrive at roughly 3 per day from crowd-sourced agents; deduplication quality is the binding constraint, not creation.

## 30.9 — Maintainer-side counterpart `[CERT]`

Clusters are handled by `skills/systemic-issue-triage` (bucket A–E) and `skills/issue-root-resolution` (closure rules A–D, borderline list) — see [Block 29] §29.7; `rdd-defect-workflow` is the single-defect flow requiring `status:approved` plus a clean reproduction on current main before implementation and one issue and PR per causal invariant.

## 30.10 — Kit comparison `[CERT]`

`research-sdd/toolbelt/stage-retro-issues.sh:1-12,1000-1052` seeds one issue per open §18 delta. Dedup is an exact whole-line body signature `Source retro: <target>/retros/<file> · <row-id>`, searched across all states with the fuzzy search result re-filtered by exact line (`:722-728`, `:1030`), a legacy-signature fallback and a `--limit` truncation guard; labels `target:<name>` are probed and auto-created (`:824-870`); there is no scrub step. `reconcile-issues.sh:1-25` classifies tracked / untracked / orphaned / shipped. `grep 'gh issue comment'` in both scripts returns nothing: no occurrence comment, no fix-version check, no regression path; a recurrence of a delta stays under the same row. The kit is ahead of upstream on deterministic dedup (signature vs LLM judgment) and behind on scrub, occurrence evidence and fixed-in-release checks. Ranked adoption: [Block 33].

## 30.11 — Open questions

- `[GAP]` No code computes channel or published-fix; checking agent execution needs a bounded manual read of ~20 occurrence comments against release notes.
- `[GAP]` Whether the 204 figure double-counts non-defect issues (regex `occurrence` applied to comments on the 61 titled issues only; not every comment fetch succeeded).
- `[GAP]` Duplicate rate among the 36 open reports is eyeballed (a 4+ cluster), not measured; needs all bodies clustered by `reason_code`.
- `[GAP]` Who applied the 4 `gentle-report` labels (not in source, so maintainer-applied `[INFER]`).

## 30.12 — Connections

- **[Block 28]** — the handoff arrived with the ODD prompt rewrite (§28.2); the 13 not_planned closures are fallout of SDD removal.
- **[Block 29]** — human issue process and labels; this block's weaknesses 1 and 3 are the label/prefix gap noted at §29.6.
- **[Block 31]** — the two-token consent envelope the handoff wraps (§31.8), and the `operation_outcome_unknown` / `mutation_outcome` vocabulary that triggers the local report.
- **[Block 32]** — `issue-creation` is a bundled skill (§32.3).
- **[Block 33]** — adoption: scrub function, occurrence comments, fixed-in-release check, read-back after create.
