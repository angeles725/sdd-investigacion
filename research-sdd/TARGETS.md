# Research-SDD — Targets Registry

This file is the **master registry of the 13 active research targets** of the Research-SDD loop
(numbered up to 16; **#6 cadesimu, #11 openness-labs and #12 openness-tools were de-registered** — see the
"De-registered — not block corpora" section at the end).
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

- Non-corpus targets (no `RESEARCH-STATE.md` by design — tooling, doc, production app) carry the flag
  **`nc`** in their maturity parenthetical after a slash, e.g. `(6 md / nc / git no / remote no / hook no)`.
  For these rows the `N md` count means **root-level `.md` files only**
  (`find <target> -maxdepth 1 -type f -name '*.md'` — naturally excludes `.venv/`, `node_modules/`,
  `.git/`, and `.atl/` without a hardcoded exclusion list). `verify-registry.sh` recognizes the `nc`
  flag and verifies the count without emitting a false "corpus layout not resolvable" WARN. A target
  WITHOUT the `nc` flag that also has no `RESEARCH-STATE.md` still receives the WARN — that is the
  error, not a non-corpus exemption.

- The `hook` flag records **hook-file presence** (`<target>/.claude/hooks/research-protocol.sh`). Active
  registration in `<target>/.claude/settings.json` (matcher `startup|resume|clear`) is tracked separately.
  `hook file yes / unregistered` means the file was installed by `research-sdd-init.sh` but the
  `settings.json` registration step was never completed, so the hook cannot fire.

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
| 1 | niagara-research | `/home/cristian/niagara-research` | **mature** (290 md / git yes / remote yes / hook yes) `[CERT]` | Decompiled Java Niagara N4 (`.class`) `[CERT]` | `decompile-java.sh` + CodeGraph | Spanish (technical EN) `[CERT]` |
| 2 | module-navigator | `/home/cristian/Honeywell/OptimizerSupervisor-N4.14.0.162/module-navigator` | **intermediate** (6 md / nc / git no / remote no / hook no; mature tooling) `[CERT]` | Python tooling (CLI/web) over 926 already-decompiled Niagara JARs `[CERT]` | Direct reading + CodeGraph; `decompile-java.sh` (underlying source) | Spanish (technical EN) `[CERT]` |
| 3 | niagara-help | `/home/cristian/Honeywell/OptimizerSupervisor-N4.14.0.162/niagara-help` | **intermediate** (2 md / nc / git yes / remote no / hook no) `[CERT]` | Tridium docs (HTML/bajadoc/txt) + 2,603 `.java` sources `[CERT]` | `fetch-doc.sh` + `decompile-java.sh` | English (Tridium docs) `[CERT]` |
| 4 | kidcad-research | `/home/cristian/kidcad-research` | **mature** (79 md / git yes / remote yes / hook no) `[CERT]` | Mixed: PDF datasheets + KiCad binaries (ELF/PE) + internal Go source `[CERT]` | `fetch-doc.sh` + `decompile-native.sh` + Go reading | Spanish (technical EN) `[CERT]` |
| 5 | api-openness | `/home/cristian/investigacion/api-openness` | **mature** (16 md / git no / remote no / hook yes) `[CERT]` | Siemens .NET API (`Siemens.Engineering`) + official PDFs `[CERT]` | `fetch-doc.sh` + `decompile-net.sh` `[INFER]` | English `[CERT]` |
| 7 | hifref | `/home/cristian/investigacion/hifref` | **intermediate** (9 md / git yes / remote yes / hook yes) `[CERT]` | BACnet/Modbus/SNMP field research: HTML + `.ps1` scripts + CSV; no binaries `[CERT]` | `fetch-doc.sh` + reading scripts | Spanish `[INFER]` |
| 8 | logosoft | `/home/cristian/investigacion/logosoft` | **mature** (77 md / git yes / remote yes / hook yes ×2) `[CERT]` | LOGO! Soft Comfort: Java (`.class`) + native `.bin` dump + PDF manual `[CERT]` | `decompile-java.sh` + `scan-firmware.sh` + `fetch-doc.sh` | **Spanish — APPROVED override** (generate in Spanish; corpus continuity) `[CERT]` |
| 9 | TRANE | `/home/cristian/investigacion/TRANE` | **intermediate** (5 md / git yes / remote yes / hook yes; RE started) `[CERT]` | `.scfx` package (81 MB, `data`) + decompiled .NET (TGE/TTUFramework `.cs`) + signature `[CERT]` | `decompile-net.sh` + `scan-firmware.sh` + `decompile-native.sh` (Ghidra) | Mixed English/Spanish `[CERT]` |
| 10 | API-FACTURAS | `/home/cristian/ALSER/Proyectos/Automatizacion/API-FACTURAS` | **incipient** as research (2 md / nc / git no / remote no / hook no) `[CERT]` | Production Python app (32 `.py`) + packaged CONTPAQi SDK (JARs + native DLLs) `[CERT]` | Direct reading; `decompile-java.sh`/`decompile-native.sh` over CONTPAQi SDK `[INFER]` | Spanish `[CERT]` |
| 13 | three.js | `/home/cristian/prototipos/three.js` | **mature** (44 md / 7 runs / git yes / remote yes / hook yes) `[CERT]` | Three.js library research over local HTML prototypes (25 voxel/realistic HVAC files, primary `[CERT]`) + official web docs (context7 `/mrdoob/three.js`, threejs.org) + live browser probes `[CERT-hw]` | fetch-doc.sh + direct reading + context7 MCP + chrome-devtools MCP + tools/probe.mjs (dynamic §12) | English `[CERT]` |
| 14 | pruebas-dashboards | `/home/cristian/prototipos/pruebas-dashboards` | **mature** (48 md / 7 runs / 4 retros + 1 corpus §18 + 3 client retros / git yes / remote yes / hook deferred) `[CERT]` — `anti-ai-ui` skill delivered — detail §14 | **Design-research corpus** on anti-AI-feel dashboard design — **no binaries**; web sources + book extracts + context7 library docs (full source list → detail §14) `[CERT]` | `webfetch` + context7 + manual extraction into `corpus/sources/` | English `[CERT]` |
| 15 | gateway-ug67 | `/home/cristian/investigacion/gateway-ug67` | **mature** (34 md / git yes / remote yes / hook file yes / unregistered) `[CERT]` · **`live-install`** (physical device) — device + capacity focuses COMPLETE; focus narrative → detail §15 | **Live hardware**: Milesight UG67 Outdoor LoRaWAN Gateway (US915, fw 60.0.0.47, Quagga vtysh CLI) — serial console COM4 + web GUI (chrome-devtools) + official PDFs `[CERT-hw]`/`[CERT-doc]` | serial driver (`SerialPort` via WSL interop) + chrome-devtools MCP + `fetch-doc.sh` + `extract-pdf.sh`; dynamic/hardware phase §12 | English `[CERT]` |
| 16 | computadoras | `/home/cristian/investigacion/computadoras` | **incipient** (6 md / git yes / remote no / hook no) `[CERT]` · **`live-install`** (mini-PC + dead source PC, READ-ONLY) — single-focus activation-recovery; narrative → detail §16 | **Live-install investigation**: Trane Tracer Summit V17 SP18 (Summit.exe) on Win11 mini-PC; local MSI/EXE + old install copy on Windows C drive (WSL mnt); full source list → detail §16 `[CERT]` | Direct reading + `lessmsi`/`msiinfo` + ssh probe (read-only) + web (Trane/forum); `decompile-native.sh`/`scan-firmware.sh` if needed | English `[CERT]` |
| 17 | hilton-bms | `/home/cristian/tunnel/Cliente/Cancun/HotelHilton` | **mature** (74 blocks / 4 runs / 2 retros / git yes / remote no) `[CERT]` · **`live-install`** · **multi-focus** (4, one ACTIVE) — narrative → detail §17 | Alerton Compass 1.6.5 BMS job (offline copy) + live Windows host over Cloudflare Tunnel `[CERT]` | `mdb-tools` + own BACnet client (`tools/bacnet_discover.ps1`) + `pwsh` lint + read-only SSH/BACnet probes (§12) | English (corpus drifted to Spanish from `compass-discover` B8 on) `[CERT]` |
| 18 | nave-panccadia | `/home/cristian/investigacion/nave-panccadia` | **intermediate** (30 blocks @2026-07-28, ACTIVE / 2 runs / 14-of-23 gaps / git yes / remote no / hook yes) `[CERT]` — CAD-to-3D reconstruction, §19 two-storey model DELIVERED; narrative → detail §18 | Architectural CAD: one AutoCAD 2007 (`AC1021`) DWG of an industrial bakery plant, converted read-only to DXF (9,939 modelspace entities / 28 layers / 531 blocks) `[CERT]` | `dwg2dxf` (LibreDWG) + `ezdxf` + `matplotlib` + own `tools/` (9 probes incl. `cad-view.py`, the visual oracle) | English `[CERT]` |
| 19 | EduVolt-Designer | `/home/cristian/investigacion/EduVolt-Designer` | **intermediate** (8 md / git yes / remote yes / hook yes; static investigable EXHAUSTED) `[CERT]` | Flutter Windows desktop app: Dart AOT native snapshot (`app.so`) + native PE DLLs; no x64 Dart decompiler available `[CERT]` | `decompile-native.sh` (Ghidra; blutter blocked) + `strings`/`readelf` static | Spanish (product) / English (corpus) `[CERT]` |
| 20 | impresora-samsung-m2070 | `/home/cristian/investigacion/impresora-samsung-m2070` | **intermediate** (13 md / git yes / remote yes / hook yes; static STOP MET + dynamic phase done) `[CERT]` · **`live-install`** (USB printer) — naming gap → detail §20 | Samsung M2070 MFP USB protocol: Windows driver (GPD/INF/JS) + Linux ULD ELF (`rastertospl`, `libsane-smfp.so`) + live USB hardware (QPDL print, PJL/SSIP probes) `[CERT]` | `decompile-native.sh` (Ghidra headless) + direct reading; dynamic: `tools/pjl-live-query.py` (pyusb, §12) | English `[CERT]` |
| 22 | sdd-investigacion | `/home/cristian/investigacion/sdd-investigacion` | **intermediate** (27 blocks / 1 run / 0 retros / git yes / remote yes / hook yes) `[CERT]` · **SELF-REFERENTIAL** · corpus one MAJOR version stale → detail §22 | gentle-ai (Go ecosystem configurator) + its SDD layer in Claude Code / OpenCode: skill/prompt/contract markdown + `state.json` + CLI surface `[CERT]` | local `tools/gen-catalog.py` (corpus-specialized fork) + direct reading + `gh api` upstream | English `[CERT]` |

