# model-tiers.v1 — Harness-Neutral Model Tier Contract

**Status**: active
**Scope**: guidance (not enforced by the toolbelt; actual model selection is user-owned)

## Purpose

PROMPT-LOOP.md and METHODOLOGY.md describe model tier selection using Claude-specific
model names (`haiku`, `sonnet`, `opus`).  This document defines the same tiers as
harness-neutral abstract concepts so they apply consistently across all three supported
harnesses (Claude Code, Codex, Reasonix).

This is a documentation contract, not runtime configuration.  The toolbelt cannot
select, enforce, or verify which model a harness uses; that authority belongs entirely
to the user's per-harness configuration.

---

## 1. Abstract Tier Definitions

Three tiers cover all delegated roles in the research-sdd loop.  Each tier is defined
by its **job** and the **reasoning-effort class** it requires — not by a vendor name.

| Tier | Job | Reasoning-effort class | Typical task examples |
|---|---|---|---|
| **mechanical** | Enumerate, locate, grep-and-cite. No inference required; the answer is directly extractable from the source. | low | List all fields in a struct, find every call-site of a function, collect URLs/line refs, dump method signatures |
| **structural** | Read N files or classes, reconstruct how a subsystem works, judge what is load-bearing, return cited findings. Some inference required. | medium | Reconstruct a protocol flow across 3–5 files, summarize a library's public surface, verify adapter parity, 4R review lenses |
| **reasoning** | Security exploitability, architecture judgment, cross-subsystem inference, non-obvious deduction from incomplete evidence. | high | Exploitability assessment, architecture risk judgment, `[INFER]`-level synthesis |

**Driver / session model** (the parent loop that issues Agent/Task calls) stays on
the user's chosen session model regardless of tier.  The toolbelt does not assign
or modify the session model.

---

## 2. Per-Harness Mapping Table

These are **recommendations / defaults**.  They reflect what PROMPT-LOOP.md and
METHODOLOGY.md currently assign for Claude Code.  For Codex the mapping is indicative:
the actual model is always user-configured outside this repo.
(OpenCode support was dropped on 2026-09-23 #954.)

| Abstract tier | Claude Code (`model:` on Agent/Task) | Codex |
|---|---|---|
| **mechanical** | `model: 'haiku'` | `model` + `reasoningEffort: low` (user-set in `config.toml`) |
| **structural** | `model: 'sonnet'` (default for most sweeps) | `model` + `reasoningEffort: medium` |
| **reasoning** | Inline on driver; or `model: 'opus'` only if delegation is truly required | `model` + `reasoningEffort: high` |

**Fallback rule (all harnesses)**: when the recommended tier is unavailable, substitute
one tier down and note it in the report.  This rule is stated in PROMPT-LOOP.md (NORMAL CYCLE
step 3, MODEL TIER) and METHODOLOGY.md §8; it carries over to Codex unchanged.
**Exemption — verification/refutation voters**: if `sonnet` is unavailable for a verification or refutation step, run inline on the driver or defer — never substitute `haiku` (METHODOLOGY §11b).

---

## 3. Documented Limitation — Model Selection is Out-of-Repo

Concrete model selection, provider choice, profile, and reasoning-level are
**user-owned** and configured **outside this repository** for every harness:

- **Claude Code** — the `model:` parameter on an Agent/Task call is set by the
  session user (e.g. via `/model`).  The toolbelt only names the abstract tier.
- **OpenCode** — support dropped 2026-09-23 (#954); `toolbelt/opencode/` removed.
- **Codex** — model and `reasoningEffort` are set in the user's
  `~/.codex/config.toml`.  The installer's managed block covers MCP server
  registration only; model config is never written by the toolbelt.

The toolbelt cannot verify or enforce which model is actually used.  This tier map
is guidance; each harness's live configuration is authoritative.

---

## 4. Evidence Format — Already Harness-Independent

This section records the U-A21c verify-only finding so it does not need to be
repeated in future planning.

The research-sdd evidence and manifest formats (`analysis-manifest.v1`,
`emit_evidence` output, all `*.v1.md` JSON contracts) are already fully
harness-independent.  The same format is emitted regardless of whether the
adapter runs under Claude Code or Codex.  No homogenization is needed;
no agent-specific format variants exist.  The `analysis-manifest.v1.md` contract
is the authoritative schema reference for all harnesses.

---

## 5. Cross-References

- **PROMPT-LOOP.md NORMAL CYCLE step 3, MODEL TIER** — rule for delegated sweeps (Claude-named;
  this document is the harness-neutral canonical definition)
- **METHODOLOGY.md §8, "Match the delegated model to the sweep"** — same tier rule in the loop-longevity text
- **toolbelt/agent-integration-19-21.design.md §2 item-21b** — design rationale
  for this unit

---

## Claude profile — which models run what

The Claude profile uses the audited prompts on `main`.  The pre-audit baseline is
tagged `prompts-pre-audit-2026-09-23`.  Non-Claude / open models (Gemma 4, Qwen,
etc.) get a compact `general` profile — tracked in #993, not built yet.

These are the **documented defaults** for the Claude profile.  Model selection
stays user-owned (§3 above); this section is the canonical reference, not
runtime enforcement.

| Role | Model | Context | Notes |
|---|---|---|---|
| Driver / orchestrator (the session running `/research-sdd`) | Claude Opus 5.5 | 1M | `opus` tier alias → Opus 5.5 for delegated reasoning |
| `sonnet` alias | Claude Sonnet 5 | 1M | Structural sweeps, review lenses, verification/skeptic voters |
| `haiku` alias | Claude Haiku 4.5 | 200K | Mechanical sweeps only; never loads the full loop prompt + HOT-CORE; verification/refutation voters never drop to `haiku` (METHODOLOGY §11b exemption) |
