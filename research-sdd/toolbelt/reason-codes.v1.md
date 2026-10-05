# Reason-code registry (v1)

Closed table of the typed "could not look / did not look" states the toolbelt emits, each with exactly
one continuation (the runnable next step). Kit issue #1704 (slice 1); evidence: the stop-code table in
`sdd-mental-model-bloque31.md` (each code has exactly one continuation) and candidate 5 of
`bloque33.md`.

Slice 1 is a REGISTRY plus a coverage test. No script's emit text was changed: a code is the
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
| `degraded: remote-visibility: timeout/gtimeout not found` | degraded | research-sdd-status.sh | neither timeout nor gtimeout exists, so the gh call cannot be bounded | install coreutils (timeout or gtimeout), then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: gh timed out for remote` | degraded | research-sdd-status.sh | the gh visibility call exceeded its bound | check network access, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: gh failed (rc=<v>) for remote` | degraded | research-sdd-status.sh | gh exited non-zero for the remote | run `gh auth status`, fix the reported problem, then re-run `research-sdd-status.sh` |
| `degraded: remote-visibility: unrecognised gh answer [<v>] for remote` | degraded | research-sdd-status.sh | gh answered with a value that is not a known visibility | run `gh repo view <owner>/<repo> --json visibility` by hand and report the value as a kit issue |
| `degraded: missing runtime dependency:` | degraded | reconcile-issues.sh | a required tool (for example jq) is absent | install the named dependency, then re-run `reconcile-issues.sh` |
| `degraded: missing runtime dependencies:` | degraded | stage-retro-issues.sh | one or more required tools are absent | install the listed dependencies, then re-run `stage-retro-issues.sh --apply` |
| `degraded: gh not found on PATH` | degraded | reconcile-issues.sh, stage-retro-issues.sh | the gh CLI is not installed | install the gh CLI, then re-run the script |
| `degraded: git not found on PATH` | degraded | reconcile-issues.sh | git is absent, so a cited commit cannot be checked against the main ref | install git, then re-run `reconcile-issues.sh` |
| `degraded: <v> is not a git repository` | degraded | reconcile-issues.sh | the directory used for the ancestry check is not a git repository | run from a kit checkout or set `RECONCILE_ISSUES_GIT_DIR` to one, then re-run `reconcile-issues.sh` |
| `degraded: ref <v> is not known locally in <v> (no fetch is performed)` | degraded | reconcile-issues.sh | the main ref is not known locally and the script never fetches | run `git fetch` by hand (or set `RECONCILE_ISSUES_MAIN_REF`), then re-run `reconcile-issues.sh` |
| `degraded: commit <v> not present locally (shallow or partial clone?)` | degraded | reconcile-issues.sh | the repository is a shallow clone and none of the commits cited in a closed issue resolves locally, so ancestry cannot be checked (the row stays borderline) | run `git fetch` (or `git fetch --unshallow`) by hand, then re-run `reconcile-issues.sh` |
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

Typed states of the data an instrument looked at (CLAUDE.md section 7). They are stable tokens used by
many toolbelt scripts; slice 1 registers the names and continuations but does not scan emitters.

| code | class | emitters | meaning | continuation |
|---|---|---|---|---|
| `absent-input` | input | many toolbelt scripts (not enumerated in slice 1) | the file or directory was not found or not traversable | fix the path or restore the input, then re-run; do not read the result as zero |
| `empty-input` | input | many toolbelt scripts (not enumerated in slice 1) | the input exists and is genuinely empty | confirm the emptiness is real; nothing to repair |
| `unclassifiable` | input | many toolbelt scripts (not enumerated in slice 1) | items exist but the instrument could not classify them | inspect the listed items by hand and extend the instrument's recognised forms if they are legitimate |

## Deferred (later slices of #1704)

- `degraded: migrate-backlogs: <reason>` (its script is not scanned yet).
- Scanning the input-class emitters, and a numeric exit-code mapping.
- Emit-text changes: a script must not be edited to fit this table in slice 1.
