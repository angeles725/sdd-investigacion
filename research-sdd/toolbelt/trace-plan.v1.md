# Plan record `trace-plan.v1`

`trace_plan.py` (U-V9) emits this schema in DRY-RUN mode: no tracer is launched,
no subprocess is spawned, the target is never executed. The plan records the exact
gdb/strace/ltrace invocation that WOULD run, gated behind `--allow-exec`.

## Supported tracers

| `tracer` | Tool | Key planned flags |
|---|---|---|
| `strace` | strace(1) | `-f` follow-forks, `-o /tmp/rsdd/out/trace.log` |
| `ltrace` | ltrace(1) | `-f` follow-forks, `-o /tmp/rsdd/out/trace.log` |
| `gdb-batch` | gdb(1) | `--batch -ex run -ex bt --args` |

## CLI

```
trace_plan.py plan --target BINARY --tracer {strace,ltrace,gdb-batch} --output DIR
                   [--cpu-seconds N] [--max-mem-bytes N] [--max-output-bytes N]
                   [--wall-seconds N] [--allow-exec]
                   [--max-input-bytes N]  # absent/None → unlimited (default); set → fail closed > N bytes
```

Exit: `0` live run (future); `2` error/gate hard-refuse; `3` auth-required.

## Containment policy (enforced at plan time)

| Invariant | Enforcement |
|---|---|
| No execution | Target is never exec'd; `planned_argv` is recorded data only |
| No subprocess | Zero Popen/run calls; data from identity + constants only |
| Symlink rejection | Target opened with `O_NOFOLLOW` (adapter_core.identity) |
| Bind safety | Output path checked via `assert_safe_bind_root` |
| Deterministic | Same target → identical plan (content-addressed) |

## `trace-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"trace-plan.v1"` | Schema sentinel |
| `tracer` | string | `strace`, `ltrace`, or `gdb-batch` |
| `tracer_options.follow_forks` | bool | Whether tracer follows child processes |
| `tracer_options.syscall_filter` | str\|null | Syscall filter (null = all; strace only) |
| `target.{path,sha256,size}` | — | Host path (O_NOFOLLOW), content hash, byte count |
| `limits.{cpu_seconds,mem_bytes,wall_seconds,output_bytes}` | int>0 | Resource caps |
| `mount_plan.{target_ro,output_writable}` | str | Sandbox path assignments |
| `planned_argv` | str[] | Full bwrap + tracer argv (never executed in this unit) |
| `outputs` | `[]` | Empty — unknown until live run |
| `limitations` | str[] | Always `["outputs-unknown-until-live-run"]` |

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): written alongside. Dry-run state:
`declared: false`, `basis: "dry-run-plan"`, `receipt_identity: null`.

Gate contract: [`gate-authorization.v1`](gate-authorization.v1.md).

```python
result = execute_or_plan(cap=CAP_EXEC, allow=args.allow_exec, plan=plan,
                         live_executor=None, output_dir=None)
if result["outcome"] == "authorization-required":
    sys.exit(EXIT_AUTH_REQUIRED)  # exit 3
# --allow-exec + RSDD_EXEC_EXECUTOR unset → GateError → exit 2
```

`dynamic.sh` is the live Frida wrapper (METHODOLOGY §12); `trace_plan.py` is the
offline plan generator for gdb/strace/ltrace — the two do not overlap. The live
executor (behind `--allow-exec`) should follow the same `[CERT-hw]`
preserve-to-sources discipline as `dynamic.sh` when eventually implemented.
