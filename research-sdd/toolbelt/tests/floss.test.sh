#!/usr/bin/env bash
# floss.test.sh — the end-to-end check of the corroborate-floss.sh compatibility shim (kit issue #2484, epic #2270).
#
# The adapter moved to Go: `rsdd corroborate floss` (research-sdd/rsdd/internal/corroborate/floss). Its cases (every
# logic case of the former suite, the legacy Python as the oracle for the command line, the JSON reader and whole
# runs, and the Go mutation controls) live in the Go tests (`go test ./internal/corroborate/floss`, `make teeth`).
# This suite keeps a few end-to-end cases through the shim and the mutation controls of the shim itself.
#
# Usage: floss.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/corroborate-floss.sh"
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
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (the manifest tool needs it)" >&2; exit 2; }

mkdir "$ROOT/out" && chmod 755 "$ROOT/out" || exit 2
printf 'MZ\220\000 some binary bytes' >"$ROOT/in.bin"
run() { "$SUT" --input "$1" --output "$2" "${@:3}"; }

# The shim injects --manifest-cli itself: the usage error names only the options the caller owes.
"$SUT" >"$ROOT/out.txt" 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$ROOT/out.txt" ] && grep -q '^usage: corroborate-floss ' "$ROOT/err.txt" \
  && grep -qx 'corroborate-floss: error: the following arguments are required: --input, --output' "$ROOT/err.txt"; then
  ok "the shim reaches the Go command and supplies --manifest-cli itself"; else no "usage through the shim (exit $rc): $(cat "$ROOT/err.txt")"; fi

"$SUT" -h >"$ROOT/out.txt" 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$ROOT/err.txt" ] && grep -q '^usage: corroborate-floss ' "$ROOT/out.txt" && grep -q -- '--max-string-len' "$ROOT/out.txt"; then
  ok "-h prints the usage on stdout and exits 0"; else no "help through the shim (exit $rc)"; fi

run "$ROOT/in.bin" "$ROOT/out/capped" --timeout 0 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(cat "$ROOT/err.txt")" = "corroborate-floss: --timeout must be >= 1" ] && [ ! -e "$ROOT/out/capped" ]; then
  ok "the caller's arguments reach the Go command (a cap fails closed)"; else no "cap pass-through (exit $rc): $(cat "$ROOT/err.txt")"; fi

mkdir "$ROOT/out/collision" && echo keep >"$ROOT/out/collision/keep"
run "$ROOT/in.bin" "$ROOT/out/collision" 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(cat "$ROOT/err.txt")" = "corroborate-floss: output must be a new non-colliding path" ] \
  && [ -f "$ROOT/out/collision/keep" ] && [ ! -e "$ROOT/out/.collision.stage" ]; then
  ok "an existing output directory is refused and left untouched"; else no "destination collision (exit $rc): $(cat "$ROOT/err.txt")"; fi

# One whole run through the shim: a stand-in floss in a venv-shaped tree, the real bwrap and the real manifest tool.
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then
  mkdir -p "$ROOT/venv/bin" && : >"$ROOT/venv/pyvenv.cfg"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = "--version" ]; then echo "floss 3.1.1-stub"; exit 0; fi' \
    'echo "{\"strings\":{\"static_strings\":[{\"string\":\"alpha\",\"offset\":1,\"encoding\":\"ASCII\"}]}}"' >"$ROOT/venv/bin/floss"
  chmod +x "$ROOT/venv/bin/floss"
  if PATH="$ROOT/venv/bin:$PATH" RSDD_FLOSS="$ROOT/venv/bin/floss" run "$ROOT/in.bin" "$ROOT/out/whole" 2>"$ROOT/err.txt" \
    && python3 "$TB/analysis_manifest.py" verify --root "$ROOT/out/whole" "$ROOT/out/whole/engine/analysis-manifest.v1.json" >/dev/null \
    && python3 - "$ROOT/out/whole/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]
assert d["schema"] == "floss-evidence.v1" and d["status"] == "complete" and d["errors"] == []
assert s["total_count"] == 1 and s["static_strings"]["strings"][0]["value"] == "alpha"
assert s["floss_version"] == "floss 3.1.1-stub"
PY
  then ok "a whole run through the shim publishes verifiable evidence"; else no "whole run through the shim: $(cat "$ROOT/err.txt")"; fi
else
  echo "  SKIP  whole run through the shim: bwrap cannot create an unprivileged sandbox here (tool-missing)"
fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: corroborate-floss.sh shim mutation controls --"
# a mutant of the shim must still find lib/rsdd-exec.sh and analysis_manifest.py: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib" && ln -s "$TB/analysis_manifest.py" "$KC/analysis_manifest.py"
# the probe asks for a refused cap and prints the last stderr line as a verdict: the original and every mutant exit 2,
# so the verdict line is what tells them apart
printf '%s\n' '#!/usr/bin/env bash' 'err="$("$1" --input "$3" --output "$2/tooth-$$" --timeout 0 2>&1 >/dev/null)"' \
  'printf "VERDICT: %s\n" "$(printf "%s" "$err" | tail -n 1)"' >"$ROOT/tooth-run.sh"
tooth() { # LABEL SED_EXPR BAD_VERDICT_FRAGMENT
  local label="$1" expr="$2" bad="$3"
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" 0 0 "$m" --orig "$SUT" --good-has 'VERDICT: corroborate-floss: --timeout must be >= 1' \
      --bad-has "$bad" --bad-lacks 'VERDICT: corroborate-floss: --timeout must be >= 1' -- \
      bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/out" "$ROOT/in.bin"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to the sibling command" 's/rsdd_exec corroborate floss/rsdd_exec corroborate java-fidelity/' 'VERDICT:'
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 'the following arguments are required: --input, --output'
tooth "shim drops the manifest tool" 's/--manifest-cli "\$_RSDD_SELF\/analysis_manifest.py" //' 'the following arguments are required: --manifest-cli'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
