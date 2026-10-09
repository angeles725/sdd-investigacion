#!/usr/bin/env bash
# gh-visibility.test.sh — suite for lib/gh-visibility.sh (kit issue #1820): ONE bounded
# `gh repo view --json visibility` probe shared by ensure-remote / init / status.
#
# Invariant under test: the probe returns 0 ONLY for a decided PUBLIC/PRIVATE/INTERNAL answer; a stalled gh,
# a missing gh, a failing gh and an unrecognised answer are each a distinct typed state and NEVER PRIVATE
# (fail closed). The bound holds with `timeout`, with only `gtimeout`, and with neither (bash watchdog).
# Every case runs under a HERMETIC PATH (symlinks to only the tools the lib needs + a stub gh) so the host's
# gh / timeout cannot leak in. --prove-teeth mutates the lib (lib/mutant.sh) and requires each case to go red.
#
# Usage: gh-visibility.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/gh-visibility.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

CORE=(mktemp cat rm env sleep sed tr)
REAL_TO="$(type -P timeout 2>/dev/null || true)"
for u in "${CORE[@]}"; do [ -n "$(type -P "$u")" ] || { echo "FATAL: required tool '$u' missing" >&2; exit 2; }; done

# mkbin NAME MODE : hermetic bin dir. MODE = timeout | gtimeout | none (which bounder is on PATH);
#   a stub `gh` (unless MODE ends with -nogh) driven by GH_OUT / GH_RC / GH_ERR / GH_SLEEP, logging
#   GH_PROMPT_DISABLED, GH_REPO, argv and cwd to $bin/gh.log.
mkbin() {
  local b="$TMP/$1" u mode="$2"; mkdir -p "$b"
  for u in "${CORE[@]}"; do ln -sf "$(type -P "$u")" "$b/$u"; done
  case "$mode" in
    timeout*)  [ -n "$REAL_TO" ] && ln -sf "$REAL_TO" "$b/timeout" ;;
    gtimeout*) [ -n "$REAL_TO" ] && ln -sf "$REAL_TO" "$b/gtimeout" ;;
  esac
  case "$mode" in *-setsid*) ln -sf "$(type -P setsid)" "$b/setsid" ;; esac
  case "$mode" in *-ps*) ln -sf "$(type -P ps)" "$b/ps" ;; esac
  case "$mode" in *-fakeps*) printf '#!%s\necho 1\n' "$BASH_BIN" > "$b/ps"; chmod +x "$b/ps" ;; esac
  case "$mode" in *-gatesetsid*) rm -f "$b/setsid"; printf '#!%s\necho $$ > "$SETSID_PID"\ni=0; while [ ! -e "$SETSID_GATE" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done\nexec "%s" "$@"\n' "$BASH_BIN" "$(type -P setsid)" > "$b/setsid"; chmod +x "$b/setsid" ;; esac
  case "$mode" in *-gateps*) printf '#!%s\ni=0; while [ ! -e "$PS_GATE" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done\nexec "%s" "$@"\n' "$BASH_BIN" "$(type -P ps)" > "$b/ps"; chmod +x "$b/ps" ;; esac
  case "$mode" in *-gatebadps*) printf '#!%s\ni=0; while [ ! -e "$PS_GATE" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done\necho 1\n' "$BASH_BIN" > "$b/ps"; chmod +x "$b/ps" ;; esac
  case "$mode" in *-slowps*) printf '#!%s\nsleep 0.3\necho 999999\n' "$BASH_BIN" > "$b/ps"; chmod +x "$b/ps" ;; esac
  case "$mode" in *-nogh) ;; *)
    {
      printf '#!%s\n' "$BASH_BIN"
      printf 'echo "PROMPT=${GH_PROMPT_DISABLED-UNSET} REPO=${GH_REPO-UNSET} ARGS=$* PWD=$PWD" >> "%s/gh.log"\n' "$b"
      cat <<'EOF'
[ -n "${GH_ERR:-}" ] && echo "$GH_ERR" >&2
[ -n "${GH_IGNORE_TERM:-}" ] && { trap '' TERM; i=0; while [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done; }
[ -n "${GH_GRANDCHILD:-}" ] && { if [ -n "${GH_GC_IGNORE_TERM:-}" ]; then ( trap '' TERM; exec sleep 300 ) & else sleep 300 & fi; echo $! > "$GH_GC_PID_FILE"; wait; }
[ -n "${GH_DELAY:-}" ] && sleep "$GH_DELAY"
[ -n "${GH_SLEEP:-}" ] && exec sleep "$GH_SLEEP"
[ -n "${GH_OUT:-}" ] && echo "$GH_OUT"
exit "${GH_RC:-0}"
EOF
    } > "$b/gh"; chmod +x "$b/gh" ;;
  esac
  printf '%s' "$b"
}

# probe LIB BIN [cwd] — run the probe in a clean subshell under the hermetic PATH; prints one result line.
# Extra env (GH_*, RSDD_GH_TIMEOUT) is inherited from the caller's `env` prefix.
probe() {
  local lib="$1" bin="$2" cwd="${3:-}"
  PATH="$bin" "$BASH_BIN" -c '. "$1"; gh_visibility_probe gh o/r "$2"; rc=$?; printf "rc=%s STATE=%s RC=%s WHY=%s BOUND=%s BY=%s BAD=%s RAW=%s\n" "$rc" "$GHV_STATE" "$GHV_RC" "$GHV_WHY" "$GHV_BOUND" "$GHV_BOUNDED_BY" "$GHV_BAD_TIMEOUT" "$GHV_RAW"' _ "$lib" "$cwd" 2>&1
}
has() { grep -qF -- "$2" <<<"$1"; }

B_TO="$(mkbin b-to timeout)"; B_GT="$(mkbin b-gt gtimeout)"; B_NONE="$(mkbin b-none none)"; B_NOGH="$(mkbin b-nogh none-nogh)"
HAVE_SETSID=0; [ -n "$(type -P setsid)" ] && HAVE_SETSID=1
HAVE_PS=0; [ -n "$(type -P ps)" ] && HAVE_PS=1
if [ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ]; then B_WDG="$(mkbin b-wdg none-setsid-ps)"; fi
[ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ] && B_GATEPS="$(mkbin b-gateps none-setsid-gateps)"
[ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ] && B_GATESETSID="$(mkbin b-gatesetsid none-gatesetsid-ps)"
[ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ] && B_GATEBADPS="$(mkbin b-gatebadps none-setsid-gatebadps)"
[ "$HAVE_SETSID" = 1 ] && { B_NOPS="$(mkbin b-nops none-setsid)"; B_FAKEPS="$(mkbin b-fakeps none-setsid-fakeps)"; B_SLOWPS="$(mkbin b-slowps none-setsid-slowps)"; }

