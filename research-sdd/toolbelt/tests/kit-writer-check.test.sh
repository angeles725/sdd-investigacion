#!/usr/bin/env bash
# kit-writer-check.test.sh — suite for maint/kit-writer-check.sh (kit issue #2208). Every case runs the instrument
# against a small fixture git repo built under $TMPDIR (never inside the live tree).
#
# Covered: changed script -> its suites required (first/middle/last/single), unrelated suites not required, a changed
# suite is required, teeth logs (valid / absent / plain-only / failed / zero-passed / FAIL line / empty / wrong suite /
# no --teeth-log), FULL escalation (note + still the named suites, never silently empty), no-suite, docs-only
# (`required: 0`), node suites (teeth-na), name-kill detection (every pattern, allow comment, comment line, .md,
# `pkill-guard` token, pre-existing line, second-hunk line number, tests scanned, untracked file under --worktree),
# --worktree, --format json, --write-teeth-log (pass, fail, timeout, refusals), degraded states and usage.
#
# Usage: kit-writer-check.test.sh                (run the suite)
#        kit-writer-check.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 every assertion held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${KIT_WRITER_CHECK_SUT:-$HERE/../maint/kit-writer-check.sh}"
IMPACT_REAL="$HERE/suite-impact.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$IMPACT_REAL" ] || { echo "FATAL: suite-impact.sh not found: $IMPACT_REAL" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }
export KIT_WRITER_CHECK_IMPACT="$IMPACT_REAL"   # a mutant copy of the SUT lives elsewhere: pin the real map

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
unset KIT_WRITER_CHECK_TIMEOUT

T=research-sdd/toolbelt
TS=$T/tests
PFX="research-sdd/toolbelt/tests/"
PK="pk""ill"; KA="kill""all"            # keep the scanned words out of this file's own added lines
OUT=""; ERR=""; RC=0
run() { OUT="$("$BASH_BIN" "$SUT" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
has()   { grep -qxF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }
ehas()  { grep -qF -- "$1" <<<"$ERR"; }

# ---- the pristine fixture repo --------------------------------------------------------------------------------
P="$TMP/pristine"; mkdir -p "$P"
w() { mkdir -p "$(dirname "$P/$1")"; cat > "$P/$1"; }
# a fake suite: banner only under --prove-teeth, summary always
fake_suite() { # path sut-word
  w "$1" <<EOF
#!/usr/bin/env bash
: '$2'   # SUT named on a code line: comment-only mentions are not graph edges (#2201)
if [ "\${1:-}" = "--prove-teeth" ]; then echo "-- teeth --"; fi
echo "== 3 passed · 0 failed =="
EOF
}
fake_suite $TS/a.test.sh 'SUT="$HERE/../alpha.sh"'
fake_suite $TS/b.test.sh '"$TOOLBELT/beta.sh"'
fake_suite $TS/c.test.sh '"$TB/gamma.sh"'
fake_suite $TS/multi.test.sh '"$TB/alpha.sh" "$TB/beta.sh" "$TB/gamma.sh"'
fake_suite $TS/lint-always.test.sh 'whole tree'
fake_suite $TS/evalish.test.sh 'eval "$cmd"'
w $TS/pi.test.mjs <<'EOF'
import x from "../adv.mjs";
EOF
w $TS/impact-always.txt <<'EOF'
# fixture
lint-always whole-tree lint
EOF
w $TS/impact-blindspot.txt <<'EOF'
# fixture
evalish builds a command and evals it
EOF
for f in lib/mutant.sh run-all.sh shard-join.sh teeth-helper-waivers.txt suite-impact.sh; do w $TS/$f <<<':'; done
w $T/alpha.sh <<'EOF'
echo alpha
EOF
w $T/beta.sh <<'EOF'
echo beta
EOF
w $T/gamma.sh <<'EOF'
echo gamma
EOF
w $T/leaf.sh <<'EOF'
echo leaf
EOF
w $T/mid.sh <<'EOF'
"$TB/leaf.sh"
EOF
w $T/top.sh <<'EOF'
"$TB/mid.sh"
EOF
fake_suite $TS/m.test.sh '"$TB/mid.sh"'
fake_suite $TS/t.test.sh '"$TB/top.sh"'
w $T/adv.mjs <<'EOF'
export default 1;
EOF
w $T/solo.sh <<'EOF'
echo nobody tests me
EOF
w $T/notes.md <<'EOF'
# notes
EOF
w $T/lib/gl.sh <<'EOF'
echo lib
EOF
w $T/old.sh <<'EOF'
# pre-existing, mentions $PK_PLACEHOLDER
EOF
sed -i "s/\$PK_PLACEHOLDER/$PK -f oldthing/" "$P/$T/old.sh"
w $TS/old.test.sh <<'EOF'
"$TB/old.sh"
EOF
fake_suite research-sdd/install/tests/a.test.sh 'nothing in particular'
w $TS/writer-check-waivers.txt <<'EOF'
# fixture waivers: <repo-relative suite> <reason>
research-sdd/toolbelt/tests/t.test.sh smoke suite with no mutation controls (fixture)
EOF
( cd "$P" && git init -q -b main . && git add -A && git commit -q -m base && git tag base )

newcase() { git clone -q "$P" "$TMP/$1" 2>/dev/null && printf '%s' "$TMP/$1"; }
commit_all() { ( cd "$1" && git add -A && git commit -q -m change ); }
# kase NAME FILE... — clone, append a line to each file, commit; prints the dir
kase() { local n="$1" d f; shift; d="$(newcase "$n")" || return 1; for f in "$@"; do printf '# changed\n' >> "$d/$f"; done; commit_all "$d"; printf '%s' "$d"; }
# Teeth logs are named after the repo-relative suite path (slashes -> __) and start with a binding header produced by
# `--print-binding` for the repo the logs were "run" in (LREPO).
lname() { printf '%s.log' "$(printf '%s' "${PFX}$1" | sed 's#/#__#g')"; }
LREPO=""
bind_hdr() { "$BASH_BIN" "$SUT" --repo "$LREPO" --base base --print-binding; }
# ow FILE BODY-FORMAT : header + body
ow() { local f="$1"; shift; { bind_hdr; printf -- "$@"; } > "$f"; }
# good_log DIR suite... — write a VALID teeth log per suite (basename under tests/)
good_log() { local dir="$1"; shift; mkdir -p "$dir"; local s; for s in "$@"; do ow "$dir/$(lname "$s")" '-- teeth --\n  PASS  x\n== 3 passed · 0 failed ==\n'; done; }
# lg REPO -> a fresh dir of valid logs bound to REPO, for every fixture suite
lg() { local d; d="$(mktemp -d "$TMP/lg.XXXXXX")"; LREPO="$1"; good_log "$d" a.test.sh b.test.sh c.test.sh multi.test.sh m.test.sh t.test.sh lint-always.test.sh evalish.test.sh old.test.sh; printf '%s' "$d"; }
BASE=(--base base)

echo "== kit-writer-check.test.sh (SUT: $(basename "$SUT")) =="

# ---- required set ---------------------------------------------------------------------------------------------
D="$(kase alpha $T/alpha.sh)"
run --repo "$D" "${BASE[@]}"
{ [ "$RC" = 1 ] && has "  ${PFX}a.test.sh" && has "  ${PFX}multi.test.sh"; } && ok "changed script: every suite naming it is required (first + last mapped)" || no "required set" "(rc=$RC $OUT)"
{ has "  ${PFX}b.test.sh" || has "  ${PFX}lint-always.test.sh" || has "  ${PFX}evalish.test.sh"; } && no "unrelated / always-run / blind-spot suites must not be required" "($OUT)" || ok "unrelated, always-run and blind-spot suites are not required"
hasre '^missing-teeth research-sdd/toolbelt/tests/a.test.sh \(no --teeth-log given\)$' && ok "no --teeth-log: every required suite is missing-teeth with the reason" || no "no teeth-log reason" "($OUT)"
D1="$(kase single $T/beta.sh)"; run --repo "$D1" "${BASE[@]}"
{ hasre '^Required suites: 2$' && has "  ${PFX}b.test.sh"; } && ok "single changed script: exactly its two suites (count line)" || no "single" "($OUT)"
D2="$(kase three $T/alpha.sh $T/beta.sh $T/gamma.sh)"; run --repo "$D2" "${BASE[@]}"
( for s in a b c multi; do has "  ${PFX}$s.test.sh" || exit 1; done ) && ok "three changed scripts: union of suites (first, middle, last)" || no "union" "($OUT)"
D3="$(kase suite_only $TS/b.test.sh)"; run --repo "$D3" "${BASE[@]}"
{ has "  ${PFX}b.test.sh" && hasre '^Required suites: 1$'; } && ok "a changed suite is itself required" || no "changed suite" "($OUT)"

# ---- teeth logs -------------------------------------------------------------------------------------------------
LREPO="$D"
L="$TMP/logs_ok"; good_log "$L" a.test.sh multi.test.sh
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 0 ] && hasre '^Findings: 0$'; } && ok "valid --prove-teeth logs for every required suite -> exit 0" || no "valid logs" "(rc=$RC $OUT)"
L="$TMP/logs_missing"; good_log "$L" a.test.sh
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*multi.test.sh \(no log research-sdd__toolbelt__tests__multi\.test\.sh\.log\)$' && ! hasre 'missing-teeth .*a.test.sh'; } && ok "one log missing (the LAST suite) -> only that suite is missing-teeth" || no "missing last" "(rc=$RC $OUT)"
L="$TMP/logs_missing2"; good_log "$L" multi.test.sh
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(no log research-sdd__toolbelt__tests__a\.test\.sh\.log\)$' && ! hasre 'missing-teeth .*multi.test.sh'; } && ok "one log missing (the FIRST suite) -> only that suite is missing-teeth" || no "missing first" "(rc=$RC $OUT)"
L="$TMP/logs_plain"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '  PASS  x\n== 3 passed · 0 failed ==\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(plain run: no teeth banner' ; } && ok "plain-only run (no teeth banner) is rejected" || no "plain only" "(rc=$RC $OUT)"
L="$TMP/logs_failed"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '-- teeth --\n== 2 passed · 1 failed ==\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(summary reports failures' ; } && ok "a log whose summary reports failures is rejected" || no "failed log" "(rc=$RC $OUT)"
L="$TMP/logs_zero"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '-- teeth --\n== 0 passed · 0 failed ==\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(summary reports zero passed' ; } && ok "zero passed cases is rejected (N must be > 0)" || no "zero passed" "(rc=$RC $OUT)"
L="$TMP/logs_failline"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '-- teeth --\n  FAIL  one\n== 3 passed · 0 failed ==\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(log contains a FAIL line' ; } && ok "a FAIL line in the log is rejected even with a green summary" || no "fail line" "(rc=$RC $OUT)"
L="$TMP/logs_empty"; good_log "$L" a.test.sh multi.test.sh; : > "$L/$(lname a.test.sh)"
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(log is empty' ; } && ok "an empty log is rejected" || no "empty log" "(rc=$RC $OUT)"
L="$TMP/logs_nosum"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '-- teeth --\nsome text\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*a.test.sh \(no summary line' ; } && ok "a log without a summary line is rejected" || no "no summary" "(rc=$RC $OUT)"
L="$TMP/logs_last"; good_log "$L" a.test.sh multi.test.sh; ow "$L/$(lname a.test.sh)" '-- teeth --\n== 1 passed · 2 failed ==\n== 3 passed · 0 failed ==\n'
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
[ "$RC" = 0 ] && ok "the LAST summary line decides (an earlier red one is superseded)" || no "last summary" "(rc=$RC $OUT)"
L="$TMP/logs_wrong"; good_log "$L" b.test.sh c.test.sh
run --repo "$D" "${BASE[@]}" --teeth-log "$L"
[ "$RC" = 1 ] && ok "logs of other suites do not satisfy the required ones" || no "wrong-suite logs" "(rc=$RC)"

