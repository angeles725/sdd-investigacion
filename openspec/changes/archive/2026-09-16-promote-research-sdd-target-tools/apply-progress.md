# Apply Progress: promote-research-sdd-target-tools

## Status

**COMPLETE — 10/10 work units merged to origin/main (11 PRs).**

| PR | Tool | PR # |
|----|------|------|
| PR1 | corroborate-bacnet | #513 |
| PR2 | qnx6-read | #515 |
| PR3 | serial-frame-analyze / serial-frame-capture | #516 / #517 |
| PR4 | niagara-hdb-read | #519 |
| PR5 | niagara-security-audit | #520 |
| PR6 | module-find | #522 |
| PR7 | bog-nav | #523 |
| PR8 | station-modules | #524 |
| PR9 | palette-lexicon-agents | #525 |
| PR10 | px-render | #526 |

Verify: PASS (0 critical). Gates: 118 suites / 2865 cases / 0 failed; shellcheck 0; §9 clean fleet-wide. All 10 promoted suites carry mutation teeth + banner. Each wrapper passed an adversarial FABLE gate; px-render took 3 FABLE corrections (XSS, containment root, dedup/teeth/cap accounting).

_The PR1 detail below is the original first-unit record; PR2–PR10 followed the same per-wrapper cadence (writer → FABLE → correction(s) → §19 re-check → orchestrator verify → merge)._

## Completed Tasks (PR1)

- [x] 1.1 Added `### Live-probe / install-audit instruments` subsection to `tool-registry.md` with 5-col table (`Input / trigger | Detection | Approach | Wrapper | Tested`)
- [x] 1.2 Added `corroborate-bacnet` row: Input/trigger = `` `host:port` ``; Detection = live BACnet/IP host (UDP/47808)
- [x] 1.3 Wrote `research-sdd/toolbelt/bacnet-evidence.v1.md` — plan-only + live-probe schema tables, three-state honesty, non-goals, output layout
- [x] 1.4 Gate passed: shellcheck zero warnings; run-all.sh 108/108 suites pass; --prove-teeth 108/108 pass; verify-tool-catalog exit 0 no new warnings

## Files Changed (PR1)

| File | Action | Notes |
|------|--------|-------|
| `research-sdd/toolbelt/tool-registry.md` | Modified | New `### Live-probe / install-audit instruments` subsection + corroborate-bacnet row |
| `research-sdd/toolbelt/bacnet-evidence.v1.md` | Created | Schema doc for bacnet-evidence.v1.json |

## TDD Cycle Evidence (Strict TDD Mode)

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 1.1 | N/A (docs only) | N/A | ✅ 108 suites/2163 cases | ➖ Structural change — single output | ✅ Gate passed | ➖ Single: docs have one form | ➖ None needed |
| 1.2 | N/A (docs only) | N/A | ✅ (same baseline) | ➖ Structural change — single output | ✅ Gate passed | ➖ Single row | ➖ None needed |
| 1.3 | N/A (docs only) | N/A | ✅ (same baseline) | ➖ Structural change — single output | ✅ Gate passed | ➖ Single schema doc | ➖ None needed |
| 1.4 | `corroborate-bacnet.test.sh` (pre-existing) | Shell integration | ✅ 108/108 before changes | N/A — gate run, not new code | ✅ 108/108 after changes, --prove-teeth 108/108 | N/A | N/A |

Note: Tasks 1.1–1.3 are purely documentation (registry rows and schema doc). No production code written.
Triangulation skipped for all three: structural changes with one possible output, no branching logic.
The existing corroborate-bacnet.test.sh already has a teeth banner matching `^\s*(--|==)\s*teeth\b` and mutation controls (M1, M2).

## Work Unit Evidence

| Evidence | Value |
|---|---|
| Focused test command | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` |
| Focused test result | 108 suites passed, 0 failed; 2621 cases passed, 8 skipped, 0 failed |
| Runtime harness | N/A — PR1 includes corroborate_bacnet.py (plan-only guard + T7 try/except); gate validates no live I/O |
| Rollback boundary | Revert `tool-registry.md` new subsection; delete `bacnet-evidence.v1.md` |

## Worktree

Branch: `feat/corroborate-bacnet`
Worktree: `/home/cristian/investigacion/sdd-investigacion/.claude/worktrees/agent-ab9711ffc24476ce9`
Base commit: `8cafc2c` (pilot impl)

## Gate Results

```
shellcheck -S warning research-sdd/toolbelt/**/*.sh  →  EXIT:0 (zero warnings)
bash research-sdd/toolbelt/tests/run-all.sh          →  108/108 suites, 2163 cases, 0 failures
bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth  →  108/108 suites, 2621 cases, 0 failures
bash research-sdd/toolbelt/verify-tool-catalog.sh    →  EXIT:0 (27 cataloged, 0 not cataloged)
```

## Side Effects Observed

The `--prove-teeth` run caused `corroborate-ifc.test.sh` to regenerate two fixture files
(`tests/fixtures/corroborate-ifc/empty.ifc`, `tests/fixtures/corroborate-ifc/valid.ifc`) with
today's timestamp and new GUIDs. These are transient test artifacts from the gate run — not
part of PR1's scope. The orchestrator should handle them separately (they are not staged and
can be restored with `git checkout` if needed).
