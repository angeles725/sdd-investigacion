### sweep-audits (#2687)

Intended divergences of `rsdd sweep audits` (the Go port behind `sweep-audits.sh` and `sweep-audits-hook.sh`) from the frozen legacy scripts that are not recorded in the main registry row. Everything else stays pinned by the differential against the sha-pinned scripts (`internal/sweep/audits_diff_test.go`, `!nodiff`) and the goldens replayed without bash.

| Divergence | Legacy script | Port |
|---|---|---|
| Arguments other than `--json`, `--hook`, `--full` and `--kit DIR` (#2687) | Ignored: `sweep-audits.sh --jsno` (or any word) answered in plain text and exited 0, so a caller asking for another mode could not tell it got none. | Plain mode: usage error before any output, `sweep-audits: unsupported argument "<arg>"` on stderr, exit 2. Hook mode keeps the hook contract (exit 0, empty stderr): the same line under the hook's "could not run (exit 2 …)" header. The first problem in argument order is reported. `internal/sweep/args_test.go`. |

Kit root (#2770): the path of the kit is found without naming the legacy script.

| Divergence | Legacy script | Port |
|---|---|---|
| Kit found without `--kit` (#2770) | The kit was found by resolving the legacy script `sweep-audits.sh` and keeping its directory: a kit without that script failed with `<kit>/toolbelt/sweep-audits.sh is missing`, and a directory without `toolbelt/` was reported as `research-sdd kit not found`. | `rsdd sweep audits` finds the kit root (`RESEARCH_SDD_KIT`, the launcher files, the default checkout; the first with a `toolbelt/` directory) without naming a script, so a kit whose legacy script was deleted resolves. A directory that exists but holds no `toolbelt/` is its own error: `research-sdd kit has no toolbelt/ directory: <dir> (set RESEARCH_SDD_KIT)`. The path text for a kit given with a trailing slash, a `.` segment or as a relative path is unchanged. `internal/sweep/kitroot_site_test.go`. |
| Invalid `RESEARCH_SDD_KIT` (#2770) | A set `RESEARCH_SDD_KIT` without `toolbelt/` fell through to another kit with no word. | The line `kit-run: DEGRADED: RESEARCH_SDD_KIT=<dir> invalid (no toolbelt/ directory); trying the launcher files and the default checkout` is printed once on stderr (not in a hook run, whose stderr is part of the context it hands the model); stdout and the exit code are unchanged. `internal/sweep/kitroot_site_test.go`. |
