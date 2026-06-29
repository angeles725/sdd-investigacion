# Audit — niagara-research CORPUS · Coverage / Completeness audit

> Question: **has the niagara-research corpus covered everything, or what remains uncovered?**
> What was audited: the full 122-block + TI corpus at `/home/cristian/niagara-research` (INDEX.md,
> CATALOG.md, RESEARCH-STATE.md) vs the AVAILABLE source universe (the 926-JAR / 51,167-class
> decompile inventory at `/home/cristian/Honeywell/OptimizerSupervisor-N4.14.0.162/module-navigator`,
> the 667 entries under `/home/cristian/modules/Prototipos/modulos/organized/`, and the Tridium
> `niagara-help` doc bundle). Method: read the corpus maps, enumerate the source universe, cross-grep
> every candidate module NAME against all block `.md` files to find subsystems with NO block.
> READ-ONLY on the corpus — this report is the only artifact written. NOTE: paths in source docs use
> `C:\modules\...`; the live tree is `/home/cristian/modules/...`.

---

## 1. What IS covered (map by layer)

The corpus is organized into 23 "Capas" (layers), 122 numbered blocks (B1–B122, B43 absent) + the
Test-Infrastructure block (TI). Source of truth: `niagara-research/INDEX.md` + `CATALOG.md`.

| Capa | Blocks | Covered area |
|---|---|---|
| 1–5 | B1–B13 | N4 framework core: Baja object model, ORD/BOG/BQL/NEQL, Control engine + kitControl, Drivers framework, Alarm/History/Schedule, UI stack, Platform/Station lifecycle, Auth/RBAC, Build system, deep gaps |
| 6–9 | B14–B20 | Templates/Provisioning/Analytics(intro), filesystem forensics + native binaries, module signing/CSRF, LON+NRIO+BOX wire, misc residuals |
| 10–13 | B21–B32 | Tag framework/Haystack4, PX/BajaUI/BajaScript, BACnet deep, Schedule/Migration/Build/Help/Native, Network/Discovery/Virtual/Web tier, Enterprise auth/FIPS/Performance/Honeywell runtime |
| 14–15 | B33–B41 | History/Alarm/UX deep, EU drivers, Flota mgmt, operational Honeywell artifacts, runtime decompile |
| 16 | B42–B52 | Frontend: external 100%-custom SPA ↔ N4 station (subscribe/alarm/history/writes/RBAC/i18n/CSRF) — CLOSED |
| 17 | B50–B65 | Reflow audit cross-stack (Vue 2.7 SPA) + MX60 synthesis — 100% COMPLETE |
| 18 | B66–B68 | Tridium Analytics module deep dive (constructive, MX60-analytics) |
| 19–20 | B69–B74 | Live-update patterns + TIER-1 triple-source audits (Equipment/Alarms/History) |
| 21 | TI, B75, B112–B114 | Test infrastructure + security incident arc: unsigned-module attack (B75), defensive detection (B112), module-signing hardening (B113), BOG/secrets encryption (B114) |
| 22 | B77–B111 | **OEM Honeywell/Centraline deobfuscation** (~35 modules): Spyder BACnet/LON drivers, Centraline C-Bus/EnOcean/PanelBus/HVAC, cloud stack (Sentience/Forge/Azure IoT), tag dictionaries, MQTT/LoRaWAN, plantController/HMI, LON AX wizards, KNXnet/IP, Device Manager OTA, Smart Edge TR50, Venom TAB, thermostat wizards, IPC/CIPer, function-block engines (honeywellFunctionBlocks/honIOBase/honIrmControl/honeywellSpyderTool), ASCOT/Stryker, honImporter/honProjectExport, honRemoteConfig, honEagleHawkHMI |
| 23 | B76 | Own-module dev (`chihuahua` port) |
| (Spyder ext.) | B115–B122 | Spyder ecosystem deep-dive: spyderToIrmNxMigrator, bundled docs, full FB catalog, io layer, UI/wizard layer, driver wire protocol, Kingfisher/TR wall modules, XML resource extract |

**Coverage is conceptually COMPLETE** for: the N4 framework mental model, the external-SPA frontend
arc, the Reflow/MX60 frontend, the analytics module, the security/signing/encryption arc, and the
Honeywell/Centraline DDC + cloud + Spyder OEM stack.

---

## 2. The AVAILABLE universe (what COULD be covered)

- **Decompile inventory**: 926 JARs / 51,167 classes (`module-navigator/README.md`). Its own
  `GAPS.md` / `RESEARCH_ROADMAP.md` track only the *navigator tool's* features (all DONE); they do
  NOT enumerate un-analyzed research targets. `bog-coverage` (GAPS.md F16) reports station-BOG types
  resolve to **44/527 modules (8.3%)** — a useful proxy for how few modules appear in real stations.
- **`organized/` tree**: 667 entries. Breakdown: **207 `lon*` vendor profile drivers**,
  **80 `doc*` doc bundles**, **41 `niagaraLexicon*` translation bundles**, 73 `hon*/honeywell*`,
  27 `cl*` (Centraline), 27 `plat*`, plus Tridium framework modules.
