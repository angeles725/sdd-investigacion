# Kit session 2026-10-05 — target wiring (W3), reinstall (R1), follow-up chain, needs-review triage, audit

Engram mirror: `odd/kit-session-2026-10-05/tasks` (project sdd-investigacion).
Operational resume file (agent ids, worktrees, ship scripts): scratchpad `RESUME-2026-10-05.md` of session 07bf93fb.

## Objective
Wire every present target (W3), reinstall the harness homes (R1), close the approved follow-up queue, triage the
34 `status:needs-review` issues with the maintainer two at a time, then "fix everything" left open by the day's work,
audit mechanisms that exist but are not wired (overlaps, interaction risks) and act on the recommendations.

## Authorization
Maintainer (2026-10-05): ODD + RDD all granted; commit, push, PR, PR view, issues and merge authorized; gentle-ai
review prompts granted; chain automatically; "corrige todo lo que tengas que corregir"; "checa todos los mecanismos
que todavía no estén conectados … propón mejoras … sigue con tu recomendación, no me preguntes". Triage decisions
are the maintainer's (recorded per issue as a "Maintainer decision 2026-10-05" comment).

## Constraints
- Kit CLAUDE.md: harness-worktree writers on origin/main, disjoint file sets, strict TDD + teeth, ~400 lines/PR.
- HOT-CORE budget (`hotcore-budget` T7) is 920/920: never grow §1 §2 §3 §4 §7 §8 §8b §9 §11 §17 (lines OR bytes); never rewrap to fit.
- RDD cap ~3 rounds; destructive/correctness WARNINGs get one extra surgical fix; remainder filed as follow-up.
- PR bodies must not reference closed/merged-into issues (Check Issue Has status:approved fails); PRs need a `type:*` label.
- Doctrine describes merged code only; every behavioural sentence maps to a pinning test.
- Never modify or push target corpora beyond the approved `--wire` setup; never update the shared checkout while a research session is live.

## Delivery strategy
`auto-chain`, `stacked-to-main` (one PR per work unit against main).

