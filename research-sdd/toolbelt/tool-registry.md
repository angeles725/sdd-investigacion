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
| In-VM run receipt | VM/sandbox output artifacts | vm_receipt.py (schema only, no VM launch) | `vm_receipt.py build\|validate\|verify` ([`vm-run-receipt.v1`](vm-run-receipt.v1.md)) | ✅ |
| Firmware / packaged | `data` / known signatures | Binwalk scan + YARA (no extraction) | `scan-firmware.sh` | ✅ |
| PDF datasheet/manual | `PDF document` | **`extract-pdf.sh`** — tier 1 (text layer) `pymupdf4llm`→MD w/ tables + `<!-- p.N -->` anchors; tier 2 (scanned, `fonts=0`) `ocrmypdf`/`marker`/`docling`/`tesseract` OCR | `extract-pdf.sh` (download still via `fetch-doc.sh`) | ✅ |
| Web page / forum / link | URL | `curl`/`wget` + `pandoc` → markdown | `fetch-doc.sh` | ✅ |
| Obfuscated JS | `.js` | `js-beautify` | (direct) | ✅ |
| Source code | known extension | direct reading + CodeGraph | (direct) | ✅ |
| Library/framework docs (MCP) | context7 / MCP query | `resolve-library-id` + `query-docs` | (MCP; snapshot load-bearing hits per METHODOLOGY §5) | ✅ |
| MCP-server capability | added to `~/.claude.json` mcpServers | e.g. `chrome-devtools` (reach JS-rendered pages) | (MCP; log in INSTALLED-TOOLS.md per §10) | ✅ |
| Browser / WebGL render target | headless Chrome (swiftshader) + local HTTP server | `tools/probe.mjs` (draw-call/triangle counts exact; FPS not) | (dynamic §12; `DYNAMIC-SETUP.md` §4) | ✅ |

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

## ghidra-mcp (agent-directed decompilation)

In addition to the headless mode (always available), `ghidra-mcp` exposes Ghidra as an
MCP server for interactive, agent-directed analysis. It requires Ghidra
running with the plugin + an open binary (server at `127.0.0.1:8089`).
See `GHIDRA-MCP.md` (generated after installation) for the usage flow.

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

## Audit mode

To re-verify an existing corpus (not discover new gaps): `PROMPT-AUDIT.md` + `templates/audit.template.md`
(METHODOLOGY §13). Output is an audit-delta under `audits/`, READ-ONLY on the audited corpus.
