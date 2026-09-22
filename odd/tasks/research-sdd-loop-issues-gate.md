# ODD Feature — research-sdd loop done-gate for delta→issue seeding

## Objective
Make `/research-sdd` seed GitHub issues for proposed retro deltas reliably ("sí o sí"),
tied to the LOOP terminal (a "done-gate") rather than a Claude Code `Stop` hook. The loop
must not be able to declare itself DONE while a conforming retro has deltas that are not yet
tracked as open issues on `angeles725/sdd-investigacion`.

## Problem (audited 2026-09-21)
The prior "backlog-first enforcement" pipeline (EN1–EN4, PRs #863–#875) shipped an auto-seed
path via a `Stop` hook (`retro-gate.sh` → `stage-retro-issues.sh --apply`). It does not fire
because:
- The supervisor project `.claude/settings.json` has **no `Stop` hook** (only 7 SessionStart
  sweeps). `TARGETS.md` row #22 (sdd-investigacion) literally reads `hook no`.
- Target repos are mostly unwired (2 wired / 4 unwired / 11 absent-settings, per campaign doc).
- A `Stop` hook fires on EVERY session close, including pure kit-maintenance sessions — the
  wrong trigger for "cada vez que se use /research-sdd".
- Minor: `retro-gate.sh` `_run_issue_seeding` greps `'created issue'` but the real output is
  `created: <url> (row N)`, so its created-counter is always 0 (accounting only; issues still
  create).

## Decision (user, 2026-09-21)
Replace the Stop-hook trigger with a **loop done-gate**: enforcement lives in the loop's own
`--next` state machine, not in session-close hooks. Chosen over "kit-only Stop hook" and
"kit + all targets Stop hook".

## Design
`research-sdd-status.sh --next` gains a terminal state `ISSUES-DUE`. Precedence:
`STALE → RETRO-DUE → NEXT → (ISSUES-DUE gate) → STOP`.
- The gate runs only when the NEXT resolution yields no more investigable work (would-be STOP).
  It enumerates the target's retros, runs `reconcile-issues.sh <retro>` per pending retro, and
  counts `untracked:` rows. If any untracked delta exists and `gh` is available it emits
  `ISSUES-DUE | <N> untracked delta(s) across <M> retro(s) — seed: stage-retro-issues.sh <retro> --apply`
  and exits, preempting STOP.
- `gh` degraded (absent/unauth) → emit STOP with a stderr WARN (`could not verify issue coverage
  (gh degraded) — seed manually`). Never deadlock an offline loop (§7 degraded ≠ block).
- `NEXT` always preempts the gate: active research is never blocked mid-loop; the gate is a
  DONE gate, not a per-iteration block.
- `--next` stays READ-ONLY: it DETECTS and gates; it never runs `--apply` itself. The loop
  clears the gate by running `stage-retro-issues.sh <retro> --apply` (auto-create, now tied to
  loop completion instead of session close), then re-checks → tracked → STOP.

Known boundary (documented, not a bug): if a user abandons a session mid-loop (NEXT work still
pending), the done-gate does not fire — there is no false "done" to gate. The doctrine instructs
the loop agent to drive to a clean terminal before reporting the loop complete.

## Scope
- IN: `research-sdd-status.sh` ISSUES-DUE state + its test with mutation teeth; PROMPT-LOOP.md
  + METHODOLOGY.md §18 terminal/done contract update.
- OUT (this feature): removing `retro-gate.sh`/Stop-hook path (stays available for targets that
  wire it); wiring peer target repos; the retro-gate counter cosmetic bug (separate follow-up).

## Constraints / checks
- Strict TDD (project CLAUDE.md §4): RED first, GREEN, mutate-to-red teeth. Runner:
  `bash research-sdd/toolbelt/tests/run-all.sh` (+ `--prove-teeth`, `--require-teeth`).
- Shellcheck zero warnings: `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh`.
- Anti-silent-zero §7: three states (absent/empty/no-match) + degraded probe distinct.
- Work-unit budget ~400 authored lines/PR → split mechanism (PR1) from doctrine (PR2).
- Language: all artifacts English. Conventional commits, no AI attribution per repo policy.

## Tasks
- [x] T1 (PR1) ISSUES-DUE terminal state in `research-sdd-status.sh --next`. DONE — merged #876
      (origin/main 537176b). Hardened over 7 RDD review rounds: whole subprocess fail-open surface
      → distinct `[issue-coverage: unverified]` (cause on stderr); early-exit on first untracked;
      per-call + aggregate probing budgets; enumeration predicate parity with sweep-retros.sh.
- [x] T2 (PR1) Tests with mutation teeth. DONE — suite 152/0, --prove-teeth 214/0, full kit gate
      123/123 (3141 cases). Follow-up #877 (R4-budget-no-memo, non-blocking memoization refinement).
- [x] T3 (PR2) Doctrine. DONE — merged #878 (origin/main 0157d5e). PROMPT-LOOP.md `--next` vocabulary
      + precedence (STALE→RETRO-DUE→NEXT→ISSUES-DUE→STOP) + terminal DONE contract; METHODOLOGY §18
      loop done-gate paragraph. doc↔code parity verified (verbatim token quotes); RDD review APPROVED
      (reliability lens, 0 findings) + acknowledged.
- [x] T4 Verify the loop consumes ISSUES-DUE. DONE — both halves merged; doctrine tells the loop to
      seed on ISSUES-DUE and not finish until a clean STOP. Live `--next` sanity on real targets
      returns valid tokens honoring precedence (kit + blender-llm both STALE — pre-existing state
      inconsistency, short-circuits correctly before the gate). ISSUES-DUE/unverified/STOP paths
      covered by the suite incl. T-IDG-CONTRACT (real reconcile-issues.sh, parser↔producer bound).

## DONE (2026-09-22)
Both PRs merged to origin/main (0157d5e). PR1 #876 (mechanism, 537176b) survived 7 RDD hardening
rounds; PR2 #878 (doctrine) approved+acknowledged. Follow-up #877 (R4-budget-no-memo, non-blocking
memoization). Worktrees + feat/docs branches cleaned. The /research-sdd loop now enforces
backlog-first issue seeding at its terminal ("sí o sí") without a session-close Stop hook.

