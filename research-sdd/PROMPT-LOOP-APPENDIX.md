# PROMPT-LOOP-APPENDIX — Research-SDD (situational)

Companion to [`PROMPT-LOOP.md`](PROMPT-LOOP.md). This file holds SITUATIONAL prose that used to
live inline in the OPERATIONAL PROMPT's step 3 — narrow special-case rules a driver only needs
when a specific trigger fires, not on every iteration (mirroring how METHODOLOGY.md separates its
own HOT-CORE from SITUATIONAL sections). A rule lives here only if its trigger is narrower than
"most iterations" AND it never applies to inline (non-delegated) work; everything else — including
every always-hit delegation rule — stays in PROMPT-LOOP.md core. Lazy-load != skip: every rule here
still applies in full once its trigger fires; PROMPT-LOOP.md's core leaves a pointer naming the
exact trigger and this file's section, so a driver reads a section here only when that trigger is
live, and reads it IN FULL when it does. Two sections, `step3-evidence-provenance` and
`prompt-loop-evidence-provenance`, are the explicit exceptions: they hold no operating rule, only the
corpus provenance notes moved out of PROMPT-LOOP.md (kit issue #1003: step 3, then the rest of the
prompt), and are read only to audit where a rule came from.

The two `hard-rules-*` sections at the end are a second exception to that admission rule (the first is the provenance pair above): they hold trigger-bound HARD RULES (kit issue #1003 L2) that can fire on inline work too, moved here because each fires on a narrow condition, not on most iterations. WEB-RESEARCH DISCOVERY-ONLY and the DELEGATED SWEEP subcases stay in core precisely because they fire on most iterations.

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

---

## step3-evidence-provenance

Trigger: none — this is provenance, not an operating rule. Read it only to audit where a step 3
rule came from. Kit issue #1003 (first slice) moved the corpus-specific `(Evidence: ...)` anecdotes
out of the OPERATIONAL PROMPT's step 3 so every iteration stops paying for them; the rules
themselves are unchanged and still live in PROMPT-LOOP.md step 3. Each row keeps the original
note verbatim, keyed by the rule it annotated. Two prose anecdotes without the `(Evidence:` wrapper (PRIOR COVERAGE CHECK, SCOPING JUDGMENTS ARE
HYPOTHESES) are included, so step 3 is complete. Two short retro pointers (`SECRETS-SENSITIVE INLINE
OVERRIDE`, `PEER CATCH`) stay in core: they are one-line pointers, not anecdotes.

| Step 3 rule | Original provenance note |
|---|---|
| GAP-ID VERIFY + ALREADY-COVERED PRE-CHECK | n5 waves 6-7 B69 B65-G1 vs G3, B74 B50-G7 vs G6; wave 11: 7 gaps returned ALREADY-COVERED at no re-derivation cost. |
| REMITTANCE-RISK FLAG | apis focus API5/API6/API8. |
| REMITTANCE-TO-EVIDENCE UPGRADE | blender-llm B10, B4 §4.2/§4.5. |
| OPERATOR-CLASSIFICATION-FIRST | blender-llm B76 §76.5. |
| ANNOTATION-BEFORE-DERIVATION | COB-IM2 B8, ANNOTATION-BEFORE-DERIVATION only; the originally cited commit no longer exists after that corpus's re-bootstrap. |
| ENTRY-POINT INSTRUMENTATION PRE-CHECK | blender B6. |
| CWD-PATH BUG FIRST | spyder commissioning. |
| VERIFY (b) absence grep-confirm across ALL install roots | n5 B102 "pxEditor absent", refuted by an `ls` of the config home. |
| PHYSICAL-ACTION FACTS | commissioning sweeps. |
| API-FILTER SILENT-DECLINE EXTENSION | blender-llm B60 §60.4. |
| NARROWING-AXES AND READ-FRACTION | blender-llm B62 §62.1–§62.3. |
| SUBJECT-DECLARED THRESHOLD | blender-llm B63 §63.2. |
| IDENTIFIER-GRANULARITY CHECK | blender-llm B65 §65.2. |
| DECOMMISSIONED/BROKEN ENDPOINT SUBCASE | niagara framework-drivers-closure D2. |
| REACHABLE ≠ REPRESENTATIVE-DEFAULT | blender B9. |
| PRIOR COVERAGE CHECK | Evidence: B279 ran module-navigator before reading B133, which already documented the JNI boundary; required a §279.9 self-revision. |
| SCOPING JUDGMENTS ARE HYPOTHESES | Evidence (retro 2026-08-07): B381 refuted B129 §129.7's "decompilation not load-bearing" — a scope-out that held unchallenged for six weeks; the actual function bodies surfaced LocalSystem account, SERVICE_AUTO_START, argv-passed passphrase, DPAPI-no-entropy, and REG_BINARY under HKLM — all load-bearing security facts. |

## prompt-loop-evidence-provenance

Trigger: none — this is provenance, not an operating rule. Read it only to audit where a rule came from.
Kit issue #1003 (second slice) moved the corpus-pointer notes that sat outside step 3 out of
PROMPT-LOOP.md so every iteration stops paying for them; the rules themselves are unchanged and still
live in PROMPT-LOOP.md. Each row keeps the original note verbatim, including its `Evidence:` /
`evidence:` / `lesson:` prefix and parentheses. The first column is the exact text the annotated rule
carries in PROMPT-LOOP.md (a label or a unique opening phrase), so `grep -nF` on it finds the rule.
Seven keys (`NAME-THE-JAR`, `MULTI-MARKER`, `GROUPING-RULE`, `NEGATIVE-ABSENCE`, `VENDOR-DOCUMENTED PORTS`, `IDENTIFIER-LEVEL SET INTERSECTION (#603)`, `The conversation is an exfil surface`) name rules that kit issue #1003 slice 4 moved into the `hard-rules-measurement-and-claims` / `hard-rules-live-install-access-recipe` sections of this file; `grep -nF` them here instead of in PROMPT-LOOP.md.
Notes that carry a real reason (not just a corpus pointer) and the one-line retro `(Source: ...)`
pointers stay in core.

| Rule (exact text in PROMPT-LOOP.md) | Original note (verbatim) |
|---|---|
| OPERATOR-SUPPLIED DATA PACKAGE | (Evidence: blender-llm B66–B67.) |
| EVIDENCE-GROUNDED DESIGN focus type | (Evidence: B611–B619.) |
| REMITTANCE-DOMINANT EXPECTATION | (Evidence: apis focus.) |
| AUDIT BOOTSTRAP PRODUCTION SCOPE | (Evidence: niagara own-modules-audit.) |
| FILTER-CALIBRATION DOMAIN | (Evidence: blender-llm B21–B37.) |
| FILTER INHERITANCE PROHIBITION | (Evidence: blender-llm B61.) |
| PRODUCT/VENDOR IDENTITY SUB-CHECK | (Evidence: B495 §495.3.) |
| SWEEP HYPOTHESIS HIGH-RISK SUBCLASS | (Evidence: B622 §622.3, B624 §624.3.) |
| SWEEP NUMERIC LABELING | (Evidence: access-control sweep AC3/AC4.) |
| BASE-MODULE IDENTIFICATION | (Evidence: provisioning focus — PV1/PV7.) |
| ARTIFACT-TYPE COMPATIBILITY | (Evidence: B386 §386.2.) |
| PDF-HEAVY / DOCUMENTATION TARGET | (lesson: WEB-HMI10-CF) |
| PDF CORPUS FAMILY-BLOCK | (Evidence: niagara optimizer-docs — family block.) |
| RELEVANCE-TRIAGE CHECKPOINT (PDF CORPUS) | (Evidence: niagara optimizer-docs — triage.) |
| GAP-PREMISE RE-DERIVE AT CHOOSE | (Evidence: blender-llm B57 §57.1.) |
| PER-ITERATION VALUE GATE | (Evidence: niagara B899–B928.) |
| LOCAL DOC CORPUS CITE DISCIPLINE | (Evidence: B336 `e975837`.) |
| (c) ENVIRONMENT/RUNTIME-VERSION | (Evidence: B616/B617.) |
| SYNTHESIS-BLOCK REGISTRATION RULE: a synthesis block | (evidence: niagara/email B334; commit `11142b9`) |
| SAME-COMMIT CHILD-GAP RULE | (Evidence: B413; commit `a852383`.) |
| PRESERVATION-SURFACES-CORRECTIONS | (Evidence: blender-llm B15, B2/B3.) |
| ARTIFACT AUDIT | (Evidence: platform-native reopen.) |
| FRONTIER-REOPEN DECISION SHAPE | (Evidence: #564.) |
| LARGE-SCALE §20 (outline > ~15 items | (Evidence: api-openness.) |
| PRODUCE THE DELIVERABLE | (Evidence: api-openness.) |
| TARGET'S OWN LAUNCHER/CLI OPTIONS RUNG (#645) | (Evidence: `nre` pass-through flags.) |
| NAME-THE-JAR ⇒ OPEN-THE-JAR | (Evidence: niagara licensing.) |
| MULTI-MARKER BOOTSTRAP FUSION | (Evidence: niagara jace9000 bootstrap.) |
| IDENTIFIER-LEVEL SET INTERSECTION (#603) | (Evidence: blender-llm B61 §61.2.) |
| GROUPING-RULE DOMAIN (#611) | (Evidence: blender-llm B61/B63.) |
| NEGATIVE-ABSENCE CLAIM DISCIPLINE (#732) | (Evidence: B478 §478.5.) |
| VENDOR-DOCUMENTED PORTS FIRST (#670) | (Evidence: Fluke 177x.) |
| OFFENSIVE/DUAL-USE GAP DESCOPING | (Evidence: niagara signing-pki-live.) |
| The conversation is an exfil surface | (Evidence: computadoras B23–B25.) |
| RESUME, don't blindly redo | (lesson: niagara B76/B122). |
| (3) ORCHESTRATED | (Evidence: niagara loop-continuation retro.) |
| ONE BLOCK PER COMMIT | (lesson: three.js B15+B16). |
| PKILL -F WRAPPER-SHELL MATCH | (Evidence: blender-llm B6.) |
| RETURN CONTRACT (per-iteration CHECKPOINT | (Evidence: niagara loop-continuation retro.) |

## hard-rules-measurement-and-claims

Trigger: one of the HARD RULES listed below fires; PROMPT-LOOP.md's HARD RULES leave a one-line pointer per rule naming
its trigger. Kit issue #1003 (slice 4) moved these rules here verbatim and in their original relative order; NEVER MERGE A DUE
CANDIDATE BEFORE ITS REVIEW, the `tried:` rule, OFFENSIVE/DUAL-USE GAP DESCOPING and SECRETS DISCIPLINE stayed in core, after this group and before LIVE-SESSION ACCESS RECIPE; the rule immediately before the group, DISK-FIRST, also stayed in core. Read the
rule whose trigger fired, in full.

  - REAL-ARTIFACT-FIRST (packaged artifact inspection) — When a gap is about physical packaging / layout /
    on-disk artifact SHAPE, inspect the REAL packaged artifact directly (e.g. `unzip -l`/`unzip -p` over
    the signed jar) before/alongside the decompiled tree — `META-INF` signing entries, jar-entry taxonomy,
    and manifest bytes are INVISIBLE in decompiled source. Distinct from DISK-FIRST (which is disk-vs-live):
    this targets the packaged artifact vs the decompiled source. RIDER (source>jar for intent): when the
    finding is about INTENT (over-permission, dead code, config), prefer SOURCE if available — a packaged
    artifact shows declarations; source shows whether they are real or scaffold.
  - NAME-THE-JAR ⇒ OPEN-THE-JAR. Citing a JAR, DLL, archive, or packaged artifact by name is not
    evidence about its contents — the name confirms only that the container exists on disk.
    Decompile or extract the artifact before claiming anything about what it implements, licenses,
    or registers; "the jar is present" is a pre-condition, not a finding. A jar cited for licensing
    evidence with no decompilation is [INFER], not [CERT].
  - MULTI-MARKER BOOTSTRAP FUSION. A bootstrap gap (or any gap) that draws simultaneously from
    multiple independent evidence channels — e.g. [CERT-doc]+[CERT-web]+[CERT]+[CERT-live] all
    supporting the same claim — is a valid FUSION. Name it as fusion explicitly in the self-verify
    tally so reviewers read the redundancy as corroboration; see the sibling
    CORROBORATION-FROM-INDEPENDENT-STORE pattern (NORMAL CYCLE step 5 self-verify tally), which
    prescribes the same declaration for evidence blocks. Each marker still requires the evidence its
    tier demands; this rule names the multi-source convergence as a corroboration pattern, not as a
    waiver of per-marker standards.
  - RE-MEASURE A DRAMATIC NEGATIVE. When an enumeration or join yields a striking negative result
    (zero matches, near-total absence, a system that appears dead or empty), do NOT report it from
    a single measurement. Re-derive it by an independent method — a different key, a different
    grouping, a spot-check of raw records — before it enters a block. A counting artifact and a
    genuine finding are indistinguishable in the output; only a second measurement separates them.
    `verify-block.sh` cannot detect a wrong join key — this is a distinct failure class from
    marker/citation errors.
    IDENTIFIER-LEVEL SET INTERSECTION (#603): when the subject's entities carry a stable identifier
    (handle, UUID, class name, object ID), prefer an ID-level set intersection over a second count
    as the re-derive method. A count comparison can agree by coincidence while masking membership
    differences; an intersection proves set equivalence and names any residue explicitly — which
    members are present, which are missing, and whether the discrepancy is a subset or a symmetric
    difference.
  - NEVER COMPARE DIFFERENT LEVELS OR CUTS WITHOUT A DISCLAIMER (twin of RE-MEASURE A DRAMATIC
    NEGATIVE). Before setting two figures side by side, state what level and cut each is: equipment vs
    service-entrance, full month vs partial, extracted vs live, own count vs a vendor aggregate. If they
    differ, say so next to the comparison or do not compare. A mismatched pair reads as a dramatic
    result (hilton B21: 20% vs 46.9% from a double count; B23/B24: monthly vendor total vs partial
    measured) and the second measurement the sibling rule demands must be like-for-like.
  - VERIFY-FIRST ON EXTERNAL DELIVERIES. Anything that reaches a third party (an emailed report, a cron
    sender, a webhook, a deployed endpoint): build and test in an isolated preview, use endpoints that
    do NOT send, never arm a cron or make a real send without the operator's consent, and confirm the
    recipients by API rather than from memory. Production stays untouched until the OK. (Evidence:
    hilton energeticos report worker, B19-B24.)
  - RE-MEASURE A DRAMATIC POSITIVE. The same re-derive obligation applies when a live probe yields a
    striking positive (an apparent security weakness, an unexpectedly open or downgraded service). Do
    NOT escalate or capture it as a block from a single measurement. The banner-vs-protocol trap: a
    probe tool's connection banner (e.g. openssl `CONNECTED`) is a TRANSPORT event — it records only
    that the TCP connection was established, before the TLS handshake even runs, NOT that the server
    accepted the specific protocol version under test. "The client cannot offer version X" is not the same claim as "the
    server refused version X". Re-derive by an independent method or a targeted counter-probe before
    treating the finding as confirmed. (Evidence: jace8000; METHODOLOGY §12.) For aggregates, the cheapest form is
    the CONCENTRATION CHECK (METHODOLOGY §11a, kit #1988): flag a series with ~50 %+ of its period on one day beside the
    headline delta, or resolve it first.
  - DERIVED-VIEW INCONSISTENCY / IMPLAUSIBLE MAGNITUDE. When a derived or aggregated view of the
    data is inconsistent (conflicting counts, missing rows, version mismatch between two summaries),
    go to the SOURCE ARTIFACT rather than cross-referencing other derived views — each derived view
    may propagate the same upstream defect. Independently, when an enumeration or count is
    implausibly LARGE (thousands on a system known to be small), treat it as a hypothesis about
    instrument error FIRST — re-derive via an independent method before treating the result as a
    finding. For the near-zero direction (near-zero on a large system), use RE-MEASURE A DRAMATIC
    NEGATIVE (four rules above), which already prescribes an independent re-derive. These are
    the same family: a derived view is an instrument; its inconsistency is evidence it may be
    reporting wrong.
  - N-SEARCH CONVENTION TRIGGER. When N ≥ 3 independent search strategies — different keys, layers,
    or geometric/structural approaches — all return zero for the same feature category, the aggregate
    is a convention-inspection trigger, distinct from the single-result RE-MEASURE rules above. BEFORE
    launching a further symbol search, ask whether the corpus convention for this feature type encodes
    PRESENCE BY ABSENCE — the feature is where something is missing, not where a mark appears. If so,
    the next step is a structural or gap-reading pass, not another symbol search. Record the convention
    and the N failed strategies as its evidence (B37 §37.4: six independent searches — arcs, layer
    filter, circle fit, modelspace, insert points, jamb pairs — all zero; convention: wall-stops, not
    drawn symbols).
  - TWO CORRECT COUNTS THAT DISAGREE = CONVENTION SIGNAL. Two INDEPENDENT counts of the same feature that
    disagree yet are BOTH correct under different conventions (e.g. 8 drawn leaf+swing symbols ⊂ 21
    operator-counted openings) are a convention-inspection signal, not an error on one side — and the gap
    between them MEASURES the fraction the narrower convention captures. Distinct from GAP NUMBERS ARE ALSO
    HYPOTHESES (one count is WRONG) and from N-SEARCH CONVENTION TRIGGER above (N≥3 strategies all ZERO):
    here both counts are positive and correct. Resolve by naming each convention and testing the subset
    hypothesis, not by re-searching. (1 observed case; cheap sub-rule, not new machinery.)
  - GROUPING-RULE DOMAIN (#611). A grouping or clustering rule carries the shape-class domain in which
    it was validated — not just a threshold. Before reusing the rule on a different shape class, state
    the class it was validated on and confirm the new class shares the same topological properties.
    A rule derived from compact bodies does not apply to thin crossing geometry without re-validation:
    transitive bbox-contact over crossing slivers can grow without bound, collapsing the entire dataset
    into one cluster.
  - NEGATIVE-ABSENCE CLAIM DISCIPLINE (#732). A negative existence claim ("no X found", "Y is
    absent") is [CERT] ONLY when the EXACT artifact that would contain X was opened and searched.
    Asserting absence about an artifact NOT opened is [INFER], not [CERT]. Before recording a
    negative finding: confirm the container (jar, module, config file) was actually inspected; do NOT
    propagate a sub-agent's "not found" without verifying the scope covered the right artifact. A §14
    correction that retracts a prior finding based on absence must re-verify the absence in the exact
    named artifact before accepting the retraction.
    CENSUS TOKEN (#1212): the cited search must be by CONTENT (class, package or resource name INSIDE
    archives) across ALL declared artifact roots; a test for one guessed filename (`saml.jar` absent,
    yet `saml-rt/ux/wb.jar` ship) or a look in one directory (Program Files, not the config home) does
    not count. Cite the token searched and the root list.
  - VENDOR-DOCUMENTED PORTS FIRST (#670). Before making any connection attempt against a live
    target, read the vendor's documented management/API port from the manual or API spec. Never rely
    on a default port sweep (e.g., 22/80/443/8080) to discover the active service port: a
    vendor-specific port outside the sweep range will produce a false "no data path" conclusion.
    This check belongs BEFORE the first connection attempt, not as a recovery step after sweeps
    fail.
  - CONCURRENT-SWEEP DISJOINT FILE SETS (#644). When parallelizing agent sweeps, only parallelize
    agents whose target file sets (blocks to write, shared state to update — INDEX, RESEARCH-STATE,
    SOURCES.md) are FULLY DISJOINT. The driver serializes writes to all shared corpus files; most
    documentation and methodology gaps cluster on the same shared files, so serial dispatch is
    often the correct choice and not a performance issue. Parallelism is safe only when each agent
    owns an exclusive, non-overlapping set of output files.

## hard-rules-live-install-access-recipe

Trigger: LIVE-SESSION ACCESS RECIPE — a live-install / Niagara target at run START before the first live probe; any live
probe, redacted copy, raw image, binary-format check, config write or credentialed command on such a target; a credential
appearing in the conversation (the exfil-surface rule); and every archive close (the archive secrets gate). Kit issue #1003 (slice 4) moved this
rule here verbatim from PROMPT-LOOP.md HARD RULES; SECRETS DISCIPLINE (live-install targets), which it references as
"above", stayed in core. Read in full.

  - LIVE-SESSION ACCESS RECIPE (live-install / Niagara targets; kit #1931) — at run START, before the first live
    probe, capture and record the access recipe for each live channel in use (workbench launch, station fox
    URI, platform daemon port) per toolbelt/NIAGARA-N4-FRAMEWORK.md §9, as a block or `sources/probes/` note
    (host/port/URI STRUCTURE only; never credentials, SECRETS DISCIPLINE above). A run that closes without it
    makes the next session re-derive ports and URIs from scratch (a ~40 min loss recurred on 2026-10-07).
    REDACTED-FILE GENERATION WORKFLOW. When preserving a REDACTED copy in `sources/probes/`: (1) generate
    in scratchpad, never directly in `sources/`; (2) verify the mask worked with a SILENT count: `grep -c
    '<secret-pattern>' <masked-temp>` must return `0` — do NOT use bare `grep <pattern>` (no `-c`), which
    prints the raw value on a missed match; (3) test the mask pattern on a known-sample snippet FIRST
    before running over the full artifact; (4) only after a verified zero, move to `sources/probes/` and
    register in SOURCES.md. (Source: 2026-08-30-jace-station-config-focus-retro.md Δ1)
    RAW DISK/MEDIA IMAGE IS SECRET-BEARING. A full `dd`/PowerShell raw image of a physical device
    contains every partition's secrets (`/etc/shadow`, keyrings, keystores, config credentials) — keep it
    in the SCRATCHPAD ONLY, never under `sources/`. Commit ONLY the DERIVED tree/manifest: paths + sizes
    + per-file sha256, with Host IDs and credential values masked. Anchor the image's identity by its
    sha256 recorded out of the repo. (Source: 2026-08-30-jace8000-sd-focus-retro.md D3)
    STRUCTURE-ONLY BINARY INSPECTION RECIPE. To identify the FORMAT or TYPE of a secret-bearing binary
    without printing its value, use this ordered recipe — none of these steps print key/hash bytes:
    (1) MAGIC BYTES: `od -A x -N 8 -t x1z <file>` — identifies container format from first 8 bytes;
    (2) SIZE: `wc -c <file>` — identifies key length (32 B = AES-256 raw key, 665 B = wrapped blob);
    (3) DISTINCT-BYTE-COUNT (entropy proxy): `od -An -tu1 <file> | tr ' ' '\n' | sort -nu | wc -l` —
    200+ distinct values = ciphertext/wrapped key; low = framing/plaintext structure;
    (4) DELIMITER SKELETON: for a TEXT-FORMAT secret field, `sed 's/[a-zA-Z0-9]/x/g'` reveals
    separators, prefix tags, and segment counts while eliminating every hash/salt/key byte — quote only
    the skeleton, never the original. This recipe answers "what FORMAT is this field?"; the §6 entropy
    test answers the orthogonal question "is this blob encrypted?". Run whichever the gap needs.
    (Source: 2026-08-30-jace-data-at-rest-focus-retro.md ΔA)
    **The conversation is an exfil surface.** A credential pasted into chat lands in the session
    transcript/logs and is compromised immediately — treat it the same as a commit to a public
    repository and rotate it without delay. Out-of-band delivery is not optional.
    LIVE-WRITE recipe that keeps this invariant on an AUTHENTICATED write: (a) authenticate out-of-band —
    a curl `-K` config file in scratchpad, NEVER the credential in argv / probe cmdline / sources /
    engram / the conversation itself;
    (b) a secret-bearing body (e.g. a config) is backed up to scratchpad and cited by `sha256`+byte-count,
    NEVER by its body; (c) mutate with a BENIGN disposable marker (not real data), confirm via an
    independent oracle (§12), then restore byte-identical and VERIFY the restore; (d) drive it through a
    dedicated MINIMAL-PRIVILEGE ephemeral principal, revoked at session end. See METHODOLOGY §12.
    CREDENTIAL SOURCE + POST-RUN SWEEP: take test credentials from a mode-600 file OUTSIDE the repo,
    never pasted in a channel or embedded in an artifact; after EVERY live run that used one, grep the
    run's outputs (report, stdout, audit, journal) for the secret value as a FIXED string read from the
    credential file, never typed into argv. Run it as THREE steps inside a script or subshell `( ... )` (so `exit 2`
    never closes an interactive shell), exit 2 = SWEEP NOT RUN, distinct from a clean 0 (#1507): (0) strip CR and
    trailing whitespace from the cred file (`sed -i 's/[[:space:]]*$//'`; a CRLF pattern never matches the secret
    and returns a false 0); (1) guard: `grep -q . <cred-file>` must find at least one NON-EMPTY pattern line AFTER
    the strip, else `echo "SWEEP NOT RUN" >&2; exit 2` (a missing, empty or whitespace-only file must not pass: an
    empty pattern matches every line); then `test -r` EVERY output path, same exit 2 (a missing file through a
    `cat` pipe still prints 0); (2) `cat <outputs> | grep -cF -f <cred-file>` prints ONE total (grep -c exits 1 on
    0 hits — a CLEAN sweep, not a failure; with several files `grep -c` prints one `file:N` line each, hence
    the concatenation). Require a printed total of exactly 0; no printed number means the sweep did not run.
    Record the count in the block, and delete the credential file (0 hits on 5 runs x 4 outputs).
    COMMAND CONSTRUCTION (#1384): when a probe needs credentials, never build the command in an unquoted
    string variable (`C="curl -u $U:$P"; $C url`) — use a shell function (`ob() { curl -u "$U:$P" "$@"; }`)
    or an array. Under zsh the variable is not word-split, so the shell prints the whole command, secret
    included, in its "command not found" error. (Evidence: pancaddia oBIX read leaked the credential.)
    MINIMAL-PRIVILEGE CAVEAT: minting an ephemeral principal is a SURFACE-DEPENDENT capability — cloud
    platforms and managed IAM (AWS/GCP/Azure) typically can; embedded controllers, PLC/SCADA stacks,
    and hardware I/O APIs typically cannot. Check for an existing low-privilege account FIRST. When
    minting is unavailable, fall back to the benign disposable-marker mutation of step (c) above (or a
    dry-run) with an existing credential. See
    METHODOLOGY §12 for the surface-by-surface breakdown.
    REMEDIATION BRANCH (when the write REMOVES a discovered vulnerability, not a probe): a permanent,
    user-authorized security remediation is NOT the reversible-probe case — its correct END-STATE is the fix
    APPLIED, not reverted. Steps (a),(b),(d) still hold (out-of-band auth, sha256 backup-before-destroy, minimal
    principal), but step (c)'s "restore byte-identical + VERIFY the restore" is REPLACED by "verified fix +
    confirmed no side-effect on other state". Do NOT restore a vulnerability you just removed by rote compliance
    with the revert ladder — retain the backup for auditability, but leave the fix in place.
    BLOCK LABEL: an authorized config mutation on a live target must mark its block `⚠ CONFIG MUTATION` and
    record before/after state (and that a byte-identical revert was offered) — so an audit can tell a supervised
    write apart from a pure read at a glance.
    MECHANIZED at the close: `research-sdd-archive.sh` runs `toolbelt/scan-secrets.sh` as a fail-closed
    GATE. The working-tree half scans EVERY regular file under the physical target (the archive builds
    that list itself and passes it as `--files-from`; dirty, untracked AND gitignored files are all
    included, symlinks are not followed), never scan-secrets.sh's default-mode narrowing to the shallowest
    block directory (kit issue #1015). The list goes through scan-secrets.sh's own file scope —
    `*.md`/config files, not arbitrary source files, kit issue #987 item 2. When the target IS a git
    repo root with at least one commit, the gate ALSO runs `--committed` (everything ever committed,
    reachable from HEAD). A high-confidence secret VALUE from either REFUSES the close (exit 3); the
    output names the path and line, never the value. Dirtiness alone never refuses — the close flow
    always leaves the tree dirty at this point. Degraded states, all typed and never a bare `ok`: a
    target with no git repo of its own, nested inside a larger one (compared PHYSICALLY, `pwd -P` — a
    path through a symlink is not nested) or a repo root with NO COMMITS yet (`git init` before the first
    corpus commit) gets the working-tree scan only plus a stderr WARN, since there is no scannable
    history; a list that cannot be computed or is empty REFUSES; an unreadable DIRECTORY is skipped (git
    cannot add it either) and disclosed as `ok, N unreadable path(s) not scanned`; an unreadable in-scope
    FILE or any grep read error is DEGRADED (exit 3), never `ok`. There is no override flag and no
    git-ignore filter: a refusal on a gitignored secret store (`.env`, `*.conf`, `credentials`) is
    resolved by moving the secret store OUTSIDE the target directory (keep only its path and structure
    in the corpus), not by exempting it.
