# Block 16 — Execution modes (auto/interactive) and the Gatekeeper

> **WHAT IT DOCUMENTS**: This block documents the two execution modes of the SDD pipeline — `auto` and `interactive` — and the **Gatekeeper** of automatic mode: the autonomous validator the orchestrator runs between phases to ensure each phase reached its objective before launching the next.
> **SCOPE**: The auto vs. interactive difference, when the mode is asked, the proposal question round in interactive mode, the Gatekeeper's five checks (contract conformance, artifact existence, no hallucination, no drift, routing coherence), the hybrid inline vs. fresh-reviewer mechanism, and the PASS/FAIL flow with a single re-run. It does NOT cover the Review Workload Guard (see [Block 17]) nor the detail of the Result Contract (see [Block 2]).
> **SOURCES** (read and verified):
> - `/home/cristian/.claude/CLAUDE.md` §"Execution Mode", §"Automatic Mode Gatekeeper (MANDATORY)", §"Artifact Store Mode", §"Result Contract"
> - `/home/cristian/.config/opencode/commands/sdd-ff.md` (lines 21-22) — auto/interactive behavior
> **METHOD**: Every claim carries a certainty marker. `[CERT]` = verified by reading the source, with `path §section`. `[CERT-a]` = asserted by a source, not re-verified. `[INFER]` = my own deduction.

---

## 16.1 — The two execution modes `[CERT]`

When the user invokes `/sdd-new`, `/sdd-ff`, or `/sdd-continue` (or an equivalent natural-language request, e.g. "haceme un SDD para X") for the first time in the session, the orchestrator ASKS which execution mode they prefer `[CERT]` (`CLAUDE.md` §"Execution Mode"):

| Mode | Behavior `[CERT]` (`CLAUDE.md` §"Execution Mode") |
|------|--------------------------------------------------------|
| **Automatic** (`auto`) | Runs all phases back-to-back WITHOUT pausing. But the orchestrator runs a **Gatekeeper validation after every phase** before launching the next. The user only sees an interruption when the Gatekeeper detects a real problem. For speed when the process is trusted. |
| **Interactive** (`interactive`) | After each phase, it shows the summary and ASKS: "Want to adjust anything or continue?" before proceeding. For when you want to review and steer each step. |

Default `[CERT]` (`CLAUDE.md` §"Execution Mode"): *"If the user doesn't specify, default to **Interactive** (safer, gives the user control)."* The mode is cached for the session; it is not asked again unless the user explicitly requests a change.

Key clarification `[CERT]`: **auto does NOT mean "no validation"**. It means "no interruption to the user on the happy path". The Gatekeeper ALWAYS runs in auto; what changes is that its results only reach the user when there is a problem. The source says so: *"Phases still run back-to-back WITHOUT interrupting the user, BUT the orchestrator runs a gatekeeper validation after every phase before launching the next sub-agent — the user only sees an interruption when the gatekeeper catches a real problem."* `[CERT]` (`CLAUDE.md` §"Execution Mode").

## 16.2 — Interactive mode: pauses between phases `[CERT]`

In interactive mode, between phases the orchestrator `[CERT]` (`CLAUDE.md` §"Execution Mode"):

1. Shows a concise summary of what the phase produced.
2. Lists what the next phase will do.
3. Asks: "¿Continuamos? / Continue?" — accepts YES/continue, NO/stop, or specific feedback to adjust.
4. If the user gives feedback, it incorporates it BEFORE running the next phase.

This matches exactly the behavior of `/sdd-ff` in interactive `[CERT]` (`sdd-ff.md:21`): *"run only the next planning phase, present its summary and artifact path(s), ask whether to adjust or continue, then STOP. Do not launch the following phase until the user confirms."*

Approval scope rule `[CERT]` (`CLAUDE.md` §"Execution Mode"): interactive approval is **phase-scoped**. Words like "continue", "dale", or "go on" approve ONLY the immediate next phase, not the rest of the SDD pipeline. A generated artifact is NOT considered approved until the user has had a chance to review it or explicitly delegated that review.

**Mental model** `[INFER]`: interactive approval is not transitive. Approving phase N does not authorize N+1, N+2... This prevents a casual "yes" at the start from being interpreted as a mandate to run the whole pipeline unsupervised. Each phase is a fresh consent.

## 16.3 — Proposal question round (interactive) `[CERT]`

Before the `sdd-propose` phase in interactive mode, the orchestrator offers a **proposal question round** instead of silently deciding whether the proposal is clear `[CERT]` (`CLAUDE.md` §"Execution Mode"):

