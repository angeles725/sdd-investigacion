# Kit session 2026-09-25 — chained backlog

Objective: drain the next-session agenda from `fleet-issue-autoseed.md` in chain, automatically.
Authorization: ODD + RDD (consent granted for every candidate), commit, push, PR, issues, merge.
TDD: strict (project CLAUDE.md §4, user global "Strict TDD Mode: enabled"); runner `bash research-sdd/toolbelt/tests/run-all.sh [--prove-teeth]`.
Delivery strategy: auto-chain; one PR per work unit, each based on `origin/main`.
Base: `origin/main` = `9f1fcd0`.

## Decisions
- #1097 provenance: the rule "general = pre-audit wording" covers only #992-sourced compression. #989 is new doctrine, so it is model-invariant: `hotcore-reread-scope` general body = claude body verbatim; #989-touched slots with pre-audit text keep the pre-audit explicit style AND carry #989's semantics. Commit/PR text must stop attributing non-#992 slots to "#992 wave B".

## Tasks
- [ ] T1 PR #1097 round 3 (#993 WU4) — route: delegated (writer, worktree) — provenance fix, rebase, RDD, Opus review, merge.
- [ ] T2 #1099 (high) marker outside recognized scope fails open — route: delegated (writer, worktree).
- [ ] T3 #1032 stray `git` file in cwd — route: delegated (writer, worktree).
- [ ] T4 #1003 slice 2 (PROMPT-LOOP L2) — after T1 merges (PROMPT-LOOP overlap).
- [ ] T5 follow-ups: #1043 #1044 #949(3,5) #1033 #1034 #1031 #1030 #1025 #1023 #1017 #1015 #1014 #1013 — triage by destination file, then batch.
- [ ] T7 retro/delta backlog: triage the 53 PENDING retros (sweep-retros --full) + open delta issues #1058 #1094 #1095 #1096 against the kit (applied / real-open / dismiss), group real-open deltas by destination file, then apply in disjoint-file batches — route: delegated (read-only mapper first, then writers).
- [ ] T8 wiring + auto-issues audit: verify a NEW session running /research-sdd on each wired target gets hooks wired and retro deltas auto-seeded as GitHub issues end-to-end (skill → kit resolution → Stop/SessionStart hooks → seeder → kit repo); list gaps as fixable defects — route: delegated (read-only auditor), fixes as follow-up writers.
- [ ] T9 heavy + automatic + child-focus continuation audit: find every place the loop can stop early, ask the operator, or fail to descend into declared child focuses/tiers (#989 campaign continuation); plus tooling/lint gaps. Read-only now; writers after T1 merges (SKILL.md / PROMPT-LOOP.md overlap) — route: delegated.
- [ ] T6 quiet-tree gate on final main + session close.

## Progress / evidence
- T9 audit done: loop stop points mostly INTENDED or already fixed (c10f9d9); real gap = no focus-partition check vs artifact universe (niagara D1). Filed #1105 (doctrine, writer T9a owns METHODOLOGY.md), #1106 (focus-partition-audit.sh, writer T9b), #1107 (score-loop-transcript C4 vacuous, later). #1089/#845 drift-sweep instrument queued.
- T8 audit done: seeder chain OK (reconcile --all: tracked=10 untracked=0 orphaned=3, 118 retros). Gaps filed: #1108 (three.js row path points at non-corpus dir → never wired; verify-registry blind), #1109 (status self-reports Stop-hook wiring), #1110 (auto-seeding Claude-only, codex/reasonix undocumented). Writer T8a on #1108+#1109.
- T7 triage done: 53 pending retros → 18 applied, 24 dismiss/zero-delta, 10 mixed, 1 kit retro (tracked #892–#897). Filed #1111 (parser misses non-canonical delta headings), #1112 (METHODOLOGY 8-delta batch), #1113 (ops docs; writer T7a), #1114 (document-cycle scaffold). Target-corpus marker flips: DENIED by the auto-mode classifier (modifying shared target repos) → left to the maintainer; list in T7 report.
- T7a #1113: PR #1115 (docs only, assess=passive). Writer was force-stopped after it ran `pkill -f run-all.sh` / `pkill -9 -f shellcheck`, which killed every other writer's gate (7 concurrent full gates ≈ load 18 on 16 cores). Lesson: writer prompts must forbid killing processes they did not start; cap concurrent full gates. Merge denied by classifier "Merge Without Review" → Opus review launched first.
- T7b marker flips DONE (user-authorized): sweep-retros 53 → 17 pending (36 flipped). Pushed: nave-panccadia d6e1b81, cloudflare 58a02d6, ford e55b4f5, Pancaddia 86de4a5 (branch feat/jace-comp-alarms), niagara-research 5a36ca4eb + 4cf57c2db. Process note: a read-only verification sub-fork committed+pushed niagara 5a36ca4eb itself; audited correct, not reverted. Deltas not in the kit → #1116.
- #1115: Opus review CHANGES_REQUIRED (4 findings + partial retro #4) → fixed in follow-up commit; re-review pending. RDD lineage review-b4e3686ae6d882a7 acknowledged on the first commit (passive).
- Merged: #1115 (7ba2369, #1113), #1117 (c209836, #1105; RDD review-7eb3293baf0acfe6 + review-b87ce7d4dd9e76cd, Opus APPROVE r2; nits → #1123).
- Open, in review/correction: #1097 (RDD 4R approved review-2476605a91e2e443 on 2c63048; Opus CHANGES_REQUIRED → round 4: hotcore-loop-cadence "every iteration" contradicts once-per-context, "non-STOP" grammar), #1118 (#1032; RDD approved review-7be3fa1c6ef2f64d; Opus CHANGES_REQUIRED → round 2: case 23 cannot fail, undeclared guard gaps), #1119 (#1108; RDD approved review-b5a25ab17f0d358b with WARNINGs circular teeth/MW23/init lib dep; Opus pending), #1120 (#1109, stacked on #1119), #1122 (#1099; RDD + Opus running).
- New issues: #1121 (unquoted ${var/pat/$repl} in ~17 more sites + lint; enumerator in #1118 too narrow), #1123 (#1117 nits).
- Tooling: scratchpad rdd.sh drives RDD from provider tokens under bash (mapfile/zsh lesson).
- Merged: #1122 (9cdd3e3, #1099; follow-ups #1125), #1097 (d6487cb, #993 WU4 via #1124; CI case 56 install test pinned WU1 placeholder → #1126 gate misses install/tests).
- #1127 (#1106): Opus found charter source wrong — niagara FOCUSES.md is a focus index; modules chartered in the RESEARCH-STATE-<focus>.md each row names (304→~128 unchartered). The merged #1117 doctrine carries the same error → round 2 amends §8c doctrine first, then the tool, + §7 silent-zero fixes, + folds #1123. Lesson: a doctrine PR describing a not-yet-built instrument must be validated against the real corpus shape, not only the instrument's draft header.
- Merged: #1118 (737fef4, #1032), #1119 (55555cb, #1108).
- SHARED CHECKOUT: fleet hooks run KIT=/home/cristian/investigacion/sdd-investigacion/research-sdd, so merged fixes are only live after the shared checkout advances. It was stale at 9f1fcd0 with an unpushed local commit 471f7e8 (row-32 refresh by a Pancaddia session). Rebased local main onto origin/main (now 55555cb + 158be0b) and carried that commit to PR #1137. Lesson: after every merge batch, fast-forward the shared checkout (rebase if a local commit exists) or the fleet keeps running old code.
- three.js: PR #1133 (issue #1132) — row path → corpus dir, honest `hook file yes / unregistered` (sessions launch from the non-git parent, never research/), wrapper KIT fixed to the stable checkout; layout decision #1134, registry WARN #1135.
- Merged: #1133 (37e530a), #1137 (0b0c833), #1120 (921ff62, #1109), #1129 (9852131, #1111). Shared checkout resynced after each.
- #1130: rebased by parent onto 9852131 (teeth-block conflicts resolved: #1129 block, fi, #1130 block; 6 suites green locally; RDD review-8ac7b1be4dc0f1e4) but CI fails env-dependent (T-SEEDABLE-PFX, teeth PFX1, teeth-IDG-oos) → writer making tests hermetic.
- #1127 round 4: commit 4d0db30 done + verified locally (niagara 243/334 chartered · 85 unchartered · 6 bare-mention; fresh-clone gate 133/133), but the writer's `git push` was DENIED by the auto-mode classifier ("Out-of-Place Publication"). Not pushed on its behalf (no permission laundering) → surfaced to the user.
- Merged: #1130 (90bc8f1, #1125; CI hermetic fixes). 11 PRs merged today. Shared checkout synced.
- Wave 3 writers launched: (A) #1121+#1131+#1126 tests/gate; (B) #1135+#1128 wiring states; (C) #1110+#1107 doctrine/score. #1112 METHODOLOGY batch waits for #1127. Pending user decision: #1127 push (A/B/C).
- Merged: #1143 (337131e, #1131). 12 PRs merged today.
- Wave-3 PRs: #1138/#1139 r2 (wording; C4 multi-focus labels), #1140 r2 (off-root premise corrected: sessions start in non-git parent; builtin walk-up, fork-free, TMPDIR-independent, split `(checked:)`), #1141 r2 waits #1140, #1144 r2 (install corpus tests, absent→non-zero, CI double run), #1142 r2 after #1144 (lint misses real sites incl. production verify-registry.sh:152 `&` bug, scan-secrets awk intervals). #1145 SIGPIPE deferral. #1127 push awaiting user.
- Recurring review lesson: new lints/instruments certified the live tree clean while real instances existed → acceptance must enumerate forms against the real corpus (§7), not fixtures.

- Merged late: #1147 (3d8cea8, 8 TARGETS rows: 5 `hook yes`, 3 `hook file yes / unregistered` — sessions never start at root), #1127 (7fca4fb, #1106 focus-partition-audit + §8c doctrine fix + #1123), #1138 (90f722e, #1110), #1139 (a44490b, #1107), #1144 (ce39ce5, #1126). #1134 closed by maintainer decision (three.js stays).

## Close (2026-09-25)
- 17 PRs merged: #1115 #1117 #1122 #1097 #1118 #1119 #1133 #1137 #1120 #1129 #1130 #1143 #1147 #1127 #1138 #1139 #1144. origin/main ce39ce5; shared checkout synced (fleet hooks run it).
- Retro backlog: 53 → 17 pending (36 markers flipped in 5 target repos, user-authorized); deltas not in the kit tracked in #1116.
- Quiet-tree gate on final main ce39ce5 (fresh clone, single runner): run-all --prove-teeth 134/134 suites (133 toolbelt + 1 install), 5046 cases, 0 failed, 8 skipped, 0 hermeticity violations; shellcheck -S warning 0 over 236 files (toolbelt + install). 21 suites without teeth = the known #426 list.
- Issues opened: #1105–#1114, #1116, #1121, #1123–#1126, #1128, #1131, #1132, #1134 (closed), #1135, #1145, #1146.

## Lessons (session 2026-09-25)
1. Fleet hooks execute the SHARED checkout's kit: resync it after every merge batch (rebase if an unpushed local commit exists) or merged fixes never reach the fleet.
2. Writers must run the FULL gate from a normal clone root (cd into it) plus research-sdd/install/tests; every PR that skipped it hid a real regression (#1097 case 56, #1118 .git, #1119 R2-TOOTH-A + profiling flake, #1142 verify-cd-physical).
3. New suites must print `== N passed · N failed ==` LAST (after teeth) or run-all counts them failed.
4. Instruments/lints certified the live tree clean while real instances existed (#1127 charter source, #1142 lint forms): acceptance enumerates forms against the real corpus, never only fixtures.
5. "Hook wired" ≠ "hook fires": Claude Code loads settings from where the session starts; check session cwd evidence before claiming `hook yes`.
6. Writers must never kill processes they did not start (one pkill killed every other writer's gate).
7. `mapfile` under zsh silently empties arrays — drive RDD from a bash script (scratchpad rdd.sh pattern).
8. RDD/Opus do not run the full suite: always wait for CI toolbelt-tests before merging.

## Next session
1. PR #1140 (#1135, wired-off-root) round 2 pushed e745af2: finish its full-clone gate, RDD, Opus re-review, merge.
2. PR #1141 (#1128, reverse hook check) round 2 36f8ed4: rebase onto #1140 once merged (3s off-root test is prepared and expected to go green), gate, RDD, Opus, merge.
3. PR #1142 (#1121) round 2 at 496e2ff: rebase onto main (includes #1144) so the lint also scans install/, fresh-clone full gate, RDD, Opus re-review (verify every missed form from the round-1 review), merge.
4. #1112 METHODOLOGY 8-delta batch (unblocked now that #1127 merged).
5. #1145 (SIGPIPE printf|grep -q and |head family + nits from #1127/#1144 reviews), #1114 (document-cycle scaffold), #1116 (deltas flipped early / still open), #1003 slice 2, #993 WU6 (maintainer eval runs).
6. Maintainer: 10 targets lack a SessionStart hook (adapt <SUBJECT> in research-protocol.sh, then research-sdd-init.sh --wire); 3 rows (nave-panccadia, panccadia-3d-viewer, fluke-177x-datos) and three.js have hooks that never fire because sessions start elsewhere.
