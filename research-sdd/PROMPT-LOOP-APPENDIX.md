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
Kit issue #1003 slice 5 moved seven of the keyed rules (REMITTANCE-RISK FLAG, REMITTANCE-TO-EVIDENCE UPGRADE, OPERATOR-CLASSIFICATION-FIRST, API-FILTER SILENT-DECLINE EXTENSION, NARROWING-AXES AND READ-FRACTION, SUBJECT-DECLARED THRESHOLD, IDENTIFIER-GRANULARITY CHECK) into the `step3-special-cases` section of this file; their key text now appears in core only in the one-line pointers, and the rule itself is `grep -nF`-able in `step3-special-cases`.

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
Slice 5 also moved `PKILL -F WRAPPER-SHELL MATCH` into the `hard-rules-loop-mechanics` section of this file; the key stays valid against the core pointer, and the rule is in that section.
Slice 6 also moved `LOCAL DOC CORPUS CITE DISCIPLINE`, `PRESERVATION-SURFACES-CORRECTIONS` and `FRONTIER-REOPEN DECISION SHAPE` into the `steps4-7-special-cases` section of this file (the keys stay valid against the core pointers; the rules are in that section). Slice 6 moved the body of the DOCUMENT CYCLE section into `document-cycle` in this file, so the keys `LARGE-SCALE §20 (outline > ~15 items` and `PRODUCE THE DELIVERABLE` now match text there rather than in PROMPT-LOOP.md; `grep -nF` them in the `document-cycle` section.
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

## step3-special-cases

Trigger: a step 3 (INVESTIGATE) special case listed below fires; PROMPT-LOOP.md step 3 leaves a one-line pointer per rule naming its trigger. Kit issue #1003 (slice 5) moved these rules here verbatim, in two groups kept in their original order (the first from after PRIOR COVERAGE CHECK, the second from after the deliberately-kept step 3 rules that precede the API-FILTER rule). Read the rule whose trigger fired, in full. Positional references inside the rules below ("above", "below") refer to PROMPT-LOOP.md, not to this file; "(step 5)" means PROMPT-LOOP.md step 5, and API-FILTER SILENT-DECLINE EXTENSION extends PRE-TEST POPULATION ANATOMY, which stays in core.

         REMITTANCE-RISK FLAG: when the PRIOR COVERAGE CHECK finds partial corpus coverage for a gap
         but cannot determine whether genuine new substance exists, flag the gap as REMITTANCE-risk in
         the backlog and include this flag in the sweep prompt: "check REMITTANCE FIRST — state whether
         this gap is fully answered by [Block N] §N.x with no new substance, BEFORE any tool use." A
         sweep that returns 'REMITTANCE — no new substance, cite [Block N] §N.x' is a valid closure;
         the driver closes without authoring a block. This prevents wasted investigation if the gap is
         remittance at fine grain even when the audit cleared it at coarse grain.
         REMITTANCE-TO-EVIDENCE UPGRADE: when the PRIOR COVERAGE CHECK finds a gap already answered
         but only at [CERT-web]/[CERT-a]/[INFER] (asserted from docs or memory), reading the PRIMARY
         SOURCE to lift the same claim to [CERT] is genuine new substance — NOT a remittance. The
         marker-tier upgrade justifies authoring a new block even though the coverage question is
         settled. The kit's existing "escalate a critical [CERT-a] before accepting" rule (step 5) and
         the CORROBORATION-FROM-INDEPENDENT-STORE pattern (step 5 self-verify) handle the after-the-fact
         case; this rule names the before-the-block case: a tier upgrade is a valid gap-closure path,
         not a wasted iteration.
         OPERATOR-CLASSIFICATION-FIRST: before building an extractor or classification filter for an
         operator's data package, check whether the package already carries a pre-existing human
         classification column (e.g. `Clase provisional`, `Revisión humana`, or any manually reviewed
         label field). A human classification is a REFERENCE STANDARD the extractor can be scored
         against — do not build a filter first and lose that calibration opportunity.

         API-FILTER SILENT-DECLINE EXTENSION: after applying an API call (select, filter, mark) that
         reports NO refusal, read the population BACK FROM THE SYSTEM and compare the returned count
         against the intended count before proceeding. A filter that silently declines entries produces
         no error and no warning — the discrepancy is only visible by comparing intent vs. result.
         NARROWING-AXES AND READ-FRACTION: when a sweep selects by BOTH container (layer/table/
         package) AND kind (entity type/class), declare BOTH narrowing axes and print `read N of M
         (X %)` as a headline on every census. A complement gate or coverage claim applied after a
         narrowing cannot see the unread fraction — the unread portion is an implicit scope exclusion
         that must be named.
         SUBJECT-DECLARED THRESHOLD: before choosing a classification threshold, look for one the
         SUBJECT ITSELF DECLARES in its artifact metadata. Prefer a value the artifact carries over
         any value the researcher picks — a subject-declared threshold produces a partition with no
         researcher-chosen numbers anywhere.
         IDENTIFIER-GRANULARITY CHECK: before keying on an identifier as a unique entity, count its
         DISTINCT VALUES against its OCCURRENCE count. A label in a document is a TYPE reference until
         proven otherwise — 44 distinct strings spanning 212 occurrences represent 44 types, not 212
         instances; collapsing by occurrence conflates all instances of one type. Confirm whether the
         identifier is per-type or per-instance before using it as a grouping key.

