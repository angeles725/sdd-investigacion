#!/usr/bin/env bash
# suite-impact.test.sh — suite for suite-impact.sh (kit issue #2201, part 1a). Every case runs the instrument against a
# small fixture git repo built under $TMPDIR (never inside the live tree): pristine repo once, a cheap clone per case.
#
# Covered: literal-SUT, $TOOLBELT/x and python-wrapper mapping, a lib closure with a CYCLE, python import edges,
# fixture-dir (and top-level fixture file) mapping, always-run and blind-spot inclusion, docs-only, no-change,
# every escalation class (harness, install, templates, CI, shellcheckrc, add/delete/rename, unmapped production
# file, unmapped fixture, named wide lib, wide closure, unclassified path), list edges (first, last, single,
# last-line-without-newline, .mjs and install-corpus suites), --worktree, degraded states (bad ref, not a repo, absent
# manifest), strict manifests (no reason, unknown suite, duplicate), --audit (clean, new eval suite, new kit-copy suite).
#
# Usage: suite-impact.test.sh                (run the suite)
#        suite-impact.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 every assertion held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${SUITE_IMPACT_SUT:-$HERE/suite-impact.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
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

# hermetic git: no user/system config, fixed identity
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset SUITE_IMPACT_WIDE_THRESHOLD

