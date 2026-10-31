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
- 11 skill dirs + 8 shared files (5 SDD + 3 resolver/convention files they reference) → kit source, deployed to `~/.claude/skills/research-sdd-phase-<phase>/` and
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

- [x] T1 — vendor + rename agents, skills and shared files; attribution file (route: delegated writer, trigger: 2+ non-trivial files) — 0b090138
- [x] T2 — installer deploys/verifies/uninstalls the new set; tests with RED + teeth (route: same writer) — 2e236e6e, b93ffe40
- [x] T3 — `CLAUDE.md` §2 + doc references (route: same writer) — d8f57170
- [ ] T4 — quiet-tree full gate (orchestrator, needs heavy slot), RDD assess, PR, Opus review

## Acceptance criteria

- `research-sdd-install.sh --harness claude` deploys 11 agents and 12 skill dirs; `--verify` reports match; drift and
  absence are reported; `--uninstall` removes them.
- A test fails if any vendored file references a sync-deleted path or an old agent name.
- `CLAUDE.md` §2 names the new agents and says they are versioned in the kit.

## Progress

- 2026-10-31: issue #2351 created (status:approved); ODD doc created; writer pending.
- Writer: RED executed against the pre-change SUT (20 phase/golden cases failed for the right reason). Install suite 306/0 plain, 467/0 with --prove-teeth; kit-writer-check Findings: 0. Authored +485/-19 (incl. 32 generated golden lines), vendored +4664. Not pushed. T4 pending (orchestrator: quiet-tree gate, RDD, PR).
- Correction (orchestrator): vendored the 3 remaining `_shared/` files the phase skills reference (skill-resolver, engram-convention, research-lifecycle) into `research-sdd-phase-shared/` (now 8 files) and rewrote every `_shared/` reference; the static guard now fails on ANY `_shared/`. RED executed first (guard failed on init/SKILL.md:75 and research/SKILL.md:53). Install suite 306/0 plain, 470/0 teeth; kit-writer-check Findings: 0. Commit SHA: see git log (subject `fix(vendor): make the phase skills self-contained ...`).
- Follow-up noticed: `research-sdd/install/install.sh` SENTINEL-AGENTS-NOTICE still looks for `~/.claude/agents/sdd-apply.md` (pinned by `toolbelt/tests/install.test.sh`); outside this unit's surfaces.
- Follow-up filed as #2352 (install.sh notice). Open note for the PR: `research-sdd-phase-shared/sdd-orchestrator-workflow.md:270` mentions `persistence-contract.md` living under the global skills dir; it is prose, not a read path, and the file is not vendored — candidate one-file follow-up.
- 2026-10-31 session close: the quiet-tree full gate (`run-all.sh --prove-teeth`, serial) was started at a43569f4 and STOPPED by the user at 80 of 198 core suites (5,039 passed, 0 failed so far) to save time; its temp leftovers were removed. That partial run is NOT a gate result.

## Next step (resume here)

1. Re-run the full gate on a quiet tree, in parallel to save time: `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth -j 4` (logs under `~/investigacion/sdd-investigacion-worktrees/2351-data/`, one heavy run machine-wide). Demand the full aggregate line.
2. `gentle-ai review assess --cwd <worktree> --json` over the branch; follow the RDD consent/review if due.
3. Open the PR for `feat/2351-vendor-sdd-phase-agents` (closes #2351) with the RED lines from this document, then the Opus adversarial review; merge after CI.
4. After merge: `research-sdd-install.sh --harness claude` on this machine to deploy `research-sdd-phase-*`.