---

## Per-target detail

### 1 — niagara-research `[CERT]`
Mental model of Niagara N4 (Tridium) reconstructed by decompilation. Very mature corpus: 290 cataloged blocks (`CATALOG.md`), auto-generated `INDEX.md` of ~400 KB, active hook `niagara-research-protocol.sh`. The source artifact is Niagara Java classes (saw `com/tridium/workbench/.../LinkMarkCommand.class`).
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
Reference for the **Siemens TIA Portal Openness V17** API (`Siemens.Engineering`, .NET interface). Very mature corpus: 43 numbered blocks at the root (`00_INDEX.md` … `42_*`), 208 `.md` total, active hook `research-reminder.sh`. **No git.** Source: official Siemens PDFs in `_fuentes/` + `Siemens.Engineering.xml` (IntelliSense).
**Startup:** continue. `decompile-net.sh` applies if you want to go beyond the XML to the .NET assembly `[INFER]` — the `.dll` binary was not inspected here.

### 7 — hifref `[CERT]`
Field research on **HiRef** equipment (chillers) via BACnet/Modbus/SNMP. Intermediate state: 9 blocks (`hifref-bloque1.md` … `hifref-bloque9.md`), git yes, remote yes (`https://github.com/angeles725/research-hifref.git`), hook yes (`research-protocol.sh`). Content: HTML captures, PowerShell polling scripts and `hiref_nrg381_bacnet_points.csv`, `sources/web-snapshots/`, `docs/`. No binaries to decompile.
**Startup:** continue. Corpus and loop infra present; use `fetch-doc.sh` for additional NRG381 datasheets as needed.

