#!/usr/bin/env bash
# rsdd-exec.sh — compatibility-shim helper for scripts ported to the Go `rsdd` binary (kit issue #2275).
#
# A ported script becomes a three-line shim:
#   #!/usr/bin/env bash
#   # Ported to Go: `rsdd verify block`. Compatibility shim (removed in phase 8, kit issue <N>).
#   . "$(dirname "$0")/lib/rsdd-exec.sh" && rsdd_exec verify block "$@"
#
#   rsdd_exec <group> <cmd> [args...]
#     Runs `rsdd <group> <cmd> [args...]` through exec: stdin, every argument byte and the exit code pass
#     through unchanged. Resolution order:
#       1. $RSDD_BIN (non-empty): used as-is, no staleness check, no rebuild. Not an executable file ->
#          `degraded: rsdd-unavailable — RSDD_BIN not executable: <path>`, rc 2.
#       2. <kit>/bin/rsdd, where <kit> is derived from THIS file (lib -> toolbelt -> kit). Stale = any
#          *.go, go.mod or go.sum under <kit>/rsdd newer than the binary. A missing or stale binary is
#          rebuilt with `go build -o <tmp> ./cmd/rsdd` (inside <kit>/rsdd; <tmp> is a mktemp file in
#          <kit>/bin, renamed onto <kit>/bin/rsdd so a racing shim never execs a half-written file).
#          Build output goes to stderr only.
#       3. Rebuild impossible but an old binary exists -> a `rsdd-exec: notice:` line on stderr, old one runs.
#       4. No binary and no way to get one -> ONE stderr line `degraded: rsdd-unavailable — <reason>`
#          (`go not found`, `build failed`, `no sources at <path>`), rc 2, nothing on stdout.
#
#   rsdd_exec_hook <sweep|gate> <group> <cmd> [args...]
#     Same as rsdd_exec, except that when rsdd is unavailable it ALLOWS (rc 0) instead of failing a hook:
#       sweep: stdout = one SessionStart JSON envelope whose additionalContext names the degradation
#       gate:  stdout empty; stderr also carries `rsdd-exec-gate: state=allow branch=degraded (...)`, the
#              shape retro-gate.sh and return-token-gate.sh use
#     In both modes the degraded line is on stderr. Unknown mode or fewer than 3 arguments -> usage, rc 2.
#
# FUNCTIONS ONLY: no top-level `set`, safe to source from a shim under `set -euo pipefail`, idempotent.
if ! declare -F rsdd_exec >/dev/null 2>&1; then

  # Kit root, fixed at source time from this file's own location (physical path).
  _RSDD_EXEC_KIT="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || _RSDD_EXEC_KIT=""

  _rsdd_exec_degrade() { printf 'degraded: rsdd-unavailable — %s\n' "$1" >&2; return 2; }

  # _rsdd_exec_stale BIN SRC — rc 0 when a source file is newer than BIN, or when the scan itself failed.
  _rsdd_exec_stale() {
    local hit rc=0
    hit="$(find "$2" \( -name '*.go' -o -name go.mod -o -name go.sum \) -newer "$1" -print -quit 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || [ -n "$hit" ]
  }

  # _rsdd_exec_build KIT — rc 0 when KIT/bin/rsdd was (re)built.
  _rsdd_exec_build() {
    local kit="$1" bin="$1/bin/rsdd" tmp
    mkdir -p -- "$kit/bin" || return 1
    tmp="$(mktemp "$kit/bin/.rsdd.XXXXXX")" || return 1
    ( trap 'rm -f -- "$tmp"' EXIT; cd -- "$kit/rsdd" && go build -o "$tmp" ./cmd/rsdd && chmod 755 "$tmp" && mv -f "$tmp" "$bin" ) >&2
  }

  # _rsdd_exec_resolve — sets _RSDD_EXEC_BIN and returns 0, or sets _RSDD_EXEC_WHY and returns 2.
  _rsdd_exec_resolve() {
    local kit="$_RSDD_EXEC_KIT" bin src have=0
    _RSDD_EXEC_BIN="" _RSDD_EXEC_WHY=""
    if [ -n "${RSDD_BIN:-}" ]; then
      if [ ! -f "$RSDD_BIN" ] || [ ! -x "$RSDD_BIN" ]; then _RSDD_EXEC_WHY="RSDD_BIN not executable: $RSDD_BIN"; return 2; fi
      _RSDD_EXEC_BIN="$RSDD_BIN"; return 0
    fi
    if [ -z "$kit" ]; then _RSDD_EXEC_WHY="cannot resolve the kit root"; return 2; fi
    bin="$kit/bin/rsdd" src="$kit/rsdd"
    if [ -f "$bin" ] && [ -x "$bin" ]; then have=1; fi
    if [ "$have" -eq 0 ] || { [ -d "$src" ] && _rsdd_exec_stale "$bin" "$src"; }; then
      if [ ! -d "$src" ]; then
        _RSDD_EXEC_WHY="no sources at $src"; return 2
      elif ! command -v go >/dev/null 2>&1; then
        if [ "$have" -eq 0 ]; then _RSDD_EXEC_WHY="go not found"; return 2; fi
        echo "rsdd-exec: notice: go not found; running a binary older than its sources: $bin" >&2
      elif ! _rsdd_exec_build "$kit"; then
        if [ "$have" -eq 0 ]; then _RSDD_EXEC_WHY="build failed"; return 2; fi
        echo "rsdd-exec: notice: rebuild failed; running a binary older than its sources: $bin" >&2
      fi
    fi
    _RSDD_EXEC_BIN="$bin"
    return 0
  }

  rsdd_exec() {
    if [ "$#" -lt 2 ]; then echo "usage: rsdd_exec <group> <cmd> [args...]" >&2; return 2; fi
    local group="$1" cmd="$2"
    shift 2
    _rsdd_exec_resolve || { _rsdd_exec_degrade "$_RSDD_EXEC_WHY"; return; }
    exec "$_RSDD_EXEC_BIN" "$group" "$cmd" "$@"
  }

  # _rsdd_exec_json_escape TEXT — TEXT escaped for use inside a JSON string (quote, backslash, control chars).
  _rsdd_exec_json_escape() {
    local s="$1" i ch esc
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    for ((i = 1; i < 32; i++)); do
      case "$i" in 9 | 10 | 13) continue ;; esac
      printf -v ch "\\x$(printf '%02x' "$i")"
      printf -v esc '\\u%04x' "$i"
      s="${s//"$ch"/"$esc"}"
    done
    printf '%s' "$s"
  }

  rsdd_exec_hook() {
    if [ "$#" -lt 3 ]; then echo "usage: rsdd_exec_hook <sweep|gate> <group> <cmd> [args...]" >&2; return 2; fi
    local mode="$1" group="$2" cmd="$3"
    case "$mode" in sweep | gate) ;; *) echo "usage: rsdd_exec_hook <sweep|gate> <group> <cmd> [args...]" >&2; return 2 ;; esac
    shift 3
    if ! _rsdd_exec_resolve; then
      _rsdd_exec_degrade "$_RSDD_EXEC_WHY" || true
      if [ "$mode" = sweep ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Research-SDD hooks DEGRADED: rsdd-unavailable — %s"}}\n' "$(_rsdd_exec_json_escape "$_RSDD_EXEC_WHY")"
      else
        printf 'rsdd-exec-gate: state=allow branch=degraded (rsdd-unavailable — %s)\n' "$_RSDD_EXEC_WHY" >&2
      fi
      return 0
    fi
    exec "$_RSDD_EXEC_BIN" "$group" "$cmd" "$@"
  }
fi
