#!/usr/bin/env bash
# suite-impact-replay.test.sh — suite for suite-impact-replay.sh (kit issue #2201, part 1a). The replay script is a
# script, so it has its own test: usage errors, the per-commit line, the totals line, the cheap oracle (a suite file the
# commit changed must be selected unless the run escalated), degraded commits, the root commit, --strict, and an
# end-to-end run against the REAL suite-impact.sh on a fixture repo. Everything lives under $TMPDIR.
#
# Usage: suite-impact-replay.test.sh                (run the suite)
#        suite-impact-replay.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 every assertion held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${SUITE_IMPACT_REPLAY_SUT:-$HERE/suite-impact-replay.sh}"
INSTRUMENT="$HERE/suite-impact.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$INSTRUMENT" ] || { echo "FATAL: instrument not found: $INSTRUMENT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }

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
unset SUITE_IMPACT_SUT SUITE_IMPACT_WIDE_THRESHOLD

TS=research-sdd/toolbelt/tests
OUT=""; ERR=""; RC=0
# run_with SUT_ENV_VALUE ARGS... — the replay script is copied next to the fixture manifests so its $HERE holds them
KIT="$TMP/kit"; mkdir -p "$KIT"
printf '# f\nlint-always whole-tree lint\n' > "$KIT/impact-always.txt"
printf '# f\nevalish eval\n' > "$KIT/impact-blindspot.txt"
cp "$SUT" "$KIT/suite-impact-replay.sh"
run() { OUT="$(env "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
rr() { run "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" "$KIT/suite-impact-replay.sh" "$@"; }       # with the fake instrument
real() { run "SUITE_IMPACT_SUT=$INSTRUMENT" "$BASH_BIN" "$KIT/suite-impact-replay.sh" "$@"; } # with the real one
has() { grep -qF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }
ehas() { grep -qF -- "$1" <<<"$ERR"; }

# fake instruments (they ignore their arguments; the replay passes the arguments of the real one)
FAKE="$TMP/fake.sh"          # selects only the always-run suite, never escalates
printf '#!/usr/bin/env bash\necho "Impacted: 3 of 10 suites"\necho "Escalated: no"\necho "Selected:"\necho "%s/lint-always.test.sh"\n' "research-sdd/toolbelt/tests" > "$FAKE"
FAKE_ESC="$TMP/fake-esc.sh"  # escalates (selection deliberately incomplete: escalation must excuse it)
printf '#!/usr/bin/env bash\necho "Impacted: 10 of 10 suites"\necho "Escalated to FULL: harness file changed: x"\necho "Selected:"\necho "%s/lint-always.test.sh"\n' "research-sdd/toolbelt/tests" > "$FAKE_ESC"
FAKE_BAD="$TMP/fake-bad.sh"  # degraded
printf '#!/usr/bin/env bash\necho "degraded: suite-impact: nope" >&2\nexit 2\n' > "$FAKE_BAD"
FAKE_GARB="$TMP/fake-garb.sh" # exit 0 with no Impacted line
printf '#!/usr/bin/env bash\necho hello\n' > "$FAKE_GARB"

# ---- fixture history: base, then 3 commits, each touching a suite (and the last one a production file) ------------
R="$TMP/repo"; mkdir -p "$R/$TS" "$R/research-sdd/toolbelt"
echo 'echo a' > "$R/$TS/a.test.sh"; echo 'echo b' > "$R/$TS/b.test.sh"; echo 'echo l' > "$R/$TS/lint-always.test.sh"; echo 'eval x' > "$R/$TS/evalish.test.sh"
echo 'echo p' > "$R/research-sdd/toolbelt/p.sh"
( cd "$R" && git init -q -b main . && git add -A && git commit -q -m base ) || { echo "FATAL: fixture" >&2; exit 2; }
( cd "$R" && echo '#1' >> $TS/a.test.sh && git commit -qam c1 && echo '#2' >> $TS/b.test.sh && git commit -qam c2 \
  && echo 'echo n' > $TS/new.test.sh && git add -A && git commit -q -m c3 )
mkdir -p "$R/research-sdd/install"; ( cd "$R" && echo i > research-sdd/install/x.sh && git add -A && git commit -q -m c4 )

echo "== suite-impact-replay.test.sh (SUT: $(basename "$SUT")) =="

# ---- usage -------------------------------------------------------------------------------------------------------------
rr; { [ "$RC" = 2 ] && ehas usage; } && ok "no N -> usage, exit 2" || no "no N" "(rc=$RC $ERR)"
rr 0 --repo "$R"; { [ "$RC" = 2 ] && ehas usage; } && ok "N=0 -> exit 2" || no "N=0" "(rc=$RC $ERR)"
rr abc --repo "$R"; { [ "$RC" = 2 ] && ehas usage; } && ok "N=abc -> exit 2" || no "N=abc" "(rc=$RC $ERR)"
rr 1 2 --repo "$R"; { [ "$RC" = 2 ] && ehas 'too many arguments'; } && ok "two positionals -> exit 2" || no "two N" "(rc=$RC $ERR)"
rr 1 --bogus; { [ "$RC" = 2 ] && ehas 'unknown argument: --bogus'; } && ok "unknown flag -> exit 2" || no "unknown flag" "(rc=$RC $ERR)"
rr 1 --repo "$R" --ref nosuchref; { [ "$RC" = 2 ] && ehas 'bad ref: nosuchref'; } && ok "bad --ref -> typed degraded, exit 2" || no "bad ref" "(rc=$RC $ERR)"
mkdir -p "$TMP/norepo"; rr 1 --repo "$TMP/norepo"; { [ "$RC" = 2 ] && ehas 'not a git repository'; } && ok "not a git repo -> typed degraded, exit 2" || no "not a repo" "(rc=$RC $ERR)"
run "SUITE_IMPACT_SUT=$TMP/absent.sh" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 1 --repo "$R"
{ [ "$RC" = 2 ] && ehas 'instrument absent'; } && ok "absent instrument -> typed degraded, exit 2" || no "absent instrument" "(rc=$RC $ERR)"

# ---- per-commit lines, totals, mean ------------------------------------------------------------------------------------
rr 3 --repo "$R" --ref main
{ [ "$RC" = 0 ] && [ "$(grep -c ' 3/10 escalated=no' <<<"$OUT")" = 3 ]; } && ok "one '<sha7> sel/total escalated=no missing=[...]' line per commit (3)" || no "per-commit lines" "(rc=$RC $OUT)"
hasre 'missing=\[research-sdd/toolbelt/tests/new.test.sh\]' && ok "oracle: a suite ADDED by the commit but not selected is reported missing" || no "oracle miss (added suite)" "($OUT)"
hasre 'missing=\[research-sdd/toolbelt/tests/b.test.sh\]' && ok "oracle: a suite MODIFIED by the commit but not selected is reported missing" || no "oracle miss (modified suite)" "($OUT)"
hasre '^Totals: commits=3 analysed=3 degraded=0 skipped=0 escalated=0 \(0%\) oracle-misses=2 mean-selected\(all\)=3\.0 mean-selected\(non-escalated\)=3\.0$' \
  && ok "totals line: counts, escalation rate, oracle misses, both means" || no "totals line" "($OUT)"
rr 3 --repo "$R" --ref main --strict
[ "$RC" = 1 ] && ok "--strict: an oracle miss exits 1" || no "--strict miss" "(rc=$RC)"
rr 1 --repo "$R" --ref main
{ [ "$RC" = 0 ] && ! hasre 'missing=\[[^]]'; } && ok "a commit touching no suite file has missing=[] (the install commit)" || no "no suite touched" "($OUT)"
run "SUITE_IMPACT_SUT=$FAKE_ESC" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 3 --repo "$R" --ref main
{ [ "$RC" = 0 ] && ! hasre 'missing=\[[^]]' && hasre 'escalated=yes' && hasre 'escalated=3 \(100%\)' && hasre 'mean-selected\(non-escalated\)=n/a'; } \
  && ok "an escalated run is never an oracle miss; the non-escalated mean is n/a when none" || no "escalated excused" "($OUT)"
run "SUITE_IMPACT_SUT=$FAKE_ESC" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 3 --repo "$R" --ref main --strict
[ "$RC" = 0 ] && ok "--strict with no miss and no degraded run exits 0" || no "--strict clean" "(rc=$RC)"

# ---- degraded commits, root commit ---------------------------------------------------------------------------------------
run "SUITE_IMPACT_SUT=$FAKE_BAD" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 3 --repo "$R" --ref main
{ [ "$RC" = 2 ] && hasre ' degraded rc=2: degraded: suite-impact: nope' && hasre 'analysed=0 degraded=3' && ehas 'nothing was measured'; } \
  && ok "every commit degraded -> typed lines, totals, exit 2 (never a quiet pass)" || no "all degraded" "(rc=$RC $OUT $ERR)"
run "SUITE_IMPACT_SUT=$FAKE_GARB" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 1 --repo "$R" --ref main
{ [ "$RC" = 2 ] && hasre 'unparseable Impacted line'; } && ok "an instrument line the replay cannot parse is degraded, not a zero" || no "unparseable" "(rc=$RC $OUT)"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = diff ] && { echo "shim: diff failed" >&2; exit 1; }; done\nexec %s "$@"\n' "$(type -P git)" > "$SHIM/git"; chmod +x "$SHIM/git"
run "PATH=$SHIM:$PATH" "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" "$KIT/suite-impact-replay.sh" 2 --repo "$R" --ref main
{ [ "$RC" = 2 ] && hasre ' degraded rc=0: git diff failed' && hasre 'analysed=0 degraded=2'; } \
  && ok "a failing 'git diff' is a degraded commit, never an empty changed-suite list (pipe checked)" || no "git diff failure" "(rc=$RC $OUT $ERR)"
rr 10 --repo "$R" --ref main
{ [ "$RC" = 0 ] && hasre 'root-commit \(no parent\): skipped' && hasre 'commits=5 analysed=4 degraded=0 skipped=1'; } && ok "the root commit is skipped and counted, N larger than history is fine" || no "root commit" "(rc=$RC $OUT)"

# ---- end to end with the REAL instrument -----------------------------------------------------------------------------------
E="$TMP/e2e"; git clone -q "$R" "$E" 2>/dev/null
real 4 --repo "$E" --ref main
{ [ "$RC" = 0 ] && hasre '^Totals: commits=4 analysed=4 degraded=0 skipped=0 escalated=1 \(25%\) oracle-misses=0 ' ; } \
  && ok "real instrument: 3 mapped commits pass the oracle, the install commit escalates (1 of 4)" || no "real instrument" "(rc=$RC $OUT $ERR)"
hasre '[0-9a-f]{7} [0-9]+/5 escalated=yes missing=\[\]' || hasre '[0-9a-f]{7} [0-9]+/4 escalated=yes missing=\[\]' && ok "real instrument: the escalated commit line shows escalated=yes" || no "real escalated line" "($OUT)"

# =================================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  KITM="$MUT/kit"; mkdir -p "$KITM"; cp "$KIT/impact-always.txt" "$KIT/impact-blindspot.txt" "$KITM/"
  mt() {   # mt LABEL GOOD-RC BAD-RC SED-EXPR [tooth flags...] -- ARGV...
    local label="$1" grc="$2" brc="$3" expr="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  mt "oracle comparison removed" 0 0 's/grep -qxF -- "\$f" "\$TMP\/selected" || missing=/grep -qxF -- "$f" "$TMP\/selected" \&\& missing=/' \
    --good-has 'new.test.sh]' --bad-lacks 'new.test.sh]' -- env "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ 3 --repo "$R" --ref main
  mt "escalated runs no longer excused" 0 0 's/  if \[ "\$escalated" = no \]; then$/  if true; then/' \
    --good-lacks 'missing=\[research' --bad-has 'missing=\[research' -- env "SUITE_IMPACT_SUT=$FAKE_ESC" "$BASH_BIN" @SUT@ 3 --repo "$R" --ref main
  mt "root-commit skip removed" 0 0 's/echo "\$short root-commit (no parent): skipped"; skipped=\$((skipped+1)); continue/:/' \
    --good-has 'root-commit' --bad-lacks 'root-commit' -- env "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ 10 --repo "$R" --ref main
  mt "instrument failure no longer typed" 2 2 's/if \[ "\$rc" -ne 0 \]; then/if false; then/' \
    --good-has 'degraded rc=2' --bad-lacks 'degraded rc=2' -- env "SUITE_IMPACT_SUT=$FAKE_BAD" "$BASH_BIN" @SUT@ 2 --repo "$R" --ref main
  mt "nothing-measured gate removed" 2 0 's/if \[ "\$analysed" -eq 0 \]; then/if false; then/' \
    -- env "SUITE_IMPACT_SUT=$FAKE_BAD" "$BASH_BIN" @SUT@ 2 --repo "$R" --ref main
  mt "--strict ignores misses" 1 0 's/if \[ "\$STRICT" = 1 \] && { \[ "\$miss" -gt 0 \] || \[ "\$degr" -gt 0 \]; }; then exit 1; fi/:/' \
    -- env "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ 3 --repo "$R" --ref main --strict
  mt "mean over non-escalated runs broken" 0 0 's/sum_ne=\$((sum_ne+sel)); n_ne=\$((n_ne+1))/n_ne=$((n_ne+1))/' \
    --good-has 'mean-selected\(non-escalated\)=3\.0' --bad-lacks 'mean-selected\(non-escalated\)=3\.0' -- env "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ 3 --repo "$R" --ref main
  mt "git diff failure ignored" 2 0 's/if ! git -C "\$REPO" diff --name-status -M "\$sha^" "\$sha" > "\$TMP\/diff" 2>\/dev\/null; then/if false; then/' \
    -- env "PATH=$SHIM:$PATH" "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ 2 --repo "$R" --ref main
  mt "N validation removed" 2 2 's/case "\$N" in .*) echo "usage: suite-impact-replay.sh <N>.*exit 2 ;; esac/:/' \
    --good-has 'usage' --bad-lacks 'usage' -- env "SUITE_IMPACT_SUT=$FAKE" "$BASH_BIN" @SUT@ abc --repo "$R" --ref main
  mt "unparseable Impacted line accepted" 2 0 's/case "\$sel\$tot" in .*) echo "\$short degraded rc=0: unparseable Impacted line: \$line"; degr=\$((degr+1)); analysed=\$((analysed-1)); continue ;; esac/:/' \
    -- env "SUITE_IMPACT_SUT=$FAKE_GARB" "$BASH_BIN" @SUT@ 1 --repo "$R" --ref main
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