- **`niagara-help`**: Tridium official docs (3,586 bajadoc HTML, 472 devguide, 8,971 guides,
  per-product PDFs-as-text). Only `docHoneywellSpyder` synthesized into a block (B116).

---

## 3. Coverage gaps (subsystems present in source, absent from the 122 blocks)

Every "where" path below is real and grep-verified absent from all block `.md` files (mention
count 0–1 = no dedicated treatment; all 122 block subjects known from CATALOG.md).

| # | Uncovered area | Where the source is (`organized/…` unless noted) | State | Priority |
|---|---|---|---|---|
| U1 | **honIrmAppl + honIrmConfig** — IRM/BEATS application + config layers (completes the triad with B105 `honIrmControl`) | `honIrmAppl/`, `honIrmConfig/` | investigable | **HIGH** |
| U2 | **honFirmwarePackage + honeywellVersionManager** — firmware packaging + version mgmt (supply-chain; ties to B94 OTA + B75/B113 signing arc) | `honFirmwarePackage/`, `honeywellVersionManager/` | investigable | **HIGH** |
| U3 | **honAlarmConsole + honAlarmExt** — Honeywell alarm console + alarm extensions (OEM layer over B8/B34 alarm) | `honAlarmConsole/`, `honAlarmExt/` | investigable | **HIGH** |
| U4 | **SylkActuatorAnalytics + lonHoneywellAnalytics** — Honeywell OEM analytics (ties to B66–68 + B88 Sylk) | `SylkActuatorAnalytics/`, `lonHoneywellAnalytics/` | investigable | MED-HIGH |
| U5 | Honeywell utility modules — BACnet helper, BAC restore, lonsock client, description utility | `honBacnetHelper/`, `honUtilityBacRestore/`, `honLonsockClient/`, `honDescriptionUtility/` | investigable | MED |
| U6 | **honeywellAXPlatinum(+HR), honeywellASC** — legacy AX / ASCOT-adjacent OEM (note B107 covered `ascCommon/ascBacnet/ascLon`, NOT `honeywellASC`) | `honeywellAXPlatinum/`, `honeywellAXPlatinumHR/`, `honeywellASC/` | investigable | MED |
| U7 | **Forge Connect onboarding + model-sync variants** — only `fcModelSync` (B85) + `honCloudEasyOnboard` (B84) covered; `fcEasyOnboard` has 0 mentions | `fcEasyOnboard/`, `fcModelSyncBacnet/`, `fcModelSyncNiagara/` | investigable | MED |
| U8 | **Centraline residue** — AHU/Heating PX graphics, LON IO r5, profile, station-upgrade tool, extensions, printout, DIN symbols | `CentralineAhuPx/`, `CentralineHtgPx/`, `CentralineLONIOr5/`, `clProfile/`, `clStationUpgradeTool/`, `clExtensions/`, `clPrintout/`, `DINsymbol/` | investigable | MED |
| U9 | **Honeywell Modbus smart-sensor + plantController migrators** (B95 covered BACnet TR50; B90 touched migrators) — partial | `honeywellModbusSmartSensor/`, `honPlantControllerMigrator/`, `honPlantControllerEHMigrator/` | investigable | LOW-MED |
| U10 | **Other-vendor OEM drivers** — Andover, Carrier CCN, McQuay, AAP, MAXPRO, Orion, Silk, axvelocity, BACnet FFT | `andoverAC256/`, `andoverInfinity/`, `ccn/`, `mcquay/`, `aaphp/`, `aapup/`, `maxpro/`, `orion/`, `alarmOrion/`, `silk/`, `axvelocity/`, `BACnetFFTN4/` | investigable | LOW-MED |
| U11 | **Video subsystem** — entire Tridium/OEM video stack, no block | `nvideo/`, `naxisVideo/`, `remoteVideo/`, `videoDriver/`, `videoMigrator/`, `baseRtsp/`, `xprotect/`, `maxpro/` | investigable (out of Honeywell-BMS mission) | LOW |
| U12 | **Tridium framework drivers not deep-distilled** — OPC-UA stack, Modbus framework, M-Bus, SNMP, oBIX driver, OpenADR, weather | `opcUaClient/Core/Server/`, `opc/`, `modbusCore/Async/Tcp*/Slave*/`, `mbus/`, `snmp*/`, `nSnmp/`, `obixDriver/`, `openAdr/`, `weather/`, `weatherUnderground/` | investigable (mostly out of mission) | LOW |
| U13 | **Data + service framework** — RDBMS integration, system DB, reporting, search, dashboard, virtual (B28 only touched virtual) | `rdb*/`, `systemDb/`, `orientSystemDb/`, `report/`, `search/`, `dashboard/`, `niagaraVirtual/` | investigable (out of mission) | LOW |
| U14 | **Extended auth/identity** beyond B11/B30 RBAC+federation — SAML, OAuth2, LDAP, gauth, client-cert, e-signature | `saml/`, `samlEncryption/`, `oauth2/`, `ldap/`, `gauth/`, `clientCertAuth/`, `electronicSignature*/` | investigable (security-relevant) | LOW-MED |
| U15 | **Tridium doc corpus (niagara-help)** — ~80 `doc*` bundles + the `niagara-help` tree un-synthesized into blocks (only `docHoneywellSpyder`=B116 done) | `organized/doc*/`, `Honeywell/…/niagara-help/` | investigable (doc-synthesis, not code-distillation) | LOW |
| U16 | **207 `lon*` vendor profile drivers** — LonMark XIF device profiles; B19/B92 cover LON framework + Honeywell LON wizards; per-vendor profiles untreated | `organized/lon{Aaon…Zytron}/` | OUT-OF-SCOPE (repetitive profile data, near-zero unique logic) | N/A |
| U17 | **41 `niagaraLexicon*` translation bundles** | `organized/niagaraLexicon*/` | OUT-OF-SCOPE (i18n strings) | N/A |
| B-1 | **G8** — Spyder→IRM round-trip migration FIDELITY (B115 lossy FB reconstructions) | needs migrated `.bog` on a **live IRM/BEATS controller** | **BLOCKED — requires-execution/hardware** | (deferred) |
| B-2 | **G5b** — `tasowizSupport` module internals (CV-AHU/VAV/LCBS wizard templates) | module **absent** from `organized/` (confirmed: no such dir); referenced only by string+reflection | **BLOCKED — missing artifact** | (deferred) |

