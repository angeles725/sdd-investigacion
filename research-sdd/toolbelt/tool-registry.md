# Tool Registry — Research-SDD toolbelt

Map of **artifact type → tool → wrapper**. The loop runs `profile-target.sh`
over the target's binaries (uses `file`) and picks the wrapper. All paths are
verified in this environment (WSL Ubuntu, 2026-06-28).

**Scope: KIT wrappers only.** This registry documents scripts that live in `toolbelt/`. A tool a target
writes for itself (`<target>/tools/*.py`, documented in that target's `tools/README.md`) is TARGET tooling:
it is tracked fleet-wide by `sweep-tools.sh` (the SessionStart tool ledger) and enters this registry only
through a §18 `promote` verdict that moves it into `toolbelt/`. Do not add target-side tools here.

| Artifact type | Detection (`file`) | Tool | Wrapper | Status |
|---|---|---|---|---|
| JAR / `.class` Java | `Java class data` / `Zip archive` (jar) | Vineflower (pref.), CFR, Procyon, `javap -p -c` | `decompile-java.sh` | ✅ |
| JAR corroboration evidence | Valid regular JAR/ZIP | Vineflower + CFR + Procyon + `javap` + `jdeps` | `corroborate-java.sh` (`java-corroboration.v1`) | ✅ |
| JAR / `.class` JVM call-graph export | `Java class data` / `Zip archive` (jar) | SootUp call-graph exporter (Maven module `jvm-callgraph/`) | `jvm-callgraph.sh analyze [options]` | ✅ |
| JVM bytecode assemble / disassemble | `Java class data` / `Zip archive` (jar) | krak2 (Krakatau2 2.0.0-alpha) — round-trip `.class` disassemble/assemble | (direct) | ✅ |
| .NET DLL/EXE | `PE32 .NET assembly` / `Mono/.Net assembly` | `ilspycmd` (resolved via `rsdd_resolve_ilspy`; no pinned version) | `decompile-net.sh` | ✅ |
| Native ELF/PE | `ELF ... executable` / `PE32 executable` | Ghidra headless (decompile) → r2/objdump fallback | `decompile-native.sh` | ✅ |
| File-type / packer / compiler / entropy detection | any regular binary or firmware blob | diec (Detect-It-Easy CLI) | (direct) | ✅ |
| Manual byte-level inspection / patching | any regular binary | hexedit / bvi (interactive hex editors) | (direct; manual step) | ✅ |
| Native corroboration evidence | Regular native binary | radare2 static analysis in Bubblewrap | `corroborate-native.sh` (`native-static.v1`) | ✅ |
| Native curated evidence | Regular native binary | Ghidra curated exporter in Bubblewrap; evidence file cap 64 (`--max-files`; override with `corroborate-ghidra.sh --max-files N`); NOT a decompiler — Ghidra performs static analysis and exports curated evidence; Vineflower decompiles Java | `decompile-native.sh ghidra-evidence` (`ghidra-corroboration.v1`) | ✅ |
| Native ELF/PE — r2 fallback | Native binary; Ghidra unavailable or a fast disassembly suffices | radare2 static analysis (`aaa` full analysis + `pdf` of `main`; falls back to `afl` if `main` absent; no GUI) | `decompile-native.sh r2 <binary>` | ✅ |
| Native ELF/PE — triage | Native binary; first-look before a full decompile | `file` + `readelf -h` + `strings` (no decompiler invoked) | `decompile-native.sh quick <binary>` | ✅ |
| Firmware static evidence | Regular firmware/opaque binary | Binwalk signatures + entropy in Bubblewrap | `scan-firmware.sh evidence` (`firmware-static.v1`) | ✅ |
| Firmware validated carving | Valid uImage or SquashFS v4 LE range | Internal exact-byte parser in Bubblewrap | `scan-firmware.sh carve` (`firmware-carve.v1`) | ✅ |
| PCAP/PCAPng offline evidence | `.pcap` / `.pcapng` capture file | capinfos (summary) + tshark -z io,phs (protocol hierarchy) in Bubblewrap, no live capture | `corroborate-pcap.sh` ([`pcap-evidence.v1`](pcap-evidence.v1.md)) | ✅ |
| PCAP/PCAPng flow reconstruction | `.pcap` / `.pcapng` capture file | tshark -z conv,tcp/udp (conversations) + tshark -z follow,tcp,raw,N (per-stream SHA-256 digest) in Bubblewrap, no replay | `pcap-flows.sh` ([`pcap-flows.v1`](pcap-flows.v1.md)) | ✅ |
| ZIP metadata inventory | Classic single-disk ZIP | Internal central-directory parser (no payload reads or extraction) | `zip-metadata.sh` ([`zip-metadata.v1`](zip-metadata.v1.md)) | ✅ |
| ZIP STORED extraction | Classic single-disk all-STORED ZIP | Internal central/local parser and bounded exact copy | `zip-stored.sh` ([`zip-stored.v1`](zip-stored.v1.md)) | ✅ |
| SquashFS extraction | SquashFS v4 LE blob or firmware image containing SquashFS | unsquashfs in Bubblewrap + post-extraction tree validation (symlink/special/hardlink/traversal rejected; per-file sha256) | `squashfs-extract.sh` ([`squashfs-extract.v1`](squashfs-extract.v1.md)) | ✅ |
| Firmware / opaque-binary recursive extraction inventory | Any regular binary (firmware, packed archive, unknown blob) | unblob v26.6.4 in network-denied Bubblewrap + bounded inventory walk (symlink/special/hardlink/traversal skipped; per-file sha256; depth/entry/bytes caps; payload bytes never published) | `corroborate-unblob.sh` ([`unblob-evidence.v1`](unblob-evidence.v1.md)) | ✅ |
| PE/ELF binary obfuscated-string inventory | PE32/PE32+ or ELF binary | FLOSS v3.1.1 in network-denied Bubblewrap; extracts static, stack, tight, and decoded strings (PE only for stack/tight/decoded); bounded sample with sha256 per string; string-count and string-length caps; truncation always visible | `corroborate-floss.sh` ([`floss-evidence.v1`](floss-evidence.v1.md)) | ✅ |
| PE/ELF/.NET binary capability detection | PE32/PE32+, ELF, or .NET binary | capa 9.4.0 in network-denied Bubblewrap; identifies ATT&CK / MBC capabilities via static rule matching; bounded, sorted capability list (name, namespace, attack_ids, mbc_ids, match_count); capability-count cap; truncation always visible; rules-dir validated and ro-bound (symlink-safe, no broad /home exposure) | `corroborate-capa.sh` ([`capa-evidence.v1`](capa-evidence.v1.md)) | ✅ |
| Binary parsed by a Kaitai Struct .ksy | Any regular binary with a matching .ksy grammar | ksc 0.11 (JVM compile, Stage 1) (alias: kaitai-struct-compiler) + kaitaistruct 0.11 Python driver (bounded SEQ_FIELDS walk with `_debug` offsets, Stage 2) in network-denied Bubblewrap; field-count, depth, and value-bytes caps; parse_error captured without traceback | `corroborate-kaitai.sh` ([`kaitai-evidence.v1`](kaitai-evidence.v1.md)) | ✅ |
| IFC/BIM model | Regular `.ifc` file (IFC2X3 / IFC4 / IFC4X3) | ifcopenshell 0.8.5 in network-denied Bubblewrap (rsdd-ifc venv); bounded, sorted entity-type histogram (count DESC then name ASC); type-count and timeout caps; truncation always visible; parse_error captured without traceback; three distinct absent/empty/parse-error states | `corroborate-ifc.sh` ([`ifc-evidence.v1`](ifc-evidence.v1.md)) | ✅ |
| QNX6 Power-Safe filesystem image | Magic `0x68191122` at partition offset `+0x2000`; accepted as any regular non-symlink file | Internal binary reader (stdlib struct/hashlib); recursive directory tree walk (`list` subcommand) + single-file extraction (`extract` subcommand); key-sorted JSON evidence; input symlink rejected via `O_NOFOLLOW`; output uses `O_CREAT\|O_EXCL\|O_NOFOLLOW` (refuses pre-existing paths and symlinks); depth cap 40 with `truncated:true` visibility; cyclic-dir protection via visited-inode set; both parse errors AND walk errors yield `status:failed` JSON (exit 1); three distinct absent/empty/parse-error states | `qnx6-read.sh` ([`qnx6-evidence.v1`](qnx6-evidence.v1.md)) | ✅ |
| Serial frame log (canonical text-log: one line per frame `{t_rel} len={N} {HH HH ...}`; emitted by `serial-frame-capture --log`) | Plain-text `.log`; NOT auto-detected by `profile-target.sh` — pass `EXTRA_EXT="log"` | Internal line parser (stdlib only; regex `len=\s*(\d+)\s+([0-9a-fA-F ]+)`); validates declared `len=N` against parsed byte count; three subcommands: `stats` (length histogram + per-position variability), `diff` (per-position byte-change analysis across two captures), `checksum` (brute-force sum8/twos-comp8/xor8/CRC16-Modbus LE/BE/CRC16-CCITT BE); input symlink rejected via `O_NOFOLLOW` (exit 2); output uses `O_CREAT\|O_EXCL` (refuses pre-existing paths, exit 2); 10 MB read cap + 10 000-frame cap with `truncated:true` visibility; unrecognized format, len mismatch, or bad hex → `errors` list + `status:failed` JSON (exit 1); three distinct absent-input/empty-input/malformed-input states | `serial-frame-analyze.sh` ([`serial-frame.v1`](serial-frame.v1.md)) | ✅ |
| Niagara N4 history archive | `.hdb` extension; magic `0xA106F11E` at file offset 0 (big-endian); accepted as any regular non-symlink file | Internal binary reader (stdlib struct/re/hashlib); reads embedded HistoryConfig XML schema (history_id, record_type, schema_fields, time_zone, source, reversible_encoding); key-sorted JSON evidence; input symlink rejected via `O_NOFOLLOW`; non-regular files (FIFOs, devices) rejected via `S_ISREG` check (exit 2); output uses `O_CREAT\|O_EXCL\|O_NOFOLLOW` (refuses pre-existing paths and symlinks); absolute `_MAX_CONFIG_BYTES` cap (1 MiB) on declared XML length prevents OOM and O(n²) regex cost regardless of file size; bad magic, cap exceeded, truncated header, or short XML read yields `status:failed` JSON (exit 1); three distinct absent-or-unreadable/parse-error/valid states; record binary region is hashed (sha256) but never decoded | `niagara-hdb-read.sh` ([`niagara-hdb.v1`](niagara-hdb.v1.md)) | ✅ |
| Niagara N4 station config.bog | `.bog` extension; ZIP containing `file.xml` (station backup) or plaintext XML (platform/defaults); accepted as any regular non-symlink file | Internal BOG-XML parser (stdlib only; TAG_RE + attribute extraction); emits component tree (paths, types, handles — including self-closing elements), link topology (sourceOrd h:xxxx handles resolved to component paths), and module prefix-map; SECRETS DISCIPLINE: slot values never emitted; LENGTH-BOUNDED ZIP inflation cap (32 MiB) via `f.read(CAP+1)` length check — never trusts `getinfo().file_size` (forged-header zip-bomb protection); ZIP entry read errors (corrupted deflate, CRC mismatch, encrypted entry, unsupported compression) wrapped in `except Exception` → `status:failed` JSON emitted (no traceback escape, exit 1); input symlink rejected via `O_NOFOLLOW`; non-regular files (FIFOs, devices) rejected via `S_ISREG` check after `O_NONBLOCK` open (no blocking wait, exit 2); output uses `O_CREAT\|O_EXCL\|O_NOFOLLOW` (refuses pre-existing paths and symlinks); component and link list caps with `truncated:true` visibility; non-XML/non-ZIP content → `status:failed` JSON (exit 1); three distinct absent-input/parse-error/valid states | `bog-nav.sh` ([`bog-nav.v1`](bog-nav.v1.md)) | ✅ |
| Niagara N4 station module dependency check | `.bog` extension (ZIP-compressed `file.xml` or plaintext XML) + Niagara install root directory; accepted as any regular non-symlink file + non-symlink directory | Read-only stdlib-only dependency checker; resolves module aliases (`m='alias=module'`, including hyphenated aliases) and type references (`t='alias:Type'`) from the station bog against JARs in `<install_root>/modules/`; emits `missing_parts` dict (modules with **no installed parts** only — never falsely reports an installed module as missing), `modules` dict (installed_parts + types_referenced + types_unresolved per module), and `summary` with jars_scanned/jars_skipped_oversized/jars_total/missing_parts/modules_referenced/types_unresolved/unresolved_aliases; two distinct findings: (A) module absent → `missing_parts`; (B) module installed but type not found in any part → `types_unresolved` (version/profile mismatch, not a missing part); SECRETS DISCIPLINE: emits module names and installed_parts names only — never versions, vendor strings, JAR paths, slot values, or credential fields; LENGTH-BOUNDED read for both ZIP inflation (32 MiB via `f.read(CAP+1)`) and plaintext bog — never trusts `getinfo().file_size`; ZIP entry read errors wrapped in `except Exception` → `status:failed` JSON (no traceback escape, exit 1); input bog symlink rejected via `O_NOFOLLOW`; non-regular files (FIFOs, devices) rejected via `S_ISREG` check after `O_NONBLOCK` open (no blocking wait, exit 2); install root symlink rejected via `lstat` + `S_ISLNK` check; absent/unreadable/escaped `modules/` dir → typed `status:failed` error — never produces a false "all modules missing" report (§7 install-side); realpath containment on `modules/` and per-JAR paths; JAR scan capped at 2 000 entries with `truncated:true` visibility; per-JAR `module.xml` inflate capped at 64 KiB with visible `jars_skipped_oversized` count; output uses `O_CREAT\|O_EXCL\|O_NOFOLLOW` (refuses pre-existing paths and symlinks); `modules_referenced=0` is exit 0 (empty station is valid — §7 anti-silent-zero); `jars_scanned` always present in summary (proves instrument looked) | `station-modules.sh` ([`station-modules.v1`](station-modules.v1.md)) | ✅ |
| Niagara distributable bundle | `.ntpl` / `.ufw` / `.dist` — always ZIP-with-`file.xml`; `.palette` — TWO forms: exported/distributable palette = ZIP-with-`file.xml` (magic `PK`); `module.palette` inside extracted/ or module trees = plain XML (grep directly — see `palette-lexicon.v1` row); `config.bog` — distributable station backup = ZIP-with-`file.xml`; platform/defaults = plaintext XML (see `bog-nav.v1` row) | Test magic before assuming format: `head -c2 <file>` — `PK` → ZIP form, extract payload with `unzip -p <bundle> file.xml`; any other prefix → plain XML, grep or parse directly. NOTE: "raw grep or strings returns no hits" applies ONLY to the ZIP form; plain-XML palettes and bogs respond to grep normally | (direct) | ✅ |
| Niagara N4 extracted module directory (palette + lexicon + agent census) | non-symlink directory containing artifact subdirs with `extracted/module.palette`, `extracted/*.lexicon` (all files recursively, including niagaraLexiconXX language-pack subdirs), and/or `extracted/META-INF/module.xml`; not auto-detected by `profile-target.sh` — pass module dir explicitly | Read-only stdlib-only census; emits `palette_count` (all `<p>` property-slot elements with at least one of `n`/`t`/`m` attributes in `module.palette` XML; `MemoryError` on ET parse caught as `status:failed`), `lexicon_keys` / `keys_examined` (valid `key=value` lines across ALL `*.lexicon` files under `extracted/` recursively; UTF-8 BOM stripped before parsing; only `=` separator recognized), `duplicate_bare_keys` dict (`{relpath: {key_name: occurrence_count}}` where `relpath` is the `.lexicon` path relative to `extracted/` — same-basename files in different subdirs remain distinct; keys appearing more than once **within the same lexicon file** only — per-file duplicate-bare-key hazard; a key in two different files is NOT flagged), `duplicate_bare_keys_count` (total within-file dup (file, key) pairs for this artifact), and `agents` list (`type_name`/`type_class`/`on_types` from `<agent>` elements in `META-INF/module.xml`); presence signals: `lexicon_files_seen` (count of `*.lexicon` files found recursively — 0 means absent), `palette_present` (bool), `module_xml_present` (bool) distinguish absent/empty/no-match (§7); `keys_examined` always present in both per-artifact and summary — proves the lexicon parser ran (§7 anti-silent-zero); SECRETS DISCIPLINE: lexicon values never read past `=`; only key names and counts emitted; input symlink rejected via `lstat` + `S_ISLNK` check; symlink artifact subdirs skipped via `lstat` + containment guard (`realpath`); `*.lexicon` files scanned recursively via `os.walk(followlinks=False)` (symlink directories not descended); files inside `extracted/` read with `O_RDONLY\|O_NOFOLLOW\|O_NONBLOCK` (symlinks rejected; FIFOs never block open); `fstat` `S_ISREG` check after open (rejects FIFOs, devices); per-file read capped at 16 MiB (palette; a pathological XML tree can still exceed available memory during parse — MemoryError caught as status:failed) or 4 MiB per file (lexicon) or 1 MiB (module.xml) via `os.read(cap+1)` — never trusts `stat().st_size`; truncation causes palette XML parse failure (`palette_count:0`) and `status:failed`; truncation errors visible in `errors[]`; output uses `O_CREAT\|O_EXCL\|O_NOFOLLOW`; `artifacts_scanned=0` is exit 0 (empty module is valid); three distinct absent-input/empty-module/valid-module states | `palette-lexicon-agents.sh` ([`palette-lexicon.v1`](palette-lexicon.v1.md)) | ✅ |
| Niagara N4 Px presentation XML (`.px` extension; `CanvasPane viewSize="W,H"` holding absolutely-positioned widgets) | `.px` extension; NOT auto-detected by `profile-target.sh` — pass explicitly | stdlib-only renderer → self-contained HTML page; walks `CanvasPane` children and renders `Label` (text+font, both XSS-sanitized before style interpolation: family to `[A-Za-z0-9 _-]`, size to digits only), `Picture` (static `image=` or `ValueBinding` IBooleanToSimple/IStatusToSimple toggle), `BoundLabel` (bound image or leaf-name fallback), `ImageButton`, `BackButton` at absolute CSS positions; unhandled widget tags counted per-tag in stderr summary; widget render cap 4000 (truncated=true when hit); image ord forms: `file:^<rel>` against shared/ root, `module://<mod>/<rel>` against organized/ corpus root; shared/ root auto-detection walks up from .px dir looking for a directory whose basename is exactly "shared" — REQUIRED for file:^ refs; without --shared and no such ancestor, file:^ refs are skipped entirely (NOT silently converted to a permissive root) and counted as `assets_needs_shared=N`; resolved shared root always printed in stderr summary (`shared=<path|none>`); asset path-traversal REFUSED via realpath containment (blocked, never embedded); each unique asset URI emitted ONCE in CSS style block (deduplication against output amplification); total embedded bytes capped at 32 MiB; per-image read capped at 8 MiB via `os.read(cap+1)`; oversized images skipped and counted; input opened with `O_RDONLY\|O_NOFOLLOW\|O_NONBLOCK` (symlinks rejected; FIFOs do not block); `fstat S_ISREG` rejects non-regular input (FIFOs, devices → exit 2); .px read capped at 16 MiB; `ET.ParseError` → exit 1 (no traceback); malformed viewSize → exit 1 (no traceback); `MemoryError` → exit 1; no `CanvasPane` → exit 1; output written via `O_WRONLY\|O_CREAT\|O_EXCL\|O_NOFOLLOW` (refuses pre-existing paths and symlink targets → exit 2); write failure → unlink partial file → exit 2; no `--out` → stdout via `buffer.write(encode("utf-8"))` (charset-safe); deterministic demo ON/OFF state (MOCK label, "demo state, not a live station"); stderr summary always emitted (never silent): `widgets_rendered=N assets_embedded=N assets_missing=N assets_blocked=N assets_needs_shared=N assets_oversized=N assets_over_budget=N assets_embed_bytes=N [skipped_by_tag={tag:N,...}] [skipped_no_layout=N] [truncated=true] shared=<path|none>`; NO JSON envelope; NO schema doc; nested CanvasPane not recursively rendered (outermost only); three-state exit: 2=I/O or output-guard failure; 1=parse error/no CanvasPane/MemoryError; 0=rendered OK | `px-render.sh` | ✅ |
| In-VM run receipt | VM/sandbox output artifacts | vm_receipt.py (schema only, no VM launch) | `vm_receipt.py build\|validate\|verify` ([`vm-run-receipt.v1`](vm-run-receipt.v1.md)) | ✅ |
| gzip/xz archive VM-run plan | gzip or xz archive (regular file; codec auto-detected or declared) | `vm_run.py` — DRY-RUN only; no VM boot, no archive inflation, no subprocess; bomb-bound check: refused if declared_decompressed_bytes > output cap | `vm_run.py plan --input ARCHIVE --output DIR [--allow-exec]` ([`vm-run-plan.v1`](vm-run-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-exec` absent → exit 3 + offline plan | ✅ |
| strace / ltrace / gdb-batch tracer run plan (in-VM) | any regular binary (never executed; identity only via O_NOFOLLOW) | `trace_plan.py` — DRY-RUN only; no VM boot, no subprocess; network isolation + per-drive containment policy + `--cap-drop ALL` + `--unshare-net` enforced in plan spec (identical to detonate) | `trace_plan.py plan --target BIN --tracer {strace,ltrace,gdb-batch} --output DIR [--allow-exec]` ([`trace-plan.v1`](trace-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-exec` absent → exit 3 + offline plan | ✅ |
| strace/ltrace/gdb-batch live trace receipt (in-VM, disposable) | any regular binary (target identity only via O_NOFOLLOW; real in-guest tracing is the HUMAN'S GATED MANUAL STEP — NEVER automated in CI) | `lib/trace_exec.py` — `TraceVmExecutor`; bwrap `--cap-drop ALL --unshare-net` + qemu `-nic none -nodefaults -accel tcg -sandbox on,...=deny`; per-drive policy: target `readonly=on`, rootfs `snapshot=on` (COW), scratch `snapshot=off` (host reads post-teardown); file-scoped `--bind <scratch> <scratch>` placed after `--tmpfs` (INV-2 / issue #60 — reachability gap reconciled and machine-checked); tracer selection via kernel cmdline `-append "init=/rsdd-agent rsdd.tracer=<tracer>"`; containment **IDENTICAL** to `DetonateVmExecutor` (shared `vm_disk_policy`); single per-run subdir (scratch + serial.log + receipt → evidence chain coherent); TOCTOU-safe sentinel substitution via `pre_boot` seam; sha256 of scratch pre/post (fail-soft); SIGTERM→SIGKILL process-GROUP teardown in finally | `trace_plan.py plan --target BIN --tracer {strace,ltrace,gdb-batch} --output DIR --allow-exec` ([`trace-run.v1`](trace-run.v1.md) + [`vm-run-receipt.v1`](vm-run-receipt.v1.md)); exit 0 + `trace-run.v1` JSON + receipt identity on success; exit 2 on preflight/boot error; exit 3 when flag absent | ✅ |
| QEMU emulation plan (user / system mode) | ELF binary (architecture auto-detected from ELF header e_machine; never executed) | `qemu_plan.py` — DRY-RUN only; no QEMU launched, no subprocess, target not emulated | `qemu_plan.py plan --target BIN --mode qemu-user\|qemu-system --output DIR [--allow-exec]` ([`qemu-plan.v1`](qemu-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-exec` absent → exit 3 + offline plan | ✅ |
| QEMU system-mode live boot receipt (disposable-VM substrate) | ELF kernel/target (O_NOFOLLOW; content-addressed sha256); mode must be `qemu-system` (`qemu-user` refused) | `lib/qemu_exec.py` — `LiveQemuBootExecutor`; bwrap `-nic none -nodefaults -sandbox on -accel tcg -snapshot` containment; per-run subdir via O_NOFOLLOW; stdout drain captures serial console (-nographic); SIGTERM→SIGKILL process-GROUP teardown (killpg) in finally; `timeout-killed` outcome when wall-deadline fires | `qemu_plan.py plan --target BIN --mode qemu-system --output DIR --allow-exec` ([`vm-boot-run.v1`](vm-boot-run.v1.md) + [`vm-run-receipt.v1`](vm-run-receipt.v1.md)); exit 0 + `vm-boot-run.v1` JSON on success; exit 2 on preflight/boot error; exit 3 when flag absent; `qemu-user` + `--allow-exec` → exit 2 (refused) | ✅ |
| Hostile-sample detonation plan | any regular file (hostile sample; magic-byte sniff for type_hint only; sample never executed) | `detonate_plan.py` — DRY-RUN only; no VM boot, no subprocess; network isolation + per-drive containment policy + `--cap-drop ALL` + `--unshare-net` enforced in plan spec; `--network none` only | `detonate_plan.py plan --sample FILE --output DIR [--allow-exec]` ([`detonate-plan.v1`](detonate-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-exec` absent → exit 3 + offline plan | ✅ |
| Hostile-sample detonation live receipt (in-VM, disposable) | any regular file (hostile sample; magic-byte sniff for type_hint; real in-guest detonation is the HUMAN'S GATED MANUAL STEP — NEVER automated in CI) | `lib/detonate_exec.py` — `DetonateVmExecutor`; bwrap `--cap-drop ALL --unshare-net` + qemu `-nic none -nodefaults -accel tcg -sandbox on,...=deny`; per-drive policy: sample `readonly=on`, rootfs `snapshot=on` (COW), scratch `snapshot=off` (host reads post-teardown); file-scoped `--bind <scratch> <scratch>` placed after `--tmpfs` (INV-2 / issue #60 — reachability gap reconciled and machine-checked); single per-run subdir (scratch in same dir as serial.log + receipt → evidence chain coherent); TOCTOU-safe sentinel substitution via `pre_boot` seam + scope check; sha256 of scratch pre-boot and post-teardown (fail-soft: hash error → null + WARNING, never discards evidence) → `vm_pre_snapshot` / `vm_post_snapshot`; SIGTERM→SIGKILL process-GROUP teardown in finally (post-hash inside guaranteed region) | `detonate_plan.py plan --sample FILE --output DIR --allow-exec` ([`detonate-run.v1`](detonate-run.v1.md) + [`vm-run-receipt.v1`](vm-run-receipt.v1.md)); exit 0 + `detonate-run.v1` JSON + receipt identity on success; exit 2 on preflight/boot error; exit 3 when flag absent | ✅ |
| Live network traffic capture plan | network interface name (charset `[A-Za-z0-9._:-]`; max 63 chars; BPF filter recorded as data only, never compiled or executed) | `capture_plan.py` — DRY-RUN only; no socket opened, no interface bound, no subprocess; `CAP_NET_RAW` requirement recorded in plan | `capture_plan.py plan --interface IFACE --output DIR [--allow-live-capture]` ([`capture-plan.v1`](capture-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-live-capture` absent → exit 3 + offline plan | ✅ |
| Live network traffic capture receipt | network interface (must be in `RSDD_CAPTURE_IFACES` allowlist; `CAP_NET_RAW` on dumpcap binary required) | `lib/capture_exec.py` — `LiveCaptureExecutor`; dumpcap ONLY (privilege-separated, no dissectors); per-run subdir via O_NOFOLLOW; -w rewrite + -a filesize: cap; SIGTERM→SIGKILL teardown; `timeout-partial` outcome when wall-deadline fires (partial pcap valid) | `capture_plan.py plan --interface IFACE --output DIR --allow-live-capture` ([`capture-run.v1`](capture-run.v1.md)); exit 0 + `capture-run.v1` JSON on success; exit 2 on preflight/capture error; exit 3 when flag absent | ✅ |
| EMBA firmware analysis plan (Docker, network-isolated) | any regular binary / firmware file (O_NOFOLLOW; content-addressed sha256) | `emba_plan.py` — DRY-RUN only; no docker run, no subprocess, no image pulled; `--privileged` REFUSED in plan; `--network none` always emitted | `emba_plan.py plan --firmware FILE --output DIR [--allow-docker]` ([`emba-plan.v1`](emba-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-docker` absent → exit 3 + offline plan | ✅ |
| FACT Core firmware analysis plan (Docker Compose, internal-bridge) | any regular binary / firmware file (O_NOFOLLOW; content-addressed sha256) | `fact_plan.py` — DRY-RUN only; no docker-compose, no subprocess, no container started; `--privileged` REFUSED; `--network host` REFUSED; internal-bridge only | `fact_plan.py plan --firmware FILE --output DIR [--allow-docker]` ([`fact-plan.v1`](fact-plan.v1.md) + [`vm-determinism.v1`](vm-determinism.v1.md)); `--allow-docker` absent → exit 3 + offline plan | ✅ |
| FACT Core firmware live run receipt | any regular binary / firmware file (O_NOFOLLOW; content-addressed sha256) | `lib/fact_exec.py` — `LiveFactExecutor`; compose override pins digests + `internal:true`; per-run project `fact-<uuid8>`; firmware TOCTOU read-then-PUT; REST poll; teardown in finally | `fact_plan.py plan --firmware FILE --output DIR --allow-docker [--rest-base-url URL]` ([`fact-run.v1`](fact-run.v1.md)); exit 0 + `fact-run.v1` JSON on success; exit 2 on hard error; exit 3 when flag absent | ✅ |
| Firmware / packaged | `data` / known signatures | Binwalk scan + YARA (no extraction) | `scan-firmware.sh` | ✅ |
| Access `.mdb` historian / trendlog | `Microsoft Access Database` | `mdb-tables -1 <file>.mdb` (list tables) then `mdb-export <file>.mdb <table>` (CSV to stdout). Reads a BMS historian export without Access or ODBC; the first table is normally the sample table. Verified on 649 Alerton Compass trendlog `.mdb` files. | (direct) | ✅ |
| CHM help file | `MS Windows HtmlHelp Data` | `7z x <file>.chm -o<dir>/` (WSL/Linux, preferred); `extract_chmLib <file>.chm <dir>/` or `pychm` (WSL alternatives); `hh.exe -decompile <dir>/ <file>.chm` (Windows native). Extracted topics land under `sources/extracted/<basename>/Topics/`. | (direct) | ✅ |
| DXF/DWG drawing | AutoCAD DXF exchange data / DWG binary drawing. NOT auto-detected: `dxf`/`dwg` are absent from `profile-target.sh`'s `BASE_EXT` allowlist — pass `EXTRA_EXT="dxf dwg"` to have it routed | ezdxf `addons.drawing` renderer — renders walls, entities, and layout geometry to **PNG or SVG** as a visual oracle | `render-drawing.sh <drawing.dxf\|.dwg> <out.png\|.svg> [--dpi N] [--style dark\|light\|white]` | ✅ |
| PDF datasheet/manual | `PDF document` | **`extract-pdf.sh`** — tier 1 (text layer) `pymupdf4llm`→MD w/ tables + `<!-- p.N -->` anchors; tier 2 (scanned, `fonts=0`) `ocrmypdf`/`marker`/`docling`/`tesseract` OCR | `extract-pdf.sh` (download still via `fetch-doc.sh`) | ✅ |
| Quick any-doc→MD (NON-cited reads only) | PDF/DOCX/PPTX/XLSX/HTML text-layer docs where page-anchored `:p.N` cites are NOT needed | `markitdown` 0.1.7 one-shot, OR `pdftotext -layout` (cleaner titles on decorative fonts). NOT a substitute for `extract-pdf.sh` when cites/OCR are needed — see [`MARKITDOWN.md`](MARKITDOWN.md) | (direct) | ✅ |
| Web page / forum / link | URL | `curl`/`wget` + `pandoc` → markdown | `fetch-doc.sh` | ✅ |
| Device web-UI HTML config snapshot | HTML page captured from an embedded device's local HTTP config interface (e.g. `http://192.168.x.y/config/`) — NOT a public URL; do NOT use `fetch-doc.sh` or cite as `[CERT-web]` | Manual `curl -o snapshots/<name>.html http://<device-ip>/path` or browser save; cite as `[CERT] snapshots/<name>.html:<line>`; store under `snapshots/` in the corpus root | (direct) | ✅ |
| Obfuscated JS | `.js` | `js-beautify` | (direct) | ✅ |
| Source code | known extension | direct reading + CodeGraph | (direct) | ✅ |
| XML IntelliSense / OpenAPI / protobuf API contract | `.xml` IntelliSense doc, `.yaml`/`.json` OpenAPI spec, `.proto` IDL — NOT auto-detected by `profile-target.sh`; pass `EXTRA_EXT="xml yaml proto"` as needed | Parse → slice by namespace / service / package → emit one MD or JSON per slice into `_extract/` + an `_extract/index.json` mapping slices to authors. Makes "source-before-agent" workable at API scale (see `api-openness/_extract/author_workflow.js` for a reference pipeline). | (direct, custom per-target; no kit wrapper) | ✅ |
| Library/framework docs (MCP) | context7 / MCP query | `resolve-library-id` + `query-docs` | (MCP; snapshot load-bearing hits per METHODOLOGY §5) | ✅ |
| MCP-server capability | added to `~/.claude.json` mcpServers | e.g. `chrome-devtools` (reach JS-rendered pages) | (MCP; log in INSTALLED-TOOLS.md per §10) | ✅ |
| Browser / WebGL render target | headless Chrome (swiftshader) + local HTTP server | `tools/probe.mjs` (draw-call/triangle counts exact; FPS not) | (dynamic §12; `DYNAMIC-SETUP.md` §4) | ✅ |
| Windows/PowerShell-over-SSH probe | live-install Windows host reachable via SSH | `powershell -NoProfile -EncodedCommand <b64>` via `connect-ssh.sh` (target-side wrapper, not a kit script); silent-failure gotchas documented (§1–5 SSH/PS; §6 Windows-native CLI from WSL) | (dynamic §12; [`WINDOWS-SSH-PROBES.md`](WINDOWS-SSH-PROBES.md)) | ✅ |
| PowerShell source syntax (`.ps1`) | `.ps1` extension; NOT auto-detected by `profile-target.sh` | `pwsh` local — `[System.Management.Automation.Language.Parser]::ParseFile`; validates grammar only, not runtime semantics or PS 5.1/7 differences; path quoting uses env-var (not interpolation) so single-quote paths are safe | `pslint.sh <file.ps1> [...]` — exit 0 all clean · 1 **any finding or failure**: syntax errors, a named file missing, or the verifier itself failing (non-zero `pwsh`) · 2 bad args · 3 pwsh unavailable; assumes UTF-8/BOM'd input (UTF-16LE-without-BOM reports a false OK — see the script header); READ-ONLY, never modifies the file; fleet targets: HotelHilton (10 `.ps1`) and logosoft (`plc-client/`, 12 `.ps1`) | ✅ |
| Windows/PowerShell SNMP v2c probe | Windows bridge with no net-snmp; UDP/161 not forwardable via `ssh -L` | Hand-built BER `Snmp-Get` / `Snmp-Walk` / `Snmp-Set` over `UdpClient`; SNMP-enabled ≠ SNMP-answering gotchas documented | (dynamic §12; [`snmp-ps.md`](snmp-ps.md)) | ✅ |
| Cloudflare-Tunnel + Windows-SSH bring-up | Provisioning sshd + cloudflared on a live-install Windows appliance from scratch | Five compiled scars: host-key ACLs, firewall `-Profile Any`, service machine-binding, `sc.exe` deletion guard, safety-net task verification | [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) | ✅ |
| Cloudflare Tunnel — operational scars (ports, watchdog, token) | cloudflared tunnel service on a Windows mini-PC | (1) Real ports: QUIC=UDP/7844, HTTP2=TCP/7844 (port 443 is update checks only); `--protocol http2` switches UDP→TCP on 7844, not to 443; flap fix: pre-check `Test-NetConnection region1.v2.argotunnel.com -Port 7844`, insert `--protocol http2` in service ImagePath and restart via detached scheduled task if TCP/7844 exits; if only 443 exits (proxy), ask IT to open 7844/TCP. (2) `sc failure` watchdog does NOT fire on clean stop — add scheduled task every N min (SYSTEM) as supplement; test with `taskkill /F`. (3) Token pitfall: `Copy-Item config.example.ps1 config.ps1` overwrites real token with placeholder → `illegal base64 data at input byte 5` (`_`); reject tokens not starting `eyJ`; recover via API `/cfd_tunnel/{id}/token`; `cfut_` API token ≠ `eyJ` connector token | (direct; see [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md)) | ✅ |
| Cloudflare Access SSH — ephemeral cert (WSL) | Cloudflare Access-protected SSH host with legacy short-lived cert support | `cloudflared access ssh-gen --hostname <host>` generates the ephemeral cert; SSH ProxyCommand: `cloudflared access ssh --hostname %h`; keys from `~/.cloudflared/` with `-i` and `-CertificateFile`; server-side: `TrustedUserCAKeys` + `AuthorizedPrincipalsFile …/%u` (cert principal = lowercased email prefix); collaborative login: `cloudflared access login` in background → human completes pin → token via `edge_token_transfer`; no long-lived private key stored on server; complements forward-TCP method | (direct; see [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) and `DYNAMIC-SETUP.md §6`) | ✅ |
| Cloudflare Pages deploy — wrangler OAuth session expiry | Long-running `npx wrangler pages deploy` session | Session can outlive the `wrangler` OAuth token; deploy errors "necessary to set CLOUDFLARE_API_TOKEN" means OAuth EXPIRED — not that credentials were never present; recover: `npx wrangler login` (SSO, can be backgrounded) or set `CLOUDFLARE_API_TOKEN` env var, then retry; do NOT assume credentials were absent | (direct; deploy operational scar) | ✅ |
| Dell OptiPlex BIOS config (`cctk`) | Live Windows appliance with Dell hardware; `cctk` (Dell Command\|Configure) CLI | `cctk --AcPwrRcvry=On` sets power-on-after-outage (verified OptiPlex 3050, Off→On); when `winget install Dell.CommandConfigure` fails (0x80072ee7, `dl.dell.com` Akamai-blocked): download installer in WSL with `curl -A "Mozilla/5.0" <url>` (without User-Agent → 498 "Access Denied"), verify SHA256 against winget-pkgs manifest for `Dell.CommandConfigure`, scp over tunnel, run `<exe> /s`; BIOS password: `--ValSetupPwd=<password>` | (direct; live BIOS write — HUMAN'S GATED MANUAL STEP) | ✅ |
| Java `.class` major-version | `Java class data` | `od -An -j6 -N2 -tu2 --endian=big <ClassName>.class` → major_version integer (52 = Java 8, 55 = Java 11, 61 = Java 17, 65 = Java 21); reads 2 bytes at offset 6 as unsigned big-endian short; faster than decompiling when only the compiler/runtime version is needed | (direct) | ✅ |
| Web snapshot / large HTML (grep complexity-limit failure) | `.html` web-snapshot; `grep`/`ugrep` fails with "exceeds complexity limits" on `.{0,N}` patterns over large UTF-8 HTML | Python inline tag-strip + keyword-window: `python3 -c "import re, sys; html=open(sys.argv[1]).read(); text=re.sub(r'<[^>]+>','',html); idx=text.find(sys.argv[2]); print(text[max(0,idx-200):idx+200])" <file> <term>`; strips tags before searching; HTML complement to `extract-pdf.sh` for preserved web-snapshot sources; verified on 4+ cloudflare web-snapshots with "exceeds complexity limits" | (direct, Python inline) | ✅ |
| Web page — effective URL resolution | URL that may 301-redirect (docs reorg, slug change) | Resolve before `fetch-doc.sh`: `curl -L -w '%{url_effective}\n' -o /dev/null <url>`; register the EFFECTIVE post-redirect URL in SOURCES.md — not the originally requested URL; prevents stale redirected citations; verified on 4+ Cloudflare developer.cloudflare.com docs reorg 301-redirects | (direct; pre-step for `fetch-doc.sh`) | ✅ |
| oBIX/HTTP probe — PowerShell 5.1 TLS failure on Windows mini-PC | Self-signed TLS oBIX endpoint on a Windows appliance (e.g. JACE 8000) | PS 5.1 `Invoke-WebRequest` fails self-signed TLS ("No se puede crear un canal seguro") even with cert-ignore callback — use Node.js (`https` module + `rejectUnauthorized: false`) for oBIX probes instead; `powershell -EncodedCommand` over SSH emits CLIXML noise — prefer scp-ing a `.mjs` and running Node directly | (direct, Node.js; see [`WINDOWS-SSH-PROBES.md`](WINDOWS-SSH-PROBES.md)) | ✅ |

### Live-probe / install-audit instruments

Tools whose input is a live host, port, or install-tree rather than a static file artifact. A
plan-only guard (exit 3 without the explicit opt-in flag) is required for any wrapper that performs
a live-network probe, modifies system state, or exercises hardware. Read-only directory scans
(dir-walk only, no network I/O or state changes) are exempt from the plan-only guard requirement.

| Input / trigger | Detection | Approach | Wrapper | Tested |
|---|---|---|---|---|
| `host:port` | live BACnet/IP host (UDP/47808) | ANSI/ASHRAE 135 BACnet/IP reachability; unicast + broadcast Who-Is (SVC 0x08); Read-BDT + Read-FDT; stdlib `socket`; plan-only exit 3 without `--allow-live-probe`; read-only (Who-Is + BDT/FDT reads only; no Write-BDT or Register-Foreign-Device) | `corroborate-bacnet.sh` ([`bacnet-evidence.v1`](bacnet-evidence.v1.md)) | ✅ |
| serial port device + baud rate | `/dev/ttyUSB*` or any serial device node | Passive idle-gap framing; read-only (never writes to port); baud-rate entropy sweep (`sweep`) + idle-gap frame capture (`capture`); `--allow-live-probe` must appear AFTER the subcommand; pyserial (deferred import — plan-only path works without it); plan-only exit 3 without `--allow-live-probe`; sweep where all bauds fail or yield zero bytes → exit 1 `status:failed`; `capture --log <txt>` emits canonical text log readable by `serial-frame-analyze`; 1 001-frame cap (off-by-one: `_MAX_FRAMES=1000` post-append `>=` check) with `truncated:true` visibility; 64 KB read cap per baud-sweep candidate; three distinct plan-only/all-fail/complete states | `serial-frame-capture.sh` ([`serial-frame.v1`](serial-frame.v1.md)) | ✅ |
| Niagara N4 install directory (`niagara_home`) | non-symlink directory containing `defaults/system.properties` and/or `security/` and/or `modules/`; no static file-magic detection | Read-only directory scan; stdlib only; no subprocesses, no network I/O; SEC-01..SEC-16 security-posture checks (SEC-13 not defined); file-based checks are automated; network/keystore checks always MANUAL; `--station <config.bog>` enables SEC-08/SEC-10/SEC-12 (ZIP inflated; real N4 attrs: `allowProgramRuntimeExec`, `SyslogService enabled`, `reversibleEncodingKeySource`); symlink root rejected (exit 2) including trailing-slash paths; absent/empty-dir/valid-install are distinct states; `security/licenses/` absent → SEC-06 `NA`; `--station` provided-but-missing → distinct MANUAL observed; no symlink followed out of install root (realpath containment check on subdirs); 5000-JAR cap with visible truncation in observed + 200-license cap + 32 MiB ZIP file.xml decompression cap (length-bounded read, never trusting the attacker-controlled `file_size` header field) + 64 KiB per-JAR module.xml decompression cap (same bounded-read defence on the SEC-15 path); secrets discipline — emits structural findings only, never secret values; verdict observed enum values: `"PASS"`, `"FAIL"`, `"MANUAL"`, `"NA"`; exempt from `--allow-live-probe` (read-only dir scan, not a live-network probe) | `niagara-security-audit.sh` ([`niagara-audit.v1`](niagara-audit.v1.md)) | ✅ |
| Niagara N4 module source tree (`.java` files) | non-symlink directory containing `.java` source files with `@NiagaraProperty` / `@NiagaraAction` annotations | Read-only source-tree scan; stdlib only; paren-balance annotation join (handles multi-line annotations that grep misses); per-fragment split extracts every sibling from container forms (`@NiagaraProperties({@NiagaraProperty(...),...})` / `@NiagaraActions({@NiagaraAction(...),...})`); a `//` comment containing `(` may widen the paren-balance buffer — per-fragment split extracts correct spans regardless; 2 MiB per-file byte cap with `files_byte_capped` count visibility; extracts slots (`name`, `type`, `flags` full expression, optional `min` facet) and actions, and `class → superclass` extends chain (collision → `errors` entry); dot-dirs pruned; symlink root rejected (exit 2) including trailing-slash paths; absent/empty-tree/no-annotations are distinct states (`scanned:0`, `scanned:N+slots:[]`, `scanned:N+slots:non-empty`); 5 000-file cap with `truncated:true` visibility; no symlink followed out of root (realpath containment + `followlinks=False`); regular-file check per `.java` entry (`S_ISREG` only); unreadable file → `status:failed`, exit 1; three-state exit: 2 = absent/not-a-dir/symlink (no JSON), 1 = walk error (`status:failed` JSON), 0 = complete (`scanned` field always present — proves instrument looked; zero annotations is valid); `--output` uses `O_WRONLY\|O_CREAT\|O_EXCL\|O_NOFOLLOW`; exempt from `--allow-live-probe` (read-only dir scan) | `module-find.sh` ([`module-find.v1`](module-find.v1.md)) | ✅ |
| Web portal with client-side HMAC auth — CDP-attach harvest | Portal auth scheme requires in-browser token generation not replayable outside the browser (client-side HMAC signing) | `chromium.connectOverCDP()` attaches to a running browser (preserves authenticated session) instead of relaunching (session lost); daemon: keep `chromium --remote-debugging-port=<PORT>` alive; append-only `_manifest.jsonl` per-key snapshot; `keyFromUrl` derivation; contrast: attach = no re-login; relaunch = session lost; pattern verified on api-paneles target (`daemon.mjs:104`, `flexom-pull.mjs:23-26`) | (direct, Node.js/Playwright; see `DYNAMIC-SETUP.md`) | ✅ |
| Web portal with client-side HMAC auth — Playwright always-open daemon | Portal auth cannot be replayed outside the browser; only viable technique when client-side HMAC signing prevents curl/API replay | `launchPersistentContext` + `headless: false` + `context.on('response')` filter + append-only `_manifest.jsonl` + `keyFromUrl` derivation; daemon holds and renews its own auth session across runs; pattern verified on api-paneles target (`daemon.mjs:13-106`) | (direct, Node.js/Playwright; see `DYNAMIC-SETUP.md`) | ✅ |
| Niagara oBIX `baja:StatusNumeric` write (JACE 8000) | oBIX HTTP endpoint with writable `<real writable="true">` StatusNumeric slot; `--allow-live-probe` required (live write) | Parent slot refuses PUT ("Cannot translate") and does not advertise `value` child; use `…/value` child directly: `curl -X PUT -H "Content-Type: text/xml" -d '<real val="N"/>' http://<host>/obix/<slot>/value`; parent also accepts wrapped `<obj is="…baja:StatusNumeric"><real name="value" val="N"/></obj>`; WARNING: attr-only `<obj val>` silently ZEROES the setpoint — prefer bare-real child `/value` form; propagation to control under 1 s on JACE 8000 class hardware | (direct; live write — HUMAN'S GATED MANUAL STEP) | ✅ |

### Deliverable / report generation

| Artifact type | Detection (`file`) | Tool | Wrapper | Status |
|---|---|---|---|---|
| Deliverable: findings report / learning manual → PDF or DOCX | certified Markdown blocks (kit output) | typst 0.15.1 via `pandoc --pdf-engine=typst` (PDF, reproducible w/ SOURCE_DATE_EPOCH); `pandoc … -o x.docx` for DOCX (no engine) | (direct; future publish-report.sh) | ✅ |
| Deliverable: circuit / schematic diagram → PDF or SVG | certified block descriptions of a circuit (nodes, nets, components) | LaTeX (`pdflatex`/`xelatex`/`lualatex`, TeX Live 2023) + CircuiTikZ package for circuit drawing; `latexmk` for builds; `dvisvgm` for SVG output | (direct; future publish-report.sh) | ✅ |

## Tool paths (verified)

| Tool | Path |
|---|---|
| Java 21 + `javap` | resolved by `lib/tool-env.sh` (`JAVA_HOME` → `RESEARCH_SDD_JAVA_HOME` → stable Homebrew `opt` → distro JVM) |
| Vineflower / CFR / Procyon | `*_JAR` → legacy env override → `RESEARCH_SDD_TOOL_HOME/java` → portable `$HOME` locations |
| `ilspycmd` | `ILSPYCMD` → PATH → portable `$HOME/.dotnet/tools/ilspycmd` |
| Ghidra `analyzeHeadless` | `ANALYZE_HEADLESS` → `GHIDRA_HOME` → `GHIDRA_INSTALL_DIR` → PATH → stable Homebrew `opt` → `/opt/ghidra*` |
| `radare2` / `objdump` / `readelf` / `nm` / `strings` | in PATH |
| `binwalk` | `/usr/bin/binwalk` |
| `yara` (4.5.5) | in PATH |
| `pdftotext` / `pdfinfo` / `pdffonts` / `pdftoppm` / `tesseract` (langs: `spa`,`eng`,`spa_best`) / `pandoc` | in PATH |
| `markitdown` (0.1.7 — quick any-doc→MD, non-cited reads; see `MARKITDOWN.md`) | `~/.local/bin/markitdown` |
| PDF→MD venv (`pymupdf4llm`, `ocrmypdf`, `marker`, `docling`, `pdfplumber`, torch-cpu) | `~/.local/share/research-sdd-tools/venv` (override: `RESEARCH_SDD_VENV`) |
| TShark/tcpdump, GDB/gdb-multiarch, strace/ltrace, QEMU system/user-static/img | system CLI paths; each is smoke-tested by `detect-tools.sh` |
| Hyperscan (`libhs.pc`) | system multiarch pkg-config dirs, injected only into the `rsdd_pkg_config` child process |
| `typst` (0.15.1 — deliverable report generation, see "Deliverable / report generation" above) | `/home/linuxbrew/.linuxbrew/bin/typst` (linuxbrew); resolved via `command -v typst` |
| LaTeX (`pdflatex`/`xelatex`/`lualatex`/`latexmk` — TeX Live 2023/Debian; deliverable circuit/report generation, see "Deliverable / report generation" above) | `/usr/bin/pdflatex` etc. (apt, root-owned); resolved via `command -v pdflatex` |
| CircuiTikZ (LaTeX circuit-diagram package) | `/usr/share/texlive/texmf-dist/tex/latex/circuitikz/circuitikz.sty` (apt); resolved via `kpsewhich circuitikz.sty` |
| krak2 (Krakatau2 — JVM bytecode assembler/disassembler) | `~/.local/bin/krak2` (cargo); resolved via `command -v krak2` |
| diec (Detect-It-Easy CLI — file-type/packer/entropy detection) | `/usr/bin/diec` (apt, root-owned); resolved via `command -v diec` |
| hexedit / bvi (interactive hex editors — manual byte inspection) | `/home/linuxbrew/.linuxbrew/bin/hexedit`, `/home/linuxbrew/.linuxbrew/bin/bvi` (linuxbrew); resolved via `command -v` |

## Environment override

Java and native wrappers share `lib/tool-env.sh`. They accept path overrides via
environment variables (`VINEFLOWER_JAR`, `CFR_JAR`, `PROCYON_JAR`; legacy
`VINEFLOWER`, `CFR`, `PROCYON`; `ANALYZE_HEADLESS`, `GHIDRA_HOME`,
`GHIDRA_INSTALL_DIR`, `ILSPYCMD`, `JAVA_HOME`, `RESEARCH_SDD_JAVA_HOME`,
`RESEARCH_SDD_TOOL_HOME`), so the toolbelt is portable without editing scripts.
`RSDD_BREW_PREFIX` exists for hermetic/alternate-prefix resolution.
`RSDD_DOTNET_ROOT` is the kit's own .NET runtime override for `decompile-net.sh`
(authoritative — fail-closed if set but unusable, no fall-through); the ambient
`DOTNET_ROOT` may fall through to derivation when unusable (resilience for
distro-installed runtimes that are too old for the current ilspycmd target).
Explicit decompiler/Ghidra overrides are authoritative and fail closed when invalid.
Use `corroborate-java.sh` when claims need deterministic multi-engine inventories,
signatures, dependency evidence, per-tool manifests, and preserved partial failures.
Use `corroborate-native.sh` for bounded static function evidence with preserved analyzer failures.
Use `scan-firmware.sh evidence <file> <new-out-dir>` for bounded, non-extracting firmware evidence.
Use `scan-firmware.sh carve <file> <new-out-dir>` only for validated uImage or SquashFS v4 LE byte ranges; use a disposable VM for hostile inputs.
Use `zip-metadata.sh --input <zip> --output <new-out-dir>` for bounded metadata-only ZIP inventory; ZIP64 and multi-disk archives fail closed.
Use `zip-stored.sh --input <zip> --output <new-out-dir>` only for strict all-STORED extraction; mixed archives and unsafe paths fail closed.

**VM-spine plan adapters** (`vm_run.py`, `trace_plan.py`, `qemu_plan.py`, `detonate_plan.py`, `capture_plan.py`, `emba_plan.py`, `fact_plan.py`): each emits an offline JSON plan and exits 3 (authorization-required) when its gate flag is absent. Gate is default-off and fail-closed. Authorization contract: [`gate-authorization.v1`](gate-authorization.v1.md). Determinism record emitted alongside each plan: [`vm-determinism.v1`](vm-determinism.v1.md). **Live executors shipped**: `emba_plan.py --allow-docker` → [`emba-run.v1`](emba-plan.v1.md) via `lib/docker_exec.py`; `fact_plan.py --allow-docker` → [`fact-run.v1`](fact-run.v1.md) via `lib/fact_exec.py`; `capture_plan.py --allow-live-capture` → [`capture-run.v1`](capture-run.v1.md) via `lib/capture_exec.py` (C1; requires `CAP_NET_RAW` + `RSDD_CAPTURE_IFACES`); `qemu_plan.py --allow-exec --mode qemu-system` → [`vm-boot-run.v1`](vm-boot-run.v1.md) via `lib/qemu_exec.py` (V1b); `detonate_plan.py --allow-exec` → [`detonate-run.v1`](detonate-run.v1.md) via `lib/detonate_exec.py` (D2; real in-guest detonation is the human's gated manual step — NEVER automated in CI); `trace_plan.py --allow-exec` → [`trace-run.v1`](trace-run.v1.md) via `lib/trace_exec.py` (D3; containment identical to detonate; tracer selection guest-side only; real in-guest tracing is the human's gated manual step — NEVER automated in CI). Remaining adapter (`vm_run.py`) is plan-only; live executor deferred to a future authorized release.

### Ghidra batch routes

`decompile-native.sh ghidra-evidence <binary> <new-out-dir>` selects the approved curated exporter through
the hardened `corroborate-ghidra.sh` adapter with fixed defaults. Its report and manifest bind the staged
input, exporter, manifest CLI, Java launcher, Bubblewrap, and listed Ghidra launch-chain files by digest;
the remaining read-only Ghidra/JDK trees are not byte-bound. Production Bubblewrap denies network access,
uses synthetic user state, and mounts the host root read-only, but Ghidra still parses the untrusted binary
in-process: this is not a hostile-parser boundary. Use a disposable VM for actively hostile samples.
Direct adapter equivalent: `corroborate-ghidra.sh --input <binary> --output <new-out-dir>`.

`decompile-native.sh ghidra <binary> <out-dir> [--script Script.java]` remains the raw, flexible headless
route. It does not provide the curated schema, hardened isolation, bounded evidence, or provenance claims.

**C decompilation export (gap + kit script):** Ghidra 12.1.2 ships no script that writes decompiled C
to a file — its bundled Decompiler scripts (DecompilerStackProblemsFinder, FindPotentialDecompilerProblems,
ShowCCalls) are analysis helpers, not exporters. `toolbelt/ghidra/ExportDecompiledC.java` fills this gap.
Use it via the raw `--script` route above:

    RSDD_OUT=<dir> [RSDD_FN_FILTER=<java-regex>] [RSDD_MAX_FN=<n>] [RSDD_TIMEOUT=<secs>] \
      decompile-native.sh ghidra <binary> <out-dir> --script <path-to-ExportDecompiledC.java>

`RSDD_FN_FILTER` is a Java unanchored regex applied to function names; omit at your peril on large
binaries (a 3 MB PE holds thousands of functions). `RSDD_MAX_FN` caps the count of successfully
decompiled functions; `RSDD_TIMEOUT` is the per-function decompiler deadline in seconds (default 120).
Output is one `<program>.c` per run. Each function gets a `/* ---- <name> @ <entry> ---- */` banner;
failures appear inline as `/* FAILED: … */` rather than being dropped silently.

**Origin and canonical copy (METHODOLOGY §10):** Promoted from
`tools/ghidra/ExportDecompiledC.java` in the HotelHilton target corpus (block B57,
commit `58e81a7`). The kit copy at `toolbelt/ghidra/ExportDecompiledC.java` is canonical;
the target copy is superseded and should not be consulted.

**B57 arg-order reconciliation:** B57 records that the `--script` wrapper route "did not work"
(postScript never ran). The root cause was a missing `<out-dir>` argument in the recorded
command — `decompile-native.sh ghidra <bin> <out-dir> --script <path>` is the correct form;
without `<out-dir>`, `$4` is `--script` and the guard at `decompile-native.sh:50–55` that
appends `-scriptPath` never fires. The route is NOT broken: the corrected invocation today
yields `RSDD-EXPORT: 15 exported, 0 failed`. Note: the kit test suite (`ghidra-c-exporter.test.sh`)
invokes `analyzeHeadless` directly; the `decompile-native.sh --script` path is currently untested.

**`RSDD_OUT` env-var propagation — reliability caveat:** `RSDD_OUT` produced output on one invocation and silently none on another with the same config. Until the propagation issue is resolved, treat `RSDD_OUT`-based output as unverified; prefer `--output`-style flags when available.

**Stripped-binary limitation — `RSDD_FN_FILTER` cannot select functions when symbols are absent:**
`RSDD_FN_FILTER` is a Java regex applied to **function names**. On a symbol-stripped binary, all
user-defined functions are auto-named `FUN_<addr>` by Ghidra. A name filter therefore matches
nothing, and `ExportDecompiledC.java` produces empty (or near-empty) output with no error — a silent
zero that looks like success. The `--script ExportDecompiledC.java` path is **not usable** for
function selection on stripped binaries.

**Workaround — string-anchored selection (`DecompileByString.java`):** instead of filtering by
name, select functions by a STRING they REFERENCE. The approach: Ghidra's defined-data list is
scanned for strings containing a target pattern (a log-message fragment, a protocol constant, a known
function-name literal embedded in a logging call). Every `FUN_<addr>` that references a matched
string is collected and its decompiled C body is exported. This bypasses the name-only limit
entirely and is the primary selection strategy for stripped targets.

Invocation (same raw `--script` route):

    RSDD_OUT_FILE=<output.txt> RSDD_NEEDLES=<needle1|needle2|...> \
      decompile-native.sh ghidra <binary> <out-dir> \
      --script <path-to-DecompileByString.java>

`RSDD_NEEDLES` is a `|`-separated list of substrings; a defined string matches if it CONTAINS any
needle. `RSDD_OUT_FILE` is the absolute path of the `.txt` to write (default: `./decomp-bystring.txt`).
`RSDD_TIMEOUT` sets the per-function decompile timeout in seconds (default 180).
Output format is the same as `ExportDecompiledC.java` (one `.txt` file, per-function banners).

**Operator recipe (Ghidra GUI path — no script required for interactive sessions):** open the binary
in Ghidra → Window → Defined Strings → filter for a known string (e.g. a log prefix, a protocol
keyword) → right-click a match → Show References To → each caller `FUN_<addr>` is the function to
decompile (Decompiler view, or right-click → Decompile `FUN_...`). Rename the `FUN_` using the
embedded function-name literal when the logging pattern is `helper(level, "file.c", line, "funcname",
…)` (see also Stripped-binary: debug-string recovery below).

**Origin and canonical copy (retro 2026-08-07, niagara platform-native sub-pass B379–B382):**
`DecompileByString.java` was written mid-run because `ExportDecompiledC.java` could not select
functions in `nverify.exe`, `njre.dll`, and `plat.exe` (all stripped; user functions uniformly
`FUN_*`). It drove all four decompile passes that produced the sub-pass's load-bearing security
findings. The kit copy at `toolbelt/ghidra/DecompileByString.java` is canonical; the target copy at
`niagara-research/tools/ghidra-scripts/DecompileByString.java` is superseded and should not be
consulted. A `ghidra-string-selector.test.sh` companion test is not yet written (follow-up).

### Stripped-binary: debug-string recovery

When a stripped ELF/PE binary still calls a debug or logging helper with the signature
`helper(level, "<srcfile.c>", <line>, "<funcname>", "<fmt>", …)`, the **original source file names,
line numbers, and function names survive verbatim in `.rodata`** and can be recovered by string
cross-reference — naming functions in a symtab-less binary at no cost.

**In Ghidra:** open Window → Defined Strings; filter for `.c` / `.cpp` hits; right-click a string →
Show References To — each caller's auto-name (`FUN_...`) can be renamed with the embedded `<funcname>`
literal. Run this before concluding "no symbols".

**In radare2:** `iz` lists `.rodata` strings; `axt @@ str.*` gives cross-references to each.

Evidence (m2070 blocks 9–10): `FUN_0040f7a0(lvl,"splcommon.c",0x418,"WriteSPLPageHeader",…)` recovered
`WriteSPLPageHeader` / `WriteBandHeader` / `compressBand` from stripped `rastertospl`; SSIP builders
named via `"ERROR: <COMMAND>"` log-string xref in stripped `libsane-smfp` (commits `1a34528` / `b3e1ff2`).

## ghidra-mcp (agent-directed decompilation)

In addition to the headless mode (always available), `ghidra-mcp` exposes Ghidra as an
MCP server for interactive, agent-directed analysis. It requires Ghidra
running with the plugin + an open binary (server at `127.0.0.1:8089`).
See `GHIDRA-MCP.md` (generated after installation) for the usage flow.

## Vendor-bundled simulation engine as oracle

When a closed-source Java target ships its own simulation or emulation engine inside the vendor IDE or SDK
JARs, that engine is the **privileged offline oracle** — it observes correct output from the vendor's
reference model rather than recomputing it from a reimplementation.

**How to identify one:** during the §6 file census, look for class names containing `Sim`, `Emulator`,
`Interpreter`, `Offline`, or `Engine` in the vendor's own classpath. A bundled engine that accepts the
target's native data format and produces execution output is an oracle promotion candidate.

**Record it in the TOOLS table as `ORACLE`.** A harness driven by the vendor oracle is an INDEPENDENT
verification path — it is not a reimplementation check. Evidence: logosoft B75 ran 253 assertions through
Siemens' own `OfflineInterpreter` (`DE/siemens/ad/logo/simulation/`) to validate `GetFB`/`GetAVB` decode
correctness without hardware; the oracle caught divergences that static decompilation analysis could not
rule out.

## Capability detection (run BEFORE concluding a tool is missing)

`detect-tools.sh` probes the **real** availability of the RE/decompile tools above and prints a
capability report (also cached to `./.research-tools.txt`). It is READ-ONLY — it never installs.

```
detect-tools.sh                 # report to stdout + cache
detect-tools.sh --cache <file>  # cache elsewhere
detect-tools.sh --quiet         # cache only
```

It resolves each tool via PATH **and** stable install roots, then runs bounded validation. A tool is
`AVAILABLE` only when usable, `UNUSABLE` when found but validation fails, and `MISSING` when
unresolved. Decompiler JARs are never executed by detection: archive integrity, the engine's expected
entry class, and SHA-256 are checked instead. Do NOT infer availability from `which` alone: assuming "Ghidra not available"
when `decompile-native.sh ghidra` worked (Ghidra was under linuxbrew Cellar) cost the first native block
its decompiler depth. The loop runs this in BOOTSTRAP (PROMPT-LOOP §a); re-run it after any install.

## Self-provisioning: missing-tool recipes

When a gap needs a tool not listed above, the loop installs it autonomously via `install-tool.sh`
(policy in METHODOLOGY §10; autonomous incl. sudo, idempotent, logged to `INSTALLED-TOOLS.md`).
Known recipes:

| Domain / artifact | Recipe | Tool | Notes |
|---|---|---|---|
| Dart/Flutter AOT (`app.so`) | `install-tool.sh blutter` | worawit/blutter (alias: blutter-build) | git clone + pip; needs cmake/C++ & a Dart SDK for full native dump; `blutter-build` is the from-source exe-compile step (logged separately) |
| Android APK/DEX | `install-tool.sh jadx` / `apktool` | jadx / apktool | brew or apt |
| Python bytecode (`.pyc`) | `install-tool.sh pycdc` / `uncompyle6` | pycdc / decompyle3 | pycdc needs cmake |
| .NET (`.dll`/`.exe`) | `install-tool.sh ilspycmd` | ilspycmd | already present in this env |
| YARA rules | `install-tool.sh yara` | yara | already present |
| Dynamic instrumentation (Frida) | `install-tool.sh frida` | frida + frida-trace | pipx/venv (PEP-668); CLIs land in `~/.local/bin` — used by `dynamic.sh` |

Generic fallback: `install-tool.sh <name>` tries `brew`, then `sudo apt` (non-interactive). If it
**cannot** install (sudo password / build fail / no recipe / unverified source), the loop records it,
does the investigable part without it, and the **orchestrator ASKS the user** whether they can install
it. Check availability: `install-tool.sh --check <cmd>`. Add new recipes inside `install-tool.sh`.

## Firmware encryption — a known blocker WITH a documented attack path (NOT a dead-end)

When `scan-firmware.sh` (binwalk) declines to carve a `.bin` because its inner archives are ENCRYPTED, that
is a *known blocker with an attack path*, not a sink-no-time dead-end. Worked case (Milesight UG67, gap G17,
reopening B16's residual): the `.bin` is a ZIP behind a 1024-byte prefix (`dd bs=1024 skip=1` yields a clean
ZIP), and its inner `router.tar` / `upgrade_tool.tar.gz` entries use legacy **ZipCrypto** — attackable by
**known-plaintext with `bkcrack`** (registered in [`INSTALLED-TOOLS.md`](INSTALLED-TOOLS.md) 2026-07-10).
Key gotcha: the known-plaintext MUST come from a **STORED (verbatim) entry** — a deflated entry whose
NUL-padding runs get compressed kills the trivial structural KP, so target an entry stored as `ZipCrypto Store`
(e.g. a verbatim `.gz` whose FNAME field is the KP). Frame such gaps as "blocker + attack path, see bkcrack",
never "firmware encryption is permanent".

## Dynamic phase (validation against a live system)

Beyond static decompilation, the engine can validate findings against a **live device/server**
(METHODOLOGY §12 — supervised, read-first). Tools:

| Tool | Purpose |
|---|---|
| `probe.sh check <ip> <port...>` | quick TCP reachability of the live system |
| `probe.sh run <target-dir> <probe>` | run a READ-ONLY protocol probe; preserves raw output in `sources/probes/` as `[CERT-hw]` evidence |
| `dynamic.sh frida-trace <target> <-i FUNC \| -I MODULE> [args...] <target-dir>` | Frida-trace a Linux-native process (by name/pid); preserves the trace log in `sources/probes/frida-trace-<ts>.log` as `[CERT-hw]` |
| `dynamic.sh frida-hook <target> <script.js> <target-dir>` | run a caller-supplied `Interceptor.attach` hook via the frida CLI; preserves BOTH the log AND the script.js (each sha256'd) in `sources/probes/` |
| `dynamic.sh boilerplate [func] [module]` | print a ready-to-edit `Interceptor.attach` skeleton to stdout to seed a hook script |
| `serial-console.sh list \| check \| run <target-dir> <com-port> <baud> <command>` | READ-ONLY serial/COM acquisition for an SSH-off live-install device — drives `System.IO.Ports.SerialPort` via Windows PowerShell over WSL interop; preserves the response in `sources/probes/` as `[CERT-hw]` (WSLInterop binfmt gotcha; `DYNAMIC-SETUP.md` §5) |
| `DYNAMIC-SETUP.md` | environment setup (WSL mirrored networking, gotchas, build-a-probe guide, §4a SPA GUI, §5 serial console, §6 scripted SSH) |
| `DEPLOY-WINDOWS-MINIPC.md` | deploying a static/Node web viewer to a Windows mini-PC (Task Scheduler + detached `node`): recipe, verification of the LIVE served copy, and the gotchas — `schtasks /End` does not kill a detached node child, `rc=$?` after a pipe reads the wrong command (kit CLAUDE.md §7 exit-code laundering) |
| `REMOTE-POWERSHELL.md` | driving non-interactive PowerShell on a live Windows host through an SSH/Cloudflare-Access tunnel: `-EncodedCommand` (UTF-16LE base64) instead of quoted strings, tagged output lines to survive CLIXML, and the five silent-failure modes (String `.ToString(fmt)`, callee variable clobbering, non-re-entrant socket scripts, `ssh` eating `while read` stdin, zsh `set --`) |
| `BACNET-TRENDLOG.md` | reading historical samples out of a BACnet Trend Log (object type 20) with ReadRange: props 141/134/145 decide the reachable window (`record-count × log-interval`), and a LARGE `-TrendCount` returns the OLDEST end truncated — the usable ceiling is ~60 records per call |
| `NIAGARA-N4-FRAMEWORK.md` | Niagara N4 framework reuse: runtime BComponent provisioning (`Type.getInstance()` + `add(...,Context.decoding)`, top-down `started()`); `Flags.READONLY` does NOT block a code `set()` (write via `Context.decoding`); native BOG (`ValueDocEncoder`/`ValueDocDecoder`) serializes a whole subtree incl. READONLY + links (a `.bog` = `BBogSpace.save`); plus two Gradle build gotchas (7.6 daemon ≠ Java 26 → `JAVA_HOME`; `findProjects()` two-layout discovery → scope as exclude) |

`dynamic.sh` reuses probe.sh's preservation discipline (same `sources/probes/` dir, `# <name> run <ts>` header, `ts()` helper). frida is a pipx/venv tool and is not assumed present: if the frida binary is absent the run degrades gracefully (non-zero + `install-tool.sh frida` hint) instead of pretending it ran, and `frida-hook` still preserves the script.js first.

The probe itself is a byte-for-byte port of the decompiled protocol client. A `[CERT-hw]` result that
contradicts a `[CERT]` code claim **wins** and triggers a correction (§3, §14).

## Corpus consistency gates (verification)

Read-only lint gates run at loop STOP / supervised review. Each exits `0` = ok · `1` = a real
defect (archive-blocking) · `2` = bad args. All are covered by `tests/*.test.sh` (run via
`tests/run-all.sh`) and are shellcheck-clean at `--severity=warning`.

| Gate | Checks |
|---|---|
| `verify-block.sh <block.md>` | per-block structure / certification-marker integrity; prints `resolved N of M` summary after citation resolution and WARNs (WARN-only, exit code unchanged) when N=0 and M>0 (all attempted citations fell back to extern/RANGE!/MISSING! — issue #956); M counts bt-cites and artifact-cites attempted; short-form cites, probe entries, jar archive paths, and `[BNNN]` back-references are excluded from M; WARN is graded by the block's declared `Type:` using P6's taxonomy; hints to set `SOURCE_ROOT`; honors `$SOURCE_ROOT` (env, opt-in) — when set, resolves backtick `file:line` citations against `$SOURCE_ROOT/<path>` (decompiled trees) before classifying as `extern` |
| `verify-sources.sh <target-dir>` | SOURCES.md preservation + registry↔block citation + web-snapshot integrity (METHODOLOGY §5) |
| `verify-state.sh <target-dir>` | RESEARCH-STATE living-mirror consistency (stale summary → premature STOP). Also checks `.claude/hooks/*.sh` for unreplaced template placeholders (P8); §7 three-state: absent-input / empty-input / no-match each produce distinct output. |
| `verify-corrections.sh <target-dir>` | §14 reciprocal-backlink lint: a block declaring "Corrects [Block N]" must have a matching "corrected in B&lt;this&gt;" note IN block N (a one-directional correction FAILs) |
| `verify-parity.sh <deliverable-file> <block-file-or-dir>` | corpus↔deliverable PARITY (subset check): every load-bearing value (hex color token, #RRGGBB/#RGB, case-insensitive) in a shipped deliverable (e.g. `prototypes/*/tokens.css`) must EXIST in the certified block palette it derives from — FAILs (exit 1) on any drifted/invented value the other gates miss (the pruebas-dashboards `tokens.css` drift, commits 6a9bc78/c27ec63) |
| `scan-secrets.sh [--committed] <target-dir>` | scans authored `.md` + high-risk config files (`.env*`, `*.conf/ini/properties/cfg`, `config.*`, `credentials`) for leaked secret VALUES violating the SECRETS DISCIPLINE — FAILs (exit 1) on a high-confidence leak (e.g. hex token, bearer secret, private-key block); ADVISORY-tier patterns WARN without failing (exit 0); excludes vendored and decompiled-artifact trees (false-positive surfaces). `--committed`: scan ALL committed history reachable from HEAD (every file version in the full git history via `git log --raw -z` NUL-safe enumeration + per-blob `git cat-file`, plus all commit messages) — a secret deleted from HEAD but still in history is caught; handles paths with embedded newlines, pipe characters, backslashes, and invalid UTF-8; uses `--no-replace-objects` so `refs/replace` cannot hide secret commits. Uses `-a/--text` so NUL-byte and invalid-UTF-8 files are not silently skipped. Target must be the repo root (refuses with exit 3 if a subdirectory). What `ensure-remote.sh` uses so the scan scope matches what `git push` sends. Requires git and at least one commit. Exit: 0 = clean in scope; 1 = high-confidence leak; 2 = bad args; 3 = degraded (`--committed`: git absent, not a git repo, no commits, not the repo root, mktemp failure, `git log --raw` failure, or cat-file failure). |
| `coverage-map.sh <corpus-dir> --subject <root> [--depth 1] [--ext java,...] [--top N] [--exclude-file <path>] [--exclude <glob>]` | subject-coverage map (METHODOLOGY §8): builds a `basename → module` index over the subject source tree at `--depth`, drops ambiguous basenames (same name in >1 module) and basenames shorter than 4 chars, then extension-bearing-token-matches (`<basename>.<ext>`, word-bounded, case-sensitive per METHODOLOGY §3) plus `<module>/` path tokens against corpus block files. `--exclude-file` (default: `<corpus-dir>/coverage-exclude.txt` when present) and `--exclude <glob>` drop whole units from denominator; always prints `excluded by declaration: N unit(s) (<file>\|none)`. Always prints `ambiguous basenames excluded: N` and `modules: <cited>/<total> cited · <uncited> never cited`; prints `--top N` uncited modules by file count desc; three distinguishable states: subject absent (exit 1) · subject empty-input (0 class basenames) · corpus empty-input (0 block files) · zero citations (`no-match`). Exit 2 bad args. Never modifies corpus or subject (propose-never-apply). |

Session-start sweep aggregator: `sweep-all.sh` runs `sweep-retros.sh`, `sweep-audits.sh`, `verify-registry.sh`, and `verify-kit-clean.sh` in sequence. Each script always runs independently — a failure or timeout in one does not abort the others. Exit: 0 if all four passed, non-zero if any failed or timed out. Intended for Codex and manual-run contexts (U-A20); redundant but harmless when Claude already executes the sweeps via its session-start hook. (OpenCode support was dropped on 2026-09-23 #954.) Per-script timeout: `RSDD_SWEEP_TIMEOUT` (default 30 s).

## Operator toolbelt (corpus lifecycle & kit maintenance)

Scripts the supervisor/operator runs directly. None of these are invoked by the research loop itself
and none modify the target corpus (propose-never-apply §8). Each `*-hook.sh` is a SessionStart wrapper
that surfaces its companion sweep as `additionalContext`; silence = clean.

| Tool | Purpose |
|---|---|
| `census-target.sh <target-path> [--threshold-count N] [--threshold-mb M]` | File-type histogram over ALL files in a research target (BOOTSTRAP mandatory step a2, METHODOLOGY §6). Stars types exceeding count/size thresholds — starred types must be claimed by a gap or dismissed. Exit 0 (information tool); exit 2 bad args. |
| `ensure-remote.sh <target-dir> [--yes] [--name <repo>]` | Create a PRIVATE-BY-CONSTRUCTION GitHub remote for a corpus and push it (METHODOLOGY §15). Hard-codes `--private`; refuses organization owners; requires `--yes` or `RSDD_ALLOW_REMOTE=1`; sweeps committed content (via `scan-secrets.sh --committed`) before push — scans ALL committed history reachable from HEAD (files + commit messages) so the scan scope matches what `git push` actually sends including any secret deleted from HEAD but still in history; refuses if the working tree is dirty; verifies visibility before any push; pushes with `--no-follow-tags` to prevent annotated tag messages (which may contain secrets) from being pushed when `push.followTags=true` is set. On a secret leak: the git history must be rewritten (e.g. git filter-repo). Exit 0 = remote present; 2 = bad args/not a git repo/no valid repo name; 3 = no consent (--yes / RSDD_ALLOW_REMOTE=1 absent); 4 = owner is an organization (refused); 5 = secret leak (scan refused push); 6 = visibility-verify failed (repo not confirmed private); 7 = gh missing/login unresolved/scan-secrets missing/create or push failed/scan degraded; 8 = dirty working tree (committed-content scan cannot equal what would be pushed — commit, add to .gitignore, or git stash -u first). |
| `research-sdd-init.sh <target-dir> [--corpus auto\|nested\|flat] [--prefix <slug>] [--force] [--wire] [--no-wire]` | Mechanical BOOTSTRAP scaffolder: creates corpus skeleton, copies templates, git-inits, rolls back on failure (METHODOLOGY BOOTSTRAP). Refuses if a corpus already exists (exit 3), UNLESS `--wire` is also given — in that case a corpus-already-exists target triggers the **wire-only** path: only `.claude/settings.json` is merged, no corpus file is touched, exit 0. **PROPOSE-NEVER-APPLY**: by default prints the `.claude/settings.json` wiring snippet for the operator to paste. Pass `--wire` to write it automatically (requires jq; idempotent merge, preserves existing hooks); if jq is absent, degrades gracefully: emits a `degraded:` message to stderr and falls back to print-only. `--no-wire` is a backward-compat alias for the default (print-only, no write). Emits follow-up checklist for the judgment half (classify artifact, seed gaps, register target, adapt hook). Exit 0 = scaffolded or wire-only merge succeeded; 1 = post-scaffold artifact missing (internal failure); 2 = bad args/not writable/missing template; 3 = corpus already exists and `--wire` not given (refused). |
| `research-sdd-status.sh <target-dir> [--next\|--sync-state] [--focus <slug>] [--stall-minutes N]` | Structured status + deterministic next-gap for a corpus. Default mode prints `campaign: none` when no `## Campaign queue` section exists, or `campaign: pending=N active=M done=K bound-stopped=J rejected=R` when it does; also `last_audit:`, `campaign_stop:` (from field or computed STOP condition), `campaign_bounds:`, and `last_iteration_ts: <ts> (age: N min)` (or `absent`). `--stall-minutes N` overrides the stall-detection threshold (default 15 min); WARN to stderr when an active/pending campaign's `last_iteration_ts` is older than the threshold. `--next` emits `NEXT\|STOP\|STALE\|BOOTSTRAP` line. `--sync-state` re-seeds the research-state envelope from ground truth (idempotent). Exit 0; 1 = lib helper missing or failed to define function, or sync-state target not found; 2 = bad args. |
| `research-sdd-archive.sh <target-dir> [--focus <name>] [--dry-run]` | Gated close discipline: runs consistency gates (verify-state, verify-sources, scan-secrets, undocumented_findings, MISSING-RETRO), regenerates CATALOG, touches INDEX, emits close-checklist. Refuses (exit 3) if a gate did not pass. The scan-secrets gate always runs a PLAIN working-tree scan (reads the filesystem directly — dirty, untracked and gitignored files all included) and, ONLY when the target IS a git repo root, ALSO runs `--committed` (everything ever committed, reachable from HEAD); both share scan-secrets.sh's own file scope (`*.md`/config files, not arbitrary source files). Dirtiness alone never refuses, only an actual leak does. A target with no git repo of its own gets the working-tree scan only (unchanged pre-#970 behaviour); a target nested inside a LARGER enclosing repo also gets the working-tree scan only, with a loud WARN (history needs a repo root to scan); an unrecognized git failure (missing git, dubious ownership, a malformed config, …) refuses loudly rather than silently downgrading coverage. `--focus <name>` scopes the run to a single focus (RESEARCH-STATE-`<name>`.md); the UF gate reports the scoped state-file count ("N of M state file(s) inspected"). Never authors content, never edits the kit, never mutates git (reads git state to select a scan strategy; never commits/pushes). Exit 0 = archived or dry-run; 1 = not a directory or lib helper failure; 2 = bad args/no RESEARCH-STATE/unknown --focus slug; 3 = gate refused. |
| `stage-retro.sh <path-to-retro.md>` | Stages ONE pending §18 retro as a kit branch (METHODOLOGY §18). Git plumbing only — creates the branch from `origin/main` (not local main), prints deltas + next steps. Applying deltas is the supervisor's judgment, never mechanical. Exit 1 = bad args/missing file/lib helper failure; 2 = retro not pending (already applied/dismissed) or unknown flag; 3 = kit has uncommitted changes; 4 = cannot checkout main; 5 = main has unpushed commits (mixed-history guard); 6 = `git fetch origin` failed (degraded: cannot verify remote state, refused to branch from a possibly stale base). |
| `reconcile-issues.sh <retro.md> \| --all` | Audits GitHub issue coverage for OPEN kit deltas (resolves #794; Phase 3 of #557). For each open delta, classifies: `tracked` (a matching open issue exists on angeles725/sdd-investigacion with the `Source retro: <target>/retros/<file> · <row-id>` body signature), `untracked` (no matching issue — actionable gap), `orphaned` (open issue whose delta row is no longer open). `--all` walks every target in TARGETS.md. propose-never-apply: REPORT ONLY — never creates/closes/edits any issue or marker. §7 anti-silent-zero: absent-input/empty-input/no-match are always distinct. Degraded probe: gh absent or unauthenticated → typed `degraded:` + exit 1. Findings are advisory (WARN-only, never fail the run). Exit 1 = retro/TARGETS.md not found, lib helper failure, or gh absent/unauthenticated (degraded). |
| `sweep-tools.sh` | Fleet tool census: finds tools under `<target>/tools/` across all TARGETS.md entries, cross-checks against `T<N>` retro rows, reports unrecorded tools. WARN-only; read-only. Exit 1 on operational failure (TARGETS.md or lib helper missing). |
| `sweep-breakthroughs.sh` | Fleet Breakthrough Ledger drift guard (METHODOLOGY §22). WARNs on blocks tagged `**Breakthrough:**` absent from BREAKTHROUGHS.md, and ledger rows whose block lost the tag. Anti-silent-zero: absent/empty/no-match are always distinct. Exit 1 on operational failure only. |
| `sweep-audits-hook.sh` | SessionStart wrapper for `sweep-audits.sh` — surfaces pending §13 audit reports as `additionalContext`. Default mode collapses per-target empty-input INFO lines to one counted summary; pass `--full` for full detail. Silent on clean; surfaces sweep failures loudly. |
| `sweep-breakthroughs-hook.sh` | SessionStart wrapper for `sweep-breakthroughs.sh` — surfaces unindexed/drifted breakthroughs as `additionalContext`. Default mode collapses per-target empty-input and no-match INFO lines to one counted summary; pass `--full` for full detail. |
| `sweep-retros-hook.sh` | SessionStart wrapper for `sweep-retros.sh` — surfaces pending §18 retros as `additionalContext`. |
| `sweep-tools-hook.sh` | SessionStart wrapper for `sweep-tools.sh` — surfaces unrecorded-tool headline when unrecorded tools exist, and not-traversed INFO when registered targets are absent on disk. Silent only when every tool is ledgered and all targets were reached. |
| `verify-kit-clean-hook.sh` | SessionStart wrapper for `verify-kit-clean.sh` — emits a DIRTY/unpushed banner only when the kit is not clean; silent when clean. |
| `verify-registry-hook.sh` | SessionStart wrapper for `verify-registry.sh` — surfaces TARGETS.md `N md` vs real block-count drift as `additionalContext`. |
| `verify-doc-consistency.sh` | Guards kit entry-point docs (SKILL.md, PROMPT-LOOP.md, README.md) against section-count drift vs METHODOLOGY.md and orphan §N references. WARN-only, read-only. Exit 0 on clean or findings; 1 on operational failure (missing required doc). |
| `verify-tool-catalog.sh` | Drift guard: cross-checks INSTALLED-TOOLS.md log entries against tool-registry.md capability rows. WARNs on installed tools with no catalog entry; never edits either file. Exit 1 only on operational failure (either input file missing). |
| `verify-tool-catalog-hook.sh` | SessionStart wrapper for `verify-tool-catalog.sh` — emits drift notice ONLY when uncataloged tools exist; silent when catalog is complete. |

## DRC-fixture oracle (constraint-DSL CI gate)

For any target that uses a **constraint DSL** (KiCad `.kicad_dru`, custom lint rules, firmware config
schemas, access control policies) where an unknown keyword can **silently disable the entire rule-set**
(exit 0, no stderr, no warning), build a fixture-based oracle with a **mandatory control-positive**:

1. **Bad fixture** — a deliberately malformed rule (known-invalid keyword) that MUST fire a violation.
2. **Good fixture** — the well-formed equivalent that MUST pass cleanly.
3. **Control-positive assertion** — a rule that MUST fire on any valid board/input. If it passes clean,
   the entire config was silently poisoned and the oracle must STOP with failure, not a green result.

The control-positive is what makes the oracle trustworthy. **A fixture oracle without a control-positive
proves nothing**: if the config is poisoned, every test passes and the suite declares victory over silence.
This is the "keyword-poison" variant of the Anti-Silent-Zero doctrine (CLAUDE.md §7); the operative rule
for research use lives in `METHODOLOGY.md` §11 under "verifying the verifier".

Evidence: kidcad `tools/drc_harness/` caught four independent keyword-poison bugs in KiCad 10.0.3 (blocks
B71, B73, B74, B77) using 14 bad/good fixture pairs across 7 constraint families. Each bug: exit 0, all
custom rules silently disabled, no visible signal without the control-positive.

## Audit mode

To re-verify an existing corpus (not discover new gaps): `PROMPT-AUDIT.md` + `templates/audit.template.md`
(METHODOLOGY §13). Output is an audit-delta under `audits/`, READ-ONLY on the audited corpus.
