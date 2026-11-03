### reconcile-issues (#2607, #2608)

Intended divergences of `rsdd retro reconcile` (the Go port behind `reconcile-issues.sh`) from the frozen legacy script. None is reachable by a recorded golden, because the script cannot produce them; each is pinned by a `goonly/*` case of `internal/retro/reconcile/cases_goonly_test.go` that asserts the exit code, stdout, stderr and the gh calls.

| Divergence | Legacy script | Port |
|---|---|---|
| `degraded: git could not be run in <dir> (<err>)` | A `git` on PATH that is not a program was run as a shell script and read as "not a git repository". | Any git failure that is neither "not found" nor a non-zero exit (cannot start, timeout, output cap) is "could not look", not "not a repository". Exit 1, rows borderline. |
| `degraded: git could not resolve ref <ref> in <dir> (<err>)` | One probe, no separate state. | The ref lookup that cannot run after `rev-parse --git-dir` succeeded is its own line, never "the ref is not known locally". Exit 1, rows borderline. |
| `degraded: cannot resolve a registered target name for <retro> (target_name_for_retro rc=<n>)` under `--all` | `find` does not follow a symlinked `retros/` directory, so its retros were never listed: `empty-input: no retro files found across all targets`, exit 0. | The listing follows the link (`[ -d ]` does), the retro's physical directory is outside every registered target, and the retro counts as degraded: `degraded=1`, exit 1. A silent zero became a loud failure. |
| `degraded: the review-status marker of <retro> lists a shipped: range too large to expand (<err>)` | A `shipped:` range such as `R1-R100002` ran a `for` loop over every id. | A range of 100000 or more ids is refused (`core/retrogrammar` `maxRangeIDs`). Exit 1. |
| `RSDD_GH_TIMEOUT` | gh ran without a bound. | Each gh call is bounded (default 120 s, `RSDD_GH_TIMEOUT` seconds); a call that outlives it reads as exit 124 and renders as `degraded: gh issue list failed for <retro> (exit 124)`. Exit 1. |

Test-side guards (not behaviour): the reconcile tests run the repository tool through a logging wrapper first on the box PATH and fail when the port runs any verb outside `rev-parse`, `cat-file` and `merge-base` (never fetch, pull, push, ls-remote or remote; the legacy suite's case 45i), and the stub gh rejects an unknown flag, an unknown `--json` field, `--limit 0` and a stray argument (legacy case 41e).
