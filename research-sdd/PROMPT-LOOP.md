# PROMPT-LOOP — Research-SDD

This is the **loop-able prompt** of Research-SDD. It is designed to run in a loop
(with Claude Code's `/loop` skill, self-paced or with an interval) and advance a research
**one iteration = one block** at a time. It is **stateful and idempotent**: it reads its own
state from disk, so running it N times advances the corpus without stepping on itself.

---

## How to use it

1. Define the target (one from [`TARGETS.md`](TARGETS.md)). Edit the `TARGET=` line below.
2. Launch the loop (recommended — dynamic self-paced, no interval):
   ```
   /loop  <paste the OPERATIONAL PROMPT below, with TARGET already set>
   ```
   Without an interval the loop uses DYNAMIC self-paced mode: the `/loop` runtime re-fires each
   iteration on the agent's ScheduleWakeup (~60s floor), keeping latency low and the prompt cache warm.
   The re-fire depends on the agent calling ScheduleWakeup (LOOP CONTINUATION, case 2). FALLBACK —
   fixed-interval: if a dynamic run halts after a single block or the harness has no ScheduleWakeup,
   use an explicit interval (e.g. `5m`):
   ```
   /loop 5m  <paste the OPERATIONAL PROMPT below, with TARGET already set>
   ```
   Under fixed-interval the harness cron re-fires each turn; no ScheduleWakeup is issued; the STOP
   TEARDOWN rule applies (LOOP CONTINUATION, case 1). NESTED-LAUNCH RULE: never launch `/loop` from
   inside an already-running `/loop` invocation of either mode — in dynamic mode the `/loop` runtime
   + ScheduleWakeup IS the re-invoker. Do not launch when a cron/wakeup is already armed; check and
   proceed directly if one is active.
3. The loop stops on its own ONLY when the stopping criterion fires (read-only-investigable exhausted, or
   backlog empty 2× in a row) — see [`METHODOLOGY.md`](METHODOLOGY.md) §8. Until then it keeps iterating.
   **Fixed-interval caveat:** under `/loop <N>m`, the harness cron continues re-firing even after STOP
   declares — the stopping criterion alone does not cancel the job. When STOP fires, the agent MUST
   disarm the re-invoker as part of the STOP declaration (see LOOP CONTINUATION hard rule, case 1).

### Two execution modes (pick by whether a human is present)

The same NORMAL CYCLE runs under either mode — they differ only in WHO drives iterations and HOW much
each delegation carries:

- **Self-paced** (`/loop`, no human in the room): the loop agent IS the driver. Under dynamic
  self-paced (no interval), it reschedules itself (ScheduleWakeup); under fixed-interval (`/loop <N>m`),
  the harness re-fires and no ScheduleWakeup is issued. Either way, per iteration, it delegates only the
  HEAVY SWEEP of a gap (>3-4 files) to a sub-agent that returns cited findings, then writes the block
  itself. Autonomous; runs unattended.
- **Orchestrated** (a human present, driving): the driver chains ONE sub-agent PER ITERATION and
  delegates the WHOLE iteration — decompile + write the block + self-verify + commit — keeping the
  driver's context near-empty across many blocks (proven: 7 blocks, no compaction). The driver only
  orchestrates, gatekeeps by TRUSTING the sub-agent's self-report (§11), and launches the next.
  Orchestrated has two sub-modes:
    · **supervised** — the driver PAUSES after each block for the human to review before launching the
      next. Use when you want a checkpoint between blocks.
    · **auto** — the human says "run autonomously"; the driver AUTO-CHAINS iteration → gatekeeper → next
      without pausing, but only within DECLARED HARD-STOPS (e.g. stop on a failed self-report, on a
      destructive step, on corpus exhaustion). It is autonomous like self-paced, but each block still
      runs in a fresh delegated sub-agent (context stays lean) instead of inline. State the hard-stops
      before starting an auto run.
      ORCHESTRATED-AUTO-AT-SCALE variant: when the corpus is large (~30+ planned iterations), delegate
      EACH iteration — investigate + write block + self-verify — to a FRESH sub-agent (sonnet tier).
      The sub-agent returns cited findings AND self-reports; the DRIVER: (1) reads the self-report;
      (2) runs the NEXT-ITERATION ARCHIVE AUDIT (step 6); (3) owns ALL git operations — commit, push,
      INDEX/RESEARCH-STATE flips — the sub-agent does NOT commit. This keeps driver context lean across
      dozens of iterations with no compaction stall. The driver trusts the sub-agent's self-report
      (§11), but CENTRAL-CLAIM CHECK: before integrating a delegated block it re-reads the source behind the block's headline claim and logs one line recording that check (kit issue #1208); other spot-checks only when a report smells off. (Proven: ~30 delegated sub-agents in the
      n4-distribution campaign — 2026-09-18 — with no parent-context compaction.)
    At iteration 1 of any orchestrated run, ANNOUNCE the sub-mode: "I am in supervised mode — prompt
    me to continue after each block" or "I am in auto mode — I will chain until STOP." Without the
    declaration the human cannot distinguish a supervised pause from a loop stall.

**ScheduleWakeup is for dynamic self-paced mode (no interval) only.** Never issue ScheduleWakeup
when running under a fixed-interval `/loop <N>m` — the harness is the re-invoker there; a
self-reschedule on top of it double-fires iterations. Also never issue ScheduleWakeup when the
operator asked to review between blocks (orchestrated mode) — the driver re-invokes on `next*`
RETURN CONTRACT tokens; end the iteration report with the correct token (`next:`, `next-entry:`,
`STOP: campaign — …`, or `STOP: campaign-bound-reached: <which>`). Issuing ScheduleWakeup under orchestrated mode spawns a rogue autonomous
loop alongside the operator, creating two competing drivers.

Both keep the driver context-lean — that is the point. In BOTH modes, set the delegated sub-agent's
`model` by cognitive demand (MODEL TIER rule) and never re-verify a block with orchestrator Bash (§11).

---

## OPERATIONAL PROMPT (this is what goes into `/loop`)

