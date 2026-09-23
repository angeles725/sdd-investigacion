#!/usr/bin/env bash
# retro-grammar.sh — shared delta-heading grammar for §18 retrospective analysis.
# Single source of truth for: canonical heading recognition, deprecated-alias recognition,
# table-row counting, and unrecognised-heading detection (Rules 1–3). Sourced by
# sweep-retros.sh and verify-retro.sh so the grammar can never drift between them.
#
# Sourced (never executed); consumers MUST fail closed after sourcing:
#   # shellcheck source=lib/retro-grammar.sh
#   . "$_rg_lib"
#   declare -F retro_grammar_delta_info >/dev/null 2>&1 || \
#     { echo "<script>: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info" >&2; exit 1; }
#
# retro_grammar_delta_info <file>
#   Parses a §18 retro file for its delta-section content.
#   Reads the file once and outputs one line of 5 NUL-safe \001-separated fields:
#
#     <found>:<form>:<count>\001<depr_h>\001<unrec_found>\001<unrec_data>\001<unrec_heading>
#
#   Field 1: <found>:<form>:<count>  (colon-separated triple)
#     found = 1 if a canonical or deprecated heading was found, 0 otherwise
#     form  = 1  table rows in canonical section (sweep form-1)
#             2  separator-shaped ### sub-headings in canonical section (sweep form-2)
#             3  ## Delta <id> — headings outside canonical section (sweep form-3)
#             w  canonical heading found but no countable rows (WARN-A)
#             n  no canonical/deprecated heading found (no section)
#     count = numeric count for the active form
#   Field 2: <depr_h>       — first deprecated-alias heading line (empty if none)
#   Field 3: <unrec_found>  — 1 if an unrecognised delta-intent heading was found, 0 otherwise
#   Field 4: <unrec_data>   — data rows in the unrecognised section (rows-1 if rows>0, else 0)
#   Field 5: <unrec_heading> — text of the first unrecognised heading (empty if none)
#
# GRAMMAR — canonical headings (case-insensitive, no deprecation WARN):
#   ## [N. ]Proposed kit delta[s][...]
#   ## Proposed delta[...]
#   ## Delta proposals[...]
#   ## Deltas NUEVOS[...]
#
# GRAMMAR — deprecated aliases (#436; accepted + WARN-migrate unconditionally):
#   ## Summary of proposed delta[...]
#   ## Summary of new deltas[...]
#   ## Delta details[...]
#
# GRAMMAR — unrecognised delta-intent headings (verify-retro Rules 1–3; outside grammar):
#   Rule 1: ## [N. ]delta<s>? followed by whitespace, ( or EOL
#   Rule 2: " kit delt" anywhere (space-separated), NOT negated by "not"
#   Rule 3: "(kit-delta" (parenthetical hyphenated compound)
#
# RSDD_RETRO_GRAMMAR_DEPR_ANCHOR — sentinel used by the both-consumers-flip mutant in
# tests/retro-grammar.test.sh; changing the deprecated-alias regex on/after this line
# must flip BOTH sweep-retros.sh (delta count changes) AND verify-retro.sh (conformance
# verdict changes) on their respective fixture retros.

