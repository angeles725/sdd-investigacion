#!/usr/bin/env bash
# Bridge suite for the Go module research-sdd/rsdd (go-port plan U0.1, kit issue #2271).
# Runs `go test ./...` in the module and reports each Go package as one case, so run-all.sh
# carries the Go result in its `== N passed · M failed ==` summary contract.
#
#   go absent        typed SKIP (exit 0) - FAIL instead under RSDD_REQUIRE_GO=1 (CLAUDE.md section 7:
#                    a missing prerequisite must never read as coverage in CI)
#   --prove-teeth    one mutation control on a COPY of the module in $TMPDIR (never the live tree):
#                    removing the panic boundary in internal/cli must turn the Go tests red
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../rsdd"
[ -f "$MOD/go.mod" ] || { echo "FATAL: Go module not found: $MOD" >&2; exit 2; }
MOD="$(cd "$MOD" && pwd)"

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

if ! command -v go >/dev/null 2>&1; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
    no "go not in PATH and RSDD_REQUIRE_GO=1 - a missing Go toolchain must fail, not skip"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  echo "SKIP: go not in PATH - Go suite skipped (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go.XXXXXX")"; trap 'rm -rf "$ROOT"' EXIT

# Case 1..N: one case per Go package that has tests. `go test` prints `ok <pkg>` or `FAIL <pkg>`;
# `?  <pkg> [no test files]` is neither. A non-zero exit with no FAIL line (build or setup error)
# is itself one failure, and zero tested packages is a failure (a silent zero proves nothing).
out="$ROOT/gotest.out"
( cd "$MOD" && go test -count=1 ./... ) >"$out" 2>&1
rc=$?
npass="$(awk '$1=="ok"{n++} END{print n+0}' "$out")"
nfail="$(awk '$1=="FAIL" && $2!=""{n++} END{print n+0}' "$out")"
while read -r _ pkg _; do ok "go test: $pkg"; done < <(awk '$1=="ok"{print}' "$out")
while read -r _ pkg _; do no "go test: $pkg"; done < <(awk '$1=="FAIL" && $2!=""{print}' "$out")
if [ "$rc" -ne 0 ] && [ "$nfail" -eq 0 ]; then
  no "go test exited $rc with no per-package FAIL line (build/setup error); tail follows"
  tail -n 15 "$out"
fi
if [ "$npass" -eq 0 ] && [ "$nfail" -eq 0 ] && [ "$rc" -eq 0 ]; then
  no "go test ran zero test packages - refusing to read that as a pass"
fi
if [ "$fail" -ne 0 ]; then tail -n 30 "$out"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# --prove-teeth mutation control
# ---------------------------------------------------------------------------
echo "--- mutation control ---"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2

# ONE mutation: disable the panic boundary in internal/cli/cli.go (recover() can no longer fire).
# The runner copies the module into a scratch dir, drops the file under test over
# internal/cli/cli.go, and runs the cli package tests. The original must pass; the mutant must fail
# because the panic ESCAPES (output carries the test command's panic text), not because of a
# compile error.
ORIG_GO="$MOD/internal/cli/cli.go"
MUTDIR="$ROOT/mut"; mkdir -p "$MUTDIR"
cat > "$MUTDIR/run_cli_tests.sh" <<'SH'
#!/usr/bin/env bash
# usage: run_cli_tests.sh MODULE_DIR CLI_GO
mod="$1"; cli_go="$2"
w="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go-mut.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cp -a "$mod/." "$w/" || { echo "SETUP-FAILED: cannot copy module"; exit 9; }
cp "$cli_go" "$w/internal/cli/cli.go" || { echo "SETUP-FAILED: cannot place file"; exit 9; }
cd "$w" && go test -count=1 ./internal/cli/ 2>&1
SH
if MUTANT_SYNTAX=none mutant_chain_or_count fail "panic-boundary mutation" "$ORIG_GO" "$MUTDIR/cli.go" \
    's/if r := recover(); r != nil {/if r := interface{}(nil); r != nil {/'; then
  if mutant_tooth "teeth: removing the panic boundary turns the cli tests red" 0 1 \
      "$MUTDIR/cli.go" --orig "$ORIG_GO" \
      --good-has '^ok' --bad-has 'kaboom' --bad-lacks 'SETUP-FAILED|build failed|undefined:' -- \
      bash "$MUTDIR/run_cli_tests.sh" "$MOD" @SUT@; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
