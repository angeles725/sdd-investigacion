# Kit session 2026-10-01

## Objective
Close PR #1155 (round 5), audit the retro/delta corpus for count and quality, fold the "can-do"
(possibility-first) mindset deltas into the kit, then chain the open backlog automatically.

## Authorization
User granted for this session: ODD + RDD (consent granted for every candidate), commit, push,
PR create/view, issues, merge; chain automatically; answer own questions; accept Gentle AI prompts.
During the session the user added global allow rules: `Bash(gh issue list|edit|view|close|comment|create:*)`,
`Bash(gh pr merge:*)`, `Bash(gh pr edit:*)`.

## Outcome
- **14 PRs merged:** #1286 (d68aa61), #1300 (cedf67d), #1302 (33084f0, supersedes #1155), #1298 (4feb177),
  #1305 (66d1150, supersedes #1303), #1306 (70a4d04), #1308 (d54592e), #1310 (eb40562), #1312 (cde675d),
  #1315 (bf749b0), #1318, #1317 (37f4f4d), #1314 (f1b5c48), #1316 (aa3907d). origin/main = aa3907d.
- **Issues:** 64 closed on 2026-10-01 (≈58 by this session: work merged, 23 verified already-applied,
  3 duplicate/obsolete/target-specific; #1263–#1267 and #1248 by another session). 21 created
  (#1288–#1297 = unseeded niagara5 deltas; the rest review follow-ups). Open: 168 → 132.
- **Can-do mindset (#1263–#1270) fully in the kit:** #1278 (another session) + #1308.
- Every PR: writer in a harness worktree (strict TDD, executed RED, mutants, 3 gates) → RDD per commit
  (all approved, consent from the standing grant) → Opus adversarial review → FIX-FIRST round when
  needed → CI → squash merge → follow-up issue.

## What changed in the kit (by PR)
- #1302 fetch-doc permanent-redirect resolution + 8 METHODOLOGY deltas (#1112).
- #1286 / #1305 / #1315 retro→issue seeding: nested corpus target name, shared `target_name_for_retro`,
  exact-signature dedup (no fuzzy GitHub hits), CommonMark fence tracking in the retro marker, reconcile
  legacy signature, `corpus/retros` scanned.
- #1298 `tests/lib/mutant.sh` (refuses empty/identical/live-tree/symlink mutants) + run-all kit-tree
  hermeticity guard (caught bog-nav/station-modules rewriting committed fixtures).
- #1300 / #1310 retro-gate: nested worktrees ignored (commondir + back-pointer proof, submodules
  counted), generated CATALOG.md skipped, symlinked targets followed (`find -H`), C0 JSON escaping;
  verify-state suite 235 s → 48 s.
- #1306 / #1314 sync-state: CHANGED lines, `--only`, `--root`, never invents values (keeps declared
  on untrustworthy derivations), closed-class rows counted, Priority-header guard, lower-bound WARNs.
- #1308 doctrine: stretch goal at bootstrap, unblock plan per wall, possibility audit before STOP.
- #1312 fetch-doc evidence-preserving re-fetch, atomic web snapshot, trap cleanup, downloader probe.
- #1316 decompile-java bounded timeout, per-unit isolation/fallback, typed DEGRADED/PARTIAL, failure-
  text-only marker scan, isolation budget.
- #1317 PROMPT-LOOP-APPENDIX: concurrent-writers, delegation-briefs, review-and-delivery,
  resource-budgets (13 issues).
- #1318 verify-doc-consistency CHECK 5 across kit docs; lint-substitution find-stderr fix.

## Census (retros/deltas, 2026-10-01)
~221 retros / ~657 deltas in registered targets (~640 / ~1,400 incl. unregistered corpora);
verify-retro 94/220 fail, only 2 after 2026-09-15 (retro gate works). 9 applied markers cite
niagara-tools shas (wrong repo). HotelHilton TARGETS path drift (`Cliente/Cancun` vs
`clientes/cancun`) hides 11 retros and blocks staging its deltas.

## Lessons (also in Engram)
- RDD `--base-ref` is the LAST REVIEWED BOUNDARY (merge-base only for the first slice); never a moving
  origin/main — a base ahead of the branch shows later merges as reverts (PR #1300 false CRITICALs).
- `lens_context_budget_exceeded` → re-publish as chained commits ≲400 authored lines, review each
  commit against its parent (scratchpad `rdd_chain.sh`).
- Force-push blocked → publish reviewed commits on a new branch and open a superseding PR.
- pr-check requires EXACTLY one `type:*` label and `status:approved` on every closed issue.
- Fleet-sweep acceptance must reach every RESEARCH-STATE/retro incl. `corpus/` subdirs (depth ≥3);
  the reviewer must re-run the sweep, not trust the writer's table (#1314 found 2 wrong changes).
- Opus doctrine cross-reads catch contradictions RDD approves at medium risk (#1308, #1317).
- Stop finished writers that keep re-notifying (TaskStop) to save orchestrator context.
- zsh does not word-split `$VAR` — pass lists as explicit arguments.

## Next session — agenda (in order)
1. **User:** fix `research-sdd/TARGETS.md` HotelHilton path (`tunnel/clientes/cancun/HotelHilton`);
   then stage its retros with `stage-retro-issues.sh` (2026-09-18 retro; 2026-08-01 after a PARTIAL
   marker `shipped: 1,4,5,7,8`). #1319 item 3: refresh other stale TARGETS paths.
2. #1320 decompile-java registry row + METHODOLOGY §6 wording (doc unit), then its code follow-ups.
3. #1319 sync-state: malformed rows must trigger the lower-bound keep (kitControl 18→16).
4. #1299 teeth rollout to `tests/lib/mutant.sh` (110 suites; chained slices).
5. #1304 / #1311 / #1313 small hardening (dedup `--limit 200`, CRLF fence closer, stderr leak,
   fetch-doc TERM/process group); #1309 doctrine nits; #1166 items 1–2 (appendix).
6. Backlog waves from the 2026-10-01 triage still open: M2 evidence/sources doctrine (#1182 #1237
   #1209 #1219 #1238 #1249 #1257 #1191–#1193 #1204 #1210 #1226 #1179), M3 verification contract
   (#1201 #1208 #1211 #1215 #1241 #1242 #1243 #1273 #1251 #1252 #1254), M4/M5, lint-block.sh (#1206 +
   rule packs), U4 verify-sources (#1228 #1242a), status.sh B (#1154 #1152 #1150 #1023), #1015/#1014
   secrets, #973 verify-block, niagara5 deltas #1288–#1297.
