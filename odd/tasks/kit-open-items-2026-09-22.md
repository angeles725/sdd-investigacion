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
- [ ] A2 — #911b backlog reader reads only one of two backlog tables (platform-native).
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

## Next step (next session, in order)
1. A2 #911b multi-table backlog reader (platform-native) — then A3 #911c (`--sync-state` reports
   non-covered counter changes; stop seeding `undocumented_findings`).
2. C7 #912 zero-delta honesty line countable as 0, then remove the two fake rows.
3. A4 #906 root targeting → C2 niagara root covered_blocks (attributed derivation gives 11).
4. C1 niagara divergent counters (#911 table) after A2/A3, each checked against prose.
5. C5b seed genuinely-open deltas of the 74 pending retros as issues (backlog-first).
6. Advisory follow-ups (#923): A1 (closed child gap needs:, seeder parity test, duplicated awk),
   #907 (A5), #921 mutant ok-path, #922 zsh skip-as-pass, #918 RESEARCH_HOME escaping.
7. C5c tool ledger (181) needs authored descriptions — decide scope with the maintainer.
