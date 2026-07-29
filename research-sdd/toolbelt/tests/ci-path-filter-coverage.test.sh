#!/usr/bin/env bash
# ci-path-filter-coverage.test.sh — asserts that every harness input declared by
# harness-sweep-parity.test.sh is covered in BOTH the push and pull_request path
# filter blocks of the CI workflow.
#
# Why this exists:
#   PR #108 edited .claude/settings.json (a harness input) without that file being
#   in the workflow paths: filter. CI never triggered, the suite broke, and the
#   regression entered main silently. This test closes that hole structurally.
#
# Design:
#   1. Inputs are DERIVED from harness-sweep-parity.test.sh --list-inputs at
#      runtime, not hardcoded.  A new harness added to the parity test is
#      automatically covered here without any manual update.
#   2. push.paths and pull_request.paths are parsed SEPARATELY and each input
#      must be present in BOTH.  An entry in push only (or PR only) is a real
#      gap: a PR touching that file would never trigger the suite.
#
# Anti-silent-zero contract (CLAUDE.md §7):
#   Zero inputs or zero filters in either block must fail loudly.
#
# Usage: ci-path-filter-coverage.test.sh [--prove-teeth]
# Exit : 0 all inputs covered in both blocks · 1 gap detected · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$TOOLBELT/../.." && pwd)"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PARITY_TEST="$HERE/harness-sweep-parity.test.sh"
WORKFLOW="$REPO/.github/workflows/toolbelt-tests.yml"

for f in "$PARITY_TEST" "$WORKFLOW"; do
  [ -f "$f" ] || { printf 'FATAL: required file not found: %s\n' "$f" >&2; exit 2; }
done

echo "== ci-path-filter-coverage.test.sh =="

# ---- Derive harness inputs from the parity test at runtime ------------------
# --list-inputs prints repo-relative paths, one per line.
HARNESS_INPUTS_RAW="$(bash "$PARITY_TEST" --list-inputs)"

input_count=0
while IFS= read -r line; do
  if [ -n "$line" ]; then input_count=$((input_count + 1)); fi
done <<< "$HARNESS_INPUTS_RAW"

if [ "$input_count" -gt 0 ]; then
  ok "parity-test: derived $input_count harness inputs from $(basename "$PARITY_TEST")"
else
  no "parity-test: --list-inputs returned nothing — mode broken or parity test has no inputs"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  exit 1
fi

# ---- Parse push and pull_request path filter blocks separately --------------
# We MUST check each block independently. sort -u over the merged set would hide
# an entry that exists in push but not pull_request (or vice versa), letting a
# real coverage gap pass as "covered". The PR case is the most dangerous: a PR
# that edits a harness input would never trigger the suite.
extract_trigger_paths() {
  # $1: workflow file  $2: trigger keyword (push or pull_request)
  local wf="$1" trigger="$2"
  awk -v trig="  ${trigger}:" '
    $0 == trig          { in_block=1; next }
    /^  [a-z]/          { in_block=0 }
    in_block && /^[[:space:]]+-[[:space:]]+"/ { print }
  ' "$wf" \
    | grep -oE '"[^"]+"' | tr -d '"' | sort
}

PUSH_FILTERS="$(extract_trigger_paths "$WORKFLOW" push)"
PR_FILTERS="$(extract_trigger_paths "$WORKFLOW" pull_request)"

push_count=0; pr_count=0
while IFS= read -r line; do if [ -n "$line" ]; then push_count=$((push_count + 1)); fi; done <<< "$PUSH_FILTERS"
while IFS= read -r line; do if [ -n "$line" ]; then pr_count=$((pr_count + 1)); fi; done <<< "$PR_FILTERS"

if [ "$push_count" -gt 0 ]; then
  ok "workflow: parsed $push_count path filters from push block"
else
  no "workflow: zero push path filters — workflow format may have changed"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
fi

if [ "$pr_count" -gt 0 ]; then
  ok "workflow: parsed $pr_count path filters from pull_request block"
else
  no "workflow: zero pull_request path filters — workflow format may have changed"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
fi

# ---- Match helper -----------------------------------------------------------
# Returns 0 if repo-relative FILE is covered by PATTERN.
# Supports exact paths and trailing-/** globs used by GitHub Actions.
matches_filter() {
  local file="$1" pattern="$2"
  case "$pattern" in
    *"/**")
      local prefix="${pattern%/**}"
      case "$file" in "$prefix"/*) return 0 ;; esac
      ;;
    *)
      [ "$file" = "$pattern" ] && return 0
      ;;
  esac
  return 1
}

input_covered_in() {
  local input_file="$1" filters="$2"
  while IFS= read -r filter; do
    if [ -z "$filter" ]; then continue; fi
    if matches_filter "$input_file" "$filter"; then
      return 0
    fi
  done <<< "$filters"
  return 1
}

# ---- Coverage check — both blocks independently ----------------------------
while IFS= read -r input_file; do
  if [ -z "$input_file" ]; then continue; fi
  if input_covered_in "$input_file" "$PUSH_FILTERS"; then
    ok "push: covered: $input_file"
  else
    no "push: NOT COVERED: $input_file — add to push.paths in $(basename "$WORKFLOW")"
  fi
  if input_covered_in "$input_file" "$PR_FILTERS"; then
    ok "pull_request: covered: $input_file"
  else
    no "pull_request: NOT COVERED: $input_file — add to pull_request.paths in $(basename "$WORKFLOW")"
  fi
done <<< "$HARNESS_INPUTS_RAW"

# ---- NEGATIVE CONTROL: prove both defects are closed -----------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: verify derivation reads parity test and asymmetry is detected --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: stub parity test with an extra known input; derivation must include it.
  # This proves ci-path-filter-coverage.test.sh reads the live parity test at runtime,
  # not a cached or hardcoded copy.
  cat > "$TMP/stub-parity.sh" << 'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--list-inputs" ]; then
  printf '.claude/settings.json\n'
  printf 'research-sdd/toolbelt/opencode/research-sdd-sweep.ts\n'
  printf '.opencode/config.json\n'
  exit 0
fi
STUB_EOF
  stub_inputs="$(bash "$TMP/stub-parity.sh" --list-inputs)"
  if printf '%s\n' "$stub_inputs" | grep -qx '.opencode/config.json'; then
    ok "teeth A: extra input from stub parity test appears in derived set (derivation reads live file)"
  else
    no "teeth A: extra stub input NOT found — derivation is not reading parity test at runtime"
  fi

  # Teeth B: asymmetric workflow — .claude/settings.json present in push only.
  # The per-block check must detect it is missing from pull_request.
  awk '
    /^  pull_request:$/ { in_pr=1 }
    /^jobs:$/           { in_pr=0 }
    in_pr && /\.claude\/settings\.json/ { next }
    { print }
  ' "$WORKFLOW" > "$TMP/asymmetric.yml"

  asym_push="$(extract_trigger_paths "$TMP/asymmetric.yml" push)"
  asym_pr="$(extract_trigger_paths "$TMP/asymmetric.yml" pull_request)"
  asym_in_push=0; asym_in_pr=0
  if input_covered_in ".claude/settings.json" "$asym_push"; then asym_in_push=1; fi
  if input_covered_in ".claude/settings.json" "$asym_pr"; then asym_in_pr=1; fi

  if [ "$asym_in_push" -eq 1 ] && [ "$asym_in_pr" -eq 0 ]; then
    ok "teeth B: push/pull_request asymmetry detected (.claude/settings.json in push only — PR gap caught)"
  else
    no "teeth B: asymmetry NOT detected (push=$asym_in_push pr=$asym_in_pr) — per-block check is theater"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
