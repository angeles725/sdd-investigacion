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
#   --decide-gremlins FILE [RC [PKG]]
#                    (internal) print the gremlins verdict for a captured `make teeth` output and its exit
#                    code RC (default 0); the bridge's gremlins parser is tested through it. PKG is the package the
#                    run was scoped to ("ALL" = whole module): lived mutants of a package on the teeth debt list
#                    (rsdd/teeth-debt.txt, override RSDD_TEETH_DEBT; kit issue #2592) are printed as DEBT and do not
#                    fail; any other lived mutant fails; with PKG a listed package reading Lived 0 is reported STALE.
#                    A captured `make teeth` whose unmutated package failed in the module-only copy (the typed
#                    `teeth: DEGRADED — the unmutated package fails ...` line, no gremlins summary) is decided per failing
#                    package: on the debt list -> a loud `DEBT  baseline fails ...` line and PASS debt-only baseline-fail;
#                    not on it (or no package nameable) -> FAIL teeth DEGRADED, regardless of RSDD_REQUIRE_GO.
#   --load-debt FILE (internal) print the packages of a teeth debt list, or `INVALID: ...` (rc 1 bad line, rc 2 unreadable).
#   --selftest-teeth (internal) run only the offline teeth-wiring self-checks (decide_gremlins diagnostics, the
#                    Makefile `make -n teeth` wiring, package scoping on a scratch git repo, verdict combining);
#                    needs make and git, never go or gremlins.
#                    It exports RSDD_GO_SELFTEST_NESTED, and a suite run that sees it exits 2 before any go command:
#                    a self-test (or a --prove-teeth mutant copy) that re-invokes the suite can never start real Go.
#   --teeth-packages BASE [MODDIR]
#                    (internal) print the Go packages (./rel, one per line) under MODDIR (default: the module)
#                    whose .go files changed between merge-base(BASE, HEAD) and the working tree; exit 3 when
#                    BASE cannot be resolved.
#   --teeth-files BASE [MODDIR]
#                    (internal) print the per-PR teeth units (kit issue #2573): the changed non-test .go files (./rel/f.go,
#                    LC_ALL=C sorted) of every changed package; a package whose only change is a _test.go brings all its
#                    non-test files. Exit 3 when BASE cannot be resolved.
#   --teeth-exclude PKG [MODDIR]
#                    (internal) read PKG's selected files on stdin, print the gremlins --exclude-files regexp that keeps
#                    only them ("/" drops subpackages, ^(other\.go|...)$ the package's other non-test files).
#   --teeth-plan I/N [MODDIR]
#                    (internal) read the --teeth-files list on stdin, print shard I's gremlins runs: one "PKG<TAB>EXCLUDE"
#                    line per package holding at least one of the shard's files.
#   --shard-select I/N
#                    (internal) print the lines read from stdin that belong to shard I of N (see RSDD_TEETH_SHARD);
#                    exit 2 and print nothing on an invalid I/N.
#   --combine-verdicts FILE
#                    (internal) fold the VERDICT lines of FILE into one: any FAIL -> FAIL, else any SKIP -> SKIP.
#   --part-plan PART PROVE
#                    (internal) print `test=<0|1> teeth=<0|1>` for RSDD_BRIDGE_PART=PART with PROVE=1 when --prove-teeth is
#                    set; exit 2 and print nothing on an unknown PART or on PART=teeth without --prove-teeth.
#   --prove-teeth    one mutation control on a COPY of the module in $TMPDIR (never the live tree):
#                    removing the panic boundary in internal/cli must turn the Go tests red, then gremlins runs.
#                    Scope of the gremlins step:
#                      RSDD_TEETH_BASE unset  whole-module `make teeth` (the nightly).
#                      RSDD_TEETH_BASE=<ref>  (a git ref, e.g. origin/main, set for pull_request events) only the
#                        changed files (kit issue #2573): the --teeth-files units between merge-base(<ref>, HEAD) and
#                        the working tree, run as one `make teeth TEETH_PKG=./<pkg> TEETH_EXCLUDE=<regexp>` per package
#                        (--teeth-plan: only the selected files directly in <pkg>; a changed subpackage is its own
#                        entry). Zero changed files is the typed state `teeth: n/a - no Go package changed vs <ref>`
#                        (ok, never teeth); an unresolvable <ref> is FAIL under RSDD_REQUIRE_GO=1 and SKIP otherwise.
#                        A change with no _test.go edit mutates only its changed files, not the whole package: the
#                        package's unchanged sibling files are covered by the nightly whole-module run.
#                    RSDD_TEETH_SHARD=I/N (kit issues #2568, #2573; needs RSDD_TEETH_BASE) splits that flat file list
#                      across N CI jobs, so one large package spreads over all of them: after LC_ALL=C sorting, shard I
#                      keeps the files at 0-based positions p with p mod N == I-1. N is 1..32 and I is 1..N, written
#                      without leading zeros; any other value is a typed FAIL before anything runs, as is a shard with
#                      no RSDD_TEETH_BASE (the whole-module nightly is never sharded). A shard whose slice is empty
#                      (fewer files than shards) is the typed `teeth: 0 files in shard I/N` (ok); no changed file at
#                      all keeps the `n/a` state above. Shards 2..N skip the whole-module `make test` (shard 1 runs
#                      it: gremlins' own baseline run still tests each package it mutates).
#                    RSDD_BRIDGE_PART (kit issue #2617) picks which half of the suite a CI job runs, so the whole-module work no
#                    longer sits in front of shard 1's teeth: unset or `all` runs both halves (local runs, schedule and
#                    workflow_dispatch, exactly as before); `test` runs only the whole-module `make test` and the
#                    panic-boundary mutation control; `teeth` runs only the suite's own mutation controls and gremlins
#                    (it needs --prove-teeth, else nothing would run) and never `make test`. Any other value is a typed
#                    FAIL before anything runs. pull_request and push run `test` in its own job and `teeth` in the 3 shards.
#                    TEETH_WORKERS (default 4, Makefile) bounds gremlins' parallel mutant workers (its default is
#                    one per CPU) and TEETH_TEST_CPU (default 1) the CPUs of each mutant's test run (as GOMAXPROCS,
#                    never gremlins --test-cpu, whose "-cpu N" argument makes every mutant read KILLED); both pass
#                    through the environment to make.
set -uo pipefail

# Depth bound for the nested-guard self-test only (kit issue #2573): when RSDD_GO_NEST_DEPTH is set, every invocation
# increments it and a second level refuses at once (exit 3). It is independent of RSDD_GO_SELFTEST_NESTED, so the
# mutant that deletes that guard turns its self-test red instead of recursing without bound.
if [ -n "${RSDD_GO_NEST_DEPTH:-}" ]; then
  RSDD_GO_NEST_DEPTH=$(( RSDD_GO_NEST_DEPTH + 1 )); export RSDD_GO_NEST_DEPTH
  if [ "$RSDD_GO_NEST_DEPTH" -ge 2 ]; then echo "FATAL: nested suite depth $RSDD_GO_NEST_DEPTH (RSDD_GO_NEST_DEPTH bound)" >&2; exit 3; fi
fi

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
# fail_heads FILE N -> the first N output lines of every package that FAILed, so a runtime crash names its
# cause: go test prints each package's output as one block that ends with its ok / FAIL / ? line, and a
# "fatal error:" header leads the block while the goroutine dump fills its tail (kit issue #2454).
fail_heads() {
  awk -v n="$2" '
    function flush(pkg,   i, m) {
      m = (cnt < n ? cnt : n)
      print "--- head of failing " pkg " (" m " of " cnt " lines) ---" # SENTINEL-GO-FAIL-HEAD
      for (i = 1; i <= m; i++) print "    | " buf[i]
    }
    ($1 == "ok" || $1 == "?") && NF >= 2 { cnt = 0; next }
    $1 == "FAIL" && $2 != "" { flush($2); cnt = 0; next }
    { buf[++cnt] = $0 }
  ' "$1"
}

# load_debt FILE -> the packages of the teeth debt list (kit issue #2592), one "./pkg" per line. Format, one entry per
# line: `<package> #<issue> <reason>`; blank lines and lines starting with `#` are ignored. Typed states, never a
# silent empty list: rc 2 + `INVALID: ... not readable` (absent-input), rc 1 + `INVALID: line N: ...` (a bad line:
# package not a ./-relative path without `..`, issue ref not `#<digits>`, reason under 10 characters, duplicate).
load_debt() {
  [ -r "$1" ] || { echo "INVALID: debt list not readable: $1"; return 2; }
  awk '
    function bad(m) { printf "INVALID: line %d: %s\n", NR, m; err = 1; exit }
    /^[[:space:]]*$/ || /^#/ { next }
    {
      pkg = $1; ref = $2; reason = $0; sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", reason)
      if (pkg !~ /^\.\/[A-Za-z0-9_.\/-]+$/ || pkg ~ /\.\./ || pkg ~ /\/$/) bad("package [" pkg "] is not a ./-relative package path")
      if (ref !~ /^#[0-9]+$/) bad("[" ref "] is not an issue reference like #2592")
      if (length(reason) < 10) bad("reason for " pkg " is under 10 characters")
      if (pkg in seen) bad("duplicate package " pkg)
      seen[pkg] = 1; print pkg
    }
    END { if (err) exit 1 }' "$1"
}

# classify_lived FILE PKG DEBT_PACKAGES CHECK_STALE -> the report of the LIVED mutants of a captured gremlins output:
# `U <line>` (package not on the debt list: a failure), `D <pkg> <line>` (debt), `STALE <pkg>` (a listed package with
# no lived mutant, only when CHECK_STALE=1) and one final `N unlisted=<n> debt=<m>`. PKG is the package the run was
# scoped to ("ALL" = whole module, "." = the root package); gremlins prints paths relative to it.
classify_lived() {
  awk -v pkgarg="$2" -v debtlist="$3" -v stale="$4" '
    BEGIN { n = split(debtlist, arr, "\n"); for (i = 1; i <= n; i++) if (arr[i] != "") debt[arr[i]] = 1 }
    / LIVED / && / at / {
      p = $0; sub(/.* at /, "", p); sub(/:[0-9]+(:[0-9]+)?$/, "", p)
      if (pkgarg != "." && pkgarg != "ALL") p = pkgarg "/" p
      sub(/^\.\//, "", p)
      d = p; if (d ~ /\//) sub(/\/[^\/]*$/, "", d); else d = "."
      pk = (d == ".") ? "." : "./" d
      line = $0; sub(/.* at /, "", line)
      if (pk in debt) { dn++; lived[pk]++; print "D " pk " " line } else { un++; print "U " line }
    }
    END {
      if (stale == 1) for (i = 1; i <= n; i++) if (arr[i] != "" && !(arr[i] in lived) && (pkgarg == "ALL" || arr[i] == pkgarg)) print "STALE " arr[i]
      printf "N unlisted=%d debt=%d\n", un, dn
    }' "$1"
}

# decide_baseline_fail FILE -> the verdict for a `make teeth` whose UNMUTATED package failed in the module-only copy
# (kit issue #2592: the typed `teeth: DEGRADED` line). Failing packages: the run's own package, or for a whole-module
# run (`.`) the `FAIL<TAB><import path>` lines. Each one ON the teeth debt list is a loud DEBT line (its out-of-module
# test reads are pending a repoint); any other, or a whole-module failure naming no package, is a FAIL (never SKIP).
decide_baseline_fail() {
  local f="$1" dpkg debtf dl drc modpath bad="" good="" p modroot whole=0
  dpkg="$(sed -n 's/^teeth: DEGRADED — the unmutated package fails in a module-only copy: //p' "$f" | head -n 1)"
  [ "$dpkg" = "." ] && [ "${2-}" = "ALL" ] && whole=1
  if [ "$dpkg" = "." ] && [ "$whole" -eq 0 ]; then # SENTINEL-BASELINE-WHOLE-NEEDS-ALL
    echo "VERDICT: FAIL teeth DEGRADED: the whole module's baseline fails in a module-only copy, and this decision has no ALL context to judge the rest of the module"; return 0
  fi
  modroot="${RSDD_GO_MOD:-$(dirname "$0")/../../rsdd}"
  debtf="${RSDD_TEETH_DEBT:-$modroot/teeth-debt.txt}"
  dl="$(load_debt "$debtf")"; drc=$?
  if [ "$drc" -ne 0 ]; then
    echo "VERDICT: FAIL teeth debt list INVALID (baseline failed in a module-only copy: $dpkg): ${dl#INVALID: }"; return 0
  fi
  if [ "$dpkg" = "." ]; then
    modpath="$(awk '/^module /{print $2; exit}' "$modroot/go.mod" 2>/dev/null)"
    dpkg="$(awk -F'\t' -v m="$modpath" 'm != "" && $1 == "FAIL" && ($2 == m || index($2, m "/") == 1) { p = substr($2, length(m) + 2); print (p == "" ? "." : "./" p) }' "$f" | sort -u)"
  fi
  if [ -z "$dpkg" ]; then
    echo "VERDICT: FAIL teeth DEGRADED: the unmutated module fails in a module-only copy and no failing package could be named, so it cannot be shown to be teeth debt"; return 0
  fi
  while IFS= read -r p; do
    if grep -qxF -e "$p" <<<"$dl"; then good="${good:+$good }$p"; else bad="${bad:+$bad }$p"; fi
  done <<<"$dpkg"
  if [ -n "$bad" ]; then
    echo "VERDICT: FAIL teeth DEGRADED: the unmutated package fails in a module-only copy and is not on the teeth debt list: $bad"; return 0
  fi
  for p in $good; do
    echo "  DEBT  baseline fails in a module-only copy (out-of-module test reads, #2592 repoint pending): $p"
  done
  if [ "$whole" -eq 1 ]; then
    # The baseline stopped the WHOLE-module run before gremlins mutated any package, so this is not a verdict: the
    # caller (teeth_whole_module) must still judge every other package. A bare PENDING reaching a caller that does not
    # is a FAIL there (never a PASS).
    echo "VERDICT: PENDING baseline-skip $good"; return 0
  fi
  echo "VERDICT: PASS debt-only baseline-fail $(wc -w <<<"$good" | tr -d ' ') package(s) on the teeth debt list, none outside it (gremlins did not run for them)"
}
decide_gremlins() {
  local f="$1" rc="$2" counts l
  counts="$(awk '
    /^Killed:/ { kl++; gsub(/,/,""); if ($3=="Lived:" && $5=="Not" && $6=="covered:" && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/) { k=$2; l=$4; n=$7; kok=1 } }
    /^Timed out:/ { tl++; gsub(/,/,""); if ($3 ~ /^[0-9]+$/) { t=$3; tok=1 } }
    END { if (kl==1 && tl==1 && kok && tok) printf "killed=%d lived=%d timed_out=%d not_covered=%d\n", k, l, t, n }' "$f")"
  # A package with no mutable expression (e.g. a command table): gremlins exits 0, prints no summary and says
  # "No results to report.". That is a typed no-mutants PASS with explicit zero counts, never a silent one; the
  # same text after a non-zero exit, or beside a (garbled) summary line, falls through to the failure paths below.
  if [ -z "$counts" ] && [ "$rc" -eq 0 ] && grep -qx 'No results to report\.' "$f" \
     && ! grep -q -e '^Killed:' -e '^Timed out:' "$f"; then # SENTINEL-GREMLINS-NO-MUTANTS
    echo "gremlins: no-mutants killed=0 lived=0"
    echo "VERDICT: PASS no-mutants (gremlins: No results to report.)"
    return 0
  fi
  if [ -z "$counts" ] && grep -q -e '^teeth: DEGRADED — the unmutated package fails in a module-only copy: ' "$f"; then
    decide_baseline_fail "$f" "${3-}"; return 0   # SENTINEL-BASELINE-DEBT
  fi
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
  # PKG (3rd argument) is the package the run was scoped to ("ALL" = whole module). Its presence also turns on the
  # stale-entry report of the teeth debt list; without it only the lived classification below uses the list.
  local pkg="${3-}" debtf dl drc rep line un=0 dn=0
  debtf="${RSDD_TEETH_DEBT:-${RSDD_GO_MOD:-$(dirname "$0")/../../rsdd}/teeth-debt.txt}"
  if [ "$l" -eq 0 ] && [ -z "$pkg" ]; then
    echo "VERDICT: PASS no lived mutants ($counts)"; return 0
  fi
  dl="$(load_debt "$debtf")"; drc=$?
  if [ "$drc" -ne 0 ]; then
    [ "$l" -gt 0 ] && awk '/ LIVED / && / at /{sub(/.* at /,""); print "  LIVED at " $0}' "$f"
    echo "VERDICT: FAIL teeth debt list INVALID ($counts): ${dl#INVALID: }"
    return 0
  fi
  rep="$(classify_lived "$f" "${pkg:-.}" "$dl" "$([ -n "$pkg" ] && echo 1 || echo 0)")"
  while IFS= read -r line; do
    case "$line" in
      "U "*) echo "  LIVED at ${line#U }" ;;
      "D "*) line="${line#D }"; echo "  DEBT  LIVED at ${line#* } (package ${line%% *} is on the teeth debt list)" ;;
      "STALE "*) echo "  teeth debt: STALE entry ${line#STALE } reads Lived 0 - remove its line from teeth-debt.txt" ;;
      "N "*) un="${line#*unlisted=}"; un="${un%% *}"; dn="${line##*debt=}" ;;
    esac
  done <<<"$rep"
  if [ "$un" -gt 0 ]; then
    echo "VERDICT: FAIL $un lived mutant(s) among the covered ones"
  elif [ "$dn" -gt 0 ]; then
    echo "VERDICT: PASS debt-only $dn lived mutant(s) on the teeth debt list, none outside it ($counts)"
  else
    echo "VERDICT: PASS no lived mutants ($counts)"
  fi
}

