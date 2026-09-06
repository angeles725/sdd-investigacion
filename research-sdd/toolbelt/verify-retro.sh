#!/usr/bin/env bash
# verify-retro.sh — single-retro §18 conformance checker (U17 / #479 — PR 1 of 2)
#
# Usage: verify-retro.sh <retro.md>
# Exit:  0 = conforming, 1 = conformance FAIL (one finding line per defect), 2 = bad args
#
# Conformance checks (all run; all defects reported before exit):
#   (a) review-status marker: leading HTML-comment block must carry
#       <!-- review-status: pending|applied|dismissed --> OR <!-- kit-retro: exclude -->
#       (the latter only when no review-status is present → declared non-kit retro, skipped).
#   (b) delta section (four §7 classes):
#       absent-section      — no canonical heading AND no §18 honesty line
#       unrecognised-heading — a delta-intent heading outside the grammar (fails even with rows)
#       empty-section       — recognised heading but zero data rows AND no §18 honesty line
#       (conforming)        — recognised heading + ≥1 data row, OR §18 honesty line
#   (c) header line: file contains a '# Retro —' title.
#
# §7 anti-silent-zero: absent-input (file not found/unreadable) is reported as exit 2
# and is DISTINCT from conformance failures (exit 1).
#
# No || true after file-reading grep — we use `if grep ...; then ...; fi` forms so that
# grep exit 2 (I/O error) is not silently collapsed into "no match". The file is verified
# readable before any grep, making exit 2 extremely unlikely, but never silently ignored.
#
# Delta-heading grammar lives in lib/retro-grammar.sh (shared with sweep-retros.sh).

_usage() {
  printf 'Usage: %s <retro.md>\n' "$(basename "$0")" >&2
  printf '  exit 0 = conforming, exit 1 = non-conforming, exit 2 = bad args\n' >&2
}

# ── Shared delta-heading grammar lib ─────────────────────────────────────────
# lib/retro-grammar.sh is the single source of truth for canonical/deprecated heading
# recognition, table-row counting, and unrecognised-heading detection (Rules 1–3).
# Sourced here so verify-retro.sh and sweep-retros.sh share identical grammar.
_vr_rg_lib="$(cd "$(dirname "$0")" && pwd)/lib/retro-grammar.sh"
if [ ! -f "$_vr_rg_lib" ]; then
  printf 'verify-retro: cannot find helper %s\n' "$_vr_rg_lib" >&2
  exit 2
fi
# shellcheck source=lib/retro-grammar.sh
. "$_vr_rg_lib"
# Fail closed: existence is not enough — the source must have DEFINED the function.
declare -F retro_grammar_delta_info >/dev/null 2>&1 || \
  { printf 'verify-retro: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info\n' >&2; exit 2; }
unset _vr_rg_lib

# ── Argument validation ───────────────────────────────────────────────────────
if [ $# -ne 1 ]; then
  _usage
  exit 2
fi
f="$1"

# §7: absent-input (file not found) is distinct from conformance failures
if [ ! -f "$f" ]; then
  printf 'ERROR: file not found (absent-input): %s\n' "$f" >&2
  exit 2
fi
case "$f" in
  *.md) ;;
  *) printf 'ERROR: argument must be a .md file: %s\n' "$f" >&2; exit 2 ;;
esac
if [ ! -r "$f" ]; then
  printf 'ERROR: file not readable (absent-input): %s\n' "$f" >&2
  exit 2
fi

# ── Extract leading HTML-comment block (shared logic with lib/retro-status.sh) ─
# Prints all consecutive lines that open an HTML comment, skipping blank lines,
# stopping at the first non-comment, non-blank line. Same algorithm as retro_review_status().
_leading=$(awk '
  /^[[:space:]]*<!--/ { print; next }
  /^[[:space:]]*$/    { next }
  { exit }
' "$f" 2>/dev/null)

# ── (a) review-status marker check ───────────────────────────────────────────
# Operates on the captured string, not a direct file re-read.
_status=$(printf '%s\n' "$_leading" \
  | grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-zA-Z]+' \
  | head -1 \
  | sed -E 's/.*:[[:space:]]*//' \
  | tr 'A-Z' 'a-z') || _status=""

