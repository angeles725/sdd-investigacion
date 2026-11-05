### kit-flake-hunt

- `degraded: kit-flake-hunt: <reason>` (maint/kit-flake-hunt.sh, kit issue #2209; Go: `rsdd maint flake-hunt`, the script is a
  shim): the load-flake hunter never turns an environment that could not measure into a clean hunt. `degraded` (exit 2,
  reason on stderr: a missing `bash`/`timeout`/`nproc`/`node`, no `run-all.sh`, an empty or unreadable suite list, a suite
  that is not a file, a refused or uncreatable `--out`, a load worker that expired before a suite, a failed `gh` issue search
  or `gh` call, `gh` missing under `--file-issues=apply`, or `nothing measured` when every suite skipped in every run) is
  never a zero. A bad flag or value exits 2 with `kit-flake-hunt: <reason>` and is usage, not a measurement.
  The degraded-code scan (section "How a code is derived" in `reason-codes.v1.md`) traverses only `toolbelt/*.sh` and
  `toolbelt/lib/*.sh`, so `maint/` is outside it and these states are listed here, not in the degraded table of
  `reason-codes.v1.md`.
  Continuation: fix the tool, path or value named on stderr and re-run; a hunt that printed `Flake hunt: ... flaky=F broken=B`
  with exit 1 is a finding (a flaky or a broken suite), not a degraded state.
