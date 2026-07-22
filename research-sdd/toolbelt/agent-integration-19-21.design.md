# Design: Agent-Integration Track (Backlog Items 19, 20, 21)

Scoping design for U-A19/U-A20/U-A21 of the Research-SDD toolbelt. Plan artifact only — no
implementation here. Supersedes the stale item-19 claim in `vm-spine-and-backlog.replan.md` §4.

## 1. Inventory — the agent-integration surface that EXISTS

| Surface | File : symbol | Fact |
|---|---|---|
| Harness adapter table | `install/adapters.sh` : `RESEARCH_SDD_HARNESSES`, `_RSDD_*` arrays, `rsdd_field`, `rsdd_render_section`, `rsdd_render_mcp_toml` | claude/opencode/codex; WHERE/HOW/WHAT table-driven, no per-harness branching |
| Installer | `install/research-sdd-install.sh` : `install_one`, `_rsdd_splice_file`, `_rsdd_link_plugin`, `_rsdd_register_mcp` | idempotent marked-block splice (CLAUDE.md / AGENTS.md / codex config.toml), opencode plugin symlink |
| Install tests + goldens | `install/tests/research-sdd-install.test.sh`, `install/tests/golden/plan-{claude,opencode,codex}.txt` | dry-run plans locked byte-for-byte; idempotency + preserve tests |
| Claude session-start hooks | `.claude/settings.json` (repo root) | wires **4** SessionStart hooks: `sweep-retros-hook.sh`, `sweep-audits-hook.sh`, `verify-registry-hook.sh`, `verify-kit-clean-hook.sh` (timeouts 15–30s) |
| Claude hook wrappers | `toolbelt/{sweep-retros,sweep-audits,verify-registry,verify-kit-clean}-hook.sh` | jq `additionalContext` envelope + plain fallback; stderr discarded (kit-clean: `2>&1`, rc 1 vs 2 distinguished) |
| OpenCode plugin | `toolbelt/opencode/research-sdd-sweep.ts` : `ResearchSddSweepPlugin`, `KIT_DIR/SWEEP/SWEEP_AUDITS/REGISTRY/KIT_CLEAN` | same **4** scripts via `experimental.chat.system.transform`; once-per-session; 20s timeout; numeric-vs-sentinel exit mapping |
| Codex leg | `adapters.sh` : `_RSDD_NEEDS_SWEEP[codex]=true` + `rsdd_render_section` manual-sweep block; `rsdd_render_mcp_toml` → `~/.codex/config.toml` | NO runtime hook; AGENTS.md section already lists all **4** scripts as manual run; MCP servers spliced into config.toml |
| Isolation profiles | `_PROFILE` dicts / inline literals in ~13 modules: `corroborate_{capa,floss,kaitai,native,java,ghidra,firmware,pcap,unblob}.py`, `pcap_flows.py`, `squashfs_extract.py`, `zip_metadata.py`, `zip_stored.py`; validator `analysis_manifest.py:382-385` | same 4-key shape everywhere; only `name` varies (+ ghidra's dynamic `network_access = not isolated`) |
| Model tiers | `PROMPT-LOOP.md:200-215` (MODEL TIER rule), `METHODOLOGY.md:392`, `SKILL.md` refs | Claude-named tiers (`haiku/sonnet/opus`); "one tier down if unavailable" is the only cross-harness rule |
| OpenCode model-variants | `~/.config/opencode/plugins/model-variants.ts` (referenced by `toolbelt/opencode/README.md`) | **user-owned, OUTSIDE the repo** — not kit-controlled |

Note: `verify-parity.sh` / `discriminator-parity.test.sh` are loop/adapter concerns, unrelated —
the new parity test needs a non-colliding name.

## 2. Per-item verdict (honest)

### Item 19 — Claude/OpenCode/Codex functional parity → **VERIFY + TEST + DOCS (no product code)**

Sweep parity **already holds**: Claude wires 4 hooks, the OpenCode plugin runs the same 4 scripts,
the Codex AGENTS.md section lists the same 4 (confirmed in `golden/plan-codex.txt`). The replan's
"Claude wires only 2" is stale. What is actually broken:

1. `toolbelt/opencode/README.md` parity note is stale ("SAME two underlying scripts", "two banners").
2. **No automated parity test** — drift already happened silently once (docs vs settings.json); nothing
   binds the three surfaces to one canonical script set.

Remaining differences are intentional harness capabilities, documented in the adapter table, not
closable in-repo: slash-command support (opencode only), plugin dir (opencode only), MCP config
splice (codex only), runtime hook (claude+opencode only). Document as designed asymmetries.

Effort: small (~150–250 lines, mostly the test). Risk: low (test + docs only).

### Item 20 — Hooks + Codex auto-execution → **DOCUMENTED CONSTRAINT + small shim (code+config+docs)**

**Codex has no session-start auto-execution hook.** `config.toml` supports MCP servers and
turn-completion `notify`, neither of which injects session-start context or runs a startup command.
This CANNOT be closed in-repo; it stays a documented limitation (the adapter table already models it
as `needs_manual_sweep_doc=true` — the honest mechanism). Re-verify against the installed Codex
version at implementation time; if a startup hook has appeared, that is a new follow-up unit, not
this one.

Best-effort shim (real, small): one aggregator `toolbelt/sweep-all.sh` that runs all four scripts
with the same banner headers and a per-script timeout, so the Codex manual instruction collapses
from four commands to ONE (raises compliance probability). `rsdd_render_section`'s manual-sweep
block then names `sweep-all.sh` (plus the four for reference) → regenerate `plan-codex.txt` golden.
Claude/OpenCode wrappers stay untouched (no churn; they already degrade to silence).

Hardening scope (small): per-script timeout inside `sweep-all.sh` (mirrors settings.json 15–30s /
plugin 20s); keep read-only + degrade-to-silence invariants; document the wrapper stderr-handling
asymmetry (`2>&1` only in kit-clean, deliberate) instead of "fixing" it.

Effort: small (~100–180 lines aggregator+test, ~20 lines render/golden). Risk: low-medium
(golden churn; shell subprocess — see threat matrix).

### Item 21 — Homogenize profiles / evidence / models / reasoning → **split verdict**

**(a) isolation-profile.v1 — real CODE, mechanical.** New `toolbelt/lib/isolation_profile.py`:
`make_profile(name, *, static_only=True, network_access=False, target_execution=False)` returning
the canonical 4-key dict, plus `isolation-profile.v1.md` contract. Migrate the ~13 inline sites;
ghidra's dynamic `network_access` uses the override kwarg. `analysis_manifest.py` remains the
envelope validator (asserts `target_execution=false`); the helper becomes the single *construction*
authority. Behavior-preserving: emitted evidence bytes must not change — existing adapter suites
lock this. Depends on U-C24a/b/c landing first (firmware/pcap/squashfs already being migrated;
avoid double-touch).

**(b) models / reasoning levels — DOCS/CONTRACT, not code.** The kit's MODEL TIER rule is written
in Claude model names. In-repo deliverable: a harness-neutral tier contract — `mechanical /
structural / reasoning` — with a per-harness mapping table (claude: haiku/sonnet/opus; opencode /
codex: nearest named equivalent + the existing "one tier down and note it" rule), added to
METHODOLOGY.md (or `model-tiers.v1.md`) and cross-referenced from PROMPT-LOOP.md:200. The actual
OpenCode `model-variants.ts` plugin and Codex model/reasoning-effort settings are **user-owned
config outside the repo** — cannot be homogenized in-repo; flag as limitation. (Adopting a
canonical model-variants copy under `toolbelt/opencode/` is a deliberate deferral, not in scope.)

**(c) evidence — VERIFY-ONLY.** Evidence envelopes are already harness-independent
(`analysis-manifest.v1` + `emit_evidence`); nothing agent-specific remains. State it, don't build it.

Effort: (a) medium (~250–350 lines across 15 files); (b) small docs. Risk: (a) low —
pure refactor under existing suites; (b) none.

## 3. Unit breakdown (each ≤400 authored lines)

| Order | Unit | Kind | Content | Deps | Lens |
|---|---|---|---|---|---|
| 1 | **U-A19** | verify + test + docs | New `install/tests/harness-sweep-parity.test.sh`: extract script set from `.claude/settings.json` (jq), `research-sdd-sweep.ts` (const paths), `rsdd_render_section codex` output; assert all equal the canonical 4-list. Fix `toolbelt/opencode/README.md` parity note (2→4). | — | review-reliability |
| 2 | **U-A20** | code + config + docs | `toolbelt/sweep-all.sh` (+ test: runs all four, per-script timeout, degrade-to-silence, read-only); update `rsdd_render_section` codex sweep text; regenerate `plan-codex.txt`; write the Codex no-hook constraint into `toolbelt/opencode/README.md` (or a sibling HARNESS-NOTES section) with the "re-verify on Codex upgrade" trigger. | U-A19 (canonical list is its input) | review-resilience |
| 3 | **U-A21a** | code | `lib/isolation_profile.py` + `isolation-profile.v1.md`; migrate ~13 modules; helper unit test (shape, defaults, override, `target_execution` immutable-false). If migration churn pushes past 400, split helper+contract / migration into 21a-i, 21a-ii. | U-C24a/b/c | review-readability |
| 4 | **U-A21b** | docs | Harness-neutral model-tier contract + per-harness mapping table; cross-refs in PROMPT-LOOP.md / METHODOLOGY.md; explicit out-of-repo limitation note (model-variants, codex reasoning effort). Evidence homogenization recorded as already-done. | — (parallel-safe) | review-readability |

Closeout items 22/23 (verify-all, registry/docs) run after, per the replan spine.

## 4. Cannot be done in-repo (documented limitations, not fake code)

- Codex session-start auto-execution — no runtime hook exists; manual-doc + `sweep-all.sh` is the ceiling.
- OpenCode `model-variants.ts` — user-owned under `~/.config/opencode/plugins/`; kit can only document the mapping.
- Codex model / reasoning-effort selection — user-owned `~/.codex/config.toml`; the installer's managed block covers MCP servers only, by design (never clobber user model config).
- Slash-command asymmetry — harness capability, already table-modeled (`supports_slash_commands`).

## 5. Tested vs doc-only deliverables

**Tested**: parity assertion (U-A19 test IS the deliverable); `sweep-all.sh` behavior (timeout,
silence-on-failure, read-only); render-text changes (existing install goldens); isolation-profile
helper + migration (new unit test + existing adapter suites proving unchanged evidence).

**Doc/contract only** (no runtime test possible): Codex constraint note, model-tier map,
`isolation-profile.v1.md` prose, README parity-note fix — locked only where they overlap rendered
installer output (goldens).

## 6. Threat matrix (applicability)

| Row | Status | Note |
|---|---|---|
| Subprocess execution | Applicable (U-A20) | `sweep-all.sh` runs a FIXED list of sibling kit scripts, no user-controlled argv; per-script timeout; failure → silence, never blocks session start. RED tests: missing script, hanging script, non-zero exit. |
| Shell command injection | N/A | no user input reaches any argv in this track |
| VCS/PR automation | N/A | read-only surfacing; `verify-kit-clean.sh` only reports |
| Routing / executable classification | N/A | not touched |
| Process integration (hooks) | Applicable (U-A19/20) | three surfaces must not diverge → the parity test is the standing control |

## 7. Open questions

- [ ] Does the currently installed Codex version expose any startup-exec/config hook? (Check at
  U-A20 implementation time; expected NO — constraint stands.)
- [ ] Should `rsdd_render_section`'s claude/opencode legs also mention `sweep-all.sh`? Default NO
  (their automated surfaces make it noise); revisit only if goldens are already being regenerated.
