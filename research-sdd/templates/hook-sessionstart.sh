#!/usr/bin/env bash
# SessionStart hook — Research-SDD protocol for <SUBJECT>.
# Mirror of the niagara-research hook, parameterized. Copy it to:
#   <TARGET>/.claude/hooks/research-protocol.sh
# and register it in <TARGET>/.claude/settings.json (matcher startup|resume|clear).
# Replace <SUBJECT> and the source/tool paths with the target's.
set -euo pipefail

read -r -d '' CTX <<'EOF' || true
RESEARCH PROTOCOL — <SUBJECT> (Research-SDD)

Every session in this project is READ-ONLY research of <SUBJECT>. Before
answering any research question, ALWAYS follow this order:

1. FIRST search the project's own .md blocks (truth already distilled):
   - <prefix>-block*.md
   - INDEX.md  (map + Pending/gaps section)
   - CATALOG.md
   Review them before opening any tool.

2. Toolbelt tools (Research-SDD) — pick based on the artifact type:
   - profile-target.sh   -> classifies binaries and suggests the wrapper
   - decompile-java.sh   -> .jar/.class (Vineflower/CFR/Procyon, javap)
   - decompile-net.sh    -> .dll/.exe .NET (ilspycmd)
   - decompile-native.sh -> native ELF/PE (Ghidra headless / r2)  | ghidra-mcp for directed analysis
   - scan-firmware.sh    -> firmware/packaged (binwalk + yara)
   - fetch-doc.sh        -> download and PRESERVE datasheets/manuals/forums in sources/
   (Kit: /home/cristian/investigacion/sdd-investigacion/research-sdd/toolbelt/)

3. PRIMARY SOURCES of the subject (real paths — fill in per target):
   - <path to binaries/decompiled output/source code of the system under study>

4. PROVENANCE AND CERTAINTY (mandatory markers on every claim):
   [CERT-hw] live system/device (highest) · [CERT-live] live remote service · [CERT] local primary ·
   [CERT-doc] official document (sources/) · [CERT-web] official web · [CERT-a] forum/secondary ·
   [INFER] deduction. No citation ⇒ [INFER] or omit.

5. EXTERNAL EVIDENCE: if you find a relevant datasheet/manual/forum/link, DOWNLOAD it with
   fetch-doc.sh (lands in sources/ + registered in SOURCES.md) and cite the local file.

ACTION AT START: tell the user you will first review the project's .md blocks
and ask which toolbelt tool(s) to use for this research before choosing.
EOF

jq -n --arg ctx "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
