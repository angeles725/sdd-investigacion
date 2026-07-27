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
| `[CERT-live]` | verified **empirically against a live REMOTE service you do not own** (hosted / cloud / third-party HTTP API) — the real endpoint's runtime RESPONSE, not its published docs. Same top rank as `[CERT-hw]`; the risk model differs (rate-limits / ToS / authorization / metered cost, not physical bricking — §12 remote-API frame). | `sources/probes/<run-output>.txt §…` + the request that produced it |
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

**docSource dual-tree (one class living in TWO physical trees).** When a target ships BOTH a decompiled tree
AND an SDK "doc source" tree for the SAME class (e.g. a `docSource/` shipped-source tree vs the
Vineflower/Procyon decompiled output), they are two PHYSICAL trees with INDEPENDENT line numbering competing
for one class name. A `file:line` citation MUST name WHICH tree — a line number valid in one is meaningless
in the other, so the two are not interchangeable. Anchor the citation to the concrete tree path (`docSource/…`
vs the decompile-output dir), never to the bare class name. This is the same identity hazard as the
beautified-temp and obfuscated-bytecode cases above: one logical class, more than one physical artifact.

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

**Saturation is a soft REVIEW prompt, not a fourth STOP criterion.** The backlog rarely empties (each
block uncovers 1-4 new gaps), so a subject can be substantively SATURATED long before the criteria above
fire. `research-sdd-status.sh` surfaces this from the `## Iteration history` "New gaps uncovered" column:
when the LAST 3 numeric iterations net EXACTLY 0 new gaps it reports `saturation : SATURATED (review)` in
the default status report. This is INFORMATIONAL only — it does NOT auto-STOP, change exit codes, or alter
`--next`; it complements the §8 STOP decision by flagging a diminishing-returns subject for human/agent review.

**A gap closes on a negative finding too.** A rigorously proven ABSENCE closes a gap exactly like a
positive one: if the investigation shows a thing is NOT there — cited as such — the gap is covered, not
open. (Proven on protocols B136: the Sox gap was closed by demonstrating Sox's absence across 973 jars,
cited.) A negative closure needs the same evidence bar as a positive one: cite what you searched and how
(paths, counts, the grep/scan that came back empty), not a bare "not found".

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

**A gap closes by remittance too.** Three closure categories now exist, not two: closed by NEW
investigation, closed by PROVEN ABSENCE (above), and closed by REMITTANCE. A gap closes by remittance when
a later sweep shows it is ALREADY fully answered by an EXISTING cited block/section, with NO new substance
to add. This is not padding and not a dropped gap: cite the exact prior `[Block N] §N.x` that covers it and
state explicitly "closed by remittance — no new substance". It differs from proven-absence (which cites a
search that came back empty); remittance cites prior COVERAGE. Use it to avoid writing a redundant block
for a gap the corpus already answers — but the citation + explicit no-new-substance note is the evidence
bar; a gap "closed by remittance" with no prior-block citation is just a silently dropped gap.
Restrict remittance to a GENUINELY PRIOR block — one already committed BEFORE this iteration. The distinct
case where NEW content answering an adjacent gap lands in the SAME block/iteration you were writing is NOT
remittance (it is new substance, just serendipitous): close that gap as closed-by-NEW-investigation citing
the same-iteration `§N.x`, not as remittance. Reserve remittance for coverage that predates this iteration.

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

