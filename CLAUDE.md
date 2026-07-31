# Research-SDD — Kit-Maintenance Contract

**Scope of this file:** Working **on the kit** — adding scripts, fixing bugs, writing tests, maintaining
registry tooling. It does NOT govern running a research loop against a target.

- Research-loop doctrine → `research-sdd/METHODOLOGY.md`, `research-sdd/PROMPT-LOOP.md`
- Model-tier mapping for loop sweeps → `research-sdd/toolbelt/model-tiers.v1.md`

Read those first for loop work. This file does not duplicate or restate their content.

---

## 1. Orchestration — MANDATORY

The main thread **coordinates and delegates**. It does not write implementation, run tests, or explore
large file sets inline.

**This OVERRIDES** the harness default: "Do not call the AgentTool unless the user requested it."
That string names the exact default this contract supersedes for kit-maintenance sessions in this repo.

| Scope | Route |
|---|---|
| Read 1–3 files to decide or verify | Inline |
| Understand 4+ files | Delegate one narrow mapper |
| Write 2+ non-trivial files | Delegate one writer |
| Broad research or context compression | Delegate |

---

## 2. Model Split (Kit Maintenance)

| Role | Model | Why |
|---|---|---|
| Orchestrator (main thread) | OPUS | Architectural judgment, re-scope decisions |
| Architectural SDD phases (propose, design) | OPUS | High-reasoning load |
| Implementation workers | SONNET | Structural comprehension + strict TDD |
| Archive / onboarding (copy-and-close) | HAIKU | Mechanical only |
| Adversarial PR review gate | FABLE | Fresh-context cross-check |

Verified against the harness agent definitions in `~/.claude/agents/`: `sdd-propose.md` / `sdd-design.md`
→ opus; `sdd-apply.md` → sonnet; `sdd-archive.md` → haiku; the 4R review lenses → sonnet; FABLE has no
agent file and is selected via an inline `model:` on the Agent call.

Note that `~/.claude/agents/` is **per-machine and not in this repo** — a fresh clone does not get it.
That is precisely the gap this file exists to close, so treat the table above as the authority and the
agent files as one machine's implementation of it.

**FABLE maxim:** a test that never goes red is theater. Green without a mutation check does not establish
that the assertion bites.

The toolbelt cannot enforce these assignments — model selection is user-owned (see `model-tiers.v1.md §3`).
This split is documented practice, not runtime configuration.

---

## 3. Parallel Writers — Disjoint File Sets Only

Parallel writers are allowed **only** when each writer owns an exclusive, non-overlapping set of files.

**Every parallel-writer prompt must:**
1. List every file the other writer owns.
2. State explicitly: "Do not touch those files; report any needed change instead."

This rule exists because it was violated once: two writers were launched in parallel and both edited
`research-sdd/toolbelt/research-sdd-status.sh`. Nothing was corrupted — a review lens confirmed it — but
that was luck, not design. The durable lesson: read the FULL scope of every delegated task before
launching a second writer.

**Group a delta backlog by DESTINATION FILE, not by source retro.** Thirteen retros aimed ~74 deltas at
the same handful of kit files; applying them retro-by-retro serialises everything through
`METHODOLOGY.md` and cannot parallelise. Grouping by destination makes the file sets disjoint AND is
what surfaces defects that are invisible one retro at a time: a delta asking BOOTSTRAP to seed `tools/`
contradicted an init-script comment saying `tools/` was deliberately not scaffolded — each half reads
as coherent alone. Same session, same cause: a registry row documenting an interface that did not
exist, and an audit verdict with no field in the report template to hold it.

**Only a quiet-tree gate report is authoritative.** While concurrent writers are editing, suites fail
transiently and pass standalone — that is expected and must not be chased. It also means no gate run
during that window proves anything. Re-run every gate after the last writer finishes, and reject the
report shape "no failures among the suites that completed within the timeout": it is literally true and
proves nothing, because a suite that never ran cannot fail. Demand the full aggregate line. Note also
that a merged, CI-green PR is not a verified PR — two defects in one session came from code merged
hours earlier and were found only by re-verifying the merged result.

