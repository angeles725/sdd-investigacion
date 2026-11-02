#!/usr/bin/env bash
# firmware-carve.test.sh — the end-to-end check of the `scan-firmware.sh carve` compatibility shim
# (firmware-carve.v1).
#
# The carver moved to Go: `rsdd corroborate carve` (research-sdd/rsdd/internal/corroborate/carve). Its cases
# (candidate detection and validation, the caps, deterministic output and modes, path safety, the sandbox command
# and the worker's staged-input checks, the process-tree launcher and the real-bubblewrap run) live in the Go tests
# (`go test ./internal/corroborate/carve`); the byte-for-byte comparison with the legacy script is the `fc-*`
# cases of `go test ./internal/testkit/parity`. This suite keeps the offline end-to-end cases through the shim and
# the mutation controls of the shim itself. No case needs bubblewrap or Binwalk.
#
# Usage: firmware-carve.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/scan-firmware.sh"
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
umask 022
printf 'not firmware' >"$ROOT/junk.bin"

# T1: the shim forwards the three positionals: a file with no supported image is the tool's own refusal, exit 2.
"$SUT" carve "$ROOT/junk.bin" "$ROOT/t1" >/dev/null 2>"$ROOT/t1.err"; t1=$?
if [ "$t1" -eq 2 ] && grep -q 'firmware-carve: .*no validated supported image found' "$ROOT/t1.err" && [ ! -e "$ROOT/t1" ]; then
  ok "no supported image: the tool's refusal, exit 2, nothing published"
else no "no supported image: expected exit 2 and the carver's message, got exit $t1"; fi

# T2: options after the positionals are forwarded: the cap is parsed by the tool.
"$SUT" carve "$ROOT/junk.bin" "$ROOT/t2" --max-input-bytes 4 >/dev/null 2>"$ROOT/t2.err"; t2=$?
if [ "$t2" -eq 2 ] && grep -q 'max-input-bytes' "$ROOT/t2.err"; then ok "options are forwarded: --max-input-bytes enforced by the tool"
else no "options are forwarded: expected the max-input-bytes refusal, got exit $t2"; fi

# T3: an absent input is refused before anything is published.
"$SUT" carve "$ROOT/absent.bin" "$ROOT/t3" >/dev/null 2>"$ROOT/t3.err"; t3=$?
if [ "$t3" -eq 2 ] && [ ! -e "$ROOT/t3" ] && [ -s "$ROOT/t3.err" ]; then ok "absent input: exit 2, a message, nothing published"
else no "absent input: expected exit 2 with a message, got exit $t3"; fi

# T4: the shim insists on its positionals (bash's ${N:?} message, exit 1 in a non-interactive shell).
"$SUT" carve "$ROOT/junk.bin" >/dev/null 2>"$ROOT/t4.err"; t4=$?
if [ "$t4" -ne 0 ] && grep -q 'new-out-dir' "$ROOT/t4.err"; then ok "missing output directory: refused by the shim"
else no "missing output directory: expected a refusal naming new-out-dir, got exit $t4"; fi

# T5: without a binary the shim degrades with a typed state (never a silent success).
RSDD_BIN="$ROOT/no-such-binary" "$SUT" carve "$ROOT/junk.bin" "$ROOT/t5" >/dev/null 2>"$ROOT/t5.err"; t5=$?
if [ "$t5" -eq 2 ] && grep -q 'degraded: rsdd-unavailable' "$ROOT/t5.err"; then ok "no binary: degraded rsdd-unavailable, exit 2"
else no "no binary: expected degraded rsdd-unavailable and exit 2, got exit $t5"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: scan-firmware.sh carve shim mutation controls --"
# a mutant of the shim must still find lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib"
# the run is good (exit 2) only when the Go carver itself enforced the forwarded cap; any other outcome is exit 9
printf '%s\n' '#!/usr/bin/env bash' '"$1" carve "$2/in.bin" "$2/out" --max-input-bytes 4 >/dev/null 2>"$2/err"; rc=$?' \
  'grep -q "max-input-bytes" "$2/err" || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
mkdir -p "$ROOT/teeth-out"; cp "$ROOT/junk.bin" "$ROOT/teeth-out/in.bin"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  rm -rf "$ROOT/teeth-out/out"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/teeth-out"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to an unknown command" 's/rsdd_exec corroborate carve/rsdd_exec corroborate nope/' 2 9
tooth "shim dispatches to an unknown group" 's/rsdd_exec corroborate carve/rsdd_exec nope carve/' 2 9
tooth "shim drops the trailing options" 's/ "\${@:4}"$//' 2 9
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
