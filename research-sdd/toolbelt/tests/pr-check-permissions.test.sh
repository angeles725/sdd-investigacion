#!/usr/bin/env bash
# pr-check-permissions.test.sh — asserts that .github/workflows/pr-check.yml
# grants the GITHUB_TOKEN the minimal read scopes its github-script steps need.
#
# Why this exists:
#   pr-check.yml calls github.rest.issues.get and github.rest.pulls.get. With no
#   `permissions:` block and a repo default of read, both calls failed at runtime
#   with "Resource not accessible by integration" (observed run 31616087563 on PR
#   #179): the "status:approved" and "type:* label" jobs errored before they could
#   evaluate policy. Removing the permissions block reintroduces that failure
#   SILENTLY — the workflow does not error at parse time, it just starts denying
#   the API calls, and because the checks are advisory-only nobody may notice.
#   This test closes that hole structurally (issue #180).
#
# Contract asserted:
#   The workflow grants read (read or write) to: contents, issues, pull-requests.
#   Either an explicit `permissions:` block with those scopes, or a `read-all` /
#   `write-all` scalar, satisfies it.
#
# Anti-silent-zero (CLAUDE.md §7): a missing permissions declaration must FAIL
# loudly, never pass by default.
#
# Usage: pr-check-permissions.test.sh [--prove-teeth]
# Exit : 0 all required scopes granted · 1 a scope is missing · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$TOOLBELT/../.." && pwd)"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORKFLOW="$REPO/.github/workflows/pr-check.yml"
REQUIRED_SCOPES="contents issues pull-requests"

[ -f "$WORKFLOW" ] || { printf 'FATAL: workflow not found: %s\n' "$WORKFLOW" >&2; exit 2; }

echo "== pr-check-permissions.test.sh =="

# Returns 0 if FILE grants read (read|write) to SCOPE, via a scalar read-all /
# write-all or an explicit scope line inside the top-level permissions: block.
grants_scope() {
  local file="$1" scope="$2"
  # Scalar form: `permissions: read-all` / `write-all` grants every scope.
  if grep -qE '^permissions:[[:space:]]*(read-all|write-all)[[:space:]]*$' "$file"; then
    return 0
  fi
  # Block form: extract the indented body of the top-level permissions: block,
  # then look for `  <scope>: read|write`.
  awk '
    /^permissions:[[:space:]]*$/ { in_blk=1; next }
    in_blk && /^[^[:space:]]/    { in_blk=0 }
    in_blk                       { print }
  ' "$file" \
    | grep -qE "^[[:space:]]+${scope}:[[:space:]]*(read|write)([[:space:]]|$)"
}

# Anti-silent-zero: prove a permissions declaration exists at all before judging
# individual scopes, so "no block" is a loud failure, not a silent per-scope pass.
if grep -qE '^permissions:' "$WORKFLOW"; then
  ok "workflow: a top-level permissions declaration is present"
else
  no "workflow: NO permissions declaration — github-script API calls run with the repo default and are denied (issue #180)"
fi

check_scopes() {
  # $1 file to check; increments pass/fail via ok/no
  local file="$1" scope
  for scope in $REQUIRED_SCOPES; do
    if grants_scope "$file" "$scope"; then
      ok "scope granted: $scope (read+)"
    else
      no "scope MISSING: $scope — add '$scope: read' under permissions: in pr-check.yml"
    fi
  done
}

check_scopes "$WORKFLOW"

# ---- NEGATIVE CONTROL: prove the check bites on the exact defect -------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutate a COPY and confirm the check detects the regression --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: strip the whole permissions block -> the check must report a failure.
  # This is the exact pre-fix state that caused run 31616087563 to fail.
  awk '
    /^permissions:[[:space:]]*$/ { in_blk=1; next }
    in_blk && /^[^[:space:]]/    { in_blk=0 }
    in_blk                       { next }
    { print }
  ' "$WORKFLOW" > "$TMP/no-perms.yml"
  # Also drop any scalar permissions line, so the mutant truly has none.
  grep -vE '^permissions:' "$TMP/no-perms.yml" > "$TMP/no-perms2.yml"
  if grep -qE '^permissions:' "$TMP/no-perms2.yml"; then
    no "teeth A: mutant still declares permissions — mutation did not strip the block"
  elif grants_scope "$TMP/no-perms2.yml" issues; then
    no "teeth A: permission-less mutant reported issues granted — check is theater"
  else
    ok "teeth A: permission-less mutant correctly reports issues NOT granted"
  fi

  # Teeth B: remove ONE load-bearing scope (issues) -> per-scope check must miss it.
  grep -vE '^[[:space:]]+issues:' "$WORKFLOW" > "$TMP/no-issues.yml"
  if grants_scope "$TMP/no-issues.yml" issues; then
    no "teeth B: mutant without an issues: line still reports issues granted — per-scope check is theater"
  else
    ok "teeth B: mutant missing the issues scope is correctly detected"
  fi

  # Teeth C (positive control): the live workflow must still grant issues, so the
  # mutations above are the only reason a scope reads as missing.
  if grants_scope "$WORKFLOW" issues; then
    ok "teeth C: live workflow grants issues (positive control holds)"
  else
    no "teeth C: live workflow does NOT grant issues — fix not applied"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