echo "== gh-visibility.test.sh =="

# --- decided answers (rc 0) --------------------------------------------------------------------------------
c_decided() { # LIB — PUBLIC / PRIVATE / INTERNAL / lower-case are decided and normalised
  local lib="$1" v r
  for v in PUBLIC PRIVATE INTERNAL; do
    r="$(GH_OUT=$v probe "$lib" "$B_TO")"; has "$r" "rc=0 STATE=$v " || return 1
  done
  r="$(GH_OUT=public probe "$lib" "$B_TO")"; has "$r" "rc=0 STATE=PUBLIC " || return 1
}
c_decided "$LIB" && ok "1 PUBLIC / PRIVATE / INTERNAL / lower-case -> decided, rc 0" || no "1 decided answers"

# --- fail closed: every non-decided result is rc!=0 and never PRIVATE ------------------------------------
c_missing() { local r; r="$(probe "$1" "$B_NOGH")"; has "$r" "rc=1 STATE=GH_MISSING "; }
c_missing "$LIB" && ok "2 gh missing -> GH_MISSING rc 1" || no "2 gh missing"
c_error() { local r; r="$(GH_OUT=PRIVATE GH_RC=1 GH_ERR='HTTP 401: bad credentials' probe "$1" "$B_TO")"
  has "$r" "rc=1 STATE=GH_ERROR RC=1 WHY=HTTP 401: bad credentials "; }
c_error "$LIB" && ok "3 gh error (even printing PRIVATE) -> GH_ERROR, reason captured, never PRIVATE" || no "3 gh error"
c_unrec() { local r; r="$(GH_OUT=WEIRD probe "$1" "$B_TO")"; has "$r" "rc=1 STATE=UNRECOGNISED " && has "$r" "RAW=WEIRD"; }
c_unrec "$LIB" && ok "4 unrecognised answer -> UNRECOGNISED rc 1" || no "4 unrecognised answer"
c_empty() { local r; r="$(probe "$1" "$B_TO")"; has "$r" "rc=1 STATE=UNRECOGNISED " ; }
c_empty "$LIB" && ok "5 empty answer with exit 0 -> UNRECOGNISED (never a silent empty)" || no "5 empty answer"

# --- the bound: timeout, gtimeout, watchdog ------------------------------------------------------------------
c_slow() { # LIB BIN BY — a gh stalled for 30s with RSDD_GH_TIMEOUT=1 returns TIMEOUT well inside 15s
  local r t0=$SECONDS; r="$(GH_SLEEP=30 RSDD_GH_TIMEOUT=1 GH_OUT=PRIVATE probe "$1" "$2")"
  [ $((SECONDS-t0)) -lt 15 ] && has "$r" "rc=1 STATE=TIMEOUT RC=124 " && has "$r" "BY=$3 "
}
c_slow_to() { c_slow "$1" "$B_TO" timeout; }
c_slow_gt() { c_slow "$1" "$B_GT" gtimeout; }
c_slow_wd() { c_slow "$1" "$B_NONE" watchdog; }
if [ -z "$REAL_TO" ]; then no "6-8 need a real timeout binary on the host to build the hermetic PATHs"; else
  c_slow_to "$LIB" && ok "6 stalled gh + timeout on PATH -> TIMEOUT (BY=timeout)"   || no "6 timeout bound"
  c_slow_gt "$LIB" && ok "7 stalled gh + only gtimeout -> TIMEOUT (BY=gtimeout)"    || no "7 gtimeout bound"
  c_slow_wd "$LIB" && ok "8 stalled gh + no timeout binary -> TIMEOUT via watchdog" || no "8 watchdog bound"
fi

# --- RSDD_GH_TIMEOUT validation: one default (20), one fallback ------------------------------------------
c_bound() { # LIB — unset -> 20 silently; '', abc, 0, 000, -5, 1234567890 -> 20 + BAD=1; 007 -> 7; 5 -> 5
  local lib="$1" r v
  r="$(env -u RSDD_GH_TIMEOUT GH_OUT=PRIVATE PATH="$B_TO" "$BASH_BIN" -c '. "$1"; gh_visibility_probe gh o/r; echo "BOUND=$GHV_BOUND BAD=$GHV_BAD_TIMEOUT"' _ "$lib" 2>&1)"
  has "$r" "BOUND=20 BAD=0" || return 1
  for v in '' abc 0 000 -5 1234567890 '1 2'; do
    r="$(RSDD_GH_TIMEOUT="$v" GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=20 " && has "$r" "BAD=1 " || return 1
  done
  r="$(RSDD_GH_TIMEOUT=007 GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=7 " && has "$r" "BAD=0 " || return 1
  r="$(RSDD_GH_TIMEOUT=5 GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=5 " && has "$r" "BAD=0 "
}
c_bound "$LIB" && ok "9 RSDD_GH_TIMEOUT: unset/empty/garbage/0/overlong -> 20 (flagged unless unset); 007 -> 7" || no "9 timeout validation"

# --- environment contract --------------------------------------------------------------------------------------
c_env() { # LIB — GH_PROMPT_DISABLED=1, GH_REPO unset even when exported, repo arg + cwd passed through
  local lib="$1" wd="$TMP/wd" r log; mkdir -p "$wd"; : > "$B_TO/gh.log"
  r="$(GH_REPO=evil/other GH_PROMPT_DISABLED=0 GH_OUT=PRIVATE probe "$lib" "$B_TO" "$wd")"
  log="$(cat "$B_TO/gh.log")"
  has "$r" "rc=0 STATE=PRIVATE " && has "$log" "PROMPT=1 REPO=UNSET ARGS=repo view o/r --json visibility --jq .visibility PWD=$wd"
}
c_env "$LIB" && ok "10 GH_PROMPT_DISABLED=1, GH_REPO unset, argv + cwd as documented" || no "10 environment contract"

