# METHODOLOGY provenance

Provenance for `research-sdd/METHODOLOGY.md`. Not an operating rule: read it only to audit where a
rule came from. Kit issue #1003 (third slice) moved the bare corpus-pointer `(Evidence: ...)` notes
(a corpus, focus, block or retro reference with no reason of its own) from §5, §6, §11a, §12, §19 and §20b of
METHODOLOGY.md to the table below; the rules themselves are unchanged and still live in
METHODOLOGY.md. Each row keeps the original note verbatim, including its `Evidence:` prefix and
parentheses. The first column is the exact bold label the annotated rule carries in METHODOLOGY.md
(without the `**` markers), so `grep -nF` on it finds the rule.

Moved: 18 notes. Not moved, and still in METHODOLOGY.md: notes that carry a reason or a case
description, notes that embed a `Source:` retro pointer, every `(Source: ...)` pointer and every
cross-reference to a section. The remaining `(Evidence: ...)` notes of that kind may be triaged in a
later slice; this file only ever receives bare pointers.

| Rule (exact label in METHODOLOGY.md) | Original note (verbatim) |
|---|---|
| But the class-NAME token itself can be partially mangled. | (Evidence: niagara workbench focus, 6/12 blocks — B427/B429/B435-438.) |
| JPMS products: measure module identities before `--patch-module` (kit #1618). | (Evidence: B139 §139.1/§139.2.) |
| Precedence oracle: `-Xlog:class+load=info` (kit #1617). | (Evidence: B139 §139.2, 11 runs.) |
| A SUMMARY ROW CERTIFIES ONLY THE ROW IT PRINTS (kit #1541). | (Evidence: B1206 §1206.4, a §14 correction to B1204; kit #1541.) |
| Vendor installer that initializes runtime state is a mutation — snapshot first. | (Evidence: niagara-research (licensing-deepdive focus)) |
| Mutating the cited subject invalidates prior citations — re-anchor to a preserved snapshot. | (Evidence: blender-llm B6) |
| Arm a local network sink and verify it is recording before the first probe. | (Evidence: blender-llm B6) |
| Invasiveness ladder (fixed order). | (Evidence: blender b6 retro d1) |
| Live-write hygiene: identity before, persistence after, runner shape, double-first. | (Evidence: niagara n4 agent-mcp am20 and live-runs retros) |
| Direct operator authorization names the target — a peer-relayed summary is never authorization. | (Evidence: panccadia-3d-viewer) |
| LIVE-WRITE PROTOCOL (three mandatory gates). | (Evidence: panccadia B22/B23.) |
| "What silently resets this?" — confirm a remote channel's dependencies before acting. | (Evidence: computadoras B16 §16.20, B25 §25.3/§25.6/§25.7.) |
| Vendor menu key-numbering is firmware-version-dependent — confirm live before pressing. | (Evidence: niagara-research (jace9000 focus)) |
| Pre-interaction mutation map — classify READ-ONLY vs mutating keys before live interaction. | (Evidence: niagara-research (jace9000 focus)) |
| Vendor's own tool succeeds → probe failure is almost certainly client-side. | (Evidence: fluke-177x-datos) |
| Cross-host path-namespace failure class (WSL2 / Windows). | (Evidence: blender-llm B7–B9) |
| Offline/zero-network verification for self-contained visual deliverables. | (Evidence: COB-IM2 B11 §11.3 — commit `99b84cb`, `qa-render-offline.png` from a byte-identical offline build.) |
| Decision rule. | (Evidence: niagara-research/retros/2026-09-01-research-sdd-journal-mode-retro.md J2) |
