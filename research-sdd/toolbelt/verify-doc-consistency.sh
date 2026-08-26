#!/usr/bin/env bash
# verify-doc-consistency.sh — guards kit entry-point docs against discoverability drift.
#
# WHY: METHODOLOGY.md grows new sections faster than SKILL.md and PROMPT-LOOP.md are
# updated. Three channels of silent drift have been observed:
#   1. The "N sections" count in SKILL.md falls behind the real section count in METHODOLOGY.
#   2. A new section gets no §N reference in SKILL.md or PROMPT-LOOP.md (orphan section).
#   3. SKILL.md cites a retros/ path that resolves under neither the kit root nor the
#      repo root. (Some retros live at the repo root rather than under the kit sub-tree;
#      either location counts as resolved — WARN only when the path is missing in both.)
#
# PROPOSE-NEVER-APPLY: WARN-only, READ-ONLY. Findings are advisory — exit 0.
# Operational failures (missing/unreadable required files) exit 1.
#
# Usage: verify-doc-consistency.sh
# Exit: 0 on clean or advisory findings; 1 on operational failure (missing required doc).
# Env:
#   RSDD_METHODOLOGY  path to METHODOLOGY.md (default: $KIT/METHODOLOGY.md)
#   RSDD_SKILL        path to SKILL.md      (default: $KIT/skills/research-sdd/SKILL.md)
#   RSDD_PROMPTLOOP   path to PROMPT-LOOP.md (default: $KIT/PROMPT-LOOP.md)
#   RSDD_KIT          kit root for resolving retros/ citations (default: $KIT)
#   RSDD_REPO         repo root for resolving retros/ citations (default: parent of $KIT)
set -uo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve defaults relative to the script's own KIT directory so cwd never matters.
RSDD_METHODOLOGY="${RSDD_METHODOLOGY:-$KIT/METHODOLOGY.md}"
RSDD_SKILL="${RSDD_SKILL:-$KIT/skills/research-sdd/SKILL.md}"
RSDD_PROMPTLOOP="${RSDD_PROMPTLOOP:-$KIT/PROMPT-LOOP.md}"

# Citation resolution roots: retros/ citations in SKILL.md are checked against BOTH.
# Some retros live at the repo root (parent of KIT) rather than under the kit sub-tree;
# either location is valid. WARN only when the path is absent in both roots.
# Override in tests via RSDD_KIT / RSDD_REPO to point at fixture directories.
_cit_kit="${RSDD_KIT:-$KIT}"
_cit_repo="${RSDD_REPO:-$(cd "$KIT/.." && pwd)}"

# --- Operational guards -------------------------------------------------------
# Missing OR UNREADABLE METHODOLOGY/SKILL is an operational failure (cannot proceed).
# The readability check is essential: an exists-but-unreadable file would let grep
# exit 2 and yield real_count=0, producing spurious stale/orphan findings instead of
# a clean operational failure — a silent-zero edge inside the anti-silent-zero guard.
# Missing PROMPT-LOOP is a degraded-mode WARN (orphan check still runs on SKILL only).
if [ ! -f "$RSDD_METHODOLOGY" ] || [ ! -r "$RSDD_METHODOLOGY" ]; then
  echo "verify-doc-consistency: cannot find or read METHODOLOGY at $RSDD_METHODOLOGY" >&2
  exit 1
fi
if [ ! -f "$RSDD_SKILL" ] || [ ! -r "$RSDD_SKILL" ]; then
  echo "verify-doc-consistency: cannot find or read SKILL at $RSDD_SKILL" >&2
  exit 1
fi

# Finding counters — advisory, never affect the exit code.
stale_count=0
orphan_count=0
broken_cite_count=0

# =============================================================================
# CHECK 1 — anti-stale-count
# Compute the REAL number of top-level numbered sections in METHODOLOGY.md.
# Pattern: ^## N. (N = one or more decimal digits). Matches "## 22." but NOT
# sub-sections ("### 12b.") and NOT lettered variants ("## 3b.").
# NEVER hardcoded — always recomputed live from the file.
# =============================================================================

# grep -E exits 1 on no-match; wc -l absorbs that and always exits 0.
# With pipefail the pipeline fails on grep exit 1 (no match), but the assignment
# still captures "0" from wc. Without -e this does not abort the script.
real_count=$(grep -E '^## [0-9]+\.' "$RSDD_METHODOLOGY" | wc -l | tr -d ' ')  # SECTION-COUNT-GREP

