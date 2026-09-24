## slot:hotcore-cadence

read IN FULL every iteration (framing + the per-block contract)

## slot:hotcore-reread-scope

Each iteration also re-reads RESEARCH-STATE, INDEX, and `--next` from the live backlog.

## slot:hotcore-loop-cadence

(read IN FULL every iteration)

## slot:loop-return-contract-explicit

Emit the per-iteration RETURN CONTRACT (including the tier used): every non-STOP return MUST end with
a continuation token from the RETURN CONTRACT vocabulary — see PROMPT-LOOP RETURN CONTRACT section for
every current form, including the campaign-continuation and campaign-stop forms — for example
`next: <gap-id> · rescheduled via <mechanism>` (`next: G12 · rescheduled via /loop(1200s)` or
`next: G12 · self-scheduled in 60s`). A return without one is a silently stopped iteration. Ending with
"shall I continue?" or any equivalent question is a contract violation — the no-question rule from the
triage section is a HARD rule inside the loop.
