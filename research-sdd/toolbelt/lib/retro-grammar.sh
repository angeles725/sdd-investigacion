#!/usr/bin/env bash
# retro-grammar.sh — shared delta-heading grammar for §18 retrospective analysis.
# Single source of truth for: canonical heading recognition, deprecated-alias recognition,
# table-row counting, and unrecognised-heading detection (Rules 1–4). Sourced by
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
#   Rule 4 (#1111): standalone "### Proposal[s]" (H3, singular or plural — the regex is
#           `proposals?`) OUTSIDE any canonical section —
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

# ─── Delta-ID rule shared by every parser of table rows and `## Delta <ID> —` headings ─────────
# rg_delta_id(tok): 1 when <tok> is a delta id written in capitals: one capital letter (`A`), or at most 8
# characters of capitals/digits that carry a digit or a hyphen (`R1`, `SO2`, `SPKI-A`). A bare multi-letter
# word (`ID`, `DELTA`, `TOTAL`, `RATIONALE`) is NOT an id. rg_table_id_skip(rid): 1 when a table row's first
# cell is a header word or separator debris and not a row id; digit-bearing cells (`1`, `D1`, `B12`) were never
# skipped. ONE rule for stage-retro-issues.sh, reconcile-issues.sh and the `## Delta` form (kit issue #1934
# #1938: `SPKI-A` was dropped by the old per-tool guard). A header row is additionally dropped by position (the
# row directly above a separator), so an upper-case hyphenated header cell (`ITEM-ID`) never becomes a delta.
_RG_AWK_ID_FN='
function rg_delta_id(tok) {
  if (tok !~ /^[A-Z][A-Z0-9]*(-[A-Z0-9]+)?$/) return 0
  if (length(tok) > 8) return 0
  if (tok !~ /[0-9-]/ && length(tok) > 1) return 0
  return 1
}
function rg_table_id_skip(rid) {
  if (rid ~ /^[-:]+$/) return 1
  if (rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/ && !rg_delta_id(rid)) return 1
  return 0
}
'

# ─── retro_grammar_defenced <file> ───────────────────────────────────────────
# Prints the file WITHOUT its fenced code blocks (kit issues #1356 item 1, #1369 b): a
# `### D99 —` entry, a `**Priority**` field or a `## Proposed kit deltas` heading written inside a
# fenced EXAMPLE is documentation, not a delta. ONE implementation shared by delta_info,
# entry_rows, stage-retro-issues.sh and reconcile-issues.sh so every consumer counts the same lines.
# CommonMark fence rules (the same ones lib/retro-status.sh applies to markers):
#   - a fence OPENS on 3+ backticks or tildes, indented at most 3 spaces; a backtick opener whose
#     info string contains a backtick is inline code, not a fence;
#   - a line indented 4+ spaces (or by a tab) is INDENTED CODE: it neither opens nor closes a fence;
#   - it CLOSES only on a line of the SAME character, at least as long as the opener, with nothing
#     but whitespace after it (a trailing CR is tolerated: CRLF files);
#   - RETRO_GRAMMAR_FENCE_UNCLOSED: a fence still open at EOF is NOT treated as a fence. Dropping
#     everything after a stray opener would turn real entries into a silent zero; keeping them is
#     the pre-existing behaviour and errs toward a visible count. It is NOT silent: one
#     `WARN: unclosed code fence opened at line N in <file> — treated as text` line goes to STDERR
#     (never stdout, so no consumer's parsing changes). A run calls this helper several times on the
#     same file; every consumer's FIRST call (delta_info) speaks and the secondary calls set
#     _RG_QUIET_FENCE=1 so the line is not repeated.
# Two passes over the same file (awk reads it twice): pass 1 records the line numbers of every
# CLOSED fence (opener through closer inclusive), pass 2 prints the remaining lines. Run lengths are
# counted with a plain loop (no POSIX interval expressions: mawk portability, kit issue #1130).
# Returns 1 (no output) when the file is absent/unreadable - never an empty success.
if ! typeset -f retro_grammar_defenced >/dev/null 2>&1; then
  retro_grammar_defenced() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _RG_FENCE_FILE="$f" awk '
      function runlen(s, c,    n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
      function indent(s,    n, c) {
        n = 0
        while ((c = substr(s, n + 1, 1)) == " ") n++
        if (c == "\t") n += 4
        return n
      }
      FNR == NR {
        if (indent($0) >= 4) next          # RETRO_GRAMMAR_FENCE_INDENT: indented code, never a fence line
        s = $0; sub(/^ +/, "", s)
        c = substr(s, 1, 1)
        if (!open) {
          if (c == "`" || c == "~") {
            n = runlen(s, c); rest = substr(s, n + 1)
            if (n >= 3 && !(c == "`" && index(rest, "`") > 0)) { open = 1; fch = c; flen = n; ostart = FNR }
          }
          next
        }
        if (c == fch) {
          n = runlen(s, c); rest = substr(s, n + 1)
          if (n >= flen && rest ~ /^[ \t\r]*$/) {   # RETRO_GRAMMAR_FENCE_CLOSER (CR tolerated: CRLF files)
            for (k = ostart; k <= FNR; k++) skip[k] = 1
            open = 0
          }
        }
        next
      }
      !(FNR in skip) { print }
      END {
        if (open && ENVIRON["_RG_QUIET_FENCE"] != "1")   # RETRO_GRAMMAR_FENCE_UNCLOSED_WARN
          printf "WARN: unclosed code fence opened at line %d in %s \342\200\224 treated as text\n", ostart, ENVIRON["_RG_FENCE_FILE"] | "cat 1>&2"
      }
    ' "$f" "$f"
  }
