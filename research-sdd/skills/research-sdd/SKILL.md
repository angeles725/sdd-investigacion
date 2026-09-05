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

> **Twin:** `research-sdd/toolbelt/opencode/SKILL.md` is the OpenCode-specific counterpart. It serves the
> same skill on the OpenCode harness with adapter substitutions for model tiers, the external loop, and
> orchestration mode. Any change to shared behavior (triage logic, mode definitions, boundaries) must be
> applied in BOTH files. The split is registered in `research-sdd/install/adapters.sh`.

## Resolving the kit path

`KIT` is the research-sdd kit directory — the one holding `METHODOLOGY.md`, `PROMPT-LOOP.md`, and
`toolbelt/`. Resolve it ONCE, in this order, and use the result for every `$KIT/...` reference below:

0. If this harness's system prompt carries a research-sdd launcher block with a `Kit path:` line,
   expand it (replace a leading `~` with `$HOME`) and use that directory as the O(1) fast-path —
   but still confirm it contains `METHODOLOGY.md` before trusting it; if the check fails, fall through.
1. `$RESEARCH_SDD_KIT` if that environment variable is set and points at a dir containing `METHODOLOGY.md`.
2. Else (relocated kit or second machine) locate it — e.g. `fd -t f METHODOLOGY.md` under the user's
   repos, confirming the hit also has `toolbelt/` and `PROMPT-LOOP.md`. Guards: never treat `$HOME`,
   `/`, or any directory missing ALL THREE of `METHODOLOGY.md`, `toolbelt/`, and `PROMPT-LOOP.md` as the
   kit. If `fd` returns multiple candidates, prefer one NOT under `.claude/worktrees/`; if still
   multiple, list them and ask the user rather than silently picking one (anti-silent-zero).
   If still unfound, ask the user for the path.

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

## Key terms (quick reference)

