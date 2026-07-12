---
name: research-sdd
description: "Trigger: /research-sdd, 'launch/continue the research loop', 'investigate <target> with research-sdd', a one-off question vs an artifact/install. Triages, picks a depth, and PROCEEDS instead of interrogating (auto-escalates light->heavy)."
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

## Resolving the kit path

`KIT` is the research-sdd kit directory — the one holding `METHODOLOGY.md`, `PROMPT-LOOP.md`, and
`toolbelt/`. Resolve it ONCE, in this order, and use the result for every `$KIT/...` reference below:

1. `$RESEARCH_SDD_KIT` if that environment variable is set and points at a dir containing `METHODOLOGY.md`.
2. Else the default checkout: `/home/cristian/investigacion/sdd-investigacion/research-sdd`.
3. Else (a relocated kit / second machine) locate it — e.g. `fd -t f METHODOLOGY.md` under the user's repos,
   confirming the hit also has `toolbelt/` and `PROMPT-LOOP.md` — and if still unfound, ask the user for the path.

The toolbelt scripts resolve their OWN location internally, so `$KIT` is only needed to FIND the docs and
invoke the scripts; nothing downstream re-hardcodes this path.

## Arguments

`/research-sdd <target-or-path> [focus] [new|continue]` — OR free-form: a path plus a natural-language
request (e.g. `/research-sdd C:\...\SomeInstall need the license serial and model`). The args are NOT always
a clean target; the request may be a one-off question. CLASSIFY intent first (next section), then act.

- `<target-or-path>` — a target name/path from `$KIT/TARGETS.md`, OR an arbitrary artifact/path/question.
- `[focus]` — optional focus/axis for a multi-focus corpus (e.g. `nmodsreflow`). Omit for single-focus.
- `[new|continue]` — optional. `continue` (default if the target/focus already has a corpus) resumes;
  `new` forces a bootstrap.
- `document "<what to document>"` — the CAPTURE sub-command: `/research-sdd <target> document "<what>"`.
  Enters **document mode** (below) instead of the discovery loop — it captures knowledge you already have
  or just produced, outline-driven, and NEVER runs gap-discovery.

If **nothing usable** was given: read `$KIT/TARGETS.md`, show the target table (name · maturity · artifact ·
language), and ask which one — then proceed. Do not guess.

## Intent & depth — TRIAGE first, then RECOMMEND and PROCEED (do NOT interrogate)

The request is not always a full research run — but the answer is almost never a question back to the user.
Do NOT guess the mode from phrasing alone, and do NOT stop to ask when a cheap look would settle it. Run a
CHEAP TRIAGE, state a one-line plan, and PROCEED on your own recommendation. This OVERRIDES the general
"ask one question and wait" conversational default FOR THIS FLOW: research is meant to run, not interview.

**TRIAGE — before any heavy work:**
- `<target-or-path>` resolves in `TARGETS.md`, OR the user said `continue` / `a fondo` / `exhaustivo` /
  "document everything" → go **heavy** directly. No triage, no question.
- The explicit `document` sub-command, OR "documentá esto" / "capturá el how-to" / "document what we just
  did" → **document mode** (capture, not discover). This is DISTINCT from "document everything [about this
  system]", which is exhaustive DISCOVERY (heavy): document mode CAPTURES knowledge you already have or just
  produced, is OUTLINE-driven, and NEVER runs gap-discovery. No triage, no question — enter it directly.
- Otherwise take ONE cheap look — read `RESEARCH-STATE`/`INDEX` if a corpus exists, else glance at the path
  (file type, subdir structure, `security/`/`licenses/`, or a quick Explore) — then STATE a one-line plan
  (`artifact type · corpus? · rough gap count · recommended mode + why`) and proceed on it.

