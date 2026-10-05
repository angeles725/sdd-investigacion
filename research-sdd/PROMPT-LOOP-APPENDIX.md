# PROMPT-LOOP-APPENDIX — Research-SDD (situational)

Companion to [`PROMPT-LOOP.md`](PROMPT-LOOP.md). This file holds SITUATIONAL prose that used to
live inline in the OPERATIONAL PROMPT's step 3 — narrow special-case rules a driver only needs
when a specific trigger fires, not on every iteration (mirroring how METHODOLOGY.md separates its
own HOT-CORE from SITUATIONAL sections). A rule lives here only if its trigger is narrower than
"most iterations" AND it never applies to inline (non-delegated) work; everything else — including
every always-hit delegation rule — stays in PROMPT-LOOP.md core. Lazy-load != skip: every rule here
still applies in full once its trigger fires; PROMPT-LOOP.md's core leaves a pointer naming the
exact trigger and this file's section, so a driver reads a section here only when that trigger is
live, and reads it IN FULL when it does.

No content below is reworded from its original PROMPT-LOOP.md location — this is a straight move.
Where a rule that used to sit between two moved rules stays in core, the moved rules keep their
original relative order and the note in their section says which rule stayed behind.

(WEB-RESEARCH DISCOVERY-ONLY and the two FALSIFY BEFORE REPORTING
delegated-sweep subcases — DELEGATED SWEEP OPERATIONAL CLAIMS and the DECOMMISSIONED/BROKEN
ENDPOINT SUBCASE — moved back to PROMPT-LOOP.md core: each fires on inline work too, so neither
satisfied this file's own admission rule above. See `verify-edge-cases` below for the same
treatment of PHYSICAL-ACTION FACTS and HIDDEN-FLAG CROSS-CHECK.)

---

## delegation-variants

Trigger: read this section in full when the gap is a single large config artifact, a quick-mode
operator question, ≥2 independent small gaps on different subsystems, a sibling gap while a sweep
is already in flight, a recursive multi-level fan-out, or you are advancing other work while a
delegated sweep executes. None of these apply to a plain inline gap.

