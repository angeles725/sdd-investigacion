# Cross-Slice Invariant Registry

## Why this file exists

The independent PR-level review of #59 found three defects — F1, F4 and F5 —
that a full per-slice 4R review had passed. None of them was a fault *inside* a
slice. Every one of them lived in the **interaction between slices**: a receipt
written by one module, consumed by another; an argv assembled in one place,
mounted in another. Component-level tests cannot see those, because each
component was individually correct.

The structural fix is not more review. It is to turn every cross-slice defect
into an **executable invariant** that runs on every unit, forever. A defect
found once by a reviewer is a lesson; a defect encoded as an invariant is a
guarantee.

## Rules

1. **Every cross-slice finding raised by a PR-level review MUST become an entry
   here, with a test, before its follow-up issue is closed.** Fixing the
   instance without adding the invariant is not a complete fix.
2. Each unit re-verifies the whole registry, not just the invariants it touches.
   That is the point: the registry exists to catch interactions the author of a
   unit did not think about.
3. An invariant with `status: pending` names a defect that is **currently live
   in the codebase**. The registry is therefore also the honest inventory of
   known-broken guarantees.
4. An invariant that cannot be asserted offline must say so and name what it
   asserts *instead*. See `untestable_offline` in `config.yaml`.

## Registry

### INV-1 — a detonation receipt binds the sample it describes

**Statement:** any `detonate`/`trace` receipt MUST carry the sha256 of the exact
sample that was injected. A receipt that does not bind its sample is evidence
about nothing.

- **Origin:** finding F1, PR #59 independent review.
- **Status:** `enforced` — fixed in commit `aa38384`.
- **Asserted by:** `tests/detonate-exec.test.sh` (RED13 only). The trace-side
  receipt `inputs[]` assertion is not yet written; tracked by issue #68.

### INV-2 — every path in the emitted argv is reachable under the emitted mount set

**Statement:** for each `-drive file=` path in the emitted qemu argv, that path
MUST be reachable inside the sandbox given the bwrap mount set emitted alongside
it. A path that is masked by a `--tmpfs` or simply never bound is a silent
failure: the plan looks correct and the real boot cannot open the file.

**Named follow-up (kernel / BIOS roms — design.md §5.2 gaps 3/4):** The kernel
(`-kernel`) and BIOS rom paths also require reachability but are not yet asserted
here. INV-2 is `enforced` for all `-drive file=` slots; kernel/BIOS reachability
is a separate open item tracked by design.md §5.2 and must NOT be conflated with
this invariant.

**Reachability is ORDER-AWARE, not set-based.** bwrap applies mount operations
in argv order. A `--bind` placed *before* a `--tmpfs` covering the same subtree
is silently re-masked, and a set-containment check would call that argv valid.
The assertion must compare positions, not membership.

- **Origin:** finding F5, PR #59 independent review. Tracked by issue #60.
- **Status:** `enforced` — fixed by issue #60 (commit slice 1). The scratch
  file-scoped bind `--bind <scratch> <scratch>` is now emitted after `--tmpfs /tmp/rsdd`,
  and `lib/vm_disk_policy` enforces the ordering at every preflight (R-REACH, R-BIND-RW).
  Previously violated: `--tmpfs /tmp/rsdd` masked the host scratch at
  `/tmp/rsdd/rsdd-<uuid>/scratch.img` — reproduced against real bwrap 0.9.0 and real qemu:
  `Could not open '/tmp/rsdd/.../scratch.img': No such file or directory`.
- **Scope of the #60 fix — the scratch is 1 of 4 reachability gaps.** The
  emitted argv also cannot reach the qemu binary (no `/usr` in the sandbox),
  the kernel, or the BIOS roms. #60 closes the scratch gap ONLY. The emitted
  argv remains **not live-runnable** afterwards, and the operator WARNING added
  in `aa38384` must be REWRITTEN to name the remaining gaps — never deleted.
  Deleting it would make a partial fix read as a complete one, which is the F5
  hazard class repeating.
