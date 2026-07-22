# EMBA firmware analysis plan `emba-plan.v1`

`emba_plan.py` — offline EMBA Docker planner (U-D17 / item 17).
Produces `emba-plan.v1.json` + `vm-determinism.v1.json`. NEVER runs docker.
Live exec gated behind `--allow-docker` (U-F1 gate contract).

## CLI

```
python3 emba_plan.py plan \
    --firmware     FILE      # regular file, no symlinks (O_NOFOLLOW)
    --output       DIR       # bind-scope guarded output directory
    [--image-tag   TAG]      # docker image tag (validated; default: embeddedanalyzer/emba:latest)
    [--profile     NAME]     # EMBA profile/module name (validated charset)
    [--cpus N] [--memory SIZE] [--pids-limit N] [--wall-seconds N]
    [--allow-docker]         # authorize live run (no live executor → exit 2)
    [--max-input-bytes N]    # optional input-size cap (default: unlimited)
                             # absent/None → no cap, behavior byte-identical to baseline
                             # set to N → firmware > N bytes fail closed (exit 2, no traceback)
```

## Containment policy (future live executor MUST enforce every row)

| Policy | Guarantee | Enforcing mechanism |
|---|---|---|
| **No docker in plan** | No subprocess spawned, no image pulled, no container started. | `subprocess.Popen/run` never called; `socket` not imported |
| **NO --privileged** | Blanket `--privileged` REFUSED; never emitted in `planned_argv`. EMBA privilege need recorded in `privilege_requirement` as data with `status: "refused-in-plan"`. | `"--privileged"` absent by construction |
| **Specific caps only** | Live executor MUST grant only specific Linux capabilities EMBA needs (e.g., `CAP_SYS_PTRACE`, `CAP_DAC_READ_SEARCH`), NOT blanket `--privileged`. | `privilege_requirement.specific_caps_required` (live executor populates) |
| **Network isolation** | `--network none` always emitted; container has no network access. | `--network none` in `planned_argv`; `network: "none"` in record |
| **Firmware read-only** | Firmware mounted `-v host:/firmware:ro`; container cannot modify it. | `:/firmware:ro` suffix in `-v` argv element |
| **Output to /tmp/rsdd only** | Writable output only to `/tmp/rsdd`; no other host paths writable. | `-v /tmp/rsdd:/tmp/rsdd` in `planned_argv` |
| **Resource limits** | `--cpus`, `--memory`, `--pids-limit` always bounded (sane defaults). | `resource_limits.*`; discrete argv elements |
| **Tag/profile safe charset** | Image tag: `[A-Za-z0-9._:/@-]`. Profile: `[A-Za-z0-9._-]`. No metacharacters; no leading dash. | `_validate_tag()` / `_validate_profile()` — exit 2, no traceback |
| **Argv as `list[str]`** | All arguments are discrete list elements; no shell string. | `planned_argv: list[str]`; no `shell=True` |
| **Firmware identity** | Content-addressed (sha256) via O_NOFOLLOW; symlinks rejected. | `adapter_core.identity` — AdapterError on symlink/missing |
| **Output bind-scope** | Output directory rejected if blocked system root or too shallow. | `assert_safe_bind_root` → exit 2 |

## `emba-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"emba-plan.v1"` | Schema identifier |
| `firmware` | `{path, sha256, size}` | Firmware identity (O_NOFOLLOW; content-addressed) |
| `image` | `{tag, digest}` | Docker image; `digest: null` in dry-run (live executor must pin) |
| `resource_limits` | `{cpus, memory, pids_limit, wall_seconds}` | Container resource caps |
| `network` | `"none"` | Always `"none"` — isolation mandatory |
| `mount_plan` | `{firmware_ro, output_writable}` | Mount containment summary |
| `profile` | `str \| null` | EMBA profile/module name |
| `planned_argv` | `list[str]` | Full `docker run` invocation (NEVER executed in dry-run) |
| `privilege_requirement` | `{requires_privileged, recorded_as, justification, specific_caps_required, status}` | EMBA privilege need as data; `status: "refused-in-plan"` |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | Privilege warning + image-digest notice |

`privilege_requirement.requires_privileged: true` — EMBA needs elevated access.
`status: "refused-in-plan"` — `--privileged` is never emitted. Live executor MUST NOT add it;
use specific caps from `specific_caps_required` only (principle of least privilege).

## Determinism and gate

`vm-determinism.v1.json`: `declared:false`, `basis:"dry-run-plan"`, `receipt_identity:null`.
Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-docker` absent | `authorization-required` / exit 3 |
| `--allow-docker` + no executor | `GateError` / exit 2 |

Exit codes: 0 ran · 2 hard error · 3 authorization-required.
`RSDD_DOCKER_EXECUTOR` env var: test-seam stub exporting `execute(plan) -> dict`.
