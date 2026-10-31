# vendor-sdd-phase-agents

Issue: #2351 · Locator: `odd/tasks/vendor-sdd-phase-agents.md` · Engram mirror: `odd/vendor-sdd-phase-agents/tasks`

## Objective

Vendor the SDD phase agents and skills into the kit under the `research-sdd-phase-` namespace and deploy them with the
installer, so `gentle-ai sync` (v4.1.0+, which retired SDD and deletes `~/.claude/agents/sdd-*`, `~/.claude/skills/sdd-*`
and the SDD files in `~/.claude/skills/_shared/`) can no longer remove them.

## Why

The kit's model split (`CLAUDE.md` §2) and active work in the kit and in `niagara-research` depend on these agents.
On 2026-10-31 two syncs deleted them 12 minutes apart. `CLAUDE.md` §2 already names the gap: they lived only in a
per-machine `~/.claude/agents/`.

## Scope

- 11 agents → `research-sdd/agents/claude/research-sdd-phase-<phase>.md`
- 11 skill dirs + 5 shared files → kit source, deployed to `~/.claude/skills/research-sdd-phase-<phase>/` and
  `~/.claude/skills/research-sdd-phase-shared/` (claude harness only)
- installer: install, `--verify`, `--uninstall`, `--force-skill`, `--dry-run` cover the new managed set
- `CLAUDE.md` §2 and any kit doc naming the old agents updated
- MIT attribution (Copyright (c) 2025 Gentleman Programming, gentle-ai)

Out of scope: pi / gentle-shell deployment; deleting the restored `~/.claude/agents/sdd-*` copies.

## Constraints

- Vendored files are byte copies except identifier and path renames; no reference may remain to `~/.claude/skills/sdd-*`,
  `skills/_shared/sdd-*` or an agent named `sdd-<phase>`.
- Strict TDD with executed RED (`CLAUDE.md` §4); mutation teeth; focused suites only in the writer (no full gate —
  heavy-slot rule).
- Work-unit budget: vendored copies (~7.4k lines) are not authored lines; authored changes are expected under ~400.

## Tasks

- [ ] T1 — vendor + rename agents, skills and shared files; attribution file (route: delegated writer, trigger: 2+ non-trivial files)
- [ ] T2 — installer deploys/verifies/uninstalls the new set; tests with RED + teeth (route: same writer)
- [ ] T3 — `CLAUDE.md` §2 + doc references (route: same writer)
- [ ] T4 — quiet-tree full gate (orchestrator, needs heavy slot), RDD assess, PR, Opus review

## Acceptance criteria

- `research-sdd-install.sh --harness claude` deploys 11 agents and 12 skill dirs; `--verify` reports match; drift and
  absence are reported; `--uninstall` removes them.
- A test fails if any vendored file references a sync-deleted path or an old agent name.
- `CLAUDE.md` §2 names the new agents and says they are versioned in the kit.

## Progress

- 2026-10-31: issue #2351 created (status:approved); ODD doc created; writer pending.
