#!/usr/bin/env bash
# job-budget.test.sh — suite for the ONE job budget that run-all.sh -j N shares with the suites' teeth batches
# (kit issue #2338; tests/lib/job-slots.sh + the mutant_job batch of tests/lib/mutant.sh). Invariants: everything
# run-all.sh -j N starts (its suites AND their teeth jobs) runs at most N at once, also when -j falls back to a
# serial run; a suite holding the only slot still runs its teeth (no deadlock); an interrupted or timed-out
# batch frees its slots even when a job left an orphan behind; a budget that cannot be created or joined is a
# FATAL rc 2, never an unbounded run; without RSDD_JOB_SLOTS the batch keeps its plain MUTANT_JOBS throttle.
# Concurrency is measured with fixtures/job-budget/watch.sh markers, as mutant-jobs.test.sh does.
#
# Usage: job-budget.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
# JB_ONLY=<case> runs that one case (the teeth use it); RUN_ALL_SUT / MUTANT_LIB / JOB_SLOTS_LIB swap in a mutant.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"
SLOTS_LIB="${JOB_SLOTS_LIB:-$HERE/lib/job-slots.sh}"
RUNALL="${RUN_ALL_SUT:-$HERE/run-all.sh}"
FIX="$HERE/fixtures/job-budget"; WATCH="$FIX/watch.sh"
for f in "$LIB" "$RUNALL" "$WATCH" "$FIX/suite.sh"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 2; }; done
command -v flock >/dev/null 2>&1 || { echo "FATAL: flock (util-linux) is not on PATH" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$LIB"
TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# This suite's own cases build private budgets: one inherited from an outer run-all.sh must not leak in.
unset MUTANT_JOBS MUTANT_JOB_TIMEOUT RSDD_JOB_SLOTS
export RSDD_JOB_SLOTS_LIB="$SLOTS_LIB" RUN_ALL_DEFAULT_RSDD_ROOT="$TMP/default-rsdd-private"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
want(){ [ -z "${JB_ONLY:-}" ] || [ "$JB_ONLY" = "$1" ]; }
echo "== job-budget.test.sh =="

# mkslots DIR N — a budget laid out by hand (DIR/slot.1..N), so a case never depends on the code under test to build it.
mkslots(){ local k; mkdir -p "$1"; for k in $(seq 1 "$2"); do : > "$1/slot.$k"; done; }
# free_slots DIR — how many of DIR's slots no process holds right now.
free_slots(){ local f n=0; for f in "$1"/slot.*; do flock -n "$f" true && n=$((n + 1)); done; echo "$n"; }
# wait_free DIR N — poll (bound 3 s) until N slots of DIR are free; prints the last count.
wait_free(){ local i=0 n; n="$(free_slots "$1")"; while [ "$n" -lt "$2" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i+1)); n="$(free_slots "$1")"; done; echo "$n"; }
# peak FILE — the largest line of a watch.sh PEAKS file (0 when empty).
peak(){ local p=0 v; while read -r v; do [ "${v:-0}" -gt "$p" ] && p="$v"; done < "$1"; echo "$p"; }
# batch_peak SLOTS N JOBS — run a JOBS-job watcher batch (barrier N, MUTANT_JOBS=JOBS) on budget SLOTS from a
# shell holding no slot; prints the peak. N = slots + 1 is the most it may run: the batch's lent slot plus every free one.
batch_peak(){
  local d; d="$(mktemp -d "$TMP/bp.XXXXXX")"; mkdir "$d/live" "$d/b"; : > "$d/peaks"
  RSDD_JOB_SLOTS="$1" MUTANT_JOBS="$3" bash -c '. "$1"; v(){ :; }; c=0; mutant_jobs_begin "$2/b" || exit 2
    for n in $(seq 1 "$5"); do mutant_job "p$n" bash "$3" "$2/live" "p$n" "$4" "$2/peaks"; done; mutant_jobs_end c v' \
    _ "$LIB" "$d" "$WATCH" "$2" "$3" >/dev/null 2>&1
  peak "$d/peaks"
}
# orphan_pids N TOKEN — live `sleep N` processes of THIS run (exact argv AND JB_TOKEN=TOKEN in the environment).
orphan_pids(){ local f p e; for f in /proc/[0-9]*/cmdline; do
  [ "$(tr '\0' ' ' < "$f" 2>/dev/null)" = "sleep $1 " ] || continue
  p="${f#/proc/}"; p="${p%/cmdline}"
  e="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)"; grep -qxF "JB_TOKEN=$2" <<<"$e" && echo "$p"
done; return 0; }
reap_orphans(){ local p; for p in $(orphan_pids "$1" "$2"); do kill -KILL "$p" 2>/dev/null; done; }
# A job that leaves an orphan (a `sleep ORPHAN` re-parented away from its tree) and then blocks: the orphan
# survives every tree kill, so it would keep a slot forever if the job had inherited the slot's descriptor.
ORPHAN_JOB='( exec sleep "$JB_ORPHAN" & ); echo $$ > "$MUTANT_JOB_SCRATCH/pid"; exec sleep 60'

