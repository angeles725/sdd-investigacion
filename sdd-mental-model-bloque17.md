# Block 17 — Delivery strategy, chain strategy, and chained PRs

> **WHAT IT DOCUMENTS**: This block documents how SDD decides the **delivery form** of an implementation: the `delivery_strategy` (ask-on-risk / auto-chain / single-pr / exception-ok), the `chain_strategy` (stacked-to-main / feature-branch-chain), the **Review Workload Guard** triggered between `sdd-tasks` and `sdd-apply`, the 400-changed-lines budget, and the `chained-pr` skill that is loaded mandatorily when there are chained PRs.
> **SCOPE**: The four delivery strategies, the two chain strategies, the Review Workload forecast, the guard's trigger conditions, and the resolution of the `chained-pr` skill by registry. It does NOT cover the task breakdown itself (see [Block 9]) nor the apply implementation (see [Block 10]).
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Delivery Strategy", §"Chain Strategy", §"Review Workload Guard (MANDATORY)", §"Agent Trigger Rules"
> - `/home/cristian/.config/opencode/commands/sdd-new.md`, `sdd-ff.md`, `sdd-continue.md` (Session Preflight: review budget, chained PR strategy)
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path §section`. `[CERT-a]` = asserted by a source, not re-verified. `[INFER]` = my own deduction.

---

## 17.1 — `delivery_strategy`: when and how to deliver `[CERT]`

On the first `/sdd-new`, `/sdd-ff`, or `/sdd-continue` of the session, the orchestrator asks ONCE and caches the `delivery_strategy` `[CERT]` (`CLAUDE.md` §"Delivery Strategy"). It is passed as `delivery_strategy` to the `sdd-tasks` and `sdd-apply` prompts.

The four strategies `[CERT]` (`CLAUDE.md` §"Delivery Strategy"):

| Strategy | Behavior `[CERT]` |
|-----------|--------------------------|
| **`ask-on-risk`** (default) | Asks the user only when the workload risk warrants it (see §17.4). |
| **`auto-chain`** | Does not ask about splitting; automatically chains PRs when needed. |
| **`single-pr`** | Forces a single PR; requires recording `size:exception` if it exceeds the budget. |
| **`exception-ok`** | Continues with `size:exception` accepted in advance. |

Explicit default `[CERT]`: `ask-on-risk` is the default. *"On the first `/sdd-new`, `/sdd-ff`, or `/sdd-continue` ... in a session, ask once for and cache delivery strategy: `ask-on-risk` (default), `auto-chain`, `single-pr`, or `exception-ok`."* `[CERT]` (`CLAUDE.md` §"Delivery Strategy").

**Mental model** `[INFER]`: the delivery strategy is a **pre-authorization policy** about what to do when a change turns out large. `ask-on-risk` leaves the decision to the human in the moment; `auto-chain` pre-authorizes it toward splitting; `single-pr` and `exception-ok` pre-authorize it toward a large PR with a recorded exception. It is the cache that avoids re-asking the same thing on every apply.

## 17.2 — `chain_strategy`: how PRs are chained `[CERT]`

When the `delivery_strategy` results in chained PRs (by user choice via `ask-on-risk` or automatically via `auto-chain`), the orchestrator asks which **chain strategy** to use `[CERT]` (`CLAUDE.md` §"Chain Strategy"):

| Chain strategy | Structure `[CERT]` (`CLAUDE.md` §"Chain Strategy") |
|----------------|-----------------------------------------------------|
| **`stacked-to-main`** | Each PR merges to main in order. Fast iteration, fix on the go. Best for speed-first teams and independent slices. |
| **`feature-branch-chain`** | The feature/tracker branch accumulates the final integration; PR #1 targets the tracker branch, later child PRs target the immediate previous PR branch to keep review diffs focused. Only the tracker merges to main. Best for rollback control and coordinated releases. |

The chain strategy is cached for the session and passed as `chain_strategy` to `sdd-tasks` and `sdd-apply` alongside `delivery_strategy` `[CERT]`. It is not asked again unless the user changes scope `[CERT]` (`CLAUDE.md` §"Chain Strategy").

**The underlying difference** `[INFER]`: `stacked-to-main` optimizes SPEED — each slice reaches main as soon as it is ready, assuming independent slices. `feature-branch-chain` optimizes CONTROL — nothing touches main until the tracker integrates everything, allowing rollback of the whole feature as a unit. It is the classic tradeoff between aggressive continuous integration and a coordinated release. The PR target structure (each child targets the previous one) is what keeps review diffs small in feature-branch-chain.

## 17.3 — The Review Workload Forecast `[CERT]`

After completing `sdd-tasks` and BEFORE launching `sdd-apply`, the orchestrator inspects the **Review Workload Forecast** `[CERT]` (`CLAUDE.md` §"Review Workload Guard"). This forecast is produced by the `sdd-tasks` phase and contains signals that predict how much review the implementation will demand.

The signals that trigger the guard `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