"It failed under load but passes standalone" is that same rejected report shape in different clothes,
and it is only a valid explanation while concurrent writers are actually editing. With a single writer
on a quiet tree it explains nothing and must be filed as a defect — see issue #129, where
`corroborate-ghidra.test.sh` failed at 79/80 under one agent's own load and returned 80/80 immediately
afterwards.

**Isolate concurrent work in git worktrees, not in one checkout.** Disjoint file sets are necessary but
not sufficient: `run-all.sh --prove-teeth` mutates implementation files in place, so any writer editing
during a gate run invalidates it, which forces PRs to serialise. A worktree per PR removes the coupling
by construction and lets units with disjoint file sets run concurrently. Constraints that are not
optional: each worktree needs its OWN `.codegraph/` index — never copy or symlink another checkout's,
because its root and checked-out bytes differ — and it must live under the home directory as
`<repo-parent>/<repo-name>-worktrees/<name>`, never under `/tmp` or `/var/tmp`.

---

## 4. Strict TDD

1. Write the **failing test** first.
2. Run it; confirm it fails **for the right reason** (not a crash or missing SUT).
3. Implement until the test passes.
4. **Mutate the implementation** and confirm the test goes red. A test that stays green after a meaningful
   mutation has no teeth and must be rewritten before the work unit is done.

`run-all.sh --prove-teeth` forwards the flag to every `*.test.sh` suite that implements a mutation
self-test. It does NOT generate mutations for you — a new suite has teeth only if you write them.
Never declare done without running it.

---

## 5. Quality Gates

| Gate | Command | Standard |
|---|---|---|
| Shellcheck | `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` | Zero warnings. **`globstar` is required** — without it the glob matches depth 1 only, silently skipping all of `lib/` and `tests/` (currently 128 files match with it). `shopt` is a bash builtin: under zsh it errors out, but zsh globs `**` recursively on its own, so the coverage is still correct — check the file count, not the absence of an error. `.shellcheckrc` suppresses SC2015 and SC2016 — intentional silences for this codebase's idioms, not blanket ignores |
| Test suite | `bash research-sdd/toolbelt/tests/run-all.sh` | All suites pass; skipped ≠ passed; zero-coverage run exits 1 |
| Mutation | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | All mutation controls go red |

Current suite: **79 suites** (77 `*.test.sh` + 2 `*.test.mjs`), **1,569 test cases** — 1,695 under
`--prove-teeth`, which adds the mutation controls — measured at `14a042c` plus the tool-lifecycle
work unit. Re-measure rather than trusting this line if it looks stale. New suites dropped into
`research-sdd/toolbelt/tests/` are picked up automatically — nothing to register.

When scanning a suite log for failures, match the runner's own `  FAIL  ` prefix, not the bare string:
tests legitimately assert that things fail, so `FAIL` appears inside many PASSING lines. A bare grep
reports dozens of failures on a fully green run.

Every toolbelt script must have a companion `*.test.sh` under `research-sdd/toolbelt/tests/`.

---

## 6. Work-Unit Budget

~**400 authored physical touched lines per PR**, so a reviewer can hold the whole change in their head.
This is the kit's established PR review budget (`sdd-mental-model-bloque17.md §17.5`).

When scope exceeds the budget: **split into chained PRs**. State explicitly what is deferred and why —
silent scope compression is a defect, not a tidy scope trim.

**Probe viability before the writer, not after the review.** The cheapest question in the loop is
"what would make this unbuildable, and what does it yield if built?" — and it must be answered before
a writer spends hours. A work unit whose measured yield is ZERO findings today has a near-zero ceiling
on what it may cost, and that ceiling is a decision input, not a footnote. The `verify-block.sh`
synthesis gate was measured at 145 remissions with 0 broken BEFORE implementation, and built anyway;
it consumed 3.6 hours of agent time across a scout, a writer, a correction and a review, and was closed
unmerged because it delivered 19 false failures and disabled a working guard. Its other fatal fact — that blocks carry no machine-readable
type, so detection could only guess from prose — was also knowable in minutes.

