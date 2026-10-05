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
  case "$mode" in *-nogh) ;; *)
    {
      printf '#!%s\n' "$BASH_BIN"
      printf 'echo "PROMPT=${GH_PROMPT_DISABLED-UNSET} REPO=${GH_REPO-UNSET} ARGS=$* PWD=$PWD" >> "%s/gh.log"\n' "$b"
      cat <<'EOF'
[ -n "${GH_ERR:-}" ] && echo "$GH_ERR" >&2
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

# ------------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null || { echo "FATAL: lib/mutant.sh lacks mutant_chain" >&2; exit 2; }
  # tooth LABEL CASEFN SED_EXPR [needs-timeout] — build a mutant of the lib, require the case to FAIL on it.
  tooth() {
    local label="$1" fn="$2" expr="$3" m="$TMP/mut-$1.sh" extra=("${@:4}")
    if ! mutant_chain "teeth $label" "$LIB" "$m" "$expr"; then fail=$((fail+1)); return; fi
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
  if [ -n "$REAL_TO" ]; then
    tooth timeout-124-map  c_slow_to 's/\[ "\$rc" = 124 \]/[ "$rc" = 999 ]/'
    tooth gtimeout-gone    c_slow_gt 's/gtimeout/gtimeoutX/g'
    tooth watchdog-143     c_slow_wd 's/\[ "\$rc" = 143 \] \&\& rc=124/:/'
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
