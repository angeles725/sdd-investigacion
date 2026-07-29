# PROMPT-REFRESH — Research-SDD refresh mode

Rewrite a corpus block whose subject has DRIFTED from the version it was written against. Output is an
**updated block in place**, NOT a new block (METHODOLOGY §13). Use it after an audit surfaces a DRIFTED
verdict — the block was correct at the subject version it cited, but the subject has since moved.
READ-ONLY on any part of the corpus that is not the target block.

## How to use it

1. Identify the block to refresh — it must carry a DRIFTED verdict from a prior audit, or a explicit
   `Subject version:` stamp that differs from the current subject version.
2. Set `SUBJECT_VERSION_OLD` and `SUBJECT_VERSION_NEW` before running.
3. Paste the OPERATIONAL PROMPT below.

Do NOT use this prompt on a block whose claims are REFUTED (wrong when written). Refuted claims are
corrected per METHODOLOGY §14, not refreshed. The distinction is the point:
- **REFUTED** — the subject contradicts the claim; the claim was wrong at write time. Correct or
  delete it.
- **DRIFTED** — the subject confirms the claim at the old version but contradicts it now; the world
  moved. Re-verify against the new version, then version-annotate the old text instead of deleting it.

## OPERATIONAL PROMPT (this is what runs)

```text
You are a Research-SDD BLOCK REFRESHER. You rewrite ONE drifted block to the current subject version
while preserving provenance of the original findings.

TARGET  = <path to the corpus>       KIT = /home/cristian/investigacion/sdd-investigacion/research-sdd
SOURCE_ROOT           = <path to the real primary sources at the NEW version>
BLOCK                 = <path to the block file to refresh>
SUBJECT_VERSION_OLD   = <vX.Y.Z | commit | date — the version the block was written against>
SUBJECT_VERSION_NEW   = <vA.B.C | commit | date — the version you are refreshing to>

0. CONFIRM the block is a DRIFT candidate, not a REFUTED-only block. Read the block. Read its
   SUBJECT VERSION stamp (block header line `Subject version:`). Confirm SUBJECT_VERSION_OLD matches.
   If the header is absent, treat every claim as unconfirmed for version scope and proceed.

1. RE-VERIFY each claim against SOURCE_ROOT (the NEW version sources). For each claim assign one of:
   - PRESERVED  — holds unchanged in the new version (cite the new file:line).
   - DRIFTED    — was correct at OLD, now changed; the new behaviour is X (cite new file:line).
   - REFUTED    — was wrong even at OLD (evidence shows the claim was never true — not just moved).
   - ESCALATED  — can now confirm a previously hedged [CERT-a] claim at the new version.

2. PROVENANCE RULES (non-negotiable):
   a. PRESERVED claims — update the `file:line` citation to the new version's location; no text change
      to the claim itself unless the evidence calls for it.
   b. DRIFTED claims — KEEP the original claim text, append a versioned note inline:
        > _(was: <old claim summary> — true at `SUBJECT_VERSION_OLD`; changed in `SUBJECT_VERSION_NEW`:
        > <what changed> [`file:line` NEW])_
      Do NOT delete the old text. Downstream readers of the old version still need the v-old truth.
   c. REFUTED claims — correct or delete per METHODOLOGY §14. Mark the change with:
        > _(corrected per refresh `SUBJECT_VERSION_NEW`: <why it was wrong at any version>)_
   d. ESCALATED claims — upgrade the marker from `[CERT-a]` to `[CERT]` and supply the new `file:line`.

3. UPDATE the block header:
   a. Change `Subject version: <old>` → `Subject version: <new>`.
   b. Update the `Sources:` line if the source path changed between versions.
   c. Add a `Refreshed:` line immediately after `Subject version:`:
        > Refreshed: <YYYY-MM-DD> from `SUBJECT_VERSION_OLD` to `SUBJECT_VERSION_NEW`.

4. WRITE the updated block back to BLOCK. This is the ONLY file you write. Do NOT write an audit
   report. Do NOT touch INDEX.md, CATALOG.md, or any other block.

5. SELF-VERIFY: run `$KIT/toolbelt/verify-block.sh <block>` and confirm it exits 0. Fix any
   marker/citation errors before declaring done.

RULES:
  - READ-ONLY on the entire corpus EXCEPT the one target block.
  - Do NOT fabricate. If you cannot reach a source at the new version, mark the claim DOWNGRADED
    (unverifiable at new version) rather than inventing a new citation.
  - A refresh is NOT a rewrite. Preserved claims keep their original phrasing. Only DRIFTED,
    REFUTED, and ESCALATED claims change.
  - If more than half the claims are REFUTED (not DRIFTED), stop and report: this is a
    retraction, not a refresh. The operator must decide whether to archive or replace the block.
  - Never start a refresh without a confirmed audit that identified the DRIFTED claims. Running
    refresh on a block with no prior audit is out of order.
```

## Notes

- **When to refresh vs. when to audit first.** An audit (PROMPT-AUDIT.md) discovers which claims
  drifted. A refresh acts on those findings. The normal order is audit → refresh, not refresh cold.
  Running refresh on an un-audited block collapses two passes into one and loses the intermediate
  diagnostic record.
- **Version scope.** The DRIFTED verdict is only meaningful if the block carries a `Subject version:`
  stamp (delta 3 of the 2026-07-28 retro adds this stamp to the template). Refreshing an un-stamped
  block requires treating every claim as potentially drifted — a full re-audit disguised as a refresh.
  Add the stamp to un-stamped blocks before refreshing.
- **Not append-only.** Blocks are normally append-only (new sections are added, old ones stay).
  A refresh is the one sanctioned exception: it edits existing claim text. The `Refreshed:` header
  line and the inline versioned notes are the provenance trail that makes in-place editing auditable.
- **Refresh findings feed the corpus record.** After refresh: update RESEARCH-STATE.md's
  `covered_blocks` count if the block count changed (it should not for a pure refresh), and note
  the refresh in the iteration history with `[REFRESH B<n>]` in the "Block" column.
