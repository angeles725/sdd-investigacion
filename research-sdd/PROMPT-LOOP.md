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
  b. Determine which system it is, where its real sources/binaries are, and the corpus language.
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
  f. Only then continue with the normal cycle over the first gap.

== NORMAL CYCLE (one iteration) ==
  1. CHOOSE: take the highest-priority NOT covered gap from the backlog. Announce which one.
  2. PROFILE: based on the gap's artifact type, pick the wrapper (tool-registry.md).
  3. INVESTIGATE (READ-ONLY), combining whatever is needed:
       - Decompile/read: decompile-java.sh | decompile-net.sh | decompile-native.sh | scan-firmware.sh
       - Source code: direct reading + CodeGraph.
       - Web: WebSearch (specs/forums/manuals) + WebFetch (specific links).
       - Documents: if you find a relevant datasheet/manual/forum, DOWNLOAD it and preserve it with
         $KIT/toolbelt/fetch-doc.sh (lands in $TARGET/sources/ + registered in SOURCES.md).
       - Missing tool? If the artifact needs a tool the toolbelt lacks (e.g. a Dart AOT decompiler
         for app.so), PROVISION it: $KIT/toolbelt/install-tool.sh <recipe> <target-binary> — ALWAYS
         pass the target binary so the recipe's arch/format PRECHECK can fail fast (e.g. blutter
         declines an x64 app in seconds via exit 5, instead of a ~20min dead-end build). See
         tool-registry.md; autonomous incl. sudo. If it returns 5 (incompatible) or can't install
         (sudo password / build fail / no recipe), REPORT the tool + reason so the orchestrator asks
         the user, and do the investigable part without it (honest [INFER]/gap). All logged to
         $KIT/toolbelt/INSTALLED-TOOLS.md.
       - Delegate heavy sub-explorations to sub-agents if the gap requires sweeping many files.
  4. WRITE ONE BLOCK: create/update $TARGET/<prefix>-blockN.md following the anatomy
     ($KIT/templates/block.template.md). Each claim with its marker and its citation:
       [CERT] file:line · [CERT-doc] sources/...pdf §N · [CERT-web] URL+date ·
       [CERT-a] forum (URL) · [INFER] deduction.
     Include the Connections section linking related [Block K].
  5. SELF-VERIFY + REPORT (in-block gatekeeping — see METHODOLOGY §11; the orchestrator does NOT run
     Bash gatekeepers, it trusts this report). Before closing, DO and REPORT:
       - Token check: grep-confirm EVERY load-bearing [CERT] token is present in its cited source;
         report how many you checked. Escalate/downgrade markers honestly (a critical [CERT-a]: try to
         confirm in the primary source first).
       - Marker tally: counts of [CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER] + the [INFER]/[CERT]
         ratio. If the ratio is high (>~0.5), say so — it signals this gap's investigable evidence is
         nearly exhausted.
       - Artifacts: block file exists, CATALOG regenerated, INDEX/RESEARCH-STATE updated.
  6. UPDATE STATE (archive phase):
       - Mark the gap covered in RESEARCH-STATE.md + INDEX.md; REGISTER the NEW gaps uncovered.
       - CLASSIFY the whole backlog into investigable vs blocked-on-<reason> (tool-missing / x64-tool /
         live-server / hardware) and record both counts in RESEARCH-STATE.md.
       - Update the coverage METRIC as a ratio (gaps closed / known gaps), NOT a free-floating %.
       - Regenerate: python3 $TARGET/tools/gen-catalog.py. Mirror to engram (research/<target>/gaps, .../progress).
  7. STOPPING (primary = investigable exhaustion, per METHODOLOGY §8): if the INVESTIGABLE count is now
     0 — every open gap is blocked on a missing/incompatible tool, a live server, or hardware — STOP.
     (Secondary: backlog empty 2× in a row.) On stop, DECLARE: blocks written, coverage ratio, the
     blocked gaps each tagged with the tool/access it needs, and the TOOLS REPORT (installed · couldn't
     -install+why · recommended — from $KIT/toolbelt/INSTALLED-TOOLS.md). If STOP did NOT fire, do NOT end
     your turn: reschedule and BEGIN the next iteration on the next gap (see LOOP CONTINUATION under HARD RULES).

HARD RULES:
  - READ-ONLY over the subject. Do not invent: no source ⇒ [INFER] or omit. Always cite.
  - ONE block per iteration (deep and cited, not wide and vague).
  - RE-MEASURE GROUND-TRUTH, never inherit it. When entering a DYNAMIC/hardware phase (or any new
    live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids —
    LIVE from the real system. Never cite them from a prior note/block (lesson: B66-B69 inherited a
    stale bench checksum `05 3d 6e e4`; the live value was `0x87B961A9`, forcing a correction). See
    METHODOLOGY §12.
  - RESUME, don't blindly redo. After a kill/crash/interruption of an iteration, FIRST check
    `git -C $TARGET log` + on-disk artifacts to see whether that iteration already LANDED its commit
    before re-launching it — resume from real state (lesson: killed B76/B122 had actually committed).
    See METHODOLOGY §17.
  - LOOP CONTINUATION — you drive the loop; nothing re-invokes you. After EVERY iteration, evaluate the
    STOPPING criterion (step 7). If it is NOT met (read-only-investigable > 0), you MUST reschedule and
    START the next iteration on the next gap — do NOT end your turn. The RETURN CONTRACT below is a
    per-iteration CHECKPOINT, not a hand-off; only the STOP declaration is terminal. Never stop after a
    single block. (Under `/loop` self-pacing this means calling ScheduleWakeup with the same prompt; under
    an orchestrator it means signalling "continue". Either way, one report ≠ done — see METHODOLOGY §8.)
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
