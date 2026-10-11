<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — sdd-investigacion (the kit itself) · GFM escape rule, corpus-wide id validity, claim verification · 2026-10-11 · Research-SDD self-retrospective

> Run reviewed: kit chain 2026-10-11 (odd/tasks/kit-chain-2026-10-11.md), PRs #2127 #2131 #2132 #2140 #2147 and issues #2118 #2128 #2135 #2148 #2150. Trigger: maintainer request.
> Method: inline (coordinator wrote it from the session's review records; no separate fresh-context agent), so discount its self-review accordingly.

> **Provenance:** base `d0ac760f` · head `819cd203` (origin/main at writing) · gate-run `none for this retro; the cited PR gates are in odd/tasks/kit-chain-2026-10-11.md` · reruns `none`

## Proposed kit deltas

| ID | Delta | Target | Evidence | Priority |
|---|---|---|---|---|
| D1 | **Check markup semantics against the authoritative renderer before encoding a parser rule, and cite the render in the code.** A rule derived from memory or a paraphrase of a spec ("an even backslash run before a pipe is a column break") was implemented, reviewed once, and was wrong: GitHub renders any backslash-pipe as an escaped pipe. One `gh api -X POST /markdown -f mode=gfm` call settles it. | `CLAUDE.md` §7 (false-negative direction) + `METHODOLOGY.md` §7 | PR #2147 first head 05305267 (odd/even) reversed at ceacfc37 after the GitHub render: `x\\\| y` renders one cell `x\| y`; append-iteration-row.v1.md carried the same wrong rule since before #2135 | HIGH |
| D2 | **Any change to a delta-id or signature validity rule needs a full-corpus dry-run diff of stage-retro-issues over ALL retros, not only the files containing the triggering character.** Narrowing the corpus to files that mention the character hid the only real-data effect. | `CLAUDE.md` §7 (acceptance is a fleet sweep) | PR #2147: the 18-retro diff (files containing a backslash-pipe) showed 0 changes; the 190-retro diff found niagara `2026-10-31-optimizersupervisor-os-arc-resume.md` Delta rows Δ1–Δ4 → #2150 | HIGH |
| D3 | **Retro delta ids must be ASCII signature-safe (`[A-Za-z0-9_-]`): no Greek letters, no markdown emphasis.** reconcile reads ids back from issue signatures with `^[A-Za-z0-9_-]+`, so a non-ASCII id can never be tracked; from #2147 on it is typed `id-not-signature-safe`. The retro template should state the id grammar next to the table. | `research-sdd/templates/retro.template.md` + `METHODOLOGY.md` §18 | #2150: niagara (Δ1–Δ4), fluke-177x-datos (Δ1–Δ3 in two retros), blender-llm (`**E5**`, `**E6**`) | MED |
| D4 | **Writers that add or edit test files run the repo-wide lint suites (pipefail-sigpipe-lint, lint-substitution, self-dir-idiom) besides their focused suites.** Two full gates failed only on pipefail-sigpipe-lint for new `producer \| grep -q` lines, costing a gate slot each. | `CLAUDE.md` §5 (gate table) / writer brief in the kit-chain practice | PR #2131 gate: 198/199 (6 violations in run-all-shard/shard-join tests); PR #2132 gate: 2 violations in kit-checkout-resolution.test.sh | MED |
| D5 | **Measure what the consumer receives, in its unit: characters of the decoded text, not bytes and not the raw stream.** A SessionStart card was first reported over the 10,000-char cap as 11,494 / 12,368 — those were UTF-8 BYTES of the decoded text (accents and box-drawing characters are multi-byte); the decoded additionalContext is 9,514 / 9,578 characters, and the raw JSON stdout only adds ~280 characters of escapes (9,796 / 9,822). Size checks must decode first and count characters (as verify-session-budget.sh does). | `CLAUDE.md` §7 ("report only what you measured") | #2128 corrected; measured 2026-10-11 with `wc -m`/`wc -c` on raw and jq-decoded output of both niagara cards; PR #2140 measures decoded chars | MED |
| D6 | **Issues opened by an orchestrator for kit work carry `status:approved` at creation when the maintainer pre-authorized the work; otherwise merge-gate refuses the PR on the issue-label check after a full green gate.** | kit-chain practice / `CLAUDE.md` §10 | PR #2127: gate 197/197 green, merge refused `ci_failed (Check Issue Has status:approved)` because #2118 lacked the label | LOW |

## Already covered
- Propose-never-apply for corpus fixes (§8): #2128, #2141, #2150 were filed, not applied.
- Anti-silent-zero typed states (§7): the new instruments report degraded/absent/empty distinctly.

## Lessons
- The most expensive defect this session was a rule nobody checked against the system that defines it; the cheapest check (one API call) was the decisive one.
- Narrowing an acceptance corpus to "files that look affected" is a form of the enumerator-coverage gap §7 already names.
