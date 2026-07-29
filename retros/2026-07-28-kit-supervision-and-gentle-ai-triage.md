<!-- review-status: pending -->
# Retro — sdd-investigacion · kit supervision + gentle-ai triage · 2026-07-28 · Research-SDD self-retrospective

> Run reviewed: a supervision/maintenance session over the kit itself, plus a `/research-sdd` triage of the
> `sdd-mental-model` corpus (27 blocks) against gentle-ai v2.2.0. Trigger: operator request, then corpus-staleness
> discovery. No knowledge blocks were authored — this run produced kit instruments and a gap diagnosis.
> Method: the kit was read directly (`METHODOLOGY.md`, `PROMPT-LOOP.md`, `TARGETS.md`, `toolbelt/`) before any
> delta was proposed, and every claim below was verified against the repo or the live binary rather than recalled.
> READ-ONLY on the kit — this report only PROPOSES; kit changes are human-reviewed and human-committed (§18).

## Proposed kit deltas

| # | Proposed change | Target (file · §/section) | Evidence (block / commit / § / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | Add a REFRESH cycle: a mode that REWRITES a block whose subject moved, instead of only reporting it | `METHODOLOGY.md §13` + new `PROMPT-REFRESH.md` | §13 states "Output is an audit-delta, NOT a new knowledge block" and is READ-ONLY on the corpus; no cycle closes the loop | new | HIGH |
| 2 | Split subject-DRIFT from researcher-ERROR in the audit vocabulary — add `DRIFTED` alongside `REFUTED` | `METHODOLOGY.md §13` · `PROMPT-AUDIT.md` | `REFUTED` today means "the source contradicts it", conflating "you were wrong" with "it was true at v1.43.2 and the world moved to v2.2.0" | new | HIGH |
| 3 | Stamp the SUBJECT's version in every block header, next to `SOURCES` | `METHODOLOGY.md §4` · `templates/` block anatomy | 1 of 27 blocks names a gentle-ai version (`rg -l 'v1\.4[0-9]\.[0-9]'`); staleness was undetectable mechanically and needed a 6-minute mapper | new | HIGH |
| 4 | Extend the tool doctrine from 2 cases to 4: add ADAPT/FORK, CREATE, and UPDATE-IN-USE | `METHODOLOGY.md §10` · `PROMPT-LOOP.md` (loop steps) | §10 covers only INSTALL of a third-party tool; `tool-registry.md` covers USE of a kit tool. 265 target-grown tools exist with no doctrine (`sweep-tools.sh`) | new | HIGH |
| 5 | BOOTSTRAP must seed `tools/` + `tools/README.md` carrying the WHY per tool (used / adapted / downloaded / created / updated) | `PROMPT-LOOP.md` BOOTSTRAP step (currently lines 119-120) | BOOTSTRAP creates `INDEX.md · RESEARCH-STATE.md · sources/SOURCES.md · retros/ · .gitignore` — `tools/` is absent, yet 6 targets invented one anyway | new | MEDIUM |
| 6 | The kit repo must register ITSELF in `TARGETS.md` at init, and a gate should flag a kit that is not in its own registry | `PROMPT-LOOP.md` BOOTSTRAP · `toolbelt/verify-registry.sh` | `rg 'sdd-investigacion' TARGETS.md` returned nothing until 2026-07-28: the fleet supervisor was the one corpus its own instruments never looked at | new | MEDIUM |

For each delta above, one line of rationale (WHY it matters, what it costs, expected impact):

1. **Refresh cycle.** The kit can DETECT rot and cannot REPAIR it, so a stale corpus stays stale while an audit report accumulates next to it. Cost: one new prompt contract plus a write path into an existing block, which breaks the "blocks are append-only" habit and needs an explicit provenance rule (what happened to the old text). Impact: a corpus becomes maintainable rather than write-once.
2. **`DRIFTED` vs `REFUTED`.** The two demand opposite treatment — a wrong claim is deleted, a drifted claim is VERSIONED, because whoever reads a v1.x artifact still needs the v1.x truth. Cost: one vocabulary term and a column in the audit template. Impact: refresh runs stop destroying still-useful history.
3. **Subject version stamping.** Without it you cannot mechanically ask "which claims are scoped to v1.43.2?" — today the only answer is to re-read 27 blocks. Cost: one header line per block and a backfill pass. Impact: staleness becomes a query instead of an investigation, and it is the precondition that makes deltas 1 and 2 cheap.
4. **Four-case tool doctrine.** The kit records tool DECISIONS only at retro time, and only for created/adapted/outgrew; the fourth case — a tool already in use getting UPDATED — has no home at all, which is exactly how gentle-ai moved 1.43.2 → 2.2.0 with nothing recording it. Cost: doctrine text plus a per-iteration reporting obligation. Impact: the tool decision is captured when it is made rather than reconstructed at the end, which is the failure mode the retro template itself warns about.
5. **Seed `tools/`.** Six targets independently created a `tools/` dir and two wrote a `tools/README.md`; the kit never asked for either, so the convention is re-invented per target and lost per target. Cost: two lines in BOOTSTRAP and a template file. Impact: the WHY lands next to the tool at the moment of writing, which is the only moment it is cheap.
6. **Self-registration.** An unregistered kit is invisible to `verify-registry.sh`, `sweep-retros.sh`, `sweep-audits.sh` and `sweep-tools.sh`, all of which derive their target list from `TARGETS.md`. Cost: one BOOTSTRAP step and one gate. Impact: the supervisor stops being exempt from its own supervision.

