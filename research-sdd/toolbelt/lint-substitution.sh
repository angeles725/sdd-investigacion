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
#    POSIX interval expressions without --re-interval, so /^#{1,6}/ silently
#    fails to match on those platforms. kit issue #1130 fixed one instance
#    (retro_marker_line's '^ {0,3}<!--' -> '^ ? ? ?<!--') and explicitly
#    deferred lib/retro-grammar.sh:248 (is_dirty_marker's '#{1,6}') to this
#    issue as a separate calibration-scoped work unit (CLAUDE.md §6).
#
# SCOPE DECLARED (§7 "prove the coverage of your own enumerator"):
#   Traversed: every *.sh file under the given root (default: this script's own
#   directory, i.e. research-sdd/toolbelt), recursively.
#   Form A recognised: ${name[subscript]?/{1,2}pattern/$name2} or
#   ${name[subscript]?/{1,2}pattern/${name2}} where the replacement operand is a
#   BARE variable reference (no surrounding quotes) immediately before the
#   closing '}'. subscript may contain '$', digits, letters, '_' but not ']'.
#   Form A EXCLUDED (not currently present in the corpus, declared as a known
#   gap): a replacement operand that concatenates a bare variable with literal
#   text (${var/pat/$x-suffix}), and an escaped literal '&' review (this lint
#   flags the UNQUOTED SHAPE, not literal '&' content, matching the issue's
#   fix #1: "quote every replacement operand").
#   Form B recognised: a line containing a `~` (awk match operator) followed by
#   an ERE literal delimited by '/', where that literal contains a POSIX
#   interval expression '{m,n}' or '{m,}'. This heuristic is scoped to files
#   that reference `awk` at least once anywhere in the file (an awk-consuming
#   script); it does not parse full awk-program boundaries, so a `~ /.../{..}/`
#   construct outside an actual awk program (unlikely in this corpus) would be
#   a false positive — none observed on the real toolbelt tree.
#
# Exit codes (§7 three-state discipline):
#   0 — scanned successfully, zero violations (no-match) or zero files found
#       under root (empty-input, reported distinctly, not silently equal to
#       no-match)
#   1 — scanned successfully, one or more violations found (findings; this is
#       a hard gate, unlike a propose-never-apply corpus tool — see header)
#   2 — operational failure: root missing/not traversable (absent-input)
#
# Usage: lint-substitution.sh [root-dir]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$SCRIPT_DIR}"

if [[ ! -d "$ROOT" ]] || [[ ! -r "$ROOT" ]] || [[ ! -x "$ROOT" ]]; then
  echo "lint-substitution: ABSENT-INPUT — root '$ROOT' is not a readable/traversable directory" >&2
  exit 2
fi

mapfile -t _files < <(find "$ROOT" -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)

if [[ ${#_files[@]} -eq 0 ]]; then
  echo "lint-substitution: EMPTY-INPUT — 0 *.sh files found under $ROOT"
  exit 0
fi

# --- Form A: unquoted bare-variable replacement operand --------------------
# Match: ${ name [subscript]? /{1,2} pattern / $ name2 }   -- $name2 not quoted.
formA_re='\$\{[A-Za-z_][A-Za-z0-9_]*(\[[A-Za-z0-9_$]*\])?/{1,2}[^/{}]*/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\}'

# --- Form B: awk interval expression inside a `~ /.../ ` ERE literal -------
formB_re='~[[:space:]]*/[^/[:space:]][^/]*\{[0-9]+,[0-9]*\}[^/]*/'

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

echo "lint-substitution: scanned $files_scanned file(s) under $ROOT"

if [[ ${#violations[@]} -eq 0 ]]; then
  echo "lint-substitution: NO-MATCH — 0 violations"
  exit 0
fi

echo "lint-substitution: FOUND ${#violations[@]} violation(s):"
for v in "${violations[@]}"; do
  echo "  - $v"
done
exit 1
