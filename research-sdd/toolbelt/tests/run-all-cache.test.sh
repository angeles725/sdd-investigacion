#!/usr/bin/env bash
# run-all-cache.test.sh — suite for `run-all.sh --cache`, the content-addressed per-suite result cache (kit issue #2201 part 2).
#
# Contract under test: with --cache a suite whose key is unchanged reuses its previous full PASS instead of running. The
# key is a sha256 over the suite file, its forward dependency set (suite-impact.sh --deps-all), tests/lib/**, run-all.sh,
# suite-impact.sh, the impact/tier manifests, the install and templates trees, the run mode (--prove-teeth, lane, tier),
# the first line of `--version` of bash/python3/node/git/jq/shellcheck, and the RSDD_* environment. Blind-spot suites and
# suites whose dependencies cannot be resolved are never cached; FAIL / SKIP results and runs with a hermeticity
# violation are never stored. --cache is refused with --require-teeth and --shard (exit 2). The cache lives under
# ${XDG_CACHE_HOME:-$HOME/.cache}/research-sdd/run-all and never inside the repo. Every degraded state (no sha256sum,
# unwritable cache dir, unanswerable dependency map) runs WITHOUT the cache and says so.
#
# Each case builds a tiny git repo in $TMP with a COPY of run-all.sh and suite-impact.sh next to fixture suites, so the
# real tests/ directory is never run. A suite appends its name to $CACHE_TEST_LOG each time it REALLY executes; a
# replayed result does not, so `ran` is the ground truth for "executed vs reused".
#
# Usage: run-all-cache.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="$HERE/run-all.sh"
IMP="$HERE/suite-impact.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$IMP" ] || { echo "FATAL: suite-impact.sh not found: $IMP" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum not on PATH" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
# shellcheck source=lib/stage-run-all.sh
. "$HERE/lib/stage-run-all.sh"
mutant_bootstrap mutant_sed || exit 2
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export RUN_ALL_DEFAULT_RSDD_ROOT="$TMP/default-rsdd-private"   # never scan the host's real /tmp/rsdd
unset XDG_CACHE_HOME RSDD_CACHE_PROBE
MID='·'
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
cgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -c init.defaultBranch=main "$@"; }

CT='research-sdd/toolbelt/tests'
# mksuite <file> <name> [exit-code] [extra line]: a suite that logs a real execution, prints a banner and a valid summary.
mksuite() {
  local f="$1" n="$2" ec="${3:-0}" extra="${4:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo %s >> "${CACHE_TEST_LOG:-/dev/null}"\n' "$n"
    printf 'echo "== %s.test.sh =="\n' "$n"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf 'echo "== 1 passed %s %s failed =="\n' "$MID" "$([ "$ec" = 0 ] && echo 0 || echo 1)"
    printf 'exit %s\n' "$ec"
  } > "$f"
}
# ctree <name> — a repo with toolbelt suites a b c, install suite i, production alpha/beta/gamma/iota (a/b/c/i reach one each),
# a fixture dir for a, a tests/lib helper, c always-run, no blind-spot suite. Prints the tests dir.
ctree() {
  local root="$TMP/$1" w; w="$root/$CT"
  mkdir -p "$w/lib" "$w/fixtures/a" "$root/research-sdd/install/tests" "$root/research-sdd/toolbelt"
  rsdd_stage_run_all "$w" "$SUT" || return 2; cp "$IMP" "$w/suite-impact.sh"
  mksuite "$w/a.test.sh" a 0 ': "$TB/alpha.sh" and fixtures'
  mksuite "$w/b.test.sh" b 0 ': "$TB/beta.sh"'
  mksuite "$w/c.test.sh" c 0 ': "$TB/gamma.sh"'
  mksuite "$root/research-sdd/install/tests/i.test.sh" i 0 ': "$TB/iota.sh"'
  printf '#!/usr/bin/env bash\necho alpha\n' > "$root/research-sdd/toolbelt/alpha.sh"
  printf '#!/usr/bin/env bash\necho beta\n' > "$root/research-sdd/toolbelt/beta.sh"
  printf '#!/usr/bin/env bash\necho iota\n' > "$root/research-sdd/toolbelt/iota.sh"
  printf '#!/usr/bin/env bash\necho gamma\n' > "$root/research-sdd/toolbelt/gamma.sh"
  printf 'data\n' > "$w/fixtures/a/data.txt"
  printf ': helper\n' > "$w/lib/helper.sh"; printf ': shard-join\n' > "$w/shard-join.sh"
  printf '# fixture: no extras\n' > "$w/suite-tiers.txt"
  printf 'c fixture always-run suite\n' > "$w/impact-always.txt"
  printf '# fixture: no blind-spot suites\n' > "$w/impact-blindspot.txt"
  cgit -C "$root" init -q && cgit -C "$root" add -A && cgit -C "$root" commit -q -m base || return 1
  printf '%s' "$w"
}
# cr <tests-dir> [run-all args...] — one run: sets OUT, RC. The real-execution log and the default cache dir live OUTSIDE the
# repo (in $TMP/ran and $TMP/xdg), so neither counts as a hermeticity leak nor as an in-repo cache dir.
OUT=""; RC=0
mkdir -p "$TMP/ran" "$TMP/xdg"
ranlog() { printf '%s/ran/%s' "$TMP" "$(basename "${1%/$CT}")"; }
cr() {
  local t="$1"; shift
  local root="${t%/$CT}" name; name="$(basename "$root")"
  : > "$(ranlog "$t")"
  OUT="$(cd "$root" && CACHE_TEST_LOG="$(ranlog "$t")" XDG_CACHE_HOME="${XDG_CACHE_HOME-$TMP/xdg/$name}" PATH="${CR_PATH:-$PATH}" bash "$t/run-all.sh" "$@" 2>&1)"; RC=$?
}
# ran: which suites really executed, WITHOUT the always-run suite c (it executes every time by design; ranraw includes it)
ranraw() { LC_ALL=C sort -u "$(ranlog "$1")" | tr -d '\n'; }
ran() { ranraw "$1" | tr -d 'c'; }
cline() { grep -E '^Cache: ' <<<"$OUT"; }
touch_prod() { printf '# edit %s\n' "$RANDOM" >> "$(dirname "$1")/../../$2"; }   # touch_prod <tests-dir> <file under research-sdd/>

