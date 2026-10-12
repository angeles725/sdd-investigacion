#!/usr/bin/env bash
# kit-maint-common.sh — helpers shared by the kit-maintenance pipeline tools (kit issue #2212). Sourced, never
# executed. FUNCTIONS ONLY: no `set` options (a sourced `set` would mutate the caller's shell).
# The caller sets KIT_TOOL (its own name, the prefix of every line it prints) before use.
#
#   kit_say MSG...            print `<KIT_TOOL>: MSG`
#   kit_fail CODE STATE [MSG] print `<KIT_TOOL>: STATE: MSG`, then exit CODE (the typed exit state)
#   kit_probe_deps DEP...     rc 3 + `<KIT_TOOL>: degraded: missing runtime dependency: <deps>` when any DEP is not on
#                             PATH (CLAUDE.md section 7: a probe at startup, never a silent pass)
#   kit_retry TRIES CMD...    run CMD up to TRIES times (network blips); sleeps KIT_RETRY_SLEEP*attempt seconds
#                             between tries (default 5); returns the last rc; retry notes go to stderr
#   kit_state_dir             default state dir: ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/pipeline

kit_say() { printf '%s: %s\n' "${KIT_TOOL:-kit}" "$*"; }

kit_fail() {
  local code="$1" state="$2"; shift 2
  kit_say "$state${*:+: $*}"
  exit "$code"
}

kit_probe_deps() {
  local d missing=''
  for d in "$@"; do
    command -v "$d" >/dev/null 2>&1 || missing="$missing $d"
  done
  if [ -n "$missing" ]; then
    echo "${KIT_TOOL:-kit}: degraded: missing runtime dependency:$missing"
    return 3
  fi
  return 0
}

kit_retry() {
  local tries="$1" n=1 rc=0
  shift
  while :; do
    "$@"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$n" -ge "$tries" ] && return "$rc"
    kit_say "retry $n/$tries after rc=$rc: $*" >&2
    sleep $(( ${KIT_RETRY_SLEEP:-5} * n ))
    n=$((n + 1))
  done
}

kit_state_dir() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/pipeline"; }
