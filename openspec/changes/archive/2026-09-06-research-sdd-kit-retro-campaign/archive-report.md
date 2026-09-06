# Archive Report: research-sdd-kit-retro-campaign

**Change**: `research-sdd-kit-retro-campaign`
**Archived**: 2026-09-06
**Archived to**: `openspec/changes/archive/2026-09-06-research-sdd-kit-retro-campaign/`
**Main branch tip at archive**: b67e4f7 (docs(retros): §18 self-retrospective of the research-sdd kit campaign)

---

## Summary

The research-sdd kit retro campaign (kit issue #508) has been completed and archived. The campaign delivered 38 work units across three sessions (explorador doctrine/lead, mejorador writer, probador quiet-tree gate) and 43+ merged PRs. The change defines five durable capability specs and closes with a post-campaign self-retrospective in METHODOLOGY §18.

---

## Scope Delivered

### Instrument Units (22 total)

**Core stream** (#1–#5): saturation parser + verify-state + status display + block-type parser + sweep-retros
- U1 #442 0df9a51: saturation parser (header-shape + cell-form recognition)
- U2 #465 fd82e82: verify-state shared-global covered_blocks fix
- U3 #451 0c90262: coverage-map.sh new instrument
- U4 #466 d8cd2c7: status cell bold + unknown token WARN
- U5 #467 11b4e77: block-type parser + synthesis/capture WARN→INFO

**Second stream** (#6–#12): teeth accounting + dentition + unguarded || true
- U6 #462 055d604: run-all.sh teeth accounting + --require-teeth flag
- U7 #475 a26253e: sweep-retros typed delta state + aliases + missing markers
- U8a #478 58bed7e: sweep-retros summary mode + hook clean sentinel
- U8b #488 91e5572: sweep-retros RSDD_PROFILE wall-time profile
- U9 #473 87c26d5: hygiene bundle (gitignore, counters, exec bit, hook path)
- U10 #477 2f8dfec: installed-skill drift detection (suite only)
- U11 #464 f470656: lib/block-files.sh centralised discriminator (16 sites)
- U12 #463 2f83114: 8 unguarded || true → typed three-state handling

**Third stream** (#13–#22): follow-ups and polish
- U13 #474 1c90f59: (continuation)
- U14 #456 6fef040: (continuation)
- U15 #493 82b88fb: (continuation)
- U16 #486 a5d3876: (continuation)
- U17 #490 6ea74c0 + #492 1e9a0a2: (continuation)
- U18 #495 dd2de6b: (continuation)
- U19 #491 e973341: (continuation)
- U20 #496 af83e7a: (continuation)
- U21 #503 bcb3fdf: (continuation)
- U22 #504 ec3d8e4: (continuation)

### Doctrine Units (16 total)

**Foundation** (#1–#5): freeze-first + Engram fallback + shared-global + delta grammar + templates
- D1 + D5 #434 272e1ad: §20 freeze-first + §7 Engram fallback + §3 marker-taxonomy
- D2 #446 7349004: DYNAMIC-SETUP + DEPLOY-WINDOWS-MINIPC.md + 15 tool-registry rows
- D3 #445 fe88d17: PROMPT-LOOP SYNTHESIS-GUIDE + SECRETS
- D4 #427 f73f5d6: §16 shared-global rules + FOCUSES status grammar
- D6 #430 2380544: §18 countable-delta + §4 Type + §8 coverage + templates

**Continuation** (#7–#16): further doctrine closure
- D7 #448 185ad74: (continuation)
- D8 #452 e0b701a: (continuation)
- D9 #455 da2781b: (continuation)
- D10 #458 ab83e5f: (continuation)
- D11 #461 e042726: (continuation)
- D12 #470 fd6762f: (continuation)
- D13 #472 a6e62eb: (continuation)
- D14 #481 bd262f5: (continuation)
- D15 #487 7ad2b92: (continuation)
- D16 #485 24069c3: (continuation)

### Planning Artifacts

- #444 f1435e6: tasks.md + delivery strategy (stacked-to-main)
- #459 4e714be: additional planning support

### Verification and Closure

- **Verify report**: #498 5f58efa (verdict FAIL: 1 CRITICAL, remediated by #502 34729a1)
  - Critical finding: missing tool-registry.md row for DEPLOY-WINDOWS-MINIPC.md (created by D2, PR #446, but not registered while siblings were)
  - Remediation: #502 34729a1 adds the row + aligns coverage spec literals + records measured budget
  
- **Campaign §18 retro**: #507 b67e4f7 (verify-retro.sh OK, 10 new deltas, 17 already-covered, 4 measured dismissals)

---

## Measured Outcomes

### Parser and Toolbelt Performance

- **Saturation parser (U1)**: BLIND 35 → 0 on post-state (34729a1: 74 files, 52 with history = 30 readable / 8 no-column / 12 unreadable-window / 2 insufficient)
- **Coverage over subject (U3)**: niagara 174/318 modules cited; 144 never cited (spec had pinned 148 — rule kept, number dated)
- **Test suite runtime**: run-all 471.5 s → 212.9 s (−55%)
- **SessionStart context size**: 26,979 → 6,127 chars (spec target 8,000 met; closed, findings never trimmed)
- **Sweep block-newest pass**: 56 s → 8.9 s
- **HOT-CORE lines**: 823 → 664 lines

### Dentition and Teeth Discipline

- **21 shell suites without teeth** made visible via --require-teeth flag
- **11 + 2 unguarded || true** converted from silent-zero to typed three-state handling
- **lib/block-files.sh centralization**: 16 discriminator sites converged to single source
- **Mutation control**: --prove-teeth green on final run

---

## Verification Gates at Close

**Probador record + verify agent (identical runs)**:

- Shellcheck: 173 files / 0 warnings
- run-all: 106/106 suites · 2,148 cases · 0 failed (after U22)
- --prove-teeth: green
- verify-doc-consistency: 0 findings

---

## Open Follow-ups (Not Blockers)

- **U23 #506** (coverage-map.sh:206 xargs cat, low priority, incidence 0, in progress by mejorador)
- **10 retro deltas of #507** (propose-never-apply, scheduled for next campaign)

---

## Operator-Only Items (Propose-Never-Apply)

These items require explicit human decision and action per §18 doctrine. The kit proposes; the operator applies.

- Operator adds `Retro:` applied-session trailer in target corpora for each retro whose deltas landed in this campaign
- `TARGETS.md`: operator refreshes affected rows after corpus-size change (U2, U3 changed observed block counts)
- `FOCUSES.md`: operator refreshes active-focus status fields using D4 closed vocabulary (active, paused, stopped, planned)
- `BREAKTHROUGHS.md`: operator refreshes after new findings logged by this campaign
- Stale worktrees: operator runs `git worktree prune` on machines with stale `.claude/worktrees/` entries (now in .gitignore per U9)
- Installed SKILL.md: operator runs skill installer to refresh stale copy (15 lines / 5 hunks behind; U10 detects drift)
- Orphan openspec change: operator closes or merges `openspec/changes/improve-research-sdd-target-onboarding/` if open
- Wire §18 Stop hook: operator adds `retro-gate.sh` snippet to each target's `.claude/settings.json` (printed by `research-sdd-init.sh`)
- Push local retro-marker commits: operator pushes niagara-research and panccadia-3d-viewer local retro commits
- Resolve ESCALATED pending kit retro: retro/2026-08-28-doctrine-lane-seven-units-and-teeth-discipline.md (8+ days pending) must be resolved before new retro work starts per §18

---

## Process Facts

- **Three sessions**: explorador (doctrine/lead, shared checkout main never advanced), mejorador (single writer, disjoint file sets per task), probador (quiet-tree gate verification)
- **Apply phase**: ran as peer sessions without sdd-apply agent or attempt ledger
- **Every PR**: issue-first with `Closes #N`
- **Shared checkout state**: local main never advanced; all work in worktrees only
- **Total PRs merged**: 43+ (D1–D16, U1–U22, planning, verification, retro)

---

## Final Task State (Phase 6)

| Item | Status | Evidence |
|------|--------|----------|
| sdd-verify | [x] Done | verify-report.md #498 5f58efa, verdict FAIL (1 CRITICAL remediated) |
| CRIT-1 remediation | [x] Done | #502 34729a1 adds tool-registry.md row + spec literal alignment |
| Campaign retro (§18) | [x] Done | #507 b67e4f7, verify-retro.sh OK, 10 deltas + 4 dismissals |
| sdd-archive | [x] Done | This archive report, specs published to openspec/specs/, change moved to archive/2026-09-06 |
| Operator items | — Deferred | Propose-never-apply: operator action required per list above |

---

## Capability Specs Published

Five capability specs have been published from this change to `openspec/specs/`:

1. **kit-instrument-honesty** — Instruments must prove they looked and report three-state outcomes (absent-input / empty-input / no-match)
2. **kit-doctrine-grammar** — Machine-countable delta declarations, Type domain, shared-global rules, template grammar
3. **kit-subject-coverage** — Coverage over the subject (niagara: 174/318 modules cited; rule preserved, number dated)
4. **kit-session-cost** — SessionStart context size target (8,000 chars); measured 6,127 at close
5. **kit-hygiene-portability** — Shared-global rules, peer-owned read-only boundaries, tool-registry coverage

Each spec includes a header note: "Published from change research-sdd-kit-retro-campaign (archived 2026-09-06, main b67e4f7)."

---

## SDD Cycle Complete

The change has been fully planned (proposal.md, design.md), implemented (22 instrument units, 16 doctrine units), verified (verify-report.md with 1 critical remediated), and archived. The capability specs are published and form the source of truth for forward work.

**Ready for the next change.**

---

## Archive Integrity

- Source change folder moved to `openspec/changes/archive/2026-09-06-research-sdd-kit-retro-campaign/`
- All artifacts preserved: proposal.md, design.md, exploration.md, specs/, tasks.md, verify-report.md
- Tasks.md updated: Phase 6 items marked complete (verify, critical remediation, retro, archive)
- Capability specs published to `openspec/specs/{domain}/spec.md` (5 specs)
- Archive is read-only; no further edits permitted
