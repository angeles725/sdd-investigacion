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

> **Twin:** `research-sdd/skills/research-sdd/SKILL.md` is the harness-neutral counterpart installed for
> Claude Code and Codex. Any change to shared behavior (triage logic, mode definitions, boundaries) must be
> applied in BOTH files. The split is registered in `research-sdd/install/adapters.sh`.

## Resolving the kit path

`KIT` is the research-sdd kit directory — the one holding `METHODOLOGY.md`, `PROMPT-LOOP.md`, and
`toolbelt/`. Resolve it ONCE at start, in this order, and use the result for every `$KIT/...` reference below:

1. `$RESEARCH_SDD_KIT` if that environment variable is set AND the directory it points at contains `METHODOLOGY.md`.
2. Else the default checkout `/home/cristian/investigacion/sdd-investigacion/research-sdd`, but only if that directory exists and contains `METHODOLOGY.md`; otherwise fall through to step 3.
3. Else (relocated kit or second machine) locate it — e.g. `fd -t f METHODOLOGY.md` under the user's repos,
   confirming the hit also has `toolbelt/` and `PROMPT-LOOP.md` — and if still unfound, ask the user for the path.

The toolbelt scripts resolve their own location internally; `$KIT` is needed only to FIND the kit docs and
invoke the scripts. Nothing downstream re-hardcodes this path.

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

## Key terms (quick reference)

| Term | One-line meaning |
|---|---|
| **corpus** | The growing set of `.md` knowledge blocks for a target (+ `INDEX.md`, `CATALOG.md`, `RESEARCH-STATE.md`). |
| **block** | One self-contained `.md` file capturing one researched gap — `<prefix>-blockN.md` or `<prefix>-bloqueN.md`. |
| **gap** | An open research question in `RESEARCH-STATE.md`; the loop attacks one per iteration. |
| **RESEARCH-STATE.md** | The per-target state file: coverage metric, prioritized gap backlog, iteration history. |
| **SECRETS DISCIPLINE** | Hard rule (full text in PROMPT-LOOP): for `live-install` targets, cite secret STRUCTURE (formats, key lengths, host IDs), never secret VALUES. |

## Intent & depth — TRIAGE first, then RECOMMEND and PROCEED (do NOT interrogate)

The request is not always a full research run — but the answer is almost never a question back to the user.
Do NOT guess the mode from phrasing alone, and do NOT stop to ask when a cheap look would settle it. Run a
CHEAP TRIAGE, state a one-line plan, and PROCEED on your own recommendation. This OVERRIDES the general
"ask one question and wait" conversational default FOR THIS FLOW: research is meant to run, not interview.

**TRIAGE — before any heavy work:**
- `<target-or-path>` resolves in `TARGETS.md`, OR the user said `continue` / `a fondo` / `exhaustivo` /
  "document everything" → go **heavy** directly. No triage, no question. CARVE-OUT (intent wins): a
  registered target resolves to HEAVY *unless* the request is a scoped factual question (a version, a
  serial, "does it use X") — that is **quick** mode even against a registered target. Answer it directly
  (quick) and OFFER to continue the heavy loop; do not force the full loop for a one-off lookup.
- The explicit `document` sub-command, OR "documentá esto" / "capturá el how-to" / "document what we just
  did" → **document mode** (capture, not discover). This is DISTINCT from "document everything [about this
  system]", which is exhaustive DISCOVERY (heavy): document mode CAPTURES knowledge you already have or just
  produced, is OUTLINE-driven, and NEVER runs gap-discovery. No triage, no question — enter it directly.
- Otherwise take ONE cheap look — read `RESEARCH-STATE`/`INDEX` if a corpus exists, else glance at the path
  (file type, subdir structure, `security/`/`licenses/`, or a quick `research-sweep-cheap` sweep) — then
  STATE a one-line plan (`artifact type · corpus? · rough gap count · recommended mode + why`) and proceed.

