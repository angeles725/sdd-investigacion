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
# Usage: research-sdd-status-visibility.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
FX="$HERE/fixtures/status-visibility"
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
# status DIR [GHBIN] — run the report with a stubbed (or deliberately absent) gh.
status() { RSDD_GH_BIN="${2:-$TMP/no-such-gh}" bash "${SUT_UNDER_TEST:-$SUT}" "$1" 2>&1; }

# 1. no git, no remote -> no visibility line at all (byte-identical to a pre-check run)
d="$TMP/nogit"; mkstate "$d"
out="$(status "$d")"
if ! grep -qE 'public-remote|remote-visibility' <<<"$out"; then ok "1a no git repo -> no visibility output"; else no "1a no-git target leaked a visibility line"; fi
d="$TMP/gitnoremote"; mkstate "$d"; mkgit "$d"
out="$(status "$d")"
if ! grep -qE 'public-remote|remote-visibility' <<<"$out"; then ok "1b git repo with no remote -> no visibility output"; else no "1b no-remote target leaked a visibility line"; fi

# 2. byte-identical to the pre-check snapshot (frozen fixture, target path normalised)
snap="$(status "$TMP/nogit" | sed "s#$TMP/nogit#<TARGET>#g")"
if [ "$snap" = "$(cat "$FX/baseline-nogit.out")" ]; then ok "2 status output byte-identical to the pre-check snapshot fixture"
else no "2 status output drifted from the frozen snapshot"; diff <(printf '%s\n' "$snap") "$FX/baseline-nogit.out" | head -5; fi

# 3. PUBLIC -> typed WARN naming the remote; stdout (part of the report)
stub_gh "$TMP/g-pub" PUBLIC
d="$TMP/pub"; mkstate "$d"; mkgit "$d" origin=https://github.com/o/r.git
out="$(status "$d" "$TMP/g-pub/gh")"
if grep -qE '^WARN public-remote: origin ' <<<"$out"; then ok "3a PUBLIC remote -> WARN public-remote: origin"; else no "3a no WARN for a PUBLIC remote: $(grep -i remote <<<"$out")"; fi
if grep -q 'repo view' "$TMP/g-pub/gh.argv" && grep -q ' o/r ' "$TMP/g-pub/gh.argv" && grep -q 'visibility' "$TMP/g-pub/gh.argv"; then ok "3b gh called as 'repo view <owner/repo> --json visibility'"; else no "3b unexpected gh argv: $(cat "$TMP/g-pub/gh.argv" 2>/dev/null)"; fi

# 4. PRIVATE / INTERNAL -> silent
for v in PRIVATE INTERNAL; do
  stub_gh "$TMP/g-$v" "$v"; d="$TMP/$v"; mkstate "$d"; mkgit "$d" origin=https://github.com/o/r.git
  out="$(status "$d" "$TMP/g-$v/gh")"
  if ! grep -qE 'public-remote|remote-visibility' <<<"$out"; then ok "4 $v remote -> no output"; else no "4 $v remote produced output: $(grep -E 'public-remote|remote-visibility' <<<"$out")"; fi
done

# 5. degraded: gh absent / failing / unrecognised — never a silent pass
d="$TMP/absent"; mkstate "$d"; mkgit "$d" origin=https://github.com/o/r.git
out="$(status "$d")"
if grep -qE '^degraded: remote-visibility: gh .*origin' <<<"$out"; then ok "5a gh absent -> typed degraded naming the remote"; else no "5a gh absent was silent: $(grep -i remote <<<"$out")"; fi
stub_gh "$TMP/g-fail" fail
out="$(status "$d" "$TMP/g-fail/gh")"
if grep -qE '^degraded: remote-visibility: .*origin' <<<"$out" && ! grep -q 'public-remote' <<<"$out"; then ok "5b gh failing -> typed degraded (not WARN, not silent)"; else no "5b gh failure mishandled: $(grep -i remote <<<"$out")"; fi
stub_gh "$TMP/g-junk" "banana"
out="$(status "$d" "$TMP/g-junk/gh")"
if grep -qiE '^degraded: remote-visibility: .*banana.*origin' <<<"$out"; then ok "5c unrecognised answer -> typed degraded echoing it"; else no "5c junk answer mishandled: $(grep -i remote <<<"$out")"; fi
stub_gh "$TMP/g-empty" ""
out="$(status "$d" "$TMP/g-empty/gh")"
if grep -qE '^degraded: remote-visibility: .*origin' <<<"$out"; then ok "5d empty answer -> typed degraded"; else no "5d empty answer was silent"; fi