### 8 — logosoft `[CERT]`
Research on **Siemens LOGO! Soft Comfort V8.4** + real PLC. Very mature: 77 blocks (gen-catalog.py authoritative) + native binaries annex, git, **two hooks** (`logosoft-protocol-reminder.sh`, `logosoft-research-protocol.sh`), `RESEARCH-LOOP.md`/`RUNBOOK-OPERACION.md`. Confirmed artifacts: Java classes (`plc-client/rpc/*.class`, LogoWatch/LogoBackup/LogoCtl), native dump `plc-mram-backup-*.bin`, manual `LOGO8-system-manual-*.pdf`.
**Startup:** continue. It is one of the most complete loops (end-to-end cycle validated against a PLC).

### 9 — TRANE `[CERT]`
Reverse engineering of **Trane Symbio 700 / Tracer (TGE)**. RE started, git + remote + hook present, 5 `.md` blocks (`trane-mental-model-block1..5.md` at root). The central artifact is `Symbio700-...scfx` (81 MB, `file` → `data`, package/firmware). There is already **decompiled .NET** in `scfx-re/results/decompiled/` (`Functions.cs`, `TTUFramework.cs`, `TraneSig.cs`, `tge/` modules), certificates (`cert.pem/der`), `signature.bin` and Ghidra workflow notes (`phase2-ghidra-workflow.md`).
**Startup:** intermediate → consolidate. `scan-firmware.sh` over `.scfx`/`signature.bin`, `decompile-net.sh` over the .NET TGE, `decompile-native.sh` (Ghidra) per the phase 2 notes.

