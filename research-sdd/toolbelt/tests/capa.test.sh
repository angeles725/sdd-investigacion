#!/usr/bin/env bash
# capa.test.sh — the end-to-end check of the corroborate-capa.sh compatibility shim (kit issue #2483, epic #2270).
#
# The adapter moved to Go: `rsdd corroborate capa` (research-sdd/rsdd/internal/corroborate/capa). Its cases (every
# logic case of the former suite, the legacy Python as the oracle for exit codes, stderr, evidence and manifest, and
# the Go mutation controls) live in the Go tests (`go test ./internal/corroborate/capa`). This suite keeps the cases
# that only exist through the shim - degraded mode, argument pass-through, the manifest tool the shim supplies - over a
# fake sandbox, a slow lane that runs the real capa, and the mutation controls of the shim itself.
#
# Lane contract (tests/lib/test-lane.sh): fast (default) = the fake sandbox; slow = real capa + bwrap + rules dir;
# all = both.
# Usage: capa.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/corroborate-capa.sh"
# shellcheck source=lib/test-lane.sh
source "$HERE/lib/test-lane.sh"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth || exit 2
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
_lane="$(rsdd_lane)"
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
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (the analysis manifest tool needs it)" >&2; exit 2; }

# A fake sandbox: a bwrap that runs the command after "--", and a capa inside a venv-shaped directory.
mkdir -p "$ROOT/bin" "$ROOT/venv/bin" "$ROOT/rules/lib" "$ROOT/in" "$ROOT/out" "$ROOT/home" || exit 2
printf '%s\n' '#!/bin/sh' 'while [ "$#" -gt 0 ]; do [ "$1" = "--" ] && { shift; break; }; shift; done' 'exec "$@"' >"$ROOT/bin/bwrap"
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "--version" ]; then echo "capa 9.4.0"; exit 0; fi' \
  'cat "$(dirname "$0")/../out.json"' >"$ROOT/venv/bin/capa"
chmod 755 "$ROOT/bin/bwrap" "$ROOT/venv/bin/capa"
echo 'home = /usr/bin' >"$ROOT/venv/pyvenv.cfg"
echo 'rule: {}' >"$ROOT/rules/lib/a.yml"
echo 'MZ sample bytes' >"$ROOT/in/sample.bin"
cat >"$ROOT/venv/out.json" <<'JSON'
{"rules": {
 "write file": {"meta": {"namespace": "host-interaction/file-system/write", "attack": [{"id": "T1105"}]}, "matches": [[1, {}]]},
 "delete file": {"meta": {"namespace": "host-interaction/file-system/delete"}, "matches": [[1, {}]]}}}
JSON
fake_env() { env HOME="$ROOT/home" PATH="$ROOT/venv/bin:$ROOT/bin:$PATH" "$@"; }
run() { fake_env "$SUT" --input "$ROOT/in/sample.bin" --rules "$ROOT/rules" --output "$1" "${@:2}"; }

