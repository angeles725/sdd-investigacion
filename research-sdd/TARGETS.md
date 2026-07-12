# Research-SDD — Targets Registry

This file is the **master registry of the 15 research targets** of the Research-SDD loop.
Each target is a system under reverse engineering / documentation. The loop uses this table to:

1. Decide whether it **continues** an existing corpus or **bootstraps** a new one (Maturity column).
2. Pick the correct **toolbelt wrapper** based on the predominant artifact.
3. Reference the existing corpus language as a historical fact (it does NOT change generation).

> Language policy: the loop writes blocks in **English by default**. **Exception (user-approved, per
> target):** a target with an established corpus in another language MAY be kept in that language for
> continuity when the user approves it — marked in the "Corpus language" column as **APPROVED override**.
> Currently approved: **logosoft → Spanish**. The column otherwise records the existing corpus language
> as a fact only; just an APPROVED override actually changes the generation language.

Evidence convention:

- `[CERT]` — verified by running commands (`profile-target.sh`, `find`, `file`, `ls`, `head`).
- `[INFER]` — deduced without confirming the real artifact (binary not present or `file` not run on it).

Maturity:

- **mature** — large corpus of `.md` blocks + active loop hook. The loop **continues**.
- **intermediate** — substantial corpus or tooling, but missing hook and/or git; partial analysis.
- **incipient** — almost empty of `.md` blocks; the loop **bootstraps** the structure (index, git, hook).

Master-table row format:

- A master-table row is **ONE scannable line per target** (name · path · maturity · artifact · language).
  Run-by-run narrative — per-block/per-run/per-retro history, deferred-scout lists, cross-vibra notes —
  belongs in that target's detail `###` section below, **NOT** in the master row. SKILL.md renders this
  table as the first-run target-picker, so an oversized cell makes it unusable. (`verify-registry.sh`
  WARNs, propose-never-apply, when a master cell exceeds `RSDD_ROW_MAXLEN`, default 200 chars.)

Sensitivity:

- **`live-install`** — the target is a REAL running installation/station (real credentials, keyring,
  config), not a distributable/decompilable artifact. Mark it in its profile. Triggers the SECRETS
  DISCIPLINE hard rule (PROMPT-LOOP): cite secret STRUCTURE, never secret VALUES; zero secrets exfiltrated.

> Calibration note: the "Predominant artifact type" field describes the **object of research**,
> not the noise from `.venv`/`node_modules`. Several `PE32 → decompile-net.sh?` detections from the profiler
> are **false positives** (`pip`/`distlib` launchers inside `.venv`, or packaged runtime). They are flagged below.

---

## Master table