# changed_paths MODDIR BASE -> every path (relative to MODDIR, one per line) changed between merge-base(BASE, HEAD)
# and the working tree: tracked edits, deletions and untracked files. Exit 3: MODDIR is not in a git work tree or
# BASE has no merge-base with HEAD (the callers type that state).
changed_paths() {
  local mod="$1" base="$2" top mb lines more
  top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" rev-parse --show-toplevel 2>/dev/null)" || return 3
  mb="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$top" merge-base "$base" HEAD 2>/dev/null)" || return 3
  lines="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" diff --name-only --no-renames --relative "$mb" -- .)" || return 3
  more="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$mod" ls-files --others --exclude-standard -- .)" || return 3
  printf '%s\n%s\n' "$lines" "$more"
}

# package_go_files MODDIR PKG -> the non-test .go files directly in PKG ("./rel/file.go", LC_ALL=C sorted).
package_go_files() {
  local f dir="$1/${2#./}"
  [ "$2" = "." ] && dir="$1"
  for f in "$dir"/*.go; do
    [ -f "$f" ] || continue
    case "$f" in *_test.go) continue ;; esac
    if [ "$2" = "." ]; then echo "./$(basename "$f")"; else echo "$2/$(basename "$f")"; fi
  done | LC_ALL=C sort
}

# changed_go_files MODDIR BASE -> the shard unit of RSDD_TEETH_SHARD (kit issue #2573): the flat, LC_ALL=C-sorted
# list ("./rel/file.go") of the non-test .go files gremlins mutates for a PR. A changed non-test file is a unit
# (a deleted one is gone). A changed package with a changed _test.go, or with no changed non-test file left,
# contributes ALL its non-test files: a test edit can change the kills of any of them (also when a non-test file
# changed alongside), and dropping the package would be a silent zero.
# _test.go files are never units (gremlins does not mutate them). Exit 3 as changed_go_packages.
changed_go_files() {
  local mod="$1" base="$2" f d lines pkgs p chg test_pkgs
  lines="$(changed_paths "$mod" "$base")" || return 3
  pkgs="$(changed_go_packages "$mod" "$base")" || return 3
  chg="$(while IFS= read -r f; do
    case "$f" in *_test.go) continue ;; *.go) ;; *) continue ;; esac
    d="$(dirname "$f")"
    case "/$d/" in */testdata/*|*/_*|*/.[!/]*) continue ;; esac
    [ -f "$mod/$f" ] || continue
    echo "./$f"
  done <<<"$lines")"
  # test_pkgs: the package dirs ("." or "./rel", as changed_go_packages prints them) holding a changed _test.go.
  test_pkgs="$(while IFS= read -r f; do
    case "$f" in *_test.go) d="$(dirname "$f")"; if [ "$d" = . ]; then echo .; else echo "./$d"; fi ;; esac
  done <<<"$lines")"
  {
    [ -z "$chg" ] || echo "$chg"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # a package keeps its changed non-test files; a test edit, or no changed non-test file, brings every one
      if grep -qxF "$p" <<<"$test_pkgs" || ! grep -qxF "$p" <<<"$(sed 's|/[^/]*$||' <<<"$chg")"; then
        package_go_files "$mod" "$p"
      fi
    done <<<"$pkgs"
  } | LC_ALL=C sort -u
}

# exclude_regexp MODDIR PKG -> reads the shard's files of PKG ("./rel/file.go") on stdin and prints the gremlins
# --exclude-files regexp (matched on the path relative to PKG) that mutates only them: "/" drops every subpackage
# file, and the package's other non-test files are listed as ^name\.go$ (a lone "/" when every file is selected).
exclude_regexp() {
  local mod="$1" pkg="$2" sel f b alts=""
  sel="$(cat)"
  while IFS= read -r f; do
    grep -qxF "$f" <<<"$sel" && continue
    b="$(basename "$f")"; b="${b//./\\.}"
    alts="${alts:+$alts|}$b"
  done < <(package_go_files "$mod" "$pkg")
  if [ -n "$alts" ]; then echo "/|^($alts)\$"; else echo "/"; fi
}

# teeth_plan MODDIR I N -> reads the changed-file list (changed_go_files) on stdin and prints the gremlins runs of
# shard I of N, one "PKG<TAB>EXCLUDE" line per package that holds at least one of the shard's files (LC_ALL=C order):
# the files at 0-based positions p with p mod N == I-1 (select_shard), grouped by the package directory they sit in,
# EXCLUDE being exclude_regexp of that package's selected files. Prints nothing when the shard's slice is empty.
teeth_plan() {
  local mod="$1" i="$2" n="$3" sel pk p f
  sel="$(select_shard "$i" "$n")"
  [ -n "$sel" ] || return 0
  pk="$(while IFS= read -r f; do echo "${f%/*}"; done <<<"$sel" | LC_ALL=C sort -u)"
  while IFS= read -r p; do
    printf '%s\t%s\n' "$p" "$(while IFS= read -r f; do if [ "${f%/*}" = "$p" ]; then echo "$f"; fi; done <<<"$sel" \
      | exclude_regexp "$mod" "$p")"
  done <<<"$pk"
}

# make_value S -> S with every "$" doubled: a value given to make on its command line is expanded again, so the
# "$" anchor of an exclude regexp would otherwise vanish (make reads "$)" as a variable named ")").
make_value() { printf '%s' "${1//\$/\$\$}"; }

# teeth_whole_module MODDIR MAKEFILE SCRATCH -> sets `verdict` (and prints the report) for a whole-module teeth run.
# One `make teeth` over the module; when its module-only BASELINE fails only in packages on the teeth debt list (kit
# issue #2592), that run stopped before gremlins mutated ANY package, and gremlins' coverage step fails on a module
# holding one failing package, so the remainder is judged package by package (`TEETH_PKG=./pkg TEETH_EXCLUDE=/`, the
# per-PR shape) over every Go package except the skipped ones. The skipped packages stay loud DEBT lines and are named
# in the PASS. A remainder that cannot be listed or run is a FAIL, never a PASS.
teeth_whole_module() {
  local mod="$1" mk="$2" sc="$3" out mrc skipped="" pk p ex one modpath
  out="$sc/gremlins.out"
  make -f "$mk" -C "$mod" teeth >"$out" 2>&1 </dev/null; mrc=$?
  verdict="$(RSDD_GO_MOD="$mod" decide_gremlins "$out" "$mrc" ALL)"
  echo "$verdict" | grep -v '^VERDICT:'
  case "$verdict" in *"VERDICT: PENDING baseline-skip "*) ;; *) return 0 ;; esac
  skipped="${verdict##*VERDICT: PENDING baseline-skip }"
  modpath="$(awk '/^module /{print $2; exit}' "$mod/go.mod" 2>/dev/null)"
  pk="$(cd "$mod" && GOTOOLCHAIN=local GOFLAGS='' go list -f '{{if .GoFiles}}{{.ImportPath}}{{end}}' ./... 2>"$sc/golist.err")"
  if [ $? -ne 0 ] || [ -z "$modpath" ] || [ -z "$pk" ]; then
    verdict="VERDICT: FAIL teeth: the baseline skipped [$skipped] and the remaining packages could not be listed (go list failed or found none)"
    return 0
  fi
  echo "teeth: baseline fails in a module-only copy for [$skipped] (listed #2592 debt): gremlins skips only those; the remaining packages run one by one"
  : > "$sc/verdicts.txt"
  while IFS= read -r p; do
    [ "$p" = "$modpath" ] && p="." || p="./${p#"$modpath"/}"
    case " $skipped " in *" $p "*) continue ;; esac
    if [[ "$p" == *[!A-Za-z0-9_./-]* ]]; then echo "VERDICT: FAIL [$p] package path has characters outside [A-Za-z0-9_./-]" >> "$sc/verdicts.txt"; continue; fi
    ex="/"   # the package's own files only: a subpackage is its own run
    make -f "$mk" -C "$mod" teeth TEETH_PKG="$p" TEETH_EXCLUDE="$ex" >"$out" 2>&1 </dev/null; mrc=$?
    one="$(RSDD_GO_MOD="$mod" decide_gremlins "$out" "$mrc" "$p")"
    echo "--- teeth: $p"
    echo "$one" | grep -v '^VERDICT:'
    echo "$one" | grep '^VERDICT:' | sed "s|^VERDICT: \([A-Z]*\) |VERDICT: \1 [$p] |" >> "$sc/verdicts.txt"
  done <<<"$pk"
  verdict="$(combine_verdicts "$sc/verdicts.txt")"
  case "$verdict" in
    "VERDICT: PASS"*) verdict="$verdict; skipped, baseline fails in a module-only copy (gremlins not run, listed #2592 debt): $skipped" ;;
  esac
}

# changed_go_packages MODDIR BASE -> prints one Go package per line ("." or "./rel", sorted), for every package
# under MODDIR with a .go file (test files included) changed between merge-base(BASE, HEAD) and the working
# tree (tracked edits, deletions and untracked files). A package whose directory is gone or holds no .go
# file any more is skipped, as are testdata and _/. directories (the go tool ignores them). Exit 3: MODDIR
# is not in a git work tree or BASE has no merge-base with HEAD (the caller types that state).
changed_go_packages() {
  local mod="$1" base="$2" f d lines
  lines="$(changed_paths "$mod" "$base")" || return 3
  while IFS= read -r f; do
    case "$f" in *.go) ;; *) continue ;; esac
    d="$(dirname "$f")"
    case "/$d/" in */testdata/*|*/_*|*/.[!/]*) continue ;; esac
    [ -d "$mod/$d" ] || continue
    compgen -G "$mod/$d/*.go" >/dev/null || continue
    if [ "$d" = "." ]; then echo "."; else echo "./$d"; fi
  done <<<"$lines" | LC_ALL=C sort -u
}

# parse_shard SPEC -> sets SHARD_I and SHARD_N, returns 0 only for I/N with N in 1..32 and I in 1..N, no leading
# zeros, signs or blanks. The length checks come first so the arithmetic never sees an overflowing number.
parse_shard() {
  [[ "$1" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || return 1
  SHARD_I="${BASH_REMATCH[1]}"; SHARD_N="${BASH_REMATCH[2]}"
  [ "${#SHARD_I}" -le 2 ] && [ "${#SHARD_N}" -le 2 ] || return 1
  [ "$SHARD_N" -le 32 ] && [ "$SHARD_I" -le "$SHARD_N" ]
}

# resolve_part PART PROVE -> sets RUN_TEST and RUN_TEETH (kit issue #2617). Returns 1 for an unknown PART, and for
# PART=teeth without --prove-teeth (PROVE=0): that job would run neither half, and a job that ran nothing must fail.
resolve_part() {
  case "$1" in
    ""|all) RUN_TEST=1; RUN_TEETH=1 ;;
    test) RUN_TEST=1; RUN_TEETH=0 ;;
    teeth) [ "$2" = 1 ] || return 1; RUN_TEST=0; RUN_TEETH=1 ;;
    *) return 1 ;;
  esac
}

# select_shard I N -> stdin lines at 0-based positions p with p mod N == I-1 (a disjoint cover for every N).
select_shard() {
  awk -v i="$1" -v n="$2" '(NR - 1) % n == i - 1' # SENTINEL-TEETH-SHARD-ASSIGN
}

