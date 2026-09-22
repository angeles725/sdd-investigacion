# ODD feature — kit-consistency-cleanup

**Created**: 2026-09-22
**Repo**: sdd-investigacion (research-sdd kit) · branch point `61c79bf` (= origin/main at creation)
**Engram mirror**: `odd/kit-consistency-cleanup/tasks`

---

## Objective

Close the three items the 2026-09-22 session deferred (#881 retro headings, stale RESEARCH-STATE
on kit + blender-llm, `printf` option-injection in the status test suite), then run a fleet audit
for what else is escaping supervision.

## Problem

Three deferred follow-ups, plus two defects found during this session's exploration that change
the shape of the work:

1. **#881 is misdiagnosed.** The issue claims the kit retro's 6 deltas are "in PROSE, not the
   canonical table". False — the file carries a well-formed 6-row markdown table. The only defect
   is the heading (`## Proposed research-sdd deltas …`), which matches no pattern in
   `lib/retro-grammar.sh` because the canonical form requires `kit` immediately after `proposed`.
   The fix is a heading rename, not a prose extraction. Same for the niagara peer retro.
2. **The kit retro is in the wrong directory.** The kit's retros live in `retros/` (5 tracked
   files); `2026-09-20-concurrent-chains-and-correlation-doctrine.md` was written to
   `research-sdd/retros/` — the kit *payload* directory — so it is untracked and it is why
   `sweep-retros` counts 6 retros against a `TARGETS.md` row declaring 4.
3. **`verify-state.sh` SC-CROSS-CHECK has a parser bug.** It reads the prose Stop-control number
   with `grep -oE '[0-9]+' | tail -1` — the LAST number on the line, not the field's value. The
   kit's own line reads `- **Open gaps — read-only investigable**: 3   ← static loop stops when
   this hits 0`, so the extractor returns `0` and the gate FAILs. Verified by running the pipeline
   inline: it prints `0`. **The kit's "stale RESEARCH-STATE" is a false positive of our own gate.**
   blender-llm's FAIL is genuine, but its message reports "prose 74" (grabbed from `G74`).
4. **The `printf` bug is not cosmetic.** All 18 sites write nothing (`printf: - : invalid option`,
   exit 2), so the Stop-control prose line is absent from those fixtures and **SC-CROSS-CHECK is
   silently skipped for all 18** — an anti-silent-zero (§7) blind spot inside the test suite.

## Why

An audit issue written by a prior session is unverified evidence. Re-deriving #881 from the code
changed the work and exposed a live false positive in an instrument the loop trusts. A gate that
cries wolf on a healthy target teaches the operator to ignore it — the same trust damage §7
describes for false negatives.

## Scope (authorized)

- **Kit repo** (`sdd-investigacion`): edit, commit, push, PR, merge.
- **Peer repos** (`niagara-research`, `blender-llm`): edit, commit and push — user-authorized
  2026-09-22 in answer to a blocking question. Both trees were clean at authorization time.
- Out of scope: broadening `retro-grammar.sh` to accept `proposed <qualifier> deltas`
  (METHODOLOGY §18 declares the alias list a CLOSED enumeration; fleet incidence is 2/131).

## Constraints

- Strict TDD (kit contract §4): RED first, executed against the pre-fix SUT — not asserted in a
  comment; then GREEN; then a mutation control that goes red.
- Runner: `bash research-sdd/toolbelt/tests/run-all.sh` (+ `--prove-teeth`). Source: CLAUDE.md §4/§5.
- Gate runs need a QUIET tree — no concurrent writer editing during the run (§3).
- English for all artifacts. Conventional commits, no AI attribution.
- `propose-never-apply`: kit TOOLS never auto-edit targets. These are human-authorized hand edits.

## Delivery

- Forecast: ~150 authored changed lines (additions + deletions) across all tasks — under the
  ~400-line budget, so **one chain, no PR split**. Strategy: `ask-on-risk` (default).
- RDD is **ON** (global). Per work-unit commit: `gentle-ai review assess --cwd <repo>
  --base-ref <last reviewed boundary> --committed-only --json`, then route by tier. User
  pre-authorized answering `granted` to the consent envelope.
- First reviewed boundary: `61c79bf`.

## Tasks

| ID | Task | Status |
|---|---|---|
| T1 | Move the kit retro to `retros/`, normalize heading + title | ☑ merged #883 |
| T2 | Seed the 10 deltas as backlog-first issues | ☑ #892–#897 (kit), #888–#891 (niagara) |
| T2a | Fix `stage-retro-issues.sh` stray `**` in titles | ☑ merged #886 |
| T2b | Create the missing `target:sdd-investigacion` label | ☑ done — it never existed; the kit's own retros could not be seeded |
| T3 | Normalize the niagara peer retro (3 FAILs, not 1) | ☑ pushed `f8e06e0d9` in niagara-research |
| T4 | `verify-state.sh` SC-CROSS-CHECK extraction | ☑ merged #884 |
| T5 | 18 `printf` sites + prove SC-CROSS-CHECK fires | ☑ merged #885 (RDD-reviewed, bounded correction applied) |
| T6 | Reconcile `blender-llm` RESEARCH-STATE | ☑ pushed `81efc2e` — exit 0. niagara split out to #901 (never in the chartered scope) |
| T7 | Doctrine: heading is matched literally | ☑ merged #899 |
| T8 | Close #881 with the corrected diagnosis | ☑ closed |
| T9a | `verify-retro` em-dash + `target_paths_all` silent zero | ☑ merged #887 |
| T9b | `derive_blocked` prose entries ☑ #898 · `_section` third heading ☑ #900 | ☑ |
| T9c | File the untriaged audit findings as backlog issues | ☑ #901 #902 #903 #904 |

**Delivery:** 8 PRs merged (#883–#887, #898, #899, #900). `origin/main` 61c79bf → 9607890. Each PR one
work unit, all well under the 400-line budget, each diff verified to contain only its own unit.

### T9 seeded audit candidates (found during exploration, not yet triaged)

- `derive_blocked()` in `verify-state.sh` only counts `- … needs:` BULLETS; blender-llm writes
  blocked gaps as prose paragraphs, so G54 is invisible. Same §7 false-negative family as T4.
- 26 of 131 accessible retros carry a non-conforming delta heading (form-3, Rule-2, or none).
  Only 2 were in #881's scope. What are the other 24 costing us?
- 7 of 12 registry targets were **not traversable** on this machine — every fleet number above is
  scoped to 131 retros in 5 targets and cannot speak for the rest.
- `TARGETS.md` carries 8 count drifts, 6 retro drifts, 17 unresolvable rows, 5 oversized rows
  (SessionStart hook output) — all WARN-only, none failing, i.e. exactly the shape §7 warns about.
- 181 of 236 fleet tools are unrecorded in the tool ledger.
- 74 pending retros / 191 across targets, several ESCALATED past 45 days.
- 3 tagged breakthroughs, all 3 unindexed in `BREAKTHROUGHS.md`.
- The kit has never tracked a retro under `research-sdd/retros/` — is that path a trap that will
  catch the next author too? (T1 is one instance; the directory should arguably not exist.)
- **`verify-retro.sh`'s header check demands a typographic em-dash.** `retros/2026-08-03-…md`
  carries `# Retro - sdd-investigacion / …` with an ASCII HYPHEN and is reported as
  `FAIL [header-missing]: no "# Retro —" title line found` — the title line is right there. Same
  §7 family as T4: the instrument does not recognise a form its corpus actually uses, and the
  message misdescribes the defect. Fix the checker, not the retro.
