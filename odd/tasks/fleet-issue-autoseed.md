# Fleet issue auto-seeding (T7, #977 follow-through) — session 2026-09-24b

## Objective
Retro deltas from every research target reach the kit repo (`angeles725/sdd-investigacion`) as GitHub issues
automatically, without a manual `stage-retro-issues.sh --apply` step. Then continue the kit backlog in chain.

## Problem (measured 2026-09-24)
- `reconcile-issues.sh --all`: tracked=6 untracked=97 degraded=2 over 116 retros; retros dated 09-20 and 09-23
  carry untracked deltas although the Stop-hook seeder (EN3) shipped on 09-21.
- Wiring sweep: 2 wired / 4 unwired / 11 absent-settings / 0 unreadable (17 targets).
- `stage-retro-issues.sh` runs `gh issue list` / `gh issue create` with no `--repo`; under the Stop hook the cwd
  is the TARGET, so gh resolves the target's own remote (e.g. `research-blender-llm`: 0 issues, 0 `target:*`
  labels) — creation would fail on missing labels or land in the wrong repo; targets with no remote always fail.
- `research-sdd-init.sh --wire` on an existing corpus only merges settings.json; it cannot recreate a missing
  `retro-gate-stop.sh` (COB-IM2, sullair, panccadia-3d-viewer, nave-panccadia, Pancaddia), and wires a
  SessionStart hook whose `<SUBJECT>` may be unadapted.
- Side finding: `verify-registry.sh` row companion check ignores `$RESEARCH_HOME/...` tokens → three.js row
  double-counted as absent (17 reported vs 16 real).

## Scope / authorization
Maintainer authorized (2026-09-24): ODD, native RDD consent granted, commit, push, PR, issues, merge; accept
gentle-ai review prompts; continue in chain without asking.

## Constraints
- Branches on `origin/main`; writers in harness worktree isolation; one RDD lineage per repo at a time.
- TDD strict (kit CLAUDE.md §4), source: project contract; runner `bash research-sdd/toolbelt/tests/run-all.sh`.
- Target repos: only `.claude/settings.json` and missing `.claude/hooks/*` files; `git add <file>` only; never
  touch corpus files; propose-never-apply for anything else.
- ~400 authored lines per PR (advisory).

## Tasks
- [x] WU1 (#1037) — PR #1042 merged f7788ad (RDD approved+ack review-4f1d6938b6b24fec; Opus APPROVE; hardening follow-up #1045 in progress). seeder targets the kit repo explicitly (`--repo` from the kit's own origin; typed error when it cannot
  be resolved) for list + create; tests + teeth. Route: delegated writer (sonnet, worktree) — script + test.