# combine_verdicts FILE -> one VERDICT line from the VERDICT lines of FILE: any FAIL -> FAIL, else any SKIP -> SKIP,
# else PASS. No VERDICT line at all is a FAIL (a silent zero proves nothing), and so is a PENDING line: PENDING is not
# a verdict, only teeth_whole_module may resolve it. The reason word follows the optional `[pkg]` tag that the
# per-package loops insert after the status word (kit issue #2683).
combine_verdicts() {
  awk '
    { r = ($3 ~ /^\[/) ? $4 : $3 } # SENTINEL-COMBINE-TAG
    /^VERDICT: FAIL/ { f++; if (ff=="") ff=substr($0, 10) }
    /^VERDICT: PENDING/ { f++; if (ff=="") ff="unresolved " substr($0, 10) } # SENTINEL-COMBINE-PENDING
    /^VERDICT: SKIP/ { k++; if (kk=="") kk=substr($0, 10) }
    /^VERDICT: PASS/ { p++; if (r=="no-mutants") nm++; if (r=="debt-only") dbt++ }
    END {
      if (f > 0) printf "VERDICT: FAIL %d of %d package run(s) failed; first: %s\n", f, f+k+p, ff
      else if (k > 0) printf "VERDICT: SKIP %d of %d package run(s) skipped; first: %s\n", k, k+p, kk
      else if (p > 0) printf "VERDICT: PASS no lived mutants in %d package run(s)%s%s\n", p, (nm > 0 ? "; no-mutants: " nm : ""), (dbt > 0 ? "; debt-only: " dbt : "")
      else print "VERDICT: FAIL no package verdict to combine"
    }' "$1"
}

if [ "${1:-}" = "--decide-gremlins" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --decide-gremlins needs a readable FILE" >&2; exit 2; }
  decide_gremlins "$2" "${3:-0}" ${4:+"$4"}; exit 0
fi

if [ "${1:-}" = "--load-debt" ]; then
  [ -n "${2:-}" ] || { echo "FATAL: --load-debt needs a FILE" >&2; exit 2; }
  load_debt "$2"; exit $?
fi

if [ "${1:-}" = "--fail-heads" ]; then
  [ -r "${2:-}" ] || { echo "FATAL: --fail-heads needs a readable FILE" >&2; exit 2; }
  fail_heads "$2" "${3:-40}"; exit 0
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

if [ "${1:-}" = "--part-plan" ]; then
  resolve_part "${2:-}" "${3:-0}" || { echo "FATAL: --part-plan: bad RSDD_BRIDGE_PART [${2:-}] (all|test|teeth; teeth needs --prove-teeth)" >&2; exit 2; }
  echo "test=$RUN_TEST teeth=$RUN_TEETH"; exit 0
fi

if [ "${1:-}" = "--shard-select" ]; then
  parse_shard "${2:-}" || { echo "FATAL: --shard-select needs I/N (N 1..32, I 1..N), got [${2:-}]" >&2; exit 2; }
  select_shard "$SHARD_I" "$SHARD_N"; exit $?
fi

if [ "${1:-}" = "--teeth-packages" ]; then
  [ -n "${2:-}" ] || { echo "FATAL: --teeth-packages needs a BASE ref" >&2; exit 2; }
  changed_go_packages "${3:-$(cd "$(dirname "$0")/../../rsdd" && pwd)}" "$2"; exit $?
fi

if [ "${1:-}" = "--teeth-files" ]; then
  [ -n "${2:-}" ] || { echo "FATAL: --teeth-files needs a BASE ref" >&2; exit 2; }
  changed_go_files "${3:-$(cd "$(dirname "$0")/../../rsdd" && pwd)}" "$2"; exit $?
fi

if [ "${1:-}" = "--teeth-whole" ]; then
  [ -f "${3:-}" ] && [ -d "${2:-}" ] || { echo "FATAL: --teeth-whole needs MODDIR MAKEFILE" >&2; exit 2; }
  tw_sc="$(mktemp -d "${TMPDIR:-/tmp}/rsdd-go-tw.XXXXXX")" || exit 2
  teeth_whole_module "$2" "$3" "$tw_sc"; rm -rf "$tw_sc"
  echo "$verdict" | grep '^VERDICT:'; exit 0
fi

if [ "${1:-}" = "--teeth-exclude" ]; then
  [ -n "${2:-}" ] || { echo "FATAL: --teeth-exclude needs a PKG (./rel or .)" >&2; exit 2; }
  exclude_regexp "${3:-$(cd "$(dirname "$0")/../../rsdd" && pwd)}" "$2"; exit $?
fi

if [ "${1:-}" = "--teeth-plan" ]; then
  parse_shard "${2:-}" || { echo "FATAL: --teeth-plan needs I/N (N 1..32, I 1..N), got [${2:-}]" >&2; exit 2; }
  teeth_plan "${3:-$(cd "$(dirname "$0")/../../rsdd" && pwd)}" "$SHARD_I" "$SHARD_N"; exit $?
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
  unset RSDD_BRIDGE_PART             # the CI part was resolved already; a nested `bash "$0"` below must not inherit it (kit issue #2617)
  export RSDD_GO_SELFTEST_NESTED=1   # every `bash "$0"` below is bounded: it can never reach the real Go run
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
  c="$(env -u TEETH_WORKERS -u TEETH_TEST_CPU -u TEETH_PKG -u TEETH_EXCLUDE make -n -C "$MOD" teeth 2>&1)"
  if grep -q 'GOMAXPROCS=1 RSDD_TEST_RESEARCH_SDD=' <<<"$c" && grep -q 'go test -count=1 ./... >' <<<"$c" && grep -Eq 'unleash --timeout-coefficient 6 --workers 4 \. \)$' <<<"$c" && ! grep -q -- '--test-cpu' <<<"$c"; then
    ok "teeth wiring: default is 4 workers, 1 test CPU, the whole module"; else no "teeth wiring: default wrong: $c"; fi
  c="$(make -n -C "$MOD" teeth TEETH_WORKERS=2 TEETH_TEST_CPU=3 TEETH_PKG=./internal/cli 2>&1)"
  if grep -q 'GOMAXPROCS=3 RSDD_TEST_RESEARCH_SDD=' <<<"$c" && grep -q 'go test -count=1 ./internal/cli >' <<<"$c" && grep -Eq 'unleash --timeout-coefficient 6 --workers 2 \./internal/cli \)$' <<<"$c"; then
    ok "teeth wiring: TEETH_WORKERS, TEETH_TEST_CPU and TEETH_PKG override"; else no "teeth wiring: override wrong: $c"; fi
  c="$(make -n -C "$MOD" teeth TEETH_PKG=./internal/cli TEETH_EXCLUDE=/ 2>&1)"
  if grep -Eq -- "--workers [0-9]+ --exclude-files '/' \./internal/cli \)\$" <<<"$c"; then
    ok "teeth wiring: TEETH_EXCLUDE passes gremlins --exclude-files before the package"; else no "teeth wiring: exclude wrong: $c"; fi
  # The kit shims (verify-state.sh and the other rsdd_exec shims) need an rsdd binary; the recipe builds one unless the
  # caller sets RSDD_BIN (run-all does), and the build stays ahead of the baseline and of gremlins.
  c="$(env -u RSDD_BIN make -n -C "$MOD" teeth TEETH_PKG=./internal/cli 2>&1)"
  if grep -q 'go build -ldflags .* -o "\$rb/rsdd" ./cmd/rsdd' <<<"$c" && grep -q 'export RSDD_BIN="\$rb/rsdd"' <<<"$c"; then
    ok "teeth wiring: the recipe builds the rsdd binary into a temp dir and exports it as RSDD_BIN unless the caller set one"
  else no "teeth wiring: RSDD_BIN build missing: $c"; fi

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

  # Shard selection (kit issue #2568): RSDD_TEETH_SHARD=I/N keeps the packages at 0-based positions p with
  # p mod N == I-1 of the sorted changed list. Seven packages and N=3 put a package in the FIRST, MIDDLE and LAST
  # position of every slice; --shard-select reads the list on stdin and prints the slice.
  local pk7 s1 s2 s3 sx
  pk7="$(printf '%s\n' ./a ./b ./c ./d ./e ./f ./g)"
  s1="$(bash "$0" --shard-select 1/3 <<<"$pk7" | tr '\n' ' ')"; s2="$(bash "$0" --shard-select 2/3 <<<"$pk7" | tr '\n' ' ')"
  s3="$(bash "$0" --shard-select 3/3 <<<"$pk7" | tr '\n' ' ')"
  if [ "$s1" = "./a ./d ./g " ] && [ "$s2" = "./b ./e " ] && [ "$s3" = "./c ./f " ]; then
    ok "shard select: 1/3, 2/3 and 3/3 of seven packages are the disjoint cover a,d,g / b,e / c,f"
  else no "shard select: wrong slices [$s1] [$s2] [$s3]"; fi
  s1="$(bash "$0" --shard-select 1/1 <<<"$pk7" | tr '\n' ' ')"
  if [ "$s1" = "./a ./b ./c ./d ./e ./f ./g " ]; then ok "shard select: 1/1 keeps every package"; else no "shard select: 1/1 wrong [$s1]"; fi
  s1="$(bash "$0" --shard-select 1/3 <<<"./only")"; s2="$(bash "$0" --shard-select 2/3 <<<"./only")"; s3="$(bash "$0" --shard-select 3/3 <<<"./only")"
  if [ "$s1" = "./only" ] && [ -z "$s2" ] && [ -z "$s3" ]; then
    ok "shard select: a single package lands in shard 1 only; N > packages leaves shards 2 and 3 empty"
  else no "shard select: single package wrong [$s1] [$s2] [$s3]"; fi
  sx=ok
  for d in 0/3 4/3 1/0 3/2 abc 1/ /3 '' 1/2/3 -1/3 01/3 1/33 1/999999999999999999999 ' 1/3'; do
    s1="$(bash "$0" --shard-select "$d" <<<"$pk7" 2>/dev/null)"; crc=$?
    if [ "$crc" -ne 2 ] || [ -n "$s1" ]; then sx="[$d] rc=$crc out=[$s1]"; break; fi
  done
  if [ "$sx" = ok ]; then ok "shard select: invalid specs exit 2 and print no package (never a silent full or empty slice)"
  else no "shard select: invalid spec accepted: $sx"; fi
  # The whole suite refuses a bad or base-less shard before any go work: a typed FAIL, exit 1.
  # A fake old `go` first on PATH bounds both calls: if a mutant accepted the selector the nested suite would stop
  # at the toolchain gate (rc 0, a SKIP) instead of recursing into this self-test without end.
  mkdir -p "$dir/fakego"; printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.20.1 linux/amd64"\nexit 0\n' > "$dir/fakego/go"; chmod +x "$dir/fakego/go"
  g="$(PATH="$dir/fakego:$PATH" RSDD_REQUIRE_GO='' RSDD_TEETH_SHARD=4/3 RSDD_TEETH_BASE=main bash "$0" 2>&1)"; crc=$?
  if [ "$crc" -eq 1 ] && grep -q 'FAIL  RSDD_TEETH_SHARD=4/3 is not I/N' <<<"$g"; then
    ok "shard select: the suite fails on an invalid RSDD_TEETH_SHARD before running anything"; else no "shard select: bad shard not a FAIL (rc=$crc): $g"; fi
  g="$(PATH="$dir/fakego:$PATH" RSDD_REQUIRE_GO='' RSDD_TEETH_SHARD=1/3 RSDD_TEETH_BASE='' bash "$0" 2>&1)"; crc=$?
  if [ "$crc" -eq 1 ] && grep -q 'FAIL  RSDD_TEETH_SHARD=1/3 needs RSDD_TEETH_BASE' <<<"$g"; then
    ok "shard select: a shard without RSDD_TEETH_BASE (whole-module run) is a FAIL, not a silent full run"; else no "shard select: base-less shard not a FAIL (rc=$crc): $g"; fi

  # Part selection (kit issue #2617): RSDD_BRIDGE_PART splits the suite into the whole-module `test` half and the
  # `teeth` half so the CI test job and the 3 teeth shards run in parallel. --part-plan prints which halves run.
  local pp
  pp="$(bash "$0" --part-plan '' 0)$(bash "$0" --part-plan all 1)$(bash "$0" --part-plan test 0)$(bash "$0" --part-plan test 1)$(bash "$0" --part-plan teeth 1)"
  if [ "$pp" = "test=1 teeth=1test=1 teeth=1test=1 teeth=0test=1 teeth=0test=0 teeth=1" ]; then
    ok "part select: unset/all run both halves, test runs only make test, teeth runs only the teeth (never make test)"
  else no "part select: wrong plans [$pp]"; fi
  pp=ok
  for d in bogus Test TEETH 'test ' ' teeth' 1 test,teeth; do
    g="$(bash "$0" --part-plan "$d" 1 2>/dev/null)"; crc=$?
    if [ "$crc" -ne 2 ] || [ -n "$g" ]; then pp="[$d] rc=$crc out=[$g]"; break; fi
  done
  bash "$0" --part-plan teeth 0 >/dev/null 2>&1; crc=$?
  if [ "$pp" = ok ] && [ "$crc" -eq 2 ]; then ok "part select: an unknown part, and teeth without --prove-teeth (a job that runs nothing), exit 2 with no plan"
  else no "part select: invalid part accepted: $pp / teeth-without-prove rc=$crc"; fi
  g="$(PATH="$dir/fakego:$PATH" RSDD_REQUIRE_GO='' RSDD_BRIDGE_PART=bogus RSDD_TEETH_SHARD='' RSDD_TEETH_BASE='' bash "$0" 2>&1)"; crc=$?
  if [ "$crc" -eq 1 ] && grep -q 'FAIL  RSDD_BRIDGE_PART=bogus is not all|test|teeth' <<<"$g"; then
    ok "part select: the suite fails on an invalid RSDD_BRIDGE_PART before running anything"; else no "part select: bad part not a FAIL (rc=$crc): $g"; fi
  g="$(PATH="$dir/fakego:$PATH" RSDD_REQUIRE_GO='' RSDD_BRIDGE_PART=teeth RSDD_TEETH_SHARD='' RSDD_TEETH_BASE='' bash "$0" 2>&1)"; crc=$?
  if [ "$crc" -eq 1 ] && grep -q 'FAIL  RSDD_BRIDGE_PART=teeth .*without --prove-teeth' <<<"$g"; then
    ok "part select: the teeth part without --prove-teeth is a FAIL, never a silent empty pass"; else no "part select: teeth without prove not a FAIL (rc=$crc): $g"; fi

  # File-level shard unit (kit issue #2573): the changed non-test .go files of all changed packages, flat and
  # LC_ALL=C sorted, are what RSDD_TEETH_SHARD splits; each package is then mutated only on its shard's files.
  local fm="$dir/files/mod" fl f7 sf1 sf2 sf3 un
  local fg=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -C "$dir/files")
  mkdir -p "$fm"/{big,mid,mix,tonly,sub/deep,testdata/t}
  for f in a b c d e f g h; do printf 'package big\n' > "$fm/big/$f.go"; done
  printf 'package big\n' > "$fm/big/a_test.go"; printf 'package mid\n' > "$fm/mid/m1.go"; printf 'package mid\n' > "$fm/mid/m2.go"
  printf 'package tonly\n' > "$fm/tonly/t1.go"; printf 'package tonly\n' > "$fm/tonly/t2.go"; printf 'package tonly\n' > "$fm/tonly/t1_test.go"
  printf 'package sub\n' > "$fm/sub/s.go"; printf 'package deep\n' > "$fm/sub/deep/d.go"; printf 'package t\n' > "$fm/testdata/t/t.go"
  printf 'package mix\n' > "$fm/mix/x.go"; printf 'package mix\n' > "$fm/mix/y.go"; printf 'package mix\n' > "$fm/mix/x_test.go"
  printf 'package main\n' > "$fm/root.go"; printf 'package main\n' > "$fm/root2.go"; printf 'module m\n' > "$fm/go.mod"
  "${fg[@]}" init -q && "${fg[@]}" add -A && "${fg[@]}" commit -q --no-verify -m c1 || { no "file scope: scratch repo setup failed"; return 0; }
  "${fg[@]}" branch base
  for f in b c d e f g h; do printf '// edit\n' >> "$fm/big/$f.go"; done      # seven changed files in one package
  printf '// edit\n' >> "$fm/mix/x.go"; printf '// edit\n' >> "$fm/mix/x_test.go"   # mixed change: the test edit brings y.go too
  printf '// edit\n' >> "$fm/mid/m2.go"; printf 'package mid\n' > "$fm/mid/m3.go"   # tracked edit + untracked new file
  printf '// edit\n' >> "$fm/tonly/t1_test.go"                                # test-only package: every non-test file
  rm "$fm/sub/s.go"; printf '// edit\n' >> "$fm/sub/deep/d.go"; printf '// edit\n' >> "$fm/testdata/t/t.go"
  printf '// edit\n' >> "$fm/root2.go"
  fl="$(bash "$0" --teeth-files base "$fm")"; crc=$?
  f7="$(printf '%s\n' ./big/b.go ./big/c.go ./big/d.go ./big/e.go ./big/f.go ./big/g.go ./big/h.go ./mid/m2.go ./mid/m3.go ./mix/x.go ./mix/y.go ./root2.go ./sub/deep/d.go ./tonly/t1.go ./tonly/t2.go)"
  if [ "$crc" -eq 0 ] && [ "$fl" = "$f7" ]; then
    ok "file scope: changed non-test files are the units; _test.go, deleted, testdata and untouched files are not; a package with a test edit (test-only or mixed) brings all its non-test files"
  else no "file scope: got rc=$crc [$(tr '\n' ' ' <<<"$fl")]"; fi
  sf1="$(bash "$0" --shard-select 1/3 <<<"$fl" | tr '\n' ' ')"; sf2="$(bash "$0" --shard-select 2/3 <<<"$fl" | tr '\n' ' ')"
  sf3="$(bash "$0" --shard-select 3/3 <<<"$fl" | tr '\n' ' ')"
  if [ "$sf1" = "./big/b.go ./big/e.go ./big/h.go ./mix/x.go ./sub/deep/d.go " ] \
     && [ "$sf2" = "./big/c.go ./big/f.go ./mid/m2.go ./mix/y.go ./tonly/t1.go " ] \
     && [ "$sf3" = "./big/d.go ./big/g.go ./mid/m3.go ./root2.go ./tonly/t2.go " ] \
     && [ "$(sort <<<"$(tr ' ' '\n' <<<"$sf1$sf2$sf3" | grep .)")" = "$(sort <<<"$fl")" ]; then
    ok "file shard: 1/3, 2/3 and 3/3 of fifteen files are a disjoint cover (union = every file), so one package spreads over all jobs"
  else no "file shard: wrong slices [$sf1] [$sf2] [$sf3]"; fi
  if [ "$(bash "$0" --shard-select 1/1 <<<"$fl")" = "$fl" ]; then ok "file shard: 1/1 keeps every file"; else no "file shard: 1/1 wrong"; fi
  un="$(bash "$0" --shard-select 3/4 <<<"./only/x.go")"
  if [ -z "$un" ] && [ "$(bash "$0" --shard-select 1/4 <<<"./only/x.go")" = "./only/x.go" ]; then
    ok "file shard: a single file lands in shard 1 only; N > files leaves the other shards empty"
  else no "file shard: single file wrong [$un]"; fi
  # The exclusion regexp a package run passes to gremlins: subpackages ("/") plus the package's other non-test files.
  un="$(bash "$0" --teeth-exclude ./big "$fm" <<<"$(printf '%s\n' ./big/b.go ./big/e.go ./big/h.go)")"
  if [ "$un" = '/|^(a\.go|c\.go|d\.go|f\.go|g\.go)$' ]; then ok "file shard: a package run excludes subpackages and the package's other non-test files"
  else no "file shard: wrong exclude [$un]"; fi
  un="$(bash "$0" --teeth-exclude ./mid "$fm" <<<"$(printf '%s\n' ./mid/m1.go ./mid/m2.go ./mid/m3.go)")"
  if [ "$un" = "/" ]; then ok "file shard: a package run with every file selected excludes only subpackages (the old shape)"
  else no "file shard: full-package exclude wrong [$un]"; fi
  un="$(bash "$0" --teeth-exclude . "$fm" <<<"./root.go")"
  if [ "$un" = '/|^(root2\.go)$' ]; then ok "file shard: the root package run is scoped by file too"; else no "file shard: root exclude wrong [$un]"; fi
  # The plan the teeth loop runs: one gremlins run per package holding a shard file, excluding its other files.
  local p1 p2 p3 tab=$'\t'
  p1="$(bash "$0" --teeth-plan 1/3 "$fm" <<<"$fl")"; p2="$(bash "$0" --teeth-plan 2/3 "$fm" <<<"$fl")"
  p3="$(bash "$0" --teeth-plan 3/3 "$fm" <<<"$fl")"
  if [ "$p1" = "./big${tab}/|^(a\.go|c\.go|d\.go|f\.go|g\.go)\$
./mix${tab}/|^(y\.go)\$
./sub/deep${tab}/" ] && [ "$p2" = "./big${tab}/|^(a\.go|b\.go|d\.go|e\.go|g\.go|h\.go)\$
./mid${tab}/|^(m1\.go|m3\.go)\$
./mix${tab}/|^(x\.go)\$
./tonly${tab}/|^(t2\.go)\$" ] && [ "$p3" = ".${tab}/|^(root\.go)\$
./big${tab}/|^(a\.go|b\.go|c\.go|e\.go|f\.go|h\.go)\$
./mid${tab}/|^(m1\.go|m2\.go)\$
./tonly${tab}/|^(t1\.go)\$" ]; then
    ok "file plan: each shard runs gremlins once per package it holds, excluding that package's other files"
  else no "file plan: wrong [$p1] [$p2] [$p3]"; fi
  # Every changed file is mutated in exactly one shard: what a shard's runs do not exclude, over all shards.
  un="$(for s in 1/3 2/3 3/3; do bash "$0" --teeth-plan "$s" "$fm" <<<"$fl" | while IFS="$tab" read -r p x; do
      for f in "$fm/${p#./}"/*.go; do
        f="${f##*/}"; case "$f" in *_test.go) continue ;; esac
        grep -Eq "$x" <<<"$f" || echo "$p/$f"; done; done; done | sed 's|^\./\./|./|; s|^\.//|./|' | LC_ALL=C sort)"
  if [ "$un" = "$(LC_ALL=C sort <<<"$fl")" ]; then ok "file plan: over all shards every changed file is mutated exactly once"
  else no "file plan: mutated set [$(tr '\n' ' ' <<<"$un")] != changed files"; fi
  if [ -z "$(bash "$0" --teeth-plan 3/4 "$fm" <<<"./only/x.go")" ]; then ok "file plan: an empty shard slice plans no run"
  else no "file plan: empty slice planned a run"; fi
  # The nested guard: a self-test that re-invokes the suite can never reach the real Go run.
  mkdir -p "$dir/markgo"; printf '#!/bin/sh\ntouch "%s/markgo/RAN"\n[ "$1" = version ] && echo "go version go1.99.0 linux/amd64"\nexit 0\n' "$dir" > "$dir/markgo/go"
  chmod +x "$dir/markgo/go"
  g="$(PATH="$dir/markgo:$PATH" RSDD_TEETH_SHARD='' RSDD_TEETH_BASE='' RSDD_GO_NEST_DEPTH="${RSDD_GO_NEST_DEPTH:-0}" timeout 60 bash "$0" 2>&1)"; crc=$?
  if [ "$crc" -eq 2 ] && grep -q 'RSDD_GO_SELFTEST_NESTED set' <<<"$g" && [ ! -e "$dir/markgo/RAN" ]; then
    ok "nested guard: a self-test re-invoking the suite exits 2 before any go command runs"
  else no "nested guard: rc=$crc ran=$([ -e "$dir/markgo/RAN" ] && echo yes || echo no): $(head -c 300 <<<"$g")"; fi

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

