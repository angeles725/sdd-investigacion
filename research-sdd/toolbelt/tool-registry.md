# Tool Registry — Research-SDD toolbelt

Map of **artifact type → tool → wrapper**. The loop runs `profile-target.sh`
over the target's binaries (uses `file`) and picks the wrapper. All paths are
verified in this environment (WSL Ubuntu, 2026-06-28).

| Artifact type | Detection (`file`) | Tool | Wrapper | Status |
|---|---|---|---|---|
| JAR / `.class` Java | `Java class data` / `Zip archive` (jar) | Vineflower (pref.), CFR, Procyon, `javap -p -c` | `decompile-java.sh` | ✅ |
| JAR corroboration evidence | Valid regular JAR/ZIP | Vineflower + CFR + Procyon + `javap` + `jdeps` | `corroborate-java.sh` (`java-corroboration.v1`) | ✅ |
| .NET DLL/EXE | `PE32 .NET assembly` / `Mono/.Net assembly` | `ilspycmd` (8.2.0) | `decompile-net.sh` | ✅ |
| Native ELF/PE | `ELF ... executable` / `PE32 executable` | Ghidra headless (decompile) → r2/objdump fallback | `decompile-native.sh` | ✅ |
| Native corroboration evidence | Regular native binary | radare2 static analysis in Bubblewrap | `corroborate-native.sh` (`native-static.v1`) | ✅ |
| Native curated evidence | Regular native binary | Ghidra curated exporter in Bubblewrap | `decompile-native.sh ghidra-evidence` (`ghidra-corroboration.v1`) | ✅ |
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
| Binary parsed by a Kaitai Struct .ksy | Any regular binary with a matching .ksy grammar | ksc 0.11 (JVM compile, Stage 1) + kaitaistruct 0.11 Python driver (bounded SEQ_FIELDS walk with `_debug` offsets, Stage 2) in network-denied Bubblewrap; field-count, depth, and value-bytes caps; parse_error captured without traceback | `corroborate-kaitai.sh` ([`kaitai-evidence.v1`](kaitai-evidence.v1.md)) | ✅ |
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
| CHM help file | `MS Windows HtmlHelp Data` | `7z x <file>.chm -o<dir>/` (WSL/Linux, preferred); `extract_chmLib <file>.chm <dir>/` or `pychm` (WSL alternatives); `hh.exe -decompile <dir>/ <file>.chm` (Windows native). Extracted topics land under `sources/extracted/<basename>/Topics/`. | (direct) | ✅ |
| DXF/DWG drawing | AutoCAD DXF exchange data / DWG binary drawing. NOT auto-detected: `dxf`/`dwg` are absent from `profile-target.sh`'s `BASE_EXT` allowlist — pass `EXTRA_EXT="dxf dwg"` to have it routed | ezdxf `addons.drawing` renderer — renders walls, entities, and layout geometry to **PNG or SVG** as a visual oracle | `render-drawing.sh <drawing.dxf\|.dwg> <out.png\|.svg> [--dpi N] [--style dark\|light\|white]` | ✅ |
| PDF datasheet/manual | `PDF document` | **`extract-pdf.sh`** — tier 1 (text layer) `pymupdf4llm`→MD w/ tables + `<!-- p.N -->` anchors; tier 2 (scanned, `fonts=0`) `ocrmypdf`/`marker`/`docling`/`tesseract` OCR | `extract-pdf.sh` (download still via `fetch-doc.sh`) | ✅ |
| Web page / forum / link | URL | `curl`/`wget` + `pandoc` → markdown | `fetch-doc.sh` | ✅ |
| Device web-UI HTML config snapshot | HTML page captured from an embedded device's local HTTP config interface (e.g. `http://192.168.x.y/config/`) — NOT a public URL; do NOT use `fetch-doc.sh` or cite as `[CERT-web]` | Manual `curl -o snapshots/<name>.html http://<device-ip>/path` or browser save; cite as `[CERT] snapshots/<name>.html:<line>`; store under `snapshots/` in the corpus root | (direct) | ✅ |
| Obfuscated JS | `.js` | `js-beautify` | (direct) | ✅ |
| Source code | known extension | direct reading + CodeGraph | (direct) | ✅ |
| XML IntelliSense / OpenAPI / protobuf API contract | `.xml` IntelliSense doc, `.yaml`/`.json` OpenAPI spec, `.proto` IDL — NOT auto-detected by `profile-target.sh`; pass `EXTRA_EXT="xml yaml proto"` as needed | Parse → slice by namespace / service / package → emit one MD or JSON per slice into `_extract/` + an `_extract/index.json` mapping slices to authors. Makes "source-before-agent" workable at API scale (see `api-openness/_extract/author_workflow.js` for a reference pipeline). | (direct, custom per-target; no kit wrapper) | ✅ |
| Library/framework docs (MCP) | context7 / MCP query | `resolve-library-id` + `query-docs` | (MCP; snapshot load-bearing hits per METHODOLOGY §5) | ✅ |
| MCP-server capability | added to `~/.claude.json` mcpServers | e.g. `chrome-devtools` (reach JS-rendered pages) | (MCP; log in INSTALLED-TOOLS.md per §10) | ✅ |
| Browser / WebGL render target | headless Chrome (swiftshader) + local HTTP server | `tools/probe.mjs` (draw-call/triangle counts exact; FPS not) | (dynamic §12; `DYNAMIC-SETUP.md` §4) | ✅ |
| Windows/PowerShell-over-SSH probe | live-install Windows host reachable via SSH | `powershell -NoProfile -EncodedCommand <b64>` via `connect-ssh.sh`; silent-failure gotchas documented (§1–5 SSH/PS; §6 Windows-native CLI from WSL) | (dynamic §12; [`WINDOWS-SSH-PROBES.md`](WINDOWS-SSH-PROBES.md)) | ✅ |
| PowerShell source syntax (`.ps1`) | `.ps1` extension; NOT auto-detected by `profile-target.sh` | `pwsh` local — `[System.Management.Automation.Language.Parser]::ParseFile`; validates grammar only, not runtime semantics or PS 5.1/7 differences; path quoting uses env-var (not interpolation) so single-quote paths are safe | `pslint.sh <file.ps1> [...]` — exit 0 all clean · 1 **any finding or failure**: syntax errors, a named file missing, or the verifier itself failing (non-zero `pwsh`) · 2 bad args · 3 pwsh unavailable; assumes UTF-8/BOM'd input (UTF-16LE-without-BOM reports a false OK — see the script header); READ-ONLY, never modifies the file; fleet targets: HotelHilton (10 `.ps1`) and logosoft (`plc-client/`, 12 `.ps1`) | ✅ |