# Extract the integer N from SKILL.md's "N sections" declaration.
declared_line=$(grep -E '[0-9]+[[:space:]]+sections' "$RSDD_SKILL" 2>/dev/null | head -1)
if [ -z "$declared_line" ]; then
  echo "WARN  SKILL.md declares no section count — expected a phrase like 'Do NOT ingest all N sections'; add it so the count stays in sync with METHODOLOGY.md."
  stale_count=$((stale_count + 1))
else
  declared_count=$(printf '%s' "$declared_line" | grep -oE '[0-9]+[[:space:]]+sections' | grep -oE '^[0-9]+' | head -1)
  if [ -z "$declared_count" ]; then
    echo "WARN  SKILL.md has a 'sections' phrase but no parseable integer before it — check the phrasing."
    stale_count=$((stale_count + 1))
  elif [ "$declared_count" != "$real_count" ]; then
    echo "WARN  Section count mismatch: SKILL.md declares ${declared_count} sections but METHODOLOGY.md has ${real_count} top-level ## N. sections — update the declared count in SKILL.md."
    stale_count=$((stale_count + 1))
  fi
fi

# =============================================================================
# CHECK 2 — no orphan section
# Every section number 1..real_count must be referenced as §N in SKILL.md or
# PROMPT-LOOP.md. The pattern §N([^0-9]|$) ensures §1 does not satisfy §12's check.
# =============================================================================

# Build the file list for §N reference search.
_check_files=("$RSDD_SKILL")
if [ -f "$RSDD_PROMPTLOOP" ]; then
  _check_files+=("$RSDD_PROMPTLOOP")
else
  echo "WARN  PROMPT-LOOP.md not found at $RSDD_PROMPTLOOP — orphan-section check uses SKILL.md only."
fi

n=1
while [ "$n" -le "$real_count" ]; do
  # §N followed by a non-digit or end-of-line. Prevents §1 from matching inside §12.
  if ! grep -qE "§${n}([^0-9]|$)" "${_check_files[@]}"; then
    echo "WARN  §${n} is a top-level METHODOLOGY section but is not referenced in SKILL.md or PROMPT-LOOP.md — add a §${n} reference so it remains discoverable."
    orphan_count=$((orphan_count + 1))
  fi
  n=$((n + 1))
done

# =============================================================================
# CHECK 3 — citations resolve
# In SKILL.md, find every retros/<...>.md citation. For each, verify it exists
# relative to the kit root (_cit_kit) OR the repo root (_cit_repo). WARN only when
# the path is absent in BOTH roots.
# Scope: retros/*.md citations only. Other relative tokens are out of scope to avoid
# false positives per §7 — a loose checker would fire on truncated doc snippets.
# =============================================================================

while IFS= read -r cite; do
  [ -n "$cite" ] || continue
  kit_target="${_cit_kit}/${cite}"
  repo_target="${_cit_repo}/${cite}"
  if [ ! -f "$kit_target" ] && [ ! -f "$repo_target" ]; then
    echo "WARN  SKILL.md cites '${cite}' but it does not exist at ${kit_target} or ${repo_target} — verify the file path or update the citation (propose-never-apply; never auto-edited)."
    broken_cite_count=$((broken_cite_count + 1))
  fi
done < <(grep -oE 'retros/[^)[:space:]]+\.md' "$RSDD_SKILL" 2>/dev/null | sort -u)

# =============================================================================
# Summary — anti-silent-zero (§7): always print what was checked and how many
# findings so a zero count is never ambiguous (absent/empty/no-match are distinct).
# Printing real_count proves the instrument actually traversed METHODOLOGY.md.
# =============================================================================
echo ""
echo "Summary: checked METHODOLOGY.md (${real_count} top-level ## N. sections) · SKILL.md · PROMPT-LOOP.md"
echo "  Findings: ${stale_count} stale-count · ${orphan_count} orphan section(s) · ${broken_cite_count} broken citation(s)"
if [ "$stale_count" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$broken_cite_count" -eq 0 ]; then
  echo "Doc consistency: clean."
else
  echo "Doc consistency: ${stale_count} stale-count finding(s); ${orphan_count} orphan section(s); ${broken_cite_count} broken citation(s) — see WARNs above (propose-never-apply; never auto-edited)."
fi

# Advisory findings never affect the exit code. Operational failures already exited 1 above.
exit 0
