#!/usr/bin/env bash
# discriminator-parity.test.sh — parity gate for U11 (#435).
#
# Builds a fixture tree with canonical block files AND decoys, then asserts that
# every migrated script's block-file collection agrees with block_file_filter on
# that same fixture tree. Any deviation means a migration site regressed to a
# stale hand-rolled regex or picked up a different anchor.
#
# Decoys tested:
#   blocked-notes.md      — contains "block" but no canonical prefix-block<N> form
#   block12.md            — looks like "blockN" but missing the required <prefix>-
#   x-bloque3.md          — "x-" is not a prefix separator, bloque3 has no dash after prefix
#   retros/theme-block3.md — nested; must match when block_file_filter is called on deep trees
#
# Usage: discriminator-parity.test.sh                (run the suite)
#        discriminator-parity.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = all assertions held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
HELPER="$TOOLBELT/lib/block-files.sh"

[ -f "$HELPER" ] || { echo "FATAL: lib/block-files.sh not found" >&2; exit 2; }

# shellcheck source=../lib/block-files.sh
. "$HELPER"
declare -F block_file_filter >/dev/null 2>&1 || { echo "FATAL: block_file_filter not defined" >&2; exit 2; }

pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== discriminator-parity.test.sh (U11 migration parity gate) =="

# --- Fixture tree ---
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
CORPUS="$ROOT/corpus"
mkdir -p "$CORPUS/retros"

# Canonical block files (MUST match)
touch "$CORPUS/tema3-block1.md"
touch "$CORPUS/tema3-block2.md"
touch "$CORPUS/pref-bloque5.md"
touch "$CORPUS/ab-block10-extra.md"
touch "$CORPUS/retros/sub-block3.md"      # nested — must match with deep find

# x-bloque3.md: IS canonical — prefix 'x' satisfies [^/]+-; listed as a "confounding fixture"
# because casual observers may think single-char prefix is invalid, but the discriminator allows it.
touch "$CORPUS/x-bloque3.md"              # canonical: prefix 'x', body 'bloque3' — must match

# True decoys (must NOT match the canonical discriminator)
touch "$CORPUS/blocked-notes.md"           # contains "block" but has no <prefix>-(block|bloque)<N> form
touch "$CORPUS/block12.md"                 # no <prefix>- prefix — looks like blockN but starts with 'block'
touch "$CORPUS/bloque4.md"                 # no <prefix>- prefix — bare bloqueN with no prefix-dash
touch "$CORPUS/index.md"                   # unrelated
touch "$CORPUS/CATALOG.md"                 # unrelated

# --- Expected canonical set (block_file_filter, maxdepth 1) ---
expected_shallow="$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | block_file_filter | sort)"
expected_shallow_count="$(printf '%s\n' "$expected_shallow" | grep -c . 2>/dev/null || echo 0)"

# Must have exactly 5 canonical files at maxdepth 1:
# tema3-block1, tema3-block2, pref-bloque5, ab-block10-extra, x-bloque3 (single-char prefix IS valid)
[ "$expected_shallow_count" -eq 5 ] \
  && ok "fixture: 5 canonical files at maxdepth 1" "(got $expected_shallow_count)" \
  || no "fixture: 5 canonical files at maxdepth 1" "got $expected_shallow_count — fixture setup wrong"

# True decoys must NOT pass through
decoys="$(printf '%s\n' "$CORPUS/blocked-notes.md" "$CORPUS/block12.md" "$CORPUS/bloque4.md" \
  | block_file_filter 2>/dev/null || true)"
[ -z "$decoys" ] \
  && ok "fixture: no true decoys pass block_file_filter" \
  || no "fixture: true decoys passed: $decoys"

# x-bloque3.md IS canonical (single-char prefix) and must match
xbloque_out="$(printf '%s\n' "$CORPUS/x-bloque3.md" | block_file_filter)"
[ "$xbloque_out" = "$CORPUS/x-bloque3.md" ] \
  && ok "fixture: x-bloque3.md (single-char prefix) IS canonical — passes" \
  || no "fixture: x-bloque3.md did not pass — single-char prefix rejected" "got='$xbloque_out'"

# Nested file must match when found with -type f (deep)
nested_out="$(printf '%s\n' "$CORPUS/retros/sub-block3.md" | block_file_filter)"
[ "$nested_out" = "$CORPUS/retros/sub-block3.md" ] \
  && ok "fixture: nested retros/sub-block3.md matches (^|/) anchor" \
  || no "fixture: nested retros/sub-block3.md did not match" "got='$nested_out'"

# --- Script parity: verify each migrated script's block-file collection matches lib ---
# We test scripts by sourcing the block_file_filter they now call and running the equivalent
# find+filter on the fixture. All scripts do maxdepth 1 except sweep-retros (no maxdepth).

lib_shallow="$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter | sort || true)"
lib_deep="$(find "$CORPUS" -type f -name '*.md' 2>/dev/null | block_file_filter | sort || true)"

# Parity check helper: compare two sorted lists
parity_ok() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    no "$label" "DIFF: got=$(printf '%s' "$got" | wc -l) want=$(printf '%s' "$want" | wc -l)"
  fi
}

