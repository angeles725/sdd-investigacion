# Tasks: Improve Research-SDD Onboarding Sequence

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~55–70 (2 lines init.sh + ~55–65 lines test.sh) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | CONFIRM/THEN split + full test coverage | PR 1 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | Real run: `bash research-sdd/toolbelt/research-sdd-init.sh <tmpdir> --corpus flat` | Revert both frozen files; no state/corpus/contract affected |

---

## Phase 1: Tests — RED (write failing assertions first)

- [x] 1.1 In `research-sdd/toolbelt/tests/research-sdd-init.test.sh`, add a `reframe` assertion block: run `bash "$SUT" "$d" --corpus flat > "$TMP/reframe.out"` (new `$d=$TMP/reframe`, new tmpdir), then `assert_grep "reframe: CONFIRM group header present" "CONFIRM these are done" "$TMP/reframe.out"`.
- [x] 1.2 In the same block, add `assert_grep "reframe: THEN group header present" "THEN do next (post-scaffold)" "$TMP/reframe.out"`.
- [x] 1.3 In the same block, add regression guard: `assert_grep "reframe: item-1 consequence unchanged" "cannot see its retros/" "$TMP/reframe.out"` (pins existing line 156 — not currently asserted).
- [x] 1.4 Run `bash research-sdd/toolbelt/tests/run-all.sh` — confirm tasks 1.1 and 1.2 are RED, task 1.3 is GREEN (line 156 already present).

## Phase 2: Implementation — GREEN

- [x] 2.1 In `research-sdd/toolbelt/research-sdd-init.sh` line 154: replace the single flat echo `-- JUDGMENT follow-ups (NOT mechanizable — do these next) --` with `-- CONFIRM these are done — they belong at PROMPT-LOOP §b/§b2, BEFORE this scaffold (do them NOW if skipped) --`.
- [x] 2.2 In the same file, insert a new echo line between item 2 (line 157) and item 3 (line 158): `echo "-- THEN do next (post-scaffold) --"`.
- [x] 2.3 Verify line 156 (`— else sweep-retros.sh cannot see its retros/ (§18).`) is byte-for-byte unchanged — do NOT alter it.
- [x] 2.4 Run `bash research-sdd/toolbelt/tests/run-all.sh` — all assertions GREEN.

## Phase 3: Mutation Teeth

- [x] 3.1 In the `--prove-teeth` block of `research-sdd-init.test.sh`, add M5: `awk '/CONFIRM these are done/ { next } { print }' "$SUT" > "$m5_mutant"`; build-check (error if `CONFIRM these are done` still present); run mutant; assert `CONFIRM these are done` absent from stdout (`ok` if absent, `no` if present — THEATER).
- [x] 3.2 Add M6: `awk '/THEN do next \(post-scaffold\)/ { next } { print }' "$SUT" > "$m6_mutant"`; build-check; run mutant; assert `THEN do next (post-scaffold)` absent from stdout.
- [x] 3.3 Run `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` — M5 and M6 go RED on their mutants.

## Phase 4: Verification and Gates

- [x] 4.1 Run `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` — zero warnings against both changed files.
- [x] 4.2 Run `bash research-sdd/toolbelt/tests/run-all.sh` — all suites pass; zero failures.
- [x] 4.3 Run `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` — M5 and M6 red on mutants.
- [x] 4.4 In the worktree, run `git diff 0d54949 -- research-sdd/PROMPT-LOOP.md` — output MUST be empty.

---

## Implementation Order

Sequential. Phase 1 (RED) must precede Phase 2 (GREEN) per strict TDD. Phase 3 (teeth) follows GREEN. Phase 4 runs on a quiet tree after all edits are complete.

Parallelism: none — all tasks share the two frozen files.