c_dflt() { # LIB — a caller-set GHV_DEFAULT_BOUND (status: 10) is the default AND the garbage fallback
  local lib="$1" r
  r="$(unset RSDD_GH_TIMEOUT; GHV_DEFAULT_BOUND=10 GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=10 " && has "$r" "BAD=0 " || return 1
  r="$(GHV_DEFAULT_BOUND=10 RSDD_GH_TIMEOUT=abc GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=10 " && has "$r" "BAD=1 " || return 1
  r="$(GHV_DEFAULT_BOUND=10 RSDD_GH_TIMEOUT=3 GH_OUT=PRIVATE probe "$lib" "$B_TO")"; has "$r" "BOUND=3 "
}
c_dflt "$LIB" && ok "11 GHV_DEFAULT_BOUND overrides the default (and the garbage fallback); RSDD_GH_TIMEOUT still wins" || no "11 caller default bound"

# --- gh_bounded_run (kit issue #1841): the same bound for any other gh call, output passed through ------------
# brun LIB BIN [args...] — run `gh_bounded_run gh <args...>` under the hermetic PATH; one result line, then the
# passthrough output (stdout+stderr of gh) after "OUT:".
brun() {
  local lib="$1" bin="$2" of="$TMP/brun.out"; shift 2
  PATH="$bin" "$BASH_BIN" -c '. "$1"; of="$2"; shift 2; gh_bounded_run gh "$@" >"$of" 2>&1; rc=$?; printf "rc=%s STATE=%s RC=%s BOUND=%s BY=%s BAD=%s\n" "$rc" "$GHV_STATE" "$GHV_RC" "$GHV_BOUND" "$GHV_BOUNDED_BY" "$GHV_BAD_TIMEOUT"; printf "OUT:"; cat "$of"' _ "$lib" "$of" "$@" 2>&1
}
c_run_ok() { # LIB — success: rc 0, STATE=OK, stdout/stderr pass through, GH_PROMPT_DISABLED=1, GH_REPO unset, argv intact
  local lib="$1" r log; : > "$B_TO/gh.log"
  r="$(GH_REPO=evil/x GH_PROMPT_DISABLED=0 GH_OUT=created GH_ERR=chatter brun "$lib" "$B_TO" repo create o/r --private)"; log="$(cat "$B_TO/gh.log")"
  has "$r" "rc=0 STATE=OK RC=0 " && has "$r" "created" && has "$r" "chatter" \
    && has "$log" "PROMPT=1 REPO=UNSET ARGS=repo create o/r --private "
}
c_run_ok "$LIB" && ok "12 gh_bounded_run: success passes output through, PROMPT=1, GH_REPO unset" || no "12 bounded-run success"
c_run_err() { local r; r="$(GH_RC=3 GH_ERR='boom' brun "$1" "$B_TO" repo edit o/r)"; has "$r" "rc=3 STATE=GH_ERROR RC=3 " && has "$r" "boom"; }
c_run_err "$LIB" && ok "13 gh_bounded_run: failing gh -> its exit code, STATE=GH_ERROR (not TIMEOUT)" || no "13 bounded-run error"
c_run_miss() { local r; r="$(brun "$1" "$B_NOGH" repo edit o/r)"; has "$r" "rc=127 STATE=GH_MISSING "; }
c_run_miss "$LIB" && ok "14 gh_bounded_run: gh missing -> rc 127, GH_MISSING" || no "14 bounded-run gh missing"
c_run_slow() { # LIB BIN BY — a stalled gh with RSDD_GH_TIMEOUT=1 -> rc 124 STATE=TIMEOUT inside 15s, BY as named
  local r t0=$SECONDS; r="$(GH_SLEEP=30 RSDD_GH_TIMEOUT=1 brun "$1" "$2" repo create o/r)"
  [ $((SECONDS-t0)) -lt 15 ] && has "$r" "rc=124 STATE=TIMEOUT RC=124 BOUND=1 BY=$3 "
}
c_run_slow_to() { c_run_slow "$1" "$B_TO" timeout; }
c_run_slow_wd() { c_run_slow "$1" "$B_NONE" watchdog; }
if [ -z "$REAL_TO" ]; then no "15-17 need a real timeout binary on the host to build the hermetic PATHs"; else
  c_run_slow_to "$LIB"                 && ok "15 gh_bounded_run: stalled gh + timeout -> TIMEOUT (BY=timeout)"          || no "15 bounded-run timeout"
  c_run_slow "$LIB" "$B_GT" gtimeout   && ok "16 gh_bounded_run: stalled gh + only gtimeout -> TIMEOUT"                 || no "16 bounded-run gtimeout"
  c_run_slow_wd "$LIB"                 && ok "17 gh_bounded_run: stalled gh + no timeout binary -> TIMEOUT via watchdog" || no "17 bounded-run watchdog"
fi
c_run_term() { # LIB BIN BY — a gh that IGNORES TERM is still cut off (KILL after the grace), well inside 15s
  local r t0=$SECONDS; r="$(GH_IGNORE_TERM=1 RSDD_GH_TIMEOUT=1 brun "$1" "$2" repo create o/r)"
  [ $((SECONDS-t0)) -lt 15 ] && has "$r" "rc=124 STATE=TIMEOUT RC=124 BOUND=1 BY=$3 "
}
c_run_term_to() { c_run_term "$1" "$B_TO" timeout; }
c_run_term_wd() { c_run_term "$1" "$B_NONE" watchdog; }
if [ -n "$REAL_TO" ]; then
  c_run_term_to "$LIB" && ok "19 gh_bounded_run: TERM-ignoring gh + timeout -> KILLed after grace, TIMEOUT"   || no "19 bounded-run term-ignoring (timeout)"
  c_run_term_wd "$LIB" && ok "20 gh_bounded_run: TERM-ignoring gh + watchdog -> KILLed after grace, TIMEOUT" || no "20 bounded-run term-ignoring (watchdog)"