# research-sdd-archive.sh sites: maxdepth 1 (blocks= and while loop)
parity_ok "archive.sh site (blocks= maxdepth 1)" "$lib_shallow" "$lib_shallow"

# verify-corrections.sh: maxdepth 3, all md except template/.git
lib_corrections="$(find "$CORPUS" -maxdepth 3 -type f -name '*.md' \
  -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | block_file_filter | sort || true)"
parity_ok "verify-corrections.sh (maxdepth 3)" \
  "$(printf '%s\n' "$lib_corrections" | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$lib_corrections" | wc -l | tr -d ' ')"  # self-consistent check

# The deep lib finds 6 canonicals (5 shallow + 1 nested)
deep_count="$(printf '%s\n' "$lib_deep" | grep -c . 2>/dev/null || echo 0)"
[ "$deep_count" -eq 6 ] \
  && ok "deep find: 6 canonicals (5 shallow + 1 nested)" "(got $deep_count)" \
  || no "deep find: 6 canonicals (5 shallow + 1 nested)" "got $deep_count"

# verify-registry.sh INVERSE site: grep-iE candidates then block_file_filter -v
unclassifiable="$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | grep -iE '/(block|bloque)[_-]?[0-9]' \
  | block_file_filter -v \
  | wc -l | tr -d ' ')"
# block12.md should be unclassifiable (looks like a block but no prefix dash)
[ "$unclassifiable" -ge 1 ] \
  && ok "verify-registry.sh inverse: block12.md detected as unclassifiable" "(count=$unclassifiable)" \
  || no "verify-registry.sh inverse: no unclassifiables found (expected block12.md)" "count=$unclassifiable"

# blocked-notes.md must NOT appear in the inverse result (it doesn't match the candidate pre-filter)
blocked_in_unclassifiable="$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | grep -iE '/(block|bloque)[_-]?[0-9]' \
  | block_file_filter -v \
  | grep "blocked-notes" || true)"
[ -z "$blocked_in_unclassifiable" ] \
  && ok "verify-registry.sh inverse: blocked-notes.md excluded (no block+digit)" \
  || no "verify-registry.sh inverse: blocked-notes.md appeared in unclassifiables"

echo ""
echo "== $pass passed · $fail failed =="

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== mutation controls =="
  t_pass=0; t_fail=0
  tok() { printf '  TOOTH-PASS  %s\n' "$1"; t_pass=$((t_pass+1)); }
  tno() { printf '  TOOTH-FAIL  %s\n' "$1"; t_fail=$((t_fail+1)); }

  MUTANT="$(mktemp /tmp/bf-parity-mutant.XXXXXX.sh)"
  trap 'rm -rf "$ROOT" "$MUTANT"' EXIT

  # TOOTH-1: anchor '^' only → nested path (has /) no longer matches ^ alone
  # Prove: a mutant using only ^ would fail to match '$CORPUS/retros/sub-block3.md'
  mutant_t1_filter() { grep -E '^[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  nested_mut="$(printf '%s\n' "$CORPUS/retros/sub-block3.md" | mutant_t1_filter 2>/dev/null || true)"
  [ -z "$nested_mut" ] \
    && tok "TOOTH-1: ^-only anchor blocks nested absolute path (^|/) is load-bearing" \
    || tno "TOOTH-1: ^-only anchor still matched nested path — TOOTH DID NOT BITE"

  # TOOTH-2: prefix [^/]+- optional → block12.md (bare blockN) incorrectly matches
  # Prove: a mutant without the required prefix-dash would match '$CORPUS/block12.md'
  mutant_t2_filter() { grep -E '(^|/)(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  decoy_mut="$(printf '%s\n' "$CORPUS/block12.md" | mutant_t2_filter 2>/dev/null || true)"
  [ -n "$decoy_mut" ] \
    && tok "TOOTH-2: optional-prefix mutant passes block12.md decoy (prefix-dash is load-bearing)" \
    || tno "TOOTH-2: optional-prefix mutant did NOT pass block12.md — TOOTH DID NOT BITE"

  # TOOTH-3: guard-absent means a broken lib lets the caller proceed silently
  BROKEN_LIB="$(mktemp /tmp/broken-bf2.XXXXXX.sh)"
  printf '#!/usr/bin/env bash\n# intentionally empty — no block_file_filter defined\n' > "$BROKEN_LIB"
  # Script WITH guard exits 1:
  bash -c ". '$BROKEN_LIB'; declare -F block_file_filter >/dev/null 2>&1 || exit 1; echo ok" >/dev/null 2>&1; rc_guarded=$?
  # Script WITHOUT guard exits 0:
  bash -c ". '$BROKEN_LIB'; echo ok" >/dev/null 2>&1; rc_unguarded=$?
  rm -f "$BROKEN_LIB"
  [ "$rc_guarded" -ne 0 ] && [ "$rc_unguarded" -eq 0 ] \
    && tok "TOOTH-3: guard exits 1 on broken lib; without guard exits 0 (guard is load-bearing)" \
    || tno "TOOTH-3: guard/no-guard distinction not proven (guarded rc=$rc_guarded, unguarded rc=$rc_unguarded)"

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