### 10 — API-FACTURAS `[CERT]`
**Not a classic research target**: it is a production app (CONTPAQi billing, Python + Streamlit, 32 `.py` at the root, `api.py`/`app.py`). The 240 `.md` and the hundreds of binaries from the profiler come from `web/node_modules` and from `CONTPAQi/` (packaged runtime/SDK: JARs `rt/lib/*.jar` + native DLLs). Only 2 real project `.md` (`README.md`, `AUDITORIA_2026-06-03.md`). No git or hook.
**Startup:** bootstrap if you want to treat it as research of the **CONTPAQi SDK**; then `decompile-java.sh`/`decompile-native.sh` over `CONTPAQi/`. As a production app, outside the block pattern.

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
anti-imitation flagship, G42) + B42 French State Design System vibra 26 (DSFR integrated tokens +
chart layer, G47 — the chart-palette trap + the DataBox AI-provenance contract; N1-N20 + H1-H12 +
B41/B42 catalog-row/creative-moves/ledger-triage handoffs pending skill adoption), pipeline still
scout-owed 42/45, G43-G46 scouts owed (G43 Source Han first — B41 dependency), G36-G38 deferred.

### 15 — gateway-ug67 `[CERT]`
Live-hardware research on the **Milesight UG67 Outdoor LoRaWAN Gateway** (US915, fw 60.0.0.47, Quagga
vtysh CLI) — a REAL running installation (`live-install`: serial console COM4 + web GUI via
chrome-devtools + SSH + HTTP-API + official PDFs). Mature corpus with git and a hook file; two
research focuses driven to completion.
**Hook status**: `.claude/hooks/research-protocol.sh` is present (installed by `research-sdd-init.sh`)
but **unregistered** — no `settings.json` or `settings.local.json` exists in the repo, the hook
`<SUBJECT>` placeholder was never replaced, and the required `startup|resume|clear` matcher was never
created. The hook cannot fire in its current state.
**Master-row narrative (moved from the master table 2026-07-12, verbatim):**
**device focus COMPLETE** (serial + web-GUI + SSH + HTTP-API; firmware-RE via Node-RED root RCE, B17) ·
**capacity focus COMPLETE** (B18–B24: LoRaWAN concurrent-traffic/scaling, US915-Mexico, web-research).
**Startup:** continue. SECRETS DISCIPLINE applies (cite secret STRUCTURE, never VALUES); dynamic/hardware
phase §12 for any further live probing.

### 16 — computadoras `[CERT]`
**Read-only** investigation of Trane **Tracer Summit V17 / SP18** activation + operator-password recovery on
replacement hardware. Live-install context: dead source PC's data is preserved on the laptop at
`/mnt/c/Tracer Summit/Tracer Summit/` (full install + Database/Backup + Doc/IP Tools/CHM + CPL/Zodiac); the
new Win11 mini-PC at 192.168.0.23 already has Summit.exe 17.0.0.228 native (base MSI + SP18 applied, Zodiak
data + Summit.mdb restored), but login fails because `HKLM\SOFTWARE\WOW6432Node\The Trane Company\Tracer
Summit\17.00\Registration` is empty/demo. Goal: cited answers to the user's six questions (activation
workflow, identifier recoverability, UI site-selection + password change, safe DB-repair fall-back, copy
semantics, safe next-action runbook) WITHOUT modifying either machine, without cracking, and without
exposing secrets. Sources are local (installer EXE/MSI, BASRegistration.exe + Registration Worksheet.rtf,
IPtools.chm, CPL PDFs, backup .MDBs read schema-only via `mdb-schema`) + web (Trane support, Tracer Summit
literature, forums for operator workflow corroboration). SECRETS DISCIPLINE applies throughout — cite
STRUCTURE of registration/operator secrets, never VALUES. Single focus: **activation-recovery**.

**Master-row artifact-cell narrative (moved from the master table 2026-07-25, verbatim):**
**Live-install investigation**: Trane Tracer Summit V17.00.0046 + SP18 (Summit.exe 17.0.0.228) on Windows 11
mini-PC (DESKTOP-N3FMUUB / 192.168.0.23) — local install media (`SummitBase/Tracer Summit.msi`,
`TracerSummitV17.00SP18 (1).exe`) + full old install copy at `/mnt/c/Tracer Summit/Tracer Summit/`
(Bin/BASRegistration.exe, Registration Worksheet.rtf, full Database/Backup, Doc/IP Tools/IPtools.chm,
CPL/Zodiac) `[CERT]`.
Toolbelt detail: Direct reading (`file`, `7z l`, `lessmsi`/`msiinfo`, `strings`, RTF/CHM/PDF parsing) +
minimal ssh probe (read-only) + web (Trane/forum) — `decompile-native.sh`/`scan-firmware.sh` only if needed
for control-flow questions.