The corollary: when the substrate has no schema, **doctrine comes first**. Prescribe the declaration,
then build the checker against it. A parser over free-form prose inherits that prose's ambiguity no
matter how good the regex. Same conclusion reached twice in one session — for block types, and for
the `TARGETS.md` maturity cell whose 18 rows carried 25 distinct field shapes.

---

## 7. Anti-Silent-Zero Doctrine

The kit's most-repeated defect family; closed at least four times. Two concrete examples:

**`fd464b9`** — `verify-registry.sh`: a corpus whose blocks used bare numbering (`block1.md`, no canonical
`<prefix>-(block|bloque)<N>.md`) returned `real=0`. The target never entered any WARN or INFO. The fix
reports unclassifiable candidates loudly and treats such a corpus as advanced for §18 purposes.

**`1771839`** — seven silent-pass channels across `verify-state`, `research-sdd-archive`,
`research-sdd-status`, and `census-target`: all returned 0 or PASS from states that were actually
absent-input or corrupt-input, not empty-input. The commit message describes each channel and why
"absent" and "empty" must be distinct signals.

**The rule:** an instrument that reports 0 or passes must be able to prove it actually looked.
Three states must be distinguishable at all times:

| State | Meaning |
|---|---|
| absent-input | File / directory not found or not traversable |
| empty-input | Found and genuinely empty |
| no-match | Items exist; none satisfied the filter |

A count of 0 that could equally mean any of these three is a bug.

Most instruments are WARN-only and never fail — that is exactly what lets a silent zero hide.
Avoid `|| true` after greps: it converts a real `grep` error (exit 2: ENOMEM / SIGPIPE) into a
silent confident zero, reintroducing the problem inside the guard that exists to prevent it.

**The false-negative direction.** The three states above ask "did the instrument look?". They do not
ask "could it SEE what it was looking at?". A parser that only recognises some of the forms its input
uses reports a low count while genuinely having looked — the three-state model is satisfied and the
number is still wrong. `verify-block.sh` resolved 6 of 95 citations on a real block, exiting 0 with no
warning, because it matched `file.ext:NNN` and the corpus overwhelmingly writes `file.ext:NNN-MMM`
(1,790 such citations fleet-wide). An instrument that resolves a LOW count must be able to prove it
recognises every form its input actually uses — enumerate the forms against real corpus data, not
against the fixtures you wrote. A false negative destroys trust exactly the way a false positive does:
one makes good evidence read as absent, the other makes noise read as a finding, and both teach the
operator to stop believing the output.

**Report only what you measured.** An instrument's output must not imply a claim wider than what it
actually checked. `sweep-retros.sh` counts retros whose review-status MARKER is open — which is not the
same claim as "this much work is waiting", and the gap between those readings was measured at ~20% of
the headline. The fix is not to make the instrument guess; deltas are prose and it cannot. The fix is
to stop implying otherwise: say what the number tracks, and flag what would have to be verified by hand
before trusting it as work.

**Acceptance is a fleet sweep, not the fixtures.** An instrument that reads corpora or the registry is
accepted by running it against the REAL fleet, diffing against `main`, and classifying every new WARN
and every exit-code flip by hand as true or false. Fixtures pin the behaviour the author already
imagined; the corpus is where the forms nobody enumerated live. Three consecutive fixture-green
versions of the `verify-block.sh` synthesis gate were each wrong on real data — one WARNed 15 times on
a clean file, one reported `unrecog=0` over six real parser gaps, one misdetected ~50 evidence blocks
and turned off the P6 anti-silent-zero WARN on all of them. Shellcheck, the full suite and
`--prove-teeth` passed every time. That PR was closed rather than merged; its measurements are in
issue #128.

