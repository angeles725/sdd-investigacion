# Kit session 2026-10-04d — wire the unwired mechanisms, then the follow-up chain

Engram mirror: `odd/kit-session-2026-10-04d/tasks` (project sdd-investigacion).

## Objective
Connect the kit mechanisms that exist but are not wired (audit `kit/unwired-mechanisms-audit-2026-10-04`),
then work the follow-up chain: forced-past RDD follow-ups, gentle-ai adoptions #1708–#1714, remaining backlog.

## Authorization
Maintainer (2026-10-04): ODD + RDD all granted; commit, push, PR, PR view, issues and merge authorized;
gentle-ai review prompts granted and run without asking; chain automatically. #1710–#1714 approved for
implementation in this session. NEEDS-HUMAN product decisions (#1328 #1385 #1208 #896 and the ~33 queue) are
NOT decided here — they stay for the maintainer.

## Constraints
- Kit CLAUDE.md: harness-worktree writers based on origin/main, disjoint file sets, strict TDD + mutation teeth,
  shellcheck + run-all gate, ~400 authored lines per PR, English artifacts, no AI attribution in commits.
- Shared checkout: never update while a /research-sdd session runs on a target.
- Target settings.json edits only through `research-sdd-init.sh --wire` (no hand edits); TARGETS.md never auto-edited.
- RDD capped at ~3 rounds; remainder filed as a follow-up issue.

## Delivery strategy
`auto-chain`, chain strategy `stacked-to-main` (one PR per work unit against main).

## Tasks
Route legend: D = delegated writer (harness worktree, sonnet), I = inline.

### Phase 1 — wire the unwired mechanisms
- [x] W1 (1a+1e) — durable stale-KIT detection: `install --verify` (or the drift hook) flags a shared checkout behind
      origin/main; call `install --verify` from `verify-skill-drift-hook`. Route D.
- [x] W2 (1d, #1732) — return-token gate: bounded transcript parse, marker pruning, chmod +x; add it to the
      `research-sdd-init.sh --wire` template, tool-registry row, PROMPT-LOOP mention. Route D.
- [ ] W3 (1b+1c) — run `research-sdd-init.sh --wire` on every present target (pkill-guard, SessionStart,
      return-token gate). After W2 merges and the shared checkout is synced. Route I (commands only).
- [x] W4 (1f, #1110) — Pi / gentle-shell session-start sweep extension (or documented manual step). Route D.
- [x] W5 (1g) — merge-gate + plan-review-slices as an explicit close checklist. Route D.
- [x] W6 (1h) — cite `reason-codes.v1.md` from METHODOLOGY §7 and the status output. Route D.

### Phase 2 — forced-past RDD follow-ups
- [x] F1 #1728 (HIGH, privacy) — scrub `AUTHORIZATION=` + glued-count silent zero.
- [x] F2 #1725 — reason-codes coverage test blind spots.
- [x] F3 #1721 — verify-block nonpath pre-split.
- [x] F4 #1718 — doctrine-absence walk typed degraded.
- [x] F5 #1696 — hook-wiring HW_GIT_ROOT flag split.
- [x] F6 #1691 — run-all TMPDIR leftovers.

### Phase 3 — gentle-ai adoptions
- [x] G1 #1708 (slice 1 ✅) · G2 #1709 (slice 1) · G3 #1710 ✅ · G4 #1711 (slice 1 ✅) · G5 #1712 ✅ · G6 #1713 ✅ · G7 #1714 ✅

### Phase 4 — remaining ACTIONABLE backlog (2026-10-04b triage)

## Progress / evidence
(per task: route, PR, merge sha, RDD tier + outcome, gate result)
- F4 #1718 — D · PR #1735 · merged d00ae17 · RDD granted, approved (suggestions only) · run-all 158/158, teeth 37/0, CI green.
- F1 #1728 — D · PR #1736 · merged · RDD granted, approved (3 suggestions) · run-all 158/158, CI green.
- G5 #1712 — D · PR #1737 · merged · RDD approved (suggestions) · run-all 158/158. Issues #1710–#1714 relabelled status:approved (CI requires it).
- F5 #1696 — D · PR #1738 · merged · RDD approved (suggestions) · run-all 158/158, fleet byte-identical.
- W5 (1g) — D · PR #1739 (Closes #1745) · merged · RDD approved (2 suggestions). Docs only; no suite reads the PR template (noted).
- W1 — PR #1741 (Closes #1744) · merged · RDD cap reached after 3 rounds, follow-up #1740.
- F3 #1721 — PR #1743 · merged · RDD cap reached after 3 rounds, follow-up #1742; fleet 164 blocks, zero classification diffs.
- G3 #1710 — D · PR #1746 · merged · RDD round 2 approved (suggestions only).
- W6 + F2 #1725 — PR #1748 · merged · RDD cap after 3 rounds, follow-up #1747 (doc wording).
- W4 #1110 — PR #1749 · merged · RDD approved (suggestions). Branch B: mandatory manual steps; native pi/gentle-shell extension deferred on #1110 (contract unconfirmed).
- #1740 (W1 follow-up) — PR #1750 · merged · RDD round 2 approved (suggestions only).
- G6 #1713 — PR #1751 · merged · RDD round 3 approved (suggestions only).
- G1 #1708 slice 1 — RDD cap, follow-up filed; shipping. G4 #1711 slice 1 — RDD cap, follow-up filed; shipping. W2 #1732 — RDD cap + one safety pass (stale-gate repair could delete working user hooks — fixed before shipping); follow-up filed; shipping.
- #1752 filed: reconcile-issues closed lookup degraded fleet-wide on gh 2.45 (stateReason).
- W2 #1732 — PR #1758 · merged (fu #1757).
- G1 #1708 slice 1 — PR #1754 · merged (fu #1753).
- W3 BLOCKED: a live pi/gentle-shell session runs in niagara-research (cwd check 21:22); shared checkout must not move while it runs. Resume when it ends.
- #1759 filed + writer: H4g flake from #1750 surfaced on PR #1756 CI.
- G4 #1711 slice 1 — PR #1756 · merged (fu #1755). Slices 2+ (verify-registry, resume-state, retro-gate envelopes) open on #1711.
- Docs #1708/#1110 — PR #1760 · merged (round-2 WARNING refuted: #1754 on origin/main).
- G7 #1714 — PR #1762 · merged (RDD cap; fu #1761). One inline test fix by the parent (empty tools value) proven by mutant.
- #1761 (install --verify agent set) — PR #1763 · merged (round 2 approved). Parent fixed a vacuous V9 guard (proven by mutant).
- #1759 — real hook defect (orphan sleeper + SessionStart hang, 9/1200); round 1 flagged SIGKILL to a reaped pid → redesign in progress.
- F6 #1691 — PR #1765 · merged (RDD WARNING refuted: run-all uses per-suite TMPDIR).
- #1755 — PR #1764 · merged. #1742 final round; #1753 round-1 fixes; #1709 + #1759 resumed with new agents after the maintainer stopped their stale-looking agents (maintainer said: retomar).

## Close — 2026-10-05

**Merged this session (24 PRs, #1735–#1774).** Phase 1 wiring: W1 install --verify stale-kit (#1741), W2 return-token gate hardened + wired by `--wire` (#1758), W4 pi/gentle-shell mandatory session steps (#1749), W5 close checklist (#1739), W6 reason-codes cited (#1748). Phase 2: #1728 (#1736), #1725 (#1748), #1721 (#1743), #1718 (#1735), #1696 (#1738), #1691 (#1765). Phase 3 gentle-ai: #1708 s1 (#1754), #1709 s1 (#1774), #1710 (#1746), #1711 s1 (#1756), #1712 (#1737), #1713 (#1751), #1714 (#1762). Follow-ups shipped: #1740 (#1750), #1742 (#1767), #1753 (#1769), #1755 (#1764), #1759 (#1772 — real hook defect: orphan sleeper + SessionStart hang), #1761 (#1763); docs #1760.

**Open follow-ups filed (RDD cap or measured gaps):** #1747 #1752 #1757 #1766 #1768 #1770 #1771 #1773, #1709 slice 2 (`regressed` class), #1711 slices 2+ (verify-registry / resume-state / retro-gate envelopes), #1110 native pi/gentle-shell extension (contract unconfirmed).

**NOT done — blocked, do FIRST next session:**
1. **W3 target wiring**: run `research-sdd-init.sh --wire` on every present target (pkill-guard 0/16, SessionStart 10/15 missing, return-token gate now registered by --wire). Blocked all session by a live pi/gentle-shell session in niagara-research (rule: never move the shared checkout while a /research-sdd session runs).
2. **Sync the shared checkout to origin/main and re-run the installer** for claude/pi/gentle-shell homes: since #1741/#1763 every pre-#1714 install reports drift (no bundle record / missing agent members) at SessionStart until reinstalled.
3. Then confirm the hooks fire (SessionStart output size within budget; return-token gate in a real Stop).

**Process lessons:** RDD round cap applied, except a destructive WARNING (W2 stale-gate repair could delete working user hooks) got one extra surgical fix before shipping; subagent reports were lost several times — parent verified committed worktrees directly (suites + shellcheck) instead of waiting; measure incidence before more rounds (#1742 R-rule: 0/164 real cites).

## Next step
Next session: items 1–3 above, then the follow-up queue, then NEEDS-HUMAN decisions (#1328 #1385 #1208 #896 + ~33).
