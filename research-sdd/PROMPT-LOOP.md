# PROMPT-LOOP — Research-SDD

This is the **loop-able prompt** of Research-SDD. It is designed to run in a loop
(with Claude Code's `/loop` skill, self-paced or with an interval) and advance a research
**one iteration = one block** at a time. It is **stateful and idempotent**: it reads its own
state from disk, so running it N times advances the corpus without stepping on itself.

---

## How to use it

1. Define the target (one from [`TARGETS.md`](TARGETS.md)). Edit the `TARGET=` line below.
2. Launch the loop:
   ```
   /loop  <paste the OPERATIONAL PROMPT below, with TARGET already set>
   ```
   No interval → the model self-paces (recommended for research). Self-paced means THERE IS NO external
   re-invoker: the loop agent itself reschedules the next iteration (ScheduleWakeup) until STOP fires —
   this is the LOOP CONTINUATION hard rule in the operational prompt. If a run halts after one block, that
   rule was skipped; as a fallback add an interval (`/loop 10m …`) so the harness re-fires deterministically.
3. The loop stops on its own ONLY when the stopping criterion fires (read-only-investigable exhausted, or
   backlog empty 2× in a row) — see [`METHODOLOGY.md`](METHODOLOGY.md) §8. Until then it keeps iterating.

### Two execution modes (pick by whether a human is present)

The same NORMAL CYCLE runs under either mode — they differ only in WHO drives iterations and HOW much
each delegation carries:

- **Self-paced** (`/loop`, no human in the room): the loop agent IS the driver. It reschedules itself
  (ScheduleWakeup) and, per iteration, delegates only the HEAVY SWEEP of a gap (>3-4 files) to a
  sub-agent that returns cited findings, then writes the block itself. Autonomous; runs unattended.
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
    At iteration 1 of any orchestrated run, ANNOUNCE the sub-mode: "I am in supervised mode — prompt
    me to continue after each block" or "I am in auto mode — I will chain until STOP." Without the
    declaration the human cannot distinguish a supervised pause from a loop stall.

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
         HOT-CORE (read in full now): §1 §2 §3 the 7 markers §4 §7 §8 §9 §11 §17 — framing + per-block contract.
         (§11b — verifying the verifier + kit test-lane contract — is SITUATIONAL: kit maintenance only, never per block.)
         SITUATIONAL (read the section in full when its phase fires): §5 source-added · §6 profiling/wrapper ·
         §10 tool-missing · §12 live-probe · §13 audit (prompt: PROMPT-AUDIT.md) · §14 correction · §15 corpus-git · §16 multi-focus ·
         §18 STOP · §19 build/PoC · §20 document-mode · §21 wall · §22 breakthrough-ledger. Unsure a phase is active -> read it.
  2. $KIT/TARGETS.md            (target profile: artifact type, tools, language)
  3. $KIT/toolbelt/tool-registry.md   (which wrapper to use per artifact type)
  4. $CORPUS/RESEARCH-STATE.md  (state: coverage + prioritized gap-backlog)  [if missing → BOOTSTRAP]
  5. $CORPUS/INDEX.md           (map of existing blocks and Pending section)  [if missing → BOOTSTRAP]
     ($CORPUS = corpus root — METHODOLOGY §15. RESUME RESOLVES it deterministically: if $TARGET/corpus/INDEX.md
      exists → $CORPUS=$TARGET/corpus/; else if $TARGET/INDEX.md exists → $CORPUS=$TARGET; else neither → BOOTSTRAP.
      Check the corpus/ path FIRST — else a nested corpus reads as "missing" and BOOTSTRAP duplicates it.)
  6. RESOLVE THE NEXT GAP mechanically — do NOT eyeball the backlog: `$KIT/toolbelt/research-sdd-status.sh $TARGET --next`
     returns one line — `NEXT | <priority> | <gap>` (investigate it), `STOP | <reason>` (§8 exhaustion),
     `STALE | <reason>` (envelope/backlog inconsistent — run `$KIT/toolbelt/research-sdd-status.sh $TARGET
     --sync-state`, reconcile, and retry; do NOT proceed on STALE), or `BOOTSTRAP | <reason>`.
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
     (lesson: niagara assumed "Ghidra not available" when decompile-native.sh ghidra worked, losing
     the first native block's decompiler depth).
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
  b. Determine which system it is, where its real sources/binaries are, and the corpus language. REGISTER
     the target in $KIT/TARGETS.md's master table right here (row: #, target, path, maturity, predominant
     artifact type, toolbelt wrapper, corpus language) — as part of bootstrap, NOT later: the retro sweeper
     `toolbelt/sweep-retros.sh` derives its ENTIRE scan list from TARGETS.md, so an unregistered target's
     `retros/` dir is invisible to the §18 supervision sweep (lesson: three.js ran its first focus — 12 blocks,
B1-B12 — unregistered, so its retro was invisible to the sweeper until registered by hand). Keep that row a
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
      bootstrap + a block each time (lesson: niagara went live-station → OEM Java modules → native
      binaries before hitting the axis the user wanted). If the angle isn't obvious from the request,
      SURFACE it for the orchestrator/user to pick rather than guessing. A mature target may legitimately
      host several parallel angles → see the MULTI-FOCUS CORPUS pattern (METHODOLOGY §16). (Small/
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
     GAP PREMISES ARE HYPOTHESES, not assertions — the initial research plan is a best guess from
     outside the code. When investigation refutes a premise (e.g. a module assumed to belong to
     subsystem Y has zero imports from it), RENAME the gap in RESEARCH-STATE to reflect the real
     finding and issue a §14 correction if a prior block already asserted the wrong premise. A
     refuted premise is itself a finding — name it honestly (e.g. "exportTags is NOT a tag-subsystem
     component" is more useful than the original "exportTags runtime").
     GAP NUMBERS ARE ALSO HYPOTHESES — when a gap's description contains a number that will serve
     as a denominator or threshold (e.g. "N classes", "M entries"), re-derive it from the source
     before using it, exactly as you would a structural premise. A wrong count silently scopes the
     investigation to the wrong universe. (Specialisation of GAP PREMISES ARE HYPOTHESES above;
     see also BOOTSTRAP e2's MEASURE rule and the deduplication caveat there.)
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
     `pdftotext` dump) instead of citable `sources/...pdf :p.N` anchors (lesson: WEB-HMI10-CF — 16
     non-page-anchored citations across 9 blocks). Not applicable to targets with no PDFs; a mixed
     corpus still extracts its PDFs at NORMAL CYCLE step 3, which also holds the extraction rules,
     range guidance, and citation format.
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
       verify-block WARN "ZERO file:line citations resolved" is EXPECTED on any synthesis block whose
     citations are exclusively [Block N] cross-references — verify-block exits 0; the WARN is
     informational. verify-block reads the Type token (kit issue #422): the WARN is INFO for a declared synthesis block. Do NOT add spurious file:line citations to silence it. TOKEN-CHECK instead applies
     to the [Block N] citations: confirm the finding attributed to [Block N] §N.x actually appears in
     that block's cited section. Record: "verify-block: exit 0, WARN expected (synthesis block;
     [Block N] token-check: N citations confirmed)." (Source: 2026-08-30-module-best-practices-focus-retro.md Δ2)
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
         remittance at fine grain even when the audit cleared it at coarse grain. (Evidence: apis focus
         API5/API6/API8, 2026-08-25: 3/8 gaps REMITTANCE-risk; all 3 turned out genuine.)
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
         RE-MEASURE A DRAMATIC NEGATIVE (HARD RULES) and GAP NUMBERS ARE ALSO HYPOTHESES (BOOTSTRAP e1).
         (Evidence: COB-IM2 B6 asserted "zero NxM labels; width is geometric" from one regex pass; B8
         found 563 `W"xH"` size labels and 886 BOD tags in the same drawing — derivation was unnecessary.
         Corrected via §14, commit d7fd595.)
       - Decompile/read: `$KIT/toolbelt/`{decompile-java.sh | decompile-net.sh | decompile-native.sh | scan-firmware.sh}
       - Source code: direct reading + CodeGraph.
       - Web: WebSearch (specs/forums/manuals) + WebFetch (specific links).
       - Live target? Before profiling, read the vendor's documented management/API port from the manual /
         API-spec — a default sweep of 22/23/80/443/1700 will MISS a vendor REST API on e.g. :8080.
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
       - VERIFY BEFORE ACTING on a sub-agent's report, and ALWAYS when the report is an ABSENCE. A
         delegated finding is a hypothesis with citation, not a fact. Before writing a block or
         correcting a document on that basis: (a) resolve at least the `file:line` citations that
         support a key claim — two sweeps in practice returned paths that did not exist on disk;
         (b) if the sub-agent asserts something does NOT exist / is NOT documented / is absent,
         grep-confirm it yourself before accepting. (c) Tool-use count is a signal: a detailed
         report with very few tool calls inferred instead of searched.
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
         (Harness-neutral tier contract and per-harness mapping: `toolbelt/model-tiers.v1.md`.)
       - PRE-TEST POPULATION ANATOMY: before running a comparison or classification test, measure
         the anatomy of the test population — how many items survive the eligibility filter, and
         what fraction is auto-generated vs. semantic vs. absent. If the post-filter count is zero,
         the test is NOT APPLICABLE and must not run — report the measured pre-filter and post-filter
         counts in place of a vacuous result (the anatomy distinguishes "the filter consumed everything"
         from "the input was absent", satisfying §7). (Distinct from RE-MEASURE A DRAMATIC NEGATIVE,
         which fires AFTER a striking result to verify it; this gate fires BEFORE the test, when the
         population is still uncounted.)
       - FALSIFY BEFORE REPORTING an operational conclusion. When the gap's answer would drive an
         operational recommendation (an alert, an escalation, a client report), cast it as a
         falsifiable hypothesis FIRST and test it against data already on disk before reporting it.
         Cost: typically one query. Value: prevented a wrong escalation costs far more. A block that
         refutes its own initial hypothesis is a valid, high-value block type.
       - MODEL TIER ALSO governs NESTED sub-sweeps. A general-purpose sweep-agent (one whose toolset INCLUDES the
         Agent tool — NOT Explore/Plan, which lack it) MAY itself spawn a SUB-SWEEP, and each Agent call carries
         its own `model`: pick the sub-sweep's tier by the SAME cognitive-demand heuristic. Nesting caveat: prefer
         ONE level — nest a sub-sweep only for a punctual, well-scoped need; the specialized agents (Explore/Plan)
         cannot sub-delegate at all. For STRUCTURED fan-out or multiple controlled levels, use the Workflow engine
         (deterministic control, no per-hop context compression) instead of free-form native nesting.
         ORCHESTRATED-MODE CAVEAT: when the delegating agent is ITSELF a sub-agent (orchestrated mode, one level
         deep), the nested `model:` tier override may be unavailable in the harness — the inner Agent call may
         fail with "agent type not available" (observed: B415 niagara/network-supervisor). Fallback: use Bash
         directly for the mechanical sweep (haiku-tier work), or route deterministic fan-out through the Workflow
         engine. Record the fallback as `inline (constraint: nested-tier-unavailable)` in the tier column.
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
     independently. (Evidence: B336 `e975837` — early draft used a shorthand, caught and fixed inline
     before commit; a shorthand breaks `verify-sources.sh`'s FABRICATED-citation cross-check.)
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
         etc.), verify-block classifies them as `extern` — it prints "ZERO file:line citations resolved"
         and exits 0. This WARN is EXPECTED, not an error: the script cannot follow a decompiler output
         path. The mechanized citation gate has checked nothing for that block; the burden falls ENTIRELY
         on the inline token-verify in this step 5. Self-verify must record this explicitly — e.g.
         "verify-block: 0 resolved (all extern — decompiled trees); sole citation gate = inline
         token-verify N/M rows" — so the omission is visible, not silently assumed covered. Separately:
         a SOURCE_ROOT mapping (not yet implemented) would let the script resolve decompiled paths; the
         absence of that config is the root cause. Until it exists, inline token-verify is non-negotiable
         for any decompile-based block. `extern` citations (beautified/decompiled/snapshot) are not
         script-verifiable — still token-check those by reading.
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
         hardcoded → the B359 NPE wall makes that claim wrong).
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
       - MCP-doc snapshots: every LOAD-BEARING [CERT-web]-via-MCP citation (context7 et al.) snapshotted to
         sources/web-snapshots/ + registered in SOURCES.md (§5). Report Y/N + count — this gate is what stops
         §5's snapshot rule from being paper-only (context7 cites kept landing unsnapshotted across runs).
       - OPTIONAL [CERT] SEAL (adversarial-verify — OPT-IN selective seal, trialed on a real claim 2026-07-07 — METHODOLOGY §3) — the driver MAY SEAL load-bearing [CERT] claims (the ones a
         conclusion rests on) by running the `adversarial-verify` workflow ($KIT/toolbelt/adversarial-verify.js),
         INSTEAD of trusting only this self-report: N=3 skeptics try to REFUTE each claim; a claim stays sealed
         [CERT] only if it SURVIVES ≥2 of 3, otherwise it is DOWNGRADED or DROPPED. Apply it SELECTIVELY (cost
         discipline) — only to LOAD-BEARING [CERT], never to [INFER] or trivial claims. Modular N: 3 skeptics for
         load-bearing, 1 or 0 for the rest. LOCAL-sourced claims (decompiled output / file:line) are CHEAP — the
         skeptics read the cited source, no web; only web-verifiable claims are expensive (~125k tokens/claim).
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
         registration gets skipped (evidence: niagara/email B334 uncovered email-G1
         requires-execution; it appeared in iteration-history but the backlog had no row and
         `requires_execution_open` stayed 0 — commit `11142b9`).
       - REVERSE BACKLOG SWEEP: after closing a gap OR retiring a §14 premise, re-read the open
         backlog and re-scope or rename any gap whose PREMISE this block just answered or invalidated.
         A gap that was opened as "is X true?" becomes stale if this block proved X false — it must
         be updated or closed, not left as-is. This sweep is PREMISE-driven and distinct from the
         NEXT-ITERATION ARCHIVE AUDIT (which checks bookkeeping counts — gap totals, marker sync);
         the archive audit catches accounting errors; this sweep catches semantic drift in the
         backlog itself. Run it inline, not as a separate pass.
       - BACK-FILL SOURCES.md's "Citing blocks" cell — when this block cites a source registered in SOURCES.md
         (this iteration, or an earlier one whose trailing cell is still blank), write THIS block's ID into that
         row's last column before closing the iteration. `fetch-doc.sh`'s `reg()` leaves the cell blank by design
         (a later manual back-fill); leaving it blank silently disables `verify-sources.sh`'s FABRICATED-citation
         cross-check for that row — the check only cross-validates rows that DO list a block (METHODOLOGY §5).
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
     obligation at every STOP gate. (Evidence: platform-native reopen — uncited decompiler output
     covered an open gap the corpus called exhausted; detected 9 days late.)
     TERMINAL TRIGGER (the open loop — see METHODOLOGY §8): STOP is not a dead end. The loop stays CLOSED
     (self-continuing) while read-only-investigable > 0; when it hits 0, OPEN the loop to the environment and
     fire the next action instead of just declaring:
       - FOCUS-level exhaustion (this focus done, but the multi-focus corpus has other queued focuses):
         OPTIONALLY write a focus-closing SYNTHESIS block first (consolidate this focus, cross-referencing
         related blocks across focuses — a valid terminal artifact at focus level, not just corpus level;
         see METHODOLOGY §8), then hand off to the next focus — announce it and, under `/loop` self-pacing,
         reschedule ONE more time re-entering this same prompt with FOCUS set to the next queued focus
         (BOOTSTRAP it if new). The loop does not die; it advances to the next axis.
       - CORPUS-level exhaustion (every focus done, nothing read-only-investigable anywhere): emit a final
         NEXT-ACTION recommendation — a cross-focus synthesis block, or handoff to a non-static phase
         (requires-execution build/PoC §19 — §19 CLOSE RULE: when a build/PoC phase produces
         block-quality findings, write them as cited blocks using `sources/probes/` for tool evidence
         BEFORE the phase ends; a deliverable is not a substitute for the evidence trail, and findings
         that exist only in code/engram are invisible to the corpus —, or the DYNAMIC/hardware phase §12) — and, if that next phase is
         itself autonomous and safe, launch it; if it needs a human decision or hardware, declare and hand
         off to the user/orchestrator. Only a corpus with NO queued focus AND no safe next phase ends silent.
       - OUT-OF-TREE APPLIED DELIVERABLE (a requires-execution close whose deliverable lands OUTSIDE $TARGET —
         a skill, plugin, or installed tool): reference it by PATH + SHA-IDENTITY (a manifest hash of the file
         set), NEVER copy it into the corpus; when there is no "original bytes" to diff against, an EXTERNAL
         adversarial QA protocol (e.g. Judgment Day) is the §19 oracle; preserve the full protocol evidence
         (ledger, fix log, consumer run, artifacts) under $CORPUS/sources/probes/<name>/ and cite it `[CERT-hw]`
         from the closing block. Full treatment: METHODOLOGY §19.
       - SELF-RETROSPECTIVE (at every focus completion, and always at corpus-level STOP — METHODOLOGY §18):
         before handing off, DELEGATE a fresh-context retro agent to review THIS run and PROPOSE kit deltas
         (rules that were skipped, techniques you improvised that the kit lacks, gaps that stalled). It reads
         the current $KIT/PROMPT-LOOP.md + METHODOLOGY.md FIRST and dedupes — proposes only what is genuinely
         new, each with evidence (block/commit/§ refs) and a priority. It writes the proposal to
         $TARGET/retros/ + engram research/<target>/retro and SURFACES it in the return. It does NOT edit the
         kit — kit changes are human-reviewed and human-committed. This is how the kit learns from real runs.
       - RETRO CHECKPOINT: before closing the RETURN, confirm whether a §18 retro is pending. If one was
         not delegated yet (e.g. this is a document-mode run or an early-stop), state: "Retro pending?
         (Y / list what)" and, if yes, delegate it now before handing off.

== DOCUMENT CYCLE (CAPTURE mode — entered ONLY when invoked as `document`; the OUTLINE-driven twin of NORMAL CYCLE) ==
  This mode CAPTURES knowledge you already have or just produced in a session — it does NOT DISCOVER gaps.
  It NEVER runs the gap-discovery / AUDIT-FIRST path (BOOTSTRAP step e / METHODOLOGY §13): no gap-backlog is
  seeded and no self-feeding backlog is used. It REUSES the kit's markers, block anatomy, verify-block gate,
  and INDEX/CATALOG conventions unchanged. Full definition: METHODOLOGY §20.
  PREFLIGHT (new-target path only): if the subject path has NO corpus (no `RESEARCH-STATE`/`INDEX` at
  `$TARGET` or `$TARGET/corpus/`) AND the triage decision gate classified the request as explicit document/
  create intent for a new target → run BOOTSTRAP steps a, a2, b (TARGETS.md registration), and c (scaffold
  via `research-sdd-init.sh`) before entering step 1 below. Step e (gap-seeding) is explicitly skipped —
  this preflight is the mechanical registration and scaffolding only; it does not seed a discovery backlog
  and does not change this mode's outline-driven contract.
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
     (Evidence: api-openness — 42 chapters, one dispatch round via `_extract/author_workflow.js`.)
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
     navigator aids, not procedural deliverables. Place at $CORPUS root. (Evidence: api-openness —
     CHEATSHEET.md, GLOSSARY.md, KEYWORD_INDEX.md, MANUAL_FULL.md alongside 42 chapters.)
  7. STOP when the OUTLINE is fully covered — NOT on gap-exhaustion (there is no gap set, so no
     read-only-investigable count and no 2×-empty secondary criterion apply). The outline is the terminator.
     CLOSURE OBLIGATIONS: the outline-completion STOP inherits the following from the NORMAL CYCLE —
     §20 previously carried none of these, which is why the hilton-bms/dashboard retro never auto-fired
     and two blocks merged in one commit (commit `cabb6d7`):
       - ONE-BLOCK-PER-COMMIT and the commit-message convention (`research(<target>/<focus>): B<n>
         <slug>`) apply throughout the document cycle, not only at normal-cycle close (LOOP
         CONTINUATION hard rule).
       - SELF-RETROSPECTIVE (METHODOLOGY §18): delegate a fresh-context retro agent exactly as the
         NORMAL CYCLE terminal trigger prescribes. §18 fires "at every FOCUS completion and always at
         corpus-level STOP" — §20 had no equivalent step, so the retro never auto-fired on a document
         run until now.
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
  - REAL-ARTIFACT-FIRST (packaged artifact inspection) — When a gap is about physical packaging / layout /
    on-disk artifact SHAPE, inspect the REAL packaged artifact directly (e.g. `unzip -l`/`unzip -p` over
    the signed jar) before/alongside the decompiled tree — `META-INF` signing entries, jar-entry taxonomy,
    and manifest bytes are INVISIBLE in decompiled source. Distinct from DISK-FIRST (which is disk-vs-live):
    this targets the packaged artifact vs the decompiled source. RIDER (source>jar for intent): when the
    finding is about INTENT (over-permission, dead code, config), prefer SOURCE if available — a packaged
    artifact shows declarations; source shows whether they are real or scaffold.
  - RE-MEASURE A DRAMATIC NEGATIVE. When an enumeration or join yields a striking negative result
    (zero matches, near-total absence, a system that appears dead or empty), do NOT report it from
    a single measurement. Re-derive it by an independent method — a different key, a different
    grouping, a spot-check of raw records — before it enters a block. A counting artifact and a
    genuine finding are indistinguishable in the output; only a second measurement separates them.
    `verify-block.sh` cannot detect a wrong join key — this is a distinct failure class from
    marker/citation errors.
  - RE-MEASURE A DRAMATIC POSITIVE. The same re-derive obligation applies when a live probe yields a
    striking positive (an apparent security weakness, an unexpectedly open or downgraded service). Do
    NOT escalate or capture it as a block from a single measurement. The banner-vs-protocol trap: a
    probe tool's connection banner (e.g. openssl `CONNECTED`) is a TRANSPORT event — it records only
    that the TCP connection was established, before the TLS handshake even runs, NOT that the server
    accepted the specific protocol version under test. "The client cannot offer version X" is not the same claim as "the
    server refused version X". Re-derive by an independent method or a targeted counter-probe before
    treating the finding as confirmed. (Evidence: jace8000 — a transport banner misread as
    TLS-version protocol acceptance, which nearly produced a false client-escalation; METHODOLOGY
    §12 live-probe frames.)
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
  - A gap entry closed as `blocked` or `absent` must carry a `tried:` clause listing the alternatives
    attempted and what measurement ruled out each route. An absent/blocked entry with no `tried:`
    clause is unfinished: it bounds one path, not the question. (Complement of the `needs:` clause.)
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
    (Evidence: computadoras `cfut_` API token pasted into chat 3× across B23–B25.)
    LIVE-WRITE recipe that keeps this invariant on an AUTHENTICATED write: (a) authenticate out-of-band —
    a curl `-K` config file in scratchpad, NEVER the credential in argv / probe cmdline / sources /
    engram / the conversation itself;
    (b) a secret-bearing body (e.g. a config) is backed up to scratchpad and cited by `sha256`+byte-count,
    NEVER by its body; (c) mutate with a BENIGN disposable marker (not real data), confirm via an
    independent oracle (§12), then restore byte-identical and VERIFY the restore; (d) drive it through a
    dedicated MINIMAL-PRIVILEGE ephemeral principal, revoked at session end. See METHODOLOGY §12.
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
    GATE — a high-confidence secret VALUE that leaked into authored corpus content REFUSES the close (exit 3).
  - ONE block per iteration (deep and cited, not wide and vague).
  - RE-MEASURE GROUND-TRUTH, never inherit it. When entering a DYNAMIC/hardware phase (or any new
    live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids —
    LIVE from the real system. Never cite them from a prior note/block (lesson: B66-B69 inherited a
    stale bench checksum and had to be corrected in B70). The worked example with the actual hex values
    lives in METHODOLOGY §12 — single source; don't restate the values here.
  - RESUME, don't blindly redo. After a kill/crash/interruption of an iteration, FIRST check
    `git -C $TARGET log` + on-disk artifacts to see whether that iteration already LANDED its commit
    before re-launching it — resume from real state (lesson: killed B76/B122 had actually committed).
    See METHODOLOGY §17.
  - LOOP CONTINUATION — you drive the loop; nothing re-invokes you. After EVERY iteration, evaluate the
    STOPPING criterion (step 7). If it is NOT met (read-only-investigable > 0), you MUST reschedule and
    START the next iteration on the next gap — do NOT end your turn. The RETURN CONTRACT below is a
    per-iteration CHECKPOINT, not a hand-off; only the STOP declaration is terminal. Never stop after a
    single block. ONE BLOCK PER COMMIT, too: even if a delegated sweep returns material for more than one
    queued gap in the same turn, each block gets its OWN commit and its OWN STOP-criterion re-check before
    the next is written — do NOT land two block files in one commit just because both sweeps returned
    together (lesson: a three.js commit landed B15+B16 as one, skipping the reschedule/STOP-check between
    them). COMMIT MESSAGE: `research(<target>): B<n> <short-gap-slug>` (multi-focus §16 disambiguates in the
    scope: `research(<target>/<focus>): B<n> <slug>`); OPTIONAL body line = coverage ratio + marker tally.
    Commit DIRECT to the default branch — a solo corpus needs no PR (METHODOLOGY §15). One commit ⇄ one block
    is what makes §17 resume answerable from `git log --oneline`. (Under `/loop` self-pacing this means calling
    ScheduleWakeup with the same prompt; under an orchestrator it means signalling "continue". Either way, one
    report ≠ done — see METHODOLOGY §8.)
  - RESCHEDULE CADENCE — the next gap is READY WORK, not an idle poll. When you reschedule under `/loop`
    self-pacing, use the SHORTEST delay (~60s, the floor), NOT the 1200-1800s idle-tick default. A short
    delay also keeps the prompt cache warm (≤300s), so back-to-back iterations are cheaper AND faster.
    Only stretch the delay when you are genuinely BLOCKED waiting on something external (an install
    building, a live server coming up) — never just to space out ready decompilation work.
  - Preserve all external evidence in sources/ before citing it.
  - Corpus language: ENGLISH by default. EXCEPTION: if TARGETS.md marks this target with a
    user-approved language override (currently: logosoft → Spanish, for continuity of its mature
    Spanish corpus), write blocks in THAT language. Otherwise English. Do not infer exceptions.
    BOOTSTRAP commits the language in the TARGETS.md row (BOOTSTRAP step b). A mid-run switch is
    a structured override: refresh the TARGETS.md row and note the transition block number and
    reason — not a prose RESEARCH-STATE comment; a silent switch leaves a split-language corpus
    whose blocks are non-uniformly searchable. [Evidence: logosoft B1–B65 Spanish → B66–B77
    English, recorded only in a RESEARCH-STATE prose note, leaving rg/grep across blocks unreliable.]
  - At the end of the iteration, summarize in 3 lines: which gap you closed, which block
    you wrote/updated, and how many new gaps remain queued.

RETURN CONTRACT (per-iteration CHECKPOINT — NOT a terminal hand-off; keep looping per LOOP CONTINUATION):
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
    - the next gap (or the stop declaration).
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