_failures=0

# SENTINEL-MARKER-CHECK-START
case "$_status" in
  pending|applied|dismissed)
    : # valid marker — run all remaining checks on this retro
    ;;
  "")
    # No review-status found — check for kit-retro: exclude opt-out
    _excluded=0
    if printf '%s\n' "$_leading" | grep -qiE '^[[:space:]]*<!--[[:space:]]*kit-retro:[[:space:]]*exclude[[:space:]]*-->'; then
      _excluded=1
    fi
    if [ "$_excluded" -eq 1 ]; then
      printf 'OK: kit-retro: exclude — declared non-kit retro, conforming/skipped\n'
      exit 0
    fi
    printf 'FAIL [marker-missing]: no review-status marker found in leading comment block\n'
    printf '  fix: add at the very top of the file:\n'
    printf '       <!-- review-status: pending -->\n'
    _failures=$(( _failures + 1 ))
    ;;
  *)
    printf 'FAIL [marker-missing]: unrecognised review-status "%s" (expected: pending | applied | dismissed)\n' "$_status"
    printf '  fix: change to:\n'
    printf '       <!-- review-status: pending -->\n'
    _failures=$(( _failures + 1 ))
    ;;
esac
# SENTINEL-MARKER-CHECK-END

# ── (c) header line check ─────────────────────────────────────────────────────
# SENTINEL-HEADER-CHECK-START
_has_title=0
if grep -qE '^# Retro —' "$f"; then
  _has_title=1
fi
# SENTINEL-HEADER-CHECK-END
if [ "$_has_title" -eq 0 ]; then
  printf 'FAIL [header-missing]: no "# Retro —" title line found\n'
  printf '  fix: add as the first heading:\n'
  printf '       # Retro — <TARGET> · <FOCUS> · <DATE> · Research-SDD self-retrospective\n'
  _failures=$(( _failures + 1 ))
fi

# ── (b) delta section check (§7 four-class) ───────────────────────────────────
# SENTINEL-DELTA-CHECK-START
#
# Grammar sourced from lib/retro-grammar.sh (shared with sweep-retros.sh).
# Output format: <found>:<form>:<count>\001<depr_h>\001<unrec_found>\001<unrec_data>\001<unrec_heading>
_delta_info=$(retro_grammar_delta_info "$f")
# SENTINEL-DELTA-CHECK-END

# Parse lib output (\001-separated fields; first field is colon-separated <found>:<form>:<count>).
_vr_first="${_delta_info%%$'\001'*}"                # "<found>:<form>:<count>"
_cf="${_vr_first%%:*}"                              # canon_found (0|1)
_vr_rest_first="${_vr_first#*:}"
_vr_form="${_vr_rest_first%%:*}"                    # form (1|2|3|w|n)
_vr_count="${_vr_rest_first##*:}"                   # count for the active form
_vr_rest="${_delta_info#*$'\001'}"                  # after first \001
_vr_depr_h="${_vr_rest%%$'\001'*}"                  # depr_h text (empty if none)
_dp=0; [ -n "$_vr_depr_h" ] && _dp=1              # deprecated boolean
_vr_rest="${_vr_rest#*$'\001'}"                     # after second \001
_uf="${_vr_rest%%$'\001'*}"                         # unrec_found (0|1)
_vr_rest="${_vr_rest#*$'\001'}"
_ud="${_vr_rest%%$'\001'*}"                         # unrec_data
_uh="${_vr_rest#*$'\001'}"                          # unrec_heading (may contain spaces)
# _cd: canonical table data rows — only form-1 (table rows) is conforming for verify-retro.
# Form-2 (### entries) and form-w (no countable rows) both map to _cd=0 so the
# empty-section check triggers correctly (identical to the prior standalone awk behaviour).
case "$_vr_form" in
  1) _cd="$_vr_count" ;;
  *) _cd=0 ;;
