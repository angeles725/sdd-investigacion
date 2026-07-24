# Hostile-sample detonation plan `detonate-plan.v1`

`detonate_plan.py` — offline hostile-sample detonation planner (U-V11 / item 11).
Produces `detonate-plan.v1.json` + `vm-determinism.v1.json`. NEVER executes:
no VM boot, no subprocess spawned, no sample detonated.
Live exec gated behind `--allow-exec` ([gate-authorization.v1](gate-authorization.v1.md)).

**D1 rebuild** (see design obs #5608 §2, §4, §6): `planned_argv` now emits the
`qemu-system-{arch}` form with three typed disk drives. Global `-snapshot` has been
**dropped** and replaced by per-drive containment policy (`lib/vm_disk_policy.py`).
The live `DetonateVmExecutor` is wired in D2; D1 remains plan-only.

## CLI

```
python3 detonate_plan.py plan \
    --sample   <FILE>           # regular file, no symlinks (O_NOFOLLOW)
    --output   <DIR>            # bind-scope guarded output directory
    [--os-image TAG]            # OS image tag recorded in plan (not executed)
    [--kernel  PATH]            # VM kernel path (default: /rsdd/vmlinuz; not executed)
    [--rootfs  PATH]            # VM rootfs image path (default: /rsdd/rootfs.img; not executed)
    [--network none]            # only "none" accepted; any other value → exit 2
    [--cpu-seconds N] [--wall-seconds N]
    [--max-mem-bytes N] [--max-output-bytes N]
    [--allow-exec]              # authorize live run (no live executor in D1 → exit 2)
    [--max-input-bytes N]       # optional input-size cap (default: unlimited)
                                # absent/None → no cap, behavior byte-identical to baseline
                                # set to N → inputs > N bytes fail closed (exit 2, no traceback)
```

Architecture (`arch`) is auto-detected from the sample's ELF `e_machine` header
(same logic as `qemu_plan.py`). Non-ELF samples degrade to `"x86_64"` silently.

## Disk slots and per-drive containment policy

The detonation VM uses **three typed disk drives** (per-drive policy; global `-snapshot`
is **absent** from the `planned_argv`). The live executor (D2) creates
`<run_dir>/scratch.img` and substitutes the sentinel `/rsdd/scratch.img` before Popen.

| Slot | Guest path | Drive flags | Rationale |
|---|---|---|---|
| **Sample** | `/input/sample` | `readonly=on,snapshot=off,format=raw,if=virtio` | Sample identity is immutable. `readonly=on` prevents any write. `snapshot=off` is explicit (no COW overlay allowed — not even for the sample). `format=raw` avoids qcow2 backing-file escape. |
| **Scratch** | host: `<run_dir>/scratch.img` | `snapshot=off,format=raw,if=virtio` | The only writable-persistent disk. Detonation artifacts written by the guest agent land here. Host reads it post-teardown via O_NOFOLLOW. `snapshot=off` ensures writes survive qemu exit. Pre/post sha256 hashes feed the evidence chain. |
| **Rootfs** | `/input/rootfs` | `snapshot=on,format=raw,if=virtio` | COW overlay discards all guest OS writes on exit. The host rootfs image is unmodified. `snapshot=on` is the ephemeral sentinel; `format=raw` is mandatory. |

**Why global `-snapshot` was dropped**: `qemu-plan.v1` uses global `-snapshot` (all drives
ephemeral, no real disk images). Detonation needs the scratch disk to **persist** so the
host can retrieve artifacts. Per-drive `snapshot=off` on scratch achieves this, while
`snapshot=on` on rootfs and `readonly=on` on the sample preserve the invariants V1b relied
on. The policy checker `lib/vm_disk_policy.py` enforces every rule above at preflight.

**`lib/vm_disk_policy.py`** — shared containment checker (single source of truth):
Exactly one writable-persistent drive is required. `format=qcow2` on any drive is
rejected (backing-file = host-path escape vector). Host device paths (`/dev/*`) are
rejected. All V1b belts are retained: `-accel tcg`, `-nic none`, `--unshare-net`,
`-smp 1`, `-nodefaults`, `-sandbox on,...=deny`; `-enable-kvm`, `-net`, `-netdev`,
`-virtfs`, `-device vfio*`, `-runas` are forbidden. Trace (D3) imports the same module
so the containment level can never regress.

## Containment policy (future live executor MUST enforce every row in this table)

This table is the normative containment spec. A correct live executor can be built from
this table alone without reading `planned_argv`.

| Policy | Guarantee | Enforcing mechanism |
|---|---|---|
| **Network namespace** | `--unshare-net`. Sample MUST NOT reach any network interface. Mode `"none"` is the only permitted value; non-none is refused at CLI and plan level. | `--unshare-net`; `network: "none"` |
| **PID namespace** | `--unshare-pid`. Sample sees only its own process tree; cannot signal or observe host processes. | `--unshare-pid` |
| **IPC namespace** | `--unshare-ipc`. Isolates System V IPC and POSIX MQs (shmget/semget/mq_open) from the host namespace; no capability needed to exploit. | `--unshare-ipc` |
| **UTS namespace** | `--unshare-uts`. Isolates hostname and NIS domain name; sample cannot change host identity. | `--unshare-uts` |
| **Cgroup namespace** | `--unshare-cgroup`. Isolates the cgroup hierarchy view; defense-in-depth against cgroup escape techniques. | `--unshare-cgroup` |
| **Capabilities** | `--cap-drop ALL`. Sample and sandbox run with zero Linux capabilities; no privilege escalation possible via capability abuse. | `--cap-drop ALL` |
| **Parent-death signal** | `--die-with-parent`. Sandbox is killed when the parent process exits; prevents orphaned sample processes surviving the planner. | `--die-with-parent` |
| **Session isolation** | `--new-session`. Creates a new POSIX session; sample cannot access the host terminal or send signals via the controlling terminal. | `--new-session` |
| **Sample mount** | `/input/sample` is mounted read-only inside the sandbox. Sample cannot modify itself or write back to the host through this path. | `--ro-bind`; `mount_plan.sample_ro` |
| **Writable area** | `/tmp/rsdd/out` is the sandbox output directory. Exactly one host path is writable inside the sandbox: the per-run scratch image, bound as a single file (`--bind <scratch> <scratch>`). The per-run **directory** is not exposed — only the individual file. | `--tmpfs`, `--dir`, `--bind`; `host_writable: mount_plan.scratch_persistent` |
| **Disk** | Per-drive policy: sample `readonly=on` (immutable, no writes allowed), rootfs `snapshot=on` (COW overlay discarded on exit, host image unchanged), scratch `snapshot=off` (writable-persistent; host reads post-teardown for pre/post sha256 hashing). | `disk.mode: "per-drive-policy"` |
| **Resource caps** | CPU, memory, wall-clock time, and output bytes are bounded. Exceeding any cap triggers kill + truncate + `reason` field. | `limits.*`; enforced by live executor |
| **Snapshot capture** | Pre-run and post-run disk-state digests MUST be captured before and after detonation (feeds U-F2 evidence chain). | `snapshot_policy.pre_run`, `snapshot_policy.post_run` |

Resource cap defaults: `cpu_seconds=30`, `mem_bytes=256 MiB`, `wall_seconds=60`,
`output_bytes=128 MiB`.

## `detonate-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"detonate-plan.v1"` | Schema identifier |
| `arch` | `str` | Detected qemu arch suffix (e.g. `"x86_64"`, `"aarch64"`); auto-detected from sample ELF, fallback `"x86_64"` |
| `qemu_binary` | `str` | Intended qemu binary (e.g. `"qemu-system-x86_64"`; never executed in dry-run) |
| `sample` | `{path, sha256, size, type_hint}` | Sample identity (O_NOFOLLOW) |
| `network` | `"none"` | Always "none" — isolation mandatory |
| `network_policy` | `{mode, justification}` | Explicit isolation record |
| `disk` | `{mode, pre_snapshot_digest, post_snapshot_capture}` | `mode="per-drive-policy"` (D1 rebuild; was `"ephemeral-snapshot"`) |
| `mount_plan` | `{sample_ro, rootfs_ro, scratch_persistent, output_writable, host_writable[, runtime_tree_ro]}` | Mount containment; `runtime_tree_ro: "/rsdd/rt"` present when `--qemu-root` is supplied (issue #65) |
| `limits` | `{cpu_seconds, mem_bytes, wall_seconds, output_bytes}` | Resource caps |
| `snapshot_policy` | `{pre_run, post_run}` | State-hash capture intent |
| `os_image` | `str \| null` | OS image tag (recorded, not executed) |
| `planned_argv` | `list[str]` | Full bwrap+qemu-system invocation with three typed `-drive` args and a file-scoped `--bind` for the scratch image (NEVER executed in dry-run) |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | `["outputs-unknown-until-live-run"]` |

`disk.mode = "per-drive-policy"` signals the per-drive snapshot approach introduced in
D1. A live executor MUST parse each `-drive` spec individually; it MUST NOT apply global
`-snapshot` or treat all drives as ephemeral.

`mount_plan.scratch_persistent = "/rsdd/scratch.img"` is a **plan-time sentinel**. The
live executor (D2) substitutes the actual `<run_dir>/scratch.img` path in `exec_argv`
before calling Popen. The host creates this file fresh in the per-run directory.

> **OPERATOR WARNING — `planned_argv` requires operator-provisioned runtime tree for live boot.**
> The emitted `planned_argv` is validated and CI-tested **OFFLINE only** (fake
> `qemu-system-*` shim; bwrap is never invoked in CI).
>
> The scratch-mount reachability gap (issue #60 / INV-2) is **reconciled and
> machine-checked**: `planned_argv` includes `--bind <scratch> <scratch>` placed
> after `--tmpfs /tmp/rsdd`, and `lib/vm_disk_policy` enforces this ordering at
> every preflight.  The scratch drive is reachable inside the sandbox.
>
> Gaps 1/3/4 (qemu binary, kernel, BIOS firmware) are addressed by issue #65
> (Slices A+B): pass `--qemu-root <DIR>` to mount a curated read-only runtime
> tree at `/rsdd/rt` inside the sandbox.  The emitted argv then uses
> `/rsdd/rt/bin/qemu-system-x86_64` and `/rsdd/rt/vmlinuz`; `lib/vm_disk_policy`
> R-REACH machine-checks the qemu-binary and kernel reachability in argv order
> (INV-7); `_preflight` fails closed if the host `<DIR>` does not exist (R6).
>
> **Operator provisioning obligation (not enforced by R-REACH):** R-REACH proves
> argv internal consistency — that each boot-input path resolves inside the
> declared mount set.  It does NOT verify that the operator's host `<DIR>` is
> actually populated.  The operator MUST provision `<DIR>` with:
>
> - `<DIR>/bin/qemu-system-x86_64` (and its `.so` closure)
> - `<DIR>/vmlinuz` (bootable kernel)
> - BIOS firmware at `<DIR>/share/qemu/` (qemu `datadir`)
>
> Without operator provisioning, the argv is structurally reachability-consistent
> but the live boot will still fail with a missing-binary or missing-kernel error.
>
> Live boot is **x86_64-only** and remains a manually-gated operator action;
> `--qemu-root` must be passed explicitly and is refused for non-x86_64 arches.
> Resolved by issue #65 (Slices A+B; previously tracked as gaps 1/3/4 per
> design.md §2).

`sample.type_hint` is metadata-only (magic-byte sniff); degrades to `"unknown"` on
any error without traceback. Does not gate execution.

`mount_plan.host_writable`: must equal `mount_plan.scratch_persistent` — exactly one host
filesystem path is made writable inside the sandbox (the per-run scratch image, bound as a
single file). Any value other than `mount_plan.scratch_persistent` MUST cause the executor
to refuse the plan before entering the sandbox. An absent field MUST be treated as a schema
error. (`"none"` was the value when this bind was missing; that claim was only true because
the feature was broken — corrected by issue #60 / INV-2.)

## Snapshot lifecycle

Two snapshot artifacts are declared in the plan: `disk.pre_snapshot_digest` (in the `disk`
object) and `snapshot_policy.pre_run.sha256` / `snapshot_policy.post_run.sha256` (in the
`snapshot_policy` object). They refer to the same logical artifact and MUST agree.

| Field | When populated | What is hashed | Format |
|---|---|---|---|
| `disk.pre_snapshot_digest` | Live executor, before detonation | Block-device / disk-image state | `sha256:<hex>` (null in dry-run) |
| `snapshot_policy.pre_run.sha256` | Live executor, before detonation | Same as above — authoritative copy in the policy record | `sha256:<hex>` (null in dry-run) |
| `snapshot_policy.post_run.sha256` | Live executor, after detonation exits | Block-device / disk-image state post-execution | `sha256:<hex>` (null in dry-run) |

In dry-run (this adapter): all three fields are `null`. In a live executor they MUST be
populated at the correct lifecycle point. `disk.pre_snapshot_digest` and
`snapshot_policy.pre_run.sha256` MUST carry identical values; any discrepancy MUST cause
the executor to abort with `error: "snapshot-identity-mismatch"`.

## Executor failure contract

A future live executor implementing this plan MUST handle the following failure paths.
See `corroborate_native.run_bounded` for the house precedent (SIGTERM → SIGKILL with
grace period, output-cap kill + truncate, `reason` field).

| Failure path | Required executor action |
|---|---|
| **Wall-clock timeout** | Send SIGTERM to the process group; if not dead within 1 s, send SIGKILL and wait; set `reason: "timeout"` in the result record. |
| **output_bytes cap exceeded** | Kill immediately (SIGTERM → SIGKILL after 1 s grace); truncate stdout + stderr to fit within the cap combined; set `reason: "output-cap"`. |
| **pre_run snapshot-capture failure** | Abort the run; do NOT report success or proceed to detonation; return a structured error with `error: "pre-snapshot-failed"`. A missing baseline makes evidence incomplete. |
| **post_run snapshot-capture failure** | Record the failure; set `error: "post-snapshot-failed"` and `completeness: "failed"`. The result MUST NOT be treated as a clean detonation — diff evidence is absent. |
| **General execution error** | Return `exit_code: null`, `signal: N` (if killed by signal), a non-empty `errors` list, and `completeness: "failed"`. |

Exit-code / error-field convention (mirrors `corroborate_native.run_bounded`):

- `exit_code`: integer if the process exited normally; `null` if killed by signal.
- `signal`: the killing signal number if killed by signal; `null` otherwise.
- `reason`: `"timeout"` | `"output-cap"` | `""` (empty string means natural exit).
- `errors`: list of strings; empty on clean exit; non-empty on any failure path above.

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): always `declared:false`, `basis:"dry-run-plan"`,
`receipt_identity:null`. Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-exec` absent | `authorization-required` / exit 3 |
| `--allow-exec` + no executor | `GateError` / exit 2 |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.
