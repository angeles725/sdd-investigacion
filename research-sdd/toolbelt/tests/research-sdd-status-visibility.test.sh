#!/usr/bin/env bash
# research-sdd-status-visibility.test.sh — remote-visibility drift check in research-sdd-status.sh
# (kit issue #1245).
#
# ensure-remote.sh verifies PRIVATE only at creation. The status report now READS BACK each git remote's
# visibility (gh repo view --json visibility) and emits a typed `WARN public-remote: <remote>` when it is
# PUBLIC, a typed `degraded: remote-visibility: ...` line when the read-back could not run (gh absent /
# failing / unrecognised answer — never a silent pass), and NOTHING for a PRIVATE remote or for a target
# with no git remote (output byte-identical to a pre-check run: snapshot fixture below).
#
# gh is STUBBED through RSDD_GH_BIN — no network, no ambient gh.
# The report side (PUBLIC/PRIVATE/degraded, argv, credentials, bounds) is pinned by the v-* scenarios of `rsdd status show`; this suite keeps
# the lib/gh-visibility.sh timeout-binary ladder (11c, 11d). Usage: research-sdd-status-visibility.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-visibility.test.sh =="

# mkstate DIR — a minimal valid corpus (research-state.v1 envelope, one pending gap).
mkstate() {
  mkdir -p "$1"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| high | the gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 1"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$1/RESEARCH-STATE.md"
}
# mkgit DIR remote=url ... — git-init the corpus and add remotes (no network: URLs are never contacted).
mkgit() {
  local d="$1"; shift
  git init -q "$d" >/dev/null 2>&1
  local kv; for kv in "$@"; do git -C "$d" remote add "${kv%%=*}" "${kv#*=}"; done
}
# stub_gh DIR BEHAVIOUR — writes DIR/gh. BEHAVIOUR: a literal answer line, or `fail` (exit 1), or `junk`.
stub_gh() {
  mkdir -p "$1"
  case "$2" in
    fail) printf '#!/usr/bin/env bash\necho "gh: not logged in" >&2\nexit 1\n' > "$1/gh" ;;
    *)    printf '#!/usr/bin/env bash\n# argv recorded for the call-shape case\nprintf "%%s\\n" "$*" >> "%s/gh.argv"\necho "%s"\n' "$1" "$2" > "$1/gh" ;;
  esac
  chmod +x "$1/gh"
}

stub_gh "$TMP/g-pub" PUBLIC
d="$TMP/pub"; mkstate "$d"; mkgit "$d" origin=https://github.com/o/r.git
g="$TMP/g-slow"; mkdir -p "$g"
printf '#!/usr/bin/env bash\necho "$GH_PROMPT_DISABLED" > "%s/prompt.env"\nsleep 30\necho PRIVATE\n' "$g" > "$g/gh"; chmod +x "$g/gh"
dd="$TMP/slow"; mkstate "$dd"; mkgit "$dd" origin=https://github.com/o/r.git

