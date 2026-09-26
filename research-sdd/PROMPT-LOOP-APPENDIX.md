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

(kit issue #1003 round 3, F1: WEB-RESEARCH DISCOVERY-ONLY and the two FALSIFY BEFORE REPORTING
delegated-sweep subcases — DELEGATED SWEEP OPERATIONAL CLAIMS and the DECOMMISSIONED/BROKEN
ENDPOINT SUBCASE — moved back to PROMPT-LOOP.md core: each fires on inline work too, so neither
satisfied this file's own admission rule above. See `verify-edge-cases` below for the same
correction applied to PHYSICAL-ACTION FACTS and HIDDEN-FLAG CROSS-CHECK.)

---

## delegation-variants

Trigger: read this section in full when the gap is a single large config artifact, a quick-mode
operator question, ≥2 independent small gaps on different subsystems, a sibling gap while a sweep
is already in flight, a recursive multi-level fan-out, or you are advancing other work while a
delegated sweep executes. None of these apply to a plain inline gap.

(N2, kit issue #1003 round 3 review: the QUICK-MODE DELEGATION rule below is currently unreachable
from PROMPT-LOOP.md — quick mode never enters the loop at all; it short-circuits in SKILL.md before
BOOTSTRAP/NORMAL CYCLE ever starts, per `skills/research-sdd/SKILL.md`'s "quick and light modes
short-circuit: answer directly (quick)... do not bootstrap or loop." This predates this PR and is
left as-is — not this PR's defect to fix — but is worth a follow-up issue to either wire quick mode
into a delegation path that can reach this rule, or delete the rule as dead text.)

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
HIDDEN-FLAG CROSS-CHECK, formerly listed here, moved back to PROMPT-LOOP.md core — both fire on
inline work too, not only on verifying a delegated sub-agent's report; kit issue #1003 round 3 F1.)

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