# Recursion guard: every internal mode is handled above, so any other first argument must stop here. Without this a
# mistyped or not-yet-implemented internal mode (a self-test calls `bash "$0" --mode`) fell through to the real
# `make test` and re-ran the self-tests, a fork-bomb-shaped chain of unbounded `go test ./...` runs.
case "${1:-}" in
  ""|--prove-teeth) ;;
  *) echo "FATAL: unknown option [$1]: no internal mode by that name (refusing to fall through to the real Go run)" >&2; exit 2 ;;
esac

# Shard validation first: a bad selector must never fall back to a full or an empty run.
SHARDED=0
if [ -n "${RSDD_TEETH_SHARD+x}" ] && [ -n "${RSDD_TEETH_SHARD}" ]; then
  if ! parse_shard "$RSDD_TEETH_SHARD"; then
    no "RSDD_TEETH_SHARD=$RSDD_TEETH_SHARD is not I/N (N 1..32, I 1..N, no leading zeros)"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  if [ -z "${RSDD_TEETH_BASE:-}" ]; then
    no "RSDD_TEETH_SHARD=$RSDD_TEETH_SHARD needs RSDD_TEETH_BASE (the whole-module run is not sharded)"
    echo "== $pass passed · $fail failed =="; exit 1
  fi
  SHARDED=1
fi

# Part selection (kit issue #2617): a bad RSDD_BRIDGE_PART must never fall back to a full or an empty run.
prove=0; [ "${1:-}" = "--prove-teeth" ] && prove=1
BRIDGE_PART="${RSDD_BRIDGE_PART:-}"
if ! resolve_part "${RSDD_BRIDGE_PART:-}" "$prove"; then
  no "RSDD_BRIDGE_PART=${RSDD_BRIDGE_PART:-} is not all|test|teeth, or is teeth without --prove-teeth (the job would run nothing)"
  echo "== $pass passed · $fail failed =="; exit 1
fi
# Resolved once: the self-tests below re-invoke this suite (without --prove-teeth), which must not inherit the part.
unset RSDD_BRIDGE_PART
# The whole-module `make test` runs in the `test` part; unpartitioned it keeps its old home, shard 1.
SKIP_TEST=0
if [ "$RUN_TEST" -eq 0 ]; then SKIP_TEST=1
elif [ -z "$BRIDGE_PART" ] && [ "$SHARDED" -eq 1 ] && [ "$SHARD_I" -ne 1 ]; then SKIP_TEST=1; fi

# Nested guard: selftest_teeth exports RSDD_GO_SELFTEST_NESTED, so a self-test (or a mutant copy of this suite run by
# --prove-teeth) that re-invokes the suite can never reach the real `make test` / gremlins below. Two such chains of
# unbounded `go test ./...` runs once drove a 16-core host to load 62 (kit issue #2573).
if [ -n "${RSDD_GO_SELFTEST_NESTED:-}" ]; then
  echo "FATAL: nested invocation from a self-test (RSDD_GO_SELFTEST_NESTED set): refusing to run the real Go suite" >&2
  exit 2
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
if [ "$SKIP_TEST" -eq 1 ]; then
  echo "go test: whole-module run skipped (RSDD_BRIDGE_PART=${BRIDGE_PART:-unset}, sharded=$SHARDED; it runs in the test part, or in shard 1 when unpartitioned)"
  : > "$out"; rc=0
else
  make -s -C "$MOD" test TESTFLAGS=-count=1 >"$out" 2>&1
  rc=$?
fi
counts="$(count_go_output "$out")"
npass="${counts#pass=}"; npass="${npass%% *}"
nfail="${counts##*fail=}"
while read -r _ pkg _; do ok "go test: $pkg"; done < <(awk '$1=="ok"{print}' "$out")
while read -r _ pkg _; do no "go test: $pkg"; done < <(awk '$1=="FAIL" && $2!=""{print}' "$out")
if [ "$nfail" -gt 0 ]; then fail_heads "$out" 40; fi
if [ "$rc" -ne 0 ] && [ "$nfail" -eq 0 ]; then
  no "go test exited $rc with no per-package FAIL line (build/setup error); tail follows"
  tail -n 15 "$out"
