<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — gentle-ai · v4.0.0 delta and kit adoption synthesis (B28-B34) · 2026-10-04 · Research-SDD self-retrospective

> Run reviewed: gentle-ai B28-B34 (v2.2.0 to v4.0.0 delta, issue/PR management, automated issues, component communication, creation and working method, adoption synthesis, instruction adherence). Trigger: focus-completion.
> Method: a delegated writer read the kit (`METHODOLOGY.md` §3/§4/§7/§8b/§14/§18, `templates/retro.template.md`) first, then the six sweep notes, re-opened cited sources and kit files, and proposes kit deltas. READ-ONLY on the kit — this report only
> PROPOSES; kit changes are human-reviewed and human-committed (METHODOLOGY §18). The ranked evidence is [B33]; each row below points at its B33 candidate number.

## Proposed kit deltas

| # | Proposed change | Target (file · §/section) | Evidence (block / commit / § / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | Make the PR issue-reference gate comment-blind: port a single parse seam (strip HTML comments, `Refs` non-closing keyword, fail closed on malformed or cross-repo) with a `node --test` job; RED first with `<!-- Closes #N -->`. Verified latent silent-pass: both jobs scan the raw body | `.github/workflows/pr-check.yml` (lines 24-26, 49-51), `.github/PULL_REQUEST_TEMPLATE.md`, new `.github/scripts/` | B33 §33.1 and candidate 1; B29 §29.4, §29.8 | new | HIGH |
| 2 | Reconcile the routing table that says "Read 1–3 files" / "Understand 4+ files" with the evidence budget (at most 3 calls / ~10k tokens inline; more than ~5 sequential lookups to a mapper; 2+ non-trivial files to a writer) or state which rule wins. gentle-ai's own test bans those exact strings as stale triggers; the two rules now coexist in one session | `CLAUDE.md` §1 (lines 23-24) | B33 candidate 2; B34 §34.6, §34.8; B28 §28.3 | refinement | HIGH |
| 3 | Add `research-sdd-install.sh --verify`: sorted-path digest over installed SKILL.md, profile and hooks; report match / drift / absent; read-only | `research-sdd/install/research-sdd-install.sh` | B33 candidate 3; B32 §32.4 | new | HIGH |
| 4 | Add `retired-phrases.txt` and one `doctrine-absence.test.sh` that walks every `*.md` under `research-sdd/` against it (phrase, issue, replacement); seed with the two strings of delta 2 | `research-sdd/toolbelt/tests/` (new suite), `research-sdd/METHODOLOGY.md` §11b | B33 candidate 4; B34 §34.6 | new | MEDIUM |
| 5 | Closed reason-code table for WARN/DEGRADED classes with a test that every emitted code is listed; every refusal line prints its exit command | `research-sdd/toolbelt/` docs (`REASON-CODES.md`), `METHODOLOGY.md` §7 | B33 candidate 5; B31 §31.4 | new | MEDIUM |
| 6 | Writer outcome triad and read-back: after `gh issue create` view the body and assert the signature line; print `mutation=not_started/unknown/committed retry_safe=...` | `research-sdd/toolbelt/stage-retro-issues.sh`, `reconcile-issues.sh` | B33 candidate 6; B30 §30.6, §30.10 | new | MEDIUM |
| 7 | Provider-issued continuation token: `research-sdd-status.sh --next --emit-token` prints the literal token line; PROMPT-LOOP says copy it, never compose it; a Stop hook compares the last report's token with `--next` and blocks once on mismatch (override form allowed) | `research-sdd/toolbelt/research-sdd-status.sh`, `retro-gate.sh` or sibling hook, `PROMPT-LOOP.md` RETURN CONTRACT | B33 candidate 7; B34 §34.3, §34.5, §34.8 | new | MEDIUM |
| 8 | Pre-mutation privacy scrub for staged issue text (paths, emails, `KEY=VAL`; allowlist; typed redaction count). Measure fleet incidence first: 1 of 6 retro files in this corpus carries an absolute home path | `research-sdd/toolbelt/lib/` (new), `stage-retro-issues.sh` | B33 candidate 8; B30 §30.6 | new | MEDIUM |
| 9 | Occurrence comment (one per issue per new retro) when an exact signature is already tracked; add "adjacent issues checked" to the defect form | `stage-retro-issues.sh`, `.github/ISSUE_TEMPLATE/kit_defect.yml` | B33 candidate 9; B30 §30.4 | new | MEDIUM |
| 10 | Closure-evidence rule (commit AND test, borderline list); verify `shipped` rows reach `origin/main`; add a `regressed` class for human review, never auto-reopen | `reconcile-issues.sh`, `METHODOLOGY.md` §18 | B33 candidate 10; B29 §29.7 | refinement | MEDIUM |
| 11 | Ship `templates/odd-task.template.md` with per-task `Route:` and `Evidence:` lines; checker later | `research-sdd/templates/` | B33 candidate 11; B32 §32.5 | new | LOW |
| 12 | Opt-in `--json` envelope with a `schema` constant for high fan-in instruments, carrying the §7 three-state enum | `research-sdd/toolbelt/*.v1.md`, verify-registry, sweep-retros, resume-state, retro-gate | B33 candidate 12; B31 §31.2 | new | LOW |
| 13 | Provenance line (base sha, head sha, gate-run id, reruns disclosed) in the retro and PR templates | `research-sdd/templates/retro.template.md`, `.github/PULL_REQUEST_TEMPLATE.md` | B33 candidate 13; B28 §28.1 | new | LOW |
| 14 | Exactly-once heading-count assertions on rendered profiles and the installed SKILL, plus a forbidden-leak list | `research-sdd/toolbelt/tests/profile-invariants.test.sh` | B33 candidate 20; B34 §34.6 | refinement | LOW |
| 15 | Read-only agent definitions (no Edit/Write) for kit reviewers, deployed by the installer | `research-sdd/install/`, `CLAUDE.md` §2 | B33 candidate 24; B34 §34.4 | new | LOW |

