```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:46e10988fda920ac5c869798cbc6a585ca2a01394de5903e51b9577b2c1a441a
verdict: fail
blockers: 1
critical_findings: 1
requirements: 14/21
scenarios: 47/55
test_command: "bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth"
test_exit_code: 0
test_output_hash: sha256:232d1c74f793422424619d025713097ae08657c6a93315e8e5d7ff227f01db7e
build_command: "shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh"
build_exit_code: 0
build_output_hash: sha256:7d1fb3ae8308be5fc3c4e83d9b72f57d10580498660fbde5b72ddeab38f9c374
```

# Verify Report — research-sdd-kit-retro-campaign

**Change**: `research-sdd-kit-retro-campaign`
**Mode**: full spec verification (proposal + design + 5 capability specs + tasks)
**Artifact store**: HYBRID (openspec files + Engram project `sdd-investigacion`)
**Evidence revision**: `af83e7a` (origin/main tip, PR #496)
**Worktree used**: `/home/cristian/investigacion/sdd-investigacion-worktrees/explorador-verify` (branch `sdd/verify-report`, created from `origin/main`; the shared checkout was stale at `4c100d8`)
**Verified**: 2026-09-06
**Envelope note**: `evidence_revision` is `sha256("af83e7aa41d11caaea58d2336ad427748ad4e010")` — the validator requires a `sha256:<64-hex>` form, and the human-readable candidate revision is commit `af83e7a`. `blockers: 1` is CRIT-1 below.

---

## 1. Summary verdict

**FAIL — 1 CRITICAL, 9 WARNING, 3 SUGGESTION.**

Every executable gate is green on a quiet tree at `af83e7a`. 39 PRs (#427–#496) merged into main
deliver the campaign. 47 of 55 spec scenarios PASS with firsthand evidence, 7 are PARTIAL (behaviour
present, the spec's pinned literal / pinned fleet number differs or the proof obligation was
delegated to the gate record rather than re-derived here), and 1 FAILS outright.

The single CRITICAL is documentation-only and one table row wide: `DEPLOY-WINDOWS-MINIPC.md` was
created by D2 (PR #446) but never registered, while its four sibling `.md` docs in the same
`tool-registry.md` block (`DYNAMIC-SETUP.md`, `REMOTE-POWERSHELL.md`, `BACNET-TRENDLOG.md`,
`NIAGARA-N4-FRAMEWORK.md`, lines 303–306) all carry rows. Nothing else in the kit references the
file. It is an orphan doc, not a broken instrument.

The verdict is `fail` because a spec scenario fails on readback, not because the kit is unsound.

---

## 2. Gate aggregate lines (run firsthand in the worktree at af83e7a)

### Shellcheck

```
FILE_COUNT=173
SHELLCHECK_EXIT=0
```

Zero warnings across 173 files. `globstar` was set explicitly, so `lib/` and `tests/` are included
(CLAUDE.md §5: check the file count, not the absence of an error).

### Test suite — `bash research-sdd/toolbelt/tests/run-all.sh`

```
Suites run:    106
Suites passed: 106
Suites failed: 0
Suites skipped: 0
Test cases passed: 2142
Test cases skipped: 6
Test cases failed: 0
```

Exit 0. `grep -c '^  FAIL  '` over the full log returns **0** (matched on the runner's own
`  FAIL  ` prefix per CLAUDE.md §5, not the bare string).

### Mutation gate — `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth`

```
Suites run:    106
Suites passed: 106
Suites failed: 0
Suites skipped: 0
Test cases passed: 2589
Test cases skipped: 8
Test cases failed: 0
Suites without teeth: 21 — [capture-analyze, capture-exec, capture-plan, corroborate-pcap, detonate-plan, docker-exec, emba-plan, fact-exec, fact-plan, firmware-carve, kaitai-driver-walk-memcap, pcap-flows, plan-common, proc-common, process-integrity, qemu-exec, qemu-plan, trace-plan, vm-determinism, vm-receipt, vm-run]
(vocabulary check: a "teeth" case with no real mutant is a review item)
Suites n/a for teeth (node): 2
Suites with teeth but no banner: 23 — [adapter-core, adapter-helpers, analysis-manifest, block-files, capa, corroborate-firmware, corroborate-ghidra, corroborate-java, corroborate-native-r2, detonate-exec, discriminator-parity, floss, ghidra-c-exporter, ghidra-exporter, jvm-callgraph, kaitai, pslint, skill-twin-parity, sweep-breakthroughs, trace-exec, unblob, vm-disk-policy, wall-protocol-doctrine]
```

Exit 0. All four #426 lines print, in the order and one-per-line shape CLAUDE.md §5 pins.

### Doc consistency — `bash research-sdd/toolbelt/verify-doc-consistency.sh`

```
Summary: checked METHODOLOGY.md (22 top-level ## N. sections) · SKILL.md · PROMPT-LOOP.md · README.md (§-range upper: 22)
  Findings: 0 stale-count · 0 orphan section(s) · 0 broken citation(s) · 0 readme-range
Doc consistency: clean.
```

Exit 0.

---

## 3. Cross-check against probador's gate record

| Metric | probador (#496, `af83e7a`) | This run (`af83e7a`) | Verdict |
|---|---|---|---|
| `run-all.sh` suites | 106/106 | 106/106 | Match |
| `run-all.sh` cases | 2142 · 0 failed | 2142 passed · 0 failed | **Exact match** |
| shellcheck | `sc 0` | 173 files, 0 warnings, exit 0 | Match |
| doc consistency | "doc green" (#487 row) | exit 0, 0 findings | Match |
| `--prove-teeth` aggregate | not recorded (record carries per-suite teeth counts only, e.g. `33/0` for retro-gate) | 106/106 · 2589 cases · 0 failed | **Not comparable — no discrepancy, no corroboration** |

**Discrepancies found: none.** The one gap is a shape gap, not a number gap: the gate record tracks
per-PR, per-suite teeth counts, so it holds no fleet `--prove-teeth` aggregate to compare against
mine. I record 2589 as a single-execution measurement of this candidate and this environment, and do
not persist it as a tracked figure (CLAUDE.md §5: live telemetry belongs to the instrument).

---

## 4. Per-capability requirement/scenario matrix

Legend: PASS = literal/behaviour verified firsthand on main plus a covering test that passed at
runtime. PARTIAL = behaviour present but a pinned literal, pinned count, or proof obligation
diverges. FAIL = readback contradicts the spec.

### 4.1 kit-instrument-honesty (5 requirements, 15 scenarios)

| # | Requirement / Scenario | Status | Evidence |
|---|---|---|---|
| R1 | Three-State Instrument Honesty | **PARTIAL** | see S1.4 |
| R1.S1 | Absent input exits non-zero with typed label | PASS | `coverage-map.sh:66` `printf 'subject: absent-input (%s not traversable)\n'`; firsthand run against `/nonexistent/path` → `rc=1` + typed line. Test: `tests/coverage-map.test.sh:44-45` "absent subject: exit 1 + absent-input message". PR #451 / `0c90262` |
| R1.S2 | No-match distinguished from absent | PASS | `coverage-map.sh:250` `printf 'no-match (%d modules, 0 cited)\n'`; `coverage-map.sh:173` `corpus: empty-input (0 block files)`; `coverage-map.sh:115` `subject: empty-input (0 class basenames)`. Test: `tests/coverage-map.test.sh:67-78` (cases 3 and 4). PR #451 / `0c90262` |
| R1.S3 | Mutation — absent-input guard removed goes red | PASS | `tests/coverage-map.test.sh` teeth (a)–(f); `--prove-teeth` 106/106, 0 failed |
| R1.S4 | `\|\| true` after producer eliminated — bite test | **PARTIAL** | 8 sites (not the spec's 11) were in scope for U12/#441; each now carries a typed string: `verify-kit-clean.sh:40-42` `WARN: staged\|unstaged\|untracked count FAILED (grep exit R)`, `scan-secrets.sh:124,132`, `sweep-tools.sh:216`, `sweep-tools-hook.sh:49`, `verify-block.sh:291,297`, and explicit "No `\|\| true`" comments at `verify-sources.sh:79`, `sweep-tools.sh:133,154`, `verify-tool-catalog-hook.sh:58`, `sweep-breakthroughs.sh:135`, `verify-retro.sh:21`. PR #463 / `2f83114`. **Residual**: two producer sites survive at `coverage-map.sh:79` and `coverage-map.sh:84` (`grep -v … \|\| true`) — see WARN-3 |
| R2 | Teeth Accounting in run-all.sh | **PASS** | |
| R2.S1 | Teeth count line emitted on every run | PASS | `tests/run-all.sh:237-241` emits all four lines; measured aggregate above shows `Suites without teeth: 21 — [...]` and exit 0. Spec predicted 21 shell suites — exact. Test: `tests/run-all.test.sh:339-341`. PR #462 / `055d604` |
| R2.S2 | `--require-teeth` fails when N > 0 | PASS | `tests/run-all.test.sh:345-352` "--require-teeth: exits 1 when no-teeth suites exist" and `:354-361` "exits 0 when all suites have teeth" — both passed at runtime in this run's suite execution |
| R2.S3 | Fleet acceptance — no new unintended failures | PASS | 106/106 · 0 failed on both the plain and `--prove-teeth` runs; 0 `  FAIL  ` lines |
| R3 | Saturation Parser Enumerates All Fleet Forms | **PARTIAL** | see S3.1 / S3.4 |
| R3.S1 | Previously BLIND tables are classified | PARTIAL | No silently-skipped table observed: every niagara focus resolved into a named bucket and 21 stderr WARNs named their forms. The fleet-wide BLIND 35→0 count was **not** re-derived here (probador gated it on #442 and #474) |
| R3.S2 | Unrecognised cell form produces typed WARN | PASS | `research-sdd-status.sh:198` `unreadable window — ${badwin} of last ${w} rows unrecognised (forms: ${wforms})`; 21 typed WARNs on stderr over the niagara corpus; no saturation number computed for those tables |
| R3.S3 | Mutation — cell-form parser bypass goes red | PASS | `tests/research-sdd-status.test.sh` teeth; `--prove-teeth` green |
| R3.S4 | Literal saturation output partition (#420 wording) | **PARTIAL** | All three pinned literals present verbatim: `research-sdd-status.sh:171` `no New-gaps column (header: ${colhdr})`; `:198` `unreadable window — N of last W rows unrecognised (forms: …)`; `:190,:200` `insufficient history (N iterations)`. The pinned fleet partition (~36 readable / 8 no-column / 6 unreadable-window / 19 no-header) was **not** reproduced — see §7. PR #442 / `0df9a51`, refined by #474 / `1c90f59` |
| R4 | sweep-retros Typed Delta-Missing State | **PASS** | |
| R4.S1 | Prose-only delta retro → typed state, not confident zero | PASS | `sweep-retros.sh:217` `deltas="no delta section found (empty-input)"`. Firsthand fleet run: **5** retros in that state, **0** occurrences of `~0 proposed deltas`. Spec predicted 4; measured 5 (corpus grew). PR #475 / `a26253e` |
| R4.S2 | Missing review-status marker surfaced | PASS | `sweep-retros.sh:168` `WARN: no review-status marker in … — add '<!-- review-status: pending -->'`. Firsthand: **22** such WARNs (spec predicted 5 — the campaign itself added retros). Also `:224` deprecated-heading WARN, 3 occurrences |
| R5 | D1 Doctrine — §20 Freeze and §7 Engram Fallback | **PASS** | |
| R5.S1 | §20 freeze-first sentence present | PASS | `METHODOLOGY.md:2483` **FREEZE THE LIVE SUBJECT FIRST.**; `:2485` names `sha256`/md5 of the artifact; `:2488` cites the measured md5 drift `1335aad0 → dbd52496 → 433630f3`. PR #434 / `272e1ad` |
| R5.S2 | §7 engram unregistered-target fallback present | PASS | `METHODOLOGY.md:644` **Unregistered-target fallback (do not skip the mirror).**; `:648` the block-note form; `:652` "Memory is evidence about memory, not about the subject" |

### 4.2 kit-doctrine-grammar (6 requirements, 12 scenarios)

| # | Requirement / Scenario | Status | Evidence |
|---|---|---|---|
| R1 | FOCUSES Status Closed Grammar (§16) | **PARTIAL** | see S1.1 |
| R1.S1 | Four-word vocabulary stated in §16 | **PARTIAL** | `METHODOLOGY.md:2036-2048` declares a closed table of **seven** tokens — `active`, `paused`, `stopped`, `planned`, `bootstrapping`, `reopened`, `document` — not the spec's exactly-four. The widening is deliberate and evidenced in place (`:2052-2056`: the live niagara index carried `CLOSED (13/13)`, `document 4/4`, `reabierto (18/31)`). The capability's Purpose ("classifiable by a downstream checker without prose heuristics") is satisfied; the scenario's literal "exactly the four tokens" is not. PR #427 / `f73f5d6` |
| R1.S2 | verify-doc-consistency clean after update | PASS | exit 0, 0 findings (§2) |
| R2 | Block Type Closed Grammar (§4 + block.template.md) | **PARTIAL** | see S2.2 |
| R2.S1 | §4 and template declare the same domain | PASS | `METHODOLOGY.md:256-258` and `templates/block.template.md:23-28` both list the identical 9-token domain: `standard`, `evidence`, `synthesis`, `mixed`, `absence-centred`, `capture`, `document`, `collaborative`, `audit`. `verify-block.sh:168` accepts exactly that set. PR #430 / `2380544`, #467 / `11b4e77` |
| R2.S2 | Out-of-domain Type value produces WARN | **PARTIAL** | `verify-block.sh:168-171` emits `WARN … unrecognised Type: token '<t>'; accepted: …`, but only inside the P6 branch (`cert_total > 0` and zero resolved citations, `:139-150`). A block with resolved citations and an out-of-domain Type gets no WARN. Doctrine agrees with the code — `METHODOLOGY.md:261` states "the token only re-grades the ZERO-citations WARN" — so this is a spec-vs-doctrine gap, not a doc↔code drift |
| R2.S3 | Synthesis-type ZERO-citation diagnostic is INFO not WARN | PASS | `verify-block.sh:166-167` `INFO    [CERT] markers present … expected for declared type $_type_token.` for `synthesis\|capture\|document\|absence-centred`. PR #467 / `11b4e77` |
| R2.S4 | Mutation — Type parser bypass goes red | PASS | `tests/verify-block.test.sh` teeth; `--prove-teeth` green. Blockquote-prefix hardening (`P6-BQ-STRIP`, `verify-block.sh:160`) added by PR #493 / `82b88fb` (U15/#468) |
| R3 | Machine-Countable Delta Declaration (§18 + retro.template.md) | **PASS** | |
| R3.S1 | §18 states mandatory machine-countable declaration | PASS | `METHODOLOGY.md:2167` "**The delta declaration is machine-countable, and that is MANDATORY.**"; trigger extended at `:2081` (applied sessions) and `:2148` (post-close addenda). PR #430 / `2380544`, extended by D14 PR #481 / `bd262f5` |
| R3.S2 | retro.template.md contains canonical heading | PASS | `templates/retro.template.md:10` `## Proposed kit deltas`; `:61` explains the counter's dependency on it |
| R4 | New-Gaps Cell Grammar in RESEARCH-STATE Template | **PASS** | |
| R4.S1 | Grammar sentence present in template | PASS | `templates/RESEARCH-STATE.template.md:79-87` — names header-name selection (`/new gaps\|nuevos gaps/i — NOT by position`) and the cell grammar (leading integer) |
| R5 | D3 — PROMPT-LOOP SYNTHESIS-GUIDE and SECRETS | **PASS** | |
| R5.S1 | SYNTHESIS-GUIDE FOCUS pattern named | PASS | `PROMPT-LOOP.md:260` `SYNTHESIS-GUIDE FOCUS`; `:274-277` `SYNTHESIS-GUIDE FOCUS PAIR` with the two-axis (WHAT/HOW) form and the declare-the-pair rule. PR #445 / `fe88d17` |
| R5.S2 | SECRETS cluster with inline-over-delegate rule | PASS | `PROMPT-LOOP.md:387-391` `SECRETS-SENSITIVE INLINE OVERRIDE` — the file-count delegation trigger is overridden when findings carry key bytes or credential strings |
| R6 | D5 — §3 Evidence-Marker Taxonomy Decision | **PASS** | |
| R6.S1 | Five marker-taxonomy rules stated in §3 | PASS | `METHODOLOGY.md:90` `[CERT-a]` = secondary source; `:96` "keeps its single meaning … It is NOT" (agent-gathered); `:85` `[CERT-hw]`; `:86` `[CERT-live]` = live REMOTE service; `:102` `-hw` vs `-live` stated once; `:129` Engram `#id` is not a `[CERT]` citation. PR #434 / `272e1ad` |

### 4.3 kit-subject-coverage (3 requirements, 8 scenarios)

| # | Requirement / Scenario | Status | Evidence |
|---|---|---|---|
| R1 | coverage-map.sh Instrument | **PARTIAL** | see S1.3 |
| R1.S1 | Uncited module count reproduced on real corpus | PASS (deviation named) | Firsthand at `af83e7a`: `coverage-map.sh /home/cristian/niagara-research --subject …/organized --ext java` → `ambiguous basenames excluded: 5530` / `excluded by declaration: 0 unit(s) (none)` / `modules: 174/318 cited · 144 never cited`. Spec pinned 148; measured **144**, reproducing PR #451's own recorded figure exactly. The spec's escape clause ("or names any deviation with measured evidence") is satisfied — PR #451's body attributes the shift to its three pre-merge correctness fixes (extension-bearing citation, declared denominator, tightened path-token) |
| R1.S2 | Three-state honesty — absent corpus path | PASS | Firsthand `rc=1` + `subject: absent-input (/nonexistent/path not traversable)`; no `0 uncited` printed. `coverage-map.sh:66` |
| R1.S3 | Fleet acceptance — two real targets | **PARTIAL** | niagara reproduced firsthand (above). panccadia ran firsthand and returned `subject: empty-input (0 class basenames)` / `modules: 0/0 cited · 0 never cited` — a correct three-state result, but it yields **no** uncited-module evidence, so "every module listed as uncited is verifiably not cited" is vacuous on that target. `tool-registry.md:327` carries the `coverage-map.sh` row (PASS) |
| R1.S4 | Mutation — bypass produces wrong count | PASS | Six teeth (a)–(f) in `tests/coverage-map.test.sh`, including `:341` asserting the `excluded by declaration:` line is never silent; `--prove-teeth` green |
| R2 | verify-state.sh shared-global covered_blocks Semantics | **PASS** (literals deviate) | |
| R2.S1 | Shared-global focus stops FAILing | PASS | `verify-state.sh:360` uses the attributed count for CHECK A and reserves `_ondisk_global` for the summary. Test `tests/verify-state.test.sh:946-965` `BS-global-ok` (covered_blocks=3 == attributed 3, corpus 5 → exit 0), with the mismatch case still FAILing at `:968-988` `BS-global-stale`. Mutation at `:1818` reverts attribution to corpus total and goes red. PR #465 / `fd82e82` |
| R2.S2 | INFO line present with corpus total | PASS — **literal deviates** | Actual printed strings (report the exact string, per the verify brief):<br>• `   INFO   corpus total ${N} block file(s) (shared-global, informational)` (`verify-state.sh:399`) — spec pinned `corpus total N (shared-global, informational)`; the code inserts `block file(s)`.<br>• `   INFO   covered_blocks unverifiable under shared-global: no attributed block ids listed` (`verify-state.sh:401`) — spec pinned the parenthetical form `… shared-global (no attributed block ids listed)`; the code uses a colon.<br>Both are the same semantic line; only punctuation/qualifier differs. Covered by `tests/verify-state.test.sh:1104-1117` `SG-unverifiable` (INFO not FAIL, exit 0) |
| R2.S3 | Non-shared target unchanged | PASS | `tests/verify-state.test.sh:1038-1050` `BS-no-blocks` asserts the standard FAIL with **no** shared-global hint when no `block_scope` applies; `:1021-1036` `BS-cannot-see` keeps the two paths distinct |
| R3 | D6 — §8 Coverage Metric in Doctrine | **PASS** | |
| R3.S1 | §8 coverage-over-the-subject paragraph present | PASS | `METHODOLOGY.md:835` "**Coverage over the SUBJECT is a second, different metric — declare it when the subject has structure.**"; cross-listed at `:47` in the systems-thinking row. PR #430 / `2380544` |

### 4.4 kit-session-cost (3 requirements, 8 scenarios)

| # | Requirement / Scenario | Status | Evidence |
|---|---|---|---|
| R1 | sweep-retros-hook.sh Summary Mode | **PASS** | |
| R1.S1 | Default output under 3,000 characters | PASS | Firsthand: **1,855** and **1,885** chars across two runs, exit 0 (probador recorded 1,738 B on #478 — the delta is retro-age text that moves with the calendar). PR #478 / `58bed7e` |
| R1.S2 | Absent-input targets collapsed to one counted line | PASS | Firsthand output carries exactly one line: `INFO: 17 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.` |
| R1.S3 | Full output available behind verbose flag | PASS | `sweep-retros-hook.sh:9-12` parses `--full` in any position; `:5` documents it as byte-identical to the old default |
| R2 | verify-tool-catalog-hook.sh Clean Sentinel | **PASS** | |
| R2.S1 | Clean run emits a non-empty sentinel line | PASS | Firsthand: `Research-SDD tool catalog: clean (26 logged tools, 0 uncataloged).`, exit 0. Source `verify-tool-catalog-hook.sh:47` (`# CLEAN-SENTINEL`). PR #478 / `58bed7e` |
| R2.S2 | Absent catalog reported distinctly | PASS | `tests/verify-tool-catalog-hook.test.sh:63` asserts `verify-tool-catalog: ERROR — cannot find INSTALLED-TOOLS.md (absent-input)`; passed at runtime in this run |
| R2.S3 | Mutation — sentinel removal goes red | PASS | `tests/verify-tool-catalog-hook.test.sh` teeth; `--prove-teeth` green |
| R3 | D2 — DYNAMIC-SETUP and DEPLOY-WINDOWS-MINIPC.md | **FAIL** | see S3.2 |
| R3.S1 | §1 raw-image subsection present | PASS | `toolbelt/DYNAMIC-SETUP.md:62` `## 1c. Raw-image a physical/removable disk (when \`wsl --mount\` fails)`; `:67` names the `drvfs` / `wsl --mount --bare \\.\PhysicalDrive<N>` failure mode; `:70` gives the raw-image-on-Windows / analyze-on-WSL split. PR #446 / `7349004` |
| R3.S2 | DEPLOY-WINDOWS-MINIPC.md exists and is registered | **FAIL** | The file exists (`research-sdd/toolbelt/DEPLOY-WINDOWS-MINIPC.md`, 79 lines, added by `7349004`). `grep -c 'DEPLOY-WINDOWS-MINIPC' research-sdd/toolbelt/tool-registry.md` → **0**, and `git show 7349004:…/tool-registry.md \| grep -c DEPLOY-WINDOWS-MINIPC` → **0**, so the row was never written. A fleet-wide grep finds **no** reference to the file anywhere outside `openspec/`. See CRIT-1 |

**Capability Purpose budget (not a `### Requirement`, reported for honesty):** the Purpose states
total SessionStart hook output MUST stay under 8,000 characters. Measured firsthand on this machine,
running all 7 hooks registered in `.claude/settings.json`:

```
sweep-retros-hook 1855 · sweep-audits-hook 2575 · sweep-breakthroughs-hook 2952
verify-registry-hook 1545 · verify-kit-clean-hook 0 · sweep-tools-hook 307
verify-tool-catalog-hook 164
TOTAL_CHARS=9398
```

**9,398 > 8,000.** See WARN-1. Note also `verify-kit-clean-hook` emitting **0 chars** — see SUGG-1.

### 4.5 kit-hygiene-portability (4 requirements, 12 scenarios)

| # | Requirement / Scenario | Status | Evidence |
|---|---|---|---|
| R1 | lib/block-files.sh Centralised Discriminator | **PARTIAL** | see S1.1 |
| R1.S1 | Byte-identical output before and after extraction | **PARTIAL** | Not re-derived here. Reproducing it requires building both `f470656^` and `af83e7a` and diffing 16 sites against two live corpora; probador gated it on PR #464 and the campaign's `discriminator-parity.test.sh` FAMILY 1/FAMILY 2 cases passed in this run. Accepted on the gate record, not on my own measurement — see §7 |
| R1.S2 | Single definition — no hand-rolled duplicates remain | PASS | `lib/block-files.sh` is the sole definition of `block_file_filter`; 9 production scripts import it (`research-sdd-status.sh`, `research-sdd-archive.sh`, `verify-state.sh`, `verify-registry.sh`, `verify-parity.sh`, `verify-corrections.sh`, `sweep-retros.sh`, `sweep-breakthroughs.sh`, `retro-gate.sh`). `verify-registry.sh:351-365` keeps a deliberately *broader* guard regex whose purpose is the opposite (catching non-canonical names the discriminator drops) and documents that in place — not a duplicate. PR #464 / `f470656` |
| R1.S3 | archive retro-marker parser routes through lib/retro-status.sh | PASS | `grep -n "head -10 \| grep '^review-status:'" research-sdd-archive.sh` → no match. `research-sdd-archive.sh:48-54` sources `lib/retro-status.sh` and uses `retro_review_status` |
| R2 | Installed-Skill Drift Detection (U10) | **PASS** | |
| R2.S1 | Stale installed copy reported by hunk count | PASS | `tests/skill-twin-parity.test.sh:192` `installed copy: DRIFT — %s hunk(s) / %s line(s) behind the kit copy`; `:171` names the four states; teeth at `:265-270` (`A12 stale fixture — exact hunk count; not in sync`). PR #477 / `2f8dfec` |
| R2.S2 | Absent installed copy reported as absent-input, not zero | PASS | `tests/skill-twin-parity.test.sh:178` `installed copy: absent-input (%s not found) — drift check skipped`; `:267` asserts the absent output must NOT contain `in sync` |
| R2.S3 | Instrument is not a SessionStart hook | PASS | `.claude/settings.json` parsed: 1 SessionStart entry with 7 hook commands (`sweep-retros-hook`, `sweep-audits-hook`, `sweep-breakthroughs-hook`, `verify-registry-hook`, `verify-kit-clean-hook`, `sweep-tools-hook`, `verify-tool-catalog-hook`). `skill-twin` string absent |
| R3 | Hygiene Bundle Correctness (U9) | **PASS** | |
| R3.S1 | .gitignore covers the worktrees directory | PASS | `.gitignore:18-19` — comment + `.claude/worktrees/`. PR #473 / `87c26d5` |
| R3.S2 | Hardcoded absolute path absent from hook template | PASS | `templates/hook-sessionstart.sh:17` `_hook_target="$(cd "$(dirname "$0")/../.." && pwd)"`; `:50` uses a `<KIT>` placeholder with a resolution sentence. Fleet grep for `/home/cristian` across `templates/` and `toolbelt/*.sh` → 0 hits |
| R3.S3 | verify-doc-consistency.sh is executable | PASS | `git ls-files --stage research-sdd/toolbelt/verify-doc-consistency.sh` → `100755 a8ef944…` |
| R3.S4 | verify-kit-clean.sh counters have companion tests that bite | PASS | `verify-kit-clean.sh:33-35` captures each counter's rc; `:40-42` emits the three typed `WARN: <counter> count FAILED (grep exit R)` lines. Mutant at `tests/verify-kit-clean.test.sh:197-199` reintroduces `\|\| true` and strips the WARNs; `--prove-teeth` green |
| R4 | D4 — §16 Multi-Focus Doctrine Completeness | **PASS** | |
| R4.S1 | §16 states global block-number allocation rule | PASS | `METHODOLOGY.md:2101-2110` "**Global block-number allocation under `shared-global`.**" — one allocation channel, `<!-- next-block: N -->` marker, claimed numbers never reused, unclaimed blocks are PROVISIONAL. PR #427 / `f73f5d6` |
| R4.S2 | §16 states peer-owned dirty tree is read-only | PASS | `METHODOLOGY.md:2111-2118` "**A peer-owned dirty tree is a hard read-only boundary; one checkout is never shared for writes.**" — includes the shared-checkout guard (no `git checkout/stash/reset/pull --rebase` on a shared tree) and cites the two-incident evidence |

---

## 5. Doctrine units D1–D16 — readback

| Unit | Issue → PR / sha | Claim | Status | Evidence |
|---|---|---|---|---|
| D1 | #432 → #434 / `272e1ad` | §20 freeze-first, §7 Engram fallback | PASS | `METHODOLOGY.md:2483,2485,2488`; `:644,648,652` |
| D2 | #428 → #446 / `7349004` | DYNAMIC-SETUP §1c, DEPLOY doc, registry rows | **PARTIAL** | §1c PASS (`DYNAMIC-SETUP.md:62`); 26 registry lines added; DEPLOY row **absent** → CRIT-1 |
| D3 | #431 → #445 / `fe88d17` | SYNTHESIS-GUIDE + SECRETS | PASS | `PROMPT-LOOP.md:260,274,387` |
| D4 | #425 → #427 / `f73f5d6` | §16 status grammar + shared-global | PASS (vocab widened) | `METHODOLOGY.md:2036-2048,2101,2111` |
| D5 | #433 → #434 / `272e1ad` | §3 marker taxonomy | PASS | `METHODOLOGY.md:85,86,90,96,102,129` |
| D6 | #429 → #430 / `2380544` | §18 + §4 + §8 + 3 templates | PASS | `METHODOLOGY.md:2167,256,835`; three templates |
| D7 | #447 → #448 / `185ad74` | §21.2 unmountable media, §12, §14, §19 | PASS | merged; doc-consistency clean |
| D8 | #450 → #452 / `e0b701a` | deferred harvested deltas | PASS | merged; doc-consistency clean |
| D9 | #454 → #455 / `da2781b` | §11 split → §11b | PASS | merged; `verify-doc-consistency` reports 22 top-level sections, 0 orphans |
| D10 | #457 → #458 / `ab83e5f` | tool-registry scope note | PASS | `tool-registry.md:7` "**Scope: KIT wrappers only.**" |
| D11 | #460 → #461 / `e042726` | CLAUDE.md §12 campaign lessons | PASS | `CLAUDE.md:337` `## 12. Multi-Session Campaigns — Measured Lessons`; `:339` names the 2026-09-05 campaign |
| D12 | #469 → #470 / `fd6762f` | §5 `--require-teeth` row + §4 teeth sentence | PASS | `CLAUDE.md:137` gate row; `:126` "`--require-teeth` turns the list into an exit-1 gate" |
| D13 | #471 → #472 / `a6e62eb` | anchor the row on a search term | PASS | `CLAUDE.md:137` cites `# SENTINEL-NO-TEETH-BANNER`; the anchor exists at `tests/run-all.sh:236` |
| D14 | #479 → #481 / `bd262f5` | §18 retro is an exit condition | PASS | `METHODOLOGY.md:2187` "**Enforcement — the retro gate (a run is not over until the retro exists).**"; both SKILL twins carry it (`skills/research-sdd/SKILL.md:197`, `toolbelt/opencode/SKILL.md:195`) |
| D15 | #482 → #487 / `7ad2b92` | harvest — §11 cautions, DYNAMIC-SETUP 4b/4c, DEPLOY gotcha | PASS | `DYNAMIC-SETUP.md:154` `### 4b.`, `:163` `### 4c.`; `DEPLOY-WINDOWS-MINIPC.md:68` detached-`node` gotcha |
| D16 | #484 → #485 / `24069c3` | technical-excavator profile §1 + §13 layer axis | PASS | `METHODOLOGY.md:36` "**Researcher profile — the technical excavator.**"; `:1789` "**The layer axis of the coverage matrix (technical-excavator profile, §1).**" |

**Stale "until #N lands" notes:** `grep -rn "until #[0-9]\|until kit issue #[0-9]\|until issue #[0-9]\|once #N lands\|until … lands\|until … merges"` across `research-sdd/*.md`, `toolbelt/*.sh`, `toolbelt/*.md`, `templates/` and `CLAUDE.md` returns **zero** stale notes. The only two hits are non-stale: `CLAUDE.md:344` is the D11 doctrine *about* such notes, and `METHODOLOGY.md:2277` is a sentence about a WARN staying visible "until a retro lands". **PASS.**

---

## 6. Issues

### CRITICAL

**CRIT-1 — `DEPLOY-WINDOWS-MINIPC.md` is an unregistered orphan doc.**
Spec: `kit-session-cost` → `Requirement: D2` → `Scenario: DEPLOY-WINDOWS-MINIPC.md exists and is registered`.
The file exists at `research-sdd/toolbelt/DEPLOY-WINDOWS-MINIPC.md` (79 lines, `7349004`), but
`tool-registry.md` has zero rows for it — and it never did (`git show 7349004:…` confirms the row was
never written, so this is an omission at authoring time, not a later regression). A grep across every
`.md` and `.sh` in the repo finds no reference outside `openspec/`.
This is not covered by D10's "kit wrappers only" scope note: four sibling `.md` documents sit in the
same registry block — `DYNAMIC-SETUP.md` (`tool-registry.md:303`), `REMOTE-POWERSHELL.md` (`:304`),
`BACNET-TRENDLOG.md` (`:305`), `NIAGARA-N4-FRAMEWORK.md` (`:306`). The convention exists; this one
file was skipped.
*Remedy*: one row after `:306`, or amend the spec scenario. Doc-only; no instrument is affected.

### WARNING

**WARN-1 — SessionStart hook budget exceeded: 9,398 chars vs the 8,000 the capability Purpose pins.**
Measured firsthand across all 7 registered hooks (breakdown in §4.4). The three sweep hooks account
for 7,382 of it. `kit-session-cost` fixed the two hooks it named (`sweep-retros-hook` 1,855 < 3,000;
`verify-tool-catalog-hook` sentinel), so its own requirements pass — the *aggregate* Purpose does not.
Machine-dependent (17 targets are absent here), so the figure is this machine's, not the fleet's.

**WARN-2 — spec-literal drift in the two #423 INFO lines.** Behaviour correct, strings differ:
spec `covered_blocks unverifiable under shared-global (no attributed block ids listed)` vs actual
`covered_blocks unverifiable under shared-global: no attributed block ids listed`; spec
`corpus total N (shared-global, informational)` vs actual
`corpus total N block file(s) (shared-global, informational)`. Any downstream grep written against the
spec text will silently miss.

**WARN-3 — two residual producer `|| true` sites in `coverage-map.sh:79` and `:84`.**
Both are `grep -v … || true` over the exclusion arguments. A `grep` exit ≥2 there silently drops
exclusions and moves the denominator without announcing it — the exact §7 failure U12 was created to
close. `coverage-map.sh` (#421) landed independently of U12 (#441), whose enumerator covered 8 sites in
other files, so it was never in scope. Small and contained; the tool prints
`excluded by declaration: N unit(s)` unconditionally, which limits the blast radius.

**WARN-4 — `Suites n/a for teeth (node): 2`, spec scenario predicted 1.** A second `.test.mjs` suite
now exists. Reality moved; the spec text did not. No defect.

**WARN-5 — FOCUSES status vocabulary is seven tokens, not the spec's four.** See §4.2 R1.S1. Deliberate
and evidenced in doctrine; the spec was never amended.

**WARN-6 — `verify-block.sh` out-of-domain Type WARN is conditional on the ZERO-citations branch.**
See §4.2 R2.S2. Doctrine and code agree; the spec scenario is broader than both.

**WARN-7 — measured fleet counts diverge from the spec's pinned counts.** `no delta section found`:
5 (spec 4). `no review-status marker`: 22 (spec 5). `deprecated delta heading`: 3 (tasks predicted 9
aliased headings counted). uncited niagara modules: 144 (spec 148). Each behaviour is present; only
the numbers moved, mostly because the campaign itself added retros. Recorded so a future reader does
not treat the spec numbers as still-live telemetry.

**WARN-8 — `tasks.md` was materially stale at verification time.** 12 wave-2 units delivered by merged
PRs (U15–U20, D11–D16) had no entry at all, and the U6/U9/U10/U11/U12/U2/U4/U5/U7/U8a/U8b/D10/U13
sections still carried `[ ]` boxes for work that had merged. Corrected in this PR (§8).

**WARN-9 — the U11 byte-identical proof obligation was not independently re-derived.** See §7.

### SUGGESTION

**SUGG-1 — `verify-kit-clean-hook.sh` emits 0 characters on a clean tree.** That is precisely the
"empty stdout as the clean signal" pattern `kit-session-cost` R2 forbids for
`verify-tool-catalog-hook.sh` (issue #380 precedent). No spec requirement names this hook, so it is
not a FAIL — but it is the same defect family, one hook over, and it is free to fix.

**SUGG-2 — the panccadia arm of the coverage-map fleet acceptance is vacuous.** `subject: empty-input
(0 class basenames)` is a correct state, not coverage evidence. If a second real coverage target is
wanted, pick one with a source tree matching some `--ext`.

**SUGG-3 — consider amending the five specs to match the delivered reality** (four-token vocabulary,
1 node suite, the two #423 literals, the 148/4/5 fleet counts) rather than leaving seven PARTIALs
standing. A spec that no longer describes the code teaches readers to stop trusting it.

---

## 7. What was NOT verified (§7 honesty)

An instrument that reports a clean result must be able to prove it looked. These are the places
where I did not look, or looked less deeply than the spec's acceptance clause demands.

1. **The #420 fleet saturation partition (~36 readable / 8 no-column / 6 unreadable-window / 19
   no-header) was not reproduced.** What I ran was a per-focus sweep over the 64 niagara
   `RESEARCH-STATE-*.md` files, which yielded 23 SATURATED, 11 `unreadable window`, 7
   `no New-gaps column`, 1 `insufficient history`, 1 `active` with an unnumbered-row note, and 21
   focuses printing no saturation line. That is a **different enumerator over a different population**
   than the spec's fleet-wide, all-targets file count, and #474 (`1c90f59`) deliberately moved three
   focuses between buckets after #442 set those numbers. My figures neither confirm nor contradict
   the spec partition; they are simply not the same measurement, and I am not presenting them as one.
2. **The U11 byte-identical proof obligation (16 sites × 2 corpora, `f470656^` vs `af83e7a`) was not
   re-derived.** It is accepted on probador's PR #464 gate plus this run's passing
   `discriminator-parity.test.sh`. CLAUDE.md §3 is explicit that a merged, CI-green PR is not a
   verified PR — this obligation is carried on someone else's measurement, not mine.
3. **The 35→0 BLIND-table count was not counted.** I confirmed no table was *silently* skipped and
   that residues are named in WARNs; I did not establish the historical before/after figure.
4. **`--require-teeth` was not run against the real fleet.** Its exit-1 behaviour is proven by
   `run-all.test.sh` cases 20/21 in a sandboxed suite directory, which passed at runtime. Running it
   for real would exit 1 today by construction (21 suites without teeth) — that is the documented
   opt-in debt, not a regression.
5. **Fleet acceptance diffs against `main` were not produced for the instrument PRs.** CLAUDE.md §7
   requires new-WARN and exit-code-flip classification by hand for corpus-reading instruments. Each PR
   did this at merge time (probador's record names the load-bearing gate per PR); this verification
   re-ran the instruments on the fleet and inspected their output, but did not diff against a
   pre-campaign baseline.
6. **`--prove-teeth` has no independent corroboration for its aggregate.** 2589 cases is one
   execution in one environment. CLAUDE.md §5 records that two careful runs once disagreed (1,868 vs
   1,871) with the cause never established. Treat 2589 as this run's reading, not as a tracked figure.
7. **Operator-only items were not executed** and cannot be, by propose-never-apply: `TARGETS.md`
   row refreshes, `FOCUSES.md` status migration, `BREAKTHROUGHS.md`, `git worktree prune`, refreshing
   the installed `SKILL.md`, and the retro-closure `Retro:` trailers in target corpora. They remain
   `[ ]` in `tasks.md` deliberately.
8. **Blocks/corpora were not modified and no target directory was written to.** All corpus-reading
   runs in this verification were read-only.

---

## 8. Task completion

`tasks.md` was materially stale (WARN-8) and is corrected in the same PR as this report. After the
sync:

- **Delivered and now `[x]` with their squash sha**: D1–D16 (16 doctrine units), U1–U20 (instrument
  units), including the twelve wave-2 units that had never been listed at all: U15 #468→#493
  `82b88fb`, U16 #476→#486 `a5d3876`, U17 #479→#490 `6ea74c0` / #492 `1e9a0a2`, U18 #483→#495
  `dd2de6b`, U19 #489→#491 `e973341`, U20 #494→#496 `af83e7a`, D11 #460→#461 `e042726`, D12
  #469→#470 `fd6762f`, D13 #471→#472 `a6e62eb`, D14 #480→#481 `bd262f5`, D15 #482→#487 `7ad2b92`,
  D16 #484→#485 `24069c3`.
- **Genuinely undone, left `[ ]`**: the Phase 6 campaign retro, `sdd-archive`, the retro-closure
  markers in target corpora, and the six operator-only items.

39 PRs merged in the #427–#496 range. No unchecked task corresponds to code that has landed.

---

## 9. Verdict

**FAIL** — one CRITICAL (CRIT-1, doc-only), nine WARNINGs, three SUGGESTIONs.

Every gate is green and no instrument is broken. The blocking item is a single missing
`tool-registry.md` row. Once CRIT-1 is closed — one row, or a spec amendment — this change is ready
for `sdd-archive`.