## Tool paths (verified)

| Tool | Path |
|---|---|
| Java 21 + `javap` | resolved by `lib/tool-env.sh` (`JAVA_HOME` → `RESEARCH_SDD_JAVA_HOME` → stable Homebrew `opt` → distro JVM) |
| Vineflower / CFR / Procyon | `*_JAR` → legacy env override → `RESEARCH_SDD_TOOL_HOME/java` → portable `$HOME` locations |
| `ilspycmd` | `/home/cristian/.dotnet/tools/ilspycmd` |
| Ghidra `analyzeHeadless` | `ANALYZE_HEADLESS` → `GHIDRA_HOME` → `GHIDRA_INSTALL_DIR` → PATH → stable Homebrew `opt` → `/opt/ghidra*` |
| `radare2` / `objdump` / `readelf` / `nm` / `strings` | in PATH |
| `binwalk` | `/usr/bin/binwalk` |
| `yara` (4.5.5) | in PATH |
| `pdftotext` / `pdfinfo` / `pdffonts` / `pdftoppm` / `tesseract` (langs: `spa`,`eng`,`spa_best`) / `pandoc` | in PATH |
| PDF→MD venv (`pymupdf4llm`, `ocrmypdf`, `marker`, `docling`, `pdfplumber`, torch-cpu) | `~/.local/share/research-sdd-tools/venv` (override: `RESEARCH_SDD_VENV`) |
| TShark/tcpdump, GDB/gdb-multiarch, strace/ltrace, QEMU system/user-static/img | system CLI paths; each is smoke-tested by `detect-tools.sh` |
| Hyperscan (`libhs.pc`) | system multiarch pkg-config dirs, injected only into the `rsdd_pkg_config` child process |