fi

# Idempotent: safe to source more than once.
# typeset -f is used instead of declare -F: both work in bash (typeset is an alias for declare),
# while declare -F in zsh means "declare as float" (always exits 0), so sourcing from zsh with
# the declare -F guard would never define the function (#903).
if ! typeset -f retro_grammar_delta_info >/dev/null 2>&1; then

  retro_grammar_delta_info() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || { printf '0:n:0\001\0010\0010\001\n'; return 0; }
    # RETRO_GRAMMAR_UNREADABLE: an existing but unreadable file is NOT an empty one. The defenced
    # stream would be empty and the awk below would report "no delta section" - a silent zero. Say so
    # on stderr and fail (the zero-shaped line keeps legacy parsers parseable; the exit status and the
    # typed message are what distinguish it).
    if [ ! -r "$f" ]; then
      echo "retro-grammar: cannot read $f (unreadable) — delta count is UNKNOWN, not zero" >&2
      printf '0:n:0\001\0010\0010\001\n'
      return 1
    fi
    retro_grammar_defenced "$f" | awk "$_RG_AWK_CANONICAL_FN"'
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
          # Unrecognised delta-intent heading detection (verify-retro Rules 1–3; Rule 4 lives
          # in the standalone-H3 block below, since it fires on a different line shape).
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
    '
  }

fi

