#!/usr/bin/env bash
# verify-tool-catalog.sh — drift guard: installed tools (INSTALLED-TOOLS.md) vs the capability
# catalog (tool-registry.md).
#
# WHY: install-tool.sh already auto-appends every install attempt to INSTALLED-TOOLS.md — the LOG
# half is automatic (Tool|How|Status|Target|Date|Notes). It does NOT write tool-registry.md, the
# CAPABILITY CATALOG half (artifact type / detection / tool / wrapper). Nothing enforced that a
# logged install ever got a capability row — this closes that gap: for each distinct tool NAME
# logged in INSTALLED-TOOLS.md, WARN if it has no matching entry anywhere in tool-registry.md
# (its "Tool" column or its "## Tool paths (verified)" table — both live in the same file).
#
# PROPOSE-NEVER-APPLY (CLAUDE.md §8): READ-ONLY. Never edits INSTALLED-TOOLS.md or tool-registry.md;
# the human catalogs the tool by hand. WARN-only on FINDINGS (a tool installed-but-not-cataloged
# never fails the run); exit 1 ONLY on an OPERATIONAL failure (either input file missing).
#
# ANTI-SILENT-ZERO (CLAUDE.md §7): three distinguishable states for "0 not-cataloged" —
#   absent-input  — INSTALLED-TOOLS.md or tool-registry.md not found (OPERATIONAL, exit 1)
#   empty-input   — INSTALLED-TOOLS.md found but its auto-log table has no data rows
#   no-match      — every distinct logged tool name is already cataloged (the clean case)
#
# Usage: verify-tool-catalog.sh
# Exit: 0 clean or advisory findings; 1 on operational failure.
set -uo pipefail

TB="$(cd "$(dirname "$0")" && pwd)"
INSTALLED_MD="$TB/INSTALLED-TOOLS.md"
REGISTRY_MD="$TB/tool-registry.md"

# --- Operational guards: both inputs are required to run this check at all (absent-input). --------
if [ ! -f "$INSTALLED_MD" ]; then
  echo "verify-tool-catalog: ERROR — cannot find $INSTALLED_MD (absent-input)" >&2
  exit 1  # OPERATIONAL-INSTALLED-MISSING
fi
if [ ! -f "$REGISTRY_MD" ]; then
  echo "verify-tool-catalog: ERROR — cannot find $REGISTRY_MD (absent-input)" >&2
  exit 1  # OPERATIONAL-REGISTRY-MISSING
fi

# --- Extract distinct tool names from BOTH logged forms in INSTALLED-TOOLS.md. -------------------
# Two forms coexist and both are logged tools this guard must cover (§7 report-only-what-you-measured
# — recognising one form silently under-reports the other, the exact false-negative that trap names):
#   Form 1 — the auto-log table install-tool.sh appends:   | <tool> | How | Status | ... |
#   Form 2 — older hand-written narrative sections:         ## <tool> (<desc>) — <date>
# Form 2 is what js-beautify and bkcrack use on the real fleet; it predates install-tool.sh's
# auto-append but the tools are installed just the same. Enumerated Form 2 = a level-2 heading whose
# first token is the tool name, followed by a parenthesised description.
# No '|| true': a real grep error (ENOMEM/SIGPIPE, exit 2) must not be swallowed into a confident
# empty read (CLAUDE.md §7).
table_rows="$(grep -E '^\|' "$INSTALLED_MD" | grep -vE '^\|[[:space:]]*[-:]+[[:space:]]*\|' | grep -viE '^\|[[:space:]]*Tool[[:space:]]*\|')"
section_names="$(grep -E '^## +[^ ]+ *\(' "$INSTALLED_MD" | awk '{print $2}')"

# Form 1: first cell of each pipe row is the Tool name. TOKENIZER-LAST-ROW-FIX: guard the read loop
# with `|| [ -n "$line" ]` so a final row surviving without a trailing newline is not silently
# dropped — the exact "last row/last field never checked" defect this kit's doctrine names.
names=""
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  name="$(printf '%s' "$line" | awk -F'|' '{print $2}')"
  # Trim surrounding whitespace.
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  [ -n "$name" ] || continue
  names="${names}${name}"$'\n'
done <<< "$table_rows"
# Form 2: section names are already whitespace-clean (awk field) — append so both forms enter the check.
[ -n "$section_names" ] && names="${names}${section_names}"$'\n'

# ANTI-SILENT-ZERO: empty-input (no tool in EITHER form) is distinct from a real 0-tool sweep — the
# file exists but carries no logged tool yet (a freshly-scaffolded kit / never ran install-tool.sh).
if [ -z "$names" ]; then
  echo "verify-tool-catalog: INSTALLED-TOOLS.md has no tool log rows (empty-input) — nothing to reconcile."
  exit 0  # EMPTY-INPUT
fi

# Dedup, preserving first-seen order — the same tool is often logged multiple times with different
# statuses (e.g. blutter: installed, then a later incompatible precheck row for a new target).
unique_names="$(printf '%s' "$names" | awk '!seen[$0]++')"

total=0; cataloged=0; missing=0
missing_list=""
while IFS= read -r tool || [ -n "$tool" ]; do
  [ -n "$tool" ] || continue
  total=$((total + 1))
  # Case-insensitive, whole-word, fixed-string match anywhere in tool-registry.md — covers both
  # the capability table's "Tool" column and the "## Tool paths (verified)" table, since both live
  # in the same file. Case-insensitive (-i) reconciles tools whose install-tool.sh LOGGED name uses
  # lowercase while the catalog display name uses Title or upper case (e.g. 'vineflower' / 'Vineflower',
  # 'cfr' / 'CFR', 'procyon' / 'Procyon'). Name-divergent tools (where the logged name differs from
  # the display name entirely, e.g. 'kaitai-struct-compiler' logged vs 'ksc' displayed) MUST carry
  # the logged name as an alias token in the catalog row so the whole-word match finds it
  # (e.g. append "(alias: kaitai-struct-compiler)" to the row's Tool cell — see tool-registry.md).
  if grep -qiwF -- "$tool" "$REGISTRY_MD"; then
    cataloged=$((cataloged + 1))
  else
    missing=$((missing + 1))
    missing_list="${missing_list:+$missing_list, }$tool"
    echo "WARN  installed-but-not-cataloged: '${tool}' is logged in INSTALLED-TOOLS.md but has no entry in tool-registry.md — add a capability row (Artifact type / Tool / Wrapper, or the '(direct)' pattern for a manual tool) and, if it has a resolvable binary, a row in \"## Tool paths (verified)\" (propose-never-apply; never auto-edited)."
  fi
done <<< "$unique_names"

echo ""
echo "Summary: ${total} distinct tool(s) logged in INSTALLED-TOOLS.md · ${cataloged} cataloged · ${missing} not cataloged."
if [ "$missing" -eq 0 ]; then
  echo "Tool catalog consistent with INSTALLED-TOOLS.md (no-match: every logged tool is cataloged)."
else
  echo "Catalog gap(s) — not cataloged: ${missing_list}"
fi

# Advisory findings (installed-but-not-cataloged) are never failures. Operational failure already
# exited 1 above.
exit 0
