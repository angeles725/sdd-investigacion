### suite-impact

- `degraded: suite-impact-oracle: <reason>` (`tests/suite-impact-oracle.sh`, kit issue #2201): same contract as the line
  below for the mutation oracle (missing tool, bad `--ref`, `<file> does not exist at <ref>`, `mutation did not change
  <file>`, `the instrument selected no suite`, `ran N of M unselected suites (could not look)`); exit 2.
- `degraded: suite-impact: <reason>` (`tests/suite-impact.sh` and `tests/suite-impact-replay.sh`, kit issue #2201): the
  impact map could not look, and says so on stderr with exit 2 instead of printing an empty selection. These two live
  under `tests/`, outside the scanned scripts, so they are NOT rows of the degraded table above. Reasons: a runtime
  dependency (git, grep, sort, awk, tar, mktemp, find) is not on PATH; `not a git repository`; `bad base ref` / `bad head
  ref`; `head <ref> has no research-sdd/ tree to analyse`; `manifest absent` (`impact-always.txt` or
  `impact-blindspot.txt` missing from the analysed tree); `no test suites found`; `empty inventory of research-sdd/`;
  `SUITE_IMPACT_WIDE_THRESHOLD must be a positive integer`; `empty selection` (the always-run manifest selected nothing); and, for the replay, `instrument absent`, `bad ref`, and
  `no commit could be analysed (nothing was measured)`. An INVALID manifest line (no reason, a suite that does not exist,
  a duplicate, or a malformed `reach=` scope in `impact-blindspot.txt`: no globs, an empty glob, a glob not starting with
  `research-sdd/` or containing `..`, or `reach=` in `impact-always.txt`) is a finding, not a degraded state: exit 1 and no
  selection is printed. `--audit` also exits 1 on `AUDIT dead reach glob in impact-blindspot.txt: <glob> (<suite>)`, a reach
  glob that matches no file (it would silently never select its suite). Continuation: install the missing
  tool, fix the ref or the manifest, then re-run; never read an empty selection as "nothing is impacted".
