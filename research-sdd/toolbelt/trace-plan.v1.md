# In-VM trace plan `trace-plan.v1`

`trace_plan.py` — offline in-VM tracer planner (U-V9 / item 9).
Produces `trace-plan.v1.json` + `vm-determinism.v1.json`. NEVER executes:
no VM boot, no subprocess spawned, no target traced.
Live exec gated behind `--allow-exec` ([gate-authorization.v1](gate-authorization.v1.md)).

**D3 rebuild** (see design obs #5608 §5): `planned_argv` now emits the
`qemu-system-{arch}` form with three typed disk drives. The tracer selection
(`strace`, `ltrace`, `gdb-batch`) is encoded in the kernel cmdline as
`-append "init=/rsdd-agent rsdd.tracer=<tracer>"` — the guest-side `rsdd-agent`
reads it from `/proc/cmdline` and wraps the target accordingly. Host attack
surface is **IDENTICAL to detonate** — containment is enforced by the SAME
shared `lib/vm_disk_policy.py` module, so trace can never regress below detonate.
The live `TraceVmExecutor` is wired in D3.

## CLI

```
python3 trace_plan.py plan \
    --target   <BINARY>          # regular file, no symlinks (O_NOFOLLOW)
    --tracer   {strace,ltrace,gdb-batch}
    --output   <DIR>             # bind-scope guarded output directory
    [--kernel  PATH]             # VM kernel path (default: /rsdd/vmlinuz; not executed)
    [--rootfs  PATH]             # VM rootfs image path (default: /rsdd/rootfs.img; not executed)
    [--cpu-seconds N] [--wall-seconds N]
    [--max-mem-bytes N] [--max-output-bytes N]
    [--allow-exec]               # authorize live run via TraceVmExecutor
    [--max-input-bytes N]        # optional input-size cap (default: unlimited)
```

Architecture (`arch`) is auto-detected from the target's ELF `e_machine` header
(same logic as `qemu_plan.py` and `detonate_plan.py`). Non-ELF targets degrade
to `"x86_64"` silently.

## Disk slots and per-drive containment policy

The trace VM uses **three typed disk drives** (per-drive policy; global `-snapshot`
is **absent** from the `planned_argv`). The live executor (D3) creates
`<run_dir>/scratch.img` and substitutes the sentinel `/rsdd/scratch.img` before Popen.

| Slot | Guest path | Drive flags | Rationale |
|---|---|---|---|
| **Target (sample)** | `/input/sample` | `readonly=on,snapshot=off,format=raw,if=virtio` | Target identity is immutable. `readonly=on` prevents any write — even for the tracer. `snapshot=off` is explicit. `format=raw` avoids qcow2 backing-file escape. |
| **Scratch** | host: `<run_dir>/scratch.img` | `snapshot=off,format=raw,if=virtio` | The only writable-persistent disk. Trace output written by the guest agent (strace/ltrace/gdb output to `/mnt/scratch/trace.log`) lands here. Host reads it post-teardown via O_NOFOLLOW. `snapshot=off` ensures writes survive qemu exit. Pre/post sha256 hashes feed the evidence chain. |
| **Rootfs** | `/input/rootfs` | `snapshot=on,format=raw,if=virtio` | COW overlay discards all guest OS writes on exit. The host rootfs image is unmodified. `snapshot=on` is the ephemeral sentinel; `format=raw` is mandatory. |

**Containment identity with detonate**: the `lib/vm_disk_policy.py` checker is the
SAME module imported by both `DetonateVmExecutor` and `TraceVmExecutor`. A trace plan
that passes preflight is guaranteed to satisfy every detonate containment rule — there
is no separate trace-only policy. The only delta is the guest-side `-append` kernel
cmdline token that selects the tracer agent.

## Tracer selection (guest-side only)

The tracer is encoded as a kernel cmdline argument and never appears in the host-level
bwrap or qemu argv as a directly executable binary:

```
-append "init=/rsdd-agent rsdd.tracer=strace"
# or:  rsdd.tracer=ltrace
# or:  rsdd.tracer=gdb-batch
```

The guest-side `rsdd-agent` reads `/proc/cmdline`, detects `rsdd.tracer=<tracer>`,
mounts `/dev/vda` (the target disk) read-only, and invokes:

| Tracer | Guest agent action |
|---|---|
| `strace` | `strace -f -o /mnt/scratch/trace.log -- <target>` |
| `ltrace` | `ltrace -f -o /mnt/scratch/trace.log -- <target>` |
| `gdb-batch` | `gdb --batch -ex run -ex bt --args <target>` |

The host never calls strace/ltrace/gdb directly. The target binary never executes
on the host. This is the same isolation boundary as detonate.

## Containment policy (future live executor MUST enforce every row)

This table is the normative containment spec. It is identical to
`detonate-plan.v1.md`'s table (same shared `vm_disk_policy` enforces both).

| Policy | Guarantee | Enforcing mechanism |
|---|---|---|
| **Network namespace** | `--unshare-net`. Target MUST NOT reach any network interface. | `--unshare-net`; `network: "none"` |
| **PID namespace** | `--unshare-pid`. Target sees only its own process tree. | `--unshare-pid` |
| **IPC namespace** | `--unshare-ipc`. Isolates System V IPC / POSIX MQs. | `--unshare-ipc` |
| **UTS namespace** | `--unshare-uts`. Target cannot change host identity. | `--unshare-uts` |
| **Cgroup namespace** | `--unshare-cgroup`. Defense-in-depth against cgroup escape. | `--unshare-cgroup` |
| **Capabilities** | `--cap-drop ALL`. No capability abuse possible. | `--cap-drop ALL` |
| **Parent-death signal** | `--die-with-parent`. Sandbox killed when parent exits. | `--die-with-parent` |
| **Session isolation** | `--new-session`. Cannot access host terminal. | `--new-session` |
| **Target mount** | `/input/sample` mounted read-only. Target cannot self-modify. | `--ro-bind`; `readonly=on` |
| **Host FS** | Exactly one host path writable inside the sandbox: the per-run scratch image, bound as a single file (`--bind <scratch> <scratch>`). The per-run directory itself is not exposed. | `--tmpfs`, `--dir`, `--bind`; `host_writable: mount_plan.scratch_persistent` |
| **Disk** | Per-drive: target `readonly=on` (immutable), rootfs `snapshot=on` (COW), scratch `snapshot=off` (writable-persistent host read). | `disk.mode: "per-drive-policy"` |
| **Acceleration** | `-accel tcg` only; `-enable-kvm` forbidden. | `vm_disk_policy` rejects `-enable-kvm` |
| **NIC** | `-nic none`; `-net`/`-netdev` forbidden. | `vm_disk_policy` rejects both |
| **Sandbox** | `-nodefaults -sandbox on,...=deny`. | `vm_disk_policy` required belt |
| **Host FS devices** | `-virtfs`/`-fsdev`/`-device vfio*` forbidden. | `vm_disk_policy` rejects all |
| **Resource caps** | CPU, memory, wall-clock time, and output bytes bounded. | `limits.*`; enforced by live executor |
| **Snapshot capture** | Pre/post scratch-disk sha256 fed into evidence chain. | `snapshot_policy.pre_run`, `post_run` |

## `trace-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"trace-plan.v1"` | Schema identifier |
| `arch` | `str` | Detected qemu arch suffix (auto-detected from ELF; fallback `"x86_64"`) |
| `qemu_binary` | `str` | Intended qemu binary (e.g. `"qemu-system-x86_64"`; never executed in dry-run) |
| `tracer` | `str` | `"strace"`, `"ltrace"`, or `"gdb-batch"` |
| `tracer_options` | `{follow_forks, syscall_filter}` | Per-tracer options (data only; enforced guest-side) |
| `target` | `{path, sha256, size}` | Target identity (O_NOFOLLOW) |
| `network` | `"none"` | Always "none" — isolation mandatory |
| `network_policy` | `{mode, justification}` | Explicit isolation record |
| `disk` | `{mode, pre_snapshot_digest, post_snapshot_capture}` | `mode="per-drive-policy"` (D3 rebuild) |
| `mount_plan` | `{sample_ro, rootfs_ro, scratch_persistent, output_writable, host_writable[, runtime_tree_ro]}` | Mount containment. When `--qemu-root` is supplied, `runtime_tree_ro: "/rsdd/rt"` is emitted in this dict (the key is absent, not null, when `--qemu-root` is not used). |
| `limits` | `{cpu_seconds, mem_bytes, wall_seconds, output_bytes}` | Resource caps |
| `snapshot_policy` | `{pre_run, post_run}` | State-hash capture intent |
| `planned_argv` | `list[str]` | Full bwrap+qemu-system invocation with three typed `-drive` args, a file-scoped `--bind` for the scratch image, and `-append` (NEVER executed in dry-run) |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | `["outputs-unknown-until-live-run"]` |

`disk.mode = "per-drive-policy"` signals the per-drive snapshot approach introduced in
D3. A live executor MUST parse each `-drive` spec individually.

`mount_plan.scratch_persistent = "/rsdd/scratch.img"` is a **plan-time sentinel**.
The live executor (D3) substitutes the actual `<run_dir>/scratch.img` path in
`exec_argv` before calling Popen.

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
> Addressed by issue #65 (Slices A+B; previously tracked as gaps 1/3/4 per
> design.md §2).

`mount_plan.host_writable`: must equal `mount_plan.scratch_persistent` — exactly one host
filesystem path is made writable inside the sandbox (the per-run scratch image, bound as a
single file). Any other value MUST cause the executor to refuse the plan before entering
the sandbox. (`"none"` was the value when the bind was missing; corrected by issue #60 / INV-2.)

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): always `declared:false`,
`basis:"dry-run-plan"`, `receipt_identity:null`.

| Condition | Outcome |
|---|---|
| `--allow-exec` absent | `authorization-required` / exit 3 |
| `--allow-exec` + qemu not on PATH | `GateError` / exit 2 |
| `--allow-exec` + qemu on PATH | live `TraceVmExecutor.evaluate()` called |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.
