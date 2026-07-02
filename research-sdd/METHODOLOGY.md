# Research-SDD — Methodology

> **Research-SDD (SDD-R)** is an adaptation of gentle-ai's SDD for **investigating
> and distilling how a system works** (program, framework, firmware, API),
> instead of building software. Same backbone (phases, fresh context,
> delegation, certainty markers), but the **terminal artifact is knowledge**:
> a corpus of self-contained `.md` blocks in the style of `niagara-research`.

This document is the method contract. The operational engine is [`PROMPT-LOOP.md`](PROMPT-LOOP.md);
the tools, [`toolbelt/tool-registry.md`](toolbelt/tool-registry.md); the subjects,
[`TARGETS.md`](TARGETS.md).

---

## 1. Guiding principle

Investigate **READ-ONLY** and produce **traceable** claims. Every claim carries its
certainty level and its source. Epistemic honesty is the core value: distinguish what
was verified by reading the primary source from what is asserted from a forum or deduced.

The output is not "a document" but an **incremental corpus** of blocks that grows by
loop iteration, keeping at all times a master INDEX, an auto-generated CATALOG
and a list of gaps (what is left to investigate).

## 2. The SDD-R phases (mapping from gentle-ai's SDD)

| SDD phase | SDD-R phase | What it produces |
|---|---|---|
| explore | **scope** — profile the subject: what it is, where its sources/binaries are, which tools apply | source map (feeds `TARGETS.md`) |
| propose | **research-plan** — research questions, hypotheses, priorities | initial gap backlog |
| spec / design | **method** — which tool for which question, order of attack, sources to cross-check | strategy per gap |
| tasks | **gap-backlog** — the prioritized queue of blocks to investigate | `RESEARCH-STATE.md` |
| apply | **investigate 1 gap** READ-ONLY → write/update **1 block** with citations | block `N` |
| verify | **audit certainty** — are the `[CERT]` cited? should any `[CERT-a]` be raised or lowered? | corrected block |
| archive | close the gap, register new gaps, regenerate CATALOG, touch INDEX | updated state |

The **loop** repeatedly runs `apply → verify → archive` over the next gap in the
backlog. `scope`/`research-plan`/`method` run once when starting a new subject
(bootstrap) and are revisited when gaps from an unexplored dimension appear.

## 3. Provenance markers (certainty system)

Extends the 3 from `niagara-research` to distinguish the **reliability of the source**:

| Marker | Meaning | How it is cited |
|---|---|---|
| `[CERT-hw]` | verified **empirically against the live system/device** — the real hardware/server responding, NOT "the code should". The **highest** certainty level. | `sources/probes/<run-output>.txt §…` + the probe that produced it |
| `[CERT]` | verified by reading the **local primary source** (code, decompiled output, bytecode) | `file:line` or `file §section` |
| `[CERT-doc]` | verified against an **official downloaded document** (datasheet/manual) | `sources/manuals/x.pdf §N` or `:p.N` |
| `[CERT-web]` | verified against an **official web source** (manufacturer site, official online doc) | URL + access date |
| `[CERT-a]` | asserted by a **secondary source** (forum, blog, answer) — lower confidence | URL (ideally preserved in `sources/`) |
| `[INFER]` | researcher's deduction, not literal in any source | — |

**Usage rules:**
- Never raise a marker without the citation that backs it. No citation ⇒ `[INFER]`.
- A security finding or a critical claim sitting at `[CERT-a]` (forum) must
  try to escalate to `[CERT]`/`[CERT-doc]` before being accepted.
- The `verify` phase audits exactly this.
- **Hardware wins.** `[CERT-hw]` outranks `[CERT]`: if the live device contradicts what the
  decompiled code implied, the hardware is right — refute/correct the code-based claim and cite the
  probe output (e.g. B64 refuted B55 §55.3 against the real LOGO!). Certainty order, high→low:
  `[CERT-hw]` > `[CERT]`/`[CERT-doc]` > `[CERT-web]` > `[CERT-a]` > `[INFER]`.

## 4. Anatomy of a block

