package skilldrift

// Intended divergences from the scripts (kit issue #2365). Each one is pinned by a test in behavior_test.go or by a case marked
// `diverg` in the case tables; parity holds everywhere else, byte for byte.
//
//  1. Exit 3 of `verify skill-drift` (single harness, deployed skill absent) is NOT degraded in the script's contract, but
//     cli.Run treats a final exit code 3 as degraded and appends one stderr line, "DEGRADED: command reported a degraded state
//     without a reason". Through `rsdd` (and so through the shim) the absent report therefore has one extra stderr line. The
//     command function itself, and so every other stream and code, is the script's. Needs a cli.Command opt-out of the degraded
//     contract (reported in the unit's reply); nothing in this package can avoid it.
//  2. The script found the kit relative to its own file. The shims hand their directory over in RSDD_TOOLBELT_DIR; without it
//     the commands say so (exit 2, or a SessionStart error report for the hook) instead of guessing.
//  3. Failures of the exec seam have their own typed text where the script printed a bash diagnostic: render-profile.sh that
//     cannot be started (the script printed "<script>: line N: <path>: Permission denied" inside its own message), a failing
//     mktemp (the script let mktemp's message through), adapters.sh without RESEARCH_SDD_HARNESSES (bash: "unbound variable"),
//     and a missing bash (the script could not run at all).
//  4. The hook always emits the SessionStart JSON; lib/hook-emit.sh printed plain text when jq was missing.
//  5. The hook has one bounding mechanism, a process-group deadline. RESEARCH_SDD_NO_TIMEOUT_BIN (the bash-only watchdog path and
//     the "skipped: no timeout available" report) is accepted and ignored, and so no longer disables the staleness check, whose
//     git work is bounded by the same mechanism. After the bound the group is stopped with TERM, then KILL after 500 ms
//     (timeout(1) sent TERM only).
//  6. Widths are counted as the scripts' tools count them under a UTF-8 locale: bytes for `cut` (the 170-byte finding cut), characters
//     for awk and bash (the 280, 160 and 200 character widths).
