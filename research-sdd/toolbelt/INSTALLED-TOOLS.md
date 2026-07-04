# Installed tools log — Research-SDD

> Append-only. Written by install-tool.sh. status: installed | already | needs-approval | failed

| Tool | How | Status | Target | Date (UTC) | Notes |
|---|---|---|---|---|---|
| blutter | `git clone worawit/blutter + pip --user (requests pyelftools capstone)` | installed | EduVolt-Designer | 2026-06-28T09:57:27Z | /home/cristian/dev/blutter; needs cmake+C++ & a Dart SDK at build/run time for full native dump |
| blutter-build | `brew(cmake ninja dart-sdk capstone icu4c pkg-config)+venv(capstone pyelftools requests); dartvm3.9.0_android_x64 static lib BUILT ok; blutter exe FAILED to compile: arm64-only disassembler/dumper (CSREG_DART_THR / AsmInstruction undefined for x64); --no-analysis also fails. EduVolt app.so is windows/x64 -> unsupported by blutter` | failed | EduVolt-Designer | 2026-06-28T10:28:36Z | external/manual |
| blutter | `compat precheck (file: ELF 64-bit LSB shared object, x86-64, ve)` | incompatible | EduVolt-Designer | 2026-06-28T17:46:14Z | ARM64-only tool; target is x64/x86 -> NOT building (saves ~20min dead-end). Use strings/manual or an x64 Dart-AOT tool |

## js-beautify (JS deobfuscator/beautifier) — 2026-07-02
- **Uso**: beautify de la SPA Vue minificada `app.4509efb4.js` / `chunk-vendors.3fecdb47.js` (nmodsreflow-ux focus, gap U3).
- **Disponibilidad**: ya presente en PATH (`/mnt/c/Users/equipo/AppData/Roaming/npm/js-beautify`) + node v22.22.2 / npx (linuxbrew). No requirió instalación.
- **Invocación**: `js-beautify <min.js> -o <scratchpad>/<name>.beauty.js` (o `npx --yes js-beautify`).
- **Nota**: READ-ONLY sobre el sujeto — beautify a temp en scratchpad, nunca sobre la fuente.
