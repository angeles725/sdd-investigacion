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

## Purpose

This kit exists to refuse the ceiling. When a licensing wall, a missing source, or a vendor's refusal closes one path, that bounds one path — not the question. Before recording a limit, enumerate what else could answer the same question (§6 channel inventory, §6 file census). The detour is often better than the road it replaced.

**The pair that makes this work:**

1. **Never accept a ceiling on one source's word.** Enumerate alternatives before closing a route; the `tried:` clause in RESEARCH-STATE (§8) is how this is recorded durably.
2. **Close a route with measurement, not with feeling.** A `blocked` entry without a measurement is an unfinished gap. A corpus full of unexamined alternatives is as useless as one that gave up early.

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
| `[CERT-live]` | verified **empirically against a live REMOTE service you do not own** (hosted / cloud / third-party HTTP API) — the real endpoint's runtime RESPONSE, not its published docs. Same top rank as `[CERT-hw]`; the risk model differs (rate-limits / ToS / authorization / metered cost, not physical bricking — §12b remote-API frame). A service you deploy and own (edge / serverless / PaaS — §12c) is **not** `[CERT-live]`; use `[CERT-hw]` there. | `sources/probes/<run-output>.txt §…` + the request that produced it |
| `[CERT]` | verified by reading the **local primary source** (code, decompiled output, bytecode) | `file:line` or `file §section` |
| `[CERT-doc]` | verified against an **official downloaded document** (datasheet/manual) | `sources/manuals/x.pdf §N` or `:p.N` |
| `[CERT-web]` | verified against an **official web source** (manufacturer site, official online doc) | URL + access date |
| `[CERT-a]` | asserted by a **secondary source** (forum, blog, answer) — lower confidence | URL (ideally preserved in `sources/`) |
| `[INFER]` | researcher's deduction, not literal in any source | — |

**Usage rules:**
- Never raise a marker without the citation that backs it. No citation ⇒ `[INFER]`.
- **Negative-existence claims carry the same open-it obligation as positive ones.** A negative existence claim about a named artifact ("no `com.tridium.niagarad.license.*` exists in `niagarad.jar`") is `[CERT]` ONLY if that EXACT named artifact was opened/decompiled. An agent asserting absence about an artifact it did NOT open is `[INFER]`, never `[CERT]` — the same discipline that requires a positive claim to cite the opened source applies symmetrically to absence.
- A field/semantic assignment derived ONLY from statistical distribution (byte-frequency analysis, uniform-distribution heuristics, correlation sweeps) is `[INFER]`, never `[CERT]` — regardless of how strong the correlation looks. It is promoted to `[CERT]` only by a symbol, a spec, or a documented anchor.
- A security finding or a critical claim sitting at `[CERT-a]` (forum) must
  try to escalate to `[CERT]`/`[CERT-doc]` before being accepted.
- The `verify` phase audits exactly this.
- **Static-defect / runtime-exploitability split.** When a code-level security defect is confirmed in
  source (`[CERT]`) but whether it is EXPLOITABLE depends on runtime/container/framework semantics NOT
  documented in the corpus, SPLIT the claim — assert the code omission as `[CERT]`, mark exploitability
  as `[INFER]`, and open a named requires-execution child gap (§8) to reproduce it. Do NOT assert the
  vulnerability as real, and do NOT dismiss it as benign; state the bounded blast radius from what IS
  known statically. (This is the static-authoring sibling of §12's post-live CONFIRMED/GATED/DEFERRED
  verdicts.)
- **Engram `#id` is NOT a valid `[CERT]` citation.** Engram is a MIRROR, not a primary source (§7). If the underlying fact came from live hardware or probe work, cite `[CERT-hw]` with the preserved probe output; if it is a researcher deduction stored in memory, cite `[INFER]`. A block that cites `engram #N` as `[CERT]` is not reproducible — a reviewer cannot follow that citation to the source.
- **Physical-inspection evidence** — device photos, indicator-lamp readings, display-state images — is `[CERT-hw]` when the image file is archived under `sources/probes/` and cited by filename (`sources/probes/<photo>.jpg`). This extends the probe-output citation format to visual captures; a photo cited without archiving it first is `[INFER]`.
- **The live system wins.** `[CERT-hw]`/`[CERT-live]` outranks `[CERT]`: if the live device OR remote
  service contradicts what the decompiled code implied, the observed live behavior is right — refute/correct
  the code-based claim and cite the probe/response output (e.g. B64 refuted B55 §55.3 against the real
  LOGO!). Certainty order, high→low:
  `[CERT-hw]`/`[CERT-live]` > `[CERT]`/`[CERT-doc]` > `[CERT-web]` > `[CERT-a]` > `[INFER]`.
- **Certainty RANK ≠ INFORMATIVENESS — for a catalog/breadth question, a POPULATED artifact beats a thin
  live default.** The ranking above answers IDENTITY/PROTOCOL questions ("what is X really?"). When the
  question is instead "what is the FULL SET of X" (a catalog, an enum, a card-type universe), actively prefer
  a REAL, populated `[CERT]` artifact (e.g. an on-disk config) over a thin/DEFAULT `[CERT-live]` instance: a
  live system's default/empty state can UNDER-report breadth even though `[CERT-live]` outranks static
  evidence for identity. (A live station's default dashboard showed 2 cards `[CERT-live]` while a real on-disk
  config held the true 20-type / 26-card catalog.) The live instance still WINS on identity — it just cannot
  certify a breadth it never had to render.

**`[INFER]` sub-convention — a "corpus-assigned" value.** A distinct, disciplined use of `[INFER]`: a source
specifies a value by named ROLE only (not a concrete value), and the researcher ASSIGNS the concrete value. This
is a `[INFER]` — **never a `[CERT]`** (no source states the literal value) — permitted ONLY when the assigned
value is TOOL-VERIFIED (e.g. `contrast.py`/WCAG certifies a colour satisfies the role) AND explicitly flagged
"corpus-assigned" at the claim. It does not weaken the marker rules; it NAMES an existing honest technique (used
B21→B28 in the dashboards corpus): the source names the role, the tool certifies the concrete value FITS it, and
the flag makes the assignment auditable. It stays `[INFER]` because the tool verifies FITNESS, not provenance —
the literal value is still the researcher's, not the source's.

**`[INFER]` sub-convention — a "computed-value" (`[INFER]`).** A sibling of the corpus-assigned case, for a
value COMPUTED from a cited public FORMULA rather than role-assigned: `value = formula(cited inputs)`, where the
formula and its inputs are themselves cited (`[CERT-doc]`/`[CERT-web]`). It is a `[INFER]` — **never a `[CERT]`**
(no source states the literal result) — permitted ONLY when the result is CROSS-CHECKED against an INDEPENDENT
PUBLISHED anchor (a table/figure from another source or block that reports the same quantity), and explicitly
flagged e.g. `[INFER — computed via <formula ref>]`. It differs from the corpus-assigned case in BOTH halves:
the value comes from a formula (not a named role), and the verification is a cross-check against a published
anchor (not a tool certifying fitness, as WCAG contrast does). Example: an airtime table computed via the
`[INFER — computed via Semtech AN1200.13]` formula, cross-checked against an earlier block's published anchors.

**Sealing `[CERT]` adversarially (OPT-IN selective seal — trialed once on a real claim, 2026-07-07 — see GRADUATION UPDATE below).** Beyond the self-report gate (§11), a LOAD-BEARING `[CERT]` claim
(one a conclusion rests on) MAY be sealed by the **adversarial-verify** workflow: N=3 skeptics try to REFUTE it,
and it stays sealed only if it SURVIVES ≥2 of 3 — otherwise it is downgraded or dropped. Apply it SELECTIVELY
(cost discipline) to conclusion-bearing claims only — not `[INFER]`, not trivia. LOCAL `file:line` claims are
cheap (the skeptics read the cited source, no web); web-verifiable claims are expensive. Operational rule + cost
discipline in PROMPT-LOOP step 5; workflow at [`toolbelt/adversarial-verify.js`](toolbelt/adversarial-verify.js).
STATUS (GRADUATED 2026-07-07 — see GRADUATION UPDATE below): the workflow is self-validated (3/3 refuted a false
claim, 3/3 preserved a true one) AND has now sealed its FIRST real load-bearing claim — `threejs-block7`'s
OrbitControls `autoRotate`/`update(deltaTime)` `[CERT-web]` contract → SURVIVED 3/3. It is no longer PARKED: it is
a STANDING gate, MANDATORY for conclusion-bearing `[CERT]` claims (see POLICY in the GRADUATION UPDATE), OPT-IN/
SELECTIVE for other load-bearing `[CERT]`.
GRADUATION TRIGGER (how EXPERIMENTAL ended): fires the FIRST time a SECURITY-CRITICAL or conclusion-bearing
claim must escalate to `[CERT]`/`[CERT-doc]` and a wrong seal would mislead a downstream decision — a LOCAL
`file:line` claim is cheap (the skeptics only read the cited source, no web). Record the outcome (survived
≥2/3, or downgraded) in that block and flip this STATUS from "never run" to "trialed on B&lt;n&gt;". This
condition WAS satisfied on 2026-07-07 by the `threejs-block7` trial (see GRADUATION UPDATE below) — it did
NOT manufacture a synthetic trial to retire the label (that would have been exactly the make-work the §18
honesty clause forbids); the trial was a real load-bearing claim. This was a defined exit condition, not a
permanent shelf, and it has now been exited.

**GRADUATION UPDATE (2026-07-07).** Trialed on a real load-bearing claim for the first time:
`threejs-block7`'s OrbitControls `autoRotate`/`update(deltaTime)` `[CERT-web]` contract → **SURVIVED 3/3**
(0 refutes; skeptic confidence 0.9-0.97; corroborated against threejs.org docs + GitHub #26471). The trial was
DELIBERATE (to graduate the tool, not decision-forced) — and it EARNED ITS KEEP: it surfaced + fixed a real
aggregation bug (the old fixed `refutes < 2` threshold false-sealed a claim on ONE hostile vote when two
skeptics died). The seal decision is now unit-tested in
[`toolbelt/adversarial-verdict.mjs`](toolbelt/adversarial-verdict.mjs): KILL on majority-refute of VALID votes
(`>= ceil(valid/2)`), `INSUFFICIENT` below a quorum of 2. The seal is now **confidence-GRADED**: a claim whose
refute-count SURVIVES but whose surviving skeptics carry a mean `confidence` below the threshold (default `0.7`)
is `INSUFFICIENT` — survived weakly, NOT sealed as full `[CERT]` (backward-compatible: confidence-less legacy
votes keep plain SURVIVES). POLICY: the adversarial seal is **MANDATORY for conclusion-bearing `[CERT]` claims**
(the ones a conclusion rests on) — not opt-in for those; it stays OPT-IN/SELECTIVE for other load-bearing `[CERT]`
and is NOT a blanket per-block gate (§11: a per-block re-verify caught nothing; §14 cross-block is the real error
capture). HONESTY (§18): seal only when a wrong seal would genuinely mislead a downstream decision — never to pad a count.

## 3b. Anatomy of a corpus (directory layout)

A block's shape is defined in §4; this is the shape of the corpus AROUND it. The layout is not
cosmetic — every fleet instrument searches fixed paths, so a target that stores something elsewhere
becomes invisible to the instrument that should find it. That is measured, not hypothetical:
`api-openness` keeps four tools under `_extract/` (one of them flagged `promote` by its own retro) and
`sweep-tools.sh` reports `no tools directory` for it. The work exists, was evaluated, and cannot be seen.

**Canonical layout.** `research-sdd-init.sh` scaffolds the first four; the rest appear as the run needs
them and are canonical when they do:

| Path | Holds | Created by |
|---|---|---|
| `<target>/retros/` | §18 self-retrospectives, one per run | BOOTSTRAP |
| `<target>/tools/` | tools born inside the loop + `README.md` provenance ledger (§10) | BOOTSTRAP |
| `<target>/.claude/hooks/` | the session hook — must ALSO be registered in a `settings.json` to fire | BOOTSTRAP |
| `<corpus>/sources/` | preserved external evidence + `SOURCES.md` registry (§5) | BOOTSTRAP |
| `<corpus>/sources/extracted/<basename>/` | text extracted from a preserved binary source (PDF, CHM) | on demand |
| `<corpus>/sources/probes/<name>/` | full evidence of an out-of-tree §19 deliverable | on demand |
| `<corpus>/audits/` | §13 audit reports | on demand |
| `<corpus>/codegen/` | §19 build/PoC artifacts and round-trip evidence | on demand |
| `<corpus>/` root | `INDEX.md`, `CATALOG.md`, `RESEARCH-STATE.md`, and the blocks | BOOTSTRAP |

**Two block placements, both legitimate.** `<corpus>` is either the target root (flat) or a subdirectory
such as `corpus/` (nested). Instruments resolve this by locating `RESEARCH-STATE*.md`, which is why that
file's presence is load-bearing beyond its content — a corpus without it cannot be located at all, only
guessed at.

**Existing variants stay legitimate until migrated.** Six mature corpora predate this section and differ
from each other; declaring a canon does not invalidate them. What it does require is that a deviation be
DECLARED in `RESEARCH-STATE.md` rather than discovered later by an instrument reporting zero. An
undeclared deviation is indistinguishable from an empty corpus, and the remedies are opposite.

**The cost of divergence is paid by every instrument, forever.** `sweep-retros.sh` walks retros
recursively and `verify-registry.sh` carries nested-corpus resolution because targets diverged first and
the tools had to tolerate it afterwards. Each new variant makes every future instrument more defensive.

## 4. Anatomy of a block

Identical to `niagara-research` (see [`templates/block.template.md`](templates/block.template.md)):

1. **Title**: `# Block N — <descriptive title>`
2. **Header blockquote** (`>`): WHAT it documents, SCOPE, the **subject version** stamp
   (`Subject version: vX.Y.Z | commit | date | "unversioned"` — required for DRIFTED/REFUTED
   disambiguation in §13 audit mode), exact SOURCES (real paths + documents in `sources/` + URLs),
   and METHOD with the legend of markers used.
3. `---` line
4. **Numbered sections** `## N.1 — Title \`[CERT]\``, with tables where they help (hierarchies,
   signatures, protocols, comparisons).
5. **Final section** `## N.x — Connections`: `[Block K]` links with the relationship explained.

Each block is self-contained but linked. Size according to source density, not by quota.

**Collaborative bridge block (Type: collaborative).** A block whose agent-authored half maps software features or findings to the gap, and whose DOMAIN or THEORY section carries explicit `[TO ANNOTATE]` placeholders for the human's engineering knowledge (EMC constraints, SI/PI limits, thermal budgets — facts the researcher cannot derive from source files alone). This is NOT an incomplete block — it is intentionally co-authored and valid in its partial state. Declare `Type: collaborative` in the header blockquote so a reviewer reads the empty placeholder sections as intentional (expected-zero), not a marker deficiency. This is a human-facing convention only: `verify-block.sh` does NOT parse `Type:` and will still tally the empty sections in its marker counts — read that tally in light of the declared type; do not expect the script to suppress it.

**Block `Type` field — closed grammar (kit issues #128, #422).** The header blockquote's `**Type:**` line is read by
its LEADING token, after stripping at most one leading `**`; everything after the token is free decoration. Legal
tokens: `standard` (the default — omit the line), `evidence` (alias of `standard`), `synthesis`, `mixed`,
`absence-centred`, `capture`, `document` (alias of `capture`), `collaborative`, `audit`. Why a closed grammar: the
template listed five values while real blocks wrote `evidence (primary modbus spec)`, `synthesis (no new
decompilation)`, `document / runbook` — 8 of 763 niagara blocks declared any type and none used a template value, so
no instrument could ever read it (the same free-form-cell failure as the TARGETS.md maturity cell and the FOCUSES.md
status cell). **Instrument status (readback against the live code):** until #422 lands, `verify-block.sh` does not
parse `Type:`; its "[CERT] markers present but ZERO file:line citations resolved" WARN fires on every synthesis /
capture / absence-centred block and is EXPECTED there — the reviewer's substitute is the `[Block N]` token check
(PROMPT-LOOP). #422 makes `verify-block.sh` read the token and downgrade that WARN to INFO for the declared types;
an unrecognised token then WARNs by name, never silently.

> **Block file naming.** The canonical catalog/discriminator (`templates/gen-catalog.py`, `verify-state.sh`,
> `research-sdd-archive.sh`) requires a focus/subject prefix — `<prefix>-blockN.md` (or `bloqueN.md`) — so a
> no-prefix `blockN.md` is silently dropped. A single-focus corpus that names its files `blockN.md` with NO
> prefix therefore needs a LOCAL optional-prefix `tools/gen-catalog.py` (the `impresora-samsung-m2070` target
> is the known exception); prefer the prefixed convention for any new corpus so the kit-generic tooling sees
> every block.
>
> **Note:** `impresora-samsung-m2070` is intentionally unregistered in `TARGETS.md` — it is a local
> single-use exception to the naming rule, not a tracked research target.

## 5. Managing external sources (`sources/`)

Golden rule: **if a claim relies on a datasheet, manual, forum or link, the document
is downloaded and preserved**. URLs die; evidence does not. Structure per target:

```
TARGET/sources/
  SOURCES.md        ← registry: file · type · origin(URL) · date · sha256 · blocks that cite it
  datasheets/   manuals/   web-snapshots/   extracted/   (page-anchored .md from extract-pdf.sh)
```

Blocks cite the **preserved local file** (`sources/manuals/x.pdf §4.2` / `:p.N`), not the
volatile URL nor the extract; `SOURCES.md` keeps the original URL and the hash. The wrapper
[`toolbelt/fetch-doc.sh`](toolbelt/fetch-doc.sh) automates download + registration;
[`toolbelt/extract-pdf.sh`](toolbelt/extract-pdf.sh) turns a PDF into page-anchored Markdown
(text-layer-first; OCR only for `fonts=0` scans, and OCR'd extracts are tagged `reliability: ocr-lossy`
so their citations get extra §11 scrutiny).

**Already-on-disk official doc corpora (`fetch-doc.sh` is URL-only; local-origin sources use cp + sha256 + SOURCES.md row).** When official documentation is already on disk rather than fetched via URL, the preservation sequence is: (1) `cp -r <source-tree> sources/manuals/<focus>-docs/`; (2) `sha256sum` the preserved files to produce the integrity hash; (3) add a SOURCES.md row with the local-origin path in the origin cell and the full hash in the sha256 cell. Cite the preserved copy exactly as a URL-fetched manual; `[CERT-doc]` applies once the file is registered with a populated hash. Do not improvise per-run — the `jsonToolkit` focus preserved 33 files across 14 blocks with no kit recipe, repeating the same 3-step by convention and establishing the workflow gap: inconsistency risk (missing sha256, blank Blocks column, wrong granularity) is real.

Check compliance mechanically — EDGE-TRIGGERED within the iteration right after an edit to `SOURCES.md` (only
when a source was actually added/preserved that iteration — see §11), at loop STOP as the final backstop, or in a
supervised review — with
[`toolbelt/verify-sources.sh`](toolbelt/verify-sources.sh) `<target>`: it fails when a corpus cites
`[CERT-doc]`/`[CERT-a]` but has no `sources/SOURCES.md`, or a cited `sources/` file is absent on disk, or a
block NAMED in the registry's "Blocks that cite it" column does not actually reference that source — a
FABRICATED citation (LEVEL 4, cross-checks the registry against block content; parses both `B60` and
`[Block 21]` forms). Lessons baked in: logosoft cited 10 `[CERT-doc]` PDFs with no registry at all (the rule
held by convention only), and a first-cut registry row claimed two blocks cited a preserved HTML they never
mention — the `[CERT-a]` in those blocks was legend boilerplate, not a citation, and LEVELs 1-3 all passed it.
It also VERIFIES the registered `sha256`: for a web-snapshot whose registry cell is a FULL 64-hex hash it
recomputes the on-disk file and FAILs on a mismatch (LEVEL 6 — a tampered/corrupted or stale-registered
snapshot; the hash is now load-bearing, not just collected). `fetch-doc.sh` now writes the FULL hash into the
registry cell (the console line still shows a truncated `${sha:0:16}…` for readability), so integrity is
ENFORCED for every NEW snapshot it registers. A MISSING/placeholder or TRUNCATED hash cell is an
`unverifiable-hash` WARN only — pre-existing rows registered before this change (truncated `${sha:0:16}…`, or
`(unhashed…)`) stay WARN until re-registered, rather than hard-failing corpora for un-checkable integrity.

**Back-fill the "Blocks that cite it" column every iteration.** `fetch-doc.sh`'s `reg()` writes each new
source row with a BLANK trailing cell BY DESIGN — it registers the file at fetch time, before any block cites
it, and expects a later manual back-fill. When a block cites that source, ADD its block ID to the row's last
column in the SAME iteration (right after WRITE ONE BLOCK / UPDATE STATE — see PROMPT-LOOP steps 4/6). Leaving
the cell blank is not cosmetic: `verify-sources.sh`'s LEVEL-4 fabricated-citation cross-check ONLY validates
rows that NAME a block, so an empty cell silently disables that check for the row. (A whole focus once left all
12 of its registered rows blank, disabling the check for every one.)

**Cite the FULL LITERAL registered basename — never an ellipsis form.** When a block cites a long or generated
snapshot filename (e.g. a `www.thethingsnetwork.org_docs_..._duty-cycle_.md` web-snapshot), write the FULL
literal basename (or a script-recognizable unique substring of it) at least once in the block — NOT an
ellipsis-abbreviated form (`…_duty-cycle_.md`). `verify-sources.sh`'s uncited-snapshot detector matches on the
LITERAL registered basename, so an abbreviation false-flags a genuinely-cited source as `uncited-snapshot …
dead weight?` and can send a reviewer to prune a load-bearing source by mistake.

**Cross-TARGET evidence (a block citing a sibling corpus).** When the evidence a block relies on lives in a
DIFFERENT registered target (e.g. a `docGraphics` class from `niagara-help` cited by a `niagara-research`
block), the golden rule still holds: COPY the evidence into the CITING target's `sources/` and register it in
THAT target's `SOURCES.md`, noting the ORIGIN target. Do NOT cite across target boundaries by reference only —
"URLs die; evidence does not" applies to sibling corpora exactly as it does to the web (a re-decompile, a
re-org, or a moved target can vanish the referenced tree). The within-target preservation above and the
multi-FOCUS-within-one-target case (§16) both keep evidence inside one target; this is the cross-TARGET case.

**SOURCES.md row granularity — one row per file OR per directory, never a compound.** When many files from one
directory back a block, register ONE row per DIRECTORY (the path cell = the dir), not a compound filename like
`A.java + B.java` crammed into a single File cell. A compound basename breaks `verify-sources.sh`'s LEVEL-4
basename cross-check (it resolves ONE basename per row). Pick a granularity — one row per file, or one row per
directory — and never put a multi-file compound in the File column.

**Beautified-temp citation (minified / obfuscated code).** For minified or obfuscated sources (bundled JS,
etc.), beautify the artifact to a SCRATCHPAD temp — never into `sources/` (keep the READ-ONLY-over-subject
discipline: the temp is a working view, not preserved evidence). Cite `file:line` of the beautified copy as
if it were the primary source — it is 1:1 with the original, so the line numbers are trustworthy across
blocks. Anchor artifact IDENTITY with a LIVE `sha256` + byte-count of the ORIGINAL minified file (not the
ephemeral temp, which is not preserved); record that hash the way any ground-truth id is recorded. This
makes a `file:line` pointing at a non-committed beautified temp fully trustworthy and reproducible.

**Obfuscated bytecode (APK/DEX, .NET, etc. — the beautified-temp rule does NOT transfer).** The rule above
works because JS minification is a COSMETIC transform: whitespace and local names change, but structure and
string LITERALS survive 1:1, so a beautified line is trustworthy. DEX/APK obfuscation (ProGuard / R8 /
DexGuard) is SEMANTIC, not cosmetic — it renames classes/methods/fields to `a`/`b`/`c` (NOT reversible),
ENCRYPTS string constants (plaintext only at runtime), and hides flow behind reflection. So:
- **Never cite a renamed symbol as identity.** `a.b(c)` is not a name, it is a position. Anchor a claim to
  a STABLE structural fingerprint — the method descriptor/signature (types + arity), its call-graph
  position, or a matched library signature — not the meaningless letter. If a deobfuscation MAPPING is
  recovered (a retained `mapping.txt`, a library-signature match, an operator-built rename map), PRESERVE it
  under `sources/` and register it: it is itself evidence, and later blocks cite the mapping, never a
  guessed name.
- **A string decoded at RUNTIME is `[INFER]`, not `[CERT]` — regardless of artifact type.** When strings are
  encrypted or otherwise assembled at runtime, a static grep proving one absent proves NOTHING (it is
  decoded at runtime). A claim about a string constant's VALUE stays `[INFER]` until the DECODED value is
  observed LIVE — dynamic instrumentation (emulator / Frida hook), which then earns `[CERT-hw]`/`[CERT-live]`
  and is preserved as probe output. This is NOT specific to DEX/.NET obfuscation: ANY decompiled artifact
  with runtime-decoded strings has the same ceiling — a `z[]`/XOR-decoded string table inside a
  Vineflower-decompiled JAR is exactly the DEX/.NET hazard, and a grep over the decompiled `.java` for the
  plaintext proves nothing. The runtime-decode is what caps certainty, not the artifact format. Static
  analysis of such an artifact has a HARD ceiling; name it, don't paper over it.
- **Identity anchor.** As with minified JS, anchor by `sha256` + byte-count of the ORIGINAL `.apk`/`.dex`
  (record the obfuscator + version if detectable), so decompiler output — which is NOT 1:1 and varies by
  tool — stays reproducible against a fixed input.

**Decompiler-string-scrubbed Java (Vineflower / Procyon — distinct from runtime-decode above).** When a Vineflower or Procyon decompiled `.java` tree renders string literals as a scrubber token (`n` / `ln`) everywhere a real string should appear in method bodies, the strings ARE present in the `.class` constant pool — the decompiler failed to render them, not the runtime. This is distinct from the runtime-decode hazard above (ProGuard/R8 — strings ENCRYPTED, plaintext only live): here the plaintext is statically reachable via bytecode; only the decompiler's rendering is untrustworthy.
- **Detect by inspecting the `.class` constant pool directly.** Spot `n` / `ln` tokens in place of string literals across method bodies. Confirm via `javap -c <ClassName>` (real `ldc` constants appear) or `rg -a <expected-literal> <ClassName.class>` (plaintext in the binary).
- **All string-dependent claims: cite bytecode or clean resources — NEVER the decompiled `.java`.** Derive every string-value claim from `javap -c -p <ClassName>` output or from preserved clean resources (`module.xml`, `.lexicon`, `extracted/` tree). A cite or grep over the decompiled `.java` for a method-body string is inadmissible when the decompiler has scrubbed it.
- **Decompiled `.java` remains valid for structure only.** Class hierarchy, method signatures, control-flow shape, and import lists survive scrubbing intact — cite those freely. Any claim depending on a string literal in a method body stays `[INFER]` until confirmed via bytecode or a clean resource.
  - **But the class-NAME token itself can be partially mangled.** A decompiler (Vineflower / Procyon) can garble the class-name TOKEN in the emitted source (`public abstract class ln extends BWbFieldEditor`) while the FILE NAME and PARENT TYPE stay real. This is structurally distinct from string-literal scrubbing (which hits method-body strings, not the type name) AND from full obfuscation (which ALSO renames the file). When the class-name token is mangled, cite the class by FILE PATH + PARENT TYPE + existence, NEVER the garbled token; body-level behavioural claims stay `[INFER]`. (Evidence: niagara workbench focus, 6/12 blocks — B427/B429/B435-438.)
- **Establish a FOUNDATION-BLOCK caveat; forward-cite it in every subsequent block header.** Scrubbing is a corpus-level hazard. Document it in the FOUNDATION evidence block (the first block that discovers it) and cite that caveat in all later block headers. This kept the discipline consistent across 6 evidence blocks (B350–B355 in the `electronicSignature` focus) and prevented ~40 potential `[CERT]` false-citations.

**docSource dual-tree (one class living in TWO physical trees).** When a target ships BOTH a decompiled tree
AND an SDK "doc source" tree for the SAME class (e.g. a `docSource/` shipped-source tree vs the
Vineflower/Procyon decompiled output), they are two PHYSICAL trees with INDEPENDENT line numbering competing
for one class name. A `file:line` citation MUST name WHICH tree — a line number valid in one is meaningless
in the other, so the two are not interchangeable. Anchor the citation to the concrete tree path (`docSource/…`
vs the decompile-output dir), never to the bare class name. This is the same identity hazard as the
beautified-temp and obfuscated-bytecode cases above: one logical class, more than one physical artifact.

**Decompiler dump offset provenance (twin-binary check — static analog of RE-MEASURE GROUND-TRUTH).** When
a preserved decompiler dump carries function offsets (an RVA, or an absolute VMA = image base + RVA),
verify those offsets against the SPECIFIC sha256-anchored shipped binary with a live disassembler BEFORE
citing any offset. Two related "twin"
binaries compiled from identical C source sit at DIFFERENT addresses — a dump produced from binary A cannot
be cited for binary B even when the source is identical. Publishing a wrong offset is a false `[CERT]` and
a reproducibility failure: a reviewer following an `audits/B…:offset` citation lands at the wrong
instruction. This is the static pre-authoring counterpart to §12's RE-MEASURE GROUND-TRUTH rule (which
covers live/dynamic re-measurement); neither subsumes the other.

Concrete gate (operator/agent, not automated by any kit script):
- (a) Record the `sha256` of the binary that produced the dump at decompilation time.
- (b) Seek to the cited offset in the SAME address space Ghidra reported — if the dump lists an RVA,
  add the image base first, or r2 lands at the wrong instruction — and confirm the disassembly there
  MATCHES the dump's instructions for that function, not merely that the address resolves (an address
  mid-function still resolves and prints valid-looking bytes): `r2 -q -c "s <vma>;pd 4" <binary>` or
  equivalent Ghidra navigation.
