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
# An UNCLASSIFIED suite is a harness error (rc 2): a read through an unrecognised binding would
# otherwise drop out of the derived set silently (#1455). A `$KIT/<p>` that is only a single-quoted span or
# backslash-escaped literal (detected quote-aware per line; an ambiguous line stays visible) (e.g. hotcore-budget.test.sh's "$KIT/TARGETS.md" anchor strings) is no read and
# is classified `none`. Comments and heredoc bodies are ignored (live_lines).
# Heredoc openers are detected AFTER the trailing comment is stripped, and `<<<word` is a here-string.
KIT_REF_RE='\$(\{KIT\}|KIT)/[A-Za-z0-9_./-]+'
KIT_REF_PREFIX_RE='^\$(\{KIT\}|KIT)/'
# Real-tree path prefixes. The variable bases (_V_*: bare, ${braced} or "$quoted" followed by `/`) are
# defined ONCE and composed into EVERY consumer: derivation (HERE_PFX, REPO_PFX), prefix strip, and the
# binding classifiers (REPO_REAL_BIND_RE, KIT_HERE_BIND_RE), so they cannot drift (#1479 R2-001).
# HERE_PFX: $HERE/../../<p> (tests dirs) and $TOOLBELT/../<p> — always the real tree. REPO_PFX:
# $REPO/research-sdd/<p> — a read of the real tree ONLY when the suite binds REPO to it
# (classify_binding REPO); a temp-bound REPO is a fixture (#1455 item 2).
# A doc path must START with a name character, so a deeper climb than the recognised prefix matches
# nothing instead of being partly stripped into `..` or a parent-relative path (#1479).
_V_HERE='\$\{?HERE\}?"?'
_V_TOOLBELT='\$\{?TOOLBELT\}?"?'
_V_REPO='\$\{?REPO\}?"?'
DOC_PATH_RE='[A-Za-z0-9_][A-Za-z0-9_./-]*'
HERE_PFX="(${_V_HERE}/\.\./\.\./|${_V_TOOLBELT}/\.\./)"
REPO_PFX="(${_V_REPO}/research-sdd/)"
REAL_REF_RE="${HERE_PFX}${DOC_PATH_RE}"
REAL_REF_PREFIX_RE="^${HERE_PFX}"
REPO_REF_RE="${REPO_PFX}${DOC_PATH_RE}"
REPO_REF_PREFIX_RE="^${REPO_PFX}"
# live_lines: print only LIVE shell text of a suite — full-line comments dropped, trailing
# ` # ...` comments stripped, heredoc bodies skipped. Every scan below reads through this one
# filter so a `$KIT/X.md` mention in prose or in a fixture body is never counted as a read.
# (Heuristic: a ` #` inside a quoted string is also stripped; acceptable, it only loses prose.)
live_lines() {
  awk '
    heredoc != "" { t=$0; if (dash) sub(/^\t+/, "", t); if (t == heredoc) heredoc=""; next }
    /^[[:space:]]*#/ { next }
    {
      line=$0
      sub(/[[:space:]]+#.*$/, "", line)
      code=line; gsub(/<<</, "___", code)
      if (match(code, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        tag=substr(code, RSTART, RLENGTH); dash=(tag ~ /^<<-/)
        gsub(/^<<-?[[:space:]]*["\047]?|["\047]?$/, "", tag); heredoc=tag
      }
      print line
    }
  ' "$1"
}

# strip_kit_literals: stdin -> stdout with every `$` the shell would NOT expand neutralised to `_`
# (inside a single-quoted span, or backslash-escaped). Quote-aware per line: a single quote inside a
# double-quoted string and `\'` are not delimiters. A line that ends inside an open quote is left
# untouched, so an ambiguous line can only keep a `$KIT/` visible (fail loud), never hide one.
strip_kit_literals() {
  awk '
    {
      line=$0; out=""; st=0; n=length(line)
      for (i=1; i<=n; i++) {
        c=substr(line,i,1)
        if (st==1) { if (c=="\047") st=0; else if (c=="$") c="_"; out=out c; continue }
        if (c=="\\" && i<n) { i++; d=substr(line,i,1); if (d=="$") d="_"; out=out c d; continue }
        if (st==2) { if (c=="\"") st=0; out=out c; continue }
        if (c=="\"") st=2; else if (c=="\047") st=1
        out=out c
      }
      print (st==0 ? out : line)
    }'
}

# classify_binding VAR REAL_RE LIVE-TEXT [EXTRA_TEMP] -> real | temp | unclassified, from VAR's binding lines.
# EXTRA_TEMP is an optional `|NAME|NAME2` suffix appended to the temp-root alternation, so a caller can
# declare extra variables (e.g. a temp-bound REPO) whose bindings count as temp.
classify_binding() {
  local var="$1" real_re="$2" live="$3" extra_temp="${4:-}" bindings
  bindings="$(grep -E "^[[:space:]]*((local|readonly|export|declare)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?)?${var}=" <<< "$live")" || bindings=""
  if grep -qE "$real_re" <<< "$bindings"; then echo real
  elif [ -n "$bindings" ] && [ -z "$(grep -vE "mktemp|\\\$\\{?(TMP|TMPDIR|SCRATCH|BOX|ROOT|TWO_KIT${extra_temp})\\b" <<< "$bindings")" ]; then echo temp
  else echo unclassified; fi
}

# A REPO binding is the real tree when it climbs out of the toolbelt or the tests dir.
REPO_REAL_BIND_RE="(${_V_TOOLBELT}/\.\./\.\.|${_V_HERE}/\.\./\.\./\.\.)"
# A KIT binding is the real kit via HERE/TOOLBELT climbs; `$REPO/research-sdd` counts only when REPO
# itself is real-bound (classify_kit_binding adds it), and is a temp fixture when REPO is temp-bound.
KIT_HERE_BIND_RE="(${_V_HERE}/\.\./\.\.|${_V_TOOLBELT}/\.\.)"

classify_kit_binding() {
  # $1 suite file -> prints real | temp | none (no live $KIT/ ref) | unclassified
  local suite="$1" live
  live="$(live_lines "$suite")"
  # A `$KIT/<p>` inside a single-quoted span or written `\$KIT` is a literal anchor, never expanded, so it
  # needs no binding (#1455: hotcore-budget cites "$KIT/TARGETS.md" only as an anchor string).
  if ! strip_kit_literals <<< "$live" | grep -E "$KIT_REF_RE" >/dev/null; then echo none; return; fi
  local repo_class kit_re="$KIT_HERE_BIND_RE" extra=""
  repo_class="$(classify_binding REPO "$REPO_REAL_BIND_RE" "$live")"
  case "$repo_class" in
    real) kit_re="(${KIT_HERE_BIND_RE}|${_V_REPO}/research-sdd)" ;;
    temp) extra="|REPO" ;;
  esac
  classify_binding KIT "$kit_re" "$live" "$extra"
}

classify_repo_binding() {
  # $1 suite file -> real | temp | none (no live $REPO/research-sdd read) | unclassified
  local suite="$1" live
  live="$(live_lines "$suite")"
  if ! strip_kit_literals <<< "$live" | grep -E "$REPO_REF_RE" >/dev/null; then echo none; return; fi
  classify_binding REPO "$REPO_REAL_BIND_RE" "$live"
}

unclassified_suites() {
  local suite
  for suite in "$@"; do
    [ -f "$suite" ] || continue
    if [ "$(classify_kit_binding "$suite")" = unclassified ] || [ "$(classify_repo_binding "$suite")" = unclassified ]; then
      basename "$suite"
    fi
  done
  return 0
}

# doc_refs_raw SUITE: every real-tree doc path a suite reads, prefix-stripped but NOT yet filtered.
# $HERE/../../<p> is always the real tree; $REPO/research-sdd/<p> only when REPO is real-bound;
# $KIT/<p> only when that suite binds KIT to the real kit.
doc_refs_raw() {
  local suite="$1"
  live_lines "$suite" | grep -oE "$REAL_REF_RE" | sed -E "s#$REAL_REF_PREFIX_RE##"
  if [ "$(classify_binding REPO "$REPO_REAL_BIND_RE" "$(live_lines "$suite")")" = real ]; then
    live_lines "$suite" | grep -oE "$REPO_REF_RE" | sed -E "s#$REPO_REF_PREFIX_RE##"
  fi
  if [ "$(classify_kit_binding "$suite")" = real ]; then
    live_lines "$suite" | grep -oE "$KIT_REF_RE" | sed -E "s#$KIT_REF_PREFIX_RE##"
  fi
}

derive_doc_inputs() {
  local kit_dir="$1" suite p; shift
  for suite in "$@"; do
    [ -f "$suite" ] || continue
    doc_refs_raw "$suite"
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

# This suite is excluded from its own scan: its teeth fixtures deliberately contain KIT bindings and
# `$KIT/METHODOLOGY.md` text, which would otherwise be derived as if a suite read that doc.
ALL_SUITES=()
for _s in "$HERE"/*.test.sh "$REPO/research-sdd/install/tests"/*.test.sh; do
  [ "$(basename "$_s")" = "$(basename "${BASH_SOURCE[0]}")" ] || ALL_SUITES+=("$_s")
done
UNCLASSIFIED="$(unclassified_suites "${ALL_SUITES[@]}")"
if [ -n "$UNCLASSIFIED" ]; then
  unc_count=0
  while IFS= read -r line; do if [ -n "$line" ]; then unc_count=$((unc_count + 1)); fi; done <<< "$UNCLASSIFIED"
  # An unclassified binding silently weakens doc coverage, so it is a harness error (rc 2), not a WARN (#1455).
  harness_error "docs: $unc_count UNCLASSIFIED suite(s) read \$KIT/<path> or \$REPO/research-sdd/<path> with an unrecognised KIT/REPO binding — bind KIT/REPO to the real tree or a temp dir, or quote the mention as a literal: $(tr '\n' ' ' <<< "$UNCLASSIFIED")"
else
  ok "docs: every suite with a \$KIT/ reference has a classified KIT binding"
fi

DOC_INPUTS="$(derive_doc_inputs "$REPO/research-sdd" "${ALL_SUITES[@]}")"
doc_count=0
while IFS= read -r line; do if [ -n "$line" ]; then doc_count=$((doc_count + 1)); fi; done <<< "$DOC_INPUTS"
if [ "$doc_count" -gt 0 ]; then
  ok "docs: derived $doc_count doctrine files read by suites: $(tr '\n' ' ' <<< "$DOC_INPUTS")"
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
  # Mutated-workflow builds (teeth B, C) go through lib/mutant.sh (kit issue #1299), sourced only on
  # this path. mutant_built refuses an empty or byte-identical result (an awk filter that matched
  # nothing); a refused build is counted ONCE and its observation never runs. The workflow is YAML,
  # so MUTANT_SYNTAX=none. The remaining teeth (D-Q) mutate nothing on disk: they redefine this
  # suite's OWN in-process functions (live_lines, strip_kit_literals, the *_RE variables) and
  # compare derivations, so there is no mutant file to build and they keep their observations.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_built mutant_or_count mutant_built_or_count || exit 2
  mk_built() { MUTANT_SYNTAX=none mutant_built_or_count fail "$@" || return 1; }

  # Teeth A: stub parity test with an extra known input; derivation must include it.
  # This proves ci-path-filter-coverage.test.sh reads the live parity test at runtime,
  # not a cached or hardcoded copy.
  cat > "$TMP/stub-parity.sh" << 'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--list-inputs" ]; then
  printf '.claude/settings.json\n'
  printf 'research-sdd/install/tests/golden/plan-pi.txt\n'
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
  if mk_built "teeth B: asymmetric workflow mutant" "$WORKFLOW" "$TMP/asymmetric.yml"; then

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

  # Teeth C: drop the skills glob from the pull_request block only; doc gap must surface.
  awk '
    /^  pull_request:$/ { in_pr=1 }
    /^jobs:$/           { in_pr=0 }
    in_pr && /research-sdd\/skills\/\*\*/ { next }
    { print }
  ' "$WORKFLOW" > "$TMP/nodoc.yml"
  if mk_built "teeth C: no-skills-doc workflow mutant" "$WORKFLOW" "$TMP/nodoc.yml"; then
    nd_gaps="$(doc_gaps "$(extract_trigger_paths "$TMP/nodoc.yml" push)" "$(extract_trigger_paths "$TMP/nodoc.yml" pull_request)")"
    if grep -q '^pull_request: research-sdd/skills/' <<< "$nd_gaps" && ! grep -q '^push:' <<< "$nd_gaps"; then
      ok "teeth C: removing skills path from pull_request block is detected as a doc gap"
    else
      no "teeth C: doc gap NOT detected after removing skills filter — doc check is theater"
    fi
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
  frc=0
  bash "$FR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh" > "$TMP/f.out" 2>&1 || frc=$?
  if [ "$frc" -eq 2 ] && grep -q 'HARNESS ERROR: docs: derivation found zero' "$TMP/f.out"; then
    ok "teeth F: zero doc derivation exits 2 with a typed HARNESS ERROR (not 1)"
  else
    no "teeth F: zero derivation rc=$frc (want 2) — harness error conflated with gap"
  fi


  # Teeth G: `$KIT/<doc>` / `$HERE/../../<doc>` inside a comment, a trailing comment, or a heredoc
  # body is NOT a read. Mutant: with the filter replaced by plain cat, the same fixture IS derived.
  cat > "$TMP/fx/g.test.sh" << 'FX_EOF'
HERE=x
KIT="$(cd "$HERE/../.." && pwd)"
# see $KIT/PROMPT-LOOP.md for context
true  # also $HERE/../../PROMPT-LOOP.md
cat > f << 'INNER'
$KIT/PROMPT-LOOP.md
$HERE/../../PROMPT-LOOP.md
INNER
echo done
FX_EOF
  g_live="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/g.test.sh")"
  live_lines_real="$(declare -f live_lines)"
  live_lines() { cat "$1"; }
  g_mut="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/g.test.sh")"
  eval "$live_lines_real"
  if [ -z "$g_live" ] && grep -qx 'research-sdd/PROMPT-LOOP.md' <<< "$g_mut"; then
    ok "teeth G: comment and heredoc-body mentions are not derived (and are, with the filter removed)"
  else
    no "teeth G: filter ineffective or mutant did not go red (live=[$g_live] mutant=[$g_mut])"
  fi

  # Teeth H (#1455): an UNCLASSIFIED suite is a harness error (rc 2) with a typed message, not a WARN.
  # Synthetic repo: one suite with an unrecognised KIT binding. Zero doc derivation would also exit 2,
  # so the assertion pins the UNCLASSIFIED message, which is emitted BEFORE derivation runs.
  HR="$TMP/hrepo"; mkdir -p "$HR/research-sdd/toolbelt/tests" "$HR/.github/workflows"
  cp "$WORKFLOW" "$HR/.github/workflows/toolbelt-tests.yml"
  cp "$0" "$HR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh"
  cp "$TMP/fx/b.test.sh" "$HR/research-sdd/toolbelt/tests/b.test.sh"
  printf '#!/usr/bin/env bash\nprintf ".claude/settings.json\\n"\n' > "$HR/research-sdd/toolbelt/tests/harness-sweep-parity.test.sh"
  hrc=0
  bash "$HR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh" > "$TMP/h.out" 2>&1 || hrc=$?
  if [ "$hrc" -eq 2 ] && grep -q 'HARNESS ERROR: docs:.*UNCLASSIFIED.*b\.test\.sh' "$TMP/h.out"; then
    ok "teeth H: an UNCLASSIFIED KIT binding exits 2 with a typed HARNESS ERROR naming the suite"
  else
    no "teeth H: unclassified suite rc=$hrc (want 2 + typed message) — gap is a silent WARN"
  fi

  # Teeth I (#1455): a \$KIT/<p> mention that is only a literal (single-quoted or backslash-escaped
  # \$KIT) is no read and needs no binding; a bare, unquoted \$KIT/<p> still does.
  cat > "$TMP/fx/i1.test.sh" << 'FX_EOF'
