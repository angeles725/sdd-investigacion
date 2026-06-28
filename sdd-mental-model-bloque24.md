# Block 24 — judgment-day and adversarial verification

> **WHAT IT DOCUMENTS**: This block establishes the mental model of **Judgment Day**: the blind dual-judge adversarial verification protocol (Judge A / Judge B in parallel), the synthesis of verdicts into buckets (confirmed / suspect / contradiction / INFO), the surgical fix-agent, the iterative re-judgment, when it triggers (post design/apply), its cost, and the models assigned to each judging agent.
> **SCOPE**: The `judgment-day` skill and its three agents (jd-judge-a, jd-judge-b, jd-fix-agent), its activation contract, decision gates, prompt/verdict formats, the post-sdd-phase trigger, and the Model Assignments row. It does NOT cover the formal `sdd-verify` phase (see [Block 11]) — judgment-day is a complementary adversarial review protocol, not a DAG phase.
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/skills/judgment-day/SKILL.md` (activation contract, hard rules, decision gates, execution steps, output contract)
> - `/home/cristian/.claude/skills/judgment-day/references/prompts-and-formats.md` (judge prompt, fix prompt, verdict table, delegation patterns, language snippets)
> - `/home/cristian/.claude/agents/jd-judge-a.md`, `/home/cristian/.claude/agents/jd-judge-b.md`, `/home/cristian/.claude/agents/jd-fix-agent.md` (sub-agent definitions)
> - `/home/cristian/.claude/CLAUDE.md` §"Model Assignments" (jd-* rows), §"Agent Trigger Rules" (post-sdd-phase)
> **METHOD**: Each claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path:line` or `path §section`. `[CERT-a]` = asserted by a source but not re-verified in its primary origin. `[INFER]` = my own deduction, not literal in the source.

---

## 24.1 — What Judgment Day is and when it loads `[CERT]`

Judgment Day is an **adversarial dual-review** protocol: *"Run blind dual review, fix confirmed issues, then re-judge."* `[CERT]` (`SKILL.md:3`, description). It loads ONLY when the user asks for it explicitly — Judgment Day, dual/adversarial review, or the Spanish trigger (`juzgar`, `que lo juzguen`) — on a specific target: files, feature, PR, or architecture slice `[CERT]` (`SKILL.md:10-12`, Activation Contract).

The guiding principle is **independence of judgment**: the orchestrator NEVER reviews the code itself. *"Launch two blind judges in parallel with identical target and criteria; never review the code yourself."* `[CERT]` (`SKILL.md:18`).

**Mental model** `[INFER]`: it is the materialization of the value "fresh reviewers = independent judgment, NOT token saving" (see [Block 1] §1.5). Two blind judges on the same target reduce the false negative of a single reviewer: one opinion can miss a bug; the agreement of two independent opinions confirms it, and disagreement marks it as suspect rather than fact.

## 24.2 — The three judging agents `[CERT]`

| Agent | Role | Tools `[CERT]` | Model `[CERT]` |
|--------|-----|-------|--------|
| `jd-judge-a` | Blind adversarial reviewer A | Read, Glob, Grep, Bash, mem_search, mem_get_observation (read-only) | sonnet |
| `jd-judge-b` | Blind adversarial reviewer B | identical to A | sonnet |
| `jd-fix-agent` | Surgical fix of confirmed issues | Read, Edit, Write, Glob, Grep, Bash, mem_search, mem_get_observation, mem_save, mem_update | sonnet |

Rules common to the judges `[CERT]` (`jd-judge-a.md:14-19`, identical in `jd-judge-b.md`):
- Do NOT use Task/Agent — do NOT delegate further (the judges are leaves of the tree). `[CERT]`
- Do NOT modify code — *"your job is ONLY to find problems"*. `[CERT]`
- Be **adversarial**: *"Assume the code has bugs until proven otherwise."* `[CERT]`
- End with `Skill Resolution: {injected|fallback-registry|fallback-path|none}`. `[CERT]`

Rules of the fix-agent `[CERT]` (`jd-fix-agent.md:14-21`):
- Fix ONLY the confirmed issues from the prompt; do NOT refactor beyond what is strictly necessary; do NOT touch unmarked code. `[CERT]`
- **Scope rule**: *"If you fix a pattern in one file, search for the SAME pattern in ALL other files and fix them ALL."* `[CERT]` (`jd-fix-agent.md:19`).
- Return `## Fixes Applied - [file:line] — {what was fixed}`. `[CERT]`

**Tool distinction** `[INFER]`: the judges are read-only by design (they cannot touch code), the fix-agent is the only one with Edit/Write/mem_save. This makes it structurally impossible for a judge to "fix something along the way", preserving its role as a pure detector.

## 24.3 — The flow: dual judge in parallel, synthesis, fix, re-judgment `[CERT]`

The execution steps `[CERT]` (`SKILL.md:38-44`, Execution Steps):

