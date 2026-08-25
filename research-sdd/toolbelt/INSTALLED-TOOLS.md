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