ANCHOR='$KIT/TARGETS.md'
echo "missing \$KIT/TARGETS.md"
FX_EOF
  cat > "$TMP/fx/i2.test.sh" << 'FX_EOF'
ANCHOR='$KIT/TARGETS.md'
cat "$KIT/METHODOLOGY.md"
FX_EOF
  unc_i="$(unclassified_suites "$TMP/fx/i1.test.sh" "$TMP/fx/i2.test.sh")"
  if [ "$unc_i" = "i2.test.sh" ]; then
    ok "teeth I: literal \$KIT/ mentions (single-quoted, escaped) are not a read; a live one is still UNCLASSIFIED"
  else
    no "teeth I: literal-mention classification wrong: [$unc_i]"
  fi

  # Teeth K (#1455 follow-up): an apostrophe inside a double-quoted string is not a quote delimiter, so
  # a live `$KIT/<p>` read between it and a later single quote must stay classified and derived.
  # Mutant: the naive apostrophe-pair strip erases the read (suite silently `none`, nothing derived).
  cat > "$TMP/fx/k.test.sh" << 'FX_EOF'
HERE=x
KIT="$(cd "$HERE/../.." && pwd)"
echo "can't"; cat "$KIT/PROMPT-AUDIT.md"; y='z'
FX_EOF
  k_got="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/k.test.sh")"
  k_class="$(classify_kit_binding "$TMP/fx/k.test.sh")"
  k_fn="$(declare -f strip_kit_literals)"
  strip_kit_literals() { sed -E "s/'[^']*'//g"; }
  k_mut="$(classify_kit_binding "$TMP/fx/k.test.sh")"
  eval "$k_fn"
  if [ "$k_class" = real ] && [ "$k_got" = "research-sdd/PROMPT-AUDIT.md" ] && [ "$k_mut" != real ]; then
    ok "teeth K: apostrophe in a double-quoted string does not hide a live \$KIT read (naive pair-strip does)"
  else
    no "teeth K: class=[$k_class] derived=[$k_got] mutant-class=[$k_mut]"
  fi

  # Teeth L (#1455 follow-up): \$REPO/research-sdd/<p> is a real-tree read only when REPO is bound to the
  # real tree; a temp-bound REPO is a fixture and must not be derived. KIT="$REPO/research-sdd" is a real binding.
  cat > "$TMP/fx/l1.test.sh" << 'FX_EOF'