1. Confirm the target and optional custom criteria.
2. Resolve exact skill paths from the registry, or warn if missing.
3. Launch Judge A and Judge B **concurrently** via delegation.
4. Synthesize findings into buckets: **confirmed, suspect, contradiction, INFO**.
5. **Ask before Round 1 fixes**; delegate a separate fix-agent only for approved confirmed fixes.
6. Re-judge in parallel after the fixes; repeat until approved, escalated, or the user asks to stop.
7. Before any terminal action, verify that every active Judgment Day has a terminal state.

Hard sequencing rules `[CERT]` (`SKILL.md:20-24`):
- Wait for BOTH judges before synthesizing; never accept a partial verdict. `[CERT]`
- After running any fix-agent, re-launch BOTH judges in parallel before commit/push/done/session summary. `[CERT]`
- Terminal states are ONLY `JUDGMENT: APPROVED` or `JUDGMENT: ESCALATED`. `[CERT]`
- After **2 fix iterations** with remaining issues, ask the user whether to continue. `[CERT]` (`SKILL.md:23`).

**Mental model of the loop** `[INFER]`: judge → synthesis → (ask) → fix → re-judge is a closed cycle that does not end by exhaustion but by explicit verdict. The mandatory re-judgment after each fix avoids the "I fixed it and I assume it's fine": every fix-agent change must survive a new dual judgment.

## 24.4 — The verdict synthesis: buckets and warning rubric `[CERT]`

Classification is decided by cross-checking the findings of both judges `[CERT]` (`SKILL.md:26-34`, Decision Gates):

| Condition | Action / bucket `[CERT]` |
|-----------|-----------------|
| Unclear target | Ask for scope; do NOT launch judges |
| No skill registry | Warn, proceed with generic criteria, record `Skill Resolution: none` |
| Both judges find the SAME CRITICAL / real WARNING | **Confirmed** → ask/fix per round rules |
| Only one judge finds the issue | **Suspect** → report and triage, do NOT auto-fix |
| The judges contradict each other | **Escalate** → manual decision |
| Round 2+ has only theoretical warnings / suggestions | Report as INFO; do NOT re-judge |

The **warning rubric** is central `[CERT]` (`SKILL.md:19`, `prompts-and-formats.md:32`): a warning is `WARNING (real)` only if normal, intended use can trigger it; if the path is contrived/malicious/impossible, it is downgraded to INFO as `WARNING (theoretical)`. Each judge finding is classified by severity: `CRITICAL | WARNING (real) | WARNING (theoretical) | SUGGESTION` `[CERT]` (`prompts-and-formats.md:27`).

The **verdict table** consolidates both opinions `[CERT]` (`prompts-and-formats.md:62-68`):

```
| Finding                          | Judge A | Judge B | Severity              | Status    |
|----------------------------------|---------|---------|-----------------------|-----------|
| Missing null check in auth.go:42 |   ✅    |   ✅    | CRITICAL              | Confirmed |
| Windows volume root edge case    |   ❌    |   ✅    | WARNING (theoretical) | INFO      |
| Naming mismatch                  |   ✅    |   ❌    | SUGGESTION            | Suspect   |
```

**Approval criterion** after Round 1 `[CERT]` (`prompts-and-formats.md:70`): zero confirmed CRITICALs and zero confirmed real WARNINGs. Theoretical warnings and suggestions can remain.

## 24.5 — The surgical fix-agent and the judges' prompt `[CERT]`

The **judge prompt** (`prompts-and-formats.md:5-37`) instructs: *"Your ONLY job is to find problems"*, gives the review criteria (Correctness, Edge cases, Error handling, Performance, Security, Naming/conventions), injects the skill paths as `Skills to load before work`, requires "Findings only. No praise.", and if clean returns `VERDICT: CLEAN — No issues found.` `[CERT]`.

The **fix prompt** (`prompts-and-formats.md:41-58`) receives the table of confirmed issues and orders: fix only confirmed ones, do not refactor beyond the necessary fix, do not touch unmarked code, and fix ALL occurrences of the same pattern in touched files `[CERT]`.

Before Round 1 fixes the orchestrator **MUST ask** (`SKILL.md:21`, "Ask before fixing Round 1 confirmed issues") `[CERT]`. The fix-agent is delegated separately and only for "confirmed approved fixes only" `[CERT]` (`SKILL.md:42`).

**Delegation patterns** `[CERT]` (`prompts-and-formats.md:72-93`): when the JD agents are configured as named sub-agents (OpenCode multi-mode overlay) `delegate(agent="jd-judge-a", ...)` is used and each agent uses its model configured in Model Assignments. When they are NOT available as named ones (Claude Code, Cursor, Windsurf, Gemini, Codex) the generic `delegate` is used without the `agent` parameter and the model is controlled by the adapter's native mechanism (model sentinels in the `.md` files). `[CERT]`

## 24.6 — When it triggers: the post-sdd-phase trigger and the cost `[CERT]`

