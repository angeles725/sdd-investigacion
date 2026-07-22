# FACT Core firmware analysis plan `fact-plan.v1`

`fact_plan.py` — offline FACT Core Docker-Compose planner (U-D18 / item 18).
Produces `fact-plan.v1.json` + `vm-determinism.v1.json`. NEVER runs docker-compose or docker.
Live exec gated behind `--allow-docker` ([gate-authorization.v1](gate-authorization.v1.md)).

## CLI

```
python3 fact_plan.py plan \
    --firmware      FILE          # regular file, no symlinks (O_NOFOLLOW)
    --output        DIR           # bind-scope guarded output directory
    [--compose-file FILE]         # docker-compose.yml path (validated; ':'/','  rejected)
    [--project-name NAME]         # compose project name (validated charset; default: fact)
    [--frontend-tag TAG]          # FACT frontend image tag (validated)
    [--backend-tag  TAG]          # FACT backend/core image tag (validated)
    [--db-tag       TAG]          # FACT database image tag (validated)
    [--plugin       NAME] ...     # analysis plugin name(s) (validated, repeatable)
    [--cpus N] [--memory SIZE] [--pids-limit N] [--wall-seconds N]
    [--allow-docker]              # authorize live run (no live executor → exit 2)
    [--max-input-bytes N]         # absent/None → unlimited (default); set → fail closed > N bytes
```

## Containment policy (future live executor MUST enforce every row)

| Policy | Guarantee | Enforcing mechanism |
|---|---|---|
| **No docker in plan** | No subprocess spawned, no image pulled, no container started. | `subprocess.Popen/run` never called; `socket` not imported |
| **NO --privileged** | Blanket `--privileged` REFUSED; never emitted in `planned_argv`. | `"--privileged"` absent by construction |
| **NO --network host** | FACT services communicate via internal bridge; host network NEVER used. | `"--network"` absent from compose argv; `network: "internal-bridge"` in record |
| **Internal bridge only** | Services reach each other by service name; no outbound internet egress. | `network: "internal-bridge"` enforced in the plan; live executor must not add egress routes |
| **Firmware read-only** | Firmware staged to `/tmp/rsdd/firmware-input` read-only before REST upload. | `mount_plan.firmware_ro` in record; live executor must honour |
| **Output to /tmp/rsdd only** | Writable output only to `/tmp/rsdd`; no other host paths writable. | `mount_plan.output_writable: "/tmp/rsdd"` |
| **DB volume project-scoped** | FACT database volume named `{project}_db`; NEVER a raw host bind-mount. | `persistent_storage.scope: "compose-project-scoped"` |
| **Resource limits** | `--cpus`, `--memory`, `--pids-limit` always bounded (sane defaults). | `resource_limits.*`; live executor must pass these to compose services |
| **Tag/name safe charset** | Image tag: `[A-Za-z0-9._:/@-]`. Project/plugin: `[A-Za-z0-9._-]`. No metacharacters; no leading dash. | `_validate_tag()` / `_validate_name()` — exit 2, no traceback |
| **':'/','  path safety** | Firmware path and compose-file path rejected if containing `':'` or `','`. | `_reject_delimiters()` — exit 2, no plan written |
| **Argv as `list[str]`** | All arguments are discrete list elements; no shell string. | `planned_argv: list[str]`; no `shell=True` |
| **Firmware identity** | Content-addressed (sha256) via O_NOFOLLOW; symlinks rejected. | `adapter_core.identity` — AdapterError on symlink/missing |
| **Output bind-scope** | Output directory rejected if blocked system root or too shallow. | `assert_safe_bind_root` → exit 2 |

## `fact-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"fact-plan.v1"` | Schema identifier |
| `firmware` | `{path, sha256, size}` | Firmware identity (O_NOFOLLOW; content-addressed) |
| `deployment` | `{planned_argv, project_name, compose_file, image_tags}` | Compose deployment plan; argv NEVER executed in dry-run |
| `network` | `"internal-bridge"` | Always `"internal-bridge"` — NEVER `"host"` |
| `submission` | `{mode, firmware_sha256, planned_endpoint, planned_method, plugins, note}` | REST submission plan (plan-only; no request made) |
| `resource_limits` | `{cpus, memory, pids_limit, wall_seconds}` | Container resource caps |
| `mount_plan` | `{firmware_ro, output_writable}` | Mount containment summary |
| `persistent_storage` | `{db_volume, scope, note}` | DB volume scoped to compose project |
| `privilege_requirement` | `{requires_privileged, recorded_as, justification, status}` | Privilege need as data; `status: "refused-in-plan"` |
| `outputs` | `[]` | Empty until live run |
| `limitations` | `list[str]` | Digest/submission/volume/network warnings |

`network: "internal-bridge"` — FACT frontend, backend, and db services communicate
via docker compose's default internal bridge. The live executor MUST NOT add
`--network host` or any external egress route.

## Determinism and gate

[`vm-determinism.v1.json`](vm-determinism.v1.md): `declared:false`, `basis:"dry-run-plan"`, `receipt_identity:null`.
Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-docker` absent | `authorization-required` / exit 3 |
| `--allow-docker` + no executor | `GateError` / exit 2 |

Exit codes: 0 ran · 2 hard error · 3 authorization-required.
`RSDD_DOCKER_EXECUTOR` env var: test-seam stub exporting `execute(plan) -> dict`.
