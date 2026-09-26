# PROMPT-LOOP-APPENDIX — Research-SDD (situational)

Companion to [`PROMPT-LOOP.md`](PROMPT-LOOP.md). This file holds SITUATIONAL prose that used to
live inline in the OPERATIONAL PROMPT's step 3 and HARD RULES — narrow special-case rules a driver
only needs when a specific trigger fires, not on every iteration (kit issue #1003, mirroring how
METHODOLOGY.md separates its own HOT-CORE from SITUATIONAL sections). Lazy-load != skip: every rule
here still applies in full once its trigger fires; PROMPT-LOOP.md's core leaves a pointer naming the
trigger and this file, so a driver reads a section here only when that trigger is live, and reads it
IN FULL when it does.

No content below is reworded from its original PROMPT-LOOP.md location — this is a straight move.

---

## step3-delegation — Delegation, sub-agent verification & model tier (SITUATIONAL)

Trigger: read this section in full when you are about to delegate a sweep to a sub-agent, choose or
declare its model tier, verify a sub-agent's returned report, or evaluate a sub-agent's absence/
count/operational claim. Moved verbatim from PROMPT-LOOP.md step 3 (kit issue #1003, slice 1).

```text
       - DELEGATE heavy sweeps to sub-agents — default, not optional, for loop longevity. If the gap needs
         reading/decompiling more than ~3-4 files or classes, spawn a sub-agent (Agent/Task) to do the sweep
         and return ONLY the cited findings (file:line + the load-bearing snippets), NOT raw dumps. The driver
         loop must stay context-lean so it survives dozens of iterations before compaction — every raw
         decompiler dump you read inline shortens the loop's life. Keep inline only narrow, single-file reads
         you already know you need. (Small/narrow gaps: read inline, no sub-agent — delegation has its own cost.)
         Inline is viable when an external re-invoker exists (e.g. `/loop` with an interval), but the trade
         is real: context accumulates per-inline-iteration and the loop compacts sooner; delegation pays a
         sub-agent boundary cost but keeps context lean. Record a constrained inline run as
         `inline (constraint: <reason>)` in the tier column so it reads as a deliberate choice, not a
         silent rule violation (see RETURN CONTRACT).
         SECRETS-SENSITIVE INLINE OVERRIDE. The file-count delegation trigger and the config-artifact
         delegation variant below are OVERRIDDEN when artifacts are SECRET-BEARING (key files, shadow
         hashes, keystores, credential configs). Stay INLINE regardless of file count: a delegated sub-
         agent's cited findings for a secrets-bearing gap include key bytes or credential strings —
         exactly what SECRETS DISCIPLINE forbids in the driver context. Record as
         `no · inline (constraint: secrets-sensitive — <artifact type>)`. Applies only when the secret
         store is the SUBJECT, not when a directory merely contains secrets en passant. Pair with the
         STRUCTURE-ONLY BINARY INSPECTION RECIPE in SECRETS DISCIPLINE for the safe inline technique.
         (Source: 2026-08-30-jace-data-at-rest-focus-retro.md ΔB)
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
       - VERIFY BEFORE ACTING on a sub-agent's report, and ALWAYS when the report is an ABSENCE. A
         delegated finding is a hypothesis with citation, not a fact. Before writing a block or
         correcting a document on that basis: (a) resolve at least the `file:line` citations that
         support a key claim — two sweeps in practice returned paths that did not exist on disk;
         CWD-PATH BUG FIRST: before concluding a cited file does not exist (and thus concluding the
         sub-agent fabricated sources), rule out a cwd/relative-path bug — verify with
         `find <repo-root> -name <basename>` from the repo root. A file that returns "No such file"
         from inside a subdirectory may exist relative to the project root. (Evidence: spyder commissioning.)
         (b) if the sub-agent asserts something does NOT exist / is NOT documented / is absent,
         grep-confirm it yourself before accepting. (c) Tool-use count is a signal: a detailed
         report with very few tool calls inferred instead of searched.
         PHYSICAL-ACTION FACTS (highest-priority VERIFY): for any cited fact a human will act on
         physically — wiring instructions, terminal maps, part numbers, safety values, calibration
         constants — the orchestrator MUST sample-verify those citations against the real source
         BEFORE relaying them, not only before writing the block. The [CERT-doc] requirement is
         necessary but not sufficient here: verify-before-relay, not only verify-before-block. The
         driver must have read the cited line; trusting the sub-agent's accuracy for a fact that may
         cause hardware damage or a safety incident is not acceptable. Record: "physical-action verify:
         N citations checked against real source, all confirmed." (Evidence: commissioning sweeps.)
       - SYSTEMATIC-OFFSET CAVEAT (extends item (a)) — when the sweep SOURCE is a CONCATENATED dump
         or a DECOMPILED-context file, a systematic line-number offset makes EVERY reported citation
         untrustworthy, so re-grep ALL load-bearing citations, not just the "key claim" ones (10/10
         blocks in one focus were offset-wrong). This ADDS to item (a) for those two source types
         only; it does not relax (a)/(b)/(c) or the "ALWAYS when the report is an ABSENCE" framing.
       - HIDDEN-FLAG CROSS-CHECK — for a Go-CLI target block whose sweep SOURCE was `--help` output,
         also read the Go source's `cli.Flag` registrations for `Hidden: true` entries: they appear
         in neither `--help` nor `--help-all` yet may be operationally critical (4 missed in one
         sweep). Scoped to `--help`-sourced Go-CLI blocks only, not every Go CLI target.
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
         PEER CATCH. When a parallel session or the operator disputes a claim, re-open the PRIMARY source
         (not the decompile that seeded the claim) and correct the block with a §14 back-pointer; a peer
         catch is first-class evidence. (Source: 2026-09-03-research-sdd-rt-authoring-campaign-retro.md #5)
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
       - WEB-RESEARCH DISCOVERY-ONLY sweep — the web/spec sibling of the decompile-sweep pattern, and the
         per-iteration division of labor for a source-heavy focus: the sub-agent (`sonnet` tier) does DISCOVERY
         ONLY — finds candidate PRIMARY sources, rough cited claims, and URLs; it does NOT preserve. The DRIVER
         then preserves (`fetch-doc.sh`), extracts (`extract-pdf.sh`/`pdftotext`), TOKEN-VERIFIES each claim
         against the preserved local copy, and writes the block. Records as `yes · sonnet (web sweep) + inline
         extract/verify`. Distinct from BOOTSTRAP e3's SCOUT (a one-time pre-gap certifiability gate, not a
         per-iteration pattern): here the agent discovers, the driver preserves+verifies+writes every iteration.
       - MODEL TIER for the delegated sweep — match the tier to the sweep's COGNITIVE DEMAND (this is about
         EFFICIENCY, not saving tokens: don't run a scalpel task on a neurosurgeon). Pick `model` on the
         Agent/Task call:
           · MECHANICAL extraction — enumerate methods/fields, locate call-sites, grep-and-cite → `model: 'haiku'`.
           · STRUCTURAL comprehension — read N classes, reconstruct how a subsystem works, judge what is
             load-bearing, return cited findings → `model: 'sonnet'` (the DEFAULT for most sweeps, e.g. R5 history).
           · Genuine REASONING/inference — security exploitability, architecture judgment → keep it INLINE on
             the driver, or `model: 'opus'` only if it truly must be delegated.
         The DRIVER loop itself (marker discipline, [INFER] deductions, synthesis, self-verify) stays on the
         session's strong model — the kit does not change that; your `/model` does. If a tier is unavailable
         (e.g. no Opus access), substitute one tier down and note it in the report.
         Exception: verification or refutation voters never drop to `haiku` — run them inline on the driver
         or defer the seal (METHODOLOGY §8).
         (Harness-neutral tier contract and per-harness mapping: `toolbelt/model-tiers.v1.md`.)
       - LONG BUILD DELEGATION (§19 iterations): write the full build spec to a scratchpad file
         BEFORE launching the implementation agent, and pass the file path in the delegation
         prompt rather than embedding the spec inline (inline specs bloat the launch turn and
         cannot be amended without a re-launch). If a constraint is discovered or the operator
         issues a correction mid-flight, deliver the updated spec file via the continuation
         mechanism (SendMessage in Claude Code) rather than killing and re-launching — re-launch
         discards accumulated implementation context and pays the startup cost again. Note: the
         continuation mechanism is harness-specific; if the harness lacks one, prefer shorter
         well-scoped delegations that are cheap to relaunch. (Evidence: nave-panccadia D19.)
       - PRE-TEST POPULATION ANATOMY: before running a comparison or classification test, measure
         the anatomy of the test population — how many items survive the eligibility filter, and
         what fraction is auto-generated vs. semantic vs. absent. If the post-filter count is zero,
         the test is NOT APPLICABLE and must not run — report the measured pre-filter and post-filter
         counts in place of a vacuous result (the anatomy distinguishes "the filter consumed everything"
         from "the input was absent", satisfying §7). (Distinct from RE-MEASURE A DRAMATIC NEGATIVE,
         which fires AFTER a striking result to verify it; this gate fires BEFORE the test, when the
         population is still uncounted.)
         API-FILTER SILENT-DECLINE EXTENSION: after applying an API call (select, filter, mark) that
         reports NO refusal, read the population BACK FROM THE SYSTEM and compare the returned count
         against the intended count before proceeding. A filter that silently declines entries produces
         no error and no warning — the discrepancy is only visible by comparing intent vs. result.
         (Evidence: blender-llm B60 §60.4.)
         NARROWING-AXES AND READ-FRACTION: when a sweep selects by BOTH container (layer/table/
         package) AND kind (entity type/class), declare BOTH narrowing axes and print `read N of M
         (X %)` as a headline on every census. A complement gate or coverage claim applied after a
         narrowing cannot see the unread fraction — the unread portion is an implicit scope exclusion
         that must be named. (Evidence: blender-llm B62 §62.1–§62.3.)
         SUBJECT-DECLARED THRESHOLD: before choosing a classification threshold, look for one the
         SUBJECT ITSELF DECLARES in its artifact metadata. Prefer a value the artifact carries over
         any value the researcher picks — a subject-declared threshold produces a partition with no
         researcher-chosen numbers anywhere. (Evidence: blender-llm B63 §63.2.)
         IDENTIFIER-GRANULARITY CHECK: before keying on an identifier as a unique entity, count its
         DISTINCT VALUES against its OCCURRENCE count. A label in a document is a TYPE reference until
         proven otherwise — 44 distinct strings spanning 212 occurrences represent 44 types, not 212
         instances; collapsing by occurrence conflates all instances of one type. Confirm whether the
         identifier is per-type or per-instance before using it as a grouping key. (Evidence: blender-llm B65 §65.2.)
       - FALSIFY BEFORE REPORTING an operational conclusion. When the gap's answer would drive an
         operational recommendation (an alert, an escalation, a client report), cast it as a
         falsifiable hypothesis FIRST and test it against data already on disk before reporting it.
         Cost: typically one query. Value: prevented a wrong escalation costs far more. A block that
         refutes its own initial hypothesis is a valid, high-value block type.
         DELEGATED SWEEP OPERATIONAL CLAIMS (HIGH-FALSIFICATION-PRIORITY): a decompilation sweep
         that concludes about LIVE STATE — endpoint alive/dead, feature availability, service
         deployed — is structurally unreliable: decompiled code reflects what was SHIPPED, not what
         is RUNNING NOW. Apply FALSIFY BEFORE REPORTING MANDATORILY for any such claim; confirm
         against a live probe (§12) or current operational evidence before authoring.
         DECOMMISSIONED/BROKEN ENDPOINT SUBCASE: a decompilation sweep that concludes an endpoint
         is "decommissioned", "deprecated", "removed", or "broken" based on strings or error-path
         code is HIGH-FALSIFICATION-PRIORITY for the same structural reason — a decompile reads
         strings, not live operational state. A string `"endpoint decommissioned"` is evidence the
         developer EXPECTED decommissioning; it is not evidence the endpoint IS currently offline.
         Apply FALSIFY BEFORE REPORTING before reporting any decommission/shutdown status from a
         decompiled source. (Evidence: niagara framework-drivers-closure D2.)
       - REACHABLE ≠ REPRESENTATIVE: before using a live endpoint response as evidence, confirm it
         is the PRODUCTION PATH, not a debug/test stub. A reachable URL proves only that the
         transport works. Check documented service paths (vendor manual, API spec, or prior corpus
         blocks) or cross-reference with block-documented operational context before treating the
         response as production evidence.
       - REACHABLE ≠ REPRESENTATIVE-DEFAULT (node/tool primitives): a node or tool primitive's
         DEFAULT mode may suppress or hide the socket/field the gap is about. Before wiring a node
         or citing its output as evidence, introspect the primitive's active mode or variant and
         confirm it is the one relevant to the gap. Distinct from the live-HTTP REACHABLE≠REPRESENTATIVE
         rule above (which governs live endpoint transport); this governs static node/tool configuration.
         (Evidence: blender B9.)
       - CROSS-FOCUS SECURITY FEED: when a mechanics or coverage sweep incidentally finds a security
         footgun in decompiled code — an exposed credential store, an unguarded admin channel, an
         unsafe default — ADD a gap entry to the security focus's backlog in the same iteration. A
         breadcrumb comment in the current block is passive and searchable only by readers of that
         block; a backlog entry is durable, appears in `research-sdd-status.sh --focus <security-focus-slug>`
         output, and will eventually be investigated. Both is better than either alone.
       - MODEL TIER ALSO governs NESTED sub-sweeps. A general-purpose sweep-agent (one whose toolset INCLUDES the
         Agent tool — NOT Explore/Plan, which lack it) MAY itself spawn a SUB-SWEEP, and each Agent call carries
         its own `model`: pick the sub-sweep's tier by the SAME cognitive-demand heuristic. DO NOT NEST
         sub-agents: include this as a STANDING INSTRUCTION in every delegation prompt by default (word it
         explicitly: "Do NOT spawn sub-agents or use the Agent tool inside this sweep"). This is boilerplate, not
         optional guidance — include it in every prompt regardless of whether nesting seems likely. A sub-agent
         that nests silently hides its findings from the driver; recovery requires SendMessage and risks losing
         partial results (evidence: WB02 B428; niagara workbench-focus retro). The specialized agents
         (Explore/Plan) cannot sub-delegate at all. For STRUCTURED fan-out or multiple controlled levels, use
         the Workflow engine (deterministic control, no per-hop context compression) instead of free-form native
         nesting.
         ORCHESTRATED-MODE CAVEAT: when the delegating agent is ITSELF a sub-agent (orchestrated mode, one level
         deep), the nested `model:` tier override may be unavailable in the harness — the inner Agent call may
         fail with "agent type not available" (observed: B415 niagara/network-supervisor). Fallback: use Bash
         directly for the mechanical sweep (haiku-tier work), or route deterministic fan-out through the Workflow
         engine. Record the fallback as `inline (constraint: nested-tier-unavailable)` in the tier column.
```