- `Chained PRs recommended: Yes`
- `400-line budget risk: High`
- estimated changed lines exceed 400
- `Decision needed before apply: Yes`

If ANY of these signals is present, the cached `delivery_strategy` is applied (see §17.4).

**Why between tasks and apply** `[INFER]`: it is the last point where the delivery form can be decided BEFORE writing code. `sdd-tasks` has already broken down the work and can estimate size; `sdd-apply` has not started yet. Deciding the splitting here avoids the worst scenario: implementing everything in a giant PR and discovering only at review that it was unreviewable. The forecast is an early prediction of the review cost.

## 17.4 — The Review Workload Guard: resolution by delivery_strategy `[CERT]`

When the forecast triggers, the guard resolves according to the cached `delivery_strategy` `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

| delivery_strategy | Guard action `[CERT]` |
|-------------------|----------------------------|
| **`ask-on-risk`** | STOP and ask whether to split into chained/stacked PRs or proceed with `size:exception`. If chained PRs is chosen and `chain_strategy` is not cached, also ask which chain strategy. |
| **`auto-chain`** | Do not ask about splitting. If `chain_strategy` is not cached, ask which to use. Then pass to `sdd-apply`: implement only the next autonomous slice with work-unit commits, with clear start/finish/verification/rollback boundary. |
| **`single-pr`** | STOP and require/record `size:exception` before apply. |
| **`exception-ok`** | Continue, but tell `sdd-apply` that this run uses `size:exception`. |

Hard rules of the guard `[CERT]` (`CLAUDE.md` §"Review Workload Guard"):

- *"Automatic mode does not override this guard."* — auto mode does NOT skip this guard. The resolved delivery strategy is always passed to `sdd-apply`.
- When launching `sdd-apply`, ALWAYS include the resolved `delivery_strategy`, the `chain_strategy`, and any chosen PR boundary/exception.

**Mental model of the guard** `[INFER]`: it is a mandatory **size checkpoint** between planning and execution. The auto-mode Gatekeeper validates the QUALITY of each phase; the Review Workload Guard validates the delivery SIZE. They are orthogonal: the Gatekeeper can pass (the tasks is well made) but the guard can trigger (the tasks describe 600 lines of change). And auto mode, which silences the Gatekeeper on the happy path, does NOT silence this guard — because the splitting decision may require human input that no autonomous validation replaces (except in `auto-chain`, which pre-authorized it).

## 17.5 — The 400-line budget `[CERT]`

The number **400 changed lines** is the central threshold of the review system `[CERT]`. It appears in two places:

1. **Review Workload Guard** `[CERT]` (`CLAUDE.md` §"Review Workload Guard"): the forecast marks `400-line budget risk: High` or `estimated changed lines exceed 400` as a trigger.
2. **Agent Trigger Rules** `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"): at pre-pr, when the diff touches sensitive paths (`**/auth/**`, `**/update/**`, `**/security/**`, `**/payments/**`) OR when the diff **exceeds 400 changed lines**, it is STRONGLY recommended to run the full 4R fan-out (`review-risk`, `review-resilience`, `review-readability`, `review-reliability`) in parallel.

The logic of the 4R trigger `[CERT]` (`CLAUDE.md` §"Agent Trigger Rules"): *"full 4R fan-out (~4x) only on hot paths (auth/update/security/payments) or diffs exceeding 400 changed lines"*. For everyday events (pre-commit, pre-push) only ONE cheap lens is considered (`review-readability`, ~1x); the full 4R fan-out is reserved for pre-pr on hot paths or large diffs.

