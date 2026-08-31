# Design: Improve Research-SDD SessionStart Bootstrap Messages

## Technical Approach

Apply the kit's OWN silent-on-clean idiom (`sweep-tools-hook.sh:22-42`) to the four always-emit
SessionStart hooks. Each guard sits AFTER the untouched operational-failure block and BEFORE the
success emit block, parsing the underlying script's STABLE `Summary:` counts. Silence triggers ONLY
on a positive clean count; a missing Summary line surfaces loudly (anti-silent-zero). The rc≠0
failure-banner path is never modified — this is the load-bearing §7 invariant.

## Architecture Decisions

| Decision | Choice | Rejected alternative | Rationale |
|---|---|---|---|
| Guard signal | Parse `Summary:` counts | Parse clean sentences ("Nothing to review.", "Registry consistent") | Counts give a free anti-silent-zero missing-Summary guard (mirrors `sweep-tools-hook.sh:27`); sentence-only cannot tell "clean" from "broken instrument that printed nothing". |
| Registry guard | Parse Summary line `verify-registry.sh:439` (drift+retro_drift+unresolved+rowlint all 0) | Explore's `grep -q 'Registry consistent'` | `:443-444` gates that sentence on drift/retro_drift/unresolved only — NOT `rowlint`. A `rowlint>0` run still prints it, so a sentence guard would SILENCE actionable oversized rows. Count-parse closes that hole. |
| Guard placement | After the `if [ "$rc" -ne 0 ]` block, before success emit | Inside the emit block | Keeps the loud failure path byte-for-byte intact; silence is a positive exception, default is emit. |
| Idiom reuse | Reuse `sweep-tools-hook.sh` shape verbatim | New helper/idiom | No new pattern; one established, tested idiom across all hooks. |

## Data Flow

    SessionStart ─→ *-hook.sh ─→ underlying *.sh (captured as $out, rc)
                        │
              rc≠0 ─────┴─→ LOUD "could not run" banner (UNTOUCHED)   ← §7 failure path
              rc=0 ─→ extract Summary ─→ missing? ─→ LOUD missing-Summary banner (anti-silent-zero)
                                          count>0 ─→ emit findings header
                                          count=0 ─→ exit 0 SILENT      ← new behavior

## D1 — Silence Guards (each mirrors `sweep-tools-hook.sh:22-42`)

| Hook | Stable token parsed | Silence condition |
|---|---|---|
| `sweep-retros-hook.sh` | `sweep-retros.sh:171` `Summary: N pending / …` | `[ "${pending:-0}" = "0" ] && exit 0` |
| `sweep-audits-hook.sh` | `sweep-audits.sh:120` `Summary: N pending / …` | `[ "${pending:-0}" = "0" ] && exit 0` |
| `sweep-breakthroughs-hook.sh` | `sweep-breakthroughs.sh:171` `… N unindexed · N drifted.` | `[ "${unindexed:-0}" = "0" ] && [ "${drifted:-0}" = "0" ] && exit 0` |
| `verify-registry-hook.sh` | `verify-registry.sh:439` `… N count drift(s) · N retro drift(s) · N unresolvable · N oversized row(s).` | all four `= 0` → `exit 0` |

Each hook first does `summary="$(printf '%s\n' "$out" | grep '^Summary:')"`; if empty → LOUD
missing-Summary banner + `exit 0` (copy of `sweep-tools-hook.sh:27-36`). Counts parsed with
`grep -oE '[0-9]+ <label>' | grep -oE '^[0-9]+'`. Guard inserted between line 18 (end of failure
block) and line 20 (success emit) in all four hooks.

## D2 — "Ledger consistent" clean sentence

In `sweep-breakthroughs.sh`, after the Summary echo (`:171`), before the `warn_unindexed>0` block
(`:175`), add — parallel to `sweep-retros.sh:176` / `verify-registry.sh:444`:

    if [ "$warn_unindexed" -eq 0 ] && [ "$warn_drift" -eq 0 ]; then
      echo "Ledger consistent — all tagged breakthroughs indexed, no drift."
    fi

The `sweep-breakthroughs-hook.sh` guard parses Summary `unindexed`+`drifted` counts, NOT this
sentence — so D2 and the guard are decoupled and land order-independently.

