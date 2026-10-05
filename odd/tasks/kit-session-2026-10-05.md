# Kit session 2026-10-05 — target wiring (W3) and the follow-up chain

Engram mirror: `odd/kit-session-2026-10-05/tasks` (project sdd-investigacion).

## Objective
Finish the work deferred by session 2026-10-04d: wire every present target (W3), reinstall the harness homes,
then close the approved follow-up queue and the remaining gentle-ai adoption slices.

## Authorization
Maintainer (2026-10-05): ODD + RDD all granted; commit, push, PR, PR view, issues and merge authorized;
gentle-ai review prompts granted and run without asking; chain automatically. NEEDS-HUMAN product decisions
(#1328 #1385 #1208 #896 and the ~33 queue) are NOT decided here.

## Constraints
- Kit CLAUDE.md: harness-worktree writers based on origin/main, disjoint file sets, strict TDD + mutation teeth,
  shellcheck + run-all gate, ~400 authored lines per PR, English artifacts, no AI attribution in commits.
- Shared checkout: never update while a /research-sdd session runs on a target. At session start a pi +
  gentle-shell session was live in niagara-research (7 h, pts/9), so W3/R1 are blocked until it ends.
- Target settings.json edits only through `research-sdd-init.sh --wire`; TARGETS.md never auto-edited.
- RDD capped at ~3 rounds (one extra surgical fix for destructive WARNINGs); remainder filed as a follow-up.

## Delivery strategy
`auto-chain`, chain strategy `stacked-to-main` (one PR per work unit against main).

## Tasks
Route legend: D = delegated writer (harness worktree, sonnet), I = inline.

### Phase 1 — rollout (blocked on the live session)
- [ ] W3 — `research-sdd-init.sh --wire` on every present target. Route I. BLOCKED: live session in niagara-research.
- [ ] R1 — re-run the installer for claude/pi/gentle-shell; confirm SessionStart budget and return-token gate fire. Route I.

### Phase 2 — follow-up queue (disjoint destination files)
- [ ] A — `reconcile-issues.sh`: #1752 (gh 2.45 stateReason degrade), #1773 (shallow CI checkout, junk token). Route D.
- [ ] B — `research-sdd-init.sh` + return-token gate test: #1757. Route D.
- [ ] C — `verify-block.sh` R rescue / version-label regex: #1766. Route D.
- [ ] D — `stage-retro-issues.sh` `_occ_cache_add` escaping: #1768. Route D.
- [ ] E — `verify-skill-drift-hook.sh`: #1770 (H4e flake), #1771 (fractional sleep probe, labels). Route D.
- [ ] F — `reason-codes.v1.md` prose: #1747. Route D.

### Phase 3 — gentle-ai adoption slices
- [ ] G — #1709 slice 2 (`regressed`), after A merges (same file). Route D.
- [ ] H — #1711 slices 2+ (`--json` envelope on further instruments). Route D.

## Progress
(updated per merged work unit: PR, merge sha, RDD outcome)

## Next step
Launch A–F writers in parallel (disjoint files), then ship each through RDD + merge-gate.