- [x] WU2 (#1038) — PR #1040 merged c10f9d9 after 3 rounds (Opus BLOCK×2 → APPROVE; RDD approved ×3); follow-ups #1043. `research-sdd-init.sh` repair mode: create only ABSENT hook files on an existing corpus, never
  overwrite; `--wire` skips the SessionStart entry while `research-protocol.sh` still contains `<SUBJECT>`.
  Route: delegated writer (sonnet, worktree).
- [x] WU3 fleet wiring — DONE for wiring: 13 wired / 2 unwired (module-navigator, three.js: not git roots) / 2 absent (niagara-help: no corpus; kit self). Backups of every .claude/ in scratchpad wire-backup/. .claude/ is gitignored in most targets → working-tree wiring, no target commits. SessionStart deferred (unadapted <SUBJECT>) in 10 targets. MISTAKE: --wire on niagara-help (no corpus marker) scaffolded a full corpus → removed by hand, issue #1047. REMAINING: triage the 97 untracked rows before any target session (retro-gate seeds every pending-marker retro).: run repair + `--wire` on each real target with a git repo; verify the wiring sweep;
  commit settings/hook files per target (`git add <file>` only). Route: inline ops (state + bounded commands).
- [x] WU4 (#1039) — PR #1041 merged 0ea1ae7 (RDD approved+ack review-13220fbf867b198e; Opus APPROVE; follow-up #1044). `verify-registry.sh` companion check recognizes `$RESEARCH_HOME` tokens. Route: delegated writer.
- [~] WU5 continue kit backlog: #993 WU4 → PR #1097 round 2 pushed, parked (provenance decision); #1003 slice 2, #1032 → next session.

## Acceptance
- A seeded issue from a target cwd lands in the kit repo with its labels (hermetic mock gh test asserts `--repo`).
- Wiring sweep reports every git-backed target wired (exceptions documented).

## Progress
- 2026-09-24: mapping done (delegated explorer); document created.
- 2026-09-24: issues #1037 #1038 #1039 filed; WU1, WU2, WU4 writers launched in parallel (disjoint file sets, harness worktrees).
- 2026-09-24: WU2 → PR #1040 (5504b27): RDD approved+acknowledged (lineage review-e661930db594942f; 5 WARNING advisories: half-wired on jq merge failure ×2, degraded snippet ignores SUBJECT gate, partial hook create not repairable, duplicated snippet); Opus review running.
- 2026-09-24: WU4 → PR #1041 (3c0b052): fleet diff only 17→16 absent; RDD running; Opus review running.
- 2026-09-24: WU1 → PR #1042 (57a3cec): real dry-run from /tmp resolves angeles725/sdd-investigacion; Opus review running; RDD queued (one lineage per repo).
- 2026-09-24: PR #1040 Opus BLOCK (reproduced: duplicate SessionStart vs $CLAUDE_PROJECT_DIR form on cloudflare; malformed settings.json → hooks left + exit 0; snippet ignores SUBJECT gate) → round 2 sent to the WU2 writer (+ comment-line SUBJECT detection, 'already wired'). Pre-existing edge cases → #1043.
- 2026-09-24: #1041/#1042 merged; missed the 'PR Has type:* Label' check before merging — labels added after (lesson: label every PR at creation).
- 2026-09-24: #1045 hardening writer launched (stage-retro-issues only, disjoint from WU2).
- 2026-09-24: #1046 (#1045 hardening) RDD approved; Opus BLOCK (alias/port regressions) → round 2 with writer.
- 2026-09-24: fleet wired (see WU3). Triage of 97 untracked rows launched (3 read-only sonnet mappers, slices A/B niagara-research, C others) → next: flip APPLIED/DISMISS markers (git add <file> only), seed OPEN rows with stage-retro-issues --apply.
- 2026-09-24: END-TO-END PROOF: a peer session in niagara-research ended a turn → Stop hook seeded 42 issues (#1048–#1089) into the kit repo. Triage (3 read-only mappers) of the 97 untracked rows: APPLIED 76, DISMISS 14, OPEN 7 (triage-A/B/C.tsv in scratchpad). Of the 42 seeded, only #1058 (harbor H-2) is a real open delta.
- 2026-09-24: marker flips in target retros DENIED by the permission classifier (Modify Shared Resources) — same as T6. Prepared scratchpad/flip-markers.sh for the maintainer. Closing the 41 false issues waits for #949 (dedup ignores closed issues → they would re-seed). New bug #1090 (PARTIAL matched case-insensitively in marker prose).
- 2026-09-24: #1046 round 2 pushed (alias/port regressions fixed, parent-verified); RDD + Opus running. Next: #949 dedup fix (same file, after #1046 merges).
- 2026-09-24: #1046 merged dae3a84 (2 rounds; Opus APPROVE; RDD approved ×2). Shared checkout fast-forwarded (fleet hooks run it).
- 2026-09-24: writers launched in parallel, disjoint files: (a) #949+#1090 seeder dedup over closed issues / list-failure fail-closed / '#' strip / PARTIAL token + Opus resolver follow-ups (stage-retro-issues.sh, reconcile-issues.sh, lib); (b) #1047 --wire refuses to scaffold (research-sdd-init.sh).
- 2026-09-24: maintainer ran flip-markers.sh (44 retros). reconcile: untracked 97 → 17 = 6 genuinely OPEN rows + 11 rows in *-closure.md retros whose marker sits after the H1 (reconcile reads the leading block only; retro-gate reads the whole file and does NOT seed them) — evidence added to #945. orphaned=36 = the false seeded issues, to be closed after #949 merges. Flipped retros are uncommitted in 7 target repos (maintainer's call; hooks read the working tree).
- 2026-09-24: marker commits (maintainer-authorized): niagara-research df72f53d6 (27), fluke 265c018 (4), blender-llm 95d51f5 (6), api-paneles 029d0ec (2; paneles-handoff.md is untracked, left), cloudflare 946d6ca (1), panccadia-3d-viewer 53c06df (2, branch fix/graficas-rango-largo), hisense 993ed2b (1). Push to target remotes denied to the agent by the classifier; maintainer pushed all 5 remotes.
- 2026-09-24: PR #1091 (#1047 --wire refuses scaffold, exit 5; --scaffold opt-in): RDD approved; Opus BLOCK (--force --wire bypasses refusal) → round 2 with writer (+ RESEARCH-STATE-*.md markers, --scaffold alone rejected, tautological tooth, vacuous snapshot).
- 2026-09-24: PR #1092 (#949 items 1–2 + #1090 + resolver follow-ups; shared lib/retro-status.sh): RDD + Opus running. Writer's first run-all 128/130 happened while it was still editing / another gate ran; quiet re-run 130/130 — parent re-runs gate before merge.
- 2026-09-24: #1092 merged b337204 (RDD approved; Opus APPROVE; follow-ups #1093). Shared checkout fast-forwarded. Closed the 41 false seeded issues with evidence (32 APPLIED + 6 DISMISS from triage; #1051/#1052/#1082 already shipped per their own markers — the pre-#1092 '#' strip bug). Seeded the genuinely open rows: #1094 (sullair DR-1), #1095/#1096 (sullair junta 1, 2). Three rows triaged OPEN were already resolved earlier (#832, #834/#562, #693) — the new dedup correctly refused to recreate them; marker script scratchpad/flip-markers-2.sh prepared for the maintainer.
- 2026-09-24: maintainer ran flip-markers-2.sh (fluke ×2, nave D11; committed+pushed). reconcile --all: tracked=10 untracked=15 orphaned=0 — every untracked row is in the five *-closure.md retros (marker after H1, #945), all triaged APPLIED. T7 outcome reached: issues arrive automatically in the kit repo, false positives closed and cannot re-seed.
- Next in chain: #1091 round 2 → #945 (shared marker scope, would bring untracked to 0) → #1093 → backlog (#993 WU4, #1003 slice 2, #1032, follow-ups).
- 2026-09-24: PR #1091 (#1047) merged da63a45 after 2 rounds (Opus BLOCK → APPROVE; RDD approved ×2); follow-ups on #1043. Shared checkout fast-forwarded.
- In progress: #945 + #1093 writer (single marker parser across reconcile / seeder / retro-gate / sweep-retros).
- 2026-09-24: WU5 chain: #993 WU4 writer launched (profile slots; SKILL/PROMPT-LOOP markers + general.slots.md + profile tests), disjoint from the #945/#1093 writer. #1032 (stray 'git' file) waits: suspected in stage-retro/retro-gate suites owned by the #945 writer. #1003 slice 2 waits for WU4 (same PROMPT-LOOP file).
- 2026-09-24: PR #1097 (#993 WU4): RDD approved; Opus BLOCK — `return-contract-shape` is not #992 wording (verified: SHAPE paragraph unchanged since tag prompts-pre-audit-2026-09-23), general body newly authored + partial field list; invariants are absence-only (ask-operator / wait mutants survive) → round 2: drop that slot, restore pre-audit fragments, add presence invariants + M1/M2 controls.
- 2026-09-24: PR #1098 (#945+#1093; fleet reconcile untracked 15→0): RDD run against a stale base (branch on b337204, origin/main already da63a45) → correction_required with 5 false findings ("#1091 reverted"). Abandon needs maintainer authorization (classifier denied agent-built auth) → scratchpad/abandon-1098.sh for the maintainer; then rebase + fresh RDD. Lesson saved: rebase before every RDD preflight.
- 2026-09-24: PR #1098 re-reviewed after the maintainer abandoned the stale lineage (review-30d3468c70a5b7c6) → rebased, RDD approved, merged 2784f44. Fleet reconcile: tracked=10 untracked=0 orphaned=0 degraded=0.
- 2026-09-24: PR #1097 round 2 pushed (e2f2ab5): return-contract-shape removed; fidelity restored; presence/absence teeth. Provenance: only hotcore-loop-cadence is #992; three slots come from #989 (6d88930), hotcore-reread-scope has no pre-audit text → design decision next session. Not reviewed/merged.

## Session 2026-09-24b — merged
| PR | Issue | Rounds | Merge |
|---|---|---|---|
| #1042 | #1037 seeder targets the kit repo | 1 | f7788ad |
| #1041 | #1039 verify-registry $RESEARCH_HOME tokens | 1 | 0ea1ae7 |
| #1040 | #1038 init wire-only repairs hooks, defers unadapted SessionStart | 3 | c10f9d9 |
| #1046 | #1045 kit-repo resolution hardening | 2 | dae3a84 |
| #1092 | #949 (1–2) + #1090 dedup over closed issues, PARTIAL token | 1 | b337204 |
| #1091 | #1047 --wire refuses to scaffold | 2 | da63a45 |
| #1098 | #945 + #1093 one marker scope/parser | 1 (+ stale-base abandon) | 2784f44 |

Fleet ops: 13 targets wired (Stop hook); 44+3 retro markers refreshed and committed in 7 target repos (maintainer-run scripts, maintainer-pushed); 41 false seeded issues closed with evidence; real open deltas #1058 #1094 #1095 #1096.
Follow-up issues filed: #1043 #1044 #1093(closed by #1098) #1099.

## Lessons (2026-09-24b)
- Wiring a hook that seeds from stale markers floods the backlog: triage markers BEFORE enabling auto-seeding.
- A dedup that ignores closed issues makes every close temporary — fixed in #1092.
- Rebase on origin/main immediately before every RDD preflight (a stale base produced 5 false blockers); abandoning a lineage needs the maintainer.
- `--wire` on a target without a corpus marker scaffolded a corpus (niagara-help, cleaned by hand) — now refused (#1047).
- Target-repo retro edits and pushes are denied to the agent by the permission classifier; hand the maintainer a reviewed script.

## Next session
1. PR #1097 (#993 WU4): decide the provenance question (does 'general = pre-audit wording' cover #989-sourced slots; what hotcore-reread-scope's general body should be), then RDD + Opus + merge; then WU6 maintainer eval runs (evals/profile-ab/PROTOCOL.md).
2. #1099 (priority high): a marker outside the recognized scope fails open (every row seeded).
3. #1032 stray 'git' file in cwd (stage-retro / retro-gate suites now free).
4. #1003 slice 2 (PROMPT-LOOP L2).
5. Follow-ups: #1043 #1044 #949 (items 3, 5) #1033 #1034 #1031 #1030 #1025 #1023 #1017 #1015 #1014 #1013.
6. Maintainer: adapt `<SUBJECT>` in research-protocol.sh for the 10 targets whose SessionStart was deferred, then re-run `research-sdd-init.sh <target> --wire`; T6 ford retro fake row.

## Close (2026-09-24b)
- Quiet-tree gate on merged main `2784f44`: run-all --prove-teeth 130/130 suites, 4635 cases, 0 failed (8 skipped; 21 suites without teeth, the known #426 list); shellcheck 0 warnings over 223 files. A stray `git` file appeared in the gate worktree again (#1032 reproduces on main).
- Cleanup: 8 agent worktrees removed (all clean and pushed); merged branches deleted locally and on the remote; PR #1097 branch kept (open, parked).
