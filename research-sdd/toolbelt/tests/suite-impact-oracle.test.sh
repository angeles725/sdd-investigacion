#!/usr/bin/env bash
# suite-impact-oracle.test.sh — suite for suite-impact-oracle.sh (kit issue #2201). The oracle breaks a production file in a
# temp copy and reports the suites that fail with the break but were NOT selected by the impact map. Here the whole
# chain runs against a fixture repo whose suites include one that reaches the file by a run-time-assembled name (the
# map cannot see it: a REAL miss), one that already fails without the mutation, and one that times out.
#
# Usage: suite-impact-oracle.test.sh                (run the suite)
#        suite-impact-oracle.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 every assertion held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${SUITE_IMPACT_ORACLE_SUT:-$HERE/suite-impact-oracle.sh}"
INSTRUMENT="$HERE/suite-impact.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$INSTRUMENT" ] || { echo "FATAL: instrument not found: $INSTRUMENT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
for t in git python3 timeout; do command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t not on PATH" >&2; exit 2; }; done

TMP="$(mktemp -d)"; MUT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain_or_count fail "$l" "$SUT" "$o" "$@" || return 1; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset SUITE_IMPACT_WIDE_THRESHOLD

TS=research-sdd/toolbelt/tests
T=research-sdd/toolbelt
# fixture manifests are passed with --manifest-dir; the real instrument is used
KIT="$TMP/kit"; mkdir -p "$KIT"
printf '# f\nindep always\n' > "$KIT/impact-always.txt"
printf '# f\n' > "$KIT/impact-blindspot.txt"
export SUITE_IMPACT_SUT="$INSTRUMENT"

OUT=""; ERR=""; RC=0
run() { OUT="$("$BASH_BIN" "$SUT" --manifest-dir "$KIT" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
has() { grep -qF -- "$1" <<<"$OUT"; }
ehas() { grep -qF -- "$1" <<<"$ERR"; }

R="$TMP/repo"; mkdir -p "$R/$TS"
hdr='HERE="$(cd "$(dirname "$0")" && pwd)"'
printf '%s\nbash "$HERE/../alpha.sh" || exit 1\n' "$hdr" > "$R/$TS/a.test.sh"
printf '%s\nbash "$HERE/../al""pha.sh" || exit 1\n' "$hdr" > "$R/$TS/hidden.test.sh"
printf 'exit 0\n' > "$R/$TS/indep.test.sh"
printf 'exit 1\n' > "$R/$TS/preexist.test.sh"
printf 'sleep 8\nexit 0\n' > "$R/$TS/slow.test.sh"
printf '%s\npython3 "$HERE/../ga""m.py" || exit 1\n' "$hdr" > "$R/$TS/hiddenpy.test.sh"
printf '%s\npython3 "$HERE/../gam.py" || exit 1\n' "$hdr" > "$R/$TS/seepy.test.sh"
printf '#!/usr/bin/env bash\necho alpha\n' > "$R/$T/alpha.sh"
printf '#!/usr/bin/env python3\nprint(1)\n' > "$R/$T/gam.py"
printf 'echo nobody tests me\n' > "$R/$T/solo.sh"
( cd "$R" && git init -q -b main . && git add -A && git commit -q -m base ) || { echo "FATAL: fixture" >&2; exit 2; }

echo "== suite-impact-oracle.test.sh (SUT: $(basename "$SUT")) =="

# ---- usage / degraded ----------------------------------------------------------------------------------------------
run; { [ "$RC" = 2 ] && ehas usage; } && ok "no --file -> usage, exit 2" || no "no --file" "(rc=$RC $ERR)"
run --file x.txt --repo "$R"; { [ "$RC" = 2 ] && ehas 'unsupported file type'; } && ok "unsupported extension -> exit 2" || no "extension" "(rc=$RC $ERR)"
run --file ../x.sh --repo "$R"; { [ "$RC" = 2 ] && ehas 'repo-relative'; } && ok "'..' path -> exit 2" || no "dotdot" "(rc=$RC $ERR)"
run --file /etc/x.sh --repo "$R"; { [ "$RC" = 2 ] && ehas 'repo-relative'; } && ok "absolute path -> exit 2" || no "absolute" "(rc=$RC $ERR)"
run --file $T/nope.sh --repo "$R"; { [ "$RC" = 2 ] && ehas 'degraded: suite-impact-oracle: research-sdd/toolbelt/nope.sh does not exist at HEAD'; } && ok "absent file -> typed degraded, exit 2" || no "absent file" "(rc=$RC $ERR)"
run --file $T/alpha.sh --repo "$R" --ref nosuchref; { [ "$RC" = 2 ] && ehas 'bad ref: nosuchref'; } && ok "bad --ref -> typed degraded, exit 2" || no "bad ref" "(rc=$RC $ERR)"
run --file $T/alpha.sh --repo "$R" --jobs 0; { [ "$RC" = 2 ] && ehas usage; } && ok "--jobs 0 -> exit 2" || no "jobs 0" "(rc=$RC $ERR)"
mkdir -p "$TMP/norepo"; run --file $T/alpha.sh --repo "$TMP/norepo"; { [ "$RC" = 2 ] && ehas 'not a git repository'; } && ok "not a repo -> typed degraded, exit 2" || no "not a repo" "(rc=$RC $ERR)"

# ---- the oracle itself -------------------------------------------------------------------------------------------------
run --file $T/alpha.sh --repo "$R" --timeout 2
EXP='ORACLE file=research-sdd/toolbelt/alpha.sh selected=2 unselected=5 failed-under-mutation=2 baseline-failing=1 timed-out=1 misses=[hidden.test.sh]'
{ [ "$RC" = 1 ] && has "$EXP"; } && ok "a suite that reaches the file by a run-time name is a REAL MISS (exit 1); the selected one is not" || no "alpha oracle" "(rc=$RC $OUT)"
has 'pre-existing failures (fail without the mutation too): preexist.test.sh' && ok "a suite failing without the mutation is reported as pre-existing, not a miss" || no "pre-existing" "($OUT)"
has 'inconclusive (timeout 2s): slow.test.sh' && ok "a suite that times out is inconclusive, never a pass or a miss" || no "timeout" "($OUT)"
run --file $T/gam.py --repo "$R" --timeout 2
{ [ "$RC" = 1 ] && has 'misses=[hiddenpy.test.sh]' && has 'selected=2 unselected=5'; } && ok "python file: the .py mutation breaks the hidden python suite (REAL MISS)" || no "python oracle" "(rc=$RC $OUT)"
run --file $T/solo.sh --repo "$R" --timeout 2
{ [ "$RC" = 0 ] && has 'escalated: no suite reaches the changed file' && has 'nothing to check'; } && ok "an escalated selection says so and exits 0 (every suite is selected)" || no "escalated" "(rc=$RC $OUT)"
run --file $T/alpha.sh --repo "$R" --timeout 2 --keep
{ has 'kept: '; } && ok "--keep prints the kept directory" || no "--keep" "($OUT)"
KD="$(sed -n 's/^kept: //p' <<<"$OUT")"; [ -n "$KD" ] && rm -rf -- "$KD"
[ "$(git -C "$R" status --short | grep -c .)" = 0 ] && ok "the live repo is never written (clean status after the run)" || no "live repo dirty" "($(git -C "$R" status --short))"

# =================================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  mt() {   # mt LABEL GOOD-RC BAD-RC SED-EXPR [tooth flags...] -- ARGV...
    local label="$1" grc="$2" brc="$3" expr="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  mt "mutation is a no-op" 1 0 "s/BREAK='exit 97'/BREAK=':'/" \
    --good-has 'misses=\[hidden\.test\.sh\]' --bad-lacks 'misses=\[hidden\.test\.sh\]' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "pre-existing failures counted as misses" 1 1 's/if \[ "\$rc" = 0 \]; then printf/if true; then printf/' \
    --good-has 'misses=\[hidden\.test\.sh\]' --bad-lacks 'misses=\[hidden\.test\.sh\]' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "timeouts treated as failures" 1 1 "s/\$1 != 0 \&\& \$1 != 124/\$1 != 0/" \
    --good-has 'baseline-failing=1' --bad-lacks 'baseline-failing=1' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "escalated selection no longer short-circuits" 0 0 "s/if grep -q '\^Escalated to FULL: ' \"\\\$WORK\\/report\"; then/if false; then/" \
    --good-has 'escalated:' --bad-lacks 'escalated:' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/solo.sh --repo "$R" --timeout 2
  mt "a real miss no longer fails the run" 1 0 's/^\[ -s "\$WORK\/misses" \] && exit 1$/:/' \
    -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "baseline re-run keeps the mutation" 1 0 's/^cat "\$WORK\/original" > "\$TREE\/\$FILE"$/:/' \
    --good-has 'misses=\[hidden\.test\.sh\]' --bad-lacks 'misses=\[hidden\.test\.sh\]' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "selected suites are run too" 1 1 's/comm -23 "\$WORK\/all" "\$WORK\/selected"/cat "$WORK\/all"/' \
    --good-has 'unselected=5' --bad-lacks 'unselected=5' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/alpha.sh --repo "$R" --timeout 2
  mt "file-exists check removed" 2 2 's/git -C "\$REPO" cat-file -e "\$REF:\$FILE" 2>\/dev\/null || degraded .*/:/' \
    --good-has 'does not exist at HEAD' --bad-lacks 'does not exist at HEAD' -- "$BASH_BIN" @SUT@ --manifest-dir "$KIT" --file $T/nope.sh --repo "$R"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
