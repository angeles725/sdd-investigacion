#!/usr/bin/env bash
# kit-size-check.test.sh — maint/kit-size-check.sh, the pre-RDD size guard (kit issue #2214).
#
# Every case builds a tiny git repo under $TMPDIR (tag `base` on the first commit) and runs the guard in it.
#
# Cases
#   thresholds   exactly at budget -> ok, budget+1 -> over-budget, hard-limit edge, hard-limit+1 -> refuse,
#                default hard-limit = 2 x budget, --budget / --hard-limit overrides, --strict exit code
#   exclusion    fixtures, lockfiles: counted apart (separate total, never hidden), not in the authored count;
#                excluded file first / middle / last in the diff; all-excluded vs empty-input vs ok
#   unmeasured   binary files (first and last in the list); pure renames (first and last), rename with edits
#   churn        mechanical-churn hotspot true positives and false positives, at the 40% / 80% / 10-line edges
#   split        over-budget prints chunks <= budget, test+SUT pair kept together
#   json         --format json is valid JSON and carries the same numbers; degraded in json
#   degraded     bad base/head ref, not a repo, no git, no merge base, bad flags, tab in a path -> exit 2
#   hygiene      read-only (git status unchanged), no temp leftovers
# Mutation controls (--prove-teeth): each boundary / exclusion / state is mutated and the case must go red.
#
# Usage: kit-size-check.test.sh [--prove-teeth]      env KSC_SUT=<path> runs the cases against another script
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="${KSC_SUT:-$TB/maint/kit-size-check.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not installed" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth mutant_cleanup_register || exit 2

T="$(mktemp -d "${TMPDIR:-/tmp}/ksc-test.XXXXXX")" || exit 2
mutant_cleanup_register "$T" || exit 2
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

# The SUT is a compatibility shim over the Go binary (kit issue #2212): `rsdd maint size-check`. The suite is the
# black-box check of the shim plus the Go command behind it. $RSDD_BIN wins; otherwise one binary is built into the
# suite temp dir (never into the tree). The behaviour's mutation controls live in the Go tests
# (internal/maint/sizecheck, `make teeth`); the controls at the end mutate the shim itself.
if [ -z "${RSDD_BIN:-}" ] || [ ! -x "${RSDD_BIN:-}" ]; then
  if ! command -v go >/dev/null 2>&1; then
    why="go not in PATH"
    [ -z "${RSDD_BIN:-}" ] || why="RSDD_BIN is not an executable file ($RSDD_BIN) and go is not in PATH"
    if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
      echo "  FAIL  rsdd-unavailable: $why (RSDD_REQUIRE_GO=1)"; echo "== 0 passed · 1 failed =="; exit 1
    fi
    echo "SKIP rsdd-unavailable: $why (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
    echo "== 0 passed · 0 failed =="; exit 0
  fi
  RSDD_BIN="$T/rsdd"
  ( cd "$TB/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$RSDD_BIN" ./cmd/rsdd ) >"$T/build.log" 2>&1 \
    || { echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$T/build.log" >&2; exit 2; }
fi
export RSDD_BIN

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
echo "== kit-size-check.test.sh =="

# ---- fixtures -----------------------------------------------------------------------------------------
# gen N PREFIX — N lines that stay distinct after the guard's normalisation (letters differ per line).
gen() { awk -v n="$1" -v p="$2" 'BEGIN { for (i = 1; i <= n; i++) { s = ""; k = i; do { s = sprintf("%c", 97 + k % 26) s; k = int(k / 26) } while (k > 0); printf "echo %s_%s done\n", p, s } }'; }
# churn N — N lines that are ONE edit repeated (digits and quoted strings differ only).
churn() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "export RSDD_X%d=\"v%d\"\n", i, i }'; }
# put REPO PATH KIND N [PREFIX] — write a file: gen | churn | mix8 (8 churn + 2 gen) | mix7 | bin
put() {
  local f="$1/$2"; mkdir -p "$(dirname "$f")"
  case "$3" in
    gen) gen "$4" "${5:-q}" >"$f" ;;
    churn) churn "$4" >"$f" ;;
    mix8) { churn 8; gen 2 zz; } >"$f" ;;
    mix7) { churn 7; gen 3 zz; } >"$f" ;;
    crlf) churn "$4" | sed 's/$/\r/' >"$f" ;;
    bin) printf '\0\1\2binary%s\0' "$4" >"$f" ;;
  esac
}
cg() { git -C "$1" "${@:2}"; }
mkrepo() {
  local r="$T/$1"; mkdir -p "$r"
  git -C "$r" init -q -b main && git -C "$r" config user.email t@t && git -C "$r" config user.name t \
    && git -C "$r" config commit.gpgsign false || exit 2
  printf 'base\n' >"$r/README"; cg "$r" add -A; cg "$r" commit -qm base; cg "$r" tag base
  echo "$r"
}
commit_all() { cg "$1" add -A; cg "$1" commit -qm "${2:-change}"; }
# scen NAME — a repo whose files the caller then adds with put(); finish with commit_all.
OUT=''; ERR=''; RC=0
run() { # DIR ARGS... -> OUT ERR RC
  local d="$1"; shift
  OUT="$(cd "$d" && bash "$SUT" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
}
has() { grep -Fq -- "$1" <<<"$OUT"; }
check() { local label="$1"; shift; if "$@"; then ok "$label"; else no "$label  [rc=$RC out=${OUT//$'\n'/ | } err=$ERR]"; fi; }
state_is() { has "size: $1"; }
rc_is() { [ "$RC" -eq "$1" ]; }
both() { rc_is "$1" && state_is "$2"; }

