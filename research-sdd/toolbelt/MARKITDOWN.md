# markitdown — quick document→Markdown converter (and where it fits vs `extract-pdf.sh`)

**Genre:** toolchain how-to (document mode, METHODOLOGY §20). Evidence class for the
commands below is `[CERT-live]` — real invocations in this environment (WSL Ubuntu),
captured 2026-08-05. Tool identity is by absolute path + `--version`.

## What it is

`markitdown` (Microsoft) converts many document types (PDF, DOCX, PPTX, XLSX, HTML,
images, audio) to Markdown with ONE command. Installed here as a user script:

```
$ markitdown --version
markitdown 0.1.7                       # path: /home/cristian/.local/bin/markitdown
```

Note: the first stderr line on every run is an unrelated onnxruntime GPU-probe warning
(`Failed to detect devices under "/sys/class/drm/card0"`) — it is NOISE, not an error;
the command still succeeds (exit 0) and prints its result after it.

Basic use:

```
markitdown INPUT.pdf -o OUTPUT.md      # exit 0 on success
```

## Where it fits — DECISION (do not reach for it blindly)

The kit's CANONICAL PDF path is **`extract-pdf.sh`** (tool-registry: "PDF
datasheet/manual"), because it (a) keeps tables, (b) writes a `<!-- p.N -->` anchor
before every page — which the citation model (`x.pdf :p.N`) REQUIRES — and (c) records
the extraction METHOD so OCR-derived text is flagged `reliability: ocr-lossy`.
`markitdown` does NONE of those three: no page anchors, no method/reliability header,
weaker table fidelity. So:

| Situation | Use |
|---|---|
| Corpus block that will CITE a PDF by page (`:p.N`) | **`extract-pdf.sh`** (page anchors are mandatory) |
| Scanned / image-only PDF (needs OCR) | **`extract-pdf.sh`** tier 2 (ocrmypdf/marker/docling/tesseract) — never markitdown; it does not add a text layer |
| Quick one-off read of a text-layer PDF, DOCX, PPTX, XLSX where you do NOT need page cites | `markitdown` (one command, no venv) or `pdftotext -layout` |
| Cleanest plain text of a text-layer PDF | `pdftotext -layout` (best column/heading fidelity — see gotcha) |

**Gotcha observed:** on a PDF whose section titles use a decorative letter-spaced font,
markitdown duplicated the glyphs (`CCCaaapppííítttuuulllooo`) while `pdftotext -layout`
rendered them correctly as `Capítulo`. For text-heavy academic PDFs, `pdftotext -layout`
was the cleaner extractor of the two.

## The text-layer vs scanned probe — RUN IT FIRST (never OCR a PDF that has text)

Same probe `extract-pdf.sh` uses internally. A PDF is a text layer when it has embedded
fonts AND real characters come out of the first pages:

```
fonts=$(pdffonts "$f" | tail -n +3 | wc -l)          # embedded font count
chars=$(pdftotext -f 1 -l 5 "$f" - | tr -d '[:space:]' | wc -c)
# text-layer  ⇔  fonts > 0  AND  chars > 100
# else        ⇒  scanned → OCR (extract-pdf.sh tier 2), never markitdown
```

RULE (from `extract-pdf.sh`): OCR is a FALLBACK, not the default. Heavy OCR sweeps get
DELEGATED (research-sweep-cheap), not run on the driver. Extract only the page RANGE a
gap needs.

## Worked evidence — Evidencia III.1 source PDFs (2026-08-05, `[CERT-live]`)

Three lecture PDFs (Univ. de Cantabria, cams) probed and extracted; all three are text
layers, so **no OCR was used**:

```
Tema 10 - Levas I.pdf     fonts=51   chars(p1-5)=2352   pages=14  => TEXT-LAYER (no OCR)
Tema 11 - Levas II.pdf    fonts=173  chars(p1-5)=2335   pages=36  => TEXT-LAYER (no OCR)
Tema V 1 Teoria.pdf       fonts=10   chars(p1-5)=1768   pages=42  => TEXT-LAYER (no OCR)
```

Extraction used for the report: `pdftotext -layout` (cleaner titles than markitdown on
these). `markitdown INPUT.pdf -o OUT.md` was verified to work (exit 0) on all three but
was not chosen as the final extractor because of the decorative-title duplication above.

## One-liner for the tool registry

`markitdown 0.1.7` (`~/.local/bin/markitdown`): quick any-doc→Markdown for non-cited
reads; NOT a substitute for `extract-pdf.sh` when page-anchored citations or OCR are
needed. Verify text-layer with the `pdffonts`/`pdftotext -f 1 -l 5` probe before any OCR.