# 6. list edges: PUBLIC remote FIRST / MIDDLE / LAST / SINGLE among three remotes (stub answers per URL)
stub_multi() { # DIR URL-substring-that-is-PUBLIC
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\ncase "$*" in *%s*) echo PUBLIC;; *) echo PRIVATE;; esac\n' "$2" > "$1/gh"; chmod +x "$1/gh"
}
for pos in first middle last; do
  d="$TMP/edge-$pos"; mkstate "$d"
  case "$pos" in
    first)  mkgit "$d" a=https://github.com/o/PUB.git b=https://github.com/o/b.git c=https://github.com/o/c.git ;;
    middle) mkgit "$d" a=https://github.com/o/a.git b=https://github.com/o/PUB.git c=https://github.com/o/c.git ;;
    last)   mkgit "$d" a=https://github.com/o/a.git b=https://github.com/o/b.git c=https://github.com/o/PUB.git ;;
  esac
  stub_multi "$TMP/gm-$pos" PUB
  out="$(status "$d" "$TMP/gm-$pos/gh")"
  n="$(grep -c '^WARN public-remote:' <<<"$out")"
  want="$(case "$pos" in first) echo a;; middle) echo b;; last) echo c;; esac)"
  if [ "$n" = 1 ] && grep -qE "^WARN public-remote: $want " <<<"$out"; then ok "6 PUBLIC remote in $pos position -> exactly one WARN naming '$want'"
  else no "6 $pos position: count=$n out=[$(grep -i remote <<<"$out")]"; fi
done
d="$TMP/edge-single"; mkstate "$d"; mkgit "$d" only=https://github.com/o/PUB.git
out="$(status "$d" "$TMP/gm-first/gh")"
if grep -qE '^WARN public-remote: only ' <<<"$out"; then ok "6 single PUBLIC remote -> WARN"; else no "6 single remote missed"; fi

# 7. the report keeps its exit code (0) and the consistency footer with the WARN present
RSDD_GH_BIN="$TMP/g-pub/gh" bash "$SUT" "$TMP/pub" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "7a PUBLIC remote does not change the exit code (0)" || no "7a exit code $rc"
grep -q 'consistency (verify-state.sh)' <<<"$(status "$TMP/pub" "$TMP/g-pub/gh")" && ok "7b report footer intact" || no "7b footer missing"

# 8. read-only: the check never touches the target (no new files, remotes unchanged)
before="$(cd "$TMP/pub" && find . -type f -not -path './.git/*' | sort | xargs sha1sum)"; rem="$(git -C "$TMP/pub" remote -v)"
status "$TMP/pub" "$TMP/g-pub/gh" >/dev/null
after="$(cd "$TMP/pub" && find . -type f -not -path './.git/*' | sort | xargs sha1sum)"
[ "$before" = "$after" ] && [ "$rem" = "$(git -C "$TMP/pub" remote -v)" ] && ok "8 read-only: target files and remotes untouched" || no "8 the check mutated the target"

