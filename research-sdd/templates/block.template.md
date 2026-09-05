# Block N — <DESCRIPTIVE TITLE>

> Research of **<MODULE/COMPONENT>**: <scope in 1-2 lines — what it covers and what it does not>.
>
> Subject version: <vX.Y.Z | commit-sha | release-date | "unversioned"> — the version of the subject
> this block was written against. An audit comparing against a different version must carry this stamp
> to distinguish DRIFTED (subject moved) from REFUTED (was wrong at write time). See PROMPT-AUDIT.md.
>
> Sources: <real primary paths · documents in sources/... · URLs>.
> Method: <how it was investigated: decompiler/tool/reading/web>. Markers (canonical list: METHODOLOGY §3):
> `[CERT-hw]` verified against the live system/device — highest (`sources/probes/...`) ·
> `[CERT-live]` verified against a live remote service you don't own (hosted/cloud API response — §12b) ·
> `[CERT]` local primary source (`file:line`) ·
> `[CERT-doc]` official downloaded document (`sources/...pdf §N`) ·
> `[CERT-web]` official web (URL + date) ·
> `[CERT-a]` secondary source/forum (URL) ·
> `[INFER]` deduction.
> For MINIFIED/OBFUSCATED sources: `file:line` may point at a beautified SCRATCHPAD temp (1:1 with the
> original); anchor identity with the ORIGINAL file's `sha256` (METHODOLOGY §5).
>
> <Layer/area>. Connects [Block K] (<brief relationship>).
>
> **Type:** (closed grammar §4) `standard` (default — omit this field) | `evidence` (alias of `standard`) |
> `synthesis` — conclusions drawn from prior blocks; file:line cites not expected | `mixed` — evidence +
> synthesis combined (a section draws `[INFER]` across PRIOR blocks) | `absence-centred` — the primary
> finding IS a proven absence | `capture` — §20 document mode (records known/done; no gap backlog) |
> `document` (alias of `capture`) | `collaborative` — agent-authored evidence half + `[TO ANNOTATE]`
> placeholders for the human; valid in its partial state, NOT a coverage gap (METHODOLOGY §4) | `audit`.
> `verify-block.sh` downgrades the ZERO-citations WARN to INFO for `synthesis`, `capture`, `document`, and
> `absence-centred`; all other tokens keep the WARN (METHODOLOGY §11, kit issue #422).
>
> **Breakthrough:** `<omit unless this block captures a DECISIVE solution>` — one line: WHAT was cracked and
> HOW. Presence tags this block for the fleet ledger (`BREAKTHROUGHS.md`, METHODOLOGY §22); it is ORTHOGONAL
> to the `[CERT*]` markers (those state evidence strength, this states crown-jewel-ness). Tag only the
> decisive turn, not every verified finding.

---

## N.1 — <Section title> `[CERT]`

<Content. Each relevant claim carries its marker and its citation. Use tables for
hierarchies, signatures, protocols, comparisons.>

| Element | Detail | Citation |
|---|---|---|
| <...> | <...> | `<file:line>` |

## N.2 — <Title> `[CERT-doc]`

<...> (e.g. value confirmed in `sources/datasheets/x.pdf §4.2`).

## N.x — Open questions / unresolved contradictions  <!-- OPTIONAL: omit if none -->

<!-- Any conflict this block SURFACED but could not adjudicate (source A says X, source B says Y).
     Record it here AND push it to the corpus CONTRADICTIONS.md as `open` (METHODOLOGY §14) — do NOT
     force it into a premature [INFER]. Resolved later; the winning side then corrects the block per §14. -->

- **[C<k>]** <A asserts X> `[CERT]` vs <B asserts Y> `[CERT-a]` — <why unresolved> → corpus `CONTRADICTIONS.md`.

## N.x — Connections

- **[Block K]** — <how it relates to this block>.
- **[Block M]** — <...>.

<!-- Collaborative block: when Type: collaborative, add one section per human-facing half using this pattern.

## N.x — <Human-domain section title> [TO ANNOTATE]

[TO ANNOTATE] — <one sentence describing what engineering knowledge or live measurement goes here>.

-->
