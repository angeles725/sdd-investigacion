#!/usr/bin/env bash
# research-sdd-status-shim.test.sh — wiring suite for the research-sdd-status.sh compatibility shim (kit issue #2549).
#
# The script is a rsdd_exec shim over `rsdd status show`; every mode (default report, --next, --sync-state), the typed
# states and the intended divergences are tested in Go, in research-sdd/rsdd/internal/status/show, against the frozen
# legacy script and its libs (testdata/legacy): see the case map in odd/tasks/status-show-go.md. This suite proves only
# the wiring the Go tests cannot see:
#   1 the shim reaches the Go command: stdout, stderr and exit code come back, arguments pass through in order
#   2 the toolbelt directory handed to the command is the shim's own PHYSICAL directory (verify-state.sh is run from it),
#     also through a symlink to the shim
#   3 a missing lib/rsdd-exec.sh is a typed degraded (exit 2), never a silent pass
#   4 the script is the shim: one dispatch line, no status logic of its own
#
# Usage: research-sdd-status-shim.test.sh                (run the suite)
#        research-sdd-status-shim.test.sh --prove-teeth  (run suite + mutation teeth on the shim)
# Exit: 0 = all pass · 1 = failure · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
[ -f "$HERE/../lib/rsdd-exec.sh" ] || { echo "FATAL: rsdd-exec helper not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# The shim runs the Go command: the caller's RSDD_BIN, else one build into the temp dir (degraded, never a pass, without go).
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$ROOT/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  RSDD_BIN="$ROOT/rsdd"
fi
export RSDD_BIN
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkcorpus DIR — a minimal valid corpus (research-state.v1 envelope, one pending high gap).
mkcorpus() {
  mkdir -p "$1"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 1\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| high | the gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 1"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$1/RESEARCH-STATE.md"
}
# mkbox NAME [shim] — a kit-shaped sandbox: the shim + lib/rsdd-exec.sh, and a verify-state.sh stub that records the
# directory it was started from and its arguments (the gate of --next runs it from the toolbelt directory).
mkbox() {
  local box="$ROOT/$1" shim="${2:-$SUT}"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/corpus"
  cp "$shim" "$box/research-sdd/toolbelt/research-sdd-status.sh"
  rsdd_stage_libs "$box/research-sdd/toolbelt"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >> "%s/vs.log"\nexit 0\n' "$box" > "$box/research-sdd/toolbelt/verify-state.sh"
  chmod +x "$box/research-sdd/toolbelt/verify-state.sh"
  mkcorpus "$box/corpus"
  printf '%s' "$box"
}
# run <script> <args...>: sets OUT, ERR and RC.
run() {
  local errf="$ROOT/err.$$"; OUT="$("$BASH_BIN" "$@" 2>"$errf")"; RC=$?; ERR="$(cat "$errf")"
}

box="$(mkbox case-wiring)"; S="$box/research-sdd/toolbelt/research-sdd-status.sh"

# 1 — the shim reaches the Go command; arguments pass through in order.
run "$S" "$box/corpus" --next
if [ "$RC" = 0 ] && [ "$OUT" = "NEXT | high | the gap" ]; then ok "1 wiring: shim → rsdd status show; --next answers NEXT, exit 0" "(exit $RC)"
else no "1 wiring: shim → rsdd status show --next" "rc=$RC out=[$OUT] err=[$ERR]"; fi
run "$S" "$box/corpus" --next --emit-token
if [ "$RC" = 0 ] && grep -qx 'return-token: next: the gap' <<<"$OUT"; then ok "1b wiring: a flag after --next reaches the command (--emit-token)" "(exit $RC)"
else no "1b wiring: --emit-token passthrough" "rc=$RC out=[$OUT] err=[$ERR]"; fi
run "$S"
if [ "$RC" != 0 ] && [ -n "$ERR" ] && [ -z "$OUT" ]; then ok "1c wiring: no arguments → a usage error on stderr, non-zero exit" "(exit $RC)"
else no "1c wiring: no arguments" "rc=$RC out=[$OUT] err=[$ERR]"; fi

# 2 — the toolbelt directory is the shim's physical directory, also through a symlink.
phys="$(cd "$box/research-sdd/toolbelt" && pwd -P)"
if [ -s "$box/vs.log" ] && grep -qxF "$phys/verify-state.sh" "$box/vs.log"; then ok "2 wiring: verify-state.sh runs from the shim's own directory" "()"
else no "2 wiring: toolbelt directory" "log=[$(cat "$box/vs.log" 2>/dev/null)] want $phys/verify-state.sh"; fi
ln -s "$S" "$box/link-status.sh"; rm -f "$box/vs.log"
run "$box/link-status.sh" "$box/corpus" --next
if [ "$RC" = 0 ] && grep -qxF "$phys/verify-state.sh" "$box/vs.log" 2>/dev/null; then ok "2b wiring: through a symlink to the shim, the SHIM's directory is used" "(exit $RC)"
else no "2b wiring: symlink" "rc=$RC out=[$OUT] log=[$(cat "$box/vs.log" 2>/dev/null)]"; fi

# 3 — a missing lib/rsdd-exec.sh is typed degraded + exit 2.
box3="$(mkbox case-nolib)"; rm -f "$box3/research-sdd/toolbelt/lib/rsdd-exec.sh"
run "$box3/research-sdd/toolbelt/research-sdd-status.sh" "$box3/corpus" --next
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside ' <<<"$ERR"; then ok "3 wiring: missing rsdd-exec.sh → degraded rsdd-unavailable + exit 2" "(exit $RC)"
else no "3 wiring: missing rsdd-exec.sh" "rc=$RC out=[$OUT] err=[$ERR]"; fi

# 4 — the shim carries no status logic and only the one dispatch line.
if [ "$(grep -c 'rsdd_exec ' "$SUT")" = 1 ] && grep -q '^RSDD_TOOLBELT_DIR="\$_RSDD_SELF" rsdd_exec status show "\$@"$' "$SUT" && [ "$(wc -l < "$SUT")" -le 16 ]; then
  ok "4 wiring: the script is the rsdd_exec shim (one dispatch line, no status logic)" "()"
else no "4 wiring: the script is the rsdd_exec shim" "lines=$(wc -l < "$SUT")"; fi

# TEETH: a broken shim must turn a wiring case red.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls on the shim --"
  # tooth <label> <sed-expr>: mutate a copy of the shim, run it in a fresh box, and require that the wiring case
  # (--next answers NEXT, verify-state.sh started from the physical toolbelt directory) no longer holds.
  tooth() {
    local label="$1" expr="$2" mut="$ROOT/mutant-$1.sh" mb phys2
    sed "$expr" "$SUT" > "$mut"
    if cmp -s "$mut" "$SUT"; then no "$label teeth" "the mutation changed nothing (anchor drifted)"; return; fi
    mb="$(mkbox "teeth-$label" "$mut")"; phys2="$(cd "$mb/research-sdd/toolbelt" && pwd -P)"
    run "$mb/research-sdd/toolbelt/research-sdd-status.sh" "$mb/corpus" --next
    if [ "$RC" = 0 ] && [ "$OUT" = "NEXT | high | the gap" ] && grep -qxF "$phys2/verify-state.sh" "$mb/vs.log" 2>/dev/null; then
      no "$label teeth" "the mutant still passes the wiring case: THEATER (rc=$RC out=[$OUT])"
    else ok "$label teeth: mutant turns the wiring case red" "(exit $RC)"; fi
  }
  tooth T1-command 's/rsdd_exec status show /rsdd_exec status nope /'
  tooth T2-passthrough 's/ "\$@"$//'
  tooth T3-toolbelt 's/^RSDD_TOOLBELT_DIR="\$_RSDD_SELF" //'
  tooth T4-self-dir 's/_RSDD_SELF="\$(CDPATH='"''"' cd -- "\$(dirname -- "\$_rsdd_s")" \&\& pwd -P)"/_RSDD_SELF="\/nonexistent"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
