#!/usr/bin/env bash
# SessionStart hook — Research-SDD protocol for <SUBJECT>.
# Mirror of the niagara-research hook, parameterized. Copy it to:
#   <TARGET>/.claude/hooks/research-protocol.sh
# and register it in <TARGET>/.claude/settings.json (matcher startup|resume|clear).
# Replace <SUBJECT> and the source/tool paths with the target's.
#
# §479: also records the session-start git sha so retro-gate.sh can detect
# which research files changed during this session.
set -euo pipefail

# Read session_id from Stop-hook JSON stdin (§479 session-sha recording)
_hook_stdin=$(cat)
_session_id=$(printf '%s' "$_hook_stdin" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""

# Record session-start git sha for retro-gate.sh (hooks live two levels below target)
_hook_target="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -n "$_session_id" ]; then
  _sha=$(git -C "$_hook_target" rev-parse HEAD 2>/dev/null) || _sha=""
  if [ -n "$_sha" ]; then
    mkdir -p "$_hook_target/.claude"
    printf '%s\n' "$_sha" > "$_hook_target/.claude/.rsdd-session-${_session_id}"
  fi
  # Rotate stale session state files (older than 7 days) to prevent accumulation
  find "$_hook_target/.claude" -maxdepth 1 \
    \( -name '.rsdd-session-*' -o -name '.rsdd-retro-blocked-*' \) \
    -mtime +7 -delete 2>/dev/null || true
fi
unset _hook_stdin _session_id _sha _hook_target

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
   (Kit: <KIT>/toolbelt/ — resolve <KIT> to your local Research-SDD kit root,
    e.g. $RESEARCH_HOME/sdd-investigacion/research-sdd or wherever you cloned it.)

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