---

## 4. Metrics

- **Blocks**: 122 numbered (B1–B122, B43 missing) + 1 Test-Infra = **123 blocks**, ~23 layers.
- **Source universe**: 926 JARs / 51,167 classes; **667** `organized/` entries.
- **Modules with a dedicated block**: ~**55–60** distinct modules (framework core + ~35 Capa-22 OEM
  modules + Reflow/analytics/frontend targets).
- **`organized/` entries that are low-information / out-of-scope**: 207 LON profiles + 41 lexicons +
  80 doc bundles = **328 (~49%)**. "Real, distinct-logic" modules ≈ **~340**.
- **Coverage estimate**:
  - Against the corpus's **stated mission** (N4 mental model + Honeywell OEM stack + frontend +
    analytics + security): **~90% complete** — the mission areas are saturated.
  - Against the **full decompiled universe** of distinct-logic modules (~340): **~17–20%** by module
    count; the framework CORE is conceptually covered, but dozens of OEM/framework driver modules
    have no dedicated block.
  - The Spyder-ecosystem sub-focus (RESEARCH-STATE.md): **read-only-investigable backlog = 0** (its
    own declared 100% within that narrow scope).

---

## 5. Honest verdict

**No — niagara-research is NOT "all done" in an absolute sense, but it IS effectively complete for
its declared mission.** The "STATIC loop STOPPED" / "backlog EMPTY" declaration in RESEARCH-STATE.md
applies ONLY to the **Honeywell Spyder ecosystem** sub-focus (7/7 read-only gaps closed). That file
explicitly scopes itself and even states "the broader niagara corpus (B1–B114) is mature." It is NOT
a claim that the entire 51k-class universe is covered.

Against the available decompiled source, real uncovered ground remains — and the most valuable of it
sits **squarely inside the corpus's own OEM-Honeywell theme** (Capa 22), so it is both high-value and
immediately investigable:

- **Top investigable gaps (do these next):** U1 `honIrmAppl`+`honIrmConfig` (closes the IRM/BEATS
  triad next to B105), U2 `honFirmwarePackage`+`honeywellVersionManager` (firmware supply-chain,
  security-adjacent to the B75/B94/B113 arc), U3 `honAlarmConsole`+`honAlarmExt`, U4
  `SylkActuatorAnalytics`+`lonHoneywellAnalytics`. All decompiled and present in `organized/`.
- **Secondary investigable:** U5–U10 (Honeywell utilities, AX Platinum/ASC, Forge onboarding,
  Centraline residue, other-vendor drivers).
- **Lower priority / arguably out-of-mission but investigable:** U11 video, U12 OPC-UA/Modbus/M-Bus/
  SNMP/oBIX framework drivers, U13 RDB/report/search/dashboard, U14 extended auth, U15 the Tridium
  doc corpus (doc-synthesis work, not code-distillation).
- **Genuinely out-of-scope:** U16 the 207 LON vendor profiles (repetitive XIF data) and U17 the 41
  lexicons (translations) — covering these would inflate block count with near-zero new knowledge.
- **Blocked (cannot do now):** G8 (needs live IRM/BEATS hardware) and G5b (needs the `tasowizSupport`
  JAR added to `organized/` — confirmed absent).

**Bottom line:** the corpus has saturated the Niagara N4 framework model, the frontend arc, and the
Honeywell DDC/cloud/Spyder stack. What remains is a real, prioritizable tail of ~25–40 distinct OEM
and framework modules (plus the un-synthesized Tridium doc corpus), led by the four HIGH-priority
Honeywell modules above, after which only out-of-scope profile/lexicon bulk and two hardware/artifact-
blocked gaps are left.