- (c) If the anchored binary differs from the dump's source, re-decompile against the correct binary
  before citing — `corroborate-native.sh` regenerates sha256-anchored offsets from the correct binary.

Evidence: niagara B424 — Ghidra offsets `getHostVendor@0x5090` / `getVolume@0x5fa0` did NOT match the
shipped `njre.dll` (sha256 `7007ff82…`); they belonged to the twin `nre.dll`. Resolved by re-verifying live
in r2, then re-decompiling against the correct binary.

**Source-repo version-tag pinning (source analog of the twin-binary check).** The check above guards
native-binary drift; this guards the same citation-drift hazard for a versioned open-source repo, where
a `file:line` anchored to the wrong version is a false `[CERT]`. Whenever a gap draws on a versioned repo:
- **Tag-pinning obligation.** A delegation prompt for a source-repo sweep MUST supply the EXACT published
  version tag of the subject binary. `main` or the default branch is FORBIDDEN — its lines drift from
  every past release.
- **Re-verify discipline.** The driver re-verifies every load-bearing `file:line` against source at that
  exact tag before sealing a block; a sweep line is never citable on the sub-agent's word alone.
- **Hypothesis rule.** An unanchored sweep line (worked from `main`) or one carrying an approximate or
  acknowledged range is a HYPOTHESIS, not citable evidence — hold it at `[INFER]` until re-verified at
  the pinned tag.
- **Citation grade.** Fetched `.go` (or equivalent) source from a pinned repo is `[CERT]` per §3 — local
  primary source, code — NOT `[CERT-doc]` (which §3 reserves for an official downloaded document). This
  APPLIES the existing §3 canon; it defines no new marker.
- **Preservation destination.** Preserve the pinned source under `sources/go-src/<tag>/` (a LOCKED, shared
  convention — do not rename it) with the full `sha256` of each fetched file (of the tag-verified tree) and a `SOURCES.md` row. HOW
  the tree is obtained is out of scope here; this rule mandates only the destination and the verification
  discipline, never a fetch recipe.

Evidence (triple-sourced): ops-B2 — a delegated sweep returned `2024.11.0` lines for a `2026.8.2` binary;
ops-B4 — approximate lines even after the tag was stated; warp D-WARP-1 — 21 `.go` files fetched
on-demand with no kit recipe, the driver improvising the `sources/go-src/<tag>/` layout from scratch.

**Bundle-evidence quality (is API X actually USED?).** Distinct from the beautified-temp rule above (which
is about citing a beautified copy faithfully). When grepping a MINIFIED / FULL-LIBRARY JS bundle to prove a
page actually USES an API, a **constructor-call / invocation token** (`new THREE.PathTracer(...)`) is
admissible signal; a **bare class-name string hit** inside a full-library bundle is WEAK and inadmissible —
the whole library ships in the bundle regardless of what the page calls, so the name's mere presence proves
nothing. Prefer call-site evidence; discard bare-name hits. Apply this uniformly across sibling sweeps of
the same type (do not invent it mid-run for one block and forget it on the next).
The INVERSE bites just as hard: **a NEGATIVE grep for a bare library name over a webpack-bundled artifact does
NOT prove ABSENCE.** A webpack bundle references its imports by NUMERIC MODULE IDs (`require(cb29)`), not by
string name, so a third-party library can be fully PRESENT while the literal `"d3"` never appears as a string
at all — the only literal hits may be unrelated collisions (a `d3` query-param). Prove absence only with an
IDIOM / API / tag-level search (a call signature, a characteristic method name, a DOM tag the library emits),
never a bare-name grep. This also NUANCES the beautified-temp "string LITERALS survive 1:1" claim above: 1:1
preservation holds for the code's OWN literals, NOT for a third-party library reached only through the internal
`require(<numeric-id>)` map, whose name is never a string in the bundle. (A block's `d3`=0 grep-negative was
later refuted: d3 WAS present, aliased under webpack module ids `cb29`/`898b`.)

**Docs retrieved via an MCP server (context7 et al.).** Library/framework docs fetched through an MCP tool
(e.g. context7) are a DISTINCT source type: cite them `[CERT-web]` with the resolved library id + the
version queried and the access date. Convenience of re-querying does NOT exempt them from preservation —
an MCP response is as volatile as a URL (the library version moves; the MCP server may be absent in a
headless/cron run). A LOAD-BEARING `[CERT-web]`-via-MCP claim MUST be snapshotted to `sources/web-snapshots/`
(the cited fragment + the query and version), registered in SOURCES.md like any other source; only throwaway
orientation lookups may stay uncited. Do not improvise a per-target policy — this is the kit's rule.

**Web-fetch fallback ladder (bot-blocked / anti-scraping pages).** When `fetch-doc.sh` (curl/wget) hits a
bot-block or an anti-scraping shell, try a known fallback before giving up: (a) **Reddit** —
`www.reddit.com` returns only an SVG shell; `old.reddit.com` serves the same thread. (b) **CodePen** —
`/full/<slug>` 403s; `/pen/<slug>` with a browser `User-Agent` succeeds AND yields the pen's full UNMINIFIED
source via its init-data JSON (better evidence than a minified bundle). (c) **Discourse** forums (e.g.
discourse.threejs.org) serve crawler-readable HTML directly, no bot-block, plus a lighter `/raw/<topic-id>`
endpoint. Record the working fallback in SOURCES.md so the next fetch skips the dead path.

**Auth-gated portal (a 403 that is not bot-blocking).** The three fallbacks above bypass anti-scraping; they do not help when the 403 is a real login wall. A human informant with authorized access may supply verbatim page content: preserve it under `sources/web-snapshots/`, annotate the SOURCES.md row as `"tech-provided verbatim"` with the access barrier noted, and cite it `[CERT-web]` (the source is still the official manufacturer page regardless of how the content was obtained). Never cite content obtained by bypassing the auth gate itself — that crosses authorization, not anti-scraping.

**Falsified artifacts are preserved and labelled, never silently deleted.** An output that a later check
proved unsound stays under `sources/probes/` with an explicit non-evidence marker in its filename and in
the directory README (`NOT EVIDENCE — refuted by §N.x`). This keeps the near-miss auditable without leaving
a citable-looking file for a future reader to trust.

**CHM help files (`.chm`) produce a LOCAL source tree** — extracted with `7z x <file>.chm -o<dir>/` on
Linux/WSL, or `hh.exe -decompile <dir>/ <file>.chm` on Windows. The extracted topic files under
`sources/extracted/<basename>/Topics/` are `[CERT-doc]` assets, cited as
`sources/extracted/<basename>/Topics/topicname.htm §section`. The tool-registry entry
(`toolbelt/tool-registry.md`) covers the wrapper command and platform variants.

## 6. Research tools

**BOOTSTRAP step a2 — file-type census (mandatory, before the coverage matrix).**
Run `$KIT/toolbelt/census-target.sh <target-path>` at the start of every target. This produces a
file-extension histogram with aggregate sizes, and is **required before building the gap backlog**:

```
$KIT/toolbelt/census-target.sh $TARGET
```

WHY this step is mandatory: a coverage matrix built from what you already noticed cannot surface
what you never looked at. The failure is structural, not attentional — if you populate the backlog
from files that already drew your attention, the invisible corpus (Access databases nobody opened,
Visio diagrams nobody printed, compiled DDC programs nobody counted) never enters any gap. One
three-second command surfaces all of it. A retro evidence: an `integration` focus closed 14 of 14
gaps and declared coverage complete without ever running a census. It never opened 681 Access
databases (450 MB), 161 Visio diagrams (76 MB), or 144 compiled DDC programs — file types that a
three-second census would have put on the radar.

**Threshold for audit obligation.** A file type is starred (*) when it meets either threshold:
`--threshold-count N` (default 5 files) OR `--threshold-mb M` (default 1 MB aggregate). Every
starred type must be either (a) claimed by a pending or covered gap in the backlog, or (b)
explicitly dismissed in `RESEARCH-STATE.md §§ Dismissed file types` with a stated reason:

```
## Dismissed file types
- .<ext> — <N> files · <M> MB — dismissed: <reason>
```

A starred type in neither is an unclosed audit hole, and the run may not declare coverage
complete. "Dismissed" must explain WHY the type is out of scope — not just "not relevant".

**Relationship to `profile-target.sh`.** `profile-target.sh` profiles binary artifact types to
pick the right decompiler. `census-target.sh` is a broader, different tool: it counts ALL file
types (including docs, databases, diagrams, and config files that `profile-target.sh` ignores)
and applies the audit-obligation threshold. Run both; they answer different questions.

The loop then profiles the artifact type (`profile-target.sh`) and picks the toolbelt wrapper:
Java decompilation (Vineflower/CFR/Procyon), .NET (ilspycmd), native (Ghidra headless / r2 /
ghidra-mcp), firmware (binwalk+yara), docs/web (fetch-doc). Detail and paths in
[`toolbelt/tool-registry.md`](toolbelt/tool-registry.md). Research is **always
READ-ONLY**: the system under study is never modified.

**Protocol / binary-format reconstruction.** When the subject is an opaque wire format or a proprietary
binary record layout — no symbol-bearing managed binary exists, only data — use this named three-step pattern:

1. **Managed-member-first, anchors-first.** Inventory the whole artifact stack by type (§10 profile step)
   BEFORE decompiling anything. Attack the highest-level managed component first — symbols survive where
   the language preserves them (.NET assemblies, JARs). In parallel, harvest documentary anchors
   (datasheets, config files containing known field→meaning pairs) BEFORE decompiling; these become the
   cross-validation oracle. When the decompiled map reproduces all anchors, the map is trustworthy.

2. **Known-plaintext attack on the binary.** Take identifiers already known to exist in the data
   (room numbers, device IDs), encode them at several widths and endiannesses, and search the binary for
   all hits. The GCD of the distances between consecutive hits of the same identifier gives the record
   STRIDE. Walk ±stride from one confirmed hit to find section boundaries and detect paging. Validate a
   candidate epoch against an EXTERNAL fact (a filename, a log timestamp) — a wrong epoch gives a date
   that is decades off; the right one matches to the minute. Trap: a naive global stride sweep over a
   misaligned offset manufactures convincing phantom values (constant fields from a neighbouring offset
   appear as frequent "values"); confirm the stride is globally consistent before trusting any frequency
   count.

3. **Falsify formulas against a large corpus using PHYSICAL IMPOSSIBILITY.** Decode the entire available
   corpus with the candidate formula and count values that are physically impossible (humidity > 100 %,
   temperature below absolute zero, a bit-flag combination that cannot coexist). A formula that produces
   ZERO impossible values across hundreds of thousands of records in hundreds of independent units is
   confirmed by mass falsification. A formula that can produce an impossible value is refuted. This is a
   stronger test than eyeballing plausible numbers and is nearly free when the corpus is already on disk.

**Circular buffers — derive ranges with min/max, never first/last row.** In a circular buffer the write
head wraps: row 0 is wherever the head happens to be, not the oldest sample. Derive time spans with
`min()` / `max()` over the timestamp column, never by subtracting the first row from the last. A measured
span that disagrees with the theoretical capacity (e.g. `record_count × sample_interval`) is a red flag
about the READ model, not about the data — investigate the reading before dismissing the buffer.

**Inference-from-sparse-evidence: a technique family.** Before hunting a new source, ask whether the data
you already have can complete or score itself. Four facets of the same move:

- **Sample-and-propagate by CLASS.** When a sparse field's semantics belong to a TYPE (controller model,
  firmware version, schema class) rather than to an individual instance, a handful of samples per type
  covers the whole population. Verify by cross-sample AGREEMENT WITHIN THE TYPE first — the agreement
  rate IS the honest per-type confidence, and a low rate flags genuine type-level variation that propagation
  cannot resolve.

- **Internal-oracle scoring for heuristic or geometric inference.** When a claim rests on inference
  (geometry, statistics, spatial heuristics), look for a redundant fact already present in the data that
  the inference DID NOT USE, and score the inference against it. Report the agreement rate as the claim's
  confidence. An inference with no scoring oracle stays `[INFER]`; one scored against an internal oracle
  earns its measured rate. When a tool has a tunable threshold, sweep it against the oracle and commit the
  sweep table as a comment next to the constant — the number alone is unfalsifiable; the table shows why
  it is not set higher or lower. (P13 note: choose thresholds by sweep over the oracle, never by feel.)

- **Learn-then-propagate by KEY.** For a partially-populated field whose values correlate with a structural
  key (instance range, model code, path prefix, naming convention), learn the mapping from the LABELLED
  subset (records that already carry the value) and propagate it to the UNLABELLED subset. The per-key
  agreement rate from the labelled set is the honest per-key confidence — 100 % for a tight, consistent
  range; 50 % for a sparse one; the output says which per row. Sibling of sample-and-propagate-by-CLASS:
  CLASS propagates along a TYPE, this technique propagates along a KEY; both verify by internal agreement
  rather than assertion.

- **Normalise categories before measuring agreement.** When counting agreement over free-text categories,
  normalise first (case, synonyms, typos, hierarchy) and report BOTH the raw and the normalised rates. A
  46 % raw agreement rate that rises to 92 % after folding synonyms is not a weak signal — it is a dirty
  vocabulary. Accepting the raw rate at face value discards a technique that resolves the problem and sends
  the investigation toward a new source that will not help.

- **Split discrepancies by class before reporting an aggregate rate.** When a measurement produces a
  population of discrepancies, classify them by operational type (cosmetic vs. semantic, abbreviation
  vs. repurposing, layout vs. scheduling) before aggregating. An undifferentiated error rate over mixed
  classes is not a finding. This is a third distinct discipline: "Normalise categories" removes
  vocabulary noise within one class; "Sample-and-propagate by CLASS" propagates values across types;
  this rule splits the OUTPUT population before any aggregate is computed.

**Entropy + byte histogram as a read-only encryption test.** When the question is "is this wire/blob
encrypted?", compute Shannon entropy (bits/byte) and the byte-value histogram before assuming a cipher.
~7.99–8.0 bits/byte with a near-flat histogram ⇒ ciphertext or maximally-compressed data; a lower entropy
with a skewed histogram dominated by a handful of values (`0x00`, `0x80`, `0xc0`, `0xff`, etc.) ⇒ plaintext
framing with ordinarily-compressed payload. Both measures are read-only and cheap:
`python3 -c "import math,collections,sys; d=open(sys.argv[1],'rb').read(); c=collections.Counter(d); print(f'{-sum(v/len(d)*math.log2(v/len(d)) for v in c.values()):.4f} bits/byte')" blob.bin`.
Windowed entropy (sliding over 256-byte blocks) localises encrypted vs. plaintext regions in a mixed blob.
This is a first-pass check, not cipher identification: a strong compressor is indistinguishable from
ciphertext at this level. `[CERT-hw]` evidence from the USB-protocol run: 5.8124 / 5.5961 bits/byte,
histogram dominated by `0x00/0x80/0xc0/0xff` → verdict "not encrypted" (commit `bd91df0`).
Placement note: `toolbelt/tool-registry.md` already routes firmware entropy through binwalk; this method
is the complementary standalone check for wire captures and opaque blobs where binwalk is not the first tool.

**Calibrated discriminators are symmetric and reusable.** A classifier calibrated on a confirmed-positive layer is a symmetric discriminator for any layer of the same geometric kind (e.g. line segments or polylines claimed to belong to a structural category). Run it against the candidate and compare the score to the baseline from the confirmed layer: high score → confirmed as that kind; near-zero → not. The two scores together are the evidence, and the discriminator needs no rewrite or recalibration per candidate — same tool, same threshold, opposite answer on opposite input, the contrast itself the finding. (Evidence: nave-panccadia B36 §36.2–§36.4 — a pairing/thickness test calibrated on a confirmed wall layer scored 91.7 % there vs. 0 % interior pairing on the candidate, classifying it non-wall with no new test.)

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

**Memory is a MIRROR, not the record. `undocumented_findings` contract.**
A finding that exists only in memory is undocumented — the corpus cannot cite it, reviewers
cannot audit it, and a future agent reading the blocks will not see it. This failure is
recurrent: evidence from a `pi5-decoding` retro showed that after a prior delta acknowledged
the problem AND a block was written to fix it, four more findings (a 649-series trend
catalogue, a cold-chain identification, a semantic-coverage-by-model finding, and a max_samples
risk) went into commits and engram with no block.

The `undocumented_findings` counter in `research-state.v1` tracks this debt:

| Event | Action |
|---|---|
| `mem_save` a project/decision finding **without a block** | increment `undocumented_findings` by 1 |
| Write the block; **edit `undocumented_findings` down by 1 in the state file** | call `--sync-state` to carry the new value forward (it cannot derive it from disk) |
| Block written, field updated, counter at 0 | archive gate will pass |

**This counter is manually maintained.** Nothing in the kit observes memory saves — there is no
hook, no watcher, no automatic increment. The researcher is responsible for the count. The machine
enforces the gate; the researcher maintains the number.

**Gate behaviour (machine-checked):**
- `verify-state.sh` WARNs when `undocumented_findings > 3`
- `verify-state.sh` FAILs (blocks `--next`) when `undocumented_findings > 6`
- `research-sdd-archive.sh` refuses to close when `undocumented_findings > 0`

**Seeding.** The field starts at `undocumented_findings: 0` in a new RESEARCH-STATE.md.
`--sync-state` carries the value forward (it cannot derive it from disk); if the field is
absent in a legacy envelope, `--sync-state` seeds it to 0. The RESEARCH-STATE.template.md
includes `undocumented_findings: 0` in the envelope for new targets.

