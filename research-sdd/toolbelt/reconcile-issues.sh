#!/usr/bin/env bash
# reconcile-issues.sh — audit GitHub issue coverage for OPEN kit deltas.
# Resolves issue #794 (Phase 3 of #557).
#
# For each OPEN delta in a §18 retro file, checks whether there is an open issue
# on angeles725/sdd-investigacion carrying the exact
#   "Source retro: <target>/retros/<file> · <row-id>"
# body signature produced by stage-retro-issues.sh. The pre-#1286 LEGACY signature
# (<path basename> instead of the registered target name) is read too, exactly as the seeder's
# dedup does (kit issue #1304 item 2), and only lines carrying THIS retro's signature count — a
# fuzzy GitHub search hit on another target's issue never does (kit issue #1304 item 1).
#
# Usage:
#   reconcile-issues.sh <retro.md>  — audit one retro file
#   reconcile-issues.sh --all       — audit every retro across all TARGETS.md targets
#   --issues-cache <file>  — pre-fetched OPEN issue bodies (no gh call)
#   --closed-cache <file>  — pre-fetched bodies of issues CLOSED AS COMPLETED (used with --issues-cache;
#                            without it the closed-issue check is skipped and says so on stderr)
#
# Classifies each OPEN delta as (printed to stdout):
#   tracked   — open delta HAS a matching open issue
#   untracked — open delta with NO matching issue  (actionable gap)
#   orphaned  — open issue whose delta row is no longer open
#   shipped   — open delta with NO open issue whose matching issue is CLOSED as completed and still
#               carries this retro's exact "Source retro: ..." signature (kit issue #1555): the row
#               has shipped even though the retro marker does not list it. Reported with a proposal
#               to update the marker by hand; never counted as untracked, never auto-edited.
#               A closed issue not closed as completed (e.g. not planned) is NOT shipped evidence.
#               Closure-evidence rule (kit issue #1709): `shipped` additionally needs BOTH a commit AND a
#               test cited in the closed issue (its body or comments), and a cited commit that reaches
#               the main ref. A row closed as completed that fails any part is `borderline` instead.
#   borderline — closed as completed with this retro's signature but the closure evidence is incomplete:
#               no commit cited, no test cited, or no cited commit reachable from the main ref (or
#               reachability could not be verified). Human review; never counted untracked or shipped.
#               Evidence grammar: a COMMIT is a 7-40 char hex token containing a digit on a line that has
#               the word commit/commits; a TEST is a path-like token (.test. / _test. / test_ / a tests/
#               segment) on a line that has the word test/tests. Reachability is
#               `git merge-base --is-ancestor <sha> <ref>` against the LOCALLY KNOWN ref (default
#               origin/main, RECONCILE_ISSUES_MAIN_REF) in the kit checkout (default: this kit's root,
#               RECONCILE_ISSUES_GIT_DIR) - NO implicit fetch: a stale local origin/main can read a
#               just-merged commit as unreachable (borderline), never as shipped. git absent, not a
#               repository, or the ref unknown -> typed `degraded:` + exit 1, rows still printed borderline.
#               NOT YET IMPLEMENTED (deferred from #1709): the `regressed` class (closed-completed plus a
#               later retro re-lists the row) - row ids are per-retro, so "re-lists" needs a defined
#               cross-retro identity first. When added it will be human-review only, never auto-reopen.
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
# Findings (untracked, shipped, orphaned) are WARN-only and never fail the run.
# Operational failures (TARGETS.md missing, lib helper missing) exit 1.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
_mode="single"
retro=""
_issues_cache=""
_closed_cache=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) _mode="all"; shift ;;
    --issues-cache)
      if [ "$#" -lt 2 ]; then
        echo "reconcile-issues: --issues-cache requires a value" >&2; exit 1
      fi
      _issues_cache="$2"; shift 2 ;;
    --closed-cache)
      if [ "$#" -lt 2 ]; then
        echo "reconcile-issues: --closed-cache requires a value" >&2; exit 1
      fi
      _closed_cache="$2"; shift 2 ;;
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
declare -F retro_grammar_entry_ids >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_entry_ids" >&2; exit 1; }
declare -F retro_grammar_entry_warn >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_entry_warn" >&2; exit 1; }
declare -F retro_grammar_has_honesty >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_has_honesty" >&2; exit 1; }
declare -F retro_grammar_defenced >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/retro-grammar.sh failed to define retro_grammar_defenced" >&2; exit 1; }

