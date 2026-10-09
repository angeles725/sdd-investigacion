# json-envelope.v1 — opt-in `--json` envelope for high fan-in instruments (kit issue #1711, slices 1-4)

An instrument that implements this contract (read-only, except `retro-gate.sh`; see its section) accepts `--json` and then prints exactly ONE JSON
document on stdout instead of its human report. Without `--json` its output is unchanged (byte-identical;
the flag is opt-in). The envelope carries the CLAUDE.md §7 state enum, so a caller never has to guess
whether a zero count means "looked and found nothing" or "could not look".

## Shape

```json
{"schema":"research-sdd.<instrument>/v1","state":"ok","reason":null,"counts":{},"items":[]}
```

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | Constant per instrument: `research-sdd.<instrument>/v1`. A breaking change bumps the version. |
| `state` | string | One of the five values below. Never absent. |
| `reason` | string or null | `null` when `state` is `ok`; otherwise one sentence saying why. |
| `counts` | object | Integer counters; the keys are instrument-specific and documented per instrument below. May be `{}` when `state` is `degraded`. |
| `items` | array | The findings, one object per item, each with a `kind` string. Non-empty if and only if `state` is `ok`: a finding is never hidden behind another state. |

## State enum (CLAUDE.md §7)

| `state` | Meaning |
|---|---|
| `ok` | The instrument produced at least one item. This wins over every other state: a partial absence (some targets missing) beside real findings is `ok`, and is visible in `counts`, never in `reason` (which stays `null`). |
| `absent-input` | The inputs it reads were not found (every target directory missing). |
| `empty-input` | Inputs were found and are genuinely empty (nothing to examine). |
| `no-match` | Items were examined and none satisfied the filter (nothing to report). |
| `degraded` | The instrument could not run to completion (a runtime dependency such as `jq` is missing); the result is NOT a zero. |

## Process contract

Exit codes of `--json` mode (every one it can return):

| rc | Meaning | stdout |
|---|---|---|
| 0 | envelope printed, any state except `degraded` (a finding is advisory and never changes the exit code) | one envelope |
| 1 | operational failure: unreadable `TARGETS.md`, no usable target path, a helper failed to load, or the `jq` envelope build itself failed | nothing |
| 2 | usage error, for the instruments whose usage error already exits 2 (`verify-registry.sh`, `resume-state.sh`, `retro-gate.sh`; the exit code is per instrument, see below) | nothing |
| 3 | `degraded` (a runtime dependency is missing) | one envelope with `"state":"degraded"` |

- `degraded` exits 3, prints a `DEGRADED:` line on stderr, and still prints a valid envelope with
  `"state":"degraded"` so a machine caller sees the typed state instead of empty stdout.
