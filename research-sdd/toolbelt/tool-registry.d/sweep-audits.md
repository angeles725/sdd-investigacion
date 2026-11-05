### sweep-audits (#2687)

Intended divergences of `rsdd sweep audits` (the Go port behind `sweep-audits.sh` and `sweep-audits-hook.sh`) from the frozen legacy scripts that are not recorded in the main registry row. Everything else stays pinned by the differential against the sha-pinned scripts (`internal/sweep/audits_diff_test.go`, `!nodiff`) and the goldens replayed without bash.

| Divergence | Legacy script | Port |
|---|---|---|
| Arguments other than `--json`, `--hook`, `--full` and `--kit DIR` (#2687) | Ignored: `sweep-audits.sh --jsno` (or any word) answered in plain text and exited 0, so a caller asking for another mode could not tell it got none. | Plain mode: usage error before any output, `sweep-audits: unsupported argument "<arg>"` on stderr, exit 2. Hook mode keeps the hook contract (exit 0, empty stderr): the same line under the hook's "could not run (exit 2 …)" header. The first problem in argument order is reported. `internal/sweep/args_test.go`. |
