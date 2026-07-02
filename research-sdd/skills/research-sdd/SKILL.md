---
name: research-sdd
description: "Launch or continue a Research-SDD investigation over a target (reverse-engineering / decompilation research). Auto-classifies depth: quick one-off answer, light exploration/mapping, or the exhaustive cited-block loop — and asks when ambiguous. Trigger: /research-sdd, 'launch the research loop', 'continue the <focus> research', 'investigate <module> with research-sdd', a one-off question against an artifact/install, 'research-sdd continue <target> <focus>'."
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

`/research-sdd <target-or-path> [focus] [new|continue]` — OR free-form: a path plus a natural-language
request (e.g. `/research-sdd C:\...\SomeInstall need the license serial and model`). The args are NOT always
a clean target; the request may be a one-off question. CLASSIFY intent first (next section), then act.

- `<target-or-path>` — a target name/path from `$KIT/TARGETS.md`, OR an arbitrary artifact/path/question.
- `[focus]` — optional focus/axis for a multi-focus corpus (e.g. `nmodsreflow`). Omit for single-focus.
- `[new|continue]` — optional. `continue` (default if the target/focus already has a corpus) resumes;
  `new` forces a bootstrap.

If **nothing usable** was given: read `$KIT/TARGETS.md`, show the target table (name · maturity · artifact ·
language), and ask which one — then proceed. Do not guess.

## Intent & depth — CLASSIFY before launching anything

The request is not always a full research run. Read the user's phrasing AND what the path actually is, then
pick a mode. When it is ambiguous, ASK one question — NEVER default a one-off question to the heavy loop;
the heavy loop costs many iterations and is wasteful for a single fact.

- **quick / clarification** — a specific factual question against an artifact or path ("get me the license
  serial", "what version is this", "does it use protocol X"). Answer it DIRECTLY: read the relevant files
  and respond. Do NOT bootstrap a corpus, do NOT run the block loop. If the artifact would reward deeper
  study, OFFER to promote it to a full target — do not assume it.
- **light / exploratory** — "map this", "what's in here", "give me the lay of the land". Run a SCOPED
  exploration (delegate an Explore sweep), return a map/summary, optionally seed a gap-backlog. Broad and
  shallow; stop after the map unless the user asks to go deep.
- **exhaustive / heavy** — "investigate thoroughly / a fondo", "document everything", "reconstruct the
  mental model", or CONTINUE an existing corpus. Run the full NORMAL CYCLE, one cited block per iteration
  until STOP. This is the ONLY mode that bootstraps or continues a corpus.

Signals: concrete question + a path that is NOT a registered target → quick · "map/explore/what's in" →
light · "a fondo / exhaustivo / document everything / continue the focus" or a registered target → heavy ·
anything ambiguous → ASK.

**Target vs ad-hoc.** If `<target-or-path>` resolves in `TARGETS.md` → real corpus target (usually
heavy/continue). If it is an arbitrary PATH not in `TARGETS.md` → ad-hoc scope: default to quick/light per
the phrasing, and only bootstrap a NEW target if the user wants depth (offer it, don't assume). A downloaded
install exposing `security/`, `licenses/`, or `certificates/` is a `live-install` artifact → apply the
SECRETS DISCIPLINE (cite structure — Host IDs, formats, public keys — never private/secret VALUES).

## What to do (in order) — EXHAUSTIVE/HEAVY mode (and continue)

These steps apply to the heavy mode and to continuing a corpus. **quick** and **light** modes short-circuit:
answer directly (quick) or run a scoped Explore and return the map (light) — do not bootstrap or loop.

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