- **Sourcing `lib/retro-grammar.sh` from zsh silently defines nothing.** The idempotency guard is
  `if ! declare -F retro_grammar_delta_info` and `declare -F` means something else in zsh, so the
  body is skipped and the caller gets `command not found`. Harmless today (every consumer has a
  bash shebang) but the documented fail-closed guard does not fail closed under zsh. Confirm
  whether any consumer can be sourced from an interactive zsh before deciding it is a non-issue.

### T9 findings confirmed during execution

- `verify-retro` on the 6 kit retros: 4 conforming, 2 FAIL — one is T1 (fixed), the other is the
  em-dash false positive above.
- The niagara retro was missing its `review-status` marker entirely. #881 described only the heading.

#### Hypothesis TESTED AND REJECTED — marker-less retros are NOT invisible

I suspected `sweep-retros` could only see retros that carry a marker, which would make every
marker-less retro silently count as resolved. **Measured, and it is false.** Of 195 retro files
under the 17 traversable targets, 37 carry no `review-status` marker, and **36 of those 37 are
reported PENDING with `status: none`** — the sweep handles the case correctly.

The one file never reported is
`niagara-research/examinacion-optimizer-4.13/retros/2026-09-14-optimizer-4.13-run-retro.md`, and
it opens with `<!-- kit-retro: exclude -->` — a deliberate operator exclusion, working as designed.

The 195-vs-191 count difference between my enumerator and the sweep's summary is **dedup**: the
sweep dedups by canonical path so a retro reachable under two overlapping registry targets counts
once; my throwaway enumerator did not. Not a coverage gap.

Recorded because a rejected hypothesis is a result: this area does not need work, and the next
audit should not re-open it.

### T9 findings CONFIRMED real (as of this session)

1. `verify-retro.sh` header check requires a typographic em-dash → false `header-missing` on
   `retros/2026-08-03-…md`, whose title line exists with an ASCII hyphen. **Not yet fixed.**
2. `target_paths_all` called with NO argument returns an empty list and exit 0 (silent zero).
   **Not yet fixed.**
3. `stage-retro-issues.sh` issue titles keep a stray `**` (9 issues already affected) — T2a.
4. `verify-state.sh` SC-CROSS-CHECK number extraction — T4.
5. 18 `printf` sites disabling SC-CROSS-CHECK in fixtures — T5.
6. `lib/retro-grammar.sh` sourced from zsh defines nothing (guard uses bash-only `declare -F`).
   No consumer is affected today; lowest priority of the six.

