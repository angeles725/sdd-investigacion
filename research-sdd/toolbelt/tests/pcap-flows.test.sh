#!/usr/bin/env bash
# pcap-flows.test.sh — the end-to-end check of the pcap-flows.sh compatibility shim (kit issue #2485, epic #2270).
#
# The tool moved to Go: `rsdd corroborate pcap-flows` (research-sdd/rsdd/internal/corroborate/pcap). Its cases (every
# legacy case of this suite, a ~100-scenario byte-for-byte comparison against the frozen legacy Python as the oracle,
# the parsers fuzzed against the legacy functions, and the Go mutation controls) live in the Go tests
# (`go test ./internal/corroborate/pcap`, `make teeth`). This suite keeps a few end-to-end cases through the shim
# with the real tshark and Bubblewrap, and the mutation controls of the shim itself.
#
# Usage: pcap-flows.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/pcap-flows.sh"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth || exit 2
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
if ! command -v tshark >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
  echo "SKIP: tshark or bwrap not in PATH — suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi
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
# A guard stands in for rsdd where the shim's arguments are checked: it refuses (exit 9) any --manifest-cli and otherwise runs
# the real binary, so a shim that hands the manifest tool path over again is caught (the Go commands accept and ignore the flag).
RSDD_REAL_BIN="$RSDD_BIN"; export RSDD_REAL_BIN
printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [ "$a" = "--manifest-cli" ] && { echo "rsdd-guard: unexpected --manifest-cli" >&2; exit 9; }; done' \
  'exec "$RSDD_REAL_BIN" "$@"' >"$ROOT/rsdd-guard" && chmod 755 "$ROOT/rsdd-guard"
RSDD_BIN="$ROOT/rsdd-guard" "$SUT" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "the shim hands no --manifest-cli to rsdd"; else no "the shim hands a --manifest-cli to rsdd (guard exit $rc)"; fi
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (the fixtures and the manifest tool need it)" >&2; exit 2; }

# Mint two deterministic pcaps. fixture.pcap: one TCP stream carrying "HELLO" (a SYN, then a PSH|ACK with the data;
# tshark dissects streams regardless of checksum validity). multi.pcap: three such streams.
python3 - "$ROOT" <<'PY' || exit 2
import struct, sys
E = bytes(6) * 2 + b'\x08\x00'; S = bytes([192, 168, 1, 1]); D = bytes([192, 168, 1, 2])
def mk(ts, sp, dp, sq, ak, fl, data):
    t = struct.pack('>HHIIHHHH', sp, dp, sq, ak, (5 << 12) | fl, 65535, 0, 0) + data
    i = struct.pack('>BBHHHBBH4s4s', 0x45, 0, 20 + len(t), 1, 0x4000, 64, 6, 0, S, D)
    f = E + i + t
    return struct.pack('<IIII', ts, 0, len(f), len(f)) + f
H = struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)
open(sys.argv[1] + '/fixture.pcap', 'wb').write(H + mk(1, 4321, 80, 1000, 0, 0x002, b'') + mk(2, 4321, 80, 1001, 1001, 0x018, b'HELLO'))
multi = b''
for n, payload in enumerate((b'A', b'B', b'C')):
    multi += mk(1 + 2 * n, 4321 + n, 80, 1000 * (n + 1), 0, 0x002, b'') + mk(2 + 2 * n, 4321 + n, 80, 1000 * (n + 1) + 1, 1000 * (n + 1) + 1, 0x018, payload)
open(sys.argv[1] + '/multi.pcap', 'wb').write(H + multi)
PY
run() { "$SUT" --input "$ROOT/fixture.pcap" --output "$1" "${@:2}"; }

if run "$ROOT/a" && run "$ROOT/b" && cmp -s "$ROOT/a/pcap-flows.v1.json" "$ROOT/b/pcap-flows.v1.json"; then
  ok "the shim publishes deterministic evidence"
else no "the shim publishes deterministic evidence"; fi

if python3 - "$ROOT/a/pcap-flows.v1.json" <<'PY'
import hashlib, json, re, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'pcap-flows.v1' and d['status'] == 'complete', d['status']
c = d['conversations']['tcp']; assert c and 'endpoint_a' in c[0] and isinstance(c[0]['frames_total'], int)
f = d['tcp_stream_follows']
assert len(f) == 1 and f[0]['payload_sha256'] == 'sha256:' + hashlib.sha256(b'HELLO').hexdigest(), f
assert re.match(r'^sha256:[0-9a-f]{64}$', f[0]['payload_sha256']) and f[0]['payload_bytes'] == 5
PY
then ok "a real TCP stream's reassembled payload reaches the evidence as its SHA-256"; else no "evidence contract"; fi

if "$RSDD_BIN" adapter manifest validate "$ROOT/a/engine/analysis-manifest.v1.json" \
  && "$RSDD_BIN" adapter manifest verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
  ok "the published analysis manifest validates and all artifact hashes verify"
else no "manifest verification"; fi

printf 'not a pcap file\n' > "$ROOT/garbage.txt"
"$SUT" --input "$ROOT/garbage.txt" --output "$ROOT/garbage-out" 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '^pcap-flows: not a pcap/pcapng file' "$ROOT/err.txt" && [ ! -e "$ROOT/garbage-out" ] && [ ! -e "$ROOT/.garbage-out.stage" ]; then
  ok "a non-pcap input exits 2 with the typed message and publishes nothing"; else no "non-pcap rejection (exit $rc): $(cat "$ROOT/err.txt")"; fi

"$SUT" --input "$ROOT/multi.pcap" --output "$ROOT/multi-out" --max-streams 2 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^pcap-flows: warning: 3 TCP streams found; analyzing only the first 2' "$ROOT/err.txt" \
  && python3 - "$ROOT/multi-out/pcap-flows.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['streams_truncated'] is True and d['streams_analyzed'] == 2 and d['stream_count_total'] == 3
assert len(d['tcp_stream_follows']) == 2
PY
then ok "the caller's arguments reach the Go command (--max-streams caps the follow passes)"; else no "--max-streams pass-through (exit $rc)"; fi

mkdir "$ROOT/collision" "$ROOT/.occupied.stage"; echo keep >"$ROOT/collision/keep"; echo stage >"$ROOT/.occupied.stage/keep"
if ! run "$ROOT/collision" 2>/dev/null && ! run "$ROOT/occupied" 2>/dev/null \
  && [ -f "$ROOT/collision/keep" ] && [ -f "$ROOT/.occupied.stage/keep" ]; then
  ok "destination and stage collisions are preserved"; else no "path collisions"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: pcap-flows.sh shim mutation controls --"
RSDD_BIN="$ROOT/rsdd-guard"; export RSDD_BIN   # every tooth run goes through the guard of the argument check above
# a mutant of the shim must still find lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib"
# each tooth run publishes into a fresh name: the original and the mutant must not collide on one destination
# and an exit 0 that did not publish this tool's report is exit 9 (a sibling command succeeding is not this command)
printf '%s\n' '#!/usr/bin/env bash' 'out="$(mktemp -u "$2/toothXXXXXX")" || exit 2' '"$1" --input "$3" --output "$out"; rc=$?' \
  '[ "$rc" -ne 0 ] || [ -f "$out/pcap-flows.v1.json" ] || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT" "$ROOT/fixture.pcap"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to another command" 's/rsdd_exec corroborate pcap-flows /rsdd_exec corroborate java-fidelity /' 0 2
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 0 2
tooth "shim hands the manifest tool over again" 's/ "\$@"$/ --manifest-cli \/nonexistent\/analysis_manifest.py "$@"/' 0 9
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
