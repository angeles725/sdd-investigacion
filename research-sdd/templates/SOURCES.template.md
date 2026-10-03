# Preserved external sources — <SUBJECT>

> Registry of every document/page downloaded during the research. Research-SDD rule:
> URLs die; evidence does not. Blocks cite the **local file**,
> not the URL. This registry is maintained by `research-sdd/toolbelt/fetch-doc.sh` (automatic append).

| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks that cite it |
|---|---|---|---|---|---|
| datasheets/example.pdf | datasheet | https://... | <YYYY-MM-DDTHH:MM:SSZ — real fetch time, UTC> | <sha256 of the downloaded bytes> | [Block K] |
| local-install (not preserved) | local-install (not preserved) | <install-root>/modules/x.jar | <YYYY-MM-DDTHH:MM:SSZ — real time the sha256sum ran, UTC> | <sha256 of the install file> | [Block K] |

> Placeholders in angle brackets are replaced with real values; never leave a midnight `T00:00:00Z` stand-in
> (METHODOLOGY §5: record the REAL hash time). A `local-install (not preserved)` row names the install-relative
> path in Origin (never an absolute machine path such as `/mnt/c/...`): the bytes stay in the licensed install.

## Structure

```
sources/
  datasheets/      ← manufacturer datasheets
  manuals/         ← official manuals / guides
  web-snapshots/   ← pages and forums converted to markdown (pandoc)
  extracted/       ← extracted text (extract-pdf.sh: pymupdf4llm text-layer → ocrmypdf/tesseract OCR fallback)
```