## Acceptance
- `run-all.sh --prove-teeth` green; new suite listed with teeth (not in "Suites without teeth").
- Shellcheck zero warnings over the toolbelt glob.
- `--next` on a fixture with an untracked delta and exhausted gaps returns ISSUES-DUE; with all
  tracked returns STOP; with gh degraded returns STOP + WARN.
- Doctrine reads consistently with the shipped code (doc↔code readback before merge).

## FABLE review findings (2026-09-21, PR #876 commit a37f110 — NOT CLEAN)
Independent adversarial cross-read (mutants + fleet probes executed) found 6 defects; all reopen
before merge:
- [ ] F3 (must-fix, §7 false-negative): gate enumerates `<target>/retros/*.md` at `-maxdepth 1`,
      but the kit's own enumerator (sweep-retros.sh) walks `-maxdepth 4 -path '*/retros/*.md'`.
      Measured invisible to the gate today: mini-pc (0 vs 2), three.js (0 vs 6), ford (0 vs 1);
      partial: sdd-investigacion 5/6, niagara-research 109/110, Pancaddia 15/17. Match the kit
      enumerator; add `-type f`.
- [ ] F4 (must-fix, §7): absent-input / empty-input / no-match are byte-identical in output; find
      `2>/dev/null` swallows a `retros/` perm error → silent STOP; reconcile stderr discarded.
      Distinguish the three states in observable output; do not let "couldn't look" read as STOP.
- [ ] F5 (must-fix): every non-zero reconcile exit is reported as "gh degraded" (reconcile exits 1
      for degraded AND operational failures); a stray/later error `break` discards already-counted
      untracked → hides deltas (false STOP). Distinguish degraded from operational; never discard a
      counted untracked on a later error.
- [ ] F1 (must-fix, teeth): T-IDG-D is theater — fixture retro is empty + runs REAL reconcile (+ real
      `gh auth status`, non-hermetic), so the gate never fires; precedence-inversion mutant M2 passes.
      Make it hermetic: untracked delta + active gap → NEXT, and a mutant that runs the gate before
      NEXT must go RED.
- [ ] F2 (should-fix, teeth): `--focus` STOP call-site (single-focus arm) has zero coverage; string
      compare against a hand-duplicated literal (`:313`/`:866`) — drift → silent STOP. Add a `--focus`
      test with teeth (mutant M1 passes today).
- [ ] F6 (PR2 doctrine): ISSUES-DUE is undefined in PROMPT-LOOP.md `--next` vocabulary; also add it to
      the script's own `--next` usage header (owned file, do now).
- [ ] PERF (should-fix): per-retro serial `gh issue list` at every would-be-STOP → niagara-research
      109 retros ≈ 100 s + 109 calls per `--next` STOP; any one failing flips the target to degraded.
      Pre-filter to retros whose review-status marker is still open/pending before calling reconcile.

## RDD native review findings (2026-09-21, candidate 38250d7, lineage review-4b1f998d — correction_required)
3 CRITICAL, all valid robustness/§7 issues (beyond FABLE's set); fix all + re-review until clean:
- [ ] R4-DEGRADED (deterministic, resilience): degraded coverage prints a STOP byte-identical to
      verified-clean on STDOUT; the distinguishing WARN is stderr-only and the `--next` documented
      contract (usage header ~L13-18) covers only stdout. Emit a DISTINCT, documented stdout marker
      when coverage is unverified (any retro degraded/timed-out and no untracked from verifiable ones);
      keep verified-clean STOP byte-identical to today. Update usage header + T-IDG-C.
- [ ] R4-SERIAL (inferential, resilience): each terminal --next forks reconcile once per retro,
      serially, NO timeout/cap → one hang blocks --next indefinitely. Wrap each call in `timeout`;
      on timeout → unverified marker (never clean STOP, never hang). Test with a hanging stub.
- [ ] R3-STUB-ONLY (inferential, reliability): no test binds the gate's `^untracked:` parser to
      reconcile-issues.sh's REAL output; format drift → silent 0 → false STOP. Add a parser↔producer
      contract test: run real reconcile with a stubbed `gh` against a fixture retro with a known open
      delta; assert the gate recognizes the real `untracked:` line. Add teeth.

## RDD review round 2 (candidate a5009cf, lineage review-5fb6233b — correction_required)
2 CRITICAL, same root (deterministic): the operational-failure branch of issues_due_gate (any
non-zero reconcile exit that is NOT 124 and NOT `degraded:` — crash, signal 137, timeout misuse 125,
unchecked mktemp fail w/ empty stderr) only WARNs on stderr and falls through to the bare
verified-clean STOP on stdout → false clean for machine callers. Fix: ANY non-zero reconcile exit ⇒
unverified marker (collapse the class); harden mktemp. Writer launched.

## Progress log
- 2026-09-21: audit complete (mapper); design decided (done-gate); feature doc created.
- 2026-09-21: PR1 (#876) implemented; FABLE cross-read → 6 defects fixed (38250d7). RDD native review
  of 38250d7 → 3 CRITICAL robustness findings (R3/R4×2) above. User: fix all + re-review until clean,
  then merge. Corrective writer launched.
- 2026-09-21: PR1 (#876, a37f110) implemented + full gate green (my suite 133/0; 1 unrelated
  corroborate-java timeout flake, passes standalone 17/0). FABLE cross-read → NOT CLEAN, 6 defects
  (F1–F6 + PERF) reopened above. RDD review consent GRANTED by user, but candidate reworked first so
  the reviewed candidate is the corrected one.
