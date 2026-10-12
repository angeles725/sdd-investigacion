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
- [x] K3 #2161 bare-pipe table readers; K4 #2162 deferred-row populations.
- [x] K5 gentle-shell follow-ups #2125 #2133 #2139 #2158; K6 #993 profiles eval.
- [x] K7 session-start improvements: tool catalog drift (8 uncataloged tools), install --verify gentle-shell drift.
- [x] Z close: this document, Engram mirror, docs PR.

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

- K3/K4: #2179 (#2161 + #2178) and #2192 (#2162, one shared deferred reader, per-table width, backlog scope) merged.
- #2182 → #2191 merged (stdin hashing, typed unreadable-snapshot); toolbelt part of #2190 → PR #2198 OPEN.
- #2175 → #2184 merged; #2183 → #2200 merged (portable default, RSDD_INIT_WIRING; shrunk 758→2 lines in init.test.sh after lens_context_budget_exceeded).
- #2174 → #2187 merged (RDD CRITICAL R1-001 bash arithmetic injection fixed: ^[0-9]+$ + stdin nonce; recover → successor lineage approved).
- #2186 → #2188 merged (docker-exec mutant; snapshot only in suite-owned roots). /tmp/rsdd leftovers 15 → 4 → 0 expected.
- K5: #2133 → #2185 merged; #2158 + #2139 → #2189 merged; #2125 stays open (needs gentle-shell source). #2195 (install suite TMPDIR leak, real marker-temp leak) → PR #2196 OPEN.
- #2197 visibility teeth-I load flake (failed 4 gates) → #2199 merged. METHODOLOGY \| doctrine was wrong → #2194 merged.
- K6 #993 closed by maintainer decision (A/B dropped; replaced by #2211 learn-from-gentle-shell + #2210 smoke).

## Merged this chain
Kit (15): #2172 #2176 #2180 #2181 #2179 #2194 #2185 #2191 #2184 #2192 #2199 #2200 #2187 #2188 #2189. Corpus: niagara-research #30 #31.

## Stopped at close (maintainer decision, 2026-10-12)
The serial ~45-min gate queue was stopped: PR #2196 and PR #2198 stay OPEN with reviews/fixes done; resume them after the fast-gates block (restack → RDD → gate). The final full gate on main moves to step 0 of the next session.

## Decisions / new issues (2026-10-12)
Local full gate stays authoritative (CI-only rejected). Next-session order: fast gates (#2203 part 1 E→extras, #2208, #2209, #2201+#2213+#2214, #2212) → #2211→#2204 doctrine diet → #2203 part 2, field tools, #2202 Go spike → #2216 #2215 #2210 #2206 #2205 #2207. Category E (VM/dynamic) → optional extras (no `forense`, never used).

## Lessons
- Run --prove-teeth on EVERY suite of an edited script (init teeth broke silently, #2184).
- A load flake in one suite blocks every gate; isolate and fix it first (#2197).
- Restacks re-trigger RDD + gate for every queued PR — batch merges (merge train, #2213).
- Doctrine claims about renderers must be verified against the renderer (GFM \| — #2194).

## Next step
Next session step 0: final full gate on origin/main + shared checkout update; then the fast-gates block; then resume #2196 and #2198.