# ---- 1: the second run reuses every suite ---------------------------------------------------------------------------------------
t="$(ctree c1)"
cr "$t" --cache; r1="$(ran "$t")"; l1="$(cline)"; rc1=$RC; raw1="$(ranraw "$t")"
cr "$t" --cache; r2="$(ran "$t")"; l2="$(cline)"; rc2=$RC; out2="$OUT"; raw2="$(ranraw "$t")"
if [ "$rc1" = 0 ] && [ "$r1" = abi ] && grep -qxF 'Cache: hit 0, miss 3, uncacheable 1 — [c.test.sh: always-run]' <<<"$l1" \
   && [ "$raw1" = abci ] && [ "$raw2" = c ] && [ "$rc2" = 0 ] && [ -z "$r2" ] && grep -qxF 'Cache: hit 3, miss 0, uncacheable 1 — [c.test.sh: always-run]' <<<"$l2" \
   && grep -qxF 'Suites passed: 4' <<<"$out2" && grep -qxF 'Test cases passed: 4' <<<"$out2" \
   && grep -qF '>>> running: a.test.sh (cached)' <<<"$out2" && grep -qxF 'Cache hits: i.test.sh, a.test.sh, b.test.sh' <<<"$out2" \
   && grep -qxF 'Cache stored: 0' <<<"$out2"; then
  ok "second run: every cacheable suite is reused, the always-run suite c still executes (uncacheable: always-run), counted as passed and labelled (cached)"
else no "second run wrong: rc1=$rc1 ran1=$r1 [$l1] rc2=$rc2 ran2=$r2 [$l2] $(grep -E '^(Suites passed|Test cases passed|Cache hits|Cache stored)|cached' <<<"$out2" | tr '\n' '|')"; fi
grep -qxF 'Cache stored: 3' <<<"$(cr "$(ctree c1b)" --cache; printf '%s' "$OUT")" && ok "first run reports what it stored" || no "first run did not report 'Cache stored: 3'"
f="$(find "$TMP/xdg/c1/research-sdd/run-all" -maxdepth 1 -type f 2>/dev/null | head -1)"
hdr=""; [ -z "$f" ] || hdr="$(head -n 1 "$f")"
if [[ "$hdr" =~ ^PASS\ 1\ 0\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9a-f]+$ ]]; then ok "an entry is keyed by its hash and starts with 'PASS <passed> 0 <date> <head>'"
else no "entry format wrong: [$hdr] file=[$f]"; fi
cr "$t" ; grep -q '^Cache' <<<"$OUT" && no "a run WITHOUT --cache printed a Cache line (default aggregate must be unchanged)" || ok "default (no --cache): no Cache line, the cache is opt-in"
r0="$(ran "$t")"; [ "$r0" = abi ] && ok "default (no --cache): every suite executes even with a warm cache" || no "default run reused the cache: ran=$r0"
cr "$t" --no-cache; [ "$(ran "$t")" = abi ] && ! grep -q '^Cache' <<<"$OUT" && ok "--no-cache is the explicit default" || no "--no-cache wrong: ran=$(ran "$t")"

