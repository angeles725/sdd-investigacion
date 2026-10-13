#!/usr/bin/env bash
# kit-flake-hunt.test.sh — behaviour + mutation-control suite for maint/kit-flake-hunt.sh
# (kit issue #2209: hunt load flakes by running suites repeatedly under bounded CPU load).
#
# Every behaviour is a SCENARIO function that takes the SUT path and prints `SCEN-OK` or
# `SCEN-BAD: <why>`. The suite runs each scenario against the real SUT; --prove-teeth re-runs the
# same scenarios (`--scenario NAME SUT`) against single-edit mutants of the SUT and requires the
# mutant to go red for the right reason (lib/mutant.sh refuses a mutant that is empty, identical,
# not valid bash or written into the live tree). Fake suites live in a per-scenario temp dir; the
# `gh` binary is always a shim, so nothing here can create a real issue.
#
# Usage: kit-flake-hunt.test.sh [--prove-teeth]      Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail

HERE="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$HERE/$(basename -- "${BASH_SOURCE[0]}")"
SUT_DEFAULT="$HERE/../maint/kit-flake-hunt.sh"

# --- fixtures ---------------------------------------------------------------------------------
# mkfake <repo> <name> <body>: a fake suite under <repo>/s/.
mkfake() { mkdir -p "$1/s"; printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/s/$2"; }
# CNT: fake-suite prelude. c = busy workers tagged with this run's output dir; w N = poll up to 2 s for N of them
# (the tool starts workers and suite back to back, so an immediate ps can run before `timeout` has exec'd bash).
CNT='c(){ ps -eo args= | grep -cE "^bash -c .*kit-flake-hunt-load:$FLAKE_HUNT_OUT\$"; }; w(){ for _ in $(seq 1 20); do [ "$(c)" -ge "$1" ] && break; sleep 0.1; done; }; '
mkstandard() { # stable, flaky (odd runs), broken, skip
  mkfake "$1" stable.test.sh "printf '== s ==\n  PASS  a\n== 1 passed · 0 failed ==\n'; exit 0"
  mkfake "$1" flaky.test.sh "if [ \$((FLAKE_HUNT_RUN % 2)) -eq 1 ]; then echo '  FAIL  odd run broke'; exit 1; fi; echo '  PASS  ok'; echo '== 1 passed · 0 failed =='"
  mkfake "$1" broken.test.sh "echo '  FAIL  always'; exit 1"
  mkfake "$1" skip.test.sh "echo 'SKIP: tool absent'; exit 0"
}
# load_count <out-dir>: busy-loop workers tagged with that output directory.
# proc_running <exact-args>: true when a process with exactly these args exists (captured first, so no pipe to grep -q).
proc_running() { local t; t="$(ps -eo args=)"; grep -qxF -- "$1" <<<"$t"; }
load_count() { local n; n="$(ps -eo args= | grep -cE "^bash -c .*kit-flake-hunt-load:$1\$")"; printf '%s' "${n:-0}"; }
# mkbin <dir> [skip...]: PATH dir of symlinks to the tools the SUT and the fakes need, minus <skip>.
mkbin() {
  local d="$1" c p; shift; mkdir -p "$d"
  for c in bash env timeout nproc node date mkdir rm grep dirname basename readlink cat sleep sed sort mktemp ps wc tr head awk; do
    case " $* " in *" $c "*) continue ;; esac
    p="$(command -v "$c")" || continue; ln -sf "$p" "$d/$c"
  done
}
mkgh() { # shim gh in <dir>/gbin; behaviour driven by files in <dir>
  mkdir -p "$1/gbin"
  cat >"$1/gbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s|' "\$@" >>"$1/gh.log"; echo >>"$1/gh.log"; pwd >>"$1/gh.cwd"
case "\$1 \$2" in
  "issue list") [ -f "$1/gh-fail" ] && exit 1; [ -f "$1/gh-existing" ] && cat "$1/gh-existing"; exit 0 ;;
  "issue create") echo "https://example.invalid/issues/1"; exit 0 ;;
  "issue comment") exit 0 ;;
esac
exit 0
EOF
  chmod +x "$1/gbin/gh"
}
setup() { W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; R="$W/repo"; mkdir -p "$R"; }
# run_hunt <sut> <args...> -> OUTPUT (stdout+stderr), RC
run_hunt() { local sut="$1"; shift; SEQ=$((SEQ+1)); LASTOUT="$W/out$SEQ"; OUTPUT="$(bash "$sut" --repo "$R" --out "$LASTOUT" "$@" 2>&1)"; RC=$?; }
bad() { echo "SCEN-BAD: $1"; return 1; }
SEQ=0

