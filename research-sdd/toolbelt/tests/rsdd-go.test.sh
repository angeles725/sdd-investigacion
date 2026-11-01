#!/usr/bin/env bash
# Bridge suite for the Go module research-sdd/rsdd (go-port plan U0.1, kit issue #2271).
# Runs `go test ./...` (through `make test`) in the module and reports each Go package as one case, so run-all.sh
# carries the Go result in its `== N passed · M failed ==` summary contract.
#
#   go absent        typed SKIP (exit 0) - FAIL instead under RSDD_REQUIRE_GO=1 (CLAUDE.md section 7:
#                    a missing prerequisite must never read as coverage in CI)
#   go too old       `go` older than go.mod's directive: typed SKIP "toolchain too old: have X need Y",
#                    or FAIL under RSDD_REQUIRE_GO=1. Go runs with GOTOOLCHAIN=local and an empty GOFLAGS,
#                    so the result never depends on a downloaded toolchain or ambient flags.
#   --parse FILE     (internal) count the package results in a captured `go test` output: prints
#                    `pass=N fail=M`, exit 1 when M > 0. The bridge's own counter is tested through it.
#   --decide-gremlins FILE [RC]
#                    (internal) print the gremlins verdict for a captured `make teeth` output and its exit
#                    code RC (default 0); the bridge's gremlins parser is tested through it.
#   --selftest-teeth (internal) run only the offline teeth-wiring self-checks (decide_gremlins diagnostics, the
#                    Makefile `make -n teeth` wiring, package scoping on a scratch git repo, verdict combining);
#                    needs make and git, never go or gremlins.
#   --teeth-packages BASE [MODDIR]
#                    (internal) print the Go packages (./rel, one per line) under MODDIR (default: the module)
#                    whose .go files changed between merge-base(BASE, HEAD) and the working tree; exit 3 when
#                    BASE cannot be resolved.
#   --combine-verdicts FILE
#                    (internal) fold the VERDICT lines of FILE into one: any FAIL -> FAIL, else any SKIP -> SKIP.
#   --prove-teeth    one mutation control on a COPY of the module in $TMPDIR (never the live tree):
#                    removing the panic boundary in internal/cli must turn the Go tests red, then gremlins runs.
#                    Scope of the gremlins step:
#                      RSDD_TEETH_BASE unset  whole-module `make teeth` (the nightly).
#                      RSDD_TEETH_BASE=<ref>  (a git ref, e.g. origin/main, set for pull_request events) only the
#                        Go packages whose .go files changed between merge-base(<ref>, HEAD) and the working tree,
#                        one `make teeth TEETH_PKG=./<pkg>` each. Zero changed packages is the typed state
#                        `teeth: n/a - no Go package changed vs <ref>` (ok, never teeth); an unresolvable <ref> is
#                        FAIL under RSDD_REQUIRE_GO=1 and SKIP otherwise.
#                    TEETH_WORKERS (default 4, Makefile) bounds gremlins' parallel mutant workers (its default is
#                    one per CPU) and TEETH_TEST_CPU (default 1) the CPUs of each mutant's test run; both pass
#                    through the environment to make.
set -uo pipefail

# count_go_output FILE -> "pass=N fail=M": one count per `ok <pkg>` / `FAIL <pkg>` line of `go test`.
# `?  <pkg> [no test files]` is neither; a `FAIL` with no package (summary line) is not counted.
count_go_output() {
  awk '$1=="ok"{p++} $1=="FAIL" && $2!=""{f++} END{printf "pass=%d fail=%d\n", p+0, f+0}' "$1"
}

