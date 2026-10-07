# Kit chain 2026-10-07b — ship #1660, then the open backlog by destination file

Status: **IN PROGRESS** (started 2026-10-07).

## Objective
Ship the held #1660 flip (verify-block ephemeral cites FAIL by default), then chain the remaining open backlog
(46 issues on 2026-10-07) grouped by destination file so writers own disjoint file sets, including the
improvements surfaced in earlier retros and reviews.

## Problem and why
The 2026-10-07 chain closed with #1952 held behind #1650–#1656 (target-corpus cleanups the kit never performs)
and 46 open issues. The maintainer lifted the hold and asked to continue the whole backlog in one automatic chain.

## Authorization
Maintainer, 2026-10-07: ODD + RDD (consent always `granted`) + commit + push + PR + pr view + issues + merge;
chain units automatically without asking, accept Gentle AI prompts and run the review, apply every possible
improvement. The #1660 hold condition is overridden (recorded on #1660).

## Constraints
- Kit tools and kit sessions never edit target corpora (propose-never-apply); #1650–#1656 and the operator
  follow-ups stay with the operator.
- Force-push is blocked in this repo: a rebased branch ships as a superseding PR.
- Issues filed against other repositories (#1924–#1929) are out of this repository's scope.

## Routes and models
Writers: sonnet, harness worktrees (`isolation: "worktree"`), disjoint file sets, branch based on origin/main.
PR gate per PR: writer verification (shellcheck with globstar, `pipefail-sigpipe-lint.test.sh` with NO args,
focused suites + `--prove-teeth`, `run-all.sh -j 4`), RDD on the PR range, Opus adversarial review
(at most 3 rounds), parent spot check. Strict TDD (CLAUDE.md §4) for behavior changes; doc-only units use
structural readback. Merge through `merge-gate.sh --merge` run from a worktree on origin/main.

## Acceptance criteria
- Every merged PR: green CI, RDD acknowledged on its range, Opus gate PASS, merge-gate allow.
- Every closed issue cites the merged PR; deferred items are stated with the reason.

## Tasks
- [ ] T0 This document.
- [ ] T1 #1660: #1952 rebased and superseded by **#1956**; RDD on the rebased range; merge. Route: inline
  (rebase only; content already reviewed and gated in #1952).
- [ ] T2 Backlog mapping by destination file (read-only explorer); units appended below.

## Decisions
- #1660: the maintainer overrode the "progress on #1650–#1656" hold on 2026-10-07; corpora with ephemeral cites
  use `--ephemeral=warn` / `RSDD_STRICT_EPHEMERAL=0` until cleaned.

## Operator follow-ups (target corpora; the kit never edits them)
- Move the gitignored `.env` secret stores outside mini-pc, Pancaddia, HotelHilton (archive refuses).
- niagara-research root: `covered_blocks` 1197 → 129; add a FOCUSES.md row for the reflow focus.
- COB-IM2 root: `covered_blocks` 39 → 37.
- three.js research: G71 `gaps_closed` 57 → 56 or move it to `## Blocked gaps`.
- #1650–#1656: clean or `ephemeral-ok`-mark the ephemeral cites (now FAIL by default after #1660).

## Progress
- 2026-10-07: document created; T1 in RDD review.

## Next step
T1 merge, then T2 mapping.
