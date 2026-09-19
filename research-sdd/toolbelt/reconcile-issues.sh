#!/usr/bin/env bash
# reconcile-issues.sh — audit GitHub issue coverage for OPEN kit deltas.
# Resolves issue #794 (Phase 3 of #557).
#
# For each OPEN delta in a §18 retro file, checks whether there is an open issue
# on angeles725/sdd-investigacion carrying the exact
#   "Source retro: <target>/retros/<file> · <row-id>"
# body signature produced by stage-retro-issues.sh.
#
# Usage:
#   reconcile-issues.sh <retro.md>  — audit one retro file
#   reconcile-issues.sh --all       — audit every retro across all TARGETS.md targets
#
# Classifies each OPEN delta as (printed to stdout):
#   tracked   — open delta HAS a matching open issue
#   untracked — open delta with NO matching issue  (actionable gap)
#   orphaned  — open issue whose delta row is no longer open
#
# propose-never-apply: REPORT ONLY.  No --apply flag; never creates, closes, or
# edits any issue or retro marker.
#
# Anti-silent-zero §7 — three states named per retro (to stderr):
#   absent-input  retro file / target dir not found
#   empty-input   found but contains no delta section
#   no-match      delta section present; no open deltas AND no orphaned issues
#
# §7 degraded probe: gh absent or unauthenticated → typed "degraded:" + exit 1.
# Findings (untracked, orphaned) are WARN-only and never fail the run.
# Operational failures (TARGETS.md missing, lib helper missing) exit 1.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
_mode="single"
retro=""
for _a in "$@"; do
  case "$_a" in
    --all) _mode="all" ;;
    --*) echo "reconcile-issues: unknown flag '$_a'" >&2; exit 1 ;;
    *)   retro="$_a" ;;
  esac
done

if [ "$_mode" = "single" ] && [ -z "$retro" ]; then
  echo "usage: reconcile-issues.sh <retro.md> | --all" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Runtime dependency probes
for _dep in awk grep sed; do
  command -v "$_dep" >/dev/null 2>&1 || {
    echo "degraded: missing runtime dependency: $_dep" >&2; exit 1
  }
done

# gh is always required — this instrument only operates against the GitHub API
if ! command -v gh >/dev/null 2>&1; then
  echo "degraded: gh not found on PATH — install gh CLI to use reconcile-issues" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "degraded: gh is not authenticated — run 'gh auth login'" >&2
  exit 1
fi

_REPO="angeles725/sdd-investigacion"

# ---------------------------------------------------------------------------
# Kit layout — KIT_ROOT is two dirs up from toolbelt/ (the script's own dir)
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
TARGETS_MD="$KIT_ROOT/research-sdd/TARGETS.md"

# ---------------------------------------------------------------------------
# Source shared helpers (fail-closed)
_RS_LIB="$_SCRIPT_DIR/lib/retro-status.sh"
[ -f "$_RS_LIB" ] || { echo "reconcile-issues: cannot find helper $_RS_LIB" >&2; exit 1; }
# shellcheck source=lib/retro-status.sh
. "$_RS_LIB"
declare -F retro_review_status >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_review_status" >&2; exit 1; }

_RG_LIB="$_SCRIPT_DIR/lib/retro-grammar.sh"
[ -f "$_RG_LIB" ] || { echo "reconcile-issues: cannot find helper $_RG_LIB" >&2; exit 1; }
# shellcheck source=lib/retro-grammar.sh
. "$_RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info" >&2; exit 1; }

_TP_LIB="$_SCRIPT_DIR/lib/target-paths.sh"
[ -f "$_TP_LIB" ] || { echo "reconcile-issues: cannot find helper $_TP_LIB" >&2; exit 1; }
# shellcheck source=lib/target-paths.sh
. "$_TP_LIB"
declare -F target_paths_all >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/target-paths.sh failed to define target_paths_all" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fleet accumulators (used under --all to build the final summary line)
_fleet_tracked=0
_fleet_untracked=0
_fleet_orphaned=0
_fleet_retros=0

