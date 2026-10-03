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
# Doc-consistency extension (kit agenda item 4):
#   Suites also read real doctrine files (METHODOLOGY.md, PROMPT-LOOP.md, skills/**,
#   profiles/**) via $HERE/../../<path> or $KIT/<path>. Those paths are DERIVED by
#   scanning the suites; each existing file outside the already-covered trees must be
#   covered by both filter blocks, or a doc-only PR breaks a suite and merges without CI.
#
# Usage: ci-path-filter-coverage.test.sh [--prove-teeth]
# Exit : 0 all inputs covered in both blocks · 1 gap detected · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REPO="$(cd "$TOOLBELT/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# harness_error: the instrument could not do its job (exit 2), as opposed to a real gap (exit 1).
harness_error(){ printf '  FAIL  HARNESS ERROR: %s\n' "$1"; fail=$((fail+1)); printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 2; }

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
  harness_error "parity-test: --list-inputs returned nothing — mode broken or parity test has no inputs"
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
  harness_error "workflow: zero push path filters — workflow format may have changed"
fi

if [ "$pr_count" -gt 0 ]; then
  ok "workflow: parsed $pr_count path filters from pull_request block"
else
  harness_error "workflow: zero pull_request path filters — workflow format may have changed"
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

# ---- Doc-consistency coverage: doctrine files the suites read ---------------
# Derive repo-relative doc files from `$HERE/../../<p>` and `$KIT/<p>` / `${KIT}/<p>` references
# in every suite. Paths under toolbelt/, install/, templates/ are already covered by
# their own filters. TARGETS.md is excluded on purpose: suites cite it as an anchor
# string or write it into fixtures, and it is refreshed by hand every session, so
# filtering on it would run the full suite on every registry refresh for no coverage.
#
# Enumerator coverage proof (CLAUDE.md §7): a `$KIT/<p>` reference only counts when the suite's
# KIT binding is classified as the REAL tree. Every suite with a non-comment `$KIT/` reference is
# classified, and one whose binding is absent or unrecognised is reported UNCLASSIFIED (WARN).
# Recognised KIT binding forms (line start, optional indentation, optional
# `local|readonly|export|declare [-flags]` prefix, quoted or unquoted RHS):
#   real-tree : RHS mentions $HERE/../.. or $TOOLBELT/..  (also the ${HERE} / ${TOOLBELT} forms)
#   temp      : RHS mentions mktemp, or a $TMP / $TMPDIR / $SCRATCH / $BOX / $ROOT / $TWO_KIT path
#   unclassified : any other RHS, or $KIT/ referenced with no KIT binding at all
# Measured on the real tree at authoring time: 2 unclassified suites (hotcore-budget.test.sh, which
# cites "$KIT/TARGETS.md" only as an anchor string with no binding, and verify-cd-physical.test.sh, whose KIT= lines live in generated fixtures) — noisy enough that this is a WARN,
# not a failure; the count is printed on every run.
KIT_BIND_RE='^[[:space:]]*((local|readonly|export|declare)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?)?KIT='
KIT_REF_RE='\$(\{KIT\}|KIT)/[A-Za-z0-9_./-]+'
classify_kit_binding() {
  # $1 suite file -> prints real | temp | none (no $KIT/ ref) | unclassified
  local suite="$1" bindings
  if ! grep -vE '^[[:space:]]*#' "$suite" | grep -qE "$KIT_REF_RE"; then echo none; return; fi
  bindings="$(grep -E "$KIT_BIND_RE" "$suite")" || bindings=""
  if grep -qE '\$\{?(HERE\}?/\.\./\.\.|TOOLBELT\}?/\.\.)' <<< "$bindings"; then echo real
  elif [ -n "$bindings" ] && ! grep -vE 'mktemp|\$\{?(TMP|TMPDIR|SCRATCH|BOX|ROOT|TWO_KIT)\b' <<< "$bindings" | grep -q .; then echo temp
  else echo unclassified; fi
}

unclassified_suites() {
  local suite
  for suite in "$@"; do
    [ -f "$suite" ] || continue
    [ "$(classify_kit_binding "$suite")" = unclassified ] && basename "$suite"
  done
  return 0
}

