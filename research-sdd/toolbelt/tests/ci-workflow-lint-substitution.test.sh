#!/usr/bin/env bash
# ci-workflow-lint-substitution.test.sh — structural guard: the kit CI workflow must RUN
# research-sdd/toolbelt/lint-substitution.sh (unwired-mechanisms audit 2026-10-05).
#
# Why: lint-substitution.sh (kit issue #1121/#1142) was reachable only from its own test; the
# workflow ran only run-all.sh and shellcheck, so a new unquoted substitution replacement operand or awk
# interval expression could merge unnoticed. Removing the CI step would be SILENT (the workflow still parses), so
# this suite fails if no non-comment line of toolbelt-tests.yml invokes the lint.
#
# Contract: a non-comment line of .github/workflows/toolbelt-tests.yml names
# `research-sdd/toolbelt/lint-substitution.sh`, and that script exists and is executable.
# Anti-silent-zero (CLAUDE.md §7): absent workflow = exit 2 (harness error), never a pass.
#
# Usage: ci-workflow-lint-substitution.test.sh [--prove-teeth]
# Exit : 0 wired · 1 step missing · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REPO="$(cd "$TOOLBELT/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORKFLOW="$REPO/.github/workflows/toolbelt-tests.yml"
LINT="$TOOLBELT/lint-substitution.sh"
[ -f "$WORKFLOW" ] || { printf 'FATAL: workflow not found: %s\n' "$WORKFLOW" >&2; exit 2; }

echo "== ci-workflow-lint-substitution.test.sh =="

# wired FILE — true when a non-comment line invokes the lint script.
wired() { grep -vE '^[[:space:]]*#' "$1" | grep -qE 'research-sdd/toolbelt/lint-substitution\.sh'; }

if wired "$WORKFLOW"; then
  ok "workflow: a non-comment line runs research-sdd/toolbelt/lint-substitution.sh"
else
  no "workflow: lint-substitution.sh is NOT run by toolbelt-tests.yml — add a step next to shellcheck"
fi

if [ -x "$LINT" ]; then
  ok "lint-substitution.sh exists and is executable"
else
  no "lint-substitution.sh missing or not executable: $LINT"
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  echo "-- teeth: mutate a COPY and confirm the check detects the regression --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: delete every line naming the script (the step removed).
  if ! MUTANT_SYNTAX=none mutant_chain "teeth A: step-removed mutant build" "$WORKFLOW" "$TMP/removed.yml" '/lint-substitution\.sh/d'; then
    no "teeth A: could not build mutant (anchor drifted or refused by lib/mutant.sh)"
  elif wired "$TMP/removed.yml"; then
    no "teeth A: mutant without the step still reads as wired — check is theater"
  else
    ok "teeth A: workflow without the step is correctly detected"
  fi

  # Teeth B: comment the invocation out (a commented-out step must not count).
  if ! MUTANT_SYNTAX=none mutant_chain "teeth B: commented-out mutant build" "$WORKFLOW" "$TMP/commented.yml" 's/^\([[:space:]]*\)\(.*lint-substitution\.sh.*\)$/\1# \2/'; then
    no "teeth B: could not build mutant (anchor drifted or refused by lib/mutant.sh)"
  elif wired "$TMP/commented.yml"; then
    no "teeth B: commented-out step still reads as wired — comment filter is theater"
  else
    ok "teeth B: commented-out step is correctly detected"
  fi

  # Teeth C (positive control): the live workflow is wired.
  if wired "$WORKFLOW"; then ok "teeth C: live workflow wired (positive control holds)"; else no "teeth C: live workflow NOT wired"; fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