### 17 — hilton-bms `[CERT]`
**Focus status**: `integration` STOPPED 14/14 (15 blocks) · `pi5-decoding` 18 blocks · `compass-discover`
**ACTIVE 19/43** (33 blocks) · `dashboard` 5 blocks (unnarrated below — needs its own paragraph).
Block counts are the on-disk census (71 total, flat `corpus/`); the `n/m` gap ratios are as last
reported by the focus and are NOT re-derived here. **Hook**: file installed by `research-sdd-init.sh` but still unregistered in
`settings.json` (no matcher). **Writes**: READ-ONLY plus AUTHORIZED config mutations — see
`ROLLBACK.md` at the target root.

**Read-only** investigation of the **Alerton Compass 1.6.5** BMS running the `GINSATEC` job at the
Cancún Hilton/Conrad complex. Live-install context: the production host `AlertonBMS`
(`alertonbms\Administrator`) is reachable READ-ONLY through a Cloudflare Tunnel installed for this
project (`connect-ssh.sh` / `fetch.sh` at the target root). An **offline copy of the job** —
4,426 files / 1.3 GB, historians excluded — lives at `descargas/job-ginsatec/` (gitignored: client
production data, never versioned; the corpus cites it by path). Inventory — the job DECLARES **558
devices** (512 MS/TP, 8 BACnet/Ethernet via ACM-GC area routers, 3 BACnet/IP), but a directed census
with our own client MEASURED **503 alive** (`compass-discover` B16): the job over-declares 78 and the
bus carries 25 the job never knew about. Broadcast Who-Is only ever saw ~210 of them — MS/TP
subordinates do not answer a forwarded broadcast at any dwell. Also 649 trendlogs, 20 FLG-Modbus
gateways, 3 Niagara4 stations (one running **on the same host**, `station` on Fox 1911), Compass web
UI on IIS (80/81/83/99, OIDC `client_id=Compass`), `bactalk` on 127.0.0.1:8088, SQL Server Express
with a 150 MB job backup. Multi-brand site: CONRAD · HILTON · CASA TULKAL · SPA · KIDS CLUB.
Three focuses: **integration** (STOPPED 14/14 — which viable paths exist to extract point data out of
this BMS) · **pi5-decoding** (13 blocks — INNCOM PI5 protocol decoded, decoder DEPLOYED in production,
point semantics 9.1%→48.2%) · **compass-discover** (ACTIVE 19/43 — reverse-engineered how Compass
discovers a controller's point universe, then replaced it: an independent BACnet client that censused
503 live devices and a read-only collector reproducing Tridium's COV/poll ladder, all five parts
measured against production).
SECRETS DISCIPLINE applies throughout (cite structure of credentials/tokens, never values); the host
already carries five pre-existing remote-access tools (Radmin, TeamViewer, AnyDesk, RustDesk, RDP).
**Hook status**: `.claude/hooks/research-protocol.sh` installed by `research-sdd-init.sh` but
**unregistered** (no `settings.json` matcher yet).
**Startup:** continue.

---

### 18 — nave-panccadia `[CERT]`

> **This target is being actively written to — its block count is a moving number.** Observed growing
> from 20 to 30 blocks over a single afternoon on 2026-07-28, which is why the master row stamps a date
> (`30 blocks @2026-07-28`) instead of asserting a standing figure. A registry drift WARN on this row is
> expected between runs and does not by itself indicate a stale registry; recount before treating it as
> drift. It also means a golden-diff of any sweep will show this row changing for reasons unrelated to
> the code under test.

Reconstruction of an architectural CAD drawing into a certified geometric model, aimed at a 3D
ground-floor build (§19 applied phase). The subject is a single AutoCAD 2007 (`AC1021`) DWG —
`Proyecto Nave Panccadia_Av.Del Curtidor.dwg`, an industrial bakery plant on Av. Del Curtidor —
preserved read-only under `raw/` with its SHA-256 alongside the LibreDWG `dwg2dxf` conversion.

**Confirmed at bootstrap** `[CERT]`: single populated modelspace (both paper-space layouts empty),
9,939 entities, 28 used layers of 30 defined, 531 block definitions with 47 distinct inserts.
Drawing text carries the literal label `PLANTA BAJA`, two floor-level marks (`NPT±0.00` ×17,
`NPT±3.15` ×14) and a full architectural programme (cold rooms, laminating room, administration).
Layer extents reveal at least two disjoint islands plus far-field outlier geometry.

**Run 1 (2026-07-27/28, 7 blocks)**: B1 units · B2 modelspace partition · B3 levels · B4 walls ·
B5 columns · B6 §19 pipeline + 3D model · B7 visual oracle (CORRECTS B6 and B5). Certified results:
1 unit = 1 metre (`$INSUNITS` refuted); the file is a 12-view drawing set; ground floor outline
**1,101 m²**; floor-to-floor **3.15 m**, building height **+9.20 m**; walls are open segments with
**26.2 % oblique**; 21 concrete columns + **28 hollow HSS 8×8×1/4**; doors ABSENT as placed objects.

