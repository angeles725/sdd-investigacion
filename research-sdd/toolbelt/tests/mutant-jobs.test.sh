#!/usr/bin/env bash
# mutant-jobs.test.sh — suite for the concurrent-teeth batch of tests/lib/mutant.sh (kit issue #2331):
# mutant_jobs_begin / mutant_job / mutant_jobs_end. Invariants: verdicts in declaration order whatever the
# finishing order (a byte-identical report for any MUTANT_JOBS), MUTANT_JOBS bounds the live jobs, each job
# has its own scratch dir, a job past MUTANT_JOB_TIMEOUT is a named FAIL counted once with its process tree
# killed, and every misuse is a loud rc 2. Kept out of mutant.test.sh: its teeth re-run that whole suite,
# so these timed cases would be paid once per helper tooth there.
#
# Usage: mutant-jobs.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$LIB"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset MUTANT_JOBS MUTANT_JOB_TIMEOUT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== mutant-jobs.test.sh =="

# expect_rc <label> <want-rc> <want-stderr-substring> <cmd...> — the exact rc AND the specific refusal text.
expect_rc(){
  local label="$1" want="$2" needle="$3"; shift 3
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$err" == *"$needle"* ]]; then ok "$label"
  else no "$label (rc=$rc want=$want; stderr=[$err])"; fi
}

# Concurrent teeth (#2331): mutant_jobs_begin / mutant_job / mutant_jobs_end run teeth MUTANT_JOBS at a time,
# each in its own scratch dir under a hard MUTANT_JOB_TIMEOUT bound, and judge them in DECLARATION order after all ran.
# jv NAME RC OUT — the test verdict: one line per job with its rc and output, so order and attribution are visible.
jv(){ printf 'V %s rc=%s out=[%s]\n' "$1" "$2" "$(tr '\n' ' ' < "$3")"; }
# jbatch JOBS — four jobs that FINISH in reverse declaration order (d first, a last); prints the verdict lines.
jbatch(){
  local d; d="$(mktemp -d "$TMP/jb.XXXXXX")"; jc=0
  MUTANT_JOBS="$1" mutant_jobs_begin "$d" || return 2
  mutant_job a bash -c 'sleep 0.3; echo A; exit 3'
  mutant_job b bash -c 'sleep 0.2; echo B >&2'
  mutant_job c bash -c 'sleep 0.1; echo C; exit 1'
  mutant_job d bash -c 'echo D'
  mutant_jobs_end jc jv "teeth "
}
j1="$(jbatch 1)"; j4="$(jbatch 4)"
want=$'V a rc=3 out=[A ]\nV b rc=0 out=[B ]\nV c rc=1 out=[C ]\nV d rc=0 out=[D ]'
if [ "$j4" = "$want" ]; then ok "jobs: verdicts in declaration order, each with its own rc and stdout+stderr (jobs=4)"
else no "jobs: order/attribution under jobs=4 [$j4]"; fi
if [ "$j1" = "$j4" ]; then ok "jobs: the report is byte-identical under jobs=1 and jobs=4"; else no "jobs: jobs=1 report differs [$j1]"; fi
# throttle: each job leaves a marker in one shared dir while it runs and reports the most markers it saw, so the
# peak is the concurrency. JWATCH DIR NAME BARRIER — wait (bound 10 s) until BARRIER markers exist, then sample for
# 0.5 s. With the barrier the lower bound holds by construction; without it a broken cap can only be MISSED on a
# slow host (a false PASS), never reported falsely.
JWATCH=': > "$1/$2"; i=0; while [ "$(ls "$1" | wc -l)" -lt "$3" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
p=0; i=0; while [ $i -lt 10 ]; do n=$(ls "$1" | wc -l); [ "$n" -gt "$p" ] && p=$n; sleep 0.05; i=$((i+1)); done; echo "$p"; rm -f "$1/$2"'
# jpeak JOBS COUNT BARRIER [foreign] — peak live jobs of COUNT watcher jobs at MUTANT_JOBS=JOBS. "foreign": the
# caller first starts four short background jobs of its own, which must never free a batch slot.
jpeak(){
  local d sh n f; d="$(mktemp -d "$TMP/jp.XXXXXX")"; sh="$d/live"; mkdir "$sh" "$d/j"; jc=0; JPEAK=0
  if [ "${4:-}" = foreign ]; then for f in 1 2 3 4; do sleep 0.1 & done; fi
  MUTANT_JOBS="$1" mutant_jobs_begin "$d/j" || return 2
  for n in $(seq 1 "$2"); do mutant_job "p$n" bash -c "$JWATCH" _ "$sh" "p$n" "$3"; done
  mutant_jobs_end jc jpv "" ; wait; printf '%s\n' "$JPEAK"
}
jpv(){ local v; v="$(tr -dc 0-9 < "$3")"; [ "${v:-0}" -gt "${JPEAK:-0}" ] && JPEAK="$v"; return 0; }
p4="$(jpeak 4 4 4)"
if [ "$p4" = 4 ]; then ok "jobs: MUTANT_JOBS=4 runs four jobs at once (barrier: peak $p4)"; else no "jobs: throttle peak jobs=4 -> $p4 (want 4)"; fi
p2="$(jpeak 2 6 1)"
if [ "$p2" -le 2 ]; then ok "jobs: MUTANT_JOBS=2 never has more than two jobs alive (peak $p2)"; else no "jobs: throttle peak jobs=2 -> $p2 (cap 2)"; fi
pf="$(jpeak 2 6 1 foreign)"
if [ "$pf" -le 2 ]; then ok "jobs: a caller's own background job finishing never frees a batch slot (peak $pf at 2)"
else no "jobs: foreign-job peak $pf at jobs=2 — a non-batch child freed a slot"; fi
# sleep_pids N TOKEN — pids of live `sleep N` processes of THIS run, read from /proc: exact argv (so it never
# matches this script) AND the run's MUTANT_JX_TOKEN in the environment, so a concurrent run of this suite (a
# sibling worktree, parallel CI) that drew the same bound is never reported, let alone killed.
sleep_pids(){ local f p; for f in /proc/[0-9]*/cmdline; do
  [ "$(tr '\0' ' ' < "$f" 2>/dev/null)" = "sleep $1 " ] || continue
  p="${f#/proc/}"; p="${p%/cmdline}"
  tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qxF "MUTANT_JX_TOKEN=$2" && echo "$p"
done; return 0; }
# interrupt: a TERM to the batch shell mid-batch kills every job, its manager and its watchdog; nothing survives.
d="$(mktemp -d "$TMP/jx.XXXXXX")"; jb=$((7000 + RANDOM % 1000)); jxtok="$$.$RANDOM.$RANDOM"
MUTANT_JX_TOKEN="$jxtok" MUTANT_JOBS=2 MUTANT_JOB_TIMEOUT="$jb" bash -c '. "$1"; mutant_jobs_begin "$2"; v(){ :; }
  for n in x1 x2 x3; do mutant_job "$n" bash -c "echo \$\$ > \"\$MUTANT_JOB_SCRATCH/pid\"; exec sleep 60"; done
  c=0; mutant_jobs_end c v; echo DONE' _ "$LIB" "$d" >"$d.out" 2>&1 &