fi
if [ "$npass" -eq 0 ] && [ "$nfail" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$SKIP_TEST" -eq 0 ]; then
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

# The head of a failing package: a runtime crash prints "fatal error:" first and a long goroutine dump after,
# so the tail alone loses the cause (#2454). Canned: a passing package, then a crash block of 60 lines.
{ printf 'ok  \texample.test/m/a\t0.004s\n'; printf 'fatal error: out of memory\n'
  for i in $(seq 1 59); do printf 'goroutine %d [GC worker (idle)]:\n' "$i"; done
  printf 'FAIL\texample.test/m/b\t0.711s\n'; } > "$ROOT/canned-crash.out"
heads="$(bash "$0" --fail-heads "$ROOT/canned-crash.out" 40)"
if grep -qx -- '--- head of failing example.test/m/b (40 of 60 lines) ---' <<<"$heads" \
   && grep -qx '    | fatal error: out of memory' <<<"$heads" && ! grep -q 'goroutine 45 ' <<<"$heads" \
   && ! grep -q 'example.test/m/a' <<<"$heads"; then
  ok "fail heads: a failing package's first lines (the fatal-error header) are printed, bounded, for that package only"
else no "fail heads: got: $(head -3 <<<"$heads")"; fi

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
# `make race` is wired through the same CAPPED wrapper with its own, larger cap (RACE_MEM_KB). Dry run only:
# a real -race run is far too heavy for this suite, so the wiring is judged from `make -n` output.
# The numbers below mirror the Makefile defaults (RACE_MEM_KB, TEST_MEM_KB, RACE_TIMEOUT): a changed default
# fails here on purpose and must be updated in both places.
r="$(make -n -C "$MOD" race 2>&1)"
if grep -q 'capexec' <<<"$r" && grep -q 'ulimit -v 8388608' <<<"$r" && grep -q -e 'go test .*-race' <<<"$r"; then
  ok "containment: make race runs under the CAPPED wrapper with the default RACE_MEM_KB"
else no "containment: make race is not capped: $(tail -n 3 <<<"$r")"; fi
r="$(make -n -C "$MOD" race RACE_MEM_KB=12345 2>&1)"
if grep -q 'ulimit -v 12345' <<<"$r" && ! grep -q 'ulimit -v 8388608' <<<"$r"; then
  ok "containment: RACE_MEM_KB overrides the race cap"
else no "containment: RACE_MEM_KB did not reach make race: $(tail -n 3 <<<"$r")"; fi
r="$(make -n -C "$MOD" race 2>&1)"
if grep -q -e 'go test -timeout 30m .*-race' <<<"$r"; then
  ok "containment: make race uses its own RACE_TIMEOUT (default 30m), not the plain TEST_TIMEOUT"
else no "containment: make race timeout is not RACE_TIMEOUT: $(tail -n 3 <<<"$r")"; fi
r="$(make -n -C "$MOD" race RACE_TIMEOUT=7m 2>&1)"
if grep -q -e 'go test -timeout 7m .*-race' <<<"$r"; then
  ok "containment: RACE_TIMEOUT overrides the race timeout"
else no "containment: RACE_TIMEOUT did not reach make race: $(tail -n 3 <<<"$r")"; fi
r="$(make -n -C "$MOD" test 2>&1)"
if grep -q 'ulimit -v 1048576' <<<"$r"; then
  ok "containment: make test keeps the TEST_MEM_KB cap (the race cap is target-specific)"
else no "containment: make test cap changed: $(tail -n 3 <<<"$r")"; fi

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
# A package with no mutable expression (e.g. a command table): gremlins exits 0 and prints "No results to report."
# That is a typed no-mutants PASS with explicit zero counts; the same text after a non-zero exit is never a PASS.
printf 'Starting...\nGathering coverage... done in 372ms\n\nNo results to report.\n' > "$ROOT/gr-nomutants.out"
g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$ROOT/gr-nomutants.out" 0)"
if grep -q '^VERDICT: PASS no-mutants' <<<"$g" && grep -q '^gremlins: no-mutants killed=0 lived=0' <<<"$g"; then
  ok "gremlins: rc=0 + 'No results to report.' -> typed no-mutants PASS with zero counts"; else no "gremlins: no-mutants case wrong: $g"; fi
g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$ROOT/gr-nomutants.out" 1)"
if grep -q '^VERDICT: FAIL' <<<"$g" && ! grep -q '^VERDICT: PASS' <<<"$g"; then
  ok "gremlins: 'No results to report.' after rc=1 stays a FAIL"; else no "gremlins: no-mutants rc=1 wrong: $g"; fi
printf 'No results to report.\nKilled: x, Lived: 0, Not covered: 0\n' > "$ROOT/gr-nomutants-garbled.out"
g="$(bash "$0" --decide-gremlins "$ROOT/gr-nomutants-garbled.out" 0)"
if grep -q '^VERDICT: FAIL gremlins summary unparseable (rc=0)' <<<"$g"; then
  ok "gremlins: 'No results to report.' beside a garbled summary stays unparseable"; else no "gremlins: no-mutants garbled wrong: $g"; fi
printf 'VERDICT: PASS no lived mutants (killed=1 lived=0 timed_out=0 not_covered=0)\nVERDICT: PASS no-mutants (gremlins: No results to report.)\n' > "$ROOT/v-nomutants"
g="$(bash "$0" --combine-verdicts "$ROOT/v-nomutants")"
if grep -q '^VERDICT: PASS no lived mutants in 2 package run(s); no-mutants: 1$' <<<"$g"; then
  ok "gremlins: the combined PASS names the no-mutants packages"; else no "gremlins: combined no-mutants wrong: $g"; fi
g="$(RSDD_REQUIRE_GO=1 bash "$0" --decide-gremlins "$ROOT/gr-unavailable.out" 1)"
if grep -q '^VERDICT: FAIL gremlins did not run (rc=1, RSDD_REQUIRE_GO=1)' <<<"$g"; then
  ok "gremlins: tool unavailable under RSDD_REQUIRE_GO=1 -> FAIL"; else no "gremlins: required-unavailable case wrong: $g"; fi

# Teeth debt list (kit issue #2592): packages whose lived mutants are known debt are printed as DEBT and do not fail;
# any other package keeps fail-on-lived; a listed package reading Lived 0 is reported STALE; a bad list is INVALID.
printf '# comment\n\n./internal/cli #2592 reason long enough to pass\n./a #2592 another long enough reason\n' > "$ROOT/debt-ok.txt"
printf './internal/other #2592 reason long enough to pass\n' > "$ROOT/debt-other.txt"
d="$(bash "$0" --load-debt "$ROOT/debt-ok.txt")"; drc=$?
if [ "$drc" -eq 0 ] && [ "$d" = $'./internal/cli\n./a' ]; then ok "debt list: comments and blank lines skipped, packages printed in order"
else no "debt list: valid list wrong (rc=$drc): $d"; fi
d="$(bash "$0" --load-debt "$MOD/teeth-debt.txt")"; drc=$?
if [ "$drc" -eq 0 ] && grep -qx './internal/lint' <<<"$d" && grep -qx './internal/verify' <<<"$d" && ! grep -qx './internal/formats' <<<"$d"; then ok "debt list: the checked-in rsdd/teeth-debt.txt parses, names lint and verify, and no longer lists the paid formats"
else no "debt list: checked-in list does not parse (rc=$drc): $d"; fi
i=0
for bad in 'internal/x #2592 reason long enough to pass' './internal/../x #2592 reason long enough to pass' './internal/x/ #2592 reason long enough to pass' \
           './internal/x 2592 reason long enough to pass' './internal/x #2592 short' './internal/x #2592'; do
  i=$((i+1)); printf '%s\n' "$bad" > "$ROOT/debt-bad$i.txt"
  d="$(bash "$0" --load-debt "$ROOT/debt-bad$i.txt")"; drc=$?
  if [ "$drc" -eq 1 ] && grep -q '^INVALID: line 1: ' <<<"$d"; then ok "debt list: INVALID line [$bad] -> typed INVALID, rc 1"
  else no "debt list: bad line [$bad] not INVALID (rc=$drc): $d"; fi
done
printf './a #2592 reason long enough to pass\n./a #2592 reason long enough to pass\n' > "$ROOT/debt-dup.txt"
d="$(bash "$0" --load-debt "$ROOT/debt-dup.txt")"; drc=$?
if [ "$drc" -eq 1 ] && grep -q 'INVALID: line 2: duplicate package ./a' <<<"$d"; then ok "debt list: a duplicate package is INVALID"
else no "debt list: duplicate not INVALID (rc=$drc): $d"; fi
d="$(bash "$0" --load-debt "$ROOT/no-such-debt.txt")"; drc=$?
if [ "$drc" -eq 2 ] && grep -q '^INVALID: debt list not readable' <<<"$d"; then ok "debt list: an absent file is a typed INVALID (rc 2), not an empty list"
else no "debt list: absent file wrong (rc=$drc): $d"; fi
# A lived mutant of a listed package is debt, of an unlisted one a failure, both in one run keep the failure.
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0 ALL)"
if grep -q '^VERDICT: PASS debt-only 1 lived' <<<"$g" && grep -q 'DEBT  LIVED at internal/cli/cli.go:161:73 (package ./internal/cli ' <<<"$g" && ! grep -q '^  LIVED at' <<<"$g"; then
  ok "debt: a lived mutant of a listed package PASSes as debt-only and is still printed"; else no "debt: listed lived wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-other.txt" bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0 ALL)"
if grep -q '^VERDICT: FAIL 1 lived' <<<"$g" && grep -q '^  LIVED at internal/cli/cli.go:161:73' <<<"$g"; then
  ok "debt: a lived mutant of an UNLISTED package still FAILs"; else no "debt: unlisted lived wrong: $g"; fi
cat > "$ROOT/gr-mixed.out" <<'CANNED'
       LIVED CONDITIONALS_BOUNDARY at internal/cli/cli.go:161:73
       LIVED CONDITIONALS_BOUNDARY at internal/lint/lint.go:9:2
       LIVED CONDITIONALS_NEGATION at internal/cli/cli.go:20:4
Killed: 5, Lived: 3, Not covered: 2
Timed out: 0, Not viable: 0, Skipped: 0
CANNED
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-mixed.out" 0 ALL)"
if grep -q '^VERDICT: FAIL 1 lived' <<<"$g" && grep -q '^  LIVED at internal/lint/lint.go:9:2' <<<"$g" && [ "$(grep -c 'DEBT  LIVED' <<<"$g")" -eq 2 ]; then
  ok "debt: listed and unlisted lived mutants in one run -> FAIL on the unlisted one, the listed two printed as DEBT"; else no "debt: mixed wrong: $g"; fi
printf 'Killed: 5, Lived: 1, Not covered: 0\nTimed out: 0, Not viable: 0, Skipped: 0\n       LIVED CONDITIONALS_BOUNDARY at a.go:3:4\n' > "$ROOT/gr-pkg.out"
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-pkg.out" 0 ./a)"
if grep -q '^VERDICT: PASS debt-only 1 lived' <<<"$g"; then ok "debt: paths of a package-scoped run are resolved against that package (./a + a.go -> ./a)"
else no "debt: package-scoped path wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-pkg.out" 0 ./b)"
if grep -q '^VERDICT: FAIL 1 lived' <<<"$g"; then ok "debt: the same output scoped to another package (./b + a.go -> ./b) is not debt"
else no "debt: other-scope path wrong: $g"; fi
# Stale entries: a listed package with no lived mutant is reported (never a failure).
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0 ./internal/cli)"
if grep -q '^VERDICT: PASS no lived' <<<"$g" && grep -q 'teeth debt: STALE entry ./internal/cli reads Lived 0' <<<"$g"; then
  ok "debt: a listed package that reads Lived 0 is reported STALE and the run still PASSes"; else no "debt: stale (package run) wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0 ./internal/other)"
if ! grep -q 'STALE' <<<"$g"; then ok "debt: a package-scoped run reports only its own package as stale"; else no "debt: foreign stale: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0 ALL)"
if grep -q 'STALE entry ./internal/cli' <<<"$g" && grep -q 'STALE entry ./a ' <<<"$g"; then ok "debt: a whole-module run reports every listed package without a lived mutant as stale"
else no "debt: stale (whole module) wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-timeouts.out" 0)"
if grep -q '^VERDICT: PASS' <<<"$g" && ! grep -q 'STALE' <<<"$g"; then ok "debt: without a PKG argument no stale report is made"; else no "debt: PKG-less stale wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-bad1.txt" bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0 ALL)"
if grep -q '^VERDICT: FAIL teeth debt list INVALID' <<<"$g"; then ok "debt: an invalid list FAILs the verdict (typed INVALID), never a silent fail-open"
else no "debt: invalid list wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/no-such-debt.txt" bash "$0" --decide-gremlins "$ROOT/gr-lived.out" 0 ALL)"
if grep -q '^VERDICT: FAIL teeth debt list INVALID .*not readable' <<<"$g"; then ok "debt: an absent list FAILs the verdict when it is needed"
else no "debt: absent list wrong: $g"; fi
printf 'VERDICT: PASS debt-only 2 lived mutant(s) on the teeth debt list, none outside it (killed=1 lived=2 timed_out=0 not_covered=0)\nVERDICT: PASS no lived mutants (killed=1 lived=0 timed_out=0 not_covered=0)\n' > "$ROOT/v-debt"
g="$(bash "$0" --combine-verdicts "$ROOT/v-debt")"
if grep -q '^VERDICT: PASS no lived mutants in 2 package run(s); debt-only: 1$' <<<"$g"; then ok "debt: the combined PASS counts the debt-only package runs"
else no "debt: combined debt-only wrong: $g"; fi
# The per-package loops tag each verdict as `VERDICT: <STATUS> [<pkg>] <reason> ...` (kit issue #2683): the combined
# summary must still count the tagged reasons, and a PENDING line (not a verdict) must never fold into a PASS.
printf 'VERDICT: PASS [./a] debt-only 2 lived mutant(s) on the teeth debt list, none outside it (killed=1 lived=2 timed_out=0 not_covered=0)\nVERDICT: PASS [./b] no-mutants (gremlins: No results to report.)\nVERDICT: PASS [./c] no lived mutants (killed=1 lived=0 timed_out=0 not_covered=0)\n' > "$ROOT/v-tagged"
g="$(bash "$0" --combine-verdicts "$ROOT/v-tagged")"
if grep -qx 'VERDICT: PASS no lived mutants in 3 package run(s); no-mutants: 1; debt-only: 1' <<<"$g"; then
  ok "verdicts: the combined PASS counts tagged no-mutants and debt-only runs"; else no "verdicts: tagged reasons miscounted: $g"; fi
printf 'VERDICT: PENDING baseline-skip ./a\nVERDICT: PASS [./b] no lived mutants (killed=1 lived=0 timed_out=0 not_covered=0)\n' > "$ROOT/v-pending"
g="$(bash "$0" --combine-verdicts "$ROOT/v-pending")"
if grep -qx 'VERDICT: FAIL 1 of 2 package run(s) failed; first: unresolved PENDING baseline-skip ./a' <<<"$g"; then
  ok "verdicts: a PENDING line reaching the combiner is a FAIL, never folded into a PASS"; else no "verdicts: PENDING folded: $g"; fi

