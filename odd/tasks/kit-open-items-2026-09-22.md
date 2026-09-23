# Kit open items after 2026-09-22 (#911, #906, RDD advisories, #903, G54)

## Objective
Close every item left open by `odd/tasks/agenda-2026-09-22-followups.md`.

## Authorized scope
Maintainer, 2026-09-22: "ve por todas utilizando ODD y tienes todo permitido" — ODD + RDD
(consent granted), commit/push/PR/issues/merge. This is also taken as the maintainer's
authorization to refresh `TARGETS.md` rows (CLAUDE.md §8 otherwise reserves them for hand edits):
only MEASURED values, each row read back, commit message names the authorization.
Never invent research content (G54 `tried:` only from recorded evidence).

## TDD
On · source: repo CLAUDE.md §4 · runner `bash research-sdd/toolbelt/tests/run-all.sh [--prove-teeth]`.

## Delivery
One PR per work unit, merged on green CI before the next unit on the same file set.
Strategy: ask-on-risk; each unit expected < 400 authored lines.

## Tasks
Lane A — seeder/verifier (`research-sdd-status.sh`, `verify-state.sh`, their tests), serial:
- [x] A1 — #911a `derive_blocked` misses niagara database DB-G1 form. Route: delegated writer,
  worktree. Root cause: `## Child gaps surfaced at close` section + `needs:` on a continuation line.
  Fleet diff (14 dirs, bash+nullglob — a first zsh run silently traversed nothing): one line,
  database blocked_open 1/0 FAIL → 1/1 ok. RDD high → granted → approved → acknowledged.
  PR #913 merged `7adff02`; sub-issue #914 closed (PR policy needs Closes/Fixes/Resolves).
  Advisory follow-ups: closed child gap with needs: would count; seeder parity untested;
  awk block duplicated across the two scripts.