# RECONCILE_ISSUES_LIST_LIMIT (kit issue #1369 c): the open-issues `gh issue list` carries an explicit
# --limit (gh's own default is 30, which silently truncated a busy repo and read tracked rows as
# untracked). 1000 is GitHub search's practical ceiling; the env override exists so a test can fill a
# page without 1000 fixtures. A reply that FILLS the limit may be truncated: typed degraded, never a
# confident answer (see the record-separator count below).
_LIST_LIMIT="${RECONCILE_ISSUES_LIST_LIMIT:-1000}"
case "$_LIST_LIMIT" in
  ''|*[!0-9]*|0) echo "degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '$_LIST_LIMIT')" >&2; exit 1 ;;
esac

_TP_LIB="$_SCRIPT_DIR/lib/target-paths.sh"
[ -f "$_TP_LIB" ] || { echo "reconcile-issues: cannot find helper $_TP_LIB" >&2; exit 1; }
# shellcheck source=lib/target-paths.sh
. "$_TP_LIB"
declare -F target_paths_all >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/target-paths.sh failed to define target_paths_all" >&2; exit 1; }
declare -F target_name_for_retro >/dev/null 2>&1 \
  || { echo "reconcile-issues: helper lib/target-paths.sh failed to define target_name_for_retro" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fleet accumulators (used under --all to build the final summary line)
_fleet_tracked=0
_fleet_untracked=0
_fleet_shipped=0
_fleet_borderline=0
_fleet_orphaned=0
_fleet_degraded=0
_fleet_outofscope=0
_fleet_retros=0

# ---------------------------------------------------------------------------
# _fetch_closed_bodies <retro_basename> <sig-prefix>...
#   Prints the bodies of issues closed AS COMPLETED for the signature prefix(es) (kit issue #1555).
#   The --jq prints one record-separator line after EVERY issue, with an empty body for one closed
#   any other way (not planned), so the cap guard counts every returned issue: --limit truncates the
#   TOTAL gh returns, so a full page of not-planned issues can hide a completed one and must degrade
#   too (counting only COMPLETED would fail open on exactly that page). A failed query or a
#   reply that filled the --limit is a typed degraded + return 1, never a confident empty answer.
_fetch_closed_bodies() {
  local _rb="$1"; shift
  local _p _out _rc _n _ef _em
  if [ -n "$_closed_cache" ]; then
    # RECONCILE_ISSUES_CLOSED_CACHE_READ
    cat "$_closed_cache" 2>/dev/null || {
      printf 'degraded: --closed-cache file not readable: %s\n' "$_closed_cache" >&2
      return 1
    }
    return 0
  fi
  for _p in "$@"; do
    _ef="$(mktemp 2>/dev/null)" || _ef=""
    # RECONCILE_ISSUES_CLOSED_QUERY: --state closed, completed only (stateReason)
    _out="$(gh issue list \
        --repo "$_REPO" \
        --state closed \
        --limit "$_LIST_LIMIT" \
        --search "\"Source retro: ${_p} ·\"" \
        --json body,stateReason,comments \
        --jq '.[] | (if .stateReason == "COMPLETED" then ([.body] + [(.comments // [])[].body]) | join("\n") else "" end), "\u001e"' 2>"${_ef:-/dev/null}")"; _rc=$?
    if [ "$_rc" -ne 0 ]; then
      if [ -n "$_ef" ]; then _em="$(head -1 "$_ef" 2>/dev/null)"; rm -f "$_ef"; else _em=""; fi
      echo "degraded: gh issue list (closed) failed for $_rb (exit $_rc)${_em:+ — }${_em}" >&2
      return 1
    fi
    [ -z "$_ef" ] || rm -f "$_ef"
    _n="$(printf '%s\n' "$_out" | awk '$0 == "\036" { n++ } END { print n + 0 }')"
    if [ "$_n" -ge "$_LIST_LIMIT" ]; then
      echo "degraded: gh issue list (closed) returned $_n results = the --limit $_LIST_LIMIT cap for $_rb — the result may be truncated (raise RECONCILE_ISSUES_LIST_LIMIT)" >&2
      return 1
    fi
    # Record separators are KEPT (kit issue #1709): one record per issue (body + comments), so the
    # evidence of one issue is never credited to another.
    printf '%s\n' "$_out"
  done
}