**Method lessons worth reading (B7, B8)** — two gate blind spots found in one run, both by the
operator eyeballing the result:
1. **B7**: the model passed a **16/16** arithmetic gate while its slab was a bounding box inventing
   **748 m² (40 %)** of floor. Arithmetic validation compares a model to the CORPUS, so it cannot
   catch geometry never ingested nor a wrong overall SHAPE. Binding rule: *a geometric deliverable is
   not verified until compared against a render of the source drawing.*
2. **B8**: the fixed model then passed **21/21** while the plan was **MIRRORED** — CAD's `+Y` is up
   the sheet, three.js's `+Z` points at the viewer, so `z = y` reflects the plan. **Reflection
   preserves every length, area, count and angle magnitude**, so no symmetric check can see it.
   Binding rule: *a coordinate-system handoff is a verification boundary; test it with an ASYMMETRIC
   signature (signed area, known-handed landmark).* Gate now 24/24 with chirality guards.

**Run 2 (2026-07-28, 5 blocks — B8..B12)**: B8 mirrored plan · B9 double flip · B10 PLANTA ALTA
registration and extent · B11 which witness defines the raised slab · B12 §19 upper-storey build.
Certified results: the upper plan registers on the ground floor by a **PURE TRANSLATION of
(48.9886, 0.2253)**, established by making three transform hypotheses COMPETE — 34/36 columns matched
vs 13 and 8 for the two mirrorings; the built upper storey is a **15.97 × 28.77 m strip**, not a
second full floor (the rest of the plan is labelled `AZOTEA`); the drawn `PROYECCIÓN` outline
**under-reports** the slab by up to 3.45 m. Delivered: two-storey viewer with a storey visibility
control, gate at **35/35**, and 5 third-path guards each demonstrated FAILING.

3. **B12**: the third transform path passed **34/34** with the laboratory annex **79.65 m off the
   site**. Four guards constrained the annex's area, vertex count, Y position and the walls' offset;
   **none constrained its X**. Binding rule: *a guard on a two-axis object must test BOTH axes* — B9's
   "a guard covers only the path it inspects", restated for axes. Found by the top-view render, not
   the gate: arithmetic cannot catch a wrong SHAPE (B7) and cannot catch a wrong PLACE either.
4. **B11**: a check that cannot SEE a defect still returns a confident answer. The parapet test
   agreed with the projected slab outline on 37 of 39 segments — but a parapet only exists where floor
   meets open air, so it could never detect ENCLOSED floor. Binding rule: *name a test's blind spot
   before trusting its verdict.* The test that worked was semantic: a labelled room cannot float.

All staged for the kit LEARNINGS ledger.

**Tooling**: `dwg2dxf` (LibreDWG via linuxbrew), `ezdxf` 1.4.4 and `matplotlib` 3.11.1 in `.venv/`,
plus eighteen own read-only tools documented in `tools/README.md`. Notably `tools/cad-view.py` renders
any region **as AutoCAD draws it** (via `ezdxf.addons.drawing`: real ACI colours, lineweights,
hatches, text) — the visual oracle the run lacked; `tools/compare-model.py` overlays model on
drawing; `tools/topview-check.py` renders the model as three.js will draw it (the only probe that
can see a mirroring, since the JSON itself is always correct — extended in run 2 to overlay both
storeys). Run 2 added `tools/upper-floor.py` (census + competing-hypothesis registration),
`tools/extract-pa.py` (imports `extract-gf.py` and moves its ORIGIN, so the registration offset has
exactly ONE place it can be applied) and **`tools/prove-guards.py`**, which turns B9's "prove every
guard by breaking it" into a tool: it injects each guard's own defect and reports CAUGHT or MISSED. Conversion artefacts found: 8 of 217 dimensions lost associativity, and 36 `INSERT`s
reference anonymous `*U` blocks LibreDWG did not export.

**Hook status**: `.claude/hooks/research-protocol.sh` installed by `research-sdd-init.sh`.
**Startup:** continue — 9 read-only-investigable gaps remain, 0 requires-execution (next: G4 structural grid).

### 19 — EduVolt-Designer `[CERT]`
RE of **EduVolt Designer** — a Flutter Windows desktop app for industrial electrical diagram design
(IEC 81346/60947/60445/61558 component library, `.evc`/`.evd` format, Pro/Free licensing gating,
`wp-json/eduvolt/v1` backend, authored by EduVolt Academy). Artifact: Dart AOT native snapshot
(`app.so`, read via `strings`/`readelf`) + native PE DLLs (`flutter_windows.dll`,
`flutter_secure_storage_windows_plugin.dll`). 8 blocks produced 2026-06-28 via static
strings/readelf/file; blutter installed but blocked (no cmake/ninja/Dart SDK in environment,
see B1 §1.6). **Static investigable set EXHAUSTED**: every remaining open gap needs an x64
Dart-AOT decompiler, a live license server, or hardware — none are static-read-only
investigable; the §8 primary STOP criterion is effectively met. No retros/ directory.
**Startup:** continue only if an x64 Dart-AOT decompiler (blutter or equivalent) becomes available.

