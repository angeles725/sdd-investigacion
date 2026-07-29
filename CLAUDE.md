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

Current suite: **78 suites** (76 `*.test.sh` + 2 `*.test.mjs`), **1,529 test cases** — 1,632 under
`--prove-teeth`, which adds the mutation controls — measured at `ed96daa` plus the deferred-delta
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

## 11. Path Portability — IN FLIGHT, Not Resolved

`TARGETS.md` is committed and shared, but its target paths are per-machine absolute paths
(e.g. `` `/home/cristian/niagara-research` ``). They resolve on exactly one developer's laptop.

A `$RESEARCH_HOME` convention is being introduced to fix this. **That work is not finished.**
The shared path-derivation pattern `` grep -oE '`/[^`]+`' `` (backtick + slash, anchoring on
absolute paths) still appears unchanged in three scripts:

| Script | Line |
|---|---|
| `research-sdd/toolbelt/verify-registry.sh` | 48 |
| `research-sdd/toolbelt/sweep-retros.sh` | 39 |
| `research-sdd/toolbelt/sweep-audits.sh` | 37 |

**Warning:** Converting `TARGETS.md` rows to a placeholder such as
`` `$RESEARCH_HOME/niagara-research` `` before those three scripts understand the placeholder
will silently blind every fleet instrument — the regex will not match `$`-prefixed strings,
every row will be skipped, and the instruments will report a clean sweep over nothing.
Do not convert rows until the derivation is updated to handle the placeholder first.