if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then
  # degraded: no rsdd binary and no way to build one - a typed state, never a silent pass
  RSDD_BIN=/nonexistent/rsdd "$SUT" --input "$ROOT/in/sample.bin" --output "$ROOT/out/degraded" >"$ROOT/d.out" 2>"$ROOT/d.err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q '^degraded: rsdd-unavailable' "$ROOT/d.err" && [ ! -e "$ROOT/out/degraded" ]; then
    ok "rsdd missing: typed degraded state, exit 2, nothing published"; else no "degraded mode (exit $rc): $(cat "$ROOT/d.err")"; fi

  if run "$ROOT/out/a" 2>"$ROOT/a.err" && run "$ROOT/out/b" 2>/dev/null && cmp -s "$ROOT/out/a/capa-evidence.v1.json" "$ROOT/out/b/capa-evidence.v1.json" \
    && grep -q '"schema":"capa-evidence.v1"' "$ROOT/out/a/capa-evidence.v1.json" && grep -q '"status":"complete"' "$ROOT/out/a/capa-evidence.v1.json" \
    && grep -q '"total_count":2' "$ROOT/out/a/capa-evidence.v1.json"; then
    ok "the shim publishes deterministic capa-evidence.v1 through the Go command"
  else no "shim happy path: $(cat "$ROOT/a.err" 2>/dev/null)"; fi

  run "$ROOT/out/capped" --max-capabilities 1 2>/dev/null
  if grep -q '"total_sampled":1' "$ROOT/out/capped/capa-evidence.v1.json" 2>/dev/null && grep -q '"truncated":true' "$ROOT/out/capped/capa-evidence.v1.json"; then
    ok "the caller's arguments reach the Go command (the capability cap bites)"; else no "argument pass-through"; fi

  if python3 "$TB/analysis_manifest.py" validate "$ROOT/out/a/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
    && python3 "$TB/analysis_manifest.py" verify --root "$ROOT/out/a" "$ROOT/out/a/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
    ok "the published analysis manifest validates and verifies with the Python manifest tool"; else no "analysis manifest"; fi

  mkdir "$ROOT/out/taken"
  run "$ROOT/out/taken" 2>"$ROOT/t.err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q '^corroborate-capa: output must be a new non-colliding path' "$ROOT/t.err" && [ ! -e "$ROOT/out/taken/capa-evidence.v1.json" ]; then
    ok "an existing output is refused fail-closed with exit 2"; else no "output collision (exit $rc)"; fi

  "$SUT" --bogus >/dev/null 2>"$ROOT/u.err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q '^usage: corroborate-capa ' "$ROOT/u.err" && grep -q 'the following arguments are required: --input, --output$' "$ROOT/u.err"; then
    ok "the shim supplies --manifest-cli: a usage error names only --input and --output"; else no "usage error (exit $rc): $(cat "$ROOT/u.err")"; fi
fi

# SLOW LANE - the real capa (tool required; informational skip when absent)
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then
  _slow_skip=0
  for _cmd in capa bwrap python3; do
    command -v "$_cmd" >/dev/null 2>&1 || { echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2; _slow_skip=1; break; }
  done
  _RULES_DIR="${RSDD_CAPA_RULES:-$HOME/.local/share/capa-rules}"
  if [ "$_slow_skip" -eq 0 ] && ! [ -d "$_RULES_DIR" ]; then echo "SLOW lane: rules dir absent: $_RULES_DIR; slow-lane tests skipped." >&2; _slow_skip=1; fi
  if [ "$_slow_skip" -eq 0 ]; then
    cp /bin/true "$ROOT/in/happy.elf"
    if "$SUT" --input "$ROOT/in/happy.elf" --rules "$_RULES_DIR" --output "$ROOT/out/real" --timeout 300 2>/dev/null \
      && grep -q '"schema":"capa-evidence.v1"' "$ROOT/out/real/capa-evidence.v1.json"; then
      ok "T1: real capa through the shim: evidence JSON produced"; else no "T1: real capa"; fi
    if python3 "$TB/analysis_manifest.py" verify --root "$ROOT/out/real" "$ROOT/out/real/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
      ok "T13: real capa: the analysis manifest verifies"; else no "T13: real capa manifest"; fi
  fi
fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: corroborate-capa.sh shim mutation controls --"
# a mutant of the shim must still find lib/rsdd-exec.sh and analysis_manifest.py: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib" && ln -s "$TB/analysis_manifest.py" "$KC/analysis_manifest.py"
# each tooth run publishes into a fresh name; an exit 0 that did not publish this tool's report is exit 9
# (a sibling command succeeding is not this command)
printf '%s\n' '#!/usr/bin/env bash' 'out="$(mktemp -u "$2/toothXXXXXX")" || exit 2' \
  'env HOME="$3/home" PATH="$3/venv/bin:$3/bin:$PATH" "$1" --input "$3/in/sample.bin" --rules "$3/rules" --output "$out"; rc=$?' \
  '[ "$rc" -ne 0 ] || [ -f "$out/capa-evidence.v1.json" ] || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/out" "$ROOT"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to the sibling command" 's/rsdd_exec corroborate capa/rsdd_exec corroborate java-fidelity/' 0 2
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 0 2
tooth "shim drops the manifest tool" 's/--manifest-cli "\$_RSDD_SELF\/analysis_manifest.py" //' 0 2
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
