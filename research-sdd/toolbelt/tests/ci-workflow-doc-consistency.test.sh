#!/usr/bin/env bash
# ci-workflow-doc-consistency.test.sh — structural guard: the kit CI workflow must RUN
# research-sdd/toolbelt/verify-doc-consistency.sh and FAIL on its findings (kit issue #1817).
#
# Why: verify-doc-consistency.sh had no caller outside its own fixture suite, and it is WARN-only
# (exit 0 on findings), so a stale section count or broken citation could merge unnoticed — a live
# run reported one broken citation nobody saw. Removing or neutering the CI step would be SILENT
# (the workflow still parses), so this suite parses the YAML and fails unless a structurally
# enabled step runs the script AND turns a WARN line into a non-zero exit.
#
# Contract: the `shellcheck` job of .github/workflows/toolbelt-tests.yml has a step whose `run:`
# contains (a) a line that IS the command `[bash ]research-sdd/toolbelt/verify-doc-consistency.sh`,
# optionally piped to tee, and (b) a line that greps for `^WARN` (the script's finding prefix); with
# no `if:` other than a literal true and no `continue-on-error: true` on the step or the job. The
# live kit tree must currently have 0 findings. Anti-silent-zero (CLAUDE.md section 7): absent
# workflow or absent ruby = exit 2 (harness error), never a pass.
#
# Usage: ci-workflow-doc-consistency.test.sh [--prove-teeth]
# Exit : 0 wired · 1 step missing/neutered or live findings · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REPO="$(cd "$TOOLBELT/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORKFLOW="$REPO/.github/workflows/toolbelt-tests.yml"
CHECK="$TOOLBELT/verify-doc-consistency.sh"
[ -f "$WORKFLOW" ] || { printf 'FATAL: workflow not found: %s\n' "$WORKFLOW" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "FATAL: ruby (YAML parser) not found" >&2; exit 2; }

echo "== ci-workflow-doc-consistency.test.sh =="

# wired FILE — structural check; on failure prints the reason to stderr and returns 1.
WIRED_RB='
d = (YAML.load_file(ARGV[0]) rescue nil)
(warn "unparseable YAML"; exit 1) unless d.is_a?(Hash)
job = (d["jobs"] || {})["shellcheck"]
(warn "no shellcheck job"; exit 1) unless job.is_a?(Hash)
off = ->(h) { h["continue-on-error"].to_s == "true" || (h.key?("if") && h["if"].to_s.strip != "true") }
(warn "shellcheck job disabled or continue-on-error"; exit 1) if off.(job)
cmd = /\A(bash\s+)?(\.\/)?research-sdd\/toolbelt\/verify-doc-consistency\.sh(\s*\|.*)?\z/
hit = (job["steps"] || []).any? { |s|
  s.is_a?(Hash) && s["run"].is_a?(String) && !off.(s) && s["run"].lines.any? { |l| l.strip =~ cmd } && s["run"].lines.any? { |l| l =~ /grep\s.*\^WARN/ }
}
(warn "no enabled step runs the command AND fails on a ^WARN grep"; exit 1) unless hit
'
wired() { ruby -ryaml -e "$WIRED_RB" "$1"; }

if wired "$WORKFLOW"; then
  ok "workflow: an enabled shellcheck-job step runs research-sdd/toolbelt/verify-doc-consistency.sh"
else
  no "workflow: verify-doc-consistency.sh is NOT run by an enabled step of toolbelt-tests.yml (shellcheck job)"
fi

if [ -x "$CHECK" ]; then
  ok "verify-doc-consistency.sh exists and is executable"
else
  no "verify-doc-consistency.sh missing or not executable: $CHECK"
fi

# Live-tree case: the real kit currently has 0 findings (exit 0, no WARN line).
live_out="$(bash "$CHECK" 2>&1)"; live_rc=$?
if [ "$live_rc" -eq 0 ] && ! grep -q '^WARN' <<<"$live_out"; then
  ok "live tree: verify-doc-consistency.sh exits 0 with no WARN finding"
else
  no "live tree: rc=$live_rc, findings: $(printf '%s\n' "$live_out" | grep '^WARN' | head -n 3)"
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
  mut "A step removed"            '/^[[:space:]]*bash research-sdd\/toolbelt\/verify-doc-consistency\.sh/d'
  mut "B grep gate neutered"      's/grep -q/true/'
  mut "C grep pattern changed"    's/\^WARN/^NOPE/g'
  mut "D echo mention"            's|^\([[:space:]]*\)bash research-sdd/toolbelt/verify-doc-consistency\.sh|\1echo research-sdd/toolbelt/verify-doc-consistency.sh|'
  mut "E if: false"               '/- name: Check kit doc consistency/a\        if: false'
  mut "F continue-on-error"       '/- name: Check kit doc consistency/a\        continue-on-error: true'

  # Teeth L: a broken citation injected into a COPY of SKILL.md must surface as a WARN line, so the
  # live-tree case above can actually go red.
  if ! MUTANT_SYNTAX=none mutant_chain "teeth L: SKILL.md mutant build" "$TOOLBELT/../skills/research-sdd/SKILL.md" "$TMP/SKILL.md" '$s|$|\nretros/does-not-exist-1817.md|'; then
    no "teeth L: could not build SKILL.md mutant"
  elif teeth_out="$(RSDD_SKILL="$TMP/SKILL.md" bash "$CHECK" 2>&1)"; grep -q '^WARN' <<<"$teeth_out"; then
    # Output captured first and read via here-string: a pipe into `grep -q` under pipefail races on SIGPIPE.
    ok "teeth L: injected broken citation yields a WARN finding (live case can go red)"
  else
    no "teeth L: injected broken citation produced no WARN — live-tree case is theater"
  fi

  # Teeth P (positive control): the live workflow is wired.
  if wired "$WORKFLOW"; then ok "teeth P: live workflow wired (positive control holds)"; else no "teeth P: live workflow NOT wired"; fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