Note: the QUICK-MODE DELEGATION rule below is not reachable from PROMPT-LOOP.md today. Quick mode
never enters the loop; it short-circuits in `skills/research-sdd/SKILL.md` ("quick and light modes
short-circuit: answer directly (quick)... do not bootstrap or loop") before BOOTSTRAP / NORMAL CYCLE
start. The rule stays as written until quick mode is wired to a delegation path or the rule is removed.

```text
         CONFIG-ARTIFACT DELEGATION VARIANT. For a focus targeting a single large config artifact (BOG/
         XML/JSON) with N gaps each corresponding to a distinct named container, scope each sub-agent by
         CONTAINER PATH rather than file count — "3-4 files" does not apply to a single-file artifact.
         Specify: (a) full artifact reference + line range; (b) exact container path (e.g.
         `/Drivers/NiagaraNetwork`). Each gap = one container = one block. (Source: 2026-08-30-jace-station-config-focus-retro.md Δ2)
         QUICK-MODE DELEGATION. When answering a scoped operator question under quick mode (quick mode — SKILL.md triage; document mode §20),
         the three-source sweep MAY be delegated to a single bounded sub-agent when the answer requires
         deep decompiled-code reading — one bounded worker returns cited verdict + file:line without
         inflating the parent. (Source: 2026-09-03-research-sdd-obix-quick-mode-retro.md #3)
         COMBINED-SWEEP FOR INDEPENDENT SMALL GAPS: when ≥2 small gaps each require reading 1-3 files
         on DIFFERENT subsystems, their pooled file count crosses the "~3-4 files or classes"
         delegation threshold — this is the exception to the "(Small/narrow gaps: read inline,
         no sub-agent — delegation has its own cost.)" note. Delegate a single agent covering both,
         returning cleanly separated sections per gap, authored as separate blocks afterward.
         Constraint: the subsystems must be independent (no shared mutable state between sweeps).
         SIBLING-GAP MOMENTUM: when a delegated sweep for the current gap is already in flight,
         investigating a small (≤2-file) sibling gap inline is a valid momentum tactic — add the
         sibling to the backlog first, then read it inline concurrently with the sweep. The driver
         serializes block writing as usual; both sweep result and inline result are written before
         any state update. (Evidence: GQL-G3/GQL-G2.)
         RECURSIVE FAN-OUT CITATION BOUNDARY: in a recursive fan-out (e.g. multi-level sharding), raw
         reading stays at the LEAVES — only cited snippets (file:line + load-bearing text) propagate up
         to the coordinator. The coordinator does not re-read leaf material; the citations are the unit
         of propagation. State this in the delegated prompt so the sub-agent does not dump raw content.
         COORDINATOR ADVANCES ORTHOGONAL WORK: while a delegated sweep is executing, advance
         independent work — prior-block validation, data-structure analysis, backlog review — rather
         than idling. The coordinator's lean context is the resource that enables this; use it.
```

---

## verify-edge-cases

Trigger: read this section in full when verifying a sub-agent's report and the sweep source is a
concatenated dump or a decompiled-context file, a sub-agent asserted an absence whose scope needs
widening, a scout returned absence from a narrow file set in an external repo, or a delegated sweep
contradicts something the driver already said inline. VERIFY BEFORE ACTING's core (a)/(b)/(c) recipe
in PROMPT-LOOP.md always applies; these are its narrower edge cases. (PHYSICAL-ACTION FACTS and
HIDDEN-FLAG CROSS-CHECK, formerly listed here, live in PROMPT-LOOP.md core — both fire on inline
work too, not only on verifying a delegated sub-agent's report. HIDDEN-FLAG CROSS-CHECK originally sat
between SYSTEMATIC-OFFSET CAVEAT and SCOPE below; in core it now precedes SYSTEMATIC-OFFSET CAVEAT.
The two bullets are independent, so the order carries no meaning; the remaining rules below keep
their original relative order.)

```text
       - SYSTEMATIC-OFFSET CAVEAT (extends item (a)) — when the sweep SOURCE is a CONCATENATED dump
         or a DECOMPILED-context file, a systematic line-number offset makes EVERY reported citation
         untrustworthy, so re-grep ALL load-bearing citations, not just the "key claim" ones (10/10
         blocks in one focus were offset-wrong). This ADDS to item (a) for those two source types
         only; it does not relax (a)/(b)/(c) or the "ALWAYS when the report is an ABSENCE" framing.
         SCOPE of a sub-agent's proven-absence is narrower than the full corpus. Before promoting
         a sub-agent negative to a gap closure, verify the cited scope covers the relevant universe
         (e.g. all jars / all modules, not just the swept subtree). A module-scoped "not found" is
         evidence for the module only — widen the search before accepting it.
         EXTERNAL-REPO ABSENCE: when a scout returns absence from a NARROW file set in an external
         repository, do not merely widen the file list — clone the repo and grep the whole tree,
         enumerating every relevant literal (`.connect()` calls, URL constants, config keys). A
         narrow-set negative is inconclusive; a tree-wide grep is the minimum re-test before
         accepting absence as [CERT]. (Evidence: blender-llm B8 §8.7; #572.)
         SWEEP CONTRADICTS DRIVER'S PRIOR INLINE STATEMENT. When a delegated sweep returns evidence
         that contradicts an assertion the driver made INLINE to the operator (not a block), acknowledge
         the refinement BEFORE or WHILE writing the block: (1) name what the inline answer said and where
         it was incomplete; (2) state the sweep's contradicting finding with its citation; (3) write the
         block using the refined framing. This is NOT a §14 (no block back-pointer); it is a
         conversational acknowledgment. Trigger: only when the correction would change the operator's
         behavior. (Source: 2026-08-30-station-organization-focus-retro.md SO1)
```

---

## delegated-claim-checks

Trigger: read this section in full when a delegated sweep returns a count that will serve as a
denominator or completeness claim, a scout's claim drives an architectural A⇒B conclusion, or a
delegated sweep answers a security/safety question by punting to an unsurveyed layer. VERIFY BEFORE
ACTING's core (a)/(b)/(c) recipe in PROMPT-LOOP.md — the "item b above" the first rule below refers
to is that recipe's item (b), not anything in this file.

```text
         RE-DERIVE DELEGATED COUNTS: counts returned by a delegated sweep (XML parse, config
         enumeration, file census) that serve as a denominator or completeness claim are hypotheses —
         re-grep every load-bearing count independently before using it. Distinct from re-grep-absence
         (item b above): this fires on POSITIVE counts too. An XML/config/bog sweep count is a
         starting point, not a settled number. (Distinct from RE-MEASURE A DRAMATIC NEGATIVE, which
         fires after a striking result; this fires on ANY delegated numeric claim that will drive scope
         or conclusions. Distinct from GAP NUMBERS ARE ALSO HYPOTHESES (BOOTSTRAP e), which fires on
         numbers in the gap's own DESCRIPTION before a sweep — this fires on numbers the sweep RETURNS
         after running.)
         DELEGATED-CLAIM-REVERSAL: when a delegated scout's claim drives an architectural conclusion
         (A⇒B — "A implies B"), test the reversed direction (B⇒A) before accepting it — A⇒B may be
         wrong as stated while B⇒A is trivially true. A single-direction confirmation passes the
         VERIFY BEFORE ACTING token-check but leaves the architectural conclusion unexamined.
         SWEEP-PUNT-TO-ANOTHER-LAYER: when a delegated sweep answers a SECURITY/SAFETY question with
         "the check, if any, is in <other layer> (not surveyed)", read that layer before authoring the
         conclusion — the punt is a scope flag, not a closure. A sweep that documents its own blind
         spot is honest; acting on its conclusion without filling the blind spot is not.
```

---

## long-build-delegation

Trigger: read this section in full for a §19 build/PoC iteration that will be delegated to an
implementation agent (spec-file handoff, mid-flight correction delivery). Not applicable to a
non-build gap.

```text
       - LONG BUILD DELEGATION (§19 iterations): write the full build spec to a scratchpad file
         BEFORE launching the implementation agent, and pass the file path in the delegation
         prompt rather than embedding the spec inline (inline specs bloat the launch turn and
         cannot be amended without a re-launch). If a constraint is discovered or the operator
         issues a correction mid-flight, deliver the updated spec file via the continuation
         mechanism (SendMessage in Claude Code) rather than killing and re-launching — re-launch
         discards accumulated implementation context and pays the startup cost again. Note: the
         continuation mechanism is harness-specific; if the harness lacks one, prefer shorter
         well-scoped delegations that are cheap to relaunch. (Evidence: nave-panccadia D19.)
```

---

## orchestrated-mode-caveat

Trigger: read this section in full only when the delegating agent is ITSELF a sub-agent
(orchestrated mode, one level deep) and needs to set a nested sweep's model tier.

```text
         ORCHESTRATED-MODE CAVEAT: when the delegating agent is ITSELF a sub-agent (orchestrated mode, one level
         deep), the nested `model:` tier override may be unavailable in the harness — the inner Agent call may
         fail with "agent type not available" (observed: B415 niagara/network-supervisor). Fallback: use Bash
         directly for the mechanical sweep (haiku-tier work), or route deterministic fan-out through the Workflow
         engine. Record the fallback as `inline (constraint: nested-tier-unavailable)` in the tier column.
```

---

## concurrent-writers

Trigger: read this section in full before launching more than one writer, background fork, or
chain against the same repository or corpus, and before delegating a writer when the research
target repo differs from the session's working directory. None of this applies to a single
writer on a quiet tree. (Kit issues #891, #892, #1177, #1188, #1199, #1222; the existing
CONCURRENT-SWEEP DISJOINT FILE SETS rule in PROMPT-LOOP.md HARD RULES is the base rule and still
applies in full.)

```text
         WRITE SETS ARE DISJOINT AND NAMED. Launch parallel writers only when every writer owns an
         exclusive, non-overlapping set of files for the whole run. Each brief lists the files that
         writer owns, lists every file the OTHER writers own, and says: "Do not touch those files;
         report any needed change instead." Read the FULL scope of every delegated task before
         launching a second writer — two writers on one shared file is luck, not design.
         DEFAULT TO TWO CONCURRENT WRITERS; add more only with disjoint file sets in harness
         worktrees and while the orchestrator stays lean (METHODOLOGY section 16: concurrency is a
         context-budget decision; kit CLAUDE.md section 3). Each extra writer multiplies
         shared-state and review-throughput risk.
         ONE COMMITTING CHAIN PER CHECKOUT/BRANCH AT A TIME. This applies to chains committing to the
         same checkout and branch; separate section 16 worktree lanes follow the section 16
         barrier instead. Two chains that regenerate CATALOG.md and
         `git add/commit/push` the same repo race on the catalog and on non-fast-forward pushes.
         Serialize committing chains per repo, or broaden one chain's backlog, instead of running
         parallel chains on one corpus.
         DIRECTORY OWNERSHIP. Each parallel agent writes only inside a path it exclusively owns for
         the run. A shared path (a common `tools/<x>/` download directory, a shared cache) has ONE
         designated owner agent; any other agent that needs a file placed there hands off to the
         owner instead of writing directly. A direct write into a path another agent owns can be
         denied by the runtime ("Modify Shared Resources") and wastes the run.
         SINGLE STATE-OWNER. When parallel block writers are told "touch no other file", a SEPARATE
         step run by the orchestrator (never by a writer) recomputes the RESEARCH-STATE counters and
         regenerates INDEX.md / CATALOG.md from the corpus. No writer edits shared state directly;
         state commits follow the block commits they describe.
         WRITE-SCOPE ADHERENCE IS A VERIFICATION DIMENSION, DISTINCT FROM CONTENT CORRECTNESS. For a
         multi-file deliverable drafted by cooperating forks (e.g. a block plus a companion doc),
         each fork is told which single file(s) it owns, and at least one OTHER verification pass
         checks which files were actually touched (a `git diff --stat` class of check), not only
         whether the drafted content is right. A scope violation and a content gap are different
         failure classes; a content-only review does not reliably catch both.
         HARNESS WORKTREE ISOLATION, WITH ITS LIMIT. Two actors sharing one checkout share the
         branch and the index, and `git checkout` is a whole-tree operation: a concurrent branch
         switch can discard another actor's uncommitted work. Isolate each concurrent writer in
         its own worktree and read back the returned worktree path before the first edit. Base each
         branch explicitly on `origin/main` (`git fetch` first), never on a stale local HEAD.
         WHEN THE TARGET REPO DIFFERS FROM THE SESSION CWD, never rely on the harness
         `isolation: worktree` option: it creates the worktree from the session cwd's repo (the
         wrong repo). Create the worktree explicitly with
         `git -C <target> worktree add <target>-worktrees/<name> <branch>` and pass that path to
         the writer. The harness resets shell cwd between commands, so the writer must use absolute
         paths or `git -C <worktree>` on every command (kit CLAUDE.md section 3).
         A worktree needs its OWN index/derived caches; never copy another checkout's.
         QUIET-TREE GATE PER WORKTREE. Writers run concurrently; the gate run (tests, linters,
         mutation controls) runs ONCE per worktree after that worktree's last writer finished. A
         gate that ran while a writer was still editing proves nothing, and "failed under load,
         passes standalone" is only a valid explanation while writers are actually editing.
         A FINISHED WRITER THAT KEEPS NOTIFYING IS STOPPED. Once a writer has delivered its report,
         stop it; a lingering agent that keeps emitting notifications or edits is a concurrent
         writer you did not plan for.
```

---

## delegation-briefs

Trigger: read this section in full when you write a brief for a delegated writer or sweep agent,
when a delegate's result comes back, when a build hits a framework/tooling wall, or when a
DOCUMENT CYCLE LARGE-SCALE run writes blocks from per-section agent findings. (Kit issues #894,
#897, #1095, #1202, #1246.)

```text
         EXECUTING-DELEGATE CONTRACT. A delegated worker can return a narrated plan with ZERO tool
         calls — it reads as done and changed nothing. Brief workers to EXECUTE with real tool
         calls, and treat a result with `tool_uses == 0` as a FAILED run: relaunch as an executing
         agent, do not accept the narrative.
         PER-TARGET ENVIRONMENT FACTS, QUOTED VERBATIM IN EVERY WRITER BRIEF. Keep one block (in
         the target's RESEARCH-STATE or its TARGETS.md detail section) holding: the test-runner
         command, the tools known to be ABSENT, and the runtime load path. Paste it into every
         writer brief; a writer must not name a runner, tool, or classpath that is not in that
         block. (Writers repeatedly named `pytest` where it was not installed and the runner was
         `python3 -m unittest`.) This is a convention for the brief, not a schema the registry
         tooling enforces.
         TRUNCATED INBOUND BRIEF. When a delegated block-writer's task brief arrives truncated or
         incomplete (distinct from the OUTBOUND report failing to reach the orchestrator): (a) ask
         the orchestrator ONCE for the full brief; (b) if no reply arrives within the session's
         bounded wait, proceed strictly from the visible gap labels/scope that DID arrive — never
         invent or guess the missing scope; (c) name in the block's own "Does not cover" note
         and/or its child-gaps section exactly what the truncation prevented it from attempting or
         resolving, instead of delivering a narrower block as if it were the briefed one. Advance
         rather than close a gap you could not fully attempt, with a named follow-up child gap.
         SWEEP CLAIMS ARE DRIVER-VERIFIED. A delegated evidence sweep returns leads, not facts: the driver
         re-opens every load-bearing token (file:line, count, quoted string) before writing it `[CERT]`. An
         unverified sweep claim stays `[INFER]`, and a block whose INFER ratio is high because of such claims
         declares type `mixed` (METHODOLOGY §11). Tell the sweep agent in the brief that its counts will be
         re-run; a driver re-run once failed to reproduce a sweep count. (Evidence: niagara B1185, B1188,
         B1194-B1196. Source: n4 agent-mcp retro #2.)
         BLOCKER-SCOPED FOCUS FIRST. In a combined build+research session, when the build hits a
         WB/framework wall, spin a focused research block on that exact wall BEFORE hand-coding a
         workaround, and hand the finding to the in-flight build via a teammate message. A focus
         scoped to an ACTIVE bug in the module under construction unblocks the build fastest.
         PDF-CITATION SPOT-CHECK (DOCUMENT CYCLE LARGE-SCALE, after the driver writes each block
         from per-section agent findings). For at least the load-bearing citations each agent
         supplied, confirm the quoted text appears on the stated page:
         `pdftotext -f N -l N <pdf> - | grep -F "<quote>"` (no toolbelt script exists yet).
         `verify-block.sh` resolves `file:line` references but does not check that the quoted text
         is actually there; without this step a page-number error or a dropped table qualifier
         survives until a manual re-read.
```

---

## review-and-delivery

Trigger: read this section in full when a repo under receipt-driven development (RDD) is about to
commit or merge, when a change set is large enough that a review lens budget could refuse it, when
a tooling bootstrap lands many tools at once, or when the target repo cannot enforce required
checks. (Kit issues #895, #1176, #1217, #1272, #1276.) The merge-order rule has an instrument
(`merge-gate.sh`, below); the rest is DOCTRINE the operator or driver follows by hand.

```text
         BULK AUTONOMOUS COMMITS VS RDD. When a chain commits per block under RDD, every commit
         trips the review stop-hook (non-blocking but noisy; races produce `unrelated target
         status is inconsistent`). For bulk autonomous research commits the OPERATOR disables RDD
         clone-local for that repo (`gentle-ai review mode disable --scope clone`) and re-enables
         it for deliberate work. The driver never toggles the mode itself.
         REVIEW SLICES ARE CHAINED COMMITS OF AT MOST ~400 AUTHORED LINES, REVIEWED PER COMMIT.
         A review lens has a context budget: one oversized candidate is refused
         (`lens_context_budget_exceeded`, observed on a ~3,400-line slice and a ~7,200-line tooling
         commit) and the recovery is a post-refusal split. Make the split the DEFAULT. Pre-split a
         large tooling-bootstrap (one commit per ported/created tool) BEFORE the first review
         attempt; cut slices at commit boundaries with real parents, never a squashed blob.
         WAVE INTEGRATION: commit a large binary `sources/` preservation (PDF, jar) as its OWN work
         unit and slice block commits at ~2-3 blocks each, so the one medium-risk piece is a small
         reviewable candidate (n5 wave 9: one mixed range was refused; re-sliced into 5 commits,
         only the PDF commit was medium and it reviewed cleanly).
         RDD BASE-REF IS THE LAST REVIEWED BOUNDARY. For the first slice that is the branch
         merge-base (where the branch left the default branch); each reviewed commit/slice then
         becomes the next base. Never use a moving `origin/main`: a base ahead of the branch shows
         later main merges as reverts and changes the candidate under review.
         PIPELINE REVIEW, DON'T SERIALIZE IT. Plan the slices up front (a script that cuts at commit
         boundaries and keeps each under the lens budget would be the mechanical form; none exists
         today, #1276), then review slice
         N while the next writer works on slice N+1: review is read-only on immutable commits, so
         the two do not collide. A serial "review, then start the next task" order wastes the
         review time (observed ~40-90 s per slice) behind the writer. Reviewing is still per
         commit; pipelining changes only the ordering.
         NEVER MERGE A DUE CANDIDATE BEFORE ITS REVIEW. When `gentle-ai review assess` reports
         `review_due=true`, the merge waits for the ACKNOWLEDGED review of that exact head (the
         observed failure: a PR merged before review, reviewed post-merge). The mechanical check
         is `toolbelt/merge-gate.sh --cwd <worktree at the PR head> --base-ref <PR base> --pr <PR#>`
         (or `--merge <PR#>`, which runs `gh pr merge <PR#> --squash --match-head-commit <head>`
         itself after an allow); merge only on a PR-bound allow (the line ends `bound to PR #N`).
         Without `--pr`/`--merge` it is range-only and trusts your `--base-ref`. Exit 0 allow, 1 refuse,
         2 usage, 3 degraded (never an allow). It never runs `gentle-ai review start`; the review
         itself stays the operator's step.
         MERGE WAITS FOR GREEN CI WHEN BRANCH PROTECTION IS UNAVAILABLE. If the target repo cannot
         enforce required checks (e.g. a private repo on a free plan), the driver's merge step
         MUST wait for green CI (`gh pr checks <n> --watch`) and record the result in the PR or
         run log. The in-repo pre-commit hook is the local backstop, not a substitute.
         WHEN FORCE-PUSH IS BLOCKED, PUBLISH A SUPERSEDING BRANCH. When the runtime or repository
         blocks force-push, publish the reviewed commits on a new branch and open a superseding PR
         that links the one it replaces, instead of rewriting; otherwise follow kit CLAUDE.md
         section 12.2 (rebase --onto and retarget).
         REVIEW PREFLIGHT VS OTHER AGENTS' FILES (#1175). The gentle-ai review preflight refuses while
         another agent's uncommitted files are in the worktree. Review from a clean, isolated worktree
         (the pattern every kit work unit uses), never the shared checkout.
         STOPPED CORRECTION => FRESH CANDIDATE (#1185). When a review correction stops incomplete,
         start a NEW test-first (RED then GREEN) commit as a fresh review candidate instead of resuming
         the stopped lineage. The RDD skill (`rdd-defect-workflow`: "findings require a new candidate")
         and the review-ledger contract ("Do not start another lineage ... or perform ambient recovery";
         `staged_workspace_overlay_recovery_unavailable`: "start fresh") cover adjacent cases but state
         this one only by implication, so it is recorded here.
         PR LABELS. When the repo's pr-check requires exactly one `type:*` label, attach exactly
         one before expecting the check to pass; zero or two fail it.
```

---

## resource-budgets

Trigger: read this section in full before starting a heavy run (a long decompile/bake-off, a
fleet sweep, a fidelity grading run, a multi-JVM job) or before launching a delegated agent that
will start one. (Kit issue #1253.)

```text
         CPU BUDGET BEFORE LAUNCH. Read load, core count and free RAM first. Keep total jobs at or
         below the physical thread count ACROSS ALL concurrent heavy runs, agents included, and
         never launch a second heavy run while one is active — queue it. Record the observed load
         in the run log so a slow run can be attributed. (Observed: a 10.6 h run at load 23-30 with
         25 JVMs on 16 threads.) Delegation multiplies this risk: every writer you add can start
         its own heavy job, so the brief states the job ceiling the writer may use.
```
