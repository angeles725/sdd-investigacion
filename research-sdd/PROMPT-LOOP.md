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

Always read first, in this order:
  1. $KIT/METHODOLOGY.md        (phases, the 5 markers, block anatomy, sources/, stopping)
  2. $KIT/TARGETS.md            (target profile: artifact type, tools, language)
  3. $KIT/toolbelt/tool-registry.md   (which wrapper to use per artifact type)
  4. $TARGET/RESEARCH-STATE.md  (state: coverage + prioritized gap-backlog)  [if missing → BOOTSTRAP]
  5. $TARGET/INDEX.md           (map of existing blocks and Pending section)  [if missing → BOOTSTRAP]

== BOOTSTRAP (only if the target has NO INDEX.md/RESEARCH-STATE.md) ==
  a. Profile the target: $KIT/toolbelt/profile-target.sh $TARGET  (classifies binaries → wrapper).
     Also run $KIT/toolbelt/detect-tools.sh (cache the report): learn which decompilers are ACTUALLY
     available before deciding what you can do. Do NOT infer availability from `which` alone — Ghidra,
     r2, jadx etc. may live under linuxbrew Cellar / a dotnet dir / a jar path and still be off PATH
     (lesson: niagara assumed "Ghidra not available" when decompile-native.sh ghidra worked, losing
     the first native block's decompiler depth).
  b. Determine which system it is, where its real sources/binaries are, and the corpus language. REGISTER
     the target in $KIT/TARGETS.md's master table right here (row: #, target, path, maturity, predominant
     artifact type, toolbelt wrapper, corpus language) — as part of bootstrap, NOT later: the retro sweeper
     `toolbelt/sweep-retros.sh` derives its ENTIRE scan list from TARGETS.md, so an unregistered target's
     `retros/` dir is invisible to the §18 supervision sweep (lesson: three.js ran its first focus — 12 blocks,
B1-B12 — unregistered, so its retro was invisible to the sweeper until registered by hand). Keep that row a
     LIVING MIRROR, not a one-time write: when a run-STOP or a §14 correction changes a fact mirrored there
     (block / run / retro / file counts), REFRESH the row as part of closing that run or correction —
     three.js's row went stale at "21 md / 3 runs" while the corpus grew to 32 blocks / 5 runs.
  b2. ANGLE (mature OR large target): a target name alone is ambiguous. DECLARE AN EXPLICIT
      INVESTIGATION ANGLE/AXIS (e.g. decompiled-Java vs native-binaries vs install/config vs
      docs/protocol) and CONFIRM it BEFORE closing the first gap — picking the wrong focus burns a
      bootstrap + a block each time (lesson: niagara went live-station → OEM Java modules → native
      binaries before hitting the axis the user wanted). If the angle isn't obvious from the request,
      SURFACE it for the orchestrator/user to pick rather than guessing. A mature target may legitimately
      host several parallel angles → see the MULTI-FOCUS CORPUS pattern (METHODOLOGY §16). (Small/
      incipient single-artifact targets: skip — the artifact is the angle.)
  c. Create $TARGET/INDEX.md from $KIT/templates/INDEX.template.md (empty map + marker legend).
  d. Create dirs first: `mkdir -p $TARGET/tools $TARGET/.claude/hooks $TARGET/sources`. Copy
     $KIT/templates/gen-catalog.py → $TARGET/tools/, and $KIT/templates/hook-sessionstart.sh →
     $TARGET/.claude/hooks/research-protocol.sh (adapt <SUBJECT> + real source paths); register it in
     $TARGET/.claude/settings.json (matcher startup|resume|clear). Seed $TARGET/sources/SOURCES.md
     from $KIT/templates/SOURCES.template.md.
     VERSION the corpus: `git -C $TARGET rev-parse --git-dir 2>/dev/null || git -C $TARGET init` — the
     git repo goes in the TARGET project, NOT in the kit (METHODOLOGY §15), so self-corrections (§14)
     have history.
  e. Create $TARGET/RESEARCH-STATE.md from $KIT/templates/RESEARCH-STATE.template.md with an initial
     research-plan: 5-15 high-priority gaps (the fundamental questions about the system). Mirror the
     gaps in engram research/<target>/gaps.
     AUDIT-FIRST BACKLOG (mature/large corpus, or a new focus over one): do NOT hand-guess the gaps.
     DELEGATE an audit sweep (Explore/general-purpose sub-agent) that returns a COVERAGE MATRIX —
     subsystem × current-depth × static-vs-dynamic × known-vs-gap — WITHOUT dumping content. Derive the
     prioritized backlog from that matrix. (Proven on the protocols focus: the audit matrix seeded 6
     well-shaped gaps before a single block was written.) See METHODOLOGY §13.
  e2. PRE-FLIGHT SOURCE EXISTENCE (anti-hallucination gate — before launching ANY iteration): for each
     planned gap, CONFIRM readable source material actually exists (the class/jar/binary/doc is present
     and reachable by the wrapper). A gap with NO reachable source must be marked blocked-on-<reason>
     (source-missing) in the backlog — NEVER launch an iteration agent at it, because with no source it
     will pad [INFER] or invent. Only gaps with confirmed source enter the investigable set.
  f. Only then continue with the normal cycle over the first (investigable, source-confirmed) gap.