## D3 — Header wording fixes

| File | Line | From | To |
|---|---|---|---|
| `sweep-retros-hook.sh` | 10 (failure hdr) | "retros sweep" | "retro sweep" (matches success `:22`) |
| `verify-registry-hook.sh` | 21 (jq) + 25 (printf fallback) | "registry drift" | "registry check" (matches failure `:10`; "drift" wrongly implies findings on clean) |

## Testing Strategy (Strict TDD, kit §4)

Four hook tests — flip test 4, add test 5, add silence teeth (test 3 operational banner UNCHANGED):

| Test | Stub | Assertion |
|---|---|---|
| 4 (flipped) | rc=0, Summary with 0 count | output EMPTY / no header → silent |
| 5 (new) | rc=0, Summary with nonzero count | findings header present |
| tooth A (kept) | rc=1 | rc-neuter mutant → test 3 RED |
| tooth B (new) | rc=0 clean | mutate silence guard `&& exit 0` → `&& true`; clean case now emits header → **test 4 goes RED** |

`&& exit 0` uniquely matches the silence line (failure block uses bare indented `exit 0`), so the
mutation is targeted.

New `verify-kit-clean-hook.test.sh` (hook `verify-kit-clean-hook.sh` has no companion test):

| Case | Stub rc | Assertion |
|---|---|---|
| 3 | 0 (clean) | output EMPTY → silent (`:7`) |
| 4 | 1 (dirty) | "KIT is NOT clean" banner (`:11`) |
| 5 | 2 (misconfigured) | "could not run" banner (`:13`), distinct from case 4 |
| tooth A | 0 | mutate `[ "$rc" = 0 ] && exit 0` → `&& true`; clean now emits → **case 3 RED** |
| tooth B | 2 | mutate `if [ "$rc" = 1 ]` → `if true`; rc=2 emits DIRTY banner → **case 5 RED** |

Acceptance also runs `run-all.sh` and `--prove-teeth` (kit §5); every silence guard must have a teeth
control that goes red.

## Threat Matrix

Applicable boundary: shell subprocess output parsing + exit-code integrity (no NEW subprocess,
routing, VCS/PR automation, or executable classification — those rows N/A).

| Threat | Applicable | Safe behavior | RED test |
|---|---|---|---|
| Silence guard swallows operational failure (rc≠0) | Yes | Guard is AFTER failure block; rc≠0 path untouched | tooth A (rc-neuter → banner test RED) |
| Broken instrument (rc=0, no Summary) read as clean | Yes | Missing-Summary → LOUD banner (anti-silent-zero) | test asserts missing-Summary emits |
| Wording drift silently breaks guard | Yes | Guards parse stable Summary counts + teeth on silence path | tooth B |
| New routing / subprocess / VCS automation | N/A | No new process spawned; `$out` already captured | — |

## PR #2 Sketch (chained, D4 — §7 done properly)

Distinct exit-code contract across `sweep-retros.sh`, `sweep-audits.sh`, `sweep-breakthroughs.sh`,
`verify-registry.sh`, disambiguating today's conflated `exit 1` (`sweep-retros.sh:42-45` absent vs
`:54-58` empty):

| State (§7) | Underlying exit | Hook message |
|---|---|---|
| absent-input (TARGETS.md missing/unreadable) | e.g. `3` | "could not run — TARGETS.md not found" |
| broken-input (present, unparseable / undefined `lib/` helper) | e.g. `4` | "could not run — TARGETS.md/helper broken" |
| empty-input (present, 0 rows) | distinct code or `0` + sentence | "no targets registered yet" (distinct, not an error) |
| no-match (rows exist, none pending) | `0` clean | silent (PR #1) |

Each hook maps every code to a distinct message; tests assert the three input-states stay
distinguishable. Kept a sketch — PR #1 is the primary slice; PR #2 auto-chains on its branch.

## Migration / Rollout

No migration, no state. Per-file revert restores prior always-emit behavior; each PR is an
independent revertible slice.

## Open Questions

- [ ] None blocking. Registry rowlint hole is resolved by the count-parse decision above.
