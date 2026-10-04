# Kit session 2026-10-04c

**Objective:** execute the 2026-10-04b "Next, in order" agenda in chain, automatically: release v1.2.0, then
every ACTIONABLE work unit from the 2026-10-04b backlog triage, plus buildable improvements found on the way.

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, PR view, issues, merge.
Gentle AI review prompts: grant and run the review without asking. The maintainer asked not to be prompted:
NEEDS-HUMAN product decisions are NOT decided by the agent; they are listed at close for the maintainer.
**Delivery:** one PR per work unit, `auto-chain`; each PR `Closes #N` of a `status:approved` issue.
Merge via `research-sdd/toolbelt/merge-gate.sh --merge` (scratchpad `ship.sh`).

**Per-PR pipeline:** harness-worktree sonnet writer (based on `origin/main`, brief = scratchpad
`writer-common.md`) → parent spot check (`review.sh`: teeth + repo-wide lints) → RDD (`rdd-drive.py`,
merge-base range, committed-only) → fix real WARNs; after ~3 rounds file the remainder as a follow-up → PR → CI →
merge-gate.

**Start:** origin/main = fa044b6. Shared checkout main = e9c9b4b (pinned: live niagara5 session; human edit in
research-sdd/TARGETS.md — never touched, never updated). RDD mode: on (global).

## Tasks
Wave 1 (concurrent, disjoint file sets; route: delegated, writer trigger):
- [x] T1 Release v1.2.0 — new CHANGELOG.md (regenerated from v1.1.0..origin/main), PR, tag v1.2.0, GitHub release.
      Route: delegated (sonnet). RDD: low/approved+acknowledged. PR #1692 merged (863a6f7), tag v1.2.0 pushed,
      release published. 269 PRs classified, 0 unclassified.
