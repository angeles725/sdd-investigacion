# Profile A/B evaluation protocol — Claude vs. Qwen, `claude` vs. `general` prompt profile

Kit issue #993 (multi-model prompt profiles). Decides, per finding, whether a prompt-wording
or context-budget change from the #992 audit needs its own model-family profile
(`research-sdd/profiles/general/`) or can stay a single doctrine shared by every model.

This protocol does not itself build the `general` profile or the harness adapter selection —
it is the measurement gate #993's proposal calls for: "decide per finding with evidence: a
small eval (same target, same focus, N iterations) run on Claude and on Qwen". The instrument
that scores a run is `research-sdd/toolbelt/score-loop-transcript.sh` (kit issue #993, WU5).

## Fixed variables

- **Target + focus**: pick ONE existing `TARGETS.md` corpus and ONE existing, non-exhausted
  focus with at least 5 read-only-investigable gaps remaining at the time the run starts.
  Record the exact corpus path (portable `$RESEARCH_HOME/...` form, METHODOLOGY §11) and focus
  slug in the run log below. Reusing the SAME target+focus across every cell isolates the
  model/profile variables — a different target per cell would also vary gap difficulty and
  corpus size, confounding the result.
- **N = 5 iterations** per run: each run is capped at 5 block commits (or an earlier STOP),
  matching the eval to the `--prove-teeth`-scale budget this kit uses for other self-tests
  rather than a full campaign. A run that STOPs before 5 iterations is scored as-is — STOP
  before N is itself a C4 input, not a discarded run.

## 2×2 grid, 3 seeds

|                  | `claude` profile | `general` profile |
|---|---|---|
| **Claude** (current model) | cell A | cell B |
| **Qwen** (4.6, via reasonix/codex harness) | cell C | cell D |

Each cell is run 3 times (3 seeds — a fresh session per seed; there is no explicit RNG seed to
set, "seed" here means an independent run, not a shared-state replay). 4 cells × 3 seeds = 12
runs total per evaluated finding. A run is a fresh session invoking the loop's operational
prompt (`PROMPT-LOOP.md` "OPERATIONAL PROMPT") against the fixed target+focus, driven to
either N=5 block commits or an earlier STOP, with `/loop` (or the harness's equivalent) issuing
each continuation — exactly the harness surface `score-loop-transcript.sh`'s C1/C4 measure.

## Scoring

For each run, preserve the session transcript (Claude Code JSONL, or the harness's own
transcript format if not Claude Code — score-loop-transcript.sh's JSONL-shape assumptions are
documented and overridable, see its header) and run:

```
score-loop-transcript.sh --corpus <target-corpus-dir> --transcript <run-transcript> \
  --base-ref <the corpus commit sha immediately BEFORE the run started>
```

Record all four `C1`/`C2`/`C3`/`C4` lines verbatim per run. A `degraded` or `n/a` result is
evidence too (e.g. a harness that produces no retrievable transcript degrades C2/C3/C4 to n/a
for every run in that cell — note this explicitly rather than dropping the cell).

## Per-criterion cell verdict

A cell (12 runs → 4 cells × 3 seeds) reports, per criterion, the count of `pass` among its 3
seed runs (0–3). `n/a`/`degraded` runs are excluded from both the numerator and denominator for
that criterion and noted separately — a criterion scored 2 n/a and 1 pass out of 3 is reported
as `1/1 pass (2 n/a)`, never silently folded into `1/3`.

## Decision rule

Keep a profile split (i.e. `general` earns its own wording/budget for this finding) ONLY when
BOTH hold, criterion by criterion:

1. **`general` beats `claude` on Qwen on at least one criterion** — cell D's pass-count for
   some C<n> is strictly greater than cell C's pass-count for that same C<n> (comparing only
   non-n/a, non-degraded runs; §7 anti-silent-zero — a comparison built from degraded data is
   not evidence of a win).
2. **`general` loses to `claude` on Claude on NO criterion** — cell B's pass-count for every
   C<n> is >= cell A's pass-count for that same C<n>.

If both hold: the `general` profile keeps the divergent wording/budget for this finding, and
the delta is recorded in `research-sdd/profiles/general/` with the evidence (cell counts, run
log entries) cited in its commit. If either fails: the finding stays a single shared-doctrine
change (no profile split) — either because `general` bought nothing on Qwen, or because it cost
something on Claude that outweighs a Qwen-only gain. A tie (cell D == cell C on every
criterion) also means no split: the null result is the default, not a coin flip.

## Run log

Append one row per run (not per cell) as each run completes. This is raw evidence, not a
snapshot to hand-maintain (CLAUDE.md §5's "no persisted counts" principle applies here too —
keep the row-level facts, derive cell counts from them at review time rather than pre-computing
and risking drift):

| Run ID | Model | Profile | Seed | Target | Focus | C1 | C2 | C3 | C4 | Transcript ref |
|---|---|---|---|---|---|---|---|---|---|---|
| _(none yet)_ | | | | | | | | | | |

## Known limitations

- **Qwen transcript shape is unverified.** `score-loop-transcript.sh`'s JSONL-record
  assumptions (operator-input, compaction-boundary detection) were written against the Claude
  Code session format; a Qwen-family harness (reasonix/codex) may emit a differently-shaped
  transcript or none at all. Before running cells C/D for the first time, confirm the harness
  can produce a transcript in a shape the scorer's overridable heuristics can be pointed at
  (`RSDD_OPERATOR_INPUT_JQ`, `RSDD_COMPACT_JQ` — see the script header), or run those cells with
  C2/C3/C4 expected to degrade to n/a and rely on C1 (commit-only, transcript-independent count)
  and manual review of the raw transcript for the other three.
- **A 5-iteration run is a signal, not a campaign-scale verdict.** This protocol answers "does
  this specific wording/budget change move a measurable criterion on this model" — it does not
  replace a full multi-session campaign retro (CLAUDE.md §12) for larger structural questions.