# ─── retro_grammar_entry_rows / _ids / _warn ──────────────────────────────────
# The delta-ENTRY form (sweep-retros form 2, METHODOLOGY §18): under the canonical section, a
# `###` heading carrying an em-dash — `### D1 — title` — is one delta; its `**Label**: value`
# lines (same line only) are its fields. ONE parser (retro_grammar_entry_rows) feeds both
# consumers: reconcile-issues.sh (IDs) and stage-retro-issues.sh (seeding), kit issue #1332.
#
# retro_grammar_entry_rows <file>
#   One record per entry, fields separated by \037 in the SAME order as a canonical table row
#   (id, change, target, evidence, type, priority) so stage-retro-issues.sh can feed it straight
#   to its row loop:
#     id        first token of the heading text before the dash, minus trailing `.`/`:`
#               (`### D2. — x` -> `D2`); an entry whose token is not [A-Za-z0-9][A-Za-z0-9_-]*
#               (`**D1**`, `[D1]`) is NOT emitted (see retro_grammar_entry_warn)
#     change    the heading text after the dash (the title)
#     target    first of `**Where in kit**` / `**Kit file …**` / `**Target…**` (else empty)
#     evidence  first `**…Evidence…**` line (else empty)
#     type      always empty (entries carry none)
#     priority  first word of the `**Priority**` line (e.g. `MEDIUM — fires…` -> `MEDIUM`)
#   Field lines end at the next `###`/`##` heading, so a later heading's `**Priority**` never
#   bleeds into the previous entry. Same heading aliases as delta_info (is_canonical_heading).
#   Returns 1 (no output) when the file is absent/unreadable — never an empty success.
if ! typeset -f retro_grammar_entry_rows >/dev/null 2>&1; then
  retro_grammar_entry_rows() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _RG_QUIET_FENCE=1 retro_grammar_defenced "$f" | awk "$_RG_AWK_CANONICAL_FN"'
      function flush() {
        if (pr == "") pr = hp   # RETRO_GRAMMAR_HEADING_PRIORITY fallback: the body **Priority** always wins
        if (have) printf "%s\037%s\037%s\037%s\037\037%s\n", id, title, tg, ev, pr
        have=0
      }
      # heading_prio: a parenthetical of the heading made ONLY of the words new, priority, high,
      # medium, low (any case, separated by commas, colons or spaces) and carrying a level yields
      # that level as written. (low-risk change) and (medium confidence) carry other words: ignored.
      # A BARE (low) / (medium) / (high) IS a priority: intentional, pinned by test T39.
      function heading_prio(h,    rest, p, q, inner, n, k, w, tok, lvl, ok, lt) {
        rest = h
        while ((p = index(rest, "(")) > 0) {
          rest = substr(rest, p + 1); q = index(rest, ")")
          if (q == 0) break
          inner = substr(rest, 1, q - 1); rest = substr(rest, q + 1)
          n = split(inner, w, /[,;:[:space:]]+/); lvl = ""; ok = 1
          for (k = 1; k <= n; k++) {
            tok = w[k]; if (tok == "") continue
            lt = tolower(tok)
            if (lt == "high" || lt == "medium" || lt == "low") { if (lvl == "") lvl = tok }
            else if (lt != "new" && lt != "priority") ok = 0
          }
          if (ok && lvl != "") return lvl
        }
        return ""
      }
      BEGIN { in_sec=0; have=0 }
      { low=tolower($0) }
      is_canonical_heading(low) { flush(); in_sec=1; next }
      /^##[^#]/                 { flush(); in_sec=0; next }
      in_sec && /^###[^#]/ {
        flush()
        if ($0 !~ /—/) next
        t=$0; sub(/^###[[:space:]]*/, "", t)
        d=index(t, "—"); if (d == 0) next
        title=substr(t, d + length("—")); sub(/^[[:space:]]+/, "", title); sub(/[[:space:]]+$/, "", title)
        t=substr(t, 1, d-1)
        sub(/[[:space:]]+$/, "", t)
        split(t, w, /[[:space:]]+/)
        id=w[1]; sub(/[.:]+$/, "", id)
        if (id ~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) { have=1; if (title == "") title=id; tg=""; ev=""; pr=""; hp=heading_prio($0) }
        next
      }
      in_sec && have && match($0, /^\*\*[^*]+\*\*/) {
        nm=tolower(substr($0, 3, RLENGTH - 4)); sub(/[:.[:space:]]+$/, "", nm)
        rest=substr($0, RLENGTH + 1); sub(/^[[:space:]]*:?[[:space:]]*/, "", rest); sub(/[[:space:]]+$/, "", rest)
        if (nm ~ /^priority/ && pr == "") { split(rest, pw, /[[:space:]]+/); pr=pw[1]; gsub(/[^A-Za-z]/, "", pr) }
        else if (nm ~ /^(where in kit|kit file|target)/ && tg == "") tg=rest
        else if (nm ~ /evidence/ && ev == "") ev=rest
      }
      END { flush() }
    '
  }
fi

# retro_grammar_entry_ids <file> — the first column of retro_grammar_entry_rows, one ID per line
# (kit issue #1332 item 2: reconcile-issues.sh read only table rows and called an applied
# entry-form retro `unclassifiable` while the seeder said `no-match`).
if ! typeset -f retro_grammar_entry_ids >/dev/null 2>&1; then
  retro_grammar_entry_ids() {
    local out
    out="$(retro_grammar_entry_rows "${1:-}")" || return 1
    [ -n "$out" ] && printf '%s\n' "$out" | cut -d $'\037' -f1
    return 0
  }
fi

