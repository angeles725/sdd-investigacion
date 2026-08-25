# Installed tools log — Research-SDD

> Append-only. Written by install-tool.sh. status: installed | already | needs-approval | failed

| Tool | How | Status | Target | Date (UTC) | Notes |
|---|---|---|---|---|---|
| blutter | `git clone worawit/blutter + pip --user (requests pyelftools capstone)` | installed | EduVolt-Designer | 2026-06-28T09:57:27Z | /home/cristian/dev/blutter; needs cmake+C++ & a Dart SDK at build/run time for full native dump |
| blutter-build | `brew(cmake ninja dart-sdk capstone icu4c pkg-config)+venv(capstone pyelftools requests); dartvm3.9.0_android_x64 static lib BUILT ok; blutter exe FAILED to compile: arm64-only disassembler/dumper (CSREG_DART_THR / AsmInstruction undefined for x64); --no-analysis also fails. EduVolt app.so is windows/x64 -> unsupported by blutter` | failed | EduVolt-Designer | 2026-06-28T10:28:36Z | external/manual |
| blutter | `compat precheck (file: ELF 64-bit LSB shared object, x86-64, ve)` | incompatible | EduVolt-Designer | 2026-06-28T17:46:14Z | ARM64-only tool; target is x64/x86 -> NOT building (saves ~20min dead-end). Use strings/manual or an x64 Dart-AOT tool |
| typst | `brew` | already | kit | 2026-08-25T07:28:28Z | resolved via `command -v typst` at `/home/linuxbrew/.linuxbrew/bin/typst`; v0.15.1; deliverable report generation (PDF/DOCX via pandoc --pdf-engine=typst) |

## js-beautify (JS deobfuscator/beautifier) — 2026-07-02
- **Uso**: beautify de la SPA Vue minificada `app.4509efb4.js` / `chunk-vendors.3fecdb47.js` (nmodsreflow-ux focus, gap U3).
- **Disponibilidad**: ya presente en PATH (`/mnt/c/Users/equipo/AppData/Roaming/npm/js-beautify`) + node v22.22.2 / npx (linuxbrew). No requirió instalación.
- **Invocación**: `js-beautify <min.js> -o <scratchpad>/<name>.beauty.js` (o `npx --yes js-beautify`).
- **Nota**: READ-ONLY sobre el sujeto — beautify a temp en scratchpad, nunca sobre la fuente.

## bkcrack (ZipCrypto known-plaintext attack) — 2026-07-10
- **Uso**: atacar el cifrado legacy ZipCrypto de los firmware Milesight UG67 (`.bin` = ZIP con `router.tar` + `upgrade_tool.tar.gz`). Target gateway-ug67, gap G17 (reabre el residual firmware-encryption de B16).
- **Disponibilidad**: NO en PATH. Compilado desde fuente: `git clone --depth 1 https://github.com/kimci86/bkcrack && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`. Binario en `build/src/cli/bkcrack` (v1.8.1). Requiere cmake+g++ (presentes vía linuxbrew).
- **Invocación**: `bkcrack -C <clean.zip> -c <entry> -p <plainfile> -o <offset>` (offset = coord del stream COMPRIMIDO, mín -12). Recupera claves internas X Y Z; luego `-r <len> ?p` recupera password, `-k X Y Z -d out` descifra. El `.bin` lleva 1024 bytes de prefijo: `dd bs=1024 skip=1` para el zip limpio.
- **Gotcha clave**: el known-plaintext debe ser de una región STORED (verbatim). Los deflaters que COMPRIMEN los runs de NUL (padding del tar) anulan el KP estructural trivial. En Milesight, sólo `42_r4` trae `upgrade_tool.tar.gz` como `ZipCrypto Store` (gzip verbatim) → KP = FNAME del gzip.
- **Nota**: READ-ONLY — opera sobre copias en scratchpad, nunca sobre el `.bin` del corpus.
| vineflower | `https://github.com/Vineflower/vineflower/releases/download/1.12.0/vineflower-1.12.0.jar` | installed | ? | 2026-08-23T23:58:44Z | pinned 1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d |
| cfr | `https://github.com/leibnitz27/cfr/releases/download/0.152/cfr-0.152.jar` | installed | ? | 2026-08-23T23:58:44Z | pinned f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2 |
| procyon | `https://github.com/mstrobel/procyon/releases/download/v0.6.0/procyon-decompiler-0.6.0.jar` | installed | ? | 2026-08-23T23:58:45Z | pinned 821da96012fc69244fa1ea298c90455ee4e021434bc796d3b9546ab24601b779 |
| jadx | `brew install jadx` | installed | ? | 2026-08-23T23:59:19Z |  |
| apktool | `brew install apktool` | installed | ? | 2026-08-23T23:59:24Z |  |
| yara | `brew (present)` | already | ? | 2026-08-23T23:59:24Z |  |
| jadx | `brew (present)` | already | ? | 2026-08-23T23:59:35Z |  |
| frida | `pipx install frida-tools` | failed | ? | 2026-08-24T00:00:14Z | pipx missing or install failed; ensure ~/.local/bin on PATH |
| uncompyle6 | `pip decompyle3` | failed | ? | 2026-08-24T00:00:15Z |  |
| ilspycmd | `dotnet tool ilspycmd` | failed | ? | 2026-08-24T00:00:15Z |  |
| frida | `pipx install frida-tools` | failed | ? | 2026-08-24T00:00:26Z | pipx missing or install failed; ensure ~/.local/bin on PATH |
| frida | `pipx install frida-tools` | installed | ? | 2026-08-24T00:01:28Z | frida + frida-trace -> ~/.local/bin |
| pycdc | `git clone zrax/pycdc + cmake make` | installed | ? | 2026-08-24T00:02:43Z | /home/cristian/dev/pycdc |
| uncompyle6 | `pip decompyle3` | failed | ? | 2026-08-24T00:02:44Z |  |
| ilspycmd | `dotnet tool install -g ilspycmd` | installed | ? | 2026-08-24T00:03:59Z |  |
| kaitai-struct-compiler | `brew (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| hexedit | `brew (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| bvi | `brew (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| capa | `pipx (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| floss | `pipx (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| unblob | `pipx (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| krak2 | `cargo (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| bwrap | `apt (present)` | already | ? | 2026-08-24T04:23:31Z |  |
| latex | `apt (present); TeX Live 2023/Debian pdflatex/xelatex/lualatex/latexmk` | already | kit | 2026-08-25T19:47:14Z | external/manual |
| circuitikz | `apt/texlive (present); circuitikz.sty` | already | kit | 2026-08-25T19:47:14Z | external/manual |
| diec | `apt (present); /usr/bin/diec Detect-It-Easy CLI` | already | kit | 2026-08-25T19:58:59Z | external/manual |