# decide_gremlins FILE RC -> prints the report line(s), then `VERDICT: PASS|FAIL|SKIP <detail>`.
# Gate = no LIVED mutant among the covered ones. Timed-out and not-covered mutants are reported, never
# failed. Three input states stay distinct (CLAUDE.md section 7):
#   - a complete, numeric summary (Killed/Lived/Not covered + Timed out lines): judged on LIVED;
#   - no summary AND a non-zero rc: gremlins itself did not run (no network, no module cache, no build):
#     SKIP - or FAIL under RSDD_REQUIRE_GO=1; a SKIP is never counted as teeth;
#   - anything else (a "Killed:"/"Timed out:" line that is not numeric, only one of the two lines, or no
#     summary at all after rc=0): gremlins ran but its output cannot be read - typed FAIL, never a pass.
decide_gremlins() {
  local f="$1" rc="$2" counts l
  counts="$(awk '
    /^Killed:/ { kl++; gsub(/,/,""); if ($3=="Lived:" && $5=="Not" && $6=="covered:" && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/) { k=$2; l=$4; n=$7; kok=1 } }
    /^Timed out:/ { tl++; gsub(/,/,""); if ($3 ~ /^[0-9]+$/) { t=$3; tok=1 } }
    END { if (kl==1 && tl==1 && kok && tok) printf "killed=%d lived=%d timed_out=%d not_covered=%d\n", k, l, t, n }' "$f")"
  if [ -z "$counts" ]; then
    local why cause; why="$(tail -n 3 "$f" | tr '\n' ' ')"
    # The make trailer alone hides the real cause (a failing baseline `go test` prints only `exit status 1`),
    # so the first failure-looking lines lead the verdict text and a bounded tail follows as context.
    cause="$(grep -m 3 -E -e '^--- FAIL' -e $'^FAIL\t' -e 'panic:' -e '^go: ' "$f" | tr '\n' '|')"
    [ -n "$cause" ] && why="cause: ${cause%|} ... $why"
    if ! grep -q -e '^Killed:' -e '^Timed out:' "$f" && [ "$rc" -ne 0 ]; then
      if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then echo "VERDICT: FAIL gremlins did not run (rc=$rc, RSDD_REQUIRE_GO=1): $why"
      else echo "VERDICT: SKIP gremlins did not run (rc=$rc): $why"; fi
    else
      echo "VERDICT: FAIL gremlins summary unparseable (rc=$rc): $why"
    fi
    echo "  context (last 20 lines of the captured output):"
    tail -n 20 "$f" | sed 's/^/    | /'
    return 0
  fi
  echo "gremlins: $counts"
  l="${counts#*lived=}"; l="${l%% *}"
  if [ "$l" -gt 0 ]; then
    awk '/ LIVED / && / at /{sub(/.* at /,""); print "  LIVED at " $0}' "$f"
    echo "VERDICT: FAIL $l lived mutant(s) among the covered ones"
  else
    echo "VERDICT: PASS no lived mutants ($counts)"
  fi
}

# changed_go_packages MODDIR BASE -> prints one Go package per line ("." or "./rel", sorted), for every package
# under MODDIR with a .go file (test files included) changed between merge-base(BASE, HEAD) and the working
# tree (tracked edits, deletions and untracked files). A package whose directory is gone or holds no .go
# file any more is skipped, as are testdata and _/. directories (the go tool ignores them). Exit 3: MODDIR
# is not in a git work tree or BASE has no merge-base with HEAD (the caller types that state).
changed_go_packages() {
  local mod="$1" base="$2" top mb f d lines
  top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" rev-parse --show-toplevel 2>/dev/null)" || return 3
  mb="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$top" merge-base "$base" HEAD 2>/dev/null)" || return 3
  lines="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" diff --name-only --no-renames --relative "$mb" -- .)" || return 3
  lines="$lines
$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" ls-files --others --exclude-standard -- .)" || return 3
  while IFS= read -r f; do
    case "$f" in *.go) ;; *) continue ;; esac
    d="$(dirname "$f")"
    case "/$d/" in */testdata/*|*/_*|*/.[!/]*) continue ;; esac
    [ -d "$mod/$d" ] || continue
    compgen -G "$mod/$d/*.go" >/dev/null || continue
    if [ "$d" = "." ]; then echo "."; else echo "./$d"; fi
  done <<<"$lines" | LC_ALL=C sort -u
}

# combine_verdicts FILE -> one VERDICT line from the VERDICT lines of FILE: any FAIL -> FAIL, else any SKIP -> SKIP,
# else PASS. No VERDICT line at all is a FAIL (a silent zero proves nothing).
combine_verdicts() {
  awk '
    /^VERDICT: FAIL/ { f++; if (ff=="") ff=substr($0, 10) }
    /^VERDICT: SKIP/ { k++; if (kk=="") kk=substr($0, 10) }
    /^VERDICT: PASS/ { p++ }
    END {
      if (f > 0) printf "VERDICT: FAIL %d of %d package run(s) failed; first: %s\n", f, f+k+p, ff
      else if (k > 0) printf "VERDICT: SKIP %d of %d package run(s) skipped; first: %s\n", k, k+p, kk
      else if (p > 0) printf "VERDICT: PASS no lived mutants in %d package run(s)\n", p
      else print "VERDICT: FAIL no package verdict to combine"
    }' "$1"
}

