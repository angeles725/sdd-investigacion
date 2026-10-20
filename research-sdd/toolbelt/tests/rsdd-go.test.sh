#!/usr/bin/env bash
# Bridge suite for the Go module research-sdd/rsdd (go-port plan U0.1, kit issue #2271).
# Runs `go test ./...` in the module and reports each Go package as one case, so run-all.sh
# carries the Go result in its `== N passed · M failed ==` summary contract.
#
#   go absent        typed SKIP (exit 0) - FAIL instead under RSDD_REQUIRE_GO=1 (CLAUDE.md section 7:
#                    a missing prerequisite must never read as coverage in CI)
#   go too old       `go` older than go.mod's directive: typed SKIP "toolchain too old: have X need Y",
#                    or FAIL under RSDD_REQUIRE_GO=1. Go runs with GOTOOLCHAIN=local and an empty GOFLAGS,
#                    so the result never depends on a downloaded toolchain or ambient flags.
#   --parse FILE     (internal) count the package results in a captured `go test` output: prints
#                    `pass=N fail=M`, exit 1 when M > 0. The bridge's own counter is tested through it.
#   --prove-teeth    one mutation control on a COPY of the module in $TMPDIR (never the live tree):
#                    removing the panic boundary in internal/cli must turn the Go tests red
set -uo pipefail

# count_go_output FILE -> "pass=N fail=M": one count per `ok <pkg>` / `FAIL <pkg>` line of `go test`.
# `?  <pkg> [no test files]` is neither; a `FAIL` with no package (summary line) is not counted.
count_go_output() {
  awk '$1=="ok"{p++} $1=="FAIL" && $2!=""{f++} END{printf "pass=%d fail=%d\n", p+0, f+0}' "$1"
}

# decide_gremlins FILE RC -> prints the report line(s), then `VERDICT: PASS|FAIL|SKIP <detail>`.
# Gate = no LIVED mutant among the covered ones. Timed-out and not-covered mutants are reported, never
# failed. No parsable summary (gremlins could not run: no network, no module cache, no build) is a SKIP -
# or a FAIL under RSDD_REQUIRE_GO=1; it is never a silent pass.
decide_gremlins() {
  local f="$1" rc="$2" counts l
  counts="$(awk '
    /^Killed:/   { gsub(/,/,""); k=$2; l=$4; n=$7; seen=1 }
    /^Timed out:/{ gsub(/,/,""); t=$3 }
    END { if (seen) printf "killed=%d lived=%d timed_out=%d not_covered=%d\n", k, l, t, n }' "$f")"
  if [ -z "$counts" ]; then
    local why; why="$(tail -n 3 "$f" | tr '\n' ' ')"
    if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then echo "VERDICT: FAIL gremlins did not run (rc=$rc, RSDD_REQUIRE_GO=1): $why"
    else echo "VERDICT: SKIP gremlins did not run (rc=$rc): $why"; fi
    return 0
  fi
  echo "gremlins: $counts"
  l="${counts#*lived=}"; l="${l%% *}"
  if [ "$l" -gt 0 ]; then
    awk '/ LIVED / && / at /{sub(/.* at /,""); print "  LIVED at " $0}' "$f"
    echo "VERDICT: FAIL $l lived mutant(s) among the covered ones"
  else
    echo "VERDICT: PASS no lived mutants ($counts)"
  fi
}

