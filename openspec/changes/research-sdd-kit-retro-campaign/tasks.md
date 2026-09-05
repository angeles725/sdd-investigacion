# Tasks: research-sdd Kit Retro Campaign (Wave 1)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~3,400 (18 units × ~190 avg authored lines, two disjoint owners) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | 18 stacked PRs, one per unit, auto-chain to main |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

> **U6 re-baseline**: U6 must land early. Every gate report produced before U6 is not comparable to one produced after; cite the U6 baseline commit in every subsequent gate report.

### Suggested Work Units

| Unit | Goal | Issue | Branch | Focused test command | Runtime harness | Rollback boundary |
|------|------|-------|--------|----------------------|-----------------|-------------------|
| D4 | §16 FOCUSES status grammar + shared-global rules | #425 | `docs/wave1-d4-shared-global` | structural readback + `verify-doc-consistency.sh` | N/A — doc only | `git revert` merge commit |
| D6 | §18 countable-delta + §4 Type + §8 coverage + templates | #429 | `docs/wave1-d6-countable-delta` | structural readback + template diff | N/A — doc only | `git revert` merge commit |
| D1 | §20 freeze-first + §7 Engram fallback | #432 | `docs/wave1-d1-d5-methodology` | structural readback | N/A — doc only | `git revert` merge commit |
| D5 | §3 marker-taxonomy decision | #433 | `docs/wave1-d1-d5-methodology` | structural readback | N/A — doc only | `git revert` merge commit (same PR as D1) |
| D2 | DYNAMIC-SETUP §1c raw-image + DEPLOY-WINDOWS-MINIPC.md + 15 tool-registry rows | #428 | `docs/wave1-d2-dynamic-setup` | structural readback + `verify-doc-consistency.sh` | N/A — doc only | `git revert` merge commit |
| D3 | PROMPT-LOOP SYNTHESIS-GUIDE + SECRETS cluster | #431 | `docs/wave1-d3-promptloop` | structural readback + `verify-doc-consistency.sh` | N/A — doc only | `git revert` merge commit |
| U1 | Saturation parser: header-shape + cell-form recognition | #420 | `feat/u1-saturation-parser` | `bash tests/research-sdd-status.test.sh --prove-teeth` | 50 fleet tables → BLIND 35→0 | `git revert` merge commit |
| U6 | `run-all.sh` teeth accounting + `--require-teeth` flag | #426 | `feat/u6-teeth-accounting` | `bash tests/run-all.sh --prove-teeth` | quiet-tree `run-all.sh --prove-teeth` → 22 named | `git revert` merge commit |
| U12 | 8 unguarded `\|\| true` → typed three-state handling | #441 | `feat/u12-remove-or-true` | per-site test stubs + `run-all.sh --prove-teeth` | grep-stubbed exit 2 at each site | `git revert` merge commit |
| U9 | Hygiene bundle: gitignore, counters, exec bit, hook path | #439 | `feat/u9-hygiene-bundle` | `bash tests/verify-kit-clean.test.sh --prove-teeth` | dirty/clean tree + hook path check | `git revert` merge commit |
| U10 | Installed-skill drift detection (suite only, no hook) | #440 | `feat/u10-installed-skill-drift` | `bash tests/skill-twin-parity.test.sh --prove-teeth` | real `$HOME`, stale fixture, empty fixture | `git revert` merge commit |
| U3 | `coverage-map.sh` new instrument | #421 | `feat/u3-coverage-map` | `bash tests/coverage-map.test.sh --prove-teeth` | niagara + panccadia (148 uncited) | `git revert` removes file + registry row |
| U11 | `lib/block-files.sh` centralised discriminator (16 sites) | #435 | `feat/u11-block-files-lib` | `bash tests/discriminator-parity.test.sh --prove-teeth` | byte-identical diff on real corpora all 16 sites | `git revert` merge commit |
| U2 | `verify-state.sh` shared-global `covered_blocks` fix | #423 | `feat/u2-shared-global-covered-blocks` | `bash tests/verify-state.test.sh --prove-teeth` | 6/6 niagara focuses → PASS | `git revert` merge commit |
| U4 | `research-sdd-status.sh` bold `**pending**` + WARN on unknown tokens | #424 | `feat/u4-status-cell-bold` | `bash tests/research-sdd-status.test.sh --prove-teeth` | 70 state files → bold rows resolve | `git revert` merge commit |
| U7 | `sweep-retros.sh` typed delta state + aliases + missing markers | #436 | `feat/u7-sweep-retros-delta-state` | `bash tests/sweep-retros.test.sh --prove-teeth` | 99 fleet retros partition | `git revert` merge commit |
| U5 | `verify-block.sh` Type parser; synthesis/capture WARN→INFO | #422 | `feat/u5-block-type-parser` | `bash tests/verify-block.test.sh --prove-teeth` | 763 niagara blocks; 8 change class | `git revert` merge commit |
| U8a | `sweep-retros.sh` summary mode + hook clean sentinel | #437 | `feat/u8a-sweep-retros-summary` | `bash tests/sweep-retros.test.sh --prove-teeth` | <3k chars; `--full` diff empty | `git revert` merge commit |
| U8b | `sweep-retros.sh` RSDD_PROFILE=1 wall-time profile (report only) | #438 | `feat/u8b-sweep-retros-profile` | `bash tests/sweep-retros.test.sh --prove-teeth` | niagara profile table + go/no-go | `git revert` merge commit |

