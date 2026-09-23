<!-- review-status: pending -->
<!-- kit-retro -->
# Retro — nave-panccadia · v14→v18 refinements + IFC→viewer · 2026-08-07

**review-status: pending**

> **Declared deviation from §18.** Written by the loop DRIVER (document-mode capture, not a
> fresh-context agent) — the session forbade spawning sub-agents without an explicit request, as in
> run 2. Discount the JUDGEMENT accordingly; the factual claims are citable to [Block 43], its probes,
> and `tools/build-viewer.py`/`tools/ifc-to-viewer.py`. READ-ONLY on the kit: this PROPOSES a kit
> delta, it does NOT apply it. Deduped against the four prior retros (D1–D10 + openings/facade + v9).

## Run summary

| | |
|---|---|
| Phase | §19 applied build, on a CLOSED corpus (STOP 39/39) — refinements v14→v18, captured via document mode (§20) |
| Block | [Block 43] — clean corners + realistic render |
| New sources | `Plantas.ifc` (operator Revit IFC4 export, benchmark), `ifcopenshell`, blueprint3d, three.js docs — registered in `sources/SOURCES.md` |
| New tool | `tools/ifc-to-viewer.py` — IFC → self-contained three.js viewer (ifcopenshell tessellate → base64-embed → IBL/ACES render) |
| Gate | every version 0 visible defects; `verify-block.sh` on B43 exit 0 |

## Proposed kit deltas

no new deltas; the kit already covers this run.

## D11 — ⚠️ PROMOTE the IFC→viewer capability to the KIT toolbelt — REQUIRES OPERATOR AUTHORIZATION

The operator DEFERRED this to review (2026-08-07): "la dejamos como propuesta para la sesión de
revisión". **Nothing has been written to `$KIT` — this is the authorization gate.** Promoting the
IFC→viewer capability to `$KIT/toolbelt/` + `tool-registry.md` is the action awaiting your go-ahead.

- **What:** `tools/ifc-to-viewer.py` (currently in the target) turns any IFC into the same
  self-contained three.js viewer used for the nave — `ifcopenshell` world-coord tessellation of
  walls/columns/slabs/doors → base64-embedded position+index buffers → per-class materials +
  `RoomEnvironment` IBL + `ACESFilmicToneMapping`. IFC Z-up → three Y-up as `(x,z,y)`.
- **Why reusable (not target-specific):** it views ANY reference model (a Revit/IFC export) beside our
  own reconstruction — a general "benchmark against a clean model" capability, exactly the toolchain
  genre §20 routes to `$KIT/toolbelt/` + `tool-registry.md`. It is the readable bridge past an opaque
  `.rvt` (proprietary OLE; only a 128×128 wireframe preview is extractable).
- **How to promote (the review action):**
  1. Copy `tools/ifc-to-viewer.py` → `$KIT/toolbelt/` (generalise: drop nave-specific defaults if any).
  2. Add a `tool-registry.md` row: `IFC model (BIM) | file: 'ISO-10303-21' / '.ifc' | ifcopenshell 0.8.5 tessellation | ifc-to-viewer.sh (or .py) | ✅`.
  3. Optional companion how-to under `$KIT/toolbelt/` (a short `IFC-VIEWER.md`).
  4. Kit-level Engram pointer so it stays recall-findable (the §20 mirror rule — a real session
     re-discovered Ghidra setup because no Engram pointer existed).
- **Dependency to note in the registry:** `pip install ifcopenshell` (0.8.5 used here).

**Until authorized:** the capability stays documented in the target ([Block 43] §43.6 +
`tools/ifc-to-viewer.py` + Engram `research/nave-panccadia`); the kit is UNCHANGED.

## Other observations (no kit delta proposed)

- **v14→v18 lesson (belongs to the corpus, already in B43):** "looks like real life" = clean geometry
  (regularise + extend-to-corner) + realistic rendering (IBL + ACES), NOT textures. This is a §19
  build lesson, not a methodology gap — no kit change.
- **A cleaning move must be constrained + anchored** (lateral-only onto the doorway host; axial-only to
  the shared corner). The free weld that moved endpoints dropped walls and broke jambs — the audit
  caught it (0→3 visible) and it was reverted. Reinforces the existing "audit is the guardrail" rule;
  no new kit delta.
