# QEMU emulation plan `qemu-plan.v1`

`qemu_plan.py` — offline QEMU invocation planner (U-V10 / item 10).
Produces `qemu-plan.v1.json` + `vm-determinism.v1.json`. NEVER executes:
no QEMU launched, no subprocess spawned, no target emulated.
Live exec gated behind `--allow-exec` ([gate-authorization.v1](gate-authorization.v1.md)).

## CLI

```
python3 qemu_plan.py plan \
    --target   <BINARY>               # regular file, no symlinks (O_NOFOLLOW)
    --output   <DIR>                  # bind-scope guarded output directory
    --mode     qemu-user|qemu-system  # emulation mode
    [--cpu-seconds N] [--wall-seconds N]
    [--max-mem-bytes N] [--max-output-bytes N]
    [--allow-exec]    # authorize live run (no executor in this unit → exit 2)
    [--max-input-bytes N]  # absent/None → unlimited (default); set → fail closed > N bytes
```

## ELF architecture detection

Reads `e_ident[EI_DATA]` + `e_machine` (raw bytes at offset 18, ≤20 bytes total).
Never executes the target. Degrades to exit 2 (no traceback) on: too-short file,
bad magic, unknown EI_DATA encoding, unmapped e_machine.

Key mappings: EM_ARM(40)→arm, EM_AARCH64(183)→aarch64, EM_X86_64(62)→x86_64,
EM_MIPS(8)→mips, EM_386(3)→i386, EM_PPC(20)→ppc, EM_PPC64(21)→ppc64,
EM_SH(42)→sh4, EM_RISCV(243)→riscv64.

Binary: `qemu-{arch}` (user mode) or `qemu-system-{arch}` (system mode).

## qemu-plan.v1 schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"qemu-plan.v1"` | Versioned schema identifier |
| `mode` | `"qemu-user"\|"qemu-system"` | Emulation mode |
| `arch` | `str` | Detected architecture suffix (e.g. `"arm"`, `"aarch64"`) |
| `qemu_binary` | `str` | Intended QEMU binary name (never executed) |
| `target` | `{path, sha256, size}` | Target identity (O_NOFOLLOW, content hash) |
| `limits` | `{cpu_seconds, mem_bytes, wall_seconds, output_bytes}` | Resource caps |
| `mount_plan` | `dict` | `target_ro`, `output_writable`, `disk_snapshot` (system) |
| `planned_argv` | `list[str]` | Full bwrap + qemu invocation (never executed) |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | `["outputs-unknown-until-live-run"]` |

`disk_snapshot: "ephemeral"` is present only in `qemu-system` mode so guest
disk writes are discarded on exit.

## Containment guarantees — qemu-system mode

`qemu-system` mode applies belt-and-suspenders containment: the OUTER layer is
`bwrap`; the INNER layer is qemu's own flags. Both must be present.

| Flag | Layer | Rationale |
|---|---|---|
| `bwrap --unshare-net` | outer | Kernel-level net namespace: no host networking for the whole bwrap subtree |
| `-nic none` | inner | qemu-level net isolation: qemu itself has no NIC; `bwrap --unshare-net` alone could be bypassed if qemu spawned a helper outside bwrap |
| `bwrap --unshare-pid` | outer | Isolated PID namespace: processes cannot see host PIDs |
| `bwrap --cap-drop ALL` | outer | Drop all Linux capabilities; qemu-system under TCG needs none |
| `-nodefaults` | inner | Suppress all default devices (VGA, USB hub, etc.); minimise qemu's attack surface |
| `-sandbox on,...` | inner | qemu's own seccomp filter: deny obsolete/elevated/spawn/resourcecontrol syscalls |
| `-smp 1` | inner | Bound vCPUs to 1; combined with `-m` this caps both memory and CPU parallelism |
| `-accel tcg` | inner | Software emulation only — no `/dev/kvm` opened, no host kernel virt extensions touched; fully offline-testable; KVM is the user's explicit manual opt-in |
| `-snapshot` | inner | Guest disk writes are discarded on exit; vacuous without a `-drive` (no disk image in this planning unit — the V1b detonation slice adds disk images) |
| `bwrap --ro-bind <target> /input/target` | outer | Target binary bind-mounted read-only; qemu reads it via `-kernel /input/target` |

### qemu-user mode
`qemu-user` mode translates guest binaries on the HOST kernel (same risk class as
host-bwrap detonation). The plan is generated but **live boot is refused** at the
executor level. Only `qemu-system` is bootable in this unit.

### Belt-and-suspenders rationale
`bwrap --unshare-net` alone isolates the network namespace but qemu could, in
principle, reach a host-visible interface via a device backend if the qemu argv
allowed it. `-nic none` closes this: qemu itself has no NIC regardless of
namespace state. Similarly, `-nodefaults` removes device-emulation attack surface
that `-sandbox on` then seccomp-hardens at the syscall level.

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): always `declared:false`, `basis:"dry-run-plan"`,
`receipt_identity:null`. Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-exec` absent | `authorization-required` / exit 3 |
| `--allow-exec` + no executor | `GateError` / exit 2 |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.
