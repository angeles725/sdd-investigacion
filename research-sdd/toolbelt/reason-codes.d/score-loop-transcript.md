### score-loop-transcript

- `degraded: <reason>` (score-loop-transcript.sh, now `rsdd eval score-loop`, kit issue #993): the scorer's lowercase
  typed line, printed on stderr with exit 3 when the whole instrument cannot look (`git` absent, or the corpus
  window cannot be read). Per-criterion degradation is a `C<n> degraded <reason>` line on stdout and does not change
  the exit code: an unreadable or unparsable transcript, a transcript of an unrecognised shape, a missing `jq` while an
  `RSDD_OPERATOR_INPUT_JQ` / `RSDD_COMPACT_JQ` override is set, a `research-sdd-status.sh` that failed, timed out or
  printed `STALE`. The command is registered `PlainExit3`, so the generic `DEGRADED:` line is not added to stderr.
  Continuation: install the missing tool or fix the named input, then re-run.

- `score-loop-transcript.sh: RSDD_BLOCK_COMMIT_REGEX|RSDD_BLOCK_ID_REGEX|RSDD_QUESTION_REGEX|RSDD_STOP_TOKEN_REGEX is not a
  valid regular expression: <err>` / `... needs at least N capture group(s) ..., got M` (kit issue #993, divergence D1):
  exit 2. The bash script silently matched nothing for an invalid expression and crashed on an under-grouped one.
  Continuation: correct the override (RE2 syntax) or unset it.