**Why 400** `[INFER]`: 400 lines is a widely-used human-reviewability threshold in the industry — above it, review quality drops because the reviewer cannot hold the whole change in their head. SDD uses it as a dual frontier: below, a simple PR with light review; above, you either split (Review Workload Guard) or pay the full 4R adversarial review (Agent Trigger Rules). The number connects the **delivery size** domain with the **review intensity** domain.

## 17.6 — The `chained-pr` skill `[CERT]`

When delivery planning results in chained PRs, SDD treats `chained-pr` (registry skill `gentle-ai-chained-pr`) as a **required skill match** `[CERT]` (`CLAUDE.md` §"Chain Strategy"):

- It is resolved by registry name through the template's existing skill-resolution mechanism (the same one already used to pass skills to the phases).
- It is ensured that the `sdd-tasks` and `sdd-apply` phases LOAD and FOLLOW that skill BEFORE planning or creating any PR.
- *"Do not hardcode the skill path; defer resolution to that mechanism."* `[CERT]` (`CLAUDE.md` §"Chain Strategy").

The description of the `chained-pr` skill (from the available skills registry) `[CERT-a]`: *"Trigger: PRs over 400 lines, stacked PRs, review slices. Split oversized changes into chained PRs that protect review focus."*

**Mental model** `[INFER]`: `chained-pr` is the "procedure manual" for executing the splitting that the Review Workload Guard decided. The guard DECIDES that chaining is needed; the `chained-pr` skill teaches HOW to do it well (how to build the slices, how to target the PRs, how to protect review focus). That it is resolved by registry (and not by a hardcoded path) is consistent with the Skill Resolver Protocol (see [Block 18], [Block 22]): the orchestrator resolves the path once and injects it into the sub-agent's prompt.

## 17.7 — How it fits into the Session Preflight `[CERT]`

Two of the four elements of the Session Preflight HARD GATE (see [Block 14]) correspond to this block `[CERT]` (`sdd-new.md:9`, `sdd-ff.md:9`, `sdd-continue.md:9`):

- **chained PR strategy** → the `chain_strategy` of §17.2.
- **review budget** → the `delivery_strategy` and the line budget of §17.1 and §17.5.

This means the delivery form is NOT improvised at apply: it is resolved at the start of the session (in the preflight) and cached. The Review Workload Guard (§17.4) then CONSUMES that cache when the forecast triggers, instead of asking from scratch.

**Complete temporal sequence** `[INFER]`:

1. **Session Preflight** (first meta-command): `delivery_strategy` + `chain_strategy` are asked and cached.
2. **`sdd-tasks`**: produces the Review Workload Forecast with the size signals.
3. **Review Workload Guard** (between tasks and apply): inspects the forecast; if it triggers, applies the cached `delivery_strategy`.
4. **`sdd-apply`**: receives `delivery_strategy` + `chain_strategy` + boundary/exception; if there is chaining, loads the `chained-pr` skill and executes the slices with work-unit commits.

## 17.8 — Connections

- **[Block 9] — sdd-tasks**: it is the phase that PRODUCES the Review Workload Forecast (§17.3) the guard inspects. The size signals (`400-line budget risk`, `estimated changed lines`, `Chained PRs recommended`) are output of [Block 9].
- **[Block 10] — sdd-apply**: it is the phase that CONSUMES `delivery_strategy` and `chain_strategy`, loads the `chained-pr` skill, and executes the slices with work-unit commits. The PR boundary (start/finish/verification/rollback) materializes there.
- **[Block 14] — meta-commands**: the Session Preflight of the three meta-commands includes chained PR strategy and review budget (§17.7) — exactly the `chain_strategy` and `delivery_strategy` of this block.
- **[Block 16] — modes + Gatekeeper**: the Review Workload Guard runs IN ADDITION to the Gatekeeper and auto mode does NOT override it (§17.4). They are orthogonal guards: quality vs. size.
- **[Block 18] — delegation + skill resolution**: the `chained-pr` skill is resolved via the Skill Resolver Protocol that [Block 18] formalizes; the phases receive the injected path, they do not hardcode it.
- **[Block 22] — skill-resolver**: the "defer resolution to that mechanism" for `chained-pr` is the Skill Resolver Protocol of the `_shared/` contracts.
