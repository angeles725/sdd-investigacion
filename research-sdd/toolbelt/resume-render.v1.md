# resume-render.v1 — prose resume handoff rendered from resume-state (kit issue #1274, slice 2)

`resume-render.sh [--json FILE|-] [--cwd DIR] [--base-ref REF] [--no-gh]` prints a concise Markdown handoff
derived from one `research-sdd.resume-state/v1` document (see `resume-state.v1.md`). It is read-only: it
writes nothing, edits no doc and invents no field (propose-never-apply).

## Input

- `--json FILE` renders that document; `--json -` reads stdin, so `resume-state.sh | resume-render.sh --json -` works.
- Without `--json` it runs the sibling `resume-state.sh` itself and forwards `--cwd`, `--base-ref`, `--no-gh`.
  Those three flags are rejected together with `--json` (they would have no effect).

## Exit codes

| rc | Meaning |
|---|---|
| 0 | handoff printed |
| 2 | usage error; absent/unreadable file; empty input; malformed JSON; more than one JSON document; wrong `schema`; wrong shape (`worktrees`/`branches` not arrays of objects, `repo` not an object, `prs` not null or an array of objects, `base_ref` not a string); a render failure (`render failed: ...`; the handoff is buffered, so stdout stays empty); `resume-state.sh` failed (rc other than 3) — nothing on stdout |
| 3 | DEGRADED: `jq` missing (typed `DEGRADED:` line on stderr), or `resume-state.sh` itself exited 3 |

## Output sections

`# Resume handoff` (generation time, repo, remote, base ref + short sha) · `## Worktrees` · `## Loose branches` ·
`## Open PRs` · `## Not derived`.

## Anti-silent-zero contract (CLAUDE.md §7)

- Every `null` renders as `unknown`: `dirty unknown`, `ahead unknown`, an unknown head sha. A real `0` renders as `0`.
- A missing key is unknown, never a default: only an explicit `repo.remote:null` renders "none configured" (a
  missing key or `repo` renders "remote unknown"), only an explicit `branch:null` renders "detached HEAD" (a
  missing key renders "branch unknown"), and a missing `exists` renders "existence unknown".
- A worktree `path`, loose-branch `name` or PR `number`/`branch`/`state`/`url` that is null or missing renders `unknown`, never the literal `null`.
- `--json ""` is rejected (rc 2); it never falls back to self-run mode.
- A worktree with `exists:false` renders `DIRECTORY MISSING` (plus a prune hint when `prunable`) with unknown counts.
- PRs: only `prs` an array AND `prs_status:"ok"` is trusted. `[]` renders "No open PRs (gh answered with an
  empty list)"; `prs:null` renders `PR list unknown: <prs_status>` (a missing status renders `prs_status missing`);
  a list present beside a non-ok status renders unknown plus an `inconsistent` note and is not listed.
  `prs_truncated:true` (or missing) adds a completeness warning.
- `## Not derived` states what has no git source (review receipts, in-flight workers, the next task) so the
  handoff never implies those were checked.

## Limits

It formats exactly what `resume-state.sh` derived; it adds no judgement (no "needs attention" ranking).