- The questions aim to improve the PRD/proposal by uncovering: business understanding, business rules, implications, impact, edge cases, and product tradeoffs.
- Prefer **3-5 concrete product questions per round**, then summarize the resulting assumptions and ask whether the user wants to correct anything or run a second round.
- Cover business/product/PRD decisions: business problem, target users and situations, business rules, product outcome, current-state gap, implications and impact, edge cases, decision gaps, first-slice scope boundaries, non-goals, product constraints, and business tradeoffs.

What is NOT asked at proposal time `[CERT]`: *"Do not ask about test commands, PR shape, changed-line budget, or other harness mechanics at proposal time unless the user explicitly asks to discuss delivery."* `[CERT]` (`CLAUDE.md` §"Execution Mode").

**Why** `[INFER]`: the question round separates the **product/business** domain (what is being built and why) from the **delivery/harness** domain (how it is delivered: PRs, line budget, test commands). At proposal time only the former is discussed. Delivery mechanics are resolved later, in the Review Workload Guard (see [Block 17]).

## 16.4 — The Gatekeeper: autonomous validator between phases `[CERT]`

In automatic mode the orchestrator IS the gatekeeper between phases `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"). It runs **after every phase**: when a delegated phase returns and BEFORE launching the next sub-agent, the orchestrator MUST validate that the phase reached its objective with everything in order.

Critical distinction `[CERT]`: the Gatekeeper is **autonomous validation — it does NOT ask the user** (that is interactive mode). It only surfaces to the user when it detects a problem. *"This is autonomous validation — it does NOT ask the user (that is Interactive mode); it only surfaces to the user when it catches a problem."* `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

**Mental model** `[INFER]`: the Gatekeeper is the automatic equivalent of the human checkpoint in interactive mode. In interactive, the HUMAN validates each phase. In auto, the ORCHESTRATOR validates each phase with objective criteria. That is why auto is not "blind mode": it is "mode with an autonomous reviewer instead of the human".

## 16.5 — The Gatekeeper's five checks `[CERT]`

The Gatekeeper checks each phase against the Result Contract `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"). The five checks:

| # | Check | What it verifies `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper") |
|---|---------|------------------------------------------------------------------|
| 1 | **Contract conformance** | The phase returned `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, and `skill_resolution`, and `status` indicates success (not partial, failed, or blocked). |
| 2 | **Artifact existence** | The declared artifact exists and is readable in the active backend — it is READ back (engram: `mem_search` + `mem_get_observation` over the topic key; openspec: read the file path). A phase that reports success but produced no retrievable artifact FAILS. |
| 3 | **No hallucination** | Every file path, symbol, command, or artifact the phase claims to have created or referenced MUST actually exist; the concrete claims are spot-checked. A referenced path that does not resolve FAILS. |
| 4 | **No drift from inputs** | The output is consistent with the phase's required inputs per the Dependency Graph — spec within the proposal's scope, design answers the proposal, tasks cover spec and design, apply implements the tasks. Invented requirements, scope creep, or dropped requirements FAIL. |
| 5 | **Routing coherence** | `next_recommended` follows the Dependency Graph and `risks` are within tolerance (no unaddressed CRITICAL). |

**Reading the set as a whole** `[INFER]`: the five checks form a hierarchy of increasing trust. (1) did the phase respond in the expected format? (2) does the artifact it claims to have made really exist? (3) does what it cites within the artifact exist? (4) is it coherent with what it received? (5) is where it points correct? It is a funnel: first the form, then the substance, then the coherence, then the routing. The most subtle is #4 (drift): it captures the most dangerous failure of LLMs, silently inventing or losing requirements.

## 16.6 — Hybrid mechanism: inline vs. fresh reviewer `[CERT]`

The Gatekeeper uses a **cost-aware** validation mechanism `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"):

| Phase type | Validation mechanism `[CERT]` |
|--------------|----------------------------------|
| **Low risk** (`sdd-explore`, `sdd-spec`, `sdd-tasks`, `sdd-archive`) | **Inline**: the orchestrator runs the checks itself by reading the artifact back. No extra sub-agent. |
| **High risk** (`sdd-design`, `sdd-apply`) | **Fresh-context reviewer**: delegate a fresh reviewer sub-agent for independent judgment, because errors in these phases compound downstream. Use the `sdd-verify` model alias for the gate review, with `model` per the mandatory model gate. |

