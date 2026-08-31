# Proposal: Declared-State Sentinel for SessionStart Sweep/Verify Instruments

## Intent

The 4 SessionStart sweep/verify instruments always dump full prose on `rc=0`, so a clean run is as noisy as one with findings. The prior fix — silencing by re-parsing free-form prose — was FABLE-blocked as §6-fragile (prose has no schema). We instead apply §6 doctrine-first: the SCRIPT declares its own aggregate state from its own counters; the hook reads that verdict to decide silence. This also structurally closes the §7 false-clean hazard: a missing verdict is treated as not-clean (loud).

## Scope

### In Scope
- Add an UNCONDITIONALLY-LAST stdout line `RSDD-STATE: clean|attention|partial` to each of the 4 scripts, computed from existing counters.
- Update each of the 4 hooks to stay silent only on `clean`; emit on `attention`/`partial`/missing sentinel; hooks ALWAYS `exit 0`.
- Add tests: per-script state computation (clean/attention/partial) + per-hook silent-on-clean, emit-on-attention, emit-on-missing-sentinel (mutation tooth).

### Out of Scope
- No exit-code contract changes (stdout-only sentinel).
- No per-corpus §7 labeling for retros/audits (pre-existing gap — separate change).
- No changes to already-silent hooks (sweep-tools / verify-tool-catalog / verify-kit-clean — reference-only).
- No touching research-sdd-init.sh, PROMPT-LOOP.md, or templates/* (peer change `improve-research-sdd-target-onboarding`).

## Capabilities

### New Capabilities
None (kit-internal instrument behavior; no OpenSpec spec surface).

### Modified Capabilities
None.

## Approach

Approach D from explore. State mapping: retros/audits → clean if `pending=0 AND no MISSING-RETRO AND skipped=0`, partial if `skipped>0`, else attention. breakthroughs → clean if `warn_unindexed=0 AND warn_drift=0 AND skipped=0` (per-corpus INFO stays prose, does not force attention). registry → clean if `drift=0 AND retro_drift=0 AND unresolved=0 AND rowlint=0 AND skipped=0`. Hook: `grep '^RSDD-STATE:' | tail -1` → silent only on `clean`; missing → loud. Base on POST-#376 main so its "Ledger consistent" prose precedes the sentinel.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `toolbelt/sweep-{retros,audits,breakthroughs}.sh`, `verify-registry.sh` | Modified | +2 lines each: compute state, echo sentinel last |
| `toolbelt/{sweep-retros,sweep-audits,sweep-breakthroughs,verify-registry}-hook.sh` | Modified | +~5 lines each: read verdict, silence branch |
| `toolbelt/tests/*` (8 files) | Modified | Sentinel + silence + missing-sentinel mutation assertions |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Sentinel not truly last (WARN after it) breaks `tail -1` | Med | Emit after all output; test asserts last line |
| Missing sentinel read as clean (silent zero) | Low | Hook fails loud on missing; mutation tooth strips emit |
| #376 prose ordering conflict | Med | Base on post-#376; sentinel goes last |
| `verify-registry.sh set -uo pipefail` | Low | Sentinel is bare echo — no pipeline/unbound var |

## Rollback Plan

Revert the single PR. No exit codes, receipts, or on-disk formats change; sweep-all.sh and manual callers ignore the extra stdout line, so partial revert is safe.

## Dependencies

- PR #376 merged to main (sweep-breakthroughs "Ledger consistent" line precedes sentinel).

## Success Criteria

- [ ] Each script emits `RSDD-STATE: clean|attention|partial` as the last stdout line.
- [ ] Each hook stays silent on `clean`, emits otherwise, and always exits 0.
- [ ] Missing-sentinel mutation makes the hook go loud (tooth bites).
- [ ] All existing RC=0 assertions and sweep-all.sh remain green (zero exit-code churn).
- [ ] `--prove-teeth` and shellcheck pass; change stays within the 400-line budget.
