# Niagara N4 framework — runtime provisioning, READONLY set(), and native BOG export/import

Reusable framework knowledge for ANY Niagara N4 target: how to instantiate and wire components at
runtime, how to write "read-only" persistent slots from provisioning code, and how the platform's OWN
serialization (BOG) captures a component subtree — links, config and all — so you rarely need to hand-roll
JSON. Plus two Gradle build-environment gotchas that stop a Niagara module build cold.

**Evidence base.** Original Tridium javadoc source (not decompiled), under
`/home/cristian/modules/Prototipos/modulos/organized/docSource/docSource-doc/extracted/` (abbrev. `EXT/`),
plus the official devguide (`niagara-help/devguide-clean/bog.txt`). `[CERT-doc]` = official doc §; `[CERT]` =
framework source file:line; `[INFER]` = derived. First captured in the chihuahua MX60 investigation chain
(2026-08-16); see Engram `research/niagara/framework/bog-export-import`.

**Read-only over the subject.** These are the supported APIs; nothing here mutates a live station by itself.

---

## 1. Instantiate + add a child BComponent at runtime `[CERT]`

**Instantiate via `Type.getInstance()` — there is no public `Type.newInstance()`.**
- `Type.getInstance()` is polymorphic (`EXT/baja/javax/baja/sys/Type.java:144-155`): `BComplex` → `new`
  (no-arg ctor); `BSingleton` → `INSTANCE`; `BSimple` → `DEFAULT`.
- The framework's own BOG decoder proves this is the canonical path: it instantiates every decoded component
  via `(BValue) type.getInstance()` (`EXT/baja/javax/baja/io/ValueDocDecoder.java:1749`).

**Add with the full overload + a Context.**
```
public final Property add(String name, BValue value, int flags, BFacets facets, Context context)
```
`EXT/baja/javax/baja/sys/BComponent.java:874-911`. Name rules follow SlotPath BNF; `null` name auto-names;
trailing `?` auto-suffixes. Throws `DuplicateSlotException`, `AlreadyParentedException` (copy the value first
if it is already parented), and **`PermissionException` if the context user lacks adminWrite**.

**`started()` fires by itself when you add under a running, mounted parent.** `started()` javadoc
(`BComponent.java:333-341`): components start **top-down, children after their parent**. The component-space
start propagation drives it; you do **not** call `start()` yourself. `Flags.NO_RUN` stops the recursion for a
given slot (`Flags.java:61-65`). `added(Property, Context)` is the post-add callback (`BComponent.java:1399`).
[INFER: the auto-start-on-add is derived from the decoder never calling start() explicitly and relying on the
space; the lifecycle javadoc is [CERT].]

**Provisioning shape:** `BComponent c = (BComponent) type.getInstance(); parent.add(name, c, flags, facets, Context.decoding);`

---

## 2. Writing a "READONLY" persistent slot from code `[CERT]`

**`Flags.READONLY` does NOT block a programmatic `set()`.** It is a UI / user-permission hint only.
- `Flags.java:24-28` / `:183`: READONLY marks slots **"not accessible to users"** (UI edit + `BPermissions`),
  `HIDDEN` (`:38-43`) and `SUMMARY` (`:45-51`) are likewise UI/tooling hints. None gates a code `set()`.
- `BComplex.set(Property, BValue, Context)` (`EXT/baja/javax/baja/sys/BComplex.java:826-851`) lists exactly one
  access throw: **`PermissionException` if the *context user* lacks write** — READONLY is not a blocker. With a
  system / no-user context, no permission check applies.
- The encoder forces READONLY into output **only** when a user-bearing context lacks write
  (`ValueDocEncoder.java:726`); a system encode writes everything as-is.