**Modes:**
- **quick / clarification** — a specific factual question against an artifact or path ("get me the license
  serial", "what version is this", "does it use protocol X"). Answer it DIRECTLY: read the relevant files
  and respond. Do NOT bootstrap a corpus, do NOT run the block loop. If the artifact would reward deeper
  study, OFFER to promote it to a full target — do not assume it.
- **light / exploratory** — "map this", "what's in here", "give me the lay of the land". Run a SCOPED
  exploration (delegate an Explore sweep), return a map/summary, seed a gap-backlog. This is a LANDING mode,
  not a dead stop — it may promote itself (see auto-escalation).
- **exhaustive / heavy** — "investigate thoroughly / a fondo", "document everything", "reconstruct the
  mental model", CONTINUE an existing corpus, OR a light pass that escalated. Run the full NORMAL CYCLE,
  one cited block per iteration until STOP. This is the ONLY mode that bootstraps or continues a corpus.
- **document / capture** — the `document` sub-command, or "documentá esto" / "capturá el how-to" / "document
  what we just did". CAPTURES knowledge you already have or just produced (a how-to, a runbook, the steps of
  the session just lived) instead of DISCOVERING gaps. It is OUTLINE-driven: seed the full list of
  topics/steps up front, transcribe + cite ONE per block, and STOP when the outline is covered — it NEVER
  runs gap-discovery / AUDIT-FIRST. Write destination is AUTO-ROUTED by knowledge TYPE (the mode decides,
  the user does not specify per call): knowledge ABOUT the subject under study → the TARGET's corpus;
  REUSABLE toolchain/environment knowledge (bring up Ghidra, use bkcrack, a WSL setup step) → the KIT
  (`toolbelt/` + register in `toolbelt/tool-registry.md`) plus an Engram pointer. Same `verify-block` gate,
  plus a MANDATORY Engram mirror so the doc stays recall-findable. Full cycle: PROMPT-LOOP's DOCUMENT CYCLE
  (METHODOLOGY §20).

**AUTO-ESCALATE light → heavy — announce, do NOT re-ask.** A light/triage pass is allowed to promote
itself. When it surfaces DEPTH — **≥3 investigable gaps**, OR a **binary/firmware** artifact, OR **multiple
subsystems**, OR an **unknown protocol** worth reconstructing — ANNOUNCE it
(`triage found N gaps + <signal> → escalating to HEAVY`) and CONTINUE into the loop in the SAME run. The
announcement IS the checkpoint; do not stop to ask. Only ask if escalating would cross a cost or scope limit
the user explicitly set.

**Ask a question ONLY** when the triage is genuinely 50/50 AND the wrong choice is expensive — never as the
default, never more than one.

**Target vs ad-hoc / live-install.** If `<target-or-path>` resolves in `TARGETS.md` → real corpus target
(heavy/continue). An arbitrary PATH not in `TARGETS.md` → ad-hoc scope: triage it, and only bootstrap a NEW
target if the depth signals fire or the user asks. A downloaded install exposing `security/`, `licenses/`,
or `certificates/` is a `live-install` artifact → apply the SECRETS DISCIPLINE (cite structure — Host IDs,
formats, public keys — never private/secret VALUES).

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
   For a LONG unattended run, wrap the invocation with the `/loop` skill
   (`/loop /research-sdd <target> a fondo`) — it is the external re-invoker PROMPT-LOOP was designed for.
   Self-paced reschedule is best-effort and can halt after a single block under conversational guardrails;
   `/loop` guarantees the cadence.

## Execution mode

Default is **self-paced** (this session becomes the loop driver and self-reschedules). For a long run that
must not stall, prefer **`/loop`-driven** (external re-invoker — most robust). If a human wants to review
between blocks, run **orchestrated** instead (chain one sub-agent per iteration; see PROMPT-LOOP
"Two execution modes"). Do not ask which mode — default to self-paced and mention `/loop` for long runs.

## Boundaries

- READ-ONLY over the subject under study. The kit is the source of truth for HOW; do not invent rules here.
- Corpus language follows `TARGETS.md` (English by default; only APPROVED overrides change it).
- Kit changes are never made from inside a run — the §18 retro PROPOSES deltas for human review, it does
  not edit `$KIT`.