if [ "${1:-}" = "--decide-gremlins" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --decide-gremlins needs a readable FILE" >&2; exit 2; }
  decide_gremlins "$2" "${3:-0}"; exit 0
fi

if [ "${1:-}" = "--parse" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --parse needs a readable FILE" >&2; exit 2; }
  res="$(count_go_output "$2")"; echo "$res"
  [ "${res##*fail=}" -eq 0 ]; exit $?
fi

if [ "${1:-}" = "--combine-verdicts" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --combine-verdicts needs a readable FILE" >&2; exit 2; }
  combine_verdicts "$2"; exit 0
fi

if [ "${1:-}" = "--teeth-packages" ]; then
  [ -n "${2:-}" ] || { echo "FATAL: --teeth-packages needs a BASE ref" >&2; exit 2; }
  changed_go_packages "${3:-$(cd "$(dirname "$0")/../../rsdd" && pwd)}" "$2"; exit $?
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="${RSDD_GO_MOD:-$HERE/../../rsdd}"   # RSDD_GO_MOD: a mutant copy of this suite lives elsewhere
[ -f "$MOD/go.mod" ] || { echo "FATAL: Go module not found: $MOD" >&2; exit 2; }
MOD="$(cd "$MOD" && pwd)"

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# selftest_teeth DIR: the offline checks of the teeth wiring and scoping (no go, no gremlins). DIR is scratch.
selftest_teeth() {
  local dir="$1" g c crc d
  # Diagnostics: a failing baseline `go test` inside gremlins prints only `exit status 1`; the verdict must
  # still name the failing test even when it is further up than the last three lines.
  printf '%s\n' '--- FAIL: TestX (0.00s)' '    x_test.go:12: boom' 'FAIL' $'FAIL\texample.test/m/b\t0.005s' \
    'exit status 1' 'make: *** [Makefile:62: teeth] Error 1' "make: Leaving directory '/x'" > "$dir/gr-baseline.out"
  g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$dir/gr-baseline.out" 2)"
  if grep -q '^VERDICT: FAIL gremlins did not run (rc=2, RSDD_REQUIRE_GO=1): cause: --- FAIL: TestX' <<<"$g" && grep -q '^    | .*x_test.go:12: boom' <<<"$g"; then
    ok "gremlins: a baseline test failure names TestX in the verdict and prints a bounded tail"
  else no "gremlins: baseline failure not diagnosable: $g"; fi
  g="$(RSDD_REQUIRE_GO='' bash "$0" --decide-gremlins "$dir/gr-baseline.out" 2)"
  if grep -q '^VERDICT: SKIP gremlins did not run (rc=2): cause: --- FAIL: TestX' <<<"$g"; then
    ok "gremlins: the cause also leads the typed SKIP"; else no "gremlins: SKIP lacks the cause: $g"; fi
  # Wiring (like the containment fixtures, read from the real Makefile): bounded workers and test CPUs, scoped path.
  # env -u: a TEETH_* value exported by the caller (CI tuning) must not break the pin of the Makefile defaults.
  c="$(env -u TEETH_WORKERS -u TEETH_TEST_CPU -u TEETH_PKG make -n -C "$MOD" teeth 2>&1)"
  if grep -Eq 'unleash --timeout-coefficient 6 --workers 4 --test-cpu 1 \.$' <<<"$c"; then
    ok "teeth wiring: default is 4 workers, 1 test CPU, the whole module"; else no "teeth wiring: default wrong: $c"; fi
  c="$(make -n -C "$MOD" teeth TEETH_WORKERS=2 TEETH_TEST_CPU=3 TEETH_PKG=./internal/cli 2>&1)"
  if grep -Eq 'unleash --timeout-coefficient 6 --workers 2 --test-cpu 3 \./internal/cli$' <<<"$c"; then
    ok "teeth wiring: TEETH_WORKERS, TEETH_TEST_CPU and TEETH_PKG override"; else no "teeth wiring: override wrong: $c"; fi

  # Package scoping on a scratch repo: the module is a subdirectory, so --relative matters.
  local r="$dir/scope" m="$dir/scope/mod"
  local gi=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -C "$dir/scope")
  mkdir -p "$m"/{a,m/n,z,gone,q,testdata/t,_skip} "$r/other"
  for d in a m/n z gone q testdata/t _skip; do printf 'package p\n' > "$m/$d/p.go"; done
  printf 'package p\n' > "$m/root.go"; printf 'package o\n' > "$r/other/o.go"; printf 'module m\n' > "$m/go.mod"
  "${gi[@]}" init -q && "${gi[@]}" add -A && "${gi[@]}" commit -q --no-verify -m c1 || { no "package scope: scratch repo setup failed"; return 0; }
  "${gi[@]}" branch feat
  printf '// main moved\n' >> "$m/q/p.go"; "${gi[@]}" commit -q --no-verify -am c2          # base advances after the branch point
  "${gi[@]}" checkout -q feat
  printf '// edit\n' >> "$m/a/p.go"                          # FIRST package, non-test edit
  mv "$m/m/n/p.go" "$m/m/n/p_test.go"                       # MIDDLE package, only a _test.go remains
  printf 'package p\n' > "$m/z/new.go"                       # LAST package, untracked new file
  rm -r "$m/gone"                                           # deleted package dir
  printf '// edit\n' >> "$m/testdata/t/p.go"; printf '// edit\n' >> "$m/_skip/p.go"
  printf 'doc\n' > "$m/README.md"; printf '// edit\n' >> "$r/other/o.go"   # not Go in the module / outside the module
  c="$(bash "$0" --teeth-packages main "$m")"; crc=$?
  if [ "$crc" -eq 0 ] && [ "$c" = "$(printf '%s\n' ./a ./m/n ./z)" ]; then
    ok "package scope: first/middle/last, _test.go-only and untracked counted; deleted dir, testdata, _dir, non-Go, outside-module and base-only changes are not"
  else no "package scope: got rc=$crc [$(tr '\n' ' ' <<<"$c")]"; fi
  printf '// edit\n' >> "$m/root.go"
  c="$(bash "$0" --teeth-packages main "$m")"
  if grep -qx '\.' <<<"$c"; then ok "package scope: a change in the module root package is '.'"; else no "package scope: root package missing: $c"; fi
  "${gi[@]}" add -A && "${gi[@]}" commit -q --no-verify -m c3
  c="$(bash "$0" --teeth-packages HEAD "$m")"; crc=$?
  if [ "$crc" -eq 0 ] && [ -z "$c" ]; then ok "package scope: nothing changed vs HEAD -> empty list, rc 0"; else no "package scope: expected empty: rc=$crc [$c]"; fi
  bash "$0" --teeth-packages no-such-ref "$m" >/dev/null 2>&1; crc=$?
  if [ "$crc" -eq 3 ]; then ok "package scope: an unresolvable base exits 3"; else no "package scope: bad base rc=$crc, want 3"; fi
  bash "$0" --teeth-packages main "$dir" >/dev/null 2>&1; crc=$?
  if [ "$crc" -eq 3 ]; then ok "package scope: a directory outside any work tree exits 3"; else no "package scope: non-repo rc=$crc, want 3"; fi

  # Verdict folding.
  printf 'VERDICT: PASS a\nVERDICT: SKIP b\n' > "$dir/v-skip"; printf 'VERDICT: PASS a\nVERDICT: FAIL 1 lived\nVERDICT: SKIP b\n' > "$dir/v-fail"
  printf 'VERDICT: PASS a\nVERDICT: PASS b\n' > "$dir/v-pass"; : > "$dir/v-none"
  if grep -q '^VERDICT: FAIL 1 of 3 .*first: FAIL 1 lived' <<<"$(bash "$0" --combine-verdicts "$dir/v-fail")" \
     && grep -q '^VERDICT: SKIP 1 of 2' <<<"$(bash "$0" --combine-verdicts "$dir/v-skip")" \
     && grep -q '^VERDICT: PASS .* 2 package' <<<"$(bash "$0" --combine-verdicts "$dir/v-pass")" \
     && grep -q '^VERDICT: FAIL no package verdict' <<<"$(bash "$0" --combine-verdicts "$dir/v-none")"; then
    ok "verdicts: any FAIL fails, else any SKIP skips, else PASS; no verdict is a FAIL"
  else no "verdicts: combine wrong"; fi
}

if [ "${1:-}" = "--selftest-teeth" ]; then
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go-st.XXXXXX")"; trap 'rm -rf "$ROOT"' EXIT
  selftest_teeth "$ROOT"
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]; exit $?
fi

if ! command -v go >/dev/null 2>&1; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
    no "go not in PATH and RSDD_REQUIRE_GO=1 - a missing Go toolchain must fail, not skip"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  echo "SKIP: go not in PATH - Go suite skipped (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

# Hermetic toolchain: never download a newer one, ignore ambient flags and workspaces.
export GOTOOLCHAIN=local GOFLAGS='' GOWORK=off
have="$(go version | awk '{sub(/^go/, "", $3); print $3}')"
need="$(awk '$1=="go"{print $2; exit}' "$MOD/go.mod")"
echo "go: $(go version) (go.mod needs $need)"
oldest="$(printf '%s\n%s\n' "$have" "$need" | sort -V | sed -n 1p)"
if [ -z "$have" ] || [ -z "$need" ] || { [ "$oldest" = "$have" ] && [ "$have" != "$need" ]; }; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
    no "toolchain too old: have ${have:-unknown} need ${need:-unknown} (RSDD_REQUIRE_GO=1)"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  echo "SKIP: toolchain too old: have ${have:-unknown} need ${need:-unknown} - Go suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go.XXXXXX")"; trap 'rm -rf "$ROOT"' EXIT

