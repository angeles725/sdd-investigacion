#!/usr/bin/env bash
# stage-retro-issues.sh — propose (or create with --apply) GitHub issues for OPEN
# kit deltas in ONE §18 retro file (issue #792; backlog-first rollout #557).
#
# An OPEN delta is one whose review-status is pending/none/absent, OR whose retro
# carries a PARTIAL applied marker and the row's ID is NOT in the shipped set.
# Shipped/applied/dismissed rows are skipped. propose-never-apply is the DEFAULT.
#
# Usage: stage-retro-issues.sh <retro.md> [--apply]
#   Default:  dry-run — print planned issues (title, labels, body) to stdout.
#   --apply:  run `gh issue create` for each open delta, with dedup check.
#
# Anti-silent-zero: three states are distinguished and named:
#   absent-input   retro file not found
#   empty-input    retro found but has no delta section
#   no-match       delta section found; all rows shipped/applied
#
# §7 degraded probe: if --apply and `gh` is absent or not authenticated,
# emit a typed `degraded:` line to stderr and exit non-zero.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
retro="${1:-}"
apply=0
for _a in "$@"; do [ "$_a" = "--apply" ] && apply=1; done

# ---------------------------------------------------------------------------
# Runtime dependency probes
_missing=""
for _dep in awk grep sed; do
  command -v "$_dep" >/dev/null 2>&1 || _missing="$_missing $_dep"
done
if [ $apply -eq 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "degraded: gh not found on PATH — install gh CLI before using --apply" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "degraded: gh is not authenticated — run 'gh auth login' before using --apply" >&2
    exit 1
  fi
fi
if [ -n "$_missing" ]; then
  echo "degraded: missing runtime dependencies:$_missing" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate retro path (absent-input)
if [ -z "$retro" ] || [ ! -f "$retro" ]; then
  echo "absent-input: retro not found: ${retro:-<no path given>}" >&2
  exit 1
fi
retro="$(cd "$(dirname "$retro")" && pwd)/$(basename "$retro")"

# ---------------------------------------------------------------------------
# Kit layout — KIT_ROOT is two dirs up from toolbelt/ (the script's own dir)
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
TARGETS_MD="$KIT_ROOT/research-sdd/TARGETS.md"

# ---------------------------------------------------------------------------
# Source shared helpers (fail-closed)
_RS_LIB="$_SCRIPT_DIR/lib/retro-status.sh"
if [ ! -f "$_RS_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_RS_LIB" >&2; exit 1
fi
# shellcheck source=lib/retro-status.sh
. "$_RS_LIB"
declare -F retro_review_status >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_review_status" >&2; exit 1; }

_RG_LIB="$_SCRIPT_DIR/lib/retro-grammar.sh"
if [ ! -f "$_RG_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_RG_LIB" >&2; exit 1
fi
# shellcheck source=lib/retro-grammar.sh
. "$_RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info" >&2; exit 1; }

_TP_LIB="$_SCRIPT_DIR/lib/target-paths.sh"
if [ ! -f "$_TP_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_TP_LIB" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$_TP_LIB"
declare -F target_paths_all >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/target-paths.sh failed to define target_paths_all" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Derive target name from the retro's directory hierarchy
# Retro is at <target_dir>/retros/<file>; target_dir = dirname(dirname(retro))
_retro_dir="$(dirname "$retro")"
_target_dir="$(cd "$(dirname "$_retro_dir")" && pwd)"
target_name=""

if [ -f "$TARGETS_MD" ]; then
  while IFS= read -r _path; do
    _exp="$(cd "$_path" 2>/dev/null && pwd)" || continue
    if [ "$_exp" = "$_target_dir" ]; then
      target_name="$(basename "$_path")"
      break
    fi
  done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)
fi

if [ -z "$target_name" ]; then
  target_name="$(basename "$_target_dir")"
  echo "WARN: target directory '$_target_dir' not found in $TARGETS_MD — using basename '$target_name'" >&2
fi

# ---------------------------------------------------------------------------
# Parse review-status and detect PARTIAL applied markers
status="$(retro_review_status "$retro")"

# Read the full leading HTML-comment block to detect PARTIAL and shipped IDs.
# Format: <!-- review-status: applied · sha · PARTIAL — shipped: 1, 2; deferred: 3 -->
_marker_line="$(awk '
  /^[[:space:]]*<!--/ { print; next }
  /^[[:space:]]*$/     { next }
  { exit }
' "$retro" 2>/dev/null \
  | grep -iE '<!--[[:space:]]*review-status:' \
  | head -1)"

is_partial=0
shipped_ids=""
if printf '%s' "$_marker_line" | grep -qiE 'PARTIAL|shipped:'; then
  is_partial=1
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

# ---------------------------------------------------------------------------
# Early exit for fully applied/dismissed with no PARTIAL marker (no-match)
# STAGE_RETRO_ISSUES_NOMATCH_GUARD: this single compound statement is the anchor
# for the T1 teeth proof — removing it causes rows to be emitted for applied retros.
case "$status" in
  applied|dismissed)
    [ $is_partial -eq 0 ] && { echo "no-match: retro is '$status' — all rows shipped" >&2; exit 0; }
    ;;
  pending|none|"")
    : ;;  # All rows open
  *)
    echo "WARN: unrecognised review-status '$status' — treating all rows as open" >&2 ;;
