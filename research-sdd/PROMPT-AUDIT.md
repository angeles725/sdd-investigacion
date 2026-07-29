# PROMPT-AUDIT — Research-SDD audit mode

Re-verify an EXISTING corpus against its primary source. Output is an **audit-delta**, NOT new
knowledge blocks (METHODOLOGY §13). Use it on a mature corpus — especially one written without this
engine — to escalate hedged `[CERT-a]` claims to cited `[CERT]`, and to catch errors a code re-read
surfaces. READ-ONLY on the audited corpus.

## How to use it

Run as a single delegated task (or `/loop` over several blocks). Set the block(s) to audit, then
paste the OPERATIONAL PROMPT below.

## OPERATIONAL PROMPT (this is what runs)

```text
You are a Research-SDD CERTAINTY AUDITOR. READ-ONLY. Re-verify the claims of EXISTING block(s) of
<TARGET> against the real primary source, to measure whether this engine extracts more certainty than
the original author and to catch errors.

TARGET = <path to the corpus>        KIT = /home/cristian/investigacion/sdd-investigacion/research-sdd
SOURCE_ROOT = <path to the real primary sources>   # OFTEN NOT under TARGET — see note below

0. LOCATE the sources. The corpus (TARGET) frequently does NOT hold its own primary code: the blocks
   cite a SIBLING tree (e.g. a decompiled-modules dir outside TARGET). Read a block's citations to find
   where the real code lives and set SOURCE_ROOT to it; TARGET is only where the .md blocks + the audit
   report live. If a class exists in SEVERAL decompiler variants (vineflower / procyon / raw), the LINE
   NUMBERS differ between them — PIN the variant the block was authored against (usually named in the
   block's method headers) and cite that one, or a `find | head -1` may land on a different copy and
   produce a FALSE REFUTED.
1. PICK the block(s) to audit (favor high `[CERT-a]` density — grep `\[CERT-a\]`). Keep it bounded
   (1-2 blocks per run).
2. EXTRACT the claims, PRIORITIZING every `[CERT-a]` (unverified) + a spot-check of `[CERT]` (test the
   author's anti-hallucination). For each, find the real evidence (decompiled code via the toolbelt,
   the cited paths) and assign a VERDICT:
   - ESCALATED — was [CERT-a]/hedged → now source-confirmed; give the real file:line.
   - CONFIRMED — was [CERT], still holds (cite the line).
   - DOWNGRADED — cannot verify from available source → should be [INFER].
   - REFUTED — the code CONTRADICTS the claim, or the cited file:line says otherwise (most valuable).
     The claim was WRONG WHEN WRITTEN. Correct or delete it per METHODOLOGY §14.
   - DRIFTED — the code confirmed the claim at the block's subject version, but the subject has
     since moved and the claim no longer holds. The claim was RIGHT WHEN WRITTEN; the world changed.
     Do NOT delete it — version-annotate it and queue a refresh (PROMPT-REFRESH.md).
     Requires a `Subject version:` stamp on the block to be meaningful; if absent, treat the claim
     as unscoped and mark DRIFTED only when you can confirm the old version matched the claim.
   NOTE: REFUTED and DRIFTED demand opposite remedies. REFUTED → correct/delete. DRIFTED →
   version-annotate and refresh. Collapsing them loses version history that downstream readers of
   older artifacts still need.
3. WRITE the audit report under $TARGET/audits/ (create the dir if absent) — NEVER under the kit /
   supervisor repo. METHODOLOGY §13 fixes `audits/` as living under the audited TARGET; the old
   "or under sdd-investigacion" branch was the bug that once landed a coverage audit in the supervisor
   repo by mistake. Write from $KIT/templates/audit.template.md: a table of audited claims + a METRICS
   summary (N audited · #ESCALATED · #CONFIRMED · #DOWNGRADED · #REFUTED · #DRIFTED).
   For each DRIFTED finding, record the subject version the claim held at (from the `Subject version:`
   stamp) and the evidence that it changed in the new version.
4. HONEST VERDICT: did the engine extract more — and of what kind (more certainty? caught errors?) —
   or did the original hold up?

RULES: READ-ONLY on the audited corpus (only WRITE the audit report, and ONLY under $TARGET/audits/ —
never the kit / supervisor repo). Do NOT fabricate — if you can't reach the code, mark DOWNGRADED
(unverifiable), not REFUTED. Cite real file:line for ESCALATED/CONFIRMED.
```

## Notes

- **First standalone run (2026-07-12, niagara blocks 90+81):** 24 claims → **13 ESCALATED · 11 CONFIRMED
  · 0 DOWNGRADED · 0 REFUTED** — a clean sweep. Every audited `[CERT-a]` was in fact correct in code, so
  the hedging meant "not re-verified by me," never "shaky"; the value here was pure certainty-raising, not
  refutation. The one residual was an **imprecise attribution** (block-81.3 credited image encryption to
  `KitpxUtils.encrypt`, but the literal `encrypt()` lives in `EncryptDecrypt.java:54`; `KitpxUtils` only
  owns the key) — the "right behavior, wrong owning class" risk, fed back as a §14 correction. Report:
  `niagara-research/audits/2026-07-12-certainty-audit.md`. (This REPLACES an earlier draft's "proven on
  bloque100: 21 claims…" note, which METHODOLOGY §13 had already retracted as unverifiable — B100 carries
  none of the audit vocabulary; do not resurrect it.)
- The first run also surfaced two contract gaps now fixed above: the sources were NOT under TARGET (hence
  the `SOURCE_ROOT` input), and the same class existed in 4 decompiler variants with different line numbers
  (hence the variant-pin step). Strong ESCALATIONs often rest on 2-3 coordinated lines (a constant def + its
  use site) — a multi-line citation is expected, not a smell.
- Audit findings can feed two distinct follow-up passes:
  - **REFUTED/DOWNGRADED** → correction pass (METHODOLOGY §14): apply the verdicts back into the
    corpus transparently ("corrected per audit").
  - **DRIFTED** → refresh pass (PROMPT-REFRESH.md): re-verify each drifted claim against the new
    subject version and version-annotate or update it in place. Do not run a correction pass on
    a DRIFTED claim — that would delete still-valid version-scoped history.
