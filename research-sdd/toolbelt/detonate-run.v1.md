# Live detonation receipt `detonate-run.v1`

`detonate_plan.py --allow-exec` → `lib/detonate_exec.py` (D2).
Boots a `qemu-system-<arch>` VM carrying the hostile sample, scratch, and rootfs
disk images in a `bwrap --cap-drop ALL --unshare-net` container.  Pre-boot and
post-teardown sha256 of the scratch disk populate `vm_pre_snapshot` /
`vm_post_snapshot` in the co-emitted `vm-run-receipt.v1`.

**Real in-guest detonation is the HUMAN'S GATED MANUAL STEP — NEVER automated
in CI.**  CI tests run entirely offline with a fake `qemu-system-*` shim.

## CLI

```
python3 detonate_plan.py plan \
    --sample FILE                # hostile sample (regular file; sha256'd O_NOFOLLOW)
    --output DIR
    [--os-image TAG]             # OS image tag (recorded in plan; not executed)
    [--kernel PATH]              # VM kernel path (default /rsdd/vmlinuz)
    [--rootfs PATH]              # rootfs image path (default /rsdd/rootfs.img)
    [--wall-seconds N]           # wall clock cap (default 60)
    [--cpu-seconds N]            # CPU cap (default 30)
    [--max-mem-bytes N]          # memory cap (default 256 MiB)
    [--max-output-bytes N]       # output cap (default 128 MiB)
    --allow-exec                 # authorize live detonation
```

## `detonate-run.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"detonate-run.v1"` | Schema identifier |
| `executed` | `true` | Always true for live receipts |
| `outcome` | `"success"` \| `"timeout-killed"` \| `"boot-failure"` | Run outcome |
| `exec_argv` | `list[str]` | Actual argv executed (bwrap + qemu-system inner, sentinel substituted) |
| `argv_deltas` | `list[{type, from, to}]` | One delta per `_SCRATCH_SENTINEL` substitution — proves planned→actual path mapping |
| `exit_code` | `int \| null` | qemu exit code; `null` on `timeout-killed` |
| `exit_reason` | `"timeout" \| null` | Set when `exit_code` is `null` |
| `duration_s` | `float` | Wall seconds from Popen to reap |
| `serial_log` | `str` | Host path to saved serial console (stdout under -nographic) |
| `stdout` / `stderr` | `str` | Capped output (≤ OUTPUT_CAP bytes) |
| `stdout_truncated` / `stderr_truncated` | `bool` | True when output was capped |
| `output_files` | `list[{path, sha256, size}]` | Files in the per-run subdir: `scratch.img`, `serial.log` (deterministic alpha order; `vm-run-receipt.v1.json` excluded — written after scan) |
| `vm_receipt_identity` | `str` (optional) | sha256 identity of the co-emitted `vm-run-receipt.v1` |
| `vm_determinism_identity` | `str` (optional) | sha256 identity of the co-emitted `vm-determinism.v1` |

## Co-emitted artifacts (in the single per-run subdir)

- `scratch.img` — writable-persistent scratch disk read from the guest post-teardown.
  Host-side sha256 is computed pre-boot (→ `vm_pre_snapshot`) and post-teardown
  (→ `vm_post_snapshot`).  Bytes differ iff the guest agent wrote to scratch.
- `serial.log` — capped serial console captured from qemu stdout (-nographic)
- `vm-run-receipt.v1.json` — canonical receipt built via `vm_receipt.build_receipt`
  with `vm_pre_snapshot` and `vm_post_snapshot` populated when the scratch hash
  succeeds; `null` fields on fail-soft hash error (logged as stderr WARNING, never
  raises through).

## Evidence chain coherence

```
vm_post_snapshot.sha256
    == output_files[scratch.img].sha256
    == sha256(scratch.img at post-teardown)
```

Both hashes reference the SAME file in the SAME per-run subdir (single run_dir
ownership; scratch.img is created by the `pre_boot` seam inside that directory
before the pre-hash, and `output_files()` scans it after teardown).  A consumer
that independently hashes `serial_log`'s parent dir `scratch.img` MUST match
`vm_post_snapshot.sha256`.  Any mismatch indicates tampering or a receipt bug.

## Disk slot policy (per-drive containment)

| Drive | Flag | Semantics |
|---|---|---|
| `/input/sample` | `readonly=on,snapshot=off,format=raw` | Sample identity immutable; guest cannot alter |
| `{run_dir}/scratch.img` | `snapshot=off,format=raw` | Persistent; host reads post-teardown; sha256'd pre/post |
| `/input/rootfs` | `snapshot=on,format=raw` | COW overlay; guest OS writes discarded |

Global `-snapshot` is intentionally ABSENT; per-drive policy replaces it.

## Fail-soft snapshot semantics

If the post-teardown scratch hash fails (e.g. I/O error, scratch removed by guest):
- `vm_post_snapshot` is set to `null` (not raised as a fatal error)
- A `WARNING: vm post-snapshot hash failed` line is emitted to stderr
- All other evidence (`serial_log`, `vm_pre_snapshot`, `outcome`, `output_files`) is preserved

If the pre-boot scratch hash fails:
- `vm_pre_snapshot` is set to `null` (same fail-soft behavior)
- The boot still proceeds

Neither failure aborts the run or discards collected evidence.

## Residual risks

| Risk | Mitigation | Residual |
|---|---|---|
| Guest→qemu device escape | `-nodefaults`, `-sandbox on,...=deny`, `bwrap --cap-drop ALL`; `-accel tcg` (no `/dev/kvm`); virtio-blk device surface narrow | Nested VM escape is not eliminated by software alone; disposable-host policy recommended |
| Sample→scratch TOCTOU | Scratch created fresh (O_NOFOLLOW) by `pre_boot` in the single per-run dir; sha256 computed after `pre_boot` returns and before Popen | Single-process write after O_NOFOLLOW creation — risk negligible |
| Malware-written scratch bytes persist on host | Intentional evidence; run_dir is NOT cleaned up (matches sibling executor convention: capture_exec, docker_exec, fact_exec all leave run_dirs for inspection) | Operator is responsible for post-analysis cleanup |
| qcow2 backing-file host-path escape | `format=raw` mandatory on every `-drive`; `format=qcow2` → GateError at preflight | Eliminated by policy |
| Host-FS 9p/virtfs exposure | `-virtfs`, `-fsdev` forbidden at preflight | Eliminated by policy |

Exit codes: 0 success · 2 preflight/boot error · 3 authorization-required (no `--allow-exec`).
