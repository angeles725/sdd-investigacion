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

1. PICK the block(s) to audit (favor high `[CERT-a]` density — grep `\[CERT-a\]`). Keep it bounded
   (1-2 blocks per run).
2. EXTRACT the claims, PRIORITIZING every `[CERT-a]` (unverified) + a spot-check of `[CERT]` (test the
   author's anti-hallucination). For each, find the real evidence (decompiled code via the toolbelt,
   the cited paths) and assign a VERDICT:
   - ESCALATED — was [CERT-a]/hedged → now source-confirmed; give the real file:line.
   - CONFIRMED — was [CERT], still holds (cite the line).
   - DOWNGRADED — cannot verify from available source → should be [INFER].
   - REFUTED — the code CONTRADICTS the claim, or the cited file:line says otherwise (most valuable).
3. WRITE the audit report under <TARGET>/../sdd-investigacion/audits/ (or TARGET/audits/) from
   $KIT/templates/audit.template.md: a table of audited claims + a METRICS summary
   (N audited · #ESCALATED · #CONFIRMED · #DOWNGRADED · #REFUTED).
4. HONEST VERDICT: did the engine extract more — and of what kind (more certainty? caught errors?) —
   or did the original hold up?

RULES: READ-ONLY on the audited corpus (only WRITE the audit report). Do NOT fabricate — if you can't
reach the code, mark DOWNGRADED (unverifiable), not REFUTED. Cite real file:line for ESCALATED/CONFIRMED.
```

## Notes

- Proven on niagara `bloque100` (ipcMigrator): 21 claims → 12 ESCALATED, 7 CONFIRMED, 2 DOWNGRADED,
  1 REFUTED. The original corpus had zero fabricated facts; the residual risk was **imprecise
  attribution** (right behavior, wrong owning class) — exactly what a code re-read catches.
- Audit findings can feed a correction pass (METHODOLOGY §14): apply the REFUTED/DOWNGRADED verdicts
  back into the corpus transparently ("corrected per audit").