# ---- thresholds ---------------------------------------------------------------------------------------
r400="$(mkrepo r400)"; put "$r400" src/a.txt gen 400; commit_all "$r400"
run "$r400" --base base
check "t1 exactly at budget (400) -> size: ok, exit 0" both 0 ok
check "t1b authored line says 400" has "authored changed lines: 400 (+400 -0) in 1 file(s)"
r401="$(mkrepo r401)"; put "$r401" src/a.txt gen 401; commit_all "$r401"
run "$r401" --base base
check "t2 budget+1 -> size: over-budget, exit 0 by default" both 0 over-budget
check "t2b over-budget prints a split suggestion" has "split suggestion"
run "$r401" --base base --strict
check "t3 --strict turns over-budget into exit 3" both 3 over-budget
run "$r401" --base base --strict --format json
check "t3b --strict json exits 3 too" rc_is 3
r800="$(mkrepo r800)"; put "$r800" src/a.txt gen 800; commit_all "$r800"
run "$r800" --base base
check "t4 exactly at default hard-limit (800) -> over-budget, exit 0" both 0 over-budget
r801="$(mkrepo r801)"; put "$r801" src/a.txt gen 801; commit_all "$r801"
run "$r801" --base base
check "t5 hard-limit+1 (801) -> size: refuse, exit 3" both 3 refuse
check "t5b refuse prints a split suggestion" has "split suggestion"
r10="$(mkrepo r10)"; put "$r10" src/a.txt gen 10; commit_all "$r10"
run "$r10" --base base --budget 10
check "t6 --budget 10 with 10 lines -> ok" both 0 ok
r11="$(mkrepo r11)"; put "$r11" src/a.txt gen 11; commit_all "$r11"
run "$r11" --base base --budget 10 --hard-limit 15
check "t7 11 lines, budget 10, hard 15 -> over-budget" both 0 over-budget
r16="$(mkrepo r16)"; put "$r16" src/a.txt gen 16; commit_all "$r16"
run "$r16" --base base --budget 10 --hard-limit 15
check "t8 16 lines, budget 10, hard 15 -> refuse" both 3 refuse
r20="$(mkrepo r20)"; put "$r20" src/a.txt gen 20; commit_all "$r20"
run "$r20" --base base --budget 10
check "t9 default hard-limit is 2 x budget: 20 lines, budget 10 -> over-budget" both 0 over-budget
r21="$(mkrepo r21)"; put "$r21" src/a.txt gen 21; commit_all "$r21"
run "$r21" --base base --budget 10
check "t9b 21 lines, budget 10 -> refuse" both 3 refuse
run "$r400" --base base --budget 400 --hard-limit 400
check "t10 hard-limit == budget is allowed (400 lines -> ok)" both 0 ok