# 9. R1: only OWNER/REPO reaches gh's argv — never the URL, never embedded credentials (#1245 review)
cred_case() { # label url want-owner/repo
  local g="$TMP/g-cred-$1"; stub_gh "$g" PRIVATE; rm -f "$g/gh.argv"
  local dd="$TMP/cred-$1"; mkstate "$dd"; mkgit "$dd" origin="$2"
  status "$dd" "$g/gh" >/dev/null
  if [ "$(grep -c . "$g/gh.argv" 2>/dev/null)" = 1 ] && grep -qE "^repo view $3 --json" "$g/gh.argv" && ! grep -qE 'SECRETTOKEN|://|@' "$g/gh.argv"; then ok "9 $1 -> gh argv carries only $3"
  else no "9 $1: argv=[$(cat "$g/gh.argv" 2>/dev/null)]"; fi
}
cred_case https-userinfo 'https://user:SECRETTOKEN@github.com/o/r.git' o/r
cred_case https-token-only 'https://SECRETTOKEN@github.com/o/r' o/r
cred_case scp 'git@github.com:o/r.git' o/r
cred_case ssh-url 'ssh://git@github.com/o/r.git' o/r
cred_case trailing-slash 'https://github.com/o/r.git/' o/r
# not a GitHub owner/repo -> typed degraded, gh NEVER called with it
for spec in "local:/srv/git/x.git" "other-forge:https://user:SECRETTOKEN@gitlab.com/o/r.git" "dash:https://github.com/-evil/r.git"; do
  lbl="${spec%%:*}"; u="${spec#*:}"; g="$TMP/g-ng-$lbl"; stub_gh "$g" PUBLIC; rm -f "$g/gh.argv"
  dd="$TMP/ng-$lbl"; mkstate "$dd"; mkgit "$dd" origin="$u"
  out="$(status "$dd" "$g/gh")"
  if grep -qE '^degraded: remote-visibility: origin not a github owner/repo' <<<"$out" && [ ! -e "$g/gh.argv" ] && ! grep -q SECRETTOKEN <<<"$out"; then ok "9 $lbl -> degraded, gh not called"
  else no "9 $lbl: out=[$(grep -i remote <<<"$out")] argv=[$(cat "$g/gh.argv" 2>/dev/null)]"; fi
done

# 10. R2: an empty `git remote get-url` is a typed degraded line; gh never gets an empty argument
g="$TMP/g-empty-url"; stub_gh "$g" PUBLIC; rm -f "$g/gh.argv"
dd="$TMP/emptyurl"; mkstate "$dd"; mkgit "$dd" origin=https://github.com/o/r.git; git -C "$dd" config remote.origin.url ""
out="$(status "$dd" "$g/gh")"
if grep -qE '^degraded: remote-visibility: origin (url empty|not a github owner/repo)' <<<"$out" && [ ! -e "$g/gh.argv" ] && ! grep -q '^WARN public-remote' <<<"$out"; then ok "10 empty remote URL -> typed degraded, gh not called"
else no "10 empty url: out=[$(grep -i remote <<<"$out")] argv=[$(cat "$g/gh.argv" 2>/dev/null)]"; fi

# 11. R3/R4: the gh call is bounded and never prompts; a timeout is a typed degraded line
g="$TMP/g-slow"; mkdir -p "$g"
printf '#!/usr/bin/env bash\necho "$GH_PROMPT_DISABLED" > "%s/prompt.env"\nsleep 30\necho PRIVATE\n' "$g" > "$g/gh"; chmod +x "$g/gh"
dd="$TMP/slow"; mkstate "$dd"; mkgit "$dd" origin=https://github.com/o/r.git
t0=$SECONDS; out="$(RSDD_GH_TIMEOUT=1 status "$dd" "$g/gh")"; el=$((SECONDS-t0))
if [ "$el" -lt 15 ] && grep -qE '^degraded: remote-visibility: gh timed out for remote origin' <<<"$out"; then ok "11a hung gh -> bounded, typed degraded (timed out) in ${el}s"
else no "11a hung gh: ${el}s out=[$(grep -i remote <<<"$out")]"; fi
[ "$(cat "$g/prompt.env" 2>/dev/null)" = 1 ] && ok "11b gh runs with GH_PROMPT_DISABLED=1" || no "11b GH_PROMPT_DISABLED not set: [$(cat "$g/prompt.env" 2>/dev/null)]"

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

