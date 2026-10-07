<!-- review-status: pending -->
# Retro — make retros automatic

## A. THE DEFECT

Prose.

### Proposals (propose-never-apply) — make it automatic, cheapest first

1. **Retro-debt counter in the loop state.** Track blocks_since_retro in the state file and return a typed
   RETRO-DUE state once the threshold is reached.
2. **Incremental retro-debt sink.** Each block appends one line to a running debt file at close.
3. **Cadence hook.** The self-paced reschedule step inserts a retro iteration when due.

**Doctrine one-liner for METHODOLOGY §18:** a retro is not only an at-STOP step.

## B. Another section

1. Numbered but not under a proposal heading.