Identical to `niagara-research` (see [`templates/block.template.md`](templates/block.template.md)):

1. **Title**: `# Block N — <descriptive title>`
2. **Header blockquote** (`>`): WHAT it documents, SCOPE, exact SOURCES (real paths
   + documents in `sources/` + URLs), and METHOD with the legend of markers used.
3. `---` line
4. **Numbered sections** `## N.1 — Title \`[CERT]\``, with tables where they help (hierarchies,
   signatures, protocols, comparisons).
5. **Final section** `## N.x — Connections`: `[Block K]` links with the relationship explained.

Each block is self-contained but linked. Size according to source density, not by quota.

## 5. Managing external sources (`sources/`)

Golden rule: **if a claim relies on a datasheet, manual, forum or link, the document
is downloaded and preserved**. URLs die; evidence does not. Structure per target:

```
TARGET/sources/
  SOURCES.md        ← registry: file · type · origin(URL) · date · sha256 · blocks that cite it
  datasheets/   manuals/   web-snapshots/   extracted/   (text from pdftotext/OCR)
```

Blocks cite the **preserved local file** (`sources/manuals/x.pdf §4.2`), not the
volatile URL; `SOURCES.md` keeps the original URL and the hash. The wrapper
[`toolbelt/fetch-doc.sh`](toolbelt/fetch-doc.sh) automates download + extraction + registration.

## 6. Research tools

The loop profiles the artifact type (`profile-target.sh`) and picks the toolbelt wrapper:
Java decompilation (Vineflower/CFR/Procyon), .NET (ilspycmd), native (Ghidra headless / r2 /
ghidra-mcp), firmware (binwalk+yara), docs/web (fetch-doc). Detail and paths in
[`toolbelt/tool-registry.md`](toolbelt/tool-registry.md). Research is **always
READ-ONLY**: the system under study is never modified.

## 7. State and memory (hybrid)

The gap backlog and progress live in **two mirrored places**:
- **Visible/versionable**: `TARGET/INDEX.md` (*Pending* section) + `TARGET/RESEARCH-STATE.md`
  (coverage, prioritized backlog, what was attacked).
- **Cross-session backup**: engram, topic key `research/<target>/gaps` and `research/<target>/progress`.

The loop reads the files first; it uses engram to recover if the local state was lost or
to start a new session.

**Engram `project` convention (do not guess).** All of a target's engram mirrors go under the
**TARGET's own project name** (the corpus directory / repo name, e.g. `niagara-research`), NOT the
kit's project (`sdd-investigacion`) and NOT the orchestrator's ambient project. Pass `project: "<target>"`
explicitly on every `mem_save`/`mem_search` for research mirrors. Sub-agents must be told the target
project in their prompt rather than inferring it from cwd. (Lesson: a niagara mirror landed in the
wrong project #3993 and engram has no delete tool — a misfiled memory is permanent, so set `project`
deliberately.) For a multi-focus target (§16), keep one project per target and disambiguate focuses via
the topic key: `research/<target>/<focus>/gaps`, `.../progress`.

## 8. Stopping criterion

The loop stops on the FIRST of these (primary first):

1. **Read-only investigable set exhausted (PRIMARY — this is the one that actually fires).** Each
   iteration MUST classify every open gap into one of THREE buckets (not two — lesson from logosoft):
   - **read-only-investigable** — answerable by static decompile/reading. The STATIC loop attacks these.
   - **requires-execution** — needs compiling/running a PoC, a round-trip diff, etc. NOT read-only →
     belongs to a separate build phase, NOT the static loop. Do NOT count these as investigable.
   - **blocked** — needs a live system/hardware/server/keys/NDA. → the DYNAMIC phase (§12) if the
     hardware appears; otherwise out of scope.
   The static loop stops when **read-only-investigable = 0**, even if `requires-execution`/`blocked`
   gaps remain. (The backlog rarely empties — each block uncovers 1-4 new gaps; exhaustion of the
   *read-only* subset is the real terminator.)