# --- scenarios --------------------------------------------------------------------------------
sc_classify() ( setup; sut="$1"; mkstandard "$R"
  run_hunt "$sut" --runs 4 --load 0 --suite s/stable.test.sh --suite s/flaky.test.sh --suite s/broken.test.sh --suite s/skip.test.sh
  [ "$RC" -eq 1 ] || bad "exit $RC, want 1 (a flaky suite) out=[$OUTPUT]" || exit 1
  grep -qxF 'flaky: s/flaky.test.sh failed 2/4 — FAIL  odd run broke' <<<"$OUTPUT" || bad "no exact flaky line: [$OUTPUT]" || exit 1
  grep -qxF 'broken: s/broken.test.sh failed 4/4 — FAIL  always' <<<"$OUTPUT" || bad "no exact broken line: [$OUTPUT]" || exit 1
  ! grep -q '^flaky: s/broken' <<<"$OUTPUT" || bad "an always-failing suite was called flaky" || exit 1
  grep -qxF 'Flake hunt: runs=4 suites=4 load=0 flaky=1 broken=1 stable=1 skipped=1' <<<"$OUTPUT" || bad "totals: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_clean() ( setup; sut="$1"; mkstandard "$R"
  run_hunt "$sut" --runs 2 --load 0 --suite s/stable.test.sh --suite s/skip.test.sh
  [ "$RC" -eq 0 ] || bad "exit $RC, want 0 on a clean hunt out=[$OUTPUT]" || exit 1
  grep -qxF 'Flake hunt: runs=2 suites=2 load=0 flaky=0 broken=0 stable=1 skipped=1' <<<"$OUTPUT" || bad "totals: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_brokenonly() ( setup; sut="$1"; mkstandard "$R"
  run_hunt "$sut" --runs 3 --load 0 --suite s/broken.test.sh
  [ "$RC" -eq 1 ] || bad "exit $RC, want 1 (a suite failing every run is a defect) out=[$OUTPUT]" || exit 1
  grep -q '^broken: s/broken.test.sh failed 3/3' <<<"$OUTPUT" || bad "broken suite not listed loudly: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_tsv() ( setup; sut="$1"; mkstandard "$R"
  run_hunt "$sut" --runs 2 --load 0 --suite s/stable.test.sh --suite s/flaky.test.sh
  t="$LASTOUT/results.tsv"; [ -s "$t" ] || bad "no results.tsv at $t" || exit 1
  [ "$(wc -l <"$t")" -eq 4 ] || bad "want 4 rows (2 runs x 2 suites), got $(wc -l <"$t")" || exit 1
  [ "$(awk -F'\t' 'NF!=4' "$t" | wc -l)" -eq 0 ] || bad "a row without exactly 4 tab fields" || exit 1
  grep -qxF "$(printf '1\ts/flaky.test.sh\tFAIL\tFAIL  odd run broke')" "$t" || bad "run-1 flaky row wrong: $(cat "$t")" || exit 1
  grep -qxF "$(printf '2\ts/flaky.test.sh\tPASS\t')" "$t" || bad "run-2 flaky row wrong" || exit 1
  grep -qxF "$(printf '2\ts/stable.test.sh\tPASS\t')" "$t" || bad "stable row wrong" || exit 1
  grep -qxF "Results: $t" <<<"$OUTPUT" || bad "no Results: line naming the tsv" || exit 1
  echo SCEN-OK )

sc_timeout() ( setup; sut="$1"
  mkfake "$R" slow.test.sh "exec sleep 9.211"
  run_hunt "$sut" --runs 2 --load 0 --suite-timeout 1 --suite s/slow.test.sh
  grep -q "$(printf 'TIMEOUT')" "$LASTOUT/results.tsv" || bad "no TIMEOUT row: $(cat "$LASTOUT/results.tsv")" || exit 1
  grep -q '^broken: s/slow.test.sh failed 2/2' <<<"$OUTPUT" || bad "a timed-out suite did not count as failing: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_skip() ( setup; sut="$1"; mkstandard "$R"
  # a suite that skips on run 1 and passes on run 2 is stable, not skipped; one that skips every run is skipped
  mkfake "$R" mixed.test.sh "if [ \"\$FLAKE_HUNT_RUN\" = 1 ]; then echo 'SKIP: first'; else echo '== 1 passed · 0 failed =='; fi; exit 0"
  run_hunt "$sut" --runs 2 --load 0 --suite s/mixed.test.sh --suite s/skip.test.sh
  grep -qxF 'Flake hunt: runs=2 suites=2 load=0 flaky=0 broken=0 stable=1 skipped=1' <<<"$OUTPUT" || bad "totals: [$OUTPUT]" || exit 1
  grep -q "$(printf 'SKIP')" "$LASTOUT/results.tsv" || bad "no SKIP row" || exit 1
  echo SCEN-OK )

sc_prove() ( setup; sut="$1"
  mkfake "$R" args.test.sh "echo \"\$*\" >>\"$W/args.log\"; exit 0"
  run_hunt "$sut" --runs 1 --load 0 --suite s/args.test.sh
  run_hunt "$sut" --runs 1 --load 0 --prove-teeth --suite s/args.test.sh
  [ "$(sed -n 1p "$W/args.log")" = "" ] || bad "--prove-teeth passed without being asked: [$(sed -n 1p "$W/args.log")]" || exit 1
  [ "$(sed -n 2p "$W/args.log")" = "--prove-teeth" ] || bad "--prove-teeth not forwarded: [$(sed -n 2p "$W/args.log")]" || exit 1
  echo SCEN-OK )

sc_survivors() ( setup; sut="$1"
  mkfake "$R" mid.test.sh "$CNT"'w 2; c >'"$W/mid"'; sleep 0.5; exit 0'
  run_hunt "$sut" --runs 1 --load 2 --load-timeout 6 --suite s/mid.test.sh
  [ "$(cat "$W/mid" 2>/dev/null)" = 2 ] || bad "want 2 busy workers during the run, saw [$(cat "$W/mid" 2>/dev/null)]" || exit 1
  n="$(load_count "$LASTOUT")"; [ "$n" -eq 0 ] || bad "$n load worker(s) survived a normal exit" || exit 1
  echo SCEN-OK )