**Modes:**
- **quick / clarification** — a specific factual question against an artifact or path ("get me the license
  serial", "what version is this", "does it use protocol X"). Answer it DIRECTLY: read the relevant files
  and respond. Do NOT bootstrap a corpus, do NOT run the block loop. If the artifact would reward deeper
  study, OFFER to promote it to a full target — do not assume it.
- **light / exploratory** — "map this", "what's in here", "give me the lay of the land". Run a SCOPED sweep
  (delegate to `research-sweep-cheap` per the runtime adapter), return a map/summary, seed a gap-backlog.
  This is a LANDING mode, not a dead stop — it may promote itself (see auto-escalation).
- **exhaustive / heavy** — "investigate thoroughly / a fondo", "document everything", "reconstruct the
  mental model", CONTINUE an existing corpus, OR a light pass that escalated. Run the full NORMAL CYCLE,
  one cited block per iteration until STOP. This is the only DISCOVERY mode that bootstraps or continues
  a corpus; a new-target DOCUMENT run also executes the mechanical BOOTSTRAP (steps a-c, including step-b
  TARGETS.md registration) before its outline cycle, skipping only gap-seeding (step e).
- **document / capture** — the `document` sub-command, or "documentá esto" / "capturá el how-to" / "document
  what we just did". CAPTURES knowledge you already have or just produced (a how-to, a runbook, the steps of
  the session just lived) instead of DISCOVERING gaps. It is OUTLINE-driven: seed the full list of
  topics/steps up front, transcribe + cite ONE per block, and STOP when the outline is covered — it NEVER
  runs gap-discovery / AUDIT-FIRST. Write destination is AUTO-ROUTED by knowledge TYPE (the mode decides,
  the user does not specify per call): knowledge ABOUT the subject under study → the TARGET's corpus;
  REUSABLE toolchain/environment knowledge (bring up Ghidra, use bkcrack, a WSL setup step) → the KIT
  (`toolbelt/` + register in `toolbelt/tool-registry.md`) plus an Engram pointer. Same `verify-block` gate,
  plus a MANDATORY Engram mirror so the doc stays recall-findable. Full cycle: PROMPT-LOOP's DOCUMENT CYCLE
  (METHODOLOGY §20). §20 was first exercised end-to-end on a real target by the TradingView new-target
  DOCUMENT run (target #23, B1-B3; see `retros/2026-08-03-document-unregistered-bootstrap-incident.md`).
  Existing toolchain how-tos (`toolbelt/DYNAMIC-SETUP.md`, `toolbelt/GHIDRA-MCP.md`) predate the mode.

**AUTO-ESCALATE light → heavy — announce, do NOT re-ask.** A light/triage pass is allowed to promote
itself. When it surfaces DEPTH — **≥3 investigable gaps**, OR a **binary/firmware** artifact, OR **multiple
subsystems**, OR an **unknown protocol** worth reconstructing — ANNOUNCE it
(`triage found N gaps + <signal> → escalating to HEAVY`) and CONTINUE into the loop in the SAME run. The
announcement IS the checkpoint; do not stop to ask. Only ask if escalating would cross a cost or scope limit
the user explicitly set.

**Ask a question ONLY** when the triage is genuinely 50/50 AND the wrong choice is expensive — never as the
default, never more than one.

**Target vs ad-hoc / live-install.** If `<target-or-path>` resolves in `TARGETS.md` → real corpus target
(heavy/continue) — UNLESS the request is a scoped factual question about it, in which case intent wins:
answer it **quick** and offer to continue the heavy loop (the carve-out above). An arbitrary PATH not in
`TARGETS.md` → ad-hoc scope: triage it. **Unregistered-path
decision gate:** if the path is absent from `TARGETS.md` AND the request carries explicit `new`/`create`/
`document`/exhaustive-documentation intent → classify as ad-hoc NEW target; announce BOOTSTRAP; run
BOOTSTRAP steps a-c (profile, TARGETS.md registration, scaffold) then continue the selected mode.
**Never** ask the user to choose an existing corpus or register manually merely because `TARGETS.md` lacks
a row. Without such explicit intent → cheap triage; bootstrap only if depth signals fire or the user asks.
A downloaded install exposing `security/`, `licenses/`, or `certificates/` is a `live-install` artifact →
apply the SECRETS DISCIPLINE (cite structure — Host IDs, formats, public keys — never private/secret VALUES).

## What to do (in order) — EXHAUSTIVE/HEAVY mode (and continue)

These steps apply to the heavy mode and to continuing a corpus. **quick** and **light** modes short-circuit:
answer directly (quick) or run a scoped Explore and return the map (light) — do not bootstrap or loop.

1. **Read the kit — these ARE the rules, do not summarize from memory:**
   - `$KIT/METHODOLOGY.md` — phases, the 7 markers, block anatomy, §8 stopping + terminal trigger,
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
   REMOTE follow-up (do NOT auto-run): after resolving the target, check `git -C <target-path> remote`. If it
   prints NO `origin`, SURFACE the one-liner "no remote — run `$KIT/toolbelt/ensure-remote.sh <target> --yes`
   when you consent to a PRIVATE GitHub remote" and continue. Creating a remote is consent-gated and the
   operator's call (METHODOLOGY §15) — never create or push one on their behalf.

3. **Confirm the angle (mature/large or multi-focus targets only).** State the active focus/axis and what
   you will reconstruct. If ambiguous, surface it and ask — do not guess the focus.

4. **Run the loop.** Execute the NORMAL CYCLE one iteration = one cited block. Delegate heavy sweeps with the
   right MODEL TIER (→ a `research-sweep-*` agent, adapter §1). Emit the per-iteration RETURN CONTRACT
   (including the tier used). At STOP, run the TERMINAL TRIGGER and the §18 SELF-RETROSPECTIVE.
   If the gap targets a BINARY artifact, first run `detect-tools.sh --require <decompiler>` to gate the
   environment: it probes TOOL availability (not the binary) — see TOOL-BEFORE-AGENT in PROMPT-LOOP HARD
   RULES. Then analyze with `decompile-native.sh <mode> <binary>`; for available modes (ghidra,
   ghidra-evidence, r2, quick) and exact CLI forms, see `$KIT/toolbelt/tool-registry.md`.
   For a LONG unattended run, drive it with the external `research-loop.sh` re-invoker (adapter §2) — OpenCode
   has no native self-reschedule, so the shell IS the re-scheduler and guarantees the cadence.

## Execution mode

Default is **self-paced** via the external `research-loop.sh` (adapter §2 — OpenCode has no native
self-reschedule; the shell is the re-scheduler). For a long run that must not stall, that IS the robust path.
If a human wants to review between blocks, run **orchestrated** instead (native `task` per iteration, adapter
§3). Do not ask which mode — default to self-paced and mention `research-loop.sh` for long runs.

## Boundaries

- READ-ONLY over the subject under study. The kit is the source of truth for HOW; do not invent rules here.
- Corpus language follows `TARGETS.md` (English by default; only APPROVED overrides change it).
- Kit changes are never made from inside a run — the §18 retro PROPOSES deltas for human review, it does
  not edit `$KIT`.

---

## OpenCode runtime adapter (READ THIS — you are NOT running on Claude Code)

The kit assumes Claude Code harness primitives. On OpenCode those primitives differ. The kit rules are still
the contract; only their MECHANISM changes. Three substitutions apply, and nothing else:

### 1. MODEL TIER → pick a sweep AGENT, not a per-call model

Claude Code lets a delegation set `model: 'haiku' | 'sonnet' | 'opus'` PER CALL. OpenCode bakes the model
into each agent, so you cannot vary it per `task`. Instead, the tier is expressed by WHICH agent you delegate
to. When the kit's MODEL TIER rule tells you a tier, translate it:

| Kit tier (PROMPT-LOOP) | Cognitive demand | OpenCode delegation |
| --- | --- | --- |
| `haiku` | MECHANICAL — enumerate methods/fields, locate call-sites, grep-and-cite | `task` → `research-sweep-cheap` (MiniMax-M2.7-highspeed) |
| `sonnet` (default) | ANALYTICAL — trace load-bearing logic, return cited findings | `task` → `research-sweep-strong` (MiniMax-M3) |
| `opus` | HARDEST — reconstruct a mental model, resolve deep ambiguity | run INLINE on the driver (already MiniMax-M3), or `task` → `research-sweep-strong` |

There is no generic `Explore`/`general-purpose` agent on OpenCode — the two `research-sweep-*` agents ARE the
replacement. Both are READ-ONLY (no write/edit tools): they investigate and RETURN cited findings; the DRIVER
writes the block, self-verifies (§11), and commits. Still RECORD the tier in RESEARCH-STATE's Iteration
history (`no·inline` / `yes·cheap` / `yes·strong`) so tier-compliance stays auditable.

**MANDATORY DELEGATION TRIGGER (not optional — this is where the loop stays alive).** Before you investigate
a gap INLINE, check it against this trigger. If ANY condition holds, you MUST `task` the sweep to a
`research-sweep-*` agent and consume ONLY its returned cited findings — running it inline is a rule VIOLATION
that bloats the driver context and shortens the loop:
- the gap touches **more than ~3 files/classes**, OR
- it requires **ANY OCR** of a scanned PDF (`extract-pdf.sh` tier 2), OR
- it extracts **more than ~10 pages** of a document, OR
- it is a **broad enumeration/grep sweep** (list all X, find all call-sites, scan a whole source tree).

Route by cognitive demand: mechanical (enumerate, grep-and-cite, OCR) → `research-sweep-cheap`; analytical
(trace load-bearing logic, reconstruct a subsystem) → `research-sweep-strong`. INLINE is reserved for a
narrow, single-file read you already know you need. Do NOT read a 191-page OCR, a 926-JAR tree, or a
multi-file subsystem on the driver — that is exactly the work these agents exist to absorb.

### 2. Self-paced autonomous loop → external `research-loop.sh` (NO ScheduleWakeup on OpenCode)

OpenCode has NO `ScheduleWakeup` and no native timer-loop. The self-paced autonomous mode is delivered by an
EXTERNAL driver: `~/.config/opencode/research-loop.sh`, which re-invokes `opencode run` once per iteration.
Because the kit is RESUME-first (every iteration derives live state from git + RESEARCH-STATE + engram), an
external re-invoker is behaviorally identical to ScheduleWakeup — the shell IS the re-scheduler.

Therefore, when this session is invoked BY the external loop (autonomous mode):
- Run EXACTLY ONE NORMAL-CYCLE iteration (one cited block), emit the RETURN CONTRACT, then RETURN.
- Do NOT try to self-reschedule and do NOT loop inside a single invocation. The shell handles cadence and
  the STOP check between invocations. "Reschedule at the ~60s floor" is enforced by the script's sleep, not
  by you.
- The TERMINAL TRIGGER (STOP) fires ONLY at TRUE corpus-level terminal per METHODOLOGY §8:
  read-only-investigable = 0 AND **no gap in the RESEARCH-STATE backlog is still `pending`**. ONLY then
  print the literal line `<<RESEARCH-SDD-STOP>>` (the exact marker `research-loop.sh` greps to exit) and
  run the §18 SELF-RETROSPECTIVE.
  GUARD — the worst failure mode: if ANY backlog gap is still `pending` (even `pending (LATER)` / deferred)
  or ANY read-only-investigable work remains, you are NOT at corpus STOP. Finish this block, emit the
  RETURN CONTRACT, and RETURN **without** the marker — the shell will start the next iteration. Emitting the
  marker with a non-empty backlog KILLS the autonomous loop mid-corpus. Before emitting, RE-READ the
  RESEARCH-STATE backlog table and confirm the summary metric ("N/N closed") actually matches zero `pending`
  rows — a stale summary that disagrees with the backlog is the classic cause of a premature STOP; trust the
  backlog rows, not the summary line. When in doubt, DO NOT emit it.

When invoked directly by a human (interactive, not via the script), you MAY run multiple iterations in the
turn if the user wants — but still one block per commit, and STOP-check between blocks.

### 3. Orchestrated mode → native `task` per iteration

Orchestrated mode (one sub-agent per iteration, human reviews between blocks) maps directly to OpenCode's
`task` tool: delegate each whole iteration to `research-sweep-strong` and review its RETURN CONTRACT before
delegating the next. This needs no external script.

### Tooling notes
- Ghidra HEADLESS (`decompile-native.sh ghidra`) works on OpenCode (it is a shell wrapper). Agent-directed
  `ghidra-mcp` is only available if the `ghidra` MCP server is present in `opencode.json` — check before
  assuming it is MISSING (same lesson as the kit: do not infer from `which` alone).
- Engram is available via the OpenCode engram plugin — the `research/<target>[/<focus>]/progress|gaps` keys
  work as written.