**Test the list edges, not just the middle.** A validator that walks a list needs its interesting case
in FIRST, MIDDLE and LAST position, plus the single-element case. `verify-registry.sh` fed its token
loop with `printf '%s' … | tr '/' '\n'`; with no trailing newline the final `read` returns non-zero and
the loop body never runs for the last token, so the last field of all 18 rows was never validated and a
single-field cell was never validated at all. Every fixture had placed its garbage mid-cell, so the
tests AND their mutation controls passed. The instrument reported zero non-conforming fields, and that
zero was read as confirmation — a zero that could not prove it had looked, inside the check written to
stop exactly that.

---

## 8. Read-Only Corpora

Kit tools **never modify target directories**. The doctrine is **propose-never-apply**: surface findings
for the human to act on; never auto-apply.

- `verify-registry.sh`, `sweep-retros.sh`, `sweep-audits.sh` — WARN-only about **findings**: a pending
  retro or a drifted row never fails the run. They DO `exit 1` on **operational** failure (TARGETS.md
  missing, a `lib/` helper that failed to define its function). A finding is advisory; a broken
  instrument is not — that distinction is §7 in practice.
- `TARGETS.md` is **never auto-edited** — not by the toolbelt, not by any kit session. Archive prints
  a "refresh the row" reminder; the human refreshes it by hand.
- Build test fixtures under `research-sdd/toolbelt/tests/fixtures/` — never inside a live target directory.

`propose-never-apply` is named in `TARGETS.md:35`, `METHODOLOGY.md` §13/§18/§20, and in
`verify-registry.sh:15` and `verify-registry.sh:244`.

---

## 9. Language Contract

All kit artifacts — code, comments, docs, commit messages, tests, fixture content — in **English**.

Conversation with the user may be in any language. That language never leaks into artifacts.

---

## 10. Git Discipline

- **Never commit** unless the user explicitly asks.
- **Never push** unless the user explicitly asks.
- Conventional commits only (`feat`, `fix`, `test`, `docs`, `refactor`, …).
- No AI attribution and no `Co-Authored-By` trailers in commit messages.

---

## 11. Path Portability — RESOLVED

All 18 `TARGETS.md` rows carry the portable form `` `$RESEARCH_HOME/<rest>` ``. No row hardcodes a
per-machine absolute path any more.

Derivation is centralized in `research-sdd/toolbelt/lib/target-paths.sh`, sourced by
`verify-registry.sh`, `sweep-retros.sh` and `sweep-audits.sh`. None of the three carries its own copy
of the old inline pattern. The library handles `` `/abs/path` ``, `` `$RESEARCH_HOME/rest` `` and
`` `${RESEARCH_HOME}/rest` ``, so a row written either way still resolves — the placeholder is the
convention, not a hard requirement.

**How the placeholder resolves:** `${RESEARCH_HOME:-$HOME}`. An unset `$RESEARCH_HOME` falls back to
`$HOME`, which is what makes the registry portable rather than merely indirect: on another machine the
same row resolves under that user's home with nothing to configure. Set `$RESEARCH_HOME` explicitly
only when the corpora do NOT live under `$HOME`.

Two properties worth preserving if this is ever touched again:

- **Derivation reads table rows only** (lines starting with optional whitespace then `|`). `TARGETS.md`
  detail sections legitimately cite file paths in prose; a whole-file scan ingested those sentences as
  targets. Five prose citations were being counted, including the version fragments `` `/v2` `` and
  `` `/vN` ``, and one ending in `...` made every sweep declare itself PARTIAL over a target that did
  not exist.
- **A truncated path INSIDE a table row still passes through and still warns.** That is deliberate
  (§7): a genuinely broken row must announce itself rather than vanish. It has its own test so a future
  narrowing cannot silently remove it.

Non-path tokens still pass through — `` `/mrdoob/three.js` `` is a GitHub slug, not a directory — and
callers filter them with `[ -d ] || continue`. That is expected, not a defect.
