# Hostile-sample detonation plan `detonate-plan.v1`

`detonate_plan.py` — offline hostile-sample detonation planner (U-V11 / item 11).
Produces `detonate-plan.v1.json` + `vm-determinism.v1.json`. NEVER executes:
no VM boot, no subprocess spawned, no sample detonated.
Live exec gated behind `--allow-exec` (U-F1 gate contract).

## CLI

```
python3 detonate_plan.py plan \
    --sample   <FILE>   # regular file, no symlinks (O_NOFOLLOW)
    --output   <DIR>    # bind-scope guarded output directory
    [--os-image TAG]    # OS image tag recorded in plan (not executed)
    [--network none]    # only "none" accepted; any other value → exit 2
    [--cpu-seconds N] [--wall-seconds N]
    [--max-mem-bytes N] [--max-output-bytes N]
    [--allow-exec]      # authorize live run (no live executor → exit 2)
    [--max-input-bytes N]  # optional input-size cap (default: unlimited)
                           # absent/None → no cap, behavior byte-identical to baseline
                           # set to N → inputs > N bytes fail closed (exit 2, no traceback)
```

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
| **Writable area** | Only `/tmp/rsdd/out` is writable; all output must go there. No host path is writable (`host_writable: "none"`). | `--tmpfs`, `--dir`; `host_writable: "none"` |
| **Disk** | Ephemeral: all sandbox disk writes are discarded on exit. No persistent side-effects on host storage. | `disk.mode: "ephemeral-snapshot"` |
| **Resource caps** | CPU, memory, wall-clock time, and output bytes are bounded. Exceeding any cap triggers kill + truncate + `reason` field. | `limits.*`; enforced by live executor |
| **Snapshot capture** | Pre-run and post-run disk-state digests MUST be captured before and after detonation (feeds U-F2 evidence chain). | `snapshot_policy.pre_run`, `snapshot_policy.post_run` |

Resource cap defaults: `cpu_seconds=30`, `mem_bytes=256 MiB`, `wall_seconds=60`,
`output_bytes=128 MiB`.

## `detonate-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"detonate-plan.v1"` | Schema identifier |
| `sample` | `{path, sha256, size, type_hint}` | Sample identity (O_NOFOLLOW) |
| `network` | `"none"` | Always "none" — isolation mandatory |
| `network_policy` | `{mode, justification}` | Explicit isolation record |
| `disk` | `{mode, pre_snapshot_digest, post_snapshot_capture}` | Ephemeral disk policy |
| `mount_plan` | `{sample_ro, output_writable, host_writable}` | Mount containment |
| `limits` | `{cpu_seconds, mem_bytes, wall_seconds, output_bytes}` | Resource caps |
| `snapshot_policy` | `{pre_run, post_run}` | State-hash capture intent |
| `os_image` | `str \| null` | OS image tag (recorded, not executed) |
| `planned_argv` | `list[str]` | Full bwrap invocation (NEVER executed in dry-run) |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | `["outputs-unknown-until-live-run"]` |

`sample.type_hint` is metadata-only (magic-byte sniff); degrades to `"unknown"` on
any error without traceback. Does not gate execution.

`mount_plan.host_writable`: the string `"none"` is the **only valid value**, meaning no
host filesystem path is made writable inside the sandbox. An absent field MUST be treated
as a schema error by any validator or live executor. Any value other than `"none"` MUST
cause the executor to refuse the plan before entering the sandbox.

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

`vm-determinism.v1.json`: always `declared:false`, `basis:"dry-run-plan"`,
`receipt_identity:null`. Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-exec` absent | `authorization-required` / exit 3 |
| `--allow-exec` + no executor | `GateError` / exit 2 |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.