---

## Phase 1: Doctrine Foundation (explorador — done / in flight)

> File set owned by explorador: `research-sdd/METHODOLOGY.md`, `research-sdd/PROMPT-LOOP.md`, `research-sdd/DYNAMIC-SETUP.md`, `research-sdd/toolbelt/tool-registry.md`, `research-sdd/toolbelt/DEPLOY-WINDOWS-MINIPC.md` (new), `research-sdd/templates/retro.template.md`, `research-sdd/templates/block.template.md`, `research-sdd/templates/RESEARCH-STATE.template.md`. No mejorador script touches these files.

---

### D4 — §16 shared-global doctrine (issue #425, explorador) [x]

> **Evidence**: PR #427 open · PASS pending aggregate · branch `docs/wave1-d4-shared-global`
> Files: `research-sdd/METHODOLOGY.md` (§16)
> **Satisfies**: `kit-hygiene-portability` spec req D4; `kit-subject-coverage` spec req D4; unblocks U2

- [x] GATE: structural readback confirms four-word FOCUSES status vocab (`active`, `paused`, `stopped`, `planned`); global block-number allocation rule for concurrent shared-global lanes; peer-owned dirty tree = hard read-only boundary; shared-checkout guard (families F1+F3)
- [x] GATE: probador quiet-tree `verify-doc-consistency.sh` exits 0

---

### D6 — §18 + §4 + §8 + templates (issue #429, explorador) [x]

> **Evidence**: PR #430 stacked · branch `docs/wave1-d6-countable-delta`
> Files: `research-sdd/METHODOLOGY.md` (§18, §4, §8); `research-sdd/templates/retro.template.md`; `research-sdd/templates/block.template.md`; `research-sdd/templates/RESEARCH-STATE.template.md`
> **Satisfies**: `kit-doctrine-grammar` spec req machine-countable delta + Type grammar; `kit-subject-coverage` spec req D6; unblocks U5, U7, U3

- [x] GATE: structural readback confirms §18 machine-countable delta declaration mandatory + retro trigger extended to applied sessions and post-close addenda; §4 closed Type domain; §8 "coverage over the subject" paragraph names it as valid AUDIT-FIRST gap seed; `retro.template.md` contains `## Proposed kit deltas` heading; `block.template.md` lists Type domain; `RESEARCH-STATE.template.md` has New-gaps cell grammar sentence
- [x] GATE: probador quiet-tree `verify-doc-consistency.sh` exits 0

---

### D1 + D5 — §20 freeze-first + §7 Engram fallback + §3 marker taxonomy (issues #432 + #433, explorador) [x]

> **Evidence**: PR #434 stacked · branch `docs/wave1-d1-d5-methodology`
> Files: `research-sdd/METHODOLOGY.md` (§20, §7, §3)
> **Satisfies**: `kit-instrument-honesty` spec req D1; `kit-doctrine-grammar` spec req D5

- [x] GATE: structural readback confirms §20 freeze-first sentence (md5/hash before document-mode work); §7 states Engram fallback for unregistered target projects; §3 five marker-taxonomy rules present: `[CERT-a]` = secondary source; unverified agent-gathered citation carries no marker until source-verified then becomes `[CERT]`; coordination notes are not evidence; `[CERT-live]` = running remote service; `[CERT-hw]` = physical device or offline media

---

### D2 — DYNAMIC-SETUP + DEPLOY-WINDOWS-MINIPC.md (issue #428, explorador) [x]

> **Evidence**: delegated writer in flight · branch `docs/wave1-d2-dynamic-setup`
> Files: `research-sdd/DYNAMIC-SETUP.md` (§1c); `research-sdd/toolbelt/DEPLOY-WINDOWS-MINIPC.md` (new); `research-sdd/toolbelt/tool-registry.md` (15 operator-tool rows + DEPLOY-WINDOWS-MINIPC.md row)
> **Satisfies**: `kit-session-cost` spec req D2

- [x] GATE: structural readback confirms §1 raw-image subsection present (covers `wsl --mount` failure path); headless-Chromium additions present; `DEPLOY-WINDOWS-MINIPC.md` exists; `tool-registry.md` has its row + 15 operator-tool rows
- [x] GATE: probador quiet-tree `verify-doc-consistency.sh` exits 0

---

### D3 — PROMPT-LOOP SYNTHESIS-GUIDE + SECRETS (issue #431, explorador) [x]

> **Evidence**: delegated writer in flight · branch `docs/wave1-d3-promptloop`
> Files: `research-sdd/PROMPT-LOOP.md`
> **Satisfies**: `kit-doctrine-grammar` spec req D3