# ---- FULL escalation, no-suite, docs-only, node -------------------------------------------------------------------
D_new="$(newcase newfile)"; printf 'echo n\n' > "$D_new/$T/fresh.sh"; printf '"$TB/fresh.sh"\n' >> "$D_new/$TS/c.test.sh"; commit_all "$D_new"
run --repo "$D_new" "${BASE[@]}"
{ [ "$RC" = 1 ] && hasre '^full-gate-needed: ' && has "  ${PFX}c.test.sh" && hasre '^missing-teeth .*c.test.sh'; } && ok "FULL escalation: note printed AND the suites naming the new file are still required" || no "full escalation" "(rc=$RC $OUT)"
LREPO="$D_new"; L="$TMP/logs_full"; good_log "$L" c.test.sh
run --repo "$D_new" "${BASE[@]}" --teeth-log "$L"
{ [ "$RC" = 0 ] && hasre '^full-gate-needed: '; } && ok "FULL escalation with valid logs: exit 0 and the full-gate note remains" || no "full ok" "(rc=$RC $OUT)"
# closure (not FULL): leaf is only reachable through mid -> m ; top -> t is NOT reached by a change to leaf
D_leaf="$(kase leaf $T/leaf.sh)"; run --repo "$D_leaf" "${BASE[@]}"
{ [ "$RC" = 1 ] && has "  ${PFX}m.test.sh" && ! hasre 'full-gate-needed'; } && ok "no escalation: a suite reaching the file THROUGH another script is required (closure)" || no "closure" "(rc=$RC $OUT)"
# FULL (a new file) + mid changed: direct suites only -> m ; the closure's t is left to the full gate
D_fd="$(newcase fulldirect)"; printf '# c\n' >> "$D_fd/$T/mid.sh"; printf 'echo n\n' > "$D_fd/$T/fresh9.sh"; printf '"$TB/fresh9.sh"\n' >> "$D_fd/$TS/c.test.sh"; commit_all "$D_fd"
run --repo "$D_fd" "${BASE[@]}"
{ has "  ${PFX}m.test.sh" && has "  ${PFX}c.test.sh" && ! has "  ${PFX}t.test.sh" && hasre '^full-gate-needed: '; } && ok "FULL: a changed file requires the suites that NAME it, not the whole closure" || no "full direct" "(rc=$RC $OUT)"
# FULL + leaf: nothing names leaf directly except mid's chain -> falls back to what the map reaches
D_fl="$(newcase fullleaf)"; printf '# c\n' >> "$D_fl/$T/leaf.sh"; printf 'echo n\n' > "$D_fl/$T/fresh8.sh"; printf '"$TB/fresh8.sh"\n' >> "$D_fl/$TS/c.test.sh"; commit_all "$D_fl"
run --repo "$D_fl" "${BASE[@]}"
{ has "  ${PFX}m.test.sh" && ! hasre '^no-suite '; } && ok "FULL, no suite names the file: falls back to the map instead of reporting no-suite" || no "full fallback" "(rc=$RC $OUT)"
D_solo="$(kase solo $T/solo.sh)"; run --repo "$D_solo" "${BASE[@]}"
{ [ "$RC" = 1 ] && hasre "^no-suite ${T}/solo.sh " && hasre '^full-gate-needed: '; } && ok "a changed script no suite names -> no-suite finding (never a silent pass)" || no "no-suite" "(rc=$RC $OUT)"
D_lib="$(kase libonly $TS/impact-always.txt)"; run --repo "$D_lib" "${BASE[@]}"
{ [ "$RC" = 0 ] && hasre '^required: 0 ' && hasre '^full-gate-needed: ' && hasre '^Required suites: 0$'; } && ok "harness-only change: explicit 'required: 0' plus the full-gate note, never an empty silence" || no "harness only" "(rc=$RC $OUT)"
D_doc="$(kase doc $T/notes.md)"; run --repo "$D_doc" "${BASE[@]}"
{ [ "$RC" = 0 ] && hasre '^required: 0 '; } && ok "docs-only change: required: 0 stated, exit 0" || no "docs only" "(rc=$RC $OUT)"
D_node="$(kase node $T/adv.mjs)"; run --repo "$D_node" "${BASE[@]}"
{ [ "$RC" = 0 ] && hasre '^teeth-na research-sdd/toolbelt/tests/pi.test.mjs$'; } && ok "a node suite takes no --prove-teeth: teeth-na, not required" || no "node suite" "(rc=$RC $OUT)"
D_lib2="$(kase libscript $T/lib/gl.sh)"; run --repo "$D_lib2" "${BASE[@]}"
{ [ "$RC" = 1 ] && hasre "^no-suite ${T}/lib/gl.sh "; } && ok "a lib script no suite names is flagged no-suite" || no "lib no-suite" "(rc=$RC $OUT)"

