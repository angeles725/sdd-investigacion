# json-envelope.v1 — opt-in `--json` envelope for high fan-in instruments (kit issue #1711, slice 1)

A read-only instrument that implements this contract accepts `--json` and then prints exactly ONE JSON
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
| 3 | `degraded` (a runtime dependency is missing) | one envelope with `"state":"degraded"` |

- `degraded` exits 3, prints a `DEGRADED:` line on stderr, and still prints a valid envelope with
  `"state":"degraded"` so a machine caller sees the typed state instead of empty stdout.
- Operational failures keep the instrument's existing behaviour: a message on stderr, exit 1, nothing on stdout.
- The envelope is built with `jq`; the instrument probes for it before doing any work and hands it the data as files, never argv words, so a large backlog cannot hit the per-argument size limit.
- The probe covers the capability, not just presence: the data is passed with `jq --rawfile` (jq >= 1.6), so a jq that lacks it is `degraded` (exit 3, reason `jq lacks --rawfile (jq >= 1.6 required)`), never a late exit 1.
- Pending-retro rows travel from the sweep to the jq builder as named `name=value` fields, so the builder reads each field by name, not by position.

## Instruments

| Instrument | Status | Schema |
|---|---|---|
| `sweep-retros.sh` | implemented (slice 1, kit issue #1711) | `research-sdd.sweep-retros/v1` |
| `verify-registry.sh` | not yet | — |
| `resume-state.sh` | not yet | — |
| `retro-gate.sh` | not yet | — |

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
