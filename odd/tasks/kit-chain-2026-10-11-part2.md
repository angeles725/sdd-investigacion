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
- [ ] A #2128 niagara hooks: one SessionStart card under the 8,000-char aggregate, `fork` matcher, re-synced
      `research-protocol.sh`, `$CLAUDE_PROJECT_DIR` to return-token-gate, no hardcoded paths; pi side uses the kit's
      `research-sdd-hooks.ts` (#2137) or fixes items 5–12. Route: delegated (corpus multi-file).
- [ ] B1 #2141 `chmod +x .claude/hooks/research-protocol.sh` in COB-IM2, sullair, panccadia-3d-viewer.
- [ ] B2 #2150 non-ASCII delta ids (niagara Δ1–Δ4, fluke, blender).
- [ ] B3 stray gentle-shell TARGETS.md rows → proposal only (human-owned registry).
- [ ] C gentle-shell web installer: identify current install, verify kit (`research-sdd-install.sh --verify`, pi
      extension load, agent home, skill/prompt discovery); adapt the kit if the layout changed; report results.
- [ ] K1 #2171 corroborate-ifc /tmp/rsdd leftovers.
- [ ] K2 #2169 suite summary-line lint.
- [ ] K3 #2161 bare-pipe table readers; K4 #2162 deferred-row populations.
- [ ] K5 gentle-shell follow-ups #2125 #2133 #2139 #2158; K6 #993 profiles eval.
- [ ] K7 session-start improvements: tool catalog drift (8 uncataloged tools), install --verify gentle-shell drift.
- [ ] Z close: this document, Engram mirror, docs PR.

## Progress / evidence
- 2026-10-11: shared checkout fast-forwarded 0f904d25 → 568587bc (153 commits; local TARGETS.md edit and untracked
  CATALOG.md preserved). No research session running.

## Next step
A.
