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
      (§11); spot-check only when a report smells off. (Proven: ~30 delegated sub-agents in the
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
     returns one line — `NEXT | <priority> | <gap>` (investigate it),
     `STOP | <reason>` (§8 exhaustion; when reason contains `[issue-coverage: unverified]`, issue coverage
     could NOT be verified — see below; treat as complete with unconfirmed coverage, advisory not a hard block),
     `STALE | <reason>` (envelope/backlog inconsistent — run `$KIT/toolbelt/research-sdd-status.sh $TARGET
     --sync-state`, reconcile, and retry; do NOT proceed on STALE), `BOOTSTRAP | <reason>`,
     `RETRO-DUE | <focus>` (the focus has crossed the §18 blocks-since-retro threshold — delegate the §18
     retro as the CURRENT iteration before resuming normal gaps; the retro is mandatory, not optional — see
     RETRO CHECKPOINT under step 7's TERMINAL TRIGGER. `--next` emits RETRO-DUE automatically once
     `blocks_since_retro` crosses the §18 threshold (kit issue #627 — landed); trust the emitted
     state, no manual threshold check is needed), or
     `ISSUES-DUE | <N> untracked delta(s) in <retro> — seed: stage-retro-issues.sh <retro> --apply`
     (issued when exhausted work would otherwise STOP, but the named retro has deltas not yet tracked as open
     GitHub issues; early-exit on the FIRST such retro found — remaining retros are NOT probed, count and path
     are scoped to that one retro only; `--next` precedence: STALE → RETRO-DUE → NEXT → ISSUES-DUE → STOP).
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
      may render entire blocks retroactively wrong. (Evidence: blender-llm B66–B67.)
  b. Determine which system it is, where its real sources/binaries are, and the corpus language. REGISTER
     the target in $KIT/TARGETS.md's master table right here (row: #, target, path, maturity, predominant
     artifact type, toolbelt wrapper, corpus language) — as part of bootstrap, NOT later: the retro sweeper
     `toolbelt/sweep-retros.sh` derives its ENTIRE scan list from TARGETS.md, so an unregistered target's
     `retros/` dir is invisible to the §18 supervision sweep (lesson: three.js — unregistered focus). Keep that row a
     LIVING MIRROR, not a one-time write: when a run-STOP or a §14 correction changes a fact mirrored there
     (block / run / retro / file counts), REFRESH the row as part of closing that run or correction —
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
      DESIGN/APPLIED" in the focus header so the distinction is visible at sweep time. (Evidence: B611–B619.) (Small/
      incipient single-artifact targets: skip — the artifact is the angle.)
  c. SCAFFOLD (mechanical — replaces the old by-hand mkdir/copy/git-init steps):
     `$KIT/toolbelt/research-sdd-init.sh $TARGET [--corpus auto|nested|flat] [--prefix <slug>]`. It resolves
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
  e. POPULATE the scaffolded $CORPUS/RESEARCH-STATE.md (step c laid the empty template) with an initial
     research-plan: 5-15 high-priority gaps (the fundamental questions about the system). Mirror the
     gaps in engram research/<target>/gaps.
     OPTIONAL: you MAY declare `campaign_bounds:` in Stop control at this point if the operator has
     specified campaign limits (max-depth, iterations, wall-clock). Absent line = no bounds; do not
     pre-fill if no bounds were requested. (Grammar: see METHODOLOGY §8c. Example:
     `campaign_bounds: max-depth=3 iterations=50 wall-clock=8h`.)
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
     the relative size is auditable. (Evidence: apis focus.)
     AUDIT BOOTSTRAP PRODUCTION SCOPE. When opening an AUDIT focus — a focus whose purpose is to
     assess the security, correctness, or compliance of a set of artifacts — establish FIRST which
     of those artifacts are actually deployed in production. Severity ratings for findings in
     artifacts not deployed carry no operational weight; an audit whose production scope is undefined
     is ungrounded. Confirm scope from a deployment manifest, a running process list, or an
     installed-package check BEFORE deriving priorities from the audit matrix findings. (See also
     the GATED-BY-DEPLOYMENT corollary under HARD RULES DISK-FIRST / METHODOLOGY §12, which applies
     the same deployment-instantiation check at individual-block verdict time rather than at
     bootstrap.) (Evidence: niagara own-modules-audit.)
     FILTER-CALIBRATION DOMAIN. Any classification filter, threshold, or scoring function calibrated
     against ONE corpus subset implicitly defines that subset as its universe — a gap that falls
     outside the calibration population may register as absent without a WARN. Before applying a
     filter derived from one population to a broader corpus, STATE the calibration domain explicitly
     in the sweep prompt or the gap description. A filter whose coverage domain is undeclared is an
     instrument whose false-negative floor is unknown. (METHODOLOGY §6 licenses calibrated
     discriminators as symmetric and reusable within the same artifact kind; cross-kind reuse
     requires re-stating the calibration domain — that is the boundary this rule marks.) (Evidence: blender-llm B21–B37.)
     FILTER INHERITANCE PROHIBITION — never derive a filter's calibration envelope from a
     population that an EARLIER filter produced; derive it from the raw universe, or declare the
     inheritance chain explicitly AND verify the chained result against the raw universe before
     using it. A filter calibrated on a filtered population silently inherits its predecessor's
     blind spots by construction and cannot detect what the earlier filter excluded. (Evidence: blender-llm B61.)
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
     different. (Evidence: B495 §495.3.)
     SWEEP HYPOTHESIS HIGH-RISK SUBCLASS — security-bypass claims and surprising existence
     claims from the audit sweep are higher-risk premises than average: the sweep cannot read
     deeply enough to certify either. Label every security-bypass or existence surprise from the
     sweep "(sweep hypothesis — measure first)" in the gap description; never embed the sweep
     phrasing as a partial assertion or a confirmed claim. A gap description that reads "X bypasses
     the Niagara session" is an ungrounded security verdict; one that reads "X bypasses session
     (sweep hypothesis — measure first)" is honest about its source and scope. (Evidence: B622 §622.3, B624 §624.3.)
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
     assert a count. (Evidence: access-control sweep AC3/AC4.)
     BASE-MODULE IDENTIFICATION (extends the audit sweep — add as a sweep sub-task): for each
     gap the sweep surfaces, require it to also ask: "is this module a specialization of a generic
     or base module, and if so, is that base module covered in the corpus?" When the base is NOT
     covered, surface it as a SEPARATE candidate gap in the backlog — do not fold it silently into
     the specialized gap. A missing base module discovered during block writing costs one full
     iteration; discovered during the sweep, it costs a one-line backlog addition. (Evidence: provisioning focus — PV1/PV7.)
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
     directory layout or a manifest, not the filename alone. (Evidence: B386 §386.2.)
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
     `pdftotext` dump) instead of citable `sources/...pdf :p.N` anchors (lesson: WEB-HMI10-CF). Not applicable to targets with no PDFs; a mixed
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
     relevant page in the table. (Evidence: niagara optimizer-docs — family block.)
     RELEVANCE-TRIAGE CHECKPOINT (PDF CORPUS). When a documentation corpus mixes a small set of
     high-relevance goal documents (product manuals, design specs, protocol references) with a large
     bulk of low-relevance material (marketing datasheets, compliance certificates, unrelated
     application notes), run a TRIAGE PASS before auto-processing the bulk: rank the full set by
     relevance to the declared investigation angle, identify the high-relevance documents and the
     bulk, and present the operator a go/no-go decision before spending extraction time on low-value
     PDFs. (Evidence: niagara optimizer-docs — triage.)
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
     (Evidence: blender-llm B57 §57.1.)
     PER-ITERATION VALUE GATE: before starting investigation, classify the gap as MECHANISM (behavior,
     code path, protocol) or REFERENCE-CATALOG (a table of SKUs, address maps, register layouts, data
     sheets with no behavioral question). Reference-catalog gaps get a `catalog-batch` qualifier in
     RESEARCH-STATE and are deferred to a dedicated reference-batch iteration that may author multiple
     blocks in one pass; the one-per-commit main loop runs mechanism gaps only. Do not spend full
     mechanism-loop overhead on a gap whose answer is a structured table with no behavior to reason
     about. (Evidence: niagara B899–B928.)
  2. PROFILE: based on the gap's artifact type, pick the wrapper (tool-registry.md).
  3. INVESTIGATE (READ-ONLY), combining whatever is needed:
       - PRIOR COVERAGE CHECK: before any tool sweep, read corpus blocks whose INDEX.md description
         overlaps this gap — especially the block that opened it. Step 5's pre-loop INDEX.md read
         names blocks; this check reads them. Cost: one targeted block read per gap. (Distinct from
         the sub-agent scope rule in VERIFY BEFORE ACTING below, which validates negative findings
         after the sweep. Evidence: B279 ran module-navigator before reading B133, which already
         documented the JNI boundary; required a §279.9 self-revision.)
         REMITTANCE-RISK FLAG: when the PRIOR COVERAGE CHECK finds partial corpus coverage for a gap
         but cannot determine whether genuine new substance exists, flag the gap as REMITTANCE-risk in
         the backlog and include this flag in the sweep prompt: "check REMITTANCE FIRST — state whether
         this gap is fully answered by [Block N] §N.x with no new substance, BEFORE any tool use." A
         sweep that returns 'REMITTANCE — no new substance, cite [Block N] §N.x' is a valid closure;
         the driver closes without authoring a block. This prevents wasted investigation if the gap is
         remittance at fine grain even when the audit cleared it at coarse grain. (Evidence: apis focus API5/API6/API8.)
         REMITTANCE-TO-EVIDENCE UPGRADE: when the PRIOR COVERAGE CHECK finds a gap already answered
         but only at [CERT-web]/[CERT-a]/[INFER] (asserted from docs or memory), reading the PRIMARY
         SOURCE to lift the same claim to [CERT] is genuine new substance — NOT a remittance. The
         marker-tier upgrade justifies authoring a new block even though the coverage question is
         settled. The kit's existing "escalate a critical [CERT-a] before accepting" rule (step 5) and
         the CORROBORATION-FROM-INDEPENDENT-STORE pattern (step 5 self-verify) handle the after-the-fact
         case; this rule names the before-the-block case: a tier upgrade is a valid gap-closure path,
         not a wasted iteration. (Evidence: blender-llm B10, B4 §4.2/§4.5.)
         OPERATOR-CLASSIFICATION-FIRST: before building an extractor or classification filter for an
         operator's data package, check whether the package already carries a pre-existing human
         classification column (e.g. `Clase provisional`, `Revisión humana`, or any manually reviewed
         label field). A human classification is a REFERENCE STANDARD the extractor can be scored
         against — do not build a filter first and lose that calibration opportunity. (Evidence: blender-llm B61 vs Dep_Ductos_crudos.)
       - SCOPING JUDGMENTS ARE HYPOTHESES: a prior block's recorded reason for NOT investigating
         further ("X is not load-bearing", "Y would add only implementation detail", "decompilation
         would add only the exact argv-dispatch order") is a testable HYPOTHESIS, not a settled
         boundary — the same family as GAP PREMISES ARE HYPOTHESES (BOOTSTRAP step e). When the
         cost of a targeted follow-up is low (e.g. one decompile pass or one block), TEST the
         judgment before accepting the closure. If a test REFUTES the judgment, issue a §14
         correction on the prior block with a back-pointer. Evidence (retro 2026-08-07): B381
         refuted B129 §129.7's "decompilation not load-bearing" — a scope-out that held unchallenged
         for six weeks; the actual function bodies surfaced LocalSystem account, SERVICE_AUTO_START,
         argv-passed passphrase, DPAPI-no-entropy, and REG_BINARY under HKLM — all load-bearing
         security facts. A scope-out that costs one iteration to test is cheaper than six weeks of
         missed findings.
       - READ THE RESIDUE BEFORE THEORISING: before forming a theory about why a remainder does not
         fit — an unexplained bucket, a residual set, un-opened columns — READ those items first. A
         theory built on unread data is [INFER] from zero evidence; the actual contents often disprove it.
       - ANNOTATION-BEFORE-DERIVATION: before deriving a quantity from a labelled source (CAD drawing,
         schematic, datasheet), exhaustively search the annotation layer for a label that already carries
         that value — size callouts, elevation/BOD tags, dimension strings. A quantity you are about to
         derive is a hypothesis that no label exists; prove that absence before spending derivation
         effort. Absence proved from ONE regex or ONE search strategy is not proven absence — see
         RE-MEASURE A DRAMATIC NEGATIVE (HARD RULES) and GAP NUMBERS ARE ALSO HYPOTHESES (BOOTSTRAP e).
         (Evidence: COB-IM2 B6/B8, commit `d7fd595`.)
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
         (Evidence: blender B6.)
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
       - DELEGATION, SUB-AGENT VERIFICATION & MODEL TIER — SITUATIONAL: read `$KIT/PROMPT-LOOP-APPENDIX.md`
         §step3-delegation IN FULL when you are about to delegate a sweep to a sub-agent, choose or
         declare its model tier, verify a sub-agent's returned report, or evaluate a sub-agent's
         absence/count/operational claim. Covers: the default-delegate threshold (secrets/config-
         artifact/quick-mode/combined-sweep/sibling-gap/recursive-fan-out variants), VERIFY BEFORE
         ACTING (offset/hidden-flag/scope/external-repo/peer-catch/re-derive/claim-reversal sub-rules),
         WEB-RESEARCH DISCOVERY-ONLY, MODEL TIER (+ nested sub-sweeps), LONG BUILD DELEGATION, PRE-TEST
         POPULATION ANATOMY, FALSIFY BEFORE REPORTING (+ decommission subcase), REACHABLE ≠
         REPRESENTATIVE(-DEFAULT), CROSS-FOCUS SECURITY FEED. Not needed for a small inline gap with no
         delegation and no sub-agent report to verify. (kit issue #1003, slice 1.)
  4. WRITE ONE BLOCK: create/update $CORPUS/<prefix>-blockN.md following the anatomy
     ($CORPUS = corpus root: default $TARGET, or $TARGET/corpus/ for an in-project target — METHODOLOGY §15)
     ($KIT/templates/block.template.md). Each claim with its marker and its citation:
       [CERT-hw] sources/probes/... (highest) · [CERT-live] live remote-service response (§12b) ·
       [CERT] file:line · [CERT-doc] sources/...pdf §N · [CERT-web] URL+date · [CERT-a] forum (URL) ·
       [INFER] deduction.  (canonical list: METHODOLOGY §3)
     LOCAL DOC CORPUS CITE DISCIPLINE: at the first `[CERT-doc]` claim in a block that draws from a
     new local doc corpus (sources preserved under `sources/manuals/<focus>-docs/`), cite by the FULL
     HTML basename exactly as registered in the SOURCES.md row — NOT a doc-title shorthand or a
     truncated form. METHODOLOGY §5 encodes this at the registry level; this surfaces it as a prompted
     gate at the per-block cite-point so a sub-agent does not have to remember the §5 policy
     independently. (Evidence: B336 `e975837`.)
     Include the Connections section linking related [Block K].
     For doc-synthesis blocks (where `[CERT-doc]` is the primary source), OPTIONALLY add a closing
     section — e.g. "§N.x — What this doc does not resolve" — listing findings the official document
     is silent about, cross-referencing corpus blocks whose evidence the guide omits. Vendor guides
     document the happy path; decompilation reveals failure modes the guide never mentions.
  5. SELF-VERIFY + REPORT (in-block gatekeeping — see METHODOLOGY §11; the orchestrator does NOT run
     Bash gatekeepers, it TRUSTS this report. Per-block orchestrator Bash re-checks cost permission prompts
     and — proven on the protocols run — caught NOTHING; the real error capture mechanism is cross-block
     correction §14, not a per-iteration re-verify. Only spot-check when a report smells off). Before closing,
     DO and REPORT:
       - MECHANIZE the counting: run `$KIT/toolbelt/verify-block.sh <block>` and paste its output — the
         marker tally, [INFER]/[CERT] ratio and [CERT] file:line citation-resolution are COMPUTED, not
         remembered (it exits non-zero on a cited file:line whose line is out of range). It is your own
         calculator, not an orchestrator gate.
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
         version cascades to wrong feasibility verdicts. (Evidence: B616/B617.)
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
         registration gets skipped (evidence: niagara/email B334; commit `11142b9`).
         SAME-COMMIT CHILD-GAP RULE (extends SYNTHESIS-BLOCK REGISTRATION RULE): register all child
         gaps surfaced by a synthesis block in RESEARCH-STATE in the SAME commit as the synthesis
         block itself. A gap named in the synthesis report but absent from RESEARCH-STATE at commit
         time is invisible to `verify-state.sh` and may be permanently lost if the session ends
         before a planned follow-up registration. This also applies to any iteration, not only
         synthesis: whenever "New gaps uncovered" is non-empty, the backlog rows must exist in the
         same commit. (Evidence: B413; commit `a852383`.)
       - REVERSE BACKLOG SWEEP: after closing a gap OR retiring a §14 premise, re-read the open
         backlog and re-scope or rename any gap whose PREMISE this block just answered or invalidated.
         A gap that was opened as "is X true?" becomes stale if this block proved X false — it must
         be updated or closed, not left as-is. This sweep is PREMISE-driven and distinct from the
         NEXT-ITERATION ARCHIVE AUDIT (which checks bookkeeping counts — gap totals, marker sync);
         the archive audit catches accounting errors; this sweep catches semantic drift in the
         backlog itself. Run it inline, not as a separate pass.
         REMITTANCE GAP REOPENING: METHODOLOGY §8 defines remittance as a gap-closure category
         that avoids writing a redundant block — so there is no "remittance block" to upgrade.
         When a gap closed-by-remittance later gains direct evidence that confirms the remitted
         claim, REOPEN the gap in RESEARCH-STATE (set status back to `pending`) and close it by
         NEW investigation in the normal cycle. The new block cites the prior remission chain in
         its Connections section (e.g. "original gap closed-by-remittance to [Block N] §N.x;
         now confirmed directly"). Record the reopen + reclosure in the iteration-history row.
       - BACK-FILL SOURCES.md's "Citing blocks" cell — when this block cites a source registered in SOURCES.md
         (this iteration, or an earlier one whose trailing cell is still blank), write THIS block's ID into that
         row's last column before closing the iteration. `fetch-doc.sh`'s `reg()` leaves the cell blank by design
         (a later manual back-fill); leaving it blank silently disables `verify-sources.sh`'s FABRICATED-citation
         cross-check for that row — the check only cross-validates rows that DO list a block (METHODOLOGY §5).
         PRESERVATION-SURFACES-CORRECTIONS: a §5 debt-closing pass that verifies bare-URL citations
         routinely surfaces link drift (a repo rename, an issue state change, a moved page) that
         demands §14 corrections on prior blocks. Budget for those corrections when scoping a
         preservation gap — do not treat them as scope creep; they are the expected second-order
         output of a careful preservation pass. (Evidence: blender-llm B15, B2/B3.)
       - RECORD the iteration in RESEARCH-STATE's Iteration history table INCLUDING the delegated? · model
         tier column (no·inline / yes·haiku|sonnet|opus) — persist the tier on disk, not only in the report,
         so tier-compliance stays auditable after the session ends. For an EXTERNAL-source iteration, record the
         e3 SCOUT VERDICT in the same row too (`scout: CERTIFIABLE-NOW`, or `scout: CERTIFIABLE-NOW ×N` for
         parallel scouts) — same reason as the tier: an unrecorded verdict makes e3-compliance unauditable after
         the session, even though authoring was gated on it.
       - CLASSIFY the whole backlog into investigable vs blocked-on-<reason> (tool-missing / x64-tool /
         live-server / hardware) and record both counts in RESEARCH-STATE.md.
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
         root — no per-target copy; research-sdd-archive.sh does this on close). Mirror to engram (research/<target>/gaps, .../progress).
       - NEXT-ITERATION ARCHIVE AUDIT (orchestrated-auto): each iteration is a FRESH sub-agent that reads
         INDEX/RESEARCH-STATE from scratch, so before appending YOUR entry, check the PRECEDING iteration's
         bookkeeping (its block-table row, file/gap-count totals) is complete and consistent — repair it as
         part of THIS archive step if not. Distinct from §14 (audits claims) and §17 (resume after a crash):
         this catches archive-bookkeeping drift between one iteration's close and the next's open.
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
     obligation at every STOP gate. (Evidence: platform-native reopen.)
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
     run cannot replicate. (Evidence: #564.)
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
         —, or the DYNAMIC/hardware phase §12) — and, if that next phase is
         itself autonomous and safe, launch it; if it needs a human decision or hardware, declare and hand
         off to the user/orchestrator. Only a corpus with NO pending §8c queue entry AND no safe next phase ends silent.
       - OUT-OF-TREE APPLIED DELIVERABLE (a requires-execution close whose deliverable lands OUTSIDE $TARGET —
         a skill, plugin, or installed tool): reference it by PATH + SHA-IDENTITY (a manifest hash of the file
         set), NEVER copy it into the corpus; when there is no "original bytes" to diff against, an EXTERNAL
         adversarial QA protocol (e.g. Judgment Day) is the §19 oracle; preserve the full protocol evidence
         (ledger, fix log, consumer run, artifacts) under $CORPUS/sources/probes/<name>/ and cite it `[CERT-hw]`
         from the closing block. Full treatment: METHODOLOGY §19.
       - SELF-RETROSPECTIVE (per-focus SELF-RETROSPECTIVE at every focus STOP; campaign RETRO CHECKPOINT at campaign STOP — METHODOLOGY §18):
         before handing off, DELEGATE a fresh-context retro agent to review THIS run and PROPOSE kit deltas.
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
         Free-form session notes, "lessons" lists, or a heading of your own are NOT a retro (measured 2026-09-05:
         3 targets advanced with no retro; 7 of 12 new retros were unmarked, wrongly headed, or empty). Before the
         final RETURN state `retro: written <path>` or `retro: not-due (no research files changed)` — never
         `retro: pending`. Enforcement: once wired (kit issue #479), `$KIT/toolbelt/retro-gate.sh` runs as the
         target's Stop hook and blocks the session ONCE with the exact missing element until this holds.
         CLAUDE-CODE-ONLY (kit issue #1110): this Stop-hook enforcement — and the delta auto-seeding it
         triggers via `stage-retro-issues.sh` — is wired only through Claude Code's `Stop` hook (project,
         project-local, or user-level Claude Code settings); the kit wires no Stop-equivalent for codex or
         reasonix, so their runs never auto-seed, and (as above) the retro-existence block is lost too. On
         codex/reasonix, run `$KIT/toolbelt/stage-retro-issues.sh <retro> --apply` by hand right after the
         retro is written (the same point the RETRO CHECKPOINT above requires it), before ending the run.
         OPERATOR-DIRECTED PAUSE: the RETRO CHECKPOINT EXIT CONDITION above supersedes any "MAY"
         language elsewhere — the retro is mandatory whenever research files changed (block /
         RESEARCH-STATE / CATALOG / INDEX), regardless of pause type: an operator-directed pause, a
         mid-focus interruption, or a focus-level stop. A paused run whose files changed is NOT
         retro-exempt. This is the PROMPT-LOOP loop-step mirror of the METHODOLOGY §8
         OPERATOR-DIRECTED PAUSE rule, which is the authority for the `PAUSED (operator-directed)`
         RESEARCH-STATE label.

== DOCUMENT CYCLE (CAPTURE mode — entered ONLY when invoked as `document`; the OUTLINE-driven twin of NORMAL CYCLE) ==
  This mode CAPTURES knowledge you already have or just produced in a session — it does NOT DISCOVER gaps.
  It NEVER runs the gap-discovery / AUDIT-FIRST path (BOOTSTRAP step e / METHODOLOGY §13): no gap-backlog is
  seeded and no self-feeding backlog is used. It REUSES the kit's markers, block anatomy, verify-block gate,
  and INDEX/CATALOG conventions unchanged. Full definition: METHODOLOGY §20.
  PREFLIGHT (new-target path only): if the subject path has NO corpus (no `RESEARCH-STATE`/`INDEX` at
  `$TARGET` or `$TARGET/corpus/`) AND the triage decision gate classified the request as explicit document/
  create intent for a new target → run BOOTSTRAP steps a, a2, b (TARGETS.md registration), and c — scaffold
  via:

    research-sdd-init.sh $TARGET [--corpus auto|nested|flat] [--prefix <slug>] --document

  (kit issue #1114). **`--document` is REQUIRED here** — omitting it seeds the generic gap-discovery
  RESEARCH-STATE (placeholder `## Gap-backlog` rows this mode never discovers or closes) instead of the
  OUTLINE-driven variant. See `$KIT/templates/RESEARCH-STATE-document.template.md`'s own header comment
  for the full rationale (empty Gap-backlog, `## Outline` work-list, `method: document-cycle` envelope
  marker, and why that differs from `method: document-cycle-external`). Step e (gap-seeding) is explicitly
  skipped — this preflight is the mechanical registration and scaffolding only; it does not seed a
  discovery backlog and does not change this mode's outline-driven contract.
  1. SEED THE OUTLINE (replaces gap-discovery). Instead of uncovering gaps, seed the FULL list of
     topics/steps up front. Three sources: (a) what the user already knows, (b) their notes, (c) RECONSTRUCT
     the steps of the session just lived (e.g. a how-to for connecting an EM500 sensor, or bringing up a
     tool). The OUTLINE IS the work-list — there is NO AUDIT-FIRST discovery and no self-feeding backlog.
     LARGE-SCALE §20 (outline > ~15 items — per-section-agent pattern): the sequential
     one-item-per-iteration model is viable up to ~10–15 sections; beyond that the driver context
     accumulates across the whole run, defeating context-lean delegation. At scale: (a) pre-extract
     source material into per-section slices BEFORE dispatching — the source-before-agent rule applies
     at slice level (each slice confirmed readable); (b) dispatch ONE agent per outline item, each
     receiving its pre-extracted slice + the outline structure, returning ONLY cited findings
     (file:line + load-bearing snippets), NOT raw dumps; (c) the driver writes the blocks from those
     findings and runs SELF-VERIFY (step 4) per block. Model tier per cognitive demand (NORMAL CYCLE
     step 3 MODEL TIER rule). Record in the iteration history as `method: per-section-agent · N sections`.
     This pattern does NOT remove the one-item-per-block rule — each agent targets one block; what
     changes is that N agents run in one dispatch round rather than N sequential iterations.
     (Evidence: api-openness.)
  2. ONE OUTLINE ITEM = ONE BLOCK: transcribe + cite that item following the block anatomy (§4). Evidence
     depends on GENRE:
       - Documenting how something in the SUBJECT works → `[CERT]` file:line (same as the static loop).
       - Documenting a PROCEDURE / how-to (connect the EM500, bring up a tool, a runbook step) → the evidence
         is the SESSION itself: the commands run, the GUI navigated, the outputs — PRESERVED under
         `sources/probes/` and cited `[CERT-hw]` / `[CERT-live]` per channel, EXACTLY as the dynamic phase
         (§12) already does. Do NOT invent a new marker; reuse the existing ones.
  3. AUTO-ROUTE the write destination by knowledge TYPE (the MODE decides — the user does NOT specify per
     call). Ask: "does this knowledge serve OTHER targets too?"
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
  5. MANDATORY ENGRAM MIRROR (non-negotiable — this is the whole point of the mode). Mirror EVERYTHING
     documented to Engram as topic pointers so the doc is always recall-findable: subject knowledge under
     `research/<target>/<topic>`, toolchain knowledge under a kit-level pointer. This exists because a real
     session re-discovered Ghidra setup from scratch when `toolbelt/GHIDRA-MCP.md` already documented it but
     Engram carried no pointer — the mirror is what prevents that. A documented item with NO Engram pointer
     is NOT done.
  6. PRODUCE THE DELIVERABLE: besides the cited blocks, write the human-readable product —
     `HOWTO-<x>.md` / `SETUP-<x>.md` / `RUNBOOK.md` (subject deliverables under `$CORPUS`; toolchain
     deliverables are PROPOSED via the §18 retro TOOLS section and land in `$KIT/toolbelt/` only after
     the supervisor acts). For REFERENCE-MANUAL corpora (a corpus whose blocks
     document a large API/SDK/protocol), also produce COMPANION REFERENCE ARTIFACTS: a cheat sheet
     (most-used paths on one page), a glossary, a symbol-to-chapter keyword index, and optionally a
     single-file full-manual build. These are not blocks and carry no evidence markers — they are
     navigator aids, not procedural deliverables. Place at $CORPUS root. (Evidence: api-openness.)
  7. STOP when the OUTLINE is fully covered — NOT on gap-exhaustion (there is no gap set, so no
     read-only-investigable count and no 2×-empty secondary criterion apply). The outline is the terminator.
     CLOSURE OBLIGATIONS: the outline-completion STOP inherits the following from the NORMAL CYCLE:
       - ONE-BLOCK-PER-COMMIT and the commit-message convention (`research(<target>/<focus>): B<n>
         <slug>`) apply throughout the document cycle, not only at normal-cycle close (LOOP
         CONTINUATION hard rule).
       - SELF-RETROSPECTIVE (METHODOLOGY §18): delegate a fresh-context retro agent exactly as the
         NORMAL CYCLE terminal trigger prescribes. §18 fires "at every focus STOP and at campaign STOP",
         and outline completion is a focus completion.
       - TARGETS.md row refresh: update block count and run facts as part of closing the document run.
       - `research-sdd-archive.sh`: run it (gates linters, regenerates CATALOG, prints the
         close-checklist). Use `--dry-run` to preview.

HARD RULES:
  - MEMORY IS A MIRROR, NEVER A SUBSTITUTE. Every project/decision finding saved to memory (engram)
    that has no corresponding block is undocumented. The corpus cannot cite it; reviewers cannot audit
    it; a future agent reading the blocks will not see it. Rule: when you call mem_save for a finding
    of type project or decision, increment `undocumented_findings` in RESEARCH-STATE immediately. When
    you write the block, decrement it. A finding that lives only in memory is missing from the record.
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
    first rung of the fallback chain for live-launcher targets. (Evidence: `nre` pass-through flags.)
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
    evidence with no decompilation is [INFER], not [CERT]. (Evidence: niagara licensing.)
  - MULTI-MARKER BOOTSTRAP FUSION. A bootstrap gap (or any gap) that draws simultaneously from
    multiple independent evidence channels — e.g. [CERT-doc]+[CERT-web]+[CERT]+[CERT-live] all
    supporting the same claim — is a valid FUSION. Name it as fusion explicitly in the self-verify
    tally so reviewers read the redundancy as corroboration; see the sibling
    CORROBORATION-FROM-INDEPENDENT-STORE pattern (NORMAL CYCLE step 5 self-verify tally), which
    prescribes the same declaration for evidence blocks. Each marker still requires the evidence its
    tier demands; this rule names the multi-source convergence as a corroboration pattern, not as a
    waiver of per-marker standards. (Evidence: niagara jace9000 bootstrap.)
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
    difference. (Evidence: blender-llm B61 §61.2.)
  - RE-MEASURE A DRAMATIC POSITIVE. The same re-derive obligation applies when a live probe yields a
    striking positive (an apparent security weakness, an unexpectedly open or downgraded service). Do
    NOT escalate or capture it as a block from a single measurement. The banner-vs-protocol trap: a
    probe tool's connection banner (e.g. openssl `CONNECTED`) is a TRANSPORT event — it records only
    that the TCP connection was established, before the TLS handshake even runs, NOT that the server
    accepted the specific protocol version under test. "The client cannot offer version X" is not the same claim as "the
    server refused version X". Re-derive by an independent method or a targeted counter-probe before
    treating the finding as confirmed. (Evidence: jace8000; METHODOLOGY §12.)
  - DERIVED-VIEW INCONSISTENCY / IMPLAUSIBLE MAGNITUDE. When a derived or aggregated view of the
    data is inconsistent (conflicting counts, missing rows, version mismatch between two summaries),
    go to the SOURCE ARTIFACT rather than cross-referencing other derived views — each derived view
    may propagate the same upstream defect. Independently, when an enumeration or count is
    implausibly LARGE (thousands on a system known to be small), treat it as a hypothesis about
    instrument error FIRST — re-derive via an independent method before treating the result as a
    finding. For the near-zero direction (near-zero on a large system), use RE-MEASURE A DRAMATIC
    NEGATIVE (two rules above), which already prescribes an independent re-derive. These are
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
    into one cluster. (Evidence: blender-llm B61/B63.)
  - NEGATIVE-ABSENCE CLAIM DISCIPLINE (#732). A negative existence claim ("no X found", "Y is
    absent") is [CERT] ONLY when the EXACT artifact that would contain X was opened and searched.
    Asserting absence about an artifact NOT opened is [INFER], not [CERT]. Before recording a
    negative finding: confirm the container (jar, module, config file) was actually inspected; do NOT
    propagate a sub-agent's "not found" without verifying the scope covered the right artifact. A §14
    correction that retracts a prior finding based on absence must re-verify the absence in the exact
    named artifact before accepting the retraction. (Evidence: B478 §478.5.)
  - VENDOR-DOCUMENTED PORTS FIRST (#670). Before making any connection attempt against a live
    target, read the vendor's documented management/API port from the manual or API spec. Never rely
    on a default port sweep (e.g., 22/80/443/8080) to discover the active service port: a
    vendor-specific port outside the sweep range will produce a false "no data path" conclusion.
    This check belongs BEFORE the first connection attempt, not as a recovery step after sweeps
    fail. (Evidence: Fluke 177x.)
  - CONCURRENT-SWEEP DISJOINT FILE SETS (#644). When parallelizing agent sweeps, only parallelize
    agents whose target file sets (blocks to write, shared state to update — INDEX, RESEARCH-STATE,
    SOURCES.md) are FULLY DISJOINT. The driver serializes writes to all shared corpus files; most
    documentation and methodology gaps cluster on the same shared files, so serial dispatch is
    often the correct choice and not a performance issue. Parallelism is safe only when each agent
    owns an exclusive, non-overlapping set of output files.
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
    (Evidence: niagara signing-pki-live.)
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
    (Evidence: computadoras B23–B25.)
    LIVE-WRITE recipe that keeps this invariant on an AUTHENTICATED write: (a) authenticate out-of-band —
    a curl `-K` config file in scratchpad, NEVER the credential in argv / probe cmdline / sources /
    engram / the conversation itself;
    (b) a secret-bearing body (e.g. a config) is backed up to scratchpad and cited by `sha256`+byte-count,
    NEVER by its body; (c) mutate with a BENIGN disposable marker (not real data), confirm via an
    independent oracle (§12), then restore byte-identical and VERIFY the restore; (d) drive it through a
    dedicated MINIMAL-PRIVILEGE ephemeral principal, revoked at session end. See METHODOLOGY §12.
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
    GATE, TWICE: once plain (the working tree as it sits on disk — dirty, untracked AND gitignored
    files all included, since it reads the filesystem directly) and, ONLY when the target IS a git repo
    root, once more with `--committed` (everything ever committed, reachable from HEAD). Both calls
    share scan-secrets.sh's own file scope — `*.md`/config files, not arbitrary source files, kit issue
    #987 item 2. A high-confidence secret VALUE from either REFUSES the close (exit 3); dirtiness alone
    never refuses — the close flow always leaves the tree dirty at this point. A target with no git
    repo of its own, or nested inside a larger one, gets the working-tree scan only (history needs a
    repo root to scan).
  - ONE block per iteration (deep and cited, not wide and vague).
  - RE-MEASURE GROUND-TRUTH, never inherit it. When entering a DYNAMIC/hardware phase (or any new
    live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids —
    LIVE from the real system. Never cite them from a prior note/block (lesson: B66-B70). The worked example with the actual hex values
    lives in METHODOLOGY §12 — single source; don't restate the values here.
  - RESUME, don't blindly redo. After a kill/crash/interruption of an iteration, FIRST check
    `git -C $TARGET log` + on-disk artifacts to see whether that iteration already LANDED its commit
    before re-launching it — resume from real state (lesson: niagara B76/B122).
    See METHODOLOGY §17.
  - LOOP CONTINUATION — after every iteration, evaluate the stopping criterion (METHODOLOGY §8). While
    work remains (read-only-investigable > 0, or any campaign queue entry is `pending` or `active`), start the
    next gap; the continuation call (per mode below) is the last action of the turn, after the
    iteration report. A focus stop does not end a campaign: run the FRONTIER-REOPEN audit, enqueue any
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
    (Evidence: niagara loop-continuation retro.)
    ONE BLOCK PER COMMIT, too: even if a delegated sweep returns material for more than one
    queued gap in the same turn, each block gets its OWN commit and its OWN STOP-criterion re-check before
    the next is written — do NOT land two block files in one commit just because both sweeps returned
    together (lesson: three.js B15+B16). COMMIT MESSAGE: `research(<target>): B<n> <short-gap-slug>` (multi-focus §16 disambiguates in the
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
  - BASH-TOOL PATH NOT PERSISTENT: the shell state (including PATH) is reset between Bash tool
    calls on every platform — the harness initializes each call from the user's shell profile, so
    PATH changes made in one call are gone in the next. When a native tool (decompiler, scan
    utility, custom script) lives off the default PATH, two approaches: (a) durable — add the
    tool's directory to your shell profile so the harness picks it up on each init; (b) fallback
    — prepend in EVERY Bash call: `export PATH=<tool-dir>:$PATH && <command>`. Do not rely on a
    PATH set in a prior call. Cross-reference: BOOTSTRAP (a) / detect-tools.sh already covers
    off-PATH decompilers ("may live under linuxbrew Cellar … and still be off PATH").
  - WAKEUP GUARD (self-paced mode): before issuing a ScheduleWakeup, check whether one is already
    armed for this loop — do not double-schedule. One armed wakeup per iteration is the invariant.
    (Distinct from the "ScheduleWakeup for autonomous mode only" rule above — that governs WHEN to
    use it; this governs how many.)
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
    concern from MEMORY IS A MIRROR above — research findings destined for corpus blocks follow that
    rule; kit-methodology insights destined for the retro follow this one. Both apply simultaneously.
  - Preserve all external evidence in sources/ before citing it.
  - Corpus language: ENGLISH by default. EXCEPTION: if TARGETS.md marks this target with a
    user-approved language override (currently: logosoft → Spanish, for continuity of its mature
    Spanish corpus), write blocks in THAT language. Otherwise English. Do not infer exceptions.
    BOOTSTRAP commits the language in the TARGETS.md row (BOOTSTRAP step b). A mid-run switch is
    a structured override: refresh the TARGETS.md row and note the transition block number and
    reason — not a prose RESEARCH-STATE comment; a silent switch leaves a split-language corpus
    whose blocks are non-uniformly searchable. [Evidence: logosoft B1–B65 Spanish → B66–B77
    English, recorded only in a RESEARCH-STATE prose note, leaving rg/grep across blocks unreliable.]
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
    wrapper — provided the plain pattern appears nowhere else in the same Bash call's argv. (Evidence: blender-llm B6.)
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
RETURN CONTRACT (per-iteration CHECKPOINT — NOT a terminal hand-off; keep looping per LOOP CONTINUATION):
  retro: not-due | written <retros/<file>> · verify-retro: PASS   ← mandatory on the FINAL return of a run (see RETRO CHECKPOINT)
  SHAPE: one-line checkpoint, then CONTINUE. The per-iteration report is a brief checkpoint followed
  immediately by the next iteration — NOT a milestone recap or a narrative summary of what has been
  accomplished so far. Expanding the report into a milestone recap is the observed trigger for a
  premature turn-end: the agent fills its context with summary prose, then stops instead of
  continuing. Emit the minimum fields below and proceed. (Evidence: niagara loop-continuation retro.)
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
- **The backlog feeds itself**: investigating a gap almost always uncovers others; that is why the
  stopping criterion requires 2 empty iterations in a row.
- **Mature targets** (e.g. `niagara-research`) already have INDEX/hook: the loop continues from their
  gaps. **Incipient targets** trigger the BOOTSTRAP.
- **Multi-focus targets**: a large/mature target may carry several parallel focuses, each with its own
  `RESEARCH-STATE-<focus>.md` and a small focus index. State the active focus when you continue, and
  mirror to the TARGET's own engram `project`. Convention in METHODOLOGY §16.
- **ghidra-mcp** (agent-directed decompilation) requires the Ghidra server alive at `:8089`
  and restarting Claude Code; for batch/triage `decompile-native.sh` is enough (see `toolbelt/GHIDRA-MCP.md`).
