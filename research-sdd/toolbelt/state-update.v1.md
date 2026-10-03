# State-counter updater `state-update.v1`

`state-update.sh <target-dir>` — propose-never-apply updater for the `research-state.v1` envelope
(kit issue #1284). It prints a unified diff against each `RESEARCH-STATE*.md` and **never writes** to
the target; the human (or a reviewed `patch -p1`) applies it.

## Contract

| Item | Value |
|---|---|
| Engine | `verify-state.sh` itself, run once over the target. The recomputed value is read from its FAIL/WARN line; nothing is re-derived here. |
| Output | Unified diff on stdout (`a/<rel>` / `b/<rel>`, relative to the target); progress, `SKIP`, `NOTE` and the summary on stderr. |
| Summary | `state-update: checked= skipped= changed= degraded= unproposed=` — emitted on every exit path (usage, absent, DEGRADED, normal) by an EXIT trap, so it is always the last stderr line. A failing state-file listing helper or an untraversable target is DEGRADED (exit 3), never "no state files". |
| Exit 0 | No change proposed. **Not** "verify-state passes": see `unproposed`. |
| Exit 1 | A change is proposed. |
| Exit 2 | Usage, or no `RESEARCH-STATE*.md` under the target. |
| Exit 3 | DEGRADED: verify-state could not be run / exited ≥ 2, printed no section for a state file, two state files share a basename, or **every** state file was skipped (nothing examined). Takes precedence over 1; any diff already found is still printed. |
| Env | `STATE_UPDATE_VERIFY` overrides the verify-state path (test hook). |

## Owned fields

Only fields `verify-state.sh` recomputes **from disk** are proposed, each from one message form:

| Field | verify-state check | Message form parsed |
|---|---|---|
| `covered_blocks` | A | `envelope covered_blocks=X != N block file(s) on disk` · `... != N attributed block(s) under shared-global` |
| `investigable_open` | B | `envelope investigable_open=X != N NEXT-eligible pending gap(s)` |
| `blocked_open` | C | `envelope blocked_open=X != N blocked entr(y/ies)` |
| `requires_execution_open` | E | `envelope requires_execution_open=X != N marked-open ...` (WARN) · `requires_execution_open=0 ... while N open requires-execution ...` (FAIL) |
| `deferred_open` | F | `envelope deferred_open=X != N deferred backlog gap(s)` · `deferred_open missing while N deferred ...` (appended inside the fence) |
| Stop-control prose number | SC-CROSS-CHECK | `stop-control prose '...: X' but backlog derives N investigable gap(s)`; only the digits after `investigable**:` change |

## Never touched

- Hand-set envelope lines (`schema`, `block_scope`, `method`, `undocumented_findings`, `blocks_since_retro`,
  `known_stale_warns`, any unknown key) keep their text and position.
- `known_gaps` and `gaps_closed`: verify-state only checks their declared identity (CHECK D/H), they are not
  recomputable from disk, and a backlog table undercounts closed gaps tracked in prose (a table-derived value
  moved one real focus 65 → 35).
- All other prose, including the coverage metric and the `Covered blocks:` mirror line (CHECK 2/3 are WARN-only
  and carry no single recomputed value).

## Withheld on purpose (the lint is not the truth)

- **Un-suffixed root of a multi-state corpus with no `FOCUSES.md` block prefix** (kit #906): verify-state counts
  the corpus-wide block total against it; writing that would satisfy the lint with a number that is not the
  focus's. `covered_blocks` is withheld and a `NOTE` names it.
- **Shared-global focus with no attributed `B<n>` ids**: verify-state reports INFO "unverifiable", emits no
  mismatch line, so nothing is proposed.
- **Envelope-less state file**: `SKIP` — seeding an envelope is `research-sdd-status.sh --sync-state`'s job.
- **Stale stop-control number with no rewritable line**: counted in `unproposed=` with a `NOTE`, never dropped.
- **verify-state FAIL lines of any other shape** (unparseable backlog, absent backlog section, ...) are counted
  in `unproposed=` with a per-file `NOTE`; nothing is invented for them.

## Why not `--sync-state` as the engine

Evaluated and rejected. `research-sdd-status.sh --sync-state` re-renders the whole fence (it moves every
non-owned line below the counters), re-derives `known_gaps`/`gaps_closed` from the backlog table, and seeds
`covered_blocks=0` for a shared-global focus — three proposals verify-state would not make. Parsing
verify-state's own message lines keeps the proposal identical to the lint by construction, at the price of a
contract on those messages; the suite pins every parsed form.

## Anti-silent-zero

`absent` (no state file → exit 2; verify-state printed no section → exit 3), `empty/no-match` (checked,
nothing drifted → exit 0 with `checked=N changed=0`) and `unverified` (`unproposed=N`, `skipped=N`) are
distinct signals. A run where no state file could be examined is never exit 0.
