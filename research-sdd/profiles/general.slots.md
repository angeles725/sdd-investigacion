## slot:hotcore-cadence

read IN FULL every iteration (framing + the per-block contract)

## slot:hotcore-reread-scope

Each iteration also re-reads RESEARCH-STATE, INDEX, and `--next` from the live backlog.

## slot:hotcore-loop-cadence

(read IN FULL every iteration)

## slot:loop-return-contract-explicit

Emit the per-iteration RETURN CONTRACT (see PROMPT-LOOP RETURN CONTRACT section for the full field
list): every non-STOP return must end with a continuation token — `next: <gap-id> · rescheduled via
<mechanism>` (for example `next: G12 · rescheduled via /loop(1200s)` or `next: G12 · self-scheduled in
60s`). A return without a token is a silently stopped iteration. Never replace the token with a
question such as "shall I continue?" — that is a contract violation, not politeness.

## slot:return-contract-shape

SHAPE RULE: write ONE short checkpoint — status, gap closed, block path, tally, continuation token —
then move straight to the next iteration. Do not turn the report into a recap of the whole run: a
report that summarizes everything done so far is the single most common cause of an unwanted stop,
because writing it fills the context and the run halts right after. Keep every checkpoint to the
fields below, nothing more, then continue.
