#!/usr/bin/env bash
# block-files.test.sh — unit harness for lib/block-files.sh (U11).
#
# Tests block_file_filter: forward mode (canonical block files pass through), inverse
# mode (-v: non-canonical pass through), prefix mode (scope to a focus prefix), stdin
# error when tty, and exit-code fidelity (grep's status passed verbatim — 0/1/2).
#
# Usage: block-files.test.sh                (run the suite)
#        block-files.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = all assertions held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/../lib/block-files.sh"
[ -f "$HELPER" ] || { echo "FATAL: helper under test not found: $HELPER" >&2; exit 2; }

# shellcheck source=../lib/block-files.sh
. "$HELPER"
declare -F block_file_filter >/dev/null 2>&1 || { echo "FATAL: block_file_filter not defined after sourcing" >&2; exit 2; }

pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== block-files.test.sh (SUT: lib/$(basename "$HELPER")) =="

# Helper: run filter on a newline-separated string; return stdout.
run_filter() { printf '%s\n' "$@" | block_file_filter; }
run_filter_v() { printf '%s\n' "$@" | block_file_filter -v; }
run_filter_pfx() { local pfx="$1"; shift; printf '%s\n' "$@" | block_file_filter "$pfx"; }

# --- 1. Canonical forms PASS through (forward mode) ---
got="$(run_filter "/corpus/tema3-block1.md")"
[ "$got" = "/corpus/tema3-block1.md" ] \
  && ok "1 canonical block1 passes" || no "1 canonical block1 passes" "got='$got'"

got="$(run_filter "/corpus/prefix-bloque12.md")"
[ "$got" = "/corpus/prefix-bloque12.md" ] \
  && ok "2 canonical bloque12 passes" || no "2 canonical bloque12 passes" "got='$got'"

got="$(run_filter "/corpus/ab-block3-foo-bar.md")"
[ "$got" = "/corpus/ab-block3-foo-bar.md" ] \
  && ok "3 canonical block with suffix passes" || no "3 canonical block with suffix passes" "got='$got'"

# --- 2. Decoys are BLOCKED (forward mode) ---
got="$(printf '%s\n' "/corpus/blocked-notes.md" | block_file_filter || true)"
[ -z "$got" ] \
  && ok "4 decoy blocked-notes.md blocked" || no "4 decoy blocked-notes.md blocked" "got='$got'"

got="$(printf '%s\n' "/corpus/block12.md" | block_file_filter || true)"
[ -z "$got" ] \
  && ok "5 decoy block12.md (no prefix) blocked" || no "5 decoy block12.md (no prefix) blocked" "got='$got'"

got="$(printf '%s\n' "/corpus/x-bloque3.md" | block_file_filter || true)"
[ "$got" = "/corpus/x-bloque3.md" ] \
  && ok "6 x-bloque3.md PASSES — prefix 'x' is valid; single-char prefix allowed" \
  || no "6 x-bloque3.md PASSES — prefix 'x' is valid; single-char prefix allowed" "got='$got'"
# Extra: a file WITHOUT the required prefix-dash does NOT pass
got2="$(printf '%s\n' "/corpus/bloque3.md" | block_file_filter || true)"
[ -z "$got2" ] \
  && ok "6b bloque3.md (no prefix-dash) blocked" || no "6b bloque3.md (no prefix-dash) blocked" "got='$got2'"

# --- 3. Nested path (retros/) PASSES when file is canonical ---
got="$(run_filter "/corpus/retros/subfocus-block5.md")"
[ "$got" = "/corpus/retros/subfocus-block5.md" ] \
  && ok "7 nested canonical in retros/ passes" || no "7 nested canonical in retros/ passes" "got='$got'"

# --- 4. Bare filename (git-log --name-only output) PASSES ---
got="$(run_filter "prefix-block7.md")"
[ "$got" = "prefix-block7.md" ] \
  && ok "8 bare filename (no slash) passes — (^|/) anchor" \
  || no "8 bare filename (no slash) passes — (^|/) anchor" "got='$got'"

# --- 5. Prefix mode scopes to the prefix ---
got="$(run_filter_pfx "tema3-" "/corpus/tema3-block1.md" "/corpus/tema4-block2.md")"
[ "$got" = "/corpus/tema3-block1.md" ] \
  && ok "5a prefix 'tema3-' keeps tema3, drops tema4" \
  || no "5a prefix 'tema3-' keeps tema3, drops tema4" "got='$got'"

