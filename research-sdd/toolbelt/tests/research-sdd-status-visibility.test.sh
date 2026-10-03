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
if grep -q 'repo view' "$TMP/g-pub/gh.argv" && grep -q 'https://github.com/o/r.git' "$TMP/g-pub/gh.argv" && grep -q 'visibility' "$TMP/g-pub/gh.argv"; then ok "3b gh called as 'repo view <url> --json visibility'"; else no "3b unexpected gh argv: $(cat "$TMP/g-pub/gh.argv" 2>/dev/null)"; fi

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
if grep -qE '^degraded: remote-visibility: .*banana.*origin' <<<"$out"; then ok "5c unrecognised answer -> typed degraded echoing it"; else no "5c junk answer mishandled: $(grep -i remote <<<"$out")"; fi
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
    out="$(status "$TMP/absent" "$TMP/g-fail/gh")"
    grep -q '^degraded: remote-visibility' <<<"$out" && no "teeth C: mutant still degraded — THEATER" || ok "teeth C: failure branch silenced -> case 5b has teeth"; fi
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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
