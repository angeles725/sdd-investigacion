# gentle-ai SDD — Research State

> **RETROACTIVE RECONSTRUCTION — 2026-07-29.** This file was not maintained during the corpus run.
> It was written after the fact from finished blocks (B1–B27), the INDEX.md, and CATALOG.md.
> Do not treat it as a live-maintained record. Per-iteration detail is not recoverable from the
> batch-written corpus; what IS recorded below is exact and sourced from the blocks themselves.
> Blocks B28–B34 (2026-10-04) were written in a delegated run with a real gap ledger; see the iteration history.

<!-- State envelope (research-state.v1) — ported from gentle-ai's verify-result/v1. -->
<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 34
gaps_closed: 8
known_gaps: 31
investigable_open: 19
requires_execution_open: 3
blocked_open: 0
deferred_open: 1
undocumented_findings: 0
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: 34 (B1..B34; B28-B34 cover gentle-ai v4.0.0; B1-B27 are classified in the B28 §28.9 staleness map: 19 STALE, 7 DRIFTED, 1 STILL-VALID)
- **Coverage metric**: 8 / 31 closed  (the original 14 gaps were established retroactively; 17 gaps were added by the 2026-10-04 run)
- **Last iteration**: 2026-10-04 — gentle-ai v2.2.0 -> v4.0.0 delta sweep (batch event, B28-B34)

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | `review` command family: deep documentation of the 21 subcommands (was deferred while RDD was unstable; RDD is stable and default-on since v3.5.0) | source `internal/cli/review*.go` in `~/investigacion/sources/gentle-ai` at v4.0.0 plus `gentle-ai review --help` | pending (re-typed from deferred 2026-10-04; B31 documents the protocol only) |
| medium | Refresh the 7 DRIFTED blocks (B1, B17, B20, B22, B25, B26, B27) against v4.0.0 | B28 §28.9 staleness map | pending |
| medium | Add a historical-banner pointer (v<=3.x) to the 19 STALE blocks, without rewriting them | B28 §28.9 staleness map | pending |
| medium | Native reviewer model assignment storage and schema (v3.7.0, six Claude assignments) | source `internal/model/*` and TUI screens | pending |
| medium | Content of the 4R lens agent prompts and the refuter/validator role contracts | source `internal/assets/claude/agents/review-*.md`, `internal/assets/skills/_shared/review-ledger-contract.md` | pending |
| medium | reviewtransaction state machine, refusal paths for wrong/stale/replayed ack tokens, consent validation (stop-hook body already read in B34) | source `internal/reviewtransaction/*` | pending |
| medium | `sync` write list per harness (what each adapter writes) | source `internal/pipeline`, `internal/planner` | pending |
| medium | Issue tracker closure and actor stats: 90-day closed issues with `state_reason`, who applies `status:approved`, label vs title-prefix coverage | `gh api` search and issue timeline events | pending |
| medium | Automated-issue quality: sample about 20 occurrence comments against release notes; cluster the open automated reports by `reason_code` | `gh api` over the upstream tracker | pending |
| low | B26: v2.2.0-era package layout compared with v4.0.0 | source `docs/architecture.md` and the `internal/` tree (the v2.2.0 tag is also in the clone) | pending (re-typed: source now cloned) |
| low | B27: did the `Adapter` interface gain methods since v2.2.0 | source `internal/agents/interface.go` | pending (re-typed: source now cloned) |
| low | B27: did `defaultAgentIDs` grow beyond 16 (B32 lists more adapter directories) | source `internal/agents/factory.go` and `registry.go` | pending (re-typed: source now cloned) |
| low | B27: did the strategy enums in `internal/model/types.go` grow | source `internal/model/types.go` | pending (re-typed: source now cloned) |
| low | Per-release detail v2.2.1..v2.9.1 (read at heading level only; about 200 review commits in v2.4) | release notes and commit history | pending |
| low | Release-provenance verify job and signing preflight | source `.github/workflows/release.yml`, `scripts/release-signing-preflight.sh`, `internal/releaseprovenance/` | pending |
| low | Run the read-only `gentle-ai review schema` subcommand for each role and validate fixtures against schemas | binary plus `contracts/review-integration/v2/fixtures/` | pending |
| low | Bench journey census (IDs per journey, collision guard) | source `bench/journeys_*.go` | pending |
| low | Why `size:exception` is waived on a large share of PRs; whether `pr-size-policy.yml` will ever flip to `enforcing` | history of `.github/grandfather-size-exceptions.json` | pending |
| low | Read the organic-runtime E2E fixture (switch on call number, adversarial guards) | source `e2e/organicruntime/organic_runtime_test.go` | pending |
| low | Team-wide `~/.claude/CLAUDE.md` distribution verification — only `gentle-ai doctor` per machine is evidence (B18 §18.4a) | live binary: `gentle-ai doctor` on each developer machine | requires-execution -> §19 (needs live system per-machine) |
| low | Does v4.0.0 `sync` prune stale `sdd-*` agents left in `~/.claude/agents` | live: `gentle-ai sync` on a scratch HOME | requires-execution -> §19 |
| low | Live behaviour of review recovery, consent and acknowledgement (B28 and B31 are `[CERT-a]` for these) | live binary against a scratch repository | requires-execution -> §19 |
| deferred | Telemetry runtime schema and collector internals (`contracts/telemetry/runtime/v1`, `internal/telemetrycollector`) — not applicable to a local kit | source tree | pending (parked by decision 2026-10-04) |
| ~~high~~ | ~~`sdd-attempt` behavior and routing logic~~ | removed in v4.0.0 (B28 §28.2) | ✅ obsolete: subcommand no longer exists |
| ~~high~~ | ~~`sdd-verify-validate` admission-gate contract~~ | retired with the verify phase (B28 §28.2) | ✅ obsolete |
| ~~medium~~ | ~~4R review lenses as native sub-agents — new block needed~~ | `internal/assets/claude/agents/` | ✅ answered: agent set listed in B28 §28.5 and B32 §32.2; prompt content re-opened as its own gap above |
| ~~low~~ | ~~Transaction states `ready_final_verification`/`final_verifying`~~ | SDD verify phase removed | ✅ obsolete |
| ~~low~~ | ~~Whether `claude_phase_assignments` acquires review-lens keys after `sync`~~ | phase assignments superseded by v3.7.0 reviewer model assignments | ✅ superseded (storage question re-opened above) |
| ~~low~~ | ~~Native dispatcher flags `--cwd`/`--json`/`--instructions`~~ | `sdd-status` removed | ✅ obsolete |
| ~~low~~ | ~~B12: reconciliation of `sdd-archive` skill vs native-gate inconsistency~~ | phase removed | ✅ moot |
| ~~low~~ | ~~Injector body bytes `components/sdd/inject.go`~~ | no `sdd` package under `internal/components` at v4.0.0 | ✅ obsolete |

