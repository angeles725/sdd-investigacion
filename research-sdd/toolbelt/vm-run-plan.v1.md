# Plan record `vm-run-plan.v1`

`vm_run.py` (U-V3) emits this schema in DRY-RUN mode: no VM is booted,
no archive is inflated, no subprocess is spawned.

## CLI

```
vm_run.py plan --input ARCHIVE --output DIR [--codec {gzip,xz,auto}]
               [--cpu-seconds N] [--max-mem-bytes N]
               [--max-output-bytes N] [--wall-seconds N] [--allow-exec]
               [--max-input-bytes N]  # absent/None → unlimited (default); set → fail closed > N bytes
```

Exit: `0` live run (future); `2` error/gate hard-refuse; `3` auth-required (plan written).

## Containment policy (enforced at plan time)

| Invariant | Enforcement |
|---|---|
| No inflation | Declared size from gzip ISIZE / xz Index; stream never read |
| No subprocess | bwrap argv is recorded data, never exec'd in this unit |
| Bind safety | Output path checked via `assert_safe_bind_root` |
| Bomb bound | Plan refused (exit 2) when `declared_decompressed_bytes > limits.output_bytes` |
| gzip ISIZE caveat | mod-2^32, untrusted; documented in `input.declared_size_caveat` |

## `vm-run-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"vm-run-plan.v1"` | Schema sentinel |
| `codec` | `"gzip"\|"xz"` | Detected or declared codec |
| `over_bound` | bool | `true` = bomb bound exceeded; plan refused (no output written) |
| `input.path` | str | Absolute resolved host path |
| `input.sha256` | sha256 | Content hash (O_NOFOLLOW, TOCTOU-safe) |
| `input.size` | int | Compressed archive byte count |
| `input.declared_decompressed_bytes` | int | gzip ISIZE or xz Index uncompressed sum |
| `input.declared_size_caveat` | str | gzip untrustworthiness note; "authoritative" for xz |
| `limits.{cpu_seconds,mem_bytes,wall_seconds,output_bytes}` | int>0 | Resource caps |
| `mount_plan.{input_ro,output_writable,tmpfs_work}` | str | VM-internal paths |
| `planned_argv` | str[] | Would-be bwrap+decompressor argv (never executed here) |
| `outputs` | `[]` | Empty — unknown until live run |
| `limitations` | str[] | Always includes `"outputs-unknown-until-live-run"` |

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): written alongside in the same output
directory. Dry-run state: `declared: false`, `basis: "dry-run-plan"`, `receipt_identity: null`.

Gate contract: [`gate-authorization.v1`](gate-authorization.v1.md).

```python
result = execute_or_plan(cap=CAP_EXEC, allow=args.allow_exec, plan=plan,
                         live_executor=None, output_dir=None)
if result["outcome"] == "authorization-required":
    sys.exit(EXIT_AUTH_REQUIRED)   # exit 3
# --allow-exec + RSDD_EXEC_EXECUTOR unset → GateError → exit 2
```