# 12. kit issue #1820 latency budget: N stalled remotes cost ONE bound (later remotes are skipped with a typed line),
#     and status keeps its historical 10 s default bound (the shared lib default is 20).
d2="$TMP/slow2"; mkstate "$d2"; mkgit "$d2" origin=https://github.com/o/r.git up=https://github.com/o/r2.git third=https://github.com/o/r3.git
# Deterministic (no clocks): a counting stalled gh records every invocation; three stalled remotes must cost exactly ONE probe.
gc="$TMP/g-count"; mkdir -p "$gc"
printf '#!/usr/bin/env bash\necho call >> "%s/calls.log"\nsleep 30\necho PRIVATE\n' "$gc" > "$gc/gh"; chmod +x "$gc/gh"
: > "$gc/calls.log"; out="$(RSDD_GH_TIMEOUT=1 status "$d2" "$gc/gh")"; ncalls="$(grep -c . "$gc/calls.log")"
nto="$(grep -c '^degraded: remote-visibility: gh timed out' <<<"$out")"; nsk="$(grep -c '^degraded: remote-visibility: skipped after timeout for remote' <<<"$out")"
if [ "$ncalls" = 1 ] && [ "$nto" = 1 ] && [ "$nsk" = 2 ]; then ok "12a three stalled remotes -> exactly one gh probe, one timeout line, two skip lines"
else no "12a latency budget: gh calls=$ncalls timeouts=$nto skips=$nsk out=[$(grep -i remote <<<"$out")]"; fi
if [ -n "$REAL_TO" ]; then
  hp="$(mkpath "$TMP/path-to10" none)"
  printf '#!%s\necho "$1" >> "%s/timeout.log"\nexec "%s" "$@"\n' "$(command -v bash)" "$hp" "$REAL_TO" > "$hp/timeout"; chmod +x "$hp/timeout"
  out="$(env -u RSDD_GH_TIMEOUT PATH="$hp" RSDD_GH_BIN="$TMP/g-pub/gh" bash "$SUT" "$TMP/pub" 2>&1)"
  if [ "$(head -1 "$hp/timeout.log" 2>/dev/null)" = 10 ]; then ok "12b status default bound is 10s (RSDD_GH_TIMEOUT unset)"
  else no "12b status default bound: timeout got '$(head -1 "$hp/timeout.log" 2>/dev/null)' (want 10)"; fi
fi

