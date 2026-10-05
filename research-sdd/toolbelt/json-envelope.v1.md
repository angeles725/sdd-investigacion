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
| `items` | array | The findings, one object per item, each with a `kind` string. `[]` unless `state` is `ok`. |

## State enum (CLAUDE.md §7)

| `state` | Meaning |
|---|---|
| `ok` | The instrument looked and has at least one item. |
| `absent-input` | The inputs it reads were not found (every target directory missing). |
| `empty-input` | Inputs were found and are genuinely empty (nothing to examine). |
| `no-match` | Items were examined and none satisfied the filter (nothing to report). |
| `degraded` | The instrument could not run to completion (a runtime dependency such as `jq` is missing); the result is NOT a zero. |

## Process contract

- Exit 0 for every state except `degraded`; a finding is advisory and never changes the exit code.
- `degraded` exits 3, prints a `DEGRADED:` line on stderr, and still prints a valid envelope with
  `"state":"degraded"` so a machine caller sees the typed state instead of empty stdout.
- Operational failures (unreadable `TARGETS.md`, a helper failing to define its function) keep the
  instrument's existing behaviour: a message on stderr, exit 1, nothing on stdout.
- The envelope is built with `jq`; the instrument probes for it before doing any work.

## Instruments

| Instrument | Status | Schema |
|---|---|---|
| `sweep-retros.sh` | implemented (slice 1, kit issue #1711) | `research-sdd.sweep-retros/v1` |
| `verify-registry.sh` | not yet | — |
| `resume-state.sh` | not yet | — |
| `retro-gate.sh` | not yet | — |

### `research-sdd.sweep-retros/v1`

State precedence: `absent-input` (at least one usable target and every one of them missing on disk) →
`empty-input` (no retro file counted under the traversed targets) → `no-match` (retros counted, no item) →
`ok`. `counts`: `targets`, `targets_absent`, `targets_skipped` (truncated paths in `TARGETS.md`),
`retros`, `pending`, `missing_retro`. A sweep with skipped targets is partial; `counts.targets_skipped`
says so, the state does not.

Items, oldest pending first, then missing-retro entries:

- `{"kind":"pending-retro","file","target","deltas","deltas_state","status","age_days","escalated","warning"}` —
  `deltas` is an integer when `deltas_state` is `counted`, else `null` (`uncountable`: count by hand;
  `no-section`: no delta section found); `status` is the marker word or `none`; `warning` is a string or `null`.
- `{"kind":"missing-retro","target"}` — a target advanced with no retro for the latest run.

The envelope reports the review-status MARKER, not whether each delta is open work (same caveat as the
human report). The wiring pass of the human report is not part of this envelope.