# ─── Single canonical heading awk function (R2-001: one definition shared by all) ─
# _RG_AWK_CANONICAL_FN is prepended to every awk invocation in this lib so both
# retro_grammar_delta_info and retro_grammar_has_honesty use the same heading aliases.
# Deprecated aliases are included because they also enter the canonical section.
# RSDD_RETRO_GRAMMAR_CANONICAL_AWK_FN_ANCHOR
_RG_AWK_CANONICAL_FN='
function is_canonical_heading(low) {
  if (low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/) return 1
  if (low ~ /^## proposed delta/)             return 1
  if (low ~ /^## delta proposals/)            return 1
  if (low ~ /^## deltas nuevos/)              return 1
  if (low ~ /^## summary of proposed delta/)  return 1
  if (low ~ /^## summary of new deltas/)      return 1
  if (low ~ /^## delta details([[:space:]]|$)/) return 1
  return 0
}
function is_depr_heading(low) {
  if (low ~ /^## summary of proposed delta/)    return 1
  if (low ~ /^## summary of new deltas/)        return 1
  if (low ~ /^## delta details([[:space:]]|$)/) return 1
  return 0
}
'

# Idempotent: safe to source more than once.
# typeset -f is used instead of declare -F: both work in bash (typeset is an alias for declare),
# while declare -F in zsh means "declare as float" (always exits 0), so sourcing from zsh with
# the declare -F guard would never define the function (#903).
if ! typeset -f retro_grammar_delta_info >/dev/null 2>&1; then

  retro_grammar_delta_info() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || { printf '0:n:0\001\0010\0010\001\n'; return 0; }
    awk "$_RG_AWK_CANONICAL_FN"'
      BEGIN { in_sec=0; found=0; rows=0; h3d=0; d3=0; depr_h=""
              in_unrec=0; unrec_found=0; unrec_rows=0; unrec_heading="" }
      { low=tolower($0) }

      # ── Canonical section headings (via shared function) ──────────────────────
      # RSDD_RETRO_GRAMMAR_CANONICAL_ANCHOR
      is_canonical_heading(low) {
        in_sec=1; in_unrec=0; found=1
        if (is_depr_heading(low) && !depr_h) depr_h=$0
        next
      }

      # ── Other level-2 headings (### sub-sections stay in active scope) ────────
      /^##[^#]/ {
        in_sec=0
        if (!found) {
          # Form-3 counting: ## Delta <id> — headings outside canonical section.
          # Used by sweep-retros.sh as a machine-countable alternative form.
          # R4: guard with is_canonical_heading so ## Delta details alias never self-matches.
          if (!is_canonical_heading(low) && low ~ /^## delta / && $0 ~ /—/) { d3++ }
          # Unrecognised delta-intent heading detection (verify-retro Rules 1–3).
          # Fires independently of d3 — the two consumers interpret the same heading
          # differently (sweep-retros counts form-3; verify-retro flags unrecognised).
          is_unrec=0
          # Rule 1: ## [N. ]delta<s>? followed by whitespace, ( or EOL
          if (low ~ /^## [0-9. ]*deltas?([[:space:]]|[(]|$)/) is_unrec=1
          # Rule 2: space-separated "kit delta/deltas", not negated by "not"
          if (!is_unrec && low ~ / kit delt/ && low !~ /not +kit +delt/) is_unrec=1
          # Rule 3: parenthetical (kit-delta hyphenated compound
          if (!is_unrec && low ~ /\(kit-delta/) is_unrec=1
          if (is_unrec && !unrec_found) { unrec_found=1; in_unrec=1; unrec_heading=$0 }
          else { in_unrec=0 }
        } else { in_unrec=0 }
        next
      }

      # ── Row counting ─────────────────────────────────────────────────────────
      # Count non-separator |rows in the canonical section (sweep form-1 and form-2).
      in_sec   && /^\|/ && $0 !~ /^\|[-: |]+\|?[[:space:]]*$/ { rows++ }
      # Count separator-shaped ### sub-headings in canonical section (sweep form-2).
      in_sec   && /^###[^#]/ && /—/                             { h3d++ }
      # Count non-separator |rows in the unrecognised section (verify-retro).
      in_unrec && /^\|/ && $0 !~ /^\|[-: |]+\|?[[:space:]]*$/ { unrec_rows++ }

      END {
        data       = (rows      > 0) ? rows      - 1 : 0
        unrec_data = (unrec_rows > 0) ? unrec_rows - 1 : 0
        if (found) {
          if      (data > 0) printf "1:1:%d\001%s\001%d\001%d\001%s\n", data,  depr_h, unrec_found, unrec_data, unrec_heading
          else if (h3d  > 0) printf "1:2:%d\001%s\001%d\001%d\001%s\n", h3d,   depr_h, unrec_found, unrec_data, unrec_heading
          else               printf "1:w:0\001%s\001%d\001%d\001%s\n",         depr_h, unrec_found, unrec_data, unrec_heading
        } else {
          if (d3 > 0) printf "0:3:%d\001\001%d\001%d\001%s\n", d3,   unrec_found, unrec_data, unrec_heading
          else        printf "0:n:0\001\001%d\001%d\001%s\n",         unrec_found, unrec_data, unrec_heading
        }
      }
    ' "$f"
  }

fi

# ─── retro_grammar_has_honesty ────────────────────────────────────────────────
# Predicate: does file $1 carry a §18 honesty line in a PURE accepted location?
#
# Design (§912 stricter fail-safe, R2/R3/R4):
#
# A. PURE canonical section: after removing blank lines, multi-line HTML comments
#    (<!-- … -->), fenced blocks (``` or ~~~ with any leading whitespace), and
#    empty-table header+separator rows (only valid when no data rows follow), the
#    section body must be exactly one or more honesty lines.
#
# B. ## Honest verdict: accepted ONLY when the canonical delta section is absent or
#    its body is empty by rule A (no real lines after stripping).  A canonical
#    section with non-honesty content blocks the HV path.
#
# C. Honesty line matching: strip leading whitespace and list/blockquote/emphasis
#    markers (- * + > ** __ _) before matching /^no new deltas([^a-z0-9]|$)/.
#
# D. Invariant: delta indicators OUTSIDE the canonical section still veto ~0.
#    - Form-3 (## Delta X — ...): counted only BEFORE canonical heading (same
#      classifier as retro_grammar_delta_info); canonical alias self-match guarded
#      by is_canonical_heading() (R4 fix).
#    - WARN-B (### D1.-style): counted outside the canonical section.
#    Both use the shared is_canonical_heading() from _RG_AWK_CANONICAL_FN (R2-001).
#
# Returns:
#   exit 0 — pure honesty: accepted location, pure section, no conflicting indicators
#   exit 1 — not found, impure, wrong location, or conflicting indicators
#
# RSDD_RETRO_GRAMMAR_HONESTY_ANCHOR
if ! typeset -f retro_grammar_has_honesty >/dev/null 2>&1; then
  retro_grammar_has_honesty() {
    [ -f "$1" ] || return 1
    awk "$_RG_AWK_CANONICAL_FN"'
      # ── Honesty marker stripping (C) ────────────────────────────────────────
      function strip_markers(s,    prev) {
        gsub(/^[[:space:]]+/, "", s)
        prev = ""
        while (s != prev && length(s) > 0) {
          prev = s
          sub(/^[-*+>][[:space:]]*/,  "", s); gsub(/^[[:space:]]+/, "", s)
          sub(/^\*\*/, "", s);                gsub(/^[[:space:]]+/, "", s)
          sub(/^__/, "", s);                  gsub(/^[[:space:]]+/, "", s)
          if (s ~ /^_[^_]/) { sub(/^_/, "", s); gsub(/^[[:space:]]+/, "", s) }
        }
        return s
      }
      function is_honesty(raw,    s, l) {
        s = strip_markers(raw)
        l = tolower(s)
        if (l ~ /^no new deltas([^a-z0-9]|$)/) return 1
        return 0
      }

      BEGIN {
        in_canonical  = 0; in_hv = 0
        in_fence      = 0; fence_ch = ""
        in_mlc        = 0   # multi-line HTML comment
        canonical_found  = 0
        before_canonical = 1
        # Canonical body counters
        body_real    = 0   # non-blank, non-table, non-comment, non-fence lines
        body_honesty = 0   # of those, lines that satisfy is_honesty()
        body_pipe    = 0   # non-separator | rows (header+data mixed; data = max(0,pipe-1))
        # HV body
        hv_honesty   = 0
        # Invariant indicators outside canonical section
        ext_form3    = 0   # form-3 heading before canonical
        ext_warnb    = 0   # WARN-B ### D1. heading outside canonical
      }

      # ── Multi-line HTML comment (global, before section routing) ─────────────
      in_mlc {
        if (index($0, "-->") > 0) in_mlc = 0
        next
      }
      /<!--/ {
        if (index($0, "-->") == 0) in_mlc = 1
        next
      }

      # ── Fence tracking (``` or ~~~ with any leading whitespace) ─────────────
      !in_fence && /^[[:space:]]*(`{3,}|~{3,})/ {
        in_fence = 1
        fence_ch = ($0 ~ /^[[:space:]]*`/) ? "`" : "~"
        next
      }
      in_fence {
        if ((fence_ch == "`" && /^[[:space:]]*```/) ||
            (fence_ch == "~" && /^[[:space:]]*~~~/)) {
          in_fence = 0
        }
        next
      }

      # ── Section transitions and indicator detection ─────────────────────────
      /^##[^#]/ {
        low = tolower($0)
        if (is_canonical_heading(low)) {
          in_canonical = 1; in_hv = 0
          canonical_found = 1; before_canonical = 0
          next
        }
        in_canonical = 0; in_hv = 0
        if (low ~ /^## honest verdict([[:space:]]|$)/) {
          in_hv = 1
        } else {
          # Form-3 indicator: ## Delta X — headings only before canonical (D, R4).
          # is_canonical_heading() guard ensures ## Delta details alias never self-matches.
          if (before_canonical && low ~ /^## delta[[:space:]]/ && $0 ~ /[—–]/) {
            ext_form3 = 1
          }
        }
        next
      }

      # ── WARN-B indicator (### D1.-style, outside canonical section) ──────────
      !in_canonical && /^###[^#]/ {
        if ($0 ~ /###[[:space:]]+([[:alpha:]][0-9]+|[0-9]+)([[:space:].—–-]|$)/) {
          ext_warnb = 1
        }
        next
      }

      # ── Canonical body analysis ───────────────────────────────────────────────
      in_canonical {
        if ($0 ~ /^[[:space:]]*$/) next                                   # blank
        if (/^\|/) {                                                       # table row
          if ($0 !~ /^\|[-: |]+\|?[[:space:]]*$/) body_pipe++            # non-separator
          next
        }
        # Real non-table line
        body_real++
        if (is_honesty($0)) body_honesty++
        next
      }

      # ── HV body analysis ─────────────────────────────────────────────────────
      in_hv {
        if ($0 ~ /^[[:space:]]*$/) next
        if (is_honesty($0)) hv_honesty = 1
        next
      }

      END {
        # Invariant veto: conflicting indicators outside canonical section
        if (ext_form3 || ext_warnb) { exit 1 }

        # Data rows = max(0, non-separator pipe rows - 1)
        body_data = (body_pipe > 1) ? body_pipe - 1 : 0

        if (canonical_found) {
          # Canonical section has data rows → not honesty path
          if (body_data > 0) { exit 1 }
          # Pure honesty: all real (non-table) lines are honesty lines, at least one
          if (body_real > 0 && body_honesty == body_real) { exit 0 }
          # Empty canonical (no real non-table content after stripping) → check HV (B)
          if (body_real == 0) {
            if (hv_honesty) { exit 0 }
          }
          # Canonical has non-honesty content → HV blocked (B, R3-001)
          exit 1
        } else {
          # No canonical section: check HV
          if (hv_honesty) { exit 0 }
          exit 1
        }
      }
    ' "$1"
  }
fi
