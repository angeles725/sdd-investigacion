## slot:hotcore-cadence

read IN FULL once per context (session start, after a compaction, or in each fresh sub-agent) — not every iteration; this covers the framing and the per-block contract

## slot:hotcore-loop-cadence

(read IN FULL once per context)

## slot:loop-return-contract-explicit

Emit the per-iteration RETURN CONTRACT (including the tier used): every return MUST end with exactly one continuation token from the RETURN CONTRACT vocabulary — see PROMPT-LOOP RETURN CONTRACT section for the full grammar and every current form, including the campaign-continuation and campaign-stop forms — for example `next: <gap-id>` when the loop continues within the current focus. A return without one is a silently stopped iteration. Ending with "shall I continue?" or any equivalent question is a contract violation — the no-question rule from the triage section is a HARD rule inside the loop.
