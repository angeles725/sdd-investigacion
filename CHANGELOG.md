# Changelog

Notable changes to the research-sdd kit. Each entry cites the merged pull request number. History before v1.1.0 lives in the [GitHub releases](https://github.com/angeles725/sdd-investigacion/releases).

## [1.2.0] - 2026-10-04

269 PRs merged since v1.1.0 (#863 to #1688). Main themes: a hardened retro/issue-seeding pipeline (retro-gate, stage-retro-issues, reconcile-issues), roughly two dozen new or promoted toolbelt instruments, a kit-wide migration of mutation-test suites to the shared `lib/mutant.sh` helper with a `--require-teeth` gate, a parallel `run-all -j` mode now used by CI, a merge-gate for delivery, per-model prompt profiles at install time, and a continued doctrine sweep over METHODOLOGY and PROMPT-LOOP.

### Breaking / removed
- Dropped OpenCode harness support (#978).
- Dropped the Reasonix and Codex harnesses from the installer (#1474). Supported harnesses are now Claude Code, Pi and gentle-shell.

### Doctrine (METHODOLOGY, PROMPT-LOOP, SKILL, templates)
- Phase-3 doctrine deltas applied across METHODOLOGY and PROMPT-LOOP in batches (#868, #869, #872, #873, #1302); fleet-delta batches M2 evidence and sources, M3 verification contract, M5 live-write hygiene (#1486, #1489, #1494); hilton, niagara5 and Pancaddia retro deltas (#1115, #1428); doctrine from the 2026-10-04 triage plus the Java decompile fidelity matrix (#1643).
- New rules: offensive/dual-use execution scope and authorization policy (#874); possibility-first rule with route-ladder lint and corpus sweep (#1278); stretch goal at bootstrap, unblock plan per wall, possibility audit before STOP (#1308); campaign continuation and campaign-level seal evidence (#997, #1117).
- ISSUES-DUE loop done-gate contract (#878); section references and range fixes (#882); delta heading is matched literally (#899); section 8b moved to HOT-CORE with a load-tier parity and size guard (#1009).
- Prompt audit waves A and B: single seal rule, smaller HOT-CORE, situational appendix for delegation and model-tier rules, evidence-note trimming (#995, #1004, #1027, #1164, #1317).
- SKILL and templates: propose-never-apply for tool cataloging and /loop cadence and teardown rules (#990); SessionStart template, SOURCES row and placeholder updates (#1001, #1477); GNU parallel catalog and concurrency caps (#1465); fetch-doc and appendix wording (#1362); merge-gate and lint-block doctrine wiring (#1368); retro-seeding documented as Claude-Code-only (#1138); RETRO-DUE note sync (#863); tool docs for recent sessions (#1594, #1667).

### New instruments
- `lint-block.sh` generic block linter with reasoned waivers, `--audit`, ephemeral-path evidence check and `--pack` loader for jvm, multi-version and native-binary packs (#1366, #1449, #1518).
- `scan-vendor-leak.sh` vendor-code leak guard (#1523); `java-fidelity-experiment.sh` round-trip decompilation fidelity experiment (#1525); `clean-check.sh` (#1528); `plan-review-slices.sh` (#1530); `resume-state.sh` and `resume-render.sh` (#1533, #1572); `state-update.sh` for envelope counters (#1535); `n4-type-catalog` static slot catalog (#1512).
- `score-loop-transcript.sh` eval scorer (#1011); `focus-partition-audit` (#1127); backlog row-drift checker with a verify-state WARN (#1424); remote-visibility drift check and `pkill -f` PreToolUse guard (#1497); empty-input digest guard (#1498).
- `research-sdd-status`: `--next` ISSUES-DUE done-gate with batched coverage query, campaign queue and stall signal, Stop-hook wiring self-report, `--next --focus` scoping and propose-only `migrate-backlogs` (#876, #880, #1006, #1120, #1658).
- verify-block resolves decompiled-tree citations via `$SOURCE_ROOT` (#871) and gains a staged ephemeral-evidence check with a scripts manifest (#1662); class-file facts (major version, LVT, resugar risk) in corroborate-java and decompile-java (#1664).

### Retro and issue pipeline (retro-gate, stage-retro-issues, reconcile-issues, sweep-retros)
- retro-gate Stop hook auto-seeds backlog-first issues (#865) and logs every Stop branch (#1360). Hardening: seeder return code and summary parsing, absent-input state, symlinked-target false ALLOW, NUL-safe candidates, kill-safe cleanup, nested worktree and CATALOG.md handling (#930, #937, #953, #1300, #1310, #1353, #1402, #1420, #1443) and a typed unknown on a missing seeder summary (#1685).
- One retro marker scope and parser across reconcile, seeder, retro-gate and sweep-retros; markers outside scope fail closed (#966, #977, #1098, #1122, #1129, #1130, #1305).
- Seeder: dedup covers closed issues and fails closed, refuses on fetch failure, kit repo targeted explicitly, nested-corpus name resolution, unknown-outcome re-check (#944, #975, #1029, #1042, #1046, #1092, #1286, #1357, #1493); retro issue short-title and shipped-reason handling (#1520); reconcile-issues and retro-status parsing fixes, including closed issues citing a retro reading as shipped (#870, #886, #1315, #1370, #1403, #1567, #1684).
- sync-state and derive_blocked fixes, including keeping a higher declared gap counter (#898, #900, #907, #913, #982, #1306, #1314, #1351, #1408, #1682); sweep-retros `--no-renames` defences (#1400, #1441).

### Toolbelt fixes and hardening
- Anti-silent-zero fixes: verify-registry absent paths and marker checks, verify-block resolved N of M reporting and target-root cites, sweep hooks never silent, verify-sources root-form rows and annotated File cells (#887, #968, #972, #994, #1119, #1141, #1422, #1485, #1508, #1683).
- decompile-java timeout, unit isolation, coverage sweep and layouts (#1316, #1359, #1410); fetch-doc evidence-preserving re-fetch, cancel and no silent overwrite (#1312, #1355, #1406); scan-secrets and archive committed-content scans, ensure-remote hardening (#999, #1010); doc-consistency anchors (#1318).
- pipefail SIGPIPE race removed from production scripts and portable here-string producers (#1143, #1467); substitution-quoting and portability fixes (#922, #932, #1142); skill-drift surfacing and Stop-hook detection off the git root (#928, #1140); verify-registry companion check (#1041); verify-state hook inspection and campaign status fixes (#1012, #1028); sweep-breakthroughs pointers (#918, #947, #1680); verify-cd-physical cd-assignment forms (#1681).
- Second-round advisory refactors and fixes for the new instruments (#1501, #1503, #1504, #1539, #1546, #1549, #1554, #1559, #1560, #1561, #1562, #1573, #1620, #1668, #1670, #1677, #1679); score-loop-transcript C4 no longer passes vacuously (#1139).
- Remaining fixes: SC-CROSS-CHECK value extraction (#884), #1636 (strict vendor-leak CI gate, refuses subdirectory wiring) and #1642 (jvm-callgraph offline build uses the bootstrap settings, typed slow-lane SKIPs).

### Install, init and harness support
- Install-time per-model prompt profiles: `render-profile.sh`, profile selection, invariants drift guard, continuation-cadence slot (#1016, #1022, #1024, #1097).
- `/research-sdd` for Pi and gentle-shell (#1470); `research-sdd-init` auto-wires Stop/SessionStart hooks, the pkill-guard and the vendor-leak guard on PUBLIC remotes, with a `--document` scaffold variant, repair and refusal rules for `--wire`, and safe scaffolding (#864, #998, #1040, #1091, #1151, #1374, #1510, #1551, #1568); skill-deploy failure clears `_baseline_ok` (#988); skill-drift fix-up (#952).

### Test infrastructure and mutation teeth
- Shared `lib/mutant.sh` helper with `mutant_chain` and `mutant_tooth`, debug opt-in, rc 2/6 teeth, and shared cleanup, python-mutant and count-once helpers (#1298, #1423, #1435, #1481, #1495, #1671).
- Migration of mutation controls to `lib/mutant.sh` across the suite corpus: #1405, #1407, #1411, #1414, #1417, #1425, #1440, #1575, #1578, #1582, #1586, #1587, #1590, #1592, #1596, #1598, #1604, #1605, #1627, #1631, #1632, #1633, #1634, #1635; real SUT mutants for detonate-exec and trace-exec (#1628).
- `run-all.sh`: traverses `research-sdd/install/tests`, kit-tree hermeticity check, opt-in `-j N` parallel mode with leak attribution, per-run TMPDIR root with per-suite leftover attribution, `--require-teeth` gated on helper use with waivers, a teeth-helper lint that sees awk-regex and python-bodied suites, and removal of stale waivers (#1144, #1298, #1376, #1490, #1515, #1537, #1569, #1646, #1649, #1687).
- Flake and hermeticity fixes: pipefail SIGPIPE removal across suites with a shared lint (#1445, #1447, #1451, #1453, #1458, #1473, #1162), hermetic PATH and stubs (#909, #910, #921, #946), temp-leak cleanup (#1118, #1564, #1669), ci-path-filter coverage (#1482), install-suite isolation (#1484), merge-gate mutants (#1409), the EN4 end-to-end enforcement harness (#875) and fixtures that had silently disabled SC-CROSS-CHECK (#885).

### CI and delivery
- `merge-gate` refuses to merge a review-due head before its review, and on pending, failed or missing CI checks, with gh stderr surfaced (#1364, #1432, #1436).
- CI: raised toolbelt-tests timeouts, doc-consistency suites run on doctrine-only changes, and the toolbelt suite now runs with `run-all -j 4` and requires parallel mode (#1372, #1438, #1456, #1673).

### Registry and records
- TARGETS.md refreshes and registrations (#916, #1133, #1137, #1147, #1170, #1323); retro normalization (#883).
- ODD session records and feature documents (#925, #951, #985, #1008, #1036, #1101, #1149, #1168, #1322, #1378, #1431, #1476, #1506, #1553, #1612, #1666, #1688).

## [1.1.0] - 2026-09-19

Backlog-first delta tracking plus a doctrine sweep.
- Backlog-first delta tracking: a delta is born as an open GitHub issue at proposal time, with `stage-retro-issues.sh` (retro deltas to issues) and `reconcile-issues.sh` (marker and issue coverage audit); the existing fleet backlog was fully triaged.
- Doctrine sweep over METHODOLOGY, PROMPT-LOOP and SKILL: anti-complacency and ACTIVE-CLOSE audit, FRONTIER investigation mode, return-contract continuation token, visual/geometric oracle, new block types, and SKILL.md `/loop` execution mode.
- Toolbelt fixes and hardening across verify-block, verify-state, research-sdd-status, research-sdd-archive, decompile-native, qnx6-read and others, plus 12 new tool-registry rows.
- Full notes: [v1.1.0 release](https://github.com/angeles725/sdd-investigacion/releases/tag/v1.1.0).

<!-- coverage: 269 PRs classified, 0 unclassified: [] (count = squash-merge commits on v1.1.0..origin/main whose subject ends in "(#N)", measured with `git log v1.1.0..origin/main --format=%s | grep -c '(#'`; every such trailing PR number appears in the 1.2.0 section) -->