- [ ] T2 METHODOLOGY doctrine batch (#1193 #1195 #1200 #1203 #1208 #1210 #1211 #1213 #1383 #1385 #1386 #1395
      #1541 #1557 #1579 #1580 #1581 #1599 #1600 #1601 #1617 #1618 #1619) — METHODOLOGY.md only, sliced ≤ ~400 lines.
- [ ] T3 PROMPT-LOOP batch (#1384 #1507 #1212 #1639 #1609) — PROMPT-LOOP.md only.
- [ ] T4 verify-sources #1678 (verify-sources.sh + suite).
- [ ] T5 research-sdd-status.sh batch (#1154 #1150 #1152 #1544 #1640 #1614 #1023), sliced.
Wave 2:
- [ ] T6 verify-block #973 + #1676 (verify-block / clean-check / scripts-manifest).
- [ ] T7 lint-block packs (#1607 #1548 #1517).
- [ ] T8 hook-wiring + verify-registry (#1153 #1158 #1044).
- [ ] T9 research-sdd-init (#1550 #1159) ; archive + scan-secrets (#1014 #1015).
- [ ] T10 small instrument follow-ups: #1013 #1025 #1017 #1538 #1536 #1641 #1645 #1145 slice.
- [ ] T11 #1675 dirname "$0" lib resolution (touches ~35 scripts — runs alone, last).
- [ ] T12 Follow-up issue: run-all TMPDIR leftovers under --prove-teeth (detect-tools, research-sdd-init).
gentle-ai adoptions (maintainer approved top 10 of B33 = #1700–#1709):
- [x] A1 #1700 comment-blind linked-issue parser — PR #1719 merged (4 RDD rounds: CRLF, emphasis, one state
      machine, inline triple-backtick, boundary, inline code spans — the last found when its own PR body tripped the
      new gate). Process slip: one commit carried a test mutant; fixed in the next commit before merge.
- [x] A2 #1701 CLAUDE.md routing by evidence budget — PR #1715 merged (3 RDD rounds).
- [x] A4 #1703 retired-phrases walk — PR #1716 merged; round-cap remainder → #1718.
- [x] T4 #1678 verify-sources — PR #1695 merged. T8 hook-wiring/verify-registry — PR #1697 (remainder #1696).
- [ ] A3 #1702 install --verify digest (install/) — delegated, running.
- [ ] A4 #1703 retired-phrases absence walk (tests/) — delegated, running.
- [ ] A5 #1707 + #1705 scrub + writer outcome triad (stage-retro-issues lane) — delegated, running.
- [ ] A6 #1708 occurrence comments + #1709 closure evidence/regressed (stage-retro-issues/reconcile lane) — after A5.
- [ ] A7 #1706 continuation token (research-sdd-status + Stop hook) — after T5 merges (same file).
- [ ] A8 #1704 closed reason-code table — scope assessment first (touches many instruments).
Close:
- [ ] T13 Close doc + Engram summary; NEEDS-HUMAN list for the maintainer.

## Excluded
NEEDS-HUMAN (maintainer decision, not decided by the agent): #1638 #1198 #1214 #906 #896 #979 #980 #993 #1015
#1094 #1096 #1116 #1157 #1175 #1178 #1179 #1180 #1185 #1186 #1187 #1189. Blocked: #1660 (after #1650–#1656
progress); target-corpus issues #1650–#1656 (live target corpora, not kit work).

## Progress log
- PR #1693 merged (METHODOLOGY batch 1: closes #1193 #1195 #1200 #1203 #1210 #1211 #1213 #1386 #1395; #1383 option a;
  #1208 #1385 → needs-review). PR #1694 merged (PROMPT-LOOP: #1384 #1507 #1212 #1609, #1639 half; 2 RDD rounds).
- #1678 PR shipping (RDD approved; fleet 41 false FABRICATED-CITE removed). hook-wiring/verify-registry: RDD WARNING
  sent back to writer. #1691 filed (TMPDIR leftovers).
- Interjected by maintainer: /research-sdd on gentle-ai v4.0.0 (target #22) — 6 sweeps (n1..n6 incl. instruction
  adherence) → corpus B28–B33 writer; separate branch research/gentle-ai-v4-delta.
- gentle-ai research done: PR #1699 merged (B28–B34, closes #1698); retro deltas staged as #1700–#1714
  (needs-review, 3 high). Staging from a worktree needs the checkout at `$RESEARCH_HOME/investigacion/sdd-investigacion`
  (stage-retro-issues fails closed on an unregistered basename) — used RESEARCH_HOME override on a temp worktree.
- Maintainer reviewing 33 needs-review issues (recommendation table delivered); kit doctrine batch 2 waits on it.
- Session start: ODD doc created; helpers recovered from the 2026-10-04b scratchpad.

## Close — 2026-10-04c

**Merged this session (19 PRs + release v1.2.0).** origin/main = ee9ce06. Shared checkout now AT origin/main
(niagara5 live session ended mid-session; TARGETS.md row-37 refresh committed and merged as PR #1731).

Release: **v1.2.0** cut (PR #1692; CHANGELOG = 269 PRs classified; tag + GitHub release published).
Kit PRs: #1693 (METHODOLOGY b1) · #1694 (PROMPT-LOOP) · #1695 (#1678 verify-sources) · #1697 (#1153 #1158 #1044) ·
#1699 (corpus B28–B34, #1698) · #1715 (#1701) · #1716 (#1703) · #1717 (#973 #1676) · #1719 (#1700) · #1720 (#1702) ·
#1722 (#1154 #1152 #1023; #1150 partial) · #1723 (#1704 slice 1) · #1724 (#1706 slice 1) · #1727 (#1707 #1705) ·
#1729 (#1706 slice 2, #1726) · #1731 (TARGETS #1730).

**gentle-ai v4.0.0 research (target #22).** PR #1699 added corpus blocks B28–B34 (v2.2→v4.0 delta + staleness map,
issue mgmt, automated issue generation, component communication, what it creates, instruction adherence, adoption
synthesis). 19/27 old blocks STALE. Retro deltas staged as issues #1700–#1714. Maintainer approved the top 10
(#1700–#1709); all 10 merged (some sliced). Net kit gains: closed a real PR-gate hole (Closes #N inside comments /
code / inline-code now ignored), privacy scrub before issue writes, install --verify, retired-phrase walk, reason-code
registry, evidence-budget routing, writer read-back + unknown outcome, --emit-token + return-token Stop-hook gate.

**Forced past the ~3-round RDD cap (follow-ups filed, fix early next session):**
- #1728 (HIGH) — scrub: `AUTHORIZATION=` not redacted (AUTHOR substring stripped) + glued-count silent-zero.
- #1732 — return-token-gate: bound the transcript parse, prune block markers, chmod +x; FOLD INTO HOOK WIRING.
- #1725 — reason-codes test: emitter check one-directional, single-line extraction blind spot.
- #1726 folded into #1729. #1721 (verify-block nonpath pre-split) · #1718 (doctrine-absence find/grep degraded) ·
  #1696 (hook-wiring HW_GIT_ROOT token) · #1691 (run-all TMPDIR leftovers).

**NEXT SESSION — START HERE (ordered):**
1. **Wire the unwired mechanisms (read-only audit done this session).** Highest value, maintainer-gated because they
   touch target corpora + the shared checkout:
   a. Target Stop hooks exec `$KIT/toolbelt/retro-gate.sh` from the shared checkout — keep it AT origin/main, or have
      `--verify` flag a stale KIT (now fixed by the sync, but will drift again; needs a durable fix).
   b. PreToolUse pkill-guard wired in 0/16 targets — `research-sdd-init.sh --wire` repair per target.
   c. SessionStart missing in 10/15 targets (no tool-registry pointer) — same repair.
   d. Land + WIRE the #1706 return-token gate (currently merged but not in any settings) — #1732.
   e. `install --verify` has no caller — call it from `verify-skill-drift-hook`.
   f. Pi/gentle-shell get NO hooks (retro, sweeps, guards are Claude-only, #1110) — session-start extension.
   g. `merge-gate` / `plan-review-slices` are loop instructions with 0 real use — make them a close checklist.
   h. `reason-codes.v1.md` orphan — cite it from METHODOLOGY §7 and the status output.
   Full per-harness matrix + top-8 in Engram (topic `kit/unwired-mechanisms-audit-2026-10-04`).
2. **Fix the forced-past follow-ups** #1728 (HIGH, privacy) first, then #1732 #1725 #1721 #1718 #1696 #1691.
3. **NEEDS-HUMAN decisions (~33 + the 5 remaining gentle-ai #1710–#1714)** — go through WITH the maintainer, one at a
   time. The recommendation table is in the chat; #1328/#1385/#1208/#896 are the four only-you calls.
4. #1708 #1709 (gentle-ai adoptions 9 & 10) — NOT started; stage-retro-issues lane, after #1728.
5. Remaining ACTIONABLE backlog from 2026-10-04b triage (METHODOLOGY/PROMPT-LOOP batches 2+, instrument follow-ups).

**Did NOT improve yet (be honest):** research-loop instruction adherence is only half-built (token exists, gate
merged but UNWIRED); no measurement of real /research-sdd quality vs score-loop-transcript.sh. Priority is wiring.