# ---- exclusion ----------------------------------------------------------------------------------------
rfix="$(mkrepo rfix)"
put "$rfix" aaa.txt gen 5 aa; put "$rfix" research-sdd/toolbelt/tests/fixtures/ksc/data.json gen 500 jj; put "$rfix" zzz.txt gen 7 zz
commit_all "$rfix"
run "$rfix" --base base
check "x1 fixture first/middle/last edges: authored = 12 (5 + 7), fixture not counted" has "authored changed lines: 12 (+12 -0) in 2 file(s)"
check "x1b excluded total printed separately, with its file" has "excluded (generated/fixture/lockfile, not counted): 500 line(s) in 1 file(s)"
check "x1c excluded file is listed by name" has "research-sdd/toolbelt/tests/fixtures/ksc/data.json"
check "x1d verdict ok" state_is ok
rfx="$(mkrepo rfx)"; FX=research-sdd/toolbelt/tests/fixtures/ksc-logic
put "$rfx" $FX/shim.sh gen 10 fs; put "$rfx" $FX/helper.py gen 10 fp; put "$rfx" $FX/mod.mjs gen 10 fm; put "$rfx" $FX/data.json gen 100 fd
commit_all "$rfx"
run "$rfx" --base base
check "x5 fixture *.sh / *.py / *.mjs are reviewed logic and counted (30); fixture data stays excluded (100)" has "authored changed lines: 30 (+30 -0) in 3 file(s)"
check "x5b the data fixture is the only exclusion" has "excluded (generated/fixture/lockfile, not counted): 100 line(s) in 1 file(s)"
rlock="$(mkrepo rlock)"
put "$rlock" src/real.txt gen 3 rl; put "$rlock" package-lock.json gen 100 pl; put "$rlock" Cargo.lock gen 100 cl
put "$rlock" web/pnpm-lock.yaml gen 100 yl; put "$rlock" go.sum gen 100 gs
commit_all "$rlock"
run "$rlock" --base base
check "x2 lockfiles (package-lock, *.lock, pnpm-lock, go.sum) excluded: authored 3" has "authored changed lines: 3 (+3 -0) in 1 file(s)"
check "x2b four excluded files, 400 lines, shown" has "excluded (generated/fixture/lockfile, not counted): 400 line(s) in 4 file(s)"
rfo="$(mkrepo rfo)"; put "$rfo" research-sdd/toolbelt/tests/fixtures/merge-gate/wf-real-toolbelt-tests.yml gen 900 wf; commit_all "$rfo"
run "$rfo" --base base
check "x3 only excluded files changed -> size: all-excluded (not ok), exit 0" both 0 all-excluded
check "x3b all-excluded still prints the excluded total" has "900 line(s) in 1 file(s)"
run "$r400" --base base --head base
check "x4 empty diff -> size: empty-input, exit 0" both 0 empty-input
check "x4b empty-input is not all-excluded" bash -c '! grep -Fq "size: all-excluded" <<<"$0"' "$OUT"

# ---- unmeasured (binary) and renames ------------------------------------------------------------------
rbin="$(mkrepo rbin)"; put "$rbin" aaa.bin bin 1; put "$rbin" mid.txt gen 3 mb; put "$rbin" zzz.bin bin 2; commit_all "$rbin"
run "$rbin" --base base
check "u1 binary first and last are listed as unmeasured (2), text counted (3)" has "unmeasured (binary): 2 file(s)"
check "u1b authored 3 only" has "authored changed lines: 3 (+3 -0) in 1 file(s)"
check "u1c unmeasured files named" has "  unmeasured  zzz.bin"
rbo="$(mkrepo rbo)"; put "$rbo" only.bin bin 1; commit_all "$rbo"
run "$rbo" --base base
check "u2 only a binary file: verdict unmeasured (0 lines is not small), exit 0" both 0 unmeasured
check "u2b the binary is listed" has "unmeasured (binary): 1 file(s)"
rbx="$(mkrepo rbx)"; put "$rbx" only.bin bin 1; put "$rbx" research-sdd/toolbelt/tests/fixtures/ksc/d.json gen 20 bx; commit_all "$rbx"
run "$rbx" --base base
check "u3 binary + excluded data only -> size: all-excluded" both 0 all-excluded
check "u3b the binary is still listed as unmeasured" has "unmeasured (binary): 1 file(s)"
rren="$(mkrepo rren)"
put "$rren" aaa_old.txt gen 40 ra; put "$rren" mid_old.txt gen 40 rm; put "$rren" zzz_old.txt gen 40 rz; commit_all "$rren" seed; cg "$rren" tag seed
cg "$rren" mv aaa_old.txt aaa_new.txt; cg "$rren" mv zzz_old.txt zzz_new.txt; printf 'added line\n' >>"$rren/mid_old.txt"; commit_all "$rren" move
run "$rren" --base seed
check "r1 two pure renames (first and last in the list) are 0 lines, listed" has "pure renames (0 lines): 2 file(s)"
check "r1b rename pair shown as old -> new" has "  rename  zzz_old.txt -> zzz_new.txt"
check "r1c only the edit counts (1 line)" has "authored changed lines: 1 (+1 -0) in 1 file(s)"
rro="$(mkrepo rro)"; put "$rro" one_old.txt gen 40 ro; commit_all "$rro" seed; cg "$rro" tag seed; cg "$rro" mv one_old.txt one_new.txt; commit_all "$rro" move
run "$rro" --base seed
check "r2 a single pure rename: authored 0, verdict unmeasured (not ok, not empty-input)" both 0 unmeasured
check "r2b rename listed" has "  rename  one_old.txt -> one_new.txt"

