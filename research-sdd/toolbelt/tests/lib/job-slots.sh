#!/usr/bin/env bash
# job-slots.sh — ONE job budget shared by run-all.sh -j N and the suites' teeth batches (kit issue #2338).
# Source it; it defines functions only.
#
# A budget is a directory of N slot files (slot.1 .. slot.N). A job holds a slot with `flock` on a descriptor
# its OWN process opened, so the slot frees itself when that process ends, however it ends (a crash, a KILL):
# no token is ever handed back by hand. run-all.sh -j N (N > 1) creates the budget, exports
# RSDD_JOB_SLOTS=<dir> and RSDD_JOB_SLOTS_LIB=<this file>, and holds one slot per suite it runs (a -j worker
# while its suite runs; the serial fallback for all of them). lib/mutant.sh's job batch joins the budget
# whenever RSDD_JOB_SLOTS is set; without it the batch keeps its plain MUTANT_JOBS throttle.
#
# Design — the invariant is "at most N jobs run at once":
#   - whoever runs holds a slot: a suite the one its runner took, a teeth job one of its own;
#   - a batch's caller already holds a slot and only waits while its jobs run, so the batch also offers ONE
#     private slot (BATCHDIR/.own-slot) that only its own jobs contend for: the caller's slot, lent to a job;
#   - waiting holds nothing: a runner or a job looks for a free slot without holding one.
# No deadlock: the only hold-and-wait is a caller holding its slot while its jobs wait for slots. Its lent
#   slot is free whenever none of its jobs runs and only those jobs contend for it, so one of them takes it
#   within one polling round and the batch moves on; a running job ends (at worst at MUTANT_JOB_TIMEOUT) and
#   frees its slot. A tooth that re-runs a suite applies the same rule one level down.
#
#   rsdd_slots_create DIR N        create DIR (it must not exist) holding slot.1..slot.N. FATAL + rc 2 when it cannot.
#   rsdd_slots_check DIR           DIR is a joinable budget: a directory holding at least one readable slot.*, with
#                                  flock on PATH. Else `FATAL: RSDD_JOB_SLOTS ...` on stderr and rc 2.
#   rsdd_slot_take VAR DIR [LENT]  block until one slot of DIR (or the LENT file) is locked on a NEW descriptor of
#                                  THIS process; its number goes to VAR. The slot is held until every copy of that
#                                  descriptor is closed: close it in a child that must not keep it (`cmd {VAR}<&-`).
#                                  rc 2 when DIR is not joinable.

# rsdd_slots_create DIR N — see header.
rsdd_slots_create() {
  local k
  # SENTINEL-SLOTS-CREATE
  if ! mkdir -- "$1" 2>/dev/null; then printf 'FATAL: cannot create the job budget (slots dir %s)\n' "$1" >&2; return 2; fi
  for ((k = 1; k <= $2; k++)); do
    : 2>/dev/null >"$1/slot.$k" || { printf 'FATAL: cannot create job slot %s/slot.%s\n' "$1" "$k" >&2; return 2; }
  done
}

# rsdd_slots_check DIR — see header.
rsdd_slots_check() {
  local f
  command -v flock >/dev/null 2>&1 || { printf 'FATAL: RSDD_JOB_SLOTS is set but flock (util-linux) is not on PATH\n' >&2; return 2; }
  # SENTINEL-SLOTS-CHECK
  if [ -n "$1" ] && [ -d "$1" ]; then
    for f in "$1"/slot.*; do [ -f "$f" ] && [ -r "$f" ] && return 0; done
  fi
  printf 'FATAL: RSDD_JOB_SLOTS=[%s] is not a joinable job budget (a directory of readable slot.* files)\n' "$1" >&2
  return 2
}

# _rsdd_slot_try FILE FLOCK-ARGS... — lock FILE on a new descriptor of this shell (its number in _RSDD_SLOT_FD): rc 0;
# busy: the descriptor is closed again, rc 1; FILE cannot be opened or flock errs: FATAL, rc 2. Called directly,
# never in $(...): the descriptor must live in the caller's process.
_rsdd_slot_try() {
  local f="$1" r; shift
  exec {_RSDD_SLOT_FD}<"$f" || { printf 'FATAL: job slot %s cannot be opened\n' "$f" >&2; return 2; }
  # SENTINEL-SLOTS-TAKE
  flock "$@" "$_RSDD_SLOT_FD"; r=$?
  [ "$r" = 0 ] && return 0
  exec {_RSDD_SLOT_FD}<&-
  [ "$r" = 1 ] && return 1   # flock's own "busy" status; anything else is an error, never a retry
  printf 'FATAL: flock failed on job slot %s (rc %s)\n' "$f" "$r" >&2; return 2
}

# rsdd_slot_take VAR DIR [LENT] — see header. One quick pass over every slot, then a kernel-blocking wait of at
# most 0.2 s on one slot at a time, rotating from the LENT slot, so a waiter costs a few forks a second.
rsdd_slot_take() {
  local -n _rst_out="$1"
  local _rst_f _rst_i=0 _rst_rc _rst_all=()
  rsdd_slots_check "$2" || return 2
  [ -z "${3:-}" ] || _rst_all+=("$3")
  _rst_all+=("$2"/slot.*)
  for _rst_f in "${_rst_all[@]}"; do
    _rsdd_slot_try "$_rst_f" -n; _rst_rc=$?
    case "$_rst_rc" in 0) _rst_out="$_RSDD_SLOT_FD"; return 0 ;; 2) return 2 ;; esac
  done
  while :; do
    _rsdd_slot_try "${_rst_all[$((_rst_i % ${#_rst_all[@]}))]}" -w 0.2; _rst_rc=$?
    case "$_rst_rc" in 0) _rst_out="$_RSDD_SLOT_FD"; return 0 ;; 2) return 2 ;; esac
    _rst_i=$((_rst_i + 1))
  done
}
