# Archive Report: promote-research-sdd-target-tools

**Status**: COMPLETE — ARCHIVED 2026-09-16

**Delivery**: 10/10 wrappers promoted and merged to origin/main across 11 PRs (#513–#526).

## Summary

This SDD change successfully promoted 10 general-purpose evidence wrappers from individual research target corpora into the research-sdd toolbelt. Each wrapper was rebuilt cleanly (never copied), tested with mutation controls, gated, registered, and delivered within the 400-line review budget. The new capability `kit-target-tool-promotion` was standardized as a specification and published to the main specs directory.

## Delivery Record

### Wrappers Promoted

| # | Wrapper Name | PR | Classification | Status |
|---|---|---|---|---|
| 1 | corroborate-bacnet | #513 | Live-probe (network) | ✅ |
| 2 | qnx6-read | #515 | File-artifact (FS image) | ✅ |
| 3 | serial-frame-analyze | #516 | File-artifact (frame dump) | ✅ |
| 4 | serial-frame-capture | #517 | Live-probe (hardware) | ✅ |
| 5 | niagara-hdb-read | #519 | File-artifact (.hdb) | ✅ |
| 6 | niagara-security-audit | #520 | Install-audit (dir tree) | ✅ |
| 7 | module-find | #522 | Install-scan (dir tree) | ✅ |
| 8 | bog-nav | #523 | File-artifact (.bog) | ✅ |
| 9 | station-modules | #524 | File-artifact (.bog/station) | ✅ |
| 10 | palette-lexicon-agents | #525 | File-artifact (palette set) | ✅ |
| 11 | px-render | #526 | Render (.px→HTML) | ✅ |

**Note**: #514, #518, #521 were documentation/review corrections during the chain; 11 PRs total, 10 promotion PRs.

### Verification Status

**Verdict**: PASS (0 critical issues)

Per `apply-progress.md`:
- **Gate results**: 118 suites / 2865 test cases / 0 failed
- **Shellcheck**: zero warnings (`shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh`)
- **Mutation teeth**: all 10 promoted suites carry `--prove-teeth` mutation controls + teeth banner
- **Fleet acceptance**: each wrapper validated against real target corpus before merge
- **FABLE gate cadence**: each wrapper (PR2–PR10) passed an adversarial FABLE review gate; px-render (#526) required 3 FABLE corrections (XSS sanitization, containment root validation, dedup/teeth/cap accounting)

### Task Completion Gate

All 10 implementation task units marked complete in `tasks.md`:

| Unit | Goal | Status |
|------|------|--------|
| PR1 | corroborate-bacnet registry subsection + schema doc | ✅ 1.1–1.4 |
| PR2 | qnx6-read wrapper + tests + fleet validation | ✅ 2.1–2.8 |
| PR3 | serial-frame-analyze + serial-frame-capture (shared schema) | ✅ 3.1–3.12 |
| PR4 | niagara-hdb-read wrapper + tests | ✅ 4.1–4.7 |
| PR5 | niagara-security-audit wrapper + tests | ✅ 5.1–5.7 |
| PR6 | module-find wrapper + tests | ✅ 6.1–6.7 |
| PR7 | bog-nav wrapper + tests + fleet validation | ✅ 7.1–7.7 |
| PR8 | station-modules wrapper + tests | ✅ 8.1–8.7 |
| PR9 | palette-lexicon-agents wrapper + tests | ✅ 9.1–9.7 |
| PR10 | px-render wrapper + tests + stdlib-only confirmation | ✅ 10.1–10.7 |

### Specs Synced

**Domain**: `kit-target-tool-promotion`

| Action | Source | Destination | Details |
|--------|--------|---|---|
| Created | `openspec/changes/promote-research-sdd-target-tools/specs/kit-target-tool-promotion/spec.md` | `openspec/specs/kit-target-tool-promotion/spec.md` | Mechanical copy verified with empty `diff -r` |

**Specification Requirements** (7 total):
1. Rebuild-Not-Copy — no target-specific references, English-only code
2. Read-Only Default Gate — live-probe/hardware tools gate behind `--allow-live-probe` flag
3. Three-State Honesty — absent-input, empty-input, no-match produce distinct typed outputs
4. TDD with Mutation Teeth — companion `*.test.sh` with ≥1 mutation control + teeth banner
5. Registration — row in `tool-registry.md`, `INSTALLED-TOOLS.md` row only for new external deps
6. Fleet-Validated Acceptance — all wrappers tested against real corpus before merge
7. One-Wrapper-Per-PR Delivery — each PR delivers exactly one wrapper within ~400-line budget

All 10 wrappers satisfy all 7 requirements; no external dependencies introduced.

### Archive Contents

- ✅ `proposal.md` — Intent, scope, approach, risks
- ✅ `specs/kit-target-tool-promotion/spec.md` — Published specification
- ✅ `design.md` — Technical approach, architecture decisions, data flow, threat matrix
- ✅ `tasks.md` — 10 task units, all [x] complete
- ✅ `apply-progress.md` — Delivery record (PR1 detail + aggregate summary)
- ✅ `archive-report.md` — This file

Archived to: `openspec/changes/archive/2026-09-16-promote-research-sdd-target-tools/`

### Tracking Warnings Resolved

Three tracking issues identified during proposal/design were resolved:

1. **Registry placement for non-file-artifact tools** (Design §AD1) — **RESOLVED**: New `### Live-probe / install-audit instruments` subsection added to `tool-registry.md` (PR1). Maintains zero churn to file-artifact rows; mirrors existing `### Deliverable / report generation` precedent. Probe/live-audit rows use separate 5-col table: `| Input / trigger | Detection | Approach | Wrapper | Tested |`.

2. **Evidence-schema doc requirement** (Design §AD2) — **RESOLVED**: 9 JSON-emitting wrappers include `<schema>.v1.md` doc per `kit-instrument-honesty` §7. Render-only tool (`px-render`) outputs HTML; registry row documents output format inline (no schema doc required). Bacnet pilot retrofitted with `bacnet-evidence.v1.md`.

3. **px-render stdlib-only feasibility** (Design §OQ1) — **RESOLVED**: PR10 confirmed stdlib-only HTML generation feasible. No external templating dependency required; no `INSTALLED-TOOLS.md` row added.

## Architecture Decisions Archived

1. **Registry placement** — New subsection rather than new column (preserves file-artifact row integrity)
2. **Evidence-schema docs** — Required for JSON-emitting wrappers; HTML-render tools document inline
3. **Tool classification** — 6 file-artifact + 3 probe/audit + 1 render = 10 total promotions
4. **Per-wrapper pattern** — 4-line `.sh` shell wrapper + Python impl + companion `*.test.sh`
5. **Three-state exit convention** — File-artifact: 2=absent/unreadable, 1=parse-error, 0=ok; Probe: 3=plan-only, 0=ok, 1=negative, 2=op-error

## Final State

**Artifact store mode**: openspec (git-tracked `openspec/changes/`, synced to `openspec/specs/`)

**Implementation route**: Delegated direct (10 PR writers + FABLE review gate per PR)

**Delivery strategy**: auto-chain (stacked-to-main, serialized on `tool-registry.md` per §12-7)

**Review workload**: 10 PRs × ~300–400 lines each = ~3000–4000 total lines; Low risk per-PR budget

**Rollback boundary**: Any wrapper can be rolled back independently by reverting its PR and re-running registry sync; all wrappers are additive.

## Cycle Closure

✅ **Proposal**: Accepted (2026-09-14, SDD launched)
✅ **Spec**: Published to `openspec/specs/kit-target-tool-promotion/spec.md`
✅ **Design**: Approved (2026-09-15, architecture decisions finalized)
✅ **Tasks**: Defined and completed (2026-09-16, all 10 units [x])
✅ **Apply**: Complete (11 PRs merged 2026-09-15 to 2026-09-16)
✅ **Verify**: PASS (0 critical, 118/2865 gates pass, no blockers)
✅ **Archive**: Complete (2026-09-16, this report)

**SDD cycle for this change is complete.** The research-sdd toolbelt now includes 10 clean, tested, honest, registered evidence wrappers for general research capabilities. The `kit-target-tool-promotion` capability is standardized and available for future promotions.

---

**Archive prepared by**: sdd-archive (haiku-4.5)
**Archive date**: 2026-09-16
**Change name**: promote-research-sdd-target-tools
**Artifact store**: openspec (hybrid-capable)