esac

# ---------------------------------------------------------------------------
# Check for a delta section (empty-input)
_grammar_info="$(retro_grammar_delta_info "$retro")"
_found_field="$(printf '%s' "$_grammar_info" | cut -d '' -f1 | cut -d: -f1)"
if [ "$_found_field" != "1" ]; then
  echo "empty-input: no delta section found in $retro" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse delta rows from the canonical/deprecated section
retro_file="$retro"
retro_basename="$(basename "$retro")"

_rows="$(awk '
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
      printf "%s\037%s\037%s\037%s\037%s\037%s\n",
        (n>=1 ? f[1] : ""), (n>=2 ? f[2] : ""), (n>=3 ? f[3] : ""),
        (n>=4 ? f[4] : ""), (n>=5 ? f[5] : ""), (n>=6 ? f[6] : "")
    }
  }
' "$retro_file")"

if [ -z "$_rows" ]; then
  echo "empty-input: delta section found but contains no data rows in $retro" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers

# is_shipped <row_id>: true when ID is in the shipped set of a PARTIAL marker
is_shipped() {
  [ $is_partial -eq 1 ] || return 1
  printf '%s\n' "$shipped_ids" | grep -qxF "$1"
}

# map_type <type_cell>: prints "feature" | "bug" | "docs"
map_type() {
  local t
  t="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  case "$t" in
    doc|docs|documentation|doc-fix|docfix) printf 'docs' ;;
    bug|fix|bugfix|defect|regression)      printf 'bug'  ;;
    *)                                      printf 'feature' ;;
  esac
}

# map_priority <priority_cell>: prints "high"|"medium"|"low" or "" to omit
map_priority() {
  local p
  p="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  case "$p" in
    high)   printf 'high'   ;;
    medium) printf 'medium' ;;
    low)    printf 'low'    ;;
    *)      printf ''       ;;
  esac
}

# is_wrong_kit <target_cell>: true if the cell names another kit
# STAGE_RETRO_ISSUES_WRONGKIT_GUARD: this is the anchor for T2 teeth proof.
is_wrong_kit() {
  printf '%s' "$1" | grep -qiE '[-a-zA-Z0-9]+-kit[:/]'
}

# strip_md_bold: removes leading/trailing ** bold markers
strip_md_bold() {
  printf '%s' "$1" | sed -E 's/^\*\*//;s/\*\*$//'
}

# ---------------------------------------------------------------------------
# Main loop
open_count=0; skipped_shipped=0; skipped_wrong_kit=0
skipped_dedup=0; created=0