- [x] A2 — #911b backlog reader reads only one of two backlog tables (platform-native).
  Route: delegated writer, worktree fix/911b-multi-table-backlog. Root cause: (1) awk hardcoded
  n==4 rejected all 5-col tables; (2) "med" priority → INVALID_PRIORITY → filtered out; (3)
  non-Gap-backlog tables silently skipped. Fix: BP-EXPECTED-COLS (track col count from separator),
  MED-ABBREV-NORM (normalize "med" → "medium" with WARN), OOB-WARN (warn on rows outside proper
  heading but still count them). Identical mirror applied to verify-state.sh _backlog_rows().
  Tests: 6 new tests (T-5COL-NOMALFORMED, T-5COL-SYNC, T-TWO-TABLE-SYNC, T-OOB-WARN,
  T-MED-ABBREV-WARN, T-MED-ABBREV-SYNC) + 3 teeth (teeth-BP-EXPECTED-COLS, teeth-MED-ABBREV-NORM,
  teeth-OOB-WARN). RED phase executed against pre-fix SUT; all confirmed failing for right reason.
  Fleet diff: 12 files fixed (0→nonzero), platform-native 0→15; 0 regressions.
  Gates: regular 123/123 suites, 0 failed, 2579 cases; prove-teeth 122/123, 1 pre-existing
  (teeth-#641). Commit: a0afa93; sub-issue: #933; PR: #934.
- [ ] A3 — #911c `--sync-state` writes counter changes silently; seeds manual `undocumented_findings`.
- [ ] A4 — #906 root `RESEARCH-STATE.md` not targetable by `--sync-state` in multi-focus corpus.
- [ ] A5 — #907 advisories (T53 INFO grep scoping, T-905 negative-only check).
Lane B — other tests/libs (disjoint from A):
- [x] B1 — #909 advisory: parity asserts the lib's own rc. PR #921 `a92250e` (closes #919).
  RDD approved; advisory: reviewers report the mutant ok-path was NOT actually tightened in the
  three suites and the comment says it was — follow-up.
- [x] B2 — #910 advisory: TOOTH 9 exercises the real PATH builder (`build_hermetic_nojq_bin`). PR #921.
- [x] B3 — #903: `research-sdd/retros/` trap now fails the retro-grammar suite (RETRO-TRAP). PR #922
  `5dc4003` (closes #920).
- [x] B4 — #903: guard uses `typeset -f` (portable). PR #922. Advisory follow-up: when zsh is
  absent the ZSH-GUARD case counts its skip as PASS (§7 silent pass).
Lane C — corpora/registry data:
- [ ] C1 — niagara divergent counters (#911 list) re-seeded after A1–A3, each checked against prose.
- [ ] C2 — niagara root covered_blocks after A4.
- [x] C3 — #903 registry refreshed under maintainer authorization. PR #916 `ca640c9` (closes #915).
  verify-registry: 8/6/17/5 → 0/0/0/0. Block counts carry `@2026-09-22`; narrative moved to detail §§.
- [x] C4 — #903 breakthroughs: 3 rows in portable `$RESEARCH_HOME` form. PR #918 `8e09587`.
- [ ] C5 — #903 retro delta headings (26 non-conforming) and pending-retro/tool-ledger triage.
  Measurement (mapper): sweep now flags 19 pending retros (9 WARN-A prose-body, 10 WARN-B
  heading); 10-retro sample of the 74 pending: 6/7 with markers are genuinely open, so the
  2026-09-20 "~81% already applied" rate does NOT carry over. Tool ledger rows need authored
  descriptions (only name/target/status derivable). C5a headings: delegated writer.
  C5a done: 21 retros in 7 repos conformed (niagara 9257323b9, sullair 7030d53, cloudflare
  2766ca0, nave-panccadia 4aa423b, fluke 389b6e9, Pancaddia 00f9270 on its checked-out branch
  feat/jace-connection-monitor, ford 6b71c4c); Pancaddia rows verified as transcriptions of its
  own "candidatos a kit" list. Defect found: two zero-delta retros got a fake "no new deltas"
  row that counts as 1 → #912 (sweep-retros cannot represent 0). Task C7 below.
  C5b: seed the genuinely-open deltas as GitHub issues (backlog-first) after C5a.
  C5c: tool ledger — not auto-generated (would invent descriptions).
- [ ] C7 — #912 sweep-retros recognises the §18 honesty line as countable 0; then remove the
  two fake rows (ford update-notice, niagara tools-search-innovation). After lane B merges
  (it owns sweep-retros.test.sh).
- [x] C8 — sweep-breakthroughs expands `$RESEARCH_HOME` pointers. PR #918 (closes #917); sweep
  3 tagged · 0 unindexed · 0 drifted. Advisory: `&`/trailing slash in RESEARCH_HOME, $HOME fallback untested.
- [x] C6 — blender-llm G54 `tried:` from recorded evidence only. Route: delegated evidence
  search + inline edit. Only recorded rung: LibreDWG `dwgread -O JSON` (B31 §31.4). A subagent
  draft claiming "no decoder available via install-tool.sh" was dropped — it was never run.
  blender-llm `a03f5df` pushed; verify-state exit 0, tried: WARN gone. Research follow-up for
  the target (not kit work): §21.4 provisioning + §21.2 chain were never walked for G54.

## Progress / evidence
- Merged this session (all on green CI): #913, #916, #918, #921, #922. Peer repos: blender-llm
  `a03f5df`; retro conformance in 7 repos (see C5).

## Session 2026-09-22/23 (resume) — results
Maintainer: "ODD + RDD (todo granted)", commit/push/PR/issues/merge; audit the /research-sdd skill + kit.
Routes: every unit delegated to a sonnet writer in a harness worktree (writer trigger: 2+ non-trivial
files); native RDD 4R per PR (consent granted); PR-level adversarial review before merge (FABLE for
the first 6, then Opus per maintainer instruction 2026-09-23).

Audit (D1) findings:
- The DEPLOYED skill `~/.claude/skills/research-sdd/SKILL.md` (and reasonix's copy) was a stale
  2026-08-23 copy of the kit source (missing §11b, §22, frontier mode). Redeployed with
  `research-sdd-install.sh --force-skill` (backups `SKILL.md.local-backup`); drift is now surfaced at
  SessionStart by `verify-skill-drift` (#928).
- retro-gate swallowed seeder failures (#930) and its `created=` count was always 0 because it grepped
  a string the seeder never prints (#935/#937).
- Recurring root class: mutation "teeth" that pass because the mutant crashes, never applies, or is
  hand-written — caught 7+ times this session → #943 (shared helper + lint).

Merged (all RDD-approved + PR-level reviewed + CI green):
- #928 c043c1a — verify-skill-drift SessionStart check, all harnesses, OpenCode/Codex parity (closes #927)
- #930 a3fbb48 — retro-gate captures seeder rc, failed=N (closes #929)
- #937 6eb5820 — retro-gate parses the seeder's summary line; ran=/empty=/failed= (closes #935)
- #932 0943c9a — ENVIRON-based awk in lib/target-paths.sh + sweep-breakthroughs; trailing-slash
  normalization; noarg parity teeth; typed SKIP (closes #931)
- #946 a678461 — install-tool.test.sh flake: sha256sum stub SIGPIPE under load (closes #941)
- #944 08ee2fb — seeder: failed=N + exit 2, anchored fence-aware marker read, case-sensitive PARTIAL (closes #938)
- #947 314e0a0 — sweep-breakthroughs ledger lookup is a whole-line match (closes #939)

Closed unfinished (branches kept, handoff in the PR comment):
- #926 (#912 zero-delta honesty line) — branch fix/912-zero-delta-retro + wip/912-leading-blockquote-rule.
  Blocker: template-scaffold blockquote exemption must survive template-text drift (ford).
- #934 (#911 A2 multi-table backlog) — branch fix/911b-multi-table-backlog + wip/911b-hierarchy-provisioning-regression.
  Blocker: REGRESSION hierarchy 7→6 / provisioning 10→7 (`## Gap-backlog (…) — free text` headings).
WIP pushed (unverified): wip/936-skill-drift-followups (#936), wip/940-retro-gate-followups (#940).

Issues filed: #935 #936 #938 #939 #940 #941 #942 (decision: accept `med`?) #943 (teeth root class) #945
(two marker scopes — now live split-brain after #944) #948 (ledger drift ignores line numbers) #949 (seeder
shipped-ID `#`, dedup vs closed issues, fence edges).

Lessons (also in Engram): rebase every PR branch onto origin/main before RDD (a stale base made RDD
review a reverted #928); never accept a writer's "pre-existing failure" or fleet classification without
re-running it (three false claims caught: teeth-#641 "pre-existing", "0 U+2011 headings", hierarchy/
provisioning "expected"); template text drifts, so rules that match it verbatim fail real retros.
RDD in Claude Code: run capture-result with `--agent claude-code` in-process (the tool-free review-*
subagents cannot relay); correction flow = capture-correction-plan → fix commit → capture-validation.

## Next step (next session, in order)
1. #926/#912: resume from wip/912-leading-blockquote-rule (see PR #926 closing comment), then remove
   the fake row in ford (`corpus/retros/2026-09-10-update-notice.md`) and replace niagara's
   (`retros/2026-09-17-tools-search-innovation.md`) with the honesty line.
2. #934/#933: resume from wip/911b-hierarchy-provisioning-regression; per-file acceptance table.
   Then A3 #911c, A4 #906, #913 advisories (lane A, serial), then C1/C2 niagara counters.
3. #942 needs the maintainer's doctrine decision on `med` (9 fleet rows) before platform-native can be re-seeded.
4. wip/936 and wip/940 → finish, verify, PR.
5. #945 (single marker scope), #943 (teeth helper + lint), #923 remaining (#907/#913 items).
6. C5b: seed the genuinely open deltas of pending retros as issues — only after #945 and #949 (dry-run first; never --apply before dedup is fixed).
7. C5c tool ledger (181) — scope decision with the maintainer.
