# Design: Promote General Target Tools into the research-sdd Kit

## Technical Approach

Ten capabilities are rebuilt (§8 never-copy) as evidence wrappers following the proven
`corroborate-bacnet` / `corroborate-ifc` pattern. The one decision this phase settles: **where
non-file-artifact tools register**. `tool-registry.md`'s main table is keyed on `Detection (file)`;
probe/interactive/install-scan tools have no `file`-routable input, so they get a dedicated table.
Neither guard constrains shape: `verify-tool-catalog.sh` only whole-word-greps the wrapper NAME
anywhere in `tool-registry.md`; `verify-registry.sh` reconciles `TARGETS.md`, not this file.

## Architecture Decisions

### Decision: Registry placement — new subsection, not a new column

| Option | Tradeoff | Decision |
|---|---|---|
| Add `Input type` column to main table | Perturbs all 18+ rows (each an independent interface claim, §12-3); diff/budget risk | Reject |
| Overload `Detection (file)` with "N/A — live host" | Column stops meaning `file` magic; ambiguous | Reject |
| **New `### Live-probe / install-audit instruments` subsection with its own 5-col table, `Detection (file)`→`Input / trigger`** | Zero churn to file-artifact rows; mirrors existing `### Deliverable / report generation` second-table precedent | **Choose** |

File-artifact promotions take ordinary rows in the MAIN table (unchanged columns). The probe/live-audit
subsection uses its own headers: `| Input / trigger | Detection | Approach | Wrapper | Tested |`
(the main-table `Detection (file)` column becomes `Input / trigger` for probe tools that have no static
file to detect). Row template (main table):
`| <artifact/input> | <detection (file magic)> | <rebuilt approach> | \`<wrapper>.sh\` ([\`<schema>.v1\`](<schema>.v1.md)) | ✅ |`
Row template (probe/live-audit subsection):
`| <host/port/dir> | <live host or install-tree description> | <rebuilt approach> | \`<wrapper>.sh\` ([\`<schema>.v1\`](<schema>.v1.md)) | ✅ |`

### Decision: Evidence-schema doc required for every JSON-emitting wrapper

Any wrapper emitting a versioned `<schema>.v1.json` envelope gets a `<schema>.v1.md` doc (ifc/pcap/bacnet
precedent). Render-only tools whose output is HTML (`px-render`, cf. `render-drawing.sh`) get NO schema
doc; the registry row documents the output format inline. The bacnet pilot is retrofitted with its
missing `bacnet-evidence.v1.md`. Minimal doc template: invocation line · one-line bounds · Trust Boundary
& Accepted Input · Evidence Schema table (Field|Content) · Three-State honesty table (§7) · Caps/Truncation
· Non-Goals · Output Layout.

### Decision: Tool classification (drives which template applies)

| Wrapper (source) | Class | Schema doc | Ext dep? |
|---|---|---|---|
| `corroborate-bacnet` (bacnet-bbmd-verify) | probe (live net) | `bacnet-evidence.v1` (retrofit) | no (stdlib socket) |
| `serial-frame-capture` (mdb_capture) | probe (hardware) | `serial-frame.v1` | no |
| `niagara-security-audit` | install-audit (dir tree) | `niagara-audit.v1` | no |
| `module-find` | install-scan (dir tree) | `module-find.v1` | no |
| `qnx6-read` (qnx6read) | file-artifact (FS image) | `qnx6-evidence.v1` | no |
| `serial-frame-analyze` (mdb_analyze) | file-artifact (frame dump) | `serial-frame.v1` (shared) | no |
| `niagara-hdb-read` (hdbread) | file-artifact (.hdb) | `niagara-hdb.v1` | no |
| `bog-nav` | file-artifact (.bog) | `bog-nav.v1` | no |
| `station-modules` | file-artifact (.bog/station) | `station-modules.v1` | no |
| `palette-lexicon-agents` | file-artifact (palette set) | `palette-lexicon.v1` | no |
| `px-render` | render (.px→HTML) | none (inline) | TBD (see risks) |

Probe/hardware/install-audit rows → new subsection. File-artifact + render rows → main table.

### Decision: Per-wrapper implementation pattern (mechanical, from pilot)

1. 4-line `<name>.sh`: `set -euo pipefail`; resolve `HERE`; `exec python3 "$HERE/<name>.py" "$@"`.
2. `<name>.py`: stdlib only; argparse with `--output`; key-sorted JSON via a `_write` helper.
3. Exit convention — probes: `3` plan-only (no `--allow-live-probe`), `0` ok, `1` negative verdict, `2` op error.
   File-artifact: `2` absent/unreadable/symlink input (no evidence), `1` parse-error (`status:failed`),
   `0` complete (empty-input → `status:complete` with zero-count that proves the driver looked, §7).
4. `<name>.test.sh` under `tests/` with ≥1 mutation control (guard/parse removal goes red under
   `--prove-teeth`); the suite MUST print a teeth banner matching `^\s*(--|==)\s*teeth\b` at runtime
   so `run-all.sh` recognizes it; shellcheck-clean.
5. Add the registry row; add schema doc (if JSON); add `INSTALLED-TOOLS.md` row ONLY on a new external dep.

## Data Flow

    input (file | host | dir | port) ─→ <name>.sh ─→ python3 <name>.py
        (probe: --allow-live-probe gate) ─→ key-sorted <schema>.v1.json in --output
                                            └─→ three-state exit code

## Threat Matrix

Generic git/PR rows are **N/A** (no VCS/PR automation, no doc-path classification). Applicable
process-integration boundaries this change introduces:

| Boundary | Applicability | Design response | Planned RED test |
|---|---|---|---|
| Live-network / hardware action gate | Applicable (bacnet, serial-capture) | Default run plan-only, exit 3, zero I/O until `--allow-live-probe` | Guard-exit mutant goes red OFFLINE (exit 3 → 0 detected without live I/O) |
| Untrusted file input (symlink/traversal) | Applicable (qnx6, hdb, bog, px, serial-analyze) | Stage read-only, reject symlink via `O_NOFOLLOW`, exit 2 | Symlink/absent input → exit 2, no evidence |
| Subprocess argv (`.sh`→python3) | Applicable | Fixed `exec python3 "$HERE/<name>.py" "$@"`; no shell interpolation of input | shellcheck -S warning zero warnings |
| Install-tree scan bounds | Applicable (audit, module-find) | Bounded walk, no writes, three-state on empty/absent dir | absent/empty/no-match distinct labels |

## Migration / Rollout

No migration. Each wrapper is additive. **PR order (all serialize on `tool-registry.md`, §12-7):**
PR1 = bacnet retrofit (row + schema doc) — establishes the new subsection every later probe row reuses
(§12-1, section owned by first merger). Then Tier 1: qnx6-read → serial-frame (analyze+capture, shared
codec). Then Tier 2: niagara-hdb-read → niagara-security-audit → module-find → bog-nav → station-modules
→ palette-lexicon-agents → px-render. Each its own auto-chained ~400-line PR, rebased on the prior.

## Open Questions

- [ ] `px-render` HTML generation: confirm stdlib-only is feasible; if it needs a templating dep, add an
  `INSTALLED-TOOLS.md` row and reclassify.
- [ ] Confirm each source tool's real input shape against the corpus during apply (fleet acceptance, §7)
  before finalizing its schema fields.
