#!/usr/bin/env bash
# rsdd-exec.sh — compatibility-shim helper for scripts ported to the Go `rsdd` binary (kit issue #2275).
# Functions only: rsdd_exec <group> <cmd> [args...] and rsdd_exec_hook <sweep|guard|gate> <group> <cmd> [args...].
# The contract, the resolution order and the shim TEMPLATES (the text tests/rsdd-exec.test.sh extracts and runs
# verbatim) are documented in the DOCUMENTATION block at the END of this file. The library's own directory is
# found with the RSDD-SELF-DIR idiom below, which must stay the first occurrence of that marker in the file.
if ! declare -F rsdd_exec >/dev/null 2>&1; then

  # Library directory and kit root, fixed at source time from this file's own location. The directory comes from
  # the kit's RSDD-SELF-DIR idiom (symlinks followed), so a symlinked lib resolves too. The idiom writes the
  # caller-visible _RSDD_SELF (the shim's own directory); it is saved and restored so sourcing leaves it intact.
  _rsdd_exec_had_self=0; if [ "${_RSDD_SELF+x}" ]; then _rsdd_exec_had_self=1; _rsdd_exec_prev_self="$_RSDD_SELF"; fi
  # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
  _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
  while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
  if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
  _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
  _RSDD_EXEC_LIBDIR="$_RSDD_SELF"
  if [ "$_rsdd_exec_had_self" -eq 1 ]; then _RSDD_SELF="$_rsdd_exec_prev_self"; else unset _RSDD_SELF; fi
  unset _rsdd_exec_had_self _rsdd_exec_prev_self
  _RSDD_EXEC_KIT=""
  if [ -n "$_RSDD_EXEC_LIBDIR" ]; then _RSDD_EXEC_KIT="$(CDPATH='' cd -P -- "$_RSDD_EXEC_LIBDIR/../.." 2>/dev/null && pwd -P)" || _RSDD_EXEC_KIT=""; fi

  _rsdd_exec_degrade() { printf 'degraded: rsdd-unavailable — %s\n' "$1" >&2; return 2; }

  # _rsdd_exec_stale BIN SRC — rc 0 when a source file is newer than BIN, or when the scan itself failed.
  _rsdd_exec_stale() {
    local hit rc=0
    hit="$(find "$2" \( -name '*.go' -o -name go.mod -o -name go.sum \) -newer "$1" -print -quit 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || [ -n "$hit" ]
  }

  # _rsdd_exec_build KIT — rc 0 built · 3 <kit>/bin cannot be created or written · 1 the build failed.
  _rsdd_exec_build() {
    local kit="$1" bin="$1/bin/rsdd" tmp
    mkdir -p -- "$kit/bin" 2>/dev/null || return 3
    tmp="$(mktemp "$kit/bin/.rsdd.XXXXXX" 2>/dev/null)" || return 3
    ( trap 'rm -f -- "$tmp"' EXIT; cd -- "$kit/rsdd" && go build -o "$tmp" ./cmd/rsdd && chmod 755 "$tmp" && mv -f "$tmp" "$bin" ) >&2 || return 1
  }

  # _rsdd_exec_resolve — sets _RSDD_EXEC_BIN and returns 0, or sets _RSDD_EXEC_WHY and returns 2.
  _rsdd_exec_resolve() {
    local kit="$_RSDD_EXEC_KIT" bin src have=0 brc why note
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
      else
        brc=0; _rsdd_exec_build "$kit" || brc=$?
        if [ "$brc" -ne 0 ]; then
          if [ "$brc" -eq 3 ]; then why="bin dir not writable: $kit/bin"; note="$why"; else why="build failed"; note="rebuild failed"; fi
          if [ "$have" -eq 0 ]; then _RSDD_EXEC_WHY="$why"; return 2; fi
          echo "rsdd-exec: notice: $note; running a binary older than its sources: $bin" >&2
        fi
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

  # _rsdd_exec_ask REASON — the PreToolUse `ask` decision (same fields and jq/no-jq split as the pkill guard).
  _rsdd_exec_ask() {
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg d ask --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$(_rsdd_exec_json_escape "$1")"
    fi
  }

  rsdd_exec_hook() {
    if [ "$#" -lt 3 ]; then echo "usage: rsdd_exec_hook <sweep|guard|gate> <group> <cmd> [args...]" >&2; return 2; fi
    local mode="$1" group="$2" cmd="$3"
    case "$mode" in sweep | guard | gate) ;; *) echo "usage: rsdd_exec_hook <sweep|guard|gate> <group> <cmd> [args...]" >&2; return 2 ;; esac
    shift 3
    if ! _rsdd_exec_resolve; then
      _rsdd_exec_degrade "$_RSDD_EXEC_WHY" || true
      case "$mode" in
        sweep)
          if [ -n "$_RSDD_EXEC_LIBDIR" ] && . "$_RSDD_EXEC_LIBDIR/hook-emit.sh" 2>/dev/null; then
            rsdd_hook_emit "Research-SDD hooks DEGRADED: rsdd-unavailable — $_RSDD_EXEC_WHY"
          else
            printf 'Research-SDD hooks DEGRADED: rsdd-unavailable — %s (lib/hook-emit.sh missing)\n' "$_RSDD_EXEC_WHY"
          fi ;;
        guard) _rsdd_exec_ask "Research-SDD guard DEGRADED: rsdd-unavailable — $_RSDD_EXEC_WHY" ;;
        *) printf 'rsdd-exec-gate: state=allow branch=degraded (rsdd-unavailable — %s)\n' "$_RSDD_EXEC_WHY" >&2 ;;
      esac
      return 0
    fi
    exec "$_RSDD_EXEC_BIN" "$group" "$cmd" "$@"
  }
