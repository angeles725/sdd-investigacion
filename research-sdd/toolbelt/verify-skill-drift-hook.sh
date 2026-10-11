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
# install --verify part contributes at most 4 degraded/behind lines of at most 170 chars each (SENTINEL-VERIFY-CAP)
# plus, per drifted harness (3 at most), a header, 3 entries of at most 280 chars, a `(+N more ...)` line and a
# kept-hand-edit line of at most 160 chars: worst case ~1,150 chars per harness, ~3,450 for three (SENTINEL-DRIFT-CAP).
# The kit-staleness check (kit issue #2130) adds exactly ONE more line of at most 200 chars, stale or degraded
# (SENTINEL-KIT-STALE-WIDTH), so the worst case is ~3,650 chars.
# $RESEARCH_SDD_INSTALL_VERIFY_CMD overrides the install --verify command (test seam).
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)
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
    # the whole count instantly and kill a healthy verify, so the watchdog probes `sleep 0.1` (exit status, then up to five elapsed samples when
    # $EPOCHREALTIME exists) and otherwise polls with integer `sleep 1` x vt (#1771). The fallback trades latency for safety: a
    # healthy verify can hold session start up to 1 s past its finish. Without $EPOCHREALTIME (bash < 5) only the exit-status
    # half runs, so a sleep that accepts 0.1 yet returns at once is not detected there.
    "$vcmd" --verify </dev/null >"$vf" 2>&1 & vpid=$!
    ( vsl=0.1; vper=10; vp0="${EPOCHREALTIME:-}"
      sleep 0.1 2>/dev/null || { vsl=1; vper=1; }   # SENTINEL-SLEEP-PROBE-RC
      # 50 ms threshold: a working `sleep 0.1` takes ~100 ms; one that reads 0.1 as 0 returns in <5 ms. 50 ms sits between them.
      # A slow sample proves nothing (CPU contention can stretch the gap around a sleep that returned at once), only a FAST
      # one proves the sleep is broken, so five samples are taken and a single fast one is enough (#1978); a working sleep
      # pays four extra 0.1 s probes once per session start.
      if [ "$vper" -eq 10 ] && [ -n "$vp0" ] && [ -n "${EPOCHREALTIME:-}" ]; then   # radix may be '.' or ',' by locale
        for vn in 1 2 3 4 5; do   # SENTINEL-SLEEP-PROBE-SAMPLES
          [ $(( ${EPOCHREALTIME//[.,]/} - ${vp0//[.,]/} )) -ge 50000 ] || { vsl=1; vper=1; }   # SENTINEL-SLEEP-PROBE-ELAPSED
          [ "$vper" -eq 10 ] && [ "$vn" -lt 5 ] || break
          [ ! -e "$vf.done" ] || break   # verify already finished: the remaining samples would only hold the hook up
          vp0="$EPOCHREALTIME"; sleep 0.1 2>/dev/null
        done
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
  extra="$(printf '%s\n' "$vout" | grep -E '^verify (harness=[^ ]+ status=degraded|kit status=behind)' | cut -c1-170 | head -4)" # SENTINEL-VERIFY-CAP
  # Drift lines list every drifted member on ONE line, and an annotated entry carries the path to reconcile
  # into (kit issue #2120). Per harness: a header, then at most 3 entries of at most 280 chars (annotated
  # `(extra: ...)` entries first, so a regular-file TARGETS.md/BREAKTHROUGHS.md is never the one dropped),
  # then an explicit `(+N more ...)` line when entries were cut (no silent truncation), then the kept hand-edit
  # list on its own line. Only the `drifted=` field is split into entries; awk, not GNU-only sed `\n`.
  vdrift="$(printf '%s\n' "$vout" | grep -E '^verify harness=[^ ]+ status=drift ' | awk -v n=3 -v w=280 -v kw=160 '
    function clip(s, l) { return length(s) > l ? substr(s, 1, l) : s }   # SENTINEL-DRIFT-WIDTH
    {
      line = $0; kept = ""
      k = index(line, " kept-hand-edit=")
      if (k > 0) { kept = substr(line, k + 16); line = substr(line, 1, k - 1) }
      d = index(line, " drifted=")
      if (d == 0) { print clip(line, w); next }
      print substr(line, 1, d - 1)
      m = split(substr(line, d + 9), e, ",")
      shown = 0
      for (pass = 1; pass <= 2; pass++)
        for (i = 1; i <= m; i++) {
          ann = (index(e[i], "(extra: ") > 0)
          if ((pass == 1) != ann) continue
          if (shown < n) { print "  - " clip(e[i], w); shown++ }   # SENTINEL-DRIFT-COUNT
        }
      if (m > shown) print "  (+" (m - shown) " more - run research-sdd-install.sh --verify for the full list)"   # SENTINEL-DRIFT-MORE
      if (kept != "") print "  kept-hand-edit: " clip(kept, kw)
    }')"
  [ -z "$vdrift" ] || extra="$vdrift${extra:+
$extra}"
  # Anti-silent-zero: a failing --verify that printed no typed finding must still be surfaced.
  if [ -n "${extra_skip:-}" ]; then
    extra="verify: install --verify skipped: no timeout available (no timeout binary, no mktemp)"
  elif [ "$vrc" -eq 124 ]; then
    extra="verify: install --verify timed out (RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, default 10s; on the pure-bash watchdog path the bound is that value plus up to ~0.5 s of sleep-probe time)${extra:+
$extra}"
  elif [ -z "$extra" ] && [ "$vrc" -ne 0 ]; then
    extra="verify: install --verify exited $vrc with no typed line"
  fi
  [ -n "$vnote" ] && [ -z "$extra_skip" ] && extra="${extra:+$extra
}$vnote"
else
  extra="verify: install --verify could not run (not executable: ${vcmd##*/})"
fi

# Kit staleness (kit issue #2130): the kit this hook runs from is a mutable shared checkout that silently falls behind origin/main,
# and the shared checkout is deliberately not auto-updated while research sessions run. ONE typed line when it is behind its
# upstream by more than RESEARCH_SDD_KIT_STALE_MAX_COMMITS (default 20) or the last fetch is older than
# RESEARCH_SDD_KIT_STALE_MAX_DAYS (default 7); ONE typed `degraded` line when that cannot be measured (never silent, never a fake 0).
# LOCAL refs only - no fetch in a SessionStart hook - so the count may understate. Skipped when install --verify already printed
# `kit status=behind` (the same fact). RESEARCH_SDD_KIT_STALE_CHECK=off opts out; RESEARCH_SDD_KIT_DIR overrides the kit dir.
_rsdd_kit_stale() {   # SENTINEL-KIT-STALE
  local kdir="${RESEARCH_SDD_KIT_DIR:-$here/..}" kmax kdays top kd t ref n fh ft now age=""
  kmax="${RESEARCH_SDD_KIT_STALE_MAX_COMMITS:-20}"; kdays="${RESEARCH_SDD_KIT_STALE_MAX_DAYS:-7}"
  case "$kmax" in ''|*[!0-9]*|???????*) kmax=20 ;; esac   # validated before any arithmetic: $(( )) would evaluate a subscript (SENTINEL-KIT-STALE-VALIDATE)
  case "$kdays" in ''|*[!0-9]*|???????*) kdays=7 ;; esac
  kmax=$((10#$kmax)); kdays=$((10#$kdays))
  if ! command -v git >/dev/null 2>&1; then printf 'verify kit-stale status=degraded reason=git not found; cannot tell whether the kit is behind its upstream\n'; return 0; fi
  if ! top="$(git -C "$kdir" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$top" ]; then
    printf 'verify kit-stale status=degraded reason=kit dir is not a git checkout (tarball install?); cannot tell whether it is behind\n'; return 0
  fi
  kd="$(cd -P "$kdir" 2>/dev/null && pwd -P)"; t="$(cd -P "$top" 2>/dev/null && pwd -P)"
  if [ -z "$kd" ] || [ -z "$t" ] || { [ "$t" != "$kd" ] && [ "$t" != "$(dirname "$kd")" ]; }; then
    printf 'verify kit-stale status=degraded reason=kit dir sits inside an unrelated repo; its upstream is not the kit'"'"'s\n'; return 0
  fi
  if ref="$(git -C "$kd" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" && [ -n "$ref" ]; then :
  elif git -C "$kd" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then ref="origin/main"
  else printf 'verify kit-stale status=degraded reason=no upstream ref (no @{upstream}, no origin/main); cannot tell whether the kit is behind\n'; return 0; fi
  if ! n="$(git -C "$kd" rev-list --count "HEAD..$ref" 2>/dev/null)" || ! [[ "$n" =~ ^[0-9]+$ ]]; then
    printf 'verify kit-stale status=degraded reason=could not count commits behind %s\n' "$ref"; return 0
  fi
  # Age of the last fetch: FETCH_HEAD mtime (GNU stat -c, BSD stat -f); a never-fetched clone falls back to the upstream tip's commit time.
  fh="$(git -C "$kd" rev-parse --git-path FETCH_HEAD 2>/dev/null)"; case "$fh" in /*) ;; *) fh="$kd/$fh" ;; esac
  ft=""; if [ -e "$fh" ]; then ft="$(stat -c %Y "$fh" 2>/dev/null || stat -f %m "$fh" 2>/dev/null)"; else ft="$(git -C "$kd" log -1 --format=%ct "$ref" 2>/dev/null)"; fi
  now="$(date +%s 2>/dev/null)"
  if [[ "$ft" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]]; then age=$(( (now - ft) / 86400 )); [ "$age" -ge 0 ] || age=0; fi
  if [ -z "$age" ] && [ "$n" -le "$kmax" ]; then   # the count passed but the age is unreadable: say so rather than report a clean zero
    printf 'verify kit-stale status=degraded reason=cannot read the age of the last fetch (behind=%s of max %s)\n' "$n" "$kmax"; return 0
  fi
  if [ "$n" -gt "$kmax" ] || { [ -n "$age" ] && [ "$age" -gt "$kdays" ]; }; then   # SENTINEL-KIT-STALE-THRESHOLD
    printf 'verify kit-stale status=stale behind=%s (max %s) fetch_age=%sd (max %sd) local refs, may understate; when no research session runs: git -C %s pull --ff-only\n' \
      "$n" "$kmax" "${age:-?}" "$kdays" "$kd" | cut -c1-200   # SENTINEL-KIT-STALE-WIDTH
  fi
  return 0
}
if [ "${RESEARCH_SDD_KIT_STALE_CHECK:-}" != "off" ] && [[ "$extra" != "verify kit status=behind"* && "$extra" != *$'\n'"verify kit status=behind"* ]]; then  # SENTINEL-KIT-STALE-DEDUPE
  kstale="$(_rsdd_kit_stale)"
  [ -z "$kstale" ] || extra="${extra:+$extra
}$kstale"
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