# ---- mechanical churn ---------------------------------------------------------------------------------
rc_pos="$(mkrepo rc_pos)"; put "$rc_pos" hooks/wire.sh churn 60 ; put "$rc_pos" other.txt gen 10 oc; commit_all "$rc_pos"
run "$rc_pos" --base base
check "c1 60 repeated-pattern lines of 70 -> mechanical churn hotspot named" has "mechanical churn: hooks/wire.sh holds 85% of the lines (60)"
check "c1b hotspot suggests a switch or a separate PR and cites #2200 / RSDD_INIT_WIRING" has "RSDD_INIT_WIRING"
rc_neg="$(mkrepo rc_neg)"; put "$rc_neg" hooks/wire.sh gen 60 wn; put "$rc_neg" other.txt gen 10 on; commit_all "$rc_neg"
run "$rc_neg" --base base
check "c2 same size, distinct lines -> no hotspot (false-positive guard)" bash -c '! grep -Fq "mechanical churn" <<<"$0"' "$OUT"
rc40="$(mkrepo rc40)"; put "$rc40" a_churn.sh churn 40; put "$rc40" b_real.sh gen 60 b4; commit_all "$rc40"
run "$rc40" --base base
check "c3 churn file at exactly 40% of the lines -> NOT flagged (strictly greater)" bash -c '! grep -Fq "mechanical churn" <<<"$0"' "$OUT"
rc41="$(mkrepo rc41)"; put "$rc41" a_churn.sh churn 41; put "$rc41" b_real.sh gen 59 b4; commit_all "$rc41"
run "$rc41" --base base
check "c4 churn file at 41% -> flagged" has "mechanical churn: a_churn.sh holds 41%"
rc8="$(mkrepo rc8)"; put "$rc8" m.sh mix8; commit_all "$rc8"
run "$rc8" --base base
check "c5 8 of 10 added lines share a pattern (80%) -> flagged" has "mechanical churn: m.sh"
rc7="$(mkrepo rc7)"; put "$rc7" m.sh mix7; commit_all "$rc7"
run "$rc7" --base base
check "c6 7 of 10 share a pattern (70%) -> not flagged" bash -c '! grep -Fq "mechanical churn" <<<"$0"' "$OUT"
rc9="$(mkrepo rc9)"; put "$rc9" m.sh churn 9; commit_all "$rc9"
run "$rc9" --base base
check "c7 9 identical-pattern lines (< 10 minimum) -> not flagged" bash -c '! grep -Fq "mechanical churn" <<<"$0"' "$OUT"
rc10="$(mkrepo rc10)"; put "$rc10" m.sh churn 10; commit_all "$rc10"
run "$rc10" --base base
check "c8 10 identical-pattern lines (the minimum) -> flagged" has "mechanical churn: m.sh"

