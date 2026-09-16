# Tasks: Promote General Target Tools into the research-sdd Kit

Skill: `~/.claude/skills/chained-pr/SKILL.md` (gentle-ai-chained-pr)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~300–400 per PR × 10 PRs |
| 400-line budget risk | Low (per PR) |
| Chained PRs recommended | Yes |
| Suggested split | PR1→PR2→PR3→PR4→PR5→PR6→PR7→PR8→PR9→PR10 |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: Low

**Serialization note**: all PRs touch `tool-registry.md` → strict serial order (§12-7).

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|----|----------------------|-----------------|-------------------|
| 1 | bacnet registry subsection + schema doc | PR1 | `bash research-sdd/toolbelt/tests/run-all.sh` | N/A (docs + row only) | revert `tool-registry.md` + delete `bacnet-evidence.v1.md` |
| 2 | qnx6-read wrapper | PR2 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./corroborate-qnx6-read.sh <img>` against `$RESEARCH_HOME` corpus (read-only) | delete `qnx6-read.{sh,py,test.sh}` + row |
| 3 | serial-frame-analyze + serial-frame-capture | PR3 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./serial-frame-analyze.sh <dump>` against corpus (read-only) | delete both wrappers + tests + shared schema doc |
| 4 | niagara-hdb-read wrapper | PR4 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./niagara-hdb-read.sh <file.hdb>` against corpus (read-only) | delete wrapper + test + row |
| 5 | niagara-security-audit wrapper | PR5 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./niagara-security-audit.sh <dir>` against corpus (read-only) | delete wrapper + test + row |
| 6 | module-find wrapper | PR6 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./module-find.sh <dir>` against corpus (read-only) | delete wrapper + test + row |
| 7 | bog-nav wrapper | PR7 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./bog-nav.sh <file.bog>` against corpus (read-only) | delete wrapper + test + row |
| 8 | station-modules wrapper | PR8 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./station-modules.sh <station>` against corpus (read-only) | delete wrapper + test + row |
| 9 | palette-lexicon-agents wrapper | PR9 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./palette-lexicon-agents.sh <dir>` against corpus (read-only) | delete wrapper + test + row |
| 10 | px-render wrapper | PR10 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `./px-render.sh <file.px>` against corpus (read-only) | delete wrapper + test + row |

---

## PR1: corroborate-bacnet Retrofit

Branch `feat/corroborate-bacnet` — wrapper already built and gated. Remaining work only.
Spec: Registration (§4), evidence-schema doc (design AD2).

- [x] 1.1 Add `### Live-probe / install-audit instruments` subsection to `research-sdd/toolbelt/tool-registry.md` with 5-col table (`Input / trigger | Detection | Approach | Wrapper | Tested`)
- [x] 1.2 Add `corroborate-bacnet` row in that subsection; Input/trigger = `host:port`; Detection = live BACnet host
- [x] 1.3 Write `research-sdd/toolbelt/bacnet-evidence.v1.md`: invocation · one-line bounds · Trust Boundary & Accepted Input · Evidence Schema table · Three-State honesty table · Caps/Truncation · Non-Goals · Output Layout
- [x] 1.4 Gate: `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` → zero warnings; `bash research-sdd/toolbelt/tests/run-all.sh` → all pass

---

## PR2: qnx6-read (file-artifact; main table)

Spec: Rebuild-Not-Copy, Three-State Honesty, TDD+Mutation, Registration, Fleet-Validated Acceptance.

- [x] 2.1 Confirm `qnx6read` real input shape against `$RESEARCH_HOME` corpus (read-only); record field names for schema before writing `.py`
- [x] 2.2 Write `research-sdd/toolbelt/qnx6-read.sh`: `set -euo pipefail`; resolve `HERE`; `exec python3 "$HERE/qnx6_read.py" "$@"` (shipped name: `qnx6_read.py`, not `corroborate-qnx6-read.py`)
- [x] 2.3 Write `research-sdd/toolbelt/qnx6_read.py`: stdlib only; argparse `--output`; `O_NOFOLLOW` symlink-reject on input → exit 2; output uses `O_CREAT|O_EXCL|O_NOFOLLOW` (refuses symlinks and pre-existing files → exit 2); absent-input exit 2; three-state exit (2=absent/unreadable/symlink, 1=parse-or-walk-error, 0=ok); key-sorted JSON; truncated:true when depth cap fires; visited-inode set prevents cyclic-dir OOM
- [x] 2.4 RED+GREEN: wrote `research-sdd/toolbelt/tests/qnx6-read.test.sh`; with a teeth banner matching `^\s*(--|==)\s*teeth\b`; 12 cases including walk-error recovery (T8), struct.error recovery (T9), cyclic-dir termination (T10), depth-cap truncated flag (T11), output-symlink refusal (T12); T4 checks exact path value; T6 checks extracted byte content; 4 mutation controls (M1-M4)
- [x] 2.5 GREEN: all 12 tests pass; M1 (O_NOFOLLOW removal) + M2 (magic inversion) + M3 (write-zero) + M4 (path-slash drop) all confirmed red under `--prove-teeth`
- [x] 2.6 Added `qnx6-read` row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = magic `0x68191122` at partition offset `+0x2000` (auto-detected, not by extension)
- [x] 2.7 Wrote `research-sdd/toolbelt/qnx6-evidence.v1.md` (same template as 1.3); documents extract exit codes, truncated field, symlink type note, depth cap visibility; dropped target-specific offset example
- [x] 2.8 Gate: shellcheck zero warnings; run-all.sh all pass; --prove-teeth all pass; verify-tool-catalog exit 0. Fleet acceptance: read-only run on `~/niagara-research/local-sd-image/jace-sd.img` at partition offset 135266304 → 697 entries, parity with the source tool's walk()