# Baseline failure of the unmutated package in a module-only copy (kit issue #2592): `make teeth` prints the typed
# `teeth: DEGRADED — the unmutated package fails in a module-only copy: <pkg>` line and exits 1 before gremlins runs.
# A package ON the debt list is loud DEBT and does not fail (its repoint is pending); an UNLISTED one stays a FAIL.
mp="$(awk '/^module /{print $2; exit}' "$MOD/go.mod")"
bl_deg() { # PKG FAILPKG... -> a captured `make teeth` output whose baseline failed
  local pk="$1" fp; shift
  printf '%s\n' '--- FAIL: TestReadsKit (0.00s)' '    k_test.go:3: open ../../toolbelt/x: no such file or directory' FAIL
  for fp in "$@"; do printf 'FAIL\t%s/%s\t0.005s\n' "$mp" "$fp"; done
  printf 'teeth: DEGRADED \xe2\x80\x94 the unmutated package fails in a module-only copy: %s\n' "$pk"
}
bl_deg ./internal/cli internal/cli > "$ROOT/gr-bl-listed.out"
g="$(RSDD_REQUIRE_GO=1 RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-listed.out" 1 ./internal/cli)"
if grep -q '^  DEBT  baseline fails in a module-only copy (out-of-module test reads, #2592 repoint pending): ./internal/cli$' <<<"$g" \
   && grep -q '^VERDICT: PASS debt-only baseline-fail' <<<"$g"; then
  ok "debt: a listed package whose module-only baseline fails is a loud DEBT line and PASSes"; else no "debt: listed baseline fail wrong: $g"; fi
bl_deg ./internal/other internal/other > "$ROOT/gr-bl-unlisted.out"
g="$(RSDD_REQUIRE_GO='' RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-unlisted.out" 1 ./internal/other)"
if grep -q '^VERDICT: FAIL teeth DEGRADED: the unmutated package fails in a module-only copy and is not on the teeth debt list: ./internal/other' <<<"$g" \
   && ! grep -q 'DEBT' <<<"$g"; then
  ok "debt: an UNLISTED package whose module-only baseline fails is a typed DEGRADED FAIL (even without RSDD_REQUIRE_GO)"; else no "debt: unlisted baseline fail wrong: $g"; fi
bl_deg . internal/cli a > "$ROOT/gr-bl-all-ok.out"
g="$(RSDD_GO_MOD="$MOD" RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-all-ok.out" 1)"
if grep -qx "VERDICT: FAIL teeth DEGRADED: the whole module's baseline fails in a module-only copy, and this decision has no ALL context to judge the rest of the module" <<<"$g" \
   && ! grep -q 'VERDICT: PASS' <<<"$g"; then
  ok "debt: a whole-module baseline failure decided without the ALL context is a typed FAIL, never a PASS"
else no "debt: whole-module baseline without ALL wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-all-ok.out" 1 ALL)"
if [ "$(grep -c '^  DEBT  baseline fails' <<<"$g")" -eq 2 ] && grep -qx 'VERDICT: PENDING baseline-skip ./a ./internal/cli' <<<"$g" && ! grep -q 'VERDICT: PASS' <<<"$g"; then
  ok "debt: a whole-module baseline failure confined to listed packages is DEBT for each of them and NOT a verdict (PENDING: the rest of the module still has to run)"
else no "debt: whole-module listed wrong: $g"; fi
bl_deg . internal/cli internal/zzz > "$ROOT/gr-bl-all-mixed.out"
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-all-mixed.out" 1 ALL)"
if grep -q '^VERDICT: FAIL teeth DEGRADED: .*not on the teeth debt list: ./internal/zzz' <<<"$g" && ! grep -q 'baseline-fail' <<<"$g"; then
  ok "debt: a whole-module baseline failure that includes an unlisted package FAILs naming it"; else no "debt: whole-module mixed wrong: $g"; fi
printf '%s\n' 'exit status 1' > "$ROOT/gr-bl-none.out"
printf 'teeth: DEGRADED \xe2\x80\x94 the unmutated package fails in a module-only copy: .\n' >> "$ROOT/gr-bl-none.out"
g="$(RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-none.out" 1 ALL)"
if grep -q '^VERDICT: FAIL teeth DEGRADED: ' <<<"$g"; then
  ok "debt: a whole-module baseline failure that names no package is a FAIL (cannot prove every failure is debt)"; else no "debt: whole-module no-package wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$ROOT/debt-bad1.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-listed.out" 1 ./internal/cli)"
if grep -q '^VERDICT: FAIL teeth debt list INVALID' <<<"$g"; then ok "debt: an invalid list FAILs a baseline failure too"
else no "debt: baseline + invalid list wrong: $g"; fi
g="$(RSDD_TEETH_DEBT="$MOD/teeth-debt.txt" bash "$0" --decide-gremlins "$ROOT/gr-bl-all-ok.out" 1 ALL)"
# The checked-in list loads completely: --load-debt returns exactly the file's package lines, read here with a plain
# grep independent of the loader. Data-driven, so paying a package's debt (deleting its line, #2592) needs no edit here.
want_debt="$(grep -oE '^\./internal/[^[:space:]]+' "$MOD/teeth-debt.txt" | LC_ALL=C sort)"
got_debt="$(bash "$0" --load-debt "$MOD/teeth-debt.txt" | LC_ALL=C sort)"
if [ "$want_debt" = "$got_debt" ]; then ok "debt list: --load-debt reads every package line of the checked-in teeth-debt.txt and nothing else"
else no "debt list: checked-in teeth-debt.txt loads as [${got_debt//$'\n'/ }], its package lines are [${want_debt//$'\n'/ }]"; fi

mkdir -p "$ROOT/st"; selftest_teeth "$ROOT/st"; unset RSDD_GO_SELFTEST_NESTED

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
if [ "$RUN_TEST" -eq 1 ] && MUTANT_SYNTAX=none mutant_chain_or_count fail "panic-boundary mutation" "$ORIG_GO" "$MUTDIR/cli.go" \
    's/if r := recover(); r != nil {/if r := interface{}(nil); r != nil {/'; then
  if mutant_tooth "teeth: removing the panic boundary turns the cli tests red" 0 1 \
      "$MUTDIR/cli.go" --orig "$ORIG_GO" \
      --good-has '^ok' --bad-has 'kaboom' --bad-lacks 'SETUP-FAILED|build failed|undefined:' -- \
      bash "$MUTDIR/run_cli_tests.sh" "$MOD" @SUT@; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# The `test` part ends here: the suite's own mutation controls and gremlins belong to the teeth jobs (kit issue #2617).
if [ "$RUN_TEETH" -eq 0 ]; then
  echo "teeth: skipped (RSDD_BRIDGE_PART=test; the teeth shards run it)"
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]; exit $?
fi

# Teeth for the part selector (kit issue #2617). The suite is the SUT (`--part-plan PART PROVE`). Dropping the unknown-part
# refusal lets a typo run both halves (the original exits 2, the mutant 0); letting the teeth part keep `make test`
# loses the shard-budget fix (the original prints test=0 teeth=1, the mutant test=1); letting the test part keep the
# teeth would run gremlins in the test job (the original prints test=1 teeth=0, the mutant teeth=1).
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "part-unknown mutation" "$0" "$MUTDIR/rsdd-go-part1.test.sh" \
    's/^    \*) return 1 ;;$/    *) RUN_TEST=1; RUN_TEETH=1 ;;/'; then
  if mutant_tooth "teeth: an unknown RSDD_BRIDGE_PART must be refused, not run as both halves" 2 0 \
      "$MUTDIR/rsdd-go-part1.test.sh" --orig "$0" -- \
      bash @SUT@ --part-plan bogus 1; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "part-teeth-runs-test mutation" "$0" "$MUTDIR/rsdd-go-part2.test.sh" \
    's/RUN_TEST=0; RUN_TEETH=1 ;;/RUN_TEST=1; RUN_TEETH=1 ;;/'; then
  if mutant_tooth "teeth: the teeth part must not run make test" 0 0 \
      "$MUTDIR/rsdd-go-part2.test.sh" --orig "$0" \
      --good-has 'test=0 teeth=1' --bad-has 'test=1 teeth=1' -- \
      bash @SUT@ --part-plan teeth 1; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "part-test-runs-teeth mutation" "$0" "$MUTDIR/rsdd-go-part3.test.sh" \
    's/test) RUN_TEST=1; RUN_TEETH=0 ;;/test) RUN_TEST=1; RUN_TEETH=1 ;;/'; then
  if mutant_tooth "teeth: the test part must not run the teeth" 0 0 \
      "$MUTDIR/rsdd-go-part3.test.sh" --orig "$0" \
      --good-has 'test=1 teeth=0' --bad-has 'test=1 teeth=1' -- \
      bash @SUT@ --part-plan test 1; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Tooth for the fail heads: printing the LAST lines of the block (the tail) loses the fatal-error header.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "fail-heads mutation" "$0" "$MUTDIR/rsdd-go-heads.test.sh" \
    's/for (i = 1; i <= m; i++) print "    | " buf\[i\]/for (i = cnt - m + 1; i <= cnt; i++) print "    | " buf[i]/'; then
  if mutant_tooth "teeth: printing the tail instead of the head loses the fatal-error header" 0 0 \
      "$MUTDIR/rsdd-go-heads.test.sh" --orig "$0" \
      --good-has '| fatal error: out of memory' --bad-lacks 'fatal error' -- \
      bash @SUT@ --fail-heads "$ROOT/canned-crash.out" 40; then
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

# Tooth for the no-mutants verdict: "No results to report." is a PASS only after rc=0. The mutant drops the rc
# guard, so the same text after a failed gremlins run reads as a PASS (a silent zero).
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "gremlins-no-mutants mutation" "$0" "$MUTDIR/rsdd-go-nm.test.sh" \
    's/if \[ -z "\$counts" \] \&\& \[ "\$rc" -eq 0 \] \&\& /if [ -z "$counts" ] \&\& /'; then
  if mutant_tooth "teeth: a no-mutants PASS without the rc=0 guard is caught" 0 0 \
      "$MUTDIR/rsdd-go-nm.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL gremlins did not run' --bad-has 'VERDICT: PASS no-mutants' -- \
      env RSDD_REQUIRE_GO=1 bash @SUT@ --decide-gremlins "$ROOT/gr-nomutants.out" 1; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Teeth for the teeth debt list (kit issue #2592; the suite is the SUT: `--decide-gremlins FILE RC PKG`, `--load-debt FILE`).
# 1) a classifier that never sees a package as debt fails the known debt again; 2) one that sees every package as debt
# lets an unlisted package's lived mutant through; 3) a loader without the issue-reference check, or 4) without the
# duplicate check, accepts a bad list; 5) a decision that never reports stale entries hides a fixed package; 6) a
# classifier that ignores the run's package scope misreads "a.go" of ./a as the root package.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-never mutation" "$0" "$MUTDIR/rsdd-go-debt1.test.sh" \
    's/if (pk in debt) {/if (0) {/'; then
  if mutant_tooth "teeth: a classifier that never recognises debt fails the listed package again" 0 0 \
      "$MUTDIR/rsdd-go-debt1.test.sh" --orig "$0" \
      --good-has 'VERDICT: PASS debt-only' --bad-has 'VERDICT: FAIL' -- \
      env RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-lived.out" 0 ALL; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-always mutation" "$0" "$MUTDIR/rsdd-go-debt2.test.sh" \
    's/if (pk in debt) {/if (1) {/'; then
  if mutant_tooth "teeth: a classifier that treats every package as debt lets an unlisted lived mutant pass" 0 0 \
      "$MUTDIR/rsdd-go-debt2.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL 1 lived' --bad-has 'VERDICT: PASS debt-only' -- \
      env RSDD_TEETH_DEBT="$ROOT/debt-other.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-lived.out" 0 ALL; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-ref mutation" "$0" "$MUTDIR/rsdd-go-debt3.test.sh" \
    's/if (ref !~ [^)]*) bad(/if (0) bad(/'; then
  if mutant_tooth "teeth: a loader without the issue-reference check accepts a line with no #issue" 1 0 \
      "$MUTDIR/rsdd-go-debt3.test.sh" --orig "$0" \
      --good-has 'INVALID: line 1' --bad-lacks 'INVALID' -- \
      bash @SUT@ --load-debt "$ROOT/debt-bad4.txt"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-dup mutation" "$0" "$MUTDIR/rsdd-go-debt4.test.sh" \
    's/if (pkg in seen) bad(/if (0) bad(/'; then
  if mutant_tooth "teeth: a loader without the duplicate check accepts a package listed twice" 1 0 \
      "$MUTDIR/rsdd-go-debt4.test.sh" --orig "$0" \
      --good-has 'duplicate package' --bad-lacks 'INVALID' -- \
      bash @SUT@ --load-debt "$ROOT/debt-dup.txt"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-stale mutation" "$0" "$MUTDIR/rsdd-go-debt5.test.sh" \
    's/print "STALE " arr\[i\]/print "NOSTALE"/'; then
  if mutant_tooth "teeth: a decision that never reports stale entries hides a listed package that reads Lived 0" 0 0 \
      "$MUTDIR/rsdd-go-debt5.test.sh" --orig "$0" \
      --good-has 'STALE entry ./internal/cli' --bad-lacks 'STALE entry' -- \
      env RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-timeouts.out" 0 ./internal/cli; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "debt-scope mutation" "$0" "$MUTDIR/rsdd-go-debt6.test.sh" \
    's/if (pkgarg != "." \&\& pkgarg != "ALL") p = pkgarg "\/" p/if (0) p = pkgarg "\/" p/'; then
  if mutant_tooth "teeth: a classifier that ignores the run's package scope misreads ./a/a.go as the root package" 0 0 \
      "$MUTDIR/rsdd-go-debt6.test.sh" --orig "$0" \
      --good-has 'VERDICT: PASS debt-only' --bad-has 'VERDICT: FAIL' -- \
      env RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-pkg.out" 0 ./a; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Teeth for the baseline-failure rule (kit issue #2592). 7) a decision that never routes the typed baseline DEGRADED line
