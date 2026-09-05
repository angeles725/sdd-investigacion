# Design: research-sdd Kit Retro Campaign (Wave 1)

Store: hybrid (Engram twin `sdd/research-sdd-kit-retro-campaign/design`). Inputs: `proposal.md`, `exploration.md`.
Every file:line below was read on `4c100d8` before designing, not taken from the summaries.

**Correction to the proposal's Affected Areas**: templates live at `research-sdd/templates/`, NOT
`research-sdd/toolbelt/templates/`. `hook-sessionstart.sh`, `RESEARCH-STATE.template.md`, `block.template.md`,
`retro.template.md` are all under `research-sdd/templates/`. Tasks must use the real path.

## Technical Approach

Four architectural moves, in this order of authority:

1. **Doctrine declares a closed grammar; only then does a checker read it.** F3 is the single cause behind five
   substrates. D4/D6 land first; U2, U5, U7 and U3's metric sentence consume them.
2. **Every parser states its enumerator coverage.** A count is admissible only when the instrument can name the
   input forms it recognises, the forms it excludes, and the residue it could not classify (CLAUDE.md §7,
   false-negative direction). Three typed states everywhere: `absent-input` / `empty-input` / `no-match`, plus a
   fourth `error` state for a producer that failed (exit ≥2), which is what the `|| true` sites currently launder.
3. **One definition per concept.** `lib/block-files.sh` joins `lib/target-paths.sh`, `lib/retro-status.sh`,
   `lib/focus-prefix.sh`, `lib/state-files.sh` as an idempotent sourced helper with a fail-closed
   `declare -F` guard. No new lib pattern is invented.
