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
#   Form A recognised: parameter substitution whose replacement operand starts with an UNQUOTED
#   $ immediately followed by anything OTHER than a single-quote, or an UNQUOTED backtick, right
#   after the separating '/' — covers a bare variable reference, a braced expansion with
#   modifiers (default value, etc.), a command substitution (parenthesised or a legacy backtick),
#   and an array/associative subscript on the substituted variable itself. Pattern and replacement
#   segments each tolerate ONE level of nested brace-expansion and an escaped slash inside the
#   pattern. Form A EXCLUDED (declared, not currently present in the corpus as risk, only as a
#   confirmed-safe shape): an ANSI-C-quoted constant replacement ($ followed immediately by a
#   single-quote, e.g. a literal newline) — its content is a FIXED escape sequence that can never
#   contain '&', and wrapping it in an outer pair of quotes would silently break the ANSI-C
#   quoting itself (that form only takes effect as its own standalone shell word) rather than
#   just being redundantly safe, so quoting it is not the applicable fix; two or more levels of
#   nested brace-expansion inside the replacement; and a replacement that concatenates a bare
#   variable with trailing literal text — the lint flags the UNQUOTED SHAPE, not literal '&'
#   content, matching the issue's fix #1: "quote every replacement operand".
#   Form B recognised: an ERE literal delimited by '/' containing a POSIX interval expression
#   '{m,n}', '{m,}', or an exact count '{m}' (kit issue #1142 review: the comma used to be
#   mandatory, missing every exact-count site), where the opening '/' is immediately preceded
#   (ignoring whitespace) by line start, whitespace, '~', '!~', '!', '(' or ',' — covers the
#   original '~ /re/' match operator, a bare pattern '/re/ {...}', a negated bare pattern
#   '!/re/', and a regex literal passed to match()/sub()/gsub()/split(). Scoped to files that
#   reference `awk` at least once anywhere in the file (an awk-consuming script; SENTINEL-AWK-GATE
#   below); this is a heuristic over TEXT, not a real awk-program parser, so a construct matching
#   this shape outside an actual awk program would be a false positive — none observed on the
#   real toolbelt+install tree.
#
# Exit codes (§7 three-state discipline):
#   0 — scanned successfully, zero violations (no-match) or zero files found across every
#       configured root (empty-input, reported distinctly, not silently equal to no-match)
#   1 — scanned successfully, one or more violations found (findings; this is
#       a hard gate, unlike a propose-never-apply corpus tool — see header)
#   2 — operational failure: EVERY configured root missing/not traversable (absent-input). A
#       single missing root (e.g. research-sdd/install absent on some other checkout shape) is a
#       WARNING and the scan continues on the remaining root(s) — not every caller of this script
#       necessarily has both trees.
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
  while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _files+=("$_f")
  done < <(find "$_root" -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)
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
# Match: ${ name [subscript]? /{1,2} pattern / X }  where X starts with an UNQUOTED $ or ` —
# any operand beginning that way is unquoted-substitution-risky (kit issue #1142 review: the
# original version only matched a bare $name/${name} replacement and missed a live production
# site plus every synthetic form below; a quoted operand always starts with '"' right after the
# separating '/', which this never matches, so the negative case is still excluded correctly).
# subscript: permissive — any content except ']' (covers [@], [*], [$i], numeric, ...).
# pattern segment: an escaped slash (\/), ONE level of nested {...} (covers ${pre} as pattern),
# or any other char that is not '/{}'.
# replacement segment: after the leading unquoted $ or `, ONE level of nested {...} (covers
# ${y:-z}) or any other char that is not '}', repeated up to the substitution's closing brace.
# Known residual gap (not currently present in the corpus, declared per §7): TWO or more levels
# of nested ${...} inside the replacement is not matched (single-level nesting covers every real
# and synthetic site enumerated in the #1142 review).
formA_re='\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?/{1,2}(\{[^{}]*\}|\\/|[^/{}])+/(\$[^'"'"']|`)(\{[^{}]*\}|[^}])*\}'

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

  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    violations+=("FORM-A unquoted replacement operand: $f:$hit")
  done < <(grep -nE "$formA_re" "$f" 2>/dev/null)

  # SENTINEL-AWK-GATE
  if grep -qE '(^|[^A-Za-z0-9_])awk([^A-Za-z0-9_]|$)' "$f" 2>/dev/null; then
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      violations+=("FORM-B awk interval expression: $f:$hit")
    done < <(grep -nE "$formB_re" "$f" 2>/dev/null)
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
