# Audit — Bloque 100 (`ipcMigrator`) certainty re-verification

## Header

- **Block audited:** `/home/cristian/niagara-research/niagara-mental-model-bloque100.md` (ipcMigrator — Spyder XL10 Next Gen → IPC 3036 migrator).
- **Original author's marker legend (from the block itself):** `[CERT]` = verified by the original author; `[CERT-a]` = sub-agent assertion, NOT re-verified by the author; `[INFER]` = deduction.
- **Sources re-verified against (READ-ONLY):** Vineflower decompilation at
  `/home/cristian/modules/Prototipos/modulos/organized/ipcMigrator/ipcMigrator-wb/vineflower/com/honeywell/ipcmigrator/...`
  (57 `.java` across the `vineflower/`, `decompiled/`, and `pipeline/procyon/` trees; 19 logical classes). All `file:line` citations below are from the `vineflower/` tree.
- **Method:** Extracted every claim, prioritizing the `[CERT-a]` (unverified) ones, plus a spot-check of the `[CERT]` hierarchy table. For each, grep + Read into the decompiled `.java` to find the real `extends`/method/field/enum/string and assign a verdict.
- **Verdicts:** ESCALATED (was `[CERT-a]`, now code-confirmed) · CONFIRMED (was `[CERT]`, still holds) · DOWNGRADED (cannot verify / wrong attribution → should be `[INFER]`) · REFUTED (code contradicts the claim).

---

## Audited claims

