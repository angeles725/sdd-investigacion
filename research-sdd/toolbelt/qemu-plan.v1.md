# QEMU emulation plan `qemu-plan.v1`

`qemu_plan.py` — offline QEMU invocation planner (U-V10 / item 10).
Produces `qemu-plan.v1.json` + `vm-determinism.v1.json`. NEVER executes:
no QEMU launched, no subprocess spawned, no target emulated.
Live exec gated behind `--allow-exec` (U-F1 gate contract).

## CLI

```
python3 qemu_plan.py plan \
    --target   <BINARY>               # regular file, no symlinks (O_NOFOLLOW)
    --output   <DIR>                  # bind-scope guarded output directory
    --mode     qemu-user|qemu-system  # emulation mode
    [--cpu-seconds N] [--wall-seconds N]
    [--max-mem-bytes N] [--max-output-bytes N]
    [--allow-exec]    # authorize live run (no executor in this unit → exit 2)
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

## Determinism and gate

`vm-determinism.v1.json`: always `declared:false`, `basis:"dry-run-plan"`,
`receipt_identity:null`. Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-exec` absent | `authorization-required` / exit 3 |
| `--allow-exec` + no executor | `GateError` / exit 2 |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.
