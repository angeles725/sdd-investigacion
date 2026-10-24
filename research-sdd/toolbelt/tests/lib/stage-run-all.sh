#!/usr/bin/env bash
# tests/lib/stage-run-all.sh — TEST-ONLY scaffolding: stage a run-all.sh copy into a fixture tests/ dir TOGETHER with
# every tests/lib file it sources (kit issue #2338: `-j N` sources lib/job-slots.sh and refuses an unbounded run
# without it, so a fixture tree holding only run-all.sh fails every -j case with rc 2). One helper for every suite
# that runs a run-all.sh copy, so a lib run-all.sh starts sourcing later reaches all of them at once.
# Sourced (never executed); defines: rsdd_stage_run_all.
#
#   rsdd_stage_run_all DEST_TESTS [RUN_ALL]
#     copy RUN_ALL (default: the real tests/run-all.sh; a suite passes its SUT or a mutant) to DEST_TESTS/run-all.sh,
#     and EVERY tests/lib/*.sh into DEST_TESTS/lib: no derived or hand-kept list, so a lib run-all.sh (or a lib it
#     sources) names in any spelling is always there. Silent on success (rc 0); rc 2 with a message on stderr when a
#     copy fails or tests/lib holds no *.sh. Callers propagate the rc (`|| return 2`, or a named FATAL at top level).
#
# FUNCTIONS ONLY — no `set` options here: a sourced `set` would change the calling suite's shell options.

_RSDD_STAGE_RA_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # LINT-CD-PHYSICAL-OK: test-only, the tests/ dir of this checkout

# rsdd_stage_run_all DEST_TESTS [RUN_ALL] — see header.
rsdd_stage_run_all() {
  local dest="$1" sut="${2:-$_RSDD_STAGE_RA_DIR/run-all.sh}" libs=()
  libs=("$_RSDD_STAGE_RA_DIR"/lib/*.sh)
  [ -f "${libs[0]}" ] || { echo "rsdd_stage_run_all: no tests/lib/*.sh under $_RSDD_STAGE_RA_DIR" >&2; return 2; }
  mkdir -p -- "$dest/lib" && cp -- "$sut" "$dest/run-all.sh" && cp -- "${libs[@]}" "$dest/lib/" \
    || { echo "rsdd_stage_run_all: cannot stage run-all.sh and tests/lib into $dest" >&2; return 2; }
}
