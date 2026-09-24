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

# Read session_id from SessionStart hook JSON stdin (§479 session-sha recording)
_hook_stdin=$(cat)
_session_id=$(printf '%s' "$_hook_stdin" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""

# Record session-start git sha for retro-gate.sh (hooks live two levels below target)
# Write only when missing/empty so that compact/clear/resume (all trigger SessionStart
# with matcher "") cannot overwrite the sha recorded at the true session start.
# Installed copies must be re-initialized from this template to pick up this fix.
#
# Very long sessions / reused session ids (documented, not silently assumed — see rotation
# below and #984):
#   - A single session running longer than the 7-day rotation window must not have ITS OWN
#     state files deleted out from under it mid-session — that would silently flip retro-gate
#     into degraded mode. The rotation below excludes this session's own files by name.
#   - If a session id were ever reused across two genuinely different sessions (this hook has
#     no way to detect that — it cannot distinguish "resuming the same session" from "a new
#     session that happens to reuse an old id"), write-once semantics keep the FIRST sha
#     recorded under that id, which would then be stale for the second, unrelated session.
#     This is an accepted tradeoff: fixing it would require extra state (e.g. a session-start
#     timestamp or a monotonically-increasing counter) to tell "resume" apart from "reuse",
#     which is out of scope here. Not currently known to happen in practice.
_hook_target="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -n "$_session_id" ]; then
  _rsdd_file="$_hook_target/.claude/.rsdd-session-${_session_id}"
  if [ ! -s "$_rsdd_file" ]; then
    _sha=$(git -C "$_hook_target" rev-parse HEAD 2>/dev/null) || _sha=""
    if [ -n "$_sha" ]; then
      mkdir -p "$_hook_target/.claude"
      printf '%s\n' "$_sha" > "$_rsdd_file"
    fi
  fi
  # Rotate stale session state files (older than 7 days) to prevent accumulation. Exclude THIS
  # session's own files by name: a session that has been running longer than 7 days must keep
  # its own session-start sha and block-once marker, or retro-gate.sh would silently fall back
  # to degraded (mtime) mode mid-session.
  find "$_hook_target/.claude" -maxdepth 1 \
    \( -name '.rsdd-session-*' -o -name '.rsdd-retro-blocked-*' \) \
    ! -name ".rsdd-session-${_session_id}" ! -name ".rsdd-retro-blocked-${_session_id}" \
    -mtime +7 -delete 2>/dev/null || true
  unset _rsdd_file _sha
fi
unset _hook_stdin _session_id _hook_target

# Probe for jq (§7 — could the instrument run at all?).
# Without jq the final JSON emission silently fails; emit a typed degraded line and a
# minimal valid hook JSON so the session is not broken.
if ! command -v jq >/dev/null 2>&1; then
  printf 'degraded: jq missing — install jq for full research-sdd context injection\n' >&2
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[degraded: jq missing — install jq for full research-sdd context]"}}'
  exit 0
fi

read -r -d '' CTX <<'EOF' || true
RESEARCH PROTOCOL — <SUBJECT> (Research-SDD)

Every session in this project is READ-ONLY research of <SUBJECT>. Before
answering a research question, work in this order:

1. FIRST search the project's own .md blocks (truth already distilled):
   - <prefix>-block*.md
   - INDEX.md  (map + Pending/gaps section)
   - CATALOG.md
   Review them before opening any tool.

2. Toolbelt tools (Research-SDD) — pick the wrapper for the artifact type from
   $RESEARCH_SDD_KIT/toolbelt/tool-registry.md (profile-target.sh classifies
   binaries and suggests one).

3. PRIMARY SOURCES of the subject (real paths — fill in per target):
   - <path to binaries/decompiled output/source code of the system under study>

4. PROVENANCE AND CERTAINTY (mandatory markers on every claim):
   [CERT-hw] live system/device (highest) · [CERT-live] live remote service · [CERT] local primary ·
   [CERT-doc] official document (sources/) · [CERT-web] official web · [CERT-a] forum/secondary ·
   [INFER] deduction. No citation ⇒ [INFER] or omit.

5. EXTERNAL EVIDENCE: if you find a relevant datasheet/manual/forum/link, DOWNLOAD it with
   fetch-doc.sh (lands in sources/ + registered in SOURCES.md) and cite the local file.

ACTION AT START: review the project's .md blocks first, then choose the toolbelt
tool(s) yourself from the artifact type and say in one line which you chose.
Inside a /research-sdd loop, continue the loop; do not stop to ask.
EOF

jq -n --arg ctx "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
