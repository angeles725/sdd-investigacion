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

1. **Investigable set exhausted (PRIMARY — this is the one that actually fires).** Every open gap in
   `RESEARCH-STATE.md` is blocked on something unavailable: a tool the toolbelt can't provide (e.g. an
   x64 Dart-AOT decompiler that does not exist), a live server, or lab/hardware/NDA. Each iteration
   MUST classify the backlog into **investigable** vs **blocked-on-<reason>** and record both counts;
   when the investigable count reaches **0**, stop. The "backlog empty" idea below rarely fires —
   evidence from TRANE/EduVolt: the backlog *grows* (each block uncovers 1-4 new gaps), so exhaustion
   of the *investigable* subset, not emptiness, is the real terminator.
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

Corpus language: **ALWAYS English**, for every target, with no exceptions. The loop writes every
block in English even when a target already has an existing corpus in another language. The
"Language" column in `TARGETS.md` only records the existing corpus language as a historical fact;
it does NOT change the generation language, which is always English.

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