REPO="$ROOT/repo"
cat "$REPO/research-sdd/METHODOLOGY.md"
FX_EOF
  cat > "$TMP/fx/l2.test.sh" << 'FX_EOF'
TOOLBELT=x
REPO="$(cd "$TOOLBELT/../.." && pwd)"
KIT="$REPO/research-sdd"
cat "$REPO/research-sdd/PROMPT-AUDIT.md" "$KIT/PROMPT-LOOP.md"
FX_EOF
  l1="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/l1.test.sh")"
  l2="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/l2.test.sh")"
  if [ -z "$l1" ] && [ "$l2" = "$(printf 'research-sdd/PROMPT-AUDIT.md\nresearch-sdd/PROMPT-LOOP.md')" ]; then
    ok "teeth L: temp-bound REPO is not derived; real-bound REPO and KIT=\"\$REPO/research-sdd\" are"
  else
    no "teeth L: temp-REPO=[$l1] real-REPO=[$l2]"
  fi

  # Teeth J (#1455): every HERE-relative form is derived, one distinct real doc per form, so a form
  # the scanner drops names itself. Mutant: the pre-fix literal-only regex drops all but the first.
  cat > "$TMP/fx/j.test.sh" << 'FX_EOF'
REPO="$(cd "$TOOLBELT/../.." && pwd)"
a="$HERE/../../METHODOLOGY.md"
b="${HERE}/../../PROMPT-LOOP.md"
c="$HERE"/../../PROMPT-AUDIT.md
d="$TOOLBELT/../PROMPT-REFRESH.md"
e="${TOOLBELT}/../PROMPT-LOOP-APPENDIX.md"
f="$REPO/research-sdd/BREAKTHROUGHS.md"
g="${REPO}/research-sdd/README.md"
FX_EOF
  j_want="$(printf 'research-sdd/BREAKTHROUGHS.md\nresearch-sdd/METHODOLOGY.md\nresearch-sdd/PROMPT-AUDIT.md\nresearch-sdd/PROMPT-LOOP-APPENDIX.md\nresearch-sdd/PROMPT-LOOP.md\nresearch-sdd/PROMPT-REFRESH.md\nresearch-sdd/README.md')"
  j_got="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/j.test.sh")"
  j_mut="$(REAL_REF_RE='\$HERE/\.\./\.\./[A-Za-z0-9_./-]+'; REAL_REF_PREFIX_RE='^\$HERE/\.\./\.\./'; derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/j.test.sh")"
  if [ "$j_got" = "$j_want" ] && [ "$j_mut" != "$j_want" ]; then
    ok "teeth J: all 7 HERE/TOOLBELT/REPO-relative path forms are derived (and the literal-only regex drops some)"
  else
    no "teeth J: forms not all derived or mutant stayed green (got=[$j_got] mutant=[$j_mut])"
  fi

  # Teeth M (#1479): a `<<<word` here-string and a heredoc opener inside a trailing comment are NOT
  # heredocs; the live read after each must still be derived. Mutant: the pre-fix live_lines.
  cat > "$TMP/fx/m.test.sh" << 'FX_EOF'