# 11c/11d: timeout binary fallbacks under a hermetic PATH: a stub dir holding symlinks to ONLY the tools the
# report needs (never timeout/gtimeout); gtimeout is added back as a symlink to the real timeout where wanted.
REAL_TO="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
mkpath() { # DIR with-gtimeout|none — prints DIR
  local pd="$1" t p; rm -rf "$pd"; mkdir -p "$pd"
  for t in bash env git grep sed awk cat cut tr sort uniq head tail wc date find xargs ls mkdir rm mktemp dirname \
           basename sha1sum sha256sum stat sleep readlink realpath mv cp diff expr id uname tee comm printf jq python3 gh; do
    p="$(command -v "$t" 2>/dev/null)" && [ -f "$p" ] && ln -sf "$p" "$pd/$t"; done
  # gtimeout is a RECORDING wrapper (kit issue #1820: the shared probe falls back to a bash watchdog, so a bound alone
  # no longer proves the gtimeout binary was used) — case 11c asserts the wrapper really ran.
  if [ "$2" = with-gtimeout ]; then printf '#!%s\necho used >> "%s/gtimeout.log"\nexec "%s" "$@"\n' "$(command -v bash)" "$pd" "$REAL_TO" > "$pd/gtimeout"; chmod +x "$pd/gtimeout"; fi
  printf '%s' "$pd"
}
if [ -z "$REAL_TO" ]; then no "11c/11d need a real timeout binary to build the hermetic PATH"; else
  hp="$(mkpath "$TMP/path-gt" with-gtimeout)"
  t0=$SECONDS; out="$(PATH="$hp" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT" "$TMP/slow" 2>&1)"; el=$((SECONDS-t0))
  if [ "$el" -lt 15 ] && grep -qE '^degraded: remote-visibility: gh timed out for remote origin' <<<"$out" && [ -s "$hp/gtimeout.log" ]; then ok "11c timeout absent, gtimeout present -> bounded THROUGH gtimeout (timed out in ${el}s)"
  else no "11c gtimeout fallback: ${el}s out=[$(grep -i remote <<<"$out")]"; fi
  hp="$(mkpath "$TMP/path-none" none)"
  # 11d (kit issue #1820): neither timeout nor gtimeout is no longer a degraded state — the shared probe is bounded by a
  # bash watchdog instead: a stalled gh is still the typed 'timed out' line, and a PUBLIC answer is still decided.
  t0=$SECONDS; out="$(PATH="$hp" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT" "$TMP/slow" 2>&1)"; el=$((SECONDS-t0))
  outp="$(PATH="$hp" RSDD_GH_BIN="$TMP/g-pub/gh" bash "$SUT" "$TMP/pub" 2>&1)"
  if [ "$el" -lt 15 ] && grep -qE '^degraded: remote-visibility: gh timed out for remote origin' <<<"$out" && grep -q '^WARN public-remote' <<<"$outp"; then ok "11d neither timeout nor gtimeout -> still bounded (watchdog, ${el}s), PUBLIC still decided"
  else no "11d no-timeout branch: ${el}s out=[$(grep -i remote <<<"$out")] pub=[$(grep -i remote <<<"$outp")]"; fi
fi

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the remote-visibility check --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TB="$HERE/.."
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # toothlib NAME SEDEXPR: like tooth, but the mutation targets lib/gh-visibility.sh (kit issue #1820: the probe lives there)
  toothlib() {
    local name="$1" expr="$2" t
    t="$(mk_tree "$name")"
    if mutant_sed "$TB/lib/gh-visibility.sh" "$t/lib/gh-visibility.sh" "$expr" >/dev/null 2>&1; then SUT_UNDER_TEST="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $name: lib mutant could not be built (pattern absent / refused by lib/mutant.sh)"; return 1
  }
  # L: the watchdog's SIGTERM->124 normalisation removed -> a stalled gh with no timeout binary is a generic failure -> case 11d goes red
  if [ -n "$REAL_TO" ] && toothlib L 's/\[ "\$rc" = 143 \] \&\& rc=124/:/'; then
    out="$(PATH="$TMP/path-none" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT_UNDER_TEST" "$TMP/slow" 2>&1)"
    grep -q 'gh timed out' <<<"$out" && no "teeth L: mutant still reports a timeout — THEATER" || ok "teeth L: watchdog normalisation removed -> case 11d has teeth"; fi
  # M: gtimeout fallback removed -> the recording wrapper is never used -> case 11c goes red
  if [ -n "$REAL_TO" ] && toothlib M 's/gtimeout/gtimeout-REMOVED/g'; then
    rm -f "$TMP/path-gt/gtimeout.log"
    PATH="$TMP/path-gt" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT_UNDER_TEST" "$TMP/slow" >/dev/null 2>&1
    [ -s "$TMP/path-gt/gtimeout.log" ] && no "teeth M: mutant still used gtimeout — THEATER" || ok "teeth M: gtimeout fallback removed -> case 11c has teeth"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
