#!/usr/bin/env bash
# corroborate-bacnet.test.sh — the end-to-end check of the corroborate-bacnet.sh compatibility shim (kit issue #2438,
# epic #2270; bacnet-evidence.v1).
#
# The probe moved to Go: `rsdd bacnet corroborate-bacnet` (research-sdd/rsdd/internal/bacnet). Its cases (frame
# builders and parsers, the live probe against scripted and loopback responders, the legacy Python as the oracle
# for every output byte, and the Go mutation controls) live in the Go tests (`go test ./internal/bacnet`,
# `make teeth`). This suite keeps the offline end-to-end cases through the shim and the mutation controls of the
# shim itself. All cases are OFFLINE: no live BACnet/IP network is needed or touched.
#
# Usage: corroborate-bacnet.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/corroborate-bacnet.sh"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth || exit 2
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)" || exit 2
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# The SUT hands over to the Go binary. $RSDD_BIN wins; otherwise one binary is built into the suite temp dir (never
# into the tree). A suite that cannot get rsdd says so with a typed SKIP, or FAILS under RSDD_REQUIRE_GO=1.
if [ -z "${RSDD_BIN:-}" ] || [ ! -x "${RSDD_BIN:-}" ]; then
  if ! command -v go >/dev/null 2>&1; then
    why="go not in PATH"
    [ -z "${RSDD_BIN:-}" ] || why="RSDD_BIN is not an executable file ($RSDD_BIN) and go is not in PATH"
    if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
      echo "  FAIL  rsdd-unavailable: $why (RSDD_REQUIRE_GO=1)"; echo "== 0 passed · 1 failed =="; exit 1
    fi
    echo "SKIP rsdd-unavailable: $why (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
    echo "== 0 passed · 0 failed =="; exit 0
  fi
  RSDD_BIN="$ROOT/rsdd"
  ( cd "$TB/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$RSDD_BIN" ./cmd/rsdd ) >"$ROOT/build.log" 2>&1 \
    || { echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$ROOT/build.log" >&2; exit 2; }
fi
export RSDD_BIN
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (the JSON checks need it)" >&2; exit 2; }

# T1: absent --allow-live-probe -> exit 3 (plan-only guard). 192.0.2.1 (TEST-NET, RFC 5737) is unreachable even if
# the guard were bypassed; exit 3 must come from the guard, not a timeout.
"$SUT" --host 192.0.2.1 --output "$ROOT/t1" 2>/dev/null
t1_code=$?
if [ "$t1_code" -eq 3 ]; then ok "plan-only guard: exit 3 without --allow-live-probe"
else no "plan-only guard: expected exit 3, got $t1_code"; fi

# T2: plan-only JSON written and the schema is correct
if python3 - "$ROOT/t1/bacnet-evidence.v1.json" <<'PY'
import json, sys, os
p = sys.argv[1]
assert os.path.exists(p), f"plan-only JSON not written at: {p}"
d = json.load(open(p))
assert d.get('schema') == 'bacnet-evidence.v1', f"wrong schema: {d.get('schema')!r}"
assert d.get('status') == 'plan-only', f"expected plan-only, got: {d.get('status')!r}"
assert d.get('host') == '192.0.2.1', f"host mismatch: {d.get('host')!r}"
assert isinstance(d.get('port'), int), f"port not int: {d.get('port')!r}"
assert 'guard' in d, "guard field missing from plan-only output"
plan = d.get('plan', {})
assert plan.get('read_only') is True, "plan.read_only must be true"
probes = plan.get('probes', [])
assert 'unicast-who-is' in probes, "unicast-who-is missing from plan.probes"
assert 'read-bdt' in probes, "read-bdt missing from plan.probes"
PY
then ok "plan-only JSON schema: required fields present and correct"
else no "plan-only JSON schema"; fi

# T3: missing --host -> non-zero exit (usage error)
if ! "$SUT" --output "$ROOT/t3" 2>/dev/null; then ok "missing --host: non-zero exit"
else no "missing --host: expected non-zero exit, got 0"; fi

# T4: missing --output -> non-zero exit (usage error)
if ! "$SUT" --host 192.0.2.1 2>/dev/null; then ok "missing --output: non-zero exit"
else no "missing --output: expected non-zero exit, got 0"; fi

# T5: --json writes valid JSON to stdout (plan-only path)
"$SUT" --host 192.0.2.1 --output "$ROOT/t5" --json > "$ROOT/t5_stdout.json" 2>/dev/null || true
if python3 - "$ROOT/t5_stdout.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('schema') == 'bacnet-evidence.v1', f"wrong schema: {d.get('schema')!r}"
PY
then ok "--json flag: stdout is valid bacnet-evidence.v1 JSON"
else no "--json flag: stdout is not valid JSON or wrong schema"; fi

# T6: --port override is reflected in the plan-only output
"$SUT" --host 192.0.2.1 --port 47809 --output "$ROOT/t6" 2>/dev/null || true
if python3 - "$ROOT/t6/bacnet-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('port') == 47809, f"port not reflected: {d.get('port')!r}"
PY
then ok "--port override reflected in plan-only output"
else no "--port override"; fi

# T7: bad --port (>65535) with --allow-live-probe -> exit 2 (operational error), no evidence file. The port check
# fires before any kernel I/O, so this sends no network frame.
mkdir -p "$ROOT/t7"
"$SUT" --host 192.0.2.1 --port 70000 --allow-live-probe --output "$ROOT/t7" 2>"$ROOT/t7.err"
t7_code=$?
if [ "$t7_code" -eq 2 ] && [ ! -f "$ROOT/t7/bacnet-evidence.v1.json" ] && grep -q 'port must be 0-65535' "$ROOT/t7.err"; then
  ok "bad-port exit-2: exits 2 with no evidence file on port overflow"
else
  no "bad-port exit-2: expected exit 2 + no evidence; got exit $t7_code, evidence=$([ -f "$ROOT/t7/bacnet-evidence.v1.json" ] && echo yes || echo no)"
fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: corroborate-bacnet.sh shim mutation controls --"
# a mutant of the shim must still find lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib"
# each tooth run writes into a fresh directory; an exit 3 that did not write this tool's plan is exit 9
printf '%s\n' '#!/usr/bin/env bash' 'out="$(mktemp -u "$2/toothXXXXXX")" || exit 2' '"$1" --host 192.0.2.1 --output "$out"; rc=$?' \
  '[ "$rc" -ne 3 ] || [ -f "$out/bacnet-evidence.v1.json" ] || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
mkdir -p "$ROOT/teeth-out"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/teeth-out"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to an unknown command" 's/rsdd_exec bacnet corroborate-bacnet/rsdd_exec bacnet corroborate-nope/' 3 2
tooth "shim dispatches to an unknown group" 's/rsdd_exec bacnet corroborate-bacnet/rsdd_exec nope corroborate-bacnet/' 3 2
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 3 2
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