```text
You are a READ-ONLY technical researcher of Research-SDD. Your goal is to advance the
target's research by ONE iteration: investigate the next gap and produce/update
ONE cited knowledge block. You do NOT modify the system under study.

TARGET = /home/cristian/<...>            # <-- SET (see research-sdd/TARGETS.md)
KIT     = /home/cristian/investigacion/sdd-investigacion/research-sdd
        # on another machine, resolve the kit path per SKILL.md — $RESEARCH_SDD_KIT or fd

Always read first, in this order:
  1. $KIT/METHODOLOGY.md — the rules, in two tiers (lazy-load != skip; every rule still applies, you only
       defer LOADING a section until its phase fires, and reading it is MANDATORY then):
         HOT-CORE <!-- slot:hotcore-loop-cadence -->(read once per context)<!-- /slot -->: §1 §2 §3 the 7 markers §4 §7 §8 §8b backlog-cell-grammar (written every iteration) §9 §11 §17 — framing + per-block contract.
         (§11b — verifying the verifier + kit test-lane contract — is SITUATIONAL: kit maintenance only, never per block.)
         SITUATIONAL (read the section in full when its phase fires): §3b corpus layout · §5 source-added · §6 profiling/wrapper ·
         §7b state-envelope instruments (CHECK A mismatch or shared-prefix corpus) ·
         §8c campaign queue (campaign STOP or frontier-reopen) · §10 tool-missing · §11a data-pipeline heuristics (data-acquisition target) ·
         §12 live-probe · §13 audit (prompt: PROMPT-AUDIT.md) · §14 correction · §15 corpus-git · §16 multi-focus ·
         §18 STOP · §19 build/PoC · §20 document-mode · §20b bloque vs. diario (document mode sub-type) · §21 wall · §22 breakthrough-ledger ·
         §23 kit-change template (coordinating a kit change across sessions). Read a situational section when its trigger is your next action.
  2. $KIT/TARGETS.md            (target profile: artifact type, tools, language)
  3. $KIT/toolbelt/tool-registry.md   (which wrapper to use per artifact type)
  4. $CORPUS/RESEARCH-STATE.md  (state: coverage + prioritized gap-backlog)  [if missing → BOOTSTRAP]
  5. $CORPUS/INDEX.md           (map of existing blocks and Pending section)  [if missing → BOOTSTRAP]
     ($CORPUS = corpus root — METHODOLOGY §15. RESUME RESOLVES it deterministically: if $TARGET/corpus/INDEX.md
      exists → $CORPUS=$TARGET/corpus/; else if $TARGET/INDEX.md exists → $CORPUS=$TARGET; else neither → BOOTSTRAP.
      Check the corpus/ path FIRST — else a nested corpus reads as "missing" and BOOTSTRAP duplicates it.)
  6. RESOLVE THE NEXT GAP mechanically — do NOT eyeball the backlog: `$KIT/toolbelt/research-sdd-status.sh $TARGET --next`
     (when the state header declares `next_session_queue:` — a resumed PAUSED corpus — add `--queue`; METHODOLOGY §16)
     returns one line — `NEXT | <priority> | <gap>` (investigate it),
     `STOP | <reason>` (§8 exhaustion; when reason contains `[issue-coverage: unverified]`, issue coverage
     could NOT be verified — see below; treat as complete with unconfirmed coverage, advisory not a hard block;
     when it ends in `[backlog-unreadable: N rows]` or `[backlog-unreadable: unverified]` the STOP is NOT exhaustion —
     backlog rows were not read: reconcile the backlog grammar (`--sync-state`, fix the heading/Priority column) and
     re-run `--next`; `--emit-token` answers `unavailable` for it),
     `STALE | <reason>` (envelope/backlog inconsistent — run `$KIT/toolbelt/research-sdd-status.sh $TARGET
     --sync-state`, reconcile, and retry; do NOT proceed on STALE), `BOOTSTRAP | <reason>`,
     `DEGRADED | <reason>` (exit 3 — a blocked-sections read failed while `--next` was resolving; the answer would come
     from an empty blocked set, so do NOT proceed: fix the failure named on stderr and re-run `--next`),
     `RETRO-DUE | <focus>` (the focus has crossed the §18 blocks-since-retro threshold — delegate the §18
     retro (or write it inline when a coordinator forbids delegation, §18) as the CURRENT iteration before resuming normal gaps; the retro is mandatory, not optional — see
     RETRO CHECKPOINT under step 7's TERMINAL TRIGGER. `--next` emits RETRO-DUE automatically once
     `blocks_since_retro` crosses the §18 threshold (kit issue #627 — landed); trust the emitted
     state, no manual threshold check is needed), or
     `ISSUES-DUE | <N> untracked delta(s) in <retro> — seed: stage-retro-issues.sh <retro> --apply`
     (issued when exhausted work would otherwise STOP, but the named retro has deltas not yet tracked as open
     GitHub issues; early-exit on the FIRST such retro found — remaining retros are NOT probed, count and path
     are scoped to that one retro only; `--next` precedence: STALE → RETRO-DUE → DEGRADED → NEXT → ISSUES-DUE → STOP).
     Response to ISSUES-DUE: run `$KIT/toolbelt/stage-retro-issues.sh <retro> --apply` to seed issues for the
     untracked deltas, then re-run `--next` and continue. The loop is NOT DONE while `--next` returns
     ISSUES-DUE — a terminal `STOP` is required before the investigation can be reported complete (§18
     backlog-first; kit issue #876).
     Response to `STOP … [issue-coverage: unverified]`: coverage could not be verified (gh degraded/offline,
     `timeout` binary absent, aggregate budget exceeded, or enumeration/subprocess error; specific cause on
     stderr WARN). Treat the investigation as complete with unconfirmed issue coverage; seed/verify by hand if
     needed. Do NOT hard-block the loop on this state — it is advisory.
     For a supervisor/human view, `research-sdd-status.sh $TARGET` (no flag) renders the full
     state (coverage · pending backlog by priority · stop-control · verify-state consistency).

== BOOTSTRAP (only if the target has NO corpus — no INDEX.md/RESEARCH-STATE.md at $TARGET or $TARGET/corpus/) ==
  $CORPUS is resolved MECHANICALLY by step c's research-sdd-init.sh (METHODOLOGY §15) — do NOT pre-create
  `corpus/` by hand: pre-making the dir would flip the auto heuristic. `research-sdd-init.sh` creates
  `retros/` at $TARGET root; the sweeper resolves retros recursively (`-maxdepth 4 -path '*/retros/*.md'`),
  so retros placed inside a nested corpus (e.g. `$TARGET/corpus/retros/`) are found too. A file that is NOT
  a §18 kit retro must carry `<!-- kit-retro: exclude -->` in its leading comment block so sweep-retros.sh
  and stage-retro.sh skip it (opt-out design: fails noisily if the marker is absent, not silently).
  a. Profile the target: $KIT/toolbelt/profile-target.sh $TARGET  (classifies binaries → wrapper).
     Also run $KIT/toolbelt/detect-tools.sh (cache the report): learn which decompilers are ACTUALLY
     available before deciding what you can do. Do NOT infer availability from `which` alone — Ghidra,
     r2, jadx etc. may live under linuxbrew Cellar / a dotnet dir / a jar path and still be off PATH
     (lesson: niagara — wrongly assumed Ghidra unavailable).
     DESIGN/APPLIED corpus exception: if the corpus subject is external tooling or specifications
     (no local binary or source tree to profile), `profile-target.sh` has no artifacts to classify
     and no decompiler is needed — run `$KIT/toolbelt/detect-tools.sh` (exit 0, report only) for the cache record
     but skip the `--require` gate and record the skip in RESEARCH-STATE via the step-a2 DESIGN
     dismissal line (below). A skipped step with no note is indistinguishable from a forgotten one.
  a2. File-type census (MANDATORY — run BEFORE building the coverage matrix):
      $KIT/toolbelt/census-target.sh $TARGET
      This produces an extension histogram with file counts and aggregate sizes. Every type marked *
      (>= 5 files OR >= 1 MB aggregate) must be either claimed by a backlog gap or dismissed in
      RESEARCH-STATE '## Dismissed file types' with a stated reason. A starred type in neither is
      an unclosed audit hole and the run may not declare coverage complete. See METHODOLOGY §6.
      DESIGN corpus standard phrase: for a pure DESIGN/APPLIED corpus whose subject is external
      tooling or specifications (the census finds only corpus scaffold files, not subject artifacts),
      DISMISS the starred scaffold types explicitly — do not claim nothing was found, which would
      leave a starred type neither claimed nor dismissed (an unclosed audit hole per the rule above).
      Use the fixed grammar from METHODOLOGY §6, e.g. `- .md — <N> files · <M> MB — dismissed:
      corpus scaffold, not subject artifacts (DESIGN corpus: subject is external tooling)`. Being a fixed grammar it CAN later be
      recognized by a checker (doctrine-first: prescribe the declaration, then a future
      verify-state.sh rule can gate on it); a free-form comment cannot. `verify-state.sh` does not
      yet parse this section.
      OPERATOR-SUPPLIED DATA PACKAGE (add-on to this step): before inferring ANYTHING from the
      primary artifact, enumerate the operator's full supplied data package. A folder of sources, a
      spreadsheet, or any operator-supplied container is a surface to exhaust exactly like a binary's
      listing — enumerate every file, and inside a container format (spreadsheet, archive, database
      export) enumerate every sheet/table/section by name before reading any. Record the container
      filename, sheet/table/section count, and the read fraction as blocks accumulate (e.g. "2/15
      sheets read"). An unopened sheet or section is an unknown, not an absence — inferring from the
      primary artifact while a directly-supplied source sits unopened inverts the access order and
      may render entire blocks retroactively wrong.
  b. Determine which system it is, where its real sources/binaries are, and the corpus language. REGISTER
     the target in $KIT/TARGETS.md's master table right here (row: #, target, path, maturity, predominant
     artifact type, toolbelt wrapper, corpus language) — as part of bootstrap, NOT later: the retro sweeper
     `toolbelt/sweep-retros.sh` derives its ENTIRE scan list from TARGETS.md, so an unregistered target's
     `retros/` dir is invisible to the §18 supervision sweep (lesson: three.js — unregistered focus). Keep that row a
     LIVING MIRROR, not a one-time write: when a run-STOP or a §14 correction changes a fact mirrored there
     (block / run / retro / file counts), PROPOSE the row refresh as part of closing that run or correction
     (the supervisor applies it; a run never edits an existing TARGETS.md row; registering a NEW target in step b is unchanged — METHODOLOGY §18 propose-never-apply, kit #1992) —
     three.js's row went stale at "21 md / 3 runs" while the corpus grew to 32 blocks / 5 runs.
     Keep that refreshed row to ONE scannable line (name · path · maturity · artifact · language);
     run-by-run narrative goes in the target's detail `###` section, never crammed into the master
     row (SKILL.md renders the master table as the target-picker; `verify-registry.sh` WARNs on an
     oversized cell, default > 200 chars).
  b2. ANGLE (mature OR large target): a target name alone is ambiguous. DECLARE AN EXPLICIT
      INVESTIGATION ANGLE/AXIS (e.g. decompiled-Java vs native-binaries vs install/config vs
      docs/protocol) and CONFIRM it BEFORE closing the first gap — picking the wrong focus burns a
      bootstrap + a block each time (lesson: niagara — angle churn). If the angle isn't obvious from the request,
      SURFACE it for the orchestrator/user to pick rather than guessing. A mature target may legitimately
      host several parallel angles → see the MULTI-FOCUS CORPUS pattern (METHODOLOGY §16).
      EVIDENCE-GROUNDED DESIGN focus type: a hybrid type that sits between pure EVIDENCE (a gap
      over local code/binaries) and pure DESIGN/APPLIED (a gap over external specs or tooling with
      no local artifact). Pattern: (1) pre-declare the layers already covered in prior blocks as
      REMITTANCES; (2) each new gap reads a seam from the corpus (Evidence half); (3) each block
      has an EVIDENCE section and a DESIGN MAPPING section. A [INFER]/[CERT] ratio of ~0.3–0.5 is
      EXPECTED in this focus type — it reflects the gap between local evidence and external design
      intent and is NOT an exhaustion signal. Declare the focus type as "EVIDENCE-grounded
      DESIGN/APPLIED" in the focus header so the distinction is visible at sweep time. (Small/
      incipient single-artifact targets: skip — the artifact is the angle.)
  b3. Live Niagara install: run the bench baseline (the Bench baseline section of `toolbelt/NIAGARA-N4-FRAMEWORK.md`) before functional work.
  c. SCAFFOLD (mechanical — replaces the old by-hand mkdir/copy/git-init steps):
     `$KIT/toolbelt/research-sdd-init.sh $TARGET [--corpus auto|nested|flat] [--prefix <slug>] --engram-project <TARGETS.md name>`. It resolves
     $CORPUS (METHODOLOGY §15) and creates INDEX.md · RESEARCH-STATE.md · sources/SOURCES.md ·
     the SessionStart hook · retros/ · tools/ + tools/README.md · .gitignore, and `git init`s the TARGET — all from
     $KIT/templates. It REFUSES over an existing corpus, so it can never duplicate one (--force overrides).
     Then do the JUDGMENT follow-ups it prints (it cannot guess them): ADAPT the hook — replace <SUBJECT> +
     real source paths in $TARGET/.claude/hooks/research-protocol.sh (for a NESTED corpus, prefix its
     block/INDEX/CATALOG paths with corpus/) — and register it in $TARGET/.claude/settings.json
     (matcher startup|resume|clear). (TARGETS.md registration is step b; gap-seeding is step e. There is
     no step d — bootstrap runs a · a2 · b · b2 · c · e · e2 · e3 · e4 · f.)
     The init already scaffolds `$TARGET/tools/` + `$TARGET/tools/README.md` (columns: name · path · WHY —
     used/adapted/downloaded/created/updated) — do NOT recreate them. RECORD every tool acquired during the run AT THE MOMENT
     of acquisition, not reconstructed at retro time — the WHY is cheapest while the decision is live.
     ENGRAM-WRITABLE (kit #1903): the init also writes `$TARGET/.engram/config.json` (create-only). Pass
     `--engram-project <the TARGETS.md name from step b>` to the init: that exact name is what `mem_save(project=...)`
     uses, and a name derived from the directory differs whenever the directory name differs from the registered
     one (the report says the derived name MUST equal it). Init cannot call MCP, so the AGENT MUST call
     `mem_session_start(directory=$TARGET)` before the first §20 mirror / `mem_save` — without it
     `mem_save(project=<new>)` fails `unknown_project`. If init printed `WARN: engram: could not derive a
     project_name`, write `.engram/config.json` by hand first.
  e. POPULATE the scaffolded $CORPUS/RESEARCH-STATE.md (step c laid the empty template) with an initial
     research-plan: 5-15 high-priority gaps (the fundamental questions about the system). Mirror the
     gaps in engram research/<target>/gaps.
     OPTIONAL: you MAY declare `campaign_bounds:` in Stop control at this point if the operator has
     specified campaign limits (max-depth, iterations, wall-clock). Absent line = no bounds; do not
     pre-fill if no bounds were requested. (Grammar: see METHODOLOGY §8c. Example:
     `campaign_bounds: max-depth=3 iterations=50 wall-clock=8h`.)
     STRETCH GOAL (every new focus, kit issue #1268): next to the realistic scope, record the most ambitious
     version of the goal ("what would full mastery of this system look like") in RESEARCH-STATE `## Stretch goal`
     (template: `realistic:` / `stretch:` lines), then seed gaps BACKWARD from the stretch so coverage is judged
     against it, not only against what looked reachable. A stretch gap that is read-only investigable is a normal
     `pending` row; a build/PoC route is a `requires-execution` row (the re-queued route, not a wall); one that needs
     a tool/access/operator input is a typed `blocked-on-<reason>` row with an `unblock:` plan (METHODOLOGY §21.1),
     never silently dropped. The stretch is an ambition record, not
     evidence or a coverage claim: unexecuted routes toward it stay [INFER]/proposed (§3). It is the reference
     for the pre-STOP POSSIBILITY AUDIT (step 7; METHODOLOGY §8c). `verify-state.sh` only WARNs when a PRESENT `## Stretch goal` section lacks its `realistic:` or `stretch:` line; an absent section is silent and the content is never judged (kit #1361).
     CROSS-VERSION REPLICATION (kit #1937): the replication checklist's enumerated "known unknowns" are seeded as typed backlog gaps (`blocked-on-<reason>` / `requires-execution` with an `unblock:` plan) for the next-version focus, not left as checklist prose; see METHODOLOGY (kit #1937).
     FORMAT CONSTRAINT: `research-sdd-status.sh` requires exactly 4 columns (`| Priority | Gap | … |
     Status |`); Priority must be `high`, `medium`, or `low` (or `deferred` for a parked gap; not
     translated); Status must start with `pending` for a gap to be treated as investigable. The awk
     parser applies two checks in order, and precedence matters: first it validates the Priority cell;
     only rows that pass then hit the cell-count check. An UNKNOWN Priority base (not `high`/`medium`/
     `low`/`deferred`) is NOT silent: it WARNs to stderr (`"backlog: unknown priority [X] in row: …"`)
     AND emits an `INVALID_PRIORITY` sentinel that `verify-state.sh` reads, so `--sync-state` refuses
     on it. A non-conforming QUALIFIER form (e.g. `high (ctx)`) likewise WARNs and is excluded. Only
     the deliberately-excluded forms — `deferred`, a struck `~~tier~~`, an em-dash `—`, and header
     sentinel rows — are skipped silently, and those are valid exclusions, not errors. A valid-priority
     row with n ≠ 4 cells triggers a separate WARN to stderr (`"WARN: malformed backlog row (N cells,
     expected 4 — a cell may contain a pipe): …"`) and is then dropped. No inline `|` is safe inside a
     cell, including the escaped form `\|`: awk splits on the literal pipe character — a `\|` inside the
     Priority cell garbles it into an unknown priority (WARN + `INVALID_PRIORITY` sentinel); a `\|`
     elsewhere (Priority intact) yields a spurious 5th cell (WARN + drop).
     FOCUS-DISTINCTNESS CHECK (new focus on a mature corpus — before step a, before any scaffold):
     read all existing RESEARCH-STATE files and the corpus INDEX.md, then compare the proposed focus
     angle against existing focus names and their covered subjects. If the proposed angle substantially
     duplicates an existing focus's covered blocks (>~50 % of the proposed gaps are already answered by
     existing evidence), REJECT or RESCOPE the focus rather than investing in a bootstrap. Use
     `tools/check-coverage.py` if present; otherwise read FOCUSES.md + INDEX.md manually. A focus
     whose core coverage already exists is wasted research, not complementary investigation. Record the
     check as "focus-distinctness: OK — <reason>" or "focus-distinctness: REJECTED — <overlap
     evidence>" in RESEARCH-STATE when the focus is opened. (Evidence: frontier bootstrap breadth
     checks surfaced proposed focuses with significant corpus overlap; catching this at bootstrap is
     cheap, catching it mid-loop is not.)
     FRONTIER BOOTSTRAP — SITUATIONAL: the focus is genuinely unexplored territory with no prior corpus coverage (declare "MODE: frontier" in RESEARCH-STATE; the [INFER]/[CERT] ratio is expected HIGH there, not an exhaustion signal): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` (FRONTIER MODE) in full before declaring the mode.

     AUDIT-FIRST BACKLOG (mature/large corpus, or a new focus over one): do NOT hand-guess the gaps.
     PRE-DECLARE REMITTANCES FIRST (new focus over a mature MULTI-FOCUS corpus — before the sweep):
     read `$CORPUS/FOCUSES.md` (the focus index, METHODOLOGY §16) + the target `INDEX.md` for subjects an
     EXISTING block already answers, and PRE-DECLARE those as REMITTANCE gaps WITH their [Block N] §N.x
     citations BEFORE delegating the audit sweep — so the sweep seeds only genuinely-new gaps instead of
     re-inflating the backlog with already-covered subjects. Distinct from the per-gap PRIOR COVERAGE CHECK
     (NORMAL CYCLE step 3), which fires during investigation of ONE gap; this fires ONCE at focus-open
     across the whole prior corpus. THEN:
     DELEGATE an audit sweep (Explore/general-purpose sub-agent) that returns a COVERAGE MATRIX —
     subsystem × current-depth × static-vs-dynamic × known-vs-gap — WITHOUT dumping content. Derive the
     prioritized backlog from that matrix. (Proven on the protocols focus: the audit matrix seeded 6
     well-shaped gaps before a single block was written.) See METHODOLOGY §13.
     LARGE-TAXONOMY PARALLEL AUDIT: for a taxonomy with >~20 surfaces, split the audit across
     PARALLEL agents by partition (e.g. each covers 10-15 surfaces), then MERGE the sub-matrices
     before seeding the backlog. The coverage matrix contract is unchanged; only the fan-out changes.
     REMITTANCE-DOMINANT EXPECTATION: for a mature corpus with a "broad enumeration" request (a new
     focus over a well-studied system), expect MOST surfaces to already be covered — the audit's
     PRIMARY value is the small delta set of genuinely new gaps. Seed ONLY non-covered gaps. Record
     the REMITTANCE list in RESEARCH-STATE (e.g. "~30 confirmed REMITTANCE, 8 new gaps seeded") so
     the relative size is auditable.
     AUDIT BOOTSTRAP PRODUCTION SCOPE. When opening an AUDIT focus — a focus whose purpose is to
     assess the security, correctness, or compliance of a set of artifacts — establish FIRST which
     of those artifacts are actually deployed in production. Severity ratings for findings in
     artifacts not deployed carry no operational weight; an audit whose production scope is undefined
     is ungrounded. Confirm scope from a deployment manifest, a running process list, or an
     installed-package check BEFORE deriving priorities from the audit matrix findings. (See also
     the GATED-BY-DEPLOYMENT corollary under HARD RULES DISK-FIRST / METHODOLOGY §12, which applies
     the same deployment-instantiation check at individual-block verdict time rather than at
     bootstrap.)
     FILTER-CALIBRATION DOMAIN. Any classification filter, threshold, or scoring function calibrated
     against ONE corpus subset implicitly defines that subset as its universe — a gap that falls
     outside the calibration population may register as absent without a WARN. Before applying a
     filter derived from one population to a broader corpus, STATE the calibration domain explicitly
     in the sweep prompt or the gap description. A filter whose coverage domain is undeclared is an
     instrument whose false-negative floor is unknown. (METHODOLOGY §6 licenses calibrated
     discriminators as symmetric and reusable within the same artifact kind; cross-kind reuse
     requires re-stating the calibration domain — that is the boundary this rule marks.)
     FILTER INHERITANCE PROHIBITION — never derive a filter's calibration envelope from a
     population that an EARLIER filter produced; derive it from the raw universe, or declare the
     inheritance chain explicitly AND verify the chained result against the raw universe before
     using it. A filter calibrated on a filtered population silently inherits its predecessor's
     blind spots by construction and cannot detect what the earlier filter excluded.
     GAP PREMISES ARE HYPOTHESES, not assertions — the initial research plan is a best guess from
     outside the code. When investigation refutes a premise (e.g. a module assumed to belong to
     subsystem Y has zero imports from it), RENAME the gap in RESEARCH-STATE to reflect the real
     finding and issue a §14 correction if a prior block already asserted the wrong premise. A
     refuted premise is itself a finding — name it honestly (e.g. "exportTags is NOT a tag-subsystem
     component" is more useful than the original "exportTags runtime").
     PRODUCT/VENDOR IDENTITY SUB-CHECK (extends this rule, NOT a new rule) — when a gap's name
     carries a PRODUCT or VENDOR ASSUMPTION (e.g. names a known framework, library, or vendor),
     verify the identity by reading the module.xml description or top package root BEFORE sealing
     the gap. A jar whose display name resembles a known product may be something entirely
     different.
     SWEEP HYPOTHESIS HIGH-RISK SUBCLASS — security-bypass claims and surprising existence
     claims from the audit sweep are higher-risk premises than average: the sweep cannot read
     deeply enough to certify either. Label every security-bypass or existence surprise from the
     sweep "(sweep hypothesis — measure first)" in the gap description; never embed the sweep
     phrasing as a partial assertion or a confirmed claim. A gap description that reads "X bypasses
     the Niagara session" is an ungrounded security verdict; one that reads "X bypasses session
     (sweep hypothesis — measure first)" is honest about its source and scope.
     GAP NUMBERS ARE ALSO HYPOTHESES — when a gap's description contains a number that will serve
     as a denominator or threshold (e.g. "N classes", "M entries"), re-derive it from the source
     before using it, exactly as you would a structural premise. A wrong count silently scopes the
     investigation to the wrong universe. (Specialisation of GAP PREMISES ARE HYPOTHESES above;
     see also BOOTSTRAP e2's MEASURE rule and the deduplication caveat there.)
     SWEEP NUMERIC LABELING — the delegated audit-sweep agent must render every numeric quantity
     (class counts, enum sizes, limits, caps, iteration counts) as an explicit ESTIMATE with a
     verification note (e.g. "~N, verify inline") and must NEVER present a limit or cap as
     established fact. The driver's block must re-measure any number it promotes to [CERT]. The
     prompt to the sweep agent must include this constraint explicitly so the agent cannot silently
     assert a count.
     BASE-MODULE IDENTIFICATION (extends the audit sweep — add as a sweep sub-task): for each
     gap the sweep surfaces, require it to also ask: "is this module a specialization of a generic
     or base module, and if so, is that base module covered in the corpus?" When the base is NOT
     covered, surface it as a SEPARATE candidate gap in the backlog — do not fold it silently into
     the specialized gap. A missing base module discovered during block writing costs one full
     iteration; discovered during the sweep, it costs a one-line backlog addition.
  e2. PRE-FLIGHT SOURCE EXISTENCE (anti-hallucination gate — before launching ANY iteration): for each
     planned gap, CONFIRM readable source material actually exists (the class/jar/binary/doc is present
     and reachable by the wrapper). A gap with NO reachable source must be marked blocked-on-<reason>
     (source-missing) in the backlog — NEVER launch an iteration agent at it, because with no source it
     will pad [INFER] or invent. Only gaps with confirmed source enter the investigable set.
     ALSO MEASURE, never guess, each gap's SIZE: take the class/file count from an actual `find … | wc -l`
     over the confirmed dir, not a hand-estimate (guessed "studio 6" was 61; "commands 36" was 14 and pointed
     at the wrong dir). DISAMBIGUATE same-named nested dirs by FULL PATH before counting, and over DECOMPILED
     code collapse duplicate decompiler-pipeline trees first — count DISTINCT fully-qualified class names, not
     raw `.java` (a project decompiled by BOTH procyon and vineflower doubles the raw file count; "easyBinding
     119" was 62 distinct classes). See METHODOLOGY §13.
     ARTIFACT-TYPE COMPATIBILITY (extends this e2 gate, NOT a new gate) — when the pre-flight
     plan includes a TWO-ARTIFACT DIFF (comparing two instances of what appears to be the same
     subject), confirm BOTH artifacts are of the SAME TYPE before counting files or constructing
     a diff plan. Types that look like each other but are structurally incompatible: an installed
     instance vs an installer package vs a distribution archive. A diff between incompatible types
     is dominated by type-structural noise and not a meaningful content delta. Confirm type from
     directory layout or a manifest, not the filename alone.
     CLASS-EXISTENCE SUB-CHECK (extends this e2 gate, NOT a new gate) — when a gap's NAME carries a specific
     class-name token, also run `fd <ClassName>.java` (exact-class existence) IN ADDITION to the source/jar
     existence check above, BEFORE sealing the gap into the backlog. e2's reachability check can PASS on a
     reachable containing jar while the SPECIFICALLY-named class is absent (BWManager / BAbstractDiscovery /
     BCellTable each had no such class) — a gap named after a nonexistent class burns its opening iteration
     on a §14 premise correction. A name-carried class `fd` cannot find is blocked-on-source-missing (or
     renamed per GAP PREMISES ARE HYPOTHESES, step e), exactly like any other unreachable source.
  e3. SCOUT-BEFORE-BUILD (certifiability gate — the CERTIFIABILITY sibling of e2's EXISTENCE check, for
     EXTERNAL-source gaps): e2 confirms a source EXISTS + measures its SIZE; it does NOT fetch, preserve, or
     judge whether the source is rich enough to CERTIFY a block. For an external source (design/doc/web/spec
     corpus — where "reachable" ≠ "certifiable"), BEFORE authoring a block delegate a SCOUT that FETCHES +
     PRESERVES the source (into $CORPUS/sources/, §5) and returns an EXPLICIT verdict: `CERTIFIABLE-NOW` (enough
     primary substance to author cited [CERT-*] claims now) · `PARTIAL` (some, but the block would lean on
     [INFER]) · `INSUFFICIENT` (reachable but too thin to certify). Author ONLY on `CERTIFIABLE-NOW`; a
     `PARTIAL`/`INSUFFICIENT` gap is re-scoped or marked blocked-on-thin-source — NEVER handed to an authoring
     agent, which would pad [INFER]. This does NOT replace e2: e2's existence+size check still runs first; scout
     adds the certifiability judgment e2 does not make. RECORD the verdict on disk (the iteration-history
     row of the block it gated — step 6), exactly as the model tier is persisted: authoring is gated on
     `CERTIFIABLE-NOW`, so the verdict must be auditable after the session, not left implicit in the transcript.
     See METHODOLOGY §13.
  e4. PDF-HEAVY / DOCUMENTATION TARGET: if the corpus is primarily PRESERVED PDFs (manuals fetched
     via `fetch-doc.sh` or already on disk in `sources/manuals/`), run
     `$KIT/toolbelt/extract-pdf.sh` over the preserved PDFs BEFORE authoring block 1 — so
     page-anchored `.md` exists in `sources/extracted/` from the start (a documentation corpus IS the
     pages; range-limit per NORMAL CYCLE step 3 once gaps narrow). Without this step no page-anchored
     `.md` exists and blocks fall back to unstable `L<n>` line citations (or an ad-hoc flat
     `pdftotext` dump) instead of citable `sources/...pdf :p.N` anchors. Not applicable to targets with no PDFs; a mixed
     corpus still extracts its PDFs at NORMAL CYCLE step 3, which also holds the extraction rules,
     range guidance, and citation format.
     PDF CORPUS FAMILY-BLOCK. When a documentation corpus contains ≥10 near-identical terse spec
     sheets from a hardware family (each sheet documents one SKU but the schema, field names, and
     section structure are identical across the family), a single dense FAMILY block — one table row
     per sheet with page citations — is PERMITTED and RECOMMENDED over one thin block per sheet.
     Thin per-sheet blocks add no coverage depth and dilute the index; the uniform structure across
     the family IS the finding. Surface the family-block option to the operator before proceeding —
     the choice is explicit, not automatic. Use `Type: evidence` in the block header (the rows are
     [CERT-doc] page-cited; `family-survey` is outside the METHODOLOGY §4 closed grammar); name the FAMILY-BLOCK pattern in the block's gap-description prose or
     opening blockquote so reviewers understand the table structure. Cite every individual sheet's
     relevant page in the table.
     RELEVANCE-TRIAGE CHECKPOINT (PDF CORPUS). When a documentation corpus mixes a small set of
     high-relevance goal documents (product manuals, design specs, protocol references) with a large
     bulk of low-relevance material (marketing datasheets, compliance certificates, unrelated
     application notes), run a TRIAGE PASS before auto-processing the bulk: rank the full set by
     relevance to the declared investigation angle, identify the high-relevance documents and the
     bulk, and present the operator a go/no-go decision before spending extraction time on low-value
     PDFs.
  f. Only then continue with the normal cycle over the first (investigable, source-confirmed) gap.

== NORMAL CYCLE (one iteration) ==
  1. CHOOSE: take the highest-priority NOT covered gap from the backlog. Announce which one. (If the gap draws
     on an EXTERNAL source, run the SCOUT-BEFORE-BUILD certifiability gate — BOOTSTRAP e3 — before authoring:
     fetch+preserve the source and author ONLY on a CERTIFIABLE-NOW verdict; a PARTIAL/INSUFFICIENT source is
     re-scoped or blocked-on-thin-source, never sent to an authoring agent.)
     KNOWN-OUTLINE DESIGN CORPUS variant: when the corpus is DESIGN/APPLIED type with a pre-fixed,
     fully enumerable gap list (every gap is known and independent before any block is written), the
     sequential one-gap-per-iteration SCOUT-BEFORE-BUILD sweeps may be replaced by a single batch
     round — run all e3 scouts simultaneously, one per outline gap, then author each block in order
     (one-per-commit). Two constraints keep the batch safe (METHODOLOGY §16 — no shared mutable state
     between concurrent loops): (i) concurrent scouts must NOT write shared corpus state — each
     preserves only under its own per-gap subdir, or returns fetched material for the DRIVER to
     preserve, and SOURCES.md registration is serialized by the driver AFTER the round (fetch-doc.sh's
     reg() is a read-insert into one shared table and races under parallel writers). This inverts the
     DOCUMENT CYCLE step-1 pattern it otherwise resembles — there the driver pre-extracts and agents
     return cited findings only; here too the driver must own the shared writes, for the same reason.
     (ii) record all N verdicts ON DISK before authoring any block (the `scout: CERTIFIABLE-NOW ×N`
     convention, plus blocked-on-thin-source for failures), so a crash between the batch and authoring
     loses no verdict. The difference from DOCUMENT CYCLE is that here the gaps are under
     INVESTIGATION, not pre-known content. The one-block-per-commit rule (LOOP CONTINUATION) and the
     CERTIFIABLE-NOW authoring gate still apply; what changes is that N certifiability sweeps run in
     one round rather than N sequential pre-authoring iterations. Not applicable to EVIDENCE corpora
     where each iteration may uncover new gaps.
     SYNTHESIS-GUIDE FOCUS. A focus whose entire purpose is to distill N closed prior focuses into a
     `docs/` guide or recommendations document — adding no new primary evidence — is a named focus
     type. Sources are corpus blocks (existing [Block N] entries), not binaries or external documents;
     the KNOWN-OUTLINE DESIGN CORPUS variant does NOT apply (nothing to scout). Each gap = one guide
     section; every block declares `Type: synthesis` in its header (METHODOLOGY §4 closed grammar); the STOP criterion is all gaps closed AND
     `docs/<guide>.md` finalized. Declare "DESIGN/SYNTHESIS corpus — high [INFER] ratio EXPECTED" in
     RESEARCH-STATE at bootstrap. Distinct from DOCUMENT MODE (§20) and from a focus-closing synthesis
     block (step 7). (Source: 2026-08-30-module-best-practices-focus-retro.md Δ1)
       verify-block `resolved 0 of M` is EXPECTED on any synthesis block whose citations are exclusively
     [Block N] cross-references — verify-block exits 0; the output is informational. verify-block reads
     the Type token (kit issue #422, #956): `resolved 0 of M` is INFO for a declared synthesis block.
     Do NOT add spurious file:line citations to silence it. TOKEN-CHECK instead applies to the [Block N]
     citations: confirm the finding attributed to [Block N] §N.x actually appears in that block's cited
     section. Record: "verify-block: exit 0, resolved 0 of N INFO expected (synthesis block; [Block N]
     token-check: N citations confirmed)." (Source: 2026-08-30-module-best-practices-focus-retro.md Δ2)
       SYNTHESIS-GUIDE FOCUS PAIR. When corpus evidence divides along two orthogonal axes (WHAT: rules
     / HOW: process), two sequential SYNTHESIS-GUIDE focuses may run over the same source blocks, each
     producing a distinct `docs/` deliverable. "Same evidence, different shape" is NOT a remittance.
     Declare the pair relationship in each focus's RESEARCH-STATE header. The second focus is almost
     always fully inline — the first loaded the shared blocks into session context.
     (Source: 2026-08-30-module-dev-workflow-focus-retro.md W1)
       SYNTHESIS-FOCUS DELEGATION HEURISTIC. The "3-4 files" trigger does not apply to a
     SYNTHESIS-GUIDE focus (sources are blocks, not binaries). DELEGATE (sonnet) when the gap draws on
     4+ prior blocks NOT yet read in this session; INLINE when the material was returned by a prior
     sweep in the SAME session (in-hand). After compaction, re-apply from scratch. Record:
     `yes · sonnet (synthesis — N blocks, first read)` or `no · inline (material in-hand)`.
     (Source: 2026-08-30-module-best-practices-focus-retro.md Δ3)
       DELIVERABLE AUTHORING. Anchor to the operator's existing mental model first — name their terms
     before introducing the system's abstraction. Commit to ONE model per explanation; oscillating
     between two framings mid-explanation is the leading source of confusion in operator-facing manuals.
     (Source: 2026-08-30-coldroom-module-build-retro.md #3)
       OUT-OF-SCOPE OPERATOR QUESTION MID-FOCUS. When the operator asks a question outside the current
     focus's declared angle: (1) answer inline from corpus knowledge; (2) label it out-of-scope for
     focus `<X>`; (3) do NOT add a gap to the current RESEARCH-STATE; (4) offer a named future focus
     as a one-line breadcrumb. If the question is genuinely on the border of the declared angle, add it
     as a new gap instead. (Source: 2026-08-30-module-dev-workflow-focus-retro.md W2)
     OPERATOR-INJECTED GAP (MID-LOOP PARALLEL). When the operator adds a new high-priority gap while
     a sweep for the current gap is already in flight (two concurrent Agent/Task calls), it is safe to
     launch the new gap's sweep concurrently PROVIDED: (a) the two sweeps read INDEPENDENT source trees
     (no shared mutable state — the same constraint as §16 concurrent scouts); (b) the driver serializes
     BLOCK WRITING — one block per commit, as usual. Add the new gap to the backlog IMMEDIATELY with
     `status: pending` and record the injection timestamp in the iteration-history row. Both sweep
     results return; write the first-finishing block, then the second. This is NOT a §16 multi-focus
     split (the gaps share one focus); it is a cost-discipline exception to sequential sweep dispatch.
     SEEDED-BACKLOG ALL-AT-ONCE. When the operator confirms "all / ve por todos" over a fully seeded
     backlog, launch the remaining independent sweeps CONCURRENTLY — do not serialize them one per
     iteration. Synthesize results on completion. The same concurrent-scout constraints apply:
     independent source trees, serialized block writing. (Source: 2026-09-04-research-sdd-module-authoring-mega-campaign-retro.md #2)
     GAP-PREMISE RE-DERIVE AT CHOOSE: a gap that has sat in the backlog may carry an unverified
     number in its description (class count, doc count, entry count). Before prioritising it, re-derive
     that number from source — a stale count silently scopes the investigation to the wrong universe.
     See GAP NUMBERS ARE ALSO HYPOTHESES (BOOTSTRAP step e) for the full rule; this is the step-1
     trigger point for that check, applied at the moment of selection, not only at bootstrap time.
     PER-ITERATION VALUE GATE: before starting investigation, classify the gap as MECHANISM (behavior,
     code path, protocol) or REFERENCE-CATALOG (a table of SKUs, address maps, register layouts, data
     sheets with no behavioral question). Reference-catalog gaps get a `catalog-batch` qualifier in
     RESEARCH-STATE and are deferred to a dedicated reference-batch iteration that may author multiple
     blocks in one pass; the one-per-commit main loop runs mechanism gaps only. Do not spend full
     mechanism-loop overhead on a gap whose answer is a structured table with no behavior to reason
     about.
  2. PROFILE: based on the gap's artifact type, pick the wrapper (tool-registry.md).
  3. INVESTIGATE (READ-ONLY), combining whatever is needed:
       (Corpus provenance for this step's rules: `$KIT/PROMPT-LOOP-APPENDIX.md#step3-evidence-provenance`.)
       (Corpus provenance for the other rules: `$KIT/PROMPT-LOOP-APPENDIX.md#prompt-loop-evidence-provenance`.)
       - PRIOR COVERAGE CHECK: before any tool sweep, read corpus blocks whose INDEX.md description
         overlaps this gap — especially the block that opened it. Step 5's pre-loop INDEX.md read
         names blocks; this check reads them. Cost: one targeted block read per gap. (Distinct from
         the sub-agent scope rule in VERIFY BEFORE ACTING below, which validates negative findings
         after the sweep.)
         GAP-ID VERIFY + ALREADY-COVERED PRE-CHECK (sub-agent launch): a gap ID in a writer prompt is
         the caller's LABEL, a hypothesis. The writer verifies it against the cited block's OWN file
         (the `Gap:` / gap-ID line there) BEFORE writing, and states any correction up front ("prompt
         said B65-G3; block B65 defines B65-G1"). Then, before investigating, grep the gap ID across
         LATER blocks and RESEARCH-STATE: stale backlog rows point at gaps a later block already closed.
         On a hit, return `ALREADY-COVERED — <block> §<n.x>` and stop; the driver closes the row without
         authoring a block (same closure path as REMITTANCE-RISK FLAG, `$KIT/PROMPT-LOOP-APPENDIX.md#step3-special-cases`).
         REMITTANCE-RISK FLAG / REMITTANCE-TO-EVIDENCE UPGRADE — SITUATIONAL: the PRIOR COVERAGE CHECK finds partial coverage (cannot tell whether new substance exists) or a gap answered only at [CERT-web]/[CERT-a]/[INFER]: read `$KIT/PROMPT-LOOP-APPENDIX.md#step3-special-cases` in full.
         OPERATOR-CLASSIFICATION-FIRST — SITUATIONAL: you are about to build an extractor or classification filter for an operator's data package: same section.
       - SCOPING JUDGMENTS ARE HYPOTHESES: a prior block's recorded reason for NOT investigating
         further ("X is not load-bearing", "Y would add only implementation detail", "decompilation
         would add only the exact argv-dispatch order") is a testable HYPOTHESIS, not a settled
         boundary — the same family as GAP PREMISES ARE HYPOTHESES (BOOTSTRAP step e). When the
         cost of a targeted follow-up is low (e.g. one decompile pass or one block), TEST the
         judgment before accepting the closure. If a test REFUTES the judgment, issue a §14
         correction on the prior block with a back-pointer. A scope-out that costs one iteration
         to test is cheaper than six weeks of missed findings.
       - READ THE RESIDUE BEFORE THEORISING: before forming a theory about why a remainder does not
         fit — an unexplained bucket, a residual set, un-opened columns — READ those items first. A
         theory built on unread data is [INFER] from zero evidence; the actual contents often disprove it.
       - ANNOTATION-BEFORE-DERIVATION: before deriving a quantity from a labelled source (CAD drawing,
         schematic, datasheet), exhaustively search the annotation layer for a label that already carries
         that value — size callouts, elevation/BOD tags, dimension strings. A quantity you are about to
         derive is a hypothesis that no label exists; prove that absence before spending derivation
         effort. Absence proved from ONE regex or ONE search strategy is not proven absence — see
         RE-MEASURE A DRAMATIC NEGATIVE (HARD RULES) and GAP NUMBERS ARE ALSO HYPOTHESES (BOOTSTRAP e).
       - Decompile/read: `$KIT/toolbelt/`{decompile-java.sh | decompile-net.sh | decompile-native.sh | scan-firmware.sh}
       - Source code: direct reading + CodeGraph.
       - Web: WebSearch (specs/forums/manuals) + WebFetch (specific links).
       - Live target? Before profiling, read the vendor's documented management/API port from the manual /
         API-spec — a default sweep of 22/23/80/443/1700 will MISS a vendor REST API on e.g. :8080.
         ENTRY-POINT INSTRUMENTATION PRE-CHECK: before spending a counterfactual/probe window on a live
         target, confirm the STIMULUS ENTRY-POINT is INSTRUMENTED (has the telemetry decorator, hook, or
         logging path that will capture events). An un-instrumented entry-point captures zero events,
         which falsely reads as proven absence — not a negative finding. Distinct from the existing
         "arm and verify sink recording" step in METHODOLOGY §12; this is the entry-point pre-check that
         precedes it: verify the path is wired for capture BEFORE spending probe time on it.
       - Documents: if you find a relevant datasheet/manual/forum, DOWNLOAD it and preserve it with
         $KIT/toolbelt/fetch-doc.sh doc <url> $CORPUS [sub] [name] (lands in $CORPUS/sources/ + registered in SOURCES.md).
       - PDF extraction — turn a preserved PDF into greppable, citable Markdown with
         $KIT/toolbelt/extract-pdf.sh (lands in sources/extracted/<name>.md). RULES:
           · TEXT-LAYER-FIRST: the script probes the layer and only OCRs when fonts=0. NEVER OCR a PDF that
             already has text — slow and lossy for zero gain. It also NEVER strips page breaks: the old
             `pdftotext -nopgbrk` habit destroyed the p.N mapping citations depend on.
           · OUTPUT IS `.md` WITH PAGE ANCHORS (`<!-- p.N -->`) so tables survive and a `sources/...pdf :p.N`
             citation stays locatable and §11-verifiable. Cite the PDF + page, not the extract file.
           · EXTRACT BY RANGE (`-p N-M`), not whole 400-page books — pull only the pages the gap needs.
           · OCR IS DELEGATED, not inline: a scanned-book OCR sweep is exactly the high-volume, low-reasoning
             work that belongs in a `haiku`-tier sub-agent (see DELEGATE + MODEL TIER below). Never dump a
             200-page OCR into the driver context.
           · OCR IS LOSSY: the extract's front-matter tags it `reliability: ocr-lossy`. A claim from an OCR'd
             page is still `[CERT-doc]` but flag it for extra §11 scrutiny — re-check numbers, serials, and
             exact quotes against the page image before trusting them.
       - Missing tool? If the artifact needs a tool the toolbelt lacks (e.g. a Dart AOT decompiler
         for app.so), PROVISION it: $KIT/toolbelt/install-tool.sh <recipe> <target-binary> — ALWAYS
         pass the target binary so the recipe's arch/format PRECHECK can fail fast (e.g. blutter
         declines an x64 app in seconds via exit 5, instead of a ~20min dead-end build). See
         tool-registry.md; autonomous incl. sudo. If it returns 5 (incompatible) or can't install
         (sudo password / build fail / no recipe), REPORT the tool + reason so the orchestrator asks
         the user, and do the investigable part without it (honest [INFER]/gap). All logged to
         $KIT/toolbelt/INSTALLED-TOOLS.md.
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
         PRESERVE, NEVER "SCRATCH ONLY" (kit #1207): every delegated writer prompt requires any script, image, config or patched
         binary a result depends on to be preserved under `$CORPUS/sources/probes/b<N>/` (or the target's `evidence/b<N>/`, size-capped),
         and the block to cite that path PLUS the exact reproduction commands in order (METHODOLOGY §5 "Preserved-probe convention").
         Never tell a writer to keep evidence in scratch only. When a writer runs a script, the prompt requires a SCRIPTS-MANIFEST row
         (script, run/step, block, sha256 of the preserved copy, sha256 of the remote copy if run remotely), preserved failed attempts, and
         RECIPE labelling for any script written after the fact (METHODOLOGY §5). An executed BUILD recipe (keys/certs/jar surgery,
         #1639) is persisted as a runnable script in the target's `tools/` or `codegen/` in the SAME commit as its block, like probe captures. (verify-block FAILs an ephemeral cite, `EPHEMERAL!`; waive a
         non-evidence line with `<!-- ephemeral-ok: <reason> -->`; `--ephemeral=warn` / `RSDD_STRICT_EPHEMERAL=0` opts out, #1660.)
         SECRETS-SENSITIVE INLINE OVERRIDE. The file-count delegation trigger and the config-artifact
         delegation variant below are OVERRIDDEN when artifacts are SECRET-BEARING (key files, shadow
         hashes, keystores, credential configs). Stay INLINE regardless of file count: a delegated sub-
         agent's cited findings for a secrets-bearing gap include key bytes or credential strings —
         exactly what SECRETS DISCIPLINE forbids in the driver context. Record as
         `no · inline (constraint: secrets-sensitive — <artifact type>)`. Applies only when the secret
         store is the SUBJECT, not when a directory merely contains secrets en passant. Pair with the
         STRUCTURE-ONLY BINARY INSPECTION RECIPE (`$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-live-install-access-recipe`) for the safe inline technique.
         (Source: 2026-08-30-jace-data-at-rest-focus-retro.md ΔB)
         DELEGATION VARIANTS — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#delegation-variants`
         in full when the gap is a single large config artifact, a quick-mode operator question, ≥2
         independent small gaps on different subsystems, a sibling gap while a sweep is already in
         flight, a recursive multi-level fan-out, or you are advancing other work while a delegated
         sweep executes. None of these apply to a plain inline gap.
       - CONCURRENT-WRITERS — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#concurrent-writers` in
         full before launching more than one writer/fork/chain on one repo or corpus, or when the
         target repo differs from the session cwd (disjoint ownership, at most two writers, one
         committing chain per repo, worktree isolation, quiet-tree gate).
       - DELEGATION-BRIEFS — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#delegation-briefs` in full
         when writing a delegate's brief or receiving its result, or when the build hits a WB/framework
         wall (executing-delegate contract, environment facts, truncated brief, blocker-scoped focus,
         PDF-citation spot-check).
       - REVIEW-AND-DELIVERY — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#review-and-delivery` in
         full before committing/merging on an RDD repo or landing a large change set (bulk-commit vs
         RDD, <=~400-line chained slices, never merge a due candidate before review, CI wait).
       - REVIEW PIPELINING: do not serialise "review, then start the next task". Plan the slices
         mechanically with `$KIT/toolbelt/plan-review-slices.sh [--base-ref REF] [--max-lines N]`
         (report-only; default 400; cuts only at commit boundaries; a commit over N prints
         UNSPLITTABLE). Review slice N (one RDD transaction per slice, `--base-ref <the slice's
         base=> --committed-only`, read-only on immutable commits) while the writer works on slice
         N+1. An UNSPLITTABLE commit is a decision for the human, not a mid-commit cut. A `base=ROOT`
         slice cannot be reviewed via `--base-ref` (review it as part of a wider range).
         `--committed-only --base-ref <base>` reviews up to HEAD, so pin HEAD at the slice's last
         sha (e.g. a worktree at `<last>`) to review slice N while later commits exist.
         SCOPE: valid only while slice N's commits are immutable — never amend/rebase/force-push
         them once its review starts. A correction on slice N lands as a NEW commit with its own
         transaction; planned slices are then stale, so re-plan from the reviewed boundary.
       - VERIFY BEFORE ACTING on a sub-agent's report, and ALWAYS when the report is an ABSENCE. A
         delegated finding is a hypothesis with citation, not a fact. Before writing a block or
         correcting a document on that basis: (a) resolve at least the `file:line` citations that
         support a key claim — two sweeps in practice returned paths that did not exist on disk;
         CWD-PATH BUG FIRST: before concluding a cited file does not exist (and thus concluding the
         sub-agent fabricated sources), rule out a cwd/relative-path bug — verify with
         `find <repo-root> -name <basename>` from the repo root. A file that returns "No such file"
         from inside a subdirectory may exist relative to the project root.
         PIN THE ROOT IN THE BRIEF (#1609): every sweep brief names the corpus root as an ABSOLUTE path (a stale cwd
         once returned remitted-only citations) and requires the return to state whether the sweep re-read the primary
         tree (fresh) or only prior blocks (remitted tier); a return without that statement is treated as remitted-only.
         ROOT-ARGUMENT MECHANISMS (same rule, mirror image — kit #1615): when a mechanism takes a ROOT as its argument (ext dir,
         patch dir, classpath, module path), assert the FULL expected child path of a known member (e.g. the class's package path
         under a `--patch-module` dir; `config\security\licenses`, not `config\licenses`) before concluding anything from the
         mechanism's silence. A wrong root argument reads as "no effect" or "store absent".
         (b) if the sub-agent asserts something does NOT exist / is NOT documented / is absent,
         grep-confirm it yourself before accepting, across ALL install roots the target uses (a
         split install keeps `bin/`+`jre/` apart from a config-home `modules/`; absence proved on one
         root is not absence).
         (c) Tool-use count is a signal: a detailed
         report with very few tool calls inferred instead of searched.
         PHYSICAL-ACTION FACTS (highest-priority VERIFY): for any cited fact a human will act on
         physically — wiring instructions, terminal maps, part numbers, safety values, calibration
         constants — the orchestrator MUST sample-verify those citations against the real source
         BEFORE relaying them, not only before writing the block. The [CERT-doc] requirement is
         necessary but not sufficient here: verify-before-relay, not only verify-before-block. The
         driver must have read the cited line; trusting the sub-agent's accuracy for a fact that may
         cause hardware damage or a safety incident is not acceptable. Record: "physical-action verify:
         N citations checked against real source, all confirmed."
       - HIDDEN-FLAG CROSS-CHECK — for a Go-CLI target block whose sweep SOURCE was `--help` output,
         also read the Go source's `cli.Flag` registrations for `Hidden: true` entries: they appear
         in neither `--help` nor `--help-all` yet may be operationally critical (4 missed in one
         sweep). Scoped to `--help`-sourced Go-CLI blocks only, not every Go CLI target.
         VERIFY-EDGE-CASES — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#verify-edge-cases` in
         full when the sweep source is a concatenated or decompiled-context dump, a sub-agent's
         proven-absence needs its scope widened, a scout returned absence from a narrow external-repo
         file set, or a delegated sweep contradicts something the driver already said inline. The
         (a)/(b)/(c) recipe above always applies; these are its edge cases.
         PEER CATCH. When a parallel session or the operator disputes a claim, re-open the PRIMARY source
         (not the decompile that seeded the claim) and correct the block with a §14 back-pointer; a peer
         catch is first-class evidence. (Source: 2026-09-03-research-sdd-rt-authoring-campaign-retro.md #5)
         DELEGATED-CLAIM-CHECKS — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#delegated-claim-checks`
         in full when a delegated sweep returns a count that will serve as a denominator or
         completeness claim, a scout's claim drives an architectural A⇒B conclusion, or a delegated
         sweep punts a security/safety question to an unsurveyed layer.
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
         Independent per-item batch steps may use `parallel -j 6 --keep-order --halt now,fail=1` (hard cap `-j 6`, one batch
         at a time, offline work only; serial rerun is the reference) — `toolbelt/DYNAMIC-SETUP.md` §8.
       - RESOURCE-BUDGETS — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#resource-budgets` in full
         before starting a heavy run or delegating one (CPU/RAM budget, queue, record the load).
       - LONG-BUILD-DELEGATION — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md#long-build-delegation`
         in full for a §19 build/PoC iteration delegated to an implementation agent (spec-file
         handoff, mid-flight correction delivery). Not applicable to a non-build gap.
       - PRE-TEST POPULATION ANATOMY: before running a comparison or classification test, measure
         the anatomy of the test population — how many items survive the eligibility filter, and
         what fraction is auto-generated vs. semantic vs. absent. If the post-filter count is zero,
         the test is NOT APPLICABLE and must not run — report the measured pre-filter and post-filter
         counts in place of a vacuous result (the anatomy distinguishes "the filter consumed everything"
         from "the input was absent", satisfying §7). (Distinct from RE-MEASURE A DRAMATIC NEGATIVE,
         which fires AFTER a striking result to verify it; this gate fires BEFORE the test, when the
         population is still uncounted.)
         API-FILTER SILENT-DECLINE EXTENSION / NARROWING-AXES AND READ-FRACTION / SUBJECT-DECLARED THRESHOLD / IDENTIFIER-GRANULARITY CHECK — SITUATIONAL: a sweep applies an API select/filter/mark, selects by both container and kind, chooses a classification threshold, or keys on an identifier as a unique entity: read `$KIT/PROMPT-LOOP-APPENDIX.md#step3-special-cases` and apply the rule whose trigger fired.
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
         decompiled source.
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
         optional guidance — include it in every prompt regardless of whether nesting seems likely. Also include,
         as a STANDING one-line stance in every delegation prompt: "Everything is possible; the question is HOW, at what cost, and what is needed." (possibility-first, METHODOLOGY §1). A sub-agent
         that nests silently hides its findings from the driver; recovery requires SendMessage and risks losing
         partial results (evidence: WB02 B428; niagara workbench-focus retro). The specialized agents
         (Explore/Plan) cannot sub-delegate at all. For STRUCTURED fan-out or multiple controlled levels, use
         the Workflow engine (deterministic control, no per-hop context compression) instead of free-form native
         nesting.
         ORCHESTRATED-SUB-AGENT MODEL TIER — SITUATIONAL: read
         `$KIT/PROMPT-LOOP-APPENDIX.md#orchestrated-mode-caveat` in full only when the delegating
         agent is ITSELF a sub-agent (orchestrated mode, one level deep) setting a nested tier.
  4. WRITE ONE BLOCK: create/update $CORPUS/<prefix>-blockN.md following the anatomy
     ($CORPUS = corpus root: default $TARGET, or $TARGET/corpus/ for an in-project target — METHODOLOGY §15)
     ($KIT/templates/block.template.md). Each claim with its marker and its citation:
       [CERT-hw] sources/probes/... (highest) · [CERT-live] live remote-service response (§12b) ·
       [CERT] file:line · [CERT-doc] sources/...pdf §N · [CERT-web] URL+date · [CERT-a] forum (URL) ·
       [INFER] deduction.  (canonical list: METHODOLOGY §3)
     LOCAL DOC CORPUS CITE DISCIPLINE — SITUATIONAL: your first `[CERT-doc]` claim in a block draws from a new local doc corpus (sources under `sources/manuals/<focus>-docs/`): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
     Include the Connections section linking related [Block K].
     BLOCK PLAN OPEN (long, multi-step blocks only): at block open, BEFORE the first sub-step, copy
     `$KIT/templates/block-plan.template.md` to `$TARGET/.research-sdd/plan/current-plan.txt` and record `opened-at: <HEAD sha>` plus the block file path in its header, then list THIS block's sub-steps (sweep → corroborate →
     write → self-verify → update catalog/index/state → commit). Tick each `[x]` only when its artifact is on disk. The plan holds sub-steps
     of the current block ONLY — gaps, backlog, queue and "what's next" stay in RESEARCH-STATE.md (METHODOLOGY §20 "Block plan"). Not an ODD task document (`odd/tasks/*.md`); the return-token gate and `--next` are unchanged; the file lives outside every block glob (hidden dir, no "block" in its name).

     For doc-synthesis blocks (where `[CERT-doc]` is the primary source), OPTIONALLY add a closing
     section — e.g. "§N.x — What this doc does not resolve" — listing findings the official document
     is silent about, cross-referencing corpus blocks whose evidence the guide omits. Vendor guides
     document the happy path; decompilation reveals failure modes the guide never mentions.
  5. SELF-VERIFY + REPORT (in-block gatekeeping — see METHODOLOGY §11; the orchestrator does NOT run
     Bash gatekeepers, it TRUSTS this report. Per-block orchestrator Bash re-checks cost permission prompts
     and — proven on the protocols run — caught NOTHING; the real error capture mechanism is cross-block
     correction §14, not a per-iteration re-verify. Beyond the one-line CENTRAL-CLAIM CHECK of a delegated block's headline claim (see ORCHESTRATED-AUTO-AT-SCALE), only spot-check when a report smells off). Before closing,
     DO and REPORT:
       - MECHANIZE the counting: run `$KIT/toolbelt/verify-block.sh <block>` and paste its output — the
         marker tally, [INFER]/[CERT] ratio and [CERT] file:line citation-resolution are COMPUTED, not
         remembered (it exits non-zero on a cited file:line whose line is out of range). It is your own
         calculator, not an orchestrator gate.
       - Before committing the block, run `$KIT/toolbelt/lint-block.sh <block.md>` next to `verify-block.sh`
         (METHODOLOGY §11 "Block lint"): a non-zero exit is a defect to fix or to waive with a reasoned
         `lint-waive` token; `lint-block.sh --audit <corpus>` is the report-only form for legacy corpora.
         GOVERNED-FAILURE ORACLE — SITUATIONAL: a block claims a replaced constant/key/toggle took effect (steering proof; also `lint-block.sh --audit --pack`): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
         VERIFY-BLOCK CITATION GATE: BLIND FOR DECOMPILED-TREE BLOCKS — SITUATIONAL: the block's `[CERT]` citations point into decompiled trees, or verify-block prints `resolved 0 of M` / classifies citations `extern`: same section.
         BASE-RELATIVE CITATION BLIND SPOT — SITUATIONAL: verify-block marks a `[CERT]` path `extern` although the file is local (a path relative to neither `$target` nor its git toplevel): same section.
         TALLY-LINE TOKEN INFLATION — SITUATIONAL: the self-verify tally appears in the block body, or a re-run of verify-block over a finished block reports inflated counts: same section.
       - Token check: grep-confirm EVERY load-bearing [CERT] token is present in its cited source;
         report how many you checked. Escalate/downgrade markers honestly (a critical [CERT-a]: try to
         confirm in the primary source first).
       - Framework-semantic check for security/permission and behavioral capability claims from
         delegated sweeps: token PRESENCE passes the token-check but does not confirm semantic
         CORRECTNESS. A flag `permissions="unrestricted"` IS present in source and passes the
         token-check, yet may still filter through `hasOperatorRead()` in calling code. Sub-agents
         read local syntax; they lack the driver's accumulated framework model. Two trigger classes:
         (a) SECURITY/PERMISSION: who can invoke what, what is protected or exposed;
         (b) BEHAVIORAL CAPABILITY: any claim that a component "supports X", "handles Z for input
         type T", or "produces Y" — when prior corpus blocks established a structural constraint
         (a hardcoded field, a type mismatch, a profile boundary), verify the capability claim does
         NOT contradict it (B365 §365.3: sweep cited `isHistoryQuery()` + `?period=` prepend →
         "partially supports history table"; driver re-read `:750` found `select ordInSession`
         hardcoded → the B359 NPE wall makes that claim wrong);
         (c) ENVIRONMENT/RUNTIME-VERSION: any claim about compiler target, JVM version, SDK level,
         or runtime environment. Verify by DIRECT MEASUREMENT before accepting — e.g.
         `od -An -j6 -N2 -tu2 --endian=big X.class` reads the class file's major-version byte and
         is the authoritative JVM target check; do NOT rely on a sweep's prose claim. A wrong
         version cascades to wrong feasibility verdicts.
         Cross-verify the INTERPRETATION against corpus-documented framework semantics BEFORE
         incorporating it. Treat such claims as hypotheses pending semantic validation.
         Three named outcomes — record each in the iteration-history row:
           · CONFIRM: claim survives the semantic re-read.
           · REFINE: claim is partly right; narrow its scope.
           · DE-ESCALATION: driver re-read subtracts a false finding (B341 §341.8, B347: two
             de-escalations; B349 §349.5 "subtracting a false finding"). DE-ESCALATION is a quality
             signal — "downgrade honestly" (step 5 token-check) adjusts a marker; DE-ESCALATION
             removes a finding the sweep should not have raised. Record it by name so retro
             reviewers distinguish the two and recognize subtraction as success.
       - Marker tally: counts of [CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER] + the [INFER]/[CERT]
         ratio, AND the block TYPE. For an EVIDENCE block (decompilation/reading), a high ratio (>~0.5)
         signals this gap's investigable evidence is nearly exhausted — say so. For a DESIGN/APPLIED block
         (an integration plan, a PoC design, a synthesis), a high ratio is EXPECTED and healthy, NOT an
         exhaustion signal — it does not close the focus. Declare which type it is so the ratio is read right.
         CORROBORATION-FROM-INDEPENDENT-STORE is a named valid EVIDENCE block type. A block whose primary
         finding is the CONFIRMATION of prior [INFER] or [CERT-hw] claims from a data source INDEPENDENT
         of the source that generated those claims is high-value evidence, NOT an exhaustion signal. Declare
         it as `EVIDENCE (corroboration — independent store)` in the self-verify tally. A corroboration
         block's [INFER] ratio is expected LOW by construction — read it as "prior [INFER] elevated toward
         [CERT-hw] by independent witness," not as diminishing returns. (Source: 2026-08-30-jace-history-audit-focus-retro.md R2)
       - Artifacts: block file exists, CATALOG regenerated, INDEX/RESEARCH-STATE updated.
       - §14 BACK-POINTER CHECK (when a §14 correction was issued this iteration): confirm the OLD BLOCK
         was actually edited to add the back-pointer note ("corrected in BN") — not just documented in the
         new block's Connections. Evidence: `git show <old-block-path>` must show the added line. This check
         is manual — the back-pointer is prose and no script can reliably detect which old block a correction
         targets (§7 false-negative: prose-guessing parsers inherit the ambiguity of the prose they parse;
         see verify-block synthesis-gate post-mortem, issue #128). 3 of 4 corrections in niagara/database
         omitted the old-block edit; 1 of 3 in niagara/network-supervisor. A correction is not self-documenting:
         the new block cites the old one; the old block MUST reference back so the audit trail is visible in
         BOTH directions. A §14 correction whose old block has no back-pointer is an ORPHANED CORRECTION — it
         looks complete from the new block but is invisible from the old one. Corrections that span more than
         one prior tier (a chain of corrections) must add the back-pointer to EVERY corrected block in the
         chain, not only the most recent.
       - FORWARD-RESOLUTION POINTER (when THIS block resolves an OPEN OBSERVATION recorded in a PRIOR
         block — distinct from a §14 correction; an observation is a noted question or uncertainty, not
         an asserted error): edit that prior block to add a forward pointer before closing this iteration,
         e.g. "resolved in [Block N] §N.x". This keeps the prior block from appearing open-ended when
         read in isolation.
       - MCP-doc snapshots: every LOAD-BEARING [CERT-web]-via-MCP citation (context7 et al.) snapshotted to
         sources/web-snapshots/ + registered in SOURCES.md (§5). Report Y/N + count — this gate is what stops
         §5's snapshot rule from being paper-only (context7 cites kept landing unsnapshotted across runs).
       - [CERT] SEAL (adversarial-verify — required for conclusion-bearing [CERT] claims — METHODOLOGY §3) — run
         the `adversarial-verify` workflow ($KIT/toolbelt/adversarial-verify.js) for conclusion-bearing [CERT] claims
         (those a conclusion rests on): N=3 skeptics try to REFUTE each claim; it stays sealed only if it SURVIVES
         ≥2 of 3, otherwise DOWNGRADED or DROPPED. KILL on majority-refute; INSUFFICIENT below quorum of 2 or mean
         confidence < 0.7. Cost discipline: [INFER] and trivial claims excluded. LOCAL-sourced claims (file:line)
         are CHEAP — skeptics read the cited source, no web; web-verifiable claims are expensive (~125k tokens/claim).
         PROHIBITED in dynamic/hardware phases (§12) and in block writing/numbering — it is a read-only SEALING
         step, not orchestration of the loop.
  6. UPDATE STATE (archive phase):
       - Mark the gap covered in RESEARCH-STATE.md + INDEX.md; REGISTER the NEW gaps uncovered. A gap may
         close by NEW investigation, by PROVEN ABSENCE, by REMITTANCE (already answered by an existing
         cited block — cite [Block N] §N.x + "no new substance"), or by RE-SCOPE (belongs to a different
         question; state which focus it belongs to and whether it exists — see METHODOLOGY §8).
         PROVEN ABSENCE requires the same sampling discipline as a positive finding: state the sample
         size and the test applied. A single sample that failed the question you asked is evidence for
         that one case, not for the universe. ALSO record what question the source DOES answer — a
         source that fails the gap question may answer a DIFFERENT open question (and that finding
         belongs in a block or in the NEW-gaps register, not discarded).
         SYNTHESIS-BLOCK REGISTRATION RULE: a synthesis block (focus-closing iteration) is still
         subject to this REGISTER rule. Any `requires-execution` gaps it uncovers MUST be added to
         the BACKLOG TABLE, not only noted in the iteration-history "New gaps uncovered" column. An
         entry only in iteration-history is invisible to `verify-state.sh` and the
         `requires_execution_open` counter — the gap will never reach the investigable/scheduler
         count. The "closing feel" of a synthesis block is precisely the blind spot where
         registration gets skipped.
         SAME-COMMIT CHILD-GAP RULE (extends SYNTHESIS-BLOCK REGISTRATION RULE): register all child
         gaps surfaced by a synthesis block in RESEARCH-STATE in the SAME commit as the synthesis
         block itself. A gap named in the synthesis report but absent from RESEARCH-STATE at commit
         time is invisible to `verify-state.sh` and may be permanently lost if the session ends
         before a planned follow-up registration. This also applies to any iteration, not only
         synthesis: whenever "New gaps uncovered" is non-empty, the backlog rows must exist in the
         same commit.
         TERMINAL-TIER CONVERGENCE — SITUATIONAL: this focus is running a second investigation tier over first-tier child gaps, and you are about to seed child gaps from it: record residues as in-block sub-sections instead of grandchild backlog rows; read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
       - REVERSE BACKLOG SWEEP: after closing a gap OR retiring a §14 premise, re-read the open
         backlog and re-scope or rename any gap whose PREMISE this block just answered or invalidated.
         A gap that was opened as "is X true?" becomes stale if this block proved X false — it must
         be updated or closed, not left as-is. This sweep is PREMISE-driven and distinct from the
         NEXT-ITERATION ARCHIVE AUDIT (which checks bookkeeping counts — gap totals, marker sync);
         the archive audit catches accounting errors; this sweep catches semantic drift in the
         backlog itself. Run it inline, not as a separate pass.
         REMITTANCE GAP REOPENING — SITUATIONAL: a gap closed-by-remittance later gains direct evidence confirming the remitted claim: read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
       - BACK-FILL SOURCES.md's "Citing blocks" cell — when this block cites a source registered in SOURCES.md
         (this iteration, or an earlier one whose trailing cell is still blank), write THIS block's ID into that
         row's last column before closing the iteration. `fetch-doc.sh`'s `reg()` leaves the cell blank by design
         (a later manual back-fill); leaving it blank silently disables `verify-sources.sh`'s FABRICATED-citation
         cross-check for that row — the check only cross-validates rows that DO list a block (METHODOLOGY §5).
         PRESERVATION-SURFACES-CORRECTIONS — SITUATIONAL: you scope or run a §5 debt-closing preservation pass over bare-URL citations: same section.
       - RECORD the iteration in RESEARCH-STATE's Iteration history table (append the row with
         `toolbelt/append-iteration-row.sh [--apply] <RESEARCH-STATE.md> "<row>"` — dry run by default, `--apply`
         writes atomically, refuses a row whose cell count differs from the header; never hand-edit the table, which
         can glue the row onto the next heading, kit #1606) INCLUDING the delegated? · model
         tier column (no·inline / yes·haiku|sonnet|opus) — persist the tier on disk, not only in the report,
         so tier-compliance stays auditable after the session ends. For an EXTERNAL-source iteration, record the
         e3 SCOUT VERDICT in the same row too (`scout: CERTIFIABLE-NOW`, or `scout: CERTIFIABLE-NOW ×N` for
         parallel scouts) — same reason as the tier: an unrecorded verdict makes e3-compliance unauditable after
         the session, even though authoring was gated on it.
       - CLASSIFY the whole backlog into investigable vs blocked-on-<reason> (tool-missing / x64-tool /
         live-server / hardware) and record both counts in RESEARCH-STATE.md.
         RE-TYPED / BLOCKED TRANSITION (kit #1638): a gap whose type changes or that becomes blocked is
         recorded in ONE of two tool-recognised forms in the SAME edit: (a) in place, Status
         `blocked (requires-<what>)` with its `tried:` / `needs:` clauses; or (b) moved out of the main
         table to `## Blocked gaps` as a `- <gap> — needs: …` bullet. A Status whose leading token is
         `re-typed` is warned about by `research-sdd-status.sh` and `verify-state.sh` and is not
         counted (METHODOLOGY §8b).
       - Update the coverage METRIC as a ratio (gaps closed / known gaps), NOT a free-floating %.
       - WRITE the coverage counts with the tool, never hand-edit them: run
         `$KIT/toolbelt/research-sdd-status.sh $TARGET --sync-state` to (re)write the state envelope's
         coverage counts from the tool's OWN measurement, rather than hand-editing covered_blocks or
         hand-counting with `fd`/`find` (whose extension-regex can diverge from the tool's — a hand
         `fd 'bloque[0-9]+\.md$'`=408 vs the tool's 409). The ratio bullet above is the DISPLAYED metric;
         this is how its numerator/denominator get WRITTEN so they cannot drift from the instrument that
         later lints them (verify-state.sh, steps 5/7). SCRIPTS-LANE note: if `--sync-state`'s count and
         `verify-state.sh`'s ever DISAGREE, that reconcile is a scripts-lane concern (route to the peer who
         owns those scripts), out of scope for this doctrine.
         Ownership (kit #1819): `--sync-state` is the in-place writer the loop runs on its OWN corpus and the only
         writer of known_gaps / gaps_closed; `state-update.sh` is the propose-only diff for review (it also alone
         proposes the Stop-control `read-only investigable: N` number) — never hand-edit either way.
       - EDGE-TRIGGERED LINT (in-edit, scoped — these are the AGENT'S OWN calculators, exactly like step 5's
         verify-block, NOT orchestrator gates; see METHODOLOGY §11): right after editing the RESEARCH-STATE
         summary, run `$KIT/toolbelt/verify-state.sh $CORPUS --focus <focus-slug>` (cheap — one file;
         `--focus` scopes the scan to the active focus's RESEARCH-STATE file, avoiding FAIL noise from
         unrelated focuses in a multi-focus corpus — an unscoped run scans ALL RESEARCH-STATE*.md and
         drove the covered_blocks-to-satisfy-noise anti-pattern); and ONLY if you edited
         SOURCES.md this iteration (a source was added/preserved), run `$KIT/toolbelt/verify-sources.sh $CORPUS`.
         Do NOT run either EVERY iteration — a linter can only surface a NEW defect when ITS input changed, so
         triggering it on its input's edit adds ZERO redundant corpus re-scans while catching the defect in the
         iteration that introduced it, instead of letting it survive until STOP. The STOP run (step 7) stays as
         the final backstop. A linter that FAILS may still report a true finding in a different
         check — read every line of its output before dismissing any of it.
       - Regenerate CATALOG.md: python3 $KIT/templates/gen-catalog.py $CORPUS (the kit generator over the corpus
         root — no per-target copy; research-sdd-archive.sh does this on close). Mirror to engram (research/<target>/gaps, .../progress). If the
         MCP `mem_save` fails under concurrent sessions (`multiple active runtime sessions match`), use the engram
         CLI (`engram save ... --project ... --topic ...`) as the fallback — never drop the mirror.
       - NEXT-ITERATION ARCHIVE AUDIT (orchestrated-auto): each iteration is a FRESH sub-agent that reads
         INDEX/RESEARCH-STATE from scratch, so before appending YOUR entry, check the PRECEDING iteration's
         bookkeeping (its block-table row, file/gap-count totals) is complete and consistent — repair it as
         part of THIS archive step if not. Distinct from §14 (audits claims) and §17 (resume after a crash):
         this catches archive-bookkeeping drift between one iteration's close and the next's open.
       - BLOCK PLAN CLOSE (only when a `$TARGET/.research-sdd/plan/current-plan.txt` was opened at step 4): once S5
         (update catalog/index/state) is ticked, do S6 exactly as the template numbers it: DELETE the plan BEFORE staging, then stage and commit the block — it is never committed and never
         outlives the iteration. It is not registered in INDEX/CATALOG/RESEARCH-STATE.
  7. STOPPING (primary = investigable exhaustion, per METHODOLOGY §8): if the INVESTIGABLE count is now
     0 — every open gap is blocked on a missing/incompatible tool, a live server, or hardware — STOP.
     (Secondary: backlog empty 2× in a row.) On stop, DECLARE: blocks written, coverage ratio, the
     blocked gaps each tagged with the tool/access it needs, and the TOOLS REPORT (installed · couldn't
     -install+why · recommended — from $KIT/toolbelt/INSTALLED-TOOLS.md).
     MECHANIZE THE CLOSE: run `$KIT/toolbelt/research-sdd-archive.sh $TARGET` — the gated close driver
     (models sdd-archive, kept to the continuous loop). It runs BOTH linters below as a GATE and REFUSES
     with exit 3 if either fails — a refusal means you are NOT at STOP: reconcile (refresh the summary /
     register the source) and keep looping. Once the gate passes it does the SAFE deterministic bookkeeping
     (regenerate CATALOG, touch INDEX) and prints a close-checklist of the JUDGMENT follow-ups it refuses to
     guess (synthesis block, §18 retro, iteration-history collapse, TARGETS.md mirror row, corpus commit).
     NON-CORPUS AUDIT: also verify the target's operational documents (README, PLAN, RUNBOOK, ROLLBACK
     if they exist) reflect the current block count and active focuses. `verify-registry.sh` mechanizes
     the TARGETS.md row; the others are manual. A corpus that grew 17 blocks while the PLAN describes
     the prior run is documentation debt invisible to corpus readers.
     Preview with `--dry-run`. It is CORPUS-scoped: it never edits the kit and never touches git — you do
     those from the checklist below.
     PUSH CADENCE (if the target has a remote — METHODOLOGY §15): push at STOP, at focus-close, and at
     retro-close (and OPTIONALLY every ~10 blocks on a long run) — with plain `git -C $TARGET push` once
     `origin` already exists (`ensure-remote.sh` BOOTSTRAPS the private remote ONCE — create + initial push —
     and is idempotent no-op once `origin` is set, so it is not the cadence pusher; use plain `git push` for
     every push after that first bootstrap). NEVER push inline per block; batching keeps the loop fast and the
     remote a checkpoint, not a per-commit mirror. A remote is consent-gated and PRIVATE by construction (§15)
     — if the target has no `origin`, DO NOT create one mid-loop; leave it to the operator. The two checks it gates on (run them directly for the detailed output):
     MECHANIZE the §5 source-registry check: run `$KIT/toolbelt/verify-sources.sh $CORPUS` and paste its
     output — it exits non-zero if a block cites a preserved-source marker ([CERT-doc]/[CERT-a]) with no
     sources/SOURCES.md, or a cited sources/ file is absent on disk. This is the corpus-level twin of
     step 5's verify-block.sh: per-block marker/citation math is checked in-iteration, source-registry
     integrity is checked once at STOP (it reads the whole corpus).
     MECHANIZE the living-mirror check too: run `$KIT/toolbelt/verify-state.sh $CORPUS --focus <focus-slug>` BEFORE honoring STOP —
     it exits non-zero when the coverage summary claims all gaps closed while the backlog still lists `pending`
     rows (the stale-mirror desync that let run-A emit a premature STOP). A non-zero exit means you are NOT at
     STOP: refresh the summary / reopen the metric and keep looping. If STOP did NOT fire, do NOT end
     your turn: reschedule and BEGIN the next iteration on the next gap (see LOOP CONTINUATION under HARD RULES).
     ARTIFACT AUDIT before honoring STOP: sweep `$TARGET/tools/` and `$CORPUS/audits/` for analysis
     dumps (`.txt` / `.c` / `.json`) produced by prior decompiler or probe runs but cited by no block.
     A dump that covers an OPEN gap and is cited by no block is false-negative exhaustion — the STOP is
     NOT honored until that dump's content is either captured as a block or explicitly dismissed.
     `verify-sources.sh` and `verify-state.sh` do NOT perform this sweep; it is an operator/agent
     obligation at every STOP gate.
     POSSIBILITY AUDIT before honoring a focus/campaign STOP (METHODOLOGY §8c; NOT on a PAUSE — budget-cap,
     operator-directed — nor a `campaign-bound-reached` stop): list what going further toward the stretch goal
     would need (tools, access, live system, build, operator data) that is not already in the backlog or `tried:`;
     seed each as a gap with route + owner + cost. Read-only and §21.4 self-provisioning routes are pursued, so
     STOP does not fire; a build/PoC (§19) item is seeded `requires-execution` and listed in the STOP declaration
     as a §19 hand-off; operator items are typed blocked rows. STOP when the list is empty or each item is
     operator-parked or handed off in the declaration. Routes are [INFER]/proposed, never findings.
     TERMINAL-TIER CONVERGENCE — SITUATIONAL: a focus runs a second investigation tier over first-tier child gaps (residues vs grandchild backlog rows): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
     FRONTIER MODE — SITUATIONAL: the focus is (or is being bootstrapped as) MODE: frontier, i.e. genuinely unexplored territory with no prior corpus coverage: same section.
     FRONTIER-REOPEN DECISION SHAPE — SITUATIONAL: STOP-CANDIDATE in heavy or frontier mode (the TERMINAL TRIGGER below runs this audit once before honoring STOP): same section.
     TERMINAL TRIGGER (the open loop — see METHODOLOGY §8): STOP is not a dead end. The loop stays CLOSED
     (self-continuing) while read-only-investigable > 0; when it hits 0, OPEN the loop to the environment and
     fire the next action instead of just declaring:
       - Focus STOP and campaign STOP not met (having run the FRONTIER-REOPEN audit once — heavy and
         frontier modes only — this focus is done but the §8c queue has pending/active entries):
         Having run the FRONTIER-REOPEN audit, enqueue new entries in the §8c campaign
         queue (never FOCUSES.md — that is a catalog, not a queue), then OPTIONALLY write a focus-closing
         SYNTHESIS block (consolidate this focus, cross-referencing related blocks across focuses — a valid
         terminal artifact at focus level; see METHODOLOGY §8), and pop the next `pending` entry. Under
         `/loop` self-pacing, reschedule ONE more time re-entering with FOCUS set to the next §8c queue entry
         (BOOTSTRAP it if `kind=focus`; re-enter the existing corpus if `kind=tier`). Emit a
         per-focus SELF-RETROSPECTIVE at each focus STOP. The loop does not die; it advances to the next entry.
       - Campaign STOP (§8c) — no entry is pending or active, last audit enqueued=0: on a multi-focus
         (§16) corpus running heavy or frontier mode, FIRST run the §8c campaign-close partition check.
         If it finds a genuinely UNCHARTERED artifact unit, enqueue each newly found family as a
         `pending` `kind=focus`/`kind=tier` §8c queue row (creating `## Campaign queue` if it does not
         exist yet) and re-enter the "Focus STOP and campaign STOP not met" branch above instead — the
         campaign is not over and this branch does not fire. Only once the check is clean (or every
         remaining UNCHARTERED unit carries a recorded out-of-scope reason) does this branch proceed:
         emit a final NEXT-ACTION recommendation — a cross-focus synthesis block, or handoff to a non-static phase
         (requires-execution build/PoC §19 — §19 CLOSE RULE: when a build/PoC phase produces
         block-quality findings, write them as cited blocks using `sources/probes/` for tool evidence
         BEFORE the phase ends; a deliverable is not a substitute for the evidence trail, and findings
         that exist only in code/engram are invisible to the corpus.
         VISUAL/GEOMETRIC ORACLE — SITUATIONAL: a §19 close whose deliverable has a visual or geometric form (rendered model, floor plan, spatial diagram): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full.
         —, or the DYNAMIC/hardware phase §12) — and, if that next phase is
         itself autonomous and safe, launch it; if it needs a human decision or hardware, declare and hand
         off to the user/orchestrator. Only a corpus with NO pending §8c queue entry AND no safe next phase ends silent.
       - NO-GARBAGE CHECK (kit #1277, METHODOLOGY §15; report-only): at every exhausted STOP, `research-sdd-status.sh
         <target> --next` runs `toolbelt/clean-check.sh` and prints its result on STDERR (`INFO: clean-check: clean ...`,
         `WARN: clean-check: ...` per finding, or `WARN: clean-check: unverifiable (...)`). It is a loud WARN, not a gate,
         and it deletes nothing: before declaring STOP, resolve each finding by hand or declare it in
         `<TARGET>/.research-sdd/keep.txt`. An `unverifiable` line means the target was NOT confirmed clean — say so.
       - OUT-OF-TREE APPLIED DELIVERABLE (a requires-execution close whose deliverable lands OUTSIDE $TARGET —
         a skill, plugin, or installed tool): reference it by PATH + SHA-IDENTITY (a manifest hash of the file
         set), NEVER copy it into the corpus; when there is no "original bytes" to diff against, an EXTERNAL
         adversarial QA protocol (e.g. Judgment Day) is the §19 oracle; preserve the full protocol evidence
         (ledger, fix log, consumer run, artifacts) under $CORPUS/sources/probes/<name>/ and cite it `[CERT-hw]`
         from the closing block. Full treatment: METHODOLOGY §19.
       - SELF-RETROSPECTIVE (per-focus SELF-RETROSPECTIVE at every focus STOP; campaign RETRO CHECKPOINT at campaign STOP — METHODOLOGY §18):
         before handing off, DELEGATE a fresh-context retro agent to review THIS run and PROPOSE kit deltas.
         A coordinator/operator instruction forbidding delegation wins: write the retro inline and put
         `Method: inline (coordinator forbade delegation)` in its header so readers discount its self-review
         (METHODOLOGY §18, kit #1991).
         The journal (METHODOLOGY §18 journal mode) is a SUPPLEMENTAL SOURCE — the full run review still
         runs. The retro agent: (1) reads $KIT/PROMPT-LOOP.md + METHODOLOGY.md FIRST and dedupes; (2) reviews
         the run — blocks written, §14 corrections, rules skipped, improvised techniques; (3) reads journal
         entries via `mem_search(query: "research/<target>/journal/<YYYY-MM-DD>", project: "<target>",
         limit: 20)` — FTS phrase match over all columns, NOT a topic_key prefix scan; pass
         `project: "<target>"` explicitly (kit cwd yields zero target hits); pass `limit: 20` explicitly
         (default is 10); filter results by title convention `<YYYY-MM-DD> <category>:` to drop FTS
         overmatches; if the result count equals 20, flag possible truncation; dedup across prior §18
         firings in this session, then dedup near-duplicates; curate and flag non-conforming entries
         explicitly; (4) merges journal candidates with run-review candidates and promotes worthwhile ones
         to `## Proposed kit deltas` rows; (5) records the retrieval state explicitly: if zero hits,
         records search-returned-nothing or nothing-captured; if count equals 20, records
         possibly-truncated — these are DISTINCT states (see METHODOLOGY §18 retrieval-states table);
         continues with the run review in all cases.
         It writes the proposal to $TARGET/retros/ + engram research/<target>/retro and SURFACES it in the
         return. The `## Proposed kit deltas` table and `review-status: pending` marker consumed by
         `sweep-retros.sh` are UNCHANGED. It does NOT edit the kit — kit changes are human-reviewed and
         human-committed. This is how the kit learns from real runs.
       - RETRO CHECKPOINT (EXIT CONDITION, not a question): a run that wrote or changed ANY block, RESEARCH-STATE,
         CATALOG or INDEX file is NOT OVER until a retro produced from `$KIT/templates/retro.template.md` exists in
         `$TARGET/retros/` newer than the newest changed block, carrying `<!-- review-status: pending -->` and a
         `## Proposed kit deltas` table (or the §18 honesty line "no new deltas; the kit already covers this run").
         Then run `$KIT/toolbelt/stage-retro-issues.sh <retro>` (dry-run to preview, then `--apply`) so each OPEN
         delta becomes a `status:needs-review` issue on the kit repo as it is proposed — backlog-first, dedup-guarded
         (§18). It is read-only without `--apply` and emits `degraded` when `gh` is absent.
         Under `--apply`, a delta whose exact title already matches an OPEN issue gets one idempotent occurrence
         comment instead of a duplicate issue (#1708); output lines `occurrence-commented: #N (row R)`,
         `occurrence-exists: #N already carries this retro (row R)`, and `occurrence-summary: commented=N already-present=N`.
         Free-form session notes, "lessons" lists, or a heading of your own are NOT a retro (measured 2026-09-05:
         3 targets advanced with no retro; 7 of 12 new retros were unmarked, wrongly headed, or empty). Before the
         final RETURN state `retro: written <path>` or `retro: not-due (no research files changed)` — never
         `retro: pending`. Enforcement: once wired (kit issue #479), `$KIT/toolbelt/retro-gate.sh` runs as the
         target's Stop hook and blocks the session ONCE with the exact missing element until this holds.
         SEED AS THE RUN'S OWN FINAL STEP (#1258): the Stop hook's `retro-conforming` seeding is only a
         backstop, so after the retro is committed run `bash $KIT/toolbelt/stage-retro-issues.sh <retro> --apply`
         yourself and include its final `summary:` line in the return; if it exits 1 with `degraded:` (e.g. `gh`
         absent or unauthenticated, kit issue repo unresolved, target not registered in TARGETS.md) or
         exits 2 (some issue creations failed), say so — never omit the line. The hook also appends one line per
         Stop to `<target>/.claude/.rsdd-retro-gate-stops.log` (branch taken plus seeding evidence: the
         seeder's `summary:` line, or a typed skip or degraded reason); check it when seeding looks missing.
         COVERAGE LINE (kit issue #1640): write one column-0 line `covers_through: B<n>` (newest block this retro
         reviewed; add ` focus=<slug>`, or `focus=root`, in a multi-state corpus) from the template, and apply by hand
         the `proposed-reset: blocks_since_retro: 0 in <state file> …` line `stage-retro-issues.sh` prints (it never
         edits a state file; propose-never-apply, METHODOLOGY §18).
         CLAUDE-CODE-ONLY — SITUATIONAL: the run is on pi or gentle-shell (no Stop hook, so no retro-existence block or delta auto-seeding): read `$KIT/PROMPT-LOOP-APPENDIX.md#steps4-7-special-cases` in full (run `stage-retro-issues.sh <retro> --apply` by hand after the retro is written, and `sweep-all.sh` by hand at session start).
         OPERATOR-DIRECTED PAUSE: the RETRO CHECKPOINT EXIT CONDITION above supersedes any "MAY"
         language elsewhere — the retro is mandatory whenever research files changed (block /
         RESEARCH-STATE / CATALOG / INDEX), regardless of pause type: an operator-directed pause, a
         mid-focus interruption, or a focus-level stop. A paused run whose files changed is NOT
         retro-exempt. This is the PROMPT-LOOP loop-step mirror of the METHODOLOGY §8
         OPERATOR-DIRECTED PAUSE rule, which is the authority for the `PAUSED (operator-directed)`
         RESEARCH-STATE label.

== DOCUMENT CYCLE (CAPTURE mode — entered ONLY when invoked as `document`; the OUTLINE-driven twin of NORMAL CYCLE) ==
  SITUATIONAL: this whole mode is entered ONLY when invoked as `document`. Read `$KIT/PROMPT-LOOP-APPENDIX.md#document-cycle` in FULL before the first step of a document run: it holds the operative contract (PREFLIGHT and steps 1-7). References elsewhere to "PROMPT-LOOP's DOCUMENT CYCLE step N" mean that section. Step 5 also holds the SUCCESS-CAPTURE RECIPE gate.

HARD RULES:
  - MEMORY IS A MIRROR, NEVER A SUBSTITUTE. Every project/decision finding saved to memory (engram)
    that has no corresponding block is undocumented. The corpus cannot cite it; reviewers cannot audit
    it; a future agent reading the blocks will not see it. Rule: when you call mem_save for a finding
    of type project or decision, increment `undocumented_findings` in RESEARCH-STATE immediately. When
    you write the block, decrement it. A finding that lives only in memory is missing from the record.
  - POSSIBILITY-FIRST — never close a gap, answer an operator proposal, or write a block on a bare "not possible /
    cannot / no way / out of reach / not determinable / no se puede". Write a ROUTE LADDER instead: >=3 routes
    from different classes (own-surface §21.2, another instrument/source class, provisioning §21.4, dynamic §12,
    build/PoC §19, operator-supplied access, decomposition), each with cost + what it needs, ending with the
    cheapest next step; "no" is legal only as "not with <route>, measured". Unexecuted routes are [INFER]/proposed,
    never findings. A bare "no" you find in your own draft or inherited from an earlier block/RESEARCH-STATE is
    rewritten as a ladder and, if inherited, reopened as a child gap B<n>-G<m> with the cheapest route as NEXT
    (§14 back-pointer). verify-block.sh WARNs on bare verdicts; `--possibility-sweep <corpus>` lists inherited ones
    (METHODOLOGY §1). Every wall you record ends with `unblock: <route> · owner: <who> · cost: <estimate>`
    (§21.1); `not-buildable` stays the only "stop asking" state.
  - READ-ONLY over the subject. Do not invent: no source ⇒ [INFER] or omit. Always cite.
  - SOURCE BEFORE AGENT — a gap counts as investigable ONLY once its source is confirmed reachable
    (the class/jar/binary/doc exists and the wrapper can read it). Confirm it BEFORE launching an
    iteration agent at that gap; an unconfirmed gap is blocked-on-source-missing, not investigable.
    Never send an agent to a gap with no reachable source — it will pad [INFER] or invent (see BOOTSTRAP e2).
    This check extends to PROPOSALS: a next-step plan naming specific artifacts must confirm those
    artifacts exist before it is offered, at least as cheaply as the corpus allows (grep existing
    blocks). A proposal acted on socially before it is confirmed technically is the costliest kind
    of wrong claim.
    ANONYMOUS-FETCH 403 ≠ ABSENT: a `git clone` or anonymous HTTP fetch returning HTTP 403
    (Forbidden) — not 404 (Not Found) — means the resource may exist but is access-gated:
    auth-gated, WAF-gated, or bot-gated (401 is the canonical auth-required code; a 403 may
    indicate any of these). Document an access-gated gap; do NOT mark the source as absent or
    treat the gap as blocked-on-source-missing. A 403 is an access boundary, not an absence signal.
  - TOOL-BEFORE-AGENT (binary/native artifacts) — before delegating a sweep over a binary
    (ELF/PE/.sys/.dll/firmware), the DRIVER runs:
      `$KIT/toolbelt/detect-tools.sh --require <decompiler-for-class>`
    where <decompiler-for-class> is: `ghidra` (or `r2`) for native ELF/PE/firmware;
    `vineflower`, `cfr`, or `procyon` for JVM bytecode; `jadx` for Android DEX.
    On a NON-ZERO exit, HALT: do NOT delegate, do NOT fall back to `strings`. Record the
    missing decompiler as blocked-on-tool in RESEARCH-STATE and surface the gap to the user.
    Proceed to decompile ONLY on exit 0. The decompiled binary is to native RE what a confirmed
    source is to a gap: without it the agent invents. Exception: `ghidra-mcp` for interactive
    exploration, not batch. Note: `--require` is model-executed doctrine at this stage; mechanical
    enforcement inside the driver wrapper is tracked as issue #253.
    TOOL-BEFORE-AGENT is the native/decompiler instance of the general WALL rule below.
  - WALL → TYPED BLOCK, NEVER SILENT SKIP (METHODOLOGY §21) — when the loop cannot proceed
    because a capability is missing (tool absent, format unsupported, path unreadable, subprocess
    timed out), record a typed wall state (`blocked-on-tool` / `unavailable` / `refused`) in
    RESEARCH-STATE and surface the gap PLUS the `install-tool.sh` fix to the user. Walk the
    declared fallback chain for the artifact class first (METHODOLOGY §21.2); record which rung
    produced the evidence so the coverage gap is explicit. Never skip silently, never pad `[INFER]`,
    never present a degraded-rung result as a full answer.
    TARGET'S OWN LAUNCHER/CLI OPTIONS RUNG (#645): before provisioning a replacement tool or
    declaring blocked-on-tool, enumerate the TARGET's own launcher/CLI pass-through flags (e.g.,
    `-@<option>` for Java VM pass-through, `--verbose`, `--debug`, `-Xjavaagent:` equivalents).
    Many targets expose native instrumentation that avoids new installs entirely. Check `<launcher>
    --help` or the vendor docs for a pass-through flag before requesting a new tool. This is the
    first rung of the fallback chain for live-launcher targets.
  - PROBE THE PREMISE BEFORE ACCEPTING `blocked-on-<tool>`. Before sealing a gap as blocked on a missing
    tool, first test the gap's PREMISE against artifacts ALREADY on disk — a block can DISSOLVE on premise
    failure rather than needing new tooling (G39 "blocked on leaf-cut-into-wall": 0/9 leaves had the
    assumed collinear gap, so the premise failed and the block evaporated — no tool was ever needed). This
    is the blocked-tag instance of GAP PREMISES ARE HYPOTHESES (BOOTSTRAP step e): a cheap on-disk probe
    can turn a tool-request into a closed premise error. (1 observed case; cheap sub-rule.)
  - DISK-FIRST (live probes) — when a gap registered as "needing a live probe" (§12) can be
    answered from on-disk artifacts (decompiled code, downloaded docs, preserved sources), prefer
    disk and only escalate to a §12 live probe after confirming disk cannot answer the gap question.
    This governs WHEN to spend a live probe, not which evidence is more trustworthy: `[CERT-hw]`/
    `[CERT-live]` still outrank `[CERT]` for identity/protocol questions (METHODOLOGY §3); DISK-FIRST
    applies only when disk evidence is sufficient to answer the gap at the required certainty.
    GATED-BY-DEPLOYMENT corollary: a self-built inbound scaffold (a probe, a test harness, a replay
    driver) validates the CODE and earns `[CERT]`, not `[CERT-hw]`; a passing code-level scaffold can
    coexist with a deployment that never instantiates the capability. Prefer DISK-FIRST followed by a
    deployment-instantiation check; if that check reveals the capability is not deployed, assign the
    GATED-BY-DEPLOYMENT verdict. See METHODOLOGY §12 (synthetic-stimulus / GATED-BY-DEPLOYMENT
    treatment) for the full framing — this corollary surfaces it at the DISK-FIRST decision point.
  - REAL-ARTIFACT-FIRST — SITUATIONAL: a gap about packaged-artifact shape (jar signing/META-INF, entry taxonomy, manifest) or INTENT of declarations: read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-measurement-and-claims` in full.
  - NAME-THE-JAR ⇒ OPEN-THE-JAR — SITUATIONAL: you are about to cite a JAR/DLL/archive by name as evidence of its contents: same section.
  - MULTI-MARKER BOOTSTRAP FUSION — SITUATIONAL: one claim is supported by several independent evidence markers: same section.
  - RE-MEASURE A DRAMATIC NEGATIVE — SITUATIONAL: an enumeration/join yields zero, near-total absence or an apparently dead/empty system (incl. IDENTIFIER-LEVEL SET INTERSECTION): same section.
  - NEVER COMPARE DIFFERENT LEVELS OR CUTS WITHOUT A DISCLAIMER — SITUATIONAL: you place two figures side by side: same section.
  - VERIFY-FIRST ON EXTERNAL DELIVERIES — SITUATIONAL: work reaches a third party (emailed report, cron sender, webhook, deployed endpoint): same section.
  - RE-MEASURE A DRAMATIC POSITIVE — SITUATIONAL: a live probe yields a striking positive (apparent weakness, open/downgraded service), an aggregate concentrated on one day, or you report a period total or delta (headline aggregate; CONCENTRATION CHECK): same section.
  - DERIVED-VIEW INCONSISTENCY / IMPLAUSIBLE MAGNITUDE — SITUATIONAL: derived views disagree, or a count is implausibly large for the system: same section.
  - N-SEARCH CONVENTION TRIGGER — SITUATIONAL: N>=3 independent search strategies returned zero for the same feature: same section.
  - TWO CORRECT COUNTS THAT DISAGREE = CONVENTION SIGNAL — SITUATIONAL: two independent positive counts of one feature disagree: same section.
  - GROUPING-RULE DOMAIN (#611) — SITUATIONAL: you reuse a grouping/clustering rule on a different shape class: same section.
  - NEGATIVE-ABSENCE CLAIM DISCIPLINE (#732) — SITUATIONAL: you record a negative existence claim ("no X found") or retract a finding on absence (incl. CENSUS TOKEN): same section.
  - VENDOR-DOCUMENTED PORTS FIRST (#670) — SITUATIONAL: before the first connection attempt against a live target: same section.
  - CONCURRENT-SWEEP DISJOINT FILE SETS (#644) — SITUATIONAL: you parallelize agent sweeps: same section.
  - NEVER MERGE A DUE CANDIDATE BEFORE ITS REVIEW (#1272). Before any merge run
    `$KIT/toolbelt/merge-gate.sh --cwd <worktree at the PR head> --base-ref <PR base> --pr <PR#>` (or
    `--merge <PR#>` to let it merge) and merge only on a PR-bound `allow` (line ends `bound to PR #N`);
    a run without `--pr`/`--merge` is range-only and trusts your `--base-ref`. `refuse: review_due` = review
    and acknowledge that exact head first; `refuse: base_excludes_pr_commits` = your base hides PR commits;
    `degraded` (exit 3) is never an allow. Details: `PROMPT-LOOP-APPENDIX.md#review-and-delivery`.
  - A gap entry closed as `blocked` or `absent` must carry a `tried:` clause listing the alternatives
    attempted and what measurement ruled out each route. An absent/blocked entry with no `tried:`
    clause is unfinished: it bounds one path, not the question. (Complement of the `needs:` clause.)
  - OFFENSIVE/DUAL-USE GAP DESCOPING. When a gap is descoped because investigating it would produce
    offensive or dual-use findings (an attack vector, an exploit path, a capability that enables
    harm), do NOT remove it from the backlog silently. Mark it `blocked-on-dual-use` in
    RESEARCH-STATE with the descope reason so the decision is visible to peer sessions and future
    runs. The descope reason occupies the `tried:` position required by the blocked-gap rule above
    — e.g. `tried: descoped — dual-use, <one-line reason>` — so the entry satisfies both rules.
    A silently-deleted gap is indistinguishable from a gap that was never discovered;
    `blocked-on-dual-use` preserves the evaluation record without propagating the harmful content.
    CROSS-SESSION BOUNDARY (#741): a peer or subsequent session cannot override a boundary
    (refused/descoped step) that a prior agent recorded without an explicit operator decision
    captured in the block. A `blocked-on-dual-use` or `refused` verdict carries session-level
    finality; resolving it requires the operator to record the authorization in the block before
    the step proceeds — not just a re-attempt by a different agent in the same run.
  - SECRETS DISCIPLINE (live-install targets) — when the target is a REAL running installation/station,
    not a distributable artifact (TARGETS.md marks it `live-install`), NEVER extract or write credentials,
    keys, keyring/keystore material, tokens, or secrets into a block, sources/, or engram. Cite the
    STRUCTURE (where a secret lives, its format, how it's used) — never the secret VALUE. Zero secrets
    exfiltrated is a hard invariant; a real install carries live credentials a decompiled jar does not.
    REDACTION CHECKLIST (live-install / firmware — WHAT to redact; the rule above is HOW): cite structure,
    never value, for · admin/root password HASHES (Unix crypt `$1$`/`$5$`/`$6$` in `/etc/shadow` or a config
    backup) · WPA/WPA2 PSK and other wifi/link pre-shared keys · cellular IMEI/ICCID/IMSI and APN credentials ·
    VPN keys/certs/peer addresses (WireGuard/IPsec/OpenVPN) · INCIDENTAL THIRD-PARTY NEIGHBOR IDENTIFIERS —
    neighbor SSIDs/BSSIDs/MACs a LAN or wifi scan sweeps in are OTHER people's networks, not the target's;
    redact them too (non-obvious: a scan pulls them in for free).
    SCOPE EXTENDS beyond the `live-install` target: apply the same "cite structure, never value" rule
    to the operator's own environment (`~/.cloudflared/`, shell dotfiles, keyrings) and to relayed peer
    material (a config a colleague sent). The rule is unchanged; only the trigger broadens.
    (Source: 2026-09-03-obix-and-loginless-dashboard-runbooks-retro.md D2)
  - LIVE-SESSION ACCESS RECIPE — SITUATIONAL: live-install / Niagara target at run START before the first live probe, or any live probe that needs credentials, a redacted copy, a raw disk/media image, a binary-format check on a secret-bearing file, a config write on a live target, a credential appears in the conversation (the exfil-surface rule), or on every archive (the archive secrets gate): read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-live-install-access-recipe` in full.
  - ONE block per iteration (deep and cited, not wide and vague).
  - RE-MEASURE GROUND-TRUTH — SITUATIONAL: you enter a DYNAMIC/hardware phase or any new live measurement (checksums, versions, IPs, build ids): read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` in full.
  - RESUME, don't blindly redo. After a kill/crash/interruption of an iteration, FIRST check
    `git -C $TARGET log` + on-disk artifacts to see whether that iteration already LANDED its commit
    before re-launching it — resume from real state.
    See METHODOLOGY §17.
    BLOCK PLAN RESUME: if a `$TARGET/.research-sdd/plan/current-plan.txt` exists for the in-progress block, verify each ticked item's artifact exists
    (a ticked item without its artifact is unticked again), then continue at its first unticked item. STALE only if `git -C $TARGET log <opened-at>..HEAD -- <block file>` is non-empty (`opened-at` and the block file are recorded in the plan header; a merely tracked block file is NOT staleness): delete the plan and resume from RESEARCH-STATE.md — never re-run its steps (METHODOLOGY §20, "Block plan"). FAIL CLOSED: if that `git log` cannot run (unresolvable `opened-at`, unfilled placeholder, no repo), staleness is unknown — stop and ask; never treat the plan as fresh or stale. S5's artifact is its grep-checkable catalog/index/state keys, and S5 is idempotent (edit in place, never append twice).
  - LOOP CONTINUATION — after every iteration, evaluate the stopping criterion (METHODOLOGY §8). While
    work remains (read-only-investigable > 0, or any campaign queue entry is `pending` or `active`), start the
    next gap; the continuation call (per mode below) is the last action of the turn, after the
    iteration report. A focus stop does not end a campaign: run the FRONTIER-REOPEN audit (heavy/frontier modes), enqueue any
    new entries, and pop the next queue entry in the same run (METHODOLOGY §8c).
    A RUN ends only on campaign STOP, a requires-execution wall, an operator pause, or a tool failure;
    a TURN ends after the mode continuation call (ScheduleWakeup / harness re-fire / RETURN CONTRACT token).
    Finishing a cluster or milestone is not a RUN end. Before ending a turn, check your last paragraph: if it is a plan
    ("next I'll …"), execute that work now with tool calls.

    Three cases based on launch mode:
    (1) FIXED-INTERVAL (`/loop <N>m`, e.g. `/loop 5m`): the harness is the re-invoker; it fires the
        next turn automatically. Do NOT issue ScheduleWakeup — a self-reschedule on top of the harness
        re-fire would double-fire iterations. End the turn after the iteration report. Ensure each
        iteration is idempotent: if the harness re-fires while nothing is pending (campaign STOP
        already met, state already committed), the iteration recognises that from real state and stops
        cleanly. Teardown runs at campaign STOP (not at each focus stop): when campaign STOP fires
        under a fixed-interval `/loop`, the harness cron keeps re-firing — token drain. Disarm the
        re-invoker as part of the campaign STOP declaration: use CronList to find the cron job whose
        prompt is this loop, then CronDelete to remove it. If the harness offers no such tool, tell
        the operator explicitly to cancel the loop. A re-fire that finds campaign STOP already met
        disarms and ends (idempotent).
    (2) DYNAMIC self-paced (`/loop` with no interval, or plain self-paced in session): the re-fire
        depends on the agent calling ScheduleWakeup. The runtime ends the turn when the agent emits
        text without a following tool call (#620), so ScheduleWakeup is the last action of the turn,
        placed after the iteration report text. At campaign STOP, do not reschedule.
    (3) ORCHESTRATED: end the iteration report with the RETURN CONTRACT token (`next: <gap-id>`,
        `next-entry: <queue-name>`, or `STOP: campaign — …`); the driver re-invokes on `next*`
        tokens and ends on `STOP:` tokens. No ScheduleWakeup is issued in orchestrated mode.
    ONE BLOCK PER COMMIT, too: even if a delegated sweep returns material for more than one
    queued gap in the same turn, each block gets its OWN commit and its OWN STOP-criterion re-check before
    the next is written — do NOT land two block files in one commit just because both sweeps returned
    together. COMMIT MESSAGE: `research(<target>): B<n> <short-gap-slug>` (multi-focus §16 disambiguates in the
    scope: `research(<target>/<focus>): B<n> <slug>`); OPTIONAL body line = coverage ratio + marker tally.
    Commit DIRECT to the default branch — a solo corpus needs no PR (METHODOLOGY §15). One commit ⇄ one block
    is what makes §17 resume answerable from `git log --oneline`. (Under fixed-interval this means
    ending the turn after the report; under dynamic self-pacing this means calling ScheduleWakeup with
    the same prompt; under an orchestrator this means emitting the RETURN CONTRACT token. Either way, one report ≠
    done — see METHODOLOGY §8.)
  - RESCHEDULE CADENCE — applies to DYNAMIC self-paced mode (no interval) only; fixed-interval mode has
    no ScheduleWakeup to tune (the harness interval governs re-fire timing). The next gap is READY WORK,
    not an idle poll. When you reschedule under dynamic self-pacing, use the SHORTEST delay (~60s, the
    floor), NOT the 1200-1800s idle-tick default. A short delay also keeps the prompt cache warm
    (≤300s), so back-to-back iterations are cheaper AND faster. Only stretch the delay when you are
    genuinely BLOCKED waiting on something external (an install building, a live server coming up) —
    never just to space out ready decompilation work.
  - BASH-TOOL PATH NOT PERSISTENT — SITUATIONAL: a native tool (decompiler, scan utility, custom script) lives off the default PATH, you set PATH/env in one Bash call for use in a later one, or a tool is "command not found": read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` in full.
  - WAKEUP GUARD (self-paced mode): before issuing a ScheduleWakeup, check whether one is already
    armed for this loop — do not double-schedule. One armed wakeup per iteration is the invariant.
    (Distinct from the "ScheduleWakeup for autonomous mode only" rule above — that governs WHEN to
    use it; this governs how many.)
  - INSTANT CAPTURE — SITUATIONAL: a kit defect, capability idea, algorithm, formula or process insight surfaces mid-loop (save it with `mem_save` BEFORE the loop continues): read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` in full.
  - Preserve all external evidence in sources/ before citing it.
  - Corpus language: ENGLISH by default. EXCEPTION: if TARGETS.md marks this target with a
    user-approved language override (currently: logosoft, hilton-bms → Spanish, for continuity of mature
    Spanish corpus), write blocks in THAT language. Otherwise English. Do not infer exceptions.
    BOOTSTRAP commits the language in the TARGETS.md row (BOOTSTRAP step b). A mid-run switch is
    a structured override: PROPOSE the TARGETS.md row refresh (the supervisor applies it; propose-never-apply, kit #1992)
    and note the transition block number and
    reason — not a prose RESEARCH-STATE comment; a silent switch leaves a split-language corpus
    whose blocks are non-uniformly searchable. [Evidence: logosoft B1–B65 Spanish → B66–B77
    English, recorded only in a RESEARCH-STATE prose note, leaving rg/grep across blocks unreliable.]
  - PKILL -F WRAPPER-SHELL MATCH — SITUATIONAL: you are about to kill, pgrep or stop a process, or report a job stopped (incl. VERIFY KILL BEFORE REPORTING, OPERATOR-SESSION SAFETY): read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` in full.
  - OBJECTIVE-LOCK — SITUATIONAL: the operator has stated an explicit objective, and while it holds every iteration states one line mapping its action to it (side-defects become typed `side-defect:` backlog rows, fixed only as incident handling): read `$KIT/PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` in full.
RETURN CONTRACT (per-iteration CHECKPOINT — NOT a terminal hand-off; keep looping per LOOP CONTINUATION):
  retro: not-due | written <retros/<file>> · verify-retro: PASS   ← mandatory on the FINAL return of a run (see RETRO CHECKPOINT)
  SHAPE: one-line checkpoint, then CONTINUE. The per-iteration report is a brief checkpoint followed
  immediately by the next iteration — NOT a milestone recap or a narrative summary of what has been
  accomplished so far. Expanding the report into a milestone recap is the observed trigger for a
  premature turn-end: the agent fills its context with summary prose, then stops instead of
  continuing. Emit the minimum fields below and proceed.
  Keep the per-iteration report CONCISE — full detail lives in the block, NOT the report
  (a huge report bloats context for no gain). This report closes ONE iteration; unless STOP fired, the
  next iteration starts right after it. Report ONLY:
    - status (done / blocked / partial),
    - the gap closed,
    - the block path + a ONE-paragraph summary of what it found,
    - the self-verify tally (tokens checked, marker counts, [INFER]/[CERT] ratio),
    - the MODEL TIER you used for any delegated sweep (haiku/sonnet/opus), or `inline (constraint:
      <reason>)` when an external re-invoker exists and inline was chosen deliberately — declaring it
      is mandatory; an unstated tier means the rule was skipped and the sweep silently inherited the
      driver's model,
    - any TOOL DECISION made this iteration (installed, adapted, created, or outgrown) — one line:
      `T<n>: <name> · <path> · WHY (used/adapted/downloaded/created/updated)`. This is the moment the
      WHY is cheapest; a retro reconstructing tool decisions from memory is a post-hoc rationalization,
    - artifacts touched (block, CATALOG, INDEX, RESEARCH-STATE, sources/),
    - BREAKTHROUGH (if demonstrated this iteration): name the proven recipe as a distinct
      `Breakthrough: <one line>` field — do not bury it in the block summary. METHODOLOGY §22
      defines the marker and the ledger; this checkpoint ensures the report surfaces it explicitly,
    - CONTINUATION TOKEN (required): end every report with exactly one of:
        `next: <gap-id>` — the next gap in the current focus (loop continues within this focus),
        `next-entry: <queue-name>` — campaign continues to the named §8c queue entry (focus STOP),
        `STOP: campaign — <reason>` — when campaign STOP fires (no entry pending or active, audit
          enqueued=0, AND — on a multi-focus heavy/frontier corpus, §8c — the campaign-close
          partition check reports no genuinely unchartered unit),
        `STOP: campaign-bound-reached: <which>` — when a declared campaign bound fires.
      When `research-sdd-status.sh <target> --next --emit-token` is available, copy its `return-token:` line verbatim; never compose the token by hand. If it prints `return-token: unavailable (<reason>)` (exit 1), that line is NOT a token: resolve the named state first (RETRO-DUE, ISSUES-DUE, STALE, BOOTSTRAP per their rules) and re-run; for a multi-focus or campaign-queue STOP, derive `next-entry:` / `STOP: campaign` from the §8c queue as this contract defines. A STOP ending in `[backlog-unreadable: …]` is never a `STOP: campaign` token: it gets `unavailable` until the backlog is reconciled (`--sync-state`) and `--next` is re-run.
      Enforcement: once wired (kit issue #1732, `research-sdd-init.sh --wire`), `$KIT/toolbelt/return-token-gate.sh` runs as a second Stop hook and blocks the session ONCE when the final report's token is missing or differs from the provider-issued one, quoting the exact line to copy; a deliberate difference needs a `return-token-override: <reason>` line.
      A report that ends without any token is a halted-but-silent stop: the operator has no
      signal to distinguish "checkpoint, continuing" from "stopped". Never substitute a question
      ("shall I continue?", "want me to go on?", or any variant) for the continuation token —
      in a research-loop flow this is a contract violation, not politeness; the loop self-continues
      until STOP fires explicitly (SKILL.md "answer is almost never a question back").
  Do NOT paste the block body, long decompiler dumps, or full file contents into the report.
```

---

## Operational notes

- **One iteration = one block.** The value of the loop is disciplined accumulation, not haste.
- **Kit work-unit close checklist** (run in order; the PR template carries the same boxes):
  1. Before opening a PR whose diff is over the ~400-line budget:
     `$KIT/toolbelt/plan-review-slices.sh --cwd <worktree> --base-ref origin/main [--max-lines N]`
     (report-only; each slice is a candidate PR/review unit; an `UNSPLITTABLE` commit is a human decision).
  2. Before merging: `$KIT/toolbelt/merge-gate.sh --cwd <worktree at the PR head> --base-ref origin/main --merge <PR#>`
     instead of a bare `gh pr merge`; merge only on an `allow` bound to the PR, and treat `refuse:` or
     `degraded` (exit 3) as a stop. Semantics: `PROMPT-LOOP-APPENDIX.md#review-and-delivery`.
- **The backlog feeds itself**: investigating a gap almost always uncovers others; that is why the
  stopping criterion requires 2 empty iterations in a row.
- **Mature targets** (e.g. `niagara-research`) already have INDEX/hook: the loop continues from their
  gaps. **Incipient targets** trigger the BOOTSTRAP.
- **Multi-focus targets**: a large/mature target may carry several parallel focuses, each with its own
  `RESEARCH-STATE-<focus>.md` and a small focus index. State the active focus when you continue, and
  mirror to the TARGET's own engram `project`. Convention in METHODOLOGY §16.
- **ghidra-mcp** (agent-directed decompilation) requires the Ghidra server alive at `:8089`
  and restarting Claude Code; for batch/triage `decompile-native.sh` is enough (see `toolbelt/GHIDRA-MCP.md`).
