#!/usr/bin/env bash
# verify-skill-drift-hook.sh — SessionStart hook: surfaces diverged deployed SKILL.md(s) and
# install --verify findings (bundle drift, stale kit checkout).
#
# Calls verify-skill-drift.sh --all (checks every harness registered in adapters.sh), then
# research-sdd-install.sh --verify (kit issue #1702 bundle digest + kit-checkout staleness).
# SILENT when all installed harnesses are in-sync / absent AND --verify has nothing to flag (exit 0).
# Emits additionalContext JSON via jq otherwise. Read-only. Wired from .claude/settings.json.
#
# Budget (openspec/specs/kit-session-cost/spec.md: SessionStart output < 8,000 chars total): the
# install --verify part contributes at most 4 typed lines of at most 170 chars each (SENTINEL-VERIFY-CAP).
# $RESEARCH_SDD_INSTALL_VERIFY_CMD overrides the install --verify command (test seam).
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh"
out="$("$here/verify-skill-drift.sh" --all 2>&1)"; rc=$?

vcmd="${RESEARCH_SDD_INSTALL_VERIFY_CMD:-$here/../install/research-sdd-install.sh}"
extra=""
vout=""; vrc=0; extra_skip=""; vnote=""   # initialised: an inherited env value must not force the skip path
if [ -x "$vcmd" ]; then
  # Validate the timeout BEFORE any use: bash evaluates $(( )) operands recursively (an array subscript runs command
  # substitution), and '', '.5', '10s' break it. Only 1..6 decimal digits with a value >= 1 are accepted (SENTINEL-VT-VALIDATE).
  vt=10
  if [ -n "${RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT+x}" ]; then
    case "$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT" in
      ''|*[!0-9]*|???????*) vt="" ;;
      *) vt="$((10#$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT))"; [ "$vt" -ge 1 ] || vt="" ;;
    esac
    if [ -z "$vt" ]; then
      vt=10
      if [ -z "$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT" ]; then   # set-but-empty reads better as '(empty)' than as =''
        vnote="verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT (empty), using 10s"
      else
        vnote="verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT='$(printf '%s' "$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT" | tr -cd '[:alnum:]._-' | cut -c1-30)', using 10s"
      fi
    fi
  fi
  vf=""; vf="$(mktemp 2>/dev/null)" || vf=""
  # RESEARCH_SDD_NO_TIMEOUT_BIN=1 forces the pure-bash watchdog below (test seam: stock macOS has no `timeout`).
  if [ -z "${RESEARCH_SDD_NO_TIMEOUT_BIN:-}" ] && command -v timeout >/dev/null 2>&1; then
    if [ -n "$vf" ]; then
      # Capture into a temp FILE, never a command substitution: a stalled grandchild (git rev-list, a hashing
      # pipe) keeps a pipe open and bash would wait on it, so the bound would not hold.
      trap 'rm -f "$vf" "$vf.fired"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      timeout "$vt" "$vcmd" --verify </dev/null >"$vf" 2>&1; vrc=$?   # SENTINEL-VERIFY-TIMEOUT
      vout="$(cat "$vf" 2>/dev/null)"; rm -f "$vf"
    else
      # No mktemp: still bounded for the direct child, but a stalled grandchild can hold the pipe open.
      vout="$(timeout "$vt" "$vcmd" --verify </dev/null 2>&1)"; vrc=$?
      vnote="${vnote:+$vnote$'\n'}verify: no mktemp - a stalled grandchild of install --verify is not bounded"
    fi
  elif [ -n "$vf" ]; then
    vpid=""; wpid=""   # cleared right after each `wait`: the EXIT trap never signals a pid that was already reaped
    trap '[ -n "$wpid" ] && kill "$wpid" 2>/dev/null; [ -n "$vpid" ] && kill "$vpid" 2>/dev/null; rm -f "$vf" "$vf.fired" "$vf.done"' EXIT   # SENTINEL-VERIFY-EXIT-TRAP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Watchdog: a background subshell polls until the run is marked done ($vf.done) or the deadline passes. It drops a
    # sentinel file when it fires, so a real exit 137/143 from install is not mistaken for the kill. There is no separate
    # sleeper process and no signal is needed to stop the watchdog (#1759: a TERM sent to a just-forked child is consumed by
    # the inherited `trap ... TERM` handler before exec, which orphaned the old sleeper and could hang `wait`); it exits
    # within one poll (0.1 s, or 1 s on the integer-sleep fallback below) of $vf.done appearing. The bound is counted in poll
    # iterations (vt*vper sleeps: vper=10 of 0.1 s, or 1 of 1 s), never wall-clock SECONDS: SECONDS granularity could fire after just over vt-1 s; drift only lengthens it.
    # A `sleep` that cannot do fractions (POSIX-only userland: it rejects 0.1, or reads it as 0 and returns at once) would burn
    # the whole count instantly and kill a healthy verify, so the watchdog probes `sleep 0.1` once (exit status, and elapsed when
    # $EPOCHREALTIME exists) and otherwise polls with integer `sleep 1` x vt (#1771). The fallback trades latency for safety: a
    # healthy verify can hold session start up to 1 s past its finish. Without $EPOCHREALTIME (bash < 5) only the exit-status
    # half runs, so a sleep that accepts 0.1 yet returns at once is not detected there.
    "$vcmd" --verify </dev/null >"$vf" 2>&1 & vpid=$!
    ( vsl=0.1; vper=10; vp0="${EPOCHREALTIME:-}"
      sleep 0.1 2>/dev/null || { vsl=1; vper=1; }   # SENTINEL-SLEEP-PROBE-RC
      # 50 ms threshold: a working `sleep 0.1` takes ~100 ms; one that reads 0.1 as 0 returns in <5 ms. 50 ms sits between them.
      if [ "$vper" -eq 10 ] && [ -n "$vp0" ] && [ -n "${EPOCHREALTIME:-}" ]; then   # radix may be '.' or ',' by locale
        [ $(( ${EPOCHREALTIME//[.,]/} - ${vp0//[.,]/} )) -ge 50000 ] || { vsl=1; vper=1; }   # SENTINEL-SLEEP-PROBE-ELAPSED
      fi
      vmax=$((vt * vper)); vi=0
      while [ ! -e "$vf.done" ] && [ "$vi" -lt "$vmax" ]; do sleep "$vsl"; vi=$((vi+1)); done
      if [ ! -e "$vf.done" ]; then : >"$vf.fired"; [ -e "$vf.done" ] || kill "$vpid" 2>/dev/null; fi ) >/dev/null 2>&1 & wpid=$!   # SENTINEL-VERIFY-WATCHDOG
    wait "$vpid" 2>/dev/null; vrc=$?; vpid=""
    : >"$vf.done"   # SENTINEL-VERIFY-DONE
    wait "$wpid" 2>/dev/null; wpid=""
    if [ -e "$vf.fired" ]; then vrc=124; fi
    vout="$(cat "$vf" 2>/dev/null)"; rm -f "$vf" "$vf.fired" "$vf.done"
  else
    extra_skip=1   # never an unbounded run
  fi
  # Only findings: harness drift / degraded and kit behind. match, absent, current stay silent; a kit
  # `degraded` (tarball install, no upstream) is un-clearable at session start, so it stays visible only
  # in `research-sdd-install.sh --verify` itself (SENTINEL-KIT-BEHIND-ONLY).
  extra="$(printf '%s\n' "$vout" | grep -E '^verify (harness=[^ ]+ status=(drift|degraded)|kit status=behind)' | cut -c1-170 | head -4)" # SENTINEL-VERIFY-CAP
  # Anti-silent-zero: a failing --verify that printed no typed finding must still be surfaced.
  if [ -n "${extra_skip:-}" ]; then
    extra="verify: install --verify skipped: no timeout available (no timeout binary, no mktemp)"
  elif [ "$vrc" -eq 124 ]; then
    extra="verify: install --verify timed out (RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, default 10s)${extra:+
$extra}"
  elif [ -z "$extra" ] && [ "$vrc" -ne 0 ]; then
    extra="verify: install --verify exited $vrc with no typed line"
  fi
  [ -n "$vnote" ] && [ -z "$extra_skip" ] && extra="${extra:+$extra
}$vnote"
else
  extra="verify: install --verify could not run (not executable: ${vcmd##*/})"
fi

[ "$rc" -eq 0 ] && [ -z "$extra" ] && exit 0   # all in-sync / all absent, nothing to flag → stay completely silent

case "$rc" in
  0) msg="WARN: research-sdd install --verify reports issues — see lines below" ;;
  1) msg="WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown" ;;
  *) msg="ERROR: verify-skill-drift.sh could not run for one or more harnesses — check kit install/adapters.sh" ;;
esac
[ -n "$extra" ] && out="${out:+$out
}$extra"

rsdd_hook_emit "$msg" "$out"
