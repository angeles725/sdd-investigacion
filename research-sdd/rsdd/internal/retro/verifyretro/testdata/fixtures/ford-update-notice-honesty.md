<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — ford-bms-panel · update-notice · 2026-09-10 · Research-SDD self-retrospective

> Run reviewed: ford-bms-panel B1–B3 (document-mode §20, focus complete, outline 3/3).
> Trigger: §20 document-mode completion.
> Method: a FRESH-CONTEXT agent read the current kit (`PROMPT-LOOP.md` + `METHODOLOGY.md`) FIRST, then
> the run's blocks (ford-bms-block1..3.md), INDEX.md, RESEARCH-STATE.md, RUNBOOK-AVISO-VERSION.md,
> and the probe at `sources/probes/`, and proposes kit deltas. READ-ONLY on the kit — this report only
> PROPOSES; kit changes are human-reviewed and human-committed (METHODOLOGY §18).

## Proposed kit deltas

> Only genuinely NEW items — anything the kit already encodes is listed under "Already covered", not here.
> Each delta: the concrete change · the target file/§ · evidence · priority.

| # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |
|---|---|---|---|---|---|

no new deltas; the kit already covers this run.

## Already covered (dedupe — proof the retro read the kit first)

- **Subject version stamp on all blocks** → already covered by `METHODOLOGY §20` ("FREEZE THE LIVE SUBJECT FIRST") and the block anatomy (`§4` required `Subject version:` line).
- **`Type: capture` on document-mode blocks** → already covered by `§4` closed block grammar (token `capture` / alias `document`).
- **`[CERT-hw]` for own-deployed Cloudflare Pages service (not `[CERT-live]`)** → already covered by `§3` taxonomy ruling ("A service you deploy and own is not `[CERT-live]`; use `[CERT-hw]` there") and the §12c explicit reference the driver cited in B3's header.
- **Playwright banner verification cited `[INFER]` (session not preserved)** → already covered by `§20 DOCUMENT CYCLE step 2` ("Documenting a PROCEDURE → the SESSION itself is the evidence … PRESERVED under `sources/probes/`"). The driver made an honest choice: no probe file → `[INFER]` is correct per §3.
- **Engram mirror executed at STOP** → already covered by `§20 step 5` ("MANDATORY ENGRAM MIRROR — non-negotiable").
- **RUNBOOK produced as subject deliverable** → already covered by `§20 step 6` ("write the human-readable product — RUNBOOK.md subject deliverables under `$CORPUS`").
- **No delegation for 3-item outline** → already covered by PROMPT-LOOP orchestration rules (inline is correct when the outline is tiny and every source is already understood).
- **`research-sdd-archive.sh` not run at STOP → CATALOG.md absent** → the rule is already encoded in `PROMPT-LOOP DOCUMENT CYCLE step 7` ("CLOSURE OBLIGATIONS — `research-sdd-archive.sh`: run it (gates linters, regenerates CATALOG, prints the close-checklist)"). This was a rule *skipped in practice*, not a missing rule. See Anti-patterns below.

## Anti-patterns observed

- **`research-sdd-archive.sh` skipped at document-mode STOP**: CATALOG.md is absent in the completed corpus. PROMPT-LOOP DOCUMENT CYCLE step 7 already mandates running archive.sh as part of the outline-completion STOP closure obligations. No new delta needed — the rule exists; the driver did not run the mechanized close. → No kit gap; covered by the existing closure obligations rule.
- **`<!-- kit-retro: exclude -->` applied to a non-retros file**: `corpus/RUNBOOK-AVISO-VERSION.md` carries this opt-out marker, but the sweeper's scope is `find … -path '*/retros/*.md'` — the RUNBOOK is not in a retros/ directory and is invisible to sweep-retros.sh regardless of any marker. The marker is superfluous and suggests a misreading of the scope marker's purpose (§18: "When a file in *such a directory* is NOT a §18 kit self-retrospective" — "such a directory" = a retros/ subdirectory). No harm done; the marker on a non-retros file is a no-op. No delta proposed: the kit's existing opt-out design section (§18 "Scope marker (opt-out)") already explains the scope.

## Tools built, adapted, or outgrown

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | — | — | — | — | — (no tools built; the run probed the live edge with curl and observed the banner in Playwright, both inline, no reusable tool produced) |

## Metrics

- **Blocks reviewed**: 3  ·  **§14 cross-block corrections in this run**: 0  ·  **Rules skipped in practice**: 1 (`research-sdd-archive.sh` at STOP)
- **Deltas proposed (new)**: 0  ·  **Already-covered lessons**: 8

## Honest verdict

No new deltas; the kit already covers this run. The ford-bms-panel #31 corpus is a clean, minimal §20 document-mode run: 3 outline items, 3 capture blocks, all markers correct, probe archived, Engram mirror complete, RUNBOOK produced. Every technique the driver used — subject freeze, `[CERT-hw]` for an own-deployed service, `[INFER]` for a non-preserved session observation, no delegation for a tiny outline — has an explicit rule in the kit. The only anti-pattern (skipped `research-sdd-archive.sh` → absent CATALOG.md) is already caught by DOCUMENT CYCLE step 7's closure obligations, not a gap in the kit rules.