# ---- 2: each declared input invalidates ----------------------------------------------------------------------------------------
warm() { local t; t="$(ctree "$1")"; cr "$t" --cache >/dev/null 2>&1; printf '%s' "$t"; }
expect_ran() { # <label> <tests-dir> <expected ran string> [run-all args...] — one more --cache run after a change
  local label="$1" t="$2" want="$3"; shift 3
  cr "$t" --cache "$@"
  if [ "$RC" = 0 ] && [ "$(ran "$t")" = "$want" ]; then ok "invalidation: $label re-runs exactly [$want]"
  else no "invalidation: $label wanted [$want] got [$(ran "$t")] rc=$RC [$(cline)]"; fi
}
t="$(warm c2suite)"; printf '# edit\n' >> "$t/b.test.sh"; expect_ran "editing the suite file b" "$t" b
t="$(warm c2dep)"; touch_prod "$t/x" toolbelt/alpha.sh; expect_ran "editing a dependency (alpha.sh, reached by a)" "$t" a
t="$(warm c2dep2)"; touch_prod "$t/x" toolbelt/iota.sh; expect_ran "editing a dependency of the install suite" "$t" i
t="$(warm c2lib)"; printf '# edit\n' >> "$t/lib/helper.sh"; expect_ran "editing tests/lib/**" "$t" abi
t="$(warm c2fx)"; printf 'more\n' >> "$t/fixtures/a/data.txt"; expect_ran "editing the suite's own fixture dir" "$t" a
t="$(warm c2runall)"; printf '# edit\n' >> "$t/run-all.sh"; expect_ran "editing run-all.sh itself" "$t" abi
t="$(warm c2imp)"; printf '# edit\n' >> "$t/impact-always.txt"; expect_ran "editing impact-always.txt" "$t" abi
t="$(warm c2tiers)"; printf '# edit\n' >> "$t/suite-tiers.txt"; expect_ran "editing suite-tiers.txt" "$t" abi
t="$(warm c2simp)"; printf '# edit\n' >> "$t/suite-impact.sh"; expect_ran "editing suite-impact.sh" "$t" abi
t="$(warm c2install)"; mkdir -p "${t%/toolbelt/tests}/install"; printf 'x\n' > "${t%/toolbelt/tests}/install/install.sh"; expect_ran "adding a file to the install tree" "$t" abi
t="$(warm c2tpl)"; mkdir -p "${t%/toolbelt/tests}/templates"; printf 'x\n' > "${t%/toolbelt/tests}/templates/t.md"; expect_ran "adding a file to the templates tree" "$t" abi
t="$(warm c2mode)"; expect_ran "the mode (--prove-teeth)" "$t" abi --prove-teeth
t="$(warm c2lane)"; expect_ran "the lane (--lane fast)" "$t" abi --lane fast
t="$(warm c2tier)"; printf 'x\n' >/dev/null; expect_ran "a different --tier (not part of the key: same suites reuse)" "$t" "" --tier all
t="$(warm c2env)"; RSDD_CACHE_PROBE=1 expect_ran "an RSDD_* environment variable" "$t" abi
# a tool version shim: a python3 that reports a different --version invalidates everything
mkdir -p "$TMP/shim-a" "$TMP/shim-b"
printf '#!/bin/sh\necho "Python 9.9.9"\n' > "$TMP/shim-a/python3"; printf '#!/bin/sh\necho "Python 9.9.8"\n' > "$TMP/shim-b/python3"; chmod +x "$TMP/shim-a/python3" "$TMP/shim-b/python3"
t="$(ctree c2tool)"; CR_PATH="$TMP/shim-a:$PATH" cr "$t" --cache >/dev/null 2>&1
CR_PATH="$TMP/shim-a:$PATH" cr "$t" --cache; same="$(ran "$t")"
CR_PATH="$TMP/shim-b:$PATH" cr "$t" --cache; chg="$(ran "$t")"
{ [ -z "$same" ] && [ "$chg" = abi ]; } && ok "invalidation: a tool version shim (python3 --version) re-runs everything, an identical one reuses" || no "tool version: same=[$same] changed=[$chg]"
# presence of an optional tool (bwrap) is part of the key: a suite may run or skip by what is installed
mkdir -p "$TMP/shim-c"; printf '#!/bin/sh\necho "bwrap 0.0"\n' > "$TMP/shim-c/bwrap"; chmod +x "$TMP/shim-c/bwrap"
t="$(ctree c2tool2)"; cr "$t" --cache >/dev/null 2>&1
CR_PATH="$TMP/shim-c:$PATH" cr "$t" --cache; chg2="$(ran "$t")"
[ "$chg2" = abi ] && ok "invalidation: a newly installed bwrap re-runs everything (tool presence is keyed)" || no "bwrap presence: ran=[$chg2]"
t="$(warm c2sj)"; printf '# edit\n' >> "$t/shard-join.sh"; expect_ran "editing tests/shard-join.sh" "$t" abi
# RSDD_* values are encoded: one multi-line value must not collide with two variables
t="$(ctree c2q)"; RSDD_CACHE_PROBE=$'1\nenv RSDD_CACHE_PROBE2=2' cr "$t" --cache >/dev/null 2>&1
RSDD_CACHE_PROBE=1 RSDD_CACHE_PROBE2=2 cr "$t" --cache
[ "$(ran "$t")" = abi ] && ok "invalidation: an RSDD_* value with a newline cannot forge a second variable (values are %q-encoded)" || no "env encoding: ran=[$(ran "$t")]"
# the cached suites are not checked for hermeticity / TMPDIR, and the aggregate says so
t="$(warm c2note)"; cr "$t" --cache
if grep -qE '^Hermeticity violations .*: 0 \(3 cached suites not checked\)$' <<<"$OUT" && grep -qE '^Kit-tree hermeticity violations .*: 0 \(3 cached suites not checked\)$' <<<"$OUT" && grep -qE '^TMPDIR leftovers: 0 — \[\] \(3 cached suites not checked\)$' <<<"$OUT"; then ok "the hermeticity and TMPDIR lines say how many cached suites were not checked"
else no "cached-not-checked note wrong: $(grep -E '^(Hermeticity|Kit-tree|TMPDIR leftovers)' <<<"$OUT" | tr '\n' '|')"; fi
cr "$t" --no-cache; grep -q 'cached suites not checked' <<<"$OUT" && no "a run without the cache printed the cached-not-checked note" || ok "no note without cached suites"
# a file OUTSIDE research-sdd/ that a suite names is part of that suite's key (and only that suite's)
t="$(ctree c2out)"; printf '# reads openspec/specs\n' >> "$t/a.test.sh"; cgit -C "${t%/$CT}" commit -qam out
cr "$t" --cache >/dev/null 2>&1; mkdir -p "${t%/$CT}/openspec"; printf 'spec\n' > "${t%/$CT}/openspec/spec.md"
expect_ran "a file under openspec/ named by suite a" "$t" a
# an unrelated edit leaves the other suites cached (the cache is not all-or-nothing)
t="$(warm c2part)"; touch_prod "$t/x" toolbelt/beta.sh; expect_ran "an edit to beta.sh leaves a, c and i reused; only b" "$t" b

