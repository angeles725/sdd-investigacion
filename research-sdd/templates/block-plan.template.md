<!-- block-plan.template.md — ephemeral step-level resume plan for ONE long block (kit issue #1178).
     Copy to `$CORPUS/<block-file-stem>.plan.md` at block open, before the first sub-step.
     Doctrine: METHODOLOGY §17 item 6; loop steps: PROMPT-LOOP step 4 / step 6 / RESUME.
     Not a state document: RESEARCH-STATE.md stays the only source for gaps, backlog, campaign queue,
     iteration history and "what's next". Not an ODD task document (odd/tasks/*.md is kit-maintenance only).
     No checker script exists yet (doctrine first; a checker is a later slice). -->
# Block plan — <block-file-stem>

Block: `<block-file-stem>.md` · Gap: <one-line gap id/title, copied from RESEARCH-STATE.md — do not track it here>

## Rules (this plan lives only until the block's commit)

- Holds ONLY the sub-steps of THIS block. No other blocks, gaps, backlog, queue or "next" items.
- Tick `[x]` only when the item's artifact is on disk. After a cut, a ticked item whose artifact is
  missing is unticked again; resume at the first unticked item.
- Delete this file at the block's commit. It is never staged or committed.

## Sub-steps

- [ ] S1 — Sweep: <what is enumerated>
      Artifact: <path of the sweep output / probe log>
- [ ] S2 — Corroborate: <what is cross-checked>
      Artifact: <path of the corroboration output>
- [ ] S3 — Write: the block file
      Artifact: `<block-file-stem>.md`
- [ ] S4 — Self-verify: `verify-block.sh` on the block
      Artifact: <path of the self-verify output / report>
- [ ] S5 — Update catalog / index / state
      Artifact: CATALOG / INDEX / RESEARCH-STATE edits on disk
- [ ] S6 — Commit, then delete this plan
      Artifact: the commit; this file removed from the working tree
