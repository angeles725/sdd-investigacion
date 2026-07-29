# gentle-ai SDD — Research State

> **RETROACTIVE RECONSTRUCTION — 2026-07-29.** This file was not maintained during the corpus run.
> It was written after the fact from finished blocks (B1–B27), the INDEX.md, and CATALOG.md.
> Do not treat it as a live-maintained record. Per-iteration detail is not recoverable from the
> batch-written corpus; what IS recorded below is exact and sourced from the blocks themselves.

<!-- State envelope (research-state.v1) — ported from gentle-ai's verify-result/v1. -->
<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 27
gaps_closed: 0
known_gaps: 14
investigable_open: 3
requires_execution_open: 3
blocked_open: 7
deferred_open: 1
undocumented_findings: 0
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: 27 (B1..B27)
- **Coverage metric**: 0 / 14 closed  (gap universe established retroactively from open questions in blocks; the initial batch sweep did not maintain a formal gap backlog, so closed-gap count is not derivable)
- **Last iteration**: 2026-07-28 — partial refresh of 8 blocks to gentle-ai v2.2.0 (retroactive record; not a formal loop iteration)

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | `sdd-attempt` behavior and routing logic — new block needed (B15 §15.5a names it as routing authority, no dedicated block) | skill file `~/.config/opencode/skills/sdd-attempt/SKILL.md` | pending |
| high | `sdd-verify-validate` full admission-gate contract beyond §19.10 summary — new block needed | skill file `~/.config/opencode/skills/sdd-verify-validate/SKILL.md` + agent file | pending |
| medium | 4R review lenses as native sub-agents — phase/model/prompt triplets — new block needed (B18 §18.4a notes absent from `claude_phase_assignments`) | agent files `~/.claude/agents/review-*.md` + skill files | pending |
| medium | Transaction states `ready_final_verification`/`final_verifying` in `sdd-verify` (B11 §11.6) — semantics require observing live dispatcher | live binary: `gentle-ai sdd-attempt status` | requires-execution → §19 (not read-only; needs binary run) |
| low | Team-wide `~/.claude/CLAUDE.md` distribution verification — only `gentle-ai doctor` per machine is evidence (B18 §18.4a) | live binary: `gentle-ai doctor` on each developer machine | requires-execution → §19 (needs live system per-machine) |
| low | Whether `claude_phase_assignments` acquires review-lens keys after `gentle-ai sync` (B18 §18.4a) | live binary: `gentle-ai sync` then re-read `state.json` | requires-execution → §19 (needs binary run) |
| deferred | `review` command family: 21 subcommands deep-documentation (B26 §26.2.3) | binary + upstream docs + source tag | deferred — upstream declares RDD unstable ("may change while remaining issues are fixed", `README.md:21`); `v1.46.0` named as last stable release without RDD |

## Iteration history

<!-- Corpus written as a one-pass batch — no formal loop was run. Per-iteration gap accounting
     was not recorded at write time and cannot be recovered from finished blocks. The two rows
     below are NOT loop iterations; they are batch events recorded retroactively. -->

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| — | 2026-06-28 | Batch write: 27 blocks in parallel (no formal gap backlog at write time; not a loop iteration) | B1-B27 | yes · 7 sub-agents (sonnet) | 9 inline [GAP] markers identified across B11,B12,B18,B26,B27 |
| — | 2026-07-28 | Batch refresh: B11,12,15,18,19,22,26,27 updated to v2.2.0; [DRIFTED] markers applied | B11,12,15,18,19,22,26,27 | no · inline | 0 new (3 requires-execution gaps reclassified from INCOMPLETE status) |

## Blocked gaps (each tagged with what it needs)

- B12: timing of reconciliation of `sdd-archive` skill/native-gate inconsistency (§12.5b admitted by upstream) — needs: upstream issue tracker or future release note · tried: reading `README.md:218` (inconsistency documented; no resolution timeline present); local Cellar install contains no changelog or issue index
- B26: v2.2.0 Go package layout completeness (`docs/architecture.md` written at v1.43.2) — needs: `internal/` tree from v2.2.0 source tag · tried: reading Cellar README and binary `--help`; Cellar ships compiled binary only, no Go source
- B27: whether `Adapter` interface gained new methods in the RDD era — needs: `internal/agents/interface.go` from v2.2.0 source tag · tried: reading Cellar install; no source present
- B27: whether `defaultAgentIDs` count grew beyond 16 in v2.x — needs: `internal/agents/factory.go` from v2.2.0 source tag · tried: reading Cellar install; no source present
- B27: whether strategy enums in `internal/model/types.go` grew in the RDD era — needs: `internal/model/types.go` from v2.2.0 source tag · tried: reading Cellar install; no source present
- Native dispatcher flags (`--cwd`/`--json`/`--instructions`) remain `[CERT-a]` — needs: v2.2.0 source tag OR per-subcommand `--help` · tried: `gentle-ai sdd-status --help` (fails: "unknown sdd-status argument --help", per B15 §15.2a); Cellar ships no source; binary `--help` does not expose per-subcommand flags
- Injector body bytes (`components/sdd/inject.go`, `filemerge/`) — B27 documents the contract (paths + per-adapter strategies) but not the exact bytes written — needs: v2.2.0 source tag · tried: reading Cellar install and binary `--help`; source not present

## Stop control (primary = read-only-investigable exhaustion, METHODOLOGY §8)

- **Open gaps — read-only investigable**: 3   ← static loop stops when this hits 0
- **Open gaps — requires-execution** (binary run or live observation; NOT read-only → build phase): 3
- **Open gaps — blocked** (needs v2.2.0 source tag or upstream issue tracker): 7
- Consecutive iterations with empty backlog (secondary): n/a — batch corpus, no formal loop
- Budget cap (default safety net): none

## Dismissed file types

<!-- BOOTSTRAP census (census-target.sh §6 step a2) was not performed during this corpus's
     one-pass creation (2026-06-28). The research SUBJECT is the gentle-ai binary and its
     configuration files at ~/.config/opencode/ and ~/.claude/ — those artifacts do NOT reside
     in this directory. The kit repo's own .sh / .md / .py / .mjs files are kit toolbelt
     material, not the research target. File type audit deferred pending a formal BOOTSTRAP run. -->

- none