**Supported provisioning idiom — pass a system Context (`Context.decoding`), exactly as the decoder does:**
- value: `parent.set(prop, value, Context.decoding)` (`ValueDocDecoder.java:811`)
- flag mask (incl. restoring READONLY): `parent.setFlags(slot, flags, Context.decoding)` (`:704`)
- `Context.decoding` is the framework singleton for "decoding from a persistent source"
  (`EXT/baja/javax/baja/sys/Context.java:123-133`). Related: `Context.commit`, `Context.skipValidate`.

**Gotcha that looks like READONLY but is NOT** (real case, chihuahua importLinks): links/sets that target an
**Action** slot (e.g. `BNumericWritable.set`) died because the code resolved the slot with `BComplex.get(name)`,
which throws / misbehaves on an Action slot. Fix: resolve with **`getSlot(name)`** (does not throw for actions)
before deciding. READONLY was a red herring — a computed READONLY *Property* round-trips fine; the Action
target was the real failure. Rule: never expect a READONLY exception from `set()`; DO use `getSlot()` when a
target may be an Action.

---

## 3. Native subtree export/import — BOG (`ValueDocEncoder` / `ValueDocDecoder`)

**BOG = "Baja Object Graph"**, the framework's native XML serialization of a `BValue` tree. Official devguide
`bog.txt:6-20,54-58` `[CERT-doc]`: *"a standard XML format to store a tree of BValues… the best way to read
and write bog files is via the standard APIs — **ValueDocEncoder**… **encodeDocument()**… **ValueDocDecoder**…
**decodeDocument()**."*

- **`ValueDocEncoder` / `ValueDocDecoder` supersede legacy `BogEncoder`/`BogDecoder`** (`@since 3.7`):
  `ValueDocEncoder.java:73-78`, `ValueDocDecoder.java:78-80`. The old class names now resolve only as inner
  `BogEncoderPlugin`/`BogDecoderPlugin`.
- **`encode` defaults to the WHOLE subtree**: `encode(value) = encode(null, value, Integer.MAX_VALUE)`
  (`ValueDocEncoder.java:311-330`); `encodeDocument(BValue)` wraps it as a `<bajaObjectGraph>` document
  (`:300-306`).
- **It serializes everything in one pass**: every property incl. **READONLY/HIDDEN/SUMMARY** (flags → attr
  `f`, `:764-766`, `:1235-1240`), dynamic slots, facets (`x`), handle (`h`), category (`c`), type (`m`/`t`),
  and **LINKS** as first-class encoded slots (`encodeLink` `:984-1033`: sourceOrd, targetSlotName, enabled…).
- **Decode reconstructs faithfully**: `decodeDocument()` (`ValueDocDecoder.java:270-281`) → `type.getInstance()`
  (`:1749`) → restore flags `setFlags(slot,flags,Context.decoding)` (`:704`) → set props
  `set(prop,obj,Context.decoding)` (`:811`) → add dynamic children `add(...,Context.decoding)` (`:821`).
  Versions accepted: `1.0` (AX) and `4.0` (N4) (`:1207-1220`).
- **A `.bog` file IS this over a root component's subtree, zipped**: `BBogSpace.save()`
  (`EXT/file-rt/com/tridium/file/types/bog/BBogSpace.java:363-396`) = `ValueDocEncoder.encodeDocument(getRootComponent())`
  with `setZipped(true)`. The station's own `config.bog` and backups use the same encoder path.
- **Round-trip preserves READONLY values + links + config** — it is the same format the station DB uses, and
  decode writes through `Context.decoding` (no user → no permission gate). `[CERT]`

**When to prefer BOG over hand-rolled JSON:** capturing a component subtree WITH its links and READONLY config
(reinstall recovery, cloning a subtree). BOG is complete by construction — no per-slot-kind enumeration to get
wrong (which is exactly how a hand-rolled JSON exporter drops `Property→Action` links). **Downsides:** couples
to type-registration (decode needs the referencing modules loadable), to bog version `1.0`/`4.0`, and produces
opaque single-letter XML (hard to diff / curate); reversible `BPassword`s with a `keyring` key source are not
host-portable (use `none`/`external`). Prefer hand-rolled JSON only when you need a *selective / transformed*
export and accept owning the fragility.