# ---- name-kill ---------------------------------------------------------------------------------------------------
nk() { # nk NAME FILE CONTENT -> repo with FILE added (appended) containing CONTENT
  local d; d="$(newcase "nk_$1")"; mkdir -p "$d/$(dirname "$2")"; printf '%s\n' "$3" >> "$d/$2"; commit_all "$d"; printf '%s' "$d"; }
nkrun() { run --repo "$1" "${BASE[@]}"; }
D="$(nk pk $T/alpha.sh "echo start
$PK -f myloop")"; D_nk1="$D"
nkrun "$D"; { hasre "^name-kill ${T}/alpha.sh:3 " && [ "$RC" = 1 ]; } && ok "name kill is reported with file:LINE of the added line" || no "name-kill basic" "(rc=$RC $OUT)"
D="$(nk ka $T/alpha.sh "$KA python3")"; nkrun "$D"; hasre "^name-kill ${T}/alpha.sh:" && ok "name-kill: second tool name" || no "killall" "($OUT)"
D="$(nk k9 $T/alpha.sh "kill -9 -1")"; D_nk2="$D"; nkrun "$D"; hasre "^name-kill " && ok "name-kill: kill -9 -1 (every process)" || no "kill -9 -1" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk px $T/alpha.sh 'pgrep -f loop | xargs kill')"; D_nk3="$D"; nkrun "$D"; hasre "^name-kill " && ok "name-kill: pgrep | xargs kill" || no "pgrep xargs" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk sub $T/alpha.sh 'kill $(pgrep -f loop)')"; D_nk4="$D"; nkrun "$D"; hasre "^name-kill " && ok "name-kill: kill \$(pgrep ...)" || no "kill subst" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk ok1 $T/alpha.sh "$PK -f x  # writer-check: allow-name-kill reaper owns this host")"; D_nk5="$D"; nkrun "$D"
{ ! hasre '^name-kill '; } && ok "the allow comment on the same line suppresses the finding" || no "allow comment" "($OUT)"
D="$(nk cmt $T/alpha.sh "# cleanup; $PK -f loop")"; D_nk6="$D"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "a comment-only line is not scanned" || no "comment line" "($OUT)"
D="$(nk md $T/notes.md "$PK -f anything")"; D_nk7="$D"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "documentation (.md) mentioning the word does not trip" || no "md false positive" "($OUT)"
D="$(nk guard $T/alpha.sh "source hook-pretool-$PK-guard.sh")"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "the token '$PK-guard' is not a kill" || no "guard token" "($OUT)"
D="$(nk word $T/alpha.sh 'echo skill killing-time pkillx')"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "similar words (skill, killing, longer identifiers) do not trip" || no "similar words" "($OUT)"
D="$(newcase pre)"; printf '# c\n' >> "$D/$T/old.sh"; commit_all "$D"; nkrun "$D"
{ ! hasre '^name-kill '; } && ok "a PRE-EXISTING name kill on an untouched line is not reported" || no "pre-existing" "($OUT)"
D="$(newcase hunk2)"; { printf 'x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\nx9\nx10\n'; } > "$D/$T/hk.sh"; commit_all "$D"; ( cd "$D" && git tag base2 )
{ printf 'x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\n%s -x y\nx10\n' "$PK"; } > "$D/$T/hk.sh"; commit_all "$D"
D_hunk="$D"; run --repo "$D" --base base2; hasre "^name-kill ${T}/hk.sh:9 " && ok "line number is right in a later hunk" || no "hunk line number" "($OUT)"
D="$(nk tst $TS/a.test.sh "$PK -f loop")"; nkrun "$D"; hasre "^name-kill ${TS}/a.test.sh:" && ok "test files are scanned too" || no "tests scanned" "($OUT)"
D="$(nk cp1 $T/alpha.sh 'make && pkill -f x')"; D_cp1="$D"; nkrun "$D"; hasre '^name-kill ' && ok "command position after &&" || no "cp &&" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk cp2 $T/alpha.sh 'sudo -n killall python3')"; nkrun "$D"; hasre '^name-kill ' && ok "command position after sudo -n" || no "cp sudo" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk cp3 $T/alpha.sh 'FOO=1 /usr/bin/pkill -9 loop')"; nkrun "$D"; hasre '^name-kill ' && ok "command position after VAR=x with an absolute path" || no "cp abs" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk cp4 $T/alpha.sh 'timeout 5 pkill -f loop')"; nkrun "$D"; hasre '^name-kill ' && ok "command position after timeout N" || no "cp timeout" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk cp5 $T/alpha.sh 'x=$(pkill -f loop)')"; nkrun "$D"; hasre '^name-kill ' && ok "command position inside \$( )" || no "cp subst" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk str1 $T/alpha.sh "grep -Eq '$PK|pgrep' file")"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "a grep pattern naming the tool is not a kill" || no "grep pattern" "($OUT)"
D="$(nk str2 $T/alpha.sh 'echo "never use pkill -f on loops"')"; D_str2="$D"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "prose inside a quoted echo is not a kill" || no "echo prose" "($OUT)"
D="$(nk str3 $T/alpha.sh "STDIN='{\"tool_input\":{\"command\":\"pkill -f foo\"}}'")"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "a JSON fixture string naming the tool is not a kill" || no "json fixture" "($OUT)"
D="$(nk str4 $T/alpha.sh 'case_pkill_closed() { :; }')"; nkrun "$D"; { ! hasre '^name-kill '; } && ok "an identifier containing the tool name is not a kill" || no "identifier" "($OUT)"
D="$(nk pyl $T/helper.py "cmd = [\"$PK\", \"-f\", \"x\"]")"; D_pyl="$D"; nkrun "$D"; hasre "^name-kill ${T}/helper.py:1 " && ok "python argv-list form is a kill" || no "py argv" "($OUT)"
D="$(nk pid $T/alpha.sh 'pidof loop | xargs kill -9')"; D_nk8="$D"; nkrun "$D"; hasre '^name-kill ' && ok "pidof piped into xargs kill is a name kill" || no "pidof pipe" "($OUT)"  # writer-check: allow-name-kill fixture text, never executed
D="$(nk py $T/helper.py "import os; os.system('$PK -f x')")"; nkrun "$D"; hasre "^name-kill ${T}/helper.py:1 " && ok "python files are scanned" || no "py scanned" "($OUT)"
D="$(nk two $T/alpha.sh "$PK a
$KA b")"; nkrun "$D"; { [ "$(grep -c '^name-kill ' <<<"$OUT")" = 2 ]; } && ok "two offending added lines -> two findings" || no "two kills" "($OUT)"