# retro_grammar_entry_warn <file> — kit issue #1332 N6. Prints ONE `WARN:` line (nothing otherwise)
# when delta_info counts more form-2 entries than retro_grammar_entry_rows yields IDs for: an entry
# headed `### **D1** —` or `### [D1] —` is counted by sweep-retros but cannot be tracked or seeded
# here — a latent false negative the consumers must surface, not hide.
if ! typeset -f retro_grammar_entry_warn >/dev/null 2>&1; then
  retro_grammar_entry_warn() {
    local f="${1:-}" info form cnt n rest
    info="$(_RG_QUIET_FENCE=1 retro_grammar_delta_info "$f")"
    info="${info%%$'\001'*}"                 # found:form:count
    rest="${info#*:}"; form="${rest%%:*}"; cnt="${rest##*:}"
    [ "$form" = "2" ] || return 0
    n="$(retro_grammar_entry_ids "$f" | wc -l | tr -d ' ')"
    if [ "$n" -lt "$cnt" ]; then
      printf "WARN: %s: only %s of %s '### … —' entries have a usable ID token (a '**D1**' or '[D1]' token is not trackable) — count by hand\n" \
        "$(basename "$f")" "$n" "$cnt"
    fi
    return 0
  }
fi

# ─── retro_grammar_alt_entry_rows ─────────────────────────────────────────────
# The delta forms real fleet retros use that are neither a row table nor a `### D<N> —` entry (kit issues
# #1895 #1932 #1933 #1934 #1938 #1939; measured on the 243-retro fleet). Consulted by stage-retro-issues.sh and
# reconcile-issues.sh ONLY after the table and `### D<N> —` forms yielded nothing, so a canonical retro never
# changes reading. Three forms, nothing else:
#   1. NUMBERED ITEMS (`1. **Title.** prose`, also `1)`) at column 0 directly under a canonical delta heading
#      (is_canonical_heading), before any `###` sub-heading — id is the item number, title the leading bold
#      span (else the first sentence), evidence the rest of that first line, target the text after a
#      `PROPOSED ` marker on a later line of the item (up to the first `:`).
#   2. The same numbered items under a `### Proposals …` H3 (inside a canonical section or not). The H3 ends at
#      the next `##`/`###` heading.
#   3. `## Delta <ID> — [HIGH|MED|MEDIUM|LOW —] title` H2 entries outside a canonical section (sweep-retros
#      form 3). <ID> follows rg_delta_id (below). MED is normalised to MEDIUM (the seeder's priority map knows
#      only the full word).
# Any other `###` heading inside a canonical section (`### Considered and rejected`, `### Evidence`) ENDS the
# item scope: a numbered list under it is not a delta list. Bullets (`- **Lesson:**`), a numbered list under any
# other heading (`## Evidence`, `## What happened`) and a `## Kit-delta proposals` section holding prose are
# deliberately NOT forms: they stay typed unclassifiable in the consumers.
# Title rules: a sentence ends at ". " followed by a non-lowercase character and not after an abbreviation
# (`e.g.`, `i.e.`, `etc.`, a single letter); the title is capped at 100 bytes on a character boundary (the
# awk runs in the C locale and never splits a UTF-8 sequence) and the cut-off text moves to the evidence
# (capped at 300); an unclosed `**` is plain text.
# Output: one record per item, \037-separated, the same shape as retro_grammar_entry_rows
# (id, change, target, evidence, type, priority). With a second argument `heads` the output is instead the
# raw source heading line of every group that produced at least one item (one per line, in file order) — the
# consumers use it to tell a proposal-like heading that produced items from one that produced none.
# Returns 1 (no output) for an absent/unreadable file. Duplicate ids across two lists are NOT resolved here:
# consumers check retro_grammar_dup_ids and type the retro unclassifiable (a signature is keyed on the id).
if ! typeset -f retro_grammar_alt_entry_rows >/dev/null 2>&1; then
  retro_grammar_alt_entry_rows() {
    local f="${1:-}" want="${2:-rows}"
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _RG_QUIET_FENCE=1 retro_grammar_defenced "$f" | LC_ALL=C awk -v want="$want" "$_RG_AWK_CANONICAL_FN$_RG_AWK_ID_FN"'
      function flush() {
        if (have) {
          if (want == "heads") { if (!(src in shown)) { shown[src] = 1; print src } }   # ALT_HEADS_UNIQ
          else printf "%s\037%s\037%s\037%s\037\037%s\n", id, title, tg, ev, pr
        }
        have=0
      }
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      # cut_at(s, n): the largest k <= n that does not split a UTF-8 sequence (C locale: bytes)
      function cut_at(s, n,    k) {
        if (length(s) <= n) return length(s)
        k = n
        while (k > 0 && substr(s, k + 1, 1) ~ /[\200-\277]/) k--   # ALT_CUT_BACKOFF
        return (k > 0) ? k : n
      }
      # sentence_end(t): position of the "." ending the first sentence, 0 when there is none
      function sentence_end(t,    off, r, p, pos, nxt, w, skip) {
        off = 0; r = t
        while ((p = index(r, ". ")) > 0) {
          pos = off + p; nxt = substr(t, pos + 2, 1)
          w = substr(t, 1, pos - 1); sub(/^.*[[:space:]]/, "", w)
          skip = 0
          if (nxt ~ /[a-z]/) skip = 1   # ALT_SENT_LOWER: a lower-case word continues the sentence
          if (tolower(w) ~ /^(e\.g|i\.e|etc|vs|cf|approx|incl)$/ || w ~ /^[A-Za-z]$/) skip = 1   # ALT_SENT_ABBREV
          if (!skip) return pos
          off = pos + 1; r = substr(t, off + 1)
        }
        return 0
      }
      function start_item(n, text,    t, u, p, e, rest, k) {
        flush(); id=n; tg=""; ev=""; pr=""; rest=""
        t=trim(text)
        if (t ~ /^\*\*/) {
          u=substr(t, 3); p=index(u, "**")
          if (p > 0) { rest=substr(u, p + 2); t=substr(u, 1, p - 1) }
          else t=u     # unclosed bold: plain text
        }
        if (rest == "") {
          e=sentence_end(t)
          if (e > 0) { rest=substr(t, e + 2); t=substr(t, 1, e - 1) }
        }
        if (length(t) > 100) { k=cut_at(t, 100); rest=substr(t, k + 1) " " rest; t=substr(t, 1, k) }   # ALT_TITLE_CAP
        sub(/[.:[:space:]]+$/, "", t)   # ALT_TITLE_STRIP
        title=trim(t); ev=trim(rest)
        if (length(ev) > 300) { k=cut_at(ev, 297); ev=substr(ev, 1, k) "..." }
        have=(title != "")
      }
      BEGIN { mode=""; have=0; blank=0; src="" }
      { low=tolower($0) }
      is_canonical_heading(low) { flush(); mode="canon"; src=$0; next }
      /^##[^#]/ {
        flush(); mode=""
        if (low ~ /^## delta /) {   # ALT_H2_DELTA
          t=$0; sub(/^## [Dd]elta +/, "", t)
          d=index(t, "—")
          if (d > 0) {
            tok=trim(substr(t, 1, d - 1))
            if (rg_delta_id(tok)) {
              rest=trim(substr(t, d + length("—"))); pr=""; title=rest
              p=index(rest, " — ")
              if (p > 0) {
                lv=toupper(trim(substr(rest, 1, p - 1)))
                if (lv ~ /^(HIGH|MEDIUM|MED|LOW)$/) {
                  pr=lv; title=trim(substr(rest, p + length(" — ")))
                  if (pr == "MED") pr = "MEDIUM"   # ALT_PRIORITY_MED
                }
              }
              id=tok; tg=""; ev=""; have=(title != ""); src=$0
              mode="h2d"
            }
          }
        }
        next
      }
      /^###[^#]/ {
        if (mode == "h2d") next
        flush(); mode=""   # ALT_H3_RESET: any other ### ends the item scope
        if (low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) { mode="h3"; src=$0 }   # ALT_H3_PROPOSALS
        next
      }
      /^[[:space:]]*$/ { blank=1; next }
      mode == "canon" || mode == "h3" {   # ALT_NUMBERED_GATE
        if (match($0, /^[0-9]+[.)][[:space:]]+/)) {   # ALT_NUMBERED_ITEM
          n=substr($0, 1, RLENGTH); sub(/[.)][[:space:]]+$/, "", n)
          start_item(n, substr($0, RLENGTH + 1)); blank=0; next
        }
        if (have && blank && $0 !~ /^[[:space:]]/) flush()   # ALT_BLANK_FLUSH
        if (have && tg == "" && (p=index($0, "PROPOSED ")) > 0) {   # ALT_PROPOSED_TARGET
          t=substr($0, p + 9); q=index(t, ":")
          if (q > 0 && q <= 120) tg=trim(substr(t, 1, q - 1))
        }
        blank=0; next
      }
      { blank=0 }
      END { flush() }
    '
  }