# to the debt classifier fails the listed package again; 8) one that drops the debt-list membership check (every
# baseline failure is debt) lets an UNLISTED package's failing baseline through as a PASS.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "baseline-route mutation" "$0" "$MUTDIR/rsdd-go-debt7.test.sh" \
    's/decide_baseline_fail "\$f" "\${3-}"; return 0 /: ; /'; then
  if mutant_tooth "teeth: a decision that ignores the baseline DEGRADED line fails the listed package again" 0 0 \
      "$MUTDIR/rsdd-go-debt7.test.sh" --orig "$0" \
      --good-has 'VERDICT: PASS debt-only baseline-fail' --bad-has 'VERDICT: FAIL' -- \
      env RSDD_REQUIRE_GO=1 RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-bl-listed.out" 1 ./internal/cli; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "baseline-listed mutation" "$0" "$MUTDIR/rsdd-go-debt8.test.sh" \
    's/if grep -qxF -e "\$p" <<<"\$dl"; then good/if true; then good/'; then
  if mutant_tooth "teeth: dropping the debt-list check lets an UNLISTED failing baseline PASS" 0 0 \
      "$MUTDIR/rsdd-go-debt8.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL teeth DEGRADED' --bad-has 'VERDICT: PASS debt-only' -- \
      env RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-bl-unlisted.out" 1 ./internal/other; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# Whole-module run with a listed baseline failure (kit issue #2592): a fixture module with ./b reading outside the module
# (its module-only baseline fails; ./b is on the debt list) and ./a testable. The skipped ./b must stay a DEBT line while
# gremlins still judges ./a: a lived mutant of ./a FAILs the run, a killed one PASSes naming exactly what was skipped.
whole_fixture_make() { # KILL|LIVE -> the path of a fixture module (its debt list is debt.txt in it)
  local mode="$1" w
  w="$(mktemp -d "$ROOT/whole-fx.XXXXXX")" || return 1
  mkdir -p "$w/a" "$w/b"
  printf 'module fx\n\ngo 1.22\n' > "$w/go.mod"
  printf 'package a\n\nfunc Pos(x int) bool { return x > 0 }\n' > "$w/a/a.go"
  if [ "$mode" = "LIVE" ]; then
    printf 'package a\n\nimport "testing"\n\nfunc TestPos(t *testing.T) {\n\tif !Pos(5) {\n\t\tt.Fatal("5")\n\t}\n}\n' > "$w/a/a_test.go"
  else
    printf 'package a\n\nimport "testing"\n\nfunc TestPos(t *testing.T) {\n\tif !Pos(5) || Pos(0) || Pos(-1) {\n\t\tt.Fatal("pos")\n\t}\n}\n' > "$w/a/a_test.go"
  fi
  printf 'package b\n\nfunc Neg(x int) bool { return x < 0 }\n' > "$w/b/b.go"
  printf 'package b\n\nimport (\n\t"os"\n\t"testing"\n)\n\nfunc TestNeg(t *testing.T) {\n\tif _, err := os.Stat("../../nope"); err != nil {\n\t\tt.Fatal(err)\n\t}\n}\n' > "$w/b/b_test.go"
  printf './b #2592 fixture test reads outside the module for the remainder test\n' > "$w/debt.txt"
  echo "$w"
}
whole_fixture() { # KILL|LIVE MAKEFILE -> the --teeth-whole report of the fixture
  local w; w="$(whole_fixture_make "$1")" || { echo "ran=no"; return; }
  RSDD_BIN=fixture-skips-the-rsdd-build RSDD_TEETH_DEBT="$w/debt.txt" bash "$0" --teeth-whole "$w" "$2" 2>&1
}

# 11) a decision without the whole-module guard PASSes a whole-module baseline failure outside the ALL context; 12) a
# combiner that reads the reason word at $3 again miscounts tagged lines; 13) one that ignores PENDING folds it into a
# PASS (kit issue #2683).
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "baseline-needs-all mutation" "$0" "$MUTDIR/rsdd-go-debt11.test.sh" \
    's/if \[ "\$dpkg" = "\." \] \&\& \[ "\$whole" -eq 0 \]; then # SENTINEL-BASELINE-WHOLE-NEEDS-ALL/if false; then/'; then
  if mutant_tooth "teeth: without the guard a whole-module baseline failure PASSes outside the ALL context" 0 0 \
      "$MUTDIR/rsdd-go-debt11.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL teeth DEGRADED' --bad-has 'VERDICT: PASS' -- \
      env RSDD_GO_MOD="$MOD" RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-bl-all-ok.out" 1; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "combine-tag mutation" "$0" "$MUTDIR/rsdd-go-comb1.test.sh" \
    's/{ r = (\$3 ~ \/^\\\[\/) ? \$4 : \$3 } # SENTINEL-COMBINE-TAG/{ r = $3 }/'; then
  if mutant_tooth "teeth: reading the reason at \$3 miscounts tagged debt-only and no-mutants runs" 0 0 \
      "$MUTDIR/rsdd-go-comb1.test.sh" --orig "$0" \
      --good-has 'debt-only: 1$' --bad-lacks 'debt-only' -- \
      bash @SUT@ --combine-verdicts "$ROOT/v-tagged"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "combine-pending mutation" "$0" "$MUTDIR/rsdd-go-comb2.test.sh" \
    's|^    /\^VERDICT: PENDING/ .*# SENTINEL-COMBINE-PENDING$||'; then
  if mutant_tooth "teeth: a combiner that drops PENDING folds it into a PASS" 0 0 \
      "$MUTDIR/rsdd-go-comb2.test.sh" --orig "$0" \
      --good-has '^VERDICT: FAIL' --bad-has '^VERDICT: PASS' -- \
      bash @SUT@ --combine-verdicts "$ROOT/v-pending"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi

# 9) a decision that treats a whole-module baseline failure like a per-package one reports PASS for a run in which
# gremlins mutated nothing; 10) a whole-module run that ignores the remainder's verdicts passes over a lived mutant of an
# unlisted package.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "baseline-whole mutation" "$0" "$MUTDIR/rsdd-go-debt9.test.sh" \
    's/\[ "\$dpkg" = "\." \] \&\& \[ "\${2-}" = "ALL" \] \&\& whole=1/whole=0/'; then
  if mutant_tooth "teeth: a whole-module baseline failure decided as final leaves the rest of the module unjudged" 0 0 \
      "$MUTDIR/rsdd-go-debt9.test.sh" --orig "$0" \
      --good-has 'VERDICT: PENDING baseline-skip' --bad-lacks 'VERDICT: PENDING' -- \
      env RSDD_GO_MOD="$MOD" RSDD_TEETH_DEBT="$ROOT/debt-ok.txt" bash @SUT@ --decide-gremlins "$ROOT/gr-bl-all-ok.out" 1 ALL; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if command -v go >/dev/null && wfx="$(whole_fixture_make LIVE)" \
   && MUTANT_SYNTAX=bash mutant_chain_or_count fail "whole-remainder mutation" "$0" "$MUTDIR/rsdd-go-debt10.test.sh" \
    's|verdict="\$(combine_verdicts "\$sc/verdicts.txt")"|verdict="VERDICT: PASS no lived mutants"|'; then
  if mutant_tooth "teeth: ignoring the remainder's verdicts passes a lived mutant of an unlisted package" 0 0 \
      "$MUTDIR/rsdd-go-debt10.test.sh" --orig "$0" \
      --good-has 'VERDICT: FAIL' --bad-has 'VERDICT: PASS' -- \
      env RSDD_BIN=fixture-skips-the-rsdd-build RSDD_TEETH_DEBT="$wfx/debt.txt" bash @SUT@ --teeth-whole "$wfx" "$MOD/Makefile"; then
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
# Shard teeth: the slice offset and the I<=N bound are each load-bearing.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "shard-offset mutation" "$0" "$MUTDIR/rsdd-go-so.test.sh" \
    's/(NR - 1) % n == i - 1/(NR - 1) % n == i/'; then
  if mutant_tooth "teeth: a shard slice shifted by one position is caught" 0 1 \
      "$MUTDIR/rsdd-go-so.test.sh" --orig "$0" \
      --good-has 'PASS  shard select: 1/3, 2/3 and 3/3' --bad-has 'FAIL  shard select: wrong slices' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "shard-bound mutation" "$0" "$MUTDIR/rsdd-go-sb.test.sh" \
    's/ && \[ "\$SHARD_I" -le "\$SHARD_N" \]//'; then
  if mutant_tooth "teeth: a shard selector with I > N accepted is caught" 0 1 \
      "$MUTDIR/rsdd-go-sb.test.sh" --orig "$0" \
      --good-has 'PASS  shard select: invalid specs' --bad-has 'FAIL  shard select: invalid spec accepted' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
# File-level shard teeth (kit issue #2573): the plan's slice offset, and a changed file silently dropped.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "file-offset mutation" "$0" "$MUTDIR/rsdd-go-fo.test.sh" \
    's/sel="\$(select_shard "\$i" "\$n")"/sel="$(select_shard "$(( i % n + 1 ))" "$n")"/'; then
  if mutant_tooth "teeth: a file plan shifted by one shard is caught" 0 1 \
      "$MUTDIR/rsdd-go-fo.test.sh" --orig "$0" \
      --good-has 'PASS  file plan: each shard runs gremlins once' --bad-has 'FAIL  file plan: wrong' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "file-dropped mutation" "$0" "$MUTDIR/rsdd-go-fd.test.sh" \
    "s/^  } | LC_ALL=C sort -u\$/  } | LC_ALL=C sort -u | sed '\$d'/"; then
  if mutant_tooth "teeth: a changed file dropped from every shard is caught" 0 1 \
      "$MUTDIR/rsdd-go-fd.test.sh" --orig "$0" \
      --good-has 'PASS  file scope: changed non-test files are the units' --bad-has 'FAIL  file scope: got rc=0' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
# Nested guard teeth: without RSDD_GO_SELFTEST_NESTED the self-test re-entry reaches go (bounded by RSDD_GO_NEST_DEPTH and
# timeout 60, never a runaway) and its case goes red.
if MUTANT_SYNTAX=bash mutant_chain_or_count fail "nested-guard mutation" "$0" "$MUTDIR/rsdd-go-ng.test.sh" \
    's/^if \[ -n "\${RSDD_GO_SELFTEST_NESTED:-}" \]; then$/if false; then/'; then
  if mutant_tooth "teeth: a suite without the nested guard lets a self-test re-entry reach go" 0 1 \
      "$MUTDIR/rsdd-go-ng.test.sh" --orig "$0" \
      --good-has 'PASS  nested guard: a self-test re-invoking the suite exits 2' --bad-has 'FAIL  nested guard: rc=' -- \
      env RSDD_GO_MOD="$MOD" bash @SUT@ --selftest-teeth; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
fi
# 3) a teeth recipe without --workers (gremlins' one-worker-per-CPU default) is caught by the wiring pin.
if MUTANT_SYNTAX=none mutant_chain_or_count fail "workers-wiring mutation" "$MOD/Makefile" "$MUTDIR/Makefile.workers" \
    's/ --workers \$(TEETH_WORKERS)//'; then
  if mutant_tooth "teeth: a teeth recipe without --workers (unbounded mutant workers) is caught" 0 0 \
      "$MUTDIR/Makefile.workers" --orig "$MOD/Makefile" \
      --good-has '--workers 4 .' --bad-lacks '--workers' -- \
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

# Gremlins on a real fixture (#2427's false verdicts): package ./a has a negative control (a boundary no test
# pins, so its mutant MUST read LIVED) and a subpackage ./a/b whose mutants its own tests kill.
# scope_fixture MAKEFILE [PKG [SUBTEST [MAKEARG...]]] prints "control=<status> sub=<lived count>", or "ran=no" when
# gremlins did not run. PKG defaults to ./a. SUBTEST=live drops the boundary case from the subpackage's test, so
# ./a/b carries a LIVED mutant of its own; MAKEARGs (e.g. TEETH_EXCLUDE=/) are passed to make.
scope_fixture() {
  local mk="$1" pkg="${2:-./a}" subtest="${3:-kill}" w
  shift $(( $# < 3 ? $# : 3 ))
  w="$(mktemp -d "$ROOT/scope-fx.XXXXXX")" || { echo "ran=no"; return; }
  mkdir -p "$w/a/b"
  printf 'module fx\n\ngo 1.22\n' > "$w/go.mod"
  printf 'package a\n\n// Pos: no test pins the boundary.\nfunc Pos(x int) bool { return x > 0 }\n' > "$w/a/a.go"
  printf 'package a\n\nimport "testing"\n\nfunc TestPos(t *testing.T) {\n\tif !Pos(5) {\n\t\tt.Fatal("5")\n\t}\n}\n' > "$w/a/a_test.go"
  printf 'package b\n\nfunc Neg(x int) bool { return x < 0 }\n' > "$w/a/b/b.go"
  if [ "$subtest" = "live" ]; then
    printf 'package b\n\nimport "testing"\n\nfunc TestNeg(t *testing.T) {\n\tif !Neg(-1) || Neg(1) {\n\t\tt.Fatal("neg")\n\t}\n}\n' > "$w/a/b/b_test.go"
  else
    printf 'package b\n\nimport "testing"\n\nfunc TestNeg(t *testing.T) {\n\tif Neg(0) || !Neg(-1) || Neg(1) {\n\t\tt.Fatal("neg")\n\t}\n}\n' > "$w/a/b/b_test.go"
  fi
  local o; o="$(RSDD_BIN=fixture-skips-the-rsdd-build make -s -f "$mk" -C "$w" teeth TEETH_PKG="$pkg" TEETH_WORKERS=2 "$@" 2>&1 </dev/null)"
  if ! grep -q '^Killed: ' <<<"$o"; then echo "ran=no"; return; fi
  local c="none"
  if grep -Eq 'LIVED CONDITIONALS_BOUNDARY at a\.go:' <<<"$o"; then c="LIVED"
  elif grep -Eq 'KILLED CONDITIONALS_BOUNDARY at a\.go:' <<<"$o"; then c="KILLED"; fi
  echo "control=$c sub=$(grep -cE 'LIVED .* at (b/|b\.go)' <<<"$o")"
}
sf="$(scope_fixture "$MOD/Makefile")"
case "$sf" in
  "control=LIVED sub=0") ok "teeth scope: a live mutant reads LIVED and a subpackage's mutants are killed by its own tests" ;;
  "ran=no") if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "teeth scope: gremlins did not run on the fixture (RSDD_REQUIRE_GO=1)"
            else echo "SKIP: teeth scope: gremlins did not run on the fixture"; fi ;;
  *) no "teeth scope: want control=LIVED sub=0, got $sf" ;;
