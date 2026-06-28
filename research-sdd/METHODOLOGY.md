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

On stopping, declare: blocks written, the **coverage metric** (gaps closed / known gaps — a ratio,
NOT a free-floating percentage), the list of **blocked gaps each tagged with the tool/access it
needs**, and the Tools Report (`toolbelt/INSTALLED-TOOLS.md`).

## 9. Golden rules

1. **READ-ONLY** over the investigated subject. You never modify it.
2. **Do not invent.** No source ⇒ `[INFER]` or omit.
3. **Always cite.** `file:line`, `sources/...`, or URL+date.
4. **Preserve external evidence** in `sources/`.
5. **One block per iteration.** Deep and cited, not wide and vague.
6. **Self-verify** certainty before closing the gap.
7. **Register the new gaps** that the research uncovers (the queue feeds itself).

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
  `[CERT]` ratio**. A high ratio (>~0.5) is the automatic signal that the investigable evidence for
  this gap is nearly exhausted — say so; it feeds the §8 stop decision.
- **Artifacts** — the block file exists, `CATALOG.md` regenerated, `INDEX.md` + `RESEARCH-STATE.md`
  updated, and the backlog re-classified investigable-vs-blocked (§8).

The orchestrator **TRUSTS this self-report** and only spot-checks when a report smells off (status
mismatch, an uncited claim, a marker tally that doesn't add up). It does **NOT** run Bash gatekeeper
commands by default — the in-block contract is the gate.

## 12. Dynamic phase (validation against a live system)

The static loop (§1–§11) is READ-ONLY decompilation — safe, autonomous, loop-able. When a LIVE system
becomes available (device, server, PLC), a DYNAMIC phase validates the static findings against it. This
phase is DIFFERENT and must NOT run as a blind autonomous loop:

- **Supervised, not loop-blind.** Each interaction with the live system is deliberate; the orchestrator
  reviews before the next step. No `/loop` self-pacing against hardware.
- **Read-first, write-supervised.** Start with READ-ONLY probes (safe on a running system — confirm
  read-only in code first). WRITE/modify (load programs, change config) only step-by-step with explicit
  user OK; a bad write can brick the device.
- **Reclassify on hardware arrival.** Gaps marked `blocked` (§8) flip to investigable when the live
  system appears — update RESEARCH-STATE and re-run those.
- **Tooling.** Build a read-only probe (a port of the decompiled protocol) and run it via
  [`toolbelt/probe.sh`](toolbelt/probe.sh), which preserves the raw output in `TARGET/sources/probes/`
  as `[CERT-hw]` evidence.
- **Hardware refutes code.** When the device contradicts a `[CERT]` claim, mark the corrected fact
  `[CERT-hw]` and fix the prior block transparently (note "corrected in BN"), as B64 did to B55 §55.3.
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