## Tasks (route: D = delegated writer, I = inline)
### Rollout
- [x] W3 — shared checkout ff to 6aec1dbb; `research-sdd-init.sh --wire` on 17 targets (kit repo excluded), all rc=0. All 17: return-token gate + pkill-guard. SessionStart on 5; 12 skipped (unadapted `<SUBJECT>`). Route I.
- [x] R1 — `research-sdd-install.sh` all harnesses rc=0; `--verify` match for claude/pi/gentle-shell. Route I.
- [x] W3b — shared checkout ff to 8ccf4d4e (#1831) with no live research session; `--wire` re-run on the 17 targets: all `== done ==`; stale-kit drift hook registered 17/17; `.research-sdd/plan/` added to `.gitignore` 17/17 (left UNCOMMITTED in each target repo for the maintainer); vendor-leak 14 PRIVATE / 2 NO-REMOTE / 1 SUBDIR (no public repo → no pre-push written). Backups: scratchpad `w3b-backup/`. Route I.
- [ ] W3c — adapt `<SUBJECT>` in `research-protocol.sh` for the 12 targets (human/judgment, per target).

### Merged — morning wave (before compaction)
F #1747→#1777 · C #1766→#1779 · E #1770/#1771→#1783 · H1 #1711 s2→#1781 · B #1757→#1778 · A #1752/#1773→#1785 ·
D #1768→#1791 · H2 #1711 s3→#1794 · I2 #1271 doc→#1786 · U3 lint-substitution CI→#1788 · U2 sweep-all drift→#1789 ·
U4 verify-corrections advisory→#1803 · I1 #1277 s2→#1801 · G #1709 s2 regressed→#1806 · D1 doctrine catch-up→#1809 ·
triage: #1613→#1802 · #1606→#1795 · #1173→#1799 · #1394/#1388→#1798 · #1389→#1792 · #1328→#1796 · #1178→#1805.

### Merged — afternoon wave (after compaction)
- [x] U1 #1787 item 1 + #1271 pre-push → #1807 (lint FORM-A fix inline).
- [x] J7 #1638 → #1810 (suite summary format fix inline).
- [x] F8 #1711 jq args → #1813 (reviewer's jq `as`-precedence CRITICAL was REAL on CI's older jq; local jq 1.8.2 hid it; parenthesized).
- [x] F5 #1797 → #1815 (exported `MUTANT_SYNTAX=none` leak found → #1814).
- [x] J6 #1259 → #1822 · F2 #1780 → #1823 · F3 #1782 → #1825.
- [x] F7 approved doctrine (12 issues) → #1824.
- [x] W2 #1817 verify-doc-consistency in CI → #1826.
- [x] W1 #1816 SessionStart budget (13.1k → ~6.5k chars, frozen-fixture test) → #1827.
- [x] F1 #1784 + #1811 → #1828 (SC2120 false positive documented).
- [x] F4 #1793 → #1829.
- [x] Q2 #1277 follow-ups + clean-warn load flake → #1830.
- [x] Q1 #1800 + #1804 → #1831 (follow-up #1834).
- [x] D2 #1819 + pending doctrine sections → #1832.
- [x] R1 #1818 slice 1 (resolver lib + archive/verify-state/verify-registry) → #1833.
- [x] F6 #1790 clause binding (false FAILs 18→6, 10 true findings unmasked) → #1838 (refs #1790; backlinks proposed as a comment; follow-ups #1835 #1840).
- [x] S2 #1818 slice 2 (status.sh) → #1839.

### In flight
- [ ] V1 #1820 — `lib/gh-visibility.sh` for init/status/ensure-remote + `GIT_OPTIONAL_LOCKS=0` in verify-kit-clean (writer).

### Backlog (filed, not started)
#1214 (rule pack under #1365) · #1821 (small unwired items) · #1834 · #1835 · #1836 · #1840 ·
needs-review for the maintainer: #1812 (closure-evidence rule → shipped=0), #1814 (MUTANT_SYNTAX export), #1837 (`--root/--focus --next` scope) ·
#1790 step 4 (promote verify-corrections to an archive gate, after #1835).

### Needs-review triage (DONE — 0 left at triage time)
Approved (22): #1613 #1638 #1606 #1173 #1208 #1394 #1388 #1389 #1259 #980 #1328 #1214 #1178 #1175 #1185 #1186 #1187 #1179 #1096 #1385 #1542 #1094.
Merged-into (4): #1198→#1606 · #1189→#1173 · #1390→#1389 · #1607→#1548. Already done (2): #1295 #1246.
Dismissed/deferred (6): #896 #1180 #1610 #1255 #1256 #1262.

## Audit 2026-10-05 (read-only, origin/main 99d72bf1) → issues
#1816 SessionStart budget (merged #1827) · #1817 doc-consistency unwired (merged #1826) · #1818 state resolver
(merged #1833 + #1839) · #1819 envelope-counter doctrine (merged #1832) · #1820 gh visibility probes (in flight) ·
#1821 small items (backlog).

## Findings worth keeping
- Verify reviewer claims by execution on the SAME environment as CI: a local refutation (jq 1.8.2) was wrong; two reviewer claims were refuted correctly with code evidence (catalog sentinel existed; `here` uses the same `dirname "$0"`).
- `ship.sh` passed GitHub default labels (bug/enhancement/documentation) → "Check PR Has type:* Label" failed; now mapped to `type:*`.
- lint-substitution FORM-A (unquoted `${v//pat/$x}` replacement) was introduced twice by writers → keep it in every writer's verification list.
- Parallel writers editing the same tool-registry row conflict at merge; with force-push blocked, merge origin/main + a sentence-level 3-way merge resolves it without losing either side.
- Timing tests: derive ceilings from a stall budget (bound + 2×host stall + slack) and make slow children outlive them (#1825, #1830); remaining flakes #1836.
- zsh: `${PIPESTATUS[0]}` is empty — use `${pipestatus[1]}`.
- Doc-only PRs: map each behavioural sentence to a pinning test; delete unpinned ones.

## Close
Merged today: the morning wave listed above, plus 18 after compaction (#1807 #1810 #1813 #1815 #1822 #1823 #1824 #1825 #1826 #1827
#1828 #1829 #1830 #1831 #1832 #1833 #1838 #1839). Remaining: V1 #1820 in flight; W3c manual; backlog above.

## Next step
Ship V1 (#1820) through RDD → merge-gate; then the next session starts from the backlog (W3c per target, #1835,
#1836, #1834/#1840, maintainer decisions on #1812/#1814/#1837).