# Case 1..N: one case per Go package that has tests. `go test` prints `ok <pkg>` or `FAIL <pkg>`;
# `?  <pkg> [no test files]` is neither. A non-zero exit with no FAIL line (build or setup error)
# is itself one failure, and zero tested packages is a failure (a silent zero proves nothing).
# `make test` runs it so every test binary carries the Makefile's memory cap and timeout (see containment).
out="$ROOT/gotest.out"
make -s -C "$MOD" test TESTFLAGS=-count=1 >"$out" 2>&1
rc=$?
counts="$(count_go_output "$out")"
npass="${counts#pass=}"; npass="${npass%% *}"
nfail="${counts##*fail=}"
while read -r _ pkg _; do ok "go test: $pkg"; done < <(awk '$1=="ok"{print}' "$out")
while read -r _ pkg _; do no "go test: $pkg"; done < <(awk '$1=="FAIL" && $2!=""{print}' "$out")
if [ "$rc" -ne 0 ] && [ "$nfail" -eq 0 ]; then
  no "go test exited $rc with no per-package FAIL line (build/setup error); tail follows"
  tail -n 15 "$out"
fi
if [ "$npass" -eq 0 ] && [ "$nfail" -eq 0 ] && [ "$rc" -eq 0 ]; then
  no "go test ran zero test packages - refusing to read that as a pass"