HERE=x
KIT="$(cd "$HERE/../.." && pwd)"
grep foo <<< word
cat "$KIT/METHODOLOGY.md"
true  # cat <<EOF
cat "$KIT/PROMPT-LOOP.md"
FX_EOF
  m_want="$(printf 'research-sdd/METHODOLOGY.md\nresearch-sdd/PROMPT-LOOP.md')"
  m_got="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/m.test.sh")"
  m_fn="$(declare -f live_lines)"
  live_lines() {
    awk '
      heredoc != "" { t=$0; if (dash) sub(/^\t+/, "", t); if (t == heredoc) heredoc=""; next }
      /^[[:space:]]*#/ { next }
      {
        line=$0
        if (match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
          tag=substr(line, RSTART, RLENGTH); dash=(tag ~ /^<<-/)
          gsub(/^<<-?[[:space:]]*["\047]?|["\047]?$/, "", tag); heredoc=tag
        }
        sub(/[[:space:]]+#.*$/, "", line)
        print line
      }
    ' "$1"
  }
  m_mut="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/m.test.sh")"
  eval "$m_fn"
  if [ "$m_got" = "$m_want" ] && [ "$m_mut" != "$m_want" ]; then
    ok "teeth M: here-string and commented heredoc opener do not swallow later reads (pre-fix live_lines does)"
  else
    no "teeth M: got=[$m_got] mutant=[$m_mut]"
  fi

  # Teeth N (#1479 R3-toolbelt-prefix-partial-climb): a deeper climb than the recognised prefix is
  # matched by NOTHING — never partly stripped into a bare `..` or a parent-relative path.
  cat > "$TMP/fx/n.test.sh" << 'FX_EOF'