# _closed_record <closed-bodies> <sig-prefix> <row-id>
#   Prints the record(s) (issues; separated by an octal-036 line) that carry the exact signature
#   "Source retro: <prefix> · <row-id>" for this row. Empty output = no closed-completed issue for the row.
_closed_record() {
  _CR_PFX="Source retro: ${2} · " _CR_RID="$3" awk '
    BEGIN { pfx = ENVIRON["_CR_PFX"]; rid = ENVIRON["_CR_RID"]; rec = ""; hit = 0 }
    function flush() { if (hit) printf "%s", rec; rec = ""; hit = 0 }
    $0 == "\036" { flush(); next }
    {
      rec = rec $0 "\n"
      p = index($0, pfx)
      if (p > 0) {
        rest = substr($0, p + length(pfx))
        if (match(rest, /^[A-Za-z0-9_-]+/) && substr(rest, 1, RLENGTH) == rid) hit = 1
      }
    }
    END { flush() }' <<<"$1"
}

# _evidence_commits <record-text> - hex commit tokens (7-40 chars, at least one digit) on lines naming a commit.
_evidence_commits() {
  printf '%s\n' "$1" \
    | grep -iE '(^|[^[:alnum:]])commits?([^[:alnum:]]|$)' \
    | grep -oE '(^|[^0-9a-fA-F])[0-9a-fA-F]{7,40}([^0-9a-fA-F]|$)' \
    | grep -oE '[0-9a-fA-F]{7,40}' | grep -E '[0-9]' | sort -u
}

# _evidence_has_test <record-text> - a path-like test token on a line naming a test.
_evidence_has_test() {
  # Captured, then matched through a here-string: `producer | grep -q` races SIGPIPE under pipefail.
  local _tl
  _tl="$(printf '%s\n' "$1" | grep -iE '(^|[^[:alnum:]])tests?([^[:alnum:]]|$)')"
  grep -qE '(\.test\.|_test\.|test_|/tests?/|(^|[^[:alnum:]])tests?/)' <<<"$_tl"
}

# Ancestry probe (kit issue #1709) - lazy, once per run. _GIT_STATE: "" (not probed) | ok | degraded.
_GIT_DIR="${RECONCILE_ISSUES_GIT_DIR:-$KIT_ROOT}"
_MAIN_REF="${RECONCILE_ISSUES_MAIN_REF:-origin/main}"
_GIT_STATE=""
_git_probe() {
  [ -z "$_GIT_STATE" ] || return 0
  if ! command -v git >/dev/null 2>&1; then
    _GIT_STATE=degraded; echo "degraded: git not found on PATH — cannot verify that cited commits reach $_MAIN_REF; rows are reported borderline, not shipped" >&2; return 0
  fi
  if ! git -C "$_GIT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _GIT_STATE=degraded; echo "degraded: $_GIT_DIR is not a git repository — cannot verify that cited commits reach $_MAIN_REF; rows are reported borderline, not shipped" >&2; return 0
  fi
  if ! git -C "$_GIT_DIR" rev-parse --verify -q "${_MAIN_REF}^{commit}" >/dev/null 2>&1; then
    _GIT_STATE=degraded; echo "degraded: ref $_MAIN_REF is not known locally in $_GIT_DIR (no fetch is performed) — cannot verify that cited commits reach it; rows are reported borderline, not shipped" >&2; return 0
  fi
  _GIT_STATE=ok
}