- [x] GATE: structural readback confirms SYNTHESIS-GUIDE FOCUS pattern named + PAIR form described; SECRETS cluster present with: raw disk image = secret-bearing statement; inline-over-delegate rule for secrets-sensitive artifacts; redacted-file mask verification required; structure-only binary inspection rule
- [x] GATE: probador quiet-tree `verify-doc-consistency.sh` exits 0

---

## Phase 2: Early Instruments — No File-Lock Conflicts (mejorador, concurrent)

> File set owned by mejorador: all `research-sdd/toolbelt/*.sh`, `research-sdd/toolbelt/lib/`, `research-sdd/toolbelt/tests/`, `research-sdd/templates/`. No explorador doc touches these files. Units in this phase have disjoint file sets and may run concurrently. Gate only after all writers finish.

---

### U1 — Saturation parser: header-shape + cell-form recognition (issue #420, mejorador) [x]

> **Evidence**: PR #442 open · fleet 35 BLIND → 0 · one review fix requested: empty cell must report `bad (empty)` not silently skip
> Branch: `feat/u1-saturation-parser`
> Files: `research-sdd/toolbelt/research-sdd-status.sh` (:112-143); `research-sdd/toolbelt/tests/research-sdd-status.test.sh`
> **Satisfies**: `kit-instrument-honesty` spec req saturation parser; unblocks U11 (same file)

- [x] RED: fixtures for each of 8 header shapes; fixtures for `N new` / `none net-new …` / `G12` cells; assert BLIND=0 on classified fixtures; assert unrecognised residue → stderr WARN naming the form
- [x] IMPL: header-NAME column selection (design D-1) — locate `## Iteration history` header row, normalise cells (lowercase, strip `**`, collapse spaces), match against closed New-gaps header set, record column index `k` and `#` index `i`; cell grammar leading-token rules: `^[0-9]+$`; `^([0-9]+)[[:space:]]+new\b`; `^(none|no|0)\b` → 0; `G<N>` list → count distinct `G` tokens; `^(-|—|n/a)$` → n/a; anything else → `unrecognised` → named in WARN
- [x] MUTANT: (a) delete one header alias → fixture using that shape must report `no New-gaps column (header: …)`; (b) delete `N new` cell rule → residue count must rise from 0
- [x] FLEET: `research-sdd-status.sh` over all 70 state files; header census via `awk '/^## Iteration history/{f=1;next}/^## /{f=0} f&&/^\|/' "$f" | head -1 | sort | uniq -c` → BLIND 35→0 or every residue NAMED; 0 new false WARN; partition: ~36 readable (active/SATURATED), 8 no-column, 6 unreadable-window, 19 no-header byte-identical; any file outside its bucket needs a named reason in the PR body
- [x] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` + shellcheck + fleet diff

---

### U6 — `run-all.sh` teeth accounting (issue #426, mejorador) [blocked-by: none; land FIRST in Phase 2]

> Branch: `feat/u6-teeth-accounting`
> Files: `research-sdd/toolbelt/tests/run-all.sh` (:96-112, :172-197)
> **Satisfies**: `kit-instrument-honesty` spec req teeth accounting

- [ ] RED: assert `--prove-teeth` emits line matching `Suites without teeth: 22 — [...]` (sorted names); assert `--require-teeth` exits non-zero; assert default run aggregate block is byte-identical before/after; assert `Suites n/a for teeth (node): 1` for the `.mjs` suite
- [ ] IMPL: count teeth-banner lines (`^\s*(--|==)\s*teeth\b`, case-insensitive, enumerator: 249 banners across 56 suites of which one uses `==` at `test-lane.test.sh:181`) from captured `$tmp_out` per suite; cross-check against static `grep -l '"--prove-teeth"'` set (78 files) → suites with banner vs those with flag but no banner are distinct states; `.mjs` suites forward nothing and classify as `n/a (node suite — teeth always run)`; add `--require-teeth` flag that exits 1 when without-teeth list non-empty; new lines print ONLY under `--prove-teeth` (default aggregate unchanged)
- [ ] MUTANT: (a) add stub suite that greps `--prove-teeth` and prints no banner → must land in banner-less bucket not with-teeth bucket; (b) remove `==` alternative from banner enumerator → banner count drops by exactly one suite
- [ ] FLEET: `bash run-all.sh --prove-teeth` on quiet tree → 22 named without teeth; `Suites n/a for teeth (node): 1`; default run byte-identical; `--require-teeth` exits 1
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` + shellcheck; record U6 baseline commit — all subsequent gate reports MUST cite it

---

### U12 — 8 unguarded `|| true` (issue #441, mejorador) [blocked-by: none; must precede U5 (#422) and U8a (#437)]