while IFS=$'\037' read -r _rid _delta _target_cell _evidence _type_cell _priority_cell; do
  _rid="$(printf '%s' "$_rid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _delta="$(printf '%s' "$_delta" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _target_cell="$(printf '%s' "$_target_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _evidence="$(printf '%s' "$_evidence" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _type_cell="$(printf '%s' "$_type_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _priority_cell="$(printf '%s' "$_priority_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$_rid" ] && continue

  # Skip shipped rows for PARTIAL applied retros; all rows open otherwise.
  # (Fully applied/dismissed without PARTIAL already exited above.)
  if [ $is_partial -eq 1 ] && is_shipped "$_rid"; then
    skipped_shipped=$((skipped_shipped+1)); continue
  fi

  # Wrong-kit check: skip rows targeting a different kit
  if is_wrong_kit "$_target_cell"; then
    echo "skipped-wrong-kit: row $_rid targets another kit ('$_target_cell') — skipping" >&2
    skipped_wrong_kit=$((skipped_wrong_kit+1)); continue
  fi

  open_count=$((open_count+1))

  # Build issue fields
  _title="$(strip_md_bold "$_delta")"
  if [ "${#_title}" -gt 120 ]; then _title="${_title:0:117}..."; fi

  _type_label="$(map_type "$_type_cell")"
  _priority_label="$(map_priority "$_priority_cell")"

  _source_line="Source retro: ${target_name}/retros/${retro_basename} · ${_rid}"
  _rollout_line="Part of backlog-first rollout #557"

  _body="$(printf '%s\n\n**Target:** %s\n**Evidence:** %s\n\n---\n%s\n%s' \
    "$_delta" "$_target_cell" "$_evidence" "$_source_line" "$_rollout_line")"

  _labels="status:needs-review,target:${target_name},type:${_type_label}"
  if [ -n "$_priority_label" ]; then _labels="${_labels},priority:${_priority_label}"; fi

  if [ $apply -eq 0 ]; then
    printf 'planned-issue: %s\n' "$_title"
    printf '  labels: %s\n' "$_labels"
    printf '  body:\n'
    printf '%s\n' "$_body" | sed 's/^/    /'
    printf '\n'
  else
    # Dedup: search for an existing open issue with the exact source signature
    _search_sig="${_source_line}"
    _existing="$(gh issue list --state open \
      --search "\"$_search_sig\"" 2>/dev/null || true)"
    # STAGE_RETRO_ISSUES_DEDUP_CHECK: anchor for T3 teeth proof — skip create when match found.
    if [ -n "$_existing" ]; then
      echo "skipped-duplicate: issue for row $_rid already exists (search matched '$_search_sig')"
      skipped_dedup=$((skipped_dedup+1)); continue
    fi

    _label_flags=""
    IFS=',' read -ra _lbl_arr <<< "$_labels"
    for _lbl in "${_lbl_arr[@]}"; do
      _label_flags="$_label_flags --label $(printf '%s' "$_lbl" | sed "s/'/'\\\\''/g")"
    done

    # shellcheck disable=SC2086
    _url="$(gh issue create \
      --title "$_title" \
      $_label_flags \
      --body "$_body" 2>&1)" || {
        echo "ERROR: gh issue create failed for row $_rid: $_url" >&2; continue
      }
    echo "created: $_url (row $_rid)"
    created=$((created+1))
  fi
done <<< "$_rows"

# Summary and no-match detection when all rows were shipped
if [ "$open_count" -eq 0 ] && [ "$skipped_shipped" -gt 0 ] && [ "$skipped_wrong_kit" -eq 0 ]; then
  echo "no-match: delta section found but all rows are shipped (skipped: $skipped_shipped)" >&2
fi

if [ $apply -eq 1 ]; then
  printf 'summary: created=%d skipped-duplicate=%d skipped-shipped=%d skipped-wrong-kit=%d\n' \
    "$created" "$skipped_dedup" "$skipped_shipped" "$skipped_wrong_kit"
fi

exit 0