sc_interrupt() ( setup; sut="$1"
  mkfake "$R" hang.test.sh "exec sleep 9.137"
  bash "$sut" --repo "$R" --out "$W/outI" --runs 1 --load 2 --load-timeout 6 --suite-timeout 8 --suite s/hang.test.sh >"$W/int.out" 2>&1 &
  tp=$!
  for _ in $(seq 1 100); do
    [ "$(load_count "$W/outI")" -ge 2 ] && proc_running 'sleep 9.137' && break; sleep 0.1
  done
  [ "$(load_count "$W/outI")" -ge 2 ] || { kill "$tp" 2>/dev/null; bad "load never started"; exit 1; }
  t0=$SECONDS; kill -TERM "$tp"; wait "$tp"; rc=$?; took=$((SECONDS - t0))
  for _ in $(seq 1 30); do
    [ "$(load_count "$W/outI")" -eq 0 ] && ! proc_running 'sleep 9.137' && break; sleep 0.1
  done
  n="$(load_count "$W/outI")"; [ "$n" -eq 0 ] || bad "$n load worker(s) survived an interrupted tool" || exit 1
  ! proc_running 'sleep 9.137' || bad "the running suite survived an interrupted tool" || exit 1
  [ "$rc" -eq 143 ] || bad "interrupted tool exited $rc, want 143" || exit 1
  [ "$took" -le 3 ] || bad "interrupted tool took ${took}s to exit (it waited for its children instead of stopping them)" || exit 1
  echo SCEN-OK )

sc_loadbound() ( setup; sut="$1"
  mkfake "$R" late.test.sh "$CNT"'w 1; c >'"$W/early"'; sleep 2.6; c >'"$W/late"'; exit 0'
  run_hunt "$sut" --runs 1 --load 1 --load-timeout 1 --suite s/late.test.sh
  [ "$(cat "$W/early")" = 1 ] || bad "want 1 worker early, saw [$(cat "$W/early")]" || exit 1
  [ "$(cat "$W/late")" = 0 ] || bad "worker outlived --load-timeout (saw [$(cat "$W/late")])" || exit 1
  echo SCEN-OK )

sc_edges() ( setup; sut="$1"; mkstandard "$R"
  # suites file: comments, blank lines, indentation, and a LAST line with no trailing newline
  printf '# header\n\n  s/stable.test.sh  # trailing\ns/skip.test.sh\ns/flaky.test.sh' >"$W/list"
  run_hunt "$sut" --runs 2 --load 0 --suites "$W/list"
  grep -q 'suites=3 ' <<<"$OUTPUT" || bad "suites file (no final newline) selected the wrong count: [$OUTPUT]" || exit 1
  grep -q '^flaky: s/flaky.test.sh failed 1/2' <<<"$OUTPUT" || bad "the LAST list line was never run: [$OUTPUT]" || exit 1
  # the flaky suite in FIRST, MIDDLE and LAST position of --suite
  for order in "flaky stable skip" "stable flaky skip" "stable skip flaky"; do
    a=(); for n in $order; do a+=(--suite "s/$n.test.sh"); done
    run_hunt "$sut" --runs 2 --load 0 "${a[@]}"
    grep -q '^flaky: s/flaky.test.sh failed 1/2' <<<"$OUTPUT" || bad "flaky suite lost at order [$order]: [$OUTPUT]" || exit 1
    grep -q 'suites=3 flaky=1 broken=0 stable=1 skipped=1' <<<"$OUTPUT" || grep -q 'suites=3 .*flaky=1 broken=0 stable=1 skipped=1' <<<"$OUTPUT" || bad "totals at order [$order]: [$OUTPUT]" || exit 1
  done
  # single suite
  run_hunt "$sut" --runs 2 --load 0 --suite s/flaky.test.sh
  grep -q 'suites=1 .*flaky=1' <<<"$OUTPUT" || bad "single-suite hunt: [$OUTPUT]" || exit 1
  # --runs 1: one failure cannot be told from a flake and reads as broken
  run_hunt "$sut" --runs 1 --load 0 --suite s/flaky.test.sh
  grep -q '^broken: s/flaky.test.sh failed 1/1' <<<"$OUTPUT" || bad "K=1 failure not broken: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_degraded() ( setup; sut="$1"; mkstandard "$R"
  chk() { # <label> <want-rc> <grep-regex> <args...>; runs with the normal PATH
    local label="$1" want="$2" re="$3"; shift 3
    run_hunt "$sut" "$@"
    [ "$RC" -eq "$want" ] || bad "$label: exit $RC, want $want out=[$OUTPUT]" || return 1
    grep -qE "$re" <<<"$OUTPUT" || bad "$label: output lacks /$re/: [$OUTPUT]" || return 1
  }
  # control: a restricted PATH holding every needed tool still hunts (so the missing-tool rows below prove the probe)
  mkbin "$W/bin"
  OUTPUT="$(PATH="$W/bin" bash "$sut" --repo "$R" --out "$W/oc" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || bad "control with a full restricted PATH exited $RC: [$OUTPUT]" || exit 1
  for tool in timeout nproc; do
    rm -rf "$W/bin2"; mkbin "$W/bin2" "$tool"
    OUTPUT="$(PATH="$W/bin2" bash "$sut" --repo "$R" --out "$W/od$tool" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
    [ "$RC" -eq 2 ] || bad "missing $tool: exit $RC, want 2" || exit 1
    grep -q "degraded: kit-flake-hunt: required tool '$tool'" <<<"$OUTPUT" || bad "missing $tool: no typed degraded line: [$OUTPUT]" || exit 1
  done
  chk "no run-all" 2 'degraded: kit-flake-hunt: run-all.sh not found' --runs 1 --load 0 || exit 1
  : >"$W/empty"
  chk "empty list" 2 'degraded: kit-flake-hunt: no suites selected' --load 0 --suites "$W/empty" || exit 1
  chk "missing suite" 2 'degraded: kit-flake-hunt: suite not found: s/nope.test.sh' --load 0 --suite s/nope.test.sh || exit 1
  chk "unreadable list" 2 'degraded: kit-flake-hunt: suite list not readable' --load 0 --suites "$W/none" || exit 1
  chk "runs 0" 2 'runs must be' --runs 0 --suite s/stable.test.sh || exit 1
  chk "runs abc" 2 'runs must be' --runs abc --suite s/stable.test.sh || exit 1
  chk "load -1" 2 'load must be' --load -1 --suite s/stable.test.sh || exit 1
  chk "bad tier" 2 'tier must be' --tier mid --suite s/stable.test.sh || exit 1
  chk "unknown flag" 2 'unknown argument' --bogus || exit 1
  chk "both lists" 2 'mutually exclusive' --suites "$W/empty" --suite s/stable.test.sh || exit 1
  # the output directory may not live inside the repo
  OUTPUT="$(bash "$sut" --repo "$R" --out "$R/out" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] && grep -q 'is the repo or inside it' <<<"$OUTPUT" || bad "out inside repo: rc=$RC [$OUTPUT]" || exit 1
  [ ! -e "$R/out" ] || bad "refused --out was left behind in the repo" || exit 1
  echo SCEN-OK )

