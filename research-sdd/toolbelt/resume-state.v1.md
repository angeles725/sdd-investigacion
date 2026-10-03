# resume-state.v1 — machine-readable resume state (kit issue #1274, slice 1)

`resume-state.sh [--cwd DIR] [--base-ref REF] [--no-gh]` prints ONE JSON document to stdout, derived only
from git (plus open PRs from `gh` when available). It writes nothing and every field is computed: there are
no hand-set fields. Rendering the prose handoff from this document is slice 2.

## Exit codes

| rc | Meaning |
|---|---|
| 0 | document printed (a degraded PR list is still rc 0 — see `prs_status`) |
| 2 | usage error (`--help` exits 0), not a git repository, unresolvable or option-shaped (`-...`) `--base-ref`, or no `origin/main`/`main` and no `--base-ref` |
| 3 | DEGRADED: `git` or `jq` missing — a typed `DEGRADED:` line on stderr, no JSON on stdout |

## Schema `research-sdd.resume-state/v1`

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | constant `research-sdd.resume-state/v1` |
| `generated_at` | string | UTC ISO-8601 time of generation |
| `repo.toplevel` | string | `git rev-parse --show-toplevel` |
| `repo.remote` | string\|null | `remote.origin.url`, null when unset |
| `base_ref`, `base_sha` | string | ref ahead/behind is measured against (default `origin/main`, else `main`) and its commit sha |
| `worktrees[]` | array | every entry of `git worktree list --porcelain`, primary included |
| `worktrees[].path` | string | worktree path |
| `worktrees[].branch` | string\|null | branch name; null for a detached HEAD |
| `worktrees[].head` | string\|null | HEAD sha |
| `worktrees[].exists` | bool | false when the directory is gone (a prunable entry) |
| `worktrees[].prunable` | bool | git marks the entry prunable |
| `worktrees[].dirty` | int\|null | tracked-file changes (`status --porcelain` lines not starting `??`); null when the directory is gone |
| `worktrees[].untracked` | int\|null | untracked entries (`??` lines); null when the directory is gone |
| `worktrees[].ahead`, `.behind` | int\|null | commits of HEAD not in `base_ref` / of `base_ref` not in HEAD |
| `branches[]` | array | local branches NOT checked out in any worktree: `name`, `head`, `ahead`, `behind` |
| `prs` | array\|null | open PRs `{number, branch, state, url}`; null whenever the list is unknown |
| `prs_truncated` | bool\|null | true when gh returned exactly the `--limit` (1000) results, so the list may be incomplete; false otherwise; null when `prs` is null |
| `prs_status` | string | `ok` (list is authoritative, possibly empty) · `skipped` (`--no-gh`) · `degraded:gh-missing` · `degraded:gh-failed` · `degraded:gh-timeout` · `degraded:gh-bad-json` |

## Anti-silent-zero contract (CLAUDE.md §7)

- `prs: []` with `prs_status: "ok"` means gh answered and there are no open PRs. An unknown list is always
  `prs: null` plus a non-`ok` status, never an empty array.
- A missing worktree directory reports `exists:false` and null counts, not `0`.
- A ref that cannot be counted yields null `ahead`/`behind`, not `0`.

## Limits

Worktree paths containing a newline are not supported (the porcelain output is parsed line by line).
Review receipts, in-flight workers and the next task are not derived here; they have no git source today.
