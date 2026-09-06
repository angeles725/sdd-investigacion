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

# Idempotent: safe to source more than once.
if ! declare -F retro_grammar_delta_info >/dev/null 2>&1; then

  retro_grammar_delta_info() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || { printf '0:n:0\001\0010\0010\001\n'; return 0; }
    awk '
      BEGIN { in_sec=0; found=0; rows=0; h3d=0; d3=0; depr_h=""
              in_unrec=0; unrec_found=0; unrec_rows=0; unrec_heading="" }
      { low=tolower($0) }

      # ── Canonical section headings ────────────────────────────────────────────
      # Recognised without a WARN. Numbered form widened to allow trailing text
      # (e.g. "for the next version …"). RSDD_RETRO_GRAMMAR_CANONICAL_ANCHOR
      low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/ ||
      low ~ /^## proposed delta/                                      ||
      low ~ /^## delta proposals/                                     ||
      low ~ /^## deltas nuevos/                                       { in_sec=1; in_unrec=0; found=1; next }

      # ── Deprecated alias headings (#436) ──────────────────────────────────────
      # Accepted + WARN-migrate unconditionally. RSDD_RETRO_GRAMMAR_DEPR_ANCHOR
      low ~ /^## summary of proposed delta/                           ||
      low ~ /^## summary of new deltas/                               ||
      low ~ /^## delta details([[:space:]]|$)/                        { in_sec=1; in_unrec=0; found=1; if (!depr_h) depr_h=$0; next }

      # ── Other level-2 headings (### sub-sections stay in active scope) ────────
      /^##[^#]/ {
        in_sec=0
        if (!found) {
          # Form-3 counting: ## Delta <id> — headings outside canonical section.
          # Used by sweep-retros.sh as a machine-countable alternative form.
          if (low ~ /^## delta / && $0 ~ /—/) { d3++ }
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