# 13. kit issue #1843: the lib check happens AFTER the remotes are enumerated. A kit copy WITHOUT lib/gh-visibility.sh
#     (nolib tree) must stay silent for a target with no remote (nothing to probe) and must still print the typed
#     degraded line for a target that HAS a remote (the probe could not run - never a silent pass).
NOLIB="$TMP/nolib"; mkdir -p "$NOLIB"; cp -r "$HERE/../lib" "$NOLIB/lib"; cp "$HERE"/../*.sh "$NOLIB/"; rm -f "$NOLIB/lib/gh-visibility.sh"
status_nolib() { RSDD_GH_BIN="$TMP/g-pub/gh" bash "$NOLIB/research-sdd-status.sh" "$1" 2>&1; }
out="$(status_nolib "$TMP/gitnoremote")"
if ! grep -qE 'public-remote|remote-visibility|reason codes' <<<"$out"; then ok "13a missing lib + repo with NO remote -> silent (no degraded line, no reason-codes footer)"
else no "13a no-remote target printed a lib-missing line: $(grep -iE 'remote|reason' <<<"$out")"; fi
out="$(status_nolib "$TMP/nogit")"
if ! grep -qE 'public-remote|remote-visibility' <<<"$out"; then ok "13b missing lib + no .git -> silent"; else no "13b no-git target printed a visibility line"; fi
out="$(status_nolib "$TMP/pub")"
if grep -qE '^degraded: remote-visibility: lib/gh-visibility.sh unavailable' <<<"$out" && grep -q 'reason codes' <<<"$out"; then ok "13c missing lib + a remote -> typed degraded line + reason-codes footer"
else no "13c missing lib with a remote was silent: $(grep -iE 'remote|reason' <<<"$out")"; fi
out="$(RSDD_GH_BIN="$TMP/g-pub/gh" bash "$SUT" "$TMP/gitnoremote" 2>&1)"
if ! grep -qE 'public-remote|remote-visibility' <<<"$out"; then ok "13d lib present + no remote -> still silent (control)"; else no "13d control printed a visibility line"; fi

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the remote-visibility check --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TB="$HERE/.."
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # tooth NAME SEDEXPR WANT-DESC CHECK-FN: build mutant tree, run, apply check
  tooth() {
    local name="$1" expr="$2" t
    t="$(mk_tree "$name")"
    if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" "$expr" >/dev/null 2>&1; then SUT_UNDER_TEST="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $name: mutant could not be built (pattern absent / refused by lib/mutant.sh)"; return 1
  }
  # toothlib NAME SEDEXPR: like tooth, but the mutation targets lib/gh-visibility.sh (kit issue #1820: the probe lives there)
  toothlib() {
    local name="$1" expr="$2" t
    t="$(mk_tree "$name")"
    if mutant_sed "$TB/lib/gh-visibility.sh" "$t/lib/gh-visibility.sh" "$expr" >/dev/null 2>&1; then SUT_UNDER_TEST="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $name: lib mutant could not be built (pattern absent / refused by lib/mutant.sh)"; return 1
  }
  # A: PUBLIC comparison neutered -> a PUBLIC remote false-passes
  if tooth A 's/PUBLIC) echo "WARN/NEVER-MATCHES) echo "WARN/'; then
    out="$(status "$TMP/pub" "$TMP/g-pub/gh")"
    grep -q '^WARN public-remote:' <<<"$out" && no "teeth A: mutant still WARNs — THEATER" || ok "teeth A: PUBLIC test neutered -> case 3a has teeth"; fi
  # B: PRIVATE treated as PUBLIC -> private remote false-flags
  if tooth B 's/PUBLIC) echo "WARN/PRIVATE) echo "WARN/'; then
    out="$(status "$TMP/PRIVATE" "$TMP/g-PRIVATE/gh")"
    grep -q '^WARN public-remote:' <<<"$out" && ok "teeth B: private-as-public -> case 4 has teeth" || no "teeth B: mutant stayed quiet — THEATER"; fi
  # C: gh-failure degraded branch silenced
  if tooth C 's/degraded: remote-visibility: gh failed/DEG-OFF/'; then
    # The mutant must exit 0 and print the intact report WITHOUT the degraded line (the exact wrong verdict); a crash
    # or empty output is not a bite. The real SUT must differ on the same fixture (it prints the degraded line).
    out="$(status "$TMP/absent" "$TMP/g-fail/gh")"; rc=$?
    real="$(SUT_UNDER_TEST=""; status "$TMP/absent" "$TMP/g-fail/gh")"
    if ! { grep -q '^degraded: remote-visibility: gh failed' <<<"$real" && [ "$real" != "$out" ]; }; then no "teeth C: real SUT and mutant agree on the fixture - vacuous"
    elif [ "$rc" = 0 ] && grep -q 'consistency (verify-state.sh)' <<<"$out" && ! grep -q '^degraded: remote-visibility' <<<"$out"; then ok "teeth C: failure branch silenced -> exit 0, intact report, no degraded line -> case 5b has teeth"
    else no "teeth C: want exit 0 + intact report without the degraded line, got rc=$rc — THEATER or crashed mutant"; fi; fi
  # D: gh-absent degraded branch silenced
  if tooth D 's/degraded: remote-visibility: gh not found/DEG-OFF/'; then
    out="$(status "$TMP/absent")"
    grep -q '^degraded: remote-visibility' <<<"$out" && no "teeth D: mutant still degraded — THEATER" || ok "teeth D: absent branch silenced -> case 5a has teeth"; fi
  # E: unrecognised-answer branch silenced
  if tooth E 's/degraded: remote-visibility: unrecognised/DEG-OFF/'; then
    out="$(status "$TMP/absent" "$TMP/g-junk/gh")"
    grep -q '^degraded: remote-visibility' <<<"$out" && no "teeth E: mutant still degraded — THEATER" || ok "teeth E: unrecognised branch silenced -> case 5c has teeth"; fi
  # F: loop stops after the first remote -> the LAST-position PUBLIC remote is missed
  if tooth F 's/"${_rv_arr\[@\]}"/"${_rv_arr[0]}"/'; then
    out="$(status "$TMP/edge-last" "$TMP/gm-last/gh")"
    grep -q '^WARN public-remote:' <<<"$out" && no "teeth F: first-only mutant still sees the last remote — THEATER" || ok "teeth F: loop truncated -> list-edge case 6 has teeth"; fi
  # G: the URL (with credentials) goes to gh again instead of owner/repo
  if tooth G 's/gh_visibility_probe "\$_rv_gh" "\$_rv_slug"/gh_visibility_probe "$_rv_gh" "$_rv_url"/'; then
    stub_gh "$TMP/g-tG" PRIVATE; rm -f "$TMP/g-tG/gh.argv"; mkstate "$TMP/tG"; mkgit "$TMP/tG" origin='https://user:SECRETTOKEN@github.com/o/r.git'
    status "$TMP/tG" "$TMP/g-tG/gh" >/dev/null
    grep -q SECRETTOKEN "$TMP/g-tG/gh.argv" && ok "teeth G: URL to gh -> credential case 9 has teeth" || no "teeth G: mutant stayed clean — THEATER"; fi
  # H: the 'not a github owner/repo' message text is rewritten (guard stays) -> case 9's degraded-line assertion goes red
  if tooth H 's/not a github owner\/repo/DEG-OFF/'; then
    out="$(status "$TMP/ng-local" "$TMP/g-ng-local/gh")"
    grep -q 'not a github owner/repo' <<<"$out" && no "teeth H: mutant still degraded — THEATER" || ok "teeth H: not-github branch silenced -> case 9 has teeth"; fi
  # I: timeout bound removed -> the hung gh is not converted to degraded. The stub stalls for STALL_S seconds (well above the
  # 1 s bound); wall time is judged in MILLISECONDS (whole-second SECONDS flaked, kit issue #1853), with the ceiling
  # derived from the stall: CEIL_MS = STALL_S*1000 - 500 on a hi-res clock, - 1000 on the coarse fallback. The control
  # first proves the UNMUTATED script returns below CEIL_MS with the 'timed out' line; the mutant must then run the
  # full stall (>= CEIL_MS) and lose that line.
  # Clock: probe once. Sub-second epoch ms from GNU date %N, else python3, else perl; only when none exists (or the
  # test forces it with clkmode=coarse) fall back to whole-second $SECONDS, where the ceiling is widened by one second
  # so the tooth stays valid (control < stall-1 s; the mutant ran the full stall, so its whole-second diff is
  # >= stall-1 s). Never a silent pass: the PASS line names the clock used.
  pick_clock() { # auto|coarse -> sets CLK and CEIL_MS
    CLK=coarse
    if [ "$1" != coarse ]; then
      nsec="$(date +%N 2>/dev/null)"; case "$nsec" in *[!0-9]*|'') ;; *) CLK=gnu-date ;; esac
      # a candidate counts only if ONE real now_ms call prints digits (an installed-but-broken python3/perl falls through)
      if [ "$CLK" = coarse ] && command -v python3 >/dev/null 2>&1; then CLK=py3; probe="$(now_ms 2>/dev/null)"; case "$probe" in ''|*[!0-9]*) CLK=coarse ;; esac; fi
      if [ "$CLK" = coarse ] && command -v perl >/dev/null 2>&1; then CLK=perl5; probe="$(now_ms 2>/dev/null)"; case "$probe" in ''|*[!0-9]*) CLK=coarse ;; esac; fi
    fi
    if [ "$CLK" = coarse ]; then CEIL_MS=$((STALL_S*1000 - 1000)); else CEIL_MS=$((STALL_S*1000 - 500)); fi
  }
  now_ms() {
    case "$CLK" in
      gnu-date) echo $(( 10#$(date +%s%N) / 1000000 )) ;;
      py3) python3 -c 'import time;print(int(time.time()*1000))' ;;
      perl5) perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' ;;
      *) echo $((SECONDS*1000)) ;;
    esac; }
  STALL_S=6
  g="$TMP/g-slow4"; mkdir -p "$g"; printf '#!/usr/bin/env bash\nsleep %s\necho PRIVATE\n' "$STALL_S" > "$g/gh"; chmod +x "$g/gh"
  # the second pass FORCES the coarse fallback so that path is exercised on every machine
  for clkmode in auto coarse; do
    pick_clock "$clkmode"
    SUT_UNDER_TEST=""; t0=$(now_ms); base="$(RSDD_GH_TIMEOUT=1 status "$TMP/slow" "$g/gh")"; elb=$(( $(now_ms) - t0 ))
    if ! { [ "$elb" -lt "$CEIL_MS" ] && grep -q 'timed out' <<<"$base"; }; then no "teeth I [$CLK clock, mode=$clkmode]: unmutated script did not pass the timeout case (${elb}ms, ceiling ${CEIL_MS}ms) — control invalid"
    elif toothlib I 's/cmd=("\$bounder" "\$t" "\${cmd\[@\]}")/:/'; then
      t0=$(now_ms); out="$(RSDD_GH_TIMEOUT=1 status "$TMP/slow" "$g/gh")"; el=$(( $(now_ms) - t0 ))
      if [ "$el" -ge "$CEIL_MS" ] && ! grep -q 'timed out' <<<"$out"; then ok "teeth I [$CLK clock, mode=$clkmode]: unbounded gh ran ${el}ms (>= ${CEIL_MS}ms), no 'timed out' -> case 11a has teeth"
      else no "teeth I [$CLK clock, mode=$clkmode]: mutant still bounded (${el}ms) — THEATER"; fi; fi
  done
  # J: GH_PROMPT_DISABLED dropped
  if toothlib J 's/GH_PROMPT_DISABLED=1 //g'; then
    rm -f "$TMP/g-slow/prompt.env"; RSDD_GH_TIMEOUT=1 status "$TMP/slow" "$TMP/g-slow/gh" >/dev/null
    [ "$(cat "$TMP/g-slow/prompt.env" 2>/dev/null)" = 1 ] && no "teeth J: mutant still sets it — THEATER" || ok "teeth J: prompt guard dropped -> case 11b has teeth"; fi
  # K: the 'url empty' message text is rewritten (guard and its continue stay) -> case 10's degraded-line assertion goes red
  if tooth K 's/url empty/DEG-OFF/'; then
    out="$(status "$TMP/emptyurl" "$TMP/g-empty-url/gh")"
    grep -qE 'url empty' <<<"$out" && no "teeth K: mutant still degraded — THEATER" || ok "teeth K: empty-url branch silenced -> case 10 has teeth"; fi
  # L: the watchdog's SIGTERM->124 normalisation removed -> a stalled gh with no timeout binary is a generic failure -> case 11d goes red
  if [ -n "$REAL_TO" ] && toothlib L 's/\[ "\$rc" = 143 \] \&\& rc=124/:/'; then
    out="$(PATH="$TMP/path-none" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT_UNDER_TEST" "$TMP/slow" 2>&1)"
    grep -q 'gh timed out' <<<"$out" && no "teeth L: mutant still reports a timeout — THEATER" || ok "teeth L: watchdog normalisation removed -> case 11d has teeth"; fi
  # M: gtimeout fallback removed -> the recording wrapper is never used -> case 11c goes red
  if [ -n "$REAL_TO" ] && toothlib M 's/gtimeout/gtimeout-REMOVED/g'; then
    rm -f "$TMP/path-gt/gtimeout.log"
    PATH="$TMP/path-gt" RSDD_GH_TIMEOUT=1 RSDD_GH_BIN="$TMP/g-slow/gh" bash "$SUT_UNDER_TEST" "$TMP/slow" >/dev/null 2>&1
    [ -s "$TMP/path-gt/gtimeout.log" ] && no "teeth M: mutant still used gtimeout — THEATER" || ok "teeth M: gtimeout fallback removed -> case 11c has teeth"; fi
  # N: skip-after-timeout removed -> every stalled remote waits its own bound -> case 12a goes red
  if tooth N 's/if \[ "\$_rv_stalled" = 1 \]; then/if false; then/'; then
    : > "$gc/calls.log"; out="$(RSDD_GH_TIMEOUT=1 status "$d2" "$gc/gh")"; ncalls="$(grep -c . "$gc/calls.log")"
    if [ "$ncalls" = 3 ] && [ "$(grep -c 'skipped after timeout' <<<"$out")" = 0 ]; then ok "teeth N: no skip -> 3 gh probes for 3 stalled remotes -> case 12a has teeth"
    else no "teeth N: mutant still skipped (gh calls=$ncalls) — THEATER"; fi; fi
  # O: status's own 10s default dropped (lib default 20 leaks through) -> case 12b goes red
  if [ -n "$REAL_TO" ] && tooth O 's/GHV_DEFAULT_BOUND=10 //'; then
    rm -f "$hp/timeout.log"; env -u RSDD_GH_TIMEOUT PATH="$hp" RSDD_GH_BIN="$TMP/g-pub/gh" bash "$SUT_UNDER_TEST" "$TMP/pub" >/dev/null 2>&1
    [ "$(head -1 "$hp/timeout.log" 2>/dev/null)" = 20 ] && ok "teeth O: default 10 dropped -> bound 20 -> case 12b has teeth" || no "teeth O: mutant still passes 10 — THEATER"; fi
  # nolib_tree NAME: copy of mutant tree NAME with lib/gh-visibility.sh removed (prints the dir)
  nolib_tree() { local n="$MT/$1-nolib"; rm -rf "$n"; mkdir -p "$n"; cp -r "$MT/$1/lib" "$n/lib"; cp "$MT/$1"/*.sh "$n/"; rm -f "$n/lib/gh-visibility.sh"; printf '%s' "$n"; }
  # P: remote-enumeration gate removed -> the lib check fires for a no-remote target again -> case 13a goes red
  if tooth P 's/\[ "\${#_rv_arr\[@\]}" -gt 0 \] || return 0/:/'; then
    out="$(RSDD_GH_BIN="$TMP/g-pub/gh" bash "$(nolib_tree P)/research-sdd-status.sh" "$TMP/gitnoremote" 2>&1)"
    grep -q '^degraded: remote-visibility' <<<"$out" && ok "teeth P: enumeration gate removed -> no-remote target degraded -> case 13a has teeth" || no "teeth P: mutant stayed silent — THEATER"; fi
  # Q: the lib-missing degraded echo silenced -> a target WITH a remote passes silently -> case 13c goes red
  if tooth Q 's/echo "degraded: remote-visibility: lib\/gh-visibility.sh unavailable/: "degraded: remote-visibility: lib\/gh-visibility.sh unavailable/'; then
    # Exact wrong verdict: exit 0, intact report, no degraded line. Real SUT without the lib prints the degraded line.
    out="$(RSDD_GH_BIN="$TMP/g-pub/gh" bash "$(nolib_tree Q)/research-sdd-status.sh" "$TMP/pub" 2>&1)"; rc=$?
    real="$(status_nolib "$TMP/pub")"
    if ! { grep -q '^degraded: remote-visibility: lib/gh-visibility.sh unavailable' <<<"$real" && [ "$real" != "$out" ]; }; then no "teeth Q: real SUT and mutant agree on the fixture - vacuous"
    elif [ "$rc" = 0 ] && grep -q 'consistency (verify-state.sh)' <<<"$out" && ! grep -q '^degraded: remote-visibility' <<<"$out"; then ok "teeth Q: lib-missing line silenced -> exit 0, intact report, no degraded line -> case 13c has teeth"
    else no "teeth Q: want exit 0 + intact report without the degraded line, got rc=$rc — THEATER or crashed mutant"; fi; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