esac
unset _vr_first _vr_rest_first _vr_form _vr_count _vr_rest _vr_depr_h

# Check for §18 honesty line (anywhere in the file).
# File is already verified readable above, so grep exit 2 should not occur.
# SENTINEL-HONESTY-CHECK-START
_has_honesty=0
if grep -qi "no new deltas.*the kit already covers this run" "$f"; then
  _has_honesty=1
fi
# SENTINEL-HONESTY-CHECK-END

# Delta section verdict
if [ "$_cf" -eq 1 ]; then
  # Canonical (or deprecated) heading found
  if [ "$_dp" -eq 1 ]; then
    printf 'WARN [deprecated-heading]: deprecated delta heading — migrate to "## Proposed kit deltas" per §18\n'
  fi
  if [ "$_cd" -eq 0 ] && [ "$_has_honesty" -eq 0 ]; then
    # empty-section: recognised heading, zero data rows, no §18 honesty line
    printf 'FAIL [empty-section]: delta heading present but zero table rows and no §18 honesty line\n'
    printf '  fix: add at least one data row to the delta table:\n'
    printf '       | 1 | <change> | <target file · §/section> | <evidence> | <type> | <priority> |\n'
    printf '  or state the §18 honesty clause under ## Honest verdict:\n'
    printf '       no new deltas; the kit already covers this run.\n'
    _failures=$(( _failures + 1 ))
  fi
elif [ "$_uf" -eq 1 ]; then
  # Unrecognised delta-intent heading (outside the grammar → always fails, rows or not)
  # SENTINEL-UNREC-FAIL-START
  printf 'FAIL [unrecognised-heading]: delta section uses unrecognised heading: %s\n' "$_uh"
  printf '  fix: rename the heading to the canonical form:\n'
  printf '       ## Proposed kit deltas\n'
  _failures=$(( _failures + 1 ))
  # SENTINEL-UNREC-FAIL-END
  # Also flag zero-rows when the unrecognised section has no rows (doubly non-conforming)
  if [ "$_ud" -eq 0 ] && [ "$_has_honesty" -eq 0 ]; then
    printf 'FAIL [zero-rows]: unrecognised delta section also has zero table rows\n'
    printf '  fix: rename the heading AND add a canonical table:\n'
    printf '       ## Proposed kit deltas\n'
    printf '       | # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |\n'
    printf '       |---|---|---|---|---|---|\n'
    printf '       | 1 | <change> | <target> | <evidence> | <type> | <priority> |\n'
    _failures=$(( _failures + 1 ))
  fi
elif [ "$_has_honesty" -eq 1 ]; then
  : # §18 honesty line present and no canonical/unrecognised heading → conforming
else
  # absent-section: no canonical heading, no unrecognised-delta heading, no honesty line
  printf 'FAIL [absent-section]: no delta section — no canonical "## Proposed kit deltas" heading and no §18 honesty line\n'
  printf '  fix: add a delta section with a table under a canonical heading:\n'
  printf '       ## Proposed kit deltas\n'
  printf '       | # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |\n'
  printf '       |---|---|---|---|---|---|\n'
  printf '       | 1 | <change> | <target> | <evidence> | <type> | <priority> |\n'
  printf '  or state the §18 honesty clause under ## Honest verdict:\n'
  printf '       no new deltas; the kit already covers this run.\n'
  _failures=$(( _failures + 1 ))
fi

# ── Final verdict ─────────────────────────────────────────────────────────────
if [ "$_failures" -eq 0 ]; then
  printf 'OK: conforming\n'
  exit 0
else
  exit 1
fi