| # | Target | Path | Maturity (.md blocks / git / remote / hook) | Predominant artifact type | Toolbelt tools | Corpus language |
|---|--------|------|-----------------------------------|--------------------------------|---------------------------|-------------------|
| 1 | niagara-research | `/home/cristian/niagara-research` | **mature** (239 md / git yes / remote yes / hook yes) `[CERT]` | Decompiled Java Niagara N4 (`.class`) `[CERT]` | `decompile-java.sh` + CodeGraph | Spanish (technical EN) `[CERT]` |
| 2 | module-navigator | `/home/cristian/Honeywell/.../module-navigator` | **intermediate** (9 md / git no / remote no / hook no; mature tooling) `[CERT]` | Python tooling (CLI/web) over 926 already-decompiled Niagara JARs `[CERT]` | Direct reading + CodeGraph; `decompile-java.sh` (underlying source) | Spanish (technical EN) `[CERT]` |
| 3 | niagara-help | `/home/cristian/Honeywell/.../niagara-help` | **intermediate** (4 md / git yes / remote no / hook no) `[CERT]` | Tridium docs (HTML/bajadoc/txt) + 2,603 `.java` sources `[CERT]` | `fetch-doc.sh` + `decompile-java.sh` | English (Tridium docs) `[CERT]` |
| 4 | kidcad-research | `/home/cristian/kidcad-research` | **mature** (125 md / git yes / remote yes / hook no) `[CERT]` | Mixed: PDF datasheets + KiCad binaries (ELF/PE) + internal Go source `[CERT]` | `fetch-doc.sh` + `decompile-native.sh` + Go reading | Spanish (technical EN) `[CERT]` |
| 5 | api-openness | `/home/cristian/investigacion/api-openness` | **mature** (207 md / git no / remote no / hook yes) `[CERT]` | Siemens .NET API (`Siemens.Engineering`) + official PDFs `[CERT]` | `fetch-doc.sh` + `decompile-net.sh` `[INFER]` | English `[CERT]` |
| 6 | cadesimu | `/home/cristian/investigacion/cadesimu` | **incipient** (6 md, 0 top / git no / remote no / hook no) `[CERT]` | Python render/parse CAD scripts; real CADe_SIMU binary **not present** `[CERT]` | Direct reading; `decompile-net.sh` when the binary shows up `[INFER]` | Spanish `[INFER]` |
| 7 | hifref | `/home/cristian/investigacion/hifref` | **incipient** (9 md / git no / remote no / hook no) `[CERT]` | BACnet/Modbus/SNMP field research: HTML + `.ps1` scripts + CSV; no binaries `[CERT]` | `fetch-doc.sh` + reading scripts | Spanish `[INFER]` |
| 8 | logosoft | `/home/cristian/investigacion/logosoft` | **mature** (76 md / git yes / remote yes / hook yes ×2) `[CERT]` | LOGO! Soft Comfort: Java (`.class`) + native `.bin` dump + PDF manual `[CERT]` | `decompile-java.sh` + `scan-firmware.sh` + `fetch-doc.sh` | **Spanish — APPROVED override** (generate in Spanish; corpus continuity) `[CERT]` |
| 9 | TRANE | `/home/cristian/investigacion/TRANE` | **intermediate** (6 md / git no / remote no / hook no; RE started) `[CERT]` | `.scfx` package (81 MB, `data`) + decompiled .NET (TGE/TTUFramework `.cs`) + signature `[CERT]` | `decompile-net.sh` + `scan-firmware.sh` + `decompile-native.sh` (Ghidra) | Mixed English/Spanish `[CERT]` |
| 10 | API-FACTURAS | `/home/cristian/ALSER/.../API-FACTURAS` | **incipient** as research (2 real md / git no / remote no / hook no) `[CERT]` | Production Python app (32 `.py`) + packaged CONTPAQi SDK (JARs + native DLLs) `[CERT]` | Direct reading; `decompile-java.sh`/`decompile-native.sh` over CONTPAQi SDK `[INFER]` | Spanish `[CERT]` |
| 11 | openness-labs | `/home/cristian/PLC/openness-labs` | **intermediate** (76 md / git yes / remote yes / hook no) `[CERT]` | Python experiments + SCL/XML (TIA Openness) `[CERT]` | Direct reading + CodeGraph | Spanish/EN `[INFER]` |
| 12 | openness-tools | `/home/cristian/PLC/openness-tools` | **intermediate** (27 md / git yes / remote yes / hook no; tooling) `[CERT]` | Python tooling (daemon, generators, offline validator) `[CERT]` | Direct reading + CodeGraph | Spanish/EN `[INFER]` |
| 13 | three.js | `/home/cristian/prototipos/three.js` | **mature** (44 md / 7 runs / git yes / remote yes / hook yes) `[CERT]` | Three.js library research over local HTML prototypes (25 voxel/realistic HVAC files, primary `[CERT]`) + official web docs (context7 `/mrdoob/three.js`, threejs.org) + live browser probes `[CERT-hw]` | fetch-doc.sh + direct reading + context7 MCP + chrome-devtools MCP + tools/probe.mjs (dynamic §12) | English `[CERT]` |
| 14 | pruebas-dashboards | `/home/cristian/prototipos/pruebas-dashboards` | **mature** (41 md / 7 runs / 3 retros +1 pending / git yes / remote yes / hook deferred) `[CERT]` — `anti-ai-ui` skill delivered; run/scout narrative → detail §14 | **Design-research corpus** on anti-AI-feel dashboard design — **no binaries**; web sources + book extracts + context7 library docs (full source list → detail §14) `[CERT]` | `webfetch` + context7 + manual extraction into `corpus/sources/` | English `[CERT]` |
| 15 | gateway-ug67 | `/home/cristian/investigacion/gateway-ug67` | **mature** (34 md / 2 focuses / 2 retros / git yes / remote no / hook yes) `[CERT]` · **`live-install`** (physical device) — device + capacity focuses COMPLETE; focus narrative → detail §15 | **Live hardware**: Milesight UG67 Outdoor LoRaWAN Gateway (US915, fw 60.0.0.47, Quagga vtysh CLI) — serial console COM4 + web GUI (chrome-devtools) + official PDFs `[CERT-hw]`/`[CERT-doc]` | serial driver (`SerialPort` via WSL interop) + chrome-devtools MCP + `fetch-doc.sh` + `extract-pdf.sh`; dynamic/hardware phase §12 | English `[CERT]` |

