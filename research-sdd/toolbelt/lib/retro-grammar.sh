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
#   ## PROPUESTA de deltas al kit[...]  (Spanish accepted alias, #1111 — real fleet form,
#                                        living convention for Spanish-language target corpora,
#                                        not a migration target: no depr WARN)
#
# GRAMMAR — deprecated aliases (#436; accepted + WARN-migrate unconditionally):
#   ## Summary of proposed delta[...]
#   ## Summary of new deltas[...]
#   ## Delta details[...]
#
# GRAMMAR — unrecognised delta-intent headings (verify-retro Rules 1–4; outside grammar):
#   Rule 1: ## [N. ]delta<s>? followed by whitespace, ( or EOL
#   Rule 2: " kit delt" or "-kit-delt"/"-kit delt"/" kit-delt" anywhere (space OR hyphen
#           separated on either side of "kit"), NOT negated by "not" (space or hyphen)
#   Rule 3: "(kit-delta" (parenthetical hyphenated compound)
#   Rule 4 (#1111): standalone "### Proposals" (H3, plural) OUTSIDE any canonical section —
#           real fleet form (niagara-research retro): "### Proposals (propose-never-apply) — …"
#           used as a bespoke delta-intent heading. Gated so it never fires for a "### Proposals"
#           sub-heading legitimately inside an already-recognised canonical section (that path is
#           form-2 territory, a different form, and requires an em-dash to count).
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
  if (low ~ /^## propuesta de deltas al kit([[:space:]]|$)/) return 1
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
          # Rule 2 (#1111 widened): "kit delt"/"kit-delt" — space OR hyphen on either side of
          # "kit" — not negated by "not " / "not-" on either side. Real fleet form: "## B.
          # Campaign-8 kit-delta backlog" (hyphenated, mid-heading, no parens — Rule 3 alone
          # does not catch it because Rule 3 requires a leading "(").
          if (!is_unrec && low ~ /[ -]kit[ -]delt/ && low !~ /not[ -]+kit[ -]+delt/) is_unrec=1
          # Rule 3: parenthetical (kit-delta hyphenated compound
          if (!is_unrec && low ~ /\(kit-delta/) is_unrec=1
          if (is_unrec && !unrec_found) { unrec_found=1; in_unrec=1; unrec_heading=$0 }
          else { in_unrec=0 }
        } else { in_unrec=0 }
        next
      }

      # ── Standalone H3 "Proposals" heading OUTSIDE any canonical section (Rule 4, #1111) ──
      # Real fleet form: "### Proposals (propose-never-apply) — …" (niagara-research retro).
      # Gated on !in_sec so a "### Proposals" sub-heading legitimately inside an already
      # recognised canonical section is left to form-2 counting instead (a different form,
      # requiring an em-dash to count) — see T13 in tests/retro-grammar.test.sh.
      !in_sec && /^###[^#]/ {
        if (!unrec_found && low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) {
          unrec_found=1; unrec_heading=$0
        }
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
# Fail-safe design (§912):
#
# A. PURE canonical section: every non-blank, non-table body line in the canonical
#    section must satisfy is_honesty() after marker stripping.  Fenced blocks, HTML
#    comments, and other non-honesty content all fail this check by construction.
#    An empty-table header+separator (no data rows) is also accepted as an empty body.
#    Exception: the LEADING BLOCKQUOTE BLOCK — contiguous > lines and blank lines
#    immediately after the canonical heading and before any other content — is exempt
#    as template scaffold IF none of its lines contains a structural marker after
#    stripping all leading > levels and normalizing NBSP.  Structural markers are:
#    list bullets (- * + with space), headings (# × 1-6 with space), tables (|),
#    ordered lists (N. or N)), letter-paren lists (a)), Unicode bullets (• – —),
#    and checkboxes ([ ]).  Any such marker marks the entire block as non-scaffold
#    (lead_block_dirty) and all buffered lines fail purity → ~?.
#    Residual risk: a delta written as blockquoted prose without a structural marker
#    would be falsely exempt — the instrument cannot distinguish template guidance
#    prose from delta prose without a structural marker.
#    Documented in METHODOLOGY §18 instrument description.
#
# B. ## Honest verdict (also ## N. Honest verdict): accepted ONLY when the canonical
#    section is absent or its body is empty (no non-blank, non-table lines).
#    Non-honesty canonical content blocks the HV path.
#
# C. Honesty line matching: strip leading whitespace and list/blockquote/emphasis
#    markers (- * + > ** __ _) then match one of the exact §18 accepted variants
#    (see METHODOLOGY §18 "Accepted honesty-line variants").  Any other trailing
#    text after "no new deltas" is NOT a conforming honesty line.
#
# D. Veto: any of the following indicators anywhere in the file force exit 1.
#    - WARN-B (##): non-canonical ## Proposed/Delta/Deltas headings.
#    - H2 delta-ID: ## [A-Za-z][0-9]+ headings outside the canonical section
#      (e.g. ## D1, ## D11).  Bare ## N. numeric headings are NOT vetoed — 9 fleet
#      retros use them for structural sections (## 6. Proposed kit deltas etc.).
#    - WARN-B (#/###): letter+digit or H1 bare-digit ID headings, and ###
#      Proposed/Delta/Deltas headings.  Note: ### N. bare-digit headings (e.g.
#      ### 1. Fast loop) are NOT vetoed — fleet retros use them structurally.
#    All use the shared is_canonical_heading() from _RG_AWK_CANONICAL_FN.
#    Note: the veto patterns here are a SUPERSET of the sweep-retros WARN-B greps;
#    the H2 delta-ID rule has no parallel in sweep-retros.
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
      # is_honesty: exact §18 accepted-variant matching (§912-R MAJOR-4 fix).
      # Only the tails listed below are conforming; any other trailing text after
      # "no new deltas" is rejected.  Add new forms here AND in METHODOLOGY §18
      # "Accepted honesty-line variants" table.
      # Em-dash U+2014 UTF-8 = \xe2\x80\x94 = octal \342\200\224.
      function is_honesty(raw,    s, l) {
        s = strip_markers(raw)
        l = tolower(s)
        sub(/[[:space:]]+$/, "", l)          # strip trailing whitespace
        # strip trailing emphasis markers (e.g. "...run.**" from "**no new deltas…**")
        sub(/\*\*$/, "", l); sub(/__$/, "", l); sub(/_$/, "", l)
        sub(/[[:space:]]+$/, "", l)          # re-strip any remaining trailing whitespace
        if (l == "no new deltas; the kit already covers this run.") return 1
        if (l == "no new deltas; nothing to add.")                  return 1
        if (l == "no new deltas \342\200\224 the kit already covers this run.") return 1
        if (l == "no new deltas \342\200\224 nothing to add.")       return 1
        return 0
      }

      # is_dirty_marker: returns 1 when a lead-block line carries a structural
      # list/table/heading marker, indicating it is a delta row, not guidance prose.
      # Input: raw line from the file (may start with one or more > levels).
      # Strips ALL leading > levels (nested blockquotes) and normalizes UTF-8 NBSP
      # (\xc2\xa0 = octal \302\240) to space before checking.
      function is_dirty_marker(raw,    _r) {   # RSDD_IS_DIRTY_MARKER_FN
        _r = raw
        # Normalize UTF-8 NBSP (\xc2\xa0) to regular space.
        gsub(/\302\240/, " ", _r)
        # Strip ALL leading > levels (handles nested blockquotes like "> > - item").
        while (_r ~ /^>/) sub(/^>[[:space:]]*/, "", _r)
        # Strip remaining leading whitespace.
        sub(/^[[:space:]]+/, "", _r)
        # List bullet: - * + with trailing space (requires space; ** bold is NOT a bullet).
        if (_r ~ /^[-*+][[:space:]]/) return 1    # RSDD_DIRTY_BULLET
        # Heading: one to six # with trailing space.
        if (_r ~ /^#{1,6}[[:space:]]/) return 1   # RSDD_DIRTY_HASH
        # Table: starts with |.
        if (_r ~ /^\|/) return 1
        # Ordered list: digits followed by . or ) and space or end-of-line.
        if (_r ~ /^[0-9]+[.)]([[:space:]]|$)/) return 1    # RSDD_DIRTY_NUMLIST
        # Letter-paren list: a) b) etc.
        if (_r ~ /^[a-zA-Z][)]([[:space:]]|$)/) return 1
        # Unicode bullet glyphs: only • (U+2022, \342\200\242) is unambiguously a list marker.
        # Em dash (— U+2014 \342\200\224) and en dash (– U+2013 \342\200\223) are deliberately
        # excluded: they appear legitimately as sentence-continuation characters at the START of
        # a lead-block line when long sentences word-wrap (see retro.template.md line starting
        # with "> — see §18…").  Including them produces false positives on real templates.
        # Known residual: "> — delta text" (em/en dash used as a list bullet) is not detected.
        if (_r ~ /^\342\200\242/) return 1   # • (U+2022)
        # Checkbox: [ ] [x] [X]
        if (_r ~ /^\[[ xX]\]([[:space:]]|$)/) return 1
        return 0
      }

      BEGIN {
        in_canonical  = 0; in_hv = 0
        canonical_found = 0
        # Canonical body purity tracking
        body_count   = 0   # non-blank, non-table body lines (after lead block)
        body_ok      = 1   # 1 while all body_count lines satisfy is_honesty()
        body_pipe    = 0   # non-separator | rows
        body_started = 0   # set once the lead block phase ends
        # HV body
        hv_honesty = 0
        # Veto: WARN-B or H2 delta-ID indicator anywhere in file
        veto = 0
        # Leading blockquote block (lead block): contiguous > lines + blanks immediately
        # after the canonical heading and before any other content.  Exempt if none of
        # its lines (after full > stripping and NBSP normalization) carries a structural
        # marker.  Fail-safe: any marker → lead_block_dirty=1 → all buffered lines fail.
        lead_block_dirty = 0   # 1 when any buffered > line has a structural marker
        lead_buf_n       = 0   # number of buffered > lines
      }

      { low = tolower($0) }

      # ── Section transitions and veto detection (D) ──────────────────────────
      /^##[^#]/ {
        if (is_canonical_heading(low)) {
          in_canonical = 1; in_hv = 0; canonical_found = 1; next
        }
        in_canonical = 0; in_hv = 0
        # ## Honest verdict — also accept ## N. Honest verdict (fleet retros use numbered headings).
        if (low ~ /^## ([0-9]+\. )?honest verdict([[:space:]]|$)/) { in_hv = 1 }
        # Veto: non-canonical ## Proposed/Delta/Deltas headings (mirrors sweep-retros WARN-B).
        if (!is_canonical_heading(low) && low ~ /^## (proposed|delta|deltas)([[:space:]]|$)/) veto = 1
        # H2 delta-ID veto: ## D1 / ## D11 headings outside the canonical section.
        # NOTE: bare ## N. headings (numeric-only, e.g. ## 6. Proposed kit deltas) are NOT
        # vetoed — 9 fleet retros use them for structural sections.  This pattern requires
        # at least one ASCII letter before the digit(s).
        if (!is_canonical_heading(low) && $0 ~ /^## [A-Za-z][0-9]+([^a-zA-Z0-9]|$)/) veto = 1  # RSDD_H2_VETO
        next
      }

      # ── WARN-B veto: ID-pattern and Proposed/Delta/Deltas headings outside canonical ──────
      # Handles # (H1) and ### (H3); ## is handled (with next) in /^##[^#]/ above.
      # Explicit alternatives replace interval expressions for mawk compatibility.
      !in_canonical && /^#/ {
        # ### Proposed/Delta/Deltas
        if (low ~ /^###[[:space:]]+(proposed|delta|deltas)([[:space:]]|$)/) veto = 1
        # letter+digit ID headings at H1 and H3 (e.g. # D1, ### D1).
        # NOTE: ### N. bare-digit headings (e.g. ### 1. Fast loop) are NOT vetoed —
        # fleet retros use them for structural sub-sections.
        if ($0 ~ /^#[[:space:]]+[A-Za-z][0-9]/ || $0 ~ /^###[[:space:]]+[A-Za-z][0-9]/) veto = 1
        # H1 bare-digit (# 1 …) is unusual enough in retro context to veto.
        if ($0 ~ /^#[[:space:]]+[0-9]/) veto = 1
        next
      }

      # ── Canonical body purity check (A) ──────────────────────────────────────
      in_canonical {
        if ($0 ~ /^[[:space:]]*$/) next
        if (!body_started) {
          # Lead block phase: buffer non-honesty > lines; structural marker taints block.
          if (/^>/ && !is_honesty($0)) {
            if (is_dirty_marker($0)) lead_block_dirty = 1  # RSDD_LEAD_DIRTY_SET
            lead_buf[++lead_buf_n] = $0; next
          }
          # First non-blank non-> content (or > honesty line): end of lead block.
          body_started = 1
          if (lead_block_dirty) {
            for (_i = 1; _i <= lead_buf_n; _i++) {
              body_count++
              if (!is_honesty(lead_buf[_i])) body_ok = 0
            }
          }
          # Fall through to process current line.
        }
        if (/^\|/) {
          if ($0 !~ /^\|[-: |]+\|?[[:space:]]*$/) body_pipe++
          next
        }
        body_count++
        if (!is_honesty($0)) body_ok = 0
        next
      }

      # ── HV body analysis (B) ─────────────────────────────────────────────────
      in_hv {
        if ($0 ~ /^[[:space:]]*$/) next
        if (is_honesty($0)) hv_honesty = 1
        next
      }

      END {
        if (veto) { exit 1 }
        # Flush dirty lead block if canonical ended without non-blockquote content.
        # RSDD_LEAD_BLOCK_END_FLUSH_ANCHOR
        if (canonical_found && !body_started && lead_block_dirty) {
          for (_i = 1; _i <= lead_buf_n; _i++) {
            body_count++
            if (!is_honesty(lead_buf[_i])) body_ok = 0
          }
        }
        # Data rows = max(0, non-separator pipe rows - 1)
        body_data = (body_pipe > 1) ? body_pipe - 1 : 0

        if (canonical_found) {
          if (body_data > 0) { exit 1 }
          # All non-table body lines are honesty (at least one present)
          if (body_count > 0 && body_ok) { exit 0 }
          # Empty canonical body → HV path (B)
          if (body_count == 0) {
            if (hv_honesty) { exit 0 }
          }
          exit 1
        } else {
          if (hv_honesty) { exit 0 }
          exit 1
        }
      }
    ' "$1"
  }
fi