fi
if [ "$fail" -ne 0 ]; then tail -n 30 "$out"; fi

# Self-check of the bridge's own counter: canned FAILING go test output must count as a failure and exit
# 1; canned green output must not. Without this a parser that silently reads 0 failures would pass any run.
cat > "$ROOT/canned-fail.out" <<'CANNED'
ok  	example.test/m/a	0.004s
--- FAIL: TestX (0.00s)
FAIL
FAIL	example.test/m/b	0.005s
?   	example.test/m/c	[no test files]
FAIL
CANNED
printf 'ok  \texample.test/m/a\t0.004s\n' > "$ROOT/canned-ok.out"
bad="$(bash "$0" --parse "$ROOT/canned-fail.out")"; badrc=$?
good="$(bash "$0" --parse "$ROOT/canned-ok.out")"; goodrc=$?
if [ "$bad" = "pass=1 fail=1" ] && [ "$badrc" -eq 1 ] && [ "$good" = "pass=1 fail=0" ] && [ "$goodrc" -eq 0 ]; then
  ok "counter: canned failing output counts fail=1 and exits 1; canned green output exits 0"
else
  no "counter: got bad='$bad' rc=$badrc good='$good' rc=$goodrc"
fi

# Toolchain gate, via a fake `go` that reports an old version (never runs a test).
FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.20.1 linux/amd64"\nexit 0\n' > "$FAKEBIN/go"; chmod +x "$FAKEBIN/go"
old="$(PATH="$FAKEBIN:$PATH" RSDD_REQUIRE_GO='' bash "$0" 2>&1)"; oldrc=$?
if [ "$oldrc" -eq 0 ] && grep -q 'SKIP: toolchain too old: have 1.20.1 need ' <<<"$old"; then
  ok "toolchain: old go -> typed SKIP naming have and need"
else no "toolchain: old go should SKIP (rc=$oldrc): $old"; fi
oldreq="$(PATH="$FAKEBIN:$PATH" RSDD_REQUIRE_GO=1 bash "$0" 2>&1)"; oldreqrc=$?
if [ "$oldreqrc" -eq 1 ] && grep -q 'FAIL  toolchain too old: have 1.20.1' <<<"$oldreq"; then
  ok "toolchain: old go under RSDD_REQUIRE_GO=1 -> FAIL"
else no "toolchain: old go with REQUIRE should FAIL (rc=$oldreqrc): $oldreq"; fi

# Containment: `make test` / `make teeth` run every test binary under a memory cap and a timeout, so a
# runaway (a gremlins mutant that allocates without bound once OOM-killed the 7 GB CI runner) dies as a
# test FAILURE instead of starving the host. A throwaway module runs through the REAL Makefile: a test
# that touches 768 MiB must die "out of memory" under a 768 MiB cap and never print SURVIVED; a test
# that sleeps 20s must die at a 3s timeout. Both fixtures stop on their own, so an uncapped run is bounded.
FIX="$ROOT/runaway"; mkdir -p "$FIX"
printf 'module runaway\n\ngo 1.22\n' > "$FIX/go.mod"
cat > "$FIX/runaway_test.go" <<'GO'
package runaway

import (
	"fmt"
	"testing"
	"time"
)

func TestRunaway(t *testing.T) {
	var keep [][]byte
	for len(keep) < 24 { // 24 x 32 MiB = 768 MiB, every page touched
		b := make([]byte, 32<<20)
		for i := range b {
			b[i] = 1
		}
		keep = append(keep, b)
	}
	fmt.Println("RUNAWAY-SURVIVED", len(keep))
}

func TestHang(t *testing.T) { time.Sleep(20 * time.Second); fmt.Println("HANG-SURVIVED") }
GO
contain() { # contain MAKEFILE TEST VAR=VALUE... -> combined output; the make exit code is the last line
  local mk="$1" t="$2"; shift 2
  make -s -f "$mk" -C "$FIX" test TESTFLAGS="-count=1 -v -run $t" "$@" 2>&1; echo "rc=$?"
}
c="$(contain "$MOD/Makefile" TestRunaway TEST_MEM_KB=786432)"
if grep -q 'out of memory' <<<"$c" && ! grep -q 'RUNAWAY-SURVIVED' <<<"$c" && ! grep -qx 'rc=0' <<<"$c"; then
  ok "containment: a test binary allocating past TEST_MEM_KB dies out of memory (a FAIL, not a host OOM)"
