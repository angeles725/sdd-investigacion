# vm-boot-run.v1 — Live QEMU System-Mode Boot Evidence Schema

Schema emitted by `lib/qemu_exec.py` `LiveQemuBootExecutor` when `qemu_plan.py plan
--allow-exec --mode qemu-system` is invoked. This is the **isolation substrate**
below the future detonate/trace-inside-VM unit. The real hypervisor boot (and any
in-VM detonation) is the user's gated manual step; CI tests run entirely offline with
a fake `qemu-system-*` shim.

## Fields

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"vm-boot-run.v1"` | Schema identifier |
| `executed` | `true` | Always true when emitted by live executor |
| `outcome` | `"success" \| "timeout-killed" \| "boot-failure"` | Run outcome |
| `exec_argv` | `list[str]` | Actual argv executed (bwrap + qemu-system inner) |
| `argv_deltas` | `list` | Always `[]` — `exec_argv` equals `planned_argv` (no token mutations). Serial log path is in the top-level `serial_log` field. |
| `exit_code` | `int \| null` | qemu exit code; null on timeout-killed |
| `exit_reason` | `"timeout" \| null` | Set when exit_code is null |
| `duration_s` | `float` | Wall seconds from Popen to reap |
| `serial_log` | `str` | Host path to saved serial console (stdout under -nographic) |
| `stdout` | `str` | Capped stdout (≤ OUTPUT_CAP chars) |
| `stderr` | `str` | Capped stderr (≤ OUTPUT_CAP chars) |
| `stdout_truncated` | `bool` | True when stdout was capped |
| `stderr_truncated` | `bool` | True when stderr was capped |
| `output_files` | `list[{path, sha256, size}]` | Files in per-run subdir |
| `vm_receipt_identity` | `str` (optional) | sha256 identity of the co-emitted `vm-run-receipt.v1` |
| `vm_determinism_identity` | `str` (optional) | sha256 identity of the co-emitted `vm-determinism.v1` |

## Co-emitted artifacts (in per-run subdir)

- `serial.log` — capped serial console captured from stdout (qemu `-nographic`)
- `vm-run-receipt.v1.json` — canonical receipt built via `vm_receipt.build_receipt`
  with `vm_pre_snapshot=null, vm_post_snapshot=null` (boot-only; populated by the
  later detonation unit), `exit_status.signal=9` on timeout-killed
- `vm-determinism.v1` wraps the receipt identity with `basis="unverified"`,
  `declared=false` (single live run, no replicate), `clock.mode="host"`

## Residual risks

- **qemu device-emulation CVEs**: mitigated by `-nodefaults` (minimal devices),
  `-sandbox on` (qemu seccomp), and nesting inside bwrap `--cap-drop ALL --unshare-net`.
  Keep qemu patched (operator prereq).
- **KVM / /dev/kvm exposure**: avoided by default TCG (`-accel tcg`). KVM is the
  user's explicit manual-boot opt-in, not in scope for this offline unit.
- **Tap networking**: REJECTED. `-nic none` + bwrap `--unshare-net` only.
- **9p/virtfs host-FS exposure**: REJECTED. Sample-in/artifact-out via disk images only.
- **`-snapshot` scope**: protects the guest disk only, not the host. Host containment
  is bwrap + qemu-sandbox + TCG, not `-snapshot`.
- **Un-testable surface**: the real hypervisor boot is the user's gated manual step.
  CI runs offline stub only.

## Related schemas

- [`vm-run-receipt.v1`](vm-run-receipt.v1.md) — canonical deterministic receipt
- [`vm-determinism.v1`](vm-determinism.v1.md) — wraps receipt identity
- [`qemu-plan.v1`](qemu-plan.v1.md) — upstream offline plan