fi

# retro_grammar_canonical_heading <file> — the FIRST canonical delta heading line (is_canonical_heading, the one
# matcher every instrument shares), or nothing when the file has none. Consumers use it to ask "did THE
# canonical heading produce items?" instead of guessing it with a looser grep (kit issue #1895 round 2).
# pipefail-audit: defenced | awk reads to EOF (a flag, no early exit). SAFE. Returns 1 for an absent/unreadable file.
if ! typeset -f retro_grammar_canonical_heading >/dev/null 2>&1; then
  retro_grammar_canonical_heading() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _RG_QUIET_FENCE=1 retro_grammar_defenced "$f" | awk "$_RG_AWK_CANONICAL_FN"'
      !done && is_canonical_heading(tolower($0)) { print; done = 1 }
    '
  }
fi

# retro_grammar_unrec_headings <file> — EVERY unrecognised delta-intent heading, one raw line each, in file
# order: the Rule 1-3 `##` headings and the Rule 4 standalone `### Proposals` of retro_grammar_delta_info, which
# reports only the FIRST (its field 5). For a file with NO canonical heading (the only case delta_info
# evaluates them) the first line of this list IS delta_info's field 5; tests pin that parity. Consumers require
# each of these headings to have produced items, so a list first and a prose heading second cannot hide the
# prose one (METHODOLOGY section 18: a heading that produces no items stays unclassifiable).
# pipefail-audit: defenced | awk reads to EOF. SAFE. Returns 1 for an absent/unreadable file.
if ! typeset -f retro_grammar_unrec_headings >/dev/null 2>&1; then
  retro_grammar_unrec_headings() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _RG_QUIET_FENCE=1 retro_grammar_defenced "$f" | awk "$_RG_AWK_CANONICAL_FN"'
      { low = tolower($0) }
      is_canonical_heading(low) { in_sec = 1; next }
      /^##[^#]/ {
        in_sec = 0
        u = 0
        if (low ~ /^## [0-9. ]*deltas?([[:space:]]|[(]|$)/) u = 1
        if (!u && low ~ /[ -]kit[ -]delt/ && low !~ /not[ -]+kit[ -]+delt/) u = 1
        if (!u && low ~ /\(kit-delta/) u = 1
        if (u) print
        next
      }
      !in_sec && /^###[^#]/ {
        if (low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) print
        next
      }
    '
  }
