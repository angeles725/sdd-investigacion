# Block 32 — What gentle-ai creates and installs, its ODD working method, the bench, and release provenance and signing

> **WHAT IT DOCUMENTS**: The artifacts gentle-ai v4.0.0 writes onto a machine and into a repository (per-harness adapters, the Claude agent set, bundled skills, hooks, the skill registry, the managed prompt block and its digest, CodeGraph guidance), the way its own developers work (ODD feature documents with route and evidence fields, 400-line work units, delivery strategy), the deterministic bench that measures review-lifecycle friction, and the release provenance and Minisign signing chain. Each topic ends with the kit's nearest equivalent.
> **SCOPE**: Creation and installation surface, working method, bench, provenance. It does NOT re-document `state.json` ([Block 27]) or the configurator commands ([Block 26]) beyond deltas ([Block 28]); the review protocol is [Block 31].
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01 (source clone). The install claims describe the shipped embedded assets, not a run: no mutating subcommand was executed (`sync` write list is a registered gap). Installed-machine observations refer to `~/.claude/agents` as read on 2026-10-04.
> **SOURCES**: `internal/agents/*`, `internal/assets/*` (claude agents, skills, orchestrators, `managed_digest.go`), `internal/components/{agenthooks,agentguidance,communitytool,filemerge}`, `internal/skillregistry/guard.go`, `docs/skill-registry.md`, `odd/tasks/*.md`, `bench/*`, `skills/gentle-ai-bench/SKILL.md`, `internal/releaseprovenance/provenance.go`, `docs/release-signing.md`, `internal/agentbuilder/*`; kit: `research-sdd/install/{adapters,research-sdd-install}.sh`, `research-sdd/skills/`.
> **METHOD**: `[CERT]` = file or directory read at v4.0.0 with `path:line` or a listing; `[CERT-a]` = stated by docs, enforcement not seen in code; `[INFER]` = deduction. Counts are listing results from 2026-10-04.
> **Type:** mixed

---

## 32.1 — Per-harness adapters write the installation `[CERT]`

Install writes per harness through one adapter interface: `internal/agents/` holds one directory per harness (antigravity, claude, codex, conductor, cursor, gemini, hermes, kilocode, kimi, kiro, openclaw, opencode, pi, qwen, trae, vscode, windsurf and more; the sweep counted 20 adapter dirs) plus `capability_manifest.go`, `interface.go`, `registry.go`, `factory.go`. Shared assets are embedded under `internal/assets/<harness>/`; Claude has `orchestrator.md`, two output styles, persona files and `agents/`. The WHERE / HOW / WHAT split matches what the kit already copies in `research-sdd/install/adapters.sh:1-12` ("Mirrors gentle-ai's decoupling") `[CERT]`. Whether the adapter-ID list grew beyond [Block 27]'s 16 is a registered gap: directory count is not `defaultAgentIDs` `[INFER]`.

## 32.2 — The Claude agent set `[CERT]`

Shipped in v4.0.0 (`internal/assets/claude/agents/`): `review-risk`, `review-resilience`, `review-readability`, `review-reliability`, `review-refuter`, `jd-judge-a`, `jd-judge-b`, `jd-fix-agent` — 8 files. On the reading machine `~/.claude/agents` additionally holds 11 `sdd-*` agents (installed list, read-only) although v4.0.0 retired SDD from the asset tree (`odd/tasks/remove-sdd-odd-only-main.md`, `odd/tasks/sdd-retirement-followups.md` exist). `[INFER]` The `sdd-*` files are managed leftovers; whether v4.0.0 `sync` prunes them is unverified (registered requires-execution gap). `[DRIFTED v2.2.0→v4.0.0]` [Block 24]'s judge/fix agents persist; the SDD phase agents of [Block 25] do not.

## 32.3 — Bundled skills `[CERT]`

`internal/assets/skills/` at v4.0.0: `branch-pr, chained-pr, cognitive-doc-design, comment-writer, gentle-ai-bench, go-testing, hermes-ephemeral-delegation, issue-creation, judgment-day, rdd-defect-workflow, skill-creator, skill-improver, skill-registry, systemic-issue-triage, work-unit-commits` (+ `_shared`). The repo-root `skills/` is a separate, repo-local set that adds `gentle-ai-collab-perfect`, `issue-root-resolution`, `rdd-advisory-transport`. The kit already carries analogues `kit-branch-pr`, `kit-chained-pr`, `kit-issue-creation` under `research-sdd/skills/`. See [Block 29] §29.7 for the triage skills and [Block 30] for `issue-creation`.

## 32.4 — Hooks, the skill registry and the managed prompt block

