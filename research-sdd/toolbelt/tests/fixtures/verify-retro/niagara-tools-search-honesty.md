<!-- review-status: pending -->
# Retro — 2026-09-17 tooling: search core, ranking, semantic, unified 3-source, preview auto-mock, kit lints

**Trigger:** operator hit `corpus-nav find "No matches"` on valid multi-word queries; root-caused to a literal-whole-query-substring matcher. Audit found the SAME bug in `niagara_help`. Operator then asked to innovate/improve the tools (chain #1–#7, high→low).

## What shipped (all verified by RUNNING)

| # | Change | Files | Verify |
|---|---|---|---|
| 1 | **Shared search core** `parse_query / file_matches(and\|or) / line_hits / score` | `tools/lib/textsearch.py` (+`test_textsearch.py`, 24 tests) | 24/24 pass |
| 2 | **Self-tests** on the search tools | `corpus-nav.py selftest`, `niagara_help.py selftest` | all assertions pass |
| 3 | **Relevance ranking + `--and/--or`** | `corpus-nav.py`, `niagara_help_lib/{find,guide}_search.py`, `niagara_help.py` | best-first; single-word unchanged |
| 4 | **Unified 3-source search** (FUENTE 1 blocks + 2 docs + 3 code), typed unavailable (never silent-zero) | `tools/find3.py` (new) | 3 sources return / typed `[!]` |
| 5 | **Semantic ranking** (TF-IDF cosine, pure-Python, ~1s/1005 blocks) | `corpus-nav.py semantic\|rank` | B1015/B736 rank high on concept queries |
| 6 | **`dashboard-preview --auto-mock`** (mock from the reader's slot arrays) + `--live` proxy | `tools/dashboard-preview.py` | 80-key mock auto-generated for UmbrellaDashboard |
| 7 | **build-n4 kit lints**: `lint-lexicon-ascii` (new), plano SKIP on 3D SPA, phantom-dep recognizes `project(:X)`, build.sh hints | kit `toolbelt/*`, `tests/*` | 58/58 bats, shellcheck OK, report-module CLEAN |

## Root cause + fix (the class)
Two independent tools matched the ENTIRE query as one literal case-insensitive substring (`query in line`), so any non-verbatim multi-word query returned zero. Fixed by tokenizing and matching by TERMS: corpus-nav = OR-any (small corpus, ranked); niagara_help = AND-per-file (huge doc corpus, no flood). Consolidated into ONE `textsearch.py` so it can never drift/re-appear, guarded by self-tests.

## Evidence (before → after)
- `corpus-nav find "BStatus overridden"` 0 → 50 (ranked). `guide-search "alarm fault"` 0 → 603. `devguide-search "servlet override"` 0 → 8. `find "setpoint override"` 19 → 209.
- `corpus-nav semantic "point health fault override status"` → B808/B1017/B736 top (BStatus concept surfaced by IDF weighting).

## Lessons
- The same search bug lived in TWO tools because search logic was duplicated — a shared core + self-tests is the systemic fix, not per-tool patches.
- Semantics should match corpus size: OR-ranked for ~1000 small blocks; AND-per-file for thousands of docs; TF-IDF cosine when you want concept-relevance without neural deps.
- A search tool must return a TYPED unavailable (tool missing/timeout/error) — never fold it into "no results", or a negative becomes a false "does not exist" (METHODOLOGY §wall).
- Neural embeddings were NOT available (no torch/sklearn/sentence-transformers); TF-IDF pure-Python keeps corpus-nav stdlib-pure and fast. True embeddings = a future dependency decision.

## Open follow-ups
- `find3` runs the 3 sources serially; `module_nav grep` is slow (~30–60s over 1046 files) → run the sources in parallel threads (proposed).
- Optional: neural-embedding `semantic` backend behind a flag if a local model is ever installed.

## Proposed kit deltas

| # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |
|---|---|---|---|---|---|
no new deltas; the kit already covers this run.
