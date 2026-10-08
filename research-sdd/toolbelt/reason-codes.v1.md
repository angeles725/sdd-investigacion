# Reason-code registry (v1)

Closed table of the typed "could not look / did not look" states the toolbelt emits, each with exactly
one continuation (the runnable next step). Kit issue #1704 (slices 1 and 2); evidence: the stop-code table in
`sdd-mental-model-bloque31.md` (each code has exactly one continuation) and candidate 5 of
`bloque33.md`.

Slice 1 is a REGISTRY plus a coverage test; slice 2 extends the coverage test to the input class. No script's emit text was changed: a code is the
normalised prefix of an emit line that already exists today. Wording changes in a script, or a new
`degraded:` emit line, make `tests/reason-codes.test.sh` fail until this table is updated — that is the
test working, not a flake.

## How a code is derived (the extraction rule)

`tests/reason-codes.test.sh` applies this rule to every non-comment `echo` / `printf` line of the
scanned scripts that contains the literal `degraded: `:

1. Start at the first `degraded: ` on the line.
2. Replace each shell expansion and each `%s` / `%d` conversion with `<v>`, then collapse runs of `<v>`.
   The expansions rewritten are exactly: `${...}`, `$(...)` (no nested parentheses), `$name`, and the
   single-character parameters `$0`-`$9`, `$?`, `$@`, `$#`, `$*`, `$!`, `$$`. The `$(...)` pattern is
   `\$\([^)]*\)`, so it stops at the FIRST `)`: a nested `$(... $(...) ...)` or an arithmetic `$((...))`
   is only partially rewritten (the `$(` up to the first `)` becomes `<v>`; the remainder, including the
   trailing `)`, stays in the code text) and will fail as an unlisted code until the emit line is simplified.
3. Cut at the first ` — ` (em dash, the prose separator), literal `\n`, or closing `"`.
4. Strip trailing whitespace and trailing `<v>`.

What remains is the code, matched byte-for-byte against the first column below. The rule detects new or
re-worded prefixes; it cannot see a change in prose after the cut point.

The test checks both directions: every emitted code must be a registry row, and every emitter a degraded
row lists must really emit that code (a stale emitter fails). A non-comment line carrying `degraded: ` that
contains no `echo` / `printf` token (a continuation line of a multi-line emit, a heredoc body, an
assignment) is reported as unclassifiable and fails the test: the extractor cannot read it, so a clean
result would be a silent zero. The scan keys only on the literal `degraded: ` and on the `echo` / `printf`
token: a line that has both is read as an emit line even if it is part of a continued command, and a helper
that adds the prefix itself (its call sites carry no literal) is NOT reported, because no scanned line
contains the literal. Only a line that starts with a comment is excluded; a ` #` before the token (trailing
comment, or inside a quoted string) is still reported. The scan is line-based; a `degraded: ` hidden in a
string built across lines without that literal is invisible. Scanned scripts today:
`research-sdd-status.sh`, `reconcile-issues.sh`, `stage-retro-issues.sh`, `research-sdd-init.sh`.

## Columns

| column | meaning |
|---|---|
| code | the derived prefix (degraded class) or the typed input token (input class) |
| class | `degraded` = the environment was incomplete, the measurement is invalid; `input` = a typed state of the data looked at |
| emitters | comma-separated script basenames that emit it (checked against the scanned scripts for the degraded class) |
| meaning | what the instrument could not do |
| continuation | the one runnable next step; never empty |

## Degraded class