if [ "${1:-}" = "--decide-gremlins" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --decide-gremlins needs a readable FILE" >&2; exit 2; }
  decide_gremlins "$2" "${3:-0}"; exit 0
fi

if [ "${1:-}" = "--parse" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --parse needs a readable FILE" >&2; exit 2; }
  res="$(count_go_output "$2")"; echo "$res"
  [ "${res##*fail=}" -eq 0 ]; exit $?
fi

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

# Hermetic toolchain: never download a newer one, ignore ambient flags and workspaces.
export GOTOOLCHAIN=local GOFLAGS='' GOWORK=off
have="$(go version | awk '{sub(/^go/, "", $3); print $3}')"
need="$(awk '$1=="go"{print $2; exit}' "$MOD/go.mod")"
echo "go: $(go version) (go.mod needs $need)"
oldest="$(printf '%s\n%s\n' "$have" "$need" | sort -V | sed -n 1p)"
if [ -z "$have" ] || [ -z "$need" ] || { [ "$oldest" = "$have" ] && [ "$have" != "$need" ]; }; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
    no "toolchain too old: have ${have:-unknown} need ${need:-unknown} (RSDD_REQUIRE_GO=1)"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  echo "SKIP: toolchain too old: have ${have:-unknown} need ${need:-unknown} - Go suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go.XXXXXX")"; trap 'rm -rf "$ROOT"' EXIT

# Case 1..N: one case per Go package that has tests. `go test` prints `ok <pkg>` or `FAIL <pkg>`;
# `?  <pkg> [no test files]` is neither. A non-zero exit with no FAIL line (build or setup error)
# is itself one failure, and zero tested packages is a failure (a silent zero proves nothing).
out="$ROOT/gotest.out"
( cd "$MOD" && go test -count=1 ./... ) >"$out" 2>&1
rc=$?
counts="$(count_go_output "$out")"
npass="${counts#pass=}"; npass="${npass%% *}"
nfail="${counts##*fail=}"
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

# Self-check of the bridge's own counter: canned FAILING go test output must count as a failure and exit
# 1; canned green output must not. Without this a parser that silently reads 0 failures would pass any run.
cat > "$ROOT/canned-fail.out" <<'CANNED'
ok  	example.test/m/a	0.004s
--- FAIL: TestX (0.00s)
FAIL
FAIL	example.test/m/b	0.005s
?   	example.test/m/c	[no test files]
FAIL
CANNED
printf 'ok  \texample.test/m/a\t0.004s\n' > "$ROOT/canned-ok.out"
bad="$(bash "$0" --parse "$ROOT/canned-fail.out")"; badrc=$?
good="$(bash "$0" --parse "$ROOT/canned-ok.out")"; goodrc=$?
if [ "$bad" = "pass=1 fail=1" ] && [ "$badrc" -eq 1 ] && [ "$good" = "pass=1 fail=0" ] && [ "$goodrc" -eq 0 ]; then
  ok "counter: canned failing output counts fail=1 and exits 1; canned green output exits 0"
else
  no "counter: got bad='$bad' rc=$badrc good='$good' rc=$goodrc"
fi

# Toolchain gate, via a fake `go` that reports an old version (never runs a test).
FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.20.1 linux/amd64"\nexit 0\n' > "$FAKEBIN/go"; chmod +x "$FAKEBIN/go"
old="$(PATH="$FAKEBIN:$PATH" RSDD_REQUIRE_GO='' bash "$0" 2>&1)"; oldrc=$?
if [ "$oldrc" -eq 0 ] && grep -q 'SKIP: toolchain too old: have 1.20.1 need ' <<<"$old"; then
  ok "toolchain: old go -> typed SKIP naming have and need"
else no "toolchain: old go should SKIP (rc=$oldrc): $old"; fi
oldreq="$(PATH="$FAKEBIN:$PATH" RSDD_REQUIRE_GO=1 bash "$0" 2>&1)"; oldreqrc=$?
if [ "$oldreqrc" -eq 1 ] && grep -q 'FAIL  toolchain too old: have 1.20.1' <<<"$oldreq"; then
  ok "toolchain: old go under RSDD_REQUIRE_GO=1 -> FAIL"
else no "toolchain: old go with REQUIRE should FAIL (rc=$oldreqrc): $oldreq"; fi

# Gremlins verdict parser, on canned output.
cat > "$ROOT/gr-lived.out" <<'CANNED'
      KILLED CONDITIONALS_NEGATION at internal/cli/cli.go:10:5
       LIVED CONDITIONALS_BOUNDARY at internal/cli/cli.go:161:73
Killed: 5, Lived: 1, Not covered: 2
Timed out: 3, Not viable: 0, Skipped: 0
CANNED
cat > "$ROOT/gr-timeouts.out" <<'CANNED'
   TIMED OUT CONDITIONALS_NEGATION at internal/cli/cli.go:10:5
Killed: 5, Lived: 0, Not covered: 2
Timed out: 3, Not viable: 0, Skipped: 0
CANNED
printf 'go: downloading honnef.co/go/tools\ndial tcp: lookup proxy.golang.org: no such host\n' > "$ROOT/gr-unavailable.out"
g="$(bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0)"
if grep -q '^VERDICT: FAIL 1 lived' <<<"$g" && grep -q 'LIVED at internal/cli/cli.go:161:73' <<<"$g" && grep -q 'killed=5 lived=1 timed_out=3 not_covered=2' <<<"$g"; then
  ok "gremlins: a lived mutant FAILs and prints file:line; counts printed"; else no "gremlins: lived case wrong: $g"; fi
g="$(bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0)"
if grep -q '^VERDICT: PASS' <<<"$g" && grep -q 'timed_out=3' <<<"$g"; then
  ok "gremlins: lived=0 with timeouts PASSes and reports the timeouts"; else no "gremlins: timeouts case wrong: $g"; fi
g="$(RSDD_REQUIRE_GO='' bash "$0" --decide-gremlins "$ROOT/gr-unavailable.out" 1)"
if grep -q '^VERDICT: SKIP gremlins did not run (rc=1)' <<<"$g"; then
  ok "gremlins: tool unavailable -> typed SKIP"; else no "gremlins: unavailable case wrong: $g"; fi
g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$ROOT/gr-unavailable.out" 1)"
if grep -q '^VERDICT: FAIL gremlins did not run (rc=1, RSDD_REQUIRE_GO=1)' <<<"$g"; then
  ok "gremlins: tool unavailable under RSDD_REQUIRE_GO=1 -> FAIL"; else no "gremlins: required-unavailable case wrong: $g"; fi

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

# Tooth for the counter: blind the parser to FAIL lines (it would then report fail=0 on canned failing
# output). The suite itself is the SUT (`--parse FILE`): the original must exit 1 with fail=1, the mutant
# must exit 0 with fail=0.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "counter mutation" "$0" "$MUTDIR/rsdd-go.test.sh" \
    's/\$1=="FAIL" \&\& \$2!=""{f++}/$1=="XFAIL" \&\& $2!=""{f++}/'; then
  if mutant_tooth "teeth: a parser blind to FAIL lines misses canned failing output" 1 0 \
      "$MUTDIR/rsdd-go.test.sh" --orig "$0" \
      --good-has 'fail=1' --bad-has 'fail=0' -- \
      bash @SUT@ --parse "$ROOT/canned-fail.out"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Mutation testing (gremlins, pinned in the Makefile): the gate is zero LIVED mutants among covered ones.
t0=$SECONDS
make -C "$MOD" teeth >"$ROOT/gremlins.out" 2>&1; mrc=$?
verdict="$(decide_gremlins "$ROOT/gremlins.out" "$mrc")"
echo "$verdict" | grep -v '^VERDICT:'
echo "gremlins wall time: $((SECONDS - t0))s"
case "$verdict" in
  *"VERDICT: PASS"*) ok "teeth: gremlins found no lived mutant" ;;
  *"VERDICT: SKIP"*) echo "SKIP: ${verdict##*VERDICT: SKIP }" ;;
  *) no "teeth: gremlins: ${verdict##*VERDICT: }" ;;
esac

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