# ---------------------------------------------------------------------------
# audit_retro <retro_path> <target_name>
#   Prints findings (tracked/untracked/orphaned) to stdout.
#   Prints advisory messages (empty-input, no-match, WARN) to stderr.
#   Returns 0 on all advisory findings; non-zero only on operational failure.
audit_retro() {
  local retro_path="$1" target_nm="$2"
  local retro_basename
  retro_basename="$(basename "$retro_path")"

  # RECONCILE_ISSUES_UNREADABLE (R3-unreadable-silent-zero): an existing but unreadable retro is not an
  # empty one - every parse below would see nothing and report a confident empty-input / no-match.
  if [ ! -r "$retro_path" ]; then
    echo "degraded: retro not readable: $retro_path — cannot audit, no verdict" >&2
    return 1
  fi

  local r_tracked=0 r_untracked=0 r_orphaned=0 r_shipped=0 r_borderline=0 _anc_degraded=0
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
  _all_row_ids="$(_RG_QUIET_FENCE=1 retro_grammar_defenced "$retro_path" | awk '
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
  ')"

  # RECONCILE_ISSUES_ENTRY_FORM (kit issue #1332 item 2): no table rows -> the doctrine-valid
  # `### D<N> —` entry form (sweep-retros form 2). The IDs come from the SHARED grammar lib so
  # this instrument counts the same entries sweep-retros.sh and verify-retro.sh count.
  if [ -z "$_all_row_ids" ]; then
    _all_row_ids="$(retro_grammar_entry_ids "$retro_path")"
    # RECONCILE_ISSUES_ENTRY_GAP_WARN (kit issue #1332 N6): entries whose heading token is not a usable ID.
    [ -z "$_all_row_ids" ] || retro_grammar_entry_warn "$retro_path" >&2
  fi

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
    echo "unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries in $retro_path — needs manual review" >&2
    return 0
  fi

  # --- Build _open_ids: row-ids that are currently open (not shipped)
  local _open_ids="" _rln
  if [ "$_has_open_rows" -eq 1 ]; then
    while IFS= read -r _rln; do
      [ -z "$_rln" ] && continue
      if [ "$is_partial" -eq 1 ]; then
        # Skip rows in the shipped set
        if grep -qxF "$_rln" <<<"$shipped_ids"; then
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
  # RECONCILE_ISSUES_LEGACY_SIG (kit issue #1304 item 2): the seeder also dedups against the
  # LEGACY `<path basename>/retros/<file>` signature that issues created before #1286 carry
  # (stage-retro-issues.sh, kit issue #1287). Without the same lookup here an OPEN legacy-signed
  # issue was reported `untracked` — an actionable gap that does not exist. The legacy name is the
  # basename of the directory holding retros/; it is skipped when it equals the registered name or
  # is a structural directory (`corpus`, `retros`), exactly as the seeder does.
  local _legacy_nm _legacy_prefix=""
  _legacy_nm="$(basename "$(dirname "$(dirname "$retro_path")")")"
  case "$_legacy_nm" in
    corpus|retros|''|"$target_nm") ;;
    *) _legacy_prefix="${_legacy_nm}/retros/${retro_basename}" ;;
  esac
  local _all_bodies=""
  # RECONCILE_ISSUES_CACHE_BRANCH: anchor for T-CACHE-NO-GH tooth — read from cache when supplied
  if [ -n "$_issues_cache" ]; then
    # RECONCILE_ISSUES_CACHE_READ: read pre-fetched issue bodies from caller-supplied cache file
    _all_bodies="$(cat "$_issues_cache" 2>/dev/null)" || {
      printf 'degraded: --issues-cache file not readable: %s\n' "$_issues_cache" >&2
      return 1
    }
  else
    local _qpfx _qbodies _qn
    for _qpfx in "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"}; do
      _gh_stderr_file="$(mktemp 2>/dev/null)" || _gh_stderr_file=""
      # RECONCILE_ISSUES_GH_JSON_FLAG: anchor for T4 tooth — --json body required for --jq
      _qbodies="$(gh issue list \
          --repo "$_REPO" \
          --state open \
          --limit "$_LIST_LIMIT" \
          --search "\"Source retro: ${_qpfx} ·\"" \
          --json body \
          --jq '.[] | .body, "\u001e"' 2>"${_gh_stderr_file:-/dev/null}")"; _gh_rc=$?
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
      # RECONCILE_ISSUES_LIST_CAP_GUARD (kit issue #1369 c): the --jq emits one record-separator line
      # (octal 036, never present in an issue body) after every body, so the issue COUNT is readable
      # without a JSON parser. A reply that filled the --limit may have been cut off: the missing
      # issues would read as untracked rows, so it is a typed degraded, not an answer.
      _qn="$(printf '%s\n' "$_qbodies" | awk '$0 == "\036" { n++ } END { print n + 0 }')"
      if [ "$_qn" -ge "$_LIST_LIMIT" ]; then
        echo "degraded: gh issue list returned $_qn results = the --limit $_LIST_LIMIT cap for $retro_basename — the result may be truncated (raise RECONCILE_ISSUES_LIST_LIMIT)" >&2
        return 1
      fi
      _qbodies="$(printf '%s\n' "$_qbodies" | awk '$0 != "\036"')"
      _all_bodies="${_all_bodies}${_qbodies}"$'\n'
    done
  fi

  # Extract row-ids referenced in open issues for this retro. BOTH paths use the same exact
  # `Source retro: <prefix> · ` filter (kit issue #1304): the gh query is a fuzzy WORD search, so
  # its bodies may belong to another target's issue (a `*-research` target's issue for the same
  # file and row id); extracting `Source retro: .+ · <id>` from them reported rows that this retro
  # does not have as tracked/orphaned. The cache path always carried ALL open issues' bodies.
  local _issue_row_ids="" _pfx _pfx_ids
  if [ -n "$_all_bodies" ]; then
    for _pfx in "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"}; do
      # RECONCILE_ISSUES_CACHE_SIGPREFIX_MATCH: fixed-string filter avoids regex metachar issues
      # (the prefix contains '/', '.', etc. from retro paths — must not be treated as regex).
      _pfx_ids="$(printf '%s\n' "$_all_bodies" \
        | grep -F "Source retro: ${_pfx} · " \
        | sed -E 's/.* · //' \
        | grep -oE '^[A-Za-z0-9_-]+')"
      [ -z "$_pfx_ids" ] || _issue_row_ids="${_issue_row_ids:+${_issue_row_ids}
}${_pfx_ids}"
    done
  fi

  # --- Classify open deltas: tracked or untracked
  local _rid _closed_loaded=0 _cb="" _cpfx _crec _ev_rec _ev_commits _ev_c _ev_reach _ev_missing
  if [ -n "$_open_ids" ]; then
    while IFS= read -r _rid; do
      [ -z "$_rid" ] && continue
      # RECONCILE_ISSUES_TRACKED_CHECK: anchor for T1 teeth — condition detects tracked
      if grep -qxF "$_rid" <<<"$_issue_row_ids"; then  # RECONCILE-ROWID-CACHE-CHECK
        printf 'tracked: row %s — open issue found in %s\n' "$_rid" "$retro_basename"
        r_tracked=$((r_tracked+1))
      else
        # RECONCILE_ISSUES_CLOSED_LOOKUP (kit issue #1555): no OPEN issue is not yet "no issue" — the
        # row may have shipped through an issue that was since closed as completed. Looked up lazily,
        # once per retro, only when a row has no open issue. With --issues-cache and no --closed-cache
        # the check cannot run: say so instead of reading it as "no closed issue".
        if [ "$_closed_loaded" -eq 0 ]; then
          _closed_loaded=1
          if [ -n "$_issues_cache" ] && [ -z "$_closed_cache" ]; then
            echo "closed-lookup: skipped for $retro_basename — --issues-cache without --closed-cache; rows with no open issue are not checked against closed issues" >&2
          else
            _cb="$(_fetch_closed_bodies "$retro_basename" "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"})" || return 1
          fi
        fi
        _ev_rec=""
        if [ -n "$_cb" ]; then
          for _cpfx in "$_sig_prefix" ${_legacy_prefix:+"$_legacy_prefix"}; do
            _crec="$(_closed_record "$_cb" "$_cpfx" "$_rid")"
            [ -z "$_crec" ] || _ev_rec="${_ev_rec}${_crec}"$'\n'
          done
        fi
        if [ -n "$_ev_rec" ]; then  # RECONCILE-CLOSED-SHIPPED
          # RECONCILE_ISSUES_CLOSURE_EVIDENCE (kit issue #1709): closed-as-completed is not enough - shipped
          # needs a commit AND a test cited, and a cited commit that reaches the main ref.
          _ev_missing=""; _ev_reach=""
          _ev_commits="$(_evidence_commits "$_ev_rec")"
          [ -n "$_ev_commits" ] || _ev_missing="no commit cited"
          if ! _evidence_has_test "$_ev_rec"; then  # RECONCILE-EVIDENCE-TEST
            _ev_missing="${_ev_missing:+${_ev_missing}; }no test cited"
          fi
          if [ -n "$_ev_commits" ]; then
            _git_probe
            if [ "$_GIT_STATE" = "ok" ]; then
              while IFS= read -r _ev_c; do
                [ -n "$_ev_c" ] || continue
                if git -C "$_GIT_DIR" rev-parse --verify -q "${_ev_c}^{commit}" >/dev/null 2>&1 \
                   && git -C "$_GIT_DIR" merge-base --is-ancestor "$_ev_c" "$_MAIN_REF" >/dev/null 2>&1; then  # RECONCILE-ANCESTRY
                  _ev_reach="$_ev_c"; break
                fi
              done <<<"$_ev_commits"
              [ -n "$_ev_reach" ] || _ev_missing="${_ev_missing:+${_ev_missing}; }no cited commit reachable from local ref $_MAIN_REF (no fetch performed; a stale ref reads as unreachable)"
            else
              _anc_degraded=1
              _ev_missing="${_ev_missing:+${_ev_missing}; }commit reachability could not be verified (degraded)"
            fi
          fi
          if [ -z "$_ev_missing" ]; then
            printf 'shipped: row %s — its issue is closed as completed and cites this retro in %s; propose marking the row shipped in the retro marker (not edited here) [evidence: commit %s reachable from %s (local ref, no fetch); test cited]\n' \
              "$_rid" "$retro_basename" "$_ev_reach" "$_MAIN_REF"
            r_shipped=$((r_shipped+1))
          else
            printf 'borderline: row %s — its issue is closed as completed and cites this retro in %s, but the closure evidence is incomplete (%s); human review (not shipped, not untracked, nothing edited)\n' \
              "$_rid" "$retro_basename" "$_ev_missing"
            r_borderline=$((r_borderline+1))
          fi
        else
          # RECONCILE_ISSUES_UNTRACKED_EMIT: anchor for T2 teeth — emit untracked when no issue
          printf 'untracked: row %s — no open issue found for this delta in %s\n' \
            "$_rid" "$retro_basename"
          r_untracked=$((r_untracked+1))
        fi
      fi
    done <<< "$_open_ids"
  fi

  # --- Detect orphaned: issue row-ids not present in the current open delta set
  local _irid
  if [ -n "$_issue_row_ids" ]; then
    while IFS= read -r _irid; do
      [ -z "$_irid" ] && continue
      # RECONCILE_ISSUES_ORPHANED_CHECK: anchor for T3 teeth — condition detects orphaned
      if ! grep -qxF "$_irid" <<<"$_open_ids"; then
        # RECONCILE_ISSUES_SHIPPED_OPEN (kit issue #1492 / #1260): say WHY the row is no longer open
        # when the retro marker proves it (shipped id list, or a terminal applied/dismissed status),
        # so the human can close the issue. REPORT ONLY (propose-never-apply): nothing is closed.
        # A row merely absent from the retro gets no claim: absent is not shipped.
        local _orphan_why=""
        if [ "$is_partial" -eq 1 ] && grep -qxF "$_irid" <<<"$shipped_ids"; then  # RECONCILE-SHIPPED-OPEN
          _orphan_why=" — the retro marker lists it shipped; propose closing the issue (not closed here)"
        elif grep -qxF "$_irid" <<<"$_all_row_ids"; then
          case "$_status" in
            applied|dismissed) _orphan_why=" — the retro review-status is ${_status}; propose closing the issue (not closed here)" ;;  # RECONCILE-STATUS-REASON
          esac
        fi
        printf 'orphaned: issue for row %s is no longer open in %s%s\n' \
          "$_irid" "$retro_basename" "$_orphan_why"
        r_orphaned=$((r_orphaned+1))
      fi
    done <<< "$_issue_row_ids"
  fi

  # --- no-match: nothing actionable found at all
  if [ "$r_tracked" -eq 0 ] && [ "$r_untracked" -eq 0 ] && [ "$r_orphaned" -eq 0 ] && [ "$r_shipped" -eq 0 ] && [ "$r_borderline" -eq 0 ]; then
    echo "no-match: no open deltas and no orphaned issues in $retro_basename" >&2
  fi

  # Accumulate fleet totals
  _fleet_tracked=$((_fleet_tracked + r_tracked))
  _fleet_untracked=$((_fleet_untracked + r_untracked))
  _fleet_shipped=$((_fleet_shipped + r_shipped))
  _fleet_borderline=$((_fleet_borderline + r_borderline))
  _fleet_orphaned=$((_fleet_orphaned + r_orphaned))
  _fleet_retros=$((_fleet_retros + 1))

  # An unverifiable ancestry check is a typed degraded (rows were still printed, as borderline).
  [ "$_anc_degraded" -eq 0 ] || return 1
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

  # Derive the target NAME exactly as stage-retro-issues.sh does (kit issue #1287): the shared
  # lib/target-paths.sh helper walks UP to the nearest registered ancestor (flat <target>/retros,
  # nested <target>/corpus/retros, deeper layouts) and returns the TARGETS.md Target-column name,
  # so the signature searched here is the `Source retro: <name>/retros/<file>` the writer stamped.
  #   rc 1 -> operational failure (TARGETS.md absent/unreadable/zero rows): exit 1, never a guess
  #   rc 2 -> no registered ancestor: flat layout keeps the WARN + basename fallback; a structural
  #           dir (corpus|retros) is refused (the writer refuses it too, so no issue can exist).
  _retro_dir="$(dirname "$retro")"
  _target_dir="$(cd "$(dirname "$_retro_dir")" && pwd)"
  _tgt_name="$(target_name_for_retro "$TARGETS_MD" "$retro")"
  _tnr_rc=$?
  if [ "$_tnr_rc" -eq 1 ]; then
    echo "reconcile-issues: cannot resolve target for '$retro' — operational failure reading $TARGETS_MD (see message above)" >&2
    exit 1
  fi

  if [ "$_tnr_rc" -ne 0 ] || [ -z "$_tgt_name" ]; then
    _tgt_name="$(basename "$_target_dir")"
    case "$_tgt_name" in
      corpus|retros)
        echo "reconcile-issues: cannot resolve target for '$retro' — no ancestor directory is registered in $TARGETS_MD (basename '$_tgt_name' is a structural directory, not a target)" >&2
        exit 1 ;;
    esac
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

    # Both layouts hold a target's retros (METHODOLOGY §3b): flat <target>/retros and nested
    # <target>/corpus/retros (kit issue #1287 — --all used to scan only the flat one).
    _have_retros_dir=0; _tgt_found=0; _empty_dirs=""
    for _retros_dir in "$_tgt_path/retros" "$_tgt_path/corpus/retros"; do
      [ -d "$_retros_dir" ] || continue
      _have_retros_dir=1
      _found_retros=0
      while IFS= read -r _rfile; do
        [ -f "$_rfile" ] || continue
        _found_retros=1
        _found_any_retro=1
        # Name per retro file via the SAME helper as single mode, so a nested registered target's
        # own retros are never labelled with this (outer) target's name.
        _rf_name="$(target_name_for_retro "$TARGETS_MD" "$_rfile")"
        _rf_rc=$?
        if [ "$_rf_rc" -ne 0 ] || [ -z "$_rf_name" ]; then
          echo "degraded: cannot resolve a registered target name for $_rfile (target_name_for_retro rc=$_rf_rc)" >&2
          _fleet_degraded=$((_fleet_degraded+1))
          continue
        fi
        audit_retro "$_rfile" "$_rf_name" || _fleet_degraded=$((_fleet_degraded+1))
      done < <(find "$_retros_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

      if [ "$_found_retros" -eq 0 ]; then
        _empty_dirs="${_empty_dirs}${_retros_dir}"$'\n'
      else
        _tgt_found=1
      fi
    done

    # An empty retros dir only WARNs when the target has no retros in ANY of its layouts: a
    # target keeping them under corpus/retros (e.g. ford) must not also be reported as "no retro
    # files" for its empty flat retros/ sibling — that would claim the opposite of what was audited.
    if [ "$_tgt_found" -eq 0 ] && [ -n "$_empty_dirs" ]; then
      while IFS= read -r _ed; do
        [ -n "$_ed" ] || continue
        echo "WARN: no retro files (*.md) found in '$_ed'" >&2
      done <<<"$_empty_dirs"
    fi

    if [ "$_have_retros_dir" -eq 0 ]; then
      echo "WARN: no retros/ directory for target '$_tgt_nm'" >&2
    fi
  done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)

  if [ "$_found_any_retro" -eq 0 ]; then
    echo "empty-input: no retro files found across all targets" >&2
  fi

  printf 'fleet-summary: tracked=%d untracked=%d shipped=%d borderline=%d orphaned=%d degraded=%d out-of-scope=%d retros=%d\n' \
    "$_fleet_tracked" "$_fleet_untracked" "$_fleet_shipped" "$_fleet_borderline" "$_fleet_orphaned" "$_fleet_degraded" "$_fleet_outofscope" "$_fleet_retros"
  # kit issue #1125 item 3: out-of-scope-marker findings are WARN-only (see the guard's comment
  # above) — only genuine operational failures (_fleet_degraded) gate the exit code.
  [ "$_fleet_degraded" -eq 0 ] || exit 1
fi

exit 0