> Branch: `feat/u12-remove-or-true`
> Files: `research-sdd/toolbelt/verify-sources.sh` (:79); `research-sdd/toolbelt/scan-secrets.sh` (:127); `research-sdd/toolbelt/sweep-tools.sh` (:133,:148); `research-sdd/toolbelt/sweep-tools-hook.sh` (:45); `research-sdd/toolbelt/verify-tool-catalog-hook.sh` (:47); `research-sdd/toolbelt/verify-block.sh` (:257,:260); companion test suites for each file
> **Satisfies**: `kit-instrument-honesty` spec req three-state honesty + `|| true` elimination

- [ ] RED: per site — stub `grep` to exit 2; assert the site's typed `error` string appears AND the run does NOT report a confident 0; write as one new test case per site in the companion test suite
- [ ] IMPL: at each site capture rc, then classify — rc 1 = legitimate `no-match`/`empty-input` (name which); rc ≥2 = `error` + WARN. Exact typed strings per design: `verify-sources.sh` → `registered data rows: 0 (no-match — N table line(s), all header/separator)` / `(empty-input — no table lines)` / `WARN: SOURCES.md row scan FAILED (grep exit R) — row count unavailable`; `scan-secrets.sh` → `WARN: NUL-byte count FAILED (grep exit R) — count unavailable` (never 0); `sweep-tools.sh` → `WARN: N retro(s) unreadable during T-row scan (grep exit R)` + `ledger_status="error"`; both hooks → append `(WARN-line extraction failed: grep exit R)` to emitted detail; `verify-block.sh` → `(scan INCOMPLETE — grep exit R; OCR-lossy check unreliable)` replacing `(none — …)` at :268
- [ ] MUTANT: per site — restore `|| true` → assertion that the typed `error` string appears must go red (8 teeth, one per site)
- [ ] FLEET: per site with grep-stubbed exit 2 → 8/8 surface `error`; 0/8 report a confident 0; 0 new false WARN on real corpus (grep exits 0 or 1 normally)
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff at each site

---

### U9 — Hygiene bundle (issue #439, mejorador) [blocked-by: none, concurrent]

> Branch: `feat/u9-hygiene-bundle`
> Files: `research-sdd/toolbelt/verify-kit-clean.sh` (:29-34); `.gitignore`; `research-sdd/toolbelt/verify-doc-consistency.sh` (mode 100644→100755); `research-sdd/templates/hook-sessionstart.sh` (:28); companion test suite for `verify-kit-clean.sh`
> **Satisfies**: `kit-hygiene-portability` spec req hygiene bundle

- [ ] RED: assert `verify-kit-clean.sh` emits `WARN: DIRTY but all three counters read 0 — porcelain has N line(s); counters disagree` on contradiction input (non-empty porcelain, all counters 0); assert `WARN: <counter> count FAILED (grep exit R) — cleanliness report incomplete` when grep stubbed to exit 2 on one counter
- [ ] IMPL: capture each counter's rc instead of `|| true`; cross-check against `git status --porcelain`; DIRTY with all counters 0 + non-empty porcelain → WARN + rc 1; add `.claude/worktrees/` to `.gitignore`; `chmod 100755` on `verify-doc-consistency.sh` (fix class of #417); replace hardcoded kit path in `templates/hook-sessionstart.sh` with `${RESEARCH_SDD_KIT:-<KIT>}/toolbelt/` placeholder + resolution sentence (artifact is copied to other machines)
- [ ] MUTANT: reintroduce `|| true` on one counter + stub `grep` to exit 2 → contradiction WARN must disappear (test asserts the WARN IS present without `|| true`, goes red when reintroduced)
- [ ] FLEET: `verify-kit-clean.sh` on dirty tree and clean tree → hook stops reporting permanent NOT-clean; `hook-sessionstart.sh` contains no absolute path outside a placeholder; `git ls-files --stage verify-doc-consistency.sh` → mode 100755; `git status` with `.claude/worktrees/` present → not listed as untracked
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff

---

### U10 — Installed-skill drift detection (issue #440, mejorador) [blocked-by: none, concurrent; NOT a SessionStart hook]

> Branch: `feat/u10-installed-skill-drift`
> Files: `research-sdd/toolbelt/tests/skill-twin-parity.test.sh`
> **Satisfies**: `kit-hygiene-portability` spec req installed-skill drift

- [ ] RED: assert suite reports `installed copy: DRIFT — N hunk(s) / M line(s) behind the kit copy` when `RSDD_INSTALL_HOME` points to stale fixture; assert `installed copy: absent-input (<resolved path> not found) — drift check skipped` when home is empty; assert NOT `in sync` for either non-sync case
- [ ] IMPL: extend `skill-twin-parity.test.sh` with third twin = installed copy at `rsdd_field claude skill_path "${RSDD_INSTALL_HOME:-$HOME}"` (uses `install/adapters.sh:116-123` home parameter — no hardcoded `~/.claude/…`); report drift BY HUNK (`diff -u … | grep -c '^@@'`) + line count; absent → typed `absent-input` string; do NOT add to `.claude/settings.json` SessionStart hooks
- [ ] MUTANT: (a) point `RSDD_INSTALL_HOME` at stale fixture → suite must report exact hunk count (5 today); (b) point at empty home → absent-input line must print and suite must NOT report `in sync`
- [ ] FLEET: real `$HOME` → 15 stale lines / 5 hunks detected; stale fixture home → DRIFT with exact count; empty fixture home → absent-input; confirm `.claude/settings.json` does NOT list this as a SessionStart hook
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck

---

### U3 — `coverage-map.sh` new instrument (issue #421, mejorador) [blocked-by: D6 done ✓; no file-lock with U11] [x]

> Branch: `feat/u3-coverage-map`
> Files: `research-sdd/toolbelt/coverage-map.sh` (new); `research-sdd/toolbelt/tests/coverage-map.test.sh` (new); `research-sdd/toolbelt/tool-registry.md` (one row)
> **Satisfies**: `kit-subject-coverage` spec req coverage-map.sh

- [x] RED: assert absent corpus path → `subject: absent-input (<path> not traversable)` + exit non-zero; assert 0-class-basename corpus → `subject: empty-input (0 class basenames)`; assert `ambiguous basenames excluded: N` and `modules: <cited>/<total> cited · <uncited> never cited` always print (anti-silent-zero)
- [x] IMPL: build `basename → module` index over subject tree; DROP every basename mapping to >1 module (5,530 on niagara) and every basename shorter than 4 chars; scan block files (via `block_file_filter` once U11 merges, or inline regex until then) for each surviving basename with word-boundary matching (`\b` / `[^A-Za-z0-9_]` guards, so `Foo` never matches `FooBar`); rank uncited modules by size (dependency centrality not computable — 2 `module.xml` fleet-wide); add `tool-registry.md` row
- [x] MUTANT: (a) remove ambiguity exclusion → 148-uncited figure must change; (b) replace `\b` with substring match → cited count must rise
- [x] FLEET: `coverage-map.sh` on niagara + panccadia → reproduces 148 uncited / 170 cited / 5,530 ambiguous; every module listed as uncited verifiably not cited in any block file; tool-registry.md row present
- [x] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff (0 new false WARN expected)

---

  - Done: PR #451 merged as 0c90262 (2026-09-05).
## Phase 3: Shared-Lib Extraction — Critical Path (mejorador)