Escalation on "smell" `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"): if an inline check on a low-risk phase finds any smell (status mismatch, unresolved path, suspected drift, missing artifact), that phase is ESCALATED to a fresh-context delegated review before deciding.

**Why design and apply are high risk** `[INFER]`: they are the two phases where a wrong decision **propagates**. A wrong design contaminates all the tasks and the implementation. A wrong apply injects bugs into the code. The low-risk phases (explore, spec, tasks, archive) produce more mechanical or reversible artifacts, where an error is more local and cheap to detect inline. The cost asymmetry justifies spending a fresh sub-agent only on design/apply. This links to the agent trigger rule: `judgment-day` is strongly recommended after design or apply (see [Block 24]).

## 16.7 — PASS/FAIL flow and the single re-run `[CERT]`

The Gatekeeper's result triggers two paths `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper"):

**On gate PASS**: continue automatically to the next phase. *"Auto stays auto on the happy path."* `[CERT]`

**On gate FAIL** `[CERT]`:

1. **Re-run the same phase EXACTLY once** with corrective feedback that names the specific failures the gatekeeper found (not a blanket-retry).
2. Re-run the gate on the new result.
3. If it passes → continue the chain.
4. If it fails again → **STOP the automatic chain** and surface a report to the user naming the phase, what the gatekeeper caught, both attempts, and the recommended fix.

No-advance rule `[CERT]`: *"Do not advance to dependent phases on a failed gate — a bad artifact compounds downstream."* `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

**Mental model of the single re-run** `[INFER]`: the system gives exactly ONE second chance with targeted feedback, not infinite retries. The logic is: if a phase fails and a re-run with specific feedback does not fix it either, the problem probably exceeds what the automatic retry can resolve — it needs a human. The "exactly once" avoids token-burning loops and forces early escalation to the user.

Coexistence with other guards `[CERT]`: the Gatekeeper runs IN ADDITION to the Review Workload Guard and the Mandatory Delegation Triggers; it never relaxes them and never auto-marks anything as reviewed in engram `[CERT]` (`CLAUDE.md` §"Automatic Mode Gatekeeper").

## 16.8 — Artifact Store Mode: the other first-turn question `[CERT]`

Along with the execution mode, on the first `/sdd-new`/`/sdd-ff`/`/sdd-continue` of the session the orchestrator ALSO asks which artifact store to use `[CERT]` (`CLAUDE.md` §"Artifact Store Mode"):

| Store | Characteristic `[CERT]` (`CLAUDE.md` §"Artifact Store Mode") |
|-------|------------------------------------------------------------|
| `engram` | Fast, no files. Artifacts only in engram. Best for solo work and quick iteration. Re-running a phase overwrites the previous version (no history). |
| `openspec` | File-based. Creates `openspec/` with a full trail. Committable, shareable, with git history. |
| `hybrid` | Both — files for the team + engram for cross-session recovery. Higher token cost. |

Default `[CERT]`: if the user does not specify, detect — if engram is available → `engram`; otherwise → `none`. The store is cached and passed as `artifact_store.mode` to each sub-agent launch `[CERT]`.

**Connection with the Gatekeeper** `[INFER]`: the Gatekeeper's check #2 (artifact existence) depends on this mode — it reads back via `mem_get_observation` if it is engram, or reads the file if it is openspec. The store chosen here determines HOW the Gatekeeper verifies that the artifact exists.

## 16.9 — Connections

- **[Block 2] — DAG + Result Contract**: the five fields the Gatekeeper requires (check #1) are exactly the Result Contract (`status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) that [Block 2] defines. Check #4 (no drift) is validated against the Dependency Graph of [Block 2].
- **[Block 8] — sdd-design** and **[Block 10] — sdd-apply**: they are the two HIGH-RISK phases the Gatekeeper validates with a fresh reviewer (§16.6), because their errors compound downstream.
- **[Block 24] — judgment-day**: the trigger rule strongly recommends running `judgment-day` after the design or apply phases — the same high-risk threshold the Gatekeeper uses. Both mechanisms reinforce the same point of the pipeline.
- **[Block 17] — delivery/chain strategy**: the Gatekeeper runs IN ADDITION to the Review Workload Guard (§16.7), which [Block 17] documents. The Artifact Store Mode (§16.8) and the execution mode are two of the four elements of the Session Preflight; the other two (chain strategy, review budget) are in [Block 17].
- **[Block 18] — delegation + models**: the Gatekeeper's fresh reviewer uses the `sdd-verify` model alias with the mandatory model gate (§16.6), which [Block 18] formalizes in the Model Assignments table.
- **[Block 14] — meta-commands**: the execution mode and artifact store asked here are two of the four elements of the Session Preflight HARD GATE that [Block 14] describes for the three meta-commands.
