# FACT live-run receipt `fact-run.v1`

`lib/fact_exec.py` — `LiveFactExecutor` — live FACT Core execution receipt.
Emitted on the stdout of `fact_plan.py plan --allow-docker` on success.
Live execution requires `--allow-docker`; absent → exit 3 + offline plan only.
See [`gate-authorization.v1`](gate-authorization.v1.md) and [`fact-plan.v1`](fact-plan.v1.md).

## CLI

```
python3 fact_plan.py plan \
    --firmware      FILE          # firmware to analyse
    --output        DIR           # plan output directory
    [--compose-file FILE]         # user docker-compose.yml (optional)
    [--project-name NAME]         # base compose project name (default: fact)
    [--frontend-tag TAG]          # FACT frontend image (default: fkiecad/fact_frontend:latest)
    [--backend-tag  TAG]          # FACT backend/core image (default: fkiecad/fact_core:latest)
    [--db-tag       TAG]          # FACT db image (default: fkiecad/fact_db:latest)
    [--wall-seconds N]            # global deadline across all phases (default: 7200)
    --allow-docker                # authorize live docker-compose run
    [--rest-base-url URL]         # FACT REST API base URL (must be loopback; executor-only)
```

`--rest-base-url` is **executor-only** — it is NOT persisted in `fact-plan.v1.json`.
Existing `fact-plan.v1` goldens remain byte-identical; do not bump fact-plan.v1.

## Security model

| Control | Mechanism |
|---|---|
| No egress | compose override sets `networks.default.internal: true`; post-up check verifies |
| Digest pinning | `resolve_digest` (local `docker image inspect`, no pull) ×3 before up |
| Override file pinning | Compose `-f override.yml` replaces image tags with `repo@sha256:` refs |
| Per-run isolation | Project name `fact-<uuid8>`; subdir `/tmp/rsdd/rsdd-<uuid>`; volume `fact-<uuid8>_db` |
| TOCTOU closure | Firmware bytes read ONCE (O_NOFOLLOW, bounded) → hashed → PUT; no mount race |
| Loopback-only REST | `--rest-base-url` host must be `127.0.0.1` or `localhost`; rejected otherwise |
| Teardown | `compose down -v` in `finally` from the moment `compose up` is spawned |
| PUT not retried | Firmware is PUT exactly once; no retry on transient failure |

## Phase sequence and wall_seconds budget

ONE global monotonic deadline (`wall_seconds`, default 7200 s) spans ALL phases:

```
preflight → resolve ×3 → TOCTOU read → compose up -d
  → post-up verify → readiness poll → PUT firmware → analysis poll
  → collect outputs → finally: compose down -v
```

## `fact-run.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"fact-run.v1"` | Schema identifier |
| `executed` | `true` | Always true when this receipt is emitted |
| `project_name` | `str` | Per-run compose project name (`fact-<uuid8>`) |
| `exec_argv_up` | `list[str]` | Full compose up argv executed |
| `argv_deltas` | `list[dict]` | Three transforms applied: project-name, override-pinning, output-subdir |
| `image_digests` | `{frontend, backend, db}` | Resolved `sha256:…` digests for each service |
| `firmware_uid` | `str` | UID returned by FACT REST PUT |
| `analysis_result` | `dict` | Final GET /rest/firmware/{uid} body |
| `duration_s` | `float` | Wall time across all phases (prep through analysis; seconds) |
| `up_stdout` | `str` | Compose up stdout (capped at 1 MiB) |
| `up_stderr` | `str` | Compose up stderr (capped at 1 MiB) |
| `up_stdout_truncated` | `bool` | True if stdout was capped |
| `up_stderr_truncated` | `bool` | True if stderr was capped |
| `output_files` | `list[dict]` | `{path, size, sha256}` for files in per-run subdir |

## Residual risks

| Risk | Notes |
|---|---|
| **dockerd trust boundary** | Daemon compromise bypasses `internal:true` network isolation |
| **inspect→up digest race ×3** | Local image may be replaced between `image inspect` and `compose up`; post-up verify narrows but does not close this window entirely |
| **Service-name constants** | Post-up verify checks running containers; pre-verification window remains if compose starts wrong services |
| **internal:true egress claim** | Relies on override file + post-up check; FACT plugins requiring egress will degrade |
| **Loopback REST impersonation** | Any local process can intercept `127.0.0.1`; no mutual authentication |
| **down -v = no cross-run DB persistence** | v1 is ephemeral per run; DB volume removed on teardown |
| **compose exit codes** | Less standardised than `docker run` 125/126/127; any non-zero exit treated as failure |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Live FACT run succeeded; `fact-run.v1` JSON on stdout |
| 2 | Hard error (preflight, digest, TOCTOU, REST, timeout, verify failure) |
| 3 | Authorization-required (`--allow-docker` absent); offline plan only |

## Test seam

`RSDD_DOCKER_EXECUTOR` env var: set to a Python file exporting `execute(plan) -> dict`.
Wins over `LiveFactExecutor` when the flag is True (same gate precedence as EMBA).
See [`gate-authorization.v1`](gate-authorization.v1.md) §Test-seam env vars.