T=research-sdd/toolbelt
TS=$T/tests
PFX="research-sdd/toolbelt/tests/"
OUT=""; ERR=""; RC=0
run() { OUT="$("$BASH_BIN" "$SUT" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
has()  { grep -qxF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }
ehas() { grep -qF -- "$1" <<<"$ERR"; }
sel_has() { has "$PFX$1"; }
nsel() { grep -c . <<<"$OUT"; }

# ---- the pristine fixture repo -------------------------------------------------------------------------------
P="$TMP/pristine"; mkdir -p "$P"
w() { mkdir -p "$(dirname "$P/$1")"; cat > "$P/$1"; }       # w PATH  (body on stdin)
w $TS/aaa-first.test.sh <<'EOF'
SUT="$HERE/../alpha.sh"
EOF
w $TS/b.test.sh <<'EOF'
"$TOOLBELT/beta.sh" --x
EOF
printf '#!/usr/bin/env bash\nset -u\npython3 "$TB/wrap.sh"' > "$P/$TS/c.test.sh"            # last line, NO trailing newline
w $TS/d.test.sh <<'EOF'
"$TB/alpha2.sh"
EOF
w $TS/e.test.sh <<'EOF'
cp -r "$HERE/fixtures/e-data" "$T"
EOF
w $TS/f.test.sh <<'EOF'
cat "$HERE/fixtures/topfile.json"
EOF
w $TS/h.test.sh <<'EOF'
python3 "$TB/usesimp.py"
EOF
w $TS/lint-always.test.sh <<'EOF'
echo whole-tree lint
EOF
w $TS/evalish.test.sh <<'EOF'
eval "$cmd"
EOF
w $TS/zzz-last.test.sh <<'EOF'
"$TB/zeta.sh"
EOF
w $TS/hooks.test.sh <<'EOF'
. "$TB/lib/hook-emit.sh"
EOF
w $TS/wsuite.test.sh <<'EOF'
"$TB/w1.sh" "$TB/w2.sh" "$TB/w3.sh"
EOF
w $TS/pi.test.mjs <<'EOF'
import x from "../adv.mjs";
EOF
w research-sdd/install/tests/inst.test.sh <<'EOF'
"$TB/instref.sh"
EOF
w $TS/fixtures/e-data/x.txt <<'EOF'
data
EOF
w $TS/fixtures/topfile.json <<'EOF'
{}
EOF
w $TS/fixtures/orphan-data/y.txt <<'EOF'
nobody reads me
EOF
w $TS/impact-always.txt <<'EOF'
# fixture
lint-always whole-tree lint
EOF
w $TS/impact-blindspot.txt <<'EOF'
# fixture
evalish builds a command and evals it
EOF
w $TS/lib/mutant.sh <<'EOF'
:
EOF
w $TS/run-all.sh <<'EOF'
:
EOF
w $TS/shard-join.sh <<'EOF'
:
EOF
w $TS/teeth-helper-waivers.txt <<'EOF'
# w
EOF
w $TS/suite-impact.sh <<'EOF'
:
EOF
w $T/alpha.sh <<'EOF'
echo alpha
EOF
w $T/alpha2.sh <<'EOF'
. "$LIB/ll1.sh"
EOF
w $T/lib/ll1.sh <<'EOF'
. "$LIB/ll2.sh"
EOF
w $T/lib/ll2.sh <<'EOF'
. "$LIB/ll1.sh"
EOF
w $T/lib/hook-emit.sh <<'EOF'
echo hook
EOF
w $T/beta.sh <<'EOF'
echo beta
EOF
w $T/wrap.sh <<'EOF'
python3 "$HERE/gamma.py" "$@"
EOF
w $T/gamma.py <<'EOF'
print(1)
EOF
w $T/usesimp.py <<'EOF'
from gamma import x
EOF
w $T/adv.mjs <<'EOF'
export default 1;
EOF
w $T/zeta.sh <<'EOF'
echo zeta
EOF
w $T/instref.sh <<'EOF'
echo i
EOF
w $T/solo.sh <<'EOF'
echo nobody tests me
EOF
w $T/wide.sh <<'EOF'
echo wide
EOF
for i in 1 2 3; do w $T/w$i.sh <<'EOF'
"$TB/wide.sh"
EOF
done
w $T/notes.md <<'EOF'
# notes
EOF
# --- review round 1: dotted python imports, suites running suites, deleted docs/fixtures, dotfiles, .mjs install suite
w $T/lib/profile_mod.py <<'EOF'
VALUE = 1
EOF
w $T/lib/sibling_mod.py <<'EOF'
VALUE = 2
EOF
w $T/user_dotted.py <<'EOF'
from lib.profile_mod import VALUE
from lib import sibling_mod, zzz_absent
EOF
w $TS/dotted.test.sh <<'EOF'
python3 "$TB/user_dotted.py"
EOF
w $TS/runner.test.sh <<'EOF'
bash "$HERE/b.test.sh"
EOF
w $TS/docref.test.sh <<'EOF'
grep -q x "$TB/notes.md"
EOF
w $T/.dotrc <<'EOF'
dot=1
EOF
w $TS/dot.test.sh <<'EOF'
cat "$TB/.dotrc"
EOF
w research-sdd/profiles/p.json <<'EOF'
{}
EOF
w $TS/prof.test.sh <<'EOF'
cat "$KIT/profiles/p.json"
EOF
w research-sdd/install/tests/inst2.test.mjs <<'EOF'
import { x } from "../../toolbelt/instref.sh";
EOF
w research-sdd/install/adapters.sh <<'EOF'
echo i
EOF
w research-sdd/templates/t.template.md <<'EOF'
# t
EOF
w .github/workflows/ci.yml <<'EOF'
name: ci
EOF
w README.md <<'EOF'
# readme
EOF
w .gitignore <<'EOF'
tmp
EOF
( cd "$P" && git init -q -b main . && git add -A && git commit -q -m base && git tag base ) || { echo "FATAL: fixture repo" >&2; exit 2; }
NSUITES_FIX="$(cd "$P" && git ls-files | grep -cE '/tests/[^/]*\.test\.(sh|mjs)$')"

# newcase NAME -> clone of the pristine repo at $TMP/NAME
newcase() { git clone -q "$P" "$TMP/$1" 2>/dev/null && printf '%s' "$TMP/$1"; }
# commit_all DIR  (stage everything, commit)
commit_all() { ( cd "$1" && git add -A && git commit -q -m change ); }
# mod DIR PATH  — append a line to an existing file
mod() { printf '# changed\n' >> "$1/$2"; }
# kase NAME FILE... — clone, modify the files, commit; prints the dir
kase() { local n="$1" d; shift; d="$(newcase "$n")" || return 1; for f in "$@"; do mod "$d" "$f"; done; commit_all "$d"; printf '%s' "$d"; }

echo "== suite-impact.test.sh (SUT: $(basename "$SUT")) =="

# ---- mapping --------------------------------------------------------------------------------------------------
D_lit="$(kase lit $T/alpha.sh)"
run --repo "$D_lit" --base base --format list
{ [ "$RC" = 0 ] && sel_has aaa-first.test.sh; } && ok "literal SUT=\"\$HERE/../x.sh\" maps (first suite in sort order)" || no "literal SUT mapping" "(rc=$RC $OUT)"
sel_has b.test.sh && no "alpha change must not select the beta suite" "($OUT)" || ok "alpha change leaves the beta suite out"
sel_has lint-always.test.sh && ok "always-run suite is in every selection" || no "always-run missing" "($OUT)"
sel_has evalish.test.sh && ok "blind-spot suite is added when production code changes" || no "blind-spot missing" "($OUT)"
[ "$(nsel)" = 3 ] && ok "selection is exactly mapped + always + blind (3 of $NSUITES_FIX)" || no "selection size" "($(nsel): $OUT)"

D_tb="$(kase tb $T/beta.sh)"; run --repo "$D_tb" --base base --format list
sel_has b.test.sh && ok "\$TOOLBELT/x.sh mapping" || no "\$TOOLBELT mapping" "($OUT)"

D_py="$(kase py $T/gamma.py)"; run --repo "$D_py" --base base --format list
{ sel_has c.test.sh; } && ok "python wrapper mapping (suite -> wrap.sh -> gamma.py), last line without newline" || no "wrapper mapping" "($OUT)"
sel_has h.test.sh && ok "python import edge (from gamma import) maps" || no "import edge" "($OUT)"

D_cy="$(kase cy $T/lib/ll2.sh)"; run --repo "$D_cy" --base base --format list
{ [ "$RC" = 0 ] && sel_has d.test.sh; } && ok "lib closure through a CYCLE terminates and maps (ll2 -> ll1 -> alpha2 -> suite)" || no "cycle closure" "(rc=$RC $OUT)"
D_cy1="$(kase cy1 $T/lib/ll1.sh)"; run --repo "$D_cy1" --base base --format list
{ [ "$RC" = 0 ] && sel_has d.test.sh; } && ok "the other node of the cycle maps too" || no "cycle other node" "(rc=$RC $OUT)"

D_fx="$(kase fx $TS/fixtures/e-data/x.txt)"; run --repo "$D_fx" --base base --format list
{ sel_has e.test.sh && ! sel_has f.test.sh; } && ok "fixture-dir file maps to the suite naming the dir only" || no "fixture dir mapping" "($OUT)"
D_fxt="$(kase fxt $TS/fixtures/topfile.json)"; run --repo "$D_fxt" --base base --format list
sel_has f.test.sh && ok "top-level fixture file maps by basename" || no "top-level fixture mapping" "($OUT)"

D_last="$(kase last $T/zeta.sh)"; run --repo "$D_last" --base base --format list
{ sel_has zzz-last.test.sh && [ "$(nsel)" = 3 ]; } && ok "LAST suite in sort order is selected (single mapped suite)" || no "last-suite edge" "($(nsel): $OUT)"
D_mjs="$(kase mjs $T/adv.mjs)"; run --repo "$D_mjs" --base base --format list
sel_has pi.test.mjs && ok ".test.mjs suite maps" || no "mjs suite" "($OUT)"
D_inst="$(kase inst $T/instref.sh)"; run --repo "$D_inst" --base base --format list
has research-sdd/install/tests/inst.test.sh && ok "install-corpus suite maps" || no "install suite" "($OUT)"

D_sc="$(kase sc $TS/aaa-first.test.sh)"; run --repo "$D_sc" --base base --format list
{ sel_has aaa-first.test.sh && ! sel_has evalish.test.sh && ! sel_has b.test.sh; } && ok "a changed suite selects itself (no production change: no blind-spot)" || no "changed suite" "($OUT)"
D_new="$(newcase newsuite)"; printf 'echo n\n' > "$D_new/$TS/brandnew.test.sh"; commit_all "$D_new"
run --repo "$D_new" --base base --format list
{ [ "$RC" = 0 ] && sel_has brandnew.test.sh && ! hasre 'Escalated'; } && ok "an ADDED suite selects itself without escalating" || no "added suite" "(rc=$RC $OUT)"
D_dsuite="$(newcase delsuite)"; ( cd "$D_dsuite" && git rm -q $TS/e.test.sh && git commit -q -m d )
run --repo "$D_dsuite" --base base --format list
{ [ "$RC" = 0 ] && ! sel_has e.test.sh && sel_has lint-always.test.sh; } && ok "a DELETED suite is not selected, run still succeeds" || no "deleted suite" "(rc=$RC $OUT)"

# ---- review round 1 ---------------------------------------------------------------------------------------------
D_dot="$(kase dotted $T/lib/profile_mod.py)"; run --repo "$D_dot" --base base
{ [ "$RC" = 0 ] && sel_has dotted.test.sh && has "Escalated: no"; } && ok "dotted import 'from lib.profile_mod import' yields an edge (lib/profile_mod.py -> user_dotted.py -> suite)" || no "dotted import" "(rc=$RC $OUT)"
D_dot2="$(kase dotted2 $T/lib/sibling_mod.py)"; run --repo "$D_dot2" --base base
{ sel_has dotted.test.sh && has "Escalated: no"; } && ok "'from lib import sibling_mod, zzz_absent': each imported name that exists is an edge" || no "from-import names" "($OUT)"
D_sr="$(kase suiterun $T/beta.sh)"; run --repo "$D_sr" --base base
{ sel_has b.test.sh && sel_has runner.test.sh && has "Escalated: no"; } && ok "a suite that RUNS another suite is selected with it (suite -> suite edge)" || no "suite runs suite" "($OUT)"
D_sr2="$(kase suiterun2 $TS/b.test.sh)"; run --repo "$D_sr2" --base base
{ sel_has b.test.sh && sel_has runner.test.sh && has "Escalated: no"; } && ok "changing the inner suite selects the suite that runs it" || no "inner suite changed" "($OUT)"
D_mdel="$(newcase mddel)"; ( cd "$D_mdel" && git rm -q $T/notes.md && git commit -q -m d ); run --repo "$D_mdel" --base base
{ [ "$RC" = 0 ] && sel_has docref.test.sh && has "Escalated: no"; } && ok "a DELETED markdown file selects the suites naming its old basename" || no "deleted md" "(rc=$RC $OUT)"
D_mren="$(newcase mdren)"; ( cd "$D_mren" && git mv $T/notes.md $T/renamed.md && git commit -q -m r ); run --repo "$D_mren" --base base
{ [ "$RC" = 0 ] && sel_has docref.test.sh && has "Escalated: no"; } && ok "a RENAMED markdown file selects the suites naming the old basename" || no "renamed md" "(rc=$RC $OUT)"
D="$(newcase fxdel)"; ( cd "$D" && git rm -rq $TS/fixtures/e-data && git commit -q -m d )
run --repo "$D" --base base
hasre '^Escalated to FULL: deleted fixture dir: e-data' && ok "FULL: a deleted fixture dir (nothing left to map from)" || no "deleted fixture dir" "(rc=$RC $OUT)"
D_fxdel="$D"
D_dotf="$(kase dotfile $T/.dotrc)"; run --repo "$D_dotf" --base base
{ sel_has dot.test.sh && has "Escalated: no"; } && ok "a dotfile production file is reachable by its dotted basename" || no "dotfile" "($OUT)"
D_kc="$(kase kitcontent research-sdd/profiles/p.json)"; run --repo "$D_kc" --base base
{ sel_has prof.test.sh && sel_has evalish.test.sh && has "Escalated: no"; } && ok "non-markdown kit content outside toolbelt maps AND triggers the blind-spot set" || no "kit content" "($OUT)"
D_im="$(kase instmjs $T/instref.sh)"; run --repo "$D_im" --base base
{ has research-sdd/install/tests/inst2.test.mjs && has "Escalated: no"; } && ok "install/tests/*.test.mjs is a suite" || no "install mjs suite" "($OUT)"

# ---- docs-only / no-change ----------------------------------------------------------------------------------
D_doc="$(newcase docs)"; mod "$D_doc" README.md; mkdir -p "$D_doc/openspec" "$D_doc/odd"; echo x > "$D_doc/openspec/s.md"; echo y > "$D_doc/odd/t.md"; commit_all "$D_doc"
run --repo "$D_doc" --base base --format list
{ [ "$RC" = 0 ] && [ "$(nsel)" = 1 ] && sel_has lint-always.test.sh; } && ok "docs-only selects ONLY the always-run set (never empty)" || no "docs-only list" "($(nsel): $OUT)"
run --repo "$D_doc" --base base
{ hasre '^docs-only' && has "Escalated: no"; } && ok "docs-only is named in the report" || no "docs-only report" "($OUT)"
D_docj="$(newcase docsj)"; mkdir -p "$D_docj/openspec" "$D_docj/odd"; echo x > "$D_docj/openspec/data.json"; echo y > "$D_docj/odd/t.txt"; commit_all "$D_docj"
run --repo "$D_docj" --base base --format list
{ [ "$RC" = 0 ] && [ "$(nsel)" = 1 ]; } && ok "openspec/** and odd/** are docs-only whatever the extension" || no "openspec/odd non-md" "($(nsel): $OUT)"
D_dm="$(kase docsmd $T/notes.md)"; run --repo "$D_dm" --base base --format list
{ [ "$RC" = 0 ] && ! sel_has evalish.test.sh; } && ok "a toolbelt markdown change does not trigger the blind-spot set" || no "md blind-spot" "($OUT)"
run --repo "$D_lit" --base HEAD --head HEAD
{ [ "$RC" = 0 ] && hasre '^no-change' && hasre '^Impacted: 1 of '; } && ok "no-change: empty diff selects the always-run set and says so" || no "no-change" "(rc=$RC $OUT)"

# ---- escalation classes -----------------------------------------------------------------------------------------
escalated() {   # escalated LABEL DIR REASON-REGEX
  local label="$1" d="$2" re="$3"
  run --repo "$d" --base base
  if [ "$RC" = 0 ] && grep -qE "^Escalated to FULL: $re" <<<"$OUT" && grep -qE "^Impacted: $NSUITES_FIX of $NSUITES_FIX suites$" <<<"$OUT"; then
    run --repo "$d" --base base --format list
    [ "$(nsel)" = "$NSUITES_FIX" ] && ok "FULL: $label" || no "FULL list size: $label" "($(nsel) of $NSUITES_FIX)"
  else no "FULL: $label" "(rc=$RC $OUT)"; fi
}
D="$(kase e_lib $TS/lib/mutant.sh)";           escalated "tests/lib/**" "$D" 'harness file changed'
D="$(kase e_runall $TS/run-all.sh)";           escalated "tests/run-all.sh" "$D" 'harness file changed'
D="$(kase e_shard $TS/shard-join.sh)";         escalated "tests/shard-join.sh" "$D" 'harness file changed'
D="$(kase e_waive $TS/teeth-helper-waivers.txt)"; escalated "teeth-helper-waivers.txt" "$D" 'harness file changed'
D="$(kase e_impact $TS/impact-always.txt)";    escalated "impact-*.txt itself" "$D" 'harness file changed'
D="$(kase e_self $TS/suite-impact.sh)";        escalated "suite-impact.sh itself" "$D" 'harness file changed'
D="$(newcase e_tiers)"; echo t > "$D/$TS/suite-tiers.txt"; commit_all "$D"; escalated "tests/suite-tiers.txt" "$D" 'harness file changed'
D="$(kase e_inst research-sdd/install/adapters.sh)"; escalated "install/**" "$D" 'install tree changed'
D="$(kase e_tpl research-sdd/templates/t.template.md)"; escalated "templates/**" "$D" 'templates changed'
D="$(kase e_gh .github/workflows/ci.yml)";     escalated ".github/**" "$D" 'CI configuration changed'
D="$(newcase e_shellcheckrc)"; echo 'disable=SC1' > "$D/$T/.shellcheckrc"; commit_all "$D"; escalated ".shellcheckrc" "$D" 'shellcheck configuration changed'

D="$(newcase e_add)"; echo 'echo new' > "$D/$T/newprod.sh"; commit_all "$D";                    escalated "added production file" "$D" 'added production file'
D="$(newcase e_del)"; ( cd "$D" && git rm -q $T/beta.sh && git commit -q -m d );               escalated "deleted production file" "$D" 'deleted/renamed production file'
D="$(newcase e_ren)"; ( cd "$D" && git mv $T/alpha.sh $T/alpha-new.sh && git commit -q -m r ); escalated "renamed production file" "$D" '(added|deleted/renamed) production file'
D="$(kase e_unmapped $T/solo.sh)";            escalated "production file no suite reaches" "$D" 'no suite reaches the changed file: research-sdd/toolbelt/solo.sh'
D="$(kase e_unfix $TS/fixtures/orphan-data/y.txt)"; escalated "fixture dir no suite names" "$D" 'no suite reaches the changed file'
D="$(kase e_named $T/lib/hook-emit.sh)";      escalated "named widely used lib (1 suite reaches it)" "$D" 'widely used library changed'
D="$(kase e_unclass .gitignore)";             escalated "unclassified path (.gitignore)" "$D" 'unclassified path'
D="$(kase wide $T/wide.sh)"
run --repo "$D" --base base --format list
{ [ "$RC" = 0 ] && sel_has wsuite.test.sh && ! hasre 'Escalated'; } && ok "closure under the threshold maps normally (default 12)" || no "wide, default threshold" "(rc=$RC $OUT)"
OUT="$(SUITE_IMPACT_WIDE_THRESHOLD=2 "$BASH_BIN" "$SUT" --repo "$D" --base base 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && hasre '^Escalated to FULL: widely used: research-sdd/toolbelt/wide.sh is reached through 4 '; } && ok "closure over the threshold escalates and names the node count" || no "wide, threshold 2" "(rc=$RC $OUT)"

# ---- report shape ---------------------------------------------------------------------------------------------
run --repo "$D_lit" --base base
{ hasre '^Impacted: 3 of '"$NSUITES_FIX"' suites$' && has "$T/alpha.sh → ${PFX}aaa-first.test.sh" && hasre '^Always-run: 1$' && hasre '^Blind-spot: 1 added' && has "Escalated: no" && has "Selected:"; } \
  && ok "report: Impacted line, '<changed> → <suite>', always/blind counts, verdict, Selected" || no "report shape" "($OUT)"
run --repo "$D_doc" --base base
hasre '^Blind-spot: 0 \(not triggered\)' && ok "report: blind-spot not triggered by docs" || no "blind-spot report" "($OUT)"

# ---- --worktree ----------------------------------------------------------------------------------------------------
D_wt="$(newcase wt)"; mod "$D_wt" $T/alpha.sh
run --repo "$D_wt" --base base --worktree --format list
{ [ "$RC" = 0 ] && sel_has aaa-first.test.sh; } && ok "--worktree sees an uncommitted modification" || no "worktree modification" "(rc=$RC $OUT)"
echo 'echo u' > "$D_wt/$T/untracked.sh"
run --repo "$D_wt" --base base --worktree
hasre '^Escalated to FULL: added production file: research-sdd/toolbelt/untracked.sh' && ok "--worktree: an UNTRACKED new production file escalates" || no "worktree untracked" "($OUT)"
run --repo "$D_lit" --base base --worktree --format list
{ [ "$RC" = 0 ] && sel_has aaa-first.test.sh; } && ok "--worktree also includes committed changes" || no "worktree committed" "($OUT)"

# ---- degraded / usage -------------------------------------------------------------------------------------------------
run --repo "$D_lit" --base nosuchref
{ [ "$RC" = 2 ] && ehas 'degraded: suite-impact: bad base ref: nosuchref' && [ -z "$OUT" ]; } && ok "bad base ref -> typed degraded, exit 2, nothing on stdout" || no "bad base ref" "(rc=$RC $ERR)"
run --repo "$D_lit" --base base --head nosuchref
{ [ "$RC" = 2 ] && ehas 'degraded: suite-impact: bad head ref: nosuchref'; } && ok "bad head ref -> typed degraded, exit 2" || no "bad head ref" "(rc=$RC $ERR)"
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
run --repo "$NOREPO" --base base
{ [ "$RC" = 2 ] && ehas 'degraded: suite-impact: not a git repository'; } && ok "not a git repository -> typed degraded, exit 2" || no "not a repo" "(rc=$RC $ERR)"
D_nom="$(newcase nomanifest)"; ( cd "$D_nom" && git rm -q $TS/impact-always.txt && git commit -q -m x )
run --repo "$D_nom" --base base
{ [ "$RC" = 2 ] && ehas 'degraded: suite-impact: manifest absent'; } && ok "absent always-run manifest -> typed degraded, exit 2 (never a quiet empty set)" || no "absent manifest" "(rc=$RC $ERR)"
for bad in abc 0 -3 ''; do
  OUT="$(SUITE_IMPACT_WIDE_THRESHOLD="$bad" "$BASH_BIN" "$SUT" --repo "$D_lit" --base base 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
  { [ "$RC" = 2 ] && ehas 'degraded: suite-impact: SUITE_IMPACT_WIDE_THRESHOLD'; } && ok "SUITE_IMPACT_WIDE_THRESHOLD='$bad' -> typed degraded, exit 2" || no "threshold '$bad'" "(rc=$RC $ERR)"
done
OUT="$(SUITE_IMPACT_WIDE_THRESHOLD=7 "$BASH_BIN" "$SUT" --repo "$D_lit" --base base 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a positive integer threshold is accepted" || no "threshold 7" "(rc=$RC $OUT)"
run --repo "$D_lit" --base base --worktree --head HEAD
{ [ "$RC" = 2 ] && ehas usage; } && ok "--worktree together with --head -> usage error, exit 2" || no "worktree+head" "(rc=$RC $ERR)"
run
{ [ "$RC" = 2 ] && ehas usage; } && ok "no arguments -> usage, exit 2" || no "no args" "(rc=$RC $ERR)"
run --base base --bogus
{ [ "$RC" = 2 ] && ehas 'unknown argument: --bogus'; } && ok "unknown flag -> exit 2" || no "unknown flag" "(rc=$RC $ERR)"
run --repo "$D_lit" --base base --format xml
{ [ "$RC" = 2 ] && ehas '--format must be list or report'; } && ok "bad --format -> exit 2" || no "bad format" "(rc=$RC $ERR)"

# ---- strict manifests ---------------------------------------------------------------------------------------------------
mkbad() {   # mkbad NAME FILE LINE -> a repo whose HEAD tree has the extra manifest line
  local d; d="$(newcase "$1")"; printf '%s\n' "$3" >> "$d/$TS/$2"; commit_all "$d"; printf '%s' "$d"
}
D="$(mkbad m_noreason impact-always.txt 'evalish')"
run --repo "$D" --base base
{ [ "$RC" = 1 ] && ehas 'no reason: evalish' && [ -z "$OUT" ]; } && ok "manifest line without a reason -> exit 1, no selection printed" || no "manifest no reason" "(rc=$RC $ERR)"
D="$(mkbad m_ghost impact-always.txt 'ghost-suite because')"
run --repo "$D" --base base
{ [ "$RC" = 1 ] && ehas 'names no existing suite: ghost-suite'; } && ok "manifest line naming no existing suite -> exit 1" || no "manifest ghost" "(rc=$RC $ERR)"
run --repo "$D" --base base --tolerate-stale-manifest
[ "$RC" = 0 ] && ok "--tolerate-stale-manifest accepts the stale name (replay only)" || no "tolerate stale" "(rc=$RC $ERR)"
D="$(mkbad m_dup impact-always.txt 'lint-always again')"
run --repo "$D" --base base
{ [ "$RC" = 1 ] && ehas 'duplicate suite: lint-always'; } && ok "manifest duplicate -> exit 1" || no "manifest duplicate" "(rc=$RC $ERR)"
D="$(mkbad m_blind impact-blindspot.txt 'ghost2 because')"
run --repo "$D" --base base
{ [ "$RC" = 1 ] && ehas 'impact-blindspot.txt'; } && ok "the blind-spot manifest is validated the same way" || no "blind manifest" "(rc=$RC $ERR)"

# ---- --audit -----------------------------------------------------------------------------------------------------------------
run --repo "$P" --audit
{ [ "$RC" = 0 ] && hasre 'missing from impact-blindspot.txt: 0;'; } && ok "--audit: clean fixture, exit 0" || no "audit clean" "(rc=$RC $OUT $ERR)"
D_ae="$(newcase audit_eval)"; printf 'eval "$x"\n' > "$D_ae/$TS/neweval.test.sh"; ( cd "$D_ae" && git add -A && git commit -q -m a )
run --repo "$D_ae" --audit
{ [ "$RC" = 1 ] && hasre '^AUDIT missing from impact-blindspot.txt: .*neweval.test.sh \(eval\)'; } && ok "--audit: a NEW eval suite not in the manifest is reported, exit 1" || no "audit eval" "(rc=$RC $OUT)"
D_ak="$(newcase audit_cp)"; printf 'cp -R "$TB"/. "$T/kit"\n' > "$D_ak/$TS/newcopy.test.sh"; ( cd "$D_ak" && git add -A && git commit -q -m a )
run --repo "$D_ak" --audit
{ [ "$RC" = 1 ] && hasre '^AUDIT missing from impact-blindspot.txt: .*newcopy.test.sh \(kit-copy\)'; } && ok "--audit: a NEW whole-kit copy suite is reported, exit 1" || no "audit kit-copy" "(rc=$RC $OUT)"
D_ad="$(newcase audit_dyn)"; printf 'for n in a b; do bash "$HERE/$n.test.sh"; done\n' > "$D_ad/$TS/dynrun.test.sh"; ( cd "$D_ad" && git add -A && git commit -q -m a )
run --repo "$D_ad" --audit
{ [ "$RC" = 1 ] && hasre '^AUDIT missing from impact-blindspot.txt: .*dynrun.test.sh \(suite-dynamic\)'; } && ok "--audit: a suite that runs suites by a computed \$HERE/\$n.test.sh name is reported" || no "audit suite-dynamic" "(rc=$RC $OUT)"
D_ac="$(newcase audit_comment)"; printf '# eval is mentioned only in a comment\necho ok\n' > "$D_ac/$TS/quiet.test.sh"; ( cd "$D_ac" && git add -A && git commit -q -m a )
run --repo "$D_ac" --audit
[ "$RC" = 0 ] && ok "--audit: eval inside a comment is not a blind spot" || no "audit comment" "(rc=$RC $OUT)"
run --repo "$D_nom" --audit
{ [ "$RC" = 2 ] && ehas 'manifest absent'; } && ok "--audit on a tree without the manifest -> degraded, exit 2" || no "audit absent manifest" "(rc=$RC $ERR)"

# =================================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # mt LABEL GOOD-RC BAD-RC SED-EXPR [tooth flags...] -- ARGV...
  mt() {
    local label="$1" grc="$2" brc="$3" expr="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  BASE=(--base base)
  mt "word closure stops at direct references" 0 0 's/for (j = 1; j <= rn\[cur\]; j++) { s = rsrc/for (j = 1; j <= 0; j++) { s = rsrc/' \
    --good-lacks 'Escalated to FULL' --bad-has 'Escalated to FULL: no suite reaches' -- "$BASH_BIN" @SUT@ --repo "$D_cy" "${BASE[@]}"
  mt "python import edge removed" 0 0 's/for (k = 1; k <= ni; k++) if (ids\[k\] != "") word(ids\[k\] "\.py", src)/;/' \
    --good-has 'tests/h.test.sh' --bad-lacks 'tests/h.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_py" "${BASE[@]}" --format list
  mt "only the first identifier after 'from' is read (dotted + from-names lost)" 0 0 's/for (k = 1; k <= ni; k++) if (ids/for (k = 1; k <= 1; k++) if (ids/' \
    --good-lacks 'Escalated to FULL' --bad-has 'Escalated to FULL' -- "$BASH_BIN" @SUT@ --repo "$D_dot" "${BASE[@]}"
  mt "suite -> suite edge removed" 0 0 '/a suite that RUNS another suite/d' \
    --good-has 'tests/runner.test.sh' --bad-lacks 'tests/runner.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_sr" "${BASE[@]}"
  mt "changed suite not walked as a node" 0 0 "s/printf 'S:%s\\\\n' \"\\\$p\" >> \"\\\$TMP\\/changed_nodes\"/:/" \
    --good-has 'tests/runner.test.sh' --bad-lacks 'tests/runner.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_sr2" "${BASE[@]}"
  mt "deleted markdown no longer maps" 0 0 's/\[ "\$g" -eq 0 \] && printf/false \&\& printf/' \
    --good-has 'tests/docref.test.sh' --bad-lacks 'tests/docref.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_mdel" "${BASE[@]}"
  mt "deleted fixture dir no longer escalates" 0 0 's/|| full "deleted fixture dir: \${n#D:}"/|| :/' \
    --good-has 'Escalated to FULL: deleted fixture dir' --bad-lacks 'Escalated to FULL: deleted fixture dir' -- "$BASH_BIN" @SUT@ --repo "$D_fxdel" "${BASE[@]}"
  mt "threshold validation removed" 2 0 "s/''|\\*\\[!0-9\\]\\*|0|0\\[0-9\\]\\*) degraded/NEVERMATCH) degraded/" \
    --good-has 'SUITE_IMPACT_WIDE_THRESHOLD' -- env SUITE_IMPACT_WIDE_THRESHOLD=abc "$BASH_BIN" @SUT@ --repo "$D_lit" "${BASE[@]}"
  mt "--worktree with --head accepted" 2 0 's/\[ "\$HEAD_GIVEN" = 1 \]; then echo/[ "$HEAD_GIVEN" = 99 ]; then echo/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_lit" "${BASE[@]}" --worktree --head HEAD
  mt "dotted basename lookup removed" 0 0 's/^  lookup(w, src)$/  ;/' \
    --good-lacks 'Escalated to FULL' --bad-has 'Escalated to FULL' -- "$BASH_BIN" @SUT@ --repo "$D_dotf" "${BASE[@]}"
  mt "kit content no longer triggers blind-spot set" 0 0 's/\*) DOCS_ONLY=0; CODE_CHANGED=1; \[ "\$st" = D \] && full "deleted kit-content/*) DOCS_ONLY=0; [ "$st" = D ] \&\& full "deleted kit-content/' \
    --good-has 'tests/evalish.test.sh' --bad-lacks 'tests/evalish.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_kc" "${BASE[@]}"
  mt "install .test.mjs not a suite" 0 0 's/|research-sdd\/install\/tests\/\*\.test\.mjs) rest=/) rest=/' \
    --good-has 'inst2.test.mjs' --bad-lacks 'inst2.test.mjs' -- "$BASH_BIN" @SUT@ --repo "$D_im" "${BASE[@]}"
  mt "suite-dynamic audit class removed" 1 0 's/then echo "suite-dynamic"; return; fi/then :; fi/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_ad" --audit
  mt "fixture change no longer maps" 0 0 "s/printf 'D:%s\\\\n' \"\\\$d\" >> \"\\\$TMP\\/changed_nodes\" ;;/: ;;/" \
    --good-has 'tests/e.test.sh' --bad-lacks 'tests/e.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_fx" "${BASE[@]}" --format list
  mt "always-run set dropped" 0 2 's/cat "\$TMP\/selected_direct" "\$TMP\/always"; }/cat "$TMP\/selected_direct"; }/' \
    --good-has 'tests/lint-always.test.sh' --bad-has 'empty selection' -- "$BASH_BIN" @SUT@ --repo "$D_doc" "${BASE[@]}" --format list
  mt "blind-spot set never added" 0 0 's/cat "\$TMP\/blind" >> "\$TMP\/sel"; /: ; /' \
    --good-has 'tests/evalish.test.sh' --bad-lacks 'tests/evalish.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_lit" "${BASE[@]}" --format list
  mt "changed suite no longer selects itself" 0 0 's/if \[ "\$st" != D \] && grep -qxF -- "\$p" "\$TMP\/suites"; then/if false; then/' \
    --good-has 'tests/aaa-first.test.sh' --bad-lacks 'tests/aaa-first.test.sh' -- "$BASH_BIN" @SUT@ --repo "$D_sc" "${BASE[@]}" --format list
  mt "harness escalation removed (tests/lib)" 0 0 's/DOCS_ONLY=0; full "harness file changed: \$p" ;;/DOCS_ONLY=0 ;;/' \
    --good-has 'Escalated to FULL: harness' --bad-lacks 'Escalated to FULL: harness' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_lib" "${BASE[@]}"
  mt "install escalation removed" 0 0 's/full "install tree changed: \$p"/:/' \
    --good-has 'Escalated to FULL: install' --bad-lacks 'Escalated to FULL: install' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_inst" "${BASE[@]}"
  mt "templates escalation removed" 0 0 's/full "templates changed: \$p"/:/' \
    --good-has 'Escalated to FULL: templates' --bad-lacks 'Escalated to FULL: templates' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_tpl" "${BASE[@]}"
  mt "CI escalation removed" 0 0 's/full "CI configuration changed: \$p"/:/' \
    --good-has 'Escalated to FULL: CI' --bad-lacks 'Escalated to FULL: CI' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_gh" "${BASE[@]}"
  mt "shellcheckrc escalation removed" 0 0 's/full "shellcheck configuration changed: \$p"/:/' \
    --good-has 'Escalated to FULL: shellcheck' --bad-lacks 'Escalated to FULL: shellcheck' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_shellcheckrc" "${BASE[@]}"
  mt "added-file escalation removed" 0 0 's/A) full "added production file: \$p" ;;/A) : ;;/' \
    --good-has 'Escalated to FULL: added production file' --bad-lacks 'Escalated to FULL: added production file' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_add" "${BASE[@]}"
  mt "deleted-file escalation removed" 0 0 's/D) full "deleted\/renamed production file: \$p" ;;/D) : ;;/' \
    --good-has 'Escalated to FULL: deleted/renamed' --bad-lacks 'Escalated to FULL: deleted/renamed' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_del" "${BASE[@]}"
  mt "unmapped-file escalation removed" 0 0 's/\*) full "no suite reaches the changed file: \${a#?:}" ;;/*) : ;;/' \
    --good-has 'Escalated to FULL: no suite reaches' --bad-lacks 'Escalated to FULL: no suite reaches' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_unmapped" "${BASE[@]}"
  mt "named wide library check removed" 0 0 's/\[ "\$base" = "\$w" \] && full "widely used library changed: \$p"/:/' \
    --good-has 'Escalated to FULL: widely used library' --bad-lacks 'Escalated to FULL: widely used library' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_named" "${BASE[@]}"
  mt "closure-size threshold disabled" 0 0 's/if \[ "\$b" -gt "\$WIDE_THRESHOLD" \]/if false/' \
    --good-has 'Escalated to FULL: widely used: ' --bad-lacks 'Escalated to FULL: widely used: ' -- env SUITE_IMPACT_WIDE_THRESHOLD=2 "$BASH_BIN" @SUT@ --repo "$TMP/wide" "${BASE[@]}"
  mt "unclassified-path escalation removed" 0 0 's/full "unclassified path (no rule places it): \$p"/:/' \
    --good-has 'Escalated to FULL: unclassified' --bad-lacks 'Escalated to FULL: unclassified' -- "$BASH_BIN" @SUT@ --repo "$TMP/e_unclass" "${BASE[@]}"
  mt "docs-only paths no longer recognised" 0 0 's/^    openspec\/\*|odd\/\*) ;;$/    odd\/*) ;;/' \
    --good-lacks 'Escalated to FULL' --bad-has 'Escalated to FULL: unclassified' -- "$BASH_BIN" @SUT@ --repo "$D_docj" "${BASE[@]}"
  mt "no-change notice removed" 0 0 's/echo "no-change: empty diff, always-run set only"/:/' \
    --good-has 'no-change' --bad-lacks 'no-change' -- "$BASH_BIN" @SUT@ --repo "$D_lit" --base HEAD --head HEAD
  mt "untracked files ignored by --worktree" 0 0 "s/git ls-files -z -o --exclude-standard | while/: | while/" \
    --good-has 'Escalated to FULL: added production file' --bad-lacks 'Escalated to FULL: added production file' -- "$BASH_BIN" @SUT@ --repo "$D_wt" "${BASE[@]}" --worktree
  mt "bad base ref no longer typed" 2 2 's/degraded "bad base ref: \$BASE"/true/' \
    --good-has 'bad base ref' --bad-lacks 'bad base ref' -- "$BASH_BIN" @SUT@ --repo "$D_lit" --base nosuchref
  mt "bad head ref no longer typed" 2 2 's/degraded "bad head ref: \$HEAD_REF"/true/' \
    --good-has 'bad head ref' --bad-lacks 'bad head ref' -- "$BASH_BIN" @SUT@ --repo "$D_lit" --base base --head nosuchref
  mt "absent manifest tolerated" 2 0 's/\[ -f "\$file" \] || degraded "manifest absent: \$file"/[ -f "$file" ] || return 0/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_nom" "${BASE[@]}"
  mt "unknown-suite manifest line tolerated" 1 0 's/echo "INVALID \$(basename "\$file"):\$ln: names no existing suite: \$name" >&2; MANIFEST_BAD=\$((MANIFEST_BAD+1)); continue/continue/' \
    -- "$BASH_BIN" @SUT@ --repo "$TMP/m_ghost" "${BASE[@]}"
  mt "reason-less manifest line tolerated" 1 0 's/MANIFEST_BAD=\$((MANIFEST_BAD+1)); continue; fi$/continue; fi/' \
    -- "$BASH_BIN" @SUT@ --repo "$TMP/m_noreason" "${BASE[@]}"
  mt "duplicate manifest line tolerated" 1 0 's/duplicate suite: \$name" >&2; MANIFEST_BAD=\$((MANIFEST_BAD+1)); continue ;;/duplicate suite: $name" >\&2; continue ;;/' \
    -- "$BASH_BIN" @SUT@ --repo "$TMP/m_dup" "${BASE[@]}"
  mt "eval detector removed from --audit" 1 0 's/ev\[a\]l/evXl/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_ae" --audit
  mt "kit-copy detector removed from --audit" 1 0 's/then echo "kit-copy"; return; fi/then :; fi/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_ak" --audit
  mt "audit ignores comment lines no more" 0 1 's/body="\$(grep -vE .\^\[\[:space:\]\]\*(#|\/\/). "\$f" 2>\/dev\/null)" || true/body="$(cat "$f")" || true/' \
    -- "$BASH_BIN" @SUT@ --repo "$D_ac" --audit
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