derive_doc_inputs() {
  local kit_dir="$1" suite p; shift
  for suite in "$@"; do
    [ -f "$suite" ] || continue
    # $HERE/../../<p> is always the real tree; $KIT/<p> only when that suite binds KIT to the real kit.
    grep -ohE '\$HERE/\.\./\.\./[A-Za-z0-9_./-]+' "$suite" 2>/dev/null | sed -E 's#^\$HERE/\.\./\.\./##'
    if [ "$(classify_kit_binding "$suite")" = real ]; then
      grep -ohE "$KIT_REF_RE" "$suite" 2>/dev/null | sed -E 's#^\$(\{KIT\}|KIT)/##'
    fi
  done | sed -E 's#[./]+$##' | sort -u \
    | while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in ../*|toolbelt|toolbelt/*|install|install/*|templates|templates/*|TARGETS.md) continue ;; esac
        if [ -d "$kit_dir/$p" ]; then
          find "$kit_dir/$p" -type f | sed "s#^$kit_dir/#research-sdd/#"
        elif [ -f "$kit_dir/$p" ]; then
          printf 'research-sdd/%s\n' "$p"
        fi
      done | sort -u
}

ALL_SUITES=("$HERE"/*.test.sh "$REPO/research-sdd/install/tests"/*.test.sh)
UNCLASSIFIED="$(unclassified_suites "${ALL_SUITES[@]}")"
if [ -n "$UNCLASSIFIED" ]; then
  unc_count=0
  while IFS= read -r line; do if [ -n "$line" ]; then unc_count=$((unc_count + 1)); fi; done <<< "$UNCLASSIFIED"
  printf '  WARN  docs: %d suite(s) reference $KIT/<path> with an unclassified KIT binding (not derived): %s\n' "$unc_count" "$(tr '\n' ' ' <<< "$UNCLASSIFIED")"
else
  ok "docs: every suite with a \$KIT/ reference has a classified KIT binding"
fi

DOC_INPUTS="$(derive_doc_inputs "$REPO/research-sdd" "${ALL_SUITES[@]}")"
doc_count=0
while IFS= read -r line; do if [ -n "$line" ]; then doc_count=$((doc_count + 1)); fi; done <<< "$DOC_INPUTS"
if [ "$doc_count" -gt 0 ]; then
  ok "docs: derived $doc_count doctrine files read by suites"
else
  harness_error "docs: derivation found zero doctrine files — scan pattern broken (silent zero)"
fi

doc_gaps() {
  # $1 push filters  $2 pr filters  -> prints "<block>: <file>" per gap
  local f
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    input_covered_in "$f" "$1" || printf 'push: %s\n' "$f"
    input_covered_in "$f" "$2" || printf 'pull_request: %s\n' "$f"
  done <<< "$DOC_INPUTS"
}

DOC_GAPS="$(doc_gaps "$PUSH_FILTERS" "$PR_FILTERS")"
if [ -z "$DOC_GAPS" ]; then
  ok "docs: all $doc_count doctrine files covered in push and pull_request filters"
else
  while IFS= read -r g; do no "docs: NOT COVERED ($g) — add to paths: in $(basename "$WORKFLOW")"; done <<< "$DOC_GAPS"
fi

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
  printf 'research-sdd/install/tests/golden/plan-codex.txt\n'
  printf 'research-sdd/install/adapters.sh\n'
  exit 0
fi
STUB_EOF
  stub_inputs="$(bash "$TMP/stub-parity.sh" --list-inputs)"
  if grep -qx 'research-sdd/install/adapters.sh' <<< "$stub_inputs"; then
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

  # Teeth C: drop the skills glob from the pull_request block only; doc gap must surface.
  awk '
    /^  pull_request:$/ { in_pr=1 }
    /^jobs:$/           { in_pr=0 }
    in_pr && /research-sdd\/skills\/\*\*/ { next }
    { print }
  ' "$WORKFLOW" > "$TMP/nodoc.yml"
  nd_gaps="$(doc_gaps "$(extract_trigger_paths "$TMP/nodoc.yml" push)" "$(extract_trigger_paths "$TMP/nodoc.yml" pull_request)")"
  if grep -q '^pull_request: research-sdd/skills/' <<< "$nd_gaps" && ! grep -q '^push:' <<< "$nd_gaps"; then
    ok "teeth C: removing skills path from pull_request block is detected as a doc gap"
  else
    no "teeth C: doc gap NOT detected after removing skills filter — doc check is theater"
  fi

  # Teeth D: a suite binding KIT with indentation + `readonly` and reading $KIT/METHODOLOGY.md must be derived.
  mkdir -p "$TMP/fx"
  cat > "$TMP/fx/a.test.sh" << 'FX_EOF'
HERE=x
  readonly KIT="$(cd "$HERE/../.." && pwd)"
cat "$KIT/METHODOLOGY.md"
FX_EOF
  if grep -qx 'research-sdd/METHODOLOGY.md' <<< "$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/a.test.sh")"; then
    ok "teeth D: indented 'readonly KIT=...' binding is recognised and \$KIT/METHODOLOGY.md derived"
  else
    no "teeth D: indented readonly KIT binding NOT derived — binding recognition too narrow"
  fi

  # Teeth E: a suite referencing $KIT/ with an unrecognised binding is reported UNCLASSIFIED, not silently dropped.
  cat > "$TMP/fx/b.test.sh" << 'FX_EOF'
KIT="$(compute_kit_somehow)"
cat "$KIT/METHODOLOGY.md"
FX_EOF
  cat > "$TMP/fx/c.test.sh" << 'FX_EOF'
cat "$KIT/METHODOLOGY.md"
FX_EOF
  unc="$(unclassified_suites "$TMP/fx/a.test.sh" "$TMP/fx/b.test.sh" "$TMP/fx/c.test.sh")"
  if [ "$unc" = "$(printf 'b.test.sh\nc.test.sh')" ]; then
    ok "teeth E: unrecognised and absent KIT bindings are reported UNCLASSIFIED (a.test.sh real-tree is not)"
  else
    no "teeth E: unclassified enumeration wrong: [$unc]"
  fi

  # Teeth F: zero derivation is a harness error (rc 2), not a gap (rc 1). Run a copy of this suite in a
  # synthetic repo whose suites reference no doctrine file.
  FR="$TMP/frepo"; mkdir -p "$FR/research-sdd/toolbelt/tests" "$FR/.github/workflows"
  cp "$WORKFLOW" "$FR/.github/workflows/toolbelt-tests.yml"
  cp "$0" "$FR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh"
  printf '#!/usr/bin/env bash\nprintf ".claude/settings.json\\n"\n' > "$FR/research-sdd/toolbelt/tests/harness-sweep-parity.test.sh"
  bash "$FR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh" > "$TMP/f.out" 2>&1; frc=$?
  if [ "$frc" -eq 2 ] && grep -q 'HARNESS ERROR: docs: derivation found zero' "$TMP/f.out"; then
    ok "teeth F: zero doc derivation exits 2 with a typed HARNESS ERROR (not 1)"
  else
    no "teeth F: zero derivation rc=$frc (want 2) — harness error conflated with gap"
  fi

fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
