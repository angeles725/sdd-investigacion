# Gate authorization `gate-authorization.v1`

`lib/gate.py` — single fail-closed authorization boundary shared by all
Research-SDD gated adapters (U-V3/9/10/11, U-N8, U-D17/18).
Ships NO live executor; offline plan path is always fully exercised.

## Capability set

| Token | CLI flag | Items | Live resource |
|---|---|---|---|
| `exec` | `--allow-exec` | 3,9,10,11 | Run untrusted code in VM/sandbox |
| `live-capture` | `--allow-live-capture` | 8 | Open a network interface |
| `docker` | `--allow-docker` | 17,18 | Docker + FACT service network |

## Flag convention

1. **Default OFF, fail-closed.** Absent flag → offline plan emitted, exit 3.
2. **Explicit per-invocation.** No env var alone can cross the gate.
3. **One flag per capability.** `--allow-exec` authorizes only `exec`.
4. **Defense in depth.** Live executors re-verify prerequisites, fail closed.

## Test-seam env vars (mirrors `RSDD_BINWALK_TEST_ONLY`)

| Cap | Env var |
|---|---|
| `exec` | `RSDD_EXEC_EXECUTOR` |
| `live-capture` | `RSDD_LIVE_CAPTURE_EXECUTOR` |
| `docker` | `RSDD_DOCKER_EXECUTOR` |

Set to the absolute path of a Python file exporting `execute(plan: dict) -> dict`.
Consulted only when the flag is True. Each cap reads only its own var.

## Authorization-required outcome schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"gate-authorization.v1"` | Versioned upgrade path for downstream consumers |
| `outcome` | `"authorization-required"` | Stable sentinel |
| `capability` | `str` | e.g. `"exec"` |
| `flag` | `str` | e.g. `"--allow-exec"` |
| `message` | `str` | Human-readable explanation (mentions "recorded" only when a file was written) |
| `plan` | `dict` | Offline run-plan from the adapter |
| `would_be_receipt_spec` | `dict\|null` | Optional receipt skeleton |

All seven fields are always present. Check `outcome == "authorization-required"`.
Downstream units should key on `schema_version` for forward-compatibility.

## Executor-injection seam

```python
from lib.gate import execute_or_plan, CAP_EXEC, EXIT_AUTH_REQUIRED, GateError
result = execute_or_plan(
    cap=CAP_EXEC, allow=args.allow_exec, plan=plan_dict,
    live_executor=None,          # drop the live executor here
    would_be_receipt_spec=spec,  # optional
    output_dir=args.output_dir,  # written when allow=False
)
if result["outcome"] == "authorization-required":
    sys.exit(EXIT_AUTH_REQUIRED)  # 3
```

Executor resolution order when allow=True:
1. `RSDD_<CAP>_EXECUTOR` env var → load stub from file.
2. `live_executor` argument.
3. Neither → `GateError` → exit 2.

Executor seam failure contract: if the resolved executor raises at runtime, the gate
wraps the exception in `GateError` and exits 2. No raw traceback propagates to the CLI.

## CLI exit codes

| Code | Meaning |
|---|---|
| 0 | Executor ran |
| 2 | Hard refuse or error |
| 3 | Authorization-required (flag absent) |

## API (`lib/gate.py`)

```
CAP_EXEC, CAP_LIVE_CAPTURE, CAP_DOCKER: str
CAPABILITIES: frozenset[str];  EXIT_AUTH_REQUIRED = 3
class GateError(AdapterError)
cap_flag(cap) -> str
cap_env_var(cap) -> str
build_auth_required(cap, plan, would_be_receipt_spec=None) -> dict
require_capability(cap, allow, plan, would_be_receipt_spec=None) -> dict | None
execute_or_plan(cap, allow, plan, live_executor=None,
                would_be_receipt_spec=None, output_dir=None) -> dict
```