jxb=$!; i=0
while { [ ! -s "$d/x1.d/pid" ] || [ ! -s "$d/x2.d/pid" ]; } && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
kill -TERM "$jxb"; wait "$jxb"; jxrc=$?; sleep 0.3
jxleft=""
for f in "$d"/x*.d/pid; do p="$(cat "$f" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { jxleft="$jxleft job:$p"; kill -KILL "$p"; }; done
if [ -r /proc/self/cmdline ]; then for p in $(sleep_pids "$jb" "$jxtok"); do jxleft="$jxleft watchdog:$p"; kill -KILL "$p"; done
else echo "  SKIP  jobs: no /proc here, so surviving watchdogs are not looked for (jobs, rc and DONE still are)"; fi
if [ -z "$jxleft" ] && [ "$jxrc" = 143 ] && ! grep -q DONE "$d.out" && [ -s "$d/x1.d/pid" ]; then
  ok "jobs: a TERM mid-batch kills every outstanding job and watchdog, then the shell dies of TERM (rc 143)"
else no "jobs: interrupted batch left [$jxleft] rc=$jxrc out=[$(tr '\n' ' ' < "$d.out")]"; fi
# isolation: every job gets its own fresh, empty MUTANT_JOB_SCRATCH and its declaration index in MUTANT_JOB_INDEX.
d="$(mktemp -d "$TMP/ji.XXXXXX")"; jc=0
MUTANT_JOBS=4 mutant_jobs_begin "$d"
for n in i0 i1 i2; do mutant_job "$n" bash -c 'ls -A "$MUTANT_JOB_SCRATCH" | wc -l; echo "$MUTANT_JOB_SCRATCH $MUTANT_JOB_INDEX"; : > "$MUTANT_JOB_SCRATCH/mine"'; done
mutant_jobs_end jc jv "" >"$d.report"; ji="$(cat "$d.report")"
if grep -qx "V i0 rc=0 out=\[0 $d/i0.d 0 \]" <<<"$ji" && grep -qx "V i1 rc=0 out=\[0 $d/i1.d 1 \]" <<<"$ji" && grep -qx "V i2 rc=0 out=\[0 $d/i2.d 2 \]" <<<"$ji"; then
  ok "jobs: each job has its own empty scratch dir and its declaration index"