REPO="$(cd "$TOOLBELT/../.." && pwd)"
a="$TOOLBELT/../../METHODOLOGY.md"
b="$HERE/../../../PROMPT-LOOP.md"
c="$(cd "$TOOLBELT/../.." && pwd)"
d="$TOOLBELT/../PROMPT-AUDIT.md"
FX_EOF
  n_got="$(doc_refs_raw "$TMP/fx/n.test.sh")"
  if [ "$n_got" = "PROMPT-AUDIT.md" ]; then
    ok "teeth N: TOOLBELT/HERE over-climbs yield no partial token (only the exact climb is derived)"
  else
    no "teeth N: raw refs=[$n_got] (want only PROMPT-AUDIT.md)"
  fi

  # Teeth O (#1479 R2-001): the quoted-slash form binds as real for KIT and REPO — binding and
  # derivation regexes share one prefix definition, so they cannot drift.
  cat > "$TMP/fx/o.test.sh" << 'FX_EOF'
HERE=x
KIT="$HERE"/../..
cat "$KIT/METHODOLOGY.md"
FX_EOF
  cat > "$TMP/fx/o2.test.sh" << 'FX_EOF'
TOOLBELT=x
REPO="$TOOLBELT"/../..
cat "$REPO/research-sdd/PROMPT-LOOP.md"
FX_EOF
  o_got="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/o.test.sh" "$TMP/fx/o2.test.sh")"
  o_unc="$(unclassified_suites "$TMP/fx/o.test.sh" "$TMP/fx/o2.test.sh")"
  if [ "$o_got" = "$(printf 'research-sdd/METHODOLOGY.md\nresearch-sdd/PROMPT-LOOP.md')" ] && [ -z "$o_unc" ]; then
    ok "teeth O: quoted-slash KIT/REPO bindings classify real and derive"
  else
    no "teeth O: derived=[$o_got] unclassified=[$o_unc]"
  fi

  # Teeth P (#1479 R3-001): KIT set from a temp-bound REPO is a fixture, not the real kit — not derived,
  # and not UNCLASSIFIED either. KIT from an UNRECOGNISED REPO binding is UNCLASSIFIED.
  cat > "$TMP/fx/p1.test.sh" << 'FX_EOF'