**Live backlog injection ≠ reopening a STOPPED loop.** When the user adds new questions WHILE a focus is
still ACTIVE (not stopped, not exhausted), the loop simply APPENDS them to the current backlog and widens its
scope (renumbering as needed) — no new bootstrap, no fresh authorization, no separate additive budget cap.
This is LIGHTER than the reopen above, which re-arms a genuinely-exhausted STOP for NEW work with its own
budget: here the loop never stopped, so the new gaps just extend the queue it is already draining (e.g. a
backlog widened mid-run with `+BG13 modernización` and `BG11 → chihuahua` at the user's request).

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

**MCP-server capabilities count as tools too.** §10 was written for `install-tool.sh` binaries, but a
capability added via an MCP server — e.g. a `chrome-devtools` MCP to reach a JS-rendered chunk a no-JS crawl
cannot — is provisioning too, and it lives in GLOBAL session config (`~/.claude.json` `mcpServers`), not
versioned with any corpus. Log it in `toolbelt/INSTALLED-TOOLS.md` like any other tool (name, what it solved,
and that it is a global MCP server, not a target-local binary), so a future session has a trace instead of a
silently present-or-absent capability. A finding that depends on an MCP capability NAMES it, same as a CLI tool.

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
- **Marker tally** — counts of `[CERT]/[CERT-doc]/[CERT-web]/[CERT-a]/[INFER]`, plus the **`[INFER]`/
  `[CERT]` ratio** AND the **block type**. For an **evidence block** (decompilation/reading) a high ratio
  (>~0.5) is the automatic signal that the investigable evidence for this gap is nearly exhausted — say so;
  it feeds the §8 stop decision. For a **design/applied block** (integration plan, PoC design, cross-focus
  synthesis) a high ratio is EXPECTED and healthy, NOT an exhaustion signal, and does NOT close the focus
  (e.g. protocols B137 at ~0.48 was a sound integration plan). Declare the type so the ratio is read right.
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

## 12. Dynamic phase (validation against a live system)

The static loop (§1–§11) is READ-ONLY decompilation — safe, autonomous, loop-able. When a LIVE system
becomes available (device, server, PLC), a DYNAMIC phase validates the static findings against it. This
phase is DIFFERENT and must NOT run as a blind autonomous loop:

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
- **Invasiveness ladder (fixed order).** Escalate deliberately, never skip a rung: (1) read-only probe —
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
- **After an incident, check the DEVICE first (refines §17).** If an iteration was killed/crashed mid-write
  in a hardware phase, the §17 resume rule inverts: check the PHYSICAL device state (is it left safe? was
  the write applied or reverted? re-measure the checksum live) BEFORE checking git/disk. A committed block
  is recoverable; a device left in a half-written state is not. Physical safety precedes artifact state.
- **Environment setup** (e.g. WSL `networkingMode=mirrored` to reach a LAN device, run `wsl --shutdown`
  from **Windows** PowerShell — not inside WSL) is a prerequisite; verify connectivity before probing.

### 12b. Remote HTTP / cloud API targets (the frame that does NOT transfer from bench hardware)

Everything above assumes a live system you physically or administratively CONTROL (a bench device, a
PLC, your own station) — where the dominant risk is bricking and the ground-truth identity is a program
checksum. A **remote HTTP / cloud API you do not own** (a hosted SaaS endpoint, a third-party API) is a
different subject: there is no unit to brick, no bench-vs-production physical confusion, no checksum-as-
identity. The invasiveness ladder, cross-protocol/independent-read oracle, and "never trust the write's
own 200" rules STILL apply. What changes:

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

**Honesty note (do not oversell).** No kit target has run this frame yet — the mature dynamic phases (§12)
are all local devices/stations. `[CERT-live]` is defined here for the FIRST remote-API target; exercise it
on a real endpoint before relying on it as a standing pattern, exactly as §11's adversarial-verify seal
carries its own "trial before you trust it" caveat.

## 13. Audit mode (re-verify an existing corpus)

A mode distinct from gap-discovery: take EXISTING blocks (especially an older corpus written without
this engine) and re-verify their claims against the primary source. Output is an **audit-delta**, NOT a
new knowledge block. Per claim assign: **ESCALATED** (was `[CERT-a]`/hedged → now source-confirmed
`[CERT]`), **CONFIRMED** (held), **DOWNGRADED** (unverifiable → `[INFER]`), **REFUTED** (the source
contradicts it — the most valuable). Write the report under `audits/`, READ-ONLY on the audited corpus.
Driven by [`PROMPT-AUDIT.md`](PROMPT-AUDIT.md). Audits ALWAYS write to `$TARGET/audits/` (never the
kit), carry a `<!-- review-status: pending -->` marker, and are surfaced by `sweep-audits.sh` — the
mirror of §18's retro sweep — with certainty verdicts routing to §14 corrections and coverage gaps to
the §8 backlog, applied by the human (propose-never-apply). STATUS (honest): the audit VOCABULARY (ESCALATED / CONFIRMED
/ DOWNGRADED / REFUTED) is exercised inline in normal blocks and §14 corrections (e.g. niagara B34 / B117 /
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

**Backlog SIZING comes from a MEASURED count, never a hand-guess.** Whenever a gap's size feeds
prioritization (how many classes/commands/files a subsystem holds), take the number from an ACTUAL count over
the real dir (`find … | wc -l`), never an eyeball estimate — hand-guesses are wildly wrong: a guessed
"studio 6" was actually 61, and "commands 36" was actually 14 AND pointed at the wrong directory. When two
nested directories share a basename, DISAMBIGUATE the full path before counting — counting the wrong
same-named dir silently mis-sizes the gap. When the count is over DECOMPILED code, first COLLAPSE duplicate
decompiler-pipeline trees: a project decompiled by BOTH procyon and vineflower yields ~2× the raw `.java`
files (an "easyBinding 119" was 62 distinct classes). Count DISTINCT fully-qualified class names, not raw
`.java` files.

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
- **REFUTE vs CLARIFY-SCOPE — distinguish them.** A **refute** means the prior claim was WRONG. A
  **scope-clarification** means the prior claim was RIGHT for a DIFFERENT artifact/build (e.g. a dev-tree
  vs the shipped binary, one version vs another) and only needs a scope note — NOT a refutation. Label it
  as a scope divergence ("correct for build X, this block covers build Y"), not as an error, so the prior
  block is not wrongly read as sloppy. Only call it a refute when the two describe the SAME artifact.
  The same distinction runs in the hardware→code direction — a live `[CERT-hw]` finding can scope-clarify a
  `[CERT]` static claim (the deployment gates a real code-path) without refuting it; that case lives in §12.
- In audit mode (§13), or periodically, sweep blocks on the same subsystem for contradictions.
- **When a conflict CANNOT yet be adjudicated**, do NOT force it into a premature `[INFER]` or drop it:
  record it in the corpus `CONTRADICTIONS.md` as `open` (source A says X, source B says Y). It is surfaced
  by `research-sdd-status.sh` (open count in the status report) so it is not forgotten at STOP, and resolved
  later per this section — the winning side then corrects the losing block and the row flips to `resolved`.
- Every correction is logged in the correcting block's Connections and in RESEARCH-STATE's history.

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
  `INDEX.md`) listing each focus as **active / paused / stopped / planned**, its `RESEARCH-STATE-<focus>.md`,
  and its block prefix. This is how the loop (and a human) knows which focuses exist and which is current.
  A **planned** focus is one whose RESEARCH-STATE + backlog are already committed but which has 0 blocks yet;
  because it is already initialized, the loop must NOT re-BOOTSTRAP it as a duplicate — it picks up the
  existing state and writes its first block.
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
machine-readable marker.

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

## 20. Document mode (CAPTURE what you already know or just did)

The static loop (§1–§11) **DISCOVERS** — "what IS this system", gap-driven, AUDIT-FIRST — and self-feeds a
backlog until read-only-investigable hits 0 (§8). **Document mode CAPTURES** knowledge the user already has
or just produced in a session — OUTLINE-driven, with NO discovery phase. It is a MODE, not a new skill: it
reuses the kit's markers (§3), block anatomy (§4), the verify-block gate (§11), and the INDEX/CATALOG
conventions unchanged. Invoked `/research-sdd <target> document "<what to document>"` (SKILL.md); the
operational contract is PROMPT-LOOP's DOCUMENT CYCLE. One-line essence: research-sdd DISCOVERS; document mode
CAPTURES what you already know or just did, and always mirrors it to Engram so it stays findable.

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
  useful across ANY target) → the KIT: `toolbelt/` + a registration in `toolbelt/tool-registry.md`, PLUS an
  Engram pointer. The browser-appliance and serial bring-up how-tos in `toolbelt/DYNAMIC-SETUP.md` are
  exactly the toolchain how-tos this routing produces.

