# VM spine + remaining-backlog global re-plan

Planning artifact (English, neutral register). NOT code. Re-plans the 16 remaining
Research-SDD toolbelt backlog items into ordered, reviewable units BEFORE the
implementation loop resumes. Batch1 (PR #56) is merged; items 1,2,4,5,6,7,13,14,15,16
are done, plus a partial item-24 cleanup pass (local `fa9ae5e` on
`research-sdd/toolbelt-cleanup-followups`).

Location note: kept alongside the `*.v1.md` contracts in `research-sdd/toolbelt/`
(house convention for toolbelt design docs). Superseded on completion by
`tool-registry.md` rows + the per-adapter `*.v1.md` specs.

---

## 0. The re-plan thesis (shared-helpers-forward)

Items **3, 9, 10, 11, 12** all do the same shape of work: run a tool inside a
disposable VM/sandbox under hard limits, snapshot, and emit a content-addressed
receipt. `vm_receipt.py` (`vm-run-receipt.v1`) already implements the *receipt*
half — build/validate/verify, no VM launch. What is duplicated-in-waiting is the
*other* half: parsing/validating limits, building a secret-free argv+env plan,
snapshot policy, and — critically — the **authorization gate** that separates the
buildable-now offline plan from the live, dangerous executor.

**Decision — build two foundation units FIRST so every downstream item is
correct-by-construction (the same payoff U-C1 `emit_evidence` gave batch1):**

- **U-F1 — gate-authorization convention** (`lib/gate.py` + `gate-authorization.v1.md`).
  One fail-closed authorization boundary shared by every gated item (3,8,9,10,11,17,18).
- **U-F2 — VM run-plan + determinism/limits/snapshot builder** (`lib/vm_plan.py` +
  `vm-run-plan.v1.md`). Turns `(tool, argv, inputs, limits, snapshot policy, profile)`
  into a canonical offline **run-plan**, reusing `vm_receipt.py`'s spec fields and
  secret-rejection, and exposes ONE `execute(plan, live_executor=None)` seam. This
  IS item 12's offline deliverable.

Without these, items 3/9/10/11/12 each re-derive limits parsing, snapshot hashing,
receipt assembly, secret-free argv, and the gate refusal — the U8/U10 "new
surface added without the shared guard" bug class. With them, each new VM adapter
reduces to: build a plan dict + a domain evidence schema + call the seam.

A **second** consolidation (isolation `_PROFILE` dicts duplicated across every
adapter → one `isolation-profile.v1`) is real but is NOT forward-pulled: it does
not gate downstream correctness. It is folded into item 21 (U-A21).

---

## 1. Gate flag convention (single family)

Three capability gates, one convention:

| Capability token | CLI flag | Covers items | Live resource |
|---|---|---|---|
| `exec` | `--allow-exec` | 3, 9, 10, 11 (and 12 live) | run untrusted code in VM/sandbox |
| `live-capture` | `--allow-live-capture` | 8 | open a network interface |
| `docker` | `--allow-docker` | 17, 18 | heavy Docker (+ FACT service network) |

Rules (enforced by `require_gate(cap, args)` in U-F1):

1. **Default OFF, fail-closed.** Flag absent → the adapter builds and writes the
   canonical run-plan (and the would-be receipt spec) into the output dir, then
   exits with a distinct **`authorization-required`** code. It NEVER touches the
   live resource. The offline slice is always fully exercised.
2. **Explicit per-invocation.** No env var alone can cross the gate; the CLI flag
   is the authorization. (Env is only a test seam — see 3.)
3. **Test seam mirrors the house `*_TEST_ONLY` pattern.** `RSDD_<CAP>_EXECUTOR`
   points the live executor at a stub (as `RSDD_BINWALK_TEST_ONLY` does for
   binwalk), so suites exercise the post-gate path without real exec/docker/capture.
4. **Defense in depth at the seam.** Crossing also requires the environmental
   capability (setcap for capture, a reachable docker socket, a disposable VM
   image); the executor re-verifies and fails closed if absent.

This is the "clean seam where the authorized live executor drops in behind an
explicit flag" that every gated item must ship.

---

## 2. Ordered unit list

Each unit ≤400 authored physical touched lines (adapter + its TDD suite). Where a
unit risks exceeding, a pre-authorized split is noted.

| # | ID | Item(s) | Scope (one line) | Depends on | Gate | Review lens |
|---|---|---|---|---|---|---|
| 1 | **U-F1** | (8,9,10,11,17,18 foundation) | `lib/gate.py` + `gate-authorization.v1.md`: fail-closed `require_gate`, `--allow-<cap>` family, offline-plan-print + `authorization-required` exit, `RSDD_<CAP>_EXECUTOR` test seam | — | — | **full 4R** (authorization boundary) |
| 2 | **U-F2** | 12 | `lib/vm_plan.py` + `vm-run-plan.v1.md`: canonical offline run-plan (limits/snapshot/profile/secret-free argv) reusing `vm_receipt` spec; `execute(plan, live_executor)` seam | U-F1, `vm_receipt.py`(done) | — | **full 4R** (limits + secret rejection) |
| 3 | **U-V3** | 3 | `corroborate_compress.py` + `compress-vm-evidence.v1.md`: bounded gzip/xz decompress-in-VM plan (ratio/output/wall bomb caps), would-be receipt; live behind `--allow-exec` | U-F1, U-F2 | exec | review-risk |
| 4 | **U-V9** | 9 | `corroborate_trace.py` + `trace-evidence.v1.md`: gdb/strace/ltrace run-plan on a sample + parser of a captured trace log → evidence; live behind `--allow-exec` | U-F1, U-F2 | exec | review-risk |
| 5 | **U-V10** | 10 | `corroborate_qemu.py` + `qemu-emulation.v1.md`: qemu-system/user-static invocation plan, snapshot policy, receipt-spec builder; live behind `--allow-exec` | U-F1, U-F2 | exec | review-risk |
| 6 | **U-V11** | 11 | `corroborate_detonate.py` + `detonation.v1.md`: disposable-VM detonation orchestration plan (pre-snap → run → post-snap → artifact diff) tied to `vm-run-receipt`; live behind `--allow-exec` | U-F1, U-F2, (U-V9,U-V10 soft) | exec | **full 4R** (hostile sample) |
| 7 | **U-N8** | 8 | `corroborate_capture.py`/`capture.sh` + `live-capture.v1.md`: bounded tshark/tcpdump live-capture plan (iface allowlist, BPF validation, pkt/byte/wall caps) → pcap → hand off to EXISTING offline pcap corroborator; live behind `--allow-live-capture` | U-F1, corroborate-pcap(done) | live-capture | review-risk |
| 8 | **U-D17** | 17 | `corroborate_emba.py` + `emba-evidence.v1.md`: EMBA docker-run plan (image digest pin, ro-input, net-none, limits) + EMBA-JSON→envelope mapping; live behind `--allow-docker` | U-F1, `emit_evidence`(done) | docker | review-risk |
| 9 | **U-D18** | 18 | `corroborate_fact.py` + `fact-evidence.v1.md`: FACT Core REST/Docker connector plan (upload/poll spec) + response parser; live behind `--allow-docker` | U-F1 | docker | review-risk |
| 10 | **U-C24a** | 24 | Migrate `corroborate_firmware.py` + `firmware_carve.py` to shared helpers (sqfs superblock, publish, sandbox); retire the module-level `run` alias (`adapter_core.py:527-530`) | helpers(done) | — | review-risk (bind/publish) |
| 11 | **U-C24b** | 24 | Migrate pcap family (`corroborate_pcap.py`, `pcap_flows.py`) to `_PCAP_MAGIC`/`_PCAPNG_MAGIC` + `emit_evidence` | helpers(done) | — | review-risk |
| 12 | **U-C24c** | 24 | Migrate `squashfs_extract.py` to shared sqfs superblock + `assert_safe_bind_root` | helpers(done) | — | review-risk |
| 13 | **U-A19** | 19 | Harness sweep parity: wire Claude hooks for `sweep-audits`/`verify-registry` so Claude matches OpenCode's 4-script sweep; confirm Codex manual-doc lists all 4; parity test | — | — | review-reliability |
| 14 | **U-A20** | 20 | Hooks hardening + Codex auto-execution path (or documented constraint if runtime cannot auto-run); improve degrade-to-silence envelopes | U-A19 | — | review-resilience |
| 15 | **U-A21** | 21 | Homogenize: one `isolation-profile.v1` shared constant/validator replacing inline `_PROFILE` dicts; homogenize model + reasoning-level map across `claude/opencode/codex` (adapters.sh + model-variants) | U-A19, U-C24a/b/c | — | review-readability |
| 16 | **U-Z22** | 22 | Comprehensive verification of ALL adapters — reuse `tests/run-all.sh --prove-teeth`; add suites for gate/vm_plan/new adapters' dry-run + stubbed live path; verification report | ALL above | — | (verification) |
| 17 | **U-Z23** | 23 | Contracts/docs/registry review — add `tool-registry.md` rows for every new adapter; reconcile each `*.v1.md`; update `INSTALLED-TOOLS.md`/`detect-tools.sh` | U-Z22 | — | review-readability |
| 18 | **U-Z25** | 25 | Final cumulative 4R over the full branch diff (fresh `review/start`) | U-Z23 | — | **full 4R** |
| 19 | **U-Z26** | 26 | Slice the branch into reviewable PRs by track; prepare commits | U-Z25 | — | (packaging) |

Dependency spine: `U-F1 → U-F2 → {U-V3,U-V9,U-V10,U-V11}`; `U-F1 → {U-N8,U-D17,U-D18}`;
`U-C24{a,b,c}` independent of the VM track (can interleave); agent track
`U-A19 → U-A20`, `{U-A19,U-C24*} → U-A21`; closeout `→ U-Z22 → U-Z23 → U-Z25 → U-Z26`.

---

## 3. Gate boundary map (offline slice vs live slice)

Every gated item ships its offline slice now; the live executor drops in behind the flag.

| Item | OFFLINE (build now, no auth) | LIVE (behind flag) | Flag |
|---|---|---|---|
| 3 gzip/xz-in-VM | decompress plan + bomb caps (ratio/output/wall) + would-be receipt spec | run gzip/xz inside the disposable VM | `--allow-exec` |
| 8 live capture | capture plan (iface allowlist, BPF validation, pkt/byte/wall caps); handoff to done offline pcap corroborator with a canned pcap | open the interface with tshark/tcpdump | `--allow-live-capture` |
| 9 traces | tracer command-plan + `trace-evidence.v1` + parser of a PRE-captured trace log | execute sample under gdb/strace/ltrace in sandbox/VM | `--allow-exec` |
| 10 QEMU | qemu invocation plan (machine/kernel/rootfs/snapshot/limits) + receipt-spec builder | boot qemu-system / run qemu-user-static | `--allow-exec` |
| 11 detonation | orchestration plan (pre-snap→run→post-snap→diff) + `detonation.v1` receipt assembly | boot disposable VM, run hostile sample, revert snapshot | `--allow-exec` (strongest) |
| 17 EMBA | docker-run plan (digest-pinned image, ro-input, net-none, limits) + EMBA-JSON→envelope map | `docker run` EMBA | `--allow-docker` |
| 18 FACT Core | REST connector plan (upload/poll) + response→`fact-evidence.v1` parser | talk to a running FACT instance | `--allow-docker` |

Seam contract (from U-F1): absent flag → write plan + would-be receipt spec to the
output dir, exit `authorization-required`, never touch the live resource. Present
flag → `execute(plan, live_executor)` runs; `vm_receipt.build_receipt` records the
result. Suites drive the live path via `RSDD_<CAP>_EXECUTOR` stubs.

---

## 4. Non-toolbelt track (19, 20, 21) — assessment

These are **agent-integration, not RE adapters**: they live in
`research-sdd/install/` (`adapters.sh`, installer, golden plans),
`research-sdd/toolbelt/opencode/` (`research-sdd-sweep.ts`), and the Claude
`.claude/settings.json` hooks — a different blast radius from the VM/gate track.

**Assessment: keep in-loop, but as a clearly separated 3-unit Agent-Integration
track sequenced after the RE adapters and before closeout** (closeout item 22
"verify ALL adapters" and item 23 registry review must run after them). They do
NOT share the gate/VM foundation and must not inflate those reviews. If review
budget is tight, U-A19/20/21 are cleanly extractable into their own SDD change —
but sequencing them in-loop keeps items 22/23 truthful about "all adapters".

Concrete scope (the machinery already exists — `adapters.sh` renders all three
harnesses; `research-sdd-sweep.ts` bridges OpenCode):

- **U-A19 parity (item 19):** OpenCode fires 4 sweep scripts; Claude currently
  wires only 2 (`sweep-retros`, `verify-kit-clean`) and Codex fires none
  (`needs_manual_sweep_doc=true`). Parity = add Claude hooks for `sweep-audits` +
  `verify-registry` (hook scripts `sweep-audits-hook.sh`/`verify-registry-hook.sh`
  already exist) and confirm the Codex manual-doc lists all four. Files:
  `.claude/settings.json`, the two hook wrappers, a parity test.
- **U-A20 hooks + Codex auto-exec (item 20):** harden hook envelopes
  (degrade-to-silence, once-per-session), and give Codex a session-start
  auto-execution path if its runtime supports a startup command; otherwise
  document the constraint precisely in the installer's Codex section.
- **U-A21 homogenize (item 21):** two homogenizations — (a) replace the inline
  `_PROFILE` dicts in every adapter with one `isolation-profile.v1` shared
  constant/validator (rides on U-C24 consolidation); (b) homogenize the model +
  reasoning-level assignments across `claude/opencode/codex` in `adapters.sh` +
  the `model-variants` plugin, and the evidence-envelope conventions doc.

---

## 5. Closeout track (22, 23, 25, 26 + rest of 24)

Order and content:

1. **U-C24a/b/c (item 24 rest)** land BEFORE closeout so item 22 verifies the
   consolidated tree, not pre-migration duplicates. Each is behavior-preserving
   but touches the security boundary (bind roots, `publish`, superblock parsing)
   → review-risk dominant lens each.
2. **U-Z22 (item 22)** — comprehensive verification. **Reuse `tests/run-all.sh`**
   (auto-discovers `*.test.sh`/`*.test.mjs`; run with `--prove-teeth` for the
   mutation/negative control). Add suites for `gate`, `vm_plan`, and each new
   adapter's dry-run + stubbed-live path. Emit a verification report; every suite
   must exit 0 and the aggregate `Suites failed: 0`.
3. **U-Z23 (item 23)** — contracts/docs/registry review. Add `tool-registry.md`
   rows for all new adapters (compress-vm, trace, qemu, detonation, live-capture,
   EMBA, FACT, plus `gate` and `vm-run-plan` infra); reconcile every `*.v1.md`;
   update `INSTALLED-TOOLS.md` and `detect-tools.sh` capability rows.
4. **U-Z25 (item 25)** — final cumulative 4R over the whole branch diff (one fresh
   `review/start`); full 4R because the cumulative surface crosses security/exec.
5. **U-Z26 (item 26)** — package into reviewable PRs by track: (A) foundation
   `U-F1/U-F2`; (B) VM-offline `U-V3/9/10/11`; (C) docker `U-D17/18`; (D)
   live-capture `U-N8`; (E) refactor `U-C24a/b/c`; (F) agent-integration
   `U-A19/20/21`; (G) closeout docs. No push until this step.

---

## 6. Risk / ordering rationale

- **Full 4R (highest security-boundary risk):** U-F1 (the entire authorization
  boundary — a gate bug crosses to live exec/docker/capture), U-F2 (limits +
  secret-free argv/env; a miss lets a bomb or secret through), U-V11 (hostile
  detonation), U-Z25 (cumulative).
- **review-risk dominant:** U-V3/U-V9/U-V10 (define dangerous-exec plans, but the
  in-loop LIVE code is stubbed behind the gate, so the offline slice is lower
  risk) — escalate any of them to full 4R if that unit lands real executor code
  rather than a stub. U-N8/U-D17/U-D18 likewise (plan + parser). U-C24a/b/c
  (behavior-preserving but touch bind-safety/`publish`/superblock parsing).
- **Agent track:** U-A19 review-reliability (parity behavior), U-A20
  review-resilience (hook degradation / interop), U-A21 review-readability
  (consolidation/naming).
- **Ordering discipline:** foundation before any VM adapter (correct-by-construction);
  refactor before closeout (verify the consolidated tree); agent track before
  item-22 so "all adapters" is honest; cumulative 4R last.

Guiding invariant for the whole loop (unchanged from batch1): fail-closed, never a
silent partial; any cap/gate that fires is visible in `limitations`/`errors`;
digests bind every artifact; no live resource without an explicit per-invocation flag.