## hard-rules-loop-mechanics

Trigger: one of the HARD RULES below fires; PROMPT-LOOP.md's HARD RULES leave a one-line pointer per rule naming its trigger. Kit issue #1003 (slice 5) moved these rules here verbatim in their original relative order. ONE block per iteration, RESUME (incl. BLOCK PLAN RESUME, pinned by the block-plan suite), LOOP CONTINUATION, RESCHEDULE CADENCE, WAKEUP GUARD, preserve-in-sources/ and corpus language stayed in core: they fire on most iterations or govern continuation. Read the rule whose trigger fired, in full. Positional references inside the rules below ("above", "below") refer to PROMPT-LOOP.md HARD RULES, not to this file.

  - RE-MEASURE GROUND-TRUTH, never inherit it. When entering a DYNAMIC/hardware phase (or any new
    live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids —
    LIVE from the real system. Never cite them from a prior note/block (lesson: the logosoft bench program B66-B70 — TARGETS row #8; corpus not present on every machine, so qualify before citing). The worked example with the actual hex values
    lives in METHODOLOGY §12 — single source; don't restate the values here.
  - BASH-TOOL PATH NOT PERSISTENT: the shell state (including PATH) is reset between Bash tool
    calls on every platform — the harness initializes each call from the user's shell profile, so
    PATH changes made in one call are gone in the next. When a native tool (decompiler, scan
    utility, custom script) lives off the default PATH, two approaches: (a) durable — add the
    tool's directory to your shell profile so the harness picks it up on each init; (b) fallback
    — prepend in EVERY Bash call: `export PATH=<tool-dir>:$PATH && <command>`. Do not rely on a
    PATH set in a prior call. Cross-reference: BOOTSTRAP (a) / detect-tools.sh already covers
    off-PATH decompilers ("may live under linuxbrew Cellar … and still be off PATH").
  - INSTANT CAPTURE (mid-loop kit insights). When a defect, capability idea, algorithm, formula, or
    process insight surfaces during any loop step, save a conforming journal entry via `mem_save`
    BEFORE the loop continues — deferred capture (saving at the terminal instead of the moment) is
    out of spec. Required fields: `title: "<YYYY-MM-DD> <category>: <insight>"` (category ∈
    improvement / defect / tool-idea / algorithm-idea / formula-idea), `topic_key:
    "research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>"` (UTC; unique across sessions and parallel
    focus lanes; for multi-focus targets use
    `research/<target>/<focus>/journal/<YYYY-MM-DD>-<HHMMSS>` — same §16 convention),
    `project: "<target>"`, `type: bugfix | discovery | pattern` (do NOT use "decision" — see
    METHODOLOGY §18 type carve-out), and `content: "<one-line description> — evidence: <block/§/ref>"`.
    <HHMMSS> is agent-supplied: read the clock per entry (`date -u +%Y-%m-%d-%H%M%S` yields the full
    suffix) — an LLM has no clock of its own; if two insights surface within the same second, re-read
    the clock or append -2, -3, never reusing one timestamp for two entries. Omit session_id: Engram
    resolves the target project's active session, or falls back to manual-save-<target>, via resolveFallbackSessionID;
    passing the harness session_id causes session_project_mismatch because it belongs to the
    orchestrator project. One insight = one `mem_save` call under a unique key. §18 consolidates
    these entries at the TERMINAL TRIGGER (METHODOLOGY §18 journal mode). NOTE: this is a DISTINCT
    concern from MEMORY IS A MIRROR above (PROMPT-LOOP.md HARD RULES) — research findings destined for corpus blocks follow that
    rule; kit-methodology insights destined for the retro follow this one. Both apply simultaneously.
  - PKILL -F WRAPPER-SHELL MATCH. `pkill -f <pattern>` matches any process whose full command line
    contains <pattern> — including the enclosing `zsh -c`/`sh -c`/`bash -c` wrapper the harness
    wraps every Bash call in. When the pattern string appears inside that wrapper's argv, pkill signals
    every match — killing the enclosing session shell as well as (or instead of) the intended child. The naive remedy `kill $(pgrep -f <pattern>)` returns
    the SAME wrapper PIDs and has the same effect. Safe alternatives: (a) record the target PID at
    spawn (`$!` or a PID file) and kill that specific PID; (b) match by exact process name (`pkill
    -x <name>` / `pgrep -x <name>`), which matches the process NAME (`comm`, truncated to 15 chars on
    Linux) rather than the command line and so cannot match a `zsh`/`bash` wrapper — but a target name
    longer than 15 chars will silently not match; (c) the bracket idiom
    `pkill -f '[p]attern'` — the bracketed first character matches the target process line, but
    the literal string `[p]attern` does not appear in any wrapper's argv and so cannot match the
    wrapper — provided the plain pattern appears nowhere else in the same Bash call's argv.
    Mechanical guard: `templates/hook-pretool-pkill-guard.sh` (PreToolUse, matcher `Bash`) denies a
    command-position `pkill -f`/`pgrep -f`/`--full` without `-x` and without a bracket-escaped pattern, naming
    (a)-(c); without `jq` it degrades to `ask`. `research-sdd-init.sh` installs it as
    `<TARGET>/.claude/hooks/pkill-guard.sh` (create-only) and `--wire` registers it under `hooks.PreToolUse`.
    VERIFY KILL BEFORE REPORTING (#587): after any kill attempt, confirm the target process is
    actually dead with `pgrep -x <name>` or `kill -0 <pid>` (exit non-zero = process gone) before
    reporting the job stopped. A pkill that returned non-zero (or silently matched the wrong process)
    can leave a second competing job running; two Ghidra analyses ran in parallel for 20 minutes while
    the session reported one had stopped — caught only by PID-level re-check.
    OPERATOR-SESSION SAFETY (#671): when the operator has an active session on the target host, never
    kill by name pattern — use explicit PID only. `pkill -f <pattern>` can terminate operator-owned
    processes (a live capture proxy, a running REPL) that happen to match the pattern. Obtain the PID
    before spawning and retain it; if it was not captured at spawn, verify with `pgrep` and confirm the
    PID is the driver-owned process before killing.
  - OBJECTIVE-LOCK. When the operator states an explicit objective for the run, EVERY iteration opens
    with one line mapping the current action to that objective (`Objective: <objective> -> <this action>`).
    An action that cannot be mapped is off-objective and is not taken. Side-defects found en route
    (a license conflict, a daemonize failure, a version switch) become typed sub-tasks in the ODD task
    file (`templates/odd-task.template.md` carries an `Objective line:` field for this) and are fixed
    only as incident handling, bounded to what unblocks the objective; they never become the de-facto
    objective. Violation signature (observed): four consecutive theory pivots (profile -> env var ->
    daemonize -> portal), each consuming multiple tool batches, while the objective line went unstated
    and the objective itself never appeared as a tracked task line. Two pivots without an objective
    line is the tripwire: stop, state the objective, and re-map the next action to it.

## steps4-7-special-cases

Trigger: a special case of NORMAL CYCLE steps 4-7 listed below fires; PROMPT-LOOP.md leaves a one-line pointer per rule naming its trigger. Kit issue #1003 (slice 6) moved these rules here verbatim, in their original relative order. Positional references inside the rules ("above", "below", "step 5") refer to PROMPT-LOOP.md, not to this file. Read the rule whose trigger fired, in full.

     LOCAL DOC CORPUS CITE DISCIPLINE: at the first `[CERT-doc]` claim in a block that draws from a
     new local doc corpus (sources preserved under `sources/manuals/<focus>-docs/`), cite by the FULL
     HTML basename exactly as registered in the SOURCES.md row — NOT a doc-title shorthand or a
     truncated form. METHODOLOGY §5 encodes this at the registry level; this surfaces it as a prompted
     gate at the per-block cite-point so a sub-agent does not have to remember the §5 policy
     independently.

         GOVERNED-FAILURE ORACLE (steering proofs; METHODOLOGY §19, kit #1616): a block claiming a replaced constant/key/toggle took effect
         shows the failure (or pass) at the EXACT call that value governs, with the replaced value the ONLY difference from the baseline
         run, plus the counter-experiment (the same call passing once the dependent artifact is re-aligned). Any other failure proves nothing.
         Packs are per-target-class and audit-first: run `lint-block.sh --audit --pack <name>` and classify
         the findings before relying on FAIL mode; calibration false-positive rates are tracked on #1517.
         VERIFY-BLOCK CITATION GATE: BLIND FOR DECOMPILED-TREE BLOCKS. When a block's `[CERT]` citations
         all point into decompiled trees (`organized/*/vineflower/`, `organized/*/procyon/`, `audits/*.c`,
         etc.), verify-block classifies them as `extern` — it prints `resolved 0 of M` and a graded WARN
         (INFO for declared synthesis/capture/document/absence-centred/decision types; WARN otherwise)
         and exits 0. This output is EXPECTED, not an error: the script cannot follow a decompiler output
         path. The mechanized citation gate has checked nothing for that block; the burden falls ENTIRELY
         on the inline token-verify in this step 5. Self-verify must record this explicitly — e.g.
         "verify-block: resolved 0 of N (all extern — decompiled trees); sole citation gate = inline
         token-verify N/M rows" — so the omission is visible, not silently assumed covered. Separately:
         set `SOURCE_ROOT` to the decompiled-tree root to let the script resolve those paths; without it,
         inline token-verify is non-negotiable for any decompile-based block. `extern` citations
         (beautified/decompiled/snapshot) are not script-verifiable — still token-check those by reading.
         BASE-RELATIVE CITATION BLIND SPOT: verify-block resolves `[CERT]` paths against two
         roots in order: (1) `$target` — the second CLI argument, defaulting to the block's own
         directory; (2) the git toplevel of `$target` (N-PROJECT-FALLBACK). The blind spot is a
         path relative to a directory that is NEITHER `$target` NOR `$target`'s git toplevel —
         for example, a path relative to a corpus sub-directory (e.g. `sources/`) when the block
         dir is `$target`, or relative to a parent project root when the corpus is its own git
         repo and `$target` was passed explicitly as a different directory. Such a path is
         classified `extern` — appearing unresolvable though it is local. Fix: ensure citations
         resolve against `$target` or its git toplevel. A `[CERT]` that verify-block marks
         `extern` for a local file is a citation-form bug, not a decompiler limitation.
         TALLY-LINE TOKEN INFLATION: verify-block.sh counts ALL bracketed marker tokens in the
         block body after the header-legend fence — including a self-verify tally line written
         with the same syntax (`[CERT] 12`, `[INFER] 5`). This inflates the reported count by 1
         per type. Two compatible remedies: (a) keep the tally in the RETURN CONTRACT / iteration
         report (not in the block body) — METHODOLOGY §11's "literal verify-block.sh output"
         mandate applies to the RETURN, not to block content; or (b) if the tally must appear in
         the block body, run verify-block BEFORE appending the self-verify section and paste
         those pre-paste numbers; note that a re-run over the FINISHED block inflates each type
         by the number of bracketed tokens the pasted text contains — +1/type for a
         one-token-per-type tally line or table; +2 [CERT], +2 [INFER], +1 each other type
         (zero-count types read 1) for the full literal output. Do NOT write plain numerals
         (`CERT 12`) as a substitute in the RETURN — §11 requires the literal bracketed
         verify-block.sh output there.

         REMITTANCE GAP REOPENING: METHODOLOGY §8 defines remittance as a gap-closure category
         that avoids writing a redundant block — so there is no "remittance block" to upgrade.
         When a gap closed-by-remittance later gains direct evidence that confirms the remitted
         claim, REOPEN the gap in RESEARCH-STATE (set status back to `pending`) and close it by
         NEW investigation in the normal cycle. The new block cites the prior remission chain in
         its Connections section (e.g. "original gap closed-by-remittance to [Block N] §N.x;
         now confirmed directly"). Record the reopen + reclosure in the iteration-history row.

         PRESERVATION-SURFACES-CORRECTIONS: a §5 debt-closing pass that verifies bare-URL citations
         routinely surfaces link drift (a repo rename, an issue state change, a moved page) that
         demands §14 corrections on prior blocks. Budget for those corrections when scoping a
         preservation gap — do not treat them as scope creep; they are the expected second-order
         output of a careful preservation pass.

     TERMINAL-TIER CONVERGENCE: when a focus runs a second investigation tier over first-tier child
     gaps (revisiting sub-gaps surfaced by a prior block), record residues as in-block sub-sections
     rather than seeding new grandchild backlog rows. Grandchild rows re-inflate the investigable
     count and prevent the STOP criterion from firing on a focus that is structurally complete. A
     bounded second-pass is a block annotation; a genuinely new open question is a new backlog row.
     A focus that applies this rule and arrives at `investigable_open=0` is structurally converged;
     the STOP criterion fires normally, and the §18 RETRO CHECKPOINT applies — do not continue
     iterating past structural convergence (evidence: module-mechanics focus hit `investigable_open=0`
     after MM1–MM32 + 29 children; "sigue" re-opened Section-E as a new tier — correct, but only
     because the operator explicitly declared it; under campaign mode, an autonomous run enqueues the new tier per §8c and pops it without operator involvement).
     FRONTIER MODE (5th investigation mode — full definition in METHODOLOGY §8): covers genuinely
     unexplored territory with no prior corpus coverage. The sweep strategy is BREADTH-FIRST with
     LIGHTER BLOCK DENSITY — the goal is a coverage map across many sub-areas, not deep certification
     of one. Declare "MODE: frontier" in RESEARCH-STATE at bootstrap. A frontier focus is NOT under
     depth pressure from the [INFER]/[CERT] ratio: the ratio is expected HIGH and signals a need to
     return later with targeted deep-dive modes, NOT exhaustion. Distinct from a deep-dive focus
     reopened via FRONTIER-REOPEN (below), which continues an existing corpus; a frontier MODE focus
     starts with no prior evidence on its proposed surfaces.
     FRONTIER-REOPEN DECISION SHAPE: at STOP-CANDIDATE in heavy or frontier modes, run a coverage/section audit before
     honoring STOP. If the audit reveals >2 contiguous section entries uncovered OR >1 named
     sub-topic with no block coverage, that is a new tier, not an in-block residue — enqueue
     each new tier as a §8c campaign queue row with `kind=tier` (name, seed list, convergence
     criterion), seed the backlog from the uncovered entries, and write `last_audit:` once for
     this audit (one audit, one outcome). A single in-child residue stays in-block (annotated
     sub-section); it does not constitute a new tier. A tier declared this way is a legitimate
     reopen; a tier opened without a §8c queue row is a silent operator-only call an autonomous
     run cannot replicate.

         VISUAL/GEOMETRIC ORACLE (extends §19 CLOSE RULE): for a deliverable with a visual or geometric
         form (a rendered model, a floor plan, a spatial diagram), §19 close MUST include a comparison
         against a RENDERING of the source — and, when the deliverable is itself rendered, against a
         render of the deliverable AS ITS VIEWER draws it (not of the raw data feeding it). Symmetric
         measures such as lengths, areas, and counts are INVARIANT under reflection and cannot detect
         mirror/flip errors. A gate authored from the same corpus as the build inherits the build's
         geometric blind spots. Three consecutive defects (inverted slab bounding box, mirrored plan,
         doubly-flipped slab) each passed a green numeric gate and were caught only by the operator
         looking at the render. The EXTERNAL ORACLE is the comparison render, not the corpus-authored
         numeric gate. Record: "visual oracle: rendering compared vs. source, N discrepancies noted."

         CLAUDE-CODE-ONLY (kit issue #1110): the RETRO CHECKPOINT Stop-hook enforcement (PROMPT-LOOP.md step 7) — and the delta auto-seeding it
         triggers via `stage-retro-issues.sh` — is wired only through Claude Code's `Stop` hook (project,
         project-local, or user-level Claude Code settings); the kit wires no Stop-equivalent for any other
         harness (pi, gentle-shell), so their runs never auto-seed, and (as above) the retro-existence block is lost too. On
         pi/gentle-shell, run `$KIT/toolbelt/stage-retro-issues.sh <retro> --apply` by hand right after the
         retro is written (the same point the RETRO CHECKPOINT above requires it), before ending the run.
         No SessionStart hook fires there either: on pi/gentle-shell also run `$KIT/toolbelt/sweep-all.sh`
         at session start.

## document-cycle

Trigger: the run was invoked as `document` (CAPTURE mode). Kit issue #1003 (slice 6) moved the body of the DOCUMENT CYCLE section here verbatim from PROMPT-LOOP.md; the `== DOCUMENT CYCLE` heading and a pointer stay in core. Positional references that point inside this section (e.g. `[PENDING-live]`, below) stay within the section; references to NORMAL CYCLE, BOOTSTRAP or HARD RULES refer to PROMPT-LOOP.md. Read in full.

  This mode CAPTURES knowledge you already have or just produced in a session — it does NOT DISCOVER gaps.
  It NEVER runs the gap-discovery / AUDIT-FIRST path (BOOTSTRAP step e / METHODOLOGY §13): no gap-backlog is
  seeded and no self-feeding backlog is used. It REUSES the kit's markers, block anatomy, verify-block gate,
  and INDEX/CATALOG conventions unchanged. Full definition: METHODOLOGY §20.
  PREFLIGHT (new-target path only): if the subject path has NO corpus (no `RESEARCH-STATE`/`INDEX` at
  `$TARGET` or `$TARGET/corpus/`) AND the triage decision gate classified the request as explicit document/
  create intent for a new target → run BOOTSTRAP steps a, a2, b (TARGETS.md registration), and c — scaffold
  via:

    research-sdd-init.sh $TARGET [--corpus auto|nested|flat] [--prefix <slug>] --engram-project <TARGETS.md name> --document

  (kit issue #1114). **`--document` is REQUIRED here** — omitting it seeds the generic gap-discovery
  RESEARCH-STATE (placeholder `## Gap-backlog` rows this mode never discovers or closes) instead of the
  OUTLINE-driven variant. See `$KIT/templates/RESEARCH-STATE-document.template.md`'s own header comment
  for the full rationale (empty Gap-backlog, `## Outline` work-list, `method: document-cycle` envelope
  marker, and why that differs from `method: document-cycle-external`). Step e (gap-seeding) is explicitly
  skipped — this preflight is the mechanical registration and scaffolding only; it does not seed a
  discovery backlog and does not change this mode's outline-driven contract.
  The `--document` scaffold already seeds the envelope at 0 with no Gap-backlog rows — do not hand-correct
  those counters (kit #1886).
  1. SEED THE OUTLINE (replaces gap-discovery). Instead of uncovering gaps, seed the FULL list of
     topics/steps up front. Three sources: (a) what the user already knows, (b) their notes, (c) RECONSTRUCT
     the steps of the session just lived (e.g. a how-to for connecting an EM500 sensor, or bringing up a
     tool). The OUTLINE IS the work-list — there is NO AUDIT-FIRST discovery and no self-feeding backlog.
     PRE-OUTLINE SWEEP (before outlining, two cheap lookups; each can change the outline):
       - SIBLING-CORPUS PREFLIGHT (cross-target subject, kit #1907): when the subject spans more than
         one target (a how-to that touches several hosts or repos), grep the sibling corpora for an
         existing deliverable of the same subject (`HOWTO-*`, `RUNBOOK*`, `hardening/`) BEFORE
         outlining. Reuse or cite what exists; a deliverable found only mid-run forces blocks already
         written to be redone (evidence: a tunnel how-to found at its B9 forced B6 to upgrade 3
         `[INFER]` claims to `[CERT]`).
       - MEMORY-ONLY FINDINGS (kit #1894): `mem_search` the target (project + topic `research/<target>/`)
         for findings that have NO block (memory-only). Open a block for each one that the deliverable
         will state; until that block exists the finding is undocumented, so raise
         `undocumented_findings` in RESEARCH-STATE (a temporary state a later block must close). Never
         cite memory directly from the deliverable, and never let such findings surface only through
         `mem_save` conflict candidates after the deliverable is drafted. This is the intake side of
         the HARD RULE MEMORY IS A MIRROR, NEVER A SUBSTITUTE.
     LARGE-SCALE §20 (outline > ~15 items — per-section-agent pattern): the sequential
     one-item-per-iteration model is viable up to ~10–15 sections; beyond that the driver context
     accumulates across the whole run, defeating context-lean delegation. At scale: (a) pre-extract
     source material into per-section slices BEFORE dispatching — the source-before-agent rule applies
     at slice level (each slice confirmed readable); (b) dispatch ONE agent per outline item, each
     receiving its pre-extracted slice + the outline structure, returning ONLY cited findings
     (file:line + load-bearing snippets), NOT raw dumps; (c) the driver writes the blocks from those
     findings, then the PDF-citation spot-check (`$KIT/PROMPT-LOOP-APPENDIX.md#delegation-briefs`), and runs SELF-VERIFY (step 4) per block. Model tier per cognitive demand (NORMAL CYCLE
     step 3 MODEL TIER rule). Record in the iteration history as `method: per-section-agent · N sections`.
     This pattern does NOT remove the one-item-per-block rule — each agent targets one block; what
     changes is that N agents run in one dispatch round rather than N sequential iterations.
     COMMIT EXEMPTION (kit #1887): because N blocks are produced in ONE dispatch, a single import
     commit holding the dispatch's blocks is legitimate for a per-section-agent run — ONE-BLOCK-PER-COMMIT
     (step 7 closure obligations) is exempt for it, provided every block was individually SELF-VERIFIED
     (step 4) before the import commit and the iteration history records `method: per-section-agent · N
     sections`. The exemption never covers a sequential run. `research-sdd-archive.sh` honors it: a commit
     adding at most N blocks prints an exemption note instead of the WARN. N is the largest value among
     the CURRENT run's recorded rows: Iteration-history table data rows (numeric first cell, outside code
     fences) added AFTER the prior retro's commit — the archive counts the data rows in the state file as
     of that commit (`git show`) and skips that many. With no prior retro, or no state file at that
     commit, every row counts; if the prior retro has no commit or `git` fails, the exemption is not
     evaluated (typed note, the WARN stands). The marker match is exact (`·` separator, plural
     `sections`); a stale row, prose or a fenced example never exempts. The SELF-VERIFIED precondition is
     not machine-checked — the recorded method row is the declaration.
     STATE OWNERSHIP (kit #1888): when the author agents are instructed NOT to touch RESEARCH-STATE, the
     driver owns populating the document-cycle state (envelope counts, `## Outline` rows) after the
     blocks land; an unassigned owner leaves the template state orphaned (retro: mini-pc 2026-09-12, #1888).
     MID-RUN OUTLINE ADDITIONS (kit #1989): a coordinator may add work mid-run. Append a new outline row with the
     next integer `#` (the status tooling reads integer `#` cells only); put "added by coordinator" in the item text AND
     in the iteration history, and bump `Outline items total` and the `Outline coverage` denominator. When the addition changes
     CODE an earlier block cites (but not the cited text), prefer a dated addendum section in that block over a
     new block; no §14 correction is needed because nothing the block cites became false.
  2. ONE OUTLINE ITEM = ONE BLOCK: transcribe + cite that item following the block anatomy (§4). Evidence
     depends on GENRE:
       - Documenting how something in the SUBJECT works → `[CERT]` file:line (same as the static loop).
       - Documenting a PROCEDURE / how-to (connect the EM500, bring up a tool, a runbook step) → the evidence
         is the SESSION itself: the commands run, the GUI navigated, the outputs — PRESERVED under
         `sources/probes/` and cited `[CERT-hw]` / `[CERT-live]` per channel, EXACTLY as the dynamic phase
         (§12) already does. Do NOT invent a new marker; reuse the existing ones (the one sanctioned
         addition is `[PENDING-live]`, below).
       - PROBLEM-ENTRY MOLD (kit #1889): every problem or lesson recorded inside a document-cycle block
         uses ONE canonical shape: symptom → cause → fix → why it works → when/where (commit) →
         verification + marker (`[CERT-*]`). A problem entry missing any element is incomplete, not
         "short". (Evidence: six traceable, reproducible problem entries in one block used this mold.)
       - PENDING-LIVE REGISTRATION (kit #1893): a `[PENDING-live]` marker (the retro's example was the
         Spanish `[PENDIENTE-live]`) in ANY block, a `Type: document` runbook included (it never runs the
         §13 gap backlog), must ALSO be registered in RESEARCH-STATE in the SAME commit, as a
         `## Blocked gaps` bullet `- <claim> — needs: first live run`, bumping `known_gaps` with it (the bullet
         raises `blocked_open`; METHODOLOGY's gap-counter rule otherwise trips CHECK H). A dedicated pending-validation
         section is NOT defined yet and no tool counts one (Refs #1893). A deliverable must NOT make an
         unvalidated mode its DEFAULT unless that bullet names the first live run as the validation.
         (Evidence: a coexistence mode tagged pending-live in a block header, unlisted in state, shipped
         as the kit default and failed on first real use.)
  3. AUTO-ROUTE the write destination by knowledge TYPE (the MODE decides — the user does NOT specify per
     call), PER CLAIM, not per block: one block may hold subject claims AND toolchain claims, so route
     each claim separately (the toolchain half proposed via the retro, not left only inside the block).
     Ask: "does this knowledge serve OTHER targets too?"
       - Knowledge ABOUT the subject under study (this gateway's config, how to connect a sensor to THIS
         device) → the TARGET's corpus (`$CORPUS`), like any block.
       - REUSABLE TOOLCHAIN / environment knowledge (bring up Ghidra, use bkcrack, a WSL setup step — useful
         across ANY target) → PROPOSE to the kit: record it in the §18 retro TOOLS section as a `promote`
         (new toolbelt file) or `absorb` (delta into an existing kit file) candidate, PLUS an Engram pointer
         so it is recall-findable immediately. The supervisor writes it to `$KIT/toolbelt/` and registers it
         in `$KIT/toolbelt/tool-registry.md` after the run — kit changes are never applied from inside a run
         (§18 propose-never-apply). (The browser-appliance and serial bring-up how-tos in
         `$KIT/toolbelt/DYNAMIC-SETUP.md` are the kind of toolchain how-tos this routing eventually produces.)
  4. SELF-VERIFY: run `$KIT/toolbelt/verify-block.sh <block>` and the load-bearing token-check — the SAME
     gate as NORMAL CYCLE step 5. Procedure blocks preserve their probe evidence under `sources/probes/`
     (`[CERT-hw]` / `[CERT-live]`), same as §12.
     TARGET-DIR FOR NESTED CORPORA (kit #1905): `verify-block.sh <block> [target-dir]` resolves
     `file:line` cites relative to target-dir, which defaults to the block's own directory. In a NESTED
     corpus (`$TARGET/corpus/`) pass `$CORPUS` (the corpus dir) as target-dir when the block cites
     `sources/…`; passing the target root resolves nothing (evidence: `$TARGET` → 0 of 17 cites
     resolved, `$TARGET/corpus` → all `ok`). A near-zero resolved count on a cite-heavy block is a
     wrong target-dir until proven otherwise, not a clean block.
     DOCUMENT AFTER EVERY VERIFICATION OR CHANGE (kit #1890): "done" is not only a closing act. After
     EVERY verification, fix or change made during the run, record it immediately in the block (using
     the problem-entry mold of step 2) and mirror it (step 5) — do not batch the write-up to the end
     of the run. A change or verification with no written trace is not done (see also METHODOLOGY §8, §18).
     STATE SYNC PER BLOCK (kit #1899, prompt half): in the SAME commit as each block (per-section-agent
     runs: once, in the import commit), run `$KIT/toolbelt/research-sdd-status.sh $CORPUS --sync-state
     --focus <slug>` and `$KIT/toolbelt/verify-state.sh $CORPUS --focus <slug>` on a multi-focus corpus,
     or `research-sdd-status.sh $CORPUS --sync-state --root` and `verify-state.sh $CORPUS` (no flag) on a
     single plain `RESEARCH-STATE.md` (what `research-sdd-init.sh --document` creates), so the RESEARCH-STATE
     envelope's `covered_blocks` never lags the block files and INDEX.
  5. MANDATORY ENGRAM MIRROR (non-negotiable — this is the whole point of the mode). Mirror EVERYTHING
     documented to Engram as topic pointers so the doc is always recall-findable: subject knowledge under
     `research/<target>/<topic>`, toolchain knowledge under a kit-level pointer. This exists because a real
     session re-discovered Ghidra setup from scratch when `toolbelt/GHIDRA-MCP.md` already documented it but
     Engram carried no pointer — the mirror is what prevents that. A documented item with NO Engram pointer
     is NOT done.
     SUCCESS-CAPTURE RECIPE (mirror gate): an operator-confirmed success ("it works now", a fix the
     operator verified in chat) is NOT captured until the corpus holds a REPLICATION RECIPE valid for a
     DIFFERENT machine of the same class: the mechanism (why it worked), the exact steps, and the state
     preconditions (what must already be true on the machine). A one-line success statement in a session
     summary without the mechanism counts as LOST CAPABILITY: if the mechanism was not derived, the
     capture is incomplete and the derivation becomes the next gap. (Observed: a bench fix confirmed by
     the operator after a reboot was noted as one line; two days later it could not be reapplied from the
     record, and the mechanism was derived from bytecode only afterwards.)
  6. PRODUCE THE DELIVERABLE: besides the cited blocks, write the human-readable product —
     `HOWTO-<x>.md` / `SETUP-<x>.md` / `RUNBOOK.md` (subject deliverables under `$CORPUS`; toolchain
     deliverables are PROPOSED via the §18 retro TOOLS section and land in `$KIT/toolbelt/` only after
     the supervisor acts). For REFERENCE-MANUAL corpora (a corpus whose blocks
     document a large API/SDK/protocol), also produce COMPANION REFERENCE ARTIFACTS: a cheat sheet
     (most-used paths on one page), a glossary, a symbol-to-chapter keyword index, and optionally a
     single-file full-manual build. These are not blocks and carry no evidence markers — they are
     navigator aids, not procedural deliverables. Place at $CORPUS root.
  7. STOP when the OUTLINE is fully covered — NOT on gap-exhaustion (there is no gap set, so no
     read-only-investigable count and no 2×-empty secondary criterion apply). The outline is the terminator.
     CLOSURE OBLIGATIONS: the outline-completion STOP inherits the following from the NORMAL CYCLE:
       - ONE-BLOCK-PER-COMMIT and the commit-message convention (`research(<target>/<focus>): B<n>
         <slug>`) apply throughout the document cycle, not only at normal-cycle close (LOOP
         CONTINUATION hard rule). Exception: a LARGE-SCALE §20 per-section-agent dispatch may land as
         one import commit (step 1, COMMIT EXEMPTION, kit #1887).
       - SELF-RETROSPECTIVE (METHODOLOGY §18): delegate a fresh-context retro agent exactly as the
         NORMAL CYCLE terminal trigger prescribes. §18 fires "at every focus STOP and at campaign STOP",
         and outline completion is a focus completion. A DOCUMENT-MODE BATCH of 3+ blocks (a tanda) ends
         the same way even without formal outline completion: emit the retro when the batch closes, do
         not wait for the operator to ask (hilton B19-B24 had none until demanded).
       - TARGETS.md row refresh (propose-never-apply, METHODOLOGY §18; kit #1992): a run never edits an existing TARGETS.md row; it
         PROPOSES the new row values (block count, run facts) in its final return and in the retro; the
         supervisor (human) applies the refresh.
       - `research-sdd-archive.sh`: run it (gates linters, regenerates CATALOG, prints the
         close-checklist). Use `--dry-run` to preview.
