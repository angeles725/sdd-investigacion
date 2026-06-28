# Installed tools log — Research-SDD

> Append-only. Written by install-tool.sh. status: installed | already | needs-approval | failed

| Tool | How | Status | Target | Date (UTC) | Notes |
|---|---|---|---|---|---|
| blutter | `git clone worawit/blutter + pip --user (requests pyelftools capstone)` | installed | EduVolt-Designer | 2026-06-28T09:57:27Z | /home/cristian/dev/blutter; needs cmake+C++ & a Dart SDK at build/run time for full native dump |
| blutter-build | `brew(cmake ninja dart-sdk capstone icu4c pkg-config)+venv(capstone pyelftools requests); dartvm3.9.0_android_x64 static lib BUILT ok; blutter exe FAILED to compile: arm64-only disassembler/dumper (CSREG_DART_THR / AsmInstruction undefined for x64); --no-analysis also fails. EduVolt app.so is windows/x64 -> unsupported by blutter` | failed | EduVolt-Designer | 2026-06-28T10:28:36Z | external/manual |