== NORMAL CYCLE (one iteration) ==
  1. CHOOSE: take the highest-priority NOT covered gap from the backlog. Announce which one.
  2. PROFILE: based on the gap's artifact type, pick the wrapper (tool-registry.md).
  3. INVESTIGATE (READ-ONLY), combining whatever is needed:
       - Decompile/read: decompile-java.sh | decompile-net.sh | decompile-native.sh | scan-firmware.sh
       - Source code: direct reading + CodeGraph.
       - Web: WebSearch (specs/forums/manuals) + WebFetch (specific links).
       - Documents: if you find a relevant datasheet/manual/forum, DOWNLOAD it and preserve it with
         $KIT/toolbelt/fetch-doc.sh (lands in $TARGET/sources/ + registered in SOURCES.md).
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
       - MODEL TIER ALSO governs NESTED sub-sweeps. A general-purpose sweep-agent (one whose toolset INCLUDES the
         Agent tool — NOT Explore/Plan, which lack it) MAY itself spawn a SUB-SWEEP, and each Agent call carries
         its own `model`: pick the sub-sweep's tier by the SAME cognitive-demand heuristic. Nesting caveat: prefer
         ONE level — nest a sub-sweep only for a punctual, well-scoped need; the specialized agents (Explore/Plan)
         cannot sub-delegate at all. For STRUCTURED fan-out or multiple controlled levels, use the Workflow engine
         (deterministic control, no per-hop context compression) instead of free-form native nesting.
  4. WRITE ONE BLOCK: create/update $TARGET/<prefix>-blockN.md following the anatomy
     ($KIT/templates/block.template.md). Each claim with its marker and its citation:
       [CERT-hw] sources/probes/... (highest) · [CERT-live] live remote-service response (§12b) ·
       [CERT] file:line · [CERT-doc] sources/...pdf §N · [CERT-web] URL+date · [CERT-a] forum (URL) ·
       [INFER] deduction.  (canonical list: METHODOLOGY §3)
     Include the Connections section linking related [Block K].
  5. SELF-VERIFY + REPORT (in-block gatekeeping — see METHODOLOGY §11; the orchestrator does NOT run
     Bash gatekeepers, it TRUSTS this report. Per-block orchestrator Bash re-checks cost permission prompts
     and — proven on the protocols run — caught NOTHING; the real error capture mechanism is cross-block
     correction §14, not a per-iteration re-verify. Only spot-check when a report smells off). Before closing,
     DO and REPORT:
       - MECHANIZE the counting: run `$KIT/toolbelt/verify-block.sh <block>` and paste its output — the
         marker tally, [INFER]/[CERT] ratio and [CERT] file:line citation-resolution are COMPUTED, not
         remembered (it exits non-zero on a cited file:line whose line is out of range). It is your own
         calculator, not an orchestrator gate. `extern` citations (beautified/decompiled/snapshot) are not
         script-verifiable — still token-check those by reading.
       - Token check: grep-confirm EVERY load-bearing [CERT] token is present in its cited source;
         report how many you checked. Escalate/downgrade markers honestly (a critical [CERT-a]: try to
         confirm in the primary source first).
       - Marker tally: counts of [CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER] + the [INFER]/[CERT]
         ratio, AND the block TYPE. For an EVIDENCE block (decompilation/reading), a high ratio (>~0.5)
         signals this gap's investigable evidence is nearly exhausted — say so. For a DESIGN/APPLIED block
         (an integration plan, a PoC design, a synthesis), a high ratio is EXPECTED and healthy, NOT an
         exhaustion signal — it does not close the focus. Declare which type it is so the ratio is read right.
       - Artifacts: block file exists, CATALOG regenerated, INDEX/RESEARCH-STATE updated.
       - MCP-doc snapshots: every LOAD-BEARING [CERT-web]-via-MCP citation (context7 et al.) snapshotted to
         sources/web-snapshots/ + registered in SOURCES.md (§5). Report Y/N + count — this gate is what stops
         §5's snapshot rule from being paper-only (context7 cites kept landing unsnapshotted across runs).
       - OPTIONAL [CERT] SEAL (adversarial-verify — EXPERIMENTAL, never yet run on a real claim) — the driver MAY SEAL load-bearing [CERT] claims (the ones a
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
         close by NEW investigation, by PROVEN ABSENCE, or by REMITTANCE (already answered by an existing
         cited block — cite [Block N] §N.x + "no new substance"; see METHODOLOGY §8).
       - RECORD the iteration in RESEARCH-STATE's Iteration history table INCLUDING the delegated? · model
         tier column (no·inline / yes·haiku|sonnet|opus) — persist the tier on disk, not only in the report,
         so tier-compliance stays auditable after the session ends.
       - CLASSIFY the whole backlog into investigable vs blocked-on-<reason> (tool-missing / x64-tool /
         live-server / hardware) and record both counts in RESEARCH-STATE.md.
       - Update the coverage METRIC as a ratio (gaps closed / known gaps), NOT a free-floating %.
       - Regenerate: python3 $TARGET/tools/gen-catalog.py. Mirror to engram (research/<target>/gaps, .../progress).
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
     MECHANIZE the §5 source-registry check: run `$KIT/toolbelt/verify-sources.sh $TARGET` and paste its
     output — it exits non-zero if a block cites a preserved-source marker ([CERT-doc]/[CERT-a]) with no
     sources/SOURCES.md, or a cited sources/ file is absent on disk. This is the corpus-level twin of
     step 5's verify-block.sh: per-block marker/citation math is checked in-iteration, source-registry
     integrity is checked once at STOP (it reads the whole corpus). If STOP did NOT fire, do NOT end
     your turn: reschedule and BEGIN the next iteration on the next gap (see LOOP CONTINUATION under HARD RULES).
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
         (requires-execution build/PoC §19, or the DYNAMIC/hardware phase §12) — and, if that next phase is
         itself autonomous and safe, launch it; if it needs a human decision or hardware, declare and hand
         off to the user/orchestrator. Only a corpus with NO queued focus AND no safe next phase ends silent.
       - SELF-RETROSPECTIVE (at every focus completion, and always at corpus-level STOP — METHODOLOGY §18):
         before handing off, DELEGATE a fresh-context retro agent to review THIS run and PROPOSE kit deltas
         (rules that were skipped, techniques you improvised that the kit lacks, gaps that stalled). It reads
         the current $KIT/PROMPT-LOOP.md + METHODOLOGY.md FIRST and dedupes — proposes only what is genuinely
         new, each with evidence (block/commit/§ refs) and a priority. It writes the proposal to
         $TARGET/retros/ + engram research/<target>/retro and SURFACES it in the return. It does NOT edit the
         kit — kit changes are human-reviewed and human-committed. This is how the kit learns from real runs.

HARD RULES:
  - READ-ONLY over the subject. Do not invent: no source ⇒ [INFER] or omit. Always cite.
  - SOURCE BEFORE AGENT — a gap counts as investigable ONLY once its source is confirmed reachable
    (the class/jar/binary/doc exists and the wrapper can read it). Confirm it BEFORE launching an
    iteration agent at that gap; an unconfirmed gap is blocked-on-source-missing, not investigable.
    Never send an agent to a gap with no reachable source — it will pad [INFER] or invent (see BOOTSTRAP e2).
  - SECRETS DISCIPLINE (live-install targets) — when the target is a REAL running installation/station,
    not a distributable artifact (TARGETS.md marks it `live-install`), NEVER extract or write credentials,
    keys, keyring/keystore material, tokens, or secrets into a block, sources/, or engram. Cite the
    STRUCTURE (where a secret lives, its format, how it's used) — never the secret VALUE. Zero secrets
    exfiltrated is a hard invariant; a real install carries live credentials a decompiled jar does not.
    LIVE-WRITE recipe that keeps this invariant on an AUTHENTICATED write: (a) authenticate out-of-band —
    a curl `-K` config file in scratchpad, NEVER the credential in argv / probe cmdline / sources / engram;
    (b) a secret-bearing body (e.g. a config) is backed up to scratchpad and cited by `sha256`+byte-count,
    NEVER by its body; (c) mutate with a BENIGN disposable marker (not real data), confirm via an
    independent oracle (§12), then restore byte-identical and VERIFY the restore; (d) drive it through a
    dedicated MINIMAL-PRIVILEGE ephemeral principal, revoked at session end. See METHODOLOGY §12.
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
    them). (Under `/loop` self-pacing this means calling ScheduleWakeup with the same prompt; under
    an orchestrator it means signalling "continue". Either way, one report ≠ done — see METHODOLOGY §8.)
  - RESCHEDULE CADENCE — the next gap is READY WORK, not an idle poll. When you reschedule under `/loop`
    self-pacing, use the SHORTEST delay (~60s, the floor), NOT the 1200-1800s idle-tick default. A short
    delay also keeps the prompt cache warm (≤300s), so back-to-back iterations are cheaper AND faster.
    Only stretch the delay when you are genuinely BLOCKED waiting on something external (an install
    building, a live server coming up) — never just to space out ready decompilation work.
  - Preserve all external evidence in sources/ before citing it.
  - Corpus language: ENGLISH by default. EXCEPTION: if TARGETS.md marks this target with a
    user-approved language override (currently: logosoft → Spanish, for continuity of its mature
    Spanish corpus), write blocks in THAT language. Otherwise English. Do not infer exceptions.
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
    - the MODEL TIER you used for any delegated sweep (haiku/sonnet/opus) — declaring it is mandatory;
      an unstated tier means the rule was skipped and the sweep silently inherited the driver's model,
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
