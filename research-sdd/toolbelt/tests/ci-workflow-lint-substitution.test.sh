#!/usr/bin/env bash
# ci-workflow-lint-substitution.test.sh — structural guard: the kit CI workflow must RUN
# research-sdd/toolbelt/lint-substitution.sh (unwired-mechanisms audit 2026-10-05).
#
# Why: lint-substitution.sh (kit issue #1121/#1142) was reachable only from its own test; the
# workflow ran only run-all.sh and shellcheck, so a new unquoted substitution replacement operand
# or awk interval expression could merge unnoticed. Removing or neutering the CI step would be
# SILENT (the workflow still parses), so this suite parses the YAML and fails unless a
# structurally enabled step runs the lint.
#
# Contract: the `shellcheck` job of .github/workflows/toolbelt-tests.yml has a step whose `run:`
# contains a line that IS the command `[bash ]research-sdd/toolbelt/lint-substitution.sh` (a name:,
# an echo, or a trailing comment does not count), with no `if:` other than a literal true and no
# `continue-on-error: true` on the step or the job; and that script exists and is executable.
# Anti-silent-zero (CLAUDE.md §7): absent workflow or absent ruby = exit 2 (harness error), never a pass.
#
# Usage: ci-workflow-lint-substitution.test.sh [--prove-teeth]
# Exit : 0 wired · 1 step missing/neutered · 2 harness error
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
command -v ruby >/dev/null 2>&1 || { echo "FATAL: ruby (YAML parser) not found" >&2; exit 2; }

echo "== ci-workflow-lint-substitution.test.sh =="

# wired FILE — structural check; on failure prints the reason to stderr and returns 1.
WIRED_RB='
d = (YAML.load_file(ARGV[0]) rescue nil)
(warn "unparseable YAML"; exit 1) unless d.is_a?(Hash)
job = (d["jobs"] || {})["shellcheck"]
(warn "no shellcheck job"; exit 1) unless job.is_a?(Hash)
off = ->(h) { h["continue-on-error"].to_s == "true" || (h.key?("if") && h["if"].to_s.strip != "true") }
(warn "shellcheck job disabled or continue-on-error"; exit 1) if off.(job)
cmd = /\A(bash\s+)?(\.\/)?research-sdd\/toolbelt\/lint-substitution\.sh\z/
hit = (job["steps"] || []).any? { |s|
  s.is_a?(Hash) && s["run"].is_a?(String) && !off.(s) && s["run"].lines.any? { |l| l.strip =~ cmd }
}
(warn "no enabled step runs the command"; exit 1) unless hit
'
wired() { ruby -ryaml -e "$WIRED_RB" "$1"; }

if wired "$WORKFLOW"; then
  ok "workflow: an enabled shellcheck-job step runs research-sdd/toolbelt/lint-substitution.sh"
else
  no "workflow: lint-substitution.sh is NOT run by an enabled step of toolbelt-tests.yml (shellcheck job)"
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

  # mut LABEL EXPR... — build a mutant of the live workflow; wired() must REJECT it.
  mut() {
    local label="$1"; shift
    if ! MUTANT_SYNTAX=none mutant_chain "teeth $label: mutant build" "$WORKFLOW" "$TMP/m.yml" "$@"; then
      no "teeth $label: could not build mutant (anchor drifted or refused by lib/mutant.sh)"
    elif wired "$TMP/m.yml" 2>/dev/null; then
      no "teeth $label: mutant still reads as wired — check is theater"
    else
      ok "teeth $label: correctly detected"
    fi
    rm -f "$TMP/m.yml"
  }
  mut "A step removed"            '/lint-substitution\.sh/d'
  mut "B commented out"           's|^\([[:space:]]*\)run: bash research-sdd/toolbelt/lint-substitution\.sh|\1# run: bash research-sdd/toolbelt/lint-substitution.sh|'
  mut "D name-only mention"       '/run: bash research-sdd\/toolbelt\/lint-substitution\.sh/d' 's|- name: Lint shell-portability.*|- name: research-sdd/toolbelt/lint-substitution.sh|'
  mut "E echo mention"            's|run: bash research-sdd/toolbelt/lint-substitution\.sh|run: echo research-sdd/toolbelt/lint-substitution.sh|'
  mut "F inline-comment mention"  's|run: bash research-sdd/toolbelt/lint-substitution\.sh|run: "true" # research-sdd/toolbelt/lint-substitution.sh|'
  mut "G if: false"              '/run: bash research-sdd\/toolbelt\/lint-substitution\.sh/a\        if: false'
  mut "H continue-on-error"       '/run: bash research-sdd\/toolbelt\/lint-substitution\.sh/a\        continue-on-error: true'

  # Teeth C (positive control): the live workflow is wired.
  if wired "$WORKFLOW"; then ok "teeth C: live workflow wired (positive control holds)"; else no "teeth C: live workflow NOT wired"; fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