2. **Backlog empty 2× (secondary).** No open gaps at all for two consecutive iterations.
3. **Budget cap (safety net).** An optional max-blocks / max-token ceiling set at launch.

**A gap closes on a negative finding too.** A rigorously proven ABSENCE closes a gap exactly like a
positive one: if the investigation shows a thing is NOT there — cited as such — the gap is covered, not
open. (Proven on protocols B136: the Sox gap was closed by demonstrating Sox's absence across 973 jars,
cited.) A negative closure needs the same evidence bar as a positive one: cite what you searched and how
(paths, counts, the grep/scan that came back empty), not a bare "not found".

On stopping, declare: blocks written, the **coverage metric** (gaps closed / known gaps — a ratio,
NOT a free-floating percentage), the list of **blocked gaps each tagged with the tool/access it
needs**, and the Tools Report (`toolbelt/INSTALLED-TOOLS.md`).

**Two execution modes.** The NORMAL CYCLE runs under either: **self-paced** (`/loop`, no human present —
the loop agent drives, self-reschedules, and delegates only each gap's heavy sweep) or **orchestrated** (a
human present — the driver chains one sub-agent per iteration and delegates the WHOLE iteration: decompile +
write + self-verify + commit, keeping its own context near-empty across many blocks). Both keep the driver
context-lean; both set the delegated `model` by cognitive demand and never re-verify a block with
orchestrator Bash (§11). PROMPT-LOOP "Two execution modes" has the operational detail.

**Continuation is the default; stopping is the exception.** The loop agent DRIVES its own iterations —
nothing re-invokes it. After each iteration, if none of the criteria above fired, it MUST reschedule and
begin the next gap; the per-iteration report is a checkpoint, not a hand-off. This matters most under
`/loop` self-pacing (no orchestrator to relaunch it): the agent self-reschedules until a criterion fires.
Halting after a single block is a bug (the LOOP CONTINUATION rule was skipped), not a valid stop.

**Reschedule cadence.** The next gap is ready work, not an idle poll — reschedule at the ~60s floor, not
the 1200-1800s idle default. Short delays keep the prompt cache warm (≤300s), so continuous iterations run
cheaper and faster. Stretch the delay ONLY when genuinely blocked waiting on something external.

**Delegate heavy sweeps for loop longevity.** A closed loop dies at compaction. To survive dozens of
iterations, the driver must stay context-lean: any gap needing more than ~3-4 files/classes read or
decompiled is delegated to a sub-agent that returns only cited findings, never raw dumps. Narrow single-file
reads stay inline. This is context hygiene, not a speed trick — every inline decompiler dump shortens the loop.

**Match the delegated model to the sweep (efficiency, not token-saving).** The tier is proportional to the
sweep's cognitive demand — the same principle SDD encodes as a per-phase table, applied here as a
task-type heuristic (the loop is one repeated role, not a fixed pipeline). Mechanical extraction
(enumerate/locate/grep-and-cite) → `haiku`; structural comprehension (reconstruct a subsystem across N
classes, return cited findings) → `sonnet`, the default for most sweeps; genuine reasoning (security
exploitability, architecture judgment) stays inline on the driver or goes to `opus` only if it must be
delegated. The driver loop itself — marker discipline, `[INFER]` deductions, synthesis, self-verify — stays
on the session's strong model. Substitute one tier down when a model is unavailable, and note it.

**Closed loop while working, open loop when done (terminal trigger).** The loop is a closed control system
while read-only-investigable > 0: it self-corrects and self-continues. When that set hits 0, it does NOT
just declare and die — it OPENS to the environment and fires the next action. At FOCUS-level exhaustion it
hands off to the next queued focus (re-entering with the next axis, bootstrapping if new). At CORPUS-level
exhaustion (all focuses done) it emits a NEXT-ACTION — a cross-focus synthesis, or a handoff to a non-static
phase (requires-execution build/PoC §19, or the DYNAMIC/hardware phase §12) — launching it if autonomous and
safe, or handing off to the user when a human decision or hardware is required. Silent end only when there
is no queued focus and no safe next phase.