- **Hook**: `internal/components/agenthooks/claude.go:56` registers a `SessionStart` hook (`startup|resume|clear|compact`, timeout 30) in the user's Claude settings; `agenthooks/skill_registry.go:24-27` runs `gentle-ai skill-registry refresh --quiet --no-gitignore --cwd "${CLAUDE_PROJECT_DIR:-$PWD}" || true`; a prune function removes the retired `UserPromptSubmit` variant and preserves unrelated hooks (`skill_registry.go`, ~31-35). Merge-not-overwrite via `internal/components/filemerge` `[CERT]`.
- **Registry**: `.atl/skill-registry.md` is an INDEX (name, full description, scope, exact SKILL.md path); project skills win over global; `_shared`, `skill-registry` and `sdd-*` are excluded (`docs/skill-registry.md`, "Registry Contract" and "Excluded Skills"); delegators pass PATHS under `## Skills to load before work`, never digested rules ("Why Not Compact Rules?"); `gentle-ai skill-registry list [--json]` previews without writing; a guard refuses to initialize in `/`, `$HOME` or markerless directories (`internal/skillregistry/guard.go:3-30`) `[CERT]`.
- **Managed prompt block**: injected by `internal/components/agentguidance/{inject.go,orchestrator.go,routing.go}`; wording pinned by ratchet tests (`internal/assets/orchestrator_drift_ratchet_test.go`; `agentguidance/routing_test.go:348` pins the delivery-strategy sentence "`ask-on-risk` (default), `auto-chain`, `single-pr`, or `exception-ok`") `[CERT]`. The prompt this corpus's orchestrator runs under is that block; the ODD protocol is both product behaviour and a text contract tested as text.
- **Managed-asset integrity**: `internal/assets/managed_digest.go:12-40` computes a deterministic `sha256:` digest over all embedded assets, path-sorted; reviewer asset-provenance compares this digest rather than build identity, so a no-op rebuild is never "stale" (#2685) `[CERT]`. Release notes must tell users to run `gentle-ai sync` after upgrading because review operations fail closed until sync repairs missing or mismatched writer provenance (`docs/release-signing.md`, "Release-note upgrade instruction") `[CERT-a]` (runtime behaviour not seen). The stop code `managed_assets_outdated` is its in-protocol face ([Block 31] §31.4).
- **CodeGraph** is installed as a "community tool" (`internal/components/communitytool/{codegraph_contract.go,codegraph_guidance.go,codegraph_version.go,pi_codegraph.go}`); injected guidance carries lazy `gentle-ai codegraph init`, never in `$HOME` or temp, per-worktree index, read-only CLI only `[CERT]` — the same guard idea as the registry guard.

## 32.5 — The ODD working method, as practised by the upstream developers `[CERT]`

Upstream keeps its own feature documents at `odd/tasks/<feature>.md` (30 `.md` files at v4.0.0 by `ls | grep -c`; the sweep counted 29, difference unexplained). Format, shown by `odd/tasks/odd-mandatory-delegation.md`: `# Feature`, `## Objective`, `## Problem`, `## Scope`, `## Constraints`, `## Tasks` as `- [x] T1 …` where each task carries an indented `Route: inline | delegated` and an `Evidence:` line (RED/GREEN observation, commit sha, RDD tier outcome), then `## Outcome` (lines 36-57 of that file). The route declaration plus commit identity per task makes skipped delegation observable. The same file records its own motivation: the "Mandatory Delegation Triggers" table had lived only in per-runtime SDD orchestrator assets, bound away from ODD work. The Engram mirror topic `odd/<feature>/tasks` is verified only through prompt text, not code `[CERT-a]`.

Delivery heuristics (orchestrator prompt): about 400 authored changed lines per work unit as a planning heuristic, not a cap; strategies `ask-on-risk` (default) | `auto-chain` | `single-pr` | `exception-ok`; chain strategies `stacked-to-main` | `feature-branch-chain`; skills `work-unit-commits` and `chained-pr` resolved by registry name [Block 17 is the SDD-era description] `[CERT]`. Kit equivalent: CLAUDE.md §6 states the same budget and chained-PR rule; the kit's `odd/tasks/*.md` exists (e.g. `kit-session-2026-10-01.md`) but has no fixed route/evidence template `[CERT]`.

## 32.6 — The bench: a deterministic friction meter `[CERT]`

- `bench/` is a separate Go module (`bench/go.mod`) that drives a `--binary` as a black box, offline, in fresh temp HOME/XDG and a throwaway git repo (`bench/README.md:1-45`).
- It measures review-lifecycle FRICTION (steps, dead ends), NOT LLM behaviour — "no model is ever called".
- Journeys: `ls bench | grep -c journeys_` returns 53 files at v4.0.0 (the sweep estimated ~70); many are named for issue numbers (e.g. `journeys_issue4377.go`), so each regression becomes a pinned journey.
- Rules from `skills/gentle-ai-bench/SKILL.md`: `go test ./bench` validates only declarations; the only driven proof is building both binaries and running `run --binary`; journey IDs are globally unique with a collision guard; a dead-execute guard exists; `dead_end` prints `n/a` unless measured, never fabricated; `run` fails closed on failed journeys but not on `unsupported` (README "Driven", issue #1883); `compare` refuses driven-vs-observed.

Kit equivalent: `*.test.sh` suites under `research-sdd/toolbelt/tests/` (151 files matched `ls *.test.sh | wc -l` on 2026-10-04, a dated listing, not a constant; unit-style, one per script) plus `research-sdd/evals/profile-ab` (LLM-side A/B). No cross-script journey corpus exists `[CERT]`. `[INFER]` The bench's three rules (unique IDs, declarations-pass is not execution-pass, `unsupported` reported apart from failure) mirror the kit's own "skipped ≠ passed" and anti-silent-zero doctrine.

## 32.7 — Release provenance and signing `[CERT]`

- **Manifest**: `internal/releaseprovenance/provenance.go:13-33` emits `gentle-ai.release-provenance/v1` (tag, source SHA, workflow, run id/attempt, job, go version, GoReleaser version `v2.15.2`) and a distinct `gentle-ai.release-provenance/local-build` schema so a hand build cannot masquerade as CI; the tag pattern accepts `vX.Y.Z` and `vX.Y.Z-rc.N` only (`:33`).
- **Signing** (`docs/release-signing.md`): Minisign over `checksums.txt` whose signed trusted comment is exactly `repo=<owner/repo>;tag=vX.Y.Z`; the public key is published out of band; at most two keys in the embedded trust set (rotation overlap); no unsigned fallback; archive cap 128 MiB; the tag workflow requires an annotated exact-semver tag where the event SHA equals the tag target equals `origin/main`; Windows binaries are intentionally not shipped until Authenticode exists (`scripts/verify-release-distribution-policy.sh`). Trust anchors are linker-injected, default `UNSET`, so source builds refuse network self-update (`internal/update/upgrade/download.go:53-57`).
- **Release assets** also include `gentle-ai-release-provenance-v1.tar.gz` and `gentle-ai-review-provider-contract-1.2.0.tar.gz` (v2.5.0..v2.8.0 notes) `[CERT-a]`.
- Release notes carry a `## Provenance` block and a `Numbers` section with the counting baseline ([Block 28] §28.1) `[CERT-a]`.

Kit equivalent `[CERT]`: `research-sdd/install/research-sdd-install.sh:26-43,271-314` records `profile=` and `sha256=` of each deployed file so a managed overwrite is distinguished from a hand edit — checked only at install time. No release signing, no provenance manifest and no release job exist; a grep for minisign/cosign/attest over `.github` and `install/` returned nothing. `.github/workflows/` holds `pr-check.yml` and `toolbelt-tests.yml` only.

## 32.8 — Agent builder `[CERT]`

`internal/agentbuilder/{engine,installer,parser,prompt,registry,types}.go` plus `PRD-AGENT-BUILDER.md` (v0.1.0-draft, 2026-04-03): the user describes an agent in the TUI, an installed AI agent generates a SKILL.md, it is validated and installed across all configured harnesses. `[INFER]` Low relevance to the kit (one skill, one adapter file).

## 32.9 — Open questions

- `[GAP]` The exact `sync` write list per harness (needs `internal/pipeline` / `internal/planner` read or a dry run on a scratch HOME; mutating subcommands were barred).
- `[GAP]` Whether v4.0.0 prunes stale `sdd-*` agents on this machine.
- `[GAP]` Bench journey IDs were not counted per journey; no driven run executed.
- `[GAP]` `.github/workflows/release.yml` and `scripts/release-signing-preflight.sh` were not opened; signing enforcement is `[CERT-a]`.

## 32.10 — Connections

- **[Block 26]/[Block 27]** — configurator and state; deltas in [Block 28] §28.6, §28.8.
- **[Block 25]** — the harness set, now different; adapter directory list in §32.1.
- **[Block 22]** — the skill registry survives (§32.4); phase-common does not.
- **[Block 24]** — `judgment-day` and the `jd-*` agents (§32.2, §32.3).
- **[Block 17]** — delivery strategy lives on in ODD (§32.5).
- **[Block 29]**, **[Block 30]** — the skills of §32.3 in use.
- **[Block 31]** — managed assets digest ↔ `managed_assets_outdated`; hooks.
- **[Block 33]** — adoption candidates: whole-bundle managed digest and `--verify`, registry-name skill resolution, a journey corpus, a Route/Evidence task template, prune-on-sync test, release provenance only if the kit starts tagging.