- **Rejected approach:** `--bind <run_dir> <run_dir>` (the direction originally
  suggested by issue #60) is REJECTED on evidence. A guest-side write inside a
  directory-scoped bind lands on the host, where `output_files(run_dir)`
  (`lib/vm_boot_core.py:160`) sweeps it into the frozen receipt's `outputs[]` —
  turning a qemu escape into evidence-chain pollution. The **file-scoped**
  `--bind <scratch> <scratch>` is strictly tighter: writes propagate, sibling
  creation lands on the sandbox tmpfs, and `rm`/`mv`/`ln -sf` against the
  scratch fail `EBUSY`, pinning the hashed inode so the guest cannot swap the
  object out from under its own hash.
- **Offline limitation:** no offline test observes the real mount namespace. The
  invariant is asserted structurally — parse the emitted argv, parse the emitted
  bwrap mount set, prove order-aware reachability — never by booting.
- **Asserted by:** `tests/detonate-plan.test.sh` (T4c), `tests/trace-plan.test.sh` (T-scratch-bind),
  `tests/detonate-exec.test.sh` (RED-F5A), `tests/trace-exec.test.sh` (RED-F5A),
  `tests/vm-disk-policy.test.sh` (RED-BIND-ABSENT asserts R-BIND-RW fires when no bind is present;
  RED-REACH-ORDER asserts R-REACH fires on wrong-order bind — the only scenario where R-BIND-RW
  passes but R-REACH detects masking; GREEN-REACH-OK; GREEN-SUBST-INVARIANT).

### INV-3 — argv token substitution matches whole tokens, never substrings

**Statement:** when substituting a sentinel or placeholder into an argv, the
match MUST be against a complete token. Substring matching silently corrupts any
argument that happens to contain the sentinel as a prefix or infix.

- **Origin:** finding F4, PR #59 independent review. Tracked by issue #63.
- **Status:** `enforced` — fixed in `vm_exec_common._substitute_scratch_sentinel`
  (issue #63). The old `pre_boot` substring loop (`_SCRATCH_SENTINEL in tok`) was
  replaced with position-aware substitution covering exactly the three structural
  positions where the sentinel appears in the post-#60 argv.
- **Three-position contract (enforced):**
  1. `--bind SRC` operand — **complete-token match** (`tok == _SCRATCH_SENTINEL`).
  2. `--bind DEST` operand — **complete-token match** (`tok == _SCRATCH_SENTINEL`).
  3. `-drive file=` value — **key-scoped infix substitution**: the sentinel is
     extracted from the comma-separated drive spec (e.g.
     `file=/rsdd/scratch.img,snapshot=off,format=raw,if=virtio`) by isolating the
     `file=` key's value and substituting only within it.
  Any other token containing the sentinel — whether as an exact match or a
  substring — is left untouched.
- **Asserted by:** `tests/detonate-exec.test.sh`:
  - `RED-INV3-bind-subst`: `--bind` SRC and DEST are substituted (complete-token).
  - `RED-INV3-drive-subst`: `-drive file=` is substituted, rest of spec intact.
  - `RED-INV3-adversarial`: adversarial tokens (`-kernel /rsdd/scratch.img` and
    `-bios /rsdd/scratch.img.bak`) are NOT rewritten (core F4 assertion).
  - `RED-INV3-sentinel-absent`: absent sentinel → empty deltas, argv unchanged.
  - `RED-INV3-drive-prefix`: `file=/rsdd/scratch.img.bak` in `-drive` left untouched (exact-match guard).
  - `RED-INV3-nonfile-key`: sentinel in `id=` key left untouched (exact `file=` value match).
  `tests/trace-exec.test.sh`:
  - `TRACE-RED-INV3-adversarial`: file= prefix path untouched on trace executor path (INV-3 shared code).
  - `RED-INV3-eval-seam` / `TRACE-RED-INV3-eval-seam`: adversarial property pinned at `evaluate()` seam (INV-3 wiring, not just helper).

### INV-4 — one run produces exactly one run_dir, and every output is declared

**Statement:** a single execution MUST create exactly one per-run directory, and
every artifact it produces MUST appear in `receipt.outputs[]`. Two run
directories means one of them leaks and its artifacts are unaccounted for.

- **Origin:** the D2 "double run_dir" defect — two CRITICAL findings during the
  4R review of the detonate executor, which forced a re-scope of the slice.
- **Status:** `enforced` — resolved by the single-run_dir + pre-boot callback
  seam in `lib/vm_boot_core.py`.
- **Asserted by:** `tests/detonate-exec.test.sh`, `tests/qemu-exec.test.sh`.

### INV-5 — teardown is guaranteed on every exit path

**Statement:** two obligations, because the per-run directory is deliberately
retained as evidence on a completed run:
1. **Process tree** — MUST be reaped on EVERY exit path (timeout, exception,
   early failure). A sandbox that leaks a live process on any path is not a
   sandbox.
2. **Per-run directory** — MUST be reaped when execution fails BEFORE boot
   evidence exists (any exception before `Popen` succeeds), and MUST be RETAINED
   after a boot begins (success or timeout), because the operator reads
   `scratch.img` and the snapshots post-teardown. Reaping run_dir on the
   success/timeout path would destroy the malware-analysis evidence — see the
   run-contract risk table in `detonate-run.v1.md` / `trace-run.v1.md`. Do NOT
   "fix" run_vm to rmtree run_dir on timeout to satisfy an over-broad reading.

- **Origin:** V1a/V1b containment hardening; re-confirmed by the #59 PR review;
  the process-tree/run_dir split was clarified by the #70 PR-level gate (F1).
- **Status:** `enforced` — process-tree reaper in `lib/proc_common.py`; run_dir
  early-failure reap in `lib/vm_boot_core.py` (`run_vm`'s pre-Popen guard).
- **Asserted by:** process tree — `tests/qemu-exec.test.sh` (RED6/RED7 killpg
  tree-reap); run_dir early-failure reap — `tests/detonate-exec.test.sh`
  (RED-INV5-earlyfail), `tests/trace-exec.test.sh` (TRACE-RED-INV5-earlyfail);
  run_dir success retention — `tests/detonate-exec.test.sh` (RED11).
- **Known gap (tracked):** an exception raised AFTER `Popen` succeeds but BEFORE
  the evidence try/finally begins can still leak a live process — see the
  follow-up issue for the post-Popen/pre-finally window.

### INV-6 — a required containment flag must appear in the argv slice that enforces it

**Statement:** a required containment flag MUST appear in the argv slice that
actually enforces it. bwrap teeth (`--cap-drop ALL`, `--unshare-pid`, `--tmpfs`,
`--unshare-net`, `--`) must appear in the bwrap prefix (before the first `--`);
qemu-inner required flags must appear in the inner slice (after `--`). A flag
present in the wrong slice satisfies a naive `set(argv)` membership check while
the component that needs it never receives it — a silent enforcement gap that is
invisible to per-component tests.

- **Origin:** finding F2, issue #61; the D1 defect re-confirmed by the PR #66
  independent review gate.
- **Status:** `enforced` — fixed in commit d7deab7 (PR #66) by partitioning
  `_REQUIRED_BWRAP` and `_REQUIRED_INNER` and checking each against its own slice.
- **Asserted by:** `tests/vm-disk-policy.test.sh` — bwrap slice: `VDP-T10a-reloc`
  (`--cap-drop ALL`), `VDP-T10c-reloc` (`--unshare-pid`), `VDP-T10d-reloc`
  (`--tmpfs`); inner slice: `VDP-T13-reloc` (`-smp`). Fragment `"bwrap prefix
  missing"` in the T10x-reloc assertions is unique to the slice-scoped error and
  absent from the R-INNER-ALLOWLIST backstop, so the tests prove the correct rule
  fires rather than a weaker fallback.

## Open invariants map to open issues

No open invariants remain.  All registry entries are `enforced`.

Issue #62 (extract `vm_exec_common.py`) is refactoring; the unit that closes it
MUST re-verify the whole registry, since collapsing the detonate/trace mirror is
exactly the kind of change that breaks a cross-slice guarantee.

Issue #61 (allowlist for block-device flags and slice-scoped containment teeth)
established INV-6 above; it carries an enforced invariant as of PR #66.