## Integration risk — T4 ↔ T5 coupling (check at the gate)

T5's new `teeth-SC-CROSS-CHECK` builds a fixture with NO Stop-control prose line and asserts
`verify-state.sh` stays **silent**. T4 was explicitly asked to give a verdict on whether a
field line with no parsable value should keep being silently skipped or should become a typed
§7 signal. **If T4 rules that absent/unparsable must warn, T5's tooth flips to failing.**

That is not a defect in either unit — it is two correct units disagreeing about a behaviour
neither owns alone. Resolve it at the integration gate, on a quiet tree, before merging either:
decide the §7 semantics once, then make the tooth assert the decided behaviour.

Also noted on T5: the tooth does not mutate a SUT, so by the kit's own vocabulary check
(`run-all.sh`: "a 'teeth' case with no real mutant is a review item") it is a control, not a
mutant. Accepted because the writer produced an EXECUTED red for the test itself, which is the
stronger evidence — but it is recorded here rather than passed over silently.

## Acceptance criteria

- `reconcile-issues.sh` reports a delta section with the right row count for both normalized retros.
- `verify-state.sh` passes on the kit target without editing `RESEARCH-STATE.md` to dodge the bug,
  and still FAILs on a genuinely stale fixture (proved by a mutation control).
- The 18 fixtures actually contain the Stop-control line, and at least one test asserts
  SC-CROSS-CHECK fires on a mismatching fixture (a test that could not have passed before).
- Full gate green on a quiet tree: `run-all.sh` and `run-all.sh --prove-teeth`, aggregate line
  quoted in full — not "no failures among the suites that completed".
- Shellcheck clean: `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh`.

## Progress log

- 2026-09-22 — feature document created after exploration (2 read-only mappers). Peer-repo
  authority granted by the user. Nothing written yet.

## Progress log (continued)

- 2026-09-22 — T1/T3 done inline; T4/T5/T2a delegated to three concurrent worktree writers.
- RDD fired on T5's candidate (tier high). Consent envelope relayed; user had pre-authorized
  `granted`. Four lenses ran concurrently; `correction_required`. Findings had to be read from
  `.git/gentle-ai/review-transactions/v2/<lineage>/review-state.json` — **no `gentle-ai review`
  read command exposes them**. Bounded correction: 29 lines against a 44-line frozen budget.
  Approved, acknowledged, authority burned.
- Full gate on a quiet tree, then again on merged main: `123/123 suites · 2556 cases · 0 failed`;
  shellcheck zero warnings over 204 files.
- Audit found 6 confirmed defects, 5 fixed. The §7 false-negative family dominated: four separate
  instruments recognised only the forms their author imagined and reported confident low numbers.

## The pattern worth keeping

Every instrument defect this session was the same shape: **a confident number the instrument had
not earned.** `verify-state` read the last number on a line; `verify-retro` denied a title line
that was present; `target_paths_all` returned an empty list for a file it never opened;
`derive_blocked` counted only the entry shape its author had seen, and then only under the heading
its author had seen; `stage-retro-issues` truncated a title mid-markup.

The costly one was `derive_blocked`, because `blender-llm`'s envelope had been **re-seeded to agree
with the broken derivation**. The instrument taught the document to record a falsehood, and the
proposed "reconciliation" was to edit the prose to match. Verify a reported reconciliation against
the corpus before applying it: making the record agree with the instrument is only safe when the
instrument was right.


## Close — 2026-09-22

**Done.** All three deferred items closed, plus an audit that found six instrument defects and
fixed five of them.

- 8 PRs merged, `origin/main` 61c79bf → 9607890, re-verified after merge each time.
- Peer repos: niagara retro `f8e06e0d9`, blender-llm state `81efc2e`, both pushed.
- 10 deltas seeded (#892–#897, #888–#891); #881 closed with a corrected diagnosis.
- Remaining findings filed rather than dropped: #901 #902 #903 #904.

**Gate of record** (quiet tree, merged main): `123 suites run · 123 passed · 0 failed · 0 skipped ·
2558 cases passed · 6 skipped · 0 failed`. shellcheck zero warnings over 204 files. The 21
teeth-less suites are the known #426 forensics/VM debt; none of the suites touched here.

**Not done, deliberately:**
- niagara's `RESEARCH-STATE` needs a judgement the instrument cannot make (is a
  `requires-execution` gap inside a "Blocked / non-read-only" section blocked or not?) plus an
  unrelated `covered_blocks` drift of 266 vs 1151. → #901. It was never in the chartered scope;
  the instrument fix merely revealed it.
- blender-llm's G54 carries `needs:` with no `tried:`. Documenting what was attempted is research
  work, not a number to adjust, so the WARN stands.
- The 9 pre-#886 issue titles are left alone — rewriting them is a maintainer decision. → #904.
