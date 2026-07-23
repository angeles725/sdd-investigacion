# Design: reconcile the scratch mount for live in-guest detonation (issue #60 / F5)

**Role**: FABLE scoping/plan authority. **DESIGN ONLY — no source or test file was written or edited.**
**Repo**: `/home/cristian/investigacion/sdd-investigacion`, work area `research-sdd/toolbelt/`. Base: `main` @ `e27d6e6`.
**Predecessors**: obs #5608 (in-VM detonate design), #5633 (D2 re-seam), #5642 (PR #59 independent review, F5), #5589 (host-detonation rejection).

---

## VERDICT: GO-WITH-CONDITIONS

The defect is real and empirically reproduced with real `bwrap` and real `qemu-system-x86_64`.
The fix is small, offline-testable, and **strictly tightens** containment relative to the direction
suggested in the issue. It does **not** enable any new capability: a host-persistent scratch was
already the approved design (obs #5608 §4) and is already implemented host-side in D2 — only the
sandbox could not see it.

Three conditions must be accepted before `sdd-apply`:

- **C1 — Scope reframe.** Issue #60 says the emitted `planned_argv` is "not live-runnable as-is".
  That is true, but the scratch mount is **one of four** reachability gaps (§2). This unit fixes the
  scratch gap and adds a machine-checkable invariant; it does **not** make `planned_argv` runnable.
  The operator WARNING added in `aa38384` must be **rewritten, never deleted**.
- **C2 — Reject the issue's suggested `--bind <run_dir> <run_dir>`.** Directory binding reopens a
  host write-back hole that is empirically demonstrated in §4 (Experiment E). Use a **file-scoped**
  `--bind <scratch> <scratch>` instead, and make the file scoping an *enforced policy rule*, not a
  convention.
- **C3 — A declared safety-claim field changes value.** `mount_plan.host_writable` goes from
  `"none"` to the scratch path. Both plan contracts currently state `"none"` is the **only valid
  value**, and `tests/detonate-plan.test.sh:72` asserts it. Today that claim is only true because
  the feature is broken. Flipping it is a correction of a false statement, not a loosening — but a
  reader of `detonate-plan.v1.json` today believes no host path is writable, so this must be
  acknowledged explicitly rather than slipped in.

C1 and C2 are decisions I am making with evidence. C3 is the one item that warrants an explicit
acknowledgement from the user before apply.

---

## 1. The defect, reproduced precisely

### 1.1 Exact emitted argv

`detonate_plan.build_plan` (`research-sdd/toolbelt/detonate_plan.py:106-126`) emits:

```
bwrap --die-with-parent --new-session
      --unshare-net --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup
      --cap-drop ALL
      --tmpfs /tmp/rsdd  --dir /tmp/rsdd/out
      --ro-bind <rootfs_path> /input/rootfs
      --ro-bind <sample>      /input/sample
      --
      qemu-system-<arch>
      -kernel /rsdd/vmlinuz  -m <MB> -smp 1 -accel tcg -nic none -nodefaults
      -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
      -nographic -no-reboot
      -drive file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio
      -drive file=/rsdd/scratch.img,snapshot=off,format=raw,if=virtio      <-- SENTINEL
      -drive file=/input/rootfs,snapshot=on,format=raw,if=virtio
```

`trace_plan.build_plan` (`trace_plan.py:104-126`) is identical plus
`-append "init=/rsdd-agent rsdd.tracer=<tracer>"`.

### 1.2 Exact host path

`vm_boot_core.run_vm` creates the single run dir via `docker_common.make_run_subdir`
(`vm_boot_core.py:84`, `docker_common.py:188`, root `_DEFAULT_RSDD_ROOT = "/tmp/rsdd"`):

```
run_dir = /tmp/rsdd/rsdd-<uuid-hex>
```

`DetonateVmExecutor.pre_boot` (`detonate_exec.py:147-186`) creates
`/tmp/rsdd/rsdd-<uuid>/scratch.img` (4 MiB, `O_NOFOLLOW`, `ftruncate`) and rewrites every token
containing `/rsdd/scratch.img` to that host path. The final `-drive` token is therefore:

```
-drive file=/tmp/rsdd/rsdd-<uuid>/scratch.img,snapshot=off,format=raw,if=virtio
```

### 1.3 The masking

`--tmpfs /tmp/rsdd` mounts a fresh empty tmpfs at `/tmp/rsdd` **inside the sandbox mount
namespace**. The substituted `-drive` path lives *under* that mount point. Nothing later in the
argv re-exposes it. Inside the sandbox, `/tmp/rsdd/rsdd-<uuid>/scratch.img` does not exist.

Consequence chain:
1. qemu cannot open the scratch → qemu exits with an error before any guest code runs.
2. `snapshot_hook` still hashes the **host** file pre and post (`detonate_exec.py:191-193`), and the
   host file is never touched by anything → `vm_pre_snapshot == vm_post_snapshot`.
3. The `vm-run-receipt.v1` therefore ships a pre/post pair that proves nothing. The evidence chain
   that D2 exists to produce is **vacuous on a real boot**.

CI does not see this because `tests/detonate-exec.test.sh` installs a fake `bwrap`
(`_BWRAP`, line 37) that simply `execvp`s everything after `--` with **no mount namespace at all**,
and a fake `qemu-system-x86_64` (`_QEMU_DETONATE`, line 54) that opens the `-drive file=` path
directly on the host filesystem and writes `DETONATE_RUN_CANNED_DATA_v1`. The shim makes
`pre != post` unconditionally, which is exactly the assertion RED7 checks. The test is green and
the property is false.

---

## 2. Empirical evidence

All experiments run locally with `bubblewrap 0.9.0` and the host `qemu-system-x86_64`.
No sample, no guest, no untrusted input. Probe directories were removed afterwards.

### Experiment A — the emitted argv verbatim

Exact emitted bwrap prefix, bare `qemu-system-x86_64` after `--`:

```
bwrap: execvp qemu-system-x86_64: No such file or directory
```

**The sandbox cannot even locate the qemu binary.** bwrap starts from an empty root; the emitted
argv binds only `/input/rootfs` and `/input/sample`, so there is no `/usr`, `/bin`, or `/lib`.

### Experiment B — masking (with `/usr` added so a probe binary can run)

```
$ ls -la /tmp/rsdd            # inside sandbox
drwxr-xr-x  out               # only the --dir entry; the tmpfs is otherwise empty
$ stat /tmp/rsdd/rsdd-f5probe/scratch.img
stat: cannot statx '...': No such file or directory
```

### Experiment G1 — real qemu, current mount policy

```
qemu-system-x86_64: -drive file=/tmp/rsdd/rsdd-f5probe/scratch.img,snapshot=off,format=raw,if=virtio:
  Could not open '/tmp/rsdd/rsdd-f5probe/scratch.img': No such file or directory
```

**This is F5, verbatim, from the real binary.**

### Experiment G2 — real qemu with the proposed file bind

Same command plus `--bind <scratch> <scratch>` after the tmpfs: qemu ran to the wall timeout
(`rc=124`) with **zero bytes on stderr**. The drive opened cleanly.

### Experiment E — the issue's suggested `--bind <run_dir> <run_dir>`

```
$ touch $RUN/evil-from-guest.txt     # inside sandbox
created
$ ls $RUN                            # ON THE HOST
evil-from-guest.txt
scratch.img
```

**A guest-side write created a file in the host run dir.** `vm_boot_core.py:160` calls
`docker_common.output_files(Path(run_dir))`, which `sorted(iterdir())`s that directory into the
receipt's `outputs[]`. A compromised qemu could therefore inject arbitrary named artifacts into the
frozen receipt, and could pre-create `serial.log` (later overwritten by the host) or clutter the
evidence set. This is the containment hole the issue's direction reintroduces.

### Experiment D — the proposed file-scoped bind

```
$ printf 'POSTWRITE' > $RUN/scratch.img   # inside sandbox
wrote-ok                                   # host sha256 changed 6a747ff8… -> 969005f1…
$ touch $RUN/evil.txt                      # inside sandbox
SIBLING CREATED                            # ...but on the sandbox's TMPFS parent
$ ls $RUN                                  # ON THE HOST
scratch.img                                # <- host dir untouched
```

bwrap auto-creates the missing parent directory **on the tmpfs** (mode 0700) and binds only the
single file into it. Writes to the scratch propagate to the host; everything else the guest does in
that directory is ephemeral and invisible to the host.

### Experiment F — inode pinning under the file bind

```
rm    $RUN/scratch.img  ->  Device or resource busy   (unlink refused)
mv    $RUN/scratch.img  ->  Device or resource busy   (rename refused)
ln -s /etc/passwd ...   ->  Device or resource busy   (symlink replace refused)
```

The bound file is a mount point, so the sandbox cannot unlink, rename, or symlink-replace it. **The
inode the host hashes is the same inode the guest writes.** This is what makes the pre/post hash
pair non-forgeable in the sense that matters: the guest cannot swap the object under the hash.

### Experiments K / K2 — mount ordering is load-bearing

```
K  : --bind <scratch> <scratch>  --tmpfs /tmp/rsdd   ->  cannot statx (re-masked)
K2 : --tmpfs /tmp/rsdd  --bind <scratch> <scratch>   ->  /tmp/rsdd/.../scratch.img 4096
```

bwrap applies mount operations in argv order. **The bind must be emitted after the tmpfs.** Any
checker for this invariant must be ordering-aware, not set-based.

### Experiments H / I / J — the three remaining gaps

```
H : -kernel /rsdd/vmlinuz  ->  qemu: could not open kernel file '/rsdd/vmlinuz': No such file or directory
I : /usr/bin + /usr/lib bound but not /usr/share  ->  qemu: could not load PC BIOS 'bios-256k.bin'
J : --ro-bind /rsdd/rootfs.img /input/rootfs (plan default, absent on host)
    ->  bwrap: Can't find source path /rsdd/rootfs.img: No such file or directory
```

**Summary of reachability gaps in the emitted argv:**

| # | Referenced by | Reachable in sandbox? | Fixed by this unit? |
|---|---|---|---|
| 1 | `qemu-system-<arch>` (execvp) | No — no `/usr`, `/bin`, `/lib` bound | No |
| 2 | `-drive file=<scratch>` | No — masked by `--tmpfs /tmp/rsdd` | **Yes** |
| 3 | `-kernel /rsdd/vmlinuz` | No — `/rsdd` is not bound at all | No |
| 4 | qemu BIOS roms (`/usr/share/qemu`) | No — not bound | No |
| 5 | `--ro-bind <rootfs>`, `--ro-bind <sample>` | Yes, if the host source exists | n/a (already correct) |

This table is the entire justification for condition **C1**. Fixing gap 2 alone and then deleting
the "not live-runnable" warning would replace a truthful warning with a false implication of
completeness, on the most dangerous capability in the toolbelt. Gaps 1/3/4 belong to a separate
unit that designs the operator's host-runtime mount set; they are not in scope here.

---

## 3. Adversarial evaluation of the proposed fix

The question the issue asks — *does binding reintroduce a containment hole?* — has to be answered
separately for the two bind granularities.

### 3.1 Directory bind (`--bind <run_dir> <run_dir>`) — REJECTED

| Concern | Assessment |
|---|---|
| Write-back into the host run dir | **Confirmed hole** (Experiment E). Guest-created files land on the host. |
| Evidence-chain integrity | **Degraded.** `output_files(run_dir)` sweeps guest-created files into receipt `outputs[]`. The receipt would attest to artifacts of the guest's choosing, with host-computed hashes lending them false authority. |
| `serial.log` / `vm-run-receipt.v1.json` | Both are written by the host into the same dir. The guest can pre-create them (the host overwrites `serial.log` afterwards, so this is mostly noise — but the receipt is written last and the guest cannot see it, so no forgery). Still: unnecessary exposure. |
| Scratch inode identity | **Not pinned.** With the directory bound, the guest can unlink/rename `scratch.img` and replace it. The post-hash uses `O_NOFOLLOW` (`detonate_exec.py:49-62`), so a symlink replacement fails soft to `post_snap=None` rather than following the link — good — but a *regular file* replacement would be hashed as if it were the original scratch. |
| Blast radius if `run_dir` root ever moves | Whole directory exposure scales with whatever else lands in `run_dir`. |

The directory bind is the wrong granularity. It grants write access to a *namespace* when only a
*single object* needs to be shared.

### 3.2 File bind (`--bind <scratch> <scratch>`) — SELECTED

| Concern | Assessment |
|---|---|
| Write-back into the host run dir | **Closed.** Only the scratch inode is shared; sibling creation lands on the sandbox tmpfs (Experiment D). |
| Evidence-chain integrity | **Preserved.** `outputs[]` contains exactly `scratch.img` + `serial.log`, both host-controlled names. The D2 invariant `outputs[scratch.img].sha256 == vm_post_snapshot.sha256` (obs #5633 Decision 3) still holds. |
| Scratch inode identity | **Pinned.** unlink/rename/symlink-replace all fail `EBUSY` (Experiment F). The host hashes the object the guest wrote. |
| Should it be read-only? | **No — and it must not be.** The scratch is the artifact-extraction channel; `snapshot=off` writable persistence is the whole mechanism (obs #5608 §4). Read-only would restore the broken state. Read-only is correct for *every other* bind, which motivates rule **R-BIND-RW** below. |
| Sample injection path | **Unaffected.** The sample reaches the guest via `--ro-bind <host sample> /input/sample` + `-drive file=/input/sample,readonly=on`. `/input/sample` is a bind destination at the sandbox root, not under `/tmp/rsdd`, so it was never masked and is not touched by this change. Receipt binding of the sample (F1 fix, `vm_boot_core.py:175-183`) is likewise unaffected. |
| `vm_disk_policy` interaction | The existing rule 4 already requires the writable-persistent `-drive file=` to be under `run_dir`. This change adds a symmetric rule tying the *bind* to that same path, so the two cannot drift apart. |
| Host disk exhaustion | **New residual.** A process that escaped qemu's seccomp could write past the 4 MiB `ftruncate` and grow the host file unbounded. `limits.output_bytes` is not enforced against the scratch. Low severity, cheap follow-up (post-teardown size check). Recorded in §7, not fixed here. |
| Forgeability of pre/post | The guest can write **any** bytes to the scratch, so it can make `post` be whatever it likes. That was always true and is inherent to the channel. What the hash proves is *that the bytes changed and what they are*, not who wrote them or why. This must be stated in the run contract — see §6. |

### 3.3 Ordering as a policy property

Experiment K shows a bind placed before the tmpfs is silently re-masked — the same class of bug as
F5, produced by a plausible "fix". The reachability checker must model mount ordering, so a
regression of this exact shape is caught by CI rather than by an operator's failed boot.

---

## 4. Alternatives considered

### Alternative 1 — Move the run dir out from under the tmpfs root

Keep `--tmpfs /tmp/rsdd` (so the guest gets an isolated ephemeral `/tmp/rsdd`) and relocate the
per-run evidence directory to a different root, e.g. `/var/tmp/rsdd-runs/rsdd-<uuid>`, which the
tmpfs never masks. Then bind only the scratch file from there.

**Rejected.** `make_run_subdir`'s `/tmp/rsdd` root is shared by `capture_exec`, `docker_exec`,
`fact_exec`, and `qemu_exec`, and is guarded by `verify_rsdd_root`. Changing it is a large blast
radius across four executors for **zero additional containment** — the file bind already pins the
inode and hides the directory. It also splits the evidence root convention in two, which is a
maintenance hazard on a security-sensitive path. Worth revisiting only if the tmpfs root and the
evidence root ever need genuinely different lifetimes.

### Alternative 2 — Drop `--tmpfs /tmp/rsdd` entirely

**Rejected outright.** The host `/tmp/rsdd` currently holds ~1,780 prior run directories
(observed locally). Exposing that to a detonating sample would let it read and tamper with the
accumulated evidence of every previous run. Strictly worse than the bug being fixed.

### Alternative 3 — Extract artifacts without a host-visible scratch

Have the guest write to the sandbox tmpfs and extract via a side channel (serial console encoding,
or a virtio-serial pipe the host reads). **Rejected.** Serial-console encoding caps throughput and
corrupts binary artifacts; virtio-serial adds device surface that `-nodefaults` deliberately
removes; and both discard the `vm_pre_snapshot`/`vm_post_snapshot` block-image evidence model that
`vm-run-receipt.v1` is already built around. This would be a redesign of D2, not a fix to it.

### Alternative 4 — Documentation only (leave the argv as-is)

That is the status quo shipped in `aa38384`. **Rejected as a terminal state**, but note that it is
*honest*: the current warning correctly says the argv is not live-runnable. The failure mode of
this whole issue is shipping a partial fix that makes the warning look obsolete. Hence C1.

---

## 5. Design

### 5.1 Emit the bind at PLAN time, as a sentinel pair

Both `detonate_plan.build_plan` and `trace_plan.build_plan` gain, **immediately after**
`--tmpfs /tmp/rsdd --dir /tmp/rsdd/out`:

```python
"--bind", _SCRATCH_SENTINEL, _SCRATCH_SENTINEL,
```

The executor's existing substring substitution (`detonate_exec.py:165-176`, `trace_exec.py`
mirror) rewrites **all three** occurrences of `/rsdd/scratch.img` — bind source, bind destination,
and `-drive file=` — to the same real per-run path. No token insertion logic is added to the
executor; substitution stays a pure rewrite.

Plan-time emission (rather than executor injection) is chosen because:
- the gate-closed dry-run `detonate-plan.v1.json` an operator inspects then describes the **complete**
  mount set, instead of omitting the one mount that matters;
- the reachability invariant (§5.2) can be enforced at plan time with `run_dir=None`, because the
  sentinel bind destination equals the sentinel drive path — the invariant is **substitution
  invariant** and the *same* checker call passes both in `_preflight` and in `pre_boot`.

`argv_deltas` will now record 3 substitutions instead of 1. No test asserts a delta count
(verified: `rg argv_deltas tests/` shows no length assertion), so this is safe.

### 5.2 New policy rules in `lib/vm_disk_policy.py`

**R-REACH — every `-drive file=` path must be reachable under the emitted mount ops.**

Parse the tokens strictly before the `--` separator into an ordered list of mount operations:

| bwrap op | arity | effect on coverage |
|---|---|---|
| `--tmpfs DEST` | 1 | **masks** DEST and everything under it |
| `--bind SRC DEST`, `--ro-bind SRC DEST` | 2 | **covers** DEST and everything under it |
| `--dir DEST` | 1 | covers DEST (directory only) |
| `--proc DEST`, `--dev DEST` | 1 | covers DEST |
| `--symlink SRC DEST` | 2 | consumed, no coverage |

For each `-drive file=P`, walk the ops **in order** maintaining a boolean `covered`:
an op at `DEST` where `DEST == P` or `DEST` is an ancestor directory of `P` sets `covered = True`
for a covering op and `covered = False` for `--tmpfs`. Final `covered == False` → `GateError`
naming the drive and the masking mount.

Under the current argv this yields:
`/input/sample` covered, `/input/rootfs` covered, `<scratch>` **not covered** → the RED we want.
After the fix all three are covered.

**R-BIND-RW — exactly one read-write bind, identity-mapped, equal to the scratch drive.**

- At most **one** `--bind` (read-write) op may appear.
- Its `SRC` must equal its `DEST` (identity mapping — no source/destination indirection).
- That path must equal the single writable-persistent `-drive file=` path already collected by
  `_check_one_drive`.
- Every other bind must be `--ro-bind`.

This converts the file-scoping decision from a convention into an enforced invariant: a future
"fix" that binds the directory, or binds some other host path read-write, is rejected by the
checker.

**R-BWRAP-DENY — forbid rw/device/overlay/try bind families.**

Add a bwrap-side denylist alongside the existing qemu-side `_FORBIDDEN`:
`--dev-bind`, `--dev-bind-try`, `--bind-try`, `--ro-bind-try`, `--overlay`, `--overlay-src`,
`--tmp-overlay`, `--ro-overlay`. The `-try` variants are forbidden because they fail **open** when
the source is missing, which would silently reproduce an unreachable-path run — precisely the F5
failure mode with no error surface.

**Honest limitation of R-REACH.** It proves *internal consistency* of the argv — that every disk
path referenced is reachable given the mounts declared. It does **not** prove the mount set is
minimal or safe; that remains the job of `_REQUIRED` / `_FORBIDDEN` / R-BIND-RW / R-BWRAP-DENY. It
also deliberately does **not** check `-kernel` (gap 3), because no kernel bind exists yet and
enabling the check would reject every plan. The checker is structured so extending it to `-kernel`
is a one-line addition once gap 3 is designed.

### 5.3 Contract changes

| Field / doc | From | To |
|---|---|---|
| `mount_plan.host_writable` (both plans) | `"none"` | `_SCRATCH_SENTINEL` |
| `detonate-plan.v1.md:129`, `trace-plan.v1.md:144` | `"none"` is the only valid value | must equal `mount_plan.scratch_persistent`; any other value refused |
| `detonate-plan.v1.md:76`, `trace-plan.v1.md:93` isolation table | "No host path is writable" | "Exactly one host path is writable: the per-run scratch image, bound as a single file. The per-run directory itself is **not** exposed." |
| `detonate-plan.v1.md:111`, `trace-plan.v1.md:129`, `detonate-run.v1.md:72`, `trace-run.v1.md:81` WARNING | "not live-runnable; scratch is masked" | rewritten: scratch mount is now reconciled and machine-checked; **still not live-runnable** — enumerate gaps 1, 3, 4 with the verbatim error strings from Experiments A, H, I |

A new plan-level invariant worth asserting in tests: `host_writable == scratch_persistent`. The
only writable host path *is* the scratch, by construction.

---

## 6. TDD slices

One PR, two commits, strict RED → GREEN. Estimated **~390 authored lines**, well inside the
800-line budget. No chained PR needed.

Ordering matters: slice 1 must land before slice 2's invariant is applied to real plans, otherwise
slice 2 turns every existing detonate/trace exec test red. Slice 2's own RED cases use synthetic
argv, so they are independent.

### Slice 1 — emit the bind pair + contract truth (~205 authored)

**RED tests first:**

| Test file | New case | Assertion (fails today) |
|---|---|---|
| `tests/detonate-plan.test.sh` | `T4c-scratch-bind` | `planned_argv` contains the contiguous triple `["--bind", "/rsdd/scratch.img", "/rsdd/scratch.img"]`, and its index is **greater than** the index of `"--tmpfs"` |
| `tests/detonate-plan.test.sh` | amend `T4a` (line 72) | `mp["host_writable"] == mp["scratch_persistent"]` (replaces `== "none"`) |
| `tests/trace-plan.test.sh` | `T-scratch-bind` | mirror of both |
| `tests/detonate-exec.test.sh` | `RED-F5A` | after `evaluate()`, `exec_argv` contains `--bind <P> <P>` where `P` is the substituted real scratch path, `P` equals the `file=` value of the writable-persistent `-drive`, and the bind index > `--tmpfs` index |
| `tests/trace-exec.test.sh` | `RED-F5A` | mirror |

**Change:** add the sentinel bind triple after `--tmpfs`/`--dir` in both `build_plan`s; change
`host_writable`; rewrite the four contract docs and the `tool-registry.md` row.

**Files:** `detonate_plan.py`, `trace_plan.py`, `detonate-plan.v1.md`, `trace-plan.v1.md`,
`detonate-run.v1.md`, `trace-run.v1.md`, `tool-registry.md`, `tests/detonate-plan.test.sh`,
`tests/trace-plan.test.sh`, `tests/detonate-exec.test.sh`, `tests/trace-exec.test.sh`.

No change to `detonate_exec.py` / `trace_exec.py` is required — substring substitution already
covers the new tokens. **Verify this holds** rather than assuming it; if the F4 follow-up (exact-
token matching) lands first, it must match the *three* structural positions, not just the `-drive`
token. Note this dependency in the F4 issue.

### Slice 2 — reachability + bind policy in `vm_disk_policy` (~185 authored)

**RED tests first**, all in `tests/vm-disk-policy.test.sh`, all synthetic argv:

| Case | Argv | Expected |
|---|---|---|
| `RED-REACH-MASK` | `--tmpfs /tmp/rsdd` + `-drive file=/tmp/rsdd/rsdd-x/scratch.img` | `GateError` naming the drive and the masking `--tmpfs` |
| `RED-REACH-ORDER` | bind placed **before** the tmpfs | `GateError` (ordering-aware) |
| `GREEN-REACH-OK` | bind placed **after** the tmpfs | no error |
| `RED-BIND-DIR` | `--bind <run_dir> <run_dir>` (directory, not the file) | `GateError` — bind path must equal the scratch drive path |
| `RED-BIND-NONIDENTITY` | `--bind /etc /tmp/rsdd/rsdd-x/scratch.img` | `GateError` — SRC must equal DEST |
| `RED-BIND-EXTRA-RW` | two `--bind` ops | `GateError` — at most one rw bind |
| `RED-BWRAP-DENY` | `--dev-bind`, `--ro-bind-try`, `--overlay` (one case each) | `GateError` |
| `GREEN-SUBST-INVARIANT` | full plan argv checked twice: sentinel form with `run_dir=None`, and substituted form with the real `run_dir` | both pass |
| `PARITY` | every new RED case re-run through the trace path | identical rejection (shared checker — assert by construction, mirroring the existing parity pattern) |

**Optional, `bwrap`-gated:** `SMOKE-BWRAP` — skipped unless `command -v bwrap` succeeds. Extract
the mount-op subsequence from a real emitted plan, append a minimal exec harness
(`--ro-bind /usr /usr --symlink usr/bin /bin ...`), and assert `bwrap ... -- /usr/bin/stat <scratch>`
exits 0. Caveat stated honestly in the test comment: this validates *bwrap's mount semantics and
our ordering*, not the emitted argv verbatim (the emitted argv cannot execute anything — gap 1).

**Change:** add `_parse_mount_ops`, `_is_reachable`, R-REACH, R-BIND-RW, R-BWRAP-DENY to
`check_disk_policy`.

**Files:** `lib/vm_disk_policy.py`, `tests/vm-disk-policy.test.sh`.

**Behavior change to document:** after slice 2, a *stale* `detonate-plan.v1.json` generated before
this unit fails `_preflight` with `GateError` (exit 2). That is the correct fail-closed outcome —
an unreachable scratch would otherwise produce a vacuous receipt — but it is user-visible and
belongs in the run contract's error table.

---

## 7. What CI still cannot prove

The fake `bwrap` shim performs **no mount namespacing whatsoever**, and the fake qemu opens the
`-drive` path directly on the host. Every mount-namespace property is therefore invisible to the
default suite. After this unit:

**Closed by the new tests (previously operator-only):**
- Every `-drive file=` path is reachable under the emitted mount ops, **ordering-aware**. Pure
  function over argv, deterministic, no bwrap required. This is the property whose absence *is* F5.
- Exactly one read-write bind exists, it is identity-mapped, and it equals the scratch drive path.
- The invariant is substitution-invariant: it holds at plan time (sentinel) and post-substitution
  (real path), so plan and exec cannot drift.
- The `-try`/overlay/dev-bind fail-open families are refused.

**Still operator-verified-only:**
1. **That a real guest boots at all.** Gaps 1, 3, 4 (§2) are unfixed; the emitted argv still cannot
   locate the qemu binary, the kernel, or the BIOS roms. The rewritten WARNING must say so.
2. **That the operator's added mount set is itself contained.** Whatever the operator binds to close
   gaps 1/3/4 is outside the checker's view and could reintroduce host exposure.
3. **qemu `-sandbox on,...=deny` efficacy** against a real hostile guest, and the guest → qemu →
   bwrap escape chain generally. Unstubbable by construction.
4. **Provenance of the scratch bytes.** `vm_post_snapshot` proves *what* the bytes are and that they
   changed; it cannot prove the *sample* wrote them rather than the guest OS or the agent. The run
   contract should state this explicitly.
5. **Real end-to-end detonation.** Remains the human's gated manual step, per obs #5589 / #5608.

The `SMOKE-BWRAP` test narrows item 1 partially — it proves our mount *ordering* is right on a real
bwrap — but it cannot execute the emitted argv, so it does not close the gap.

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Partial fix read as "now live-runnable" | **High** — this is the F5 hazard class repeating | C1: rewrite, never delete, the operator WARNING; enumerate gaps 1/3/4 with verbatim error strings |
| `host_writable` flips from `"none"` | Medium — declared safety-claim field | C3: explicit user acknowledgement; assert `host_writable == scratch_persistent` |
| Stale plan JSONs start failing preflight | Low — fail-closed, but user-visible | Document in the run contract error table; error message names the masking mount |
| Guest grows the scratch past 4 MiB → host disk exhaustion | Low — requires qemu escape | Recorded as follow-up: enforce `limits.output_bytes` against the scratch post-teardown |
| F4 follow-up (exact-token substitution) breaks the bind pair | Medium — cross-issue coupling | Note in issue F4: substitution must cover all three structural positions |
| `check_disk_policy` argv parser misalignment on unknown bwrap options | Low | Only known ops with known arities are recognized; unknown tokens are not consumed. Limitation stated in §5.2 |

---

## 9. Recommended next steps

1. Confirm **C3** (the `host_writable` contract change) with the user — one line, not a full gate.
2. Hand slices 1 → 2 to one `sdd-apply` implementer under strict TDD, single PR, two commits.
3. Post-apply: run the review lens per the trigger rules (security/containment → `review-risk`).
4. File a follow-up issue for gaps 1/3/4: *"design the operator host-runtime mount set for live VM
   detonation (qemu binary, kernel, BIOS roms, rootfs source)"*. That unit is what would finally
   make the argv live-runnable, and it is where the WARNING can eventually be retired.
5. File a follow-up for the scratch size cap (§7 residual).
