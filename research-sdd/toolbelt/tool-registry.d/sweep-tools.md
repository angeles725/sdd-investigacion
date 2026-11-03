### sweep-tools (#2361)

Intended divergences of `rsdd sweep tools` (the Go port behind `sweep-tools.sh` and `sweep-tools-hook.sh`) from the frozen legacy scripts. Everything else is byte-identical on stdout, stderr and exit code, pinned by a differential against the sha-pinned scripts (`internal/sweep/tools_diff_test.go`, `!nodiff`) and by goldens recorded from them (`testdata/tools/golden/cases.txt`, replayed without bash). Each row below is a `nodiff` scenario of `internal/sweep/tools_scenarios_test.go` or a unit test of `tools_unit_test.go`.

| Divergence | Legacy script | Port |
|---|---|---|
| Dependency directories (`node_modules`, `__pycache__`, `.venv`, `.git`) | `find -not -path '*/<dir>/*'` matched the whole path, so a target that itself lived under a `.venv/` or `node_modules/` directory read as `tools/ directory exists but is empty`. | The exclusion is judged on the path below `tools/` only (`TestToolsFilesIgnoreTargetPrefix`, scenario "target under a dependency dir keeps its tools"). |
| `tools/` that is a symbolic link to a directory | `find` listed the link and nothing under it: `exists but is empty`. | The link is followed (scenario "tools symlinked to a directory is followed"). |
| Tool name in a retro T-row | `grep -qF "$base"`: a name starting with a dash was read as an option and never matched (and `dirname`/`grep` printed usage errors to stderr). | The name is a literal substring (scenario "tool name starting with a dash is found in a retro"). |
| Tool name in the ledger | `grep -E` with only the dot escaped: `a+b.sh` was a regex and missed its own row; a name with `[` made grep fail. | Every character is literal (`TestToolsInLedger`, scenario "regex metacharacters in a ledger name are literal"). |
| `lib/target-paths.sh` missing or defining no function (`sweep-tools: helper ... failed to define target_paths_all`, exit 1) | Fail-closed exits of the bash helper. | No equivalent: the derivation is `internal/core/kit`; there is no helper to break. |
| Hook: `WARN-line extraction failed: grep exit N` and `INFO-line extraction failed` | A `grep` that exited 2 inside the hook. | No equivalent: the hook filters strings in process. |

Same-state behaviour kept on purpose: a retro or ledger that cannot be read is the typed `WARN: ... unreadable during T-row scan (grep error)` / `tools/README.md scan FAILED (grep error)` line (never a zero), and a file with a NUL byte matches nothing, as for grep. Test-side guards: the unreadable-file cases go through the `readFunc` seam of the sweep (the scenario lists the paths in `RSDD_TOOLS_TEST_UNREADABLE`; the differential really chmods them and fails when run as root).