| Term | One-line meaning |
|---|---|
| **target** | The system/artifact under study, registered in `TARGETS.md` (name · path · maturity · artifact · language). `$TARGET` = its root dir; the corpus is built FOR it and may live AT `$TARGET` (flat) or under `$TARGET/corpus/` (nested) — that corpus root is `$CORPUS`. |
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
  DOCUMENT run (target #23, B1-B3; see the kit repo-root `retros/2026-08-03-document-unregistered-bootstrap-incident.md`, not `$KIT/retros/`).
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
`TARGETS.md` → ad-hoc scope: triage it. **Unregistered-path decision gate:** if the path is absent from
`TARGETS.md` AND the request carries explicit `new`/`create`/`document`/exhaustive-documentation intent →
classify as ad-hoc NEW target; announce BOOTSTRAP; run BOOTSTRAP steps a-c (profile, TARGETS.md
registration, scaffold) then continue the selected mode. **Never** ask the user to choose an existing
corpus or register manually merely because `TARGETS.md` lacks a row. Without such explicit intent →
cheap triage; bootstrap only if depth signals fire or the user asks. A downloaded install exposing
`security/`, `licenses/`, or `certificates/` is a `live-install` artifact → apply the SECRETS DISCIPLINE
(cite structure — Host IDs, formats, public keys — never private/secret VALUES).

## What to do (in order) — EXHAUSTIVE/HEAVY mode (and continue)

These steps apply to the heavy mode and to continuing a corpus. **quick** and **light** modes short-circuit:
answer directly (quick) or run a scoped Explore and return the map (light) — do not bootstrap or loop.

1. **Read the kit — these ARE the rules, do not summarize from memory:**
   - `$KIT/METHODOLOGY.md` — the rules. Do NOT ingest all 22 sections every iteration; it is a reference,
     not a monolith to reload each block. Load it in two tiers — lazy-load is NOT skip: every rule still
     applies, you only DEFER loading a section until its phase fires, and reading it is MANDATORY then.
     - HOT-CORE — read IN FULL every iteration (framing + the per-block contract): §1 guiding principle,
       §2 phases, §3 the 7 markers, §4 block anatomy, §7 state/memory, §8 stopping + terminal trigger,
       §9 golden rules, §11 self-verify, §17 resume.
     - SITUATIONAL — read the named section IN FULL the moment its phase triggers, by number: §5 sources →
       adding/preserving/citing an external source; §6 research tools → BOOTSTRAP profiling or picking a
       wrapper per artifact type; §11b verifying the verifier / kit test-lane contract → adding or changing a guard, check, oracle,
       or test lane in the KIT (never needed to write a block); §10 self-provisioning → a required tool is missing (before recording
       `blocked-on-tool`); §12 dynamic phase → validating a finding against a LIVE system; §13 audit mode →
       running an AUDIT (operational prompt: `PROMPT-AUDIT.md`); §14 cross-block consistency → a block CORRECTS another; §15 corpus versioning →
       corpus bootstrap ($CORPUS) or a git commit/remote; §16 multi-focus → the target has multiple
       focuses; §18 self-retrospective → at STOP / terminal trigger; §19 build/PoC loop → the gap REQUIRES
       EXECUTION; §20 document mode → the `document` sub-command; §21 wall protocol → you hit a WALL; §22
       breakthrough ledger → a decisive/reusable solution cracked the target (tag the block with a
       `**Breakthrough:**` field + add it to the fleet index).
       If unsure whether a section's phase is active, READ IT — a wrongly-skipped rule costs more than the
       tokens saved.
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

4. **Run the loop.** Execute the NORMAL CYCLE one iteration = one cited block, and self-continue per the
   LOOP CONTINUATION + RESCHEDULE CADENCE rules (self-paced: reschedule at the ~60s floor until STOP fires).
   Delegate heavy sweeps with the right MODEL TIER. Emit the per-iteration RETURN CONTRACT (including the
   tier used). At STOP, run the TERMINAL TRIGGER and the §18 SELF-RETROSPECTIVE.
   If the gap targets a BINARY artifact, first run `$KIT/toolbelt/detect-tools.sh --require <decompiler>` to gate the
   environment: it probes TOOL availability (not the binary) — see TOOL-BEFORE-AGENT in PROMPT-LOOP HARD
   RULES. Then analyze with `$KIT/toolbelt/decompile-native.sh <mode> <binary>`; for available modes (ghidra,
   ghidra-evidence, r2, quick) and exact CLI forms, see `$KIT/toolbelt/tool-registry.md`.
   For a LONG unattended run, wrap the invocation with the `/loop` skill
   (`/loop /research-sdd <target> a fondo`) — it is the external re-invoker PROMPT-LOOP was designed for.
   Self-paced reschedule is best-effort and can halt after a single block under conversational guardrails;
   `/loop` guarantees the cadence.

**Walls & evidence (never a silent skip).** A wall is a MISSING CAPABILITY, not an absent answer:
record a TYPED state — `blocked-on-tool` (name the exact capability), `unavailable` (the instrument ran
but produced no result), or `refused` (a gate/permission declined) — never a silent skip or an invented
`[INFER]` (METHODOLOGY §21). Provision FIRST: try `$KIT/toolbelt/install-tool.sh <tool>` (§21.4), then
walk the artifact class's fallback chain (§21.2) and record the last rung reached. For a BINARY artifact,
a decompile is NOT evidence until corroborated: cross-check it with the matching
`$KIT/toolbelt/corroborate-*.sh` wrapper (`tool-registry.md`) — an un-anchored offset can hit a twin
binary (niagara B424).

**Installing a tool is not the end of provisioning — cataloging it is.** `install-tool.sh` auto-logs
every install to `INSTALLED-TOOLS.md`; that half needs no action. Adding the path (Tool paths table),
purpose (Artifact type row), and how-to-use (Wrapper column, or `(direct)` for a manual tool) to
`toolbelt/tool-registry.md` is YOUR job, done proactively as part of the install — do it unprompted,
same as you would save a decision to memory without being asked. `toolbelt/verify-tool-catalog.sh` is
the anti-silent-zero backstop that WARNs on a logged-but-uncataloged tool; treat its WARN as a missed
step, not a substitute for doing it. The guard matches case-insensitively, so a logged lowercase name
finds a Title-case entry without extra work. When the logged name and the catalog display name differ
entirely (e.g. `kaitai-struct-compiler` logged, `ksc` displayed), append `(alias: <logged-name>)` to
the Tool cell of the relevant catalog row so the whole-word match finds it.

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