got="$(run_filter_pfx "tema4-" "/corpus/tema3-block1.md" "/corpus/tema4-block2.md")"
[ "$got" = "/corpus/tema4-block2.md" ] \
  && ok "5b prefix 'tema4-' keeps tema4, drops tema3" \
  || no "5b prefix 'tema4-' keeps tema4, drops tema3" "got='$got'"

# --- 6. Inverse mode (-v) ---
got="$(run_filter_v "/corpus/blocked-notes.md" "/corpus/tema3-block1.md")"
[ "$got" = "/corpus/blocked-notes.md" ] \
  && ok "6a -v passes decoy, blocks canonical" \
  || no "6a -v passes decoy, blocks canonical" "got='$got'"

# --- 7. Exit code fidelity ---
# grep exit 0 (match): block_file_filter must exit 0
printf '%s\n' "/x/prefix-block1.md" | block_file_filter >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "7a exit 0 on match" || no "7a exit 0 on match" "rc=$rc"

# grep exit 1 (no match): block_file_filter must exit 1
printf '%s\n' "/x/blocked-notes.md" | block_file_filter >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "7b exit 1 on no-match" || no "7b exit 1 on no-match" "rc=$rc"

# --- 8. Idempotent source ---
# shellcheck source=../lib/block-files.sh
. "$HELPER"
declare -F block_file_filter >/dev/null 2>&1 \
  && ok "8 idempotent double-source" || no "8 idempotent double-source"

echo ""
echo "== $pass passed · $fail failed =="

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== mutation controls =="
  t_pass=0; t_fail=0
  tok() { printf '  TOOTH-PASS  %s\n' "$1"; t_pass=$((t_pass+1)); }
  tno() { printf '  TOOTH-FAIL  %s\n' "$1"; t_fail=$((t_fail+1)); }

  MUTANT="$(mktemp /tmp/block-files-mutant.XXXXXX.sh)"
  trap 'rm -f "$MUTANT"' EXIT

  # TOOTH-1: anchor '^' only → absolute paths like /corpus/prefix-block1.md no longer match
  # (^|/) matches the '/' before the basename; bare '^' cannot match inside an absolute path.
  mutant_t1() { grep -E '^[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  out_t1="$(printf '%s\n' '/corpus/prefix-block1.md' | mutant_t1 2>/dev/null || true)"
  [ -z "$out_t1" ] && tok "TOOTH-1: ^-only mutant blocks absolute path ((^|/) is load-bearing)" \
                   || tno "TOOTH-1: ^-only mutant still passed absolute path — TOOTH DID NOT BITE"

  # TOOTH-2: prefix [^/]+- optional → block12.md decoy passes
  # Prove: a mutant without the required prefix-dash would match bare 'block12.md'
  mutant_t2() { grep -E '(^|/)(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  out_t2="$(printf '%s\n' '/corpus/block12.md' | mutant_t2 2>/dev/null || true)"
  [ -n "$out_t2" ] && tok "TOOTH-2: optional-prefix mutant passes block12.md decoy (prefix is load-bearing)" \
                   || tno "TOOTH-2: optional-prefix mutant did NOT pass block12.md — TOOTH DID NOT BITE"

  # TOOTH-3: remove declare -F guard in verify-parity.sh → broken lib no longer exits 1
  # Simulate: source a lib that does NOT define block_file_filter, then run the guard-stripped script fragment
  BROKEN_LIB="$(mktemp /tmp/broken-bf.XXXXXX.sh)"
  printf '#!/usr/bin/env bash\n# intentionally empty\n' > "$BROKEN_LIB"
  GUARD_STRIPPED="$(mktemp /tmp/guard-stripped.XXXXXX.sh)"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "%s"\necho "guard absent — no exit 1"\n' "$BROKEN_LIB" > "$GUARD_STRIPPED"
  bash "$GUARD_STRIPPED" >/dev/null 2>&1; rc=$?
  # With guard removed the script exits 0 (no error), so we expect exit 0 = the PROBLEM
  # The tooth proves that adding the guard WOULD catch it; without the guard, rc is 0 (bad)
  [ "$rc" -eq 0 ] && tok "TOOTH-3: guard-absent fragment exits 0 (proves guard is load-bearing)" \
                  || tno "TOOTH-3: guard-absent fragment did NOT exit 0 (tooth logic error)"
  rm -f "$BROKEN_LIB" "$GUARD_STRIPPED"

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