---

## Per-target detail

### 1 — niagara-research `[CERT]`
Mental model of Niagara N4 (Tridium) reconstructed by decompilation. Very mature corpus: 112 cataloged blocks (`CATALOG.md`), auto-generated `INDEX.md` of ~400 KB, active hook `niagara-research-protocol.sh`. The source artifact is Niagara Java classes (saw `com/tridium/workbench/.../LinkMarkCommand.class`).
**Startup:** continue. Stable loop with its own hook.

### 2 — module-navigator `[CERT]`
Not a corpus of blocks but **Python tooling** (175 CLI commands + dashboard, ~1,354 MB of indexes) that navigates the **decompiled code of 926 Niagara JARs / 51,167 classes** (per `README.md`). Mostly `.py`/`.pyc`; only 9 `.md` (very large ROADMAP/GAPS). Has `.atl` but **no git or hook**.
**Startup:** continue as a support tool for niagara-research; the JARs were already decompiled with `decompile-java.sh`. Do not re-decompile.

### 3 — niagara-help `[CERT]`
Massive dump of Tridium documentation: 13,031 HTML, 11,343 `bajadoc`, 10,471 `.txt`, plus 2,603 `.java` sources (devguide/source). Has git but **no hook** and only 4 `.md` of analysis. The value is in the raw docs corpus, still barely synthesized.
**Startup:** intermediate — the raw corpus exists; the `.md` block layer is missing. Use `fetch-doc.sh` to extract/normalize and `decompile-java.sh` over the example sources.

### 4 — kidcad-research `[CERT]`
Mental model of KiCad v10. Mature corpus (79 blocks, `CATALOG.md`/`INDEX.md`), git present, empty `.claude` (**no hook**). Confirmed mixed artifacts: PDF datasheets/standards (`Prototip/datasheets/...`, `docs/*.pdf`), 14 native KiCad binaries (ELF/PE) and own Go source in `internal/`.
**Startup:** continue. Consider adding a hook to align it with niagara/logosoft.

### 5 — api-openness `[CERT]`
Reference for the **Siemens TIA Portal Openness V17** API (`Siemens.Engineering`, .NET interface). Very mature corpus: 69 numbered blocks at the root (`00_INDEX.md` … `19_*`), 207 `.md` total, active hook `research-reminder.sh`. **No git.** Source: official Siemens PDFs in `_fuentes/` + `Siemens.Engineering.xml` (IntelliSense).
**Startup:** continue. `decompile-net.sh` applies if you want to go beyond the XML to the .NET assembly `[INFER]` — the `.dll` binary was not inspected here.

### 6 — cadesimu `[CERT]`
Research on **CADe_SIMU** (electrical simulator). Incipient state: 0 `.md` at the root, 6 in `docs/`, no git or hook. What exists are own Python render/parse scripts (`build_*.py`, `cad_parser.py`, `render_cad.py`) and generated PNGs. **The real CADe_SIMU binary is not present**; the detected ELF/`.exe` are false positives from `.venv` (PIL, pip launchers).
**Startup:** bootstrap. The loop must create index/git/hook and, when the executable shows up (CADe_SIMU is a Windows app, probably .NET/Delphi `[INFER]`), run `decompile-net.sh`/`decompile-native.sh`.

