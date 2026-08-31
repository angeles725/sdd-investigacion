# Proposal: Improve Research-SDD SessionStart Bootstrap Messages

## Doctrine Preservation (headline — non-negotiable)

This change **improves** kit doctrine; it must never **replace or erode** it.

- **§7 Anti-Silent-Zero stays inviolable.** `absent-input` vs `empty-input` vs `no-match` MUST remain distinguishable in every message. "Silence-on-clean" applies ONLY to the genuinely-clean path (instrument looked, found nothing actionable). Operational failures stay LOUD (exit≠0, visible banner). We are APPLYING the kit's OWN existing silent-on-clean idiom (already in `sweep-tools-hook.sh`, `verify-tool-catalog-hook.sh`, `verify-kit-clean-hook.sh`) consistently — not inventing a new pattern.
- **§8 propose-never-apply stays intact.** Instruments remain WARN-only about findings and exit≠0 on operational failure. No fix may blur a real error into a friendly "nothing here."

**Doctrine risk of getting it wrong:** a silence guard that swallows an operational failure (broken TARGETS.md, undefined `lib/` helper) would convert a §7 loud error into a confident silent zero — the exact defect §7 exists to prevent. Every guard exits BEFORE the emit block only on the *clean* signal; the *failure* banner path is untouched.

## Intent

Four of seven SessionStart hooks always emit output on success, injecting multi-line sweep noise into every fresh session even when nothing is actionable — inconsistent with three sibling hooks that already stay silent on clean. Plus: no "all clean" sentence for breakthroughs (D2), success/failure header wording drift (D3), and absent-vs-empty TARGETS.md conflated to one error banner (D4).

## Scope

### In Scope
- **PR #1 (~147 lines):** D1 silence-on-clean guards on the 4 always-emit hooks; D2 "Ledger consistent" clean sentence in `sweep-breakthroughs.sh`; D3 header wording fixes; flip test 4 → clean/silent + add test 5 findings-case + mutation teeth; NEW `verify-kit-clean-hook.test.sh`.
- **PR #2 (~80 lines, chained follow-up):** D4 distinct exit-code contract across the 4 underlying scripts so absent-input (missing/broken TARGETS.md) is distinct from empty-input (present, zero rows), plus tests.

### Out of Scope
- Peer's lane (`improve-research-sdd-target-onboarding`): `research-sdd-init.sh`, `PROMPT-LOOP.md`, `research-sdd/templates/*`, `research-sdd-status.sh`.
- `templates/hook-sessionstart.sh` (explore did not require it).

## Delivery (auto-chain)

PR #1 = primary slice. PR #2 (D4) is **deferred-and-scheduled**, explicitly auto-chained — NOT a silent scope trim (§6). Each PR ≤400 authored touched lines.

## Capabilities

### New Capabilities
- None (kit-internal shell tooling; no `openspec/specs/` capability).

### Modified Capabilities
- None (behavioral fix to hook wrappers; no spec-level requirement change).

## Approach

Approach A — output-token parsing, mirroring `sweep-tools-hook.sh`. Each guard parses the underlying script's STABLE output tokens / Summary counts and exits 0 silently only on the clean signal:
- `sweep-retros-hook.sh`: no `PENDING`/`MISSING-RETRO` line → silent; fix failure header `retros sweep`→`retro sweep`.
- `sweep-audits-hook.sh`: no `PENDING` line → silent.
- `sweep-breakthroughs-hook.sh`: parse Summary `unindexed`+`drifted` counts (0+0 → silent) — decoupled from the D2 sentence, so it does NOT depend on D2 landing first.
- `verify-registry-hook.sh`: `Registry consistent` present → silent; fix success header `registry drift`→`registry check` (neutral; "drift" wrongly implies findings on a clean run).

TDD (§4): failing test first, confirm right-reason red, implement, then mutate the silence guard → the clean/silent case MUST go RED. Cross-lane coupling with `research-sdd-status.sh` is CLEARED (peer confirmed it does not parse breakthroughs output).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/sweep-retros-hook.sh` | Modified | silence guard + header fix |
| `research-sdd/toolbelt/sweep-audits-hook.sh` | Modified | silence guard |
| `research-sdd/toolbelt/sweep-breakthroughs-hook.sh` | Modified | silence guard (Summary counts) |
| `research-sdd/toolbelt/verify-registry-hook.sh` | Modified | silence guard + header fix |
| `research-sdd/toolbelt/sweep-breakthroughs.sh` | Modified | D2 "Ledger consistent" sentence |
| `research-sdd/toolbelt/tests/{4 hook}.test.sh` | Modified | test 4 flip + test 5 + teeth |
| `research-sdd/toolbelt/tests/verify-kit-clean-hook.test.sh` | New | rc=0 silent / rc=1 dirty / rc=2 misconfigured + teeth |
| (PR #2) 4 underlying `sweep-*`/`verify-registry.sh` + tests | Modified | D4 distinct exit codes |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Silence guard swallows an operational failure (§7 violation) | Med | Guard triggers only on clean token; failure banner path untouched; teeth prove clean-case goes red |
| Hook-to-string coupling — script wording change silently breaks guard | Med | Hook tests carry teeth on the silence path; guards parse stable tokens/Summary counts |
| Test 4 behavioral flip mis-implemented | Low | Explicit test 4 (clean→silent) + test 5 (findings→header) + mutation control |
| D4 deferred: absent/empty still conflated until PR #2 | Low | Documented as scheduled chained PR, not dropped |

## Rollback Plan

Per-file revert of the hook guards and the `sweep-breakthroughs.sh` sentence restores prior always-emit behavior. Each PR is an independent, revertible slice; no data migration, no state. Reverting PR #1 leaves the kit exactly as today.

## Dependencies

- None external. PR #2 chains on PR #1 branch (auto-chain).

## Success Criteria

- [ ] The 4 hooks stay SILENT on a genuinely clean run; still emit on findings.
- [ ] Operational failures (missing/broken TARGETS.md, undefined helper) still exit≠0 with a visible banner — §7 preserved.
- [ ] `sweep-breakthroughs.sh` prints a "Ledger consistent" clean sentence.
- [ ] Header wording consistent success vs failure (D3).
- [ ] New `verify-kit-clean-hook.test.sh` covers rc=0/1/2 with mutation teeth.
- [ ] `run-all.sh` and `--prove-teeth` green; every new silence guard has a teeth control that goes red.
- [ ] PR #2 (D4) delivers distinct absent-vs-empty exit-code contract with tests.