# budget: two simulated suite workers each hold one slot of a 2-slot budget and run a work phase and a 4-job
# teeth batch: never more than 2 jobs at once in total.
if want budget; then
  d="$(mktemp -d "$TMP/bu.XXXXXX")"; mkslots "$d/slots" 2; mkdir "$d/live"; : > "$d/peaks"; pids=()
  for k in 1 2; do
    RSDD_JOB_SLOTS="$d/slots" bash -c 'exec 9<"$2/slots/slot.$3"; flock -n 9 || exit 3
      . "$1"; mkdir "$2/b$3"; c=0; v(){ :; }; bash "$4" "$2/live" "s$3-work" 1 "$2/peaks"
      mutant_jobs_begin "$2/b$3" || exit 2
      for n in 1 2 3 4; do mutant_job "t$n" bash "$4" "$2/live" "s$3-t$n" 1 "$2/peaks"; done; mutant_jobs_end c v' \
      _ "$LIB" "$d" "$k" "$WATCH" >"$d/s$k.out" 2>&1 & pids+=("$!")
  done
  brc=0; for p in "${pids[@]}"; do wait "$p" || brc=$?; done; bp="$(peak "$d/peaks")"
  if [ "$brc" = 0 ] && [ "$bp" -ge 1 ] && [ "$bp" -le 2 ]; then ok "budget: two slot-holding suites with 4-job teeth batches never run more than 2 jobs (peak $bp)"
  else no "budget: peak $bp with a 2-slot budget (rc $brc) [$(cat "$d"/s*.out | tr '\n' ' ')]"; fi
fi

# deadlock: a suite holding the ONLY slot still runs its 3-job teeth batch, one job at a time, in bounded time.
if want deadlock; then
  d="$(mktemp -d "$TMP/dl.XXXXXX")"; mkslots "$d/slots" 1; mkdir "$d/live" "$d/b"; : > "$d/peaks"
  RSDD_JOB_SLOTS="$d/slots" MUTANT_JOBS=3 timeout 20 bash -c 'exec 9<"$2/slots/slot.1"; flock -n 9 || exit 3
    . "$1"; c=0; v(){ :; }; mutant_jobs_begin "$2/b" || exit 2
    for n in 1 2 3; do mutant_job "t$n" bash "$3" "$2/live" "t$n" 1 "$2/peaks"; done; mutant_jobs_end c v' \
    _ "$LIB" "$d" "$WATCH" >"$d.out" 2>&1; drc=$?; dp="$(peak "$d/peaks")"
  if [ "$drc" = 0 ] && [ "$dp" = 1 ] && [ "$(wc -l < "$d/peaks")" = 3 ]; then ok "deadlock: a suite holding the only slot runs its teeth one at a time through its own slot"
  else no "deadlock: rc $drc (124 = hung) peak $dp runs $(wc -l < "$d/peaks") [$(tr '\n' ' ' < "$d.out")]"; fi
fi