### 7 — hifref `[CERT]`
Field research on **HiRef** equipment (chillers) via BACnet/Modbus/SNMP. Incipient state: 1 `.md`, no git or hook. Content: HTML captures (`_bacnet.html`, `_net_now.html`…), PowerShell polling scripts (`bacnet_read.ps1`, `modbus_scan.ps1`, `snmp_get.ps1`) and `hiref_nrg381_bacnet_points.csv`. No binaries to decompile.
**Startup:** bootstrap. Synthesize the scripts/captures into blocks; `fetch-doc.sh` for the NRG381 datasheets.

### 8 — logosoft `[CERT]`
Research on **Siemens LOGO! Soft Comfort V8.4** + real PLC. Very mature: 25 blocks + native binaries annex, git, **two hooks** (`logosoft-protocol-reminder.sh`, `logosoft-research-protocol.sh`), `RESEARCH-LOOP.md`/`RUNBOOK-OPERACION.md`. Confirmed artifacts: Java classes (`plc-client/rpc/*.class`, LogoWatch/LogoBackup/LogoCtl), native dump `plc-mram-backup-*.bin`, manual `LOGO8-system-manual-*.pdf`.
**Startup:** continue. It is one of the most complete loops (end-to-end cycle validated against a PLC).

### 9 — TRANE `[CERT]`
Reverse engineering of **Trane Symbio 700 / Tracer (TGE)**. RE started but no git/hook and only 6 `.md` (in `scfx-re/`). The central artifact is `Symbio700-...scfx` (81 MB, `file` → `data`, package/firmware). There is already **decompiled .NET** in `scfx-re/results/decompiled/` (`Functions.cs`, `TTUFramework.cs`, `TraneSig.cs`, `tge/` modules), certificates (`cert.pem/der`), `signature.bin` and Ghidra workflow notes (`phase2-ghidra-workflow.md`).
**Startup:** intermediate → consolidate. `scan-firmware.sh` over `.scfx`/`signature.bin`, `decompile-net.sh` over the .NET TGE, `decompile-native.sh` (Ghidra) per the phase 2 notes.

### 10 — API-FACTURAS `[CERT]`
**Not a classic research target**: it is a production app (CONTPAQi billing, Python + Streamlit, 32 `.py` at the root, `api.py`/`app.py`). The 240 `.md` and the hundreds of binaries from the profiler come from `web/node_modules` and from `CONTPAQi/` (packaged runtime/SDK: JARs `rt/lib/*.jar` + native DLLs). Only 2 real project `.md` (`README.md`, `AUDITORIA_2026-06-03.md`). No git or hook.
**Startup:** bootstrap if you want to treat it as research of the **CONTPAQi SDK**; then `decompile-java.sh`/`decompile-native.sh` over `CONTPAQi/`. As a production app, outside the block pattern.

### 11 — openness-labs `[CERT]`
Experiment lab over **TIA Portal Openness**: 230 `.py`, 74 `.md` (inside `experiments/`), SCL/XML, git present, **no hook**, own `CLAUDE.md`. Notes corpus distributed per experiment, not centralized in an index.
**Startup:** intermediate. Consolidate a master index and hook; direct reading + CodeGraph (no binaries).

### 12 — openness-tools `[CERT]`
Openness automation **tooling**: 95 `.py`, daemon (py/ps1), generators, `offline-validator`, tests, 51 KB `CHANGELOG.md` and 33 KB `CLAUDE.md`. Git present, **no hook**, 27 `.md`.
**Startup:** intermediate. It is own source code: direct reading + CodeGraph; no decompilation required.

