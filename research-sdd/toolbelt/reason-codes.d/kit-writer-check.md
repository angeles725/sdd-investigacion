### kit-writer-check

- `degraded: kit-writer-check: <reason>` (`maint/kit-writer-check.sh`, kit issue #2208): the writer-discipline
  check could not look, and says so on stderr with exit 2 instead of reporting a clean pass. It lives under
  `maint/`, outside the scanned scripts, so it is NOT a row of the degraded table in `reason-codes.v1.md` (section "Degraded class"). Reasons: a runtime
  dependency (git, grep, awk, sort, mktemp, timeout) is not on PATH; `not a git repository`; `bad base ref` /
  `bad head ref`; `no merge-base of <base> and HEAD`; `git diff failed`; `teeth-log dir absent` (an absent
  directory is not "no logs"); `suite-impact.sh not found`; `suite-impact.sh exited N: <its message>` (an
  impact map that could not look must never read as an empty requirement set);
  `KIT_WRITER_CHECK_TIMEOUT must be a positive integer`; `cannot create teeth-log dir`; `cannot hash the changed
  files`. Findings (exit 1, not degraded): `missing-teeth <suite> <reason>`, `stale-teeth <suite> <reason>` (the log's
  binding header is missing or its tree hash differs from the changed files), `no-suite <file>`, `name-kill
  <file>:<line>`, `bad-waiver <file>:<line>` (a waiver with no reason). Notes (never fail): `full-gate-needed:
  <reason>`, `teeth-na <suite>`, `teeth-waived <suite> (<reason>)`, `required: 0 (...)`. Continuation: install the tool or fix the
  ref or directory, then re-run; run `--write-teeth-log DIR <suite>...` to produce the logs a `missing-teeth`
  line asks for.