> U11 is the critical-path unit. It unlocks U2, U4, U7, U8a (through same-file locks). It must NOT start until U1 (#442) has merged.

---

### U11 — `lib/block-files.sh` centralised discriminator (issue #435, mejorador) [blocked-by: U1 #442 merge; unlocks U2 #423, U4 #424, U7 #436, U8a #437]

> Branch: `feat/u11-block-files-lib`
> Files: `research-sdd/toolbelt/lib/block-files.sh` (new); `research-sdd/toolbelt/research-sdd-status.sh` (:391,394,397,557,560); `research-sdd/toolbelt/research-sdd-archive.sh` (:200,238,260,284); `research-sdd/toolbelt/verify-state.sh` (:322,328); `research-sdd/toolbelt/verify-registry.sh` (:209 strict + :373-374 inverse `-v`); `research-sdd/toolbelt/verify-parity.sh` (:68); `research-sdd/toolbelt/verify-corrections.sh` (:27); `research-sdd/toolbelt/sweep-retros.sh` (:291); `research-sdd/toolbelt/sweep-breakthroughs.sh` (:116); companion test suite
> **Satisfies**: `kit-hygiene-portability` spec req centralised discriminator

- [ ] RED (byte-identical): snapshot stdout+stderr of all 16 sites on `main` against real corpora (niagara + panccadia) BEFORE writing any code; assert post-migration `diff` is empty at each site — this is the acceptance gate, not a fixture
- [ ] RED (function guard): assert `declare -F block_file_filter` succeeds after sourcing; assert exit 1 + `<script>: helper lib/block-files.sh failed to define block_file_filter` when lib is missing or broken
- [ ] IMPL: create `lib/block-files.sh` — idempotent sourced-never-executed; `block_file_filter [-v] [<focus_prefix>]`: stdin filter, stdout = matching paths, exit = grep's verbatim status (NEVER laundered), `-v` = inverse; regex: `(^|/)[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$`; with prefix P: `(^|/)P(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$`; `${_fpfx}` interpolated unescaped (byte-identical mandate; escaping deferred as follow-up); route `research-sdd-archive.sh:284` → `retro_review_status` / `retro_has_bare_marker` (lib/retro-status.sh), replacing `head -10 | grep '^review-status:'`; migrate all 16 call sites with `declare -F` fail-closed guard at each
- [ ] MUTANT: (a) change anchor to `^` only → `discriminator-parity.test.sh` FAMILY 1 / FAMILY 2 classification must go red; (b) make `[^/]+-` optional → `blocked-notes.md` decoy must be counted (false positive)
- [ ] FLEET (anchor proof obligation): for each of 16 sites, `diff <(main-build-output) <(new-build-output)` on real corpora → diff EMPTY; anything non-empty blocks the merge (byte-identical is not an assumption, it is a proof obligation)
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff all 16 sites; `discriminator-parity.test.sh` FAMILY 1/FAMILY 2 pass; `research-sdd-archive.sh` contains no `head -10 | grep '^review-status:'` pattern

---

## Phase 4: File-Lock-Blocked Instruments — Unlocked by U11 (mejorador, concurrent within phase)

> U2, U4, U7 may run concurrently after U11 merges (disjoint regions within their shared files). U5 may run concurrently with U2/U4/U7 as soon as U12 merges — it does not depend on U11.

---

### U2 — `verify-state.sh` shared-global `covered_blocks` fix (issue #423, mejorador) [blocked-by: D4 done ✓, U11 #435]

> Branch: `feat/u2-shared-global-covered-blocks`
> Files: `research-sdd/toolbelt/verify-state.sh` (:309-331); companion test suite
> **Satisfies**: `kit-subject-coverage` spec req verify-state.sh shared-global semantics

- [ ] RED: fixture `block_scope: shared-global` with 19 attributed blocks in 758-block corpus → assert `covered_blocks: 19 attributed (shared-global)` + INFO `corpus total 758 (shared-global, informational)`; no FAIL emitted
- [ ] RED: fixture with no attributed block IDs listed → assert INFO `covered_blocks unverifiable under shared-global (no attributed block ids listed)` + MUST NOT FAIL
- [ ] IMPL: under `block_scope: shared-global`, attribution set = union of block numbers from `## Coverage` `B1..BN`/`B<k>` tokens AND `Block` column of `## Iteration history`, intersected with on-disk canonical block files by `blocknum()` grammar (`verify-corrections.sh:31`); corpus total → separate INFO line; `--sync-state` writes attributed count NOT corpus total; focus whose envelope disagrees with its own listed IDs remains a FAIL (true finding)
- [ ] MUTANT: make attribution fall back to `_ondisk_global` → 6 sampled niagara focuses must FAIL again
- [ ] FLEET: `verify-state.sh` over 6 sampled niagara focuses + 2 non-shared targets → 6/6 FAIL→PASS; non-shared targets byte-identical
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff; assert per-focus output on non-shared-global targets unchanged

---

### U4 — `research-sdd-status.sh` bold `**pending**` + WARN on unknown tokens (issue #424, mejorador) [blocked-by: U11 #435; wait for #442 merge before branching from updated main]

> Branch: `feat/u4-status-cell-bold`
> Files: `research-sdd/toolbelt/research-sdd-status.sh` (:184-235); companion test suite
> **Satisfies**: `kit-instrument-honesty` spec req status cell parsing

- [ ] RED: fixture `****pending****` (greedy bold, 4 asterisks) → assert rejected before fix; fixture `**pending**` → resolves as `pending` after fix; fixture with unknown token → `INVALID_STATUS\t<token>` on stdout + WARN on stderr
- [ ] IMPL: strip AT MOST ONE leading `**` and AT MOST ONE trailing `**` from Status cell before `tolower` (§8b); closed token vocabulary: `pending`, `requires-execution`, `blocked-on-*`, `✅`, `~~`; unknown → stderr `WARN: non-conforming status token [<tok>] — strip decoration per METHODOLOGY §8b; row excluded from investigable_open until migrated` + stdout `INVALID_STATUS\t<token>` (mirrors `INVALID_PRIORITY` idiom exactly)
- [ ] MUTANT: (a) strip `**` greedily (all leading asterisks) → `****pending****` fixture must stop being rejected (wrong); (b) remove the strip entirely → bold fixture's `--next` must revert to the medium-priority row
- [ ] FLEET: `--next` over all 70 state files → bold-`**pending**` rows now resolve; new `INVALID_STATUS` lines all hand-classified true/false; byte-identical output for non-affected rows
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff; `--next` golden unchanged for non-bold fixtures

---

### U7 — `sweep-retros.sh` typed delta state + aliases + missing markers (issue #436, mejorador) [blocked-by: D6 done ✓, U11 #435]

> Branch: `feat/u7-sweep-retros-delta-state`
> Files: `research-sdd/toolbelt/sweep-retros.sh` (:124-196); companion test suite
> **Satisfies**: `kit-instrument-honesty` spec req sweep-retros typed delta-missing state; `kit-doctrine-grammar` spec req enumerated heading set

- [ ] RED: fixture PENDING retro with no canonical delta-section heading → assert `no delta section found (empty-input)` not `~0`; fixture with deprecated alias heading → assert `WARN: deprecated delta heading [<h>] — migrate to '## Proposed kit deltas' per §18`; fixture retro with no `review-status:` line → assert `WARN: no review-status marker — add '<!-- review-status: pending -->'`
- [ ] IMPL: add distinct no-delta-section state (`~0 proposed deltas` → `no delta section found (empty-input)` for PENDING retro with zero indicators); add 4 measured DEPRECATED heading aliases: `## Summary of proposed deltas`, `## Summary of new deltas proposed`, `## Delta details`, `## <N>. PROPOSED kit deltas for the next version …` — each emits WARN to migrate; surface retros with no review-status marker via `retro_review_status` returning empty; existing WARN-A/WARN-B `?` strings unchanged; NO prose regex extension (closed enumerated set only, per D-2 design decision)
- [ ] MUTANT: (a) remove no-delta-section branch → 4 known retros must revert to confident `~0`; (b) remove one alias → its retro drops back to `?`
- [ ] FLEET: `sweep-retros.sh` over 99 fleet retros → 4 confident-zero false negatives → typed state; 9 aliased headings counted; 5 unmarked retros surfaced; 78-pending total unchanged; `Summary:` line byte-identical in both modes
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff; assert existing WARN-A/WARN-B strings unchanged

---

### U5 — `verify-block.sh` Type parser (issue #422, mejorador) [blocked-by: D6 done ✓, U12 #441]

> Branch: `feat/u5-block-type-parser`
> Files: `research-sdd/toolbelt/verify-block.sh` (:80, :140-156); companion test suite
> **Satisfies**: `kit-doctrine-grammar` spec req block Type grammar; `kit-instrument-honesty` spec req

- [ ] RED: fixture `Type: unknown-value` → assert `WARN: unrecognised block Type [unknown-value] — closed domain is <…> per §4`; fixture `Type: synthesis` with zero citations → assert ZERO-citation diagnostic emitted at INFO not WARN; fixture with no Type header → assert `(no Type declared — P6 WARN applies; declare it per METHODOLOGY §4)`
- [ ] IMPL: parse `Type:` leading token against D6's closed domain (adopt observed fleet values: `evidence`, `synthesis`, `document`, `capture`, `absence-centred` as the closed set — D6 owns the definition); out-of-domain token → WARN naming the token + listing the domain; when declared type is `synthesis` / `capture` / `absence-centred`, P6 ZERO-citation WARN at :151 → INFO; existing P6 WARN / doc-grade INFO strings otherwise unchanged
- [ ] MUTANT: mutant that ignores the Type token entirely → WARN must re-raise on a declared-synthesis fixture (P6 WARN appears)
- [ ] FLEET: `verify-block.sh` over 763 niagara blocks → 8 declared-Type blocks change class; other 755 byte-identical; every new WARN hand-classified true/false
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff

---

## Phase 5: Output Budget (mejorador)

---

### U8a — `sweep-retros.sh` summary mode + hook clean sentinel (issue #437, mejorador) [blocked-by: U11 #435, U7 #436, U12 #441]

> Branch: `feat/u8a-sweep-retros-summary`
> Files: `research-sdd/toolbelt/sweep-retros.sh` (:224-239); `research-sdd/toolbelt/verify-tool-catalog-hook.sh` (:44); companion test suite
> **Satisfies**: `kit-session-cost` spec req summary mode + clean sentinel

- [ ] RED: assert default `sweep-retros.sh` output < 3,000 chars on real kit; assert absent-input targets collapsed to ONE `INFO:` counted line (not one per target); assert `sweep-retros.sh --full` diff is empty vs today's default byte-for-byte; assert `verify-tool-catalog-hook.sh` emits non-empty sentinel on clean run; assert `Summary:` line byte-identical in both modes
- [ ] IMPL: summary mode = oldest 5 PENDING rows + `… and N more — run sweep-retros.sh --full`; absent targets → `INFO: N target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.` (ONE line); `--full` reproduces today's default exactly (byte-identical); `verify-tool-catalog-hook.sh` emits `Research-SDD tool catalog: clean (N logged tools, 0 uncataloged).` sentinel instead of 0 bytes
- [ ] MUTANT: force summary mode with 0 pending → sentinel/collapse lines must still print (silent clean run is the defect); mutant that removes hook sentinel → test must go red
- [ ] FLEET: `sweep-retros.sh` char count < 3,000; `--full` diff vs today's default empty; hook char count with sentinel; absent-input targets counted in one line; `Summary:` line diff: both modes identical
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck + fleet diff; hook sentinel present in output

---

### U8b — `sweep-retros.sh` RSDD_PROFILE=1 wall-time profile (issue #438, mejorador) [blocked-by: U8a #437]

> Branch: `feat/u8b-sweep-retros-profile`
> Files: `research-sdd/toolbelt/sweep-retros.sh` (measurement instrumentation only); companion test suite
> **Satisfies**: `kit-session-cost` spec req (profile deliverable, not optimisation)

- [ ] RED: assert `RSDD_PROFILE=1` emits per-phase `profile: <phase> <seconds>` lines to stderr; assert `profile: unavailable (no EPOCHREALTIME)` when bash < 5; assert phase sum reconciles with `total` (within floating-point rounding)
- [ ] IMPL: `RSDD_PROFILE=1` accumulates wall time via `$EPOCHREALTIME` per phase to stderr: `pending-pass`, `waiver-pass`, `retro-newest-pass`, `block-newest-pass` (:288-291, one `git log` per block file), `total`; fallback message when unavailable; NO change to any `git` invocation (design D-6 mandate); deliverable = profile TABLE + go/no-go recommendation, not an optimisation (CLAUDE.md §6 — probe viability before writer)
- [ ] MUTANT: suppress one phase timer → phase sum stops reconciling with `total` (test asserts reconciliation, goes red)
- [ ] FLEET: `RSDD_PROFILE=1 bash sweep-retros.sh` on niagara; record phase breakdown table; record go/no-go; `--full` diff still empty after this PR
- [ ] GATE: probador quiet-tree `run-all.sh` + `--prove-teeth` (cite U6 baseline) + shellcheck; confirm `--full` diff vs U8a baseline empty

---

## Phase 2b: Wave-2 units added during the campaign (explorador doctrine · mejorador tests)

### D7 — §21.2 unmountable media, §12 mutating live install, §14 threat-model axis, §19 tool-vs-PoC (issue #447, explorador) [x]
- [x] PR #448 merged as 185ad74; retros jace8000-sd, live-cutover, jace-data-at-rest, jace-history-audit closed.

### D8 — deferred harvested deltas across §5/§6/§8/§11/§12/§16/§18/§19/§21 (issue #450, explorador) [x]
- [x] PR #452 merged as e0b701a; 10 niagara retros updated (markers re-stamped with e0b701a).

### D9 — §11 split: kit-maintenance doctrine to situational §11b, HOT-CORE 823 → 664 lines (issue #454, explorador) [x]
- [x] PR #455 merged as da2781b; verbatim move verified by removed/added line-set diff.

### D10 — tool-registry.md scope note: kit wrappers only (issue #457, explorador)
- [ ] PR #458 open (probador gate).

### U13 — saturation window excludes unnumbered structural rows, never silently (issue #449, mejorador) [blocked-by: #435 U11, #424 U4 — same file]
- [ ] RED: fixture with a `—` bootstrap row in the tail; reopen-tail fixture with a positive seeded count.
- [ ] IMPL: exclude structural rows from the window + insufficient count; append `[N unnumbered row(s) … excluded]`; append `latest unnumbered row seeded N gaps — not yet an iteration` when the last row is unnumbered with a positive count.
- [ ] TEETH: 3 mutants named in #449. FLEET: exactly the 3 named focuses move out of `unreadable window`.

### U14 — test speed: hermetic PATH + probe timeouts in detect-tools/tool-env/verify-parity (issue #453, mejorador) [x]
- [x] PR #456 merged as 6fef040; baseline detect-tools 243.6 s of 471.5 s total; after-numbers recorded by probador.

## Phase 6: Campaign Close

### Retro closure markers in target corpora (METHODOLOGY §18, propose-never-apply)

- [ ] Operator adds `Retro:` applied-session trailer in target corpus per METHODOLOGY §18 for each retro whose deltas landed in this campaign. Kit never edits target corpora (propose-never-apply). Enumerate the closed retros after sdd-verify completes.

### Operator-only items (propose-never-apply — kit proposes; operator applies)

- [ ] `TARGETS.md`: operator refreshes affected rows after any corpus-size change (U2, U3 change observed block counts)
- [ ] `FOCUSES.md`: operator refreshes active-focus status fields using the D4 closed vocabulary (`active`, `paused`, `stopped`, `planned`)
- [ ] `BREAKTHROUGHS.md`: operator refreshes after new findings logged by this campaign
- [ ] Stale worktrees: operator runs `git worktree prune` on machines with stale `.claude/worktrees/` entries (now in `.gitignore` per U9)
- [ ] Installed SKILL.md: operator runs skill installer to refresh the stale installed copy (15 lines / 5 hunks behind today; U10 detects the drift but cannot self-apply)
- [ ] Orphan openspec change (`openspec/changes/improve-research-sdd-target-onboarding/`): operator closes or merges if open

### sdd-verify

- [ ] Run `sdd-verify` after all instrument PRs merge to main; verify the six spec capabilities (`kit-instrument-honesty`, `kit-doctrine-grammar`, `kit-subject-coverage`, `kit-session-cost`, `kit-hygiene-portability`) and every success criterion from `proposal.md`

### sdd-archive

- [ ] Run `sdd-archive` to close this change; update `tool-registry.md` rows for `coverage-map.sh` and `lib/block-files.sh` as prompted; refresh the `research-sdd-kit-retro-campaign` openspec change entry

---

## Sequencing Reference (design D-7)

```
D1 D2 D3 D5 ── inert doctrine, already done or in flight
D4 ──────────────────────────► U2
D6 ──────────────► U5 · U7 · U3 (metric sentence)
U6 ─(re-baseline)─► every later gate report must cite U6 baseline commit
U1 ─► U11 ─► U4
       └───► U2 (after D4 ✓)
       └───► U7 (after D6 ✓) ─► U8a ─► U8b
U12 ─► U5 (after D6 ✓)
U12 ─► U8a
U9 · U10 · U3 — no file lock, fully concurrent in Phase 2
```