### 13 — three.js `[CERT]`
Mental model of the **Three.js library** (r160 primary, r128 legacy) as used by the HVAC prototyping
pipeline (voxel-art first pass → realistic PBR second pass). Mature corpus built 2026-07-04 across
5 runs: 32 blocks (`threejs-block1..32.md`), 32/32 gaps closed, CATALOG/INDEX/RESEARCH-STATE, git,
SessionStart hook (`research-protocol.sh`), 40+ preserved sources in `sources/web-snapshots/`
(29 external showcase/forum targets analyzed), team deliverable `WORKFLOW.md` (5 adoption
sections). First purely docs/web target of the kit AND first web-target DYNAMIC phase (§12,
Puppeteer GL-hook probes, tools/probe.mjs). 4 retros in `retros/` (2026-07-04, runs 1-5).
**Startup:** continue. Reopen per §8 for new URL batches or follow-ups; the corpus dir doubles as
the subject dir (prototypes + corpus in one repo — commits are explicitly scoped, `.gitignore`
covers `.atl/`/`.claude/`/Zone.Identifier).

### 14 — pruebas-dashboards `[CERT]`
Anti-AI-feel **dashboard design research** corpus, NOT reverse-engineering. The subject under
study is the design knowledge domain itself: Tufte, Few, Cairo, FT Visual Vocabulary,
Okabe-Ito, Paul Tol, IBM Carbon, Observable, Mantine, Phosphor, etc. The user asked for sources
"Foro, normas, libros, libros de diseño, reglas" — that is exactly the kind of triangulation this
target is built to capture with citations. Artifacts: web-snapshots (pandoc/`webfetch` → markdown),
book extracts (paratext preserved under `corpus/sources/extracted/`), context7 docs snapshotted
under `corpus/sources/web-snapshots/`. Bootstrap 2026-07-05: created corpus/ subdir
(`INDEX.md` / `RESEARCH-STATE.md` / `sources/SOURCES.md` / `tools/gen-catalog.py` — the
`tools/gen-catalog.py` copy is now LEGACY/vestigial: eje #2 stopped seeding it, and
research-sdd-archive.sh regenerates CATALOG.md via the kit generator), git
initialized, target row registered in `$KIT/TARGETS.md`. **Hook deferred** — OpenCode runtime
does not honor `.claude/settings.json` hooks, so the SessionStart retro-sweep / kit-clean surfacing never fires
there — run `toolbelt/sweep-retros.sh` and `toolbelt/verify-kit-clean.sh` MANUALLY at loop-close on OpenCode;
re-evaluate if the target migrates to Claude Code.
User pre-clarification (2026-07-05): **do NOT read or annotate the user's own dashboards** — the
user explicitly described them as "AI-generic looking" and asked for a *research corpus* of
alternatives, not a review of existing work. The deliverable is a cited knowledge base the user
will then use to BUILD the protos under `prototypes/` (which is gitignored — never enters corpus
history).
**Startup:** maintenance. Four runs (2026-07-05/06 · 07-07 · 07-12) produced **31 blocks** (B1-B31):
7 editorial/web vibras + 6 industrial/HMI vibras + 4 vibra additions (B25-B28) + cross-vibra
discipline blocks + the external design-skill layer (B29 survey / B30 mechanisms / B31 skill
design + applied outcome). Sources triangulate web-snapshots + **13 OCR'd book extracts** (Tufte,
Few, Bertin, Müller-Brockmann, Cairo, Norman, Hollifield...) under `sources/extracted/` + 33
commit-pinned skill snapshots + 6 `[CERT-hw]` probe files (`sources/probes/anti-ai-ui-applied/`).
**State: OPEN — pipeline investigable exhausted 37/40, G41-G47 scouts owed (2026-07-12; previously sweep-#2 36/39 G40 investigable, sweep-#1 investigable end 35/38 and FULL STOP 32/32; G36-G38 carried deferred-pending).** G31 delivered the `anti-ai-ui` skill at
`~/.claude/skills/anti-ai-ui/` (7 files, SHA-identity `b349d1c26116ead6`): trap-brief validation
(divergence gate fired · lint exit 0 · screenshot QA) + Judgment Day TERMINAL APPROVED (round 2,
11 fixed units). Retros: 3 on disk; the iteration-27 close retro (§18) is still owed (+1). The
earlier run-A premature-STOP class stays fixed by the `research-state.v1` envelope + verify-state
STALE-gate. Fifth run (2026-07-12, §8 scoped vibra extension): **B32 Spaceflight Touch-FUI**
(vibra 18, iteration 28) — the corpus's first SOURCE-PUBLISHED-hex vibra (palette machine-
extracted from SpaceX's own `iss-sim.spacex.com` CSS, preserved RAW under
`corpus/sources/web-snapshots/raw/`; Lato SOURCE-SHIPPED; Territory + F-35 cited layers; HARD
role-semantics inversion vs B28). Sixth run (2026-07-12, §8 6-gap exploration sweep): **B33
Maritime ECDIS** (vibra 19, iteration 29) — the corpus's first STANDARD-PUBLISHED CIE-xyY
palette with THREE mandated illumination states (IHO S-52 Ed 6.1.1 + PresLib e4.0.0 Appendix A
preserved as official PDFs under `corpus/sources/docs/ecdis/`; oversized 296-pp Part I +
564-pp Addendum registered fetched-and-hashed with the page-anchored extract at
`corpus/sources/extracted/ecdis-s52-extract.md`; derived sRGB rendering labeled per B33-1).
Sweep registered G33-G38: G33 closed; iteration 30 (same sweep run) closed G34 → **B34
ATC Radar Scope** (vibra 20) — the corpus's first OWNERSHIP-LIFECYCLE colour grammar, from
the SOURCE-PUBLISHED EEC Report 292 Master Colour Table (RGB% + 0-255; preserved with
DOT/FAA/AR-99/52 under `corpus/sources/docs/atc/`; oversized 188-pp ITWP HMI V4
fetched-and-hashed with the page-anchored extract at
`corpus/sources/extracted/atc-radar-scope-extract.md`; hex = corpus re-encodings, Trinitron
caveat B34-13; WCAG-vs-FAA-doctrine convergence: assumed WHITE 8.09:1 inside the 7-8:1
datablock band). Iteration 31 (same sweep run) closed G35 → **B35 Medical Patient
Monitoring** (vibra 21) — the corpus's first PARAMETER-IDENTITY colour grammar, from the
Philips IntelliVue IFU default `Color` tables (MX400-800 2018 + MP5 2008, decade-zero-drift;
BOTH PDFs OVERSIZED — 534 pp + 362 pp — fetched-and-hashed, NOT in repo; page-anchored
extract preserved at `corpus/sources/extracted/medical-intellivue-extract.md` as the sole
evidence carrier); colour NAMES only in the source → hex CORPUS-ASSIGNED + WCAG-computed
(B35-5); **critical source correction: the IFUs cite IEC 60601-2-49, never 60601-1-8**
(B35-3 FABRICATED-CITE guard); three-tier alarm grammar verbatim (banner colour = priority ·
***/**/* + !!!/!! glyphs · lamp modulation 1.0 s/0.25 s). G36-G38 remain deferred
scout-PARTIAL (not closed). Seventh run (2026-07-12, §8 sweep #2 regional expansion):
iteration 32 registered AND closed G39 → **B36 Swiss Rail Operations Board** (vibra 22) —
the corpus's first NUMBER-FORMAT honesty channel: the SBB Generalanzeiger six-column
grammar + DELAY-STATE numeric grammar (precision graded by magnitude + explicit unknown
state, verbatim from sbb.ch) + worded disruption vocabulary + HIM-CUS icon role system +
blue/white figure-ground (2014 LED statement), certified from 13 snapshots preserved
under `corpus/sources/web-snapshots/sbb/` + the image-only eGuide PDF under
`corpus/sources/docs/sbb/` (full sha256); palette = SOURCE-PUBLISHED digital.sbb.ch web
hex verbatim with **TWO declared proxies as scout conditions** (board blue `#2d327d` =
published WEB Blue, physical value unpublished → B36-3; SBB Web proprietary →
Helvetica-class proxy grounded in the eGuide Helvetica statement → B36-4);
Müller-Brockmann 1978-80 lineage joins B12 as the Swiss school's live-operations branch.
Sweep #2 pipeline registered: G40 MoTeC (scout COMPLETE, CERTIFIABLE-NOW — NEXT-eligible)
· G41-G47 pending-scout (UK AF/ONS · DataV · Source Han · jlreq · 和色 · 中国传统色 ·
DSFR) · G48 DB-fold-into-B36 note · G49-G50 conditional (DADS · ShakeMap/PAGER).
Iteration 33 (same run) closed G40 → **B37 Motorsport Telemetry Analysis** (vibra 23) —
the corpus's first GRAMMAR-FIRST vibra and first POST-HOC analytical-comparison grammar:
the MoTeC Interpreter → i2 linked-cursor keystone + 14 page-anchored signature rules
certified from 2 vendor PDFs preserved whole under `corpus/sources/docs/motec/`
(Interpreter User's Manual Aug 2002 + i2 V1.1.4 Feature Guide Oct 2018) + the official
i2 Features page snapshot under `corpus/sources/web-snapshots/motec/` (TLS
fetch-provenance note) + the page-anchored extract; the sources publish NO palette
(channel colours user/template-assigned) → all display tokens CORPUS-ASSIGNED +
WCAG-computed (B37-3); Standard-vs-Pro matrix adopted as citable component budget;
red = ranking (within 2% of fastest), alarm grammar banned (B37-2).
Coverage: **37 blocks, 37/40 — pipeline investigable exhausted, G41-G47 scouts owed**,
envelope investigable_open=0; reopenings otherwise per §8.

**Master-row narrative (moved from the master table 2026-07-12, verbatim — newer than the body above):**
13 OCR book-extracts + 5 standard/manual extracts; `anti-ai-ui` skill delivered; B39 NUREG-0700 + B40
public-warning severity grammar cross-vibra FOUNDATIONS + B41 大屏 Command-Canvas vibra 25 (the
anti-imitation flagship, G42; N1-N20 + H1-H12 + B41 catalog-row/creative-moves/ledger-triage handoffs
pending skill adoption), pipeline still scout-owed 41/44, G43-G47 scouts owed (G43 Source Han first —
B41 dependency), G36-G38 deferred.

### 15 — gateway-ug67 `[CERT]`
Live-hardware research on the **Milesight UG67 Outdoor LoRaWAN Gateway** (US915, fw 60.0.0.47, Quagga
vtysh CLI) — a REAL running installation (`live-install`: serial console COM4 + web GUI via
chrome-devtools + SSH + HTTP-API + official PDFs). Mature corpus with git and an active hook; two
research focuses driven to completion.
**Master-row narrative (moved from the master table 2026-07-12, verbatim):**
**device focus COMPLETE** (serial + web-GUI + SSH + HTTP-API; firmware-RE via Node-RED root RCE, B17) ·
**capacity focus COMPLETE** (B18–B24: LoRaWAN concurrent-traffic/scaling, US915-Mexico, web-research).
**Startup:** continue. SECRETS DISCIPLINE applies (cite secret STRUCTURE, never VALUES); dynamic/hardware
phase §12 for any further live probing.

---

## Targets whose type I could NOT confirm 100%

- **cadesimu (#6)** `[INFER]`: the real CADe_SIMU binary **is not in the tree**; I could not run `file` on it. Assuming .NET/Delphi Windows is an inference. What is present is only auxiliary Python tooling.
- **api-openness (#5)** `[INFER]`: confirmed as a .NET API by the XML doc, but **I did not inspect the `.dll` assembly** of `Siemens.Engineering`; `decompile-net.sh` remains an unverified recommendation against the binary.
- **API-FACTURAS (#10)** `[INFER]`: the CONTPAQi SDK has JARs (Java, `[CERT]`) and native DLLs, but **I did not run `file` discriminating .NET vs native** on each DLL; the choice between `decompile-net.sh` and `decompile-native.sh` per DLL remains pending.
- **openness-labs / openness-tools (#11, #12)** `[INFER]` (language only): type confirmed (Python source), but I infer the corpus language as Spanish/EN without having read the `.md`.

## Profiler false positives to ignore
- `cadesimu` and `API-FACTURAS`: the `PE32 → decompile-net.sh?` and `ELF → decompile-native.sh` come from `.venv` (PIL `*.so`, `pip`/`distlib` launchers `t32/t64/w32/w64.exe`). **They are not targets.**