else no "containment: runaway not contained: $(tail -n 5 <<<"$c")"; fi
c="$(contain "$MOD/Makefile" TestHang TEST_TIMEOUT=3s)"
if grep -q 'test timed out after 3s' <<<"$c" && ! grep -q 'HANG-SURVIVED' <<<"$c" && ! grep -qx 'rc=0' <<<"$c"; then
  ok "containment: a hung test binary dies at TEST_TIMEOUT"
else no "containment: hang not bounded by TEST_TIMEOUT: $(tail -n 5 <<<"$c")"; fi

# Gremlins verdict parser, on canned output.
cat > "$ROOT/gr-lived.out" <<'CANNED'
      KILLED CONDITIONALS_NEGATION at internal/cli/cli.go:10:5
       LIVED CONDITIONALS_BOUNDARY at internal/cli/cli.go:161:73
Killed: 5, Lived: 1, Not covered: 2
Timed out: 3, Not viable: 0, Skipped: 0
CANNED
cat > "$ROOT/gr-timeouts.out" <<'CANNED'
   TIMED OUT CONDITIONALS_NEGATION at internal/cli/cli.go:10:5
Killed: 5, Lived: 0, Not covered: 2
Timed out: 3, Not viable: 0, Skipped: 0
CANNED
printf 'go: downloading honnef.co/go/tools\ndial tcp: lookup proxy.golang.org: no such host\n' > "$ROOT/gr-unavailable.out"
g="$(bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0)"
if grep -q '^VERDICT: FAIL 1 lived' <<<"$g" && grep -q 'LIVED at internal/cli/cli.go:161:73' <<<"$g" && grep -q 'killed=5 lived=1 timed_out=3 not_covered=2' <<<"$g"; then
  ok "gremlins: a lived mutant FAILs and prints file:line; counts printed"; else no "gremlins: lived case wrong: $g"; fi
g="$(bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0)"
if grep -q '^VERDICT: PASS' <<<"$g" && grep -q 'timed_out=3' <<<"$g"; then
  ok "gremlins: lived=0 with timeouts PASSes and reports the timeouts"; else no "gremlins: timeouts case wrong: $g"; fi
g="$(RSDD_REQUIRE_GO='' bash "$0" --decide-gremlins "$ROOT/gr-unavailable.out" 1)"
if grep -q '^VERDICT: SKIP gremlins did not run (rc=1)' <<<"$g"; then
  ok "gremlins: tool unavailable -> typed SKIP"; else no "gremlins: unavailable case wrong: $g"; fi
# An unparseable or absent summary after a run that exited 0 is a typed FAIL (never a PASS, never a SKIP):
# gremlins ran, so the instrument is broken or its output format drifted - anti-silent-zero.
printf 'Killed: x, Lived: y, Not covered: z\nTimed out: 0, Not viable: 0, Skipped: 0\n' > "$ROOT/gr-garbled.out"
printf 'Killed: 5, Lived: 0, Not covered: 2\n' > "$ROOT/gr-partial.out"
printf 'gremlins: all done, nothing to report\n' > "$ROOT/gr-nosummary.out"
for c in garbled partial nosummary; do
  g="$(RSDD_REQUIRE_GO='' bash "$0" --decide-gremlins "$ROOT/gr-$c.out" 0)"
  if grep -q '^VERDICT: FAIL gremlins summary unparseable (rc=0)' <<<"$g" && ! grep -q '^VERDICT: \(PASS\|SKIP\)' <<<"$g"; then
    ok "gremlins: $c summary after rc=0 -> typed FAIL, never PASS or SKIP"; else no "gremlins: $c case wrong: $g"; fi
done
g="$(RSDD_REQUIRE_GO='' bash "$0" --decide-gremlins "$ROOT/gr-garbled.out" 1)"
if grep -q '^VERDICT: FAIL gremlins summary unparseable (rc=1)' <<<"$g"; then
  ok "gremlins: a garbled summary is a FAIL even when rc is non-zero (gremlins did run)"; else no "gremlins: garbled rc=1 wrong: $g"; fi
g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$ROOT/gr-unavailable.out" 1)"
if grep -q '^VERDICT: FAIL gremlins did not run (rc=1, RSDD_REQUIRE_GO=1)' <<<"$g"; then
  ok "gremlins: tool unavailable under RSDD_REQUIRE_GO=1 -> FAIL"; else no "gremlins: required-unavailable case wrong: $g"; fi

mkdir -p "$ROOT/st"; selftest_teeth "$ROOT/st"

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# --prove-teeth mutation control
# ---------------------------------------------------------------------------
echo "--- mutation control ---"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2

