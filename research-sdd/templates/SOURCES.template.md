# Preserved external sources — <SUBJECT>

> Registry of every document/page downloaded during the research. Research-SDD rule:
> URLs die; evidence does not. Blocks cite the **local file**,
> not the URL. This registry is maintained by `research-sdd/toolbelt/fetch-doc.sh` (automatic append).

| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks that cite it |
|---|---|---|---|---|---|
| datasheets/example.pdf | datasheet | https://... | 2026-06-28T00:00:00Z | abc123… | [Block K] |

## Structure

```
sources/
  datasheets/      ← manufacturer datasheets
  manuals/         ← official manuals / guides
  web-snapshots/   ← pages and forums converted to markdown (pandoc)
  extracted/       ← extracted text (extract-pdf.sh: pymupdf4llm text-layer → ocrmypdf/tesseract OCR fallback)
```