fi

# retro_grammar_dup_ids — reads item ids on stdin (one per line), prints the ids that occur more than once.
# A numbered list restarts at 1, so two lists under one retro collide on the id and the issue signature
# (keyed on the id) would silently merge them; the consumers type such a retro unclassifiable instead.
if ! typeset -f retro_grammar_dup_ids >/dev/null 2>&1; then
  retro_grammar_dup_ids() { sort | uniq -d; }
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
        # Heading: one to six # with trailing space. Written as explicit chained ?
        # (not an exact-count-or-range brace interval form) for mawk portability --
        # mawk lacks POSIX interval-expression support without --re-interval, same fix family as
        # kit issue #1130 chained-? rewrite of retro_marker_line. kit issue #1121.
        # NOTE: no single-quote chars in this comment block -- this whole function
        # body is one bash single-quoted string (opened earlier); a stray apostrophe
        # here truncates that string and silently corrupts everything after it.
        if (_r ~ /^##?#?#?#?#?[[:space:]]/) return 1   # RSDD_DIRTY_HASH
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

# ---------------------------------------------------------------------------
# Cross-retro row identity (kit issues #1709 slice 2, #1811). reconcile-issues.sh compares a row's TITLE across
# retros; the rule that makes a title an identity lives HERE so it has one home. stage-retro-issues.sh still carries
# its own copy (title_is_unusable / _MIN_TITLE_LEN) until it calls these helpers; tests/retro-grammar.test.sh T52
# extracts that function and requires the same verdict on a title list, and reconcile-issues.test.sh case 47
# requires the same titles from the title-column parser, so a drift in either copy is a red test.

# retro_grammar_title_has_identity <title> - rc 0 when the (already trimmed) title can carry a cross-retro identity:
# not a bare priority/type token (any length, case-insensitive) and at least 12 CHARACTERS. Characters, not bytes,
# whatever the locale: under LC_ALL=C every byte except a UTF-8 continuation byte (0x80-0xBF) starts one character;
# input that is not valid UTF-8 is counted in bytes so it is never undercounted into a false refusal. A missing
# iconv skips the validity probe (the continuation-byte strip is then used for every title), silently: the seeder
# owns the NOTE about it.
if ! typeset -f retro_grammar_title_has_identity >/dev/null 2>&1; then
  retro_grammar_title_has_identity() {
    local t _n
    t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$t" in   # RETRO_GRAMMAR_TITLE_TOKEN_CLAUSE
      high|medium|low|feature|bug|fix|bugfix|defect|regression|doc|docs|documentation|doc-fix|docfix) return 1 ;;
    esac
    if ! command -v iconv >/dev/null 2>&1 || printf '%s' "$t" | LC_ALL=C iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
      _n="$(printf '%s' "$t" | LC_ALL=C tr -d '\200-\277' | wc -c)"
    else
      _n="$(printf '%s' "$t" | LC_ALL=C wc -c)"
    fi
    [ "$((_n + 0))" -ge 12 ]   # RETRO_GRAMMAR_TITLE_MIN_LEN
  }