# ONE mutation: disable the panic boundary in internal/cli/cli.go (recover() can no longer fire).
# The runner copies the module into a scratch dir, drops the file under test over
# internal/cli/cli.go, and runs the cli package tests. The original must pass; the mutant must fail
# because the panic ESCAPES (output carries the test command's panic text), not because of a
# compile error.
ORIG_GO="$MOD/internal/cli/cli.go"
MUTDIR="$ROOT/mut"; mkdir -p "$MUTDIR"
cat > "$MUTDIR/run_cli_tests.sh" <<'SH'
#!/usr/bin/env bash
# usage: run_cli_tests.sh MODULE_DIR CLI_GO
mod="$1"; cli_go="$2"
w="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go-mut.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cp -a "$mod/." "$w/" || { echo "SETUP-FAILED: cannot copy module"; exit 9; }
cp "$cli_go" "$w/internal/cli/cli.go" || { echo "SETUP-FAILED: cannot place file"; exit 9; }
cd "$w" && go test -count=1 ./internal/cli/ 2>&1
SH
if MUTANT_SYNTAX=none mutant_chain_or_count fail "panic-boundary mutation" "$ORIG_GO" "$MUTDIR/cli.go" \
    's/if r := recover(); r != nil {/if r := interface{}(nil); r != nil {/'; then
  if mutant_tooth "teeth: removing the panic boundary turns the cli tests red" 0 1 \
      "$MUTDIR/cli.go" --orig "$ORIG_GO" \
      --good-has '^ok' --bad-has 'kaboom' --bad-lacks 'SETUP-FAILED|build failed|undefined:' -- \
      bash "$MUTDIR/run_cli_tests.sh" "$MOD" @SUT@; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Tooth for the counter: blind the parser to FAIL lines (it would then report fail=0 on canned failing
# output). The suite itself is the SUT (`--parse FILE`): the original must exit 1 with fail=1, the mutant
# must exit 0 with fail=0.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "counter mutation" "$0" "$MUTDIR/rsdd-go.test.sh" \
    's/\$1=="FAIL" \&\& \$2!=""{f++}/$1=="XFAIL" \&\& $2!=""{f++}/'; then
  if mutant_tooth "teeth: a parser blind to FAIL lines misses canned failing output" 1 0 \
      "$MUTDIR/rsdd-go.test.sh" --orig "$0" \
      --good-has 'fail=1' --bad-has 'fail=0' -- \
      bash @SUT@ --parse "$ROOT/canned-fail.out"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Tooth for the gremlins parser: an unparseable summary after rc=0 must be a FAIL; the mutant downgrades
# it to a SKIP (a silent non-gate). The suite is the SUT (`--decide-gremlins FILE RC`).
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "gremlins-unparseable mutation" "$0" "$MUTDIR/rsdd-go-gr.test.sh" \
    's/VERDICT: FAIL gremlins summary unparseable/VERDICT: SKIP gremlins summary unparseable/'; then
  if mutant_tooth "teeth: an unparseable gremlins summary downgraded to SKIP is caught" 0 0 \
      "$MUTDIR/rsdd-go-gr.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL gremlins summary unparseable' --bad-has 'VERDICT: SKIP gremlins summary unparseable' -- \
      bash @SUT@ --decide-gremlins "$ROOT/gr-garbled.out" 0; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Teeth for the teeth wiring (the suite is the SUT: `--selftest-teeth` runs the offline checks, rc 1 on any FAIL).
# 1) a decide_gremlins that no longer greps `--- FAIL` hides the failing test again; 2) a package scope that diffs
# against BASE instead of merge-base(BASE, HEAD) reports changes the base made after the branch point.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "diagnostics mutation" "$0" "$MUTDIR/rsdd-go-diag.test.sh" \
    "s/-e '^--- FAIL' //"; then
  if mutant_tooth "teeth: a verdict that no longer greps '--- FAIL' loses the failing test name" 0 1 \
      "$MUTDIR/rsdd-go-diag.test.sh" --orig "$0" \
      --good-has 'PASS  gremlins: a baseline test failure' --bad-has 'FAIL  gremlins: baseline failure not diagnosable' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "merge-base mutation" "$0" "$MUTDIR/rsdd-go-mb.test.sh" \
    's/--relative "\$mb"/--relative "$base"/'; then
  if mutant_tooth "teeth: scoping by a plain diff against BASE (not its merge-base) is caught" 0 1 \
      "$MUTDIR/rsdd-go-mb.test.sh" --orig "$0" \
      --good-has 'PASS  package scope: first/middle/last' --bad-has 'FAIL  package scope: got' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
# 3) a teeth recipe without --workers (gremlins' one-worker-per-CPU default) is caught by the wiring pin.
if MUTANT_SYNTAX=none mutant_chain_or_count fail "workers-wiring mutation" "$MOD/Makefile" "$MUTDIR/Makefile.workers" \
    's/ --workers \$(TEETH_WORKERS)//'; then
  if mutant_tooth "teeth: a teeth recipe without --workers (unbounded mutant workers) is caught" 0 0 \
      "$MUTDIR/Makefile.workers" --orig "$MOD/Makefile" \
      --good-has '--workers 4 --test-cpu 1' --bad-lacks '--workers' -- \
      make -n -f @SUT@ -C "$MOD" teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Tooth for the containment: a Makefile whose -exec wrapper no longer sets the cap must let the runaway
# fixture allocate its 768 MiB and print RUNAWAY-SURVIVED (the fixture stops there, so this stays bounded).
if MUTANT_SYNTAX=none mutant_chain_or_count fail "memory-cap mutation" "$MOD/Makefile" "$MUTDIR/Makefile" \
    's/ulimit -v %s || exit 97/: %s/'; then
  if mutant_tooth "teeth: a test-binary wrapper without the memory cap lets the runaway survive" 2 0 \
      "$MUTDIR/Makefile" --orig "$MOD/Makefile" \
      --good-has 'out of memory' --good-lacks 'RUNAWAY-SURVIVED' --bad-has 'RUNAWAY-SURVIVED' -- \
      make -s -f @SUT@ -C "$FIX" test 'TESTFLAGS=-count=1 -v -run TestRunaway' TEST_MEM_KB=786432; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Mutation testing (gremlins, pinned in the Makefile): the gate is zero LIVED mutants among covered ones.
# RSDD_TEETH_BASE unset: the whole module. Set: only the packages changed vs that ref (see the header).
t0=$SECONDS
verdict=""
if [ -z "${RSDD_TEETH_BASE:-}" ]; then
  make -C "$MOD" teeth >"$ROOT/gremlins.out" 2>&1; mrc=$?
  verdict="$(decide_gremlins "$ROOT/gremlins.out" "$mrc")"
  echo "$verdict" | grep -v '^VERDICT:'
else
  pkgs="$(changed_go_packages "$MOD" "$RSDD_TEETH_BASE")"; prc=$?
  if [ "$prc" -ne 0 ]; then
    verdict="VERDICT: SKIP RSDD_TEETH_BASE=$RSDD_TEETH_BASE cannot be resolved (not a work tree, or no merge-base with HEAD)"
    [ "${RSDD_REQUIRE_GO:-}" = "1" ] && verdict="VERDICT: FAIL RSDD_TEETH_BASE=$RSDD_TEETH_BASE cannot be resolved (RSDD_REQUIRE_GO=1)"
  elif [ -z "$pkgs" ]; then
    echo "teeth: n/a — no Go package changed vs $RSDD_TEETH_BASE"
    ok "teeth: n/a — no Go package changed vs $RSDD_TEETH_BASE (not counted as teeth)"
    verdict="VERDICT: NA"
  else
    echo "teeth scope: changed vs $RSDD_TEETH_BASE — $(wc -l <<<"$pkgs" | tr -d ' ') package(s): $(tr '\n' ' ' <<<"$pkgs")"
    : > "$ROOT/verdicts.txt"
    while IFS= read -r p; do
      # The path reaches an unquoted $(TEETH_PKG) in the Makefile recipe: accept only plain package paths.
      case "$p" in
        .|./*) ;;
        *) echo "VERDICT: FAIL [$p] not a ./-relative package path" >> "$ROOT/verdicts.txt"; continue ;;
      esac
      if [[ "$p" == *[!A-Za-z0-9_./-]* ]]; then
        echo "VERDICT: FAIL [$p] package path has characters outside [A-Za-z0-9_./-]" >> "$ROOT/verdicts.txt"; continue
      fi
      # </dev/null: make must not read the package list this loop is consuming from stdin.
      make -C "$MOD" teeth TEETH_PKG="$p" >"$ROOT/gremlins.out" 2>&1 </dev/null; mrc=$?
      one="$(decide_gremlins "$ROOT/gremlins.out" "$mrc")"
      echo "--- teeth: $p"
      echo "$one" | grep -v '^VERDICT:'
      echo "$one" | grep '^VERDICT:' | sed "s|^VERDICT: \([A-Z]*\) |VERDICT: \1 [$p] |" >> "$ROOT/verdicts.txt"
    done <<<"$pkgs"
    verdict="$(combine_verdicts "$ROOT/verdicts.txt")"
  fi
fi
echo "gremlins wall time: $((SECONDS - t0))s"
case "$verdict" in
  "VERDICT: NA") ;;
  *"VERDICT: PASS"*) ok "teeth: gremlins found no lived mutant" ;;
  *"VERDICT: SKIP"*) echo "SKIP: ${verdict##*VERDICT: SKIP }" ;;
  *) no "teeth: gremlins: ${verdict##*VERDICT: }" ;;
esac

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
