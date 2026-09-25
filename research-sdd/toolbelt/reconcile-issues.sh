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
# Anti-silent-zero §7 — four states named per retro (to stderr; kit issue #1111 added the 4th):
#   absent-input    retro file / target dir not found
#   empty-input     found but contains no delta section AND no proposal-like heading at all
#   unclassifiable  a delta/canonical section (or a proposal-like heading the shared grammar
#                    cannot classify, e.g. a hyphenated "kit-delta" mid-heading or a standalone
#                    "### Proposals") was found but is not in a countable form — needs manual
#                    review; never conflated with empty-input, which would silently hide it
#   no-match        delta section present; no open deltas AND no orphaned issues
#
# §7 degraded probe: gh absent or unauthenticated → typed "degraded:" + exit 1.
# Findings (untracked, orphaned) are WARN-only and never fail the run.
# Operational failures (TARGETS.md missing, lib helper missing) exit 1.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
_mode="single"
retro=""
_issues_cache=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) _mode="all"; shift ;;
    --issues-cache)
      if [ "$#" -lt 2 ]; then
        echo "reconcile-issues: --issues-cache requires a value" >&2; exit 1
      fi
      _issues_cache="$2"; shift 2 ;;
    --*) echo "reconcile-issues: unknown flag '$1'" >&2; exit 1 ;;
    *)   retro="$1"; shift ;;
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

