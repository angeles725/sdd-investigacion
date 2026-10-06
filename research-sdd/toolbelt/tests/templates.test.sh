#!/usr/bin/env bash
# templates.test.sh — structural check of research-sdd/templates/odd-task.template.md (kit issue #1710).
#
# Every task block (`- [ ] T<N> — ...`, also `[x]`/`[X]`) in the template must carry a `Route:` line and an
# `Evidence:` line before the next task block or heading. The template header must also say no checker
# exists yet, so doctrine does not claim one, and templates/README.md must list the template. This
# validates the TEMPLATE only, not documents copied from it.
#
# Test seams (absent-input paths are exercised through them): ODD_TASK_TEMPLATE, ODD_TASK_README,
# ODD_MUTANT_LIB override the template, README and mutant-helper paths.
#
# Usage: templates.test.sh [--prove-teeth]
# Exit: 0 all held · 1 structural regression · 2 harness error (template/README/mutant lib absent, mktemp failed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT in the kit checkout
SUT="${ODD_TASK_TEMPLATE:-$KIT/templates/odd-task.template.md}"
README="${ODD_TASK_README:-$KIT/templates/README.md}"
MUTLIB="${ODD_MUTANT_LIB:-$HERE/lib/mutant.sh}"
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp -d returned no directory" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
[ -f "$SUT" ] || { echo "FATAL: template not found: $SUT" >&2; exit 2; }  # MISSING-TEMPLATE
[ -f "$README" ] || { echo "FATAL: README not found: $README" >&2; exit 2; }  # MISSING-README
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== templates.test.sh =="

# check FILE -> prints "tasks=N missing=M"; rc 0 only when N>=1 and M=0.
check() {
  awk '
    function close_task() { if (intask) { if (!r) m++; if (!e) m++ } }
    /^- \[[ xX]\] T[0-9]+/ { close_task(); intask=1; n++; r=0; e=0; next }
    /^#/ { close_task(); intask=0; next }
    intask && /^[[:space:]]+Route:/ { r=1 }
    intask && /^[[:space:]]+Evidence:/ { e=1 }
    END { close_task(); printf "tasks=%d missing=%d\n", n, m; exit (n >= 1 && m == 0) ? 0 : 1 }
  ' "$1"
}
header_ok() { grep -qi 'no checker' "$1"; }
readme_ok() { grep -q 'odd-task.template.md' "$1"; }

out="$(check "$SUT")"; rc=$?
if [ "$rc" = 0 ]; then ok "every task block has Route: and Evidence: ($out)"; else no "task blocks incomplete ($out)"; fi
n="$(printf '%s' "$out" | sed -n 's/^tasks=\([0-9]*\).*/\1/p')"
if [ "${n:-0}" -ge 2 ]; then ok "template shows at least two task blocks"; else no "template shows fewer than two task blocks"; fi
if header_ok "$SUT"; then ok "header states no checker exists yet"; else no "header must state no checker exists yet"; fi
if readme_ok "$README"; then ok "templates/README.md lists the template"; else no "templates/README.md must list the template"; fi

# Exit-2 paths: re-run this suite with one seam broken; absent input must exit 2, never 1 or 0.
if [ -z "${ODD_TEMPLATES_CHILD:-}" ]; then
rc2() { # rc2 LABEL EXPECT_RC ENV... -> run this suite with the env assignments
  local label="$1" want="$2"; shift 2
  env ODD_TEMPLATES_CHILD=1 "$@" bash "$0" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then ok "$label -> exit $want"; else no "$label -> exit $got (wanted $want)"; fi
}
rc2 "missing template" 2 ODD_TASK_TEMPLATE="$TMP/absent.md"
rc2 "missing README" 2 ODD_TASK_README="$TMP/absent-readme.md"
rc2 "mktemp failure" 2 TMPDIR="$TMP/no/such/dir"
: > "$TMP/empty-lib.sh"
rc2l() { # rc2l LABEL ENV... (teeth mode)
  local label="$1"; shift
  env ODD_TEMPLATES_CHILD=1 "$@" bash "$0" --prove-teeth >/dev/null 2>&1; local got=$?
  if [ "$got" = 2 ]; then ok "$label -> exit 2"; else no "$label -> exit $got (wanted 2)"; fi
}
rc2l "missing mutant lib" ODD_MUTANT_LIB="$TMP/absent-lib.sh"
rc2l "mutant lib without mutant_sed" ODD_MUTANT_LIB="$TMP/empty-lib.sh"
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the template structure check --"
  [ -f "$MUTLIB" ] || { echo "FATAL: mutant lib not found: $MUTLIB" >&2; exit 2; }
  # shellcheck source=lib/mutant.sh
  . "$MUTLIB" || { echo "FATAL: sourcing $MUTLIB failed" >&2; exit 2; }
  declare -F mutant_sed >/dev/null || { echo "FATAL: $MUTLIB did not define mutant_sed" >&2; exit 2; }
  tooth() { # tooth NAME FILE PREDICATE SED_EXPR — the mutated FILE must fail PREDICATE (check|header_ok|readme_ok)
    local name="$1" file="$2" pred="$3" expr="$4" m="$TMP/$1.md"
    if MUTANT_SYNTAX=none mutant_sed "$file" "$m" "$expr" >/dev/null 2>&1; then
      if "$pred" "$m" >/dev/null; then no "teeth $name: mutant still passes — THEATER"; else ok "teeth $name: mutant fails the check"; fi
    else no "teeth $name: mutant could not be built (pattern absent / refused)"; fi
  }
  tooth first-evidence-dropped "$SUT" check '0,/^  Evidence:/{/^  Evidence:/d}'
  tooth first-route-dropped "$SUT" check '0,/^  Route:/{/^  Route:/d}'
  tooth last-evidence-dropped "$SUT" check '/^  Evidence: <pending>\.$/d'
  tooth checked-box-still-counted "$SUT" check '/^- \[ \] T2/{s/\[ \]/[x]/;n;n;d}'
  tooth header-claims-checker "$SUT" header_ok 's/[Nn]o checker/A checker/'
  tooth readme-unlisted "$README" readme_ok '/odd-task.template.md/d'
  # Exit-2 tooth: a mutant of this suite that exits 1 on a missing template must be caught by the contract.
  mut="$TMP/self-mutant.sh"
  if MUTANT_SYNTAX=bash mutant_sed "$0" "$mut" '/# MISSING-TEMPLATE$/s/exit 2/exit 1/' >/dev/null 2>&1; then
    ODD_TASK_TEMPLATE="$TMP/absent.md" bash "$mut" >/dev/null 2>&1; got=$?
    if [ "$got" = 2 ]; then no "teeth exit-2: mutant still exits 2 — THEATER"; else ok "teeth exit-2: mutant exits $got, contract would catch it"; fi
  else no "teeth exit-2: mutant could not be built (pattern absent / refused)"; fi
fi
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