**Zero-hit note (do not re-search):** there is no `StationSaveOp` class — station save is
`com.tridium.sys.station.BStationSaveJob`, same encoder path.

---

## 4. Gradle build-environment gotchas (Tridium module builds)

Two failures that stop `./deploy.sh` / `./gradlew` before any code compiles. Worked example: chihuahua MX60
(Gradle 7.6, Tridium `com.tridium.settings.multi-project`, Niagara 4.13 SDK, Java 8 toolchain).

### 4.1 Gradle 7.6 daemon cannot run on Java 26 `[CERT]`
Gradle 7.6 supports running its daemon on Java **8–19**; a system default of Java 26 makes the embedded Kotlin
throw `IllegalArgumentException: 26.0.1` while parsing the version (`JavaVersion.parse`). The lever people miss:
**the daemon JVM is distinct from the compile toolchain.** `-Porg.gradle.java.installations.paths=<jdk8>` sets
the **toolchain** (which JDK compiles), NOT the JVM that runs the daemon. Fix (minimal, Linux-scoped): prefix
the invocation so `gradlew` launches the daemon on Java 8 —
```sh
JAVA_HOME="$JAVA8" ./gradlew <tasks> -Porg.gradle.java.installations.paths="$JAVA8"
```
Do **not** hardcode `org.gradle.java.home` in a committed cross-platform `gradle.properties` (it usually carries
Windows default paths). For manual `./gradlew` outside the deploy script, use `~/.gradle/gradle.properties`.

### 4.2 `findProjects()` discovers by TWO layouts — scope it to exclude strays `[CERT]`
`com.tridium.settings.multi-project`'s `findProjects()` (no args) auto-discovers subprojects by **both**
`<proj>/<proj>.gradle.kts` **and** `<proj>/build.gradle.kts` (the plugin's own comment documents this). So a
stray `build.gradle.kts` anywhere under the repo — e.g. a `docs/.../template/build.gradle.kts` skeleton with an
empty `plugins {}` — gets discovered as a real project, its unapplied `vendor` extension throws
`Unresolved reference: defaultVendor / defaultModuleVersion`, and **every** gradle invocation breaks. There is
**no exclude API**; the sanctioned fix is inclusion-scoping — pass the real module container as an argument:
`findProjects("<module-root-subdir>")`. Project names still derive from the `<proj>.gradle.kts` filename, so
task paths like `:mymod-rt:jar` are unchanged (verify with `./gradlew projects`). Trivial fallback: rename the
stray `build.gradle.kts` → `.sample` so it stops matching.

---

## 5. When a slot change needs a vendorVersion `--bump` `[CERT-doc]`

Orthogonal but always relevant to Niagara module maintenance: a `vendorVersion` bump is required **only** for a
**new/modified frozen slot** (`@NiagaraProperty` / `@NiagaraAction` / `@NiagaraTopic`) on an already-instanced
`BComponent` — so the station's persisted `.bog` reconciles the new structure. A **code-only** change (method
body, data in a `static final` array) needs only recompile + station restart, **no bump**. Adding an
`@NiagaraAction` (e.g. an export/import action) IS a new frozen slot → bump. (chihuahua `BUILD_WORKFLOW.md:343`
positive rule, `:365` code-only carve-out.)

---

## 6. Licence files and code signing: SignTool is lossy, InPlaceSign surgery is the patch path `[#1901][#1579][#1581]`