# ---- split suggestion ---------------------------------------------------------------------------------
rsp="$(mkrepo rsp)"
put "$rsp" research-sdd/toolbelt/bar.sh gen 100 sb; put "$rsp" research-sdd/toolbelt/foo.sh gen 200 sf
put "$rsp" research-sdd/toolbelt/tests/foo.test.sh gen 200 st; put "$rsp" xtra/zzz.md gen 100 sz; commit_all "$rsp"
chunk_of() { awk -v f="$1" '/^  chunk [0-9]+:/ { c = $2; sub(/:/, "", c) } $NF == f && c != "" { print c }' <<<"$OUT"; }
run "$rsp" --base base --budget 450 --hard-limit 900
check "s1 600 lines over a 450 budget -> over-budget" state_is over-budget
sut_chunk="$(chunk_of research-sdd/toolbelt/foo.sh)"; test_chunk="$(chunk_of research-sdd/toolbelt/tests/foo.test.sh)"
check "s2 the test and its SUT land in the same chunk ($sut_chunk / $test_chunk)" bash -c '[ -n "$0" ] && [ "$0" = "$1" ]' "$sut_chunk" "$test_chunk"
check "s3 three chunks for 100 | 400 | 100" has "chunk 3: 100 lines"
check "s3b every chunk is within the budget" bash -c '! grep -Eq "^  chunk [0-9]+: ([5-9][0-9]{2}|[0-9]{4,}) lines" <<<"$0"' "$OUT"
run "$r801" --base base
check "s4 a single 801-line unit is flagged as exceeding the budget on its own" has "single-unit-over-budget"

rpm="$(mkrepo rpm)"
put "$rpm" research-sdd/toolbelt/maint/foo.sh gen 200 pf; put "$rpm" research-sdd/toolbelt/tests/foo.test.sh gen 200 pt
put "$rpm" research-sdd/toolbelt/lib/bar.sh gen 100 pb; put "$rpm" research-sdd/toolbelt/tests/bar.test.sh gen 100 pc; commit_all "$rpm"
run "$rpm" --base base --budget 450 --hard-limit 900
check "s5 maint/ SUT and its toolbelt test share a chunk" bash -c '[ -n "$0" ] && [ "$0" = "$1" ]' "$(chunk_of research-sdd/toolbelt/maint/foo.sh)" "$(chunk_of research-sdd/toolbelt/tests/foo.test.sh)"
check "s5b lib/ SUT and its toolbelt test share a chunk" bash -c '[ -n "$0" ] && [ "$0" = "$1" ]' "$(chunk_of research-sdd/toolbelt/lib/bar.sh)" "$(chunk_of research-sdd/toolbelt/tests/bar.test.sh)"
check "s5c two chunks (bar pair 200, foo pair 400)" has "chunk 2: 400 lines"

# ---- base advanced after the fork ---------------------------------------------------------------------
radv="$(mkrepo radv)"; cg "$radv" checkout -q -b feat; put "$radv" feat.txt gen 5 fa; commit_all "$radv" feat
cg "$radv" checkout -q main; put "$radv" main_only.txt gen 500 ma; commit_all "$radv" main-advance
run "$radv" --base main --head feat
check "a1 commits that only advanced the base after the fork are NOT counted (5, not 505)" has "authored changed lines: 5 (+5 -0) in 1 file(s)"
check "a1b verdict ok" state_is ok

# ---- hotspot diff failure is never silent -------------------------------------------------------------
mkdir -p "$T/fakebin"
REALGIT="$(command -v git)"
printf '#!/usr/bin/env bash\ncase " $* " in *" --unified=0 "*) exit 1 ;; esac\nexec %s "$@"\n' "$REALGIT" >"$T/fakebin/git"; chmod +x "$T/fakebin/git"
OUT="$(cd "$rc_pos" && PATH="$T/fakebin:$PATH" bash "$SUT" --base base 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
check "k1 a failing hotspot diff prints 'hotspot: unchecked <file>' (never a silent no-churn)" has "hotspot: unchecked hooks/wire.sh"
check "k1b the verdict itself is unaffected (ok, exit 0)" both 0 ok
OUT="$(cd "$rc_pos" && PATH="$T/fakebin:$PATH" bash "$SUT" --base base --format json 2>/dev/null)"; RC=$?
check "k2 json carries hotspots_unchecked" has '"hotspots_unchecked":["hooks/wire.sh"]'
run "$rc_pos" --base base --format json
check "k3 json hotspots_unchecked is empty on a healthy run" has '"hotspots_unchecked":[]'
rglob="$(mkrepo rglob)"; put "$rglob" 'w[1].sh' churn 60; put "$rglob" w1.sh gen 3 gw; commit_all "$rglob"
run "$rglob" --base base
check "k4 a path with glob characters is diffed literally and still flagged" has "mechanical churn: w[1].sh"