| code | class | emitters | meaning | continuation |
|---|---|---|---|---|
| `degraded: remote-visibility: git not found` | degraded | research-sdd-status.sh | git is not on PATH, so the target's remotes cannot be read | install git, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: gh not found` | degraded | research-sdd-status.sh | gh is not on PATH, remote visibility cannot be verified | install the gh CLI, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: <v> url empty or unreadable` | degraded | research-sdd-status.sh | a remote has no readable URL | run `git remote -v` in the target and fix the remote URL |
| `degraded: remote-visibility: <v> not a github owner/repo` | degraded | research-sdd-status.sh | the remote is not a GitHub owner/repo, so gh cannot classify it | verify the host's visibility by hand; no tool step exists |
| `degraded: remote-visibility: gh probe could not run (<v>) for remote` | degraded | research-sdd-status.sh | the shared bounded gh probe could not run (no temp file, or gh vanished between the check and the call) | free disk / TMPDIR space, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: lib/gh-visibility.sh unavailable` | degraded | research-sdd-status.sh | the shared probe library next to the script is missing or broken, so no remote can be probed | re-install or update the kit so `lib/gh-visibility.sh` sits beside `research-sdd-status.sh`, then re-run |
| `degraded: remote-visibility: gh timed out for remote` | degraded | research-sdd-status.sh | the gh visibility call exceeded its bound | check network access, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: skipped after timeout for remote` | degraded | research-sdd-status.sh | an earlier remote's gh call timed out, so this remote was not probed (the block's total latency stays at one bound) | check network access, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: gh failed (rc=<v>) for remote` | degraded | research-sdd-status.sh | gh exited non-zero for the remote | run `gh auth status`, fix the reported problem, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: unrecognised gh answer [<v>] for remote` | degraded | research-sdd-status.sh | gh answered with a value that is not a known visibility | run `gh repo view <owner>/<repo> --json visibility` by hand and report the value as a kit issue |
| `degraded: missing runtime dependency:` | degraded | reconcile-issues.sh | a required tool (for example jq) is absent | install the named dependency, then re-run `reconcile-issues.sh` |
| `degraded: missing runtime dependencies:` | degraded | stage-retro-issues.sh | one or more required tools are absent | install the listed dependencies, then re-run `stage-retro-issues.sh --apply` |
| `degraded: gh not found on PATH` | degraded | reconcile-issues.sh, stage-retro-issues.sh | the gh CLI is not installed | install the gh CLI, then re-run the script |
| `degraded: git not found on PATH` | degraded | reconcile-issues.sh | git is absent, so a cited commit cannot be checked against the main ref | install git, then re-run `reconcile-issues.sh` |
| `degraded: <v> is not a git repository` | degraded | reconcile-issues.sh | the directory used for the ancestry check is not a git repository | run from a kit checkout or set `RECONCILE_ISSUES_GIT_DIR` to one, then re-run `reconcile-issues.sh` |
| `degraded: ref <v> is not known locally in <v> (no fetch is performed)` | degraded | reconcile-issues.sh | the main ref is not known locally and the script never fetches | run `git fetch` by hand (or set `RECONCILE_ISSUES_MAIN_REF`), then re-run `reconcile-issues.sh` |
| `degraded: retros directory not listable:` | degraded | reconcile-issues.sh | the retros directory could not be listed (find failed or reported an error), so later retros were not enumerated and the `regressed` check has no verdict | fix the directory permissions, then re-run `reconcile-issues.sh` |
| `degraded: later retro not readable:` | degraded | reconcile-issues.sh | a later retro in the same retros directory exists but cannot be read, so re-proposals of shipped rows in it (the `regressed` class) were not checked | fix the file permissions, then re-run `reconcile-issues.sh` |
| `degraded: gh issue list (closed, old-gh fallback) failed (exit <v>)` | degraded | reconcile-issues.sh | this gh has no `stateReason` --json field and the fallback closed-issue listing (number, body, comments) also failed, so the audit has no verdict | run `gh auth status` and the same `gh issue list` by hand, then re-run `reconcile-issues.sh` |
| `degraded: gh api state_reason listing failed (this gh has no stateReason --json field)` | degraded | reconcile-issues.sh | this gh has no `stateReason` --json field, so the state reasons are read from one paginated `gh api repos/<owner>/<repo>/issues?state=closed` listing and that call failed twice (one bounded retry after a wait that honours a Retry-After / X-RateLimit-Reset hint, else `RECONCILE_ISSUES_RETRY_BACKOFF`, capped by `RECONCILE_ISSUES_RETRY_MAX_WAIT`); when the retro filename starts with a YYYY-MM-DD date D the listing URL carries `&since=<D minus 2 days>T00:00:00Z` (a 2-day margin: updated_at is UTC while D is the author's local date), so re-run the call by hand with that same `since=`; an undated retro, or a host with no usable `date` arithmetic (then a `note: date arithmetic unavailable` line is printed), lists all closed issues with no `since=` | run that `gh api` call by hand, fix the reported problem (auth, rate limit, network), then re-run `reconcile-issues.sh` |
| `degraded: gh is not authenticated` | degraded | reconcile-issues.sh, stage-retro-issues.sh | gh has no usable login | run `gh auth login`, then re-run the script |
| `degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '<v>')` | degraded | reconcile-issues.sh | the list-limit override is not a positive integer | set `RECONCILE_ISSUES_LIST_LIMIT` to a positive integer or unset it |
| `degraded: STAGE_RETRO_ISSUES_LIST_LIMIT must be a positive integer (got '<v>')` | degraded | stage-retro-issues.sh | the list-limit override is not a positive integer | set `STAGE_RETRO_ISSUES_LIST_LIMIT` to a positive integer or unset it |
| `degraded: --closed-cache file not readable:` | degraded | reconcile-issues.sh | the closed-issues cache file named by `--closed-cache` is unreadable | pass a readable file to `--closed-cache`, or drop the flag to query gh live |
| `degraded: --issues-cache file not readable:` | degraded | reconcile-issues.sh | the issues cache file named by `--issues-cache` is unreadable | pass a readable file to `--issues-cache`, or drop the flag to query gh live |
| `degraded: gh issue list (closed) failed for <v> (exit <v>)` | degraded | reconcile-issues.sh | the closed-issue listing failed, so the audit has no verdict | run `gh auth status` and the same `gh issue list` by hand, then re-run `reconcile-issues.sh` |
| `degraded: gh issue list (closed) returned <v> results = the --limit <v> cap for` | degraded | reconcile-issues.sh | the closed listing hit the cap and may be truncated | raise `RECONCILE_ISSUES_LIST_LIMIT`, then re-run `reconcile-issues.sh` |
| `degraded: gh issue list failed for <v> (exit <v>)` | degraded | reconcile-issues.sh | the open-issue listing failed for a retro | run `gh auth status` and the same `gh issue list` by hand, then re-run `reconcile-issues.sh` |
| `degraded: gh issue list returned <v> results = the --limit <v> cap for` | degraded | reconcile-issues.sh | the open listing hit the cap and may be truncated | raise `RECONCILE_ISSUES_LIST_LIMIT`, then re-run `reconcile-issues.sh` |
| `degraded: retro not readable:` | degraded | reconcile-issues.sh, stage-retro-issues.sh | the retro file cannot be read, so there is no audit or staging | fix the retro path or its permissions, then re-run the script |
| `degraded: cannot resolve a registered target name for <v> (target_name_for_retro rc=<v>)` | degraded | reconcile-issues.sh | the retro maps to no registered TARGETS.md row | register the target in `TARGETS.md` by hand (the kit never edits it), then re-run `reconcile-issues.sh` |
| `degraded: cannot resolve kit issue repo (<v>)` | degraded | stage-retro-issues.sh | the kit issue repo is unknown, so no issue may be created | set `RESEARCH_SDD_ISSUE_REPO=<owner>/<name>` or configure an `origin` remote on the kit, then re-run `stage-retro-issues.sh --apply` |
| `degraded: could not probe label '<v>' on <v> (gh label list exit <v>):` | degraded | stage-retro-issues.sh | the label probe failed; no issue was created | run `gh label list` on the kit repo by hand, then re-run `stage-retro-issues.sh --apply` |
| `degraded: gh label list returned an unexpected reply for '<v>' on <v> (expected a JSON array):` | degraded | stage-retro-issues.sh | the label probe answered something other than a JSON array; no issue was created | run `gh label list --json name` on the kit repo by hand, then re-run `stage-retro-issues.sh --apply` |
| `degraded: target '<v>' is unregistered in <v> (basename fallback)` | degraded | stage-retro-issues.sh | the target is not registered, so no label or issue is created | register the target in `TARGETS.md` by hand, then re-run `stage-retro-issues.sh --apply` |
| `degraded: label '<v>' is missing on <v> and could not be created:` | degraded | stage-retro-issues.sh | the label is absent and creating it failed; no issue was created | create the label by hand with `gh label create`, then re-run `stage-retro-issues.sh --apply` |
| `degraded: iconv is missing or unusable` | degraded | stage-retro-issues.sh | iconv is unavailable, so title length is counted without validating the encoding | install iconv (glibc or libiconv) and re-run; a non-UTF-8 title may otherwise be over-refused |
| `degraded: jq not found on PATH` | degraded | research-sdd-init.sh | jq is absent, so settings.json cannot be wired | install jq, then re-run `research-sdd-init.sh --wire` |
| `degraded: jq failed on` | degraded | research-sdd-init.sh | jq failed on the settings file; success is not reported | fix the settings.json syntax, then re-run `research-sdd-init.sh --wire` |

## Input class

Typed states of the data an instrument looked at (CLAUDE.md section 7). Slice 2 scans their emitters:
`tests/reason-codes.test.sh` classifies every occurrence of the four tokens in the toolbelt shell scripts and
checks the `emitters` column in both directions (see "How an input code is found" below).

| code | class | emitters | meaning | continuation |
|---|---|---|---|---|
| `absent-input` | input | coverage-map.sh, focus-partition-audit.sh, migrate-backlogs.sh, reconcile-issues.sh, retro-gate.sh, stage-retro-issues.sh, sweep-audits.sh, sweep-breakthroughs.sh, sweep-retros.sh, sweep-tools.sh, verify-cd-physical.sh, verify-registry.sh, verify-retro.sh, verify-tool-catalog.sh | the file or directory was not found or not traversable | fix the path or restore the input, then re-run; do not read the result as zero |
| `empty-input` | input | coverage-map.sh, focus-partition-audit.sh, migrate-backlogs.sh, reconcile-issues.sh, score-loop-transcript.sh, stage-retro-issues.sh, sweep-audits-hook.sh, sweep-audits.sh, sweep-breakthroughs-hook.sh, sweep-breakthroughs.sh, sweep-retros.sh, sweep-tools.sh, verify-cd-physical.sh, verify-tool-catalog.sh | the input exists and is genuinely empty | confirm the emptiness is real; nothing to repair |
| `unclassifiable` | input | focus-partition-audit.sh, reconcile-issues.sh, retro-gate.sh, stage-retro-issues.sh, verify-cd-physical.sh, verify-registry.sh | items exist but the instrument could not classify them | inspect the listed items by hand and extend the instrument's recognised forms if they are legitimate |
| `no-match` | input | coverage-map.sh, focus-partition-audit.sh, reconcile-issues.sh, stage-retro-issues.sh, sweep-breakthroughs-hook.sh, sweep-breakthroughs.sh, sweep-retros.sh, verify-cd-physical.sh, verify-registry.sh, verify-tool-catalog.sh | items exist and the instrument looked, but none satisfied the filter | confirm the filter is the intended one; widen it if a hit was expected, otherwise nothing to repair |

## How an input code is found (the scan and its declared coverage)

Per CLAUDE.md section 7, an audit instrument must prove the coverage of its own enumerator, so this section
declares what the scan recognises, what it excludes and what it cannot see. The vocabulary is closed to four
tokens: `absent-input`, `empty-input`, `unclassifiable`, `no-match`. An input-class row outside that list fails
as "not scannable"; a new token needs the scanner and this table updated together.

Traversed: every `*.sh` directly under `research-sdd/toolbelt/` and under `research-sdd/toolbelt/lib/`. An
absent directory, zero shell files, or zero token occurrences is a typed DEGRADED (exit 2), never a clean pass.
The test prints one `INFO  input-class coverage:` line with the file count and the per-class tallies of the run.

An occurrence is a word-bounded token on a non-comment line. A hyphen or alphanumeric neighbour makes it a
different word, so `unclassifiable-items`, `unclassifiable-row` and `unclassifiable-blocks` are NOT occurrences.
The `\t` and `\n` escapes are blanked first, so `%d\tunclassifiable` is seen. Each occurrence gets exactly one
class, first match wins:

| class | recognised form | counts as an emitter |
|---|---|---|
| counter | `token=`, `$token`, `${token`, or inside `$(( ... ))` | no: a variable, not a state |
| comment | after a trailing ` #` outside double quotes | no |
| emit-jq | a jq state literal, `then "token"` or `else "token"` | yes |
| consumer | the line is a matcher: `grep`, `case`, a leading `*` or `/` pattern, `= "token"` or `== "token"` | no |
| emit-echo | the line is an `echo` / `printf` | yes |
| emit-marker | a parenthesised marker `(token` inside a string on any other line (an emit helper call, an assignment) | yes |
| UNCLASSIFIED | none of the above | the test FAILS and names `file:line`; resolve by adding a recognised form or a waiver |

A waiver (`file|substring|reason`, in `IC_WAIVERS` in the test) marks a prose mention that only looks like an
emission (for example the "empty-input digests" check, which is about hashes of empty input). A waiver that
matches no occurrence fails as stale, so the list cannot become a blanket ignore.

Not seen, by design: python (`*.py`; the test counts the files that mention a token and reports them as out of
scope), a state printed by a helper whose call sites carry no marker or token, a token assembled across lines
or from variables, and `*.sh` outside the two traversed directories. The test fails when a registry input row
lists a script that does not emit the code (stale emitter), when a script emits a code its row does not list
(emitter mismatch), when an emitted token has no row, and when a row's code is never emitted (stale row).

## Run-level notes that are not degraded codes

These prefixes are NOT `degraded:` lines, so the extraction rule never sees them and they do not fail a run.
They are listed here so a reader of this registry finds every typed state the script can print.

- `shallow-clone: <dir> is a shallow clone and no cited commit resolved locally for N row(s) (e.g. <sha>)`
  (reconcile-issues.sh, kit issue #1773): printed once per run (single-retro and `--all`) when the closure
  evidence of N rows cites no commit that exists locally and the checkout is shallow, so reachability
  cannot be verified. Those rows stay `borderline`, never `shipped`, and the exit code is unchanged.
  Continuation: run `git fetch --unshallow` (or raise the CI fetch-depth), then re-run `reconcile-issues.sh`.

- `note: state_reason for issue #<n> missing from the closed-issue listing after one reload` (reconcile-issues.sh,
  kit issue #1752): on a gh without the `stateReason` field, a closed issue found by the search is absent from
  the batched `state_reason` listing even after one forced reload of it. Its rows are reported `borderline`
  (the issue's evidence is not trusted) and the run is not failed. Continuation: run
  `gh api repos/<owner>/<repo>/issues/<n> --jq .state_reason` by hand, then re-run `reconcile-issues.sh`.

- `regressed-lookup: <reason>` (reconcile-issues.sh, kit issue #1709 slice 2): the `regressed` check for a `shipped`
  row could not look at something and says so on stderr instead of reporting a silent no-match: the shipped retro or
  a sibling has no `YYYY-MM-DD` filename prefix, or a sibling has the same date (retros cannot be ordered), the row title is under 12 characters or a
  bare priority/type token (no cross-retro identity), or a later retro's review-status marker sits outside the
  leading-block scope (open/closed cannot be told). The run is not failed. Continuation: rename the retro with a date
  prefix, give the row a real title, or move the marker into the leading block, then re-run `reconcile-issues.sh`.

## Deferred (later slices of #1704)

- `degraded: migrate-backlogs: <reason>` (its script is not scanned yet).
- A numeric exit-code mapping.
- Emit-text changes: a script must not be edited to fit this table.
- Dropped by decision (maintainer, 2026-10-07): "every refusal line prints its exit command". It is not
  deferred and will not be built.