**`SignTool` re-encoding is lossy for a full licence.** Re-encoding a Niagara licence through
`SignTool` collapses it down to the **root element only** — any nested structure the full licence
carried is dropped on the round-trip. `SignTool` is therefore not a safe tool for patching a
licence in place; it is a signer for a document it also silently truncates. [#1901]

**Standardize InPlaceSign textual surgery as the licence-patch path instead.** Rather than
re-encoding the whole document (lossy) or re-emitting it through the canonical writer, patch the
licence text directly and re-sign only the signature block in place:

- Edit the licence content as text (textual surgery), leaving everything the lossy re-encode would
  have dropped untouched.
  Evidence: `sign-run.log`. [#1901]

**The bench-JRE SHA1/DSA rejection.** Signing on the bench's own JRE failed because that JRE
rejects the licence's SHA1/DSA signature algorithm combination. **Fix:** sign on a local JDK
instead of the bench JRE — the local JDK accepts the SHA1/DSA combination the bench JRE rejects.
[#1901]

**General rule for a signed-jar target: rebuild + push + hash-verify, never an in-place archive
editor.** For signed-jar targets, prefer rebuilding the jar locally, pushing the rebuilt artifact,
and verifying its hash over using any in-place archive editor. .NET's `ZipArchive.Update` API
silently loses entries on an in-place edit; because the jar carries per-entry signature digests,
a silently dropped entry causes a **FATAL error at class load** time, not at edit time — the
failure surfaces far from its cause. Evidence: B1212 §1212.2, walls 2-3. [#1579]

**When the target's own canonical writer is itself part of what is being verified, sign via
in-place signature-block surgery and a fixpoint self-verify — never re-emit the file through that
writer.** Re-emitting through the writer under test contaminates the verification: any defect in
the writer now also affects the "known-good" artifact used to check it. Sign the artifact by
editing its signature block directly (the same textual-surgery discipline as the licence case
above) and confirm that the signing step is a fixpoint — a second application changes nothing more.
Evidence: B1212 §1212.3. [#1581]

**One branded licence per brand slot `[#2033]`.** The licence DB accepts at most ONE branded licence
per brand slot. Loading a second licence with a different `brandId` (observed: a second
`brandId=Webs` file) fails at DB-load time: `nre -licenses` prints that file as
`{invalid: Cannot have multiple branded licenses}` **and silently omits the entire Features
section** (16.5 KB of output collapsed to 595 B), so a missing Features section is a symptom of this
conflict, not of an empty licence. **Fix:** rename the conflicting file to `.disabled` (never delete
it) and keep the backup; the backup-before-destroy rule in METHODOLOGY §12 applies unchanged.
Evidence: B1217 §1217.3 (probe `o3-branded-conflict.txt`).

**Two security homes: install vs daemon `[#2034]`.** The platform daemon loads `security\` from its
OWN home (`C:\ProgramData\Niagara4.13\<brand>\security\`), while the interactive CLI oracle
(`nre -licenses`) reads the install context only. A licence or certificate the daemon must see
therefore has to exist in BOTH locations, and a `{valid}` from the CLI proves only the install side.

Live-licence deploy checklist step: after placing a licence or certificate in the install's
`security\`, place (or confirm) the same file under the daemon's `security\` home, verify both
copies against the source per the METHODOLOGY §12 hash-verify rule, and only then judge the daemon's behaviour.

The automated CHECK for install-vs-daemon parity is **deferred**: there is no substrate to build it
on yet and incidence is a single target. The recurrence (B1217 §1217.2; B1215 §1215.3; B1202/B1203
lineage) is recorded here as prose until a second target shows the same shape. Revisit trigger: when a second target shows the problem,
add a `--daemon-home` option to `niagara-security-audit.sh`. Refs #2034.

## 7. Module-load oracle: direct `station.exe <name>` launch `[#1902]`

**Standard oracle for "did this module load successfully": launch the station binary directly.**

```
station.exe <station-name>
```

This is the standard way to answer "does this station load without error" — no service switch
involved, and it leaves the host's N5 posture **untouched** (it does not flip the box into or out
of an N5-managed state). Prefer this direct launch over starting/stopping the Windows service when
the question is purely "does the module load".

**SCM env-staleness caveat for daemon-as-service boots.** When the station instead runs as a
Windows service (via the Service Control Manager), the service process inherits the environment
that was current **when the service was registered or last restarted by the SCM**, not the
environment visible in a fresh interactive session. A machine-wide environment change (see
REMOTE-POWERSHELL.md §8) made after the service last started is **not** visible to that running
service — restart the service (or re-register it) before trusting it to reflect a just-changed
environment variable. This caveat applies only to the service-boot path; the direct `station.exe`
launch above always reflects the environment of the shell that launched it.

Evidence: kit issue #1902 (R1.5/R1.6; `reflow-station-test4.log`).

**Multi-install bench: every CLI oracle verdict prints `niagara.home` `[#2031][#2032]`.** On a bench
with more than one Niagara install, the launcher can resolve a DIFFERENT install than the one under
test, so a `{valid}` with no home line is unaudited. Print `niagara.home` next to every CLI oracle
verdict (`nre -licenses`, `nre -version`, ...) and compare it to the intended install before
accepting the verdict. Evidence: B1216 §1216.5, §1216.1; B1217 §1217.1. This extends the "necessary,
not sufficient" note in METHODOLOGY §12 (kit #1540).

**`NIAGARA_HOME` at both scopes `[#2031]`.** A same-named user-scope variable (typically left behind
by a second OEM installer) shadows the machine-scope one; see REMOTE-POWERSHELL.md §8. Version-switch
scripts must set `NIAGARA_HOME` at BOTH Machine and User scope, mirror it into the running session
(`$env:NIAGARA_HOME = ...`; registry writes never reach a running process), and verify with `nre -version`, not
with service state.

## 8. Defensive notes: config.bog and credentials.xml exposure `[#1599][#1600][#1601]`

These are **defensive, authorized-lab hardening notes** — what an operator who already has local
file-system access to a Niagara host may be able to recover from its own configuration files, and
how to reduce that exposure. This is not a how-to for obtaining that access; it assumes it is
already present (e.g. an authorized assessment on a host the assessor already controls) and
describes the resulting risk and the mitigation. [#1599][#1600][#1601]

**What is at risk.** A Niagara station's `config.bog` and the Workbench `credentials.xml` can both
hold credential-related material. Depending on the configured key source, Niagara's reversible
credential encoding (`[aes-256.2]`) can make platform-level credentials recoverable by anyone who
already has a user-session foothold on the same host — i.e. once an attacker (or an unauthorized
party) has a local session, the credential store can be **plaintext-equivalent** rather than a
meaningful additional barrier. Treat both files as standard recon artifacts in a security
assessment of the host, and treat their presence with a reversible key source as a finding in its
own right, independent of whatever else is found on the box. [#1599][#1600]

**How to reduce the exposure (mitigations, in priority order):**
- Prefer a non-reversible / external key source for the credential store over a reversible
  on-host key source, so that local file access alone does not yield usable credentials.
- Treat `config.bog` and `credentials.xml` as File Integrity Monitoring (FIM) targets: an
  unexpected modification or read-time access to either file is itself a signal worth alerting on,
  not just a config-management concern.
- Review PBKDF2 iteration-count hygiene on any password hash the platform maintains — a low
  iteration count that was acceptable when it was set is a forgotten crack surface years later as
  hardware improves; audit and raise it rather than assuming the original setting still holds.
- Check `passwordHistory` settings — a forgotten or disabled password-history policy is an
  overlooked crack surface in the same category: it is easy to miss during a review because it is
  not the active credential, but a historical one that may still be guessable or reused elsewhere.

Evidence: B1215 §1215.1-§1215.4.

**Cross-reference (deferred):** this defensive note belongs conceptually under METHODOLOGY.md §12
(SECRETS DISCIPLINE) alongside the live-install credential-handling guidance already there;
METHODOLOGY.md is owned by another writer in this chain, so the cross-link from §12 to this
section should be added when that file is next touched.


## 9. Live-session access recipe — REQUIRED capture at run start `[#1931]`

For a live-install Niagara target, the three access channels below must be recorded at the START of the run
(before the first live probe), as a block or a `sources/probes/` note — not re-derived each session.
PROMPT-LOOP HARD RULES (LIVE-SESSION ACCESS RECIPE) enforces the capture. Record host/port/URI STRUCTURE
only; never credentials (SECRETS DISCIPLINE).

| Channel | Recipe (as reported in kit #1931) |
|---|---|
| Workbench (`wb`) launch | Start it through a scheduled task: `schtasks ... /RU <interactive user> /IT /RL HIGHEST`, running a launcher `.cmd` that CLEARS the rival-posture machine environment variables per process. Without the clear, the N4 JVM dies before boot. |
| Station (fox) | URI `foxs://<host>:4911` (TLS) — evidenced in the incident run (`plugin-st-stderr.txt`: FOXS 4911). The issue reports UDP 1911 as discovery-only on that host `[unverified]`. |
| Platform | Reported in kit #1931 as "N4 1911 / N5 3011 platformssl" `[unverified]` — this CONFLICTS with the kit's audit defaults (`niagara-audit.v1.md` SEC-09/SEC-14: fox 1911 and platform 3011 plaintext; foxs 4911 and platformssl 5011 TLS). Do not copy either set as fact: read the live host's actual ports (station/platform config or a port listing) and record them, with their source, in the run's capture. |

- **Unverified here:** the exact `schtasks` argument list and the names of the cleared variables are not in the
  issue text; copy them from the run's own `wb-session.log` / launcher `.cmd` rather than from this table.
- **Why required:** the recipe was not documented after the 2026-10-03/04 sessions, the incident recurred on
  2026-10-07, and about 40 minutes were lost re-deriving ports and URIs.
- **How to cite:** preserve the launcher `.cmd`, the session log and the stderr capture of the station connect
  under `sources/probes/` and cite them `[CERT-live]` (the FOXS 4911 evidence is `plugin-st-stderr.txt`).

Evidence: kit issue #1931 (retro 2026-10-06 reflow-bypass-bench item 5; `wb-session.log`, `plugin-st-stderr.txt`).

---

## Self-verify

| # | Claim | Marker | Evidence |
|---|---|---|---|
| 1 | Runtime instantiation = `Type.getInstance()`; no public newInstance | `[CERT]` | Type.java:144-155; ValueDocDecoder.java:1749 |
| 2 | `add(name,val,flags,facets,ctx)`; started() fires top-down on add to running parent | `[CERT]`/`[INFER]` | BComponent.java:874-911,333-341; Flags.java:61-65 |
| 3 | READONLY does not block code set(); only user-context PermissionException does | `[CERT]` | Flags.java:24-28; BComplex.java:826-851 |
| 4 | Provisioning writes via Context.decoding (set/setFlags) | `[CERT]` | ValueDocDecoder.java:811,704; Context.java:123-133 |
| 5 | importLinks bug was get()-on-Action, not READONLY; use getSlot() | `[CERT]` | ValueDocDecoder/ChiLinkHelper Action-slot case |
| 6 | BOG (ValueDocEncoder/Decoder) serializes whole subtree incl READONLY+links; supersedes BogEncoder | `[CERT-doc]`/`[CERT]` | bog.txt:6-20,54-58; ValueDocEncoder.java:73-78,311-330,984-1033 |
| 7 | .bog = BBogSpace.save via encodeDocument(rootComponent), zipped | `[CERT]` | BBogSpace.java:363-396 |
| 8 | Gradle 7.6 daemon ≠ toolchain; JAVA_HOME sets daemon JVM (Java 8) | `[CERT]` | worked case; installations.paths = toolchain |
| 9 | findProjects() 2 layouts; scope as exclude; no exclude API | `[CERT]` | settings.gradle.kts:118-131,126-131 |
| 10 | Bump only for frozen-slot structure change, not code-only | `[CERT-doc]` | BUILD_WORKFLOW.md:343,365 |

**Tally:** 9 `[CERT]/[CERT-doc]`, 1 mixed with `[INFER]` (claim 2, auto-start). No unmarked claims.