# interrupt: while a batch runs, its jobs hold the budget's slots; a TERM to the batch shell frees every one of
# them (the jobs' orphans included) and a following batch can use the whole budget again.
if want interrupt; then
  d="$(mktemp -d "$TMP/ix.XXXXXX")"; mkslots "$d/slots" 2; mkdir "$d/b"; tok="$$.$RANDOM.$RANDOM"; ob=$((7000 + RANDOM % 1000))
  JB_TOKEN="$tok" JB_ORPHAN="$ob" RSDD_JOB_SLOTS="$d/slots" MUTANT_JOBS=3 bash -c '. "$1"; v(){ :; }; c=0
    mutant_jobs_begin "$2/b" || exit 2; for n in x1 x2 x3; do mutant_job "$n" bash -c "$3"; done; mutant_jobs_end c v; echo DONE' \
    _ "$LIB" "$d" "$ORPHAN_JOB" >"$d.out" 2>&1 &
  ib=$!; i=0
  while [ "$(cat "$d"/b/x*.d/pid 2>/dev/null | wc -l)" -lt 3 ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  iheld=$((2 - $(free_slots "$d/slots"))); kill -TERM "$ib"; wait "$ib"; irc=$?
  ifree="$(wait_free "$d/slots" 2)"; reap_orphans "$ob" "$tok"
  for f in "$d"/b/x*.d/pid; do p="$(cat "$f" 2>/dev/null)"; [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  if [ "$iheld" = 2 ]; then ok "interrupt: the running batch's jobs hold both slots of the budget"
  else no "interrupt: slots held while the batch ran = $iheld (want 2) [$(tr '\n' ' ' < "$d.out")]"; fi
  if [ "$irc" = 143 ] && [ "$ifree" = 2 ]; then ok "interrupt: a TERM mid-batch frees every slot, orphans or not (rc $irc)"
  else no "interrupt: after TERM rc=$irc, $ifree of 2 slots free"; fi
  ip="$(batch_peak "$d/slots" 3 3)"
  if [ "$ip" = 3 ]; then ok "interrupt: a following batch runs on the whole budget again (peak $ip = 2 slots + its lent one)"
  else no "interrupt: following batch peak $ip (want 3)"; fi
fi

# timeout: jobs past MUTANT_JOB_TIMEOUT are named FAILs and their slots are free once the batch ended, orphans or not.
if want timeout; then
  d="$(mktemp -d "$TMP/tm.XXXXXX")"; mkslots "$d/slots" 2; mkdir "$d/b"; tok="$$.$RANDOM.$RANDOM"; ob=$((8000 + RANDOM % 1000))
  tout="$(JB_TOKEN="$tok" JB_ORPHAN="$ob" RSDD_JOB_SLOTS="$d/slots" MUTANT_JOBS=3 MUTANT_JOB_TIMEOUT=1 bash -c '. "$1"; v(){ :; }; c=0
    mutant_jobs_begin "$2/b" || exit 2; for n in y1 y2 y3; do mutant_job "$n" bash -c "$3"; done; mutant_jobs_end c v' \
    _ "$LIB" "$d" "$ORPHAN_JOB" 2>&1)"
  tfree="$(free_slots "$d/slots")"; reap_orphans "$ob" "$tok"
  if [ "$(grep -c 'timed out' <<<"$tout")" = 3 ] && [ "$tfree" = 2 ]; then ok "timeout: timed-out jobs are named FAILs and leave both slots free at batch end"
  else no "timeout: slots not all free after the batch ($tfree of 2) [$(tr '\n' ' ' <<<"$tout")]"; fi
  tp="$(batch_peak "$d/slots" 3 3)"
  if [ "$tp" = 3 ]; then ok "timeout: a following batch runs on the whole budget again (peak $tp)"
  else no "timeout: following batch peak $tp (want 3)"; fi
fi

# fatal: a budget that cannot be joined or created is a named FATAL rc 2 — never an unbounded batch.
if want fatal; then
  expect_fatal(){ local label="$1" needle="$2" err rc; shift 2; err="$("$@" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" = 2 ] && [[ "$err" == *FATAL*"$needle"* ]]; then ok "$label"; else no "$label (rc=$rc stderr=[$err])"; fi; }
  mkdir "$TMP/empty-budget"; : > "$TMP/not-a-dir"
  for s in "$TMP/no-such-budget" "$TMP/empty-budget" "$TMP/not-a-dir" ""; do
    expect_fatal "fatal: RSDD_JOB_SLOTS=[${s#"$TMP/"}] is refused by mutant_jobs_begin" RSDD_JOB_SLOTS \
      env RSDD_JOB_SLOTS="$s" bash -c '. "$1"; mutant_jobs_begin "$(mktemp -d "$2/fb.XXXXXX")"' _ "$LIB" "$TMP"
  done
  mkdir "$TMP/ro"; chmod 555 "$TMP/ro"
  expect_fatal "fatal: a budget that cannot be created is refused" "slots" bash -c '. "$1"; rsdd_slots_create "$2/ro/slots" 2' _ "$SLOTS_LIB" "$TMP"
fi

# no budget: without RSDD_JOB_SLOTS the batch keeps the plain MUTANT_JOBS throttle (three jobs at once at 3).
if want plain; then
  d="$(mktemp -d "$TMP/pl.XXXXXX")"; mkdir "$d/live" "$d/b"; : > "$d/peaks"
  MUTANT_JOBS=3 bash -c '. "$1"; v(){ :; }; c=0; mutant_jobs_begin "$2/b" || exit 2
    for n in 1 2 3; do mutant_job "p$n" bash "$3" "$2/live" "p$n" 3 "$2/peaks"; done; mutant_jobs_end c v' _ "$LIB" "$d" "$WATCH" >/dev/null 2>&1
  pp="$(peak "$d/peaks")"
  if [ "$pp" = 3 ]; then ok "plain: without RSDD_JOB_SLOTS MUTANT_JOBS=3 still runs three jobs at once"; else no "plain: peak $pp (want 3)"; fi
fi

# run-all: two fixture suites (a work phase + a 4-job teeth batch each) under a run-all.sh copy with -j 2 never
# run more than 2 jobs at once, through GNU parallel and through the serial fallback (a non-GNU `parallel`).
# runall_peak NAME ARGS... — build a fixture tree (the nested repo shape run-all.sh resolves) and run it; sets RP/RRC.
runall_peak(){
  local name="$1" root m; shift; root="$TMP/$name/research-sdd/toolbelt/tests"; m="$TMP/$name-m"
  mkdir -p "$root/lib" "$TMP/$name/research-sdd/install/tests" "$m/live"; : > "$m/peaks"
  cp "$RUNALL" "$root/run-all.sh"; cp "$HERE"/lib/*.sh "$root/lib/"; cp "$LIB" "$root/lib/mutant.sh"
  if [ -f "$SLOTS_LIB" ]; then cp "$SLOTS_LIB" "$root/lib/job-slots.sh"; fi
  printf '# fixture: no extras\n' > "$root/suite-tiers.txt"
  cp "$FIX/suite.sh" "$root/a.test.sh"; cp "$FIX/suite.sh" "$root/b.test.sh"
  ( cd "$TMP/$name" && JB_WATCH="$WATCH" JB_LIVE="$m/live" JB_PEAKS="$m/peaks" bash "$root/run-all.sh" "$@" ) >"$m.out" 2>&1; RRC=$?
  RP="$(peak "$m/peaks")"
}
if want runall; then
  _pv="$(parallel --version 2>/dev/null)"
  if [[ "$_pv" == *"GNU parallel"* ]]; then
    runall_peak ra -j 2
    if [ "$RRC" = 0 ] && [ "$RP" -ge 1 ] && [ "$RP" -le 2 ]; then ok "run-all: -j 2 with two teeth-batch suites never runs more than 2 jobs (peak $RP)"
    else no "run-all: -j 2 peak $RP (cap 2) rc $RRC [$(tail -n 5 "$TMP/ra-m.out" | tr '\n' ' ')]"; fi
  else echo "  SKIP  run-all: -j 2 budget through GNU parallel (GNU parallel not installed)"; fi
  mkdir "$TMP/fakebin"; printf '#!/bin/sh\necho "not GNU"\n' > "$TMP/fakebin/parallel"; chmod +x "$TMP/fakebin/parallel"
  PATH="$TMP/fakebin:$PATH" runall_peak rs -j 2
  if [ "$RP" -ge 1 ] && [ "$RP" -le 2 ] && grep -qF 'DEGRADED' "$TMP/rs-m.out"; then ok "run-all: -j 2 falling back to a serial run still runs at most 2 jobs (peak $RP)"
  else no "run-all: serial fallback peak $RP (cap 2) rc $RRC"; fi
fi

# --- teeth: mutate the budget and require the named case to go red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: job-budget mutants (each must fail the named case) --"
  # teeth_case NAME KIND SED CASE NEEDLE — a mutant of KIND (mutant: lib/mutant.sh · slots: lib/job-slots.sh ·
  # runall: run-all.sh) must turn case NEEDLE red when this suite runs only CASE (JB_ONLY).
  teeth_case(){
    local name="$1" kind="$2" m="$TMP/teeth-$1.sh" res orig var
    case "$kind" in mutant) orig="$LIB" var=MUTANT_LIB ;; slots) orig="$SLOTS_LIB" var=JOB_SLOTS_LIB ;; *) orig="$RUNALL" var=RUN_ALL_SUT ;; esac
    if ! mutant_sed "$orig" "$m" "$3" 2>"$m.err"; then
      no "teeth $name: could not build a valid $kind mutant ($(cat "$m.err"))"; return
    fi
    res="$(env "$var=$m" JB_ONLY="$4" bash "$HERE/job-budget.test.sh" 2>&1)"
    if grep -qF "  FAIL  $5" <<<"$res"; then ok "teeth $name: the $kind mutant turns the named case red"
    else no "teeth $name: the $kind mutant did NOT fail case [$5] — check is THEATER [$(grep -F "  FAIL  " <<<"$res" | tr "\n" " ")]"; fi
  }
  teeth_case take slots '/SENTINEL-SLOTS-TAKE/{n;s/flock "\$@" "\$_RSDD_SLOT_FD"; r=\$?/r=0/}' budget "budget: peak"
  teeth_case join mutant 's/if \[ -n "\${RSDD_JOB_SLOTS+x}" \]; then/if false; then/' budget "budget: peak"
  teeth_case lent mutant 's/rsdd_slot_take s "\$_MUTANT_JSLOTS" "\$d\/\.own-slot"/rsdd_slot_take s "$_MUTANT_JSLOTS"/' deadlock "deadlock: rc"
  teeth_case release-interrupt mutant '/SENTINEL-JOBS-SLOT-CLOSE/{n;s/ {s}<&- & w=/ \& w=/}' interrupt "interrupt: after TERM"
  teeth_case release-timeout mutant '/SENTINEL-JOBS-SLOT-CLOSE/{n;s/ {s}<&- & w=/ \& w=/}' timeout "timeout: slots not all free after the batch"
  teeth_case check slots '/SENTINEL-SLOTS-CHECK/{n;s/^  if .* then$/  return 0; if false; then/}' fatal "fatal: RSDD_JOB_SLOTS=[no-such-budget]"
  teeth_case create slots '/SENTINEL-SLOTS-CREATE/{n;s/>&2; return 2; fi/>\&2; return 0; fi/}' fatal "fatal: a budget that cannot be created"
  if [[ "$(parallel --version 2>/dev/null)" == *"GNU parallel"* ]]; then
    teeth_case export runall '/SENTINEL-BUDGET-EXPORT/{n;s/export RSDD_JOB_SLOTS=/export RSDD_JOB_SLOTS_UNUSED=/}' runall "run-all: -j 2 peak"
    teeth_case worker runall '/SENTINEL-BUDGET-WORKER/,+3s/rsdd_slot_take slot "\$RSDD_JOB_SLOTS"/exec {slot}<\/dev\/null/' runall "run-all: -j 2 peak"
  else echo "  SKIP  teeth export/worker: GNU parallel not installed"; fi
  teeth_case hold runall '/SENTINEL-BUDGET-HOLD/{n;s/rsdd_slot_take _ra_slot "\$RSDD_JOB_SLOTS" ||/true ||/}' runall "run-all: serial fallback peak"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
