---
name: research-sdd
description: "Launch or continue a Research-SDD investigation loop over a target (reverse-engineering / decompilation research, one cited knowledge block per iteration). Trigger: /research-sdd, 'launch the research loop', 'continue the <focus> research', 'investigate <module> with research-sdd', 'research-sdd continue <target> <focus>'."
user-invocable: true
license: MIT
metadata:
  author: cristian
  version: "1.0"
---

# Research-SDD launcher

You are about to drive a **Research-SDD** investigation loop. This skill is a THIN LAUNCHER: it does NOT
restate the loop rules — the single source of truth is the kit. Read the kit, resolve the target, resume
from real state, and run the loop. Never bake mutable state (block numbers, "next gap") into what you run —
derive it live each iteration (that is why RESUME exists).

## Fixed paths

```
KIT = /home/cristian/investigacion/sdd-investigacion/research-sdd
```

## Arguments

`/research-sdd <target> [focus] [new|continue]`

- `<target>` — a target name or path from `$KIT/TARGETS.md` (e.g. `niagara-research`, `logosoft`).
- `[focus]` — optional focus/axis for a multi-focus corpus (e.g. `nmodsreflow`). Omit for single-focus.
- `[new|continue]` — optional. `continue` (default if the target/focus already has a corpus) resumes;
  `new` forces a bootstrap.

If **no target** was given: read `$KIT/TARGETS.md`, show the target table (name · maturity · artifact ·
language), and ask which one — then proceed. Do not guess.

## What to do (in order)

1. **Read the kit — these ARE the rules, do not summarize from memory:**
   - `$KIT/METHODOLOGY.md` — phases, the 5 markers, block anatomy, §8 stopping + terminal trigger,
     §11 self-verify, §12 dynamic phase, §16 multi-focus, §17 resume, §18 self-retrospective.
   - `$KIT/TARGETS.md` — resolve the target: its real path, artifact type, toolbelt wrapper, language
     (honor an APPROVED language override; otherwise English).
   - `$KIT/toolbelt/tool-registry.md` — which wrapper per artifact type.
   - `$KIT/PROMPT-LOOP.md` — **the operational cycle you will run.** This is the contract: BOOTSTRAP,
     NORMAL CYCLE, HARD RULES (including LOOP CONTINUATION, RESCHEDULE CADENCE, DELEGATION + MODEL TIER,
     SOURCE-BEFORE-AGENT, SECRETS DISCIPLINE), TERMINAL TRIGGER, RETURN CONTRACT. Follow it verbatim.

2. **RESUME first (never bake stale state).** For the resolved target/focus, reconcile the REAL current
   state before writing anything: `git -C <target-path> log --oneline -15`, read its
   `RESEARCH-STATE[-<focus>].md`, `CATALOG.md`, and engram `research/<target>[/<focus>]/progress` + `/gaps`.
   Start from the next NOT-covered gap in the live backlog — not from any number a human typed.
   If the target/focus has NO `RESEARCH-STATE`/`INDEX` → run BOOTSTRAP (PROMPT-LOOP), including the
   ANGLE-first declaration for a mature/large target and AUDIT-FIRST backlog seeding.

3. **Confirm the angle (mature/large or multi-focus targets only).** State the active focus/axis and what
   you will reconstruct. If ambiguous, surface it and ask — do not guess the focus.

4. **Run the loop.** Execute the NORMAL CYCLE one iteration = one cited block, and self-continue per the
   LOOP CONTINUATION + RESCHEDULE CADENCE rules (self-paced: reschedule at the ~60s floor until STOP fires).
   Delegate heavy sweeps with the right MODEL TIER. Emit the per-iteration RETURN CONTRACT (including the
   tier used). At STOP, run the TERMINAL TRIGGER and the §18 SELF-RETROSPECTIVE.

## Execution mode

Default is **self-paced** (this session becomes the loop driver and self-reschedules). If a human wants to
review between blocks, run **orchestrated** instead (chain one sub-agent per iteration; see PROMPT-LOOP
"Two execution modes"). Ask only if it is unclear which mode the user wants; otherwise default to self-paced.

## Boundaries

- READ-ONLY over the subject under study. The kit is the source of truth for HOW; do not invent rules here.
- Corpus language follows `TARGETS.md` (English by default; only APPROVED overrides change it).
- Kit changes are never made from inside a run — the §18 retro PROPOSES deltas for human review, it does
  not edit `$KIT`.
