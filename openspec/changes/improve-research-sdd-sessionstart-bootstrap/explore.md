# Exploration — improve-research-sdd-sessionstart-bootstrap

**Phase:** explore · **Store:** hybrid (engram `sdd/improve-research-sdd-sessionstart-bootstrap/explore` id 7537 + this file)
**Lane:** SessionStart hook bootstrap messages (Primario). Disjoint from `improve-research-sdd-target-onboarding` (Secundario).

## Subject
The messages a fresh Claude session sees, produced by 7 SessionStart hook wrappers registered in `.claude/settings.json` (matcher `startup|resume|clear`), each under `research-sdd/toolbelt/`, wrapping the underlying `sweep-*.sh` / `verify-*.sh` scripts.

## Defects (verified against real files)

### Defect 1 — Always-emit-on-clean count is 4, not 3 (CORRECTED)
Always-emit on success (defect): `sweep-retros-hook.sh`, `sweep-audits-hook.sh`, `sweep-breakthroughs-hook.sh`, `verify-registry-hook.sh` (all lines 20-26, unconditional jq emit, no findings-count guard).
Silent-on-clean (reference model to mirror): `verify-kit-clean-hook.sh:7` (`[ "$rc" = 0 ] && exit 0`), `sweep-tools-hook.sh:42` (`[ "${unrecorded:-0}" = "0" ] && exit 0`), `verify-tool-catalog-hook.sh:44` (`[ "${missing:-0}" = "0" ] && exit 0`).

### Defect 2 — sweep-breakthroughs.sh has no "all clean" sentence (CONFIRMED)
`sweep-breakthroughs.sh:170-171` prints only `Summary: 0 … · 0 unindexed · 0 drifted.` with no follow-on. Contrast: `sweep-retros.sh:175-176` "Nothing to review."; `sweep-audits.sh:124-125` same; `verify-registry.sh:443-444` "Registry consistent with reality (within tolerance ${tol})." Fix ~3 lines.

### Defect 3 — Header wording drift success vs failure (CONFIRMED)
- `sweep-retros-hook.sh`: success:22 "retro sweep" vs failure:10 "retros sweep".
- `verify-registry-hook.sh`: success:21 "registry drift" (implies findings even on clean) vs failure:10 "registry check". "check" is the correct neutral term for the header.

### Defect 4 — Empty/absent TARGETS.md reads as ERROR (CONFIRMED)
`sweep-retros.sh:42-45` (missing → exit 1) and `:54-58` (found but zero usable paths → exit 1, anti-silent-zero guard) both surface via `sweep-retros-hook.sh:9-18` as the same generic "could not run (exit $rc — check TARGETS.md and lib/ helper)" banner. Same pattern in `sweep-audits.sh:40-56`, `sweep-breakthroughs.sh:45-64`, `verify-registry.sh:52-74`.
Proper §7-compliant fix = distinct exit codes across the 4 underlying scripts so absent-input (missing/broken TARGETS.md → real error) stays distinct from empty-input (TARGETS.md present, zero rows → "nothing registered yet"). ~80 lines touching 4 core scripts + their tests. **Delivered as chained PR #2**, not dropped.

### Missing test
`verify-kit-clean-hook.sh` has no companion hook test (only the underlying script is tested). Its rc=0 silent / rc=1 dirty / rc=2 misconfigured branching is untested.

## Recommended approach — A (silence guard mirroring sweep-tools-hook.sh)
Per-hook: parse the underlying script's stable output tokens; exit 0 when no findings.
- retros: no `PENDING`/`MISSING-RETRO` line → silent; also fix "retros sweep"→"retro sweep" failure header.
- audits: no `PENDING` line → silent.
- breakthroughs: parse `unindexed`+`drifted` counts from Summary (0+0 → silent), decoupled from the Defect-2 sentence; add "Ledger consistent" sentence in the script.
- registry: `"Registry consistent"` present → silent; fix success header "registry drift"→"registry check".

§7 is inviolable: absent/empty/no-match stay distinguishable; "clearer" never costs "less honest".

## Budget
D2 sentence +3 · 4 silence guards +32 · 2 wording fixes +2 · 4 hook tests updated (test 4 → clean/silent, add test 5 findings-case + teeth) +~60 · new `verify-kit-clean-hook.test.sh` +~50 = **~147 lines** (PR #1). D4 ~+80 (PR #2). Both within the 400/PR budget.

## Risks
- **Cross-lane coupling (HIGH):** changing `sweep-breakthroughs.sh` output format may couple with `research-sdd-status.sh` (Secundario's lane) if it parses that output. Verify before apply. Mitigation: the breakthroughs silence guard parses Summary counts, not the new sentence, so it does not depend on the Defect-2 change landing first.
- Test-4 behavioral flip: current tests assert "success → header present"; new behavior inverts to "clean → silent" + needs a findings-case test 5 and teeth on the silence guard.
- Defect 4 sequenced as PR #2 (explicit, not silent scope trim).

**Next:** sdd-propose.