# ---------------------------------------------------------------------------
# audit_retro <retro_path> <target_name>
#   Prints findings (tracked/untracked/orphaned) to stdout.
#   Prints advisory messages (empty-input, no-match, WARN) to stderr.
#   Returns 0 on all advisory findings; non-zero only on operational failure.
audit_retro() {
  local retro_path="$1" target_nm="$2"
  local retro_basename
  retro_basename="$(basename "$retro_path")"

  local r_tracked=0 r_untracked=0 r_orphaned=0

  # --- Parse review-status and PARTIAL marker (mirrors stage-retro-issues.sh logic)
  local _status
  _status="$(retro_review_status "$retro_path")"

  local _marker_line
  _marker_line="$(awk '
    /^[[:space:]]*<!--/ { print; next }
    /^[[:space:]]*$/     { next }
    { exit }
  ' "$retro_path" 2>/dev/null \
    | grep -iE '<!--[[:space:]]*review-status:' \
    | head -1)"

  local is_partial=0 shipped_ids=""
  if printf '%s' "$_marker_line" | grep -qiE 'PARTIAL|shipped:'; then
    is_partial=1
    local _shipped_raw
    _shipped_raw="$(printf '%s' "$_marker_line" \
      | grep -oiE 'shipped:[^;>]*' \
      | head -1 \
      | sed -E 's/^[Ss]hipped:[[:space:]]*//')"
    if [ -n "$_shipped_raw" ]; then
      shipped_ids="$(printf '%s' "$_shipped_raw" \
        | awk '{
            n = split($0, tokens, /[,[:space:]]+/)
            for (i=1; i<=n; i++) {
              t = tokens[i]
              if (t == "") continue
              if (match(t, /^([A-Za-z]*)([0-9]+)-([A-Za-z]*)([0-9]+)$/, m)) {
                pfx1=m[1]; n1=int(m[2]); pfx2=m[3]; n2=int(m[4])
                if (pfx1 == pfx2) {
                  for (j=n1; j<=n2; j++) printf "%s%d\n", pfx1, j
                } else { printf "%s\n", t }
              } else { printf "%s\n", t }
            }
          }')"
    fi
  fi

  # --- Check for a delta section (empty-input guard)
  local _grammar_info _found_field
  _grammar_info="$(retro_grammar_delta_info "$retro_path")"
  _found_field="$(printf '%s' "$_grammar_info" | cut -d '' -f1 | cut -d: -f1)"
  if [ "$_found_field" != "1" ]; then
    echo "empty-input: no delta section found in $retro_path" >&2
    return 0
  fi

  # --- Determine whether any rows can be open
  local _has_open_rows=1
  case "$_status" in
    applied|dismissed)
      [ "$is_partial" -eq 0 ] && _has_open_rows=0 ;;
    pending|none|"") ;;
    *)
      echo "WARN: unrecognised review-status '$_status' in $retro_basename — treating all rows as open" >&2 ;;
  esac

  # --- Parse all delta row-ids from the retro (same awk as stage-retro-issues.sh)
  local _all_row_ids
  _all_row_ids="$(awk '
    BEGIN { in_sec=0 }
    {
      low = tolower($0)
      if (low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/ ||
          low ~ /^## proposed delta/ ||
          low ~ /^## delta proposals/ ||
          low ~ /^## deltas nuevos/ ||
          low ~ /^## summary of proposed delta/ ||
          low ~ /^## summary of new deltas/ ||
          low ~ /^## delta details([[:space:]]|$)/) {
        in_sec = 1; next
      }
      if (/^##[^#]/) { in_sec = 0; next }
      if (in_sec && /^\|/ && $0 !~ /^\|[-: |]+\|?[[:space:]]*$/) {
        line = $0
        sub(/^\|[[:space:]]*/, "", line)
        sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
        n = split(line, f, /[[:space:]]*\|[[:space:]]*/)
        rid = f[1]; gsub(/[[:space:]]/, "", rid)
        if (rid ~ /^[-:]+$/) next
        if (rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/) next
        print rid
      }
    }
  ' "$retro_path")"

  if [ -z "$_all_row_ids" ]; then
    echo "empty-input: delta section found but contains no data rows in $retro_path" >&2
    return 0
  fi

  # --- Build _open_ids: row-ids that are currently open (not shipped)
  local _open_ids="" _rln
  if [ "$_has_open_rows" -eq 1 ]; then
    while IFS= read -r _rln; do
      [ -z "$_rln" ] && continue
      if [ "$is_partial" -eq 1 ]; then
        # Skip rows in the shipped set
        if printf '%s\n' "$shipped_ids" | grep -qxF "$_rln"; then
          continue
        fi
      fi
      if [ -z "$_open_ids" ]; then
        _open_ids="$_rln"
      else
        _open_ids="${_open_ids}
${_rln}"
      fi
    done <<< "$_all_row_ids"
  fi

  # --- Broad GitHub query: all open issues referencing this retro file
  # Returns text that may include Source retro: ... · <row-id> lines.
  local _sig_prefix="${target_nm}/retros/${retro_basename}"
  local _all_bodies=""
  if ! _all_bodies="$(gh issue list \
      --repo "$_REPO" \
      --state open \
      --search "\"Source retro: ${_sig_prefix} ·\"" \
      --template '{{range .}}{{.body}}{{"\n"}}{{end}}' 2>/dev/null)"; then
    echo "WARN: gh issue list failed for $retro_basename — output may be incomplete" >&2
    _all_bodies=""
  fi

  # Extract row-ids referenced in open issues for this retro
  local _issue_row_ids=""
  if [ -n "$_all_bodies" ]; then
    _issue_row_ids="$(printf '%s\n' "$_all_bodies" \
      | grep -oE 'Source retro: .+ · [A-Za-z0-9_-]+' \
      | sed -E 's/.* · //')"
  fi

  # --- Classify open deltas: tracked or untracked
  local _rid
  if [ -n "$_open_ids" ]; then
    while IFS= read -r _rid; do
      [ -z "$_rid" ] && continue
      # RECONCILE_ISSUES_TRACKED_CHECK: anchor for T1 teeth — condition detects tracked
      if printf '%s\n' "$_issue_row_ids" | grep -qxF "$_rid"; then
        printf 'tracked: row %s — open issue found in %s\n' "$_rid" "$retro_basename"
        r_tracked=$((r_tracked+1))
      else
        # RECONCILE_ISSUES_UNTRACKED_EMIT: anchor for T2 teeth — emit untracked when no issue
        printf 'untracked: row %s — no open issue found for this delta in %s\n' \
          "$_rid" "$retro_basename"
        r_untracked=$((r_untracked+1))
      fi
    done <<< "$_open_ids"
  fi

  # --- Detect orphaned: issue row-ids not present in the current open delta set
  local _irid
  if [ -n "$_issue_row_ids" ]; then
    while IFS= read -r _irid; do
      [ -z "$_irid" ] && continue
      # RECONCILE_ISSUES_ORPHANED_CHECK: anchor for T3 teeth — condition detects orphaned
      if ! printf '%s\n' "$_open_ids" | grep -qxF "$_irid"; then
        printf 'orphaned: issue for row %s is no longer open in %s\n' \
          "$_irid" "$retro_basename"
        r_orphaned=$((r_orphaned+1))
      fi
    done <<< "$_issue_row_ids"
  fi

  # --- no-match: nothing actionable found at all
  if [ "$r_tracked" -eq 0 ] && [ "$r_untracked" -eq 0 ] && [ "$r_orphaned" -eq 0 ]; then
    echo "no-match: no open deltas and no orphaned issues in $retro_basename" >&2
  fi

  # Accumulate fleet totals
  _fleet_tracked=$((_fleet_tracked + r_tracked))
  _fleet_untracked=$((_fleet_untracked + r_untracked))
  _fleet_orphaned=$((_fleet_orphaned + r_orphaned))
  _fleet_retros=$((_fleet_retros + 1))

  return 0
}