fi

# retro_grammar_row_titles <file> - one "<row-id>\037<title>" line per delta row (table form, else the entry form).
# The title is the delta cell: the column the header names (proposed change / delta / title / gist / ...), else
# column 2, with a leading **bold** unwrapped and the ends trimmed. Mirrors stage-retro-issues.sh's header mapping
# for the TITLE column only. Returns 1 (no output) when the file is absent or unreadable.
if ! typeset -f retro_grammar_row_titles >/dev/null 2>&1; then
  retro_grammar_row_titles() {
    local f="${1:-}" _rows _id _dl _rest
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
    _rows="$(_RG_QUIET_FENCE=1 retro_grammar_defenced "$f" | awk '
      BEGIN { in_sec = 0 }
      {
        low = tolower($0)
        if (low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/ || low ~ /^## proposed delta/ ||
            low ~ /^## delta proposals/ || low ~ /^## deltas nuevos/ || low ~ /^## propuesta de deltas al kit([[:space:]]|$)/ ||
            low ~ /^## summary of proposed delta/ || low ~ /^## summary of new deltas/ || low ~ /^## delta details([[:space:]]|$)/) {
          in_sec = 1; prev = ""; ct = 0; next
        }
        if (/^##[^#]/) { in_sec = 0; next }
        if (in_sec && /^\|[-: |]+\|?[[:space:]]*$/) {
          if (prev != "") {
            hl = tolower(prev)
            sub(/^\|[[:space:]]*/, "", hl); sub(/[[:space:]]*\|[[:space:]]*$/, "", hl)
            hn = split(hl, h, /[[:space:]]*\|[[:space:]]*/)
            ct = 0
            for (k = 2; k <= hn; k++)
              if (!ct && h[k] ~ /^(proposed change|proposed delta|proposal|title|delta|gist|change|rule \/ change|delta propuesto)/) ct = k
          }
          prev = ""; next
        }
        if (in_sec && /^\|/) {
          prev = $0
          line = $0
          sub(/^\|[[:space:]]*/, "", line); sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
          n = split(line, f, /[[:space:]]*\|[[:space:]]*/)
          rid = f[1]; gsub(/[[:space:]]/, "", rid)
          if (rid ~ /^[-:]+$/) next
          if (rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/) next
          printf "%s\037%s\n", f[1], (ct ? f[ct] : (n >= 2 ? f[2] : ""))
        }
      }')"
    [ -n "$_rows" ] || _rows="$(retro_grammar_entry_rows "$f")"
    while IFS=$'\037' read -r _id _dl _rest; do
      _id="${_id#"${_id%%[![:space:]]*}"}"; _id="${_id%"${_id##*[![:space:]]}"}"
      [ -n "$_id" ] || continue
      _dl="$(printf '%s' "$_dl" | sed -E 's/^\*\*([^*]+)\*\*.*/\1/;t;s/^\*\*//;s/\*\*$//')"
      _dl="${_dl#"${_dl%%[![:space:]]*}"}"; _dl="${_dl%"${_dl##*[![:space:]]}"}"
      printf '%s\037%s\n' "$_id" "$_dl"
    done <<<"$_rows"
  }
fi
