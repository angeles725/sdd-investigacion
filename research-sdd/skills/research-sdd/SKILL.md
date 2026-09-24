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

## Who drives the loop

You drive it as the **technical excavator** (METHODOLOGY §1): first principles — cite the code, the bytes or the
physics that DEFINE a behaviour, never a summary of it; obsessive rigor — a gap closes when you know why it works
and how it fails, not when it works; systems thinking — every finding is read for its effect on the whole system
(interlocks, blast radius, the layers above and below). Each trait is bound to a checkable rule in §1; a mindset
that cannot be checked is theater.

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
  REUSABLE toolchain/environment knowledge (bring up Ghidra, use bkcrack, a WSL setup step) → PROPOSE
  to the kit: record it in the §18 retro TOOLS section as a `promote` (new toolbelt file) or `absorb`
  (delta into an existing kit file) candidate, plus an Engram pointer immediately so it is recall-findable.
  Kit changes are never applied from inside a run (§18 propose-never-apply). Same `verify-block` gate,
  plus a MANDATORY Engram mirror. Full cycle: PROMPT-LOOP's DOCUMENT CYCLE
  (METHODOLOGY §20). §20 was first exercised end-to-end on a real target by the TradingView new-target
  DOCUMENT run (target #23, B1-B3; see the kit repo-root `retros/2026-08-03-document-unregistered-bootstrap-incident.md`, not `$KIT/retros/`).
  Existing toolchain how-tos (`toolbelt/DYNAMIC-SETUP.md`, `toolbelt/GHIDRA-MCP.md`) predate the mode.
- **frontier** — genuinely unexplored territory with no prior corpus coverage on the proposed surfaces.
  Different sweep strategy from the four modes above: BREADTH-FIRST with LIGHTER BLOCK DENSITY — the goal is
  a COVERAGE MAP across many sub-areas, not deep certification of one. The `[INFER]`/`[CERT]` ratio is
  EXPECTED HIGH and signals "return with targeted deep-dive passes later", NOT exhaustion. Declare
  `MODE: frontier` in RESEARCH-STATE at bootstrap. Full definition: METHODOLOGY §8. Distinct from a
  grade-upgrade reopen (deepens evidence for already-asked questions) and from live-backlog injection
  (extends an active loop's queue).

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
   - `$KIT/METHODOLOGY.md` — the rules. Do NOT ingest all 23 sections every iteration; it is a reference,
     not a monolith to reload each block. Load it in two tiers — lazy-load is NOT skip: every rule still
     applies, you only DEFER loading a section until its phase fires, and reading it is MANDATORY then.
     - HOT-CORE — <!-- slot:hotcore-cadence -->read once per context (session start, after a compaction, or in each fresh sub-agent)<!-- /slot -->:
       §1 guiding principle, §2 phases, §3 the 7 markers, §4 block anatomy, §7 state/memory,
       §8 stopping + terminal trigger, §8b backlog cell grammar (written every iteration), §9 golden rules,
       §11 self-verify, §17 resume.
       <!-- slot:hotcore-reread-scope -->Each iteration re-reads only RESEARCH-STATE, INDEX, and `--next` from the live backlog.<!-- /slot -->
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
       `**Breakthrough:**` field + add it to the fleet index); §23 three-session kit-change template →
       coordinating a kit change across separate coordinator / researcher / QA sessions; §3b corpus layout →
       creating or moving corpus files; §7b state-envelope instruments → a CHECK A mismatch or a
       shared-prefix corpus; §8c campaign queue → a focus STOP, a FRONTIER-REOPEN audit, or campaign STOP;
       §11a measurement and data-pipeline heuristics → a data-acquisition target; §20b block mode vs.
       journal mode → deciding whether applied work
       becomes a corpus block or a journal entry.
       Read a situational section when its trigger is your next action.
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
   AMBIGUOUS "CONTINUE <TOPIC>" — ALL-TERMINAL CASE: when an operator's "continue <topic>" instruction
   matches one or more focuses and ALL matching focuses are in terminal state (STOP fired, retro written,
   no open investigable gaps), do NOT guess which terminal focus to reopen. Instead, run an AUDIT-FIRST
   coverage sweep: read the INDEX.md and RESEARCH-STATE for the matching focuses, derive any net-new
   territory not yet covered, and surface that as candidate new gaps before asking the operator to
   choose. Reopening a terminal focus is a last resort; a coverage sweep first confirms whether
   genuine new territory exists. (Evidence: niagara wb-vendor-ux-wave3 retro.)

4. **Run the loop.** Execute the NORMAL CYCLE one iteration = one cited block, and self-continue per the
   LOOP CONTINUATION + RESCHEDULE CADENCE rules in PROMPT-LOOP. Delegate heavy sweeps with the right
   MODEL TIER. <!-- slot:loop-return-contract-explicit -->Emit the per-iteration RETURN CONTRACT (PROMPT-LOOP RETURN CONTRACT section — that is
   the single definition of the token format and required fields); ending with "shall I continue?" or
   any equivalent question is a contract violation.<!-- /slot --> At campaign STOP, run the TERMINAL TRIGGER and
   the §18 SELF-RETROSPECTIVE.
   The run is NOT OVER until the retro exists (from `$KIT/templates/retro.template.md`, `<!-- review-status: pending -->`,
   `## Proposed kit deltas` table or the honesty line) — this applies to quick, document and applied runs too, not only
   to STOP. State `retro: written <path>` or `retro: not-due` in the final return. A target wired with the kit's Stop hook
   (`toolbelt/retro-gate.sh`, kit issue #479) blocks the session once until it holds.
   If the gap targets a BINARY artifact, first run `$KIT/toolbelt/detect-tools.sh --require <decompiler>` to gate the
   environment: it probes TOOL availability (not the binary) — see TOOL-BEFORE-AGENT in PROMPT-LOOP HARD
   RULES. Then analyze with `$KIT/toolbelt/decompile-native.sh <mode> <binary>`; for available modes (ghidra,
   ghidra-evidence, r2, quick) and exact CLI forms, see `$KIT/toolbelt/tool-registry.md`.
   For a LONG unattended run, wrap with the `/loop` skill — recommended as DYNAMIC (no interval):
   `/loop /research-sdd <target> a fondo`; the re-fire depends on the agent calling ScheduleWakeup
   at the ~60s floor. FALLBACK: if the dynamic run halts after a single block or the harness has no
   ScheduleWakeup, use fixed-interval: `/loop 5m /research-sdd <target> a fondo`.

**Walls & evidence (never a silent skip).** A wall is a MISSING CAPABILITY, not an absent answer:
record a TYPED state — `blocked-on-tool` (name the exact capability), `unavailable` (the instrument ran
but produced no result), or `refused` (a gate/permission declined) — never a silent skip or an invented
`[INFER]` (METHODOLOGY §21). Provision FIRST: try `$KIT/toolbelt/install-tool.sh <tool>` (§21.4), then
walk the artifact class's fallback chain (§21.2) and record the last rung reached. For a BINARY artifact,
a decompile is NOT evidence until corroborated: cross-check it with the matching
`$KIT/toolbelt/corroborate-*.sh` wrapper (`tool-registry.md`) — an un-anchored offset can hit a twin
binary (niagara B424).

**Installing a tool is not the end of provisioning — proposing the catalog row is.** `install-tool.sh`
auto-logs every install to `INSTALLED-TOOLS.md`; that half needs no action. Adding the path (Tool paths
table), purpose (Artifact type row), and how-to-use (Wrapper column, or `(direct)` for a manual tool)
to `toolbelt/tool-registry.md` is PROPOSED, not applied from inside a run: record the row in the §18
retro TOOLS section as an `absorb` candidate (§18 propose-never-apply). Provisioning is complete for
this run when the §18 retro entry is written; the supervisor applies it later. Record an Engram pointer
immediately so the tool is recall-findable while the kit row awaits the supervisor.
`toolbelt/verify-tool-catalog.sh` is the anti-silent-zero backstop: a WARN while a §18 retro proposal
for that tool is already pending is expected — the row awaits the supervisor. A WARN for a tool with
NO proposed row in any retro is the missed step: write the §18 retro TOOLS entry now. The guard matches
case-insensitively, so a logged lowercase name finds a Title-case entry without extra work. When the
logged name and the catalog display name differ entirely (e.g. `kaitai-struct-compiler` logged, `ksc`
displayed), include `(alias: <logged-name>)` in the §18 retro TOOLS entry for that row — so the
supervisor adds it to the Tool cell when applying the catalog row.

## Execution mode

This table applies to heavy and continue modes only — quick and light modes never launch `/loop`. Announce the mode and proceed; do not ask which mode.

| Situation | Mode | Launch | Continuation |
|---|---|---|---|
| Unattended (default at BOOTSTRAP) | Self-paced dynamic (recommended) | Launch `/loop /research-sdd <target> [focus]` before the first iteration | ScheduleWakeup at ~60s floor; at campaign STOP, do not reschedule |
| Unattended, dynamic halted after 1 block | Self-paced fixed-interval (fallback) | `/loop 5m /research-sdd <target> [focus]` | Harness re-fires; campaign STOP: disarm the re-invoker (CronList → CronDelete; else tell the operator) |
| Attended — operator asked to review between blocks | Orchestrated | Proceed directly — do not launch `/loop` | End report with RETURN CONTRACT token; driver re-invokes on `next*`, ends on `STOP:` |

Before launching in unattended mode, check whether a re-invoker is already active (arrived via `/loop`, or a wakeup/cron is armed). If one is active, proceed directly without a nested launch. Do not issue ScheduleWakeup when the operator asked to review between blocks (orchestrated mode) — that spawns a rogue autonomous loop alongside the operator.

Dynamic is recommended for unattended runs; fixed-interval is the deterministic fallback. For stall detection, the instrument reads `last_iteration_ts` in RESEARCH-STATE (METHODOLOGY §8c) — an operator who sees no new block commit for > 15 min can relaunch with the `/loop 5m` fallback while that instrument is pending.

## Boundaries

- READ-ONLY over the subject under study. The kit is the source of truth for HOW; do not invent rules here.
- Corpus language follows `TARGETS.md` (English by default; only APPROVED overrides change it).
- Kit changes are never made from inside a run — the §18 retro PROPOSES deltas for human review, it does
  not edit `$KIT`.