sc_tier() ( setup; sut="$1"; mkstandard "$R"
  ra="$R/research-sdd/toolbelt/tests/run-all.sh"; mkdir -p "$(dirname "$ra")"
  cat >"$ra" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/ra.log"
case "\$*" in
  *"--tier core"*) [ -f "$W/accept-tier" ] || { echo "usage: run-all.sh ..." >&2; exit 2; }; echo s/stable.test.sh; exit 0 ;;
esac
printf 's/stable.test.sh\ns/skip.test.sh\n'
EOF
  # default tier: no --tier flag reaches the runner
  run_hunt "$sut" --runs 1 --load 0
  grep -q 'suites=2 ' <<<"$OUTPUT" || bad "default selection via --list-suites: [$OUTPUT]" || exit 1
  ! grep -q -- '--tier' "$W/ra.log" || bad "default tier passed --tier to the runner: $(cat "$W/ra.log")" || exit 1
  # core on a runner that rejects --tier: full list + a note
  : >"$W/ra.log"; run_hunt "$sut" --runs 1 --load 0 --tier core
  grep -q '^note: run-all.sh rejected --tier core' <<<"$OUTPUT" || bad "no fallback note: [$OUTPUT]" || exit 1
  grep -q 'suites=2 ' <<<"$OUTPUT" || bad "fallback did not use the full list: [$OUTPUT]" || exit 1
  # core on a runner that accepts it: its narrower list, no note
  touch "$W/accept-tier"; run_hunt "$sut" --runs 1 --load 0 --tier core
  grep -q 'suites=1 ' <<<"$OUTPUT" && ! grep -q '^note:' <<<"$OUTPUT" || bad "accepted --tier core: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_xdg() ( setup; sut="$1"; mkstandard "$R"
  OUTPUT="$(XDG_STATE_HOME="$W/xdg" bash "$sut" --repo "$R" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
  t="$(grep '^Results: ' <<<"$OUTPUT" | sed 's/^Results: //')"
  case "$t" in "$W"/xdg/research-sdd/flake-hunt/*/results.tsv) ;; *) bad "default out not under XDG_STATE_HOME: [$t]"; exit 1 ;; esac
  [ -s "$t" ] || bad "no results at $t" || exit 1
  echo SCEN-OK )

issue_setup() { mkstandard "$R"; mkgh "$W"; mkbin "$W/bin"; }
sc_issues_dry() ( setup; sut="$1"; issue_setup
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues --suite s/flaky.test.sh
  [ "$RC" -eq 1 ] || bad "exit $RC" || exit 1
  grep -q "^would run: gh issue create --title .*flaky.test.sh.* --label type:bug --body-file" <<<"$OUTPUT" || bad "no would-run create line: [$OUTPUT]" || exit 1
  ! grep -qE 'issue (create|comment)\|' "$W/gh.log" || bad "dry mode executed gh: $(cat "$W/gh.log")" || exit 1
  grep -q '^issue|list|' "$W/gh.log" || bad "dry mode did not search for an existing issue: $(cat "$W/gh.log")" || exit 1
  printf '77\tflake: flaky.test.sh failed 1/2 under CPU load\n' >"$W/gh-existing"; : >"$W/gh.log"
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues --suite s/flaky.test.sh
  grep -q '^would run: gh issue comment 77 --body-file' <<<"$OUTPUT" || bad "no would-comment on the existing issue: [$OUTPUT]" || exit 1
  # near-miss titles (other suite name containing ours, a longer name, another case/prefix) must NOT dedupe
  printf '88\tflake: myflaky.test.sh failed 1/2 under CPU load\n89\tflake: flaky.test.sh.old failed 1/2\n90\tFLAKE: flaky.test.sh failed\n91\tfix flake: flaky.test.sh failed\n' >"$W/gh-existing"
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues --suite s/flaky.test.sh
  grep -q '^would run: gh issue create ' <<<"$OUTPUT" && ! grep -q 'issue comment' <<<"$OUTPUT" || bad "a near-miss title was treated as the same issue: [$OUTPUT]" || exit 1
  # gh runs against the kit repo (cwd = --repo), not the caller's cwd
  want="$(cd -P "$R" && pwd -P)"; got="$(sort -u "$W/gh.cwd")"
  [ "$got" = "$want" ] || bad "gh ran in [$got], want the repo [$want]" || exit 1
  echo SCEN-OK )

sc_issues_apply() ( setup; sut="$1"; issue_setup
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues=apply --suite s/flaky.test.sh
  [ "$RC" -eq 1 ] || bad "exit $RC" || exit 1
  grep -q '^issue|create|--title|flake: flaky.test.sh failed 1/2 under CPU load|--label|type:bug|--body-file|' "$W/gh.log" || bad "create not run as specified: $(cat "$W/gh.log")" || exit 1
  printf '77\tflake: flaky.test.sh failed 1/2 under CPU load\n' >"$W/gh-existing"; : >"$W/gh.log"
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues=apply --suite s/flaky.test.sh
  grep -q '^issue|comment|77|--body-file|' "$W/gh.log" && ! grep -q '^issue|create|' "$W/gh.log" || bad "dedupe failed: $(cat "$W/gh.log")" || exit 1
  # a failed search files nothing and is degraded, never a blind create
  rm -f "$W/gh-existing"; touch "$W/gh-fail"; : >"$W/gh.log"
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues=apply --suite s/flaky.test.sh
  [ "$RC" -eq 2 ] || bad "failed search: exit $RC, want 2" || exit 1
  ! grep -qE '^issue\|(create|comment)\|' "$W/gh.log" || bad "filed after a failed search: $(cat "$W/gh.log")" || exit 1
  echo SCEN-OK )

sc_issues_edges() ( setup; sut="$1"; issue_setup
  # nothing flaky or broken (clean) => gh is never called, even with =apply
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues=apply --suite s/stable.test.sh --suite s/skip.test.sh
  [ ! -s "$W/gh.log" ] || bad "gh called with nothing to file: $(cat "$W/gh.log")" || exit 1
  # a broken suite (fails every run) is filed too
  PATH="$W/gbin:$PATH" run_hunt "$sut" --runs 2 --load 0 --file-issues=apply --suite s/stable.test.sh --suite s/broken.test.sh
  [ "$RC" -eq 1 ] && grep -q '^issue|create|--title|flake: broken.test.sh failed 2/2 under CPU load|' "$W/gh.log" || bad "broken suite not filed: rc=$RC $(cat "$W/gh.log")" || exit 1
  # no gh: apply is degraded, dry prints the command with a dedupe-not-checked note
  mkdir -p "$W/nogh"; mkbin "$W/nogh"
  OUTPUT="$(PATH="$W/nogh" bash "$sut" --repo "$R" --out "$W/oa" --runs 2 --load 0 --file-issues=apply --suite s/flaky.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] && grep -q 'gh not found' <<<"$OUTPUT" || bad "apply without gh: rc=$RC [$OUTPUT]" || exit 1
  OUTPUT="$(PATH="$W/nogh" bash "$sut" --repo "$R" --out "$W/ob" --runs 2 --load 0 --file-issues --suite s/flaky.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 1 ] && grep -q 'dedupe not checked' <<<"$OUTPUT" || bad "dry without gh: rc=$RC [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_summary() ( setup; sut="$1"
  # exit 0 is not enough: like run-all, PASS needs a `== N passed · M failed ==` line with M=0 and N>0
  mkfake "$R" nosum.test.sh "echo '  PASS  a'; exit 0"
  mkfake "$R" failsum.test.sh "echo '== 3 passed · 1 failed =='; exit 0"
  mkfake "$R" malformed.test.sh "echo '== 3 passed · x failed =='; exit 0"
  mkfake "$R" zero.test.sh "echo '== 0 passed · 0 failed =='; exit 0"
  mkfake "$R" good.test.sh "echo '== 3 passed · 0 failed =='; exit 0"
  run_hunt "$sut" --runs 2 --load 0 --suite s/nosum.test.sh --suite s/failsum.test.sh --suite s/malformed.test.sh --suite s/zero.test.sh --suite s/good.test.sh
  for n in nosum failsum malformed zero; do
    grep -q "^broken: s/$n.test.sh failed 2/2 — .*summary" <<<"$OUTPUT" || bad "$n was not failed on its summary line: [$OUTPUT]" || exit 1
  done
  grep -qxF 'Flake hunt: runs=2 suites=5 load=0 flaky=0 broken=4 stable=1 skipped=0' <<<"$OUTPUT" || bad "totals: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_nothing() ( setup; sut="$1"; mkstandard "$R"
  run_hunt "$sut" --runs 2 --load 0 --suite s/skip.test.sh
  [ "$RC" -eq 2 ] || bad "all-skipped hunt exited $RC, want 2: [$OUTPUT]" || exit 1
  grep -q 'degraded: kit-flake-hunt: nothing measured' <<<"$OUTPUT" || bad "no typed nothing-measured line: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_outguard() ( setup; sut="$1"; mkstandard "$R"
  mkdir -p "$R/research-sdd" "$W/ext"; echo keep >"$R/keep.txt"; echo keep >"$R/research-sdd/x"; echo keep >"$W/ext/old.txt"
  ln -s "$R" "$W/lnk"
  try() { # <label> <--out value>, run from inside the repo so "." is the repo
    local label="$1" o="$2"
    OUTPUT="$(cd "$R" && bash "$sut" --repo "$R" --out "$o" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
    [ "$RC" -eq 2 ] || bad "$label: exit $RC, want 2: [$OUTPUT]" || return 1
    grep -q 'degraded: kit-flake-hunt: output directory' <<<"$OUTPUT" || bad "$label: no typed refusal: [$OUTPUT]" || return 1
    [ -f "$R/keep.txt" ] && [ -f "$R/research-sdd/x" ] && [ -f "$R/s/stable.test.sh" ] && [ -f "$W/ext/old.txt" ] || bad "$label: files were destroyed" || return 1
  }
  try "repo root" "$R" || exit 1
  try "dot" . || exit 1
  try "existing repo subdir" "$R/research-sdd" || exit 1
  try "new repo subdir" "$R/newdir" || exit 1
  [ ! -e "$R/newdir" ] || bad "a refused --out was created inside the repo" || exit 1
  try "dotdot back into the repo" "$R/../repo/newdir2" || exit 1
  [ ! -e "$R/newdir2" ] || bad "a refused --out (..) was created inside the repo" || exit 1
  try "symlink to the repo" "$W/lnk" || exit 1
  try "pre-existing non-empty dir outside the repo" "$W/ext" || exit 1
  # control: a fresh dir outside the repo works, and an existing EMPTY one is accepted
  mkdir -p "$W/emptyout"
  OUTPUT="$(bash "$sut" --repo "$R" --out "$W/emptyout" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || bad "control (empty existing out dir) exited $RC: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_node() ( setup; sut="$1"; mkstandard "$R"
  command -v node >/dev/null 2>&1 || { echo SCEN-SKIP; exit 0; }
  printf "if (process.argv.length > 2) { console.log('  FAIL  got args ' + process.argv.slice(2)); process.exit(1); }\nconsole.log('== 1 passed · 0 failed ==');\n" >"$R/s/m.test.mjs"
  # run under node (no shebang, no +x), and without --prove-teeth (run-all gives it to *.test.sh only)
  run_hunt "$sut" --runs 2 --load 0 --prove-teeth --suite s/m.test.mjs --suite s/stable.test.sh
  grep -qxF 'Flake hunt: runs=2 suites=2 load=0 flaky=0 broken=0 stable=2 skipped=0' <<<"$OUTPUT" || bad "mjs suite not run under node: [$OUTPUT]" || exit 1
  # node absent: degraded only when an mjs suite is selected
  mkbin "$W/nonode" node
  OUTPUT="$(PATH="$W/nonode" bash "$sut" --repo "$R" --out "$W/o1" --runs 1 --load 0 --suite s/m.test.mjs 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] && grep -q "degraded: kit-flake-hunt: required tool 'node'" <<<"$OUTPUT" || bad "mjs without node: rc=$RC [$OUTPUT]" || exit 1
  OUTPUT="$(PATH="$W/nonode" bash "$sut" --repo "$R" --out "$W/o2" --runs 1 --load 0 --suite s/stable.test.sh 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || bad "a shell-only hunt without node exited $RC: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_expiry() ( setup; sut="$1"; mkstandard "$R"
  mkfake "$R" first.test.sh "echo '== 1 passed · 0 failed =='; sleep 2; exit 0"
  run_hunt "$sut" --runs 1 --load 2 --load-timeout 1 --suite s/first.test.sh --suite s/stable.test.sh
  [ "$RC" -eq 2 ] || bad "expired load: exit $RC, want 2: [$OUTPUT]" || exit 1
  grep -q 'degraded: kit-flake-hunt: load expired at run 1' <<<"$OUTPUT" || bad "no typed expiry line: [$OUTPUT]" || exit 1
  [ "$(wc -l <"$LASTOUT/results.tsv")" -eq 1 ] || bad "a suite ran after the load expired: $(cat "$LASTOUT/results.tsv")" || exit 1
  # controls: a long enough load-timeout, and --load 0, never expire
  run_hunt "$sut" --runs 1 --load 2 --load-timeout 30 --suite s/first.test.sh --suite s/stable.test.sh
  [ "$RC" -eq 0 ] || bad "control with a long load-timeout exited $RC: [$OUTPUT]" || exit 1
  run_hunt "$sut" --runs 1 --load 0 --load-timeout 1 --suite s/first.test.sh --suite s/stable.test.sh
  [ "$RC" -eq 0 ] || bad "control with --load 0 exited $RC: [$OUTPUT]" || exit 1
  echo SCEN-OK )

sc_loaddefault() ( setup; sut="$1"
  # default --load-timeout = runs x suites x suite-timeout + 300 s: 2 x 1 x 7 + 300 = 314
  mkfake "$R" dflt.test.sh 'for _ in $(seq 1 20); do n=$(ps -eo args= | grep -cE "^timeout 314 bash -c .*kit-flake-hunt-load:"); [ "$n" -ge 1 ] && break; sleep 0.1; done; echo "$n" >'"$W/dflt"'; echo "== 1 passed · 0 failed =="'
  run_hunt "$sut" --runs 2 --load 1 --suite-timeout 7 --suite s/dflt.test.sh
  [ "$(cat "$W/dflt" 2>/dev/null)" = 1 ] || bad "default load-timeout is not derived from the hunt (saw [$(cat "$W/dflt" 2>/dev/null)] workers with timeout 314)" || exit 1
  echo SCEN-OK )

sc_tmpdir() ( setup; sut="$1"
  body='echo "$TMPDIR" >>'"$W/tmpdirs"'; [ -d "$TMPDIR" ] || exit 1; touch "$TMPDIR/junk"; echo "== 1 passed · 0 failed =="'
  mkfake "$R" t1.test.sh "$body"; mkfake "$R" t2.test.sh "$body"
  run_hunt "$sut" --runs 2 --load 0 --suite s/t1.test.sh --suite s/t2.test.sh
  [ "$(wc -l <"$W/tmpdirs")" -eq 4 ] && [ "$(sort -u "$W/tmpdirs" | wc -l)" -eq 4 ] || bad "want 4 distinct per-suite TMPDIRs: $(cat "$W/tmpdirs")" || exit 1
  while IFS= read -r d; do
    case "$d" in "$LASTOUT"/*) ;; *) bad "TMPDIR $d is not under the out dir"; exit 1 ;; esac
    [ ! -e "$d" ] || bad "TMPDIR $d was not cleaned up" || exit 1
  done <"$W/tmpdirs"
  grep -qxF 'Flake hunt: runs=2 suites=2 load=0 flaky=0 broken=0 stable=2 skipped=0' <<<"$OUTPUT" || bad "totals: [$OUTPUT]" || exit 1
  echo SCEN-OK )

SCENARIOS=(classify clean brokenonly tsv timeout skip prove survivors interrupt loadbound edges degraded tier xdg issues_dry issues_apply issues_edges summary nothing outguard node expiry loaddefault tmpdir)
SCEN_DESC=(
  "classification: stable/flaky/broken/skip lines, totals, exit 1"
  "a clean hunt exits 0 with zero flaky"
  "a broken-only hunt is listed as broken and exits 1"
  "results.tsv rows: 4 tab fields, run/suite/status/first FAIL line"
  "a suite past --suite-timeout is TIMEOUT and counts as failing"
  "SKIP detection: all-skip is skipped, mixed skip/pass is stable"
  "--prove-teeth is forwarded to suites only when asked"
  "no load worker survives a normal exit; exactly N run during it"
  "a TERM-interrupted tool leaves no load worker and no running suite"
  "load workers self-terminate at --load-timeout"
  "list edges: no final newline, first/middle/last position, single suite, K=1"
  "degraded and usage paths all exit 2 with typed lines"
  "--tier: default passes no flag, core falls back with a note, core honoured"
  "default out dir lives under XDG_STATE_HOME"
  "--file-issues (dry): prints would-run create/comment, runs no mutating gh"
  "--file-issues=apply: create, dedupe-to-comment, failed search files nothing"
  "--file-issues edges: nothing to file => no gh; broken filed; no gh => degraded/apply, note/dry"
  "PASS needs a valid '== N passed · 0 failed ==' summary line (none/failed/malformed/zero => FAIL)"
  "nothing measured (all skipped) is degraded, exit 2"
  "--out inside the repo (root, ., subdir, .., symlink) or a non-empty dir is refused and nothing is deleted"
  "*.test.mjs suites run under node without --prove-teeth; node probed only when needed"
  "a load worker that expired before a suite is degraded (exit 2), not a silent unloaded run"
  "default --load-timeout is derived from runs x suites x suite-timeout"
  "each suite gets its own TMPDIR under the out dir, removed afterwards"
)

if [ "${1:-}" = "--scenario" ]; then
  [ "$#" -eq 3 ] || { echo "usage: --scenario NAME SUT" >&2; exit 2; }
  "sc_$2" "$3"; exit $?
fi

# --- main -------------------------------------------------------------------------------------
[ -f "$SUT_DEFAULT" ] || { echo "FATAL: SUT not found: $SUT_DEFAULT" >&2; exit 2; }
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== kit-flake-hunt.test.sh =="

[ -x "$SUT_DEFAULT" ] && ok "script exists and is executable" || no "script missing or not executable: $SUT_DEFAULT"
for i in "${!SCENARIOS[@]}"; do
  res="$("sc_${SCENARIOS[$i]}" "$SUT_DEFAULT" 2>&1)"
  if [ "$(tail -n 1 <<<"$res")" = "SCEN-SKIP" ]; then printf '  SKIP  %s (prerequisite missing)\n' "${SCEN_DESC[$i]}"
  elif [ "$(tail -n 1 <<<"$res")" = "SCEN-OK" ]; then ok "${SCEN_DESC[$i]}"; else no "${SCEN_DESC[$i]} :: $(grep -m1 '^SCEN-BAD' <<<"$res" || echo "${res:0:300}")"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each single-edit mutant of the SUT must turn its scenario red (SCEN-BAD), not crash --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain_or_count mutant_tooth mutant_crash_re mutant_cleanup_register || exit 2
  MT="$(mktemp -d)"; mutant_cleanup_register "$MT" || exit 2
  CRASH="$(mutant_crash_re bash cmd)" || exit 2
  # teeth <label> <scenario> <sed-expr>: the original must print SCEN-OK (rc 0), the mutant SCEN-BAD (rc 1).
  teeth() {
    local m="$MT/$1.sh"
    if mutant_chain_or_count fail "teeth: $1" "$SUT_DEFAULT" "$m" "$3"; then
      if mutant_tooth "teeth: $1" 0 1 "$m" --orig "$SUT_DEFAULT" --good-has 'SCEN-OK' --bad-has 'SCEN-BAD' --bad-lacks "$CRASH" -- bash "$SELF" --scenario "$2" @SUT@; then
        pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
  }
  teeth broken-never-reported classify 's/^  elif \[ "\$f" -eq "\$RUNS" \]; then$/  elif [ "$f" -eq 999999 ]; then/'
  teeth flaky-exit-code classify 's/^rc_out=0; \[ \$((flaky + broken)) -eq 0 \] || rc_out=1$/rc_out=0/'
  teeth broken-exit-zero brokenonly 's/^rc_out=0; \[ \$((flaky + broken)) -eq 0 \] || rc_out=1$/rc_out=0; [ "$flaky" -eq 0 ] || rc_out=1/'
  teeth load-pids-untracked expiry 's/LOAD_PIDS+=("\$!"); //'
  teeth expiry-unchecked expiry 's/if ! load_alive; then/if false; then/'
  teeth exit-trap-removed survivors 's/^trap cleanup EXIT$/:/'
  # (no mutant for the explicit TERM/INT traps: bash runs the EXIT trap on a fatal signal anyway, so removing them is behaviour-neutral)
  teeth cleanup-kills-nothing interrupt 's/\[ -z "\$p" \] || kill_group "\$p"/:/'
  teeth timeout-status-lost timeout 's/then st=TIMEOUT/then st=PASS/'
  teeth suite-timeout-unbounded timeout 's/exec timeout "\$SUITE_TIMEOUT" "\${runner\[@\]}"/exec "${runner[@]}"/'
  teeth skip-not-detected skip "s/if grep -q '\\^SKIP:' \"\\\$log\"; then/if false; then/"
  teeth prove-teeth-dropped prove 's/args=(--prove-teeth)/args=()/'
  teeth results-not-written tsv 's/"\$first" >>"\$RESULTS"/"$first" >\/dev\/null/'
  teeth last-line-dropped edges '0,/|| \[ -n "\$_l" \]/s///'
  teeth load-unbounded loadbound 's/timeout "\$LOAD_TIMEOUT" bash -c/bash -c/'
  teeth load-timeout-constant loaddefault 's/^\[ -n "\$LOAD_TIMEOUT" \] || LOAD_TIMEOUT=.*$/[ -n "$LOAD_TIMEOUT" ] || LOAD_TIMEOUT=14400/'
  teeth empty-list-passes degraded 's/^\[ "\${#SUITES\[@\]}" -gt 0 \] || die/: || die/'
  teeth nproc-not-probed degraded 's/for _dep in bash timeout nproc; do/for _dep in bash timeout; do/'
  teeth out-in-repo-allowed outguard 's|case "\$OUT/" in "\$REPO"/\*) die|case "$OUT/" in "/nonexistent-never"/*) die|'
  teeth out-nonempty-allowed outguard 's/^if \[ -d "\$OUT" \] \&\& ! dir_empty "\$OUT"; then die .*$/:/'
  teeth summary-not-required summary 's/elif first="\$(pass_problem "\$log")"; then st=FAIL/elif false; then st=FAIL/'
  teeth nothing-measured-passes nothing 's/if \[ \$((flaky + broken + stable)) -eq 0 \]; then/if false; then/'
  teeth tmpdir-not-cleaned tmpdir 's/^    rm -rf -- "\$st_tmp"$/    :/'
  teeth tmpdir-shared tmpdir 's/export TMPDIR="\$st_tmp" //'
  teeth mjs-not-under-node node 's/runner=(node "\$p")/runner=(bash "$p")/'
  teeth node-probe-dropped node 's/command -v node >\/dev\/null 2>&1 || die/true || die/'
  teeth tier-note-dropped tier 's/echo "note: run-all.sh rejected/echo "xnote: run-all.sh rejected/'
  teeth dry-mode-applies issues_dry 's/^    if \[ "\$FILE_MODE" = apply \]; then$/    if [ -n "$FILE_MODE" ]; then/'
  teeth dedupe-ignored issues_dry 's/^    if \[ -n "\$existing" \]; then$/    if false; then/'
  teeth prefix-match-loosened issues_dry 's/"flake: \$base "\*)/*"$base"*)/'
  teeth gh-wrong-cwd issues_dry 's/listing="\$(cd -- "\$REPO" \&\& gh issue list/listing="$(gh issue list/'
  teeth broken-not-filed issues_edges 's/broken=\$((broken + 1)); ISSUE_LIST+=("\$s"); KIND\[\$s\]=broken/broken=$((broken + 1)); KIND[$s]=broken/'
  teeth failed-search-files-anyway issues_apply 's/if \[ "\$FILE_MODE" = apply \]; then echo "degraded: kit-flake-hunt: gh issue search/if false; then echo "degraded: kit-flake-hunt: gh issue search/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