# ---- numeric flags ------------------------------------------------------------------------------------
run "$r10" --base base --budget 010
check "n1 --budget 010 is ten (base 10), not an octal error" both 0 ok
check "n1b header shows budget 10 / hard-limit 20" has "budget 10, hard-limit 20"
run "$r10" --base base --budget 08
check "n2 --budget 08 is eight: 10 lines -> over-budget" both 0 over-budget
check "n2b header shows budget 8 / hard-limit 16" has "budget 8, hard-limit 16"
run "$r10" --base base --budget 8 --hard-limit 009
check "n3 --hard-limit 009 is nine: 10 lines, budget 8 -> refuse" both 3 refuse
run "$r10" --base base --budget -5
check "n4 negative --budget -> usage exit 2" both 2 degraded
run "$r10" --base base --budget 1e3
check "n5 --budget 1e3 -> exit 2" both 2 degraded
run "$r10" --base base --budget 1234567890
check "n6 a 10-digit --budget (overflow guard) -> exit 2" both 2 degraded
run "$r10" --base base --hard-limit ''
check "n7 an explicitly empty --hard-limit -> exit 2 (not the default)" both 2 degraded
run "$r10" --base base --hard-limit 1234567890
check "n8 a 10-digit --hard-limit -> exit 2" both 2 degraded

# ---- json ---------------------------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  jget() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); r=eval(sys.argv[1]); print(*r) if isinstance(r, tuple) else print(r)' "$1" <<<"$OUT"; }
  run "$rfix" --base base --format json
  check "j1 json parses and carries state / authored / excluded" bash -c '[ "$0" = "ok 12 500 2" ]' "$(jget 'd["state"], d["authored"], d["excluded_lines"], len(d["files"])')"
  check "j1b excluded file is listed in json" bash -c '[ "$0" = "research-sdd/toolbelt/tests/fixtures/ksc/data.json" ]' "$(jget 'd["excluded"][0]["path"]')"
  run "$rc_pos" --base base --format json
  check "j2 hotspots in json" bash -c '[ "$0" = "hooks/wire.sh 85" ]' "$(jget 'd["hotspots"][0]["path"], d["hotspots"][0]["percent_of_total"]')"
  run "$rsp" --base base --budget 450 --hard-limit 900 --format json
  check "j3 split chunks in json (3 chunks, foo pair together)" bash -c '[ "$0" = "3 True" ]' "$(jget 'len(d["split"]), any("research-sdd/toolbelt/foo.sh" in c["files"] and "research-sdd/toolbelt/tests/foo.test.sh" in c["files"] for c in d["split"])')"
  run "$r400" --base nope --format json
  check "j4 degraded in json is still valid json with state degraded, exit 2" bash -c '[ "$0" = "degraded" ] && [ "$1" -eq 2 ]' "$(jget 'd["state"]')" "$RC"
  run "$rbin" --base base --format json
  check "j5 unmeasured binaries in json" bash -c '[ "$0" = "2" ]' "$(jget 'len(d["unmeasured"])')"
else
  echo "  SKIP  j1-j5 json parse checks: python3 not installed (the json shape is still grep-checked below)"
fi
run "$rfix" --base base --format json
check "j6 json state field" has '"state":"ok"'
check "j6b json authored field" has '"authored":12'