### 20 — impresora-samsung-m2070 `[CERT]`
RE of the **Samsung M2070 Series MFP USB communication protocol**. `live-install`: real USB
printer probed via `usbipd-win` / WSL USB/IP. 13 blocks produced 2026-07-04: 12 evidence
blocks (B1–B11 static RE + B4 live USB hardware) + 1 corpus-closing synthesis (B12) + 1
dynamic-phase live PJL probe (B13). Key findings: QPDL print protocol decoded at
native-Samsung-source level (`rastertospl` Ghidra headless, B9); SSIP scan protocol == `xerox_mfp`
wire (all 8 opcodes confirmed, `libsane-smfp.so` Ghidra headless, B10); live `@PJL` probe
confirmed QPDL as firmware-declared language and captured real page-count + `LITESMSTATUS`
bytes (B13, `[CERT-hw]`). Static STOP MET after B11 (read-only-investigable = 0).
1 retro in `retros/`: `2026-07-04-m2070-usb-protocol.md` (7 proposed kit deltas including a
verified `decompile-native.sh` Ghidra dot-prefix bug — **review-status: pending**).

**Naming issue `[CERT]`**: block files are named `block1.md` … `block13.md` — no hyphenated
prefix. The kit's canonical discriminator (`*-block*.md` / `*-bloque*.md`) matches **zero**
files here. `verify-registry.sh` now reports these 13 as unclassifiable candidates and directs
the operator to rename. However `research-sdd-archive.sh` and `sweep-retros.sh` still use the
naive discriminator, so any gate built on a block count sees zero for this target until the
files are renamed to the canonical pattern (e.g. `m2070-block1.md`).

**Startup:** static loop closed (G13 — networked M2070W/FW AirPrint/eSCL end-to-end — remains
the only genuinely hardware-blocked gap). Resolve the naming issue before the next archive run.

---

### 22 — sdd-investigacion `[CERT]`

**SELF-REFERENTIAL target: this row points at the kit repo itself.** The kit supervises a fleet of
research corpora; it also *is* one. `research-sdd/README.md:197` says so outright — "the SDD
mental-model corpus: the kit applied to itself, as a worked example". It went unregistered until
2026-07-28, so for its whole life the fleet supervisor was the one corpus its own instruments never
looked at: `verify-registry.sh`, `sweep-retros.sh`, `sweep-audits.sh` and `sweep-tools.sh` all derive
their target list from this table, and this table did not mention it.

**Corpus.** 27 blocks `sdd-mental-model-bloque1..27.md` at the repo ROOT (they match the canonical
`<prefix>-(block|bloque)<N>.md` discriminator), plus `INDEX.md` and `CATALOG.md`. Subject: gentle-ai
(Go ecosystem configurator) and its SDD layer as materialized in Claude Code / OpenCode. Written
2026-06-28 by a read-only sweep with 7 parallel sub-agents, styled after the `niagara-research`
corpus and using the same certainty markers.

**No `RESEARCH-STATE.md` — BOOTSTRAP is owed.** The corpus has an index and a catalog but no gap
backlog and no iteration history; `git log` shows only two commits (add, then translate to English).
It was written in one pass and never ran the loop. `verify-registry.sh` therefore reports it as
`corpus layout not resolvable … cannot recount blocks` — correctly refusing to invent a count rather
than silently reporting zero.

**Staleness — one full MAJOR version.** The corpus documents gentle-ai **v1.43.2**; the installed
binary is **v2.2.0** `[CERT]`. A block-by-block audit on 2026-07-28 returned **8 STALE** (11, 12, 15,
18, 19, 22, 26, 27) · **11 INCOMPLETE** (1, 2, 3, 10, 14, 16, 17, 20, 21, 24, 25) · **8 CURRENT**
(4, 5, 6, 7, 8, 9, 13, 23). The cause is **Receipt-Driven Development**, introduced in `v1.47.0` on
2026-07-10; the module moved to `/v2` because Go requires the `/vN` suffix at major ≥ 2
(`Cellar/gentle-ai/2.2.0/README.md:29,159`). Uncovered subsystems: the whole `review` command family
(3–5 blocks), `sdd-attempt`, `sdd-verify-validate`, the 4R lenses as native sub-agents,
`skill-registry list`.