REPO="$ROOT/repo"
KIT="$REPO/research-sdd"
cat "$KIT/METHODOLOGY.md"
FX_EOF
  cat > "$TMP/fx/p2.test.sh" << 'FX_EOF'
REPO="$(compute_repo_somehow)"
KIT="$REPO/research-sdd"
cat "$KIT/METHODOLOGY.md"
FX_EOF
  p_got="$(derive_doc_inputs "$REPO/research-sdd" "$TMP/fx/p1.test.sh")"
  p_unc="$(unclassified_suites "$TMP/fx/p1.test.sh" "$TMP/fx/p2.test.sh")"
  if [ -z "$p_got" ] && [ "$p_unc" = "p2.test.sh" ]; then
    ok "teeth P: KIT via a temp-bound REPO is a fixture (not derived, not unclassified); via an unknown REPO it is UNCLASSIFIED"
  else
    no "teeth P: derived=[$p_got] unclassified=[$p_unc]"
  fi

  # Teeth Q (#1479 R3-002): $REPO/research-sdd reads with an unrecognised or absent REPO binding are
  # UNCLASSIFIED (rc 2 through the harness), never silently dropped; temp and real REPO are not.
  cat > "$TMP/fx/q1.test.sh" << 'FX_EOF'
REPO="$(compute_repo_somehow)"
cat "$REPO/research-sdd/METHODOLOGY.md"
FX_EOF
  cat > "$TMP/fx/q2.test.sh" << 'FX_EOF'