**`block_scope` — corpus block-counting mode (optional envelope field).**
By default (`block_scope` absent, or `block_scope: per-focus`), `verify-state.sh` CHECK A counts
only the block files whose names carry the focus-specific prefix derived from the state filename
(§16 prescribed layout: `RESEARCH-STATE-<focus>.md` ↔ `<focus>-block<N>.md`). This is correct
for multi-focus corpora where each focus has its own prefix.

Some corpora deliberately do NOT follow §16's per-focus layout: all focuses share one corpus-wide
block prefix (e.g. `niagara-mental-model-bloque`). Declaring `block_scope: shared-global` tells
`verify-state` that the on-disk file count is corpus-wide and therefore says nothing about THIS focus.
Without this declaration, CHECK A reports a false mismatch (focus-filtered count = 0 while
the corpus has many blocks) and gives a misleading "= 0" message. Declaring it is how a shared-prefix
corpus stays verifiable rather than silently failing.

**Under `shared-global`, `covered_blocks` is the number of blocks ATTRIBUTED to the focus — never the
corpus-wide total.** The corpus total is a moving target that no stopped focus can keep up with: measured on
the niagara index, 40 of 61 focus envelopes carried a frozen corpus-wide snapshot (`266`, `607`, `747` …)
from the day they were synced and could never equal the live count again, so every focus reported FAIL and
`--sync-state` would have overwritten a focus that owns 19 blocks with `758`. The attributed count is stable:
a stopped focus's set does not change when a sibling focus writes. CHECK A derives the attributed set from
the focus's OWN state file, in this order: a `## Covered blocks` list when present; otherwise the distinct
`B<n>` ids in the focus's `## Iteration history` Block column. When neither yields an id, CHECK A reports
`covered_blocks unverifiable under shared-global (no attributed block ids listed)` as INFO — an honest
cannot-see, never a FAIL against the corpus total (§7 three-state rule). The corpus-wide count is still
printed, as INFO (`corpus total N, shared-global`). `--sync-state` writes the attributed count. A focus whose
envelope disagrees with its own listed ids is a TRUE finding and stays a FAIL.
**Instrument status (readback against the live code, kit issue #423):** until #423 lands, `verify-state.sh`
still compares `covered_blocks` against the corpus-wide file count under `shared-global` (its CHECK A has no
attribution step yet). On a shared-global corpus treat that FAIL as noise and do NOT run `--sync-state` on a
focus file — it would write the corpus total. #423 removes this paragraph when the instrument matches.

| Value | Meaning | CHECK A comparison |
|---|---|---|
| absent | same as `per-focus` (backward-compatible default) | focus-prefix filtered count |
| `per-focus` | §16 layout — each focus has its own prefix | focus-prefix filtered count |
| `shared-global` | all focuses share one corpus-wide prefix | blocks attributed to the focus (own state); corpus total as INFO |

**Gate behaviour:** present but empty, or any value other than `per-focus` / `shared-global`, is a
hard FAIL — `verify-state` cannot proceed without knowing the counting mode. Absent is always legal.

**Cannot-see diagnostic.** Even when `block_scope` is absent/per-focus, if the focus-filtered count
is 0 while other-prefix blocks exist, `verify-state` emits a distinguishing FAIL message that names
`block_scope: shared-global` as the declaration to add — rather than a bare "≠ 0 block file(s)"
that hides which condition was actually hit.

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
   gaps remain.

**Static+live gap-split rule.** When a single gap has BOTH a static-readable component AND a live/execution
component, SPLIT it into TWO backlog entries at seeding time: one for the static half (read-only-investigable
— close it in the current loop) and one for the live half (requires-execution → §19). Do NOT leave the whole
gap as `requires-execution` or `blocked-on-live` because one half needs execution: an unsplit gap loses its
static work permanently when the loop exits.

**`tried:` clause for blocked and absence-closed entries.** A blocked or absence-closed gap entry must
carry a `tried:` field — the alternatives enumerated and the measurement that ruled each one out.
`verify-state.sh` checks for its presence the same way it checks the `needs:` clause. A `blocked` entry
with no `tried:` is an unfinished gap: it bounds one path, not the question. (The backlog rarely empties — each block uncovers 1-4 new gaps; exhaustion of the
   *read-only* subset is the real terminator.)

**`blocked-by-design` vs `blocked-on-live-arrival`.** Two sub-types of `blocked` carry different resolutions:
- **`blocked-by-design`**: the target has NO remote/live surface by design — an air-gapped kiosk, a device
  with an internal all-block firewall, LOCAL-ONLY management. "Hardware arrival" (§12) can NEVER reclassify
  these; the block is terminal for that channel. Record as static-only and do not re-attempt remotely.
- **`blocked-on-live-arrival`**: a live surface EXISTS but is not reachable YET — pending hardware delivery,
  network access, or credentials. These ARE candidates for §12 reclassification when access appears. The
  discriminator is whether access can EVER arrive, not whether a surface exists: a surface with no credible
  path to future access (permanent credential-lock, revoked NDA) is `blocked-by-design`-terminal despite
  existing.
Distinguish the two in the `tried:` clause: the evidence already describes WHY each alternative was ruled
out; naming the sub-type tells a future reader whether to await hardware or treat the gap as permanently
static-only.

2. **Backlog empty 2× (secondary).** No open gaps at all for two consecutive iterations.
3. **Budget cap (safety net).** An optional max-blocks / max-token ceiling set at launch.

**Saturation is a soft REVIEW prompt, not a fourth STOP criterion.** The backlog rarely empties (each
block uncovers 1-4 new gaps), so a subject can be substantively SATURATED long before the criteria above
fire. `research-sdd-status.sh` surfaces this from the `## Iteration history` "New gaps uncovered" column:
when the LAST 3 numeric iterations net EXACTLY 0 new gaps it reports `saturation : SATURATED (review)` in
the default status report. This is INFORMATIONAL only — it does NOT auto-STOP, change exit codes, or alter
`--next`; it complements the §8 STOP decision by flagging a diminishing-returns subject for human/agent review.

**The saturation prompt reads the `New gaps uncovered` cell by header name, and the cell needs a leading count.**
Write `3 new — G7, G8, G9` or `none`, never a bare identifier list (`B754-G1/G2`, `IC1–IC4 seeded`): measured on
the fleet, 35 of 50 iteration-history tables were unreadable to the saturation parser, and the dominant residue was
identifier lists, which an instrument must REPORT as unreadable, not count by guessing (kit issue #420 — until it
lands `research-sdd-status.sh` reads the LAST column as the count and prints "insufficient history" on tables it
cannot read; treat that line as "unreadable", not as "short history").

**A gap closes on a negative finding too.** A rigorously proven ABSENCE closes a gap exactly like a
positive one: if the investigation shows a thing is NOT there — cited as such — the gap is covered, not
open. (Proven on protocols B136: the Sox gap was closed by demonstrating Sox's absence across 973 jars,
cited.) A negative closure needs the same evidence bar as a positive one: cite what you searched and how
(paths, counts, the grep/scan that came back empty), not a bare "not found". State the sample size and
the test applied. And when a source fails the question you asked, record what question it DOES answer
before closing it — a source containing no location data may still document control logic or engineering
schematics (a separate open gap).

**A negative found only in the vendor's OVERLAY is not proven absence.** When the target embeds a
third-party runtime, SDK, or framework, a capability absent from the vendor's own classes may be
inherited from the base platform. Before recording proven-absence, search the BASE platform too and state
both scopes in the citation ("absent in `<vendor pkg>` AND in `<base platform pkg>`"). A negative whose
search covered only the overlay is INCONCLUSIVE, not proven-absence. Cheap tell: does the target's class
`extend` a base-platform type? Then the base platform is in scope.

**A sub-agent's proven-absence inherits the sub-agent's search scope** — which is narrower than the full
corpus. Before promoting a delegated negative to a gap closure, verify that the cited scope covers the
relevant universe (all jars, all modules, the full platform); widen the search if it does not. A
module-scoped "not found" is evidence for that module, not for the corpus. (Primary rule lives in
PROMPT-LOOP §DELEGATE.)

**Identity negatives ≠ feature absence (external-URL sweeps).** Proven-absence closes a gap by showing a
feature is missing from a confirmed IN-SCOPE subject. A case-study/showcase sweep over user-supplied external
URLs produces DIFFERENT outcomes that are NOT that, and each must be labeled honestly rather than forced into
proven-absence: (a) a target CONFIRMED NOT the subject library (a genuine IDENTITY negative — cite it, e.g.
no `three` dependency, a different renderer stack); (b) INCONCLUSIVE-but-leaning-not (investigated honestly,
evidence insufficient either way — say so; do NOT upgrade it to a proven negative); (c) a URL serving
UNRELATED content (apparent slug reuse — a data-quality flag on the INPUT LIST itself, not a finding about
the subject). These close the gap row with an honest verdict about identity/input-quality, not about a
feature's presence.

On stopping, declare: blocks written, the **coverage metric** (gaps closed / known gaps — a ratio,
NOT a free-floating percentage), the list of **blocked gaps each tagged with the tool/access it
needs**, and the Tools Report (`toolbelt/INSTALLED-TOOLS.md`).

**Coverage over the SUBJECT is a second, different metric — declare it when the subject has structure.** `gaps closed /
known gaps` is a ratio over the gaps you KNOW; it cannot see the units of the subject no gap ever named. When the
subject has its own structural units (modules, packages, source directories, chapters), also declare the fraction of
those units cited by at least one block — the research analogue of code coverage. Measured on niagara-research: 318
top-level modules with Java, 170 cited by some block, 148 (47 %) never cited by any of 763 blocks, while every focus
reported its known-gap ratio honestly. Its consumer is §13 AUDIT-FIRST: uncited units are candidate gaps to SEED, not
findings. Ambiguity is reported, never absorbed (a class name present in two modules is excluded from the join and
counted). **Instrument status:** none until kit issue #421 lands `toolbelt/coverage-map.sh`; until then compute it by
hand or declare "coverage over the subject: not measured".

**PAUSED (budget-cap) ≠ STOPPED (exhaustion).** Distinguish the two in RESEARCH-STATE vocabulary. A halt on
the budget-cap safety-net (criterion 3) while read-only-investigable gaps are STILL open is a PAUSE, not a
genuine STOP — word it "PAUSED (budget cap; N gaps still investigable)", never "STOPPED", so a future reader
does not mistake a budget pause for real completion. The terminal-trigger machinery (the §8 focus-closing
synthesis, the §18 retro) MAY still fire on a pause — a run worth pausing is usually worth consolidating —
but the report must LABEL the halt as a pause and list the still-investigable gaps as the resume point.
Resuming a pause needs no new authorization (the gaps were already queued); that is lighter than "Reopening
a STOPPED loop" below, which reopens a genuinely-exhausted focus for a NEW question.

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
(Harness-neutral tier contract and per-harness mapping: `toolbelt/model-tiers.v1.md`.)

**Closed loop while working, open loop when done (terminal trigger).** The loop is a closed control system
while read-only-investigable > 0: it self-corrects and self-continues. When that set hits 0, it does NOT
just declare and die — it OPENS to the environment and fires the next action. At FOCUS-level exhaustion it
hands off to the next queued focus (re-entering with the next axis, bootstrapping if new) — optionally
writing a **focus-closing synthesis block** FIRST: a terminal block that consolidates the just-finished
focus, cross-referencing related blocks across other focuses (e.g. a security thread tying this focus to
findings in sibling focuses). A synthesis block is a valid terminal artifact at FOCUS level, not only at
corpus level — it is the right call whenever a focus produced a thread worth consolidating before moving on. At CORPUS-level
exhaustion (all focuses done) it emits a NEXT-ACTION — a cross-focus synthesis, or a handoff to a non-static
phase (requires-execution build/PoC §19, or the DYNAMIC/hardware phase §12) — launching it if autonomous and
safe, or handing off to the user when a human decision or hardware is required. Silent end only when there
is no queued focus and no safe next phase.

**A gap closes by remittance too.** Four closure categories now exist, not three: closed by NEW
investigation, closed by PROVEN ABSENCE (above), closed by REMITTANCE, and closed by RE-SCOPE.
A gap closes by remittance when a later sweep shows it is ALREADY fully answered by an EXISTING
cited block/section, with NO new substance
to add. This is not padding and not a dropped gap: cite the exact prior `[Block N] §N.x` that covers it and
state explicitly "closed by remittance — no new substance". It differs from proven-absence (which cites a
search that came back empty); remittance cites prior COVERAGE. Use it to avoid writing a redundant block
for a gap the corpus already answers — but the citation + explicit no-new-substance note is the evidence
bar; a gap "closed by remittance" with no prior-block citation is just a silently dropped gap.
Restrict remittance to a GENUINELY PRIOR block — one already committed BEFORE this iteration. The distinct
case where NEW content answering an adjacent gap lands in the SAME block/iteration you were writing is NOT
remittance (it is new substance, just serendipitous): close that gap as closed-by-NEW-investigation citing
the same-iteration `§N.x`, not as remittance. Reserve remittance for coverage that predates this iteration.

**A gap closes by RE-SCOPE too.** A gap closes by re-scope when it turns out to belong to a different
question. The re-scope record must state: (a) which focus the gap belongs to, (b) whether that focus
exists (opening it is recommended when it does not yet exist, but is not mandatory), (c) what
conclusion elsewhere remains unresolved because of it, so the transferred gap does not silently vanish
from the originating focus's ledger.

**Reopening a STOPPED loop for a bounded experiment.** STOP is not permanent. A focus that reached STOP can
be REOPENED — a new tool arrived, a hardware bench appeared, a targeted follow-up — WITHOUT a full
re-bootstrap: read the existing state, run just the added iteration(s), then re-declare STOP. What makes it
a reopen is that it is SCOPED and authorized, not that it is one gap: it may be a single question (logosoft
B76: one hardware question) OR a bounded MULTI-GAP expansion (three.js run 2: four new gaps G16-G19 plus two
rescoped). A reopen sets its OWN fresh budget cap (additive, e.g. "+7 blocks") — it does not inherit the
original run's. Keep it scoped — an experiment, not a re-run of the whole loop. NOTE — this paragraph is for
a genuinely-EXHAUSTED STOP reopened for NEW work; resuming a focus that merely PAUSED on the budget cap with
gaps still queued is lighter and needs no new authorization (see "PAUSED (budget-cap) ≠ STOPPED" above).
SCALING under repeated reopens (distinct from §16, which splits PARALLEL axes): a single continuous focus
reopened many times accretes one unbounded `RESEARCH-STATE.md` (three.js: 32 gap-backlog + 32 iteration-
history rows across 5 reopens in one file). Do NOT force §16's per-focus split on it — it is one axis, not
many; instead, once a focus crosses a threshold (a 3rd+ reopen, or >25 iteration-history rows), COLLAPSE
prior runs' rows into a one-line-per-run summary (blocks, gaps closed, coverage ratio, retro link) and keep
only the CURRENT run's rows verbose.

**A STOPPED focus may also be reopened to raise its evidence grade — a grade-upgrade reopen.** The paragraph above covers new tool / new question / hardware bench as the reopen motive; grade-upgrade reopen names a second, distinct category: the SAME questions are re-examined at higher fidelity (e.g. strings/RTTI evidence → decompiled function bodies) to produce stronger answers to questions already asked, not to pursue new ones. Its distinguishing risk is re-derivation (redundant churn that re-covers known ground) — not scope-creep — and that difference demands its own honesty discipline: **PRIOR-COVERAGE → REMIT → DEEPEN**. Start by auditing what the prior run established; REMIT those findings (cite, do not re-derive them); only then DEEPEN the grade with higher-fidelity evidence. A grade-upgrade that skips the REMIT step re-derives prior work and forfeits the legitimacy of the reopen. This category is legitimate and distinct from churn: the 2026-08-07 platform-native Ghidra sub-pass reopened a STOPPED native-decompilation focus to upgrade strings/RTTI evidence to decompiled function bodies, and surfaced 4 security facts that lower-fidelity evidence had not reached.

**Live backlog injection ≠ reopening a STOPPED loop.** When the user adds new questions WHILE a focus is
still ACTIVE (not stopped, not exhausted), the loop simply APPENDS them to the current backlog and widens its
scope (renumbering as needed) — no new bootstrap, no fresh authorization, no separate additive budget cap.
This is LIGHTER than the reopen above, which re-arms a genuinely-exhausted STOP for NEW work with its own
budget: here the loop never stopped, so the new gaps just extend the queue it is already draining (e.g. a
backlog widened mid-run with `+BG13 modernización` and `BG11 → chihuahua` at the user's request).

## 8b. Gap-backlog cell grammar (issue #147)

The `## Gap-backlog` table has two grammar-sensitive cells — **Priority** and **Status** — that
historically carried uncontrolled free text. Both parsers silently dropped non-conforming rows:
a `pending` row with a qualified Priority vanished from `investigable_open` without warning (same
defect family as issue #143). This section declares the grammar; parser changes are its consequence.

**Priority cell grammar.** Legal values (trimmed cell, ASCII, case-insensitive):

```
^(high|medium|low|deferred|—|~~(high|medium|low)~~)$
```

Routing-class table:

| Value | Class | Routing |
|---|---|---|
| `high`, `medium`, `low` | routable | counted in `investigable_open`; `NEXT` walks high → medium → low |
| `deferred` | parked | counted in `deferred_open`; never yields `NEXT` |
| `—`, `~~high~~`, `~~medium~~`, `~~low~~` | closed | not counted anywhere |

**`deferred` is normative.** It is a parked routing class with its own envelope field (`deferred_open`)
and two dedicated readers (`count_deferred()` in `research-sdd-status.sh`, `derive_deferred()` in
`verify-state.sh`). Use it for a gap explicitly set aside — not as a synonym for `low` or for an
unknown priority. A `deferred` row never yields `NEXT` and never enters `investigable_open`.

**Qualifiers are forbidden** in the Priority cell. Forms such as `high (cross-vibra)`,
`medium (pending-scout)`, and `low (deferred)` are non-conforming: the parser drops the entire row
before reading Status, so a `pending` row with a qualified priority silently vanishes from
`investigable_open`. The observed qualifiers encoded four unrelated concepts (routing class,
provenance/lineage, workflow debt, structural notes) with no single machine meaning — no safe
strip-and-route is possible. Two forms already map to conforming values: `low (deferred)` → `deferred`;
`(pending-scout)` belongs in Status decoration. Place nuance in the **Gap cell prose** or as
**Status decoration** (everything after the leading Status token is free text).

**Status cell contract.** Classification reads the **leading token** after stripping at most one
leading `**`. Live tokens (the row stays open):

| Token | Meaning |
|---|---|
| `pending` | the ONLY token that enters `investigable_open`; `NEXT` selection reads it |
| `requires-execution` | open but not read-only; counted in `requires_execution_open` (§19) |
| `blocked-on-<reason>` | open but blocked; `<reason>` matches `[a-z0-9/-]+` |

Closed markers: `✅` or `~~` prefix ONLY. The bare words `covered`, `closed`, `done` do **not** close
a row — they appear negated inside open asides and parsers cannot reliably distinguish the forms. Do
not use them as closure markers. Everything after the leading token is **free decoration** (→ block
ref, note, date).

**Deprecated aliases.** `open` and `queued` are non-conforming aliases of `pending`. Migrate to `pending`.

**Em-dash means closed and nothing else.** An open row must carry a real tier (`high`, `medium`, `low`,
or `deferred`). Blocked-ness belongs in Status, not in an empty or `—` Priority cell.

**Table shape.** The backlog heading grammar is closed: the exact base form `## Gap-backlog`
(ASCII U+002D hyphen-minus), optionally followed by a single parenthetical descriptor on the same
line — `## Gap-backlog (<descriptor>)`. Grammar: `^## Gap-backlog( \([^)]+\))?$`. Valid:
`## Gap-backlog`, `## Gap-backlog (prioritized)`, `## Gap-backlog (investigable)`. Non-conforming:
free text outside the parenthetical (`## Gap-backlog prioritized`, `## Gap-backlog extra (prioritized)`),
`## Gap backlog` (space), a U+2011 non-breaking hyphen form, and `## Backlog de gaps`; tooling
emits a provisional WARN naming the canonical forms. The table MUST be 4 columns:
`| Priority | Gap | <type/source> | Status |`, Priority first. A literal `|` inside a cell MUST be
written `&#124;` — the Markdown parser does not honour `\|`. One physical line per row.

**Migration (propose-never-apply).** Corpus edits are always the human's; tooling WARNs and never
auto-applies. Migration classes to address:

- **Qualifiers** → strip qualifier; move qualifier prose to Gap cell or Status decoration.
- Abbreviated or compound tiers (`med`, `MED`) → a real tier; `critical` → `high`.
- `open` / `queued` → `pending`.
- Open em-dash rows (Priority `—`, non-closed Status) → assign a real tier + appropriate Status.
- Heading variants → `## Gap-backlog`.
- Wrong column order or missing columns → 4-column canonical form.
- Bare `|` inside cells → `&#124;`.

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
9. **A name is not a kind.** Never assert a class's KIND (enum / interface / POJO / abstract) from its NAME
   pattern — a `*Handle` may be a POJO not an enum; a `BI*FE` may be a concrete class, not a `BInterface`.
   State any name-implied kind as a HYPOTHESIS and confirm it against the actual declaration line before
   writing it `[CERT]`.

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

**Installing a tool is not complete until it is CATALOGED.** `install-tool.sh` auto-appends every
install attempt to `toolbelt/INSTALLED-TOOLS.md` — that LOG half is automatic and needs no action from
you. It does NOT write `toolbelt/tool-registry.md`, the CAPABILITY CATALOG half: **that is your job**,
done proactively as part of the install, unprompted, the same way a decision or a bugfix gets saved to
memory without being asked. Cataloging a tool means adding, in `tool-registry.md`: its **path** (a row
in "## Tool paths (verified)"), **what it's for** (an Artifact type / Detection row), and **how to use
it** (the Wrapper column — or the `(direct)` pattern for a manual tool with no kit wrapper, as js-beautify
and the `.mdb`/CHM rows already do). `toolbelt/verify-tool-catalog.sh` is the anti-silent-zero backstop
that WARNs when a logged install never got cataloged — treat its WARN as a reminder you skipped, not as
the mechanism that does the cataloging for you (propose-never-apply: it never edits the registry itself).
The guard matches case-insensitively, so a logged lowercase name (`vineflower`) finds a Title-case catalog
entry (`Vineflower`) without extra work. When the logged name and the display name differ entirely (e.g.
`install-tool.sh` logs `kaitai-struct-compiler` but the catalog entry's display name is `ksc`), the
catalog row MUST carry the logged name as a searchable alias token — append `(alias: <logged-name>)` to
the Tool cell of the relevant row. The whole-word case-insensitive match then finds it. Do NOT invent a
new catalog section; one alias token per row is sufficient and keeps the registry human-readable.

**MCP-server capabilities count as tools too.** §10 was written for `install-tool.sh` binaries, but a
capability added via an MCP server — e.g. a `chrome-devtools` MCP to reach a JS-rendered chunk a no-JS crawl
cannot — is provisioning too, and it lives in GLOBAL session config (`~/.claude.json` `mcpServers`), not
versioned with any corpus. Log it in `toolbelt/INSTALLED-TOOLS.md` like any other tool (name, what it solved,
and that it is a global MCP server, not a target-local binary), so a future session has a trace instead of a
silently present-or-absent capability. A finding that depends on an MCP capability NAMES it, same as a CLI tool.

**Search before you decide.** The four cases below are worded as if you already know what exists —
ADAPT says an existing tool "almost fits", CREATE says "no existing tool fits". Neither is knowable
without looking, and a run that skips the search does not choose CREATE, it DEFAULTS to it. Before
recording a case, search three places and write down what you searched:

1. `$KIT/toolbelt/tool-registry.md` — the kit catalogue, indexed by artifact type and technique. Search
   by the ARTIFACT you are holding (`DXF`, `CHM`, `stripped ELF`) and by the JOB (`oracle`, `carve`,
   `entropy`), not by the name you were about to give your script.
2. `$TARGET/tools/README.md` — this corpus may already have it from an earlier run.
3. The rest of the fleet — `toolbelt/sweep-tools.sh` lists every target carrying a `tools/` directory;
   grep their ledgers for the same two axes.

Record the search in the same entry as the decision: the terms used and what came back. **A CREATE with
no recorded search is a claim, not a finding** — "nothing existed" and "I did not look" produce the same
empty result, and only the record tells them apart.

**Honest limit of this search today.** It is only as good as the ledgers, and most of the fleet has none:
the census currently reports 293 tools with 6 recorded. Until the write-at-acquisition rule below has run
for a while, a fleet-wide "not found" is WEAK evidence — it means "not found among the few that are
described", not "does not exist". Say so when you record it, and prefer searching by artifact type in
`tool-registry.md`, which IS complete for the kit's own tools. Comparing filenames is not searching:
two targets can build the same wheel under different names and neither will ever know.

**Four tool-decision cases** (beyond fresh install from a known recipe). When a run encounters a tool need,
one of four cases applies — record it in RESEARCH-STATE and surface it at retro time:

- **INSTALL** — the tool is new to this target; provision it via `install-tool.sh` (above). This is the
  existing case.
- **ADAPT / FORK** — an existing kit or target tool almost fits; the run modifies a copy for the local
  need. Record what was changed, why the existing tool could not express it, and what would be needed to
  merge the change upstream.
- **CREATE** — no existing tool fits; the run authors one from scratch in `tools/`. Name it, document its
  purpose and oracle (what it can SEE rather than recompute), and add it to the retro's TOOLS table for
  promote/absorb/keep-local/no verdict.
- **UPDATE-IN-USE** — a tool already in `tools/` is changed mid-run (parameter added, bug fixed, threshold
  tuned). Record the change at the iteration where it happens, not only at retro time. A kit tool with a
  parallel target copy that drifts is a maintenance debt; note whether the kit version needs the same
  update.
- **RETIRE / SUPERSEDE** — a tool stops being used, or is replaced by another. The ledger records births
  and, without this case, records no deaths — so it starts lying the moment anyone tidies up. Record what
  replaces it, why, and the commit sha holding its last version.

**Do not delete a tool — mark it superseded.** A script is kilobytes; the risk of deleting the better of
two similar tools is not worth that saving. Keep the file, mark the row `superseded by <name> (<sha>)`,
and let the reader see both. Delete only what is actively harmful (a leaked secret, a destructive
one-liner), and record the sha first.

The deletion cases worth naming, because each fails differently:

- **The wrong one was deleted.** Two tools looked alike, the weaker survived. Recoverable ONLY under git:
  `git log --diff-filter=D --name-only` finds the deletion, `git show <sha>^:<path>` reads it back,
  `git checkout <sha>^ -- <path>` restores it. Verified on a real deletion in this repo.
- **The target has no git.** Then none of the above exists and the loss is permanent. Three fleet targets
  are in that state today. Before deleting ANYTHING in a target, check its `git` flag in `TARGETS.md` —
  and prefer superseding, which needs no recovery at all.
- **git yes, remote no.** Three further targets. History survives a mistake but not a dead disk, and
  `ensure-remote.sh` exists precisely to close that. Recovery here is real but local-only; treat it as
  one failure away from the case above.
- **A shared tool was "improved" and broke the target using it differently.** UPDATE-IN-USE on a tool
  that more than one corpus relies on is not a local edit. Before changing a kit tool or a promoted one,
  name who else uses it (the same fleet-ledger grep as retirement) and state whether the change is
  backward-compatible. A silent behaviour change is a deletion with extra steps: the old behaviour is
  gone and nothing records that it ever existed.
- **ADAPT with no decision.** A forked kit tool that is never resolved into "merge upstream" or "stays
  local" becomes a third state that drifts from both. The ADAPT case already asks what merging would
  take; the answer must be RECORDED, and if it is "cannot merge", the reason is the thing worth keeping.
- **Another target depended on it.** Nobody tracks cross-target use. Before retiring, grep the fleet's
  ledgers (`toolbelt/sweep-tools.sh` lists every target carrying `tools/`) and name in the row which
  targets used it. An unrecorded dependant discovers the loss by failing.
- **Promoted upstream, copy left behind.** A tool promoted into the kit while its target copy stays live
  produces two truths that drift apart. Whichever survives must be named canonical in both ledgers, and
  the other row must point at it.
- **False duplication.** Same name, different behaviour — merging them silently drops a capability.
  Different names, same behaviour — the duplication is invisible. Neither is decidable from filenames;
  compare the recorded PURPOSE, which is why the search clause above and the write-at-acquisition rule
  below are what make retirement safe rather than a guess.

**Write-at-acquisition rule (`tools/README.md`).** Record each row the moment the tool is acquired,
created, or changed — never reconstructed at retro time. The rationale is cheapest while the decision is
live, and a backfill written weeks later loses exactly what the ledger exists to hold: nine backfill
retrospectives written in one day each reported the same limit — finished artifacts show what was DONE
and never what was ABANDONED. Applies to all four cases above. This ledger is also what makes the
do-not-reinvent rule enforceable: without a recorded purpose per tool, duplication can only be checked
by comparing FILENAMES, which proves nothing — two targets can build the same wheel under different
names and neither will ever know. The practice comes from a target that ran it before the kit did
(HotelHilton's `tools/README.md`).

**Oracle-first heuristic (check before you CREATE).** When the subject is a closed-source managed binary with its own IDE or SDK (Java, .NET), scan the vendor's shipped JAR or assembly tree for a `simulation/` or `emulation/` package DURING the §6 file census — before authoring any tool under the CREATE case. A vendor-bundled simulation engine is a privileged offline oracle: its outputs are validated against the vendor's own reference model rather than a reimplementation, making it independent by construction. Flag it in the TOOLS table as `ORACLE · vendor-bundled · IDENTIFY`; record where in the JAR it lives. If later used to validate a tool's output, it earns the second-highest trust position behind live hardware (`[CERT-hw]`).

The per-iteration reporting obligation (announcing the case in the iteration record) is a PROMPT-LOOP rule.

## 11. Self-verification contract (in-block gatekeeping)

Gatekeeping lives INSIDE the block-writing iteration, NOT in orchestrator Bash commands (those trigger
permission prompts and were dropped mid-run on EduVolt). Before closing a block, the sub-agent MUST do
and MUST REPORT these checks:

- **Token check** — every load-bearing `[CERT]` token was `grep`-confirmed present in its cited source
  (file / binary / `strings`). Report how many tokens were checked. (Track record this enforces: 12/12
  blocks across TRANE+EduVolt had zero hallucinated citations.) CAUTION — a single-line `grep` can
  FALSE-NEGATIVE on a token that is line-wrapped or built by string concatenation across lines, reporting
  "absent" for a token that is genuinely present. Before DOWNGRADING a `[CERT]` for an unresolved token, do a
  whitespace-normalized / multi-line re-check so a merely wrapped token is not wrongly demoted.
  **Citation-form convention.** Bare `file:line` is acceptable in a block body when one source dominates
  the evidence, but the SELF-VERIFY anchor for every load-bearing citation MUST carry the full
  `filename:line` form — the only form `verify-block.sh` can resolve; an unqualified line number
  classifies as `extern` and is invisible to the auditor (named pair: *bare `:line` body + full
  `filename:line` self-verify anchor*). For `[CERT-doc]` citations over an HTML or doc source, the
  anchor uses the **full HTML basename** from the `SOURCES.md` row (e.g. `JsonSchemaTypes-Json-70BA9870.html`)
  — never a doc-title shorthand — so `verify-sources.sh` can resolve it.
- **Marker tally** — counts of `[CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER]`, plus the **`[INFER]`/
  `[CERT]` ratio** AND the **block type**. For an **evidence block** (decompilation/reading) a high ratio
  (>~0.5) is the automatic signal that the investigable evidence for this gap is nearly exhausted — say so;
  it feeds the §8 stop decision. For a **design/applied block** (integration plan, PoC design, cross-focus
  synthesis) a high ratio is EXPECTED and healthy, NOT an exhaustion signal, and does NOT close the focus
  (e.g. protocols B137 at ~0.48 was a sound integration plan). Declare the type so the ratio is read right.
  Three non-standard types worth naming: a **MIXED** block (evidence + synthesis or verdict combined in
  one block; trigger: a section within the block draws `[INFER]` ACROSS prior blocks — not deductions
  from this block's own `[CERT]` sources — declare MIXED rather than evidence), an **ABSENCE-CENTRED**
  block (primary finding IS a proven absence, with remaining content deducing consequences), and a
  **CAPTURE** block (§20 document mode — records what is already known or just done; there is no gap
  backlog, so the coverage-ratio / exhaustion semantics do not apply — declare CAPTURE so the exhaustion
  signal is not read as meaningful in a mode with no gaps). For all three, the ratio is advisory — a
  high ratio in an absence-centred block is a structural artifact (absence is cheap to certify, costly
  to reason about), not an exhaustion signal.
  A synthesis block that cites only prior `[Block N]` cross-references will report `n/a` (no `[CERT*]`
  markers) from `verify-block.sh` — this is the EXPECTED signature of a correctly-written DESIGN block,
  not a defect. Declare MIXED, ABSENCE-CENTRED, or CAPTURE so the ratio is read correctly rather than
  triggering a false exhaustion signal.
  The tally counts a block's OWN markers, not markers it QUOTES from another block for meta-purposes: a §14
  correction block that literally quotes a prior block's `[INFER]`/`[CERT]` token in order to correct it will
  have those quoted markers counted as if they were fresh claims, INFLATING the count. Think in RAW vs
  ADJUSTED counts — the raw count is every token in the file; the adjusted count strips the markers quoted
  from other blocks — and read the ratio off the ADJUSTED count. (Doctrine only here; distinguishing quoted
  from own markers mechanically is a separate slice.)
- **Artifacts** — the block file exists, `CATALOG.md` regenerated, `INDEX.md` + `RESEARCH-STATE.md`
  updated, and the backlog re-classified investigable-vs-blocked (§8).
- **MCP-doc snapshots** — every LOAD-BEARING `[CERT-web]`-via-MCP citation (context7 et al.) was
  snapshotted to `sources/web-snapshots/` and registered in SOURCES.md (§5). Report Y/N + count. This
  gate exists because the §5 snapshot rule was ADOPTED but went unenforced — context7 citations kept
  landing with no snapshot across runs; treat it like the token-check, not a good intention.

**Mechanize the counting.** The marker tally, the `[INFER]`/`[CERT]` ratio, and `[CERT]` `file:line`
citation-resolution are COMPUTED, not remembered: run [`toolbelt/verify-block.sh`](toolbelt/verify-block.sh)
`<block>` inside the iteration and paste its output into the self-report. It is the agent's OWN calculator
(not an orchestrator post-hoc gate — §11 rejects those); it exits non-zero on a verifiable contradiction (a
cited file that exists but whose line is out of range). It does NOT replace the token-check: a citation to a
beautified-temp / decompiled / snapshot path shows as `extern` (not target-resolvable), so the agent still
confirms those the same way it confirms every load-bearing `[CERT]` token — by reading the cited source.
The reported tally MUST BE the LITERAL `verify-block.sh` output (or a verbatim excerpt of it), never a
hand-recalled or rounded estimate: a self-report that gives `~N` counts, or a hand-computed ratio that does
not match a live run, is a VIOLATION — and a block that reports NO numbers at all (only prose like "expect
ratio ~0.5" / "high ratio expected") is a RULE VIOLATION, not a lighter-weight compliant report. The whole
point of trusting the self-report (below) is that its numbers are MECHANICALLY computed; a hand-number
silently erodes that, and the gate stops being a gate. If the script was not run, the block is not done.

**The corpus linters are edge-triggered agent calculators too — not orchestrator gates.** `verify-block.sh` is
the agent's PER-BLOCK calculator; `verify-state.sh` and `verify-sources.sh` are its PER-INPUT calculators, run
the same way — INSIDE the iteration, by the agent, never as an orchestrator Bash gate (this section rejects
those). They are EDGE-TRIGGERED on their input's edit: run `verify-state.sh` right after editing the
`RESEARCH-STATE` summary (cheap — one file), and `verify-sources.sh` ONLY after an edit to `SOURCES.md` (i.e.
only when a source was added/preserved this iteration) — NOT every iteration. This RECONCILES the tension with
"no per-block orchestrator gate": a linter can only surface a NEW defect when ITS input changed, so triggering it
exactly on that input's edit adds ZERO redundant corpus re-scans, yet catches the defect in the ITERATION that
introduced it instead of letting it survive to the STOP backstop (§5, §8). The STOP run stays as the final
backstop, not the first line of defense — it re-reads the whole corpus once, which is why it runs only at STOP.

**Block-evidence artifacts are gate-enforced (not `extern`).** An evidence dump a `[CERT]` cites BY ARTIFACT
NAME (`B<N>-*` / `bloque<N>-*`, extension OPTIONAL — `B125-ghidra-njre.txt:421‑488` and `B128-triage:103` both
count — cited inside a parenthetical span or backticks, single line or a range) MUST be preserved in the corpus.
`verify-block.sh` now resolves these strictly: an unresolvable artifact cite is a **FAIL**, not `extern` —
bloque125 sealed load-bearing `[CERT]`s to `B125-*.txt` dumps that were never preserved, and the old parser
(backticked single-line only) let them pass clean.

The orchestrator **TRUSTS this self-report** and only spot-checks when a report smells off (status
mismatch, an uncited claim, a marker tally that doesn't add up). It does **NOT** run Bash gatekeeper
commands by default — the in-block contract is the gate. This is not a soft preference: on the protocols
run the orchestrator ran a per-block Bash gatekeeper (ls + git log + grep the star claim) after all 6
blocks — every one PASSed and **caught nothing**, while the one real error (a B131 byte-order default) was
caught later by **cross-block correction (§14)**, not by any per-iteration re-check. So the real
error-capture mechanism is §14, not an orchestrator gatekeeper — per-block Bash re-verify only adds
permission friction and driver bloat for no demonstrated catch.

**Verifying the verifier.** When a run adds or relies on a guard, check, or oracle, these rules apply
before trusting its verdict:

- **Prove a guard by breaking it — and keep the proof as a re-runnable artifact.** Revert the guarded
  subject PER-FILE (not as a set), run the guard against the reverted copy, and confirm the guard fires.
  Keep the demonstration as a re-runnable script in the target's `tools/` (`prove-guards.py` or
  equivalent) — a guard proved once by hand decays the moment the code changes; a committed proof survives.
  Anchor the guard to its PRODUCER: reverting data while the producer still runs correctly proves nothing
  about whether the guard watches the right output.

- **Measure the guard's firing range against real production data.** After setting a threshold in a guard (distance, area, count, ratio), query the actual distribution of the guarded quantity over the full real dataset and confirm the threshold lies within that range. A threshold that no real sample crosses is dead code: the guard passes every real input, including broken ones. Synthetic injection proves the guard FIRES; a range check against real data proves it is REACHABLE. Both are required — state the blind spot of the injection proof (it cannot demonstrate reachability against real distributions) before claiming the guard is sound. Cross-reference: nave-panccadia B11's "name a test's blind spot" principle — synthetic injection is blind to this failure mode by construction. (Evidence: nave-panccadia B38 — v8 midpoint dedup threshold 0.6 m; all 20 real doorways × leaf midpoints yielded min 1.842 m, 3× the threshold; detected by measuring `min(dist)` against the JSON, not by reading the code.)

- **Per-path verification → per-degree-of-freedom.** When elements reach the output by different transform
  routes, each route needs its own check. But a guard that constrains N−1 of a defect's N degrees of
  freedom reports PASS on a broken build. Before trusting a guard set, state which DEGREES OF FREEDOM each
  guard constrains (position X, position Y, scale, orientation, presence/absence) and verify that the
  union across all guards covers every degree the element actually has. A guard covering a path but not all
  its dimensions is a partial guard.

- **Instrument before theorising.** When an interaction yields no answer, an empty result, or an unexpected
  count, the FIRST action is to add observability — dump the raw frame or payload, capture the exception,
  log the actual request issued — NOT to form a hypothesis about the peer or the data. A hypothesis formed
  without the bytes is unfalsifiable and costs a full iteration to test. Budget rule: if two consecutive
  hypotheses have failed, instrument rather than hypothesise again.

- **Compete rival hypotheses instead of validating one.** When a derived transform or mapping could
  plausibly be wrong in more than one way, score ALL plausible wrong answers against the evidence and
  require the correct one to win by a clear margin. A lone hypothesis that merely fits is not evidence that
  alternatives do not fit better. (Close relative of `adversarial-verify` §3, which refutes one claim with
  N skeptics; this method ranks N mutually exclusive candidates with one measurement.)

- **Defer instead of guess when two explanations fit.** When one observation admits two competing
  explanations and neither is yet falsifiable — the distinguishing evidence has not been gathered —
  record the observation, name both, defer the verdict, and open a gap. A deferred verdict is a finding;
  a guessed verdict is a liability: in practice, corrections came from continuing to READ, not from
  revisiting the guess. Distinct from "Compete rival hypotheses" (which scores candidates when the
  distinguishing evidence EXISTS); distinct from §14's `CONTRADICTIONS.md` case (which records a
  conflict between two existing claims) — here the observation has not yet resolved into any claim.

- **Record computed-and-rejected measurements at the site.** When a measurement is computed and rejected
  (wrong method, wrong filter, wrong assumption), record the number, the method, and the reason AT THE SITE
  where a reader would naturally reach for the same approach — a comment in the tool, a note in the probe
  output — not only in block prose. A silently deleted dead end gets re-walked; a rejection note at the
  tool prevents the next reader from repeating the same failed path.

- **"The verifier asserts more than it checks."** A guard whose NAME promises more than its CONDITION is a
  silent false pass. Known forms: a literal `True` as the condition; an `except` branch that counts an
  OMITTED comparison as approved; a constant expression that never evaluates the actual data; a regex whose
  exclusion pattern never matches the real defect; a check that reads from a proxy (a cached JSON, a prior
  build's output) while the defect lives in the rendered or live output; a token satisfied by its own
  adjacent comment; a comparison window that crosses the boundary into a neighbouring record. Treat the
  check's name as a claim and audit it the same way.

- **Config-file keyword-poison (the guard that silently stops guarding).** When the research relies on a
  constraint or rule file (a DRC ruleset, a lint config, a CI gate spec) as the test oracle, verify the
  constraint engine's response to UNKNOWN tokens before trusting any result: some DSLs silently discard
  unrecognised keywords, disabling all custom rules with exit 0 and no warning — a structural sibling of the
  count-zero anti-pattern applied to config-file authoring. A mandatory CONTROL-POSITIVE — one rule that MUST
  fire on a known-bad fixture — is the only reliable detector: if the control-positive goes clean, the config
  is poisoned and every subsequent "pass" is a false one. Probe for this at the start of any DRC or
  constraint-DSL investigation; do not trust a clean result until a control-positive has fired.

- **Negative-control / background rate.** A match rate, overlap count, or alarm frequency is not evidence
  until measured against a CONTROL SET THAT SHOULD NOT MATCH. If the alarm fires on 40 % of a corpus,
  the relevant question is: how often does it fire on a corpus known to be clean? A control set without
  the target property — a device that has never been configured, a block that contains none of the tokens
  under investigation — establishes the background rate. Without it, you cannot tell whether a 40 % hit
  reflects a real signal or a noisy instrument. This is the negative twin of the CONTROL-POSITIVE rule:
  one rule must fire on a known-bad fixture (control-positive); one must NOT fire on a known-good fixture
  (control-negative). Run both before trusting any match count or alarm rate.

- **Scope check: claim wider than measurement.** Before closing a block, compare the SCOPE of each central
  claim against the scope of what was actually measured. If the claim speaks of a population (all devices,
  all screens, the system) and the evidence is a sample (one device, one screen, one module), either measure
  the population or rewrite the claim to its real scope. A well-cited sample is `[CERT]` for the sample and
  `[INFER]` for the population. Cheap tell: a claim using a quantifier ("none", "all", "the system") backed
  by a point measurement is missing the scope check.

- **Test an attribution method on a known-answer case before deploying it.** The "prove a guard by
  breaking it" principle extends to ATTRIBUTION METHODS, SIMILARITY METRICS, and HEURISTIC MAPPINGS.
  Before trusting such a method on unknowns: (1) run it on at least one case whose correct answer is
  already known and confirm it gives the right answer (this positive test is required); (2) where a
  case known to be WRONG exists, require the method to reject it (the negative control is required
  when such a case exists — a method that passes only the positive may be trivially accepting; one
  that passes only the negative may be trivially rejecting).

- **Coordinate-system handoffs are verification boundaries.** Any handoff between coordinate systems
  (CAD +Y up vs three.js +Z toward viewer; job-network numbering vs live-bus numbering) is a boundary
  that requires an ASYMMETRIC signature to test correctly — signed area, winding order, a known-handed
  landmark. Symmetric measures (lengths, areas, counts, angle magnitudes) are INVARIANT under reflection
  and cannot detect a coordinate-system flip or a handoff error; a fully mirrored model passes symmetric
  checks with no failures.

- **Viability is a property of the critical step, not the first.** A path of N steps is viable when the
  step MOST LIKELY TO FAIL passes — normally the last step (read the data, receive the response, apply the
  effect). "The door opens" (open/connect/auth succeeds) is evidence only about that step. Until the
  critical step passes, the honest report is "step K of N passed; step N (critical) is untested." Applies
  to PoC builds, integrations, chains of auth, multi-stage protocols: the enthusiasm of a first partial
  success is exactly when over-claiming happens.

- **State redundant-vs-complementary before combining sources.** When combining two sources to derive a
  coverage or completeness metric, declare up front whether they are expected to be REDUNDANT (intersection
  is the quality signal) or COMPLEMENTARY (union coverage is). A metric chosen before understanding the
  source types will misreport: two complementary sources that never share items show 0 % intersection,
  which reads as a join bug, not a design property. Check whether the record keys or device sets overlap
  before choosing the metric.

- **Verify the edit landed.** When modifying a deliverable by pattern or string replacement rather than a
  structured edit, assert the new text is present afterwards (grep the new string, or make the script exit
  non-zero on a non-match). A silent no-op edit is indistinguishable from a runtime bug and sends
  debugging at the wrong layer. The same discipline applies to corpus files a later iteration was supposed
  to update: a retro or state file that did not receive its intended update is a silent no-op with a longer
  blast radius.

**Scope: this applies to the STATIC read-only loop only.** In a DYNAMIC/hardware, destructive, or
BUILD/PoC phase (§12), a per-block orchestrator Bash gate IS justified and expected — there it verifies
PHYSICAL/EXTERNAL state the in-block self-report cannot vouch for and §14 cannot protect: the device was
left safe (baseline restored, a write reverted, the checksum re-measured live), the blast-radius of a
write was contained, the PoC's round-trip actually ran. §14 catches wrong CLAIMS across blocks; it does
not catch a bricked device or an un-reverted write. Static blocks trust the self-report; live/destructive
iterations gate on real-world state.
A **batch of FIXES** in a build/QA/execution phase (§19) is likewise OUTSIDE the static self-report contract:
it is a NEW change surface, and the fixer's own directed/green tests do NOT substitute for verification. It
gets its OWN scoped adversarial re-check on the fix delta before any terminal verdict — see §19 (a round of
fixes, each closed by a passing directed test, has introduced fresh CRITICAL defects caught only by re-judging
the delta). The trust-the-self-report gate is scoped to STATIC blocks; a fix batch is not one.

**Kit test-lane contract (toolbelt quality gate).** The toolbelt gate (`run-all.sh`) defaults to the
**fast** lane: suites load fixture-cached assertions instead of spawning the real tool (Ghidra, r2,
bwrap, etc.), keeping the full suite under ~30 s.  Two additional lanes are available via
`RSDD_TEST_LANE=slow|all`.  Select with the env var or, for ergonomics, a `--lane` flag if the runner
exposes one.

| Lane | Meaning |
|------|---------|
| `fast` (default) | Fixture-cached assertions; real tool NOT spawned. |
| `slow` | Real tool run; containment guards still asserted. |
| `all`  | Both fast and slow paths exercised. |

Fixtures live under `tests/fixtures/lane/<suite>/<name>.json`; regenerate with
`tests/regen-lane-fixtures.sh` (requires a real tool install).

**Critical anti-#128 rule:** containment guards (bwrap / qemu / docker flags) are ALWAYS asserted in
the fast lane — only the spawn / real-tool-run is deferred.  A fast-lane suite MUST emit a normal
`== N passed · N failed ==` summary and MUST NOT emit a `SKIP:` line (`run-all.sh` counts
`SKIP:+exit0` as skipped, which is lost coverage).

**Rule R2 — fast-lane teeth come from the live module, not the frozen fixture.** A fast-lane
suite's teeth (the assertion that must go red under `--prove-teeth`) MUST come from a LIVE import of
the SUT — a unit assertion over an importable constant or pure function — NEVER from the committed
fixture. A fixture captures the value BEFORE any mutation and is not regenerated during
`--prove-teeth`, so a fixture-only assertion stays green after the SUT is mutated: theater, not teeth
(§4 FABLE maxim). The fixture DOCUMENTS the report shape; the live import BITES. Exemplars:
`corroborate-native-r2` imports `SAFE_R2`; `corroborate-firmware` imports `require_private` /
`normalized`. **Exception:** a suite whose SUT has no importable oracle (a pure-Java analyzer such as
`jvm-callgraph` or the `ghidra-*` exporters) cannot get live-import teeth; its fast-lane
`--prove-teeth` mutates a COPY of the fixture, which proves the assertion bites but NOT that a SUT
regression is caught, and therefore claims ZERO fast anti-#128 credit. This exception MUST be declared
in the test-file header; the real SUT-regression teeth for such a suite (mutate the analyzer +
rebuild) stay slow-only. A computed value that is not an importable constant (e.g. a finding cap) is
the same case: its fast tooth is a fixture-level structural check and its real regression tooth lives
in the slow lane. Every fixture-copy or SUT-copy mutation MUST be drift-guarded — fail loud with a
`MUTANT-SETUP-FAIL` when the mutated token is absent, never silently green.

**Rule R5 — the content-addressed manifest `verify` is slow-only and never enters a fixture.**
Suites that produce an `analysis-manifest.v1` (native, firmware, java) MUST keep `analysis_manifest.py
verify` in the SLOW lane. It is not fixture-portable: `verify` re-resolves the tool launcher on the
LIVE machine and rehashes it (e.g. `/usr/bin/bwrap`, re-resolved from `PATH`, NOT stored in the
fixture), so on any other machine it raises `file-backed tool identity changed` even when every file
inside the fixture tree rehashes fine. The fast lane asserts only the normalized top-level report and
never reads or verifies the manifest; `validate` (pure schema + identity recompute over the JSON, no
filesystem) is fast-safe if a cheap manifest check is wanted. The manifest `identity` is a content
hash that excludes the three volatile run fields (`started_at`, `ended_at`, `duration_ms`), so
`manifest_identity` is stable run-to-run on one machine — a fixture placeholder is honest — but
machine/version-bound: regenerate the fixture on tool or launcher drift.

## 12. Dynamic phase (validation against a live system)

The static loop (§1–§11) is READ-ONLY decompilation — safe, autonomous, loop-able. When a LIVE system
becomes available (device, server, PLC), a DYNAMIC phase validates the static findings against it. This
phase is DIFFERENT and must NOT run as a blind autonomous loop:

- **Static-install boundary (vendor-disk / daemon boundary).** The static/live split is a STATE
  predicate, not a file-location one: the distinguishing fact is EXECUTION, not where the bytes live.
  Vendor software installed to disk with its daemon NOT started is still STATIC territory (§1–§11).
  Disk-read, decompilation, `grep`/`rg`, `javap`, and `fd` over the installed tree are READ-ONLY and
  run autonomously under the static loop — installing and reading a vendor package never crosses into
  this phase. The LIVE-EXECUTION CROSSING is any of: (a) executing the vendor launcher or daemon; (b)
  setting a runtime-root env var the daemon consumes as its home (e.g. `NIAGARA_HOME`,
  `NIAGARA_USER_HOME`); or (c) spawning any subprocess that initializes vendor runtime state. Each of
  these is a MUTATION — it writes DB tables, a license cache, socket files, and log dirs — so it falls
  under this section's supervised + scoped-authorization cadence, NEVER the static loop's autonomous
  one. (Disambiguation: this is a DIFFERENT concept from the "Live-install pre-flight checklist" bullet
  below, which governs data-op safety on a running production host; do not conflate the two terms.)
  Concrete Niagara case: decompiling `nre`/station JARs from the installed tree is static and
  autonomous; executing `nre`, or exporting `NIAGARA_HOME` for a daemonized subprocess that boots the
  station, crosses the boundary and requires §12 supervision.
- **Supervised, not loop-blind.** Each interaction with the live system is deliberate; the orchestrator
  reviews before the next step. No `/loop` self-pacing against hardware. The DELEGATE / MODEL-TIER rules
  (PROMPT-LOOP) govern the static loop's HEAVY SWEEPS, not this phase: narrow live probes and a live
  write-credential must never be handed to a sub-agent, so `no·inline` is the COMPLIANT tier record for
  §12 iterations — not a skipped delegation.
- **Capture-once / slice-many.** When ONE live acquisition (e.g. a single serial `running-config` dump)
  is the source for MANY topic blocks, do not stamp a fresh ACQUISITION/DELEGATE line on each block: the
  capture happened once, and re-running per-iteration acquisition machinery over an already-preserved
  artifact is empty ceremony. `no·inline` is the COMPLIANT record for every downstream slice; the real
  per-block cost is the reschedule/catalog overhead, not a delegation-discipline failure. Preserve the
  capture once under `sources/probes/` (`[CERT-hw]`), then cite that one artifact from every slice.
- **Read-first, write-supervised.** Start with READ-ONLY probes (safe on a running system — confirm
  read-only in code first). WRITE/modify (load programs, change config) only step-by-step with explicit
  user OK; a bad write can brick the device.
- **Invasiveness ladder (fixed order).** Escalate deliberately, never skip a rung: **(0) passive
  capture** — redirect the vendor's own client or driver through a **file-backed sink** and capture
  the genuine datastream byte-for-byte; no custom protocol client is written and no byte is sent to
  the device. General form: any emit target with an existing vendor driver can be captured through a
  file-backed or packet-capture sink before any probe is written. Print/scan instance: create a `FILE:`
  Windows printer port and trigger a vendor test-page print to capture the wire stream ([CERT-hw]-grade).
  Passive USB parallel: USBPcap/Wireshark host-side capture of the USB bus →
  **(1) read-only probe** —
  including SAFE method/gate discovery: learn a destructive endpoint's allowed verbs and its auth gate
  WITHOUT triggering the op, via `OPTIONS` or a deliberately wrong-method request that returns `405 + Allow`
  (e.g. a GET on a POST-only `backups/reset` reveals the verb and the gate without detonating the wipe) →
  (2) reversible write — read-and-save the current value first, hold an oracle, restore in a `finally` →
  (3) destructive write — backup-first (below) → (4) irreversible — last, and only under scoped
  authorization (below). Announce which rung each step is on.
- **Cross-protocol oracle for every write.** Validate a write through an INDEPENDENT channel, not the one
  you wrote on. On the LOGO!8: a Modbus FC01 read was the oracle for an RPC `writeDT`, and an RPC GetFB
  read was the oracle for a Modbus write. A write confirmed by a second channel earns `[CERT-hw]`; a write
  confirmed only by the channel that made it is `[INFER]`. No oracle ⇒ do not write.
  For a SINGLE-protocol target (web/REST, no second wire), an INDEPENDENT READ endpoint is a valid oracle —
  a GET on the resource after the POST that wrote it (e.g. GET `/nmodsreflow/config` confirming a POST
  `config_update`). The essential property is that confirmation does NOT come from the write's OWN response,
  not that a second wire protocol exists; never trust the write's own `200`.
- **Attribution oracle for every READ on a routed protocol.** On any protocol where requests traverse a
  router, gateway, or bridge (BACnet, BACnet/IP-to-MSTP, Modbus gateways, CAN bridges, any
  store-and-forward relay), a reply arriving is NOT evidence of who replied. Before recording data as
  evidence about a specific remote node, prove attribution: read an identity property of the TARGET ITSELF
  (e.g. BACnet `Device` object's `object-identifier`) and require the responder to identify as the
  requested node. If it answers as a different node, the data is UNATTRIBUTABLE and must not be recorded
  as a finding about that node — regardless of how plausible it looks. Cheap tell: identical values across
  devices that should differ (different vendors, different models) is an attribution failure until proven
  otherwise. This is the read-side counterpart to the write oracle above.
- **Counterfactual probe for silent failures.** When a feature produces correct-looking results but may be
  operating in a degraded mode — no error, no timeout, no missing sample visible — measure it by adding a
  parameter whose sole purpose is to DISABLE the feature. Run the same scenario with the flag on and off;
  the difference between the two runs IS the measurement. A failure that produces no error and no missing
  data is only detectable by this contrast. (Three instances from one engagement: `-NoRenew` to measure COV
  subscription renewal; `-CovGiveUpAfter 999` to isolate per-device COV savings; `batch=1` vs `batch=N`
  to measure pipeline timing against a single-request baseline.)
- **Internal witness for ambiguous silence.** When the failure to detect produces silence
  indistinguishable from valid silence (a COV point that never changed vs a COV subscription that expired;
  a device that never answers vs a bus without activity), look for a field the TARGET SYSTEM computes
  INDEPENDENTLY of your measurement channel and that reflects the internal state you want to observe. That
  field is the witness. If the protocol provides one, read it; if not, add observability at the target side
  (a heartbeat, a diagnostic field, a state log). Before concluding "silence = failure", confirm the
  independent witness agrees. (Example: BACnet `time-remaining` on a COV subscription — the device reports
  how long it considers the subscription valid, independently of whether notifications are arriving.)
- **Synthetic-stimulus deploy-test (validate LOGIC with no live upstream data).** When validating a deployed
  flow/program whose REAL trigger (an external device/event) is not available, do not stop at "it reads
  correct on paper" — inject a SYNTHETIC stimulus (an `inject`/equivalent node feeding a representative
  message) and read the result back through an IN-PROCESS capture: flow context, a `catch` node for errors, a
  debug tap. This answers a DIFFERENT question than the cross-protocol oracle above: the oracle asks "was the
  WRITE actually applied", this asks "does the LOGIC run correctly given no live upstream data". It finds bugs
  static reading never surfaces — a deploy-test caught a real `TypeError [ERR_UNKNOWN_ENCODING]` and then
  confirmed the fix on a second run. A flow that merely LOOKS correct is not a flow that RUNS.
- **Backup-before-destroy (citable).** Before overwriting a program/image/config, READ and SAVE the current
  one to `sources/`, and VERIFY the backup actually restores. Keep it as both evidence and the revert
  target. A destructive step with no verified backup does not run.
- **"What silently resets this?" — confirm a remote channel's dependencies before acting.** Before
  relying on any configuration to keep a remote channel alive, enumerate what can silently undo it:
  **suspend** (sleep policy restores defaults on wake), **network reclassification** (a firewall
  `-Profile` flips to Public on reconnect, dropping inbound rules), **your own earlier automation**
  (an event-triggered task re-runs DHCP-first logic on any network-change event and can override a
  later manual static assignment), and the **DHCP lottery** on a segment with multiple DHCP servers.
  Corollary: an auto-revert rescue must be verified to exist (read it back; abort if absent) AND its
  target state must itself be safe under live conditions — reverting to DHCP on a two-DHCP-server
  segment can land in a different failure, not the intended safe state.
  (Evidence: computadoras B16 §16.20, B25 §25.3/§25.6/§25.7.)
- **Security-remediation write — the fix STAYS APPLIED, not reverted.** The invasiveness ladder's rung (2)
  reversible-write recipe ends with a byte-identical RESTORE — correct for a PROBE. A permanent,
  user-authorized REMOVAL of a discovered live vulnerability (deleting a leftover/malicious flow, closing an
  open write path) is NOT a probe: its correct terminal state is the FIX STAYING APPLIED. It still requires
  backup-before-destroy + a dual/independent oracle, but "verified restore (byte-identical)" is replaced by
  "verified fix + confirmed no side-effect on OTHER state". Do not restore a vulnerability by rote compliance
  with the probe recipe — the backup is retained for rollback, not applied.
- **Device identity ≠ program identity.** A checksum/version identifies the loaded PROGRAM, not the physical
  UNIT. Confirming you are on the BENCH and not PRODUCTION is out-of-band (who plugged in what), never
  inferred from the program you read. Do this BEFORE any write — a prior session wrote to PRODUCTION
  believing it was the bench (near-miss). Verify the unit, then verify the program.
- **Scoped authorization for irreversible ops.** Irreversible/destructive actions are HARD-BLOCKED by
  default. The user lifts the block "for this session only"; record the grant with an explicit expiry
  (persist it), and re-arm the block when the session ends. Never carry an irreversible authorization
  across sessions. **A grant is a CEILING, not an instruction** — exhaust offline/on-disk artefacts
  BEFORE spending a live grant; if disk evidence answers the gap, the authorization is conserved.
- **Reboot / NIC-reconfig on a physically-inaccessible host is DESTRUCTIVE-equivalent.** On a box with
  no immediate physical access, a `Restart-Computer` or any network-interface reconfiguration that can
  sever all remote channels is NOT a free validation step — it can leave both channels down with no
  recovery for hours. Gate it identically to an irreversible write: require explicit operator go-ahead
  AND a proven independent fallback (a human near the machine, or a second channel confirmed independent
  of the one under test) BEFORE acting. Prefer designing the fix to need no reboot.
  (Evidence: computadoras B23 §23.1 reboot → ~3 h lockout; B25 §25.3 secondary-IP add → second lockout.)
- **Verify tooling REMOVAL with the same rigour as placement.** Re-measure the removal on the host
  (path absent, no residual files match the tool's signature) AND confirm that untouched processes
  were not restarted (same-PID invariant: process identifiers before and after the visit must match).
  "I did not touch the BMS" is a claim of intent; identical PIDs are a measurement of it. A restart
  would change them even if every command was read-only.
- **Cached network evidence carries a state field.** ARP/CAM/neighbour tables record both the layer-2
  mapping AND the state of that mapping: `Stale` means the mapping was known but has not been reconfirmed
  by the stack recently; `Reachable` means the stack confirmed the layer-2 address recently (presence
  evidence). Never report presence from a cached table without checking the state field or taking an active
  confirmation. Related: absence of ICMP/TCP response is not absence of device — embedded controllers may
  speak Ethernet layer 2 and legitimately never answer IP; confirm absence via network infrastructure
  tables (`Stale` + ping failure + no ICMP-filtered `Reachable`), not via a ping sweep alone.
- **Probe output ≠ protocol acceptance.** A connection banner (e.g. openssl `CONNECTED`) records a TRANSPORT handshake, not server-side protocol or version acceptance; re-derive before escalating (PROMPT-LOOP.md HARD RULES → RE-MEASURE A DRAMATIC POSITIVE).
- **Module-loaded ≠ path-taken.** Which implementation actually RUNS is a runtime fact, not a static
  one: a component can be LOADED — present in imports, exports, or a registry — without being the ACTIVE
  path for a given operation. Determining which code path executes requires a live stack/provider census
  taken WHILE the operation runs, never an inference from static import/export topology alone. This
  applies to any runtime plugin registry, SPI, or multi-provider runtime where several implementations
  are present and load order or provider precedence decides which one wins.
  (Evidence: static exports inferred DSA verify ran through a native module; a live census during the
  operation showed 0 hits — the real path was a Java provider, BouncyCastle.)
- **Re-measure ground-truth, never inherit it.** When entering a dynamic/hardware phase (or any new
  live measurement), re-measure ground-truth identifiers — checksums, versions, IPs, build ids — LIVE
  from the real system in THIS phase. Do NOT cite them from a prior note or earlier block: an inherited
  value may be stale. B66-B69 carried a bench-program checksum `05 3d 6e e4` inherited from an earlier
  probe; the live value was `0x87B961A9` (only B70 measured it live), which forced a correction (§14).
- **Reclassify on hardware arrival.** Gaps marked `blocked` (§8) flip to investigable when the live
  system appears — update RESEARCH-STATE and re-run those. Exception: `blocked-by-design` gaps (§8 — no
  live surface by design) never reclassify, even on hardware arrival.
- **Reclassify on tool WITHDRAWAL.** The mirror of hardware arrival: when the tool/access/host a gap
  depends on is WITHDRAWN (a live session ends, a scoped grant expires, a tool is uninstalled), flip its
  gaps investigable→blocked in the SAME pass — update RESEARCH-STATE and re-run the §8 investigable
  count. A gap left `pending — investigable` after its tooling is gone silently over-reports investigable
  runway and corrupts the §8 STOP criterion.
- **Tooling.** Build a read-only probe (a port of the decompiled protocol) and run it via
  [`toolbelt/probe.sh`](toolbelt/probe.sh), which preserves the raw output in `TARGET/sources/probes/`
  as `[CERT-hw]` evidence.
- **Hardware refutes code.** When the device contradicts a `[CERT]` claim, mark the corrected fact
  `[CERT-hw]` and fix the prior block transparently (note "corrected in BN"), as B64 did to B55 §55.3.
- **Hardware scope-CLARIFIES code (the softer move).** A live `[CERT-hw]` finding can SCOPE-CLARIFY a
  `[CERT]` static claim WITHOUT refuting it: when the code-path is real but the live DEPLOYMENT gates or
  limits its exploitability (e.g. `backups/reset` exists and is reachable in code, but the live station
  auth-gates it `403`; a `?file=` traversal is coded but the deployment returns `500`). Label it a scope
  divergence — "correct for the code-path; the live deployment adds a control the static source could not
  express" — NOT an error. Reserve "refute" (above) for a live behavior that proves the static claim WRONG
  for the SAME artifact. (This is §14's REFUTE-vs-CLARIFY-SCOPE distinction, in the hardware→code direction.)
- **Live-verification verdicts (name each defect's outcome).** Distinct from §13's certainty-audit verbs
  (those re-verify a static corpus). For each static defect validated live, assign one: **CONFIRMED** (a
  live oracle reproduced it) / **NOT-REPRODUCED** (the live system did not exhibit it) / **GATED** (code-path
  real, live deployment auth-gates it — the scope-clarify case above) / **CONFIRMED-BY-PARITY** (a sibling
  sink sharing an ALREADY-PROVEN privileged path — deliberately NOT re-detonated, since one live proof of
  the pattern suffices and re-firing is risk without new information) / **DEFERRED-requires-execution**
  (needs a built probe → §19). Consolidate them in a per-defect verdict table in the phase's terminal block.
- **A negative dynamic result is a first-class finding, not a failed probe.** When a requires-execution step returns a NEGATIVE (the expected behaviour does NOT occur), record it with the same evidence standard as a positive result, and immediately check whether any prior block asserted the corresponding POSITIVE. If one does, §14-correct it in the same pass — do not defer to a later audit or wait for the operator to ask. This is the proactive execution-result pairing rule; it complements §14's proactive measurement-scan rule. B534's honest negative ("moved file is native") §14-corrected B532's "one Java method = HostId gate", but only because the operator kept asking; this rule makes the pairing mandatory on every negative execution result.
- **After an incident, check the DEVICE first (refines §17).** If an iteration was killed/crashed mid-write
  in a hardware phase, the §17 resume rule inverts: check the PHYSICAL device state (is it left safe? was
  the write applied or reverted? re-measure the checksum live) BEFORE checking git/disk. A committed block
  is recoverable; a device left in a half-written state is not. Physical safety precedes artifact state.
- **Live-install pre-flight checklist.** Before taking any action on a production target (compressing,
  transferring, or archiving live data): (a) measure free disk space BEFORE writing to the target; (b)
  verify archive or extraction completeness by entry count against a direct disk count BEFORE transferring
  — a pipeline truncated upstream (e.g. `Select-Object -First N` terminating a `tar`) will report success
  while delivering a partial archive; (c) delete temporary artifacts from the production host after
  verified transfer; (d) SHA256-verify the transferred copy against the source; (e) never version client
  production data — gitignore the data copy before staging anything.
- **Environment setup** (e.g. WSL `networkingMode=mirrored` to reach a LAN device, run `wsl --shutdown`
  from **Windows** PowerShell — not inside WSL; for USB targets, hand off the device via `usbipd-win`
  bind/attach/detach — see `DYNAMIC-SETUP.md §1b`) is a prerequisite; verify connectivity before probing.

### 12b. Remote HTTP / cloud API targets (the frame that does NOT transfer from bench hardware)

Everything above assumes a live system you physically or administratively CONTROL (a bench device, a
PLC, your own station) — where the dominant risk is bricking and the ground-truth identity is a program
checksum. A **remote HTTP / cloud API you do not own** (a hosted SaaS endpoint, a third-party API) is a
different subject: there is no unit to brick, no bench-vs-production physical confusion, no checksum-as-
identity. The invasiveness ladder, cross-protocol/independent-read oracle, and "never trust the write's
own 200" rules STILL apply. A service you **deploy and own** but do not host the infrastructure for
(edge / serverless / PaaS) is a third frame — neither §12's hardware nor this one: see §12c. What
changes for §12b:

- **Authorization is the gate — and it covers READS too.** Probe only a service you are authorized on:
  your own account, a sandbox/test tenant, or written permission. Unlike a local device (where reads are
  free and only writes need a grant), on a service you do not own an *unauthorized read* is already a
  violation. Record the authorization scope + expiry exactly as §12's scoped-authorization rule does for
  irreversible ops, and re-arm the block when the session ends.
- **GET is not free.** A read against a remote API can still cost money (metered calls), mutate state
  (non-idempotent or side-effecting GET), rate-limit or lock the account, or be logged/flagged. Treat
  every call as observable and accountable. Prefer a sandbox/test tenant; never load-test production.
- **Rate-limit & ToS discipline (inverts the static loop's cadence).** Read the ToS and published rate
  limits FIRST and stay well under them. Give a remote-probe loop a HARD call budget and a deliberate
  delay, and back off on `429` — the OPPOSITE of the static loop's shortest-delay reschedule cadence,
  which is for local read-only decompilation, not for someone else's server.
- **Data discipline extends to response bodies.** Responses may carry PII, secrets, or other tenants'
  data. The SECRETS DISCIPLINE (cite STRUCTURE, never VALUES) applies to what comes BACK, not only to
  credentials sent: never paste a raw token/PII-bearing response into a block or `sources/` — redact and
  cite the shape (fields, types, sizes), preserving only a sanitized snapshot.
- **Marker.** A claim verified by observing the live remote service's actual RESPONSE earns `[CERT-live]`
  (same rank as `[CERT-hw]`). A claim from the API's published DOCS is `[CERT-web]`. A claim resting only
  on the write's own success code is `[INFER]` until an independent read confirms it.

**Honesty note.** First exercised on computadoras B23–B25 (Cloudflare tunnel API: GET/PUT tunnel
configurations, connector status reads, Access app + service-token creation). One caveat the run
surfaced: a repoint of a remote-managed tunnel ingress is a reversible WRITE (rung 2 of the
invasiveness ladder in §12), not a pure read — save the full config before PUT, restore byte-identical
in a finally block, and confirm via an independent GET (computadoras B23 §23.5 repoint-probe-restore).

### 12c. Own-but-not-host targets (edge / serverless / PaaS)

A service the researcher **deploys and owns** but does not run the infrastructure for — a Cloudflare
Worker, an edge function, a PaaS deployment. This is a third frame: neither §12's bench hardware (no
unit to brick, no program checksum as identity, no physical bench-vs-production confusion) nor §12b's
remote third-party API (you are the owner and administrator — authorization is not the gate, rate-
limit / ToS discipline is not the primary risk).

The invasiveness ladder, the "never trust the write's own 200" principle, and the SECRETS DISCIPLINE on
response bodies carry over from §12 and §12b.

- **DEPLOYED ≠ PROPAGATED.** A successful deploy receipt (HTTP 200 from the deploy API, a "success" CLI
  output) confirms the platform accepted the artifact — it does NOT confirm the change is live at the
  edge. Edge and serverless platforms propagate to points of presence over a window measured in seconds
  to minutes; an immediate post-deploy probe may observe the old version at the PoP that served the
  request. A live claim requires a **propagation re-measurement**: wait for the expected propagation
  window, then re-probe. A single probe taken immediately after deploy is `[INFER]` — it tells you what
  one PoP returned at that instant, not what the fleet serves after full propagation. The symptom can
  look identical to a cache miss: `cache-control: no-cache` may help distinguish them, but propagation
  and cache are separate phenomena — confirming one does not rule out the other. (Measured: hilton-bms
  B11 §11.6 — immediately post-deploy the guarded route still returned 200; 5/5 probes returned 401
  ~30 s later without a cache-bypass header; what first appeared to be a caching artefact was a
  propagation race.)
- **Marker.** A live claim confirmed by probing your own deployed service **after the propagation window**
  earns `[CERT-hw]` — you own the service; its post-propagation response is as authoritative as a local
  device under your administrative control. Do **not** use `[CERT-live]`: that marker is reserved for
  services you do not own (§12b / §3). A claim resting on the deploy receipt alone, or on a single probe
  taken immediately after deploy before the propagation window closes, is `[INFER]` until a post-
  propagation re-measurement confirms it.
- **Staging vs. production boundary.** If the platform provides a staging or preview environment, probe
  staging first — the same caution as §12's bench-vs-production rule applies at the logical (environment)
  level, not the physical one.

## 13. Audit mode (re-verify an existing corpus)

A mode distinct from gap-discovery: take EXISTING blocks (especially an older corpus written without
this engine) and re-verify their claims against the primary source. Output is an **audit-delta**, NOT a
new knowledge block. Per claim assign: **ESCALATED** (was `[CERT-a]`/hedged → now source-confirmed
`[CERT]`), **CONFIRMED** (held), **DOWNGRADED** (unverifiable → `[INFER]`), **REFUTED** (the source
contradicts it — the claim was WRONG WHEN WRITTEN), **DRIFTED** (the claim was CORRECT WHEN WRITTEN but
the subject has since moved — do NOT delete; version-annotate it and queue a REFRESH via
[`PROMPT-REFRESH.md`](PROMPT-REFRESH.md)). **REFUTED and DRIFTED demand opposite treatment**: REFUTED →
correct or delete per §14; DRIFTED → version-annotate to preserve the older version-scoped truth, then
refresh. Write the report under `audits/`, READ-ONLY on the audited corpus.
Driven by [`PROMPT-AUDIT.md`](PROMPT-AUDIT.md).
A verdict of **DRIFTED** (claim was correct at write time but the subject moved — see PROMPT-AUDIT.md)
is not a §14 correction; it feeds the REFRESH cycle: [`PROMPT-REFRESH.md`](PROMPT-REFRESH.md).

**Operational suppression notes need an expiry.** §13's DRIFTED category covers BLOCK CLAIMS that
drifted with the subject. Its operational cousin — an "ignore this alarm / known caveat" note in a
state file — is riskier because it suppresses a MACHINE verdict, not just a prose claim, and is never
caught by a §13 audit sweep. Any standing instruction to suppress a linter, `verify-state.sh`, or
§7 alarm MUST carry a re-measurement date or explicit expiry condition (e.g. "caveat applies until
`<condition>` — RESOLVED `<date>`"). A suppression note with no expiry converts a real `STALE` or
`FAIL` into permanent noise, exactly as a DRIFTED claim does at block level — but harder to detect
because the suppression lives in the instrument, not in the claim it was silencing.

Audits ALWAYS write to `$TARGET/audits/` (never the
kit), carry a `<!-- review-status: pending -->` marker, and are surfaced by `sweep-audits.sh` — the
mirror of §18's retro sweep — with certainty verdicts routing to §14 corrections and coverage gaps to
the §8 backlog, applied by the human (propose-never-apply). STATUS (honest): the audit VOCABULARY
(ESCALATED / CONFIRMED / DOWNGRADED / REFUTED / DRIFTED) is exercised inline in normal blocks and §14 corrections (e.g. niagara B34 / B117 /
B119). The STANDALONE mode — a dedicated audit-delta under `audits/`, driven by PROMPT-AUDIT.md — was
EXERCISED ONCE (2026-07-12) on niagara blocks 90+81: 24 claims → 13 ESCALATED · 11 CONFIRMED · 0 DOWNGRADED ·
0 REFUTED (`niagara-research/audits/2026-07-12-certainty-audit.md`), the fleet's first `audits/` dir. It
raised certainty and caught no errors (a clean sweep); the one residual was an imprecise attribution fed back
as a §14 correction — so the mode reproduced its own predicted risk model on first contact. The run also
taught the contract two things now folded into PROMPT-AUDIT.md + the template: SOURCE_ROOT is usually NOT
under the corpus, and a class in multiple decompiler variants has DIFFERENT line numbers (pin the variant, or
risk a false REFUTED). Treat §13-standalone as PROVEN-ONCE, not battle-hardened — one clean corpus is not yet
a track record. (An earlier draft claimed "proven on niagara B100"; B100 carries none of this vocabulary — the
claim was removed as unverifiable; do not resurrect it.)

**Audit-first as a backlog seed.** A second use of an audit sweep: to BOOTSTRAP the gap-backlog of a new
focus over a mature corpus. Instead of hand-guessing gaps, delegate an audit that returns a coverage
matrix (subsystem × depth × static-vs-dynamic × known-vs-gap); the prioritized backlog falls out of it.
This is the recommended BOOTSTRAP path (PROMPT-LOOP step e) whenever the corpus is large enough that a
hand-listed plan would miss areas — proven on the protocols focus (matrix → 6 well-shaped gaps).

**Scale the bootstrap to the taxonomy's size — one boundary, two sides.** As a working heuristic (revise on
contradiction), let the number of candidate surfaces decide HOW to seed. When a package is small and legible
— up to roughly 20 classes/commands you can read directly — seed the gaps INLINE and skip the delegated
sweep, which would cost more than it returns. Above that same ~20 boundary, where a hand-listed plan would
miss areas, delegate the audit-first sweep above; for a LARGE taxonomy, fan it into PARALLEL audit shards
over disjoint surface sets so no single agent holds the whole universe. The ~20 count is the single
partition: at or below it, inline triage; above it, delegated and (when large) parallel audit — a working
figure, not a hard gate.

**Backlog SIZING comes from a MEASURED count, never a hand-guess.** Whenever a gap's size feeds
prioritization (how many classes/commands/files a subsystem holds), take the number from an ACTUAL count over
the real dir (`find … | wc -l`), never an eyeball estimate — hand-guesses are wildly wrong: a guessed
"studio 6" was actually 61, and "commands 36" was actually 14 AND pointed at the wrong directory. When two
nested directories share a basename, DISAMBIGUATE the full path before counting — counting the wrong
same-named dir silently mis-sizes the gap. When the count is over DECOMPILED code, first COLLAPSE duplicate
decompiler-pipeline trees: a project decompiled by BOTH procyon and vineflower yields ~2× the raw `.java`
files (an "easyBinding 119" was 62 distinct classes). Count DISTINCT fully-qualified class names, not raw
`.java` files.

**Sweep numeric claims are ESTIMATES until tool-counted.** The SIZING rule above governs the driver sizing
a gap; its sweep-side complement governs any number a DELEGATED sweep emits back. A sweep reporting "64
opcodes", "8 handlers", or "48 states" with no actual count has GUESSED — measured runs put those three at
256, 10, and 3. So a surfaced count that was not tool-counted MUST read as an estimate: "approximately N in
`<package/dir>`", naming the counting method it would use (`find … | wc -l`, `fd -e java`, class-name dedup)
and the scope boundary it ranges over. A bare integer presented as fact, with no method and no scope, is
the defect this rule stops — the reader cannot tell a measurement from a guess (§7).

**Verify a gap's PREMISE before sealing it.** A sweep proposes gaps from names it INFERS exist — a
`module.xml` component, a `ClassName.java`, an expected subsystem. Before a proposed gap enters the backlog,
confirm its premise against the real tree (`fd ClassName.java`, read the actual `module.xml` identity,
`[ -d ]` the dir): roughly a third of hand-inferred premises do not survive that check, and a gap sealed on
a wrong premise sends a writer to author a block that cannot be cited. This is the gap-shaping cousin of §7 —
an instrument proposing work must prove the work's subject exists.

**Shape gaps by independence AND certifiable depth — SPLIT and MERGE are one rule, not rival absolutes.**
Two retros read as contradictory — one said MERGE thin adjacent gaps, one said SPLIT independent gaps into a
parallel fan-out — but they answer one question with one discriminating test: *could this gap alone produce
a self-contained citable block at ≥substantive depth?* The honest-depth label a scout assigns each gap —
**substantive**, **short-concrete**, or **collapsible-thin** — is the input. When gaps are genuinely
INDEPENDENT and each certifies to substantive depth alone, keep them separate (and fan them out in
parallel); when gaps are ADJACENT and any one alone is only collapsible-thin, MERGE them into one work unit
that clears the depth bar together. Neither is the default — the test decides, and depth labels, not gap
count, feed it.

**Surface the uncovered BASE module for specialization-of-generic gaps.** When a proposed gap SPECIALIZES a
generic mechanism (a subclass, a concrete strategy, a themed variant), check whether the generic base is
itself covered; if not, surface the base as its own backlog gap. As a working heuristic, revise on
contradiction: a specialization documented over an undocumented base leaves the load-bearing mechanism uncited.

**Scout-before-build (certifiability, not just existence).** The pre-flight existence+size check (PROMPT-LOOP e2)
confirms a source is REACHABLE and measures how big it is — it does NOT judge whether the source is rich enough
to CERTIFY a block. For an EXTERNAL-source corpus (design/doc/web/spec) "reachable" ≠ "certifiable": a URL can
resolve, a doc can exist, and the source still carry too little primary substance to author cited `[CERT-*]`
claims. So before authoring a block from an external source, delegate a SCOUT that FETCHES + PRESERVES it (into
`sources/`, §5) and returns an explicit verdict — `CERTIFIABLE-NOW` / `PARTIAL` / `INSUFFICIENT` — and author
ONLY on `CERTIFIABLE-NOW`. It is the CERTIFIABILITY sibling of e2's existence gate, not a replacement: e2 still
runs first (does the source exist, how big), scout adds the judgment e2 omits (is it enough to certify). A
`PARTIAL`/`INSUFFICIENT` gap is re-scoped or marked blocked-on-thin-source, never handed to an authoring agent
that would pad `[INFER]`.

**Name the jar, then open it — a reachable jar is a backlog gap, not a permanent `[INFER]`.** When a claim
cannot be certified because its implementing classes live in a named, REACHABLE artifact (a jar, an apk, a
bundled archive you can point at), that is not terminal `[INFER]`: it is a decompile-me BACKLOG GAP. Name
the jar, queue opening it — extract, decompile, author the cited block from the recovered source. Only a
source genuinely absent or unreachable settles to `[INFER]`. §13 is the CANONICAL HOME for this
backlog-seeding rule; a future §5 source-citation unit should CROSS-REFERENCE this paragraph, never restate it.

**Coverage audit ≠ certainty audit.** The audit above (and PROMPT-AUDIT) checks whether existing CLAIMS
are TRUE. A **coverage audit** answers a different, recurring user question — "did we cover EVERYTHING?" —
by mapping the corpus against the code UNIVERSE, not re-verifying claims. Delegate a sweep that returns:
(a) a coverage RATIO of the mission scope and of the whole universe (e.g. ~90% of the intended subsystem,
~18% of all classes), (b) the list of subsystems/areas NOT yet touched, and (c) an honest verdict on
whether the untouched areas matter for the mission or are out of scope. Output goes under `audits/` like a
certainty audit, but its verdict feeds the §8 backlog (untouched-but-relevant areas become new gaps), not
the marker escalation. Do not conflate the two: a corpus can be 100% certain on what it covered and still
cover only 18% of the universe.

**A sweep MUST reconcile against PRIOR coverage as a named output section.** Distinct from the driver-side
PROMPT-LOOP check asking "did we already cover this?", every bootstrap or coverage sweep MUST carry an
explicit RECONCILIATION section in its OUTPUT stating, per proposed gap, whether an existing block already
covers it (skip), partially covers it (narrow the gap), or leaves it open (seed it). Without it a sweep
re-proposes work the corpus already did, and the human cannot tell a new gap from a rediscovered one. The
reconciliation is advisory output the human applies (propose-never-apply, §8), never an auto-dedup.

## 14. Cross-block consistency

The corpus self-corrects: a later block often refutes/refines an earlier one (B59→B55, B62→B17/B51,
B64→B55). Make this a habit, not an accident:

- While investigating, if you touch a fact another block asserts, CHECK it. If it's wrong, CORRECT the
  prior block transparently — keep the original text, add a note "corrected in BN" + the new citation.
  **Scoping judgments are also subject to §14 correction.** A prior block's recorded scope-out
  ("X is not load-bearing", "decompilation would add only implementation detail") is a testable
  hypothesis, not a closed door (see PROMPT-LOOP INVESTIGATE step 3 — SCOPING JUDGMENTS ARE
  HYPOTHESES). When investigation refutes that judgment, correct the prior block exactly as any
  factual claim and add the back-pointer.
- A `[CERT-hw]` finding that contradicts a `[CERT]` block MUST trigger a correction (hardware wins, §3).
- **Correction-on-absence guard.** A §14 correction that retracts or refutes a prior finding ON THE BASIS OF an absence MUST first re-verify that absence in the EXACT named artifact — never a sibling. Absence in a sibling does not prove absence in the target: B478 retracted a "no `niagarad.license.*`" claim that came from opening only `nre.jar`, not `niagarad.jar`, and the wrong correction propagated to four artifacts before revert. Because a correction propagates across the corpus, an unverified absence driving it multiplies the error; re-verify the absence in the exact named artifact, never a sibling, before issuing the correction.
- **REFUTE vs CLARIFY-SCOPE — distinguish them.** A **refute** means the prior claim was WRONG. A
  **scope-clarification** means the prior claim was RIGHT for a DIFFERENT artifact/build (e.g. a dev-tree
  vs the shipped binary, one version vs another) and only needs a scope note — NOT a refutation. Label it
  as a scope divergence ("correct for build X, this block covers build Y"), not as an error, so the prior
  block is not wrongly read as sloppy. Only call it a refute when the two describe the SAME artifact.
  The same distinction runs in the hardware→code direction — a live `[CERT-hw]` finding can scope-clarify a
  `[CERT]` static claim (the deployment gates a real code-path) without refuting it; that case lives in §12.
- In audit mode (§13), or periodically, sweep blocks on the same subsystem for contradictions.
- **Proactively scan for contradictions after computing a measurement.** The reactive rule above fires
  when you revisit a prior claim. Add the proactive complement: after computing a measurement over a
  population, search the corpus for prior measurements of the SAME population and verify they agree. If
  they do not, issue a §14 correction — do not leave both figures standing unremarked. Use both together:
  the reactive rule fires when you revisit a claim; the periodic sweep (above) fires by subsystem on a
  schedule; this rule fires at the moment a measurement is computed — triggered by the act of computing,
  not by a later audit or encounter.
- **When a conflict CANNOT yet be adjudicated**, do NOT force it into a premature `[INFER]` or drop it:
  record it in the corpus `CONTRADICTIONS.md` as `open` (source A says X, source B says Y). It is surfaced
  by `research-sdd-status.sh` (open count in the status report) so it is not forgotten at STOP, and resolved
  later per this section — the winning side then corrects the losing block and the row flips to `resolved`.
- Every correction is logged in the correcting block's Connections and in RESEARCH-STATE's history.
- **A deterministic error produces evidence indistinguishable from a law of the system.** Accumulating
  concordant observations does NOT distinguish a systematic bug from a real pattern — the concordances are
  an artifact of the same mechanism that produced the error. The only test is a NEW PREDICTION about cases
  the prior observations did NOT cover, and verifying whether it fails. Before documenting a regular
  mapping, transformation, or renumbering scheme as a site finding, derive a prediction that would only
  hold if the pattern is real and test it against fresh cases that were NOT part of the training sample.
  If the prediction fails, the apparent regularity was the defect. (Worked example: a job→live network
  mapping with 184 concordant observations and consistent per-family offsets — all derived from a
  `[byte] -shl 8` overflow that produced 0 for every input > 255; refuted when 383 predicted routes
  failed to route.)
- **Contrast, not translator, for derived mappings.** When a tool derives a mapping between two
  representations of the same object (job-network IDs vs live-bus IDs; config-file values vs on-disk
  state), design it to EXPOSE divergences rather than reconcile them silently. A translator makes the
  data consistent; a contrast makes divergences visible. A divergence that a translator would "correct"
  may be a real site fact — a renumbered trunk, a partial migration, a retired device never updated in
  the job file — that a translator would permanently hide.

## 15. Corpus versioning (git)

Each target's corpus is a git repo (the engine kit lives separately in sdd-investigacion). Bootstrap
runs `git init` in the TARGET so that self-corrections (§14) have history and the corpus is shareable.
On an existing un-versioned corpus, init it once. NOTE: git-init goes in the **target project**, never
in the kit.

**Scope commits to the corpus — gitignore orchestrator-local artifacts.** A research commit must contain
ONLY corpus files (blocks, RESEARCH-STATE, CATALOG/INDEX, sources/, tools/). Orchestrator-local state that
is NOT part of the corpus — `.atl/` skill-registry caches, `.claude/` local settings, editor/tool caches —
must be gitignored. BOOTSTRAP seeds the target `.gitignore` with at least `.atl/` and `.claude/`; on an
existing corpus, add them if missing. (Lesson: niagara accidentally committed `.atl/.skill-registry.cache.json`
twice via `git add -A` before it was ignored — a fingerprint-only churn with no corpus value.) Prefer
explicit `git add <files>` over `git add -A`, but the `.gitignore` is the durable fix, not the manual habit.

**When the corpus dir IS the subject dir.** Some targets are researched IN PLACE — the corpus lives in the
same directory as the subject's OWN material (e.g. a prototype repo you are also documenting). Then
gitignoring orchestrator-local caches is not enough: the SUBJECT's own files (its `.html`, build output,
assets) share the dir and must NOT be swept into the corpus history either. Add them to the target
`.gitignore` explicitly (or keep the corpus in a subdir) — do not rely on `git add <file>` discipline alone,
which is one `git add -A` away from committing the whole subject. The structural guard, not operator habit,
is the fix. (Lesson: three.js's corpus sat alongside 23 subject `.html` files kept out only by hand.)

**Corpus root (`$CORPUS`) — the structural guard, named.** Define `$CORPUS` = the corpus root. Default
`$CORPUS = $TARGET`. When the target is an IN-PROJECT corpus (its dir also holds its OWN non-corpus subject
material — app files, prototypes), set `$CORPUS = $TARGET/corpus/` so a flat corpus does not drown the
project root. The ENTIRE flat corpus lives under `$CORPUS`: blocks (`$CORPUS/<prefix>-blockN.md`, still with
the focus-aware prefix of §16 for a readable `ls`), INDEX.md, CATALOG.md, RESEARCH-STATE.md, HANDBOOK.md,
`sources/`. NO extra `blocks/` subdir — blocks sit directly in `$CORPUS`. EXCEPTION: `retros/` stay at the
TARGET root (`$TARGET/retros/`), NOT under `$CORPUS`, because `toolbelt/sweep-retros.sh` scans `$target/retros`
(§18) — moving them would blind the sweep. Precedent (the model to copy): `pruebas-dashboards` uses exactly
this layout — `corpus/dashboard-block*.md`, `corpus/INDEX.md`, `corpus/sources/`, root `retros/`. Use the
name `corpus/` (not `research/`). The loop HANDS the linters the resolved `$CORPUS` (PROMPT-LOOP step 7), so
they lint the corpus wherever it sits; `verify-state.sh` additionally auto-anchors on the blocks
(`find -maxdepth 3`). RULE: never hardcode the target root into a linter — resolve or receive `$CORPUS`, else a
nested corpus FALSE-PASSes (the §5 gap that bit `verify-sources.sh`).

**Parity gate for a shipped derived deliverable.** An in-project corpus sometimes also SHIPS a derived
deliverable that COPIES load-bearing values out of a certified block (e.g. hex tokens in `prototypes/*/tokens.css`
lifted from a certified design-token block). That copy can silently DRIFT from the block it derives from, and the
three standing gates do NOT cover this axis: `verify-block.sh` checks a block's OWN marker/citation math (§11),
`verify-sources.sh` the source registry (§5), `verify-state.sh` the living mirror (§8) — none checks
deliverable↔block PARITY. For that, run [`toolbelt/verify-parity.sh`](toolbelt/verify-parity.sh)
`<deliverable> <block(s)>`: a subset-check that every load-bearing value the deliverable copies still EXISTS in
the certified block it derives from, FAILing on drift. Run it whenever the corpus ships such a deliverable — the
other three gates passing does not imply the deliverable is in parity with its source block.

**Fleet mirror (master registry vs reality).** `verify-state.sh` lints the mirror INSIDE one corpus; the
master `TARGETS.md` registry drifts on a different axis — its per-target `N md` claim vs the real block
count across the whole fleet (e.g. the three.js row claimed 40 md while the corpus held 44). `research-sdd-archive.sh`
only PRINTS an unverified "refresh the row" reminder and is corpus-scoped (it never edits the kit), so
[`toolbelt/verify-registry.sh`](toolbelt/verify-registry.sh) mechanizes the reconcile: per resolvable row it
recomputes the block count from disk with the SAME canonical discriminator and WARNs on drift beyond a small
tolerance — WARN-only, read-only, exit 0 always (propose-never-apply; it never rewrites a count), surfaced at
session start next to the retro/audit sweeps.

**Commit message convention.** Corpus commits use `research(<target>): B<n> <short-gap-slug>` — the block number
and a terse slug for the gap it closed (multi-focus §16 disambiguates in the scope: `research(<target>/<focus>):
B<n> <slug>`). An OPTIONAL body line carries the coverage ratio + marker tally at that block (e.g.
`coverage 34/38 · [CERT] 21 · [INFER] 6`). Commit DIRECT to the default branch — a solo corpus needs NO PR
(contrast §18's KIT changes, which land on a branch/PR because a retro mutates the shared method prose that
every target depends on and so needs review; a single-author corpus is history for its own author and does
not). One-block-per-commit is already the rule (PROMPT-LOOP one-block-per-commit) and is LOAD-BEARING for §17
resume: after a kill/crash, `git log --oneline` maps one commit ⇄ one block, so "did B<n> land?" is answerable
at a glance. Never fold two blocks into one commit.

**Remote (private-by-construction).** A target MAY have a GitHub remote, but a corpus DECOMPILES proprietary
systems, so the remote must be **private by construction, never by convention**. Create it ONLY via
[`toolbelt/ensure-remote.sh`](toolbelt/ensure-remote.sh) `<target> --yes`: the wrapper hard-codes `--private`
on the single `gh repo create` (there is no public code path), refuses an organization owner, is CONSENT-gated
(`--yes` / `RSDD_ALLOW_REMOTE=1` — network mutation is never implicit), runs `scan-secrets.sh` as a PRE-PUSH
gate and refuses on a high-confidence CONTENT hit, separately refuses if any secret-type FILE (keys, certs,
keystores — the binary types `scan-secrets.sh` never opens) is git-tracked, and VERIFIES visibility read back
as PRIVATE before it pushes a single commit (hard-aborting and removing the origin otherwise). The content
scan covers the working tree only; for a high-sensitivity target, audit or squash history before the first
push (`scan-secrets.sh` does not walk deleted history). It is idempotent (an existing `origin`
short-circuits) and is NEVER auto-invoked by the loop — the operator runs it once, per target, on consent. A
corpus remote is NEVER public.

## 16. Multi-focus corpus (parallel focuses under one target)

A small target is a single axis. A **mature or large** target often has several distinct subjects worth
investigating in parallel — niagara ended up with three: `Spyder`, `OptimizerSupervisor`, and
`platform-native`. Formalize this instead of spawning ad-hoc state files:

- **One RESEARCH-STATE per focus.** Each focus gets its own `RESEARCH-STATE-<focus>.md` under `$CORPUS` (its own
  coverage ratio + gap backlog). Pick a short, stable `<focus>` slug (the angle from PROMPT-LOOP §b2).
- **A focus index.** Keep a small `FOCUSES.md` at the corpus root `$CORPUS` (or a top "## Focuses" section in
  `INDEX.md`) listing each focus, its status, its `RESEARCH-STATE-<focus>.md`, and its block prefix. This is how
  the loop (and a human) knows which focuses exist and which is current.
  A **planned** focus is one whose RESEARCH-STATE + backlog are already committed but which has 0 blocks yet;
  because it is already initialized, the loop must NOT re-BOOTSTRAP it as a duplicate — it picks up the
  existing state and writes its first block.
- **Focus-status cell grammar (closed vocabulary, §8b style).** The status cell is read by its LEADING token,
  after stripping at most one leading `**`; everything after the token is free decoration (a parenthetical
  ratio such as `stopped (12/12; +B556)` is the convention). Legal tokens:

  | Token | Meaning |
  |---|---|
  | `active` | the loop is currently writing blocks for this focus |
  | `paused` | halted on the budget cap or by the operator with investigable gaps still queued (§8 PAUSED ≠ STOPPED) |
  | `stopped` | read-only-investigable = 0 declared; reopen per §8 |
  | `planned` | state + backlog committed, 0 blocks yet |
  | `bootstrapping` | BOOTSTRAP in progress — state file may be incomplete |
  | `reopened` | a STOPPED focus re-armed for a bounded experiment or grade-upgrade (§8) |
  | `document` | a §20 document-mode focus (outline-driven, no gap backlog) |

  `closed` is NOT a token — write `stopped`. Regional variants (`reabierto`) are non-conforming — write the
  token. No checker reads this cell yet (a WARN-only FOCUSES↔RESEARCH-STATE drift sweep is a wave-2 kit unit);
  when one exists it MUST read the token only, WARN by row on anything else, and never guess
  (propose-never-apply: migrating an existing row is the operator's edit). Why closed: the live niagara index carried four prescribed
  words plus `CLOSED (13/13; …)`, `document 4/4`, `reabierto (18/31)` and ≥12 parenthetical shapes, and a row
  saying `planned (0/8)` while its state file said `stopped (12/12)` nearly cost a heavy re-derivation loop; a
  cell no instrument can read cannot be checked for that drift (TARGETS.md maturity cell, retro delta
  declaration and the block `Type` field all failed the same way — doctrine before checker).
- **Focus status in a remittance note is a verifiable claim.** Before writing "closed by remittance to focus X
  (stopped)" or handing off to "the next queued focus", confirm the status from `FOCUSES.md` AND the focus's
  own `RESEARCH-STATE-<focus>.md` header; when they disagree, the state file wins and the index row is a drift
  finding to surface.
- **Naming convention.** Blocks carry a focus-aware prefix (e.g. `spyder-blockN.md`,
  `platform-native-blockN.md`) so a flat `ls` stays readable; state mirrors them as
  `RESEARCH-STATE-<focus>.md`.
- **State the active focus** when continuing the loop, and confirm the angle (§b2) before opening a new
  focus — a new focus is a new bootstrap, so it deserves the same angle confirmation.
- **One engram project, focus in the topic key.** All focuses mirror under the same target project
  (§7); disambiguate with `research/<target>/<focus>/...` topic keys.
- **Keep the PARENT's block count live, every child-focus iteration.** When a parent `RESEARCH-STATE.md`
  carries a "Covered blocks: N on disk" line above the focuses, REFRESH it at EVERY iteration of an active
  child focus — not only at focus-open and focus-close. A parent touched only at focus boundaries
  under-reports corpus size for the whole run in between (one parent claimed 18 while the corpus grew to 23
  — undercounting by up to 5 blocks across 5 consecutive child iterations). If you would rather not touch it
  per iteration, declare it explicitly a focus-boundary-only field and have the tooling read the TRUE on-disk
  block count in between rather than trusting the stale parent line.

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
- **Global block-number allocation under `shared-global`.** When focuses share one corpus-wide block prefix
  (§7 `block_scope: shared-global`), the block NUMBER is a shared resource and two concurrent lanes will
  collide on it (observed: two same-day retros both self-numbered "(3/3)"; a `gen-catalog.py` regeneration
  picked up a peer's untracked B725). Rule: before writing a block, a lane CLAIMS the next number through ONE
  allocation channel — a message to the lane that owns numbering for this run, or, when no owner is live, a
  committed `<!-- next-block: N -->` marker at the top of `CATALOG.md` that the claimant advances in the same
  commit — and waits for the confirmation (or the commit) before using it. A claimed number is never reused,
  even if the block is abandoned (record the abandonment in the state file). A block written without a
  confirmed claim is PROVISIONAL: do not cite it by number, do not regenerate the catalog over it. Per-focus
  layouts (`<focus>-block<N>.md`) do not need this — their numbering spaces are disjoint by construction.
- **A peer-owned dirty tree is a hard read-only boundary; one checkout is never shared for writes.** A lane
  never runs `git checkout`, `git stash`, `git reset`, `git pull --rebase` on a shared tree, or a catalog /
  index regeneration over files another live lane is writing (`git checkout` is a whole-tree operation: a
  peer's branch switch discarded uncommitted work twice in one kit-maintenance session — kit CLAUDE.md §3).
  Each concurrent lane writes in its OWN worktree (or its own clone) and integrates through commits; a
  cross-lane action over the shared tree waits on the BARRIER above. Reading a peer's untracked or uncommitted
  file is allowed only as evidence marked as such (`[INFER]` until the peer commits) — never as a citation
  target by number.

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
very long single focus, it MAY also fire every ~10 blocks so lessons don't wait until the end. Also fires:
(a) proactively, whenever a run yields a REUSABLE METHOD or hits a REPEATED FRICTION — do not wait for STOP
or operator intervention; (b) at §20 document-mode completion; (c) at session close.

**It also fires for sessions that wrote no block.** An APPLIED / build-along session (the operator builds or deploys
with the corpus as the guide) and a POST-CLOSE ADDENDUM (new evidence lands on a focus already STOPPED) both
produce lessons the focus-STOP trigger above never sees — ~10 of 30 recent retros described exactly such sessions
and were written only because the operator asked. Treat "the session changed how the next one should run" as the
trigger, not "a focus stopped".

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

   **The delta declaration is machine-countable, and that is MANDATORY.** Deltas go under the canonical heading
   `## Proposed kit deltas` as the template's table, one row per delta (or `### D1 —` entries under that heading).
   The sweeper accepts, and nothing else, these enumerated aliases: today `## Proposed deltas`, `## Delta proposals`,
   `## Deltas nuevos` and a numbered `## N. Proposed kit deltas` (`sweep-retros.sh`); kit unit U7 adds the forms
   measured in real retros — `## Summary of proposed deltas`, `## Summary of new deltas proposed`, `## Delta details`
   and the numbered heading with a trailing parenthetical. Deltas declared only as inline `→ PROPOSED …` prose, or under any other heading,
   are INVISIBLE to supervision: measured on 74 niagara retros, 62 distinct delta headings were in use, 20 of 78
   pending retros were uncountable, and 4 returned a confident `~0` that was false in all 4 cases. A retro with no
   canonical delta section is unreviewable until its author fixes the heading — the honesty clause below covers
   "no new deltas", not a missing section. **Instrument status:** until kit unit U7 lands, `sweep-retros.sh` can
   still print a confident `~0 proposed deltas` on a retro whose deltas live in prose; U7 makes it print
   "no delta section found" instead and never a confident zero.

**Hard boundary — propose, never apply.** The retro agent does NOT edit the kit. Kit changes are reviewed and
committed by a human (the kit is a separate repo, `sdd-investigacion`; the human leads, the engine proposes).
This preserves both the audit trail and the rule that the operator — not an autonomous agent — owns the method.

**Honesty clause.** A run that surfaces nothing new must SAY so ("no new deltas; the kit already covers this
run") rather than inventing improvements to look productive. A retro that always finds something is not a retro,
it is noise.

**Review lifecycle — nothing sits unreviewed.** A retro is generated by a target run but ACTED ON by the kit
maintainer (a human), and the two are decoupled in time — so proposals must not get lost between them. Every
retro carries a top marker `<!-- review-status: pending -->` (the template seeds it). When the maintainer has
applied or dismissed its deltas, they flip it to `applied`/`dismissed` (with date + the kit commit sha). The
sweeper [`toolbelt/sweep-retros.sh`](toolbelt/sweep-retros.sh) reads TARGETS.md, scans every target's
`retros/`, and lists the ones still `pending` — run it manually or on a schedule so a finished run's proposals
are always surfaced, even when nobody remembered to bring them. This closes the self-improvement loop:
§18 GENERATES proposals autonomously; the sweeper ROUTES them; the human REVIEWS and applies (propose-never-apply).

**Review-status vocabulary (two words, not three).** The only status words that close a retro are `applied`
and `dismissed`. `pending` and empty are treated identically — unreviewed. Any other word — a typo, an
experiment (`accepted`, `reviewed`, `done`) — is treated as pending AND the sweeper emits a visible `WARN` so
the anomaly is never silent: a retro annotated with an unrecognized word would otherwise disappear from the
pending queue without anyone acting on it. The vocabulary is kept to two words deliberately: more words → more
code paths that silently interpret a status as "closed" → more ways for a proposal to evaporate unreviewed. If
`applied` and `dismissed` feel too blunt for a given workflow, annotate the retro's body — do not widen the
machine-readable marker. A **partially-applied** review — some deltas shipped, others deferred or kept
staged — is the canonical case for this hatch: close the marker with `applied` and record the split in the
body (e.g. `applied · <sha> · PARTIAL — shipped: D2-D5; DEFERRED: D1`), as existing retros already do. A
dedicated `partial`/`staged` closing word is deliberately NOT added (issue #134): it would be one more code
path that could read a retro as closed while its deferred deltas evaporate — the exact failure this two-word
vocabulary exists to prevent — and every observed partial case is already legible via the body annotation.

**Scope marker (opt-out) — `kit-retro: exclude`.** The sweeper walks retros recursively
(`find … -maxdepth 4 -path '*/retros/*.md'`), so a `retros/` directory nested inside a corpus
(e.g. `$TARGET/corpus/retros/`) is reached too. When a file in such a directory is NOT a §18 kit
self-retrospective — e.g. a client-feedback retro whose deltas target a separate skill's
`references/` files — it must carry `<!-- kit-retro: exclude -->` in its leading HTML-comment block.
`sweep-retros.sh` (pending pass and MISSING-RETRO fleet pass) silently skips such files;
`stage-retro.sh` refuses them with exit 2. `research-sdd-archive.sh` also filters excluded
retros from both the `retros:` mirror-fact count and the MISSING-RETRO detector.
Design: OPT-OUT (not opt-in). An opt-in marker would fail silently — a genuine §18 retro missing the
marker becomes invisible to supervision, the exact failure mode this loop exists to eliminate. An
opt-out marker fails noisily — an un-marked non-§18 file surfaces as a false-positive PENDING item,
visible and self-correcting. For a supervision instrument, noisy beats silent.

**Concurrency & the supervisor branch/PR model.** Multiple targets can run at once WITHOUT colliding: each run
writes only its OWN `<target>/retros/` and engram `research/<target>/retro`, and NONE touch the kit (propose-only).
The kit (`sdd-investigacion`) is the single SUPERVISOR, touched only by the maintainer. To keep multi-source
proposals from landing on `main` unreviewed, retro-sourced deltas go through a branch/PR, not a direct commit:
[`toolbelt/stage-retro.sh <retro>`](toolbelt/stage-retro.sh) creates a `retro/<target>-<date>` branch off main,
where the supervisor applies only the ACCEPTED deltas, then opens a PR. The PR is where the supervisor judges the
three things that matter across concurrent proposals — does it CONFLICT with main, does it DUPLICATE another open
retro PR, is it even NECESSARY — before merge (=applied) or close (=dismissed). Each proposal isolated on its own
branch means N concurrent targets never collapse into one another; they queue as N reviewable PRs. (Direct
maintainer edits — interactive kit work, not sourced from a target retro — may still go to main; the branch/PR
gate is specifically for retro-sourced deltas arriving from target runs.) **Traceability backlink (convention).**
The applying kit commit MUST carry a `Retro: <target>/retros/<file>@<target-sha>` trailer (`stage-retro.sh`
suggests it in its commit line) — the reverse of the retro's own forward `applied … · kit <sha>` marker — so
"why does this kit rule exist" is traceable in both directions: kit commit → source retro, and retro → kit sha.

**Apply and close are the SAME work unit.** Applying a retro delta and flipping the retro's
`review-status` marker to `applied` are one atomic action, not two tasks where the second is optional.
The cost of separating them: commits `9db7a02`, `1771839`, and `8e22f73` applied deltas from five
different retros without touching a single marker. The sweep over-reported those five retros as fully
open from that point, inflating the pending count by roughly 20 % of the headline at the time of
discovery. The mechanism is not historical — any future commit that applies a delta without closing its
retro immediately re-opens the same gap. **Rule:** when a commit applies one or more deltas from a
retro, flip or update the marker in that same commit (or at the latest the same session). Use
`applied + PARTIAL` if only some deltas were accepted (see PARTIAL-application state below). A marker
left unflipped means the retro reads as open work — the sweep will report it as pending, its delta
count will inflate the headline, and the next maintainer will waste time reconstructing what was already
done.

**MISSING-RETRO detector.** A run that closed WITHOUT producing a fresh retro loses that run's feedback
silently — nobody notices until much later, if ever. `research-sdd-archive.sh` checks this at close time
(comparing the newest block's git-added date against the newest retro's) and prints an advisory WARN when
the corpus advanced past its newest retro; [`toolbelt/sweep-retros.sh`](toolbelt/sweep-retros.sh) runs the
same check across the whole fleet, surfacing a `MISSING-RETRO: <target> advanced with no retro for the
latest run` line for every target that needs one. Like the rest of this section, it is surface-only
(propose-never-apply) — it flags the gap for a human to act on, it never generates a retro itself.

**MISSING-RETRO grace window (sweep only).** When blocks and their retro arrive in the same session — the
retro committed minutes after the last block — the fleet sweeper can falsely flag the corpus as neglected
before the retro is even in the index. `RSDD_MISSING_RETRO_GRACE_HOURS` (default `24`, overridable via env)
gives `sweep-retros.sh` an in-flight tolerance: MISSING-RETRO is suppressed while the newest block's
committed timestamp is YOUNGER than `grace_hours × 3600` seconds from NOW. The implemented condition is
`nb > nr && now > nb + grace_secs` — the alert requires both that the corpus genuinely advanced past the
newest retro (`nb > nr`) AND that the block has been idle long enough to rule out an in-flight retro
(`now > nb + grace_secs`). Suppression is a DEFERRAL, not a forgiveness: once the window expires the alert
surfaces and stays visible until a retro lands. The rejected alternative form `nb > nr + grace_secs` would
have granted permanent amnesty to any block that landed within `grace_secs` of the retro epoch, silencing
the alert forever even years later — that is why it was rejected.

The archive-time detector in `research-sdd-archive.sh` deliberately carries NO grace window. The asymmetry is
intentional: archive runs at the moment of human close — that IS the end of the in-flight period, so
in-flight tolerance is a category error there. A grace window in the archive would suppress the warning on
essentially every real close (the block was just committed), making the instrument quieter than it was before
the window existed. The archive's governing principle is "noisy beats silent"; at close time the right
behaviour is to be loud, not to defer. Any inconsistency between a swept MISSING-RETRO and a silent archive
close would be confusing; the deliberate choice here is to make them asymmetric by design, not by accident.

**Retro-waived convention.** Some targets run exploratory or throwaway sessions where a formal §18 retro
would produce no useful delta — the run's every lesson is already encoded from a prior run, or the run was
a deliberate dead end. Waiving the retro is a DELIBERATE documented decision, not an omission. To record it:
create a file under `<target>/retros/` (conventionally `retro-waived.md`) that carries BOTH
`<!-- kit-retro: exclude -->` (so the sweeper does not count it as a pending §18 retro) AND
`<!-- retro-waived: <date> · <reason> -->` in its leading HTML-comment block. The sweeper's MISSING-RETRO
fleet pass recognizes the second marker, suppresses the `MISSING-RETRO` line for that target, and adds a
`waived: N target(s)` line to the sweep summary — so the suppression is never invisible. Design: OPT-OUT,
same reasoning as `kit-retro: exclude`. A missing waiver means the target is supervised by default; deleting
the waiver file makes MISSING-RETRO reappear automatically and self-correctively.

**Aging / escalation.** A pending retro that sits unreviewed too long is as bad as one that never gets
written. `sweep-retros.sh` sorts the pending queue oldest-first by each retro's git-added date and tags any
retro older than `RSDD_RETRO_AGE_DAYS` (default 7, overridable via env) as `ESCALATED (aged Nd)`, so the
stalest proposals lead the list instead of hiding at the bottom. The same aging/escalation logic mirrors to
audits via [`toolbelt/sweep-audits.sh`](toolbelt/sweep-audits.sh) (§13). Again, this only sorts and labels
for the human — propose-never-apply.

**Escalation with teeth.** Labeling a retro `ESCALATED` without consequence turns the sweeper into a noise
machine — the same stale items appear on every sweep until the list becomes wallpaper. The rule: when the
sweep shows ANY `ESCALATED` item, the maintainer's NEXT kit session MUST begin by resolving those items
(apply or dismiss) before opening new retro work. If no deltas in the proposal still apply, dismissal is
correct and takes thirty seconds; bulk-dismissal of an aged LOW-priority backlog is explicitly BLESSED.
A dismissed retro is not erased — it stays in the closed record with its full rationale and the list of
considered-but-rejected deltas intact, so bulk-dismissal costs no audit trail. The tradeoff mirrors the
scope-marker design: opt-out fails noisily when absent (the item stays visible and self-corrects) rather
than silently; an agent that treats dismissal as data loss and resists it has misread the design — dismissal
is a deliberate, recorded close, not a deletion.
A propose-only system that accumulates proposals indefinitely without clearing them is not a supervision loop
— it is a backlog with no drain, and its output will be ignored. The corollary: do not let aged retros guilt
the maintainer into applying stale or overtaken proposals. Apply when genuinely valuable, dismiss fast when
not — both are valid resolutions that keep the loop healthy.

**PARTIAL-application state.** A retro may contain ten proposed deltas but only three are accepted on a
given review pass — the remaining seven are deferred, not permanently rejected. To record this without
blocking the applied/dismissed vocabulary or leaving the retro fully pending: set the review-status to
`applied + PARTIAL — <date> · kit <sha>` and add a freeform `DEFERRED backlog:` annotation in the retro's
body listing the remaining items with a brief note on why they were deferred (superseded, needs more data,
lower priority than current work). The sweeper extracts the first run of letters (`[a-z]+`, case-insensitive) after `review-status:` and matches it exactly against `applied` or `dismissed` — the resolved portion exits the pending queue. The prescribed `applied + PARTIAL` form works because the token boundary falls at the space after `applied`; a variant like `partial-applied-<date>` would extract `partial` instead, remain unrecognized as a closing word, and leave the retro PENDING. The deferred portion stays visible as a body annotation: the next
retro writer for that target reads prior retros before proposing (deduplication step) and can re-raise still-
relevant items, and the maintainer can track them as follow-up tasks. This avoids both failure modes: the
pessimistic one ("nothing applied until all ten are agreed") and the optimistic one (`applied` with deferred
items silently dropped and forgotten).

**Tools section.** The retro template ([`templates/retro.template.md`](templates/retro.template.md)) includes
a TOOLS section that records every tool a run built, forked, or abandoned — the route back into the kit that
the phantom "LEARNINGS ledger" never was. Each entry carries a VERDICT. The supervisor acts on each verdict
on the retro branch: `promote` means the tool moves into `$KIT/toolbelt/` with a companion test under
`toolbelt/tests/*.test.sh` (the kit's convention — every toolbelt script has one); `absorb` becomes an
ordinary delta row against the named kit file and enters the standard retro-delta review cycle. `keep-local`
and `no` close an entry and are recorded in the retro, but they differ in what to do with the tool after:

- **`keep-local`** — the tool is real, works, and is worth keeping, but it is target-specific (tightly
  coupled to one binary format, corpus shape, or environment) and cannot be promoted without a generalisation
  effort that is out of scope now. **Keep it in the target**; do not copy or delete it. Note what would need
  to change for promotion so a future retro can revisit the question with fresh context.

- **`no`** — the tool is not worth keeping anywhere: it is a throwaway one-liner written during probing, is
  already superseded by the block's findings, or duplicates an existing kit tool without adding value.
  **Remove or ignore it**; no action is taken in the kit or the target.

The template's worked-example rows T3 and T4 illustrate each verdict with a concrete case so the boundary
is visible from the template alone without opening METHODOLOGY.

An ORACLE finding — a tool that can SEE whether a result is correct rather than recompute it — is the
highest-value promotion candidate and always warrants an explicit verdict, even when the run did not
explicitly flag it.

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
- **Mark open build gaps in the backlog.** An OPEN `requires-execution` gap SHOULD be a Gap-backlog row
  whose Status column carries `requires-execution` (e.g. `requires-execution → §19`, as three.js's G41
  does). That marker is what lets `verify-state.sh` derive the open count from disk and gate the premature
  build-STOP hazard BY CONSTRUCTION — an envelope declaring `requires_execution_open: 0` while marked-open
  rows remain is a hard FAIL, the exact analog of the read-only investigable gate. A build gap tracked only
  in `## Stop control` prose is still valid (logosoft closed its whole build loop that way), but it is not
  machine-gated — the linter cannot see what the backlog does not mark.
- **Artifacts in `codegen/`.** PoC source, build output, and captured round-trip diffs live under
  `$CORPUS/codegen/` and are preserved as evidence (a diff is `[CERT]` evidence like a probe capture).
  The block cites them; the code is not the deliverable, the validated finding is.
- **Handoff from the static loop.** When the static loop's TERMINAL TRIGGER (§8) sees remaining
  `requires-execution` gaps, it hands off here — this is the "non-static phase" it names. Provisioning a
  compiler/runtime follows §10.
- **Out-of-tree APPLIED deliverable (path + SHA identity, external QA as the oracle).** When a
  `requires-execution` gap's deliverable lands OUTSIDE `$TARGET` — a skill, a plugin, an installed tool — the
  round-trip byte-diff above does not apply (a skill has no "original bytes" to diff). Instead: (a) the corpus
  references the deliverable BY PATH + SHA-IDENTITY (a manifest hash of the file set — e.g. sha256 of the
  sorted per-file sha256s, first 16 hex), NEVER by copying it in; (b) an EXTERNAL adversarial QA protocol
  serves as the §19 oracle — a blind dual review (Judgment Day: independent judges, frozen ledger, bounded fix
  rounds, terminal verdict) PLUS a real consumer run replace the byte-diff; (c) the FULL protocol evidence
  (ledger, fix log, consumer phase log, artifacts/screenshots) is preserved under
  `$CORPUS/sources/probes/<name>/` and cited `[CERT-hw]` from the closing block section. §19's `codegen/`
  round-trip and this out-of-tree pattern are siblings: pick by whether the deliverable has bytes to diff.
- **A fix batch is a NEW change surface — re-check the fix delta adversarially.** In a build/QA phase, a batch
  of fixes does NOT inherit §11's trust-the-self-report contract (§11 Scope). Each fix closed by its own
  directed test that PASSED is NOT sufficient evidence: re-check the FIX DELTA with a scoped adversarial pass
  (a scoped re-judgment) BEFORE the terminal verdict. This is not ceremony — a round of fixes, each with a
  green directed test, has introduced 2 NEW CRITICAL defects that only the scoped re-judgment on the delta
  caught. The fixer's own tests certify the fix they aimed at, not the new surface the fix created.
- **Consumer-run-before-review.** Before adversarially reviewing an applied deliverable, RUN A REAL CONSUMER
  first — a fresh agent USING the deliverable as intended (not inspecting it) — and feed its friction findings
  to the reviewers as SEED claims. A review seeded by real usage friction finds spec-gap defects that blind
  code reading misses: a consumer forced to improvise undocumented fallbacks or invent unstated precedence
  surfaces exactly those gaps, which then land verbatim as confirmed review defects.
- **Reimplement, do not relink.** A §19 deliverable derived from decompiled proprietary code must REIMPLEMENT
  the mechanism (ideally against the public standard the vendor implements), never load, link against, or
  redistribute vendor binaries. State the boundary in the deliverable's own header so the distinction
  survives without the corpus. Where the mechanism IS a public standard, cite the standard, not the
  decompilation, as the implementation's authority.
- **A reimplementation is not done at its first correct result.** When a §19 deliverable reimplements a
  mechanism learned from decompilation, the vendor's BATCHING and CACHING are part of the mechanism, not an
  optimisation to add later: round-trip count, request batching, per-peer sizing, and persisted discovery
  caches are usually visible in the same decompiled source as the sequence. Record a MEASURED cost (time,
  round trips) for the deliverable and compare it against what the vendor's own implementation would issue.
  An order-of-magnitude gap means the sequence was copied and the engineering was not.
  - **Corollary — copying a vendor parameter requires copying its operating context.** A timeout designed
    for continuous polling on a loaded bus is wrong for a one-shot census on an idle bus, even when the
    protocol is identical. Before adopting a vendor parameter, state the conditions it was designed for and
    confirm they match the intended use. If they do not, measure the appropriate value for the actual context
    rather than inheriting the vendor's. (Worked example: a 24 s timeout correct for continuous-poll mode →
    1 device recovered in a one-shot census, 24× slower — the operating conditions differed.)
- **External oracle for visual/geometric deliverables (the §12 principle at build phase).** §12 requires
  validating every write through an INDEPENDENT channel, not the one you wrote on — a write confirmed only
  by its own channel is `[INFER]`, never `[CERT-hw]`. The same discipline applies when the deliverable has
  a visual or geometric form. A validation script authored from the same corpus and assumptions as the build
  re-checks the builder's model of the deliverable, not the result itself — a render always *looks* like
  something, so a same-corpus check reads as evidence even when no independent channel confirmed it. To
  close: verify through an external oracle not derived from the build pipeline. **What counts:** rendering
  the output through an INDEPENDENT viewer (not the code that produced it) and comparing against the source
  artifact; a measurement taken outside the build pipeline (e.g. an independent CAD/DXF renderer checking
  geometry against the source drawing); or a documented human visual comparison against the source artifact,
  preserved under `sources/probes/` and cited `[CERT-hw]`. **What does NOT count:** a validation script
  authored from the same corpus or by the same agent that built the deliverable; a check that reads from the
  build's own output data rather than the rendered or displayed result. Marker consequence: confirmed through
  an external oracle → `[CERT-hw]`; confirmed only by a same-corpus script → `[INFER]`. (Evidence:
  nave-panccadia B7–B9 — three consecutive defects past a 16/16–25/25 green gate, each caught only by the
  operator looking at the render, not by any gate check.)

- **Deterministic camera-position hook (precondition for reproducible §19 QA captures).** For browser-rendered 3D deliverables, expose a deterministic camera-position hook at build time (e.g. `window.__cam = {position, target}` settable before the render loop starts) and drive it from the QA driver (e.g. a `--cam <name>` CLI flag that selects from a named set of positions). Name and document the positions used in the QA session alongside the captures under `sources/probes/` so a future run replicates the same angles. A random-orbit QA pass is non-reproducible and spends most captures on uninformative views; a named-position set makes each capture a deliberate, re-runnable measurement. The hook costs one build-time feature; absent it, a QA agent orbiting by click will waste half its budget finding useful angles before any meaningful capture is possible. This is a precondition for the external-oracle captures above to constitute evidence rather than orbit-lottery. (Evidence: nave-panccadia B38–B39 QA session — blind-orbit wasted roughly half captures on uninformative angles; `window.__cam` + `--cam <name>` Playwright CLI flag resolved this.)

- **Regenerate and token-check before any visual judgment pass.** Before capturing screenshots or computing pixel diffs on a §19 build deliverable, regenerate the artifact fresh from the current source and confirm the fix token is present in the served bytes (`rg <new-token> <served.html>` or equivalent). An artifact whose filename does not change between builds is indistinguishable from a stale one without checking its content — a stale artifact absorbs the visual comparison and the fix is declared failing when it was never tested. This is the §11 "Verify the edit landed" discipline applied to build artifacts: it is a prerequisite for the visual pass, not a verification step, and must run before screenshots are captured or pixel diffs are computed. (Evidence: nave-panccadia B38 — the v8 HTML was generated BEFORE the v8 code changes; `rg nominal_width` returned zero hits in the served file; the fix was never served, never evaluated.)
- **Pixel-diff attribution requires an isolated control.** A pixel diff proves THAT something changed, not WHAT changed it. Before attributing a rendered-image delta to a specific cause, ISOLATE the variable: compare the candidate build against a no-op/without-the-change build that is otherwise identical. Without an isolated control, a pixel diff is correlation, not attribution — other simultaneous variables (dependency version, renderer state, font loading) can produce the same diff. Distinct from the regenerate-and-token-check rule above (which proves the browser received new bytes) and from the external-oracle rule (which verifies the result through an independent channel): this rule is about not asserting a CAUSE for a visual change without eliminating competing causes. (Evidence: nave-panccadia v9 build retro, `retros/2026-08-05-v9-build-run.md` D17 / B38 — a 1,018-pixel diff attributed to a midpoint dedup was actually a same-commit door-template change.)
- **Multi-artifact co-registration: validate through a label-independent channel.** When aligning two artifacts by deriving a transform from labeled landmarks, a transform that fits the landmarks is necessary but not sufficient — the landmarks constrain a family of solutions, and the correct one is not guaranteed. VALIDATE the alignment through a LABEL-INDEPENDENT channel: compare content or geometry overlap in regions the landmarks did not constrain, and run NEGATIVE CONTROLS — pairs that SHOULD fail alignment — to confirm the method has discriminatory power. A spurious fit (the transform satisfies the landmarks but misaligns the content) is undetectable without an independent check. (The §11 negative-control and known-answer-attribution rules applied to a registration transform; the new obligation here is the label-independent channel. Evidence: COB-IM2 B4 §4.3–4.4 — `coregister.py`, commit `9cc0bd3`: the correct offset beats no-offset and wrong-offset controls by 1–2 orders of magnitude.)
- **Offline/zero-network verification for self-contained visual deliverables.** For an assembled self-contained visual deliverable (e.g. a single HTML build), VERIFY it is truly offline: (a) grep the assembled artifact for external `fetch`/`import()`/XHR/remote-URL references and confirm zero are present; (b) confirm the deliverable renders correctly with the network disabled. This verifies the assembly step actually inlined all dependencies rather than leaving live references. A deliverable mechanically proven offline this way is `[CERT-hw]`; one merely asserted offline is `[INFER]`. The concrete build recipe and network-isolation procedure for design3d tool deliverables live in the design3d skill, not here. (Evidence: COB-IM2 B11 §11.3 — commit `99b84cb`, `qa-render-offline.png` from a byte-identical offline build.)

**CLOSE step — write build-phase findings as blocks before the phase ends.** When a requires-execution
phase produces findings that would have been blocks had they come from the static loop, write them as
blocks before the phase ends, citing the tools as `sources/probes/`. A deliverable is not a substitute
for the evidence trail. A finding that exists only in a tool's docstring or in engram is undocumented —
it is not cited, not verified, not connected to other blocks, and invisible to any reader of the corpus.
Without this step, a productive build phase silently drains the corpus of its own discoveries.

## 20. Document mode (CAPTURE what you already know or just did)

The static loop (§1–§11) **DISCOVERS** — "what IS this system", gap-driven, AUDIT-FIRST — and self-feeds a
backlog until read-only-investigable hits 0 (§8). **Document mode CAPTURES** knowledge the user already has
or just produced in a session — OUTLINE-driven, with NO discovery phase. It is a MODE, not a new skill: it
reuses the kit's markers (§3), block anatomy (§4), the verify-block gate (§11), and the INDEX/CATALOG
conventions unchanged. Invoked `/research-sdd <target> document "<what to document>"` (SKILL.md); the
operational contract is PROMPT-LOOP's DOCUMENT CYCLE. One-line essence: research-sdd DISCOVERS; document mode
CAPTURES what you already know or just did, and always mirrors it to Engram so it stays findable.

**Cross-ref §18:** a document-mode run ends with the same §18 retrospective pass a discovery run does — fire it at §20 completion before handing off.

**CAPTURE vs DISCOVER.** The static loop uncovers gaps and self-feeds a backlog; document mode does the
opposite — it SEEDS the full list of topics/steps up front (the outline IS the work-list) and STOPS when the
outline is covered, never on gap-exhaustion. It NEVER runs the gap-discovery / AUDIT-FIRST path (§13,
PROMPT-LOOP BOOTSTRAP e). The outline is seeded from three sources: (a) what the user already knows, (b)
their notes, (c) RECONSTRUCTing the steps of the session just lived (a how-to for connecting an EM500 sensor,
bringing up a tool). One block transcribes + cites one outline item.

**The procedure / how-to genre.** A block's evidence base depends on what it documents. Documenting how
something in the SUBJECT works is ordinary `[CERT]` file:line. Documenting a PROCEDURE — a how-to (connect an
EM500 sensor, bring up a tool, a runbook step) — has a different evidence base: the SESSION itself is the
evidence, i.e. the commands run, the GUI navigated, the outputs. Preserve them under `sources/probes/` and
cite them `[CERT-hw]` / `[CERT-live]` per channel, EXACTLY as the dynamic phase (§12) already does. Document
mode introduces NO new marker: a captured procedure is empirical evidence of a live interaction, which is
precisely what `[CERT-hw]`/`[CERT-live]` already mean.

**Auto-routed destination (subject vs toolchain).** The key decision — made by the MODE, not by the user per
call: ask "does this knowledge serve OTHER targets too?"
- Knowledge ABOUT the subject under study (this gateway's config, how to connect a sensor to THIS device) →
  the TARGET's corpus (`$CORPUS`), like any block.
- REUSABLE toolchain / environment knowledge (how to bring up Ghidra, how to use bkcrack, a WSL setup step —
  useful across ANY target) → PROPOSE to the kit: record it in the §18 retro TOOLS section as a `promote`
  (new toolbelt file) or `absorb` (delta into an existing kit file) candidate, PLUS an Engram pointer so it
  is recall-findable immediately. The supervisor writes it to `toolbelt/` and registers it in
  `toolbelt/tool-registry.md` after the run — kit changes are never applied from inside a run
  (§18 propose-never-apply). The browser-appliance and serial bring-up how-tos in `toolbelt/DYNAMIC-SETUP.md`
  are the kind of toolchain how-tos this routing eventually produces.

**Mandatory Engram mirror (the reason the mode exists).** Everything documented MUST be mirrored to Engram as
topic pointers so it stays recall-findable — subject knowledge under `research/<target>/<topic>`, toolchain
knowledge under a kit-level pointer. This is not optional bookkeeping: a real session re-discovered Ghidra
setup from scratch even though `toolbelt/GHIDRA-MCP.md` already documented it, because Engram carried no
pointer to it. The mirror is the safeguard against re-discovering what the kit already knows; a documented
item with no Engram pointer is not done.

**RESEARCH-STATE for corpora produced outside the loop.** When a corpus is authored by a bespoke multi-agent workflow rather than the standard PROMPT-LOOP (§2), a RESEARCH-STATE initialized at bootstrap but never iterated shows stale counts. Two approaches: **(a) do NOT initialize RESEARCH-STATE** — a missing state file is unambiguous (kit tools read it as not-started, which is accurate); OR **(b) initialize with `method: document-cycle-external`** in the state envelope — a SEMANTIC marker that §20 (document mode) and human reviewers read to distinguish an external-document corpus from an abandoned loop. `research-sdd-status.sh --sync-state` PRESERVES this marker (and every other preamble field) across a reseed — it reconciles only the machine-owned count fields — so the declaration survives mechanical reconciliation. NOTE: no kit tool AUTO-SUPPRESSES alerts from this field, and none should — a stale `TARGETS.md` row (`verify-registry.sh`) or an absent retro (`sweep-retros.sh`) for such a corpus is a LEGITIMATE signal to act on (refresh the row, add a retro), not a false positive to hide. Either approach is fine; what is wrong is a loop-format RESEARCH-STATE left at template-placeholder values while the corpus holds a different block count — that is the instrument reporting 0 when it has not actually looked.

**Product.** Besides the cited blocks, document mode yields a human-readable deliverable — `HOWTO-<x>.md`,
`SETUP-<x>.md`, or `RUNBOOK.md` (subject deliverables under `$CORPUS`; toolchain deliverables are PROPOSED
via the §18 retro TOOLS section and land in `toolbelt/` only after the supervisor acts). Same `verify-block`
gate as the static loop; STOP when the outline is covered.

**STATUS (honest).** The DOCUMENT CYCLE is fully specified (SKILL.md + PROMPT-LOOP's DOCUMENT CYCLE) and has
been exercised end-to-end on a real target: computadoras B16–B25 (~10 `method: document-cycle` blocks, each
preserving probes under `sources/probes/`, each passing `verify-block.sh`, and each mirrored to Engram). The
mode is EXERCISED. Maintainer caveat: those blocks were driven inline rather than through the skill's
`document` sub-command — the `method: document-cycle` stamp confirms the DOCUMENT CYCLE contract was
followed; whether the CLI surface was exercised is a separate question.

## 21. Wall protocol (blocked-artifact handling)

A **wall** is any point where the loop cannot proceed at the required certainty because a *capability*
is missing — not because the answer is absent: a tool is not installed, a format is unsupported, a
path is unreadable, or a subprocess timed out. On another machine, walls are the NORMAL case. A wall
is never a silent skip and never an invented `[INFER]`; it is a typed, recorded, human-visible state.

**21.1 Typed wall states** (extend the §8 `blocked-on-<reason>` Status grammar; the absent/empty/
no-match distinction still applies — never a bare zero):
- `blocked-on-tool` — a required capability (decompiler, parser, MCP server) is not AVAILABLE. Name
  the exact capability.
- `unavailable` — an instrument RAN but could not produce a result (backend absent). Distinct from a
  finding of zero: preserve the typed `unavailable` state, never coerce it to PASS or 0.
- `refused` — the capability exists but declined (permission/gate/authorization). Record the refusal
  scope; never retry-loop or launder it through another actor.

**21.2 Fallback chain by artifact class.** Before declaring a wall, walk the declared degradation
chain; each rung is less capable, and the LAST rung reached is recorded so the coverage gap is
explicit:

**Own-surface first (pre-check).** Before walking any chain below OR provisioning a replacement tool
(§21.4), first exhaust the TARGET'S OWN surface as a zero-cost instrument: the launcher's own `-help`
and pass-through options, its `.properties`/config files, and its exported symbols. Any target that
carries a CLI or config surface can answer part of the question about itself before a single external
tool is installed — this is the cheapest first move and it PRECEDES the chain, it is not a rung inside
one. (Evidence: an `nre -@<option>` JVM pass-through found via `nre -help` after 3 wrong tool-walls;
`nre.properties:46` plus `nre.dll` exported symbols unblocked B533/B535 — zero new installs.)

- Native ELF/PE/firmware: `ghidra → r2 → quick` (already in `decompile-native.sh`; never bare
  `strings` — TOOL-BEFORE-AGENT).
- JVM bytecode: `vineflower → cfr → procyon → javap`.
- .NET (PE32 .NET assembly): `ilspycmd → capa → quick` — full decompile via `decompile-net.sh`, then
  capability evidence via `corroborate-capa.sh` (capa handles .NET), then `decompile-native.sh quick`
  (file + strings). Below ilspycmd the question narrows to capabilities/strings, never source.
- PDF / documentation: `extract-pdf.sh tier-1 → extract-pdf.sh tier-2 OCR → markitdown/pdftotext` —
  text-layer (`pymupdf4llm`) first; OCR (`ocrmypdf`/`marker`/`docling`/`tesseract`, auto when `fonts=0`)
  when there is no text layer; then a NON-cited quick read (`markitdown`/`pdftotext -layout`) that drops
  the `:p.N` anchors and therefore cannot be cited as `[CERT]` page-anchored evidence.
- PCAP / PCAPng: `pcap-flows.sh → corroborate-pcap.sh → capinfos` — flow reconstruction (conversations +
  per-stream sha256 digests) first, then the offline summary + protocol hierarchy, then a bare `capinfos`
  summary. No rung replays or captures live traffic.
- Firmware / opaque blob: `corroborate-unblob.sh → scan-firmware.sh carve → scan-firmware.sh evidence` —
  recursive extraction inventory first, then validated exact-byte carving (uImage / SquashFS v4 LE only),
  then a non-extracting binwalk signature + entropy map; `squashfs-extract.sh` is the specialized branch
  once a SquashFS filesystem is confirmed. Encrypted inner archives are a blocker WITH an attack path
  (bkcrack known-plaintext, tool-registry), not a wall.
- Android APK / DEX: `jadx → apktool → quick` — full decompile (`install-tool.sh jadx`), then resources +
  smali (`install-tool.sh apktool`), then `unzip` + strings triage. All three are self-provisioned, so
  §21.4 (`install-tool.sh` first) applies before recording `blocked-on-tool`.
- Web / minified JS bundle: `js-beautify → CodeGraph → context7` — readable reformat first, then structural
  reading via CodeGraph / direct source, then identify a bundled third-party library by its API via the
  context7 MCP instead of reading it. Prove an API is actually USED, not merely present (bundle-evidence rule).
- A new artifact class declares its chain HERE before a checker is built (doctrine-first).

**21.3 Degrade with honesty.** A downgraded rung answers a NARROWER question. Record which rung
produced the evidence. NEVER present a `quick` triage as a full decompile. If NO rung answers the gap
at the required certainty, the gap stays OPEN as the typed state above — not closed, not padded, not
dropped.

**21.4 Provision before blocking.** `blocked-on-tool` names a capability; §10 (Self-provisioning) is
the first response — try `install-tool.sh <tool>` (idempotent) BEFORE recording the block. Record the
block only when provisioning is unavailable or declined, and surface the exact `install-tool.sh`
invocation so the wall is one command from removed.

**21.5 One final attempt before terminal.** After the chain is walked (§21.2–§21.3) and self-provisioning exhausted (§21.4), make exactly one direct, concrete attempt at the original question — not vague persistence and not retry-until-success — and record it with its measured result in the `tried:` clause (§8); that attempt is terminal and opens no loop, since the §8 SCOPED, AUTHORIZED reopen (a bounded experiment on a genuinely-exhausted STOP, §8 "Reopening a STOPPED loop") remains the only path back to an exhausted question.

## 22. Breakthrough ledger (the decisive-solution index)

The corpus records EVERYTHING; the **breakthrough ledger** records the FEW decisive solutions — the
technique that finally cracked a target — so they stay findable instead of buried under hundreds of
blocks. A block that captures such a solution is TAGGED, and a fleet-wide index points at all of them.

**22.1 The marker.** A block whose finding is a decisive breakthrough declares a `**Breakthrough:**`
field in its header blockquote (alongside `**Type:**`, §4):

> **Breakthrough:** <one line — WHAT was cracked and HOW>

Presence of the field tags the block; absence is the default (not a breakthrough). This is ORTHOGONAL to
the §3 certainty markers: `[CERT]` states how STRONG the evidence is; `Breakthrough:` states that this
block is a crown-jewel SOLUTION. A block is both `[CERT]` and a breakthrough when a decisive solution is
also verified — the common case.

Proof-of-function is a THIRD, independent axis from both. The `Breakthrough:` marker requires a DEMONSTRATED crack of the target (§22.5) — a deduced-but-undemonstrated technique is not tagged even when its sub-claims are `[CERT]`. Crucially, proof-of-function is orthogonal to `[CERT]` provenance strength: an `[INFER]`-provenance block that documents a demonstrated crack still earns the marker. Decisive rule: demonstrated → tag (regardless of `[CERT]`/`[INFER]`); merely deduced → do not tag (regardless of `[CERT]`).

**22.2 The four coordinates.** Every ledger entry answers the four questions that get forgotten: WHAT
problem was cracked, HOW (the technique), WHERE it is documented (block `path:line`), and WHERE it is
remembered (Engram topic-key). Three already live in the block (what/how are intrinsic; the block IS the
"where documented"); the Engram mirror supplies the fourth. The ledger adds only the cross-target INDEX
that points at them — that index is the whole feature.

**22.3 The fleet index — `BREAKTHROUGHS.md`.** `research-sdd/BREAKTHROUGHS.md` is the kit-level,
cross-target registry, one row per breakthrough:

| target | what (cracked) | how — block `path:line` | memory — engram topic-key |

It is a REGISTRY like `TARGETS.md`, and like `TARGETS.md` it is **never auto-edited** (§8): the human, or
a research-loop session working ON that target, writes the row after tagging the block. An instrument may
PROPOSE rows and WARN on drift; it NEVER applies (propose-never-apply).

**22.4 Back-fill is target-owned.** Blocks live in target corpora, which the kit READS but never WRITES
(§8). Tagging a block with `**Breakthrough:**` is therefore the operator's / research-loop's act, not a
kit-maintenance one. The kit sweep `sweep-breakthroughs.sh` reads the corpora, cross-checks the tagged
blocks against `BREAKTHROUGHS.md`, and WARNs — never fails on a finding — on: a block tagged but ABSENT
from the index (unindexed breakthrough), an index row whose block NO LONGER carries the marker (drift),
and, at INFO, a corpus with ZERO tagged breakthroughs. It MUST distinguish absent-input / empty-input /
no-match (§7) and `exit 1` only on OPERATIONAL failure, never on a finding.

**22.5 What NOT to tag.** Not every `[CERT]` block is a breakthrough. Tag only the DECISIVE turn — the
technique without which the target stayed closed (the decrypt, the auth path, the gateway, the
load-code RPC). If EVERYTHING is a breakthrough, nothing is; keep the ledger to the crown jewels.