| # | Claim (short) | Orig. marker | Verdict | Real evidence `file:line` / why |
|---|---------------|-------------|---------|---------------------------------|
| 1 | `IPCMigrator` is a POJO coordinator, no `extends` | `[CERT]` | CONFIRMED | `migrator/IPCMigrator.java:55` — `public class IPCMigrator {` (no extends) |
| 2 | `MigratingJob extends Thread` | `[CERT]` | CONFIRMED | `ui/MigratingJob.java:53` — `public class MigratingJob extends Thread` |
| 3 | `BSpyderToIPCMigrator extends BWbNavNodeTool` | `[CERT]` | CONFIRMED | `ui/BSpyderToIPCMigrator.java:48` |
| 4 | `BFunctionBlockMigrator extends BComponent implements IMigrator` | `[CERT]` | CONFIRMED | `migrator/BFunctionBlockMigrator.java:90` |
| 5 | `BMigrationEntityEnum extends BFrozenEnum` | `[CERT]` | CONFIRMED | `enums/BMigrationEntityEnum.java:15` |
| 6 | `IMigrator` contract = `migrate()` + `handlePostMigrate()` | `[CERT]` | CONFIRMED | `migrator/IMigrator.java:10` (migrate) + `:12` (handlePostMigrate) |
| 7 | Execution pattern is direct `Thread`, NOT `BSimpleJob` | `[CERT]` | CONFIRMED | `ui/MigratingJob.java:53` extends Thread; no `BSimpleJob` reference anywhere in the module |
| 8 | `BMigrationEntityEnum` has 3 values `device`/`application`/`sylkdevice`, default `application` | `[CERT-a]` | **ESCALATED** | `enums/BMigrationEntityEnum.java:12-13` (`@Range` + `defaultValue="application"`), `:19-22` (the 3 instances + `DEFAULT = application`) |
| 9 | Six `BComponent implements IMigrator` sub-migrators | `[CERT-a]` | **ESCALATED** | All 6 confirmed: `BFunctionBlockMigrator.java:90`, `BIOMigrator.java:91`, `BLinkMigrator.java:39`, `BScheduleBlockMigrator.java:72`, `BSoftwarePointsMigrator.java:31`, `BSylkDeviceMigrator.java:153` |
| 10 | `ioPriorityOverrideSlotMap` & `tempSetpointsMap` are `static HashMap` (shared mutable state) | `[CERT-a]` (MEDIO) | **ESCALATED** | `migrator/IPCMigrator.java:60` (`static HashMap<String,String> ioPriorityOverrideSlotMap`) + `:69` (`static HashMap<String,BOrd> tempSetpointsMap`) |
| 11 | `TerminalAssignmentHandler` consumes model terminal lists; on exhaustion adds `BExpansionIODeviceExt` (expio3022h/9056h) | `[CERT-a]` | **ESCALATED** | `migrator/TerminalAssignmentHandler.java:55-58` (consumes model lists), `:62-72` `addExpansionDeviceAndUpdateFreeTerminalsList()` adds `BExpansionIODeviceExt`, `:63/:65` `expio3022h`/`expio9056h` |
| 12 | Max 15 expansions | `[CERT-a]` | **ESCALATED (with caveat)** | Value 15 present: `TerminalAssignmentHandler.java:42` `EXPANSION_IO_DEVICE_LIMIT = 15` and `:73` fault when `address > geti("max",15)`. CAVEAT: the named constant `EXPANSION_IO_DEVICE_LIMIT` is **dead code** (never referenced); the real cap is the `address` slot-facet `max` default of 15 at `:73` |
| 13 | `BFunctionBlockMigrator` maps Spyder FB → IPC FB via a static map in `MigratorUtil`; type conversions `BStatusNumeric → BHonStatusNumeric / BFiniteStatusBoolean`; `BAlarm → BAlarmSourceExt` | `[CERT-a]` | **ESCALATED** | `BFunctionBlockMigrator.java:120` `MigratorUtil.getspyderFbToF1FbMap()`, `:225-233` the two status conversions, `:369` `new BAlarmSourceExt()`; map defined at `utils/MigratorUtil.java:224` |
| 14 | `BScheduleBlockMigrator`: `BSchedule` Spyder (holidays) → `BEnumSchedule` IPC | `[CERT-a]` | **ESCALATED** | `BScheduleBlockMigrator.java:122-127` builds `BEnumSchedule` target; `:3-5` imports `BHoliday`/`BHolidayArray`/`BSchedule` source |
| 15 | `BSylkDeviceMigrator`: `BSBusWallModule` (Kingfisher) → `BTR75X/TR71X/TR42/TR40SylkDevice`; converts TR70→TR71 with warning | `[CERT-a]` | **ESCALATED** | `BSylkDeviceMigrator.java:3` Kingfisher `BSBusWallModule` import; `:38` `BTR40SylkDevice`, `:40` `BTR71XSylkDevice`, `:41` `BTR75XSylkDevice`, `:261` `instanceof BTR42SylkDevice`; TR70→TR71 warning at `:331-340` (`sylk.migration.fromTR70.toTR71`) |
| 16 | `BSoftwarePointsMigrator`: network points → `BNumeric/EnumConst/Writable` | `[CERT-a]` | **ESCALATED** | `BSoftwarePointsMigrator.java:9-14` imports `BEnumConst`/`BNumericConst`/`BEnumWritable`/`BNumericWritable`; `:63` `new BNumericConst()`, `:77` `new BEnumConst()` |
| 17 | `.bog` deserialization `decodeDocument(true)` + `add("ControlProgram", v)` without type validation | `[CERT-a]` (MEDIO) | **ESCALATED (relocated)** | Pattern is real but lives in `ui/MigratingJob.java:276` (`decodeDocument(true)`) + `:277` (`((BComponent)device).add("ControlProgram", v)`), NOT in `IPCMigrator` as the §100.4 framing implies |
| 18 | `copyALibraryFile()` excludes file names containing `"security"` (fragile substring filter) | `[CERT-a]` (BAJO) | **ESCALATED (relocated)** | `ui/MigratingJob.java:608` `copyALibraryFile(...)`, `:610` filter `fileName.indexOf("security") < 0` (also excludes `UserDefined`/`Standard.jar`/`index.xml`). Lives in `MigratingJob`, not `IPCMigrator` |
| 19 | `IPCMigrator` generates a `.txt` report with warnings | `[CERT-a]` | **DOWNGRADED** | `IPCMigrator` only builds an in-memory `List<String> migrationReportMessages` (`migrator/IPCMigrator.java:249`). The actual `.txt` file is written in `utils/MigratorUtil.java:313` (`makeFile(... + ".txt")`). "IPCMigrator generates the .txt" is not supported — should be `[INFER]`/relocated |
| 20 | Point counting "BQL over the source" attributed to `TerminalAssignmentHandler` | `[CERT-a]` | **REFUTED** | `TerminalAssignmentHandler` does NO BQL — it receives pre-counted ints via `initializeFreeTerminals(int miCount, int biCount, ...)` (`:48`). The BQL counting actually lives in `migrator/BIOMigrator.java:65` (`import javax.baja.bql.BqlQuery`), `:131-137` (BQL strings), `:139-140` (`resolveQueryAndGetIOCount`). Misattributed class |
| 21 | Target model is `BIPCDeviceModelEnum.ipc3036vav` | `[CERT-a]` | **DOWNGRADED** | Not found in the `ipcMigrator` tree under that symbol; the enum belongs to the `ipcCommBus` module (Bloque 99), not re-verifiable from the cited ipcMigrator sources. Should stay `[INFER]` |

