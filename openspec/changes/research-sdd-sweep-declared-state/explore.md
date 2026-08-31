# Exploration — research-sdd-sweep-declared-state

**Phase:** explore · **Store:** hybrid (engram `sdd/research-sdd-sweep-declared-state/explore` + this file)
**Goal:** Replace the dropped hook-parser silence (FABLE-blocked, §6 fragility) with a doctrine-first DECLARED-STATE mechanism for the 4 SessionStart sweep/verify instruments. Lane: mine (sweep/verify scripts + their hooks + tests). Disjoint from peer `improve-research-sdd-target-onboarding` (init.sh/PROMPT-LOOP).

## Current state
Each hook captures the instrument's `rc` (0 vs non-zero) for operational-failure detection, then emits the full prose on rc=0 — no silence decision. The prior attempt silenced by re-parsing that prose; dropped (free-form stdout has no schema — §6).

Current exit-code contracts (verified): all 4 scripts use ONLY exit 0 (normal, findings or clean) and exit 1 (operational failure: TARGETS.md missing / lib helper broken / no usable paths). Exit 2, 3+ unclaimed. `verify-kit-clean-hook.sh` is the only existing multi-exit-code hook (0/1/2).

## Blast radius (why exit codes are ruled out)
Every "attention/findings" test case across the 4 instrument test files asserts `RC = 0` (25+ assertions), and `sweep-all.sh` treats ANY non-zero exit as FAIL. Introducing exit-3 for "has findings" would break all of them. Exit-code signalling = prohibitive churn, no hook-side gain.

## Decision — Approach D: sentinel marker line with §7 vocabulary
Each instrument emits, as the UNCONDITIONALLY LAST stdout line, a prescribed token:

| Token | Meaning | Hook decision |
|---|---|---|
| `RSDD-STATE: clean` | no findings/WARN/PENDING/MISSING-RETRO/drift; complete traversal | SILENT |
| `RSDD-STATE: attention` | WARN / PENDING / MISSING-RETRO / drift / unresolved | EMIT |
| `RSDD-STATE: partial` | skipped/truncated targets — cannot certify clean | EMIT |

The script DECLARES its own state from its own counters (it already computes them); the hook reads the verdict. This is §6 doctrine-first: prescribe the declaration, build the checker against it — not a prose parser.

State mapping per script:
- **sweep-retros.sh:** clean if `pending=0 AND no MISSING-RETRO AND skipped=0`; partial if `skipped>0`; else attention.
- **sweep-audits.sh:** same shape.
- **sweep-breakthroughs.sh:** clean if `warn_unindexed=0 AND warn_drift=0 AND skipped=0`; partial if `skipped>0`; else attention. (Per-corpus absent/empty/no-match INFO stays prose; does not force aggregate attention — correct.)
- **verify-registry.sh:** clean if `drift=0 AND retro_drift=0 AND unresolved=0 AND rowlint=0 AND skipped=0`; partial if `skipped>0`; else attention.

## Hook design (exits-0 invariant preserved)
```
out="$(./instrument.sh 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then emit failure banner; exit 0; fi   # hook ALWAYS exits 0
state="$(printf '%s\n' "$out" | grep '^RSDD-STATE:' | tail -1 | cut -d' ' -f2)"
[ "${state:-}" = "clean" ] && exit 0                        # clean → silent
emit "$out" as additionalContext; exit 0                    # attention/partial/MISSING sentinel → loud
```
Missing sentinel falls to the loud branch (§7 anti-silent-zero). This is the critical mutation tooth: strip the `RSDD-STATE` emit → hook must go loud.

## Budget & chaining
~115 additive lines across 4 scripts + 4 hooks + 8 test files; ~0 deletions. Single PR, within the 400-line budget. No exit-code changes → sweep-all.sh and its 25+ RC=0 assertions untouched.

## Risks
1. **Sentinel must be the LAST stdout line.** Coordinates with PR #376's "Ledger consistent" prose line in sweep-breakthroughs.sh — that prose must precede the sentinel. Base apply on post-#376 main.
2. **Missing-sentinel fallback must be mutation-tested** (loud on absent sentinel).
3. **Per-corpus §7 labeling for retros/audits** (absent/empty/no-match) is a pre-existing gap — out of scope here (aggregate sentinel only).
4. **verify-registry.sh `set -uo pipefail`** — sentinel emit is a bare echo, no pipeline/unbound var; confirm at apply.
5. **sweep-all.sh passes stdout through** — `RSDD-STATE:` lines appear in aggregated output (harmless; no current tool parses them).

**Next:** sdd-propose.