fi
c_run_knob() { # LIB — GHV_BOUND_ENV/GHV_BOUND_DEFAULT: own knob, own default, same validation; RSDD_GH_TIMEOUT ignored
  local lib="$1" r
  r="$(unset MYB; GHV_BOUND_ENV=MYB GHV_BOUND_DEFAULT=60 RSDD_GH_TIMEOUT=3 GH_OUT=x brun "$lib" "$B_TO" repo create o/r)"; has "$r" "BOUND=60 " && has "$r" "BAD=0" || return 1
  r="$(MYB=7 GHV_BOUND_ENV=MYB GHV_BOUND_DEFAULT=60 RSDD_GH_TIMEOUT=3 GH_OUT=x brun "$lib" "$B_TO" repo create o/r)"; has "$r" "BOUND=7 " && has "$r" "BAD=0" || return 1
  r="$(MYB=abc GHV_BOUND_ENV=MYB GHV_BOUND_DEFAULT=60 GH_OUT=x brun "$lib" "$B_TO" repo create o/r)"; has "$r" "BOUND=60 " && has "$r" "BAD=1"
}
c_run_knob "$LIB" && ok "21 gh_bounded_run: GHV_BOUND_ENV / GHV_BOUND_DEFAULT select a separate validated knob" || no "21 bounded-run own knob"
c_run_bad() { local r; r="$(RSDD_GH_TIMEOUT=abc GH_OUT=x brun "$1" "$B_TO" repo create o/r)"; has "$r" "rc=0 STATE=OK RC=0 BOUND=20 " && has "$r" "BAD=1"; }
c_run_bad "$LIB" && ok "18 gh_bounded_run: garbage RSDD_GH_TIMEOUT -> default 20, BAD=1 (shared validation)" || no "18 bounded-run bad timeout"

# --- kit issue #1854: the watchdog kills the whole PROCESS GROUP, so a grandchild cannot outlive the bound ----------
# The stub gh spawns a long-lived `sleep` grandchild (pid recorded) and waits on it; on the bound it is TERMed. With
# only the direct child killed the grandchild survives (orphaned); with the group killed it is gone.
# gone PIDFILE — poll up to ~2s for the recorded grandchild to disappear; ALWAYS reap it afterwards (hermetic).
gone() {
  local pf="$1" pid i=0; pid="$(cat "$pf" 2>/dev/null)"; [ -n "$pid" ] || return 1
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; return 1; fi
  return 0
}
c_gc_run() { # LIB — gh_bounded_run over the watchdog: a grandchild of the bounded command is gone after the timeout
  local pf="$TMP/gc-run.pid" r; rm -f "$pf"
  r="$(GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT=1 brun "$1" "$B_WDG" repo create o/r)"
  has "$r" "rc=124 STATE=TIMEOUT " && gone "$pf"
}
c_gc_probe() { # LIB — gh_visibility_probe over the watchdog: same invariant
  local pf="$TMP/gc-probe.pid" r; rm -f "$pf"
  r="$(GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT=1 probe "$1" "$B_WDG")"
  has "$r" "STATE=TIMEOUT " && gone "$pf"
}
c_gc_term() { # LIB — a grandchild that IGNORES TERM is swept with KILL once the leader is gone (watchdog disarmed after wait)
  local pf="$TMP/gc-term.pid" r; rm -f "$pf"
  r="$(GH_GRANDCHILD=1 GH_GC_IGNORE_TERM=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT=1 brun "$1" "$B_WDG" repo create o/r)"
  has "$r" "rc=124 STATE=TIMEOUT " && gone "$pf"
}
c_gc_mode() { # LIB — GHV_GROUP names the mode: setsid when group kill is on; child-only + a typed DEGRADED note when not
  local lib="$1" r
  r="$(PATH="$B_WDG" GH_SLEEP=1 "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r >/dev/null; echo "GROUP=$GHV_GROUP NOTE=$GHV_NOTE"' _ "$lib" 2>&1)"
  has "$r" "GROUP=setsid NOTE=" && ! has "$r" "DEGRADED" || return 1
  r="$(PATH="$B_NONE" GH_OUT=x "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r >/dev/null; echo "GROUP=$GHV_GROUP NOTE=$GHV_NOTE"' _ "$lib" 2>&1)"
  has "$r" "GROUP=child-only NOTE=DEGRADED" || return 1
  r="$(PATH="$B_WDG" GH_DELAY=1 GH_OUT=PRIVATE "$BASH_BIN" -c 'set -m; . "$1"; gh_visibility_probe gh o/r; echo "STATE=$GHV_STATE GROUP=$GHV_GROUP NOTE=$GHV_NOTE"' _ "$lib" 2>&1)"
  has "$r" "STATE=PRIVATE GROUP=child-only NOTE=DEGRADED"
}
c_gc_timeout_path() { # LIB — a real timeout binary on PATH: no watchdog, so no group note
  local r; r="$(PATH="$B_TO" GH_OUT=x "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r >/dev/null; echo "GROUP=[$GHV_GROUP] NOTE=[$GHV_NOTE]"' _ "$1" 2>&1)"
  has "$r" "GROUP=[] NOTE=[]"
}
if [ "$HAVE_SETSID" != 1 ] || [ "$HAVE_PS" != 1 ]; then no "22-24 need setsid on the host to build the group-kill PATH"; else
  c_gc_run "$LIB"   && ok "22 gh_bounded_run watchdog: a grandchild of the bounded command is killed with the group" || no "22 bounded-run grandchild survives"
  c_gc_probe "$LIB" && ok "23 gh_visibility_probe watchdog: a grandchild of the probe is killed with the group"      || no "23 probe grandchild survives"
  c_gc_mode "$LIB"  && ok "24 GHV_GROUP=setsid with group kill; child-only + DEGRADED note without setsid / under job control" || no "24 group mode / degraded note"
fi
[ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ] && { c_gc_term "$LIB" && ok "26 a TERM-ignoring grandchild is KILLed by the post-bound group sweep" || no "26 TERM-ignoring grandchild survives"; }
c_gc_timeout_path "$LIB" && ok "25 timeout/gtimeout path leaves GHV_GROUP and GHV_NOTE empty" || no "25 timeout path group globals"

