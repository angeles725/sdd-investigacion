### run-all-cache

- `Cache: DEGRADED — <reason>` (`tests/run-all.sh --cache`, kit issue #2201 part 2): the result cache could not be
  keyed or stored, so EVERY suite ran without it; printed on stderr when it happens and as an aggregate line, exit code
  unchanged (the run is still the authoritative one). It lives in `tests/`, outside the scanned scripts, so it is NOT a
  row of the degraded table. Reasons: `no sha256 tool (<cmd> not on PATH)`; `neither XDG_CACHE_HOME nor HOME is set`;
  `cache dir '<dir>' cannot be created or written`; `suite-impact.sh not found next to run-all.sh`;
  `suite-impact.sh --deps-all exited N (<its message>)`; `suite-impact.sh --deps-all printed no DEPS-SUMMARY line`;
  `suite-impact.sh knows N suite(s) but this runner discovered M`; `could not hash the files under research-sdd/`;
  `scanning for '<pattern>' failed`; `cannot create temp files`. Continuation: install the tool, point
  `XDG_CACHE_HOME` at a writable directory outside the repo, or fix the suite-impact failure, then re-run.
- `Cache: hit H, miss M, uncacheable U — [<suite>: <reason>, ...]` (not degraded): a suite that is never keyed always
  runs and says why: `always-run`, `blind-spot (manifest|detected:<class>)`, `no dependency resolved`, `not known to suite-impact.sh`,
  `suite file unreadable`, `dependency unreadable: <file>`, `could not compute the key`. `Cache store FAILED: N` means N
  full passes could not be written (those suites run again next time). A cache dir inside the repository is refused with
  exit 2 before any suite runs; `--cache` with `--require-teeth` or `--shard` is refused with exit 2.
- `degraded: suite-impact: <reason>` for `--deps-all` / `--deps <suite>` (`tests/suite-impact.sh`): the existing
  suite-impact reasons plus `no such suite: <path>` (an unknown `--deps` argument) and
  `dependency pass produced no suites (could not look)`; exit 2. `BLIND` and `UNRESOLVED` lines in its output are
  answers, not degraded states: they mean the suite's reach is unknowable, and run-all.sh never caches such a suite.