> **Do not deep-document the `review` surface yet.** Upstream declares it unstable: *"RDD is unstable.
> Every release from v1.47.0 onward is part of the RDD development line and may change"*
> (`README.md:21`), and names `v1.46.0` as the last stable release without RDD. Document the
> architecture and the contract — which stabilise first — and mark the CLI surface as moving.

**Provenance caveat.** Each block's `SOURCES` header cites per-machine absolute paths
(`/home/cristian/.claude/CLAUDE.md`, `/home/cristian/.config/opencode/skills/...`). Those citations
resolve on one laptop only, and v2.2.0 has since rewritten several of the files they point at — so
the provenance is both unportable and partly dangling. Re-cite when refreshing a block.

**Tooling.** `tools/gen-catalog.py` at the repo root is a corpus-specialized fork of the kit
generator: it matches `^sdd-mental-model-bloque(\d+)\.md$` rather than the generic prefix-aware
discriminator (`toolbelt/tests/gen-catalog.test.sh:18,130`). `research-sdd-archive.sh` already
prefers a target's local generator over the kit's for exactly this reason.

---

## Targets whose type I could NOT confirm 100%

- **api-openness (#5)** `[INFER]`: confirmed as a .NET API by the XML doc, but **I did not inspect the `.dll` assembly** of `Siemens.Engineering`; `decompile-net.sh` remains an unverified recommendation against the binary.
- **API-FACTURAS (#10)** `[INFER]`: the CONTPAQi SDK has JARs (Java, `[CERT]`) and native DLLs, but **I did not run `file` discriminating .NET vs native** on each DLL; the choice between `decompile-net.sh` and `decompile-native.sh` per DLL remains pending.

## Profiler false positives to ignore
- `cadesimu` and `API-FACTURAS`: the `PE32 → decompile-net.sh?` and `ELF → decompile-native.sh` come from `.venv` (PIL `*.so`, `pip`/`distlib` launchers `t32/t64/w32/w64.exe`). **They are not targets.**

---

## De-registered — not block corpora

These were formerly rows #6, #11 and #12. Verification on 2026-07-15 confirmed they are **NOT
research-sdd block corpora** — they are Python code/tooling projects (no INDEX, no
`*-block`/`*-bloque` files, no research-sdd markers). They are removed from the ACTIVE registry.
Paths below are intentionally in PLAIN TEXT (no backticks). The toolbelt parser
(verify-registry.sh / sweep-retros.sh / sweep-audits.sh) registers a target only when its
absolute path appears wrapped in backticks; leaving these paths unwrapped keeps them
de-registered.

- **openness-labs** — path: /home/cristian/PLC/openness-labs
  - Reason: Python code/tooling project (TIA Openness experiment lab), not a research-sdd block corpus; verified 2026-07-15.
  - Salvaged profiling notes (prior maturity **intermediate** `[CERT]`): experiment lab over TIA Portal
    Openness — 230 `.py`, 74 `.md` (inside `experiments/`), SCL/XML; git present, remote yes, **no hook**,
    own `CLAUDE.md`. Notes distributed per experiment, not centralized in an index. Prior toolbelt note:
    direct reading + CodeGraph (no binaries). Corpus language inferred Spanish/EN `[INFER]` (never confirmed
    by reading the `.md`).

- **openness-tools** — path: /home/cristian/PLC/openness-tools
  - Reason: Python code/tooling project (Openness automation tooling), not a research-sdd block corpus; verified 2026-07-15.
  - Salvaged profiling notes (prior maturity **intermediate** `[CERT]`): Openness automation tooling —
    95 `.py`, daemon (py/ps1), generators, `offline-validator`, tests, 51 KB `CHANGELOG.md`, 33 KB
    `CLAUDE.md`; git present, remote yes, **no hook**, 27 `.md`. It is own source code: direct reading +
    CodeGraph, no decompilation required. Corpus language inferred Spanish/EN `[INFER]` (language only —
    type confirmed Python source, never confirmed by reading the `.md`).
- **cadesimu** — path: /home/cristian/investigacion/cadesimu
  - Reason: Python reverse-engineering tooling project (CADe_SIMU electrical simulator), not a research-sdd block corpus; verified 2026-07-15. Genuine RE research exists but lives as project docs, not a block-structured corpus with an INDEX.
  - Salvaged profiling notes (prior maturity **incipient** `[CERT]`): 0 `.md` at root, 6 in `docs/` (CAD_FORMAT, REVERSE_ENGINEERING, SYMBOL_CODES, TERMINAL_MODEL); own Python render/parse scripts (`cad_parser.py`, `render_cad.py`, `build_*.py`) + generated PNGs; no git, no hook. Real CADe_SIMU binary not present (detected ELF/.exe are `.venv` false positives). If converted later: run research-sdd-init + structure the RE findings into blocks.