# ---- 3: blind-spot, unresolved, FAIL, SKIP, hermeticity are never stored ------------------------------------------------------
t="$(ctree c3blind)"; printf 'b whole-tree reader fixture\n' > "$t/impact-blindspot.txt"; cgit -C "${t%/$CT}" commit -qam bl
cr "$t" --cache >/dev/null; cr "$t" --cache
if [ "$RC" = 0 ] && [ "$(ran "$t")" = b ] && grep -qxF 'Cache: hit 2, miss 0, uncacheable 2 — [b.test.sh: blind-spot (manifest), c.test.sh: always-run]' <<<"$OUT"; then ok "a blind-spot suite always runs and the reason is printed; the others are reused"
else no "blind-spot wrong: ran=$(ran "$t") [$(cline)]"; fi
t="$(ctree c3unres)"; printf '#!/usr/bin/env bash\necho z >> "${CACHE_TEST_LOG:-/dev/null}"\necho "== z.test.sh =="\necho "== 1 passed %s 0 failed =="\n' "$MID" > "$t/z.test.sh"; cgit -C "${t%/$CT}" add -A; cgit -C "${t%/$CT}" commit -qm z
cr "$t" --cache >/dev/null; cr "$t" --cache
if [ "$(ran "$t")" = z ] && grep -qF 'z.test.sh: no dependency resolved' <<<"$(cline)"; then ok "a suite with no resolvable dependency is never cached (it always runs, with the reason)"
else no "unresolved wrong: ran=$(ran "$t") [$(cline)]"; fi
t="$(ctree c3fail)"; mksuite "$t/b.test.sh" b 1 ': "$TB/beta.sh"'; sed -i 's/ 1 failed ==/ 0 failed ==/' "$t/b.test.sh"; cgit -C "${t%/$CT}" commit -qam f
cr "$t" --cache; rc1=$RC; cr "$t" --cache
if [ "$rc1" = 1 ] && [ "$RC" = 1 ] && [ "$(ran "$t")" = b ] && grep -qxF 'Cache: hit 2, miss 1, uncacheable 1 — [c.test.sh: always-run]' <<<"$OUT" && grep -q 'b.test.sh (exit 1)' <<<"$OUT"; then ok "a FAIL is never cached: the failing suite re-runs and still fails, the passing ones are reused"
else no "fail wrong: rc=$rc1/$RC ran=$(ran "$t") [$(cline)]"; fi
t="$(ctree c3skip)"; printf '#!/usr/bin/env bash\necho b >> "${CACHE_TEST_LOG:-/dev/null}"\necho "SKIP: no tool"\necho "== 1 passed %s 0 failed =="\n: "$TB/beta.sh"\n' "$MID" > "$t/b.test.sh"; cgit -C "${t%/$CT}" commit -qam s
cr "$t" --cache >/dev/null; cr "$t" --cache
{ [ "$(ran "$t")" = b ] && grep -q 'Cache: hit 2, miss 1' <<<"$OUT"; } && ok "a SKIP is never cached (an environment-dependent result is not a PASS)" || no "skip wrong: ran=$(ran "$t") [$(cline)]"
t="$(ctree c3sumfail)"; printf '#!/usr/bin/env bash\necho b >> "${CACHE_TEST_LOG:-/dev/null}"\necho "== b.test.sh =="\necho "== 1 passed %s 1 failed =="\n: "$TB/beta.sh"\nexit 0\n' "$MID" > "$t/b.test.sh"; cgit -C "${t%/$CT}" commit -qam sf
cr "$t" --cache >/dev/null; cr "$t" --cache
{ [ "$(ran "$t")" = b ] && grep -q 'Cache: hit 2, miss 1' <<<"$OUT"; } && ok "an exit-0 suite whose summary reports failures is never replayed as a pass" || no "sumfail wrong: ran=$(ran "$t") [$(cline)]"
t="$(ctree c3tskip)"; mksuite "$t/b.test.sh" b 0 ': "$TB/beta.sh"
echo "  SKIP: one case needs a missing tool"'; cgit -C "${t%/$CT}" commit -qam ts
cr "$t" --cache >/dev/null; cr "$t" --cache
{ [ "$(ran "$t")" = b ] && grep -q 'Cache: hit 2, miss 1' <<<"$OUT"; } && ok "a suite with per-test skips is never cached (its result depends on the environment)" || no "per-test skip wrong: ran=$(ran "$t") [$(cline)]"
t="$(ctree c3leak)"; mksuite "$t/b.test.sh" b 0 ': "$TB/beta.sh"
echo leak > "$PWD/leaked-by-b.txt"'; cgit -C "${t%/$CT}" commit -qam l
cr "$t" --cache >/dev/null; rm -f "${t%/$CT}/leaked-by-b.txt"; cr "$t" --cache
rm -f "${t%/$CT}/leaked-by-b.txt"
{ [ "$RC" = 1 ] && [ "$(ran "$t")" = b ] && grep -q 'Cache: hit 2, miss 1' <<<"$OUT"; } && ok "a PASS with a hermeticity violation is never stored (a leak cannot be replayed away)" || no "leak wrong: ran=$(ran "$t") [$(cline)]"
t="$(warm c3corrupt)"; for e in "$TMP"/xdg/c3corrupt/research-sdd/run-all/*; do printf 'garbage\n' > "$e"; done
cr "$t" --cache
{ [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -q 'Cache: hit 0, miss 3' <<<"$OUT"; } && ok "a corrupt entry is a miss (the suite runs; the entry is rewritten)" || no "corrupt wrong: rc=$RC ran=$(ran "$t") [$(cline)]"
cr "$t" --cache; { [ "$RC" = 0 ] && [ -z "$(ran "$t")" ]; } && ok "the rewritten entry is then reused" || no "entry not rewritten: ran=$(ran "$t")"

# ---- 4: teeth classification survives replay; -j ------------------------------------------------------------------------------
t="$(ctree c4teeth)"
{ printf '#!/usr/bin/env bash\necho a >> "${CACHE_TEST_LOG:-/dev/null}"\n: "$TB/alpha.sh"\n'
  printf 'if [ "${1:-}" = "--prove-teeth" ]; then echo "-- teeth: fixture mutation control --"; echo "  PASS  mutant verified"; fi\n'
  printf 'echo "== a.test.sh =="\necho "== 2 passed %s 0 failed =="\n' "$MID"; } > "$t/a.test.sh"; cgit -C "${t%/$CT}" commit -qam teeth
cr "$t" --cache --prove-teeth; f1="$(grep -E '^Suites without teeth' <<<"$OUT")"
cr "$t" --cache --prove-teeth; f2="$(grep -E '^Suites without teeth' <<<"$OUT")"
if [ "$RC" = 0 ] && [ -z "$(ran "$t")" ] && [ -n "$f1" ] && [ "$f1" = "$f2" ] && ! grep -qE '^Suites without teeth: [0-9]+ — \[.*\ba\b' <<<"$f2" && grep -qxF 'Test cases passed: 5' <<<"$OUT"; then ok "--prove-teeth: a replayed suite keeps its teeth classification (same 'Suites without teeth' line, case counts intact)"
else no "teeth replay wrong: ran=$(ran "$t") first=[$f1] second=[$f2]"; fi
pver=""; command -v parallel >/dev/null 2>&1 && pver="$(parallel --version 2>/dev/null)"
if [[ "$pver" == *"GNU parallel"* ]]; then
  t="$(ctree c4j)"; cr "$t" --cache -j 2; r1="$(ran "$t")"; rc1=$RC
  cr "$t" --cache -j 2; r2="$(ran "$t")"; rc2=$RC; o2="$OUT"
  printf '# edit\n' >> "$t/b.test.sh"; cr "$t" --cache -j 2; r3="$(ran "$t")"
  if [ "$rc1" = 0 ] && [ "$r1" = abi ] && [ "$rc2" = 0 ] && [ -z "$r2" ] && grep -qxF 'Cache: hit 3, miss 0, uncacheable 1 — [c.test.sh: always-run]' <<<"$o2" && [ "$r3" = b ] && [ "$RC" = 0 ] \
     && grep -qxF 'Suites passed: 4' <<<"$OUT" && grep -qxF 'Cache: hit 2, miss 1, uncacheable 1 — [c.test.sh: always-run]' <<<"$OUT"; then ok "-j 2: the batch stores, a second batch reuses everything, a mixed batch runs only the changed suite and replays in order"
  else no "-j wrong: ran=$r1/$r2/$r3 rc=$rc1/$rc2/$RC [$(cline)]"; fi
else printf '  SKIP  -j cache cases: GNU parallel not available\n'; fi

# ---- 5: refusals and degraded states -------------------------------------------------------------------------------------------
t="$(ctree c5ref)"
cr "$t" --cache --require-teeth; { [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && grep -qF -- '--cache cannot be combined with --require-teeth' <<<"$OUT"; } && ok "--cache with --require-teeth is refused (exit 2, nothing ran)" || no "require-teeth refusal wrong: rc=$RC ran=$(ran "$t")"
cr "$t" --cache --shard 1/2; { [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && grep -qF -- '--cache cannot be combined with --shard' <<<"$OUT"; } && ok "--cache with --shard is refused (exit 2, nothing ran)" || no "shard refusal wrong: rc=$RC ran=$(ran "$t")"
XDG_CACHE_HOME="${t%/$CT}/.cache" cr "$t" --cache; { [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && grep -qF 'inside the repository' <<<"$OUT"; } && ok "a cache dir inside the repo is refused (exit 2, nothing ran)" || no "in-repo cache dir wrong: rc=$RC ran=$(ran "$t") [$OUT]"
printf 'a file, not a dir\n' > "$TMP/notadir"
XDG_CACHE_HOME="$TMP/notadir" cr "$t" --cache
{ [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -qE '^Cache: DEGRADED — .*cache' <<<"$OUT"; } && ok "an unusable cache dir -> typed Cache: DEGRADED, the run proceeds without the cache" || no "unwritable wrong: rc=$RC ran=$(ran "$t") [$(grep Cache <<<"$OUT")]"
RUN_ALL_SHA256_CMD=no-such-sha256-tool cr "$t" --cache
{ [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -qE '^Cache: DEGRADED — no sha256 tool' <<<"$OUT"; } && ok "no sha256 tool -> typed Cache: DEGRADED, the run proceeds without the cache" || no "no-sha256 wrong: rc=$RC ran=$(ran "$t") [$(grep Cache <<<"$OUT")]"
t="$(ctree c5nogit)"; rm -rf "${t%/$CT}/.git"
cr "$t" --cache
{ [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -qE '^Cache: DEGRADED — suite-impact.sh --deps-all exited' <<<"$OUT"; } && ok "an unanswerable dependency map (suite-impact fails) -> typed Cache: DEGRADED, the run proceeds without the cache" || no "no-deps wrong: rc=$RC ran=$(ran "$t") [$(grep Cache <<<"$OUT")]"
cr "$t" --cache; [ -z "$(find "$TMP/xdg/c5nogit" -type f 2>/dev/null)" ] && ok "a degraded run stores nothing" || no "a degraded run wrote cache entries"

# =================================================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: run-all.sh --cache — each guard removed in turn; its scenario must then break --"
  # scn <kind> <tests-dir> — "held" or "broken <why>"; the SAME scenario is judged against the real runner and one mutant
  scn() {
    local k="$1" t="$2" r1 r2
    case "$k" in
      reuse)    cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$RC" = 0 ] && [ -z "$r1" ] && echo held || echo "broken rc=$RC ran=$r1" ;;
      suite)    cr "$t" --cache >/dev/null 2>&1; printf '# edit\n' >> "$t/b.test.sh"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = b ] && echo held || echo "broken ran=$r1" ;;
      dep)      cr "$t" --cache >/dev/null 2>&1; touch_prod "$t/x" toolbelt/alpha.sh; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = a ] && echo held || echo "broken ran=$r1" ;;
      lib)      cr "$t" --cache >/dev/null 2>&1; printf '# e\n' >> "$t/lib/helper.sh"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      fixture)  cr "$t" --cache >/dev/null 2>&1; printf 'm\n' >> "$t/fixtures/a/data.txt"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = a ] && echo held || echo "broken ran=$r1" ;;
      runall)   cr "$t" --cache >/dev/null 2>&1; printf '# e\n' >> "$t/run-all.sh"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      manifest) cr "$t" --cache >/dev/null 2>&1; printf '# e\n' >> "$t/impact-always.txt"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      mode)     cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache --prove-teeth; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      lane)     cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache --lane fast; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      env)      cr "$t" --cache >/dev/null 2>&1; RSDD_CACHE_PROBE=1 cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      tool)     CR_PATH="$TMP/shim-a:$PATH" cr "$t" --cache >/dev/null 2>&1; CR_PATH="$TMP/shim-b:$PATH" cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      install)  cr "$t" --cache >/dev/null 2>&1; mkdir -p "${t%/toolbelt/tests}/install"; printf 'x\n' > "${t%/toolbelt/tests}/install/install.sh"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      blind)    printf 'b fixture\n' > "$t/impact-blindspot.txt"; cgit -C "${t%/$CT}" commit -qam bl; cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = b ] && grep -qF 'b.test.sh: blind-spot (manifest)' <<<"$OUT" && echo held || echo "broken ran=$r1" ;;
      unres)    printf '#!/usr/bin/env bash\necho z >> "${CACHE_TEST_LOG:-/dev/null}"\necho "== z.test.sh =="\necho "== 1 passed %s 0 failed =="\n' "$MID" > "$t/z.test.sh"; cgit -C "${t%/$CT}" add -A; cgit -C "${t%/$CT}" commit -qm z; cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = z ] && grep -qF 'z.test.sh: no dependency resolved' <<<"$OUT" && echo held || echo "broken ran=$r1" ;;
      fail)     mksuite "$t/b.test.sh" b 1 ': "$TB/beta.sh"'; sed -i 's/ 1 failed ==/ 0 failed ==/' "$t/b.test.sh"; cgit -C "${t%/$CT}" commit -qam f; cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = b ] && [ "$RC" = 1 ] && echo held || echo "broken ran=$r1 rc=$RC" ;;
      skip)     printf '#!/usr/bin/env bash\necho b >> "${CACHE_TEST_LOG:-/dev/null}"\necho "SKIP: no tool"\necho "== 1 passed %s 0 failed =="\n: "$TB/beta.sh"\n' "$MID" > "$t/b.test.sh"; cgit -C "${t%/$CT}" commit -qam s; cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = b ] && echo held || echo "broken ran=$r1" ;;
      leak)     mksuite "$t/b.test.sh" b 0 ': "$TB/beta.sh"
echo leak > "$PWD/leaked-by-b.txt"'; cgit -C "${t%/$CT}" commit -qam l; cr "$t" --cache >/dev/null 2>&1; rm -f "${t%/$CT}/leaked-by-b.txt"; cr "$t" --cache; r1="$(ran "$t")"; rm -f "${t%/$CT}/leaked-by-b.txt"; [ "$r1" = b ] && echo held || echo "broken ran=$r1" ;;
      corrupt)  cr "$t" --cache >/dev/null 2>&1; for e in "$TMP/xdg/$(basename "${t%/$CT}")"/research-sdd/run-all/*; do printf 'garbage\n' > "$e"; done; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      always)   cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ranraw "$t")"; [ "$r1" = c ] && grep -qF 'c.test.sh: always-run' <<<"$OUT" && echo held || echo "broken ran=$r1 [$(cline)]" ;;
      tool2)    cr "$t" --cache >/dev/null 2>&1; CR_PATH="$TMP/shim-c:$PATH" cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      sj)       cr "$t" --cache >/dev/null 2>&1; printf '# e\n' >> "$t/shard-join.sh"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      quote)    RSDD_CACHE_PROBE=$'1\nenv RSDD_CACHE_PROBE2=2' cr "$t" --cache >/dev/null 2>&1; RSDD_CACHE_PROBE=1 RSDD_CACHE_PROBE2=2 cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = abi ] && echo held || echo "broken ran=$r1" ;;
      note)     cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; grep -qE '^TMPDIR leftovers: 0 — \[\] \(3 cached suites not checked\)$' <<<"$OUT" && echo held || echo "broken" ;;
      notier)   cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache --tier all; r1="$(ran "$t")"; [ -z "$r1" ] && echo held || echo "broken ran=$r1" ;;
      tskip)    mksuite "$t/b.test.sh" b 0 ': "$TB/beta.sh"
echo "  SKIP  one case needs a missing tool"'; cgit -C "${t%/$CT}" commit -qam ts; cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = b ] && echo held || echo "broken ran=$r1" ;;
      outside)  printf '# reads openspec/specs\n' >> "$t/a.test.sh"; cgit -C "${t%/$CT}" commit -qam out; cr "$t" --cache >/dev/null 2>&1; mkdir -p "${t%/$CT}/openspec"; printf 'spec\n' > "${t%/$CT}/openspec/spec.md"; cr "$t" --cache; r1="$(ran "$t")"; [ "$r1" = a ] && echo held || echo "broken ran=$r1" ;;
      jreuse)   cr "$t" --cache -j 2 >/dev/null 2>&1; cr "$t" --cache -j 2; r1="$(ran "$t")"; [ "$RC" = 0 ] && [ -z "$r1" ] && echo held || echo "broken rc=$RC ran=$r1" ;;
      reqteeth) cr "$t" --cache --require-teeth; [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && echo held || echo "broken rc=$RC ran=$(ran "$t")" ;;
      shard)    cr "$t" --cache --shard 1/2; [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && echo held || echo "broken rc=$RC ran=$(ran "$t")" ;;
      inrepo)   XDG_CACHE_HOME="${t%/$CT}/.cache" cr "$t" --cache; [ "$RC" = 2 ] && [ -z "$(ran "$t")" ] && echo held || echo "broken rc=$RC ran=$(ran "$t")" ;;
      nosha)    RUN_ALL_SHA256_CMD=no-such-sha256-tool cr "$t" --cache; [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -q 'Cache: DEGRADED — no sha256 tool' <<<"$OUT" && echo held || echo "broken rc=$RC ran=$(ran "$t")" ;;
      nodeps)   rm -rf "${t%/$CT}/.git"; cr "$t" --cache; [ "$RC" = 0 ] && [ "$(ran "$t")" = abi ] && grep -q 'Cache: DEGRADED — suite-impact.sh --deps-all exited' <<<"$OUT" && echo held || echo "broken rc=$RC ran=$(ran "$t")" ;;
      hitlabel) cr "$t" --cache >/dev/null 2>&1; cr "$t" --cache; [ "$RC" = 0 ] && grep -qxF 'Test cases passed: 4' <<<"$OUT" && grep -qF '>>> running: a.test.sh (cached)' <<<"$OUT" && grep -qxF 'Cache hits: i.test.sh, a.test.sh, b.test.sh' <<<"$OUT" && echo held || echo "broken" ;;
      *)        echo "broken: unknown scenario $k" ;;
    esac
  }
  # tooth <label> <scenario> <sed-expr>
  tooth() {
    local lbl="$1" k="$2" expr="$3" tg tm g m
    tg="$(ctree "teeth-$lbl-good")"; g="$(scn "$k" "$tg")"
    if [ "$g" != held ]; then no "teeth-$lbl: the real runner does not hold scenario '$k' ($g) — the tooth cannot discriminate"; return; fi
    mkdir -p "$TMP/mut-$lbl"
    if ! mutant_sed "$SUT" "$TMP/mut-$lbl/run-all.sh" "$expr" 2>"$TMP/mut-$lbl/err"; then no "teeth-$lbl: no mutant: $(cat "$TMP/mut-$lbl/err")"; return; fi
    tm="$(ctree "teeth-$lbl-mut")"; cp "$TMP/mut-$lbl/run-all.sh" "$tm/run-all.sh"; cgit -C "${tm%/$CT}" commit -qam mutant
    m="$(scn "$k" "$tm")"
    case "$m" in
      broken*) ok "teeth-$lbl: the mutant breaks scenario '$k' ($m)" ;;
      *)       no "teeth-$lbl: the mutant still holds scenario '$k' (THEATER)" ;;
    esac
  }
    tooth reuse-lookup reuse '/SENTINEL-CACHE-HIT/ s/if \[\[ "\$hdr"/if false \&\& [[ "$hdr"/'
  tooth key-suite suite 's/""suite \$rel \${chash\[\$rel\]}"/""suite $rel x"/'
  tooth key-dep dep 's/km+="dep \$f \${chash\[\$f\]}"/km+="dep $f x"/'
  tooth key-lib lib 's/"\$rel_tests"\/lib\/\*|//'
  tooth key-runall runall 's/"\$rel_tests"\/run-all\.sh|//'
  tooth key-manifest manifest 's/"\$rel_tests"\/impact-\*\.txt|//'
  tooth key-install install 's/^      research-sdd\/install\/\*) glob_sig/      research-sdd\/NOPE\/*) glob_sig/'
  tooth key-mode mode 's/prove=\${PROVE_TEETH:-none}/prove=x/'
  tooth key-env env 's/\[\[ "\$v" == RSDD_\* \]\]/[[ "$v" == NOPE_* ]]/'
  tooth key-tool tool 's/tool_sig+="tool \$t \$v \$h"/tool_sig+="tool $t"/'
  tooth key-outside outside 's/km+="outside \${g_path\[\$gi\]} \${ghash\[\$gi\]}"/:/'
  tooth always-run-uncacheable always 's/if \[\[ -n "\${calways\[\$rel\]+set}" \]\]; then reason="always-run"/if false; then reason="always-run"/'
  tooth key-tool-presence tool2 's/(bash python3 node git jq shellcheck bwrap /(bash python3 node git jq shellcheck /'
  tooth key-shard-join sj 's/"\$rel_tests"\/shard-join\.sh|//'
  tooth key-env-quoting quote 's/\$(printf .%q. "\${!v}")/${!v}/'
  tooth note-cached-not-checked note 's/_cache_note=" (\${#cache_hit_names\[@\]} cached suites not checked)"/_cache_note=""/'
  tooth tier-not-in-key notier 's/lane=\${LANE_ARG:-none}"/lane=${LANE_ARG:-none} tier=$TIER"/'
  tooth blind-never-cached blind 's/if \[\[ -n "\${cblind\[\$rel\]+set}" \]\]; then reason/if false; then reason/'
  tooth unresolved-reason unres 's/elif \[\[ -n "\${cunres\[\$rel\]+set}" \]\]; then reason="no dependency resolved"/elif false; then reason="no dependency resolved"/'
  tooth fail-never-stored fail 's/"\$_res" == PASS \&\& //; s/"\${s_failed:-1}" -eq 0/1 -eq 1/'
  tooth skip-never-stored skip 's/"\$_res" == PASS \&\& //; s/then _suite_skip_seen=1; fi/then _suite_skip_seen=0; fi/'
  tooth skip-line-never-stored tskip 's/then _suite_skip_seen=1; fi/then _suite_skip_seen=0; fi/'
  tooth leak-never-stored leak 's/\&\& -n "\$_suite_clean" \]\]/\&\& 1 -eq 1 ]]/'
  tooth corrupt-entry-is-miss corrupt 's/if \[\[ "\$hdr" =~ .*; then   # SENTINEL-CACHE-HIT/if [[ -f "${cache_file[$s]}" ]]; then/'
  tooth refuse-require-teeth reqteeth 's/^if \[\[ -n "\$CACHE" \&\& -n "\$REQUIRE_TEETH" \]\]; then$/if false; then/'
  tooth refuse-shard shard 's/^if \[\[ -n "\$CACHE" \&\& -n "\$SHARD_N" \]\]; then$/if false; then/'
  tooth refuse-in-repo inrepo 's/^    "\$root"\/\*) echo "--cache: the cache dir/    "$root"\/NEVER) echo "--cache: the cache dir/'
  tooth degrade-no-sha nosha 's/^  command -v "\$sha" >\/dev\/null 2>&1 || { _cache_degrade/  true || { _cache_degrade/'
  tooth degrade-no-deps nodeps 's/^  if \[\[ "\$rc" -ne 0 \]\]; then$/  if false; then/'
  tooth hit-label hitlabel 's/\${_cache_hit:+ (cached)}//'
  tooth replay-output hitlabel 's/^    tail -n +2 "\${cache_file\[\$suite\]}" > "\$tmp_out"$/    : > "$tmp_out"/'
  tooth j-skips-hits jreuse 's/\[\[ "\${cache_state\[\${all_suites\[\$_pi\]}\]-}" == hit \]\] \&\& continue/false \&\& continue/'
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1
