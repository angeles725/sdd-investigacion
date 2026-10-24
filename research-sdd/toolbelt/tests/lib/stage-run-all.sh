#!/usr/bin/env bash
# tests/lib/stage-run-all.sh — TEST-ONLY scaffolding: stage a run-all.sh copy into a fixture tests/ dir TOGETHER with
# every tests/lib file it sources (kit issue #2338: `-j N` sources lib/job-slots.sh and refuses an unbounded run
# without it, so a fixture tree holding only run-all.sh fails every -j case with rc 2). One helper for every suite
# that runs a run-all.sh copy, so a lib run-all.sh starts sourcing later reaches all of them at once.
# Sourced (never executed); defines: rsdd_stage_run_all.
#
#   rsdd_stage_run_all DEST_TESTS [RUN_ALL]
#     copy RUN_ALL (default: the real tests/run-all.sh; a suite passes its SUT or a mutant) to DEST_TESTS/run-all.sh,
#     and into DEST_TESTS/lib every lib the REAL run-all.sh sources — derived from its text (`$SCRIPT_DIR/lib/<name>.sh`),
#     never a hand-kept list. Silent on success (rc 0); rc 2 with a message on stderr when a copy fails or the
#     derivation finds no lib at all (a renamed idiom must not silently stage nothing).
#
# FUNCTIONS ONLY — no `set` options here: a sourced `set` would change the calling suite's shell options.

_RSDD_STAGE_RA_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # LINT-CD-PHYSICAL-OK: test-only, the tests/ dir of this checkout

# rsdd_stage_run_all DEST_TESTS [RUN_ALL] — see header.
rsdd_stage_run_all() {
  local dest="$1" sut="${2:-$_RSDD_STAGE_RA_DIR/run-all.sh}" text libs n
  text="$(cat -- "$_RSDD_STAGE_RA_DIR/run-all.sh")" || { echo "rsdd_stage_run_all: cannot read run-all.sh" >&2; return 2; }
  libs="$(grep -o '\$SCRIPT_DIR/lib/[A-Za-z0-9_.-]*\.sh' <<<"$text" | sort -u)"
  [ -n "$libs" ] || { echo "rsdd_stage_run_all: found no \$SCRIPT_DIR/lib/*.sh in run-all.sh" >&2; return 2; }
  mkdir -p -- "$dest/lib" && cp -- "$sut" "$dest/run-all.sh" || { echo "rsdd_stage_run_all: cannot stage run-all.sh into $dest" >&2; return 2; }
  for n in $libs; do
    n="${n##*/}"
    cp -- "$_RSDD_STAGE_RA_DIR/lib/$n" "$dest/lib/$n" || { echo "rsdd_stage_run_all: cannot stage lib/$n into $dest" >&2; return 2; }
  done
}
