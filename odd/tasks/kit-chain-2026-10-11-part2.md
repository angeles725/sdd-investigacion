# Kit chain 2026-10-11 part 2 — niagara hooks, corpus items, gentle-shell installer, kit backlog

## Objective
Fix the niagara-research hooks for Claude Code and gentle-shell (#2128), apply the open corpus items, re-verify the kit
against the new gentle-shell web installer, then chain through the kit backlog and the improvements surfaced by the
session-start instruments.

## Authorization
Maintainer, 2026-10-11: ODD + RDD (consent always `granted`) + commit + push + PR + pr view + issues + merge; chain
automatically without asking; accept Gentle AI prompts and run the review; apply everything that can be applied.
Corpus edits for A/B were requested by the maintainer (no research session running, confirmed 2026-10-11).

## Routes and models
Sonnet writers (kit: harness worktrees on `origin/main`; corpora: sibling worktrees `<repo>-worktrees/<name>`), at most
2 suite-running writers, focused suites + `--prove-teeth` only. Per kit PR: Opus adversarial review → restack → RDD on
the new head → ONE serial `run-all.sh -j 4 --prove-teeth` → CI → `merge-gate.sh --merge`. Corpus PRs: Opus review →
RDD → merge.

## Scope
- In: niagara-research hooks (`.claude/`, `tools/hooks/`, `.pi/extensions/`), corpus hook chmod / delta ids, kit repo,
  kit issues, gentle-shell install verification.
- Out: `TARGETS.md` rows (human-owned; propose only), #2163 B1201 content (maintainer decision), live stations.

## Tasks
- [x] A #2128 niagara hooks: one SessionStart card under the 8,000-char aggregate, `fork` matcher, re-synced
      `research-protocol.sh`, `$CLAUDE_PROJECT_DIR` to return-token-gate, no hardcoded paths; pi side uses the kit's
      `research-sdd-hooks.ts` (#2137) or fixes items 5–12. Route: delegated (corpus multi-file).
- [x] B1 #2141 `chmod +x .claude/hooks/research-protocol.sh` in COB-IM2, sullair, panccadia-3d-viewer.
- [x] B2 #2150 non-ASCII delta ids (niagara Δ1–Δ4, fluke, blender).
- [x] B3 stray gentle-shell TARGETS.md rows → proposal only (human-owned registry).
- [x] C gentle-shell web installer: identify current install, verify kit (`research-sdd-install.sh --verify`, pi
      extension load, agent home, skill/prompt discovery); adapt the kit if the layout changed; report results.
- [x] K1 #2171 corroborate-ifc /tmp/rsdd leftovers.
- [x] K2 #2169 suite summary-line lint.
- [ ] K3 #2161 bare-pipe table readers; K4 #2162 deferred-row populations.
- [ ] K5 gentle-shell follow-ups #2125 #2133 #2139 #2158; K6 #993 profiles eval.
- [x] K7 session-start improvements: tool catalog drift (8 uncataloged tools), install --verify gentle-shell drift.
- [ ] Z close: this document, Engram mirror, docs PR.

## Progress / evidence
- 2026-10-11: shared checkout fast-forwarded 0f904d25 → 568587bc (153 commits; local TARGETS.md edit and untracked
  CATALOG.md preserved). No research session running.

- A: niagara-research#31 merged 167760df2 (route: delegated writer + Opus review; RDD off clone-local in niagara → RDD-off tier high: writer checks + independent Opus review, 6 fixes applied). verify-session-budget live: 20,118 → 3,494 chars OK, 0 truncated. Follow-ups #2174 #2175 #2177.
- B1: chmod +x ×3 (gitignored, no commit), #2141 commented. B2: niagara-research#30 merged, #2150 closed (other Δ retros are retro-closed).
- B3/C: #2172 merged (closes #2173). gentle-shell is npm gentle-pi 4.0.0, release channel; web installer keeps agent home ~/.gentle-shell/agent → no kit path change; `upgrade`/`--channel` exist only on main builds. Reinstalled harness: --verify status=match. Live -p test: empty output in a research target with the kit extension (#2177); default model 401 (provider auth, not kit).
- K7: tool catalog drift was a stale shared checkout (38/38 after pull); install drift fixed by the reinstall.
- K2: PR #2176 Opus review (2 should-fix + 5 nits applied), RDD approved + acknowledged (4 lenses).

- K2: #2176 merged (gate 209/209, 14,690 cases).
- K1: #2171 premise false (corroborate-ifc never allocates); root cause fact-exec `teeth-root-hardcoded` mutant → #2180 merged (leftovers 15→4). Second source docker-exec mutant → #2186 / PR #2188 (pipeline; review: CLI-child allocations were invisible; snapshot limited to suite-owned roots to avoid -j cross-suite deletion).
- #2177: pi print mode empty output (settle continuation; print mode prints only the last assistant message) → #2181 merged; live in niagara: answer + niagara card context on stdout, typed stderr notice, no block markers. Gentle-shell harness reinstalled from 583f2dee.
- K3: #2161 + #2178 → PR #2179 (Opus blocker: masked pre-check hid rows other readers misread → all verify-sources readers fixed); pipeline. Follow-up #2182 (sha256sum backslash digest).
- #2175 → PR #2184 (`--portable`, 2 Opus blockers fixed + re-check; RED executed by orchestrator); pipeline. Follow-up #2183.
- K5a #2133 → PR #2185 (render-dir guard, record-sha check, launcher skip); pipeline.
- #2174 → PR #2187 (verify-session-budget --harness pi|both; niagara pi aggregate 5,781 OK); fix round.
- K5b #2158/#2125/#2139 writer running.

## Next step
Drain pipeline (#2179 #2184 #2185 #2188), #2187 fixes → pipeline, K5b; then K4 #2162, #2182, #2183, K6 #993, final gate on main, close.