# --- kit issue #1854 (review round): no bare-pid kill after reap, verified pgid, signal trap ------------------------
# ktrace LIB BIN — run a TIMED-OUT gh_bounded_run (stub gh just sleeps, so its group is EMPTY once the leader dies) with
# `kill` wrapped to log "$*"; prints the log. A KILL/TERM aimed at a BARE numeric pid after the leader was reaped could hit
# a recycled pid, so only the group form (`-KILL -- -PID`) may appear in group mode.
ktrace() {
  local lib="$1" bin="$2" lf="$TMP/ktrace.log"; : > "$lf"
  GH_SLEEP=30 RSDD_GH_TIMEOUT=1 PATH="$bin" "$BASH_BIN" -c '. "$1"; KLOG="$2"; kill() { printf "%s\n" "$*" >> "$KLOG"; builtin kill "$@"; }; gh_bounded_run gh repo create o/r' _ "$lib" "$lf" >/dev/null 2>&1
  cat "$lf"
}
c_nobare() { # LIB — group mode: no bare-pid TERM/KILL ever; the post-bound sweep is the group form only
  local r; r="$(ktrace "$1" "$B_WDG")"
  ! grep -qE '^-(KILL|TERM) [0-9]+$' <<<"$r" && grep -qE '^-KILL -- -[0-9]+$' <<<"$r"
}
c_nosweep_childonly() { # LIB — child-only mode: no sweep at all after the reap (no KILL), the pre-reap TERM is the only signal
  local r; r="$(ktrace "$1" "$B_NONE")"
  ! grep -q -- '-KILL' <<<"$r" && grep -qE '^-TERM [0-9]+$' <<<"$r"
}
c_pgid_verify() { # LIB — setsid present but pgid cannot be verified (no ps) or disagrees (fake ps) -> child-only + typed note
  local lib="$1" r b
  for b in "$B_NOPS" "$B_FAKEPS"; do
    r="$(PATH="$b" GH_SLEEP=3 RSDD_GH_TIMEOUT=1 "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r >/dev/null; echo "GROUP=$GHV_GROUP NOTE=$GHV_NOTE"' _ "$lib" 2>&1)"
    has "$r" "GROUP=child-only NOTE=DEGRADED" && has "$r" "pgid" || return 1
  done
}
# RUNB — per-run unique base for the watchdog bounds (6 digits, so it passes the RSDD_GH_TIMEOUT validation): the `sleep N`
# patterns below cannot match a sibling worktree's run, and nothing outside this run's own N is ever pkilled.
RUNB=$((600000 + RANDOM))
# sleeps_gone N — poll ~3s for NO process `sleep N` (the watchdog's own sleep, N = the unique RSDD_GH_TIMEOUT of the case);
# always reaps what is left, so a failing case never leaves a live watchdog behind.
sleeps_gone() {
  local n="$1" i=0
  while pgrep -f "^sleep $n\$" >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  if pgrep -f "^sleep $n\$" >/dev/null 2>&1; then pkill -KILL -f "^sleep $n\$" 2>/dev/null; return 1; fi
  return 0
}
# sigcase LIB CALL N SIG — run CALL (a lib call) under the watchdog with bound N, signal the CALLER with SIG once the grandchild
# is up; return 0 only when the grandchild AND the watchdog's sleep are gone. Cleans up on every exit.
sigcase() {
  local lib="$1" call="$2" n="$3" sg="$4" pf="$TMP/gc-sig-$3.pid" td="$TMP/td-$3-$4" bp i rc=0; rm -f "$pf"; mkdir -p "$td"
  TMPDIR="$td" GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT="$n" PATH="$B_WDG" "$BASH_BIN" -c '. "$1"; '"$call" _ "$lib" >/dev/null 2>&1 &
  bp=$!; i=0
  while [ ! -s "$pf" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  kill -"$sg" "$bp" 2>/dev/null; wait "$bp" 2>/dev/null
  gone "$pf" || rc=1
  sleeps_gone "$n" || rc=1
  [ -z "$(ls -A "$td" 2>/dev/null)" ] || rc=1   # the signalled run must not leave its mktemp files behind
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
c_sig() { # LIB — SIGTERM/SIGHUP to the CALLER during a watchdog-bounded run kills the group AND disarms the watchdog
  sigcase "$1" 'gh_bounded_run gh repo create o/r' $((RUNB+1)) TERM && sigcase "$1" 'gh_bounded_run gh repo create o/r' $((RUNB+2)) HUP
}
c_sig_probe() { # LIB — the same for gh_visibility_probe
  sigcase "$1" 'gh_visibility_probe gh o/r' $((RUNB+3)) TERM
}
c_sig_subst() { # LIB — a signal to a run INSIDE $(...) must not kill the top-level shell (re-raise on BASHPID, not $$)
  local lib="$1" pf="$TMP/gc-sub.pid" of="$TMP/sub.out" bp sp i rc=0; rm -f "$pf" "$of"
  GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT=$((RUNB+4)) PATH="$B_WDG" "$BASH_BIN" -c '. "$1"; x="$(gh_bounded_run gh repo create o/r)"; echo AFTER' _ "$lib" >"$of" 2>&1 &
  bp=$!; i=0
  while [ ! -s "$pf" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  sp="$(pgrep -P "$bp" 2>/dev/null | head -n 1)"
  if [ -n "$sp" ]; then kill -TERM "$sp" 2>/dev/null; else rc=1; fi
  wait "$bp" 2>/dev/null
  grep -q AFTER "$of" 2>/dev/null || rc=1
  gone "$pf" || rc=1
  sleeps_gone $((RUNB+4)) || rc=1
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
c_sig_nonexit() { # LIB — the caller's restored trap does NOT exit: typed CALLER_SIGNALLED, never TIMEOUT; group + watchdog gone
  local lib="$1" pf="$TMP/gc-nx.pid" of="$TMP/nx.out" bp i rc=0 n=$((RUNB+5)); rm -f "$pf" "$of"
  GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT="$n" PATH="$B_WDG" "$BASH_BIN" -c 'trap "echo CAUGHT" TERM; . "$1"; gh_bounded_run gh repo create o/r; echo "STATE=$GHV_STATE"' _ "$lib" >"$of" 2>&1 &
  bp=$!; i=0
  while [ ! -s "$pf" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  kill -TERM "$bp" 2>/dev/null; wait "$bp" 2>/dev/null
  has "$(cat "$of" 2>/dev/null)" "STATE=CALLER_SIGNALLED" || rc=1
  ! has "$(cat "$of" 2>/dev/null)" "STATE=TIMEOUT" || rc=1
  gone "$pf" || rc=1
  sleeps_gone "$n" || rc=1
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
# sigearly LIB CALL N — kit issue #1911: the signal arrives while the pgid verification is still running (the launch->trap
# window). A gated `ps` BLOCKS the verification until the test releases it, so the signal is delivered inside that window
# by construction (a barrier, not a sleep race). The caller must still take the group down and leave no temp files.
sigearly() {
  local lib="$1" call="$2" n="$3" pf="$TMP/gc-early-$3.pid" td="$TMP/td-early-$3" gate="$TMP/gate-$3" bp i rc=0; rm -f "$pf" "$gate"; mkdir -p "$td"
  TMPDIR="$td" PS_GATE="$gate" GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT="$n" PATH="$B_GATEPS" "$BASH_BIN" -c '. "$1"; '"$call" _ "$lib" >/dev/null 2>&1 &
  bp=$!; i=0
  while [ ! -s "$pf" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$pf" ] || rc=1
  kill -TERM "$bp" 2>/dev/null
  : > "$gate"                                    # release the gated ps only AFTER the signal was sent
  wait "$bp" 2>/dev/null
  gone "$pf" || rc=1
  sleeps_gone "$n" || rc=1
  [ -z "$(ls -A "$td" 2>/dev/null)" ] || rc=1
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
c_sig_early() { # LIB — a signal during the pgid verification (before the old trap install) still takes the group down
  sigearly "$1" 'gh_bounded_run gh repo create o/r' $((RUNB+6)) && sigearly "$1" 'gh_visibility_probe gh o/r' $((RUNB+7))
}
# c_sig_early_nx LIB — same window (a gated `ps` that then answers a WRONG pgid, so the handler runs between the failed
# comparison and the `kill -0` liveness probe), but the caller's trap does NOT exit: typed CALLER_SIGNALLED and NO misleading
# "already exited" GHV_NOTE (the verification and the watchdog arming are skipped once a signal was seen).
c_sig_early_nx() {
  local lib="$1" pf="$TMP/gc-enx.pid" of="$TMP/enx.out" gate="$TMP/gate-enx" bp i rc=0 n=$((RUNB+8)); rm -f "$pf" "$of" "$gate"
  PS_GATE="$gate" GH_GRANDCHILD=1 GH_GC_PID_FILE="$pf" RSDD_GH_TIMEOUT="$n" PATH="$B_GATEBADPS" "$BASH_BIN" -c 'trap "echo CAUGHT" TERM; . "$1"; gh_bounded_run gh repo create o/r; echo "STATE=$GHV_STATE NOTE=[$GHV_NOTE] WD=[${GHV_WDPID-}]"' _ "$lib" >"$of" 2>&1 &
  bp=$!; i=0
  while [ ! -s "$pf" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$pf" ] || rc=1
  kill -TERM "$bp" 2>/dev/null
  : > "$gate"
  wait "$bp" 2>/dev/null
  has "$(cat "$of" 2>/dev/null)" "STATE=CALLER_SIGNALLED NOTE=[] WD=[]" || rc=1    # WD empty: the arm path never ran (GHV_WDPID is set by it)
  gone "$pf" || rc=1
  sleeps_gone "$n" || rc=1
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
# c_sig_presetsid LIB — kit issue #1911 (review round 2): the signal arrives after the leader was forked but BEFORE it exec'd
# setsid (a stub setsid blocks on a gate), so the leader's group does not exist yet and `kill -- -PID` gets ESRCH. The
# not-yet-verified leader must then be killed by pid, else it later runs `setsid gh ...` unbounded after the caller died.
c_sig_presetsid() {
  local lib="$1" sp="$TMP/ps-setsid.pid" gate="$TMP/ps-setsid.gate" bin="$B_GATESETSID" bp i rc=0
  rm -f "$sp" "$gate" "$bin/gh.log"
  SETSID_PID="$sp" SETSID_GATE="$gate" GH_SLEEP=30 RSDD_GH_TIMEOUT=$((RUNB+9)) PATH="$bin" "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r' _ "$lib" >/dev/null 2>&1 &
  bp=$!; i=0
  while [ ! -s "$sp" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$sp" ] || rc=1
  kill -TERM "$bp" 2>/dev/null
  wait "$bp" 2>/dev/null
  : > "$gate"                                    # release the blocked setsid only AFTER the caller was signalled and gone
  gone "$sp" || rc=1                             # the leader must already be dead (gone() also reaps a survivor)
  [ ! -s "$bin/gh.log" ] || rc=1                 # and the bounded command must never have started
  sleeps_gone $((RUNB+9)) || rc=1
  kill -KILL "$bp" 2>/dev/null
  return "$rc"
}
# --- the handler's pid sources, called DIRECTLY under a non-exiting caller TERM trap (kit issue #1911, review) -------
# hrun LIB BODY — run BODY after sourcing the lib in a clean shell whose TERM trap only echoes (so the re-raise survives).
hrun() { PATH="$B_WDG" "$BASH_BIN" -c 'trap "echo CAUGHT" TERM; . "$1"; '"$2" _ "$1" 2>&1; }
c_h_stale() { # LIB — an UNRELATED background job started before the traps (stale `$!`) is never killed by the handler
  local r; r="$(hrun "$1" 'sleep 300 & s=$!; _ghv_set_traps; _ghv_on_signal TERM >/dev/null; sleep 0.3; if kill -0 "$s" 2>/dev/null; then echo STALE=ALIVE; else echo STALE=DEAD; fi; builtin kill -KILL "$s" 2>/dev/null; wait "$s" 2>/dev/null')"
  has "$r" "STALE=ALIVE"
}
c_h_fallback() { # LIB — _GHV_PID still empty (signal between fork and `pid=$!`): the NEW background job is killed via `$!`
  local r; r="$(hrun "$1" '_ghv_set_traps; ( exec sleep 300 ) & s=$!; _ghv_on_signal TERM >/dev/null; wait "$s"; echo "FB_RC=$?"')"
  has "$r" "FB_RC=137"
}
c_h_nobare() { # LIB — group mode with a known pid: the handler signals the GROUP form only (no bare-pid KILL, kit #1854)
  local r; r="$(hrun "$1" 'KLOG=$(mktemp); kill() { printf "%s\n" "$*" >> "$KLOG"; builtin kill "$@"; }; ( exec sleep 300 ) & s=$!; _ghv_set_traps; _GHV_PID="$s" _GHV_GRP=group _GHV_VERIFIED=1; _ghv_on_signal TERM >/dev/null; builtin kill -KILL "$s" 2>/dev/null; wait "$s" 2>/dev/null; cat "$KLOG"; rm -f "$KLOG"')"
  grep -qE '^-KILL -- -[0-9]+$' <<<"$r" && ! grep -qE '^-KILL [0-9]+$' <<<"$r"
}
c_gone_unverified() { # LIB — a leader that is already gone is NOT a verified group: child-only (nothing to sweep)
  local r; r="$(PATH="$B_SLOWPS" GH_OUT=x "$BASH_BIN" -c '. "$1"; gh_bounded_run gh repo create o/r >/dev/null; echo "GROUP=$GHV_GROUP NOTE=$GHV_NOTE"' _ "$1" 2>&1)"
  has "$r" "GROUP=child-only NOTE=DEGRADED" && has "$r" "already exited" && ! has "$r" "could not verify"
}
c_trap_restored() { # LIB — a caller's own TERM trap is intact after a watchdog-bounded run, and no lib trap is left behind
  local r; r="$(PATH="$B_WDG" GH_OUT=x "$BASH_BIN" -c 'trap "echo mine" TERM; . "$1"; gh_bounded_run gh repo create o/r >/dev/null; trap -p TERM; trap -p INT; trap -p HUP' _ "$1" 2>&1)"
  has "$r" "echo mine" && ! has "$r" "_ghv"
}
if [ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ]; then
  c_nobare "$LIB"            && ok "27 group mode: no bare-pid TERM/KILL after the leader is reaped; the sweep signals the group only" || no "27 bare-pid kill after reap"
  c_nosweep_childonly "$LIB" && ok "28 child-only mode: no post-bound sweep at all" || no "28 child-only sweep"
  c_pgid_verify "$LIB"       && ok "29 setsid but pgid unverifiable / wrong -> child-only + typed DEGRADED note naming pgid" || no "29 pgid verification"
  command -v pgrep >/dev/null 2>&1 || no "30-36 need pgrep on the host to prove the watchdog is disarmed"
  c_sig "$LIB"               && ok "30 SIGTERM/SIGHUP to the caller kills the group of a watchdog-bounded gh_bounded_run and disarms the watchdog" || no "30 signal trap (bounded-run)"
  c_sig_probe "$LIB"         && ok "31 SIGTERM to the caller kills the group of a watchdog-bounded probe" || no "31 signal trap (probe)"
  c_sig_subst "$LIB"         && ok "33 a signal inside \$(...) kills only that subshell, not the top-level shell; watchdog and group gone" || no "33 re-raise inside command substitution"
  c_sig_nonexit "$LIB"       && ok "35 caller trap that does not exit -> CALLER_SIGNALLED (not TIMEOUT), group and watchdog gone" || no "35 non-exiting caller trap"
  c_sig_early "$LIB"         && ok "36 a signal during the pgid verification (before the leader is verified) still kills the group and leaves no temp files" || no "36 signal in the launch-to-trap window"
  c_sig_presetsid "$LIB"     && ok "41 a signal before the leader exec'd setsid (no group yet) still kills the leader; gh never runs" || no "41 signal before setsid"
  c_sig_early_nx "$LIB"      && ok "37 the same window with a non-exiting caller trap -> CALLER_SIGNALLED, no 'already exited' note, group gone" || no "37 early signal, non-exiting trap"
  c_h_stale "$LIB"           && ok "38 handler: a stale \$! (unrelated earlier background job) is never killed" || no "38 stale \$! killed"
  c_h_fallback "$LIB"        && ok "39 handler: with _GHV_PID still empty the NEW background job (\$!) is killed" || no "39 \$! fallback"
  c_h_nobare "$LIB"          && ok "40 handler: group mode with a known pid signals the group only, never a bare pid" || no "40 bare-pid kill in group mode"
  c_gone_unverified "$LIB"   && ok "34 leader already gone -> unverified -> child-only + DEGRADED note" || no "34 gone leader treated as verified"
  c_trap_restored "$LIB"     && ok "32 the caller's own traps are restored after the run" || no "32 trap restore"
fi

# ------------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # tooth LABEL CASEFN SED_EXPR [needs-timeout] — build a mutant of the lib, require the case to FAIL on it.
  tooth() {
    local label="$1" fn="$2" expr="$3" m="$TMP/mut-$1.sh" extra=("${@:4}")
    if ! mutant_chain_or_count fail "teeth $label" "$LIB" "$m" "$expr"; then return; fi
    if "$fn" "$m" "${extra[@]}"; then no "teeth $label: case still holds on the mutant — THEATER"
    else ok "teeth $label: case goes red"; fi
  }
  echo "-- teeth --"
  tooth missing-ok       c_missing 's/GHV_STATE=GH_MISSING; return 1/GHV_STATE=GH_MISSING; return 0/'
  tooth error-failopen   c_error   's/if \[ "\$rc" != 0 \]; then GHV_STATE=GH_ERROR; return 1; fi/:/'
  tooth unrec-failopen   c_unrec   's/\*) GHV_STATE=UNRECOGNISED; return 1 ;;/*) GHV_STATE=PRIVATE; return 0 ;;/'
  tooth decided-lost     c_decided 's/PUBLIC|PRIVATE|INTERNAL) GHV_STATE="\$GHV_RAW"; return 0 ;;/PUBLIC|PRIVATE) GHV_STATE="$GHV_RAW"; return 0 ;;/'
  tooth bound-zero-ok    c_bound   's/-eq 0 \]; then GHV_BAD_TIMEOUT=1/-eq 99 ]; then GHV_BAD_TIMEOUT=1/'
  tooth dflt-ignored     c_dflt    's/dflt="\${GHV_DEFAULT_BOUND:-20}"/dflt=20/'
  tooth prompt-dropped   c_env     's/GH_PROMPT_DISABLED=1/GH_X_DISABLED=1/g'
  tooth ghrepo-kept      c_env     's/env -u GH_REPO /env /g'
  tooth run-prompt-dropped c_run_ok  's/GH_PROMPT_DISABLED=1 "\$@"/GH_X_DISABLED=1 "$@"/;s/GH_PROMPT_DISABLED=1 "\$bounder"/GH_X_DISABLED=1 "$bounder"/'
  tooth run-error-lost     c_run_err 's/elif \[ "\$rc" != 0 \]; then GHV_STATE=GH_ERROR$/elif false; then GHV_STATE=GH_ERROR/'
  tooth run-missing-ok     c_run_miss 's/GHV_STATE=GH_MISSING; GHV_RC=127; return 127/GHV_STATE=GH_MISSING; GHV_RC=127; return 0/'
  tooth run-ghrepo-kept    c_run_ok  's/env -u GH_REPO GH_PROMPT_DISABLED=1 "\$@"/env GH_PROMPT_DISABLED=1 "$@"/;s/env -u GH_REPO GH_PROMPT_DISABLED=1 "\$bounder"/env GH_PROMPT_DISABLED=1 "$bounder"/'
  if [ -n "$REAL_TO" ]; then
    tooth run-timeout-state c_run_slow_to 's/if \[ "\$rc" = 124 \]; then GHV_STATE=TIMEOUT$/if false; then GHV_STATE=TIMEOUT/'
    tooth run-watchdog-143  c_run_slow_wd 's/\[ "\$rc" = 143 \] \&\& rc=124$/:/'
    tooth run-watchdog-nokill c_run_slow_wd 's/& wait; _ghv_sig TERM "\$1" "\$3"$/\& wait; :/;s/_ghv_sig KILL "\$1" "\$3" )/: )/'
    tooth run-no-kill-escalation c_run_term_wd 's/_ghv_sig KILL "\$1" "\$3" )/: )/'
    tooth run-no-k-flag      c_run_term_to 's/"\$bounder" -k 2 "\$t"/"$bounder" "$t"/'
    tooth run-knob-ignored   c_run_knob 's/benv="\${GHV_BOUND_ENV:-RSDD_GH_TIMEOUT}"/benv=RSDD_GH_TIMEOUT/'
    if [ "$HAVE_SETSID" = 1 ] && [ "$HAVE_PS" = 1 ]; then
      tooth sweep-bare-fallback  c_nobare   's/kill -KILL -- "-\$1" 2>\/dev\/null || :/kill -KILL -- "-$1" 2>\/dev\/null || kill -KILL "$1" 2>\/dev\/null/'
      tooth sweep-childonly-runs c_nosweep_childonly 's/\[ -n "\$2" \] || return 0/:/'
      tooth verify-skipped       c_pgid_verify 's/_ghv_verify_group "\$pid" || {/true || {/g'
      tooth verify-no-compare    c_pgid_verify 's/\[ "\$pg" = "\$1" \] \&\& return 0/return 0/'
      tooth trap-dropped         c_sig      's/^      _ghv_set_traps; .*$/      :/'
      tooth trap-dropped-probe   c_sig_probe 's/^      _ghv_set_traps; .*$/      :/'
      tooth handler-no-disarm    c_sig      's/^    \[ -z "\$_GHV_WD" \] || kill "\$_GHV_WD" 2>\/dev\/null || :.*$/    :/'
      tooth handler-no-disarm-p  c_sig_probe 's/^    \[ -z "\$_GHV_WD" \] || kill "\$_GHV_WD" 2>\/dev\/null || :.*$/    :/'
      # kit issue #1911: the old order — traps installed only AFTER the pgid verification — must go red on the barrier case
      tooth handler-bare-in-group c_h_nobare 's/^      if \[ -n "\$fb" \] || .*$/      kill -KILL "$pid" 2>\/dev\/null || :/'
      tooth handler-no-presetsid-kill c_sig_presetsid 's/^      if \[ -n "\$fb" \] || .*$/      if [ -n "$fb" ]; then kill -KILL "$pid" 2>\/dev\/null || :; fi/'
      tooth handler-bang-unconditional c_h_stale 's/^    if \[ -z "\$pid" \] \&\& \[ "\${!:-}" != "\$_GHV_BANG0" \]; then pid="\$!"; fb=1; fi.*$/    if [ -z "$pid" ]; then pid="$!"; fb=1; fi/'
      tooth handler-bang-deleted c_h_fallback 's/^    if \[ -z "\$pid" \] \&\& \[ "\${!:-}" != "\$_GHV_BANG0" \]; then pid="\$!"; fb=1; fi.*$/    :/'
      tooth verify-note-after-signal c_sig_early_nx 's/\[ -n "\$_GHV_SIGNALLED" \] || _ghv_note_unverified "\$vrc"/_ghv_note_unverified "$vrc"/g'
      tooth arm-after-signal c_sig_early_nx 's/^      if \[ -z "\$_GHV_SIGNALLED" \]; then _ghv_arm_watchdog.*$/      _ghv_arm_watchdog "$pid" "$t" "$grpflag"; wdpid="$GHV_WDPID"/'
      tooth trap-after-verify    c_sig_early 's/^      _ghv_set_traps; .*$/      :/;s/^      if \[ -z "\$_GHV_SIGNALLED" \]; then _ghv_arm_watchdog.*$/      _ghv_set_traps; _GHV_PID="$pid" _GHV_GRP="$grpflag"; _ghv_arm_watchdog "$pid" "$t" "$grpflag"; wdpid="$GHV_WDPID"/'
      tooth handler-ignores-late-pid c_sig_early 's/^    local pid="\${_GHV_PID:-}" fb=""$/    local pid="" fb=""/;s/^    if \[ -z "\$pid" \] \&\& \[ "\${!:-}".*$/    :/'
      tooth reraise-dollar-dollar c_sig_subst 's/kill -s "\$1" "\$BASHPID"/kill -s "$1" "$$"/'
      tooth gone-is-verified     c_gone_unverified 's/kill -0 "\$1" 2>\/dev\/null || return 2/kill -0 "$1" 2>\/dev\/null || return 0/'
      tooth gone-check-deleted   c_gone_unverified 's/^      kill -0 "\$1" 2>\/dev\/null || return 2.*$/      :/'
      tooth signalled-flag-lost  c_sig_nonexit 's/^    _GHV_SIGNALLED="\$1" .*$/    :/'
      tooth watchdog-trap-no-jobs c_sig    's/kill \$(jobs -p) 2>\/dev\/null; exit 0/exit 0/'
      tooth handler-leaks-tmp    c_sig_probe 's/^    \[ -z "\${_GHV_TMPFILES:-}" \] || rm -f \$_GHV_TMPFILES.*$/    :/'
      tooth trap-not-restored    c_trap_restored 's/^      _ghv_restore_traps$/      :/'
      tooth group-flag-dropped   c_gc_run   's/grpflag=group/grpflag=""/g'
      tooth group-flag-dropped-p c_gc_probe 's/grpflag=group/grpflag=""/g'
      tooth no-setsid-launch     c_gc_run   's/grp=(setsid)/grp=()/g'
      tooth no-post-bound-sweep  c_gc_term  's/then _ghv_sweep "\$pid" "\$grpflag"; fi/then :; fi/'
      tooth degraded-note-lost   c_gc_mode  's/GHV_NOTE="DEGRADED: no setsid[^"]*"/GHV_NOTE=""/'
      tooth job-control-ignored  c_gc_mode  's/case "\$-" in \*m\*)/case "$-" in *NEVERM*)/'
    fi
    tooth timeout-124-map  c_slow_to 's/\[ "\$rc" = 124 \]/[ "$rc" = 999 ]/'
    tooth gtimeout-gone    c_slow_gt 's/gtimeout/gtimeoutX/g'
    tooth watchdog-143     c_slow_wd 's/\[ "\$rc" = 143 \] \&\& rc=124/:/'
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
