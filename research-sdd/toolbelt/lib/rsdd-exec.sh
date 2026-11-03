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

  # Link-time symbol that `rsdd version --source-hash` reads; the same value as SOURCE_HASH_SYM in rsdd/Makefile
  # (tests/rsdd-exec.test.sh compares the two, so a drift is a failing case).
  _RSDD_EXEC_HASH_SYM='github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands.sourceHash'

  # _rsdd_exec_valid_hash TEXT — rc 0 when TEXT is exactly sha256:<64 lowercase hex>.
  _rsdd_exec_valid_hash() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

  # _rsdd_exec_shell_hash SRC — the source hash of the tree at SRC, computed in shell with the selection and the
  # manifest of rsdd/internal/commands/testdata/source-hash/README.md (find | LC_ALL=C sort | path NUL sha LF | sha256).
  # rc 0 sets _RSDD_EXEC_TREE; rc 1 sets _RSDD_EXEC_HWHY (the hash is UNAVAILABLE, never "fresh"): no sha256 tool, a
  # failed find, an empty selection, a selected path with a newline or a backslash (sha256sum would escape it), or a
  # sha tool that failed or answered out of step. One sha256 invocation covers all files (no fork per file).
  _rsdd_exec_shell_hash() {
    local src="$1" p line out i
    local -a sha files=() lines=()
    _RSDD_EXEC_TREE=""; _RSDD_EXEC_HWHY=""
    if command -v sha256sum >/dev/null 2>&1; then sha=(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then sha=(shasum -a 256 -b)
    else _RSDD_EXEC_HWHY="no sha256 tool (sha256sum, shasum)"; return 1; fi
    if ! command -v find >/dev/null 2>&1 || ! command -v sort >/dev/null 2>&1; then _RSDD_EXEC_HWHY="find or sort not found"; return 1; fi
    while IFS= read -r -d '' p; do files+=("$p"); done < <(
      cd -- "$src" 2>/dev/null || { printf 'FIND-FAILED\0'; exit 0; }
      { find . -type f \( -name '*.go' ! -name '*_test.go' -o -path ./go.mod -o -path ./go.sum -o -path './vendor/*' -o -path './embed/*' -o -path '*/embed/*' \) ! -path './testdata/*' ! -path '*/testdata/*' ! -name testdata -print0 2>/dev/null || printf 'FIND-FAILED\0'; } | LC_ALL=C sort -z)
    # An empty selection is decided BEFORE any "${files[@]}" expansion: on bash < 4.4 that expansion is an unbound
    # variable error under the caller's `set -u`.
    if [ "${#files[@]}" -eq 0 ]; then _RSDD_EXEC_HWHY="no source files matched"; return 1; fi
    for p in "${files[@]}"; do
      case "$p" in
        FIND-FAILED) _RSDD_EXEC_HWHY="scanning the sources failed"; return 1 ;;
        *$'\n'* | *\\*) _RSDD_EXEC_HWHY="a source path contains a newline or a backslash"; return 1 ;;
      esac
    done
    out="$(cd -- "$src" 2>/dev/null && "${sha[@]}" -- "${files[@]}" 2>/dev/null)" || { _RSDD_EXEC_HWHY="${sha[0]} failed over the sources"; return 1; }
    while IFS= read -r line; do lines+=("$line"); done <<<"$out"
    if [ "${#lines[@]}" -ne "${#files[@]}" ]; then _RSDD_EXEC_HWHY="${sha[0]} answered out of step"; return 1; fi
    for ((i = 0; i < ${#files[@]}; i++)); do
      line="${lines[i]}"
      if [ "${line:64:1}" != " " ] || [ "${line:66}" != "${files[i]}" ]; then _RSDD_EXEC_HWHY="${sha[0]} answered out of step"; return 1; fi
    done
    out="$(
      for ((i = 0; i < ${#files[@]}; i++)); do printf '%s\0%s\n' "${files[i]#./}" "${lines[i]:0:64}"; done | "${sha[@]}" 2>/dev/null)" || { _RSDD_EXEC_HWHY="${sha[0]} failed over the manifest"; return 1; }
    out="sha256:${out:0:64}"
    if ! _rsdd_exec_valid_hash "$out"; then _RSDD_EXEC_HWHY="${sha[0]} printed no hash"; return 1; fi
    _RSDD_EXEC_TREE="$out"
  }

  # _rsdd_exec_go_hash SRC — the authoritative hash from `go run ./cmd/rsdd-srchash .` inside SRC (sets _RSDD_EXEC_TREE).
  _rsdd_exec_go_hash() {
    local h
    h="$(cd -- "$1" 2>/dev/null && go run ./cmd/rsdd-srchash . 2>/dev/null)" || return 1
    _rsdd_exec_valid_hash "$h" || return 1
    _RSDD_EXEC_TREE="$h"
  }

  # _rsdd_exec_tree_hash SRC — shell hash, else the go fallback. rc 0 sets _RSDD_EXEC_TREE; rc 1 sets _RSDD_EXEC_HWHY.
  _rsdd_exec_tree_hash() {
    local why
    _rsdd_exec_shell_hash "$1" && return 0
    why="$_RSDD_EXEC_HWHY"
    if ! command -v go >/dev/null 2>&1; then _RSDD_EXEC_HWHY="$why; go not found for the fallback"; return 1; fi
    _rsdd_exec_go_hash "$1" && return 0
    _RSDD_EXEC_HWHY="$why; go run rsdd-srchash failed"; return 1
  }

  # _rsdd_exec_check BIN SRC — rc 0 fresh (BIN's `version --source-hash` equals the tree hash) · 1 stale (any other
  # answer, `sha256:unknown` and a non-zero exit included) · 2 cannot tell (sets _RSDD_EXEC_HWHY).
  _rsdd_exec_check() {
    local got
    _RSDD_EXEC_GOT=""
    _rsdd_exec_tree_hash "$2" || return 2
    got="$("$1" version --source-hash 2>/dev/null </dev/null)" || return 1
    _RSDD_EXEC_GOT="$got"
    [ "$got" = "$_RSDD_EXEC_TREE" ] || return 1
  }

  # _rsdd_exec_build KIT — rc 0 built · 3 <kit>/bin cannot be created or written · 1 the build failed (a failed
  # stamp computation included). The binary is stamped with the tree hash from `go run ./cmd/rsdd-srchash .`.
  _rsdd_exec_build() {
    local kit="$1" bin="$1/bin/rsdd" tmp
    mkdir -p -- "$kit/bin" 2>/dev/null || return 3
    tmp="$(mktemp "$kit/bin/.rsdd.XXXXXX" 2>/dev/null)" || return 3
    ( trap 'rm -f -- "$tmp"' EXIT; cd -- "$kit/rsdd" && h="$(go run ./cmd/rsdd-srchash .)" && _rsdd_exec_valid_hash "$h" && CGO_ENABLED=0 go build -ldflags "-s -w -X $_RSDD_EXEC_HASH_SYM=$h" -o "$tmp" ./cmd/rsdd && chmod 755 "$tmp" && mv -f "$tmp" "$bin" ) >&2 || return 1
  }

  # _rsdd_exec_lock_wait — sets _RSDD_EXEC_LOCKWAIT: seconds to wait for the rebuild lock. Default 120; the env var
  # RSDD_EXEC_LOCK_WAIT overrides it and must be a positive integer (anything else: one notice, the default).
  _rsdd_exec_lock_wait() {
    _RSDD_EXEC_LOCKWAIT=120
    [ -n "${RSDD_EXEC_LOCK_WAIT+x}" ] || return 0
    if [[ "$RSDD_EXEC_LOCK_WAIT" =~ ^[1-9][0-9]{0,8}$ ]]; then _RSDD_EXEC_LOCKWAIT="$RSDD_EXEC_LOCK_WAIT"
    else echo "rsdd-exec: notice: RSDD_EXEC_LOCK_WAIT must be a positive integer, got '$RSDD_EXEC_LOCK_WAIT'; using 120" >&2; fi
  }

  # _rsdd_exec_disagree_known KIT — rc 0 when <kit>/bin/.rsdd-disagree records exactly the binary hash and the tree hash
  # of the check that just ran (_RSDD_EXEC_GOT, _RSDD_EXEC_TREE): that pair was already rebuilt once.
  _rsdd_exec_disagree_known() {
    local marker
    [ -n "$_RSDD_EXEC_GOT" ] || return 1
    marker="$(cat -- "$1/bin/.rsdd-disagree" 2>/dev/null)" || return 1
    [ "$marker" = "$_RSDD_EXEC_GOT $_RSDD_EXEC_TREE" ]
  }

  # _rsdd_exec_build_locked KIT — _rsdd_exec_build under an exclusive flock on <kit>/bin/.rsdd.lock, waited for at most
  # _RSDD_EXEC_LOCKWAIT seconds. Freshness is re-checked after the lock is taken, so a shim that waited does not
  # rebuild what another one just built. After a build the shell hash is compared with the stamp just written; a
  # disagreement (the shell and Go selections differ) is recorded in <kit>/bin/.rsdd-disagree as "<stamp> <shell hash>"
  # so the next calls do not rebuild in a loop.
  # rc 0 built · 10 already fresh after the wait · 11 built but the shell hash disagrees with the stamp · 12 the lock
  # stayed busy · 1 build failed · 3 <kit>/bin not writable.
  _rsdd_exec_build_locked() {
    local kit="$1" bin="$1/bin/rsdd" lock="$1/bin/.rsdd.lock" rc=0 crc
    _rsdd_exec_lock_wait
    if ! command -v flock >/dev/null 2>&1; then
      echo "rsdd-exec: notice: flock not found; rebuilding without a lock" >&2
      _rsdd_exec_build "$kit"; return
    fi
    mkdir -p -- "$kit/bin" 2>/dev/null || return 3
    { : >>"$lock"; } 2>/dev/null || return 3
    (
      { exec {lfd}>>"$lock"; } 2>/dev/null || exit 3
      flock -w "$_RSDD_EXEC_LOCKWAIT" "$lfd" || exit 12
      if [ -f "$bin" ] && [ -x "$bin" ]; then
        crc=0; _rsdd_exec_check "$bin" "$kit/rsdd" || crc=$?
        if [ "$crc" -eq 0 ]; then exit 10; fi
        if [ "$crc" -eq 1 ] && _rsdd_exec_disagree_known "$kit"; then exit 11; fi
      fi
      _rsdd_exec_build "$kit" || exit $?
      crc=0; _rsdd_exec_check "$bin" "$kit/rsdd" || crc=$?
      if [ "$crc" -eq 1 ] && [ -n "$_RSDD_EXEC_GOT" ]; then
        printf '%s %s\n' "$_RSDD_EXEC_GOT" "$_RSDD_EXEC_TREE" >"$kit/bin/.rsdd-disagree" 2>/dev/null
        exit 11
      fi
      exit 0
    ) || rc=$?
    return "$rc"
  }

  # _rsdd_exec_resolve — sets _RSDD_EXEC_BIN and returns 0, or sets _RSDD_EXEC_WHY and returns 2.
  _rsdd_exec_resolve() {
    local kit="$_RSDD_EXEC_KIT" bin src have=0 need=0 brc crc=0 why note
    _RSDD_EXEC_BIN="" _RSDD_EXEC_WHY=""
    if [ -n "${RSDD_BIN:-}" ]; then
      if [ ! -f "$RSDD_BIN" ] || [ ! -x "$RSDD_BIN" ]; then _RSDD_EXEC_WHY="RSDD_BIN not executable: $RSDD_BIN"; return 2; fi
      _RSDD_EXEC_BIN="$RSDD_BIN"; return 0
    fi
    if [ -z "$kit" ]; then _RSDD_EXEC_WHY="cannot resolve the kit root"; return 2; fi
    bin="$kit/bin/rsdd" src="$kit/rsdd"
    if [ -f "$bin" ] && [ -x "$bin" ]; then have=1; fi
    if [ "$have" -eq 0 ]; then
      need=1
    elif [ -d "$src" ]; then
      _rsdd_exec_check "$bin" "$src" || crc=$?
      case "$crc" in
        0) ;;
        1) need=1 ;;
        *) echo "rsdd-exec: degraded: rsdd-source-hash-unavailable — $_RSDD_EXEC_HWHY" >&2 ;;
      esac
    fi
    if [ "$need" -eq 1 ]; then
      if [ ! -d "$src" ]; then
        _RSDD_EXEC_WHY="no sources at $src"; return 2
      elif ! command -v go >/dev/null 2>&1; then
        if [ "$have" -eq 0 ]; then _RSDD_EXEC_WHY="go not found"; return 2; fi
        echo "rsdd-exec: notice: go not found; running a binary older than its sources: $bin" >&2
      else
        brc=0; _rsdd_exec_build_locked "$kit" || brc=$?
        if [ "$brc" -eq 10 ]; then brc=0; fi
        if [ "$brc" -eq 11 ]; then brc=0; echo "rsdd-exec: degraded: rsdd-source-hash-unavailable — shell and go source hashes disagree" >&2; fi
        if [ "$brc" -ne 0 ]; then
          case "$brc" in
            3) why="bin dir not writable: $kit/bin"; note="$why" ;;
            12) why="rebuild lock busy"; note="rebuild lock busy for ${_RSDD_EXEC_LOCKWAIT}s" ;;
            *) why="build failed"; note="rebuild failed" ;;
          esac
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
#       2. <kit>/bin/rsdd, where <kit> is derived from THIS file (lib -> toolbelt -> kit). Fresh = the binary's
#          `version --source-hash` output equals the source hash of <kit>/rsdd, computed in shell with the
#          selection and manifest of rsdd/internal/commands/testdata/source-hash/README.md (one sha256sum, or
#          `shasum -a 256`, over all files). Stale = any other answer: a different hash, `sha256:unknown`, a
#          non-zero exit. The mtime of files plays no part: touching a file does not rebuild, a content change
#          with an old mtime does. A binary that is missing or stale is rebuilt under an exclusive flock on
#          <kit>/bin/.rsdd.lock, with freshness RE-CHECKED once the lock is held (a shim that waited does not
#          rebuild what another one just built; the fresh path takes no lock). The build stamps the hash:
#          `go run ./cmd/rsdd-srchash .` then `CGO_ENABLED=0 go build -ldflags "-s -w -X <SOURCE_HASH_SYM>=<hash>" -o <tmp>
#          ./cmd/rsdd` (inside <kit>/rsdd; <tmp> is a mktemp file in <kit>/bin, renamed onto <kit>/bin/rsdd so a
#          racing shim never execs a half-written file); a failed stamp computation is a failed build. Build
#          output goes to stderr only. If <kit>/bin cannot be created or written, the reason is `bin dir not
#          writable: <dir>` (not `build failed`). Without `flock` the rebuild runs unlocked after one
#          `rsdd-exec: notice: flock not found; rebuilding without a lock` line (the atomic rename keeps it safe).
#          The wait for that lock is bounded: `flock -w <seconds>`, default 120, overridden by the env var
#          RSDD_EXEC_LOCK_WAIT (a positive integer; any other value gives one `rsdd-exec: notice: RSDD_EXEC_LOCK_WAIT
#          must be a positive integer, got '<v>'; using 120` line and the default). When the lock stays busy: an
#          existing binary runs after `rsdd-exec: notice: rebuild lock busy for <N>s; running a binary older than its
#          sources: <bin>`; without a binary the reason is `rebuild lock busy` (see 4.), so a hung `go build` never
#          blocks the hooks that wait behind it for good.
#          When the shell hash is UNAVAILABLE (no sha256 tool; a failed find; no source file; a path with a newline or a
#          backslash; a sha tool that failed or answered out of step, or printed no hash) `go run ./cmd/rsdd-srchash .`
#          stands in for it; if that fails too, or go is absent, one line
#          `rsdd-exec: degraded: rsdd-source-hash-unavailable — <reason>` goes to stderr and the existing binary runs
#          unchanged (an unknown is never "fresh" and never triggers a rebuild). The same line, with the reason
#          `shell and go source hashes disagree`, is printed when a rebuild has just stamped a hash that the shell
#          hash still differs from: the new binary runs, the pair (stamp, shell hash) is remembered in
#          <kit>/bin/.rsdd-disagree, and the next calls with the same pair do not rebuild again. A change of the sources
#          changes the pair and allows one new rebuild. Known limit: the selected files go to the sha tool as arguments,
#          so a source tree whose paths exceed the OS argument limit (E2BIG) makes the shell hash UNAVAILABLE.
#       3. Rebuild impossible but an old binary exists -> a `rsdd-exec: notice:` line on stderr, old one runs.
#       4. No binary and no way to get one -> exactly one `degraded:` line,
#          `degraded: rsdd-unavailable — <reason>` (`go not found`, `build failed`,
#          `bin dir not writable: <dir>`, `rebuild lock busy`, `no sources at <path>`, `RSDD_BIN not executable: <path>`),
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