## Environment override

Java and native wrappers share `lib/tool-env.sh`. They accept path overrides via
environment variables (`VINEFLOWER_JAR`, `CFR_JAR`, `PROCYON_JAR`; legacy
`VINEFLOWER`, `CFR`, `PROCYON`; `ANALYZE_HEADLESS`, `GHIDRA_HOME`,
`GHIDRA_INSTALL_DIR`, `ILSPYCMD`, `JAVA_HOME`, `RESEARCH_SDD_JAVA_HOME`,
`RESEARCH_SDD_TOOL_HOME`), so the toolbelt is portable without editing scripts.
`RSDD_BREW_PREFIX` exists for hermetic/alternate-prefix resolution.
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
| Dart/Flutter AOT (`app.so`) | `install-tool.sh blutter` | worawit/blutter | git clone + pip; needs cmake/C++ & a Dart SDK for full native dump |
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

`dynamic.sh` reuses probe.sh's preservation discipline (same `sources/probes/` dir, `# <name> run <ts>` header, `ts()` helper). frida is a pipx/venv tool and is not assumed present: if the frida binary is absent the run degrades gracefully (non-zero + `install-tool.sh frida` hint) instead of pretending it ran, and `frida-hook` still preserves the script.js first.

The probe itself is a byte-for-byte port of the decompiled protocol client. A `[CERT-hw]` result that
contradicts a `[CERT]` code claim **wins** and triggers a correction (§3, §14).

## Corpus consistency gates (verification)

Read-only lint gates run at loop STOP / supervised review. Each exits `0` = ok · `1` = a real
defect (archive-blocking) · `2` = bad args. All are covered by `tests/*.test.sh` (run via
`tests/run-all.sh`) and are shellcheck-clean at `--severity=warning`.

| Gate | Checks |
|---|---|
| `verify-block.sh <block.md>` | per-block structure / certification-marker integrity |
| `verify-sources.sh <target-dir>` | SOURCES.md preservation + registry↔block citation + web-snapshot integrity (METHODOLOGY §5) |
| `verify-state.sh <target-dir>` | RESEARCH-STATE living-mirror consistency (stale summary → premature STOP) |
| `verify-corrections.sh <target-dir>` | §14 reciprocal-backlink lint: a block declaring "Corrects [Block N]" must have a matching "corrected in B&lt;this&gt;" note IN block N (a one-directional correction FAILs) |
| `verify-parity.sh <deliverable-file> <block-file-or-dir>` | corpus↔deliverable PARITY (subset check): every load-bearing value (hex color token, #RRGGBB/#RGB, case-insensitive) in a shipped deliverable (e.g. `prototypes/*/tokens.css`) must EXIST in the certified block palette it derives from — FAILs (exit 1) on any drifted/invented value the other gates miss (the pruebas-dashboards `tokens.css` drift, commits 6a9bc78/c27ec63) |

Session-start sweep aggregator: `sweep-all.sh` runs `sweep-retros.sh`, `sweep-audits.sh`, `verify-registry.sh`, and `verify-kit-clean.sh` in sequence. Each script always runs independently — a failure or timeout in one does not abort the others. Exit: 0 if all four passed, non-zero if any failed or timed out. Intended for Codex and manual-run contexts (U-A20); redundant but harmless when Claude/OpenCode already execute the sweeps via their session-start hooks. Per-script timeout: `RSDD_SWEEP_TIMEOUT` (default 30 s).

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