else no "jobs: per-job isolation [$ji]"; fi
# timeout: a job past MUTANT_JOB_TIMEOUT is a NAMED FAIL counted once, its verdict is never called, and its whole
# process tree (a grandchild sleep included) is killed.
d="$(mktemp -d "$TMP/jt.XXXXXX")"; jc=0; t0=$SECONDS
MUTANT_JOBS=2 MUTANT_JOB_TIMEOUT=1 mutant_jobs_begin "$d"
mutant_job slow bash -c 'sleep 30 & echo $! > "$MUTANT_JOB_SCRATCH/gc.pid"; wait'
mutant_job quick bash -c 'echo Q'
mutant_jobs_end jc jv "teeth " >"$d.report"; jt="$(cat "$d.report")"
jgc="$(cat "$d/slow.d/gc.pid" 2>/dev/null)"
if [ "$jt" = $'  FAIL  teeth slow: timed out — killed after 1s (MUTANT_JOB_TIMEOUT)\nV quick rc=0 out=[Q ]' ] && [ $((SECONDS - t0)) -lt 10 ]; then
  ok "jobs: a job past MUTANT_JOB_TIMEOUT is a named FAIL, not a skip or a pass; the others are still judged"
else no "jobs: timeout report [$jt] after $((SECONDS - t0))s"; fi
# the count happens in the CALLER's shell (not inside the $(...) above): run it again without a substitution
d2="$(mktemp -d "$TMP/jt.XXXXXX")"; jc=0
MUTANT_JOBS=1 MUTANT_JOB_TIMEOUT=1 mutant_jobs_begin "$d2"; mutant_job slow bash -c 'exec sleep 30'
mutant_jobs_end jc jv "" >/dev/null
if [ "$jc" = 1 ]; then ok "jobs: a timed-out job adds exactly one to the caller's counter"; else no "jobs: timeout counted $jc times"; fi
if [ -n "$jgc" ] && ! kill -0 "$jgc" 2>/dev/null; then ok "jobs: the timed-out job's grandchild is killed with it"
else no "jobs: grandchild [$jgc] of a timed-out job survived"; [ -n "$jgc" ] && kill -KILL "$jgc" 2>/dev/null; fi
# misuse is a loud rc 2, never a quiet no-op
expect_rc "jobs: MUTANT_JOBS=0 is refused" 2 "MUTANT_JOBS" env MUTANT_JOBS=0 bash -c '. "$1"; mutant_jobs_begin "$2"' _ "$LIB" "$TMP"
for v in '' abc -1 7 '1 2'; do
  expect_rc "jobs: MUTANT_JOBS='$v' is refused" 2 "MUTANT_JOBS" env MUTANT_JOBS="$v" bash -c '. "$1"; mutant_jobs_begin "$2"' _ "$LIB" "$TMP"
