# Tool Registry — Research-SDD toolbelt

Map of **artifact type → tool → wrapper**. The loop runs `profile-target.sh`
over the target's binaries (uses `file`) and picks the wrapper. All paths are
verified in this environment (WSL Ubuntu, 2026-06-28).

| Artifact type | Detection (`file`) | Tool | Wrapper | Status |
|---|---|---|---|---|
| JAR / `.class` Java | `Java class data` / `Zip archive` (jar) | Vineflower (pref.), CFR, Procyon, `javap -p -c` | `decompile-java.sh` | ✅ |
| .NET DLL/EXE | `PE32 .NET assembly` / `Mono/.Net assembly` | `ilspycmd` (8.2.0) | `decompile-net.sh` | ✅ |
| Native ELF/PE | `ELF ... executable` / `PE32 executable` | Ghidra headless (decompile) → r2/objdump fallback | `decompile-native.sh` | ✅ |
| Firmware / packaged | `data` / known signatures | `binwalk -e` + `yara` | `scan-firmware.sh` | ✅ |
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
| Java 21 (`JAVA_HOME`) | `/home/linuxbrew/.linuxbrew/opt/openjdk@21` |
| Vineflower | `/home/cristian/modules/Prototipos/Reflow/vineflower.jar` |
| CFR | `/home/cristian/modules/Prototipos/Reflow/cfr.jar` |
| Procyon | `/home/cristian/modules/Prototipos/modulos/procyon.jar` |
| `javap` | in PATH (`/home/linuxbrew/.linuxbrew/bin/javap`) |
| `ilspycmd` | `/home/cristian/.dotnet/tools/ilspycmd` |
| Ghidra `analyzeHeadless` | `/home/linuxbrew/.linuxbrew/Cellar/ghidra/12.1/libexec/support/analyzeHeadless` |
| `radare2` / `objdump` / `readelf` / `nm` / `strings` | in PATH |
| `binwalk` | `/usr/bin/binwalk` |
| `yara` (4.5.5) | in PATH |
| `pdftotext` / `pdfinfo` / `pdffonts` / `pdftoppm` / `tesseract` (langs: `spa`,`eng`,`spa_best`) / `pandoc` | in PATH |
| PDF→MD venv (`pymupdf4llm`, `ocrmypdf`, `marker`, `docling`, `pdfplumber`, torch-cpu) | `~/.local/share/research-sdd-tools/venv` (override: `RESEARCH_SDD_VENV`) |

## Environment override

All wrappers accept path overrides via environment variables
(`VINEFLOWER`, `CFR`, `PROCYON`, `ILSPYCMD`, `GHIDRA_INSTALL_DIR`, `JAVA_HOME`),
so the toolbelt is portable to another machine without editing the scripts.

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

It resolves each tool via PATH **and** known install dirs — linuxbrew `Cellar/*/...` globs, the dotnet
tools dir, and the Vineflower/CFR/Procyon jar paths — so a tool reachable only off-PATH is reported
`available`, not `MISSING`. Do NOT infer availability from `which` alone: assuming "Ghidra not available"
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
| `verify-parity.sh <deliverable-file> <block-file-or-dir>` | corpus↔deliverable PARITY (subset check): every load-bearing value (hex color token, #RRGGBB/#RGB, case-insensitive) in a shipped deliverable (e.g. `prototypes/*/tokens.css`) must EXIST in the certified block palette it derives from — FAILs (exit 1) on any drifted/invented value the other gates miss (the pruebas-dashboards `tokens.css` drift, commits 6a9bc78/c27ec63) |

## Audit mode

To re-verify an existing corpus (not discover new gaps): `PROMPT-AUDIT.md` + `templates/audit.template.md`
(METHODOLOGY §13). Output is an audit-delta under `audits/`, READ-ONLY on the audited corpus.