esac
if [ "$sf" = "control=LIVED sub=0" ]; then
  # Tooth: gremlins --test-cpu back in the recipe turns the parent's live mutant into a false KILLED.
  sed 's/ --workers \$(TEETH_WORKERS)/ --workers $(TEETH_WORKERS) --test-cpu 1/' "$MOD/Makefile" > "$MUTDIR/Makefile.testcpu"
  if cmp -s "$MOD/Makefile" "$MUTDIR/Makefile.testcpu"; then no "teeth scope tooth: --test-cpu mutant is identical to the Makefile"
  else
    sf2="$(scope_fixture "$MUTDIR/Makefile.testcpu")"
    case "$sf2" in "control=KILLED"*) ok "teeth scope tooth: gremlins --test-cpu makes the live control read KILLED (why the recipe never passes it)" ;;
      *) no "teeth scope tooth: --test-cpu mutant should read control=KILLED, got $sf2" ;; esac
  fi
fi

# Baseline guard (kit issue #2592): the unmutated package is tested in a module-only copy before gremlins runs. The
# fixture's only test reads a marker file outside the module: "bypass" reads ../../kitmarker (a relative path out of
# the module, which exists in the tree but not in the copy), "env" reads $RSDD_TEST_RESEARCH_SDD/kitmarker (what the
# recipe exports: the parent of the module, here $ROOT). guard_fixture MAKEFILE READER prints "state=degraded" (the
# typed DEGRADED line and no gremlins report), "state=ran" (gremlins reported) or "state=none".
guard_fixture() {
  local mk="$1" reader="$2" w o src
  w="$(mktemp -d "$ROOT/guard-fx.XXXXXX")" || { echo "state=none"; return; }
  : > "$ROOT/kitmarker"
  mkdir -p "$w/a"
  printf 'module fx\n\ngo 1.22\n' > "$w/go.mod"
  printf 'package a\n\nfunc Pos(x int) bool { return x > 0 }\n' > "$w/a/a.go"
  if [ "$reader" = "env" ]; then src='os.Getenv("RSDD_TEST_RESEARCH_SDD") + "/kitmarker"'; else src='"../../kitmarker"'; fi
  printf 'package a\n\nimport (\n\t"os"\n\t"testing"\n)\n\nfunc TestPos(t *testing.T) {\n\tif _, err := os.Stat(%s); err != nil {\n\t\tt.Fatal(err)\n\t}\n\tif !Pos(5) || Pos(-1) || Pos(0) {\n\t\tt.Fatal("pos")\n\t}\n}\n' "$src" > "$w/a/a_test.go"
  o="$(RSDD_BIN=fixture-skips-the-rsdd-build make -s -f "$mk" -C "$w" teeth TEETH_PKG=./a TEETH_WORKERS=2 2>&1 </dev/null)"
  if grep -q '^teeth: DEGRADED — the unmutated package fails in a module-only copy: ./a$' <<<"$o" && ! grep -q '^Killed: ' <<<"$o"; then echo "state=degraded"
  elif grep -q '^Killed: ' <<<"$o"; then echo "state=ran"
  else echo "state=none"; fi
}
gf_bypass="$(guard_fixture "$MOD/Makefile" bypass)"
gf_env="$(guard_fixture "$MOD/Makefile" env)"
[ "$gf_bypass" = "state=degraded" ] && ok "teeth guard: a test reading a path outside the module fails the module-only baseline -> typed DEGRADED, gremlins never runs" \
  || no "teeth guard: bypassing read want state=degraded, got $gf_bypass"
if [ "$gf_env" = "state=ran" ]; then
  ok "teeth guard: a test reading the kit through RSDD_TEST_RESEARCH_SDD passes the baseline and gremlins runs"
  # Tooth 1: a recipe without the baseline step lets the out-of-module read through: gremlins runs and reads all KILLED.
  sed 's/go test -count=1 \$(TEETH_BASE_PKG)/true/' "$MOD/Makefile" > "$MUTDIR/Makefile.nobaseline"
  if cmp -s "$MOD/Makefile" "$MUTDIR/Makefile.nobaseline"; then no "teeth guard tooth: the no-baseline mutant is identical to the Makefile"
  else
    gm="$(guard_fixture "$MUTDIR/Makefile.nobaseline" bypass)"
    [ "$gm" = "state=ran" ] && ok "teeth guard tooth: without the baseline step the out-of-module read goes straight to gremlins (the vacuous KILLED of #2592)" \
      || no "teeth guard tooth: no-baseline mutant should read state=ran, got $gm"
  fi
  # Tooth 2: a recipe that no longer exports RSDD_TEST_RESEARCH_SDD fails the baseline of a test that honours it.
  sed 's/ RSDD_TEST_RESEARCH_SDD=\$(TEETH_KIT)//' "$MOD/Makefile" > "$MUTDIR/Makefile.noenv"
  if cmp -s "$MOD/Makefile" "$MUTDIR/Makefile.noenv"; then no "teeth guard tooth: the no-env mutant is identical to the Makefile"
  else
    gm="$(guard_fixture "$MUTDIR/Makefile.noenv" env)"
    [ "$gm" = "state=degraded" ] && ok "teeth guard tooth: without the exported RSDD_TEST_RESEARCH_SDD the kit read fails the baseline" \
      || no "teeth guard tooth: no-env mutant should read state=degraded, got $gm"
  fi
elif [ "$gf_env" = "state=none" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "teeth guard: gremlins did not run on the env fixture (RSDD_REQUIRE_GO=1)"
  else echo "SKIP: teeth guard: gremlins did not run on the env fixture"; fi
else no "teeth guard: env reader want state=ran, got $gf_env"; fi

# Per-PR scope (RSDD_TEETH_BASE): a changed package P mutates only the files directly in P (TEETH_EXCLUDE=/ drops every
# file gremlins finds below a subdirectory); a subpackage that changed is in the list on its own. Here ./a/b has a
# LIVED mutant of its own (its test skips the boundary).
sf_all="$(scope_fixture "$MOD/Makefile" ./a live)"
sf_par="$(scope_fixture "$MOD/Makefile" ./a live TEETH_EXCLUDE=/)"
sf_sub="$(scope_fixture "$MOD/Makefile" ./a/b live TEETH_EXCLUDE=/)"
if [ "$sf_all" = "ran=no" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "teeth shallow scope: gremlins did not run on the fixture (RSDD_REQUIRE_GO=1)"
  else echo "SKIP: teeth shallow scope: gremlins did not run on the fixture"; fi
else
  case "$sf_all" in "control=LIVED sub="[1-9]*) ok "teeth shallow scope fixture: without TEETH_EXCLUDE the subpackage's LIVED mutant is in scope" ;;
    *) no "teeth shallow scope fixture: want control=LIVED and sub>=1 whole-tree, got $sf_all" ;; esac
  [ "$sf_par" = "control=LIVED sub=0" ] && ok "teeth shallow scope: TEETH_EXCLUDE=/ on the parent keeps its own LIVED mutant and ignores the subpackage's" \
    || no "teeth shallow scope: parent-only want control=LIVED sub=0, got $sf_par"
  # Tooth: a recipe that drops the --exclude-files flag lets the subpackage's LIVED mutant into the parent's run.
  sed 's/\$(TEETH_EXCLUDE_ARG)//' "$MOD/Makefile" > "$MUTDIR/Makefile.noexclude"
  if cmp -s "$MOD/Makefile" "$MUTDIR/Makefile.noexclude"; then no "teeth shallow scope tooth: the no-exclude mutant is identical to the Makefile"
  else
    sf_mut="$(scope_fixture "$MUTDIR/Makefile.noexclude" ./a live TEETH_EXCLUDE=/)"
    case "$sf_mut" in "control=LIVED sub="[1-9]*) ok "teeth shallow scope tooth: without the --exclude-files flag the subpackage's mutant leaks into the parent run" ;;
      *) no "teeth shallow scope tooth: no-exclude mutant should read sub>=1, got $sf_mut" ;; esac
  fi
  case "$sf_sub" in "control=none sub="[1-9]*) ok "teeth shallow scope: a changed subpackage is still checked on its own (its LIVED mutant is reported)" ;;
    *) no "teeth shallow scope: changed subpackage want control=none sub>=1, got $sf_sub" ;; esac
  # File-level scope (kit issue #2573): the plan's exclude regexp, through make_value, drops the excluded file's
  # mutants. Excluding a.go (and not the subpackage, so gremlins still has mutants to report) removes the LIVED
  # control and keeps b/b.go's; a regexp whose "$" make swallowed would not even compile (gremlins would not run).
  sf_file="$(scope_fixture "$MOD/Makefile" ./a live "TEETH_EXCLUDE=$(make_value '^(a\.go)$')")"
  case "$sf_file" in "control=none sub="[1-9]*) ok "teeth file scope: an excluded file's mutants are not run (a.go's LIVED control disappears, b/b.go's stays)" ;;
    *) no "teeth file scope: excluding a.go want control=none sub>=1, got $sf_file" ;; esac
fi

if [ "$sf" = "control=LIVED sub=0" ]; then
  wf="$(whole_fixture LIVE "$MOD/Makefile")"
  if grep -q '^  DEBT  baseline fails in a module-only copy (out-of-module test reads, #2592 repoint pending): ./b$' <<<"$wf" \
     && grep -q '^  LIVED at a\.go:' <<<"$wf" && grep -q '^VERDICT: FAIL' <<<"$wf" && ! grep -q '^VERDICT: PASS' <<<"$wf"; then
    ok "teeth whole module: a listed baseline failure (./b) is skipped but a lived mutant of ./a still FAILs the run"
  else no "teeth whole module: want DEBT ./b + LIVED a.go + VERDICT: FAIL, got: $wf"; fi
  wf="$(whole_fixture KILL "$MOD/Makefile")"
  if grep -q '^  DEBT  baseline fails .*: ./b$' <<<"$wf" && grep -q '^VERDICT: PASS .*skipped, baseline fails in a module-only copy (gremlins not run, listed #2592 debt): ./b$' <<<"$wf"; then
    ok "teeth whole module: with ./a's mutants killed the run PASSes and names exactly what was skipped (./b)"
  else no "teeth whole module: want PASS naming ./b, got: $wf"; fi
fi

# Mutation testing (gremlins, pinned in the Makefile): the gate is zero LIVED mutants among covered ones.
# RSDD_TEETH_BASE unset: the whole module. Set: only the packages changed vs that ref (see the header).
t0=$SECONDS
verdict=""
if [ -z "${RSDD_TEETH_BASE:-}" ]; then
  teeth_whole_module "$MOD" "$MOD/Makefile" "$ROOT"
else
  files="$(changed_go_files "$MOD" "$RSDD_TEETH_BASE")"; prc=$?
  if [ "$prc" -ne 0 ]; then
    verdict="VERDICT: SKIP RSDD_TEETH_BASE=$RSDD_TEETH_BASE cannot be resolved (not a work tree, or no merge-base with HEAD)"
    [ "${RSDD_REQUIRE_GO:-}" = "1" ] && verdict="VERDICT: FAIL RSDD_TEETH_BASE=$RSDD_TEETH_BASE cannot be resolved (RSDD_REQUIRE_GO=1)"
  elif [ -z "$files" ]; then
    echo "teeth: n/a — no Go package changed vs $RSDD_TEETH_BASE"
    ok "teeth: n/a — no Go package changed vs $RSDD_TEETH_BASE (not counted as teeth)"
    verdict="VERDICT: NA"
  else
    ntotal="$(wc -l <<<"$files" | tr -d ' ')"
    si=1 sn=1; if [ "$SHARDED" -eq 1 ]; then si="$SHARD_I" sn="$SHARD_N"; fi
    plan="$(teeth_plan "$MOD" "$si" "$sn" <<<"$files")"
    if [ -z "$plan" ]; then
      echo "teeth: 0 files in shard $si/$sn ($ntotal changed vs $RSDD_TEETH_BASE)"
      ok "teeth: 0 files in shard $si/$sn (not counted as teeth)"
      verdict="VERDICT: NA"
    else
    nsel="$(select_shard "$si" "$sn" <<<"$files" | wc -l | tr -d ' ')"
    echo "teeth scope: changed vs $RSDD_TEETH_BASE — $nsel of $ntotal file(s)${RSDD_TEETH_SHARD:+ in shard $RSDD_TEETH_SHARD}, $(wc -l <<<"$plan" | tr -d ' ') package run(s): $(select_shard "$si" "$sn" <<<"$files" | tr '\n' ' ')"
    : > "$ROOT/verdicts.txt"
    while IFS=$'\t' read -r p ex; do
      # The exclude regexp reaches a single-quoted make argument: only file-name and regexp characters.
      if [[ "$ex" == *[!A-Za-z0-9_./\|^\(\)\$\\-]* ]]; then
        echo "VERDICT: FAIL [$p] exclude regexp has unexpected characters: $ex" >> "$ROOT/verdicts.txt"; continue
      fi
      # The path reaches an unquoted $(TEETH_PKG) in the Makefile recipe: accept only plain package paths.
      case "$p" in
        .|./*) ;;
        *) echo "VERDICT: FAIL [$p] not a ./-relative package path" >> "$ROOT/verdicts.txt"; continue ;;
      esac
      if [[ "$p" == *[!A-Za-z0-9_./-]* ]]; then
        echo "VERDICT: FAIL [$p] package path has characters outside [A-Za-z0-9_./-]" >> "$ROOT/verdicts.txt"; continue
      fi
      # </dev/null: make must not read the package list this loop is consuming from stdin.
      make -C "$MOD" teeth TEETH_PKG="$p" TEETH_EXCLUDE="$(make_value "$ex")" >"$ROOT/gremlins.out" 2>&1 </dev/null; mrc=$?
      one="$(decide_gremlins "$ROOT/gremlins.out" "$mrc" "$p")"
      echo "--- teeth: $p"
      echo "$one" | grep -v '^VERDICT:'
      echo "$one" | grep '^VERDICT:' | sed "s|^VERDICT: \([A-Z]*\) |VERDICT: \1 [$p] |" >> "$ROOT/verdicts.txt"
    done <<<"$plan"
    verdict="$(combine_verdicts "$ROOT/verdicts.txt")"
    fi
  fi
fi
echo "gremlins wall time: $((SECONDS - t0))s"
case "$verdict" in
  "VERDICT: NA") ;;
  *"VERDICT: PASS"*"debt-only"*) ok "teeth: no lived mutant outside the teeth debt list (the DEBT lines above are known lived mutants, kit issue #2592)" ;;
  *"VERDICT: PASS"*) ok "teeth: gremlins found no lived mutant" ;;
  *"VERDICT: SKIP"*) echo "SKIP: ${verdict##*VERDICT: SKIP }" ;;
  *) no "teeth: gremlins: ${verdict##*VERDICT: }" ;;
esac

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
