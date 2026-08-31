# Design: Declared-State Sentinel for SessionStart Sweep/Verify Instruments

## Technical Approach

Approach D. Each of the 4 scripts computes an aggregate verdict from its OWN existing
counters and emits it as the UNCONDITIONALLY-LAST stdout line
`RSDD-STATE: clean|attention|partial`. Each hook reads that verdict with
`grep '^RSDD-STATE:' | tail -1` and stays silent ONLY on `clean`; every other value —
including a MISSING sentinel — falls to the existing loud emit. Exit codes are untouched
(0/1); `sweep-all.sh` and the 25+ RC=0 assertions are unaffected. §6 doctrine-first: the
script declares state; the hook checks the declaration, never re-parses prose.

## Architecture Decisions

| Decision | Choice | Rejected | Rationale |
|---|---|---|---|
| Signal channel | Last-line stdout sentinel | New exit code 3 | Exit-3 breaks 25+ `RC=0` attention assertions + `sweep-all.sh` FAIL logic (explore blast radius). Sentinel = zero exit churn. |
| Missing-sentinel semantics | Treat as NOT-clean → emit | Default to clean | §7 anti-silent-zero: absent verdict must fail loud, not silent-pass. This is the load-bearing invariant. |
| State precedence | clean iff all-findings-zero AND skipped=0; else emit | per-finding branching | Only `clean` gates silence; attention vs partial both emit, so precedence never affects correctness. |

## Per-Script Sentinel (placement + expression from that script's OWN vars)

Uniform tail appended as the script's final statement:

```sh
if [ "$FINDINGS" -eq 0 ] && [ "$skipped_count" -eq 0 ]; then st=clean
elif [ "$skipped_count" -gt 0 ] && [ "$FINDINGS" -eq 0 ]; then st=partial
else st=attention; fi
echo "RSDD-STATE: $st"
```

| Script | `FINDINGS` = | Goes AFTER (must follow) | Note |
|---|---|---|---|
| `sweep-retros.sh` | `pending + missing_retro` | line 243 (waived-report block, the last stdout after the MISSING-RETRO pass) | MISSING-RETRO is currently only printed (line 237), not counted — ADD `missing_retro=0` before the fleet loop and `missing_retro=$((missing_retro+1))` at line 237. `skipped_count` exists (line 60/62). |
| `sweep-audits.sh` | `pending` | line 130 (end of pending-hints block) | `pending` (line 69/92), `skipped_count` (line 58/60). No MISSING-RETRO pass here. |
| `sweep-breakthroughs.sh` | `warn_unindexed + warn_drift` | after the post-#376 "Ledger consistent" branch; today the last stdout is line 180 | Per-corpus INFO (absent/empty/no-match, lines 106/120/145) stays prose and does NOT force attention. |
| `verify-registry.sh` | `drift + retro_drift + unresolved + rowlint` | after summary block (ends line 448), BEFORE `exit 0` (line 451) | All 5 vars initialised before use (drift/retro_drift/unresolved line 88, rowlint line 412, skipped_count line 76). |

### `verify-registry.sh` `set -uo pipefail` safety (line 22)
The sentinel is a **bare `echo`** — no pipeline (pipefail-immune) and every referenced var is
assigned before the sentinel on all paths reaching line 448, so `set -u` cannot trip. The
WARN-only early `exit 0` at line 73 (no usable paths) intentionally emits NO sentinel →
the hook sees a missing verdict → loud. That is §7-correct and needs no special-casing.

## Per-Hook Silence Branch (all 4 identical twins)

Insert AFTER the unchanged rc≠0 failure block (closes at line 18) and BEFORE the existing
emit (line 20). The rc≠0 block and its `exit 0` are untouched; the hook exits 0 on every
path.

```sh
state="$(printf '%s\n' "$out" | grep '^RSDD-STATE:' | tail -1 | awk '{print $2}')"
if [ "${state:-}" = "clean" ]; then
  exit 0    # clean → silent
fi
# attention / partial / MISSING sentinel → fall through to existing loud emit
```

MISSING sentinel ⇒ `state` empty ⇒ `"${state:-}"` ≠ `clean` ⇒ emit. Anti-silent-zero holds.

## Data Flow

    script counters ──► "RSDD-STATE: <st>" (last stdout line)
                              │
       hook: out=$(script 2>&1); rc=$?
         rc≠0 ─► failure banner ─► exit 0        (unchanged)
         rc=0 ─► grep|tail|awk ─► st==clean ? exit 0 silent : emit $out ─► exit 0

## File Changes

| File | Action | Change |
|---|---|---|
| `toolbelt/sweep-retros.sh` | Modify | +`missing_retro` counter (init + incr@237) + sentinel tail |
| `toolbelt/sweep-audits.sh` | Modify | sentinel tail (~4 lines) |
| `toolbelt/sweep-breakthroughs.sh` | Modify | sentinel tail after Ledger-consistent line |
| `toolbelt/verify-registry.sh` | Modify | sentinel tail before final `exit 0` |
| `toolbelt/{sweep-retros,sweep-audits,sweep-breakthroughs,verify-registry}-hook.sh` | Modify | +silence branch (~4 lines each) |
| `toolbelt/tests/*` (8 files) | Modify | sentinel + silence + missing-sentinel assertions + teeth |

## Testing Strategy (Strict TDD, kit §4 — each test carries a mutation tooth)

| Layer | Test | Tooth (must genuinely apply to source) |
|---|---|---|
| Script | clean stub → last line `RSDD-STATE: clean`; attention stub (finding>0) → `attention`; skipped-only stub → `partial` | `sed` drops one FINDINGS term (retros: `missing_retro`; registry: `rowlint`; +`skipped_count` guard) → that case's verdict flips → RED. Pattern MUST match the written expression (no silent no-op). |
| Hook | clean sentinel → SILENT; attention sentinel → EMIT; **MISSING sentinel → EMIT** | (a) mutate guard `= "clean"` → `= "attention"`/`if false` ⇒ clean case no longer silent → RED. (b) mutate default `${state:-}` → `${state:-clean}` ⇒ MISSING case defaults clean/silent → RED (proves anti-silent-zero). |

Assert the sentinel is the LAST line (`tail -1`) so a stray later WARN is caught. Hooks
must contain the literal `"${state:-}"` and `= "clean"` tokens so both teeth patterns bite.

## Threat Matrix

N/A for all rows — no routing, git/PR automation, executable-file classification, or new
external input. The only process boundary is a subprocess wrapper parsing script-generated
stdout; its risks (`set -u`/pipefail safety, missing-verdict fallback) are handled as design
responses above, not adversarial-input rows.

## Migration / Rollout

No migration. Additive stdout + additive hook branch; revert = single-PR revert. Depends on
PR #376 (adds the "Ledger consistent" line to `sweep-breakthroughs.sh`) being merged first so
its prose precedes the sentinel.

## Open Questions

- [ ] PR #376 is NOT yet in the working tree (`grep 'Ledger consistent'` → none). Apply MUST
  rebase onto post-#376 main; if #376 changes the breakthroughs summary tail, re-confirm the
  sentinel is appended after it.
