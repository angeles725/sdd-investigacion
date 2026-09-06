# Exploration — research-sdd-kit-retro-campaign

Date: 2026-09-05 · Phase: sdd-explore (hybrid store; Engram twin: `sdd/research-sdd-kit-retro-campaign/explore` #8169,
`…/math-models` #8173, `…/block-type-grammar` #8176) · Lead: explorador · Writer: mejorador · Gate: probador

## 1. Method and enumerator coverage (kit CLAUDE.md §7)

- Sources: (a) 30 pending §18 retros dated 2026-08-30..2026-09-04 (27 niagara-research, 3 panccadia-3d-viewer);
  (b) the verified second-wave backlog in Engram (#7874-#7877, #7879-#7881, 2026-08-31) re-checked against
  `origin/main` 4c100d8; (c) two deltas relayed by the investigador session; (d) explorador's own measurements
  (fleet probes, listed in §5).
- Read in full: 20 retros. Read at delta-declaration + target level only: 10 (jace-station-config, jace-data-at-rest,
  jace-history-audit, module-best-practices, module-dev-workflow, station-organization, jace8000-qnx-native,
  build-n4-module-kit-v0.2, coldroom-module-build, deploy-windows-minipc). Their evidence was not independently
  checked.
- The harvesting agent had no Bash tool: its delta counts were hand-derived by applying `sweep-retros.sh:150-195`
  logic to the files; the instrument's own run (explorador, same day) reports 78 pending / 99 retros fleet-wide with
  3 non-conforming declarations, consistent with the hand count.
- Pre-2026-08-30 doctrine cluster in #7876 (WC-B, D5-deep, D6-deep, D1-native, DELTA-3-ports, MA-1/CS-2, CS-GT,
  CS-META, BC3) was outside read scope and is NOT re-verified — declared gap.
- Unclassifiable candidates: none.
- Fleet universe for state-file measurements: 70 `RESEARCH-STATE*.md` (maxdepth 3, worktree copies and the kit
  template excluded; reconciled with probador's gate enumerator).

## 2. Measured facts that change the plan

1. **sweep-retros false-negative residual is ~7 %, down from 44 %.** Over the 30 in-scope retros: 19 counted
   correctly, 7 return `?` with a visible WARN, 4 confident zeros of which 2 are genuine false negatives (deltas
   declared inline as `→ PROPOSED …` prose) and 1 a true zero. Marginal fleet yield of any regex widening: 2 retros.
   Verdict: do NOT widen the parser; add a NEGATIVE check (WARN when a PENDING retro has no canonical delta
   section) after tightening §18. 5/30 retros carry no review-status marker at all.
2. **Saturation parser blind on 35/50 iteration-history tables** (issue #420, unit #1 dispatched). Column chosen by
   position, integer-only cells; fleet uses 8 header shapes and cell forms `N new`, `none net-new …`, `G12`.
3. **Bayesian saturation model dismissed with evidence.** 35 readable series, 349 transitions, base rate
   P(next block uncovers ≥1 gap) = 0.10. Brier: naive-3-zeros(soft) 0.089 ≈ base-rate 0.090 < EW-0.5 0.199 <
   GP-W3 0.203 < GP-W6 0.244 < GP-all 0.299; Gamma-Poisson over-confident (0.8-1.0 bin observed 0.02). The series is
   ~90 % zeros with a bootstrap burst; STOP is already deterministic. Not a work unit.
4. **Coverage over the SUBJECT is a real, buildable metric the doctrine lacks.** niagara-research: 318 top-level
   modules with Java under `organized/`, 50,358 class basenames (5,530 ambiguous, excluded), 2,102 cited across
   763 blocks; 170 modules cited, 148 (47 %) never cited. Direct AUDIT-FIRST gap-seeding source. Dependency
   centrality is NOT computable from `organized/` (only 2 `module.xml`); rank uncited units by size.
5. **Block `Type` field: doctrine contradiction + 1 % adoption** (issue #128 root fact). Template says verify-block
   reads it; §4 says it does not; verify-block:80/:151 tells authors to declare it and parses nothing. 8/763 niagara
   blocks declare it, with values (`evidence`, `synthesis`, `document`) outside the template domain.
6. **FOCUSES.md status drift is real but the cell has no schema.** 2 corpora fleet-wide have a FOCUSES.md.
   `niagara-research/FOCUSES.md:48` says `apis` is `planned (0/8)` while `RESEARCH-STATE-apis.md:27` says
   `status: stopped (12/12)`, `investigable_open: 0`. §16 prescribes four words (active/paused/stopped/planned); the
   live file uses `CLOSED (13/13; …)`, `document 4/4`, `reabierto (18/31)` and ≥12 parenthetical shapes. Third
   instance of the TARGETS.md maturity-cell failure → doctrine (§16 grammar) first, checker second.
7. **`[CERT-a]` semantic collision.** METHODOLOGY:63 defines it as secondary source; rt-authoring proposes
   agent-gathered citation; panccadia proposes preserved coordination notes. Needs one §3 decision pass, alongside
   the twice-contested `[CERT-live]`/`[CERT-hw]` boundary.
8. **verify-block `[BNNN]`/`jar!entry` citation classes**: verified open (no matches in the script), freshly
   re-exhibited (WARN on 3/6 module-best-practices blocks) — but same instrument and same WARN as the closed-unmerged
   synthesis gate (#128, 3.6 h). Land the doctrine half first; re-probe before any writer.

## 3. Backlog by destination file (deduplicated; sources in parentheses)

### METHODOLOGY.md
- §3 markers: `[CERT-hw]` extended to offline physical-media imaging (jace8000-sd D4); a teammate claim carries no
  marker until source-verified (MERGE cross-session-verify#1 + obix-architecture#2 + dashboardpan#4); liveness is a
  claim — verify freshness before labeling live (live-cutover#1, HIGH); numeric constants are `[CERT]` only with a
  fresh file:line grep (module-authoring#4); no-git mtime fallback (large-single-file#2); `[CERT-a]` — DECISION
  needed (§2.7).
- §4 block anatomy: close the `Type:` grammar (§2.5) and reconcile with the template (explorador).
- §5 sources: symbol-bearing ELF inventory is `[CERT]`, exempt from the twin-binary offset check (qnx-native D1);
  real slot vs reader-derived value before naming a data contract (dashboardpan#2, HIGH); a control-WRITE contract is
  incomplete without interlock/safety semantics (dashboardpan#5).
- §6 tools: focus-inherited census + fixed declaration grammar (alarm-webhook D1); giant single-line artifact recipe
  (MERGE large-single-file#1 + cross-session-verify#2, `awk 'length<300'`); firmware entropy + binwalk encryption
  discriminator (qnx-native D4); canonize a custom implementation against the vendor's own equivalent, a 0-hit
  anti-pattern survey is strong deviation evidence (multi-session-obix#3); obfuscated docSource is a WALL, not
  evidence (rt-authoring#3).
- §7 state/memory: engram unregistered-target fallback — §7:560-567 assumes `project:"<target>"` is always passable
  (MERGE panccadia-D2 + document-mode-live-subject#2); human-asserted memory needs verification (obix-and-loginless
  D1); a cited `[CERT]` finding is an asset, re-cite by id (obix-architecture#1); `mem_search` zero is not proof of
  absence (module-authoring#6); shared-global `covered_blocks` is the FILE count, not the max number (alarm-webhook D3).
- §8 stopping: saturation→application pivot is a legitimate terminal (rt-authoring#1); POST-CLOSE ADDENDUM lane
  (coldroom#2); cheap mid-run sub-request = BONUS block (module-authoring#3); add "coverage over the subject" as a
  distinct metric from "gaps closed / known gaps" (explorador, §2.4); one sentence pointing the saturation line at
  the New-gaps cell grammar (#420).
- §11 self-verify: read the code that DEFINES the set before an enumeration claim (commissioning-map#1, HIGH); prove
  a delta by checking the CONSUMER for absence (dashboardpan#1, HIGH).
- §12 dynamic: a live install that CAN mutate — credentials from a chmod-600 file outside the repo, never a real
  production write during verification (live-cutover#4, HIGH); live oBIX/Slot-Sheet is the first-choice oracle,
  always read the MODE next to the value (multi-session-obix#2).
- §14 consistency: REFUTE vs CLARIFY-SCOPE extended to the threat-model axis (data-at-rest C); peer dispute →
  re-open the PRIMARY source, a peer catch is first-class evidence (rt-authoring#5); `[CERT-live]` overrides a
  `[CERT-doc]` spec, then fix the doc (live-cutover#2); code-derived `[CERT]` needs a `[CERT-live]` cross-check
  (obix-quick-mode#2).
- §16 multi-focus: **FOCUSES.md status grammar** (doctrine-first, §2.6); **global block-number allocation for
  concurrent lanes in a shared-global corpus** (RELAYED; corroborated by two 2026-09-03 retros both self-numbered
  "(3/3)" and by relayed-cert-live#2); peer-owned dirty tree is a hard read-only boundary (MERGE dashboardpan#3 +
  module-authoring#5); peer-session-triggered focus topology (alarm-webhook D2, may merge with #7876 D6-deep —
  unverified); sibling/twin focus (qnx-native D2); distributed multi-session diagnosis split by SOURCE
  (multi-session-obix#1); APPLIED/BUILD-ALONG run mode (coldroom#1); census→taxonomy→playbook triad
  (module-authoring#1).
- §18 retro: trigger extension to applied sessions + post-close addenda (coldroom#5); a campaign retro checks the
  CONSUMING kit's corpus index (module-authoring#7); machine-countable delta declaration MANDATORY (§2.1 + #7875).
- §19 build/PoC: a read-only FS parser is a §19 deliverable whose oracle is the self-describing structure, not a
  round-trip byte diff (jace8000-sd D2); reusable-tool vs one-off-PoC classification (history-audit R1); bake
  redaction into reader tools (history-audit R3); scratchpad PoC proving control logic (rt-authoring#6).
- §20 document mode: **FREEZE THE LIVE SUBJECT FIRST** (MERGE panccadia-D1 + document-mode-live-subject#1, both HIGH;
  measured md5 drift 1335aad0→dbd52496→433630f3, validated three times) — best-evidenced delta of the wave, NOT
  applied; quick-mode terminal = engram finding + SEED memory (obix-quick#1); quick-mode drift into design advice
  must be marked (commissioning-map#2); CLIENT knowledge routes to the client log, not the corpus
  (commissioning-map#3); a cached artifact pins its resolved location or a resolver (module-authoring#8);
  provisional document block promoted in place (relayed-cert#3, LOW, author invites dismissal); coordination-notes
  path (panccadia D3) — BLOCKED on the `[CERT-a]` decision.
- §21 walls: **exotic/unmountable filesystem fallback rung** (jace8000-sd D2, HIGH) — NOT applied; native rung refined
  so symbol-bearing binaries are not pushed straight to decompile (qnx-native D1).

### PROMPT-LOOP.md
- BOOTSTRAP a2 census cross-ref; SECRETS: a raw disk image is itself secret-bearing, scratchpad only (jace8000-sd D3);
  SECRETS scope generalized to operator-own-env / relayed-peer (obix-and-loginless D2); redacted-file
  mask-verification (station-config Δ1, HIGH); structure-only binary inspection recipe (data-at-rest ΔA, HIGH);
  XML-path-scoped delegation (station-config Δ2); **inline-over-delegate override for secrets-sensitive artifacts**
  (data-at-rest ΔB, HIGH); synthesis-delegation in-hand→inline heuristic (MBP Δ3); **SYNTHESIS-GUIDE FOCUS** named
  pattern (MBP Δ1; strongest cross-retro corroboration, 3 independent instances) and its PAIR form (W1); out-of-scope
  operator question protocol (W2); delegated-sweep-contradicts-driver acknowledgement (SO1); focus-status in a
  remittance note is a VERIFIABLE claim — confirm from FOCUSES.md (SO2; doctrine twin of the drift checker);
  synthesis-block verify-block WARN is expected, token-check `[Block N]` instead (MBP Δ2); corroboration from an
  independent store as a named evidence block type (history-audit R2); quick mode may delegate the 3-source sweep
  (obix-quick#3); "todos" over a seeded backlog = launch concurrently (module-authoring#2); deliverable authoring
  anchors to the operator's existing mental model (coldroom#3).

### templates/
- `RESEARCH-STATE.template.md`: New-gaps cell grammar (#420). `block.template.md`: Type grammar (§2.5).
  `retro.template.md`: countable-delta declaration mandatory (§2.1).

### toolbelt/ docs
- `DYNAMIC-SETUP.md`: **new §1c raw-image a physical/removable disk when `wsl --mount` fails** (jace8000-sd D1, HIGH;
  three silent gotchas: 0-length read is not EOF on `\\.\PhysicalDrive`, `[Math]::Min` truncates >2 GB to Int32,
  seek-per-chunk; zero kit coverage, ~25 lines); headless-Chromium WebGL QA recipe (MERGE document-mode#3 +
  panccadia-T2; PARTIALLY applied at :80, new: CDP captureScreenshot fallback, relaunch-per-viewport, fresh-port
  confirmation); CORS/origin caveat for e2e (live-cutover#3).
- New `toolbelt/DEPLOY-WINDOWS-MINIPC.md` (panccadia b7-b9 PROMOTE + deploy-windows-minipc content; its `rc=$?`
  after a pipe gotcha is the exit-code-laundering family of kit CLAUDE.md §7).
- `tool-registry.md`: rows for any new instrument.

### toolbelt/ instruments (teeth required; fleet acceptance, never fixtures alone)
- **I-1 `research-sdd-status.sh` saturation parser** — issue #420, dispatched (unit #1).
- **I-2 `coverage-map.sh` (new)** — coverage over the subject; spec in `scratchpad/unit2-coverage-map.md`; measured
  yield 148 uncited modules on niagara.
- **I-3 `verify-block.sh` Type token** — after the §4 grammar; downgrade the ZERO-citations WARN to INFO for declared
  synthesis/capture/absence-centred blocks.
- I-4 `sweep-retros.sh` negative check (PENDING retro with no canonical delta section) + surface marker absence —
  ~40 lines, depends on the §18 doctrine line.
- I-5 FOCUSES.md ↔ RESEARCH-STATE status-drift checker — WARN-only, ~60 lines, DEPENDS on the §16 grammar; yield
  capped by 2 corpora.
- I-6 `verify-block.sh` `[BNNN]`/`jar!entry` citation classes — RE-PROBE first (#128 trap); no writer scheduled.
- I-7 `research-sdd-archive.sh` retro close-gate advisory→blocking — maintainer decision (§8), not mechanical.

## 4. Already applied (evidence)
sweep-retros doctrine-first delta counting (`sweep-retros.sh:124-195`, `retro.template.md:16-20`); canonical-heading
tightening excluding "verdict" (:153); retro FORMAT LINT at archive (`research-sdd-archive.sh:270-275`, advisory);
`--use-angle=swiftshader` (`DYNAMIC-SETUP.md:80`); §16 focus-prefix derivation (`verify-state.sh:302-308`,
`lib/focus-prefix.sh`); `[CERT-a]` secondary-source definition (METHODOLOGY:63); §7 engram project convention
(METHODOLOGY:560-583); §10 CREATE / UPDATE-IN-USE (both jace8000 retros decline to re-propose).
Still open from #7876, re-verified: MA-2/OM-2/CS-4 (= I-6); RE-D6/D1-live (= I-7); D3-dyn archive `--focus`; BC2 vs
METHODOLOGY:2298 contradiction needing a decision.

## 5. Operator-only (propose-never-apply; not writer work)
TARGETS.md niagara row 722→759; FOCUSES.md `apis` row hand-fix (also the acceptance evidence for I-5); B727 has no
engram mirror; 5 unmarked retros need review-status markers; qnx6read.py / hdbread.py promote verdicts need a
fixture + decision; two 2026-09-03 retros both self-numbered "(3/3)" — hand-renumber; panccadia TARGETS row
(retros 1→3, md 6→9, maturity `nested corpus` not in legend); COB-IM2 §18 feedback unwired (19 blocks / 0 retros);
BREAKTHROUGHS.md: 1 unindexed (cob-block13.md:35). Also for Cristian: 21 stale `.claude/worktrees/agent-*` and one
untracked orphan `openspec/changes/improve-research-sdd-target-onboarding/` — nobody on the team created them.

## 6. Defect families (recurring pain)
- F1 Concurrent lanes in one checkout / one numbering space — 4 retros + relayed delta + the "(3/3)" collision. Kit
  CLAUDE.md §3 learned it for maintenance; research doctrine has not. Highest recurrence.
- F2 Search-tool zeros read as absence (corpus-nav, `mem_search`, grep on base64 lines). §7 covers shipped
  instruments; nothing extends it to the agent's own recall/search surface.
- F3 Free-form declaration cells no instrument can read — FOCUSES status, retro delta declaration, TARGETS maturity,
  block Type, New-gaps cell. Five substrates, one cause: doctrine before checker.
- F4 Evidence-marker taxonomy under load — `[CERT-a]` ×3 meanings, `[CERT-live]`/`[CERT-hw]` contested twice.
- F5 Sessions with real value but no block (~10/30 retros); §18's trigger is focus-STOP-shaped.
- F6 Retro-template adherence (7/30 uncountable, 2/30 invisible, 5/30 unmarked, 1 in Spanish).

## 7. Suggested first-wave ordering (yield / cost)
- W0 (in flight): I-1 #420.
- W1 doctrine-only, disjoint files, concurrent then ONE quiet-tree gate: W1a METHODOLOGY §7 + §20 (freeze-the-subject,
  engram fallback, quick/document items) ~50 lines; W1b DYNAMIC-SETUP §1c + DEPLOY-WINDOWS-MINIPC.md + tool-registry
  ~60 lines (pure new content); W1c PROMPT-LOOP SYNTHESIS-GUIDE + SECRETS clusters ~50 lines.
- W2 doctrine that must precede instruments: W2a §16 status grammar + block-number allocation + peer-dirty-tree +
  shared-checkout guard (F1 + F3); W2b §18 + retro template countable-delta line; W2c §4 Type grammar + template;
  W2d one §3 marker-taxonomy DECISION (F4).
- W3 instruments (teeth + full-fleet acceptance): I-2 coverage-map; I-3 Type token in verify-block; I-4 sweep-retros
  negative check; I-5 FOCUSES drift checker; I-6 re-probe only.
- DO NOT BUILD: delta-counter regex widening (yield 2 retros); Bayesian saturation (§2.3); journal mode until
  accepted/dismissed; build-n4-module kit items (other repo); corpus-nav.py items (target tooling).

## 8. Pending input
Independent kit diagnosis (tests without teeth, silent-zero incidence, doctrine drift, hook cost) — agent still
running at write time; its findings are appended as §9 when they land.

## 9. Independent kit diagnosis (measured on 4c100d8; full tables in Engram `…/kit-diagnosis` — every count has a command)

### A. Test discipline
- 104 scripts vs 98 `.test.sh` + 2 `.test.mjs`. Scripts with no suite and never named in one: `verify-kit-clean-hook.sh`
  (the only hook wrapper of 7 without a test — CLAUDE.md §5 violation) and `lib/docker_common.py` (6 importers).
- **22 suites silently ignore `--prove-teeth`** (21 `.sh` + `adversarial-verdict.test.mjs`); confirmed empirically: they
  exit 0 under the flag. `run-all.sh` forwards the flag (l.106) and never accounts for it — 5,681 test LOC guarding
  4,304 SUT LOC report green under the mutation gate with zero mutation controls. 78 suites implement teeth (1,935
  labelled mentions).
- Test bloat: 41,195 test LOC / 20,539 script LOC = 2.01×. No shared harness: 75/98 suites hand-roll `ok()/no()`
  (~130 definitions, 4 whitespace variants), 74 hand-roll tmpdir+trap, 12 embed python heredocs. Longest suites:
  verify-registry 2246, verify-state 2149, sweep-retros 1886, research-sdd-status 1330.
- Skip machinery is honest (run-all counts skipped separately; zero-coverage run exits 1) and mostly dormant here.
  `extract-pdf.test.sh` asserts 2 cases against a 200-line SUT. The installer suite is not in the local gate glob
  (CI runs it separately).
### B. Anti-silent-zero incidence
- 172 `|| true` sites / 39 files; 18 benign `command -v`. **11 unguarded sites after a real producer in production
  code / 7 files**: `verify-kit-clean.sh:30-32` (three `git … | grep -c . || true` counters, no test asserts them —
  can print `DIRTY — 0 staged · 0 unstaged · 0 untracked`), `verify-sources.sh:79`, `scan-secrets.sh:127`,
  `sweep-tools.sh:133,148`, `sweep-tools-hook.sh:45`, `verify-tool-catalog-hook.sh:47`, `verify-block.sh:257,260`.
  Three sibling files carry written refusals to do exactly this (`verify-registry.sh:361-363`,
  `verify-tool-catalog.sh:47`, `sweep-breakthroughs.sh:128`) — doctrine known, unevenly applied.
- 8 bare `grep -c` (2 guarded), 22 `| wc -l`, **275 `| head`** and 198 `| grep -q` early-terminating consumers never
  audited as a family. 17/62 production scripts have no `pipefail` — the WARN-only sweep/hook family (documented at
  `sweep-retros.sh:24`) plus `detect-tools.sh` and `lib/tool-env.sh` (undocumented).
### C. Doctrine size and drift
- HOT-CORE (§1,2,3,4,7,8,9,11,17) = 719 lines = 30.5 % of METHODOLOGY, ≈2.4 k tokens per block; §11 (268) + §8 (184)
  are 63 % of it. Four unnumbered sections (`Purpose`, `Dismissed file types`, `3b`, `8b`) total 215 lines outside
  the numbering. METHODOLOGY↔PROMPT-LOOP verbatim overlap: 1 line (hypothesis refuted); 10 of 14 PROMPT-LOOP HARD
  RULE names appear nowhere in METHODOLOGY (operational rules live only in PROMPT-LOOP).
- Dangling `§N`: zero. Dangling `issue #N`: zero (22/22). Exception: `verify-state.sh:294` cites "§263" — a line
  number wearing a `§` (the volatile-telemetry class CLAUDE.md §8 names). `verify-doc-consistency.sh` checks only
  the orphan direction, never "cited §N does not exist".
- **Installed launcher stale**: `~/.claude/skills/research-sdd/SKILL.md` differs from the kit copy in 5 hunks /
  15 lines (missing the §22 rule, the tool-cataloging paragraph, the `target` glossary row, the PROMPT-AUDIT pointer;
  says 21 sections vs 22). No instrument checks the installed copy (`grep '.claude/skills'` over tests/tools/install
  → 0 hits); `verify-doc-consistency.sh` and `skill-twin-parity.test.sh` both report clean on the copy nobody loads.
### D. Toolbelt hygiene
- Registry rows without a script: 0. Scripts never named in `tool-registry.md`: 51/104, of which 15 are top-level
  operator tools (`census-target`, `ensure-remote`, `research-sdd-{init,status,archive}`, `stage-retro`,
  `sweep-{tools,breakthroughs}`, all 5 hooks, `verify-{doc-consistency,tool-catalog}`); nothing audits the
  disk→registry direction.
- `verify-doc-consistency.sh` is the only top-level `toolbelt/*.sh` committed 100644 (same class as #417).
- **Block-file discriminator hand-rolled at 15 sites / 8 scripts** (`research-sdd-status.sh` 5, `research-sdd-archive.sh`
  3, `verify-state.sh` 2, `verify-{registry,corrections,parity}.sh`, `sweep-{retros,breakthroughs}.sh`); `lib/` owns no
  `block_files()` helper; `verify-corrections.sh:26` documents the coupling in a comment.
- `research-sdd-archive.sh:284` hand-rolls a second retro-marker parser (`head -10 | grep '^review-status:'`) divergent
  from `lib/retro-status.sh`, the declared single source of truth.
- `templates/hook-sessionstart.sh` hardcodes `/home/cristian/investigacion/sdd-investigacion/research-sdd/toolbelt/`
  in the artifact meant to be copied to other machines (the class CLAUDE.md §11 declares RESOLVED for TARGETS.md).
### E. SessionStart cost (7 hooks in `.claude/settings.json`; `install/` wires none)
- Total 31.3 s and 26,979 chars (~6.7 k tokens) per session. `sweep-retros-hook.sh` alone: 27.08 s (3 s under its
  own timeout) and 19,799 chars — it dumps all 78 pending retros plus 17 `corpus not found (absent-input)` lines for
  targets absent on this machine. `verify-tool-catalog-hook.sh` emits 0 bytes when clean (indistinguishable from a
  crash).
- `.claude/worktrees/` is not in `.gitignore` → `verify-kit-clean-hook` reports NOT clean permanently (21 stale
  worktrees); its DIRTY trigger counts porcelain lines (3) while the counters count expanded files (27).
### F. Retro pipeline
- Template and counter agree on the canonical heading; real retros use 62 distinct delta-section headings; 58
  recognised. **9 heading forms carry deltas the counter cannot match** (`## Summary of proposed deltas` ×4,
  `## Summary of new deltas proposed` ×2, `## Delta details` ×2, `## 6. PROPOSED kit deltas for the next version (…)`).
- 20 of 78 pending report `~?` (honest WARN). **4 retros report a confident `~0` and all four are false negatives**
  (zero table rows, zero matching heading → the `deltas=0` branch at `sweep-retros.sh:191`); two visibly carry
  kit-facing proposals in prose. One is written in Spanish. This is the §7 false-negative direction verbatim and
  matches §2.1: the fix is a distinct "no delta section found" state, not a wider regex.
### G. Other
TODO/FIXME: 1 (intentional fixture text). `__pycache__` ignored. `run-all.sh` zero-coverage handling rigorous.
Harness parity (Claude/OpenCode/Codex) locked: 20/20.

### Diagnosis top-10 (ranked)
1. 22 suites swallow `--prove-teeth`, `run-all.sh` never reports it. 2. `sweep-retros` confident `~0` on 4 delta-less
retros. 3. Installed SKILL.md 15 lines stale, unchecked by any instrument. 4. SessionStart 31 s / 27 k chars, 86 %/73 %
from one hook. 5. `.claude/worktrees/` not gitignored → permanent false NOT-clean. 6. Block-file discriminator ×15 sites.
7. Divergent retro-marker parser in archive. 8. 11 unguarded `|| true` after real producers. 9. Hook without test +
non-executable verify-doc-consistency. 10. Hardcoded absolute path in `templates/hook-sessionstart.sh`.
