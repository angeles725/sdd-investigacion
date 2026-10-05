#!/usr/bin/env bash
# templates.test.sh — structural check of research-sdd/templates/odd-task.template.md (kit issue #1710).
#
# Every task block (`- [ ] T<N> — ...`) in the template must carry a `Route:` line and an `Evidence:` line
# before the next task block or heading. The template header must also say no checker exists yet, so
# doctrine does not claim one. This validates the TEMPLATE only, not documents copied from it.
#
# Usage: templates.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT in the kit checkout
SUT="$KIT/templates/odd-task.template.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== templates.test.sh =="

# check FILE -> prints "tasks=N missing=M"; rc 0 only when N>=1 and M=0.
check() {
  awk '
    function close_task() { if (intask) { if (!r) m++; if (!e) m++ } }
    /^- \[[ x]\] T[0-9]+/ { close_task(); intask=1; n++; r=0; e=0; next }
    /^#/ { close_task(); intask=0; next }
    intask && /^[[:space:]]+Route:/ { r=1 }
    intask && /^[[:space:]]+Evidence:/ { e=1 }
    END { close_task(); printf "tasks=%d missing=%d\n", n, m; exit (n >= 1 && m == 0) ? 0 : 1 }
  ' "$1"
}

if [ ! -f "$SUT" ]; then
  no "template exists: $SUT"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  exit 1
fi
ok "template exists"
out="$(check "$SUT")"; rc=$?
if [ "$rc" = 0 ]; then ok "every task block has Route: and Evidence: ($out)"; else no "task blocks incomplete ($out)"; fi
n="$(printf '%s' "$out" | sed -n 's/^tasks=\([0-9]*\).*/\1/p')"
if [ "${n:-0}" -ge 2 ]; then ok "template shows at least two task blocks"; else no "template shows fewer than two task blocks"; fi
if grep -qi 'no checker' "$SUT"; then ok "header states no checker exists yet"; else no "header must state no checker exists yet"; fi
if grep -q 'odd-task.template.md' "$KIT/templates/README.md" 2>/dev/null; then ok "templates/README.md lists the template"; else no "templates/README.md must list the template"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the template structure check --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  export MUTANT_SYNTAX=none
  tooth() { # tooth NAME SED_EXPR — the mutated template must fail check()
    local name="$1" expr="$2" m="$TMP/$1.md"
    if mutant_sed "$SUT" "$m" "$expr" >/dev/null 2>&1; then
      if check "$m" >/dev/null; then no "teeth $name: mutant still passes — THEATER"; else ok "teeth $name: mutant fails the check"; fi
    else no "teeth $name: mutant could not be built (pattern absent / refused)"; fi
  }
  tooth first-evidence-dropped '0,/^  Evidence:/{/^  Evidence:/d}'
  tooth first-route-dropped '0,/^  Route:/{/^  Route:/d}'
  tooth last-evidence-dropped '/^  Evidence: <pending>\.$/d'
fi
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