# ---------------------------------------------------------------------------
# Main dispatch

if [ "$_mode" = "single" ]; then
  # Validate the retro path (absent-input)
  if [ ! -f "$retro" ]; then
    echo "absent-input: retro not found: ${retro}" >&2
    exit 1
  fi
  retro="$(cd "$(dirname "$retro")" && pwd)/$(basename "$retro")"

  # Derive target name from path hierarchy: retro lives at <target>/retros/<file>
  _retro_dir="$(dirname "$retro")"
  _target_dir="$(cd "$(dirname "$_retro_dir")" && pwd)"
  _tgt_name=""

  if [ -f "$TARGETS_MD" ]; then
    while IFS= read -r _tgt_path; do
      _exp="$(cd "$_tgt_path" 2>/dev/null && pwd)" || continue
      if [ "$_exp" = "$_target_dir" ]; then
        _tgt_name="$(basename "$_tgt_path")"
        break
      fi
    done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)
  fi

  if [ -z "$_tgt_name" ]; then
    _tgt_name="$(basename "$_target_dir")"
    echo "WARN: target directory '$_target_dir' not found in $TARGETS_MD — using basename '$_tgt_name'" >&2
  fi

  audit_retro "$retro" "$_tgt_name"

elif [ "$_mode" = "all" ]; then
  if [ ! -f "$TARGETS_MD" ]; then
    echo "absent-input: TARGETS.md not found: $TARGETS_MD" >&2
    exit 1
  fi

  _found_any_retro=0

  while IFS= read -r _tgt_path; do
    [ -d "$_tgt_path" ] || continue
    _tgt_nm="$(basename "$_tgt_path")"
    _retros_dir="$_tgt_path/retros"

    if [ ! -d "$_retros_dir" ]; then
      echo "WARN: no retros/ directory for target '$_tgt_nm'" >&2
      continue
    fi

    _found_retros=0
    while IFS= read -r _rfile; do
      [ -f "$_rfile" ] || continue
      _found_retros=1
      _found_any_retro=1
      audit_retro "$_rfile" "$_tgt_nm"
    done < <(find "$_retros_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

    if [ "$_found_retros" -eq 0 ]; then
      echo "WARN: no retro files (*.md) found in '$_retros_dir'" >&2
    fi
  done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)

  if [ "$_found_any_retro" -eq 0 ]; then
    echo "empty-input: no retro files found across all targets" >&2
  fi

  printf 'fleet-summary: tracked=%d untracked=%d orphaned=%d retros=%d\n' \
    "$_fleet_tracked" "$_fleet_untracked" "$_fleet_orphaned" "$_fleet_retros"
fi

exit 0