**Reopening a STOPPED loop for a bounded experiment.** STOP is not permanent. A focus that reached STOP can
be REOPENED for a single, bounded, authorized question — a new tool arrived, a hardware bench appeared, a
targeted follow-up — WITHOUT a full re-bootstrap: read the existing state, run just the added iteration(s),
then re-declare STOP. (Proven on logosoft B76: a DONE static loop reopened for one hardware question, then
re-stopped.) Keep the reopen scoped — it is an experiment, not a re-run of the whole loop.

## 9. Golden rules

1. **READ-ONLY** over the investigated subject. You never modify it.
2. **Do not invent.** No source ⇒ `[INFER]` or omit.
3. **Always cite.** `file:line`, `sources/...`, or URL+date.
4. **Preserve external evidence** in `sources/`.
5. **One block per iteration.** Deep and cited, not wide and vague.
6. **Self-verify** certainty before closing the gap.
7. **Register the new gaps** that the research uncovers (the queue feeds itself).
8. **Re-measure ground-truth live; never inherit it.** In a dynamic/live phase, measure checksums,
   versions, IPs and build ids against the real system — do not cite them from a prior block (§12).

Corpus language: **English by default** — for new targets and targets with no existing corpus.
**Exception (user-approved, per target):** a target with an established corpus in another language MAY
be kept in that language for continuity, but ONLY when the user explicitly approved it AND it is
recorded as an approved override in the target's `Language` column in `TARGETS.md`. Do NOT infer
exceptions — only honor the ones registered there. Currently approved: **logosoft → Spanish** (mature
Spanish corpus; mixing EN+ES would fragment its terminology and cross-references). Everything else: English.

## 10. Self-provisioning (tool installation)

When a gap needs a tool the toolbelt lacks (e.g. a Dart/Flutter AOT decompiler for `app.so`, an
Android decompiler, a Python-bytecode decompiler), the loop **provisions it autonomously** via
[`toolbelt/install-tool.sh`](toolbelt/install-tool.sh) instead of stalling or inflating `[INFER]`:

1. **Recipe** — if `install-tool.sh` has a known recipe, run it (idempotent; never re-installs).
2. **Autonomous install** — install via user-space managers OR `sudo` (non-interactive). Everything
   is logged to `toolbelt/INSTALLED-TOOLS.md`.
3. **If it cannot install** (sudo needs a password, the build fails, no recipe, unverified source):
   the iteration records it as `needs-approval`/`failed`, does the investigable part WITHOUT the tool
   (honest `[INFER]`/gap), and **reports the missing tool to the orchestrator, which ASKS the user
   whether they can install it**. The loop never silently gives up on a tool it genuinely needs.

Safety line (independent of the autonomy level): only **known recipes / official sources**; never
`pipe-to-shell` from an unverified URL.

**Tools Report (at loop end):** when the loop stops, it emits a summary of (a) tools it installed
(with the command used), (b) tools it needed but could NOT install (and why → these are what to ask
the user about), and (c) recommended tools for the domain. Source of truth: `toolbelt/INSTALLED-TOOLS.md`.

## 11. Self-verification contract (in-block gatekeeping)

Gatekeeping lives INSIDE the block-writing iteration, NOT in orchestrator Bash commands (those trigger
permission prompts and were dropped mid-run on EduVolt). Before closing a block, the sub-agent MUST do
and MUST REPORT these checks:

- **Token check** — every load-bearing `[CERT]` token was `grep`-confirmed present in its cited source
  (file / binary / `strings`). Report how many tokens were checked. (Track record this enforces: 12/12
  blocks across TRANE+EduVolt had zero hallucinated citations.)
- **Marker tally** — counts of `[CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER]`, plus the **`[INFER]`/
  `[CERT]` ratio** AND the **block type**. For an **evidence block** (decompilation/reading) a high ratio
  (>~0.5) is the automatic signal that the investigable evidence for this gap is nearly exhausted — say so;
  it feeds the §8 stop decision. For a **design/applied block** (integration plan, PoC design, cross-focus
  synthesis) a high ratio is EXPECTED and healthy, NOT an exhaustion signal, and does NOT close the focus
  (e.g. protocols B137 at ~0.48 was a sound integration plan). Declare the type so the ratio is read right.