## Already covered (dedupe — proof the retro read the kit first)

- **Installing a third-party tool the toolbelt lacks** — `METHODOLOGY.md §10` (self-provisioning via `install-tool.sh`, logged to `toolbelt/INSTALLED-TOOLS.md`, with a Tools Report at loop end, and MCP-server capabilities explicitly counted as tools). Delta 4 EXTENDS this; it does not replace it.
- **Choosing which kit tool fits an artifact type** — `toolbelt/tool-registry.md` (artifact type → tool → wrapper).
- **Recording tools a run created / adapted / outgrew** — `templates/retro.template.md`, TOOLS section, added in `bf84d33`. Delta 4's contribution is moving the capture EARLIER (into the loop) and adding the UPDATE case.
- **Detecting that an existing claim no longer holds** — `METHODOLOGY.md §13` audit mode, with `ESCALATED / CONFIRMED / DOWNGRADED / REFUTED`. Deltas 1-2 build ON this rather than replacing it.
- **Not auto-applying findings to the kit** — `propose-never-apply`, named in `TARGETS.md:35`, `METHODOLOGY.md` §13/§18/§20 and `verify-registry.sh:15,244`. This retro obeys it.
- **Honest maturity labelling** — §13 already declares itself `PROVEN-ONCE, not battle-hardened` and §20 `DEFINED-BUT-UNEXERCISED`. No delta needed; the kit does not oversell itself.

## Anti-patterns observed (optional)

- **Doctrine that lives only on the authoring machine.** The "orchestrator delegates" rule and the model split lived solely in `~/.claude/CLAUDE.md` and a local Engram DB. A second developer's clone inherited the hooks (`.claude/settings.json` is versioned) but not the doctrine, and defaulted to inline execution — correctly, since the harness default says "Do not call the AgentTool unless the user requested it". Closed this session by adding a repo-root `CLAUDE.md`. → the delta that would have prevented it: #6's general principle, that shared behaviour belongs in the shared artifact.
- **A sub-agent reporting "verified" for claims it did not verify.** Three separate agents this session returned mechanically-correct work with incorrect characterisations of it: a fabricated commit citation, a wrong exit-code claim, a shellcheck command that silently skipped 47 files, and two Python tool trees described as "JS/TS build trees". Every one survived the agent's own verification report. → supervision rule: verify the REPORT's citations, not just the artifact.
- **Counting by hand when an instrument was cheap.** The orchestrator hand-counted 115 target tools across 6 hand-picked targets; the instrument found 265 across 18. A 2.3× error that existed only because the count was eyeballed. § METHODOLOGY §13 already says "Backlog SIZING comes from a MEASURED count, never a hand-guess" — the rule existed and was not followed.

## Tools built, adapted, or outgrown

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | `toolbelt/sweep-tools.sh` · fleet tool census + T-row ledger reconciler | — | — | — | `promote` · already authored directly into the kit (this target IS the kit); 11 cases + 2 mutation teeth, suite 75/1478 |
| T2 | `toolbelt/lib/target-paths.sh` · shared target-path derivation understanding `$RESEARCH_HOME` | the derivation was copy-pasted verbatim in `verify-registry.sh:48`, `sweep-retros.sh:39`, `sweep-audits.sh:37` | — | — | `promote` · in kit; retrofit of the three consumers is the following work unit |
| T3 | — | `tools/gen-catalog.py` (repo root) vs `$KIT` generator · hard-codes `^sdd-mental-model-bloque(\d+)\.md$` instead of the generic prefix-aware discriminator | — | — | `absorb` · fold prefix-awareness into the kit generator; `research-sdd-archive.sh` already prefers a target's local generator, and `tests/gen-catalog.test.sh:18,130` documents the divergence |
| T4 | — | — | — | — | `no` · no throwaway probes written this run; the session produced instruments, not one-off scripts |

## Metrics

- **Blocks reviewed**: 0 (no knowledge blocks authored — supervision + triage run)  ·  **§14 cross-block corrections in this run**: 0  ·  **Rules skipped in practice**: 1 (the measured-count rule of §13, see anti-patterns)
- **Corpus staleness diagnosed**: 8 STALE · 11 INCOMPLETE · 8 CURRENT of 27 blocks
- **Fleet tools surfaced**: 265 across 18 targets · 0 recorded in any retro
- **Suite**: 74 suites / 1467 cases → 75 / 1478, 0 failures

## Honest verdict

The kit's supervision instruments are good at finding drift and bad at closing it. Every gap this run
surfaced has the same shape: something valuable is produced inside a run — a tool, a doctrine, a corpus —
and the kit provides no path back to the shared artifact. That is one structural defect wearing four
costumes, and deltas 1-6 are the same fix applied at four layers.

The three-case honesty check: the instruments built this run are TESTED and MEASURED, not asserted. The
gentle-ai triage is a DIAGNOSIS, not a refresh — no block was updated, and the corpus is still a full
major version stale. The refresh itself is deliberately NOT started, because upstream declares the new
`review` subsystem unstable (`Cellar/gentle-ai/2.2.0/README.md:21`), and documenting a declared-moving
target would reproduce the exact rot this retro proposes to fix.
