# METHODOLOGY provenance

Provenance for `research-sdd/METHODOLOGY.md`. Not an operating rule: read it only to audit where a
rule came from. Kit issue #1003 (third slice) moved the bare corpus-pointer `(Evidence: ...)` notes
(a corpus, focus, block or retro reference with no reason of its own) from §5, §6, §11a, §12, §19 and §20b of
METHODOLOGY.md to the table below; the rules themselves are unchanged and still live in
METHODOLOGY.md. Each row keeps the original note verbatim, including its `Evidence:` prefix and
parentheses. The first column is the exact bold label the annotated rule carries in METHODOLOGY.md
(without the `**` markers), so `grep -nF` on it finds the rule.

Slice 7 (the rows after the first 18) moved 94 more: every `(Source: ...)` retro or corpus pointer that
stands alone at the end of a paragraph or list item (single-line, or wrapped across two lines) and gives no reason of
its own. Moved in total: 112 notes. Not moved, by design: notes that carry a reason or a case description, and notes
embedded mid-sentence in rule text; moving those would require rewriting rule text, which is not worth it. They stay in
METHODOLOGY.md. Rows keep the original note verbatim (wrapped notes are joined onto one line).

| Rule (exact label in METHODOLOGY.md) | Original note (verbatim) |
|---|---|
| But the class-NAME token itself can be partially mangled. | (Evidence: niagara workbench focus, 6/12 blocks — B427/B429/B435-438.) |
| JPMS products: measure module identities before `--patch-module` (kit #1618). | (Evidence: B139 §139.1/§139.2.) |
| Precedence oracle: `-Xlog:class+load=info` (kit #1617). | (Evidence: B139 §139.2, 11 runs.) |
| A SUMMARY ROW CERTIFIES ONLY THE ROW IT PRINTS (kit #1541). | (Evidence: B1206 §1206.4, a §14 correction to B1204; kit #1541.) |
| Vendor installer that initializes runtime state is a mutation — snapshot first. | (Evidence: niagara-research (licensing-deepdive focus)) |
| Mutating the cited subject invalidates prior citations — re-anchor to a preserved snapshot. | (Evidence: blender-llm B6) |
| Arm a local network sink and verify it is recording before the first probe. | (Evidence: blender-llm B6) |
| Invasiveness ladder (fixed order). | (Evidence: blender b6 retro d1) |
| Live-write hygiene: identity before, persistence after, runner shape, double-first. | (Evidence: niagara n4 agent-mcp am20 and live-runs retros) |
| Direct operator authorization names the target — a peer-relayed summary is never authorization. | (Evidence: panccadia-3d-viewer) |
| LIVE-WRITE PROTOCOL (three mandatory gates). | (Evidence: panccadia B22/B23.) |
| "What silently resets this?" — confirm a remote channel's dependencies before acting. | (Evidence: computadoras B16 §16.20, B25 §25.3/§25.6/§25.7.) |
| Vendor menu key-numbering is firmware-version-dependent — confirm live before pressing. | (Evidence: niagara-research (jace9000 focus)) |
| Pre-interaction mutation map — classify READ-ONLY vs mutating keys before live interaction. | (Evidence: niagara-research (jace9000 focus)) |
| Vendor's own tool succeeds → probe failure is almost certainly client-side. | (Evidence: fluke-177x-datos) |
| Cross-host path-namespace failure class (WSL2 / Windows). | (Evidence: blender-llm B7–B9) |
| Offline/zero-network verification for self-contained visual deliverables. | (Evidence: COB-IM2 B11 §11.3 — commit `99b84cb`, `qa-render-offline.png` from a byte-identical offline build.) |
| Decision rule. | (Evidence: niagara-research/retros/2026-09-01-research-sdd-journal-mode-retro.md J2) |
| Possibility-first (route ladder, not a verdict). | (Source: 2026-09-30-possibility-first-mindset retro; kit issues #1263-#1266.) |
| Persist timestamps in UTC from the raw value; convert to local only at the display layer. | (Source: fluke-177x-datos.) |
| Tracker-close is not a fix in your build. | (Source: 2026-09-16-blender-llm-b15-b16-source-and-security-retro.md delta #1) |
| Name the gate condition for a gated defect. | (Source: 2026-09-16-blender-llm-b15-b16-source-and-security-retro.md delta #3) |
| In-code maintainer comments are primary-source evidence. | (Source: 2026-09-16-blender-llm-b10-bridge-threading-retro.md delta #2) |
| CAPABILITY ≠ ENABLED. | (Source: 2026-09-16-blender-llm-b14-asset-pipeline-retro.md delta #1) |
| Per-record certainty for heuristic datasets. | (Source: 2026-09-16-blender-llm-b17-b20-duct-pipeline-retro.md delta #5) |
| Verify the DATA against the declared contract. | (Source: niagara-research/retros/2026-09-03-obix-architecture-consulting-retro.md #3) |
| Slot vs. reader-derived value (API/facade boundary). | (Source: 2026-09-04-dashboardpan-2d-to-3d-port-multi-session-coordination-retro.md #2) |
| Control-write contract is incomplete without interlock semantics. | (Source: 2026-09-04-dashboardpan-2d-to-3d-port-multi-session-coordination-retro.md #5) |
| App INSTALL / artifact as a first-order source. | (Source: 2026-09-13-mejora-continua-de-la-doctrina.md row 4) |
| Plugin/extension-hosting targets: record load channels per entry point. | (Source: kit #1960.) |
| Focus-inherited census (scoped focus over an already-censused corpus). | (Source: 2026-08-30-alarm-webhook-focus-retro.md D1) |
| A residual category is not noise until someone has read it. | (Source: blender-llm B35) |
| Giant single-line artifact navigation (minified / base64-laden files). | (Source: 2026-09-01-large-single-file-navigation-retro.md #1; 2026-09-03-research-sdd-cross-session-verify-retro.md #2) |
| Entropy + byte histogram as a read-only encryption test. | (Source: 2026-08-30-jace8000-qnx-native-focus-retro.md D4) |
| Custom-implementation survey against the vendor's equivalent in `organized/docSource`. | (Source: 2026-09-03-research-sdd-multi-session-obix-oracle-and-tridium-canonization.md #3) |
| Obfuscated `docSource` is a tool wall, not evidence. | (Source: 2026-09-03-research-sdd-rt-authoring-campaign-retro.md #3) |
| Corroboration doctrine applies to any measured quantity, not only decompiled binaries. | (Source: blender-llm/retros/2026-09-16-blender-llm-b17-b20-duct-pipeline-retro.md Δ6) |
| Real-artifact-first for packaging/layout gaps. | (Source: niagara-research/retros/2026-08-29-module-anatomy-focus-retro.md module-anatomy-1) |
| Read the package histogram before judging size or emptiness. | (Source: niagara-research/retros/2026-08-29-own-modules-audit-focus-retro.md own-modules-1) |
| Prefer source over jar for INTENT and CONFIG claims when source is available. | (Source: niagara-research/retros/2026-08-29-chihuahua-source-focus-retro.md chihuahua-2) |
| `shared-global` migration: backfill ALL RESEARCH-STATE files, not only the active focus. | (Source: niagara-research/retros/2026-08-05-electronicSignature.md ES-B) |
| A refused or deferred-by-policy step must become a typed backlog row in the same pass. | (Source: niagara D4.) |
| Apply the stopping criterion to sub-lines too — terminate with a measured bound, not a pause. | (Source: blender-llm/retros/2026-09-16-blender-llm-b21-b37-cad-reconstruction-retro.md Δ7.) |
| A long analysis is justified by a question only it can answer, not by having already started it. | (Source: blender-llm Δ6, B54 §54.5.) |
| Saturation is a soft REVIEW prompt, not a fourth STOP criterion. | (Source: 2026-09-03-research-sdd-rt-authoring-campaign-retro.md #1) |
| The saturation prompt reads the `New gaps uncovered` cell by header name, and the cell needs a leading count. | (Source: niagara RP-C, B362–B365.) |
| ACTIVE CLOSE: audit before declaring a gap closed or a deliverable done. | (Source: fluke-177x-datos) |
| Pre-stop artifact audit: check for uncited decompiler dumps before honoring `investigable=0`. | (Source: niagara D1.) |
| A unit counts as CITED only when one of its unambiguous file basenames appears in a block as an extension-bearing token (`<basename>.<ext>`, word-bounded, case-sensitive) or inside a path token; a bare class or file stem in prose is never a citation | (Source: kit issue #421 fleet acceptance, 2026-09-05) |
| The coverage universe is DECLARED, never inferred. | (Source: kit issue #421 fleet acceptance, 2026-09-05) |
| Gap counters are NOT mutually exclusive — a single gap can satisfy multiple counters simultaneously. | (Source: niagara-research/retros/2026-08-29-ports-focus-retro.md DELTA-4) |
| `known_gaps` DENOMINATOR MUST BE LIVE. | (Source: niagara module-mechanics-closeout) |
| A mid-run operator sub-request that is cheap and cross-cutting becomes a BONUS block, not a deferral or a new focus. | (Source: 2026-09-04-research-sdd-module-authoring-mega-campaign-retro.md #3) |
| Frontier mode (5th investigation mode — unexplored territory, breadth-first). | (Source: niagara-research/retros/2026-09-14-frontier-mode-proposal.md) |
| Extension for node-graph tools (Blender GN/shader, Unreal Blueprint, Houdini, etc.): | (Source: blender-llm/retros/2026-09-16-blender-llm-b7-b9-live-phase-session-retro.md Δ1) |
| When disambiguation by geometry or proximity is ambiguous, look for a conserved quantity. | (Source: blender-llm B29/B32) |
| PROPRIETARY-OPERATOR-DATA discipline. | (Source: 2026-09-16-blender-llm-b12-b13-cad-application-retro.md delta #1) |
| Record the GATING condition when copying a rule or threshold. | (Source: investigacion/mini-pc/corpus/retros/2026-09-14-doctrina-documentar-problemas.md delta #4.) |
| For an ENUMERATION or set-membership claim, read the code that DEFINES the set before answering. | (Source: 2026-09-03-research-sdd-commissioning-map-consulting-retro.md #1) |
| DECOMPILED-TREE BLOCKS WILL SHOW ZERO RESOLVED CITATIONS — THIS IS EXPECTED. | (Source: niagara-research B542–B547.) |
| A boolean named `*Protect`, `*Enable` or `*Mode` may be a CONFIG flag, not the active STATE. | (Source: panccadia-3d-viewer/retros/2026-09-05-kit-retro-document-runs-b10-b19.md D3) |
| To prove a "what changed since X" delta when timestamps cannot discriminate (e.g. same-day commits), check the CONSUMER for ABSENCE, not the producer's commit boundary. | (Source: 2026-09-04-dashboardpan-2d-to-3d-port-multi-session-coordination-retro.md #1) |
| UNANIMITY IS AN ARTIFACT DETECTOR: a 100 % hit-rate must be re-verified by an independent method. | (Source: blender-llm B17-B20) |
| MATCHING COUNTS ARE NOT A JOIN: equal cardinality does not establish intersection. | (Source: blender-llm B17-B20) |
| CONSERVATION CHECK: quantities that must sum or balance must be explicitly checked. | (Source: blender-llm B21-B37) |
| RESEARCH-TO-QUOTE BRIDGE: map cited evidence to every quoted number in a synthesis report. | (Source: niagara-research reports focus) |
| RECOMPUTE-BLINDNESS: at least one check must read consumer state, not derived state. | (Source: blender-llm B44 §44.4.) |
| PRINT POPULATION COUNT IN THE SAME CALL AS THE MUTATION. | (Source: blender-llm B59 §59.1.) |
| POPULATION-FLOOR GATE: a verification suite must not pass an empty subject. | (Source: blender-llm B59 §59.5.) |
| LONG BATCH RUNS ARE CONTENT-ADDRESSED PER UNIT, AND THE CACHE IS THE CHECKPOINT. | (Source: n5 fidelity long-run-throughput retro #1, #2.) |
| VALIDATE EMBEDDED JAVASCRIPT WITH `node --check` BEFORE PUBLISHING AN HTML ARTIFACT. | (Source: fluke-177x-datos 2026-09-14-entrega-dashboard-supabase-pages.md row 4.) |
| SELF-REFERENTIAL MARKER INFLATION: do not paste `verify-block.sh`'s own tally into the block. | (Source: n5 wave 6-7 retro #2) |
| Run an experiment before restating a tool-behavior rule. | (Source: n5 method-errors retro #12.) |
| A GATE IS ONLY WORTH WHAT ITS REFERENCE IS WORTH: validate the reference before trusting the gate. | (Source: blender-llm B21-B37) |
| Before calling a state-changing operator, confirm a non-mutating variant exists. | (Source: 2026-09-03-research-sdd-multi-session-obix-oracle-and-tridium-canonization.md #2) |
| SCALE GROUND TRUTH: seek the artefact the system itself PRODUCES as the answer key. | (Source: fluke-177x-datos) |
| SAME-SNAPSHOT COMPARISON: compare against the EXACT same data snapshot. | (Source: fluke-177x-datos) |
| Prior-coverage reconciliation is a REQUIRED first output of the audit-first sweep (kit issue #1116). | (Source: niagara-research `retros/2026-08-28-template-focus-retro.md` D1.) |
| FAILURE-AXIS AUDIT-FIRST bootstrap (hardening/robustness focus variant). | (Source: niagara module-hardening retro.) |
| Mature-corpus broad-enumeration audit: REMITTANCE-dominant, not discovery-dominant. | (Source: niagara-research/retros/2026-08-25-apis-closure.md D3) |
| Recursive auto-sharding for artifacts that exceed a single context window. | (Source: fluke-177x-datos 2026-09-13-auto-sharding-recursivo-de-agentes, 2026-09-13-orquestacion-sweeps-paralelos-decompilado) |
| A sweep-named architectural pattern must cite a concrete file (kit issue #1116). | (Source: niagara-research `retros/2026-08-28-provisioning-focus-retro.md` D1.) |
| Reconcile against the subject's own audit/CHANGELOG/ADR documents when available. | (Source: niagara-research/retros/2026-08-29-chihuahua-source-focus-retro.md chihuahua-3) |
| Count-discrepancy scope check. | (Source: niagara-research/retros/2026-08-28-kitcontrol-focus-retro.md D3) |
| Layer-distinction reconciliation check. | (Source: niagara-research/retros/2026-08-05-webChart.md WC-C) |
| Cross-session parameter proposals are hypotheses until measured. | (Source: COB-IM2/retros/2026-09-09-cob-im2-continuity-round.md D3) |
| Declared resume queue (`next_session_queue`). | (Source: kit #1614, niagara5-research licence lane) |
| Leaf vs. root trust artifacts (cross-focus note). | (Source: niagara-research/retros/2026-08-07-signing-pki.md SPKI-C.) |
| Consolidation focus. | (Source: 2026-08-29-ports-focus-retro.md DELTA-2) |
| Sibling / twin focus. | (Source: 2026-08-30-jace8000-qnx-native-focus-retro.md D2) |
| Peer-session-triggered focus. | (Source: 2026-08-30-alarm-webhook-focus-retro.md D2) |
| Peer-axis-split focus. | (Source: niagara-research/retros/2026-08-24-licensing-deepdive.md D6) |
| APPLIED / BUILD-ALONG focus. | (Source: 2026-08-30-coldroom-module-build-retro.md #1) |
| Distributed multi-session diagnosis split by source. | (Source: 2026-09-03-research-sdd-multi-session-obix-oracle-and-tridium-canonization.md #1) |
| Census → taxonomy → playbook triad for "document everything about X across many instances." | (Source: 2026-09-04-research-sdd-module-authoring-mega-campaign-retro.md #1) |
| Admission-audit gate for cross-lane consumed artifacts. | (Source: COB-IM2/retros/2026-09-09-cob-im2-continuity-round.md D2) |
| At a campaign retro, check whether a consuming kit has a corpus index that needs the new blocks. | (Source: 2026-09-04-research-sdd-module-authoring-mega-campaign-retro.md #7) |
| A scratchpad PoC proving control-logic claims is a cheap, high-value evidence step. | (Source: 2026-09-03-research-sdd-rt-authoring-campaign-retro.md #6) |
| Version-matrix API-signature diff as a standard instrument. | (Source: n4 agent-mcp retro #3.) |
| LIVE/UNFOLDING operations. | (Source: niagara relayed-cert-live retro.) |
| Driver, not the authoring sub-agent, populates document-cycle state after authoring. | (Source: investigacion/mini-pc/corpus/retros/2026-09-12-mini-pc.md delta #3.) |
| Mid-run outline additions by a coordinator are legal (kit #1989). | (Source: tunnel/clientes/cancun/HotelHilton/retros/2026-10-07-energeticos-b27-b32.md delta #2.) |
| Renderer by deliverable role (kit issue #1094). | (Source: sullair 2026-08-25 document-mode rendering retro DR-1.) |
| 21.1 Typed wall states | (Source: 2026-09-14-module-mechanics-closeout-retro.md C1) (annotates the `not-extracted` bullet) |
| Anti-ephemeral-artifact rule. | (Source: investigacion/mini-pc/corpus/retros/2026-09-14-doctrina-documentar-problemas.md delta #3.) |
| Documenting a problem is part of finishing it, not a deferred extra — a cadence rule, not a new debt. | (Source: investigacion/mini-pc/corpus/retros/2026-09-14-doctrina-documentar-problemas.md delta #2.) |
| Gate for recursive auto-sharding (default OFF). | (Source: fluke-177x-datos 2026-09-13-auto-sharding-recursivo-de-agentes, 2026-09-13-orquestacion-sweeps-paralelos-decompilado) |
| INDEX.md coverage: mandatory-per-block or explicitly read-on-demand. | (Source: cloudflare/retros/2026-08-28-corpus-complete.md D-CORPUS-1) |
| Corpus-level close trigger. | (Source: cloudflare/retros/2026-08-28-corpus-complete.md D-CORPUS-2) |
| Assumptions inherited from a compaction are hypotheses until re-verified. | (Source: fluke-177x-datos 2026-09-13-doctrina-detenerse-corto-y-explorar, 2026-09-13-camino-b-end-to-end-completo) |
| Problem-entry template (canonical form for documenting a bug or incident fixed mid-session). | (Source: investigacion/mini-pc/corpus/retros/2026-09-14-doctrina-documentar-problemas.md delta #1.) |
| Two-layer alerting pattern (platform-up ≠ payload-freshness). | (Source: tunnel/clientes/Leon-Guanajuato/Pancaddia/corpus/retros/2026-09-14-incidente-pipeline-jace.md A-3.) |
