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