cat "$REPO/research-sdd/METHODOLOGY.md"
FX_EOF
  q_unc="$(unclassified_suites "$TMP/fx/q1.test.sh" "$TMP/fx/q2.test.sh" "$TMP/fx/l1.test.sh" "$TMP/fx/l2.test.sh")"
  QR="$TMP/qrepo"; mkdir -p "$QR/research-sdd/toolbelt/tests" "$QR/.github/workflows"
  cp "$WORKFLOW" "$QR/.github/workflows/toolbelt-tests.yml"
  cp "$0" "$QR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh"
  cp "$TMP/fx/q1.test.sh" "$QR/research-sdd/toolbelt/tests/q1.test.sh"
  printf '#!/usr/bin/env bash\nprintf ".claude/settings.json\\n"\n' > "$QR/research-sdd/toolbelt/tests/harness-sweep-parity.test.sh"
  qrc=0
  bash "$QR/research-sdd/toolbelt/tests/ci-path-filter-coverage.test.sh" > "$TMP/q.out" 2>&1 || qrc=$?
  if [ "$q_unc" = "$(printf 'q1.test.sh\nq2.test.sh')" ] && [ "$qrc" -eq 2 ] && grep -q 'HARNESS ERROR: docs:.*UNCLASSIFIED.*q1\.test\.sh' "$TMP/q.out"; then
    ok "teeth Q: an unrecognised/absent REPO binding with \$REPO/research-sdd reads is UNCLASSIFIED (rc 2)"
  else
    no "teeth Q: unclassified=[$q_unc] rc=$qrc"
  fi

fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
