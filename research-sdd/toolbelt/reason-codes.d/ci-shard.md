### ci-shard

- `ci-shard: DEGRADED — <reason>; assigning round-robin by name (still a disjoint, complete cover)` (`rsdd maint ci-shard plan`, package
  `internal/maint/cishard`, kit issue #2753): the durations file gave no usable weight, so the shard plan is the sorted package
  list by position mod N. `<reason>` is one of `no --durations file given`, `durations file absent`, `durations file unreadable`,
  `durations file lists no package` (empty or comments only), `durations file lists no planned package` (every entry is stale). The
  command prints the shard's packages and exits 0; the line is a note on stderr, not a failure, and no balance line follows it.
  Continuation: give `--durations` a file that lists the planned packages.
- `ci-shard: INVALID — <file> line N: ...` and `ci-shard: durations file has N invalid line(s); nothing planned` (same command): a
  durations line with no seconds, extra text, seconds that are not a positive integer of at most six digits, or a package listed
  twice. Exit 1, nothing on stdout, nothing planned. Continuation: fix the line the message names. A package list (stdin) or planned
  list (`manifest --planned`) with a package twice or a path holding whitespace is the same `ci-shard: INVALID — package list
  line N: ...` / `planned list line N: ...`, exit 1.
- `ci-shard: EMPTY SHARD — I/N selected 0 of T packages (N exceeds the package count); nothing to run, so this shard is not a pass`
  (same command): this shard's own share is empty. Exit 1, nothing on stdout, as the bash runner prints `Shard: EMPTY SHARD`.
  Continuation: lower N or add packages.
- `ci-shard: absent-input — ...`, `ci-shard: empty-input — <what>: the list has no bytes; ...`, `ci-shard: no-match — <what>: the list has
  bytes but no package line; ...` (both subcommands; `<what>` is `package list` or `planned list`): the three distinct non-answers. `absent-input`
  is a standard input or a planned file that could not be read; `empty-input` zero bytes; `no-match` bytes with no package line.
  Exit 1 and nothing on stdout: an empty plan or an empty manifest is never presented as a pass. Continuation: feed the real
  package list or plan.
- `ci-shard: FINDING — <kind>: ...` (`rsdd maint ci-shard manifest`): the manifest is written on stdout and the exit is 1. Kinds:
  `empty-input` (the `go test -json` stream has no bytes) and `no-events` (bytes, but no readable event); both record every planned
  package `FAIL`. `malformed-lines` (some lines are not JSON events, others are). `unplanned-package` (the stream names a package
  the plan does not hold). `no-final-event` (a planned package started but never reported a package-level result, a killed run;
  recorded `FAIL`; not raised when the whole stream is empty, where `empty-input` or `no-events` already says so).
  `exit-0-with-fail` (`--exit 0` with a `FAIL` row). `exit-nonzero-no-fail` (a non-zero `--exit` and no row is `FAIL`, whatever mix
  of `PASS` and `SKIP` rows: an exit that no row explains; the message names the exit code and the PASS/SKIP counts). Continuation:
  check that the stream was written to a file before `make`'s status was read, that the plan and the run used the same package list,
  and re-run the shard.
- `ci-shard: header exit raised to 1 because of findings: <kind>, ...` (same command): with ANY finding and `--exit 0`, the manifest
  header is written `exit=1`, so `shard-join.sh` fails (`JOIN: SHARD FAILED`) from the manifest alone even if a workflow step
  swallowed the command's exit code. A non-zero `--exit` is written as given and this line is not printed. The report-only lines
  below never change the header.
- `Go tests skipped: N — [pkg: n]` and `unknown actions: N — [names]` (same command, stderr, always printed, report-only): the
  test-level skips counted from the stream (a package whose tests all skip is a package-level `pass`) and the events whose `Action`
  the writer does not know (`(none)` when absent). A zero is printed as `0 — []`, so it proves the stream was read.
