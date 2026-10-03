# `plan-review-slices.v1`

`plan-review-slices.sh [--cwd DIR] [--base-ref REF] [--max-lines N]` plans reviewable slices of
`merge-base(REF, HEAD)..HEAD` (kit issue #1276). It exists so a large unreviewed range is cut into
slices a reviewer can hold, mechanically, instead of by eye, and so review of slice N can overlap
the writer's work on slice N+1.

Report-only: it creates no branch, ref or file, and never modifies the repository.

## Algorithm

1. Resolve the merge-base of `REF` (default `origin/main`) and `HEAD`.
2. Walk `merge-base..HEAD` first-parent, oldest first. Each commit is measured against its first
   parent with `git diff --numstat`: authored changed lines = additions + deletions.
3. Group consecutive commits greedily into slices of at most `--max-lines` (default 400, the kit
   delivery budget). A slice may hold exactly N lines. Cuts happen only at commit boundaries.
4. A single commit over N is never cut: it is its own slice, typed `UNSPLITTABLE`.

## Output

```
SLICE <k> <first>..<last> commits=<c> lines=<l> [binary=<b>] base=<parent-of-first>
SLICE <k> <first>..<last> commits=1 UNSPLITTABLE lines=<l> [binary=<b>] base=<parent-of-first>
PLAN: <S> slice(s) commits=<C> lines=<L> max=<N> [binary=<B>]
EMPTY-RANGE base=<ref>
```

`base=` is the first parent of `<first>`: review the slice as `--base-ref <base>` with HEAD at
`<last>`. Shas are 12 characters.

## Typed states

| State | Meaning |
|---|---|
| `EMPTY-RANGE` | Found and genuinely empty: nothing between the merge-base and HEAD (exit 0) |
| `binary=<b>` | Binary files were present; they have no line count and are excluded from `lines=` |
| `UNSPLITTABLE` | One commit exceeds `--max-lines`; the planner will not cut inside a commit |
| `DEGRADED: git not found` | git absent: nothing was measured (exit 3) |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | A plan was produced (including `UNSPLITTABLE` slices) or `EMPTY-RANGE` |
| 2 | Bad usage, `--max-lines` not a positive integer, not a git repository, base ref unresolvable, no merge-base |
| 3 | git missing (DEGRADED) |

## Limits

- Generated files are not excluded: every non-binary path counts. The tool does not invent a
  declaration of "generated"; add one only when a repository declares it.
- Slices are measured per commit and summed. A later commit that rewrites an earlier commit's lines
  makes the slice's reviewable diff smaller than `lines=`; the plan is conservative.
- Merge commits are measured against their first parent (the first-parent walk).