**Mandatory Engram mirror (the reason the mode exists).** Everything documented MUST be mirrored to Engram as
topic pointers so it stays recall-findable — subject knowledge under `research/<target>/<topic>`, toolchain
knowledge under a kit-level pointer. This is not optional bookkeeping: a real session re-discovered Ghidra
setup from scratch even though `toolbelt/GHIDRA-MCP.md` already documented it, because Engram carried no
pointer to it. The mirror is the safeguard against re-discovering what the kit already knows; a documented
item with no Engram pointer is not done.

**Product.** Besides the cited blocks, document mode yields a human-readable deliverable — `HOWTO-<x>.md`,
`SETUP-<x>.md`, or `RUNBOOK.md` (subject deliverables under `$CORPUS`, toolchain deliverables under
`toolbelt/`). Same `verify-block` gate as the static loop; STOP when the outline is covered.

**STATUS (honest, do not oversell).** The DOCUMENT CYCLE is fully specified (SKILL.md + PROMPT-LOOP's DOCUMENT
CYCLE) but has NOT been exercised end-to-end THROUGH the skill's `document` sub-command on a real target: its
cited products (`toolbelt/DYNAMIC-SETUP.md`, `toolbelt/GHIDRA-MCP.md`) both PREDATE the mode (committed
2026-06-28; the mode landed 2026-07-11) — they are the KIND of toolchain how-to this routing produces, not
outputs of a real document-mode run. Treat §20 as DEFINED-BUT-UNEXERCISED until a real
`/research-sdd <target> document` run produces a cited block + its mandatory Engram mirror — exactly as §11's
adversarial seal and §12b's `[CERT-live]` frame each carry their own "trial it before you trust it" caveat.