- **#1** — latent gate bypass; S cost, high value; Refs also lets delta-staging PRs avoid auto-closing backlog issues.
- **#2** — verified at `CLAUDE.md:23-24`; costs a doc PR; the model otherwise resolves two live contradictory rules arbitrarily.
- **#3** — catches a stale installed skill versus the checkout (known hazard); report-only so propose-never-apply holds.
- **#4** — upstream's first prose fix reached one runtime and left ten; the same regression shape is possible here (kit #962 orphan sections).
- **#5-#6** — make "report only what you measured" and half-applied issue batches auditable; additive output.
- **#7** — closes the model-authored `next:` gap that the transcript scorer already measures; override form avoids blocking operator redirects.
- **#8-#10** — issue-writer lane; serial on `stage-retro-issues.sh` (CLAUDE.md §3); #8 gated on measuring incidence (§7).
- **#11-#15** — cheap or experimental; #12 and #7 share instrument-contract files.

## Already covered (dedupe — proof the retro read the kit first)

- Deterministic whole-line signature dedup of staged issues → already covered by `stage-retro-issues.sh` (`:722-728`, `:1030`) and ahead of upstream's LLM-judged equivalence (B30 §30.10).
- Single-source slot rendering with per-family profiles → already covered by `render-profile.sh` and `profile-invariants.test.sh` (B34 §34.8).
- A live adherence metric → already covered by `score-loop-transcript.sh`; upstream has none.
- Atomic envelope writes → already covered by `research-sdd-status.sh --sync-state` (same-directory temp plus `mv`); `state-update.sh` is propose-only (B33 §33.3). Only lock and expected-revision remain (B33 candidate 19, not proposed here).
- 400-line work-unit budget and chained PRs → already covered by `CLAUDE.md` §6.
- No AI attribution in commits → already covered by `CLAUDE.md` §10 and agrees with upstream `AI_POLICY.md:28`.

## Anti-patterns observed (optional)

- A sweep note premised a kit change (lock plus expected-revision on `state-update.sh`) on the script editing in place; it does not → verify the kit-side baseline before ranking (B33 §33.3). Closest delta: none new; this is §14 correction-on-absence applied to a comparison baseline.
- A sweep cited the gate regex at the wrong lines (21-23 vs 24-26) → re-open the cited file before quoting line numbers.

## Every 'no' said in this run → its route ladder and whether it was reopened

| # | "No" said (block / gap) | Route ladder (>=3 classes · cheapest next step) | Reopened? (child gap / block / not yet) |
|---|---|---|---|
| N1 | B31 §31.17 · "stop-hook body was not read" | own-surface (read `internal/cli/review_stop_hook.go`) · other instrument (codegraph) · live (run hook on a scratch repo) → read the file | `B34 §34.5` (done) |
| N2 | B32 §32.9 · "sync write list not enumerated" | own-surface (`internal/pipeline`) · live (dry-run on scratch HOME) · operator (ask maintainers) → read the planner | `RESEARCH-STATE: sync write list` (pending) |

## Tools built, adapted, or outgrown

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | — | `tools/gen-catalog.py` · run unchanged to regenerate CATALOG.md for B1-B34 | — | — | `keep-local` · regenerated the catalog; the repo-local copy hard-codes the `sdd-mental-model-bloque` prefix and header text |
| T2 | — | `research-sdd/toolbelt/verify-block.sh <block> <source-clone>` · run with the gentle-ai clone as the target so `file:line` cites resolve | — | `verify-block.sh` · resolved 18 of 21 cites in B31 and caught an out-of-range cite (`statecoord.go:25-45`, file has 42 lines) that a read of the sweep note would not | `no` · already in the kit; note for the loop: pass the SOURCE clone, not the corpus dir, as target-dir |
| T3 | — | `jq` over saved `gh` JSON · re-computed tracker and PR sample counts instead of copying them (title regex gave 82/100, the note said 77) | — | — | `no` · throwaway; superseded by the dated figures in B29 §29.6 |

## Metrics

- **Blocks reviewed**: 7 (B28-B34)  ·  **§14 cross-block corrections in this run**: 4 (all in B33 §33.3, sweep-side assumptions; no prior corpus block was corrected)  ·  **Rules skipped in practice**: 0
- **Deltas proposed (new)**: 15  ·  **Already-covered lessons**: 6

## Honest verdict

The run surfaced two genuinely new, verified kit findings: the comment-blind issue-reference gate (delta 1) and the `CLAUDE.md` §1 routing rule that gentle-ai's own tests ban as stale and that contradicts the injected evidence budget (delta 2). The remaining deltas are ranked adoptions of upstream techniques; their value is estimated, not measured, and delta 8 explicitly needs incidence measured first. B1-B27 were deliberately not rewritten: 19 are STALE and 7 DRIFTED per the B28 staleness map, which is a backlog item, not a finding about the kit.