- **Artifacts** — the block file exists, `CATALOG.md` regenerated, `INDEX.md` + `RESEARCH-STATE.md`
  updated, and the backlog re-classified investigable-vs-blocked (§8).

The orchestrator **TRUSTS this self-report** and only spot-checks when a report smells off (status
mismatch, an uncited claim, a marker tally that doesn't add up). It does **NOT** run Bash gatekeeper
commands by default — the in-block contract is the gate. This is not a soft preference: on the protocols
run the orchestrator ran a per-block Bash gatekeeper (ls + git log + grep the star claim) after all 6
blocks — every one PASSed and **caught nothing**, while the one real error (a B131 byte-order default) was
caught later by **cross-block correction (§14)**, not by any per-iteration re-check. So the real
error-capture mechanism is §14, not an orchestrator gatekeeper — per-block Bash re-verify only adds
permission friction and driver bloat for no demonstrated catch.

**Scope: this applies to the STATIC read-only loop only.** In a DYNAMIC/hardware, destructive, or
BUILD/PoC phase (§12), a per-block orchestrator Bash gate IS justified and expected — there it verifies
PHYSICAL/EXTERNAL state the in-block self-report cannot vouch for and §14 cannot protect: the device was
left safe (baseline restored, a write reverted, the checksum re-measured live), the blast-radius of a
write was contained, the PoC's round-trip actually ran. §14 catches wrong CLAIMS across blocks; it does
not catch a bricked device or an un-reverted write. Static blocks trust the self-report; live/destructive
iterations gate on real-world state.

## 12. Dynamic phase (validation against a live system)

The static loop (§1–§11) is READ-ONLY decompilation — safe, autonomous, loop-able. When a LIVE system
becomes available (device, server, PLC), a DYNAMIC phase validates the static findings against it. This
phase is DIFFERENT and must NOT run as a blind autonomous loop:

- **Supervised, not loop-blind.** Each interaction with the live system is deliberate; the orchestrator
  reviews before the next step. No `/loop` self-pacing against hardware.
- **Read-first, write-supervised.** Start with READ-ONLY probes (safe on a running system — confirm
  read-only in code first). WRITE/modify (load programs, change config) only step-by-step with explicit
  user OK; a bad write can brick the device.
- **Invasiveness ladder (fixed order).** Escalate deliberately, never skip a rung: (1) read-only probe →
  (2) reversible write — read-and-save the current value first, hold an oracle, restore in a `finally` →
  (3) destructive write — backup-first (below) → (4) irreversible — last, and only under scoped
  authorization (below). Announce which rung each step is on.
- **Cross-protocol oracle for every write.** Validate a write through an INDEPENDENT channel, not the one
  you wrote on. On the LOGO!8: a Modbus FC01 read was the oracle for an RPC `writeDT`, and an RPC GetFB
  read was the oracle for a Modbus write. A write confirmed by a second channel earns `[CERT-hw]`; a write
  confirmed only by the channel that made it is `[INFER]`. No oracle ⇒ do not write.
- **Backup-before-destroy (citable).** Before overwriting a program/image/config, READ and SAVE the current
  one to `sources/`, and VERIFY the backup actually restores. Keep it as both evidence and the revert
  target. A destructive step with no verified backup does not run.
- **Device identity ≠ program identity.** A checksum/version identifies the loaded PROGRAM, not the physical
  UNIT. Confirming you are on the BENCH and not PRODUCTION is out-of-band (who plugged in what), never
  inferred from the program you read. Do this BEFORE any write — a prior session wrote to PRODUCTION
  believing it was the bench (near-miss). Verify the unit, then verify the program.
- **Scoped authorization for irreversible ops.** Irreversible/destructive actions are HARD-BLOCKED by
  default. The user lifts the block "for this session only"; record the grant with an explicit expiry
  (persist it), and re-arm the block when the session ends. Never carry an irreversible authorization
  across sessions.
- **Re-measure ground-truth, never inherit it.** When entering a dynamic/hardware phase (or any new
  live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids — LIVE
  from the real system in THIS phase. Do NOT cite them from a prior note or earlier block: an inherited
  value may be stale. B66-B69 carried a bench-program checksum `05 3d 6e e4` inherited from an earlier
  probe; the live value was `0x87B961A9` (only B70 measured it live), which forced a correction (§14).
- **Reclassify on hardware arrival.** Gaps marked `blocked` (§8) flip to investigable when the live
  system appears — update RESEARCH-STATE and re-run those.
- **Tooling.** Build a read-only probe (a port of the decompiled protocol) and run it via
  [`toolbelt/probe.sh`](toolbelt/probe.sh), which preserves the raw output in `TARGET/sources/probes/`
  as `[CERT-hw]` evidence.
- **Hardware refutes code.** When the device contradicts a `[CERT]` claim, mark the corrected fact
  `[CERT-hw]` and fix the prior block transparently (note "corrected in BN"), as B64 did to B55 §55.3.
- **After an incident, check the DEVICE first (refines §17).** If an iteration was killed/crashed mid-write
  in a hardware phase, the §17 resume rule inverts: check the PHYSICAL device state (is it left safe? was
  the write applied or reverted? re-measure the checksum live) BEFORE checking git/disk. A committed block
  is recoverable; a device left in a half-written state is not. Physical safety precedes artifact state.
- **Environment setup** (e.g. WSL `networkingMode=mirrored` to reach a LAN device, run `wsl --shutdown`
  from **Windows** PowerShell — not inside WSL) is a prerequisite; verify connectivity before probing.

## 13. Audit mode (re-verify an existing corpus)

A mode distinct from gap-discovery: take EXISTING blocks (especially an older corpus written without
this engine) and re-verify their claims against the primary source. Output is an **audit-delta**, NOT a
new knowledge block. Per claim assign: **ESCALATED** (was `[CERT-a]`/hedged → now source-confirmed
`[CERT]`), **CONFIRMED** (held), **DOWNGRADED** (unverifiable → `[INFER]`), **REFUTED** (the source
contradicts it — the most valuable). Write the report under `audits/`, READ-ONLY on the audited corpus.
Driven by [`PROMPT-AUDIT.md`](PROMPT-AUDIT.md). (Proven on niagara B100: 12 escalated, 1 refuted — the
engine adds certainty and catches attribution errors a re-read surfaces, without touching the original.)

**Audit-first as a backlog seed.** A second use of an audit sweep: to BOOTSTRAP the gap-backlog of a new
focus over a mature corpus. Instead of hand-guessing gaps, delegate an audit that returns a coverage
matrix (subsystem × depth × static-vs-dynamic × known-vs-gap); the prioritized backlog falls out of it.
This is the recommended BOOTSTRAP path (PROMPT-LOOP step e) whenever the corpus is large enough that a
hand-listed plan would miss areas — proven on the protocols focus (matrix → 6 well-shaped gaps).

**Coverage audit ≠ certainty audit.** The audit above (and PROMPT-AUDIT) checks whether existing CLAIMS
are TRUE. A **coverage audit** answers a different, recurring user question — "did we cover EVERYTHING?" —
by mapping the corpus against the code UNIVERSE, not re-verifying claims. Delegate a sweep that returns:
(a) a coverage RATIO of the mission scope and of the whole universe (e.g. ~90% of the intended subsystem,
~18% of all classes), (b) the list of subsystems/areas NOT yet touched, and (c) an honest verdict on
whether the untouched areas matter for the mission or are out of scope. Output goes under `audits/` like a
certainty audit, but its verdict feeds the §8 backlog (untouched-but-relevant areas become new gaps), not
the marker escalation. Do not conflate the two: a corpus can be 100% certain on what it covered and still
cover only 18% of the universe.

## 14. Cross-block consistency

The corpus self-corrects: a later block often refutes/refines an earlier one (B59→B55, B62→B17/B51,
B64→B55). Make this a habit, not an accident:

- While investigating, if you touch a fact another block asserts, CHECK it. If it's wrong, CORRECT the
  prior block transparently — keep the original text, add a note "corrected in BN" + the new citation.
- A `[CERT-hw]` finding that contradicts a `[CERT]` block MUST trigger a correction (hardware wins, §3).
- In audit mode (§13), or periodically, sweep blocks on the same subsystem for contradictions.
- Every correction is logged in the correcting block's Connections and in RESEARCH-STATE's history.

## 15. Corpus versioning (git)

Each target's corpus is a git repo (the engine kit lives separately in sdd-investigacion). Bootstrap
runs `git init` in the TARGET so that self-corrections (§14) have history and the corpus is shareable.
On an existing un-versioned corpus, init it once. NOTE: git-init goes in the **target project**, never
in the kit.

## 16. Multi-focus corpus (parallel focuses under one target)

A small target is a single axis. A **mature or large** target often has several distinct subjects worth
investigating in parallel — niagara ended up with three: `Spyder`, `OptimizerSupervisor`, and
`platform-native`. Formalize this instead of spawning ad-hoc state files:

- **One RESEARCH-STATE per focus.** Each focus gets its own `RESEARCH-STATE-<focus>.md` (its own
  coverage ratio + gap backlog). Pick a short, stable `<focus>` slug (the angle from PROMPT-LOOP §b2).
- **A focus index.** Keep a small `FOCUSES.md` at the target root (or a top "## Focuses" section in
  `INDEX.md`) listing each focus as **active / paused / stopped**, its `RESEARCH-STATE-<focus>.md`, and
  its block prefix. This is how the loop (and a human) knows which focuses exist and which is current.
- **Naming convention.** Blocks carry a focus-aware prefix (e.g. `spyder-blockN.md`,
  `platform-native-blockN.md`) so a flat `ls` stays readable; state mirrors them as
  `RESEARCH-STATE-<focus>.md`.
- **State the active focus** when continuing the loop, and confirm the angle (§b2) before opening a new
  focus — a new focus is a new bootstrap, so it deserves the same angle confirmation.
- **One engram project, focus in the topic key.** All focuses mirror under the same target project
  (§7); disambiguate with `research/<target>/<focus>/...` topic keys.

**Concurrent loops under one orchestrator.** Focuses (or whole targets) can run in PARALLEL, not just
sequentially — a lean orchestrator drives N independent loops at once (proven: logosoft build/PoC + niagara
Spyder running simultaneously as background agents). Rules that keep this safe:

- **Independent state, per loop.** Each concurrent loop keeps its OWN `RESEARCH-STATE-<focus>.md`, its own
  block prefix, and its own STOP flag in engram. No shared mutable state between loops.
- **Gatekeep each on its own task-notification.** The orchestrator validates each loop's returned block
  independently as it lands; it does not block one loop waiting on another.
- **Cross-loop barrier for shared actions.** Any action that spans loops — a shared commit, a synthesis
  across focuses, a shared-resource write — waits on a BARRIER: it fires only when ALL participating loops
  have reached the agreed point (e.g. "commit when BOTH have stopped"). Never let one loop take a
  cross-cutting action mid-flight while another is still writing.
- **Concurrency is a context-budget decision.** Run loops in parallel only while the orchestrator stays
  lean (it just routes task-notifications). If the orchestrator starts doing real work per loop, serialize.

## 17. Incident & resume (after a kill / crash / interruption)

Sub-agent iterations can be killed or crash mid-run yet have ALREADY landed their commit (niagara B76
and B122 both did). Before re-launching an interrupted iteration:

1. **Check real state first.** Run `git -C $TARGET log --oneline -5` and inspect the on-disk artifacts
   (the expected block file, CATALOG, INDEX/RESEARCH-STATE) to see whether the iteration already
   committed its work.
2. **Resume from real state, don't blindly redo.** If the block landed, do NOT re-run it — re-running
   risks overwriting good work or duplicating a block. Pick up from the actual committed state: verify
   it self-verified correctly, then continue with the next gap.
3. **If it only partially landed** (e.g. block written but state/CATALOG not updated), finish the
   remaining archive steps rather than restarting the whole iteration.
4. After any incident (wrong cwd, accidental mutation, interrupted run), reconcile engram against the
   on-disk truth before continuing — files are the source of truth, engram is the mirror.

## 18. Self-retrospective (the kit learns from its own runs)

The engine improves by observing real runs — not by guesswork. Every improvement in this kit so far was
harvested by reviewing an actual session transcript against the current rules. §18 makes that a PHASE of
the loop instead of a manual favor: at the end of a run, the loop proposes its own upgrades.

**When it fires.** At every FOCUS completion, and ALWAYS at corpus-level STOP (§8 terminal trigger). For a
very long single focus, it MAY also fire every ~10 blocks so lessons don't wait until the end.

**What it does.** The driver DELEGATES a fresh-context retro agent (fresh context is the point — independent
judgment, not the driver's own rationalizations). The retro agent:

1. **Reads the current kit FIRST** — `$KIT/PROMPT-LOOP.md` + `$KIT/METHODOLOGY.md` — and DEDUPES. It proposes
   only what is genuinely new; a lesson the kit already encodes is noted as "already covered", not re-proposed.
2. **Reviews the run** — blocks written, `§14` cross-block corrections, gaps that stalled or got mis-classified,
   rules that were SKIPPED in practice (e.g. a model tier never set, a gate run where the kit says not to), and
   techniques the operator IMPROVISED that the kit does not name.
3. **Proposes kit deltas** — each with: the concrete change, the target file/section, EVIDENCE (block / commit /
   `§` / transcript refs), and a priority. Anti-patterns become "add a rule that prevents X"; improvised wins
   become "codify Y".
4. **Writes the proposal** to `$TARGET/retros/<date>-<focus>.md` (from `$KIT/templates/retro.template.md`)
   and mirrors it to engram `research/<target>/retro`, and SURFACES it in the return contract.

**Hard boundary — propose, never apply.** The retro agent does NOT edit the kit. Kit changes are reviewed and
committed by a human (the kit is a separate repo, `sdd-investigacion`; the human leads, the engine proposes).
This preserves both the audit trail and the rule that the operator — not an autonomous agent — owns the method.

**Honesty clause.** A run that surfaces nothing new must SAY so ("no new deltas; the kit already covers this
run") rather than inventing improvements to look productive. A retro that always finds something is not a retro,
it is noise.

## 19. Build/PoC loop (the requires-execution phase)

The static loop (§1–§11) is READ-ONLY. Some gaps are answerable only by BUILDING and RUNNING something — a
PoC that ports a decompiled routine, a round-trip that re-encodes a structure and diffs it against the real
artifact. §8 classifies these as `requires-execution` and excludes them from the static stop count; §19 is
their loop. It is NOT read-only, so it runs like the dynamic phase (§12): supervised or auto with declared
hard-stops, never blind.

- **Oracle-anchored.** Every build/PoC iteration validates against an ORACLE — the real artifact or a second
  independent channel. The canonical form is a ROUND-TRIP byte-diff: take the real bytes → parse with your
  port → re-emit → diff against the original. A zero diff earns `[CERT]` on the reconstructed logic; a
  nonzero diff is the finding (it shows exactly where your model of the format is wrong).
- **Stop counter: `requires-execution` → 0.** The static loop stops at read-only-investigable = 0; the
  build loop stops when the `requires-execution` count hits 0 — each PoC that lands decrements it. Track it
  in RESEARCH-STATE exactly like the investigable count.
- **Artifacts in `codegen/`.** PoC source, build output, and captured round-trip diffs live under
  `$TARGET/codegen/` and are preserved as evidence (a diff is `[CERT]` evidence like a probe capture).
  The block cites them; the code is not the deliverable, the validated finding is.
- **Handoff from the static loop.** When the static loop's TERMINAL TRIGGER (§8) sees remaining
  `requires-execution` gaps, it hands off here — this is the "non-static phase" it names. Provisioning a
  compiler/runtime follows §10.