4. **A refactor that must be byte-identical is proven by diff on the real fleet, not by fixtures** (issue #128).

## Architecture Decisions

### D-1: Header-NAME column selection, not positional, for the saturation parser

**Choice**: locate the `## Iteration history` header row, normalise each header cell, match it against a CLOSED
New-gaps header set, and use that index for every data row. **Rejected**: keep `a[n]` (last cell) — it is exactly
what makes the parser blind when the fleet's Notes column is last; widen to "any integer-looking cell" — that
resolves the wrong column silently, which is worse than a WARN.
**Rationale**: the blindness is a column-identification bug, not a cell-parsing bug; fixing cells first would
produce confident wrong numbers.

### D-2: A closed alias list for delta headings, never a wider regex

**Choice**: U7 recognises exactly the 4 measured non-canonical heading forms as DEPRECATED aliases (each emits a
migrate-me WARN) plus a distinct `no delta section` state. **Rejected**: widening the prose regex — measured
marginal fleet yield is 2 retros (exploration §2.1) and it inherits the prose's ambiguity.
**Rationale**: doctrine-first. D6 makes the countable declaration mandatory; the aliases are a bounded, sunsettable
migration ramp, not a permanent parser surface.

### D-3: `block_file_filter` is a stdin FILTER, not a `find` wrapper

**Choice**: one function that filters a stream of paths, so all three call-site shapes (find output, `git log`
output, and the negative/unclassifiable form) migrate through the same definition. **Rejected**: a
`block_files <dir>` enumerator — it cannot serve `research-sdd-archive.sh:260`, which filters `git log` output and
whose regex is deliberately `(^|/)`-anchored rather than `/`-anchored; two functions would recreate the drift.
**Rationale**: 15 strict sites + 1 inverse site collapse to one regex with one anchor.

### D-4: U10 lives in `skill-twin-parity.test.sh`, and resolves the home via `install/adapters.sh`

**Choice**: extend the existing SKILL.md twin-drift suite with a third twin — the installed copy — resolved by
`rsdd_field claude skill_path "${RSDD_INSTALL_HOME:-$HOME}"` (`install/adapters.sh:116-123` already takes `home`
as its third parameter). **Rejected**: (a) `verify-doc-consistency.sh` — its scope is METHODOLOGY↔SKILL section
citations, it is the one non-executable top-level script (U9 fixes that separately), and it feeds no hook;
(b) a new `verify-installed-skill.sh` — adds a script + suite and invites someone to wire it as a SessionStart
hook, which the operator decision of 2026-08-31 explicitly refused.
**Rationale**: `adapters.sh` already owns home-relative resolution, so U10 hardcodes no `~/.claude/...` path and a
fake `$RSDD_INSTALL_HOME` makes both the present and absent cases testable.

### D-5: U8 defaults to summary; `--full` restores today's bytes

**Choice**: `sweep-retros.sh --full` reproduces the current default output byte-for-byte; the new default omits the
per-retro `PENDING`/`target:` pairs and the per-target `absent-input` INFO lines. **Rejected**: `--summary` as an
opt-in — the 19,799-char cost is paid by every session, so the safe-by-default direction is the summarised one.
**Rationale**: the flag that changes nothing for a scripted caller must be the one they can pass explicitly.

### D-6: U8 splits measurement from optimisation

**Choice**: U8a is the output budget (summary mode + sentinel, no runtime change); U8b is a PROFILE REPORT only.
No optimisation is written until the profile names the hot phase. **Rejected**: optimising the obvious suspect (the
`rsdd_added_epoch` git call per block file — 763 invocations on niagara) in the same PR.
**Rationale**: CLAUDE.md §6 — probe viability before the writer. A guessed hot spot is how #128 cost 3.6 h.

### D-7: U11 lands BEFORE U2/U4/U7 and AFTER U1 (same-file locks)

**Choice**: see the lock table below. **Rejected**: the proposal's implicit "U11 is independent" — it is not:
U11 edits `research-sdd-status.sh` (5 sites), `verify-state.sh:322,328` (the exact region U2 rewrites) and
`sweep-retros.sh:291`.
**Rationale**: CLAUDE.md §3 disjointness is per FILE, not per region; two writers in one checkout also share the
index and the branch.

## Interface: `research-sdd/toolbelt/lib/block-files.sh`

```bash
# Idempotent, sourced-never-executed. Consumers MUST fail closed:
#   declare -F block_file_filter >/dev/null 2>&1 || { echo "<script>: helper failed to define block_file_filter" >&2; exit 1; }
#
# block_file_filter [-v] [<focus_prefix>]
#   stdin : one candidate path per line
#   stdout: the lines whose BASENAME is a canonical block file
#   exit  : grep's status VERBATIM — 0 match, 1 no-match, >=2 error (never laundered to 0)
#   -v    : inverse (the unclassifiable-candidate form at verify-registry.sh:373-374)
#   <focus_prefix>: interpolated EXACTLY as today (see the metachar note below)
#
# THE regex — one definition, replacing 15 hand-rolled copies:
#   no prefix : (^|/)[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$
#   prefix P  : (^|/)P(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$
```

**Anchor unification proof obligation.** 14 sites use `/…`; `research-sdd-archive.sh:260` uses `(^|/)…`. For any
stream produced by `find <dir> …` the basename is always preceded by `/`, so `(^|/)` ≡ `/` on those streams; the
migration is byte-identical only if that holds on the real corpora, so it is a diff obligation, not an assumption.

**Metacharacter note (deliberate non-change).** `${_fpfx}` is interpolated unescaped today
(`verify-state.sh:328`, `research-sdd-status.sh:394,557`). U11 preserves that exactly. Escaping it would change
output on a prefix containing a regex metachar — out of scope for a byte-identical refactor; filed as a follow-up.

**Also in U11**: `research-sdd-archive.sh:284` drops its `head -10 | grep '^review-status:'` parser and calls
`retro_review_status` / a new `retro_has_bare_marker` in `lib/retro-status.sh`, so the malformed-vs-absent WARN
split at :285-287 keeps its exact two message strings while reading ONE definition of "leading block".

## Per-unit design

Typed-state strings below are the exact literals to emit.

| # | File · region | Approach | Typed states (exact strings) | Teeth mutant → must flip |
|---|---|---|---|---|
| **U1** | `research-sdd-status.sh:112-143` (`iter_gaps_rows`, `saturation_line`) | Header row = first row in `## Iteration history` whose normalised cells (lowercase, strip `**`, collapse spaces) hit the closed New-gaps header set; record its index `k` and the `#` index `i`. Cell grammar, leading-token, in order: `^[0-9]+$`; `^([0-9]+)[[:space:]]+new\b`; `^(none|no|0)\b` incl. `none net-new …` → 0; `G<N>` list → count of distinct `G` tokens; `^(-|—|n/a)$` → n/a, excluded from the window and counted; anything else → `unrecognised`, counted AND named | `(no iteration history)` (unchanged) · `no New-gaps column (header: …)` · `insufficient history (N iterations)` (unchanged) · appended ` · distinct state `unreadable window — N of last 3 rows unrecognised (forms: …)` that does NOT compute on the readable subset; readable window with older unreadable rows appends `[WARN: N of M rows unreadable (forms: …)]`` when M>0, one `WARN: iteration-history New-gaps cell not recognised [<cell>]` per residue to stderr | Delete one header alias from the set → a fixture using that shape must report the no-recognisable-column state, not a number. Delete the `N new` cell rule → residue count must rise from 0 |
| **U2** | `verify-state.sh:309-331` | Under `block_scope: shared-global`, `ondisk` becomes blocks ATTRIBUTED to the focus, not `_ondisk_global`. Attribution set (per D4): the union of block numbers claimed by this focus's state file — `## Coverage` `B1..BN`/`B<k>` tokens and the `Block` column of `## Iteration history` — intersected with on-disk canonical block files by `blocknum()` (`verify-corrections.sh:31` grammar). Corpus total moves to an INFO line | `covered_blocks: <n> attributed (shared-global)` plus a separate INFO line `corpus total N (shared-global, informational)` · INFO `covered_blocks unverifiable under shared-global (no attributed block ids listed)` (MUST NOT FAIL) · existing `block_scope` absent/empty/illegal FAIL states unchanged | Make attribution fall back to `_ondisk_global` → the 6 sampled niagara focuses must FAIL again |
| **U3** | NEW `coverage-map.sh` + `tool-registry.md` row | Build `basename → module` index over the subject tree; DROP every basename mapping to >1 module (5,530 on niagara) and every basename shorter than 4 chars; scan block files (via `block_file_filter`) for each surviving basename with word-boundary matching (`\b`/`[^A-Za-z0-9_]` guards) so `Foo` never matches `FooBar`; a module is cited when ≥1 of its unambiguous basenames appears. Rank uncited by size — dependency centrality is NOT computable (2 `module.xml` fleet-wide) | `subject: absent-input (<path> not traversable)` · `subject: empty-input (0 class basenames)` · `no-match (N modules, 0 cited)` · always print `ambiguous basenames excluded: N` and `modules: <cited>/<total> cited · <uncited> never cited` | Remove the ambiguity exclusion → the 148 figure must move. Replace `\b` with substring → cited count must rise |
| **U4** | `research-sdd-status.sh:184-235` (`backlog_rows`, `resolve_next`) | Strip AT MOST ONE leading and one trailing `**` from the Status cell before `tolower` (§8b). Status leading-token vocabulary is closed: `pending`, `requires-execution`, `blocked-on-*`, `✅`, `~~`. Unknown token → stderr WARN + `INVALID_STATUS\t<token>` stdout sentinel, mirroring the existing `INVALID_PRIORITY` idiom exactly | `WARN: non-conforming status token [<tok>] — strip decoration per METHODOLOGY §8b; row excluded from investigable_open until migrated` · `backlog: unknown status [<tok>] in row: <row>` | Strip `**` greedily (all leading asterisks) → a `****pending****` fixture must stop being rejected. Remove the strip → the bold fixture's `--next` must revert to the medium row |
| **U5** | `verify-block.sh:80, 140-156` | Parse the `Type:` leading token against D6's closed domain; when the declared type is `synthesis` / `capture` / `absence-centred`, the P6 ZERO-citation WARN at :151 becomes an INFO line | `(no Type declared — P6 WARN applies; declare it per METHODOLOGY §4)` · `WARN: unrecognised block Type [<tok>] — closed domain is <…> per §4` · existing P6 WARN / doc-grade INFO strings unchanged | Mutant that ignores the token → the WARN must re-raise on a declared-synthesis fixture |
| **U6** | `tests/run-all.sh:96-112, 172-197` | Count teeth-banner lines per suite from the captured `$tmp_out`. Enumerator (measured, closed): `^[[:space:]]*(--|==)[[:space:]]*teeth\b`, case-insensitive — 249 banners across 56 `.sh` suites, of which exactly one uses `==` (`test-lane.test.sh:181`). CROSS-CHECK against the static `grep -l '"--prove-teeth"'` set (78 files) so "implements teeth but prints no banner" is a DISTINCT state from "no teeth at all". `.mjs` suites: forward nothing (they have no flag) but classify them under `n/a (node suite — teeth always run)`, never as silent zeros. Opt-in `--require-teeth` exits 1 when the without-teeth list is non-empty | Under `--prove-teeth` only, after `Suites skipped:`: `Suites without teeth: N — [name, name, …] (vocabulary check: a "teeth" case with no real mutant is a review item)` · `Suites with teeth but no banner: N — [names]` · `Suites n/a for teeth (node): N` · under `--require-teeth`: `FAIL: --require-teeth and N suite(s) have no mutation control` | Add a stub suite that greps `--prove-teeth` and prints no banner → it must land in the banner-less bucket, not the with-teeth bucket. Remove the `==` alternative → the banner count must drop by exactly one suite |
| **U7** | `sweep-retros.sh:124-196` | Add the distinct no-delta-section state; add the 4 measured DEPRECATED heading aliases (`## Summary of proposed deltas`, `## Summary of new deltas proposed`, `## Delta details`, `## <N>. PROPOSED kit deltas for the next version …`) each WARNing to migrate; surface retros with NO review-status marker (5/30 today) via `retro_review_status` returning empty | `~0 proposed deltas` becomes `no delta section found (empty-input)` for a PENDING retro with zero indicators · `WARN: deprecated delta heading [<h>] — migrate to '## Proposed kit deltas' per §18` · `WARN: no review-status marker — add '<!-- review-status: pending -->'` · existing WARN-A/WARN-B `?` strings unchanged | Remove the no-delta-section branch → the 4 known retros must revert to a confident `~0`. Remove one alias → its retro must drop back to `?` |
| **U8a** | `sweep-retros.sh:224-239`, `verify-tool-catalog-hook.sh:44` | Default = summary. `Summary:` line at :233 stays BYTE-IDENTICAL in both modes. Summary mode prints only the oldest 5 PENDING rows, then `… and N more — run sweep-retros.sh --full`. Absent targets collapse to ONE counted line. `--full` reproduces today's default exactly. `verify-tool-catalog-hook.sh` emits a one-line declared-clean sentinel instead of 0 bytes | `INFO: N target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.` · `Research-SDD tool catalog: clean (N logged tools, 0 uncataloged).` | Force summary mode with 0 pending → the sentinel/collapse lines must still print (a silent clean run is the defect) |
| **U8b** | `sweep-retros.sh` (measurement only) | `RSDD_PROFILE=1` accumulates wall time per phase to stderr: `pending-pass`, `waiver-pass`, `retro-newest-pass`, `block-newest-pass` (:288-291, one `git log` per block file), `total`. Deliverable is the profile TABLE and a go/no-go, not an optimisation | `profile: <phase> <seconds>` lines; `profile: unavailable (no EPOCHREALTIME)` when bash <5 | Suppress one phase timer → the phase sum must stop reconciling with `total` |
| **U9** | `verify-kit-clean.sh:29-34`; `.gitignore`; `verify-doc-consistency.sh` mode; `templates/hook-sessionstart.sh:28` | Capture each counter's rc instead of `|| true`; DIRTY with all three counters 0 while `$porcelain` is non-empty is a provable contradiction. Add `.claude/worktrees/`. `chmod 100644→100755` (class of #417). Replace the hardcoded kit path with a `<KIT>/toolbelt/` placeholder plus a resolution sentence — the artifact is COPIED to other machines | `WARN: DIRTY but all three counters read 0 — porcelain has N line(s); counters disagree` · `WARN: <counter> count FAILED (grep exit R) — cleanliness report incomplete` | Reintroduce `|| true` on one counter and stub `grep` to exit 2 → the contradiction WARN must disappear (test asserts it does not) |
| **U10** | `tests/skill-twin-parity.test.sh` | Third twin = installed copy at `rsdd_field claude skill_path "${RSDD_INSTALL_HOME:-$HOME}"`; also the OpenCode twin already at `../opencode/SKILL.md`. Report drift BY HUNK (`diff -u … \| grep -c '^@@'`) | `installed copy: absent-input (<resolved path> not found) — drift check skipped` · `installed copy: DRIFT — N hunk(s) / M line(s) behind the kit copy` · `installed copy: in sync` | Point `RSDD_INSTALL_HOME` at a fixture home holding a deliberately stale copy → the suite must report the exact hunk count; point it at an empty home → the absent-input line must print, and the suite must NOT report `in sync` |
| **U11** | `lib/block-files.sh` (new) + 15 strict sites + 1 inverse + `research-sdd-archive.sh:284` | See the interface above. Sites: `research-sdd-status.sh:391,394,397,557,560`; `research-sdd-archive.sh:200,238,260`; `verify-state.sh:322,328`; `verify-registry.sh:209` and the inverse at `:373-374`; `verify-parity.sh:68`; `verify-corrections.sh:27`; `sweep-retros.sh:291`; `sweep-breakthroughs.sh:116` | `<script>: helper lib/block-files.sh failed to define block_file_filter` (fail-closed, exit 1) · `block-files: cannot read stdin` | Change the anchor to `^` only → `discriminator-parity.test.sh` must go red. Make `[^/]+-` optional → a `blocked-notes.md` decoy must be counted |
| **U12** | 8 unguarded `\|\| true` after real producers | `verify-sources.sh:79`; `scan-secrets.sh:127`; `sweep-tools.sh:133,148`; `sweep-tools-hook.sh:45`; `verify-tool-catalog-hook.sh:47`; `verify-block.sh:257,260`. Pattern at every site: capture rc, then classify — rc 1 is a legitimate `no-match`/`empty-input`, rc ≥2 is `error` and MUST surface | `verify-sources.sh`: `-- SOURCES.md present · registered data rows: 0 (no-match — N table line(s), all header/separator)`, `… (empty-input — no table lines)`, `WARN: SOURCES.md row scan FAILED (grep exit R) — row count unavailable` · `scan-secrets.sh`: `WARN: NUL-byte count FAILED (grep exit R) — count unavailable` (never 0) · `sweep-tools.sh`: `WARN: N retro(s) unreadable during T-row scan (grep exit R)`, `ledger_status="error"` · both hooks: append `(WARN-line extraction failed: grep exit R)` to the emitted detail · `verify-block.sh`: `(scan INCOMPLETE — grep exit R; OCR-lossy check unreliable)` replacing `(none — …)` at :268 | Per site: stub `grep` to exit 2 and assert the `error` string appears AND the run does not report a confident 0. Restoring `\|\| true` must make each assertion red |

**Doctrine units (explorador, doc-only).** D1 §20+§7; D2 DYNAMIC-SETUP §1c + new `toolbelt/DEPLOY-WINDOWS-MINIPC.md`
+ tool-registry rows; D3 PROMPT-LOOP SYNTHESIS-GUIDE + SECRETS; **D4** §16 FOCUSES status grammar (closed
vocabulary, §8b style) + shared-global `covered_blocks` attribution rule + global block-number allocation +
peer-owned-dirty-tree + shared-checkout guard; D5 §3 marker taxonomy DECISION; **D6** §18 countable-delta
declaration MANDATORY + retro trigger extension + §4 `Type` grammar + §8 coverage-over-the-subject paragraph +
New-gaps cell grammar sentence. D4 and D6 each declare a CLOSED vocabulary the paired instrument then reads
verbatim; the vocabulary lives in doctrine, never in the script's regex comments.

## Ownership, file locks and sequencing

Two writers, disjoint file sets (mejorador = `toolbelt/**` + `tests/**` + `templates/**`; explorador = doctrine
`.md` only). Within mejorador, these files carry MULTIPLE claimants and MUST be serialised:

| File | Claimants | Serial order |
|---|---|---|
| `research-sdd-status.sh` | U1, U11, U4 | U1 (in flight) → U11 → U4 |
| `verify-state.sh` | U11, U2 | U11 → U2 |
| `sweep-retros.sh` | U11, U7, U8a, U8b | U11 → U7 → U8a → U8b |
| `verify-block.sh` | U12, U5 | U12 → U5 (U5 also waits on D6) |
| `verify-tool-catalog-hook.sh` | U12, U8a | U12 → U8a |
| `research-sdd-archive.sh`, `verify-registry.sh`, `verify-parity.sh`, `verify-corrections.sh`, `sweep-breakthroughs.sh` | U11 only | — |
| `tests/run-all.sh` | U6 only | — |
| `verify-kit-clean.sh`, `.gitignore`, `templates/hook-sessionstart.sh` | U9 only | — |
| `coverage-map.sh` (new), `lib/block-files.sh` (new) | U3 / U11 | — |

```
D1 D2 D3 D5 ──(inert doctrine, any time)
D4 ──────────────────────────► U2
D6 ──────────────► U5 · U7 · U3(metric sentence)
U6 ─(re-baseline)─► every later gate report
U1 ─► U11 ─► U4
       └───► U2 (after D4)
       └───► U7 (after D6) ─► U8a ─► U8b
U12 ─► U5 (after D6)
U9 · U10 · U3 — no file lock, fully concurrent
```

**U6 re-baseline**: U6 changes the `--prove-teeth` aggregate block. It lands EARLY (no file conflicts, opt-in
failure mode) so every subsequent unit's gate report already carries the teeth accounting and any new suite
without mutants is visible the moment it lands. Every gate report produced BEFORE U6 is not comparable to one
produced after; state the U6 baseline commit in each report.

**Gate discipline** (CLAUDE.md §3): writers with disjoint locks run CONCURRENTLY; ONE gate run on a quiet tree
afterwards. `--prove-teeth` mutates only temp-dir copies, so it does not serialise writers. Reject any report
shaped "no failures among the suites that completed" — demand the full aggregate line.

## What must stay byte-identical (regression fixtures, written BEFORE the change)

| Contract | Guarded against | Owner |
|---|---|---|
| `research-sdd-status.sh --next` output for every existing fixture | U1, U4, U11 | U1 lands the golden; U4/U11 re-assert it |
| Exit codes of all 9 touched instruments on the existing fixture corpus | U1–U12 | each unit |
| `run-all.sh` default (no-flag) aggregate block, line for line | U6 | U6 — the new lines print ONLY under `--prove-teeth` |
| `verify-state.sh` per-focus output on non-shared-global targets | U2, U11 | U2 |
| Every discriminator site's enumeration on the REAL corpora, before vs after | U11 | U11 — extraction merges only when the diff is empty |
| `sweep-retros.sh --full` == today's default output | U8a | U8a |
| `Summary:` line of `sweep-retros.sh` in BOTH modes | U7, U8a | U8a |
| `discriminator-parity.test.sh` FAMILY 1 / FAMILY 2 classification | U11 | U11 |

## Fleet acceptance recipe (per unit — fixtures are NOT acceptance)

Corpora: `niagara-research` (763 blocks, shared-global, 70 state files fleet-wide) and `panccadia-3d-viewer`.
Recipe for every instrument unit:

1. `git stash` / worktree the `main` build; run the instrument over every resolvable `TARGETS.md` path; save stdout+stderr.
2. Run the changed build over the same set; `diff` the two captures.
3. Partition EVERY new WARN and EVERY exit-code flip by hand into `true` / `false`. Zero unclassified.
4. Record the expected partition in the PR body.

| Unit | Command | Expected partition |
|---|---|---|
| U1 | `research-sdd-status.sh` over all 70 state files; header census via `awk '/^## Iteration history/{f=1;next}/^## /{f=0} f&&/^\|/' "$f" \| head -1 \| sort \| uniq -c` | BLIND 35 → 0, or every residue NAMED; 0 new false WARN |
| U2 | `verify-state.sh` over 6 sampled niagara focuses + 2 non-shared targets | 6/6 FAIL → PASS; non-shared byte-identical |
| U3 | `coverage-map.sh` on niagara + panccadia | reproduces 148 uncited / 170 cited / 5,530 ambiguous |
| U4 | `--next` over all 70 state files | bold-`**pending**` rows now resolve; new `INVALID_STATUS` lines all hand-classified |
| U5 | `verify-block.sh` over 763 niagara blocks | 8 declared-Type blocks change class; the other 755 byte-identical |
| U6 | `run-all.sh --prove-teeth` on a quiet tree | 22 named without teeth; default run byte-identical; `--require-teeth` exits 1 |
| U7 | `sweep-retros.sh` over 99 fleet retros | 4 confident zeros → typed state; 9 aliased headings counted; 5 unmarked surfaced; 78-pending total unchanged |
| U8a | `sweep-retros.sh` vs `--full`; hook char count | <3 k chars from 19,799; `--full` diff empty |
| U9 | `verify-kit-clean.sh` on a dirty and a clean tree | hook stops reporting permanent NOT-clean |
| U10 | suite with real `$HOME`, a stale fixture home, and an empty fixture home | 15 stale lines / 5 hunks detected today; empty home → absent-input, not `in sync` |
| U11 | each of the 16 sites, old vs new enumeration, both corpora | diff EMPTY at all 16; anything non-empty blocks the merge |
| U12 | each site with a `grep` stub exiting 2 | 8/8 surface `error`; 0/8 report a confident zero |

## Threat Matrix

| Boundary | Applicability | Design response | Planned RED tests |
|---|---|---|---|
| Documentation-like paths | **Applicable** — the block discriminator classifies `.md` files, and `templates/hook-sessionstart.sh` is an executable artifact copied to other machines | `block_file_filter` is basename-anchored and rejects decoys (`blocked-notes.md`); U9 removes the absolute kit path from the copied hook and U9 fixes the one 100644 top-level script | Decoy names (`blocked-notes.md`, `block1.md`, `x-block1.markdown`) must NOT classify; the copied hook must contain no absolute path outside a placeholder |
| Git repository selection | **Applicable** — `git -C "$root"`/`git -C "$p"` in `verify-kit-clean.sh:23,30-32`, `sweep-retros.sh:208,259`, `research-sdd-archive.sh:262` | `-C` with an explicit dir is preserved at every site; U12/U9 capture rc rather than laundering it; U8b's profiler must not change any `git` invocation | Non-git target dir → fallback path, no crash; `git` stubbed to exit non-zero → typed `error`, never a confident 0 |
| Commit state | **Applicable** — U9 reads staged / unstaged / untracked counters | The three counters are cross-checked against `git status --porcelain`; disagreement is a WARN + rc 1 | Empty index with a dirty worktree; staged-only; untracked-only; all three zero with non-empty porcelain (the contradiction case) |
| Push state | N/A — no unit changes `verify-kit-clean.sh`'s upstream/ahead logic (`:42-52`) and nothing pushes | — | — |
| PR commands | N/A — no unit composes `gh`/PR commands; PR creation stays operator work | — | — |

## Migration / Rollout

Auto-chain, issue-first, one PR per unit closing exactly one issue, ≤~300 authored lines. Doctrine PRs are inert
until their instrument lands, so they merge ahead freely. `--require-teeth` (U6) and `--full` (U8a) are opt-in, so
no existing caller changes behaviour. No data migration; corpora are read-only (propose-never-apply).
Rollback = `git revert` of the single merge commit.

## Open Questions

- [ ] D6's `Type` closed domain must be fixed before U5 is written — today's 8 adopters use `evidence`,
      `synthesis`, `document`, all outside the template's domain. Does D6 adopt the observed values or the
      template's? U5 cannot be specified until this is answered.
- [ ] U2's attribution set (D4) — does a focus's `## Coverage` `B1..BN` range claim blocks that another focus in
      the same shared-global corpus also claims? If ranges can overlap, `covered_blocks` needs a tie-break rule.
- [ ] Escaping `${_fpfx}` before regex interpolation is deferred out of U11 (byte-identical mandate). Needs its
      own issue.
- [ ] This artifact exceeds the skill's generic 800-word budget by design: the orchestrator's brief mandates
      per-unit parsing approach, exact typed strings, teeth mutants and acceptance recipes for 18 units under a
      ~400-line ceiling. Recorded rather than silently compressed.