# ---- degraded -----------------------------------------------------------------------------------------
run "$r400" --base no-such-ref
check "d1 bad base ref -> exit 2, size: degraded" both 2 degraded
check "d1b typed stderr line" bash -c 'grep -Fq "degraded: kit-size-check: base ref does not resolve to a commit: no-such-ref" <<<"$0"' "$ERR"
run "$r400" --base base --head no-such-ref
check "d2 bad head ref -> exit 2" both 2 degraded
mkdir -p "$T/plain"
OUT="$(cd "$T/plain" && GIT_CEILING_DIRECTORIES="$T" bash "$SUT" --base x 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
check "d3 not a git work tree -> exit 2" both 2 degraded
check "d3b says why" bash -c 'grep -Fq "not inside a git work tree" <<<"$0"' "$ERR"
# d4 (git missing -> exit 2, typed) cannot run through the shim (it needs dirname on PATH): it is Go test TestGitMissingIsATypedDegradedState
rorph="$(mkrepo rorph)"; cg "$rorph" checkout -q --orphan other; cg "$rorph" rm -rfq .; printf 'x\n' >"$rorph/f"; commit_all "$rorph"
run "$rorph" --base main --head other
check "d5 no merge base -> exit 2" both 2 degraded
run "$r400"
check "d6 missing --base -> exit 2" both 2 degraded
run "$r400" --base base --budget abc
check "d7 non-numeric --budget -> exit 2" both 2 degraded
run "$r400" --base base --budget 0
check "d7b --budget 0 -> exit 2" both 2 degraded
run "$r400" --base base --budget 100 --hard-limit 50
check "d8 hard-limit below budget -> exit 2" both 2 degraded
run "$r400" --base base --frobnicate
check "d9 unknown flag -> exit 2" both 2 degraded
run "$r400" --base base --format yaml
check "d10 unknown format -> exit 2" both 2 degraded
rtab="$(mkrepo rtab)"; printf 'x\n' >"$rtab/$(printf 'a\tb')"; commit_all "$rtab"
run "$rtab" --base base
check "d11 a tab in a path is refused loudly, not mis-parsed -> exit 2" both 2 degraded
rcrp="$(mkrepo rcrp)"; printf 'x\n' >"$rcrp/$(printf 'a\rb')"; commit_all "$rcrp"
run "$rcrp" --base base
check "d11b a carriage return in a path is refused too (exit 2)" both 2 degraded
rcrl="$(mkrepo rcrl)"; put "$rcrl" crlf.sh crlf 12; commit_all "$rcrl"
run "$rcrl" --base base --format json
no_cr() { [[ $OUT != *$'\r'* ]]; }
check "d11c a CRLF file's churn pattern reaches the json with no raw CR" no_cr
check "d11d ...and the churn is still flagged" has '"path":"crlf.sh"'
if command -v python3 >/dev/null 2>&1; then
  check "d11e ...and the json parses" bash -c 'python3 -I -c "import json,sys; json.loads(sys.stdin.read())" <<<"$0"' "$OUT"
fi
run "$r400" --help
check "d12 --help prints the header incl. the #2200 pointer, exit 0" bash -c '[ "$1" -eq 0 ] && grep -Fq RSDD_INIT_WIRING <<<"$0"' "$OUT" "$RC"

# ---- hygiene ------------------------------------------------------------------------------------------
before="$(cg "$r401" status --porcelain=v1 -uall; cg "$r401" rev-parse HEAD)"
mkdir -p "$T/tmproot"
OUT="$(cd "$r401" && TMPDIR="$T/tmproot" bash "$SUT" --base base --strict 2>/dev/null)"; RC=$?
after="$(cg "$r401" status --porcelain=v1 -uall; cg "$r401" rev-parse HEAD)"
check "h1 read-only: the repo status and HEAD are unchanged" bash -c '[ "$0" = "$1" ]' "$before" "$after"
check "h2 no temp leftovers after an over-budget --strict run" bash -c '[ -z "$(ls -A "$0")" ]' "$T/tmproot"
OUT="$(cd "$r400" && TMPDIR="$T/tmproot" bash "$SUT" --base nope 2>/dev/null)"; RC=$?
check "h3 no temp leftovers after a degraded run" bash -c '[ -z "$(ls -A "$0")" ]' "$T/tmproot"

# ---- mutation controls (the shim itself; the behaviour's controls are the Go tests') ------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: the shim must dispatch to rsdd maint size-check with the caller's arguments --"
  # a mutant of the shim must still find ../lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
  KC="$T/kitcopy"; MUT="$KC/maint"; mkdir -p "$MUT" && ln -s "$TB/lib" "$KC/lib"
  cat >"$T/runner.sh" <<'EOS'
cd "$1" || exit 99
shift
exec bash "$@"
EOS
  mk() { mutant_chain "$@" || { fail=$((fail + 1)); return 1; }; }
  tt() { if mutant_tooth "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
  # shellcheck disable=SC2016  # the sed expressions are literal text
  {
    mk "s1 dispatch" "$SUT" "$MUT/s1.sh" 's/^rsdd_exec maint size-check /rsdd_exec maint gate /' \
      && tt "s1 shim dispatches to the sibling command" 0 2 "$MUT/s1.sh" --good-has "size: over-budget" --bad-lacks "size: over-budget" -- bash "$T/runner.sh" "$r401" @SUT@ --base base
    mk "s2 arguments" "$SUT" "$MUT/s2.sh" 's/^rsdd_exec maint size-check "\$@"$/rsdd_exec maint size-check/' \
      && tt "s2 shim drops the caller's arguments" 0 2 "$MUT/s2.sh" --good-has "size: over-budget" --bad-lacks "size: over-budget" -- bash "$T/runner.sh" "$r401" @SUT@ --base base
  }
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