# gh probe: only required when --issues-cache is not supplied.
# On the cache path, gh is never called so the probe is skipped.
if [ -z "$_issues_cache" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "degraded: gh not found on PATH — install gh CLI to use reconcile-issues" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "degraded: gh is not authenticated — run 'gh auth login'" >&2
    exit 1
  fi
fi

_REPO="angeles725/sdd-investigacion"

# ---------------------------------------------------------------------------
# Kit layout — KIT_ROOT is two dirs up from toolbelt/ (the script's own dir).
# -P/pwd -P (PHYSICAL resolution) is required here, not the default -L logical mode: this script
# is invoked as $KIT/toolbelt/reconcile-issues.sh where $KIT can be a per-profile RENDER dir whose
# toolbelt/ is a SYMLINK to the real kit's toolbelt/ (kit issue #993 WU2 install-time profile
# rendering + #1024 F1 render-dir completion). Bash's default (-L) $PWD tracking resolves ".."
# against the STRING it cd'd into, never spending the symlink component — so the second ".." here
# cancelled it out lexically and landed one level short of the real kit root, inside
# .../research-sdd/profile/ instead of .../research-sdd/ (kit issue #1024 round 3, MEDIUM;
# reproduced: TARGETS_MD pointed at a nonexistent .../profile/research-sdd/TARGETS.md). -P forces
# the kernel's physical path at each step, so both cd's walk the REAL directory tree regardless of
# how many symlinks were traversed to invoke this script.
_SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
KIT_ROOT="$(cd -P "$_SCRIPT_DIR/../.." && pwd -P)"
TARGETS_MD="$KIT_ROOT/research-sdd/TARGETS.md"

# ---------------------------------------------------------------------------
# Source shared helpers (fail-closed)
_RS_LIB="$_SCRIPT_DIR/lib/retro-status.sh"
[ -f "$_RS_LIB" ] || { echo "reconcile-issues: cannot find helper $_RS_LIB" >&2; exit 1; }
# shellcheck source=lib/retro-status.sh
. "$_RS_LIB"
declare -F retro_marker_scope_line >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_marker_scope_line" >&2; exit 1; }
declare -F retro_status_from_marker_line >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_status_from_marker_line" >&2; exit 1; }
declare -F retro_marker_is_partial >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_marker_is_partial" >&2; exit 1; }
declare -F retro_marker_shipped_ids >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_marker_shipped_ids" >&2; exit 1; }
declare -F retro_marker_out_of_scope >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-status.sh failed to define retro_marker_out_of_scope" >&2; exit 1; }

_RG_LIB="$_SCRIPT_DIR/lib/retro-grammar.sh"
[ -f "$_RG_LIB" ] || { echo "reconcile-issues: cannot find helper $_RG_LIB" >&2; exit 1; }
# shellcheck source=lib/retro-grammar.sh
. "$_RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info" >&2; exit 1; }
declare -F retro_grammar_has_honesty >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_has_honesty" >&2; exit 1; }

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
_fleet_degraded=0
_fleet_outofscope=0
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
  local _gh_rc _gh_stderr_file _gh_err_msg

  # --- Parse review-status and PARTIAL marker (mirrors stage-retro-issues.sh logic)
  # RECONCILE_ISSUES_SCOPE_SHARED (kit issue #945): both the raw marker line and the derived
  # status word come from retro_marker_scope_line — the ONE scope reconcile-issues.sh,
  # stage-retro-issues.sh, retro-gate.sh, and sweep-retros.sh now share (leading block, tolerating
  # exactly one H1 line at the top — the real-corpus layout in *-closure.md retros). Before #945
  # this used retro_review_status's NO-H1-tolerance leading-block scan plus its own hand-copied
  # copy of the same awk pipeline, so a marker on line 3 (H1 line 1, blank line 2) was invisible
  # here even though the seeder already found it — the exact split-brain #945 closes.
  local _marker_line
  _marker_line="$(retro_marker_scope_line "$retro_path")"

  # RECONCILE_ISSUES_OUT_OF_SCOPE_GUARD (kit issue #1099): an empty scope-scan result does not
  # mean "no marker" when a whole-file scan still finds one outside the shared #945 scope (YAML
  # frontmatter, a multi-line comment run before it, a marker after a second heading, …).
  # Conflating that with "genuinely absent" was the #1048-#1089 fail-open shape — status read as
  # "" (pending/open) and every row was treated as untracked/open. Report it loudly instead of
  # silently classifying.
  # RECONCILE_ISSUES_OUT_OF_SCOPE_IS_A_FINDING (kit issue #1125 item 3): this is a CORPUS finding
  # (the retro's own marker is mispositioned), not an operational failure of this instrument —
  # per CLAUDE.md §8 a finding is WARN-only and never fails the run, the same rule that already
  # applies to every other typed state this function reports (empty-input, unclassifiable, …).
  # Before this fix it `return 1`ed into the SAME degraded= bucket as a real gh-query failure,
  # so a single mispositioned marker anywhere in the fleet made `--all` exit 1 — indistinguishable
  # from the instrument itself being broken. Counted separately (out-of-scope=) so the finding
  # stays visible without gating the exit code; the other three consumers (sweep-retros.sh,
  # stage-retro-issues.sh, retro-gate.sh) already treat this as non-fatal.
  if [ -z "$_marker_line" ] && retro_marker_out_of_scope "$retro_path"; then
    echo "out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in $retro_basename — refusing to classify (kit issue #1099); move the marker into the leading block" >&2
    _fleet_outofscope=$((_fleet_outofscope + 1))
    return 0
  fi

  local _status
  _status="$(retro_status_from_marker_line "$_marker_line")"

  local is_partial=0 shipped_ids=""
  # RECONCILE_ISSUES_PARTIAL_CHECK (kit issue #1090): PARTIAL is a STATUS TOKEN, detected only
  # in the marker's STRUCTURED segment via the shared retro_marker_is_partial helper — never a
  # case-insensitive whole-line grep, which let a DISMISSED marker's free-text explanation
  # (e.g. "P1 partial" in prose) falsely trip PARTIAL handling and reopen every row.
  if retro_marker_is_partial "$_marker_line"; then
    is_partial=1
    local _shipped_raw
    _shipped_raw="$(printf '%s' "$_marker_line" \
      | grep -oiE 'shipped:[^;>]*' \
      | head -1 \
      | sed -E 's/^[Ss]hipped:[[:space:]]*//')"
    if [ -n "$_shipped_raw" ]; then
      shipped_ids="$(retro_marker_shipped_ids "$_shipped_raw")"
    fi
  fi

  # --- Check for a delta section (empty-input vs unclassifiable — kit issue #1111)
  local _grammar_info _found_field
  _grammar_info="$(retro_grammar_delta_info "$retro_path")"
  _found_field="$(printf '%s' "$_grammar_info" | cut -d '' -f1 | cut -d: -f1)"
  if [ "$_found_field" != "1" ]; then
    # unrec_found (field 3 of retro_grammar_delta_info's \001-separated output): the shared
    # grammar's own unrecognised-delta-intent-heading detector (Rules 1-4). A proposal-like
    # heading the parser cannot classify (e.g. a hyphenated "kit-delta" mid-heading, or a
    # standalone "### Proposals") must never be reported as a confident empty-input.
    local _temp_depr _temp_unrec _unrec_found
    _temp_depr="${_grammar_info#*$'\001'}"
    _temp_unrec="${_temp_depr#*$'\001'}"
    _unrec_found="${_temp_unrec%%$'\001'*}"
    if [ "$_unrec_found" = "1" ]; then
      echo "unclassifiable: proposal-like heading found but not in a countable delta form in $retro_path — needs manual review" >&2
    else
      echo "empty-input: no delta section found in $retro_path" >&2
    fi
    return 0
  fi

  # --- Determine whether any rows can be open
  local _has_open_rows=1
  # RECONCILE_ISSUES_DISMISSED_WINS (kit issue #1090): 'dismissed' ALWAYS means zero open rows
  # — it never falls through to the is_partial check the way 'applied' does. See the matching
  # guard and comment in stage-retro-issues.sh for the full rationale (both tools must agree).
  case "$_status" in
    dismissed)
      _has_open_rows=0 ;;
    applied)
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
          low ~ /^## propuesta de deltas al kit([[:space:]]|$)/ ||
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
    # kit issue #1129 finding 2: check for an HONEST §18 zero FIRST — same reasoning as
    # stage-retro-issues.sh's matching guard (see its comment). Real fleet counterexample:
    # niagara-research/retros/2026-09-17-tools-search-innovation.md.
    if retro_grammar_has_honesty "$retro_path"; then
      echo "empty-input: delta section found but contains no data rows (honest §18 zero) in $retro_path" >&2
      return 0
    fi
    # A canonical/deprecated section WAS found — not "empty" (kit issue #1111), and not a
    # declared honest zero either: typed distinctly from the found=0 empty-input case above
    # (see its comment).
    echo "unclassifiable: delta section found but not in row-table form in $retro_path — needs manual review" >&2
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

  # --- Broad GitHub query or cache read: issue bodies for this retro
  # Retrieves the body of each matching open issue; bodies carry the
  #   "Source retro: <target>/retros/<file> · <row-id>"  signature.
  # §7 contract: query failure → typed degraded + return 1, never false untracked.
  # gh requires --json when --jq is used; --template also requires --json.
  local _sig_prefix="${target_nm}/retros/${retro_basename}"
  local _all_bodies=""
  # RECONCILE_ISSUES_CACHE_BRANCH: anchor for T-CACHE-NO-GH tooth — read from cache when supplied
  if [ -n "$_issues_cache" ]; then
    # RECONCILE_ISSUES_CACHE_READ: read pre-fetched issue bodies from caller-supplied cache file
    _all_bodies="$(cat "$_issues_cache" 2>/dev/null)" || {
      printf 'degraded: --issues-cache file not readable: %s\n' "$_issues_cache" >&2
      return 1
    }
  else
    _gh_stderr_file="$(mktemp 2>/dev/null)" || _gh_stderr_file=""
    # RECONCILE_ISSUES_GH_JSON_FLAG: anchor for T4 tooth — --json body required for --jq
    _all_bodies="$(gh issue list \
        --repo "$_REPO" \
        --state open \
        --search "\"Source retro: ${_sig_prefix} ·\"" \
        --json body \
        --jq '.[].body' 2>"${_gh_stderr_file:-/dev/null}")"; _gh_rc=$?
    if [ "$_gh_rc" -ne 0 ]; then
      if [ -n "$_gh_stderr_file" ]; then
        _gh_err_msg="$(head -1 "$_gh_stderr_file" 2>/dev/null)"
        rm -f "$_gh_stderr_file"
      else
        _gh_err_msg=""
      fi
      echo "degraded: gh issue list failed for $retro_basename (exit $_gh_rc)${_gh_err_msg:+ — }${_gh_err_msg}" >&2
      # RECONCILE_ISSUES_GH_DEGRADED_RETURN: anchor for T5 tooth — return 1 on query failure
      return 1
    fi
    [ -n "$_gh_stderr_file" ] && rm -f "$_gh_stderr_file"
  fi

  # Extract row-ids referenced in open issues for this retro.
  # Cache path: _all_bodies holds ALL open issues — filter by _sig_prefix to avoid cross-retro collision.
  # gh path: bodies are already pre-filtered by the --search flag; generic extraction is safe.
  local _issue_row_ids=""
  if [ -n "$_all_bodies" ]; then
    if [ -n "$_issues_cache" ]; then
      # RECONCILE_ISSUES_CACHE_SIGPREFIX_MATCH: fixed-string filter avoids regex metachar issues
      # (_sig_prefix contains '/', '.', etc. from retro paths — must not be treated as regex).
      _issue_row_ids="$(printf '%s\n' "$_all_bodies" \
        | grep -F "Source retro: ${_sig_prefix} · " \
        | sed -E 's/.* · //' \
        | grep -oE '^[A-Za-z0-9_-]+')"
    else
      _issue_row_ids="$(printf '%s\n' "$_all_bodies" \
        | grep -oE 'Source retro: .+ · [A-Za-z0-9_-]+' \
        | sed -E 's/.* · //')"
    fi
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
  exit $?

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
      audit_retro "$_rfile" "$_tgt_nm" || _fleet_degraded=$((_fleet_degraded+1))
    done < <(find "$_retros_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

    if [ "$_found_retros" -eq 0 ]; then
      echo "WARN: no retro files (*.md) found in '$_retros_dir'" >&2
    fi
  done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)

  if [ "$_found_any_retro" -eq 0 ]; then
    echo "empty-input: no retro files found across all targets" >&2
  fi

  printf 'fleet-summary: tracked=%d untracked=%d orphaned=%d degraded=%d out-of-scope=%d retros=%d\n' \
    "$_fleet_tracked" "$_fleet_untracked" "$_fleet_orphaned" "$_fleet_degraded" "$_fleet_outofscope" "$_fleet_retros"
  # kit issue #1125 item 3: out-of-scope-marker findings are WARN-only (see the guard's comment
  # above) — only genuine operational failures (_fleet_degraded) gate the exit code.
  [ "$_fleet_degraded" -eq 0 ] || exit 1
fi

exit 0
