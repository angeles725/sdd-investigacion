#!/usr/bin/env bash
# lint-substitution.sh — kit issue #1121: catch two shell-portability defect
# classes across the toolbelt's own *.sh source (never a target corpus — this
# lints the kit itself, so it is not subject to the §8 propose-never-apply rule
# that governs corpus tools).
#
# A) UNQUOTED bash parameter-substitution replacement operand:
#      var substituted as  NAME/pattern/$repl  or  NAME//pattern/$repl  inside ${...}
#    When $repl is a BARE variable reference (not "$repl"), bash still gives an
#    unescaped '&' inside the replacement text special meaning (it expands to
#    the matched substring) REGARDLESS of whether the whole expansion sits in a
#    quoted context — only quoting the REPLACEMENT OPERAND itself ("$repl")
#    suppresses that. kit issue #1032 (bash 5.1+): an unquoted $repl containing
#    '&&' or '>&2' silently corrupted a mutation-control fixture at the point of
#    substitution. Verified empirically 2026-09-25 (see PR body) — quoting is
#    NOT about outer word-splitting, it changes '&' handling inside the operand.
#
# B) awk interval expression {m,n} inside an embedded awk program. mawk (the
#    default awk on Debian/Ubuntu and other non-GNU systems) does not support
#    POSIX interval expressions without --re-interval, so a heading-depth regex using that
#    exact-count-or-range brace form silently fails to match on those platforms. kit issue
#    #1130 fixed one instance
#    (retro_marker_line's '^ {0,3}<!--' -> '^ ? ? ?<!--') and explicitly
#    deferred lib/retro-grammar.sh:248 (is_dirty_marker's '#{1,6}') to this
#    issue as a separate calibration-scoped work unit (CLAUDE.md §6).
#
# SCOPE DECLARED (§7 "prove the coverage of your own enumerator", re-enumerated for kit issue
# #1142's review — the original version's enumerator was too narrow and certified a live tree
# clean while real sites existed; see the PR body / commit for the exact false-negative writeup):
#   Traversed: every *.sh file under EACH configured root. With no argument (the normal gate
#   usage) that is BOTH research-sdd/toolbelt (this script's own tree) AND research-sdd/install
#   (kit issue #1142 review: install/tests/research-sdd-install.test.sh had a real site), matching
#   CLAUDE.md §5's shellcheck glob scope. An explicit argument scans exactly that one root instead
#   (used by this script's own fixture-based tests).
#   Form A recognised (kit issue #1142 review round 3, finding #1: the previous version only
#   checked whether the replacement operand STARTED with an unquoted $/backtick, and missed a
#   live site — retro-gate.sh:210 — whose operand instead started with a literal escaped
#   backslash and carried the risky expansion later): an UNQUOTED, UNESCAPED $ (not immediately
#   followed by a single-quote — that combination starts a $'...' ANSI-C literal, treated as safe
#   instead) or an UNQUOTED, UNESCAPED backtick, occurring ANYWHERE in the replacement operand,
#   not only at its start. A one-level-nested unquoted {...} group (covers a default-value
#   replacement like ${y:-z}), a $'...' ANSI-C literal, a "..." double-quoted sub-span, and any
#   \X escaped pair are each consumed as ONE safe atomic unit and do not expose their own content
#   to the check — this is what lets a fully-quoted operand ("$repl", "${a:-$b}") stay unflagged
#   while a MIXED operand ("a"$y, or the escaped-backslash-then-bare-$ shape at
#   retro-gate.sh:210) is still caught by the part that truly is unquoted. The name accepted
#   before the pattern/replacement separator is a bare identifier, a pure-digit positional
#   parameter ($1, $12, ...), a special parameter ($@ $* $# $? $! $$ $-), or any of those
#   indirect via a leading '!' (bash's ${!ref...} indirection). The pattern segment tolerates ONE level of nested
#   brace-expansion and any \X escaped pair (covers an escaped slash \/ or an escaped brace \} \{).
#   Form A EXCLUDED (declared per §7, evidence is the #1142 review's own independent character-
#   level enumeration — none of these is currently present in the real toolbelt+install tree):
#   two or more levels of nested brace-expansion in EITHER the pattern or the replacement segment;
#   a quoted slash inside the pattern segment (${s//"/"/$y}) — the first unescaped, unnested '/'
#   is always treated as the pattern/replacement separator, regardless of quoting; a command
#   substitution containing its own internal '/' inside the pattern segment (a command
#   substitution such as printf with a slash argument, used as the pattern to match);
#   and a substitution whose pattern or replacement segment itself spans multiple physical source
#   lines — the lint scans line-by-line (grep -nE), so a literal newline inside either segment is
#   invisible to it. NOT excluded, despite an earlier draft of this header incorrectly saying so
#   (kit issue #1142 review round 3, nit): a bare variable with trailing literal text appended
#   right after it in the replacement (e.g. a suffixed hyphenated word) — only the variable
#   portion needs to be unquoted for the same '&'-in-the-expanded-value risk to apply, so this
#   shape IS flagged, correctly.
#   Form B recognised: an ERE literal delimited by '/' containing a POSIX interval expression
#   '{m,n}', '{m,}', or an exact count '{m}' (kit issue #1142 review: the comma used to be
#   mandatory, missing every exact-count site), where the opening '/' is immediately preceded
#   (ignoring whitespace) by line start, whitespace, '~', '!~', '!', '(' or ',' — covers the
#   original '~ /re/' match operator, a bare pattern '/re/ {...}', a negated bare pattern
#   '!/re/', and a regex literal passed to match()/sub()/gsub()/split(). Scoped to files that
#   reference `awk` at least once anywhere in the file (an awk-consuming script; SENTINEL-AWK-GATE
#   below); this is a heuristic over TEXT, not a real awk-program parser, so a construct matching
#   this shape outside an actual awk program would be a false positive — none observed on the
#   real toolbelt+install tree. Form B EXCLUDED (declared, enumerated against the real tree —
#   none present): an awk STRING regex passed as a plain string literal rather than a /re/
#   literal (e.g. `$0 ~ "#{1,6}"`, `match(s, "x{2}")`), a regex supplied via `-v re=...` on the
#   awk command line, and an awk program held in a shell variable rather than inlined at the call
#   site (checked by hand: lib/retro-grammar.sh's own `_RG_AWK_CANONICAL_FN` variable holds one
#   such program and contains no interval expression today).
#   Not traversed by either form's default (no-argument) invocation: research-sdd/templates/*.sh
#   (the shipped hook scripts) sit outside both default roots. Scanned by hand for the #1142
#   review and found clean; add a third default root here if that ever needs to be automatic.
#
# Exit codes (§7 three-state discipline):
#   0 — scanned successfully, zero violations (no-match) or zero files found across every
#       configured root (empty-input, reported distinctly, not silently equal to no-match)
#   1 — scanned successfully, one or more violations found (findings; this is
#       a hard gate, unlike a propose-never-apply corpus tool — see header)
#   2 — operational failure: EITHER every configured root is missing/not traversable
#       (absent-input; a single missing root among several is only a WARNING and the scan
#       continues on the remaining root(s) — not every caller necessarily has both trees), OR a
#       'find' traversal or a per-file 'grep' read failed mid-scan (kit issue #1142 review round
#       3, finding #2, §7: a real read/traversal error used to be silenced by a bare '2>/dev/null'
#       with the exit status never checked, so an unreadable file or an untraversable
#       subdirectory read as a confident 0-violations pass instead of the DEGRADED state it
#       actually is — the scan fails closed and reports DEGRADED on stderr instead).
#
# Usage: lint-substitution.sh [root-dir]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ROOTS: an explicit argument scans exactly that one root (backward compatible — existing
# fixture-based tests pass a single custom root). With no argument, the default scans BOTH
# research-sdd/toolbelt (this script's own tree) AND research-sdd/install (kit issue #1142
# review finding #2: install/tests/research-sdd-install.test.sh:1026 has a real unquoted
# replacement site, and this lint's coverage should match CLAUDE.md §5's shellcheck glob, which
# already names both trees). research-sdd/install is resolved relative to this script, never
# assumed from the caller's cwd, matching run-all.sh's own kit issue #1126/#1144 convention.
if [[ $# -ge 1 ]]; then
  ROOTS=("$1")
else
  ROOTS=("$SCRIPT_DIR")
  _install_root="$(cd -P "$SCRIPT_DIR/../install" 2>/dev/null && pwd)"  # LINT-CD-PHYSICAL-OK: climbs from SCRIPT_DIR (BASH_SOURCE-derived) via '..'; -P resolves physically so a symlinked toolbelt/ (kit issue #1024) never lands one level off
  if [[ -n "$_install_root" ]]; then
    ROOTS+=("$_install_root")
  else
    echo "lint-substitution: WARNING: default install-tree root ($SCRIPT_DIR/../install) not found; scanning research-sdd/toolbelt only" >&2
  fi
fi

# _lint_scan <pattern> <file> — kit issue #1142 review round 3 (finding #2, §7 anti-silent-zero):
# a per-file grep used to discard both stderr AND the exit code ('2>/dev/null', rc never
# checked), so an unreadable file (grep rc 2) produced empty output — identical to a genuinely
# clean "no violations" file — and read as a confident 0 instead of the DEGRADED state it
# actually is. rc 0 (matched) and rc 1 (no match) are both legitimate scan outcomes; rc >= 2 is
# an operational read failure and fails the WHOLE scan closed (exit 2) rather than silently
# treating that one file as clean. Sets $_LINT_SCAN_OUT (the matching lines, one per line) and
# $_LINT_SCAN_RC for the caller.
_lint_scan() {
  local _pat="$1" _f="$2"
  _LINT_SCAN_OUT="$(grep -nE "$_pat" "$_f" 2>/dev/null)"; _LINT_SCAN_RC=$?
  if [[ "$_LINT_SCAN_RC" -ge 2 ]]; then
    echo "lint-substitution: DEGRADED — grep failed reading '$_f' (exit $_LINT_SCAN_RC); scan invalid, cannot certify NO-MATCH for this file" >&2
    exit 2
  fi
}

_files=()
_roots_absent=0
_roots_scanned=0
for _root in "${ROOTS[@]}"; do
  if [[ ! -d "$_root" ]] || [[ ! -r "$_root" ]] || [[ ! -x "$_root" ]]; then
    _roots_absent=$((_roots_absent + 1))
    echo "lint-substitution: ABSENT-INPUT — root '$_root' is not a readable/traversable directory" >&2
    continue
  fi
  _roots_scanned=$((_roots_scanned + 1))
  # kit issue #1142 review round 3 (finding #2): 'find' used to be piped straight into the
  # while-read loop via process substitution ('2>/dev/null', never checking find's own exit
  # status), so a traversal error partway through (e.g. an unreadable subdirectory) silently
  # certified whatever partial file list find managed to print before failing. Capture find's
  # OWN exit status first (sorting is a separate step specifically so this doesn't become sort's
  # exit status instead) and fail closed on any nonzero.
  _find_out="$(find "$_root" -type f -name '*.sh' 2>&1)"; _find_rc=$?
  if [[ "$_find_rc" -ne 0 ]]; then
    echo "lint-substitution: DEGRADED — 'find' failed under root '$_root' (exit $_find_rc), scan invalid: $_find_out" >&2
    exit 2
  fi
  while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _files+=("$_f")
  done < <(LC_ALL=C sort <<<"$_find_out")
done

if [[ "$_roots_scanned" -eq 0 ]]; then
  # every configured root was absent — an operational failure, not a confident 0 (§7).
  exit 2
fi

if [[ ${#_files[@]} -eq 0 ]]; then
  echo "lint-substitution: EMPTY-INPUT — 0 *.sh files found under ${ROOTS[*]}"
  exit 0
fi

# --- Form A: unquoted replacement operand -----------------------------------
# Match: ${ name [subscript]? /{1,2} pattern / ...X... } where an UNQUOTED, UNESCAPED $ or `
# occurs ANYWHERE in the replacement segment (kit issue #1142 review round 3, finding #1: the
# previous version only checked whether the operand STARTED with $/backtick and missed
# retro-gate.sh:210, whose operand starts with a literal escaped backslash and carries the risky
# expansion later — see the header's SCOPE DECLARED section for the full writeup). Built from
# named sub-patterns for readability; see that section for what each safe/risky class covers.
_lint_name_re='!?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?!$-])'
_lint_subscript_re='(\[[^]]*\])?'
# pattern segment: an escaped pair \X (covers \/  \{  \}), ONE level of nested {...}, or any
# other char that is not '/{}' — the separating '/' is never consumed here except inside an
# escape or a matched nested group.
_lint_pattern_re='(\{[^{}]*\}|\\.|[^/{}])+'
# replacement PREFIX/anywhere safe-unit: consumed WITHOUT exposing an inner '$'/backtick to the
# risk check — a one-level nested {...} group, an escaped pair \X, a $'...' ANSI-C literal, or a
# "..." double-quoted sub-span. Deliberately excludes '$', backtick, backslash and '"' from the
# separate "any other char" bucket below — each of those four has exactly one way to be consumed
# safely (through one of these four alternatives), so there is no ambiguity about whether a given
# '$' was actually escaped or quoted.
_lint_replsafe_re='(\{[^{}]*\}|\\.|\$'"'"'[^'"'"']*'"'"'|"[^"]*")'
_lint_replplain_re='[^}$`\"]'
# the risky trigger itself: an unescaped $ NOT immediately followed by a single-quote (that
# combination starts a $'...' literal, handled by _lint_replsafe_re instead), or a bare backtick.
_lint_repltrigger_re='(\$[^'"'"']|`)'
# SUFFIX (after the trigger has fired): once risk is established, the remainder just needs to
# reach the true closing brace — a wider, unfussy alphabet (anything but '}' and a bare
# backslash, which still routes through the escaped-pair alternative) so a second '$'/backtick
# later in the same operand (e.g. the closing backtick of a command-substitution pair) does not
# block the match from completing.
_lint_replsuffix_re='(\{[^{}]*\}|\\.|[^}\\])'
formA_re="\\\$\\{${_lint_name_re}${_lint_subscript_re}/{1,2}${_lint_pattern_re}/(${_lint_replsafe_re}|${_lint_replplain_re})*${_lint_repltrigger_re}${_lint_replsuffix_re}*\\}"

# --- Form B: awk interval expression inside an ERE literal -----------------
# Match: a `/.../ ` ERE literal containing a POSIX interval expression {m,n} or {m} (exact
# count — the comma is now OPTIONAL, kit issue #1142 review: {40,64} matched before, but a bare
# exact count like {6} did not), where the opening '/' is immediately preceded (ignoring
# whitespace) by one of: line start, whitespace, '~', '!~', '!', '(' or ','. This widens beyond
# the original '~ /.../ '-only match to also catch: a bare awk pattern '/re/ {...}', a negated
# bare pattern '!/re/', and a regex literal passed as a match()/sub()/gsub()/split() argument
# (preceded by '(' or ', '). Still scoped to files that mention `awk` at least once (SENTINEL-AWK-GATE
# below) — this is a heuristic over TEXT, not a real awk-program parser, so a '/.../ ' construct
# outside an actual awk program is a theoretical false positive; none observed on the real tree.
formB_re='(^|[~!(,[:space:]])[[:space:]]*/[^/[:space:]][^/]*\{[0-9]+(,[0-9]*)?\}[^/]*/'

violations=()
files_scanned=0

for f in "${_files[@]}"; do
  files_scanned=$((files_scanned + 1))

  _lint_scan "$formA_re" "$f"
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    violations+=("FORM-A unquoted replacement operand: $f:$hit")
  done <<<"$_LINT_SCAN_OUT"

  # SENTINEL-AWK-GATE
  _lint_scan '(^|[^A-Za-z0-9_])awk([^A-Za-z0-9_]|$)' "$f"
  if [[ "$_LINT_SCAN_RC" -eq 0 ]]; then
    _lint_scan "$formB_re" "$f"
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      violations+=("FORM-B awk interval expression: $f:$hit")
    done <<<"$_LINT_SCAN_OUT"
  fi
done

echo "lint-substitution: scanned $files_scanned file(s) under ${ROOTS[*]}"

if [[ ${#violations[@]} -eq 0 ]]; then
  echo "lint-substitution: NO-MATCH — 0 violations"
  exit 0
fi

echo "lint-substitution: FOUND ${#violations[@]} violation(s):"
for v in "${violations[@]}"; do
  echo "  - $v"
done
exit 1