Judgment Day is organically recommended after high-stakes SDD phases `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"):

> *"At post-sdd-phase, after the design or apply phase completes, strongly recommend running judgment-day. (adversarial verification (~4 + 3*findings cost) only at high-stakes SDD phases (design and apply))"* `[CERT]`

Two key readings `[CERT]`:
- **When**: after `design` or after `apply` — the two phases where *"errors in these phases compound downstream"* (this matches the Automatic mode Gatekeeper, which already uses fresh-context reviewers for design and apply, see [Block 16]). `[CERT-a]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").
- **Cost**: **~4 + 3×findings**. `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules").

**Cost breakdown** `[INFER]`: the base `4` corresponds roughly to the two initial judges plus the cycle (re-judgment of two judges after a fix); the `3×findings` models the incremental work per confirmed finding (fix + re-verification). That is why the protocol is reserved for high-stakes phases: it is not free, and its value (independent dual judgment) only justifies the cost when an error propagates downstream.

The trigger rules are *"organic recommendations, not enforced checkpoints"* `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules": gentle-ai only renders the text; the orchestrator decides when to act).

## 24.7 — The models assigned to the judging agents `[CERT]`

From the Model Assignments table `[CERT]` (`CLAUDE.md` §"Model Assignments"):

| Phase | Default model | Effort | Reason `[CERT]` |
|------|---------------|--------|------|
| `jd-judge-a` | sonnet | default | Adversarial review — blind judge A |
| `jd-judge-b` | sonnet | default | Adversarial review — blind judge B |
| `jd-fix-agent` | sonnet | default | Surgical fixes from confirmed issues |

This matches the `model: sonnet` declared in each agent's frontmatter (`jd-judge-a.md:7`, `jd-judge-b.md:7`, `jd-fix-agent.md:6`) `[CERT]`. The **mandatory model gate** applies: SDD/Judgment-Day phase Agent calls MUST include `model`, resolving the alias from this table `[CERT]` (`CLAUDE.md` §"Model Assignments": "Mandatory phase model gate"). If there is no Opus access, it is substituted with `sonnet` — but here all three are already sonnet `[CERT]`.

**Observation** `[INFER]`: all three agents use the same model (sonnet). Independence of judgment does NOT come from different models but from **parallel fresh contexts with the same target and criteria** — two blind instances of the same model, neither seeing the other's output. Agreement between the two is a signal precisely because neither influenced the other.

## 24.8 — Output Contract and terminal states `[CERT]`

The return is `## Judgment Day — {target}` with: round number, verdict table, confirmed/suspect/contradiction counts, fixes applied, re-judgment result, `Skill Resolution`, and the final verdict `JUDGMENT: APPROVED ✅` or `JUDGMENT: ESCALATED ⚠️` `[CERT]` (`SKILL.md:46-48`, Output Contract).

The language snippets confirm the protocol's bilingual tone `[CERT]` (`prompts-and-formats.md:95-98`): Spanish ("Juicio iniciado", "Los jueces trabajan en paralelo", "Los jueces coinciden", "Escalado — necesita revisión humana") and equivalent English.

**Terminal mental model** `[INFER]`: Judgment Day does not admit an ambiguous ending. It either converges to APPROVED (zero confirmed CRITICAL/real WARNING) or ESCALATED (contradiction between judges, or issues that persist after iterations). This forces an explicit decision instead of a "seems fine", which is the pathology the adversarial protocol exists to avoid.

## 24.9 — Connections

- **[Block 8] — sdd-design** and **[Block 10] — sdd-apply**: these are the two trigger points of Judgment Day (post-sdd-phase). The protocol adds a layer of adversarial verification over the output of these high-stakes phases, where errors propagate downstream.
- **[Block 16] — modes and Gatekeeper**: the Automatic mode Gatekeeper already delegates fresh-context reviewers for design and apply; Judgment Day is the explicit and dual version of that same principle (independent judgment over phases that compound). Both share the "fresh-context reviewer" as a mechanism.
- **[Block 18] — delegation and model assignments**: the jd-judge-a / jd-judge-b / jd-fix-agent rows (all sonnet) live in the same Model Assignments table as the SDD phases, and the mandatory model gate (include `model` in the Agent call) applies to the judging agents just as to the phases.
- **[Block 11] — sdd-verify**: judgment-day is complementary, NOT a substitute. `sdd-verify` validates against the spec/design/tasks (the DAG's formal contract); judgment-day does free adversarial review with Correctness/Security/Performance criteria. One verifies conformance; the other hunts bugs.
- **[Block 22] — skill-resolver**: both the judges and the fix-agent receive injected skill paths (`Skills to load before work`) through the same registry resolution mechanism, and report `Skill Resolution` in their output.
- **[Block 1] — philosophy**: Judgment Day embodies the §1.5 separation between delegation-by-compression and delegation-by-independence-of-judgment: here the value is exclusively independent judgment, never token saving (in fact it costs ~4 + 3×findings).