done
expect_rc "jobs: MUTANT_JOB_TIMEOUT=0 is refused" 2 "MUTANT_JOB_TIMEOUT" env MUTANT_JOB_TIMEOUT=0 bash -c '. "$1"; mutant_jobs_begin "$2"' _ "$LIB" "$TMP"
expect_rc "jobs: a missing batch dir is refused" 2 "directory" bash -c '. "$1"; mutant_jobs_begin "$2/nope"' _ "$LIB" "$TMP"
expect_rc "jobs: mutant_job before mutant_jobs_begin is refused" 2 "mutant_jobs_begin" bash -c '. "$1"; mutant_job a true' _ "$LIB"
expect_rc "jobs: a job name that is not a plain token is refused" 2 "name" bash -c '. "$1"; d=$(mktemp -d "$2/jm.XXXXXX"); mutant_jobs_begin "$d"; mutant_job a/b true' _ "$LIB" "$TMP"
expect_rc "jobs: a duplicate job name is refused" 2 "duplicate" bash -c '. "$1"; d=$(mktemp -d "$2/jm.XXXXXX"); mutant_jobs_begin "$d"; mutant_job a true; mutant_job a true' _ "$LIB" "$TMP"
expect_rc "jobs: an undefined verdict function is refused" 2 "verdict" bash -c '. "$1"; d=$(mktemp -d "$2/jm.XXXXXX"); mutant_jobs_begin "$d"; mutant_job a true; c=0; mutant_jobs_end c nope_fn' _ "$LIB" "$TMP"
expect_rc "jobs: mutant_jobs_end from a subshell of the batch shell is refused" 2 "subshell" bash -c '. "$1"; d=$(mktemp -d "$2/jm.XXXXXX"); mutant_jobs_begin "$d"; mutant_job a true; v(){ :; }; c=0; ( mutant_jobs_end c v )' _ "$LIB" "$TMP"
expect_rc "jobs: a bad counter name is refused" 2 "counter" bash -c '. "$1"; d=$(mktemp -d "$2/jm.XXXXXX"); mutant_jobs_begin "$d"; mutant_job a true; v(){ :; }; mutant_jobs_end "x y" v' _ "$LIB" "$TMP"

# --- teeth: mutate the job batch and require the specific case to go red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: job-batch mutants (each must fail the named case) --"
  # teeth_case NAME SED_SCRIPT NEEDLE — a helper mutant (built with the helper) must turn case NEEDLE red.
  teeth_case(){
    local name="$1" m="$TMP/helper-$1.sh" res
    if ! mutant_sed "$LIB" "$m" "$2" 2>"$TMP/helper-$name.err"; then
      no "teeth $name: could not build a valid helper mutant ($(cat "$TMP/helper-$name.err"))"; return
    fi
    res="$(MUTANT_LIB="$m" bash "$HERE/mutant-jobs.test.sh" 2>&1)"
    if grep -qF "  FAIL  $3" <<<"$res"; then ok "teeth $name: mutated helper turns the named case red"
    else no "teeth $name: mutated helper did NOT fail case [$3] — check is THEATER"; fi
  }
  teeth_case order 's/_MUTANT_JQ+=("\$name")/_MUTANT_JQ=("$name" "${_MUTANT_JQ[@]+"${_MUTANT_JQ[@]}"}")/' \
    "jobs: order/attribution under jobs=4"
  teeth_case throttle '/SENTINEL-JOBS-THROTTLE/{n;s/-ge "\$_MUTANT_JMAX"/-ge 99/}' \
    "jobs: throttle peak jobs=2"
  teeth_case validate '/SENTINEL-JOBS-VALIDATE/{n;s/{ \[ "\$v" -ge 1 \] && \[ "\$v" -le "\$3" \]; }/true/}' \
    "jobs: MUTANT_JOBS=0 is refused"
  teeth_case timeout '/SENTINEL-JOBS-TIMEOUT/{n;s/if \[ -e "\$_mje_d\/\$_mje_n\.timeout" \]; then/if false; then/}' \
    "jobs: timeout report"
  teeth_case nokill 's/_mutant_kill_tree "\$w" KILL/:/' \
    "jobs: timeout report"
  teeth_case abort '/SENTINEL-JOBS-ABORT/,+2s/_mutant_kill_tree "\${e%%:\*}" KILL/:/' \
    "jobs: interrupted batch left"
  teeth_case foreign '/SENTINEL-JOBS-REAP/{n;s/ "\${_mjr_pids\[@\]}" 2>/ 2>/};s/\[ "\${_mjr_e%%:\*}" = "\$_mjr_reaped" \] || _mjr_keep+=/[ "$_mjr_e" = "${_MUTANT_JLIVE[0]}" ] || _mjr_keep+=/' \
    "jobs: foreign-job peak"
  teeth_case scratch 's/MUTANT_JOB_SCRATCH="\$d\/\$name\.d"/MUTANT_JOB_SCRATCH="$d"/' \
    "jobs: per-job isolation"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