- Operational failures keep the instrument's existing behaviour: a message on stderr, exit 1, nothing on stdout.
- The envelope is built with `jq`; the instrument probes for it before doing any work and hands it the data as files, never argv words, so a large backlog cannot hit the per-argument size limit (slices 1-3; `retro-gate.sh` is the exception: the block reason travels on jq's stdin and only short fields use `--arg`/`--argjson`).
- The probe covers the capability, not just presence: in slices 1-3 the data is passed with `jq --rawfile` (jq >= 1.6; `retro-gate.sh` probes `jq -n --argjson x 1 '$x'` instead, jq >= 1.5, reason `jq lacks --argjson (jq >= 1.5 required)`), so a jq that lacks it is `degraded` (exit 3, reason `jq lacks --rawfile (jq >= 1.6 required)`), never a late exit 1.
- Pending-retro rows travel from the sweep to the jq builder as named `name=value` fields, so the builder reads each field by name, not by position.

## Instruments

| Instrument | Status | Schema |
|---|---|---|
| `sweep-retros.sh` | implemented (slice 1, kit issue #1711) | `research-sdd.sweep-retros/v1` |
| `verify-registry.sh` | implemented (slice 2, kit issue #1711) | `research-sdd.verify-registry/v1` |
| `resume-state.sh` | implemented (slice 3, kit issue #1711) | `research-sdd.resume-state/v1` |
| `retro-gate.sh` | implemented (slice 4, kit issue #1711) | `research-sdd.retro-gate/v1` |

### `research-sdd.sweep-retros/v1`

State precedence: `ok` (at least one item, including a missing-retro item beside zero retros) →
`absent-input` (at least one usable target and every one of them missing on disk) →
`empty-input` (no retro file counted under the traversed targets) → `no-match` (retros counted, no item). `counts`: `targets`, `targets_absent`, `targets_skipped` (truncated paths in `TARGETS.md`),
`retros`, `pending`, `missing_retro`. A sweep with skipped targets is partial; `counts.targets_skipped`
says so, the state does not.

Items, oldest pending first, then missing-retro entries:

- `{"kind":"pending-retro","file","target","deltas","deltas_state","status","age_days","age_state","escalated","warning"}` —
  `deltas` is an integer when `deltas_state` is `counted`, else `null` (`uncountable`: count by hand;
  `no-section`: no delta section found; `unknown`: the instrument did not record a state). `deltas_state` is recorded by the sweep where the delta count is decided, never re-derived from the human report text;
  `age_days` is an integer when `age_state` is `counted`, else `null` with `age_state` `unknown` (one bad
  age never kills the envelope); `status` is the marker word or `none`; `warning` is a string or `null`.
- `{"kind":"missing-retro","target"}` — a target advanced with no retro for the latest run.

The envelope reports the review-status MARKER, not whether each delta is open work (same caveat as the
human report). The wiring pass of the human report is not part of this envelope.

### `research-sdd.verify-registry/v1`

State precedence: `absent-input` (every registered target directory is absent on disk) → `ok` (at least one
item) → `no-match` (targets reconciled, no item). `empty-input` is never emitted: a `TARGETS.md` with no usable
target path is an operational failure (rc 1), not an empty result. `counts` mirror the human `Summary:` line
one-to-one: `targets` (usable paths in `TARGETS.md`, absent ones included, truncated `...` ones excluded),
`targets_absent`, `targets_skipped` (truncated paths), `reconciled`, `count_drift`, `retro_drift`,
`unresolved` (the "unresolvable" figure), `oversized_rows`, `attention`.

Process differences from the default mode, all in `--json` only: an all-absent registry is an `absent-input`
envelope with rc 0 (the default mode exits 1 with a stderr message); a registry with no usable target path is
rc 1 with empty stdout (the default mode exits 0 with a stderr message), so a machine caller never reads it as
a clean pass. Stderr messages are unchanged in both modes. Any argument other than `--json` is a usage error in
both modes: rc 2, usage on stderr, nothing on stdout (no envelope).

Items, in discovery order. Every item is `{"kind","severity","target","message"}`: `severity` is `WARN` or
`INFO` exactly as in the human line, `target` is the name the human line cites (basename, or the full path for
`corpus-unresolvable` and `absent-target`, or the row name for `oversized-row`), `message` is the human line
without its `WARN  `/`INFO  ` prefix. There is one item per human `WARN`/`INFO` finding line, plus one
`absent-target` item per absent target (the human report lists at most three of them, in one aggregate line).

| `kind` | Finding |
|---|---|
| `nonconform-field` | a maturity-cell field not in the legend schema |
| `hook-unwired` | row claims `hook yes` but the Stop hook is not wired at the checked path |
| `hook-off-root` | row claims `hook yes`; wired, but the path is not its own git root |
| `hook-wired-contradiction` | row claims `hook no` but the Stop hook is wired |
| `hook-registered-never-loaded` | row claims `hook yes`; the Stop hook is registered but every registered retro-gate command names a script that does not exist, so it can never load |
| `hook-script-degraded` | row claims `hook yes`; the script-resolution check could not run (awk unavailable or failed), so loadability is unknown |
| `hook-registered-no-sessions` | row claims `hook yes`; the Stop hook is registered with a loadable script, but no Claude Code session was ever launched from exactly the target directory, so it has never been loaded |
| `hook-unregistered-stale` | row carries `hook file yes / unregistered` but the Stop hook IS registered with a loadable script |
| `hook-no-sessions-stale` | row carries `registered-no-sessions` but the hook is no longer registered with a loadable script, or sessions now exist |
| `nc-contradiction` | `nc` row but a `RESEARCH-STATE.md` exists |
| `nc-no-count` | `nc` row without a claimed `N md` count |
| `count-drift` | claimed `N md` differs from the on-disk count beyond the tolerance (corpus and `nc` rows) |
| `no-corpus-marker` | registered path has no corpus marker (`INDEX.md`/`CATALOG.md`/`RESEARCH-STATE*.md`) |
| `corpus-unresolvable` | no `RESEARCH-STATE*.md` under the target, blocks cannot be recounted |
| `catalog-stale-header` | `CATALOG.md` header total disagrees with its own rows |
| `catalog-disc-zero` | discriminator found 0 blocks while `CATALOG.md` claims some |
| `catalog-stale` | `CATALOG.md` total differs from the on-disk discriminator beyond the tolerance |
| `catalog-unparseable` | `CATALOG.md` present but no parseable total |
| `retros-unreadable` | `retros/` is not accessible, the retro count cannot be verified |
| `retro-drift` | claimed `N retros` differs from the non-excluded retro files found |
| `no-claimed-count` | row has no claimed `<N> md` count |
| `unclassifiable-blocks` | `block`/`bloque` files the canonical discriminator does not count |
| `no-retros-wired` | `INFO`: blocks on disk but no `retros/*.md` reachable (§18 feedback not wired) |
| `oversized-row` | a `TARGETS.md` master cell longer than `RSDD_ROW_MAXLEN` |
| `kit-not-registered` | the kit repo is not in its own `TARGETS.md` |
| `absent-target` | `INFO`: a registered target directory is absent on disk, not checked |

The envelope reports the findings of the default report, nothing wider: `ok` with `counts.targets_absent > 0`
is a partial reconcile, visible in `counts`, not in `reason`. The aggregate hint lines of the human report
(absent and skipped notes, the "refresh by hand" reminders) are carried by `counts` and are not items.

### `research-sdd.resume-state/v1`

`resume-state.sh` already prints a JSON document by default (see `resume-state.v1.md`). `--json` maps the same
facts into this envelope and does not duplicate them: the default document is unchanged and stays the
default. Both shapes carry the schema id `research-sdd.resume-state/v1`; they are told apart by the flag the
caller passed, and the envelope has `state`/`counts`/`items` where the default document has `worktrees`/`branches`/`prs`.

State precedence: `degraded` (git or jq missing, rc 3) → `ok`. The `repo` item is always present on a run
that completes, so `absent-input`, `empty-input` and `no-match` are never emitted: a repository whose lists are
empty is still a real answer, and an unreadable repository is an operational failure (rc 2, no stdout), not a state.

`counts`: `worktrees`, `worktrees_missing` (directory gone, `exists:false`), `worktrees_dirty` (tracked-file
changes > 0), `branches` (local branches not checked out in any worktree), `prs` (open PR items), `prs_unknown`
(`1` when the PR list is unknown: `--no-gh` or any non-`ok` `prs_status`; `0` when gh answered). `prs:0` beside
`prs_unknown:1` means "not looked at", never "no open PRs". A `degraded` envelope has `counts:{}`.

Process differences from the default mode, all in `--json` only: rc 3 (git or jq missing) prints a hand-built
`degraded` envelope on stdout beside the `DEGRADED:` stderr line (the default mode prints nothing on stdout); an
envelope build failure is rc 2 with empty stdout. Operational failures keep the instrument's existing code, **2**
(not the contract-wide 1): usage error, not a repository, unresolvable `--base-ref`, `git worktree list` or
`mktemp` failed — a message on stderr, nothing on stdout, in both modes.

Items, in this order (`repo`, then worktrees in `git worktree list` order, then branches, then PRs):

| `kind` | Fields |
|---|---|
| `repo` | `generated_at`, `toplevel`, `remote` (null when unset), `base_ref`, `base_sha`, `prs_status` (as in `resume-state.v1.md`), `prs_truncated` (bool or null when the list is unknown) |
| `worktree` | `path`, `branch` (null when detached), `head`, `exists`, `prunable`, `dirty` and `untracked` (int or null), `ahead`, `behind` |
| `branch` | `name`, `head`, `ahead`, `behind` (a local branch outside every worktree) |
| `pr` | `number`, `branch`, `state`, `url` (only when `prs_status` is `ok`) |

Every field keeps the meaning and null semantics documented in `resume-state.v1.md`.

### `research-sdd.retro-gate/v1`

`retro-gate.sh` is the §18 Stop-hook body: by default it prints the hook decision (`{"decision":"block",...}`) on a
block and nothing on an allow, and always exits 0. `retro-gate.sh --json <target>` (the flag may sit in any position)
prints this envelope INSTEAD of the decision; the gate itself is unchanged, so the block-once state file, the stop
log, the issue seeding and every stderr line behave exactly as without the flag. `--json` is a machine-reading
mode, not a hook registration: do not register it as the Stop hook (a hook wants the decision JSON and exit 0).

**`retro-gate.sh` is the one instrument of this contract that is NOT read-only**, because `--json` runs the real gate. Two hazards: (1) a `--json` call fed a live session's hook JSON writes that session's block-once state file, so it consumes the session's one block (the real Stop that follows is allowed with `block-once`); (2) when a conforming retro is found it can seed GitHub issues through `stage-retro-issues.sh --apply`. Callers that only want to look must not pass a live `session_id` and should expect those side effects otherwise.

State precedence: `degraded` (jq missing, rc 3) → `ok`. A completed run always carries one `verdict` item, so
`absent-input`, `empty-input` and `no-match` are never emitted (the resume-state precedent): an allow is a real
answer, and a missing target is an operational failure (rc 1, no stdout), not a state.

`counts`: `blocked` (`1` when the verdict is `block`, else `0`), `degraded_check` (`1` when the change set was
decided by the mtime fallback because the session-start sha was absent or unresolvable, else `0`), `unverified`
(`1` when the verdict was reached without a check the gate normally makes: `verify-retro.sh` absent so the
retro was not verified (`branch` `no-verifier`, an allow), the nested-worktree probe failed (any non-zero rc,
including rc 3, an incomplete traversal), or a directory-symlink scan was skipped, timed out or incomplete; else
`0`; each case also prints its typed stderr WARN, except rc 3, whose WARN comes from the lib). A directory link
that is deliberately skipped because it resolves to `/`, `$HOME` or an ancestor of the target is a safety skip,
not a failed check: it prints its WARN but does not set `unverified`. An allow with `unverified:1` is NOT a clean pass. A `degraded` envelope has `counts:{}`.

Process differences from the default mode, all in `--json` only: usage error (anything other than one `<target>`
beside the flag) is rc 2, target not found / a missing or incomplete helper lib / a failed envelope build is rc 1
(the default mode exits 0 on all of these, per the hook contract). A build failure on a `retro-conforming` allow exits 1 before the issue seeding runs; both print their stderr message and nothing on
stdout. rc 3 (jq missing, or a jq without `--argjson`, probed before the gate runs) prints the `DEGRADED:` line beside the unchanged `state=allow branch=degraded` line and a
hand-built `degraded` envelope on stdout (the default mode prints nothing on stdout). The envelope goes out before
the issue seeding runs, so a Stop timeout during seeding cannot swallow it. The reason travels on jq's stdin, never
argv.

Item (exactly one):

| `kind` | Fields |
|---|---|
| `verdict` | `verdict` (`allow` or `block`), `branch` (the stop-log branch: `loop-safety`, `block-once`, `no-change`, `retro-conforming`, `no-verifier`, `retro-pending`), `target` (basename), `session_id` (string or null when the hook JSON carried none), `check_mode` (`session-sha`, `mtime-fallback`, or null on `loop-safety`/`block-once`, which exit before the change set is evaluated), `newest_retro` (basename of the retro the verdict rests on, or null), `reason` (the block reason, equal to the default decision's `reason` after JSON decoding, except that bytes that are not valid UTF-8 become U+FFFD in the envelope; null on an allow) |