fi

# ----------------------------------------------------------------------------------------- DOCUMENTATION
#
# A ported script becomes a short shim. It finds this library through the kit's RSDD-SELF-DIR idiom (own
# directory from BASH_SOURCE, symlinks followed; never $0 or the caller's cwd) and says so when the library is
# missing. There is one template per way a shim is used; the text between the TEMPLATE markers is the single
# source of truth: tests/rsdd-exec.test.sh extracts it from this header and runs it verbatim (from a symlink,
# and with the library absent), so the documentation and the tested shim cannot drift apart.
#
#   (a) CLI shim: a missing library is `degraded: rsdd-unavailable — rsdd-exec.sh missing beside <path>`, rc 2.
#   >>> TEMPLATE cli
#       #!/usr/bin/env bash
#       # Ported to Go: `rsdd verify block`. Compatibility shim (removed in phase 8, kit issue <N>).
#       # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
#       _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
#       while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
#       if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
#       _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
#       . "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
#       rsdd_exec verify block "$@"
#   <<< TEMPLATE
#
# Hook shims use rsdd_exec_hook, which has THREE degraded modes, one per hook event. A hook never fails the
# session: every mode exits 0 when rsdd is unavailable, and a missing library is announced, never silent
# (the SENTINEL-HOOK-EMIT-GUARD pattern of verify-registry-hook.sh).
#
#   (b) sweep (SessionStart): a DEGRADED headline as additionalContext (rsdd_hook_emit), rc 0.
#   >>> TEMPLATE hook-sweep
#       #!/usr/bin/env bash
#       # Ported to Go: `rsdd verify registry`. Compatibility shim (removed in phase 8, kit issue <N>).
#       # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
#       _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
#       while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
#       if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
#       _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
#       . "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/rsdd-exec.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout
#       rsdd_exec_hook sweep verify registry "$@"
#   <<< TEMPLATE
#
#   (c) guard (PreToolUse): answers `ask`, never an empty allow. Stdout is the PreToolUse decision JSON in the
#       shape templates/hook-pretool-pkill-guard.sh emits (hookSpecificOutput.permissionDecision/-Reason), rc 0,
#       the degraded line on stderr. A missing library fails closed to `ask` too.
#   >>> TEMPLATE hook-guard
#       #!/usr/bin/env bash
#       # Ported to Go: `rsdd guard pkill`. Compatibility shim (removed in phase 8, kit issue <N>).
#       # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
#       _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
#       while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
#       if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
#       _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
#       . "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Research-SDD guard DEGRADED: rsdd-unavailable — rsdd-exec.sh missing beside %s"}}\n' "${0//[\"\\]/_}"; exit 0; }   # SENTINEL-GUARD-FAIL-CLOSED
#       rsdd_exec_hook guard guard pkill "$@"
#   <<< TEMPLATE
#
#   (d) gate (Stop): allows (rc 0), stdout empty, `branch=degraded` on stderr.
#   >>> TEMPLATE hook-gate
#       #!/usr/bin/env bash
#       # Ported to Go: `rsdd verify retro`. Compatibility shim (removed in phase 8, kit issue <N>).
#       # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
#       _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
#       while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
#       if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
#       _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
#       . "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; printf 'rsdd-exec-gate: state=allow branch=degraded (rsdd-unavailable — rsdd-exec.sh missing beside %s)\n' "$0" >&2; exit 0; }
#       rsdd_exec_hook gate verify retro "$@"
#   <<< TEMPLATE
#
#   rsdd_exec <group> <cmd> [args...]
#     Runs `rsdd <group> <cmd> [args...]` through exec: stdin, every argument byte and the exit code pass
#     through unchanged. Resolution order:
#       1. $RSDD_BIN (non-empty): used as-is, no staleness check, no rebuild. Not an executable file ->
#          `degraded: rsdd-unavailable — RSDD_BIN not executable: <path>`, rc 2.
#       2. <kit>/bin/rsdd, where <kit> is derived from THIS file (lib -> toolbelt -> kit). Stale = any
#          *.go, go.mod or go.sum under <kit>/rsdd newer than the binary (mtime). A scan that FAILS (for
#          example an unreadable subdirectory) counts as stale: when the scan cannot prove the binary fresh,
#          it is rebuilt. A missing or stale binary is rebuilt with `go build -o <tmp> ./cmd/rsdd` (inside
#          <kit>/rsdd; <tmp> is a mktemp file in <kit>/bin, renamed onto <kit>/bin/rsdd so a racing shim
#          never execs a half-written file). Build output goes to stderr only. If <kit>/bin cannot be
#          created or written, the reason is `bin dir not writable: <dir>` (not `build failed`).
#       3. Rebuild impossible but an old binary exists -> a `rsdd-exec: notice:` line on stderr, old one runs.
#       4. No binary and no way to get one -> exactly one `degraded:` line,
#          `degraded: rsdd-unavailable — <reason>` (`go not found`, `build failed`,
#          `bin dir not writable: <dir>`, `no sources at <path>`, `RSDD_BIN not executable: <path>`),
#          rc 2, nothing on stdout. Build diagnostics (the `go build` output) may precede that line on stderr.
#
#   rsdd_exec_hook <sweep|guard|gate> <group> <cmd> [args...]
#     Same as rsdd_exec, except that when rsdd is unavailable it exits 0 instead of failing the hook, with the
#     per-event behaviour of templates (b), (c) and (d) above. The degraded line is on stderr in every mode.
#       sweep: stdout = the SessionStart envelope from lib/hook-emit.sh (rsdd_hook_emit): JSON with jq, plain
#              text without it
#       guard: stdout = the PreToolUse `ask` decision JSON (jq when present, escaped printf otherwise)
#       gate:  stdout empty; stderr also carries `rsdd-exec-gate: state=allow branch=degraded (...)`, which
#              mirrors the `state=allow branch=degraded` fields of retro-gate.sh / return-token-gate.sh minus
#              their `target=` field (this hook has no target)
#     Unknown mode or fewer than 3 arguments -> usage on stderr, rc 2.
#
# FUNCTIONS ONLY: no top-level `set`, safe to source from a shim under `set -euo pipefail`, idempotent.