D_ren="$(newcase ren)"; ( cd "$D_ren" && git mv $T/beta.sh $T/beta2.sh && git commit -q -m rename )
run --repo "$D_ren" "${BASE[@]}"; { [ "$RC" = 1 ] && hasre "^no-suite ${T}/beta2.sh "; } && ok "a renamed script is checked under its NEW path" || no "rename" "(rc=$RC $OUT)"

# ---- live-repo wiring (kit issue #2208 follow-up): the pkill guard hook and the PR template RED line -------------
REPO_ROOT="$(cd -P -- "$HERE/../../.." && pwd -P)"
SETTINGS="$REPO_ROOT/.claude/settings.json"
GUARD_REL="research-sdd/templates/hook-pretool-pkill-guard.sh"
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  gcmd="$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | .command] | map(select(test("hook-pretool-pkill-guard[.]sh"))) | .[0] // empty' "$SETTINGS" 2>/dev/null)"
  [ -n "$gcmd" ] && ok "kit .claude/settings.json wires the pkill guard under PreToolUse (Bash)" || no "pkill guard not wired in the kit settings.json"
  case "$gcmd" in *'"$CLAUDE_PROJECT_DIR/'"$GUARD_REL"'" --strict-name-kill'*) ok "the guard is wired portably (\$CLAUDE_PROJECT_DIR) with --strict-name-kill" ;; *) no "guard command is not the portable strict form" "($gcmd)" ;; esac
  case "$gcmd" in */home/*|*/Users/*) no "absolute per-machine path in the guard command" ;; *) ok "no absolute per-machine path in the guard command" ;; esac
  case "$gcmd" in *'exit 2'*) ok "the wrapper fails closed (exit 2 blocks the tool call in Claude Code)" ;; *) no "wrapper does not fail closed" "($gcmd)" ;; esac
  mkdir -p "$TMP/noguard"
  jq -nc --arg c "$PK foo" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' > "$TMP/pl_deny.json"
  CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$gcmd" < "$TMP/pl_deny.json" > "$TMP/wo" 2> "$TMP/we"; wrc=$?
  { [ "$wrc" = 0 ] && grep -q '"permissionDecision":"deny"' "$TMP/wo"; } && ok "the wired command, executed, denies a strict name kill" || no "wired command did not deny" "(rc=$wrc $(cat "$TMP/wo"))"
  CLAUDE_PROJECT_DIR="$TMP/noguard" bash -c "$gcmd" < "$TMP/pl_deny.json" > "$TMP/wo" 2> "$TMP/we"; wrc=$?
  { [ "$wrc" = 2 ] && grep -q 'pkill guard missing' "$TMP/we"; } && ok "guard script absent -> exit 2 and a stderr reason (fail closed)" || no "missing guard did not fail closed" "(rc=$wrc $(cat "$TMP/we"))"
  [ -x "$REPO_ROOT/$GUARD_REL" ] && ok "the wired guard script exists and is executable" || no "guard script missing or not executable"
else
  no "jq or the kit settings.json is missing (cannot check the guard wiring)"
fi
TEMPLATE="$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md"
RED_JS="$REPO_ROOT/.github/scripts/parse-red-evidence.cjs"
red_check() { # red_check BODY-FILE -> prints "ok" or "fail" for a PR that changes a production script
  node -e 'const {checkRedEvidence}=require(process.argv[1]);const b=require("fs").readFileSync(process.argv[2],"utf8");process.stdout.write(checkRedEvidence(b,["research-sdd/toolbelt/foo.sh"]).ok?"ok":"fail")' "$RED_JS" "$1" 2>&1
}
if command -v node >/dev/null 2>&1 && [ -f "$TEMPLATE" ]; then
  grep -qE '^RED:' "$TEMPLATE" && ok "the PR template carries a visible RED: line" || no "PR template has no visible RED: line"
  grep -q 'RED: n/a' "$TEMPLATE" && ok "the PR template documents the RED: n/a alternative" || no "PR template does not mention RED: n/a"
  [ "$(red_check "$TEMPLATE")" = fail ] && ok "the unedited template does NOT satisfy the RED check for a production change" || no "the unedited PR template satisfies the RED check"
  sed -E 's/^RED:.*$/RED: foo.test.sh case one — expected 3 got 0/' "$TEMPLATE" > "$TMP/filled.md"
  [ "$(red_check "$TMP/filled.md")" = ok ] && ok "replacing the template RED line with real evidence satisfies the check" || no "a filled template RED line does not satisfy the check" "$(red_check "$TMP/filled.md")"
else
  no "node or the PR template is missing (cannot check the RED line)"
fi

# ---- --worktree ---------------------------------------------------------------------------------------------------
D="$(newcase wt)"; printf '# w\n' >> "$D/$T/alpha.sh"; printf '%s -f stray\n' "$PK" > "$D/$T/untracked.sh"
run --repo "$D" "${BASE[@]}" --worktree
{ [ "$RC" = 1 ] && has "  ${PFX}a.test.sh" && hasre "^name-kill ${T}/untracked.sh:1 "; } && ok "--worktree: uncommitted edit maps suites; untracked file is scanned with line numbers" || no "worktree" "(rc=$RC $OUT)"
run --repo "$D" "${BASE[@]}" --worktree --head HEAD; { [ "$RC" = 2 ]; } && ok "--worktree with --head is a usage error" || no "worktree+head" "(rc=$RC)"

# ---- json ------------------------------------------------------------------------------------------------------
D="$(kase json $T/alpha.sh)"; run --repo "$D" "${BASE[@]}" --format json
{ [ "$RC" = 1 ] && grep -q '"status":"findings"' <<<"$OUT" && grep -q '"type":"missing-teeth"' <<<"$OUT" && grep -q "\"required\":\[\"${PFX}a.test.sh\"" <<<"$OUT"; } && ok "--format json carries status, required and typed findings" || no "json" "(rc=$RC $OUT)"
LREPO="$D"; L="$TMP/logs_json"; good_log "$L" a.test.sh multi.test.sh; run --repo "$D" "${BASE[@]}" --format json --teeth-log "$L"
{ [ "$RC" = 0 ] && grep -q '"status":"ok"' <<<"$OUT" && grep -q '"findings":\[\]' <<<"$OUT"; } && ok "--format json clean run: status ok, empty findings" || no "json ok" "(rc=$RC $OUT)"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$OUT" && ok "--format json output parses as JSON" || no "json parse" "($OUT)"
fi

# ---- --write-teeth-log ------------------------------------------------------------------------------------------------
D="$(newcase wtl)"; WL="$TMP/wl"
run --repo "$D" --write-teeth-log "$WL" --base base "$TS/a.test.sh" "$TS/multi.test.sh"
{ [ "$RC" = 0 ] && [ -s "$WL/$(lname a.test.sh)" ] && has "PASS  $TS/a.test.sh -> $WL/$(lname a.test.sh)"; } && ok "--write-teeth-log runs each suite with --prove-teeth and writes <suite>.log" || no "write logs" "(rc=$RC $OUT $ERR)"
grep -q -- '-- teeth --' "$WL/$(lname a.test.sh)" && ok "the written log carries the teeth banner (it really ran with --prove-teeth)" || no "banner in written log" "$(cat "$WL/$(lname a.test.sh)")"
D_c="$(kase wtl_check $T/alpha.sh)"; run --repo "$D_c" --write-teeth-log "$TMP/wl2" --base base "$TS/a.test.sh" "$TS/multi.test.sh"; run --repo "$D_c" "${BASE[@]}" --teeth-log "$TMP/wl2"
[ "$RC" = 0 ] && ok "end to end: logs written by --write-teeth-log satisfy the check" || no "write then check" "(rc=$RC $OUT)"
printf '#!/usr/bin/env bash\necho "-- teeth --"; echo "  FAIL  boom"; echo "== 1 passed · 1 failed =="; exit 1\n' > "$D/$TS/red.test.sh"
run --repo "$D" --write-teeth-log "$TMP/wl3" --base base "$TS/red.test.sh"
{ [ "$RC" = 1 ] && ehas 'FAIL  research-sdd/toolbelt/tests/red.test.sh: exit 1'; } && ok "a failing suite -> exit 1, FAIL line, log still written" || no "failing suite" "(rc=$RC $ERR)"
printf '#!/usr/bin/env bash\nsleep 5\n' > "$D/$TS/slow.test.sh"; D_slow="$D"
KIT_WRITER_CHECK_TIMEOUT=1 run --repo "$D" --write-teeth-log "$TMP/wl4" --base base "$TS/slow.test.sh"
{ [ "$RC" = 1 ] && ehas 'timed out after 1s'; } && ok "a suite over the timeout is killed and reported (timeout, not a name kill)" || no "timeout" "(rc=$RC $ERR)"
KIT_WRITER_CHECK_TIMEOUT=abc run --repo "$D" --write-teeth-log "$TMP/wl5" --base base "$TS/a.test.sh"; { [ "$RC" = 2 ] && ehas 'KIT_WRITER_CHECK_TIMEOUT must be a positive integer'; } && ok "invalid timeout value -> degraded, exit 2" || no "bad timeout" "(rc=$RC $ERR)"
run --repo "$D" --write-teeth-log "$TMP/wl6" --base base "$TS/nope.test.sh"; { [ "$RC" = 1 ] && ehas 'suite not found'; } && ok "a missing suite is a failure, not a silent skip" || no "missing suite" "(rc=$RC $ERR)"
run --repo "$D" --write-teeth-log "$TMP/wl7" --base base "$TS/pi.test.mjs"; { [ "$RC" = 1 ] && ehas 'only *.test.sh suites take --prove-teeth'; } && ok "a non-.test.sh suite is refused" || no "mjs refused" "(rc=$RC $ERR)"
run --repo "$D" --write-teeth-log "$TMP/wl8"; { [ "$RC" = 2 ]; } && ok "--write-teeth-log without suites -> usage, exit 2" || no "no suites" "(rc=$RC)"
run --repo "$D" --write-teeth-log "$TMP/wl9" "$TS/a.test.sh"; { [ "$RC" = 2 ] && ehas 'needs --base'; } && ok "--write-teeth-log without --base -> usage, exit 2 (the binding needs a base)" || no "write needs base" "(rc=$RC $ERR)"

printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$TMP/badimpact.sh"
# ---- teeth logs are bound to what they tested (stale-teeth) ----------------------------------------------------------------
D_b="$(kase bind $T/alpha.sh)"
run --repo "$D_b" --base base --print-binding; B1="$OUT"
run --repo "$D_b" --base base --print-binding; B2="$OUT"
{ [ "$B1" = "$B2" ] && grep -qE '^# writer-check: head=[0-9a-f]{40} tree=[0-9a-f]{40}$' <<<"$B1"; } && ok "--print-binding: stable, 'head=<sha> tree=<hash>' header" || no "print-binding" "($B1 | $B2)"
D_b2="$(kase bind2 $T/beta.sh)"; run --repo "$D_b2" --base base --print-binding
[ "$OUT" != "$B1" ] && ok "the binding differs for different changed contents" || no "binding is content-blind"
run --repo "$D_b" --write-teeth-log "$TMP/wb" --base base "$TS/a.test.sh" "$TS/multi.test.sh"
[ "$(head -n 1 "$TMP/wb/$(lname a.test.sh)")" = "$B1" ] && ok "--write-teeth-log writes the binding header as the first line of the log" || no "header written" "$(head -n1 "$TMP/wb/$(lname a.test.sh)")"
run --repo "$D_b" "${BASE[@]}" --teeth-log "$TMP/wb"; [ "$RC" = 0 ] && ok "a log whose binding still matches passes" || no "fresh logs" "(rc=$RC $OUT)"
printf 'echo changed-after-the-log\n' >> "$D_b/$T/alpha.sh"; commit_all "$D_b"
run --repo "$D_b" "${BASE[@]}" --teeth-log "$TMP/wb"
{ [ "$RC" = 1 ] && hasre '^stale-teeth .*a\.test\.sh \(changed files differ' && hasre '^stale-teeth .*multi\.test\.sh'; } && ok "edit AFTER the log (committed) -> stale-teeth for every bound suite" || no "stale after edit" "(rc=$RC $OUT)"
D_b3="$(kase bind3 $T/alpha.sh)"; run --repo "$D_b3" --write-teeth-log "$TMP/wb3" --base base "$TS/a.test.sh" "$TS/multi.test.sh"
printf 'echo uncommitted-edit\n' >> "$D_b3/$T/alpha.sh"
run --repo "$D_b3" "${BASE[@]}" --worktree --teeth-log "$TMP/wb3"
{ [ "$RC" = 1 ] && hasre '^stale-teeth .*a\.test\.sh'; } && ok "edit AFTER the log (uncommitted, --worktree) -> stale-teeth" || no "stale worktree" "(rc=$RC $OUT)"
D_b4="$(kase bind4 $T/alpha.sh)"; mkdir -p "$TMP/hand"; good_log_unbound() { printf -- '-- teeth --\n== 3 passed · 0 failed ==\n' > "$1"; }
good_log_unbound "$TMP/hand/$(lname a.test.sh)"; good_log_unbound "$TMP/hand/$(lname multi.test.sh)"
run --repo "$D_b4" "${BASE[@]}" --teeth-log "$TMP/hand"
{ [ "$RC" = 1 ] && hasre '^stale-teeth .*a\.test\.sh \(no writer-check header'; } && ok "a hand-written log without the header fails as stale-teeth" || no "hand-written log" "(rc=$RC $OUT)"
printf -- '# writer-check: head=abc tree=zzz\n-- teeth --\n== 3 passed · 0 failed ==\n' > "$TMP/hand/$(lname a.test.sh)"
run --repo "$D_b4" "${BASE[@]}" --teeth-log "$TMP/hand"; hasre '^stale-teeth .*a\.test\.sh \(no writer-check header' && ok "a malformed header counts as no header" || no "malformed header" "($OUT)"
mkdir -p "$TMP/two"; run --repo "$D_b4" --write-teeth-log "$TMP/two" --base base "$TS/a.test.sh" research-sdd/install/tests/a.test.sh
{ [ "$RC" = 0 ] && [ -s "$TMP/two/research-sdd__toolbelt__tests__a.test.sh.log" ] && [ -s "$TMP/two/research-sdd__install__tests__a.test.sh.log" ]; } && ok "same basename in two corpora -> two distinct log files (repo-relative names)" || no "log name collision" "$(ls "$TMP/two")"
ABS="$D_b4/$TS/a.test.sh"; run --repo "$D_b4" --write-teeth-log "$TMP/abs" --base base "$ABS"
[ -s "$TMP/abs/$(lname a.test.sh)" ] && ok "an absolute suite path is normalised to the repo-relative log name" || no "absolute path name" "$(ls "$TMP/abs" 2>&1)"

# ---- waivers: teeth-waived, never silent --------------------------------------------------------------------------------
D_w="$(kase waive $T/top.sh)"; run --repo "$D_w" "${BASE[@]}"
{ [ "$RC" = 0 ] && hasre "^teeth-waived ${PFX}t\.test\.sh \(smoke suite with no mutation controls" && ! hasre '^missing-teeth'; } && ok "a waived required suite needs no log and is reported as teeth-waived (with its reason)" || no "waiver" "(rc=$RC $OUT)"
D_w2="$(newcase waive2)"; printf '# c\n' >> "$D_w2/$T/top.sh"; printf '# c\n' >> "$D_w2/$T/alpha.sh"; commit_all "$D_w2"; run --repo "$D_w2" "${BASE[@]}"
{ [ "$RC" = 1 ] && hasre '^teeth-waived ' && hasre '^missing-teeth .*a\.test\.sh'; } && ok "a waiver covers only the suites it names" || no "waiver scope" "(rc=$RC $OUT)"
D_w3="$(newcase waive3)"; printf 'research-sdd/toolbelt/tests/t.test.sh\n' >> "$D_w3/$TS/writer-check-waivers.txt"; printf '# c\n' >> "$D_w3/$T/top.sh"; commit_all "$D_w3"; run --repo "$D_w3" "${BASE[@]}"
hasre '^bad-waiver .*writer-check-waivers\.txt:[0-9]+ ' && ok "a waiver line without a reason is a bad-waiver finding" || no "bad waiver" "(rc=$RC $OUT)"
D_w4="$(newcase waive4)"; ( cd "$D_w4" && git rm -q "$TS/writer-check-waivers.txt" && git commit -q -m nowaivers ); printf '# c\n' >> "$D_w4/$T/top.sh"; commit_all "$D_w4"; run --repo "$D_w4" "${BASE[@]}"
{ [ "$RC" = 1 ] && hasre '^missing-teeth .*t\.test\.sh'; } && ok "no waiver file: nothing is waived (and nothing degrades)" || no "absent waivers" "(rc=$RC $OUT)"

# ---- one production-path definition, pinned by a parity list shared with parse-red-evidence.test.cjs --------------------------
PP="$HERE/fixtures/kit-writer-check/production-paths.txt"
npp=0
while IFS=$'\t' read -r verdict path; do
  case "$verdict" in production|other) ;; *) continue ;; esac
  npp=$((npp+1)); run --classify "$path"
  if [ "$OUT" = "$verdict $path" ]; then ok "classify: $verdict $path"; else no "classify: want [$verdict $path] got [$OUT]"; fi
done < "$PP"
[ "$npp" -gt 15 ] && ok "the production-path list was read ($npp lines)" || no "production-path list read $npp lines"

# ---- name-kill: the writer-check scan agrees with the hook's strict mode on one corpus --------------------------------------
CORP="$HERE/fixtures/kit-writer-check/name-kill-corpus.txt"
D_cp="$(newcase corpus)"; : > "$D_cp/$T/corpus.sh"; VERD=(); ncorp=0
while IFS=$'\t' read -r verdict cmd; do
  case "$verdict" in deny|allow) ;; *) continue ;; esac
  printf '%s\n' "$cmd" >> "$D_cp/$T/corpus.sh"; VERD+=("$verdict"); ncorp=$((ncorp+1))
done < "$CORP"
commit_all "$D_cp"; run --repo "$D_cp" "${BASE[@]}"
FLAGGED=" $(grep -oE "^name-kill ${T}/corpus\.sh:[0-9]+" <<<"$OUT" | sed -E 's/.*://' | tr '\n' ' ')"
[ "$ncorp" -gt 20 ] && ok "the name-kill corpus was read ($ncorp lines)" || no "corpus read $ncorp lines"
i=0; for v in "${VERD[@]}"; do
  i=$((i+1)); line="$(sed -n "${i}p" "$D_cp/$T/corpus.sh")"
  case "$FLAGGED" in *" $i "*) got=deny ;; *) got=allow ;; esac
  [ "$got" = "$v" ] && ok "scan parity ($v): $line" || no "scan parity: corpus says $v, scan says $got: $line"
done

# ---- degraded + usage -------------------------------------------------------------------------------------------------
run --repo "$D" --base nosuchref; { [ "$RC" = 2 ] && ehas 'bad base ref'; } && ok "bad base ref -> degraded, exit 2" || no "bad base" "(rc=$RC $ERR)"
run --repo "$D" --base base --head nosuchref; { [ "$RC" = 2 ] && ehas 'bad head ref'; } && ok "bad head ref -> degraded, exit 2" || no "bad head" "(rc=$RC $ERR)"
run --repo "$TMP" "${BASE[@]}"; { [ "$RC" = 2 ] && ehas 'not a git repository'; } && ok "not a git repository -> degraded, exit 2" || no "not a repo" "(rc=$RC $ERR)"
run --repo "$D" "${BASE[@]}" --teeth-log "$TMP/nope-dir"; { [ "$RC" = 2 ] && ehas 'teeth-log dir absent'; } && ok "absent --teeth-log dir -> degraded (absent-input is not 'no logs')" || no "absent log dir" "(rc=$RC $ERR)"
KIT_WRITER_CHECK_IMPACT="$TMP/none.sh" run --repo "$D" "${BASE[@]}"; { [ "$RC" = 2 ] && ehas 'suite-impact.sh not found'; } && ok "suite-impact.sh absent -> degraded, exit 2" || no "no impact" "(rc=$RC $ERR)"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$TMP/badimpact.sh"
KIT_WRITER_CHECK_IMPACT="$TMP/badimpact.sh" run --repo "$D" "${BASE[@]}"; { [ "$RC" = 2 ] && ehas 'suite-impact.sh exited 2: boom'; } && ok "suite-impact failing -> degraded with its message, exit 2 (never an empty requirement set)" || no "impact fails" "(rc=$RC $ERR)"
run --repo "$D"; { [ "$RC" = 2 ]; } && ok "no --base -> usage, exit 2" || no "no base" "(rc=$RC)"
run --repo "$D" "${BASE[@]}" --format xml; { [ "$RC" = 2 ]; } && ok "unknown --format -> usage, exit 2" || no "bad format" "(rc=$RC)"
run --repo "$D" "${BASE[@]}" --bogus; { [ "$RC" = 2 ]; } && ok "unknown flag -> usage, exit 2" || no "bad flag" "(rc=$RC)"
run --repo "$D" "${BASE[@]}" stray; { [ "$RC" = 2 ]; } && ok "stray positional in check mode -> usage, exit 2" || no "stray arg" "(rc=$RC)"

# =================================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # mt LABEL GOOD-RC BAD-RC SED-EXPR [tooth flags...] -- ARGV...
  mt() {
    local label="$1" grc="$2" brc="$3" expr="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  TA="$(kase t_alpha $T/alpha.sh)"
  mt "teeth banner no longer required" 1 0 's/if ! grep -qEi/if false \&\& grep -qEi/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_plain"
  mt "FAIL-line check removed" 1 0 's/if grep -qE .\^  FAIL  . "\$log"; then/if false; then/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_failline"
  mt "zero-passed check removed" 1 0 's/if \[ "\${n%% \*}" = "0" \]; then/if false; then/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_zero"
  mt "failed-summary check removed" 1 0 's/if \[ "\${n#\* }" != "0" \]; then/if false; then/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_failed"
  mt "first summary used instead of last" 0 1 's/| tail -n 1)"/| head -n 1)"/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_last"
  mt "missing log tolerated" 1 0 's/echo "missing|no log \$(basename -- "\$log")"; return; fi/return; fi/' \
    -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_missing"
  mt "empty log no longer named" 1 1 's/if \[ ! -s "\$log" \]; then echo "missing|log is empty"; return; fi//' \
    --good-has 'log is empty' --bad-lacks 'log is empty' -- "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}" --teeth-log "$TMP/logs_empty"
  mt "no-suite finding dropped" 1 0 's/if \[ "\$n" -eq 0 \]; then printf/if false; then printf/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_solo" "${BASE[@]}"
  mt "changed suites no longer required" 1 0 's/^cat "\$TMP\/chsuites" >> "\$TMP\/req"$/:/' \
    -- "$BASH_BIN" @SUT@ --repo "$D3" "${BASE[@]}"
  mt "rename resolves to the old path" 1 1 's/R\*|C\*) p="\$b"/R*|C*) p="$a"/' \
    --good-has 'no-suite research-sdd/toolbelt/beta2.sh' --bad-lacks 'beta2.sh' -- "$BASH_BIN" @SUT@ --repo "$D_ren" "${BASE[@]}"
  mt "FULL note dropped" 0 0 's/if \[ -n "\$FULL_REASON" \]; then printf/if false; then printf/' \
    --good-has 'full-gate-needed' --bad-lacks 'full-gate-needed' -- "$BASH_BIN" @SUT@ --repo "$D_lib" "${BASE[@]}"
  mt "required: 0 note dropped" 0 0 's/if \[ "\$NREQ" -eq 0 \]; then/if false; then/' \
    --good-has 'required: 0' --bad-lacks 'required: 0' -- "$BASH_BIN" @SUT@ --repo "$D_doc" "${BASE[@]}"
  mt "suite-impact failure ignored" 2 1 's/if \[ "\$irc" -ne 0 \]; then/if false; then/' \
    --good-has 'suite-impact.sh exited 2' --bad-lacks 'suite-impact.sh exited' -- env "KIT_WRITER_CHECK_IMPACT=$TMP/badimpact.sh" "$BASH_BIN" @SUT@ --repo "$TA" "${BASE[@]}"
  mt "name-kill pattern dead" 1 0 's/\[p\]kill|\[k\]illall/ZZZ/' -- "$BASH_BIN" @SUT@ --repo "$D_nk1" "${BASE[@]}" --teeth-log "$(lg "$D_nk1")"
  mt "kill -1 pattern dead" 1 0 's/\[k\]ill\[\[:space:\]\]+(-/[k]illZ[[:space:]]+(-/' -- "$BASH_BIN" @SUT@ --repo "$D_nk2" "${BASE[@]}" --teeth-log "$(lg "$D_nk2")"  # writer-check: allow-name-kill label text, never executed
  mt "pgrep-xargs pattern dead" 1 0 's/(xargs|while)\[^&\]\*/(xargsZ)[^\&]*/' -- "$BASH_BIN" @SUT@ --repo "$D_nk3" "${BASE[@]}" --teeth-log "$(lg "$D_nk3")"
  mt "kill-subst pattern dead" 1 0 's/\[k\]ill\[^;|&\]\*/ZZ/' -- "$BASH_BIN" @SUT@ --repo "$D_nk4" "${BASE[@]}" --teeth-log "$(lg "$D_nk4")"
  mt "allow comment ignored" 0 1 's/if (line ~ \/writer-check:/if (0 \&\& line ~ \/writer-check:/' -- "$BASH_BIN" @SUT@ --repo "$D_nk5" "${BASE[@]}" --teeth-log "$(lg "$D_nk5")"
  mt "comment-line skip removed" 0 1 's@if (line ~ /^\[\[:space:\]\]\*(#|\\/\\/)/) next@if (0) next@' -- "$BASH_BIN" @SUT@ --repo "$D_nk6" "${BASE[@]}" --teeth-log "$(lg "$D_nk6")"
  mt "non-code files scanned" 0 1 's@scan = (f ~ /\\.(sh|bash|py|mjs|cjs|js|ts)\$/)@scan = 1@' -- "$BASH_BIN" @SUT@ --repo "$D_nk7" "${BASE[@]}" --teeth-log "$(lg "$D_nk7")"
  mt "FULL uses the whole closure instead of direct suites" 1 1 's/^  if \[ -n "\$FULL_REASON" \]; then$/  if false; then/' \
    --good-lacks '/t[.]test[.]sh' --bad-has '/t[.]test[.]sh' -- "$BASH_BIN" @SUT@ --repo "$D_fd" "${BASE[@]}"
  mt "FULL fallback to the map removed" 1 1 's/^  if \[ "\$n" -eq 0 \]; then$/  if false; then/' \
    --good-lacks '^no-suite' --bad-has '^no-suite' -- "$BASH_BIN" @SUT@ --repo "$D_fl" "${BASE[@]}"
  mt "command-position rule dropped (prose trips)" 0 1 's/cmd = pre opt /cmd = "[ ]" /' \
    -- "$BASH_BIN" @SUT@ --repo "$D_str2" "${BASE[@]}" --teeth-log "$(lg "$D_str2")"
  mt "separator & no longer a command position" 1 0 's/\[;&|(/[;|(/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_cp1" "${BASE[@]}" --teeth-log "$(lg "$D_cp1")"
  mt "python argv-list form dropped" 1 1 's/(script && (line ~ argv || line ~ call))/(script \&\& line ~ call)/' \
    --good-has '^name-kill' --bad-lacks '^name-kill' -- "$BASH_BIN" @SUT@ --repo "$D_pyl" "${BASE[@]}" --teeth-log "$(lg "$D_pyl")"
  mt "binding comparison removed" 1 0 's/if \[ "\${first##\* tree=}" != "\${BIND_HDR##\* tree=}" \]; then/if false; then/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_b" "${BASE[@]}" --teeth-log "$TMP/wb"
  mt "header requirement removed" 1 1 's/if ! grep -qE .\^# writer-check: head=\[0-9a-f\]+ tree=\[0-9a-f\]{40}\$. <<<"\$first"; then/if false; then/' \
    --good-has 'no writer-check header' --bad-lacks 'no writer-check header' -- "$BASH_BIN" @SUT@ --repo "$D_b4" "${BASE[@]}" --teeth-log "$TMP/hand"
  mt "waiver no longer applied" 0 1 's/if \[ -n "\$wr" \]; then printf/if false; then printf/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_w" "${BASE[@]}"
  mt "reason-less waiver accepted" 1 0 's/\[ -z "\$wreason" \]/false/' \
    --good-has '^bad-waiver' --bad-lacks '^bad-waiver' -- "$BASH_BIN" @SUT@ --repo "$D_w3" "${BASE[@]}"
  mt "tests/lib no longer production" 0 0 's#research-sdd/toolbelt/tests/lib/\*) ;;#research-sdd/toolbelt/tests/lib/*) return 1 ;;#' \
    --good-has '^production ' --bad-lacks '^production ' -- "$BASH_BIN" @SUT@ --classify research-sdd/toolbelt/tests/lib/mutant.sh
  mt "install/tests counted as production" 0 0 's#^    research-sdd/install/tests/\*) return 1 ;;##' \
    --good-has '^other ' --bad-lacks '^other ' -- "$BASH_BIN" @SUT@ --classify research-sdd/install/tests/helper.sh
  mt "templates no longer production" 0 0 's#|research-sdd/templates/\*) ;;#) ;;#' \
    --good-has '^production ' --bad-lacks '^production ' -- "$BASH_BIN" @SUT@ --classify research-sdd/templates/hook-kit-run.sh
  mt "extension filter narrowed" 0 0 's#\*\.sh|\*\.py|\*\.mjs|\*\.js|\*\.cjs|\*\.ts) return 0#*.sh) return 0#' \
    --good-has '^production ' --bad-lacks '^production ' -- "$BASH_BIN" @SUT@ --classify research-sdd/toolbelt/x.ts
  mt "pidof not scanned" 1 0 's/pipekill = "(\[p\]grep|\[p\]idof)/pipekill = "([p]grep)/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_nk8" "${BASE[@]}" --teeth-log "$(lg "$D_nk8")"
  mt "hunk line numbering off by one" 1 1 's/ln=a\[1\]+0; next/ln=a[1]+1; next/' \
    --good-has ':9 ' --bad-lacks ':9 ' -- "$BASH_BIN" @SUT@ --repo "$D_hunk" --base base2
  mt "timeout wrapper removed" 1 0 's/timeout "\$T_OUT" bash "\$sp"/bash "$sp"/' \
    -- env KIT_WRITER_CHECK_TIMEOUT=1 "$BASH_BIN" @SUT@ --repo "$D_slow" --write-teeth-log "$TMP/wlt" --base base "$TS/slow.test.sh"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