## Iteration history

<!-- Corpus written as a one-pass batch — no formal loop was run. Per-iteration gap accounting
     was not recorded at write time and cannot be recovered from finished blocks. The rows
     below are NOT loop iterations; they are batch events. The 2026-10-04 rows are one delegated
     run (5 sonnet sweeps + 1 sonnet writer, plus a sixth sonnet sweep for B34) recorded per block. -->

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| — | 2026-06-28 | Batch write: 27 blocks in parallel (no formal gap backlog at write time; not a loop iteration) | B1-B27 | yes · 7 sub-agents (sonnet) | 9 inline [GAP] markers identified across B11,B12,B18,B26,B27 |
| — | 2026-07-28 | Batch refresh: B11,12,15,18,19,22,26,27 updated to v2.2.0; [DRIFTED] markers applied | B11,12,15,18,19,22,26,27 | no · inline | 0 new (3 requires-execution gaps reclassified from INCOMPLETE status) |
| — | 2026-10-04 | v2.2.0 -> v4.0.0 delta; closes the 8 SDD-era gaps and re-types 4 source-tag gaps as investigable | B28 | yes · 5 sonnet sweeps + 1 sonnet writer | 5 (refresh DRIFTED, STALE banners, reviewer model storage, per-release detail, sdd-agent prune) |
| — | 2026-10-04 | Issue/PR management | B29 | yes · 5 sonnet sweeps + 1 sonnet writer | 2 (tracker stats, size:exception history) |
| — | 2026-10-04 | Automated issue generation (also promotes the deferred `review` family to pending) | B30 | yes · 5 sonnet sweeps + 1 sonnet writer | 1 (occurrence-comment quality sample) |
| — | 2026-10-04 | Component communication contract | B31 | yes · 5 sonnet sweeps + 1 sonnet writer | 4 (reviewtransaction code, review schema fixtures, live review behaviour, lens prompts) |
| — | 2026-10-04 | Creation/installation surface, ODD method, bench, provenance | B32 | yes · 5 sonnet sweeps + 1 sonnet writer | 3 (sync write list, bench census, release verify job) |
| — | 2026-10-04 | Adoption synthesis (34 ranked kit candidates; verified latent defect in the kit pr-check.yml) | B33 | yes · 5 sonnet sweeps + 1 sonnet writer | 0 |
| — | 2026-10-04 | Instruction adherence; stop-hook body read, closing that part of the B31 gap | B34 | yes · 1 sonnet sweep + sonnet writer | 1 (organic-runtime E2E fixture) |

## Blocked gaps (each tagged with what it needs)

<!-- none open as of 2026-10-04. The 7 previously blocked gaps were resolved by cloning the source:
     5 are obsolete (SDD removed) and the B26 layout plus B27 interface/factory/types gaps are re-typed
     as pending rows above. The earlier "tried" notes are preserved in version history. -->

## Stop control (primary = read-only-investigable exhaustion, METHODOLOGY §8)

- **Open gaps — read-only investigable**: 19   ← static loop stops when this hits 0
- **Open gaps — requires-execution** (binary run or live observation; NOT read-only → build phase): 3
- **Open gaps — blocked** (needs a source tag or upstream issue tracker): 0
- Consecutive iterations with empty backlog (secondary): n/a — batch corpus, no formal loop
- Budget cap (default safety net): none

## Dismissed file types

<!-- BOOTSTRAP census (census-target.sh §6 step a2) was not performed during this corpus's
     one-pass creation (2026-06-28). The research SUBJECT is the gentle-ai binary and its
     configuration files at ~/.config/opencode/ and ~/.claude/ — those artifacts do NOT reside
     in this directory. The kit repo's own .sh / .md / .py / .mjs files are kit toolbelt
     material, not the research target. File type audit deferred pending a formal BOOTSTRAP run. -->

- none
