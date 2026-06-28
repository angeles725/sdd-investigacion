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
   No interval → the model self-paces (recommended for research).
3. The loop stops on its own when the gap backlog stays empty for 2 iterations in a row
   (see stopping criterion in [`METHODOLOGY.md`](METHODOLOGY.md) §8).

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
  b. Determine which system it is, where its real sources/binaries are, and the corpus language.
  c. Create $TARGET/INDEX.md from $KIT/templates/INDEX.template.md (empty map + marker legend).
  d. Create dirs first: `mkdir -p $TARGET/tools $TARGET/.claude/hooks $TARGET/sources`. Copy
     $KIT/templates/gen-catalog.py → $TARGET/tools/, and $KIT/templates/hook-sessionstart.sh →
     $TARGET/.claude/hooks/research-protocol.sh (adapt <SUBJECT> + real source paths); register it in
     $TARGET/.claude/settings.json (matcher startup|resume|clear). Seed $TARGET/sources/SOURCES.md
     from $KIT/templates/SOURCES.template.md.
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
         for app.so), PROVISION it: $KIT/toolbelt/install-tool.sh <recipe> (see tool-registry.md;
         autonomous incl. sudo). If it can't install (sudo password / build fail / no recipe), REPORT
         the missing tool so the orchestrator asks the user, and do the investigable part without it
         (honest [INFER]/gap). Everything logged to $KIT/toolbelt/INSTALLED-TOOLS.md.
       - Delegate heavy sub-explorations to sub-agents if the gap requires sweeping many files.
  4. WRITE ONE BLOCK: create/update $TARGET/<prefix>-blockN.md following the anatomy
     ($KIT/templates/block.template.md). Each claim with its marker and its citation:
       [CERT] file:line · [CERT-doc] sources/...pdf §N · [CERT-web] URL+date ·
       [CERT-a] forum (URL) · [INFER] deduction.
     Include the Connections section linking related [Block K].
  5. SELF-VERIFY (verify phase): re-read your block. Does each [CERT] have a real citation? Escalate or
     downgrade markers based on the evidence. A critical [CERT-a]: try to confirm it in the primary
     source before closing.
  6. UPDATE STATE (archive phase):
       - Mark the gap as covered in RESEARCH-STATE.md and INDEX.md.
       - REGISTER the NEW gaps the research uncovered (the queue feeds itself).
       - Regenerate the catalog: python3 $TARGET/tools/gen-catalog.py
       - Update the estimated coverage in RESEARCH-STATE.md.
       - Mirror gaps/progress in engram (research/<target>/gaps, research/<target>/progress).
  7. STOPPING: if the backlog ended up empty and the previous iteration also left it empty
     (2 in a row with no new gaps), DECLARE estimated coverage + non-investigable gaps
     (without lab/hardware/NDA), emit the TOOLS REPORT (tools installed with command · tools needed
     but not installable + why · recommended tools — from $KIT/toolbelt/INSTALLED-TOOLS.md), and end
     the loop. Otherwise, the next iteration continues.

HARD RULES:
  - READ-ONLY over the subject. Do not invent: no source ⇒ [INFER] or omit. Always cite.
  - ONE block per iteration (deep and cited, not wide and vague).
  - Preserve all external evidence in sources/ before citing it.
  - Corpus language: ALWAYS English, for every target, with no exceptions — even if the target
    already has an existing corpus in another language. All blocks you write/update are in English.
  - At the end of the iteration, summarize in 3 lines: which gap you closed, which block
    you wrote/updated, and how many new gaps remain queued.
```

---

## Operational notes

- **One iteration = one block.** The value of the loop is disciplined accumulation, not haste.
- **The backlog feeds itself**: investigating a gap almost always uncovers others; that is why the
  stopping criterion requires 2 empty iterations in a row.
- **Mature targets** (e.g. `niagara-research`) already have INDEX/hook: the loop continues from their
  gaps. **Incipient targets** trigger the BOOTSTRAP.
- **ghidra-mcp** (agent-directed decompilation) requires the Ghidra server alive at `:8089`
  and restarting Claude Code; for batch/triage `decompile-native.sh` is enough (see `toolbelt/GHIDRA-MCP.md`).
