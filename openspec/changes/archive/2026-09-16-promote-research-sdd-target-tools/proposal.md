# Proposal: Promote General Target Tools into the research-sdd Kit

## Intent

Genuinely general capabilities today live buried in individual research target corpora, invisible and
unmaintained by the shared kit. A read-only judgment pass over ~51 un-recorded tools produced a
promotion shortlist. Precedent `corroborate-ifc.sh` (kit #511) proved the pattern: promote a
capability as a clean, re-built evidence wrapper — never a copy. Promote the shortlist so the fleet
gains maintained, tested, honest instruments.

## Scope

### In Scope
- **Tier 1 (cross-platform general):** `corroborate-bacnet` (pilot built+gated on `feat/corroborate-bacnet`;
  reuse as reference, still needs registry row + schema doc), `qnx6-read`, `serial-frame-analyze` (+ `serial-frame-capture`).
- **Tier 2 (Niagara-family general, per IFC format-family precedent):** `niagara-hdb-read`, `niagara-security-audit`,
  `bog-nav`, `px-render`, `module-find`, `station-modules`, `palette-lexicon-agents`.
- Each promoted as a clean rebuild: TDD (§4), gates (§5), three-state honesty (§7), target-specific refs stripped, English only (§9).

### Out of Scope
- `licensador.py`, `niagara-license-tool.py` — product/license-signing, not research evidence.
- `module-navigator`, `niagara-help`, `fluke-177x-datos` — bespoke/duplicate, zero candidates.
- Retro-flow redesign (issues replacing markers) — separate future SDD change.

## Capabilities

### New Capabilities
- `kit-target-tool-promotion`: governs how a general capability found in a target corpus is promoted into the
  toolbelt as a clean rebuilt evidence wrapper — registered, tested, honest, and target-agnostic.

### Modified Capabilities
- None. (Promoted wrappers must satisfy existing `kit-instrument-honesty` requirements; no requirement text changes.)

## Approach

One wrapper per PR, auto-chained (§6 ~400-line budget). Each wrapper: rebuild clean from the source tool's
observable behavior, strip all target-specific references, add TDD tests with mutation teeth, pass all gates,
and register it. **Design tension the design phase must resolve once:** `tool-registry.md` is organized by
ARTIFACT TYPE (file formats like `.ifc`). Probe/interactive tools (`corroborate-bacnet`=live network,
`bog-nav`=config navigation, `niagara-security-audit`=install audit) are NOT file-artifact producers — design
MUST decide registry placement for non-file-artifact tools and whether each needs an evidence-schema doc
(like `ifc-evidence.v1.md`) or a different registration shape.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/` | New | 10 evidence-wrapper scripts (one per promoted tool) |
| `research-sdd/toolbelt/tests/` | New | Companion `*.test.sh` per wrapper, with mutation teeth |
| `research-sdd/toolbelt/tool-registry.md` | Modified | Registration rows; possibly a new non-file-artifact section |
| `research-sdd/toolbelt/schemas` (evidence-schema docs) | New | Schema doc per wrapper where applicable |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Registry shape can't hold non-file-artifact tools | High | Design phase resolves placement ONCE before any wrapper PR |
| Verbatim copy leaks target-specific refs | Med | §8 propose-never-apply; rebuild clean, English-only readback |
| Wrapper fixture-green but wrong on real fleet | Med | §5 acceptance = fleet behavior, not fixtures |
| Chain exceeds review budget | Med | §6 one wrapper per PR, auto-chain |

## Rollback Plan

Each wrapper is an independent additive PR. Revert the offending PR; no existing instrument or target corpus
is modified (§8). The `corroborate-bacnet` pilot branch stays intact as reference until merged.

## Dependencies

- `feat/corroborate-bacnet` pilot branch (reference impl for Tier 1).
- Source tools remain readable in their target corpora during rebuild.

## Success Criteria

- [ ] Design phase has decided registry placement + schema shape for non-file-artifact tools.
- [ ] Each of the 10 wrappers registered, TDD-tested with mutation teeth, and passing all §5 gates.
- [ ] No wrapper contains target-specific references; all English (§9).
- [ ] Each wrapper accepted against real fleet behavior, not fixtures alone.