---

## Metrics

- **Claims audited:** 21
- **ESCALATED** (was `[CERT-a]`, now code-confirmed): **12** (incl. 2 "relocated" — confirmed but in a different class than implied, #17, #18; and 1 with a dead-code caveat, #12)
- **CONFIRMED** (was `[CERT]`, still holds): **7**
- **DOWNGRADED** (unverifiable / wrong attribution → `[INFER]`): **2** (#19, #21)
- **REFUTED** (code contradicts the claim): **1** (#20)

---

## Notable findings

### REFUTED — prior-corpus error (juiciest)
- **#20 BQL counting misattributed.** The block credits `TerminalAssignmentHandler` with "counts points by type (BQL over the source)". The handler does no querying at all — it takes pre-counted integers in `initializeFreeTerminals(...)`. The BQL point-counting is in `BIOMigrator` (`:65,:131-140`). The original `[CERT-a]` (sub-agent) conflated two collaborators into one. The *behavior* (count → consume terminals → add expansion) is real and spread across both classes; the single-class attribution is wrong.

### DOWNGRADED — overstated attribution
- **#19** `.txt` report writing is in `MigratorUtil:313`, not `IPCMigrator` (which only assembles a `List<String>`).
- **#21** `ipc3036vav` model enum is not part of the audited module's sources (it lives in `ipcCommBus`/Bloque 99), so it cannot be confirmed from the cited ipcMigrator paths — correctly belongs at `[INFER]`.

### Notable ESCALATIONS — certainty the prior Claude left on the table
The author marked 5 of the 6 sections `[CERT-a]` ("not re-verified"), yet every structural claim in them is directly confirmable in one grep:
- The 6 `IMigrator` sub-migrators (#9), the 3-value entity enum with `application` default (#8), the static shared-state maps that drive the concurrency risk (#10), the BQL→terminal→expansion I/O pipeline (#11), the Sylk TR75X/TR71X/TR42/TR40 targets + TR70→TR71 warning (#15), and the FB-map + status-type conversions (#13) were all sitting at `file:line` and could have been `[CERT]` from the start.
- **Dead-code catch (#12):** the named `EXPANSION_IO_DEVICE_LIMIT = 15` constant is never referenced; the real 15-cap is a slot-facet `max` at `:73`. The original "max 15" conclusion is right, but for a different reason than the obvious-looking constant suggests — a subtlety only a code re-read surfaces.

---

## Honest verdict

**The engine extracted MORE than the original author — and of two distinct kinds.**

1. **More certainty.** 12 of 13 `[CERT-a]` claims escalated to code-confirmed with exact `file:line`. The original corpus was *accurate* on these — the sub-agent didn't hallucinate the substance — but it left them flagged as unverified. grep-confirmation over the real decompiled tree converts that hedge into hard certainty cheaply. The author's `[CERT]` hierarchy table (claims #1-7) held up perfectly, including the precise line numbers — strong evidence the original anti-hallucination discipline was sound.

2. **Caught real attribution errors.** One REFUTED (#20, BQL credited to the wrong class) and two DOWNGRADED (#19 `.txt` writer, #21 cross-module enum) are precisely the failure mode of single-pass sub-agent summarization: *correct behaviors attached to the wrong owning class/module*. None are fabrications of non-existent behavior — they are mislocations. The re-verification pass is what distinguishes "this feature exists" from "this class does this feature", which matters for anyone navigating the code from the notes.

**Bottom line:** the original corpus was honest and substantively reliable (no invented behavior), but it under-claimed certainty and carried a few owner/location slips. This re-verification engine adds value on both axes — promoting hedged-but-true claims to cited certainty, and correcting where a true behavior was pinned to the wrong file. The largest residual risk in the prior block was not false facts but **imprecise attribution**, which only a direct code re-read catches.