---

## PR3: serial-frame-analyze + serial-frame-capture (shared serial-frame.v1; analyze→main table, capture→new subsection)

Spec: all spec reqs; plus Read-Only Default Gate (spec §2) for `serial-frame-capture` (hardware probe).

- [x] 3.1 Confirm `mdb_analyze` + `mdb_capture` real input/trigger shapes against corpus (read-only); document shared schema fields
- [x] 3.2 Write `research-sdd/toolbelt/serial-frame-analyze.sh` (4-line wrapper)
- [x] 3.3 Write `research-sdd/toolbelt/serial-frame-analyze.py`: file-artifact; `O_NOFOLLOW`; three-state exit; key-sorted JSON
- [x] 3.4 Write `research-sdd/toolbelt/serial-frame-capture.sh` (4-line wrapper)
- [x] 3.5 Write `research-sdd/toolbelt/serial-frame-capture.py`: probe; `--allow-live-probe` gate → exit 3 plan-only without flag, zero I/O; three-state exit
- [x] 3.6 RED: `research-sdd/toolbelt/tests/serial-frame-analyze.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; absent/empty/no-match + symlink cases fail before impl
- [x] 3.7 RED: `research-sdd/toolbelt/tests/serial-frame-capture.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; plan-only default (exit 3) + no I/O asserted; guard-exit mutant (exit 3 → 0) detected offline
- [x] 3.8 GREEN + mutation controls both suites: remove symlink-guard (analyze) and remove `--allow-live-probe` guard (capture) → each exits non-zero
- [x] 3.9 Add `serial-frame-analyze` row to main table; add `serial-frame-capture` row to `### Live-probe / install-audit instruments` subsection in `research-sdd/toolbelt/tool-registry.md`
- [x] 3.10 Write `research-sdd/toolbelt/serial-frame.v1.md` (shared schema doc for both wrappers)
- [x] 3.11 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`
- [x] 3.12 FABLE correction: BLOCKER-1 (§7 garbage→status:failed), MAJOR-1 (M7 baseline T13), MINOR-5 (M5 poly-only sed), NIT-2 (M6 message 0x2022), MINOR-2/3/4 (doc no-data/--log/port-fail), NIT-1 (doc cap 1001)

---

## PR4: niagara-hdb-read (file-artifact; main table)

- [x] 4.1 Confirm `hdbread` real input shape against corpus (read-only); document schema fields
- [x] 4.2 Write `research-sdd/toolbelt/niagara-hdb-read.sh` (4-line wrapper)
- [x] 4.3 Write `research-sdd/toolbelt/niagara-hdb-read.py`: file-artifact; `O_NOFOLLOW`; three-state exit; key-sorted JSON
- [x] 4.4 RED + GREEN: `research-sdd/toolbelt/tests/niagara-hdb-read.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; mutation control (symlink-guard removal → non-zero)
- [x] 4.5 Add row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = `.hdb`
- [x] 4.6 Write `research-sdd/toolbelt/niagara-hdb.v1.md`
- [x] 4.7 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`

---

## PR5: niagara-security-audit (install-audit; new subsection)

- [x] 5.1 Confirm real dir-tree input shape against corpus (read-only); document audit schema fields
- [x] 5.2 Write `research-sdd/toolbelt/niagara-security-audit.sh` (4-line wrapper)
- [x] 5.3 Write `research-sdd/toolbelt/niagara-security-audit.py`: install-audit; bounded walk; no writes; three-state exit; key-sorted JSON
- [x] 5.4 RED + GREEN: `research-sdd/toolbelt/tests/niagara-security-audit.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; absent/empty/no-match distinct labels; remove the bounded-walk/symlink guard → confirm non-zero under --prove-teeth
- [x] 5.5 Add row to `### Live-probe / install-audit instruments` subsection in `research-sdd/toolbelt/tool-registry.md`; Input/trigger = dir tree
- [x] 5.6 Write `research-sdd/toolbelt/niagara-audit.v1.md`
- [x] 5.7 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`

---

## PR6: module-find (install-scan; new subsection)

- [x] 6.1 Confirm real dir-tree input shape against corpus (read-only)
- [x] 6.2 Write `research-sdd/toolbelt/module-find.sh` (4-line wrapper)
- [x] 6.3 Write `research-sdd/toolbelt/module-find.py`: install-scan; bounded walk; no writes; three-state exit; key-sorted JSON
- [x] 6.4 RED + GREEN: `research-sdd/toolbelt/tests/module-find.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; absent/empty/no-match distinct; mutation control
- [x] 6.5 Add row to `### Live-probe / install-audit instruments` subsection in `research-sdd/toolbelt/tool-registry.md`; Input/trigger = dir tree
- [x] 6.6 Write `research-sdd/toolbelt/module-find.v1.md`
- [x] 6.7 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`

---

## PR7: bog-nav (file-artifact; main table)

- [x] 7.1 Confirm `.bog` real input shape against corpus (read-only); document schema fields
- [x] 7.2 Write `research-sdd/toolbelt/bog-nav.sh` (4-line wrapper)
- [x] 7.3 Write `research-sdd/toolbelt/bog_nav.py`: file-artifact; `O_NOFOLLOW`; three-state exit; key-sorted JSON
- [x] 7.4 RED + GREEN: `research-sdd/toolbelt/tests/bog-nav.test.sh` with teeth banner; 4 mutation controls (M1-M4) all detected
- [x] 7.5 Add row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = `.bog`
- [x] 7.6 Write `research-sdd/toolbelt/bog-nav.v1.md`
- [x] 7.7 Gate: shellcheck 0; run-all.sh 2764/0; prove-teeth 2764/0; verify-tool-catalog 0; fleet 4 bogs

---

## PR8: station-modules (file-artifact; main table)

- [x] 8.1 Confirm station dir/file input shape against corpus (read-only)
- [x] 8.2 Write `research-sdd/toolbelt/station-modules.sh` (4-line wrapper)
- [x] 8.3 Write `research-sdd/toolbelt/station-modules.py`: file-artifact; `O_NOFOLLOW`; three-state exit; key-sorted JSON
- [x] 8.4 RED + GREEN: `research-sdd/toolbelt/tests/station-modules.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; mutation control
- [x] 8.5 Add row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = `.bog/station`
- [x] 8.6 Write `research-sdd/toolbelt/station-modules.v1.md`
- [x] 8.7 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`

---

## PR9: palette-lexicon-agents (file-artifact; main table)

- [x] 9.1 Confirm palette-set input shape against corpus (read-only)
- [x] 9.2 Write `research-sdd/toolbelt/palette-lexicon-agents.sh` (4-line wrapper)
- [x] 9.3 Write `research-sdd/toolbelt/palette-lexicon-agents.py`: file-artifact; `O_NOFOLLOW`; three-state exit; key-sorted JSON
- [x] 9.4 RED + GREEN: `research-sdd/toolbelt/tests/palette-lexicon-agents.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; mutation control
- [x] 9.5 Add row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = palette set
- [x] 9.6 Write `research-sdd/toolbelt/palette-lexicon.v1.md`
- [x] 9.7 Gate: shellcheck zero warnings; `run-all.sh`; `run-all.sh --prove-teeth`

---

## PR10: px-render (render; main table; NO schema doc)

Open question (design §OQ1): confirm stdlib-only feasibility; add `INSTALLED-TOOLS.md` row if an external dep is required.

- [x] 10.1 Confirm `.px` real input shape against corpus (read-only); verify stdlib-only HTML generation feasible
- [x] 10.2 Write `research-sdd/toolbelt/px-render.sh` (4-line wrapper)
- [x] 10.3 Write `research-sdd/toolbelt/px-render.py`: render; `O_NOFOLLOW`; three-state exit; output HTML (no JSON envelope, no schema doc)
- [x] 10.4 RED + GREEN: `research-sdd/toolbelt/tests/px-render.test.sh` with a teeth banner matching `^\s*(--|==)\s*teeth\b`; symlink-reject + output-guard mutation controls
- [x] 10.5 Add row to main table of `research-sdd/toolbelt/tool-registry.md`; Detection = `.px`; document output format inline in row
- [x] 10.6 stdlib-only confirmed (no external dep); no INSTALLED-TOOLS.md row required
- [x] 10.7 Gate: shellcheck zero warnings; run-all.sh 118/0; prove-teeth 118/0; fleet 19/20 rendered (1 exit1: no CanvasPane, expected); §9 clean
